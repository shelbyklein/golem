import Foundation
import CryptoKit


/// Durable trigger identities and command receipts survive UI and service restarts.
/// Only this process writes assistant policy state and journal.json.
@MainActor final class GolemJobs {
    struct Job:Codable {var id:String;var label:String;var text:String;var submitted=false}
    struct State:Codable {var schema=1;var jobs:[Job]=[];var seen:Set<String>=[];var problem:String?;var paused=false;var emailAttempt:Date?;var emailThrough:Date?;var emailProblem:String?;var emailAccounts:[String]?;var controls:[String:CommandReceipt]?=[:]
        /// Consecutive failed sweeps, since when, and whether the user has been told.
        var emailFailures:Int?;var emailFailingSince:Date?;var emailAlerted:Bool?
        /// Important mail found while catching up, briefed once when the watcher reaches the present.
        var emailBacklog:[EmailSweep.Email]?;var emailBacklogSince:Date?}
    struct Entry:Codable {var id:UUID;var date:Date;var kind:String;var title:String;var detail:String?;var chat:UUID?;var chatName:String?}
    private(set) var state:State
    private(set) var entries:[Entry]
    private let folder:URL
    private let ownership:RuntimeOwnership
    private let client:RuntimeClient
    private var timer:Timer?
    private var processing=false
    private var refreshing=false
    private var sweeping=false
    var isSweeping:Bool{sweeping}
    private var pendingEvents:[RuntimeEvent]=[]
    private var persistenceHealthy=true
    private var integrationEnabled=false
    private let encoder:JSONEncoder={let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;return e}()
    init(client:RuntimeClient) throws {
        self.client=client
        folder=URL(fileURLWithPath:RuntimePaths.assistantFolder)
        ownership=try RuntimeOwnership(root:folder.appendingPathComponent("Service"))
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let stateFile=folder.appendingPathComponent("service-state.json")
        if FileManager.default.fileExists(atPath:stateFile.path){state=try decoder.decode(State.self,from:Data(contentsOf:stateFile))}else{state=State()}
        let journal=folder.appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath:journal.path){entries=try decoder.decode([Entry].self,from:Data(contentsOf:journal))}else{entries=[]}
        guard state.schema==1 else{throw RuntimeFailure("Unsupported Golem state version")}
        for key in (state.controls ?? [:]).keys where state.controls?[key]?.state == "dispatching" {
            state.controls?[key]?.state="delivery_uncertain"
        }
        let prefs=folder.appendingPathComponent("service-preferences.plist")
        if FileManager.default.fileExists(atPath:prefs.path) {
            let values=try PropertyListSerialization.propertyList(from:Data(contentsOf:prefs),format:nil) as? [String:Any] ?? [:]
            for (key,value) in values{AppPreferences.defaults.set(value,forKey:key)}
        }
    }
    func start(){
        client.onEvent={ [weak self] event in self?.refresh(event) }
        client.start(role:"golem")
        timer=Timer.scheduledTimer(withTimeInterval:60,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
    }
    func stop(){timer?.invalidate();timer=nil;EmailSweep.cancel();client.stop()}
    func pause(_ paused:Bool){state.paused=paused;save();if paused{EmailSweep.cancel()}else{tick()}}
    func checkInNow(){enqueue(id:"manual:\(UUID())",label:"Check-in",text:"Do your standing jobs from your memory and brief the user on anything that needs them. Reply NO_REPORT when nothing needs them.");drain()}
    func sweepNow(){state.emailAttempt=nil;save();sweep(now:Date())}
    func settings(_ values:JSON) throws {
        let keys:Set<String>=["dotCheckIns","dotCheckInTimes","dotWatchWaiting","dotSummarizeFinished","dotEmailWatch","dotEmailModel"]
        guard let body=values.object,Set(body.keys).isSubset(of:keys) else{throw RuntimeFailure("unsupported_preference")}
        var staged=AppPreferences.defaults.dictionaryRepresentation().filter{keys.contains($0.key)}
        for (key,value) in body {
            if key=="dotCheckInTimes"{let times=try value.decode([Int].self);guard times.allSatisfy({(0..<1440).contains($0)}),times.count<=4 else{throw RuntimeFailure("invalid_times")};staged[key]=times.sorted()}
            else if key=="dotEmailModel",let x=value.string,!x.isEmpty{staged[key]=x}
            else if key != "dotEmailModel",let x=value.bool{staged[key]=x}
            else{throw RuntimeFailure("invalid_preference")}
        }
        // Validate the whole update and persist it before changing the live policy.
        try PropertyListSerialization.data(fromPropertyList:staged,format:.binary,options:0).write(to:folder.appendingPathComponent("service-preferences.plist"),options:.atomic)
        for (key,value) in staged{AppPreferences.defaults.set(value,forKey:key)}
    }
    func executeControl(_ request:RuntimeRequest,_ action:() throws -> JSON) throws -> JSON {
        let e=JSONEncoder();e.outputFormatting = .sortedKeys
        let fingerprint=SHA256.hash(data:try e.encode(request.body)).map{String(format:"%02x",$0)}.joined()
        if let receipt=state.controls?[request.id] {
            guard receipt.operation==request.operation,receipt.fingerprint==fingerprint else{throw RuntimeFailure("request_id_conflict")}
            guard receipt.state=="completed",let result=receipt.result else{throw RuntimeFailure("delivery_uncertain")}
            return result
        }
        guard (state.controls?.count ?? 0)<100_000 else{throw RuntimeFailure("Golem command receipts are full; no action was applied")}
        if state.controls==nil{state.controls=[:]}
        state.controls?[request.id]=CommandReceipt(operation:request.operation,fingerprint:fingerprint,state:"dispatching")
        save();guard persistenceHealthy else{throw RuntimeFailure("Golem persistence unavailable")}
        let result=try action()
        state.controls?[request.id]?.result=result;state.controls?[request.id]?.state="completed"
        save();guard persistenceHealthy else{throw RuntimeFailure("delivery_uncertain")}
        return result
    }
    func tick(now:Date=Date()){
        var now=now
        #if DEBUG
        if RuntimePaths.data.path.hasPrefix("/tmp/golem-"),let clock=ProcessInfo.processInfo.environment["GOLEM_TEST_CLOCK"],let date=ISO8601DateFormatter().date(from:clock){now=date}
        #endif
        guard !state.paused,client.connected else{return}
        let d=AppPreferences.defaults,calendar=Calendar.current
        let minutes=calendar.component(.hour,from:now)*60+calendar.component(.minute,from:now)
        let day=calendar.dateComponents([.year,.month,.day],from:now)
        let dayKey=String(format:"%04d-%02d-%02d",day.year!,day.month!,day.day!)
        if integrationEnabled,(d.object(forKey:"dotCheckIns") as? Bool ?? true),!calendar.isDateInWeekend(now){
            for time in (d.array(forKey:"dotCheckInTimes") as? [Int] ?? [480,900]) where time<=minutes && minutes-time<=180 {
                enqueue(id:"schedule:\(dayKey):\(time)",label:time<720 ? "Morning check-in":"Afternoon check-in",text:"This is a scheduled check-in. Do your standing jobs from your memory. Check only what your tools reach. If nothing needs the user, reply exactly NO_REPORT. Otherwise give a short briefing, most important first.")
            }
        }
        if d.object(forKey:"dotEmailWatch") as? Bool ?? true {sweep(now:now)}
        drain()
    }
    private func sweep(now:Date){
        let interval:TimeInterval=(9..<17).contains(Calendar.current.component(.hour,from:now)) ? 900:1800
        // While catching up, the next window follows straight on; otherwise wait the usual interval.
        let behind=now.timeIntervalSince(state.emailThrough ?? now)>interval
        let wait:TimeInterval=behind && (state.emailFailures ?? 0)==0 ? 0:interval
        guard !state.paused,!sweeping,now.timeIntervalSince(state.emailAttempt ?? .distantPast)>=wait else{return}
        guard let codex=CodexAppServer.locateBinary() else {
            state.emailAttempt=now
            failed("Email watcher cannot start Codex. Check Golem’s app-specific codexPath for a missing executable.",now:now);return
        }
        // A test fixture left in the real preferences once made every sweep "succeed" at nothing.
        if !RuntimePaths.data.path.hasPrefix("/tmp/golem-"),EmailCatchUp.looksLikeFixture(codex) {
            state.emailAttempt=now
            failed("Email watcher is set to run a test provider instead of Codex (\(codex)). Remove codexPath from Golem’s preferences.",now:now);return
        }
        if let skipped=EmailCatchUp.skipped(through:state.emailThrough,now:now),let through=state.emailThrough {
            journal(id:"email-skipped:\(Int(through.timeIntervalSince1970))",title:"Older email not swept",detail:"Email between \(through.formatted()) and \(skipped.formatted()) was older than a week when the watcher recovered and wasn’t checked.",kind:"activity",chat:nil)
        }
        guard let window=EmailCatchUp.window(through:state.emailThrough,failures:state.emailFailures ?? 0,now:now) else{return}
        state.emailAttempt=now;save();sweeping=true
        Task {
            defer{sweeping=false}
            let result=await EmailSweep.run(codex:codex,model:AppPreferences.defaults.string(forKey:"dotEmailModel") ?? "gpt-6-luna",prompt:EmailSweep.prompt(name:"Golem",since:window.since,until:window.until))
            guard !state.paused else{return}
            switch result {
            case .failure(let error):failed(error,now:Date())
            case .success(let emails,let accounts):
                if state.problem==state.emailProblem{state.problem=nil}
                state.emailProblem=nil;state.emailAccounts=accounts
                state.emailFailures=nil;state.emailFailingSince=nil;state.emailAlerted=nil
                let fresh=emails.filter{!state.seen.contains(identity($0))}
                for email in fresh {
                    journal(id:"journal:\(identity(email))",title:"Email from \(email.from)",detail:"\(email.subject): \(email.why) Suggested: \(email.action)",kind:"activity",chat:nil)
                }
                if window.catchingUp || state.emailBacklog != nil {
                    if state.emailBacklogSince==nil{state.emailBacklogSince=window.since}
                    var backlog=state.emailBacklog ?? []
                    for email in fresh where !backlog.contains(where:{identity($0)==identity(email)}){backlog.append(email)}
                    state.emailBacklog=backlog
                }
                if window.catchingUp {
                    state.emailThrough=window.until;save()
                    // The next piece of the backlog, straight away (once this sweep has finished).
                    Task{sweep(now:Date())}
                    return
                }
                state.emailThrough=window.until
                if let backlog=state.emailBacklog {
                    briefCatchUp(backlog,since:state.emailBacklogSince ?? window.since,until:window.until)
                    state.emailBacklog=nil;state.emailBacklogSince=nil
                } else {
                    for email in fresh {enqueue(id:identity(email),label:"Email from \(email.from)",text:Self.emailJob(email))}
                }
                save();drain()
            }
        }
    }
    private func identity(_ email:EmailSweep.Email)->String {"email:\(email.account):\(email.id.isEmpty ? email.subject : email.id)"}
    private static func emailJob(_ email:EmailSweep.Email)->String {
        "Email candidate: \(email.subject) (\(email.account)). \(email.why) Suggested next step: \(email.action). \(email.link). Before reporting, check your conversation context and, for project alerts, list/read the matching project chat. Correlate the alert with existing work and link to that chat when relevant. If it is routine, already addressed, unchanged from an earlier alert, or needs no new user action, reply exactly NO_REPORT. Important school, appointments, life admin and USA Archery deserve contextual attention; ordinary autopay notices and speculative announcements stay quiet. Otherwise give a brief contextual report. This sweep only read mail; do not send, draft, archive, label, mark read or change any email."
    }
    /// Everything found while catching up, as one briefing.
    private func briefCatchUp(_ emails:[EmailSweep.Email],since:Date,until:Date){
        let ids=emails.map(identity)
        guard !emails.isEmpty else{return}
        let list=emails.enumerated().map{"\($0.offset+1). \($0.element.subject) — from \($0.element.from) (\($0.element.account)). \($0.element.why) Suggested: \($0.element.action). \($0.element.link)"}.joined(separator:"\n")
        enqueue(id:"email-catchup:\(Int(since.timeIntervalSince1970))",label:"Email catch-up",text:"Email catch-up: the email watcher was behind and has now read the mail from \(since.formatted()) to \(until.formatted()). These candidates passed the sweep's filter:\n\(list)\nGive ONE short catch-up briefing, most important first. Check your conversation context and, for project alerts, list/read the matching project chat; link to it when relevant. Leave out anything routine, already addressed, unchanged from an earlier alert, or needing no new user action. Important school, appointments, life admin and USA Archery deserve contextual attention; ordinary autopay notices and speculative announcements stay quiet. If nothing needs the user, reply exactly NO_REPORT. This sweep only read mail; do not send, draft, archive, label, mark read or change any email.")
        // Later sweeps that see the same messages stay quiet.
        for id in ids{state.seen.insert(id)}
    }
    /// A failed sweep keeps the cursor, shrinks the next window, and tells the user once if it persists.
    private func failed(_ error:String,now:Date){
        state.emailProblem=error;state.problem=error
        state.emailFailures=(state.emailFailures ?? 0)+1
        if state.emailFailingSince==nil{state.emailFailingSince=now}
        save()
        guard EmailCatchUp.shouldAlert(failingSince:state.emailFailingSince,failures:state.emailFailures ?? 0,alerted:state.emailAlerted ?? false,now:now),
              let since=state.emailFailingSince else{return}
        state.emailAlerted=true;save()
        let text="Email watching has been failing since \(since.formatted(date:.abbreviated,time:.shortened)), so I may have missed important mail. Last error: \(error) I’m retrying with smaller windows; nothing will be skipped once it recovers."
        journal(id:"email-failing:\(Int(since.timeIntervalSince1970))",title:"Email watching is failing",detail:text,kind:"activity",chat:nil)
        Task {_ = try? await client.request("notify",body:["title":"Golem","text":.string(text)],id:"notification-email-failing-\(Int(since.timeIntervalSince1970))")}
    }
    func enqueue(id:String,label:String,text:String){
        guard !state.seen.contains(id),!state.jobs.contains(where:{$0.id==id}) else{return}
        guard state.jobs.count<1000,state.seen.count<100_000 else {
            state.problem="Golem’s durable job storage is full. Automation is paused; review the service state before resuming."
            state.paused=true;save();return
        }
        state.jobs.append(Job(id:id,label:label,text:"<app_note>\n\(text)\nYou may suggest answers but never submit user answers or approve requests.\n</app_note>"))
        save()
    }
    private func refresh(_ event:RuntimeEvent){
        guard event.kind != "turn.progress",event.kind != "draft.changed" else{return}
        guard !refreshing else{
            if pendingEvents.count<256{pendingEvents.append(event)}
            else{pendingEvents=[RuntimeEvent(sequence:event.sequence,revision:0,kind:"runtime.resync")]}
            return
        }
        guard client.connected else{return}
        refreshing=true
        Task {
            defer{refreshing=false;if !pendingEvents.isEmpty{refresh(pendingEvents.removeFirst())}}
            do {
                let health=try await client.request("health")
                integrationEnabled=health["integrationEnabled"]?.bool ?? false
                guard integrationEnabled,!state.paused else{return}
                let chats=try await client.request("list").decode([RuntimeChatState].self)
                let d=AppPreferences.defaults
                for chat in chats where chat.record.isDot != true {
                    if d.object(forKey:"dotWatchWaiting") as? Bool ?? true {
                        for item in chat.pendingItems ?? chat.record.items where item.approvalState == .pending {
                            enqueue(id:"waiting:\(item.id)",label:"\(chat.record.title) is waiting on you",text:"Chat \(chat.record.id) is waiting on the user: \(item.text). Read it with read_chat and briefly explain what it needs from the user. Suggest an answer only when confident and the decision is not personal or about money, access, deletion or publishing.")
                        }
                    }
                    if !chat.running,(event.kind=="runtime.resync" || (event.chatID==chat.record.id && event.kind=="turn.finished")),d.object(forKey:"dotSummarizeFinished") as? Bool ?? true {
                        let last=chat.record.items.lastIndex(where:{$0.kind == .user}) ?? 0
                        let turn=chat.record.items.dropFirst(last)
                        if chat.record.dotFollowing==true || turn.contains(where:{$0.kind == .tool || ($0.workedSeconds ?? 0)>=60}) {
                            if let reply=turn.last(where:{$0.kind == .assistant && $0.phase == .final}),Date().timeIntervalSince(chat.record.updatedAt)<86400 {
                                enqueue(id:"finished:\(chat.record.id):\(reply.id)",label:"\(chat.record.title) finished",text:"Chat \(chat.record.id) finished. Read it with read_chat and summarize the result, what changed and anything the user needs to do or decide next.")
                            }
                        }
                    }
                }
                let notes=try await client.request("assistantNotes").decode([JSON].self)
                for note in notes {
                    guard let id=note["id"]?.string else{continue}
                    if !state.seen.contains(id){journal(id:id,title:note["title"]?.string ?? "Decision",detail:note["detail"]?.string,kind:"decision",chat:note["chatID"]?.string.flatMap(UUID.init(uuidString:)))}
                }
                if persistenceHealthy,!notes.isEmpty {_ = try await client.request("ackAssistantNotes",body:["ids":try .value(notes.compactMap{$0["id"]?.string})])}
                if let assistant=chats.first(where:{$0.record.isDot==true}),!assistant.running {
                    for item in assistant.record.items where item.kind == .assistant && item.phase == .final && !item.text.isEmpty {
                        if item.text != "NO_REPORT",!state.seen.contains("reply:\(item.id)"){
                            _ = try await client.request("notify",body:["title":"Golem","text":.string(item.text),"itemID":.string(item.id.uuidString)],id:"notification-\(item.id)")
                        }
                        journal(id:"reply:\(item.id)",title:item.text=="NO_REPORT" ? "Nothing needs you":"Briefing",detail:item.text,kind:"activity",chat:assistant.record.id)
                    }
                }
                tick();drain()
            }catch{state.problem=error.localizedDescription;save()}
        }
    }
    private func drain(){
        guard integrationEnabled,persistenceHealthy,!processing,!state.paused,client.connected,let job=state.jobs.first(where:{!$0.submitted}) else{return}
        processing=true
        Task {
            defer{processing=false}
            do {
                let chats=try await client.request("list").decode([RuntimeChatState].self)
                guard chats.first(where:{$0.record.isDot==true})?.running != true else{return}
                _ = try await client.request("sendAutomatic",body:["label":.string(job.label),"text":.string(job.text)],id:stableUUID("job:\(job.id)").uuidString)
                if let i=state.jobs.firstIndex(where:{$0.id==job.id}){state.jobs[i].submitted=true}
                journal(id:job.id,title:job.label,detail:nil,kind:"activity",chat:nil)
                // A failing email watcher stays visible until a sweep succeeds.
                state.jobs.removeAll{$0.submitted};if state.problem != state.emailProblem{state.problem=nil};save()
            }catch{state.problem=error.localizedDescription;save()}
        }
    }
    private func journal(id:String,title:String,detail:String?,kind:String,chat:UUID?){
        guard !state.seen.contains(id) else{return}
        // Journal entry UUID is deterministically recovered from the persisted identity list.
        // Save journal before state; a retry checks its entry identity to avoid duplication.
        let uuid=UUID(uuidString:id.replacingOccurrences(of:"reply:",with:"")) ?? stableUUID(id)
        if !entries.contains(where:{$0.id==uuid}){entries.append(Entry(id:uuid,date:Date(),kind:kind,title:title,detail:detail,chat:chat,chatName:nil))}
        entries=Array(entries.suffix(400));state.seen.insert(id);save()
    }
    private func stableUUID(_ text:String)->UUID {
        let digest=SHA256.hash(data:Data(text.utf8));let bytes=Array(digest.prefix(16))
        return bytes.withUnsafeBytes{UUID(uuid:$0.loadUnaligned(as:uuid_t.self))}
    }
    private func save(){
        do {try encoder.encode(entries).write(to:folder.appendingPathComponent("journal.json"),options:.atomic)
            try encoder.encode(state).write(to:folder.appendingPathComponent("service-state.json"),options:.atomic);persistenceHealthy=true}
        catch{persistenceHealthy=false;state.problem="Golem persistence failed: \(error.localizedDescription)";RuntimeHooks.note(state.problem!)}
    }
}
