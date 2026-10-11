import SwiftUI

@main struct GolemMobileApp:App {
    @UIApplicationDelegateAdaptor(MobilePushAppDelegate.self) private var delegate
    @State private var store=MobileStore()
    @Environment(\.scenePhase) private var scenePhase
    var body:some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.environment["GOLEM_TEST_APPEARANCE"] == "1" {
                    NavigationStack { Form { GolemAppearanceSettings() }.navigationTitle("Appearance") }
                } else if ProcessInfo.processInfo.environment["GOLEM_TEST_VOICE_SETTINGS"] == "1" {
                    NavigationStack { Form { GolemVoiceSettings() }.navigationTitle("Voice") }
                } else if store.isPaired {GolemMobileRoot()}
                else {ConnectView()}
                #else
                if store.isPaired {GolemMobileRoot()}
                else {ConnectView()}
                #endif
            }.environment(store).defaultAppStorage(AppPreferences.defaults).environment(\.readerStyle,.mobile)
            // While Golem is open on screen the iPhone doesn't auto-lock; iOS restores it when he isn't.
            .onChange(of:scenePhase,initial:true){_,phase in UIApplication.shared.isIdleTimerDisabled = phase == .active}
            #if DEBUG
            .task {
                let env=ProcessInfo.processInfo.environment
                if !store.isPaired,env["CHATTERBOX_TEST_HOST"]=="127.0.0.1",let port=env["CHATTERBOX_TEST_PORT"],port != String(Companion.port),let code=env["CHATTERBOX_TEST_CODE"]{try? await store.pair(host:"127.0.0.1",code:code)}
            }
            #endif
        }
    }
}
struct GolemMobileRoot:View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability:String?
    @State private var paused=false
    @State private var controlProblem:String?
    @State private var policies:[String:Bool]=[:]
    @Environment(\.horizontalSizeClass) private var sizeClass
    enum Destination:String,CaseIterable,Identifiable {
        case golem="Golem",journal="Journal",notes="Notes",settings="Settings"
        var id:String{rawValue}
        var icon:String{switch self{case .golem:return "sparkles";case .journal:return "book";case .notes:return "note.text";case .settings:return "gearshape"}}
    }
    @State private var destination:Destination? = .golem
    var body:some View {
        Group {
        if sizeClass == .regular {
            NavigationSplitView {
                List(Destination.allCases,selection:$destination){item in
                    NavigationLink(value:item){Label(item.rawValue,systemImage:item.icon)}
                }.navigationTitle("Golem")
            } detail: {
                switch destination ?? .golem {
                case .golem:GolemHome()
                case .journal:GolemJournalMobile()
                case .notes:GolemNotesMobile()
                case .settings:settingsView
                }
            }
        } else {
        TabView(selection: $destination) {
            GolemHome().tabItem{Label("Golem",systemImage:"sparkles")}.tag(Destination.golem as Destination?)
            GolemJournalMobile().tabItem{Label("Journal",systemImage:"book")}.tag(Destination.journal as Destination?)
            GolemNotesMobile().tabItem{Label("Notes",systemImage:"note.text")}.tag(Destination.notes as Destination?)
            settingsView.tabItem{Label("Settings",systemImage:"gearshape")}.tag(Destination.settings as Destination?)
        }
        }
        }
        .modifier(GolemWidgetLinks(destination:$destination))
        .onChange(of: GolemConversationRequest.shared.pending?.id, initial: true) { _, id in
            if id != nil { destination = .golem }
        }
        .safeAreaInset(edge:.top){if let availability{Text(availability).font(.caption).frame(maxWidth:.infinity).padding(8).background(.thinMaterial)}}
        .task(id:scenePhase){
            guard scenePhase == .active else{return}
            while !Task.isCancelled {
                do{availability=try await store.golemAvailability() ? nil:"Golem’s automation service is stopped on your Mac."}
                catch{availability="Can’t reach Golem on your Mac."}
                try? await Task.sleep(for:.seconds(4))
            }
        }
    }
    private var settingsView:some View {
NavigationStack {
                Form {
                    Section{
                        NavigationLink{GolemCapabilitiesView()} label:{Label("What Golem Can Do",systemImage:"sparkles")}
                    }
                    Section("Connection"){
                        Text(store.connection?.macName ?? "Mac")
                        if let problem=store.problem{Text(problem).foregroundStyle(.orange)}
                        Button("Disconnect Golem",role:.destructive){store.forget()}
                    }
                    MobileNotificationControls()
                    Section {
                        NavigationLink("Quick Prompts"){GolemQuickPromptsEditor()}
                    } footer: {Text("Prepared messages, like “Catch me up”, in the menu when you tap Golem at the top left of his conversation.")}
                    GolemVoiceSettings()
                    GolemAppearanceSettings()
                    Section("Automation on your Mac") {
                        ForEach(["dotCheckIns","dotWatchWaiting","dotSummarizeFinished","dotEmailWatch","dotOutlookWatch"],id:\.self){key in
                            // The Outlook watcher is off until turned on; the others are on by default.
                            Toggle(policyLabel(key),isOn:Binding(get:{policies[key] ?? (key != "dotOutlookWatch")},set:{value in policies[key]=value;control("settings",[key:value])}))
                        }
                        Button(paused ? "Resume Automation":"Pause Automation") {control("pause",["paused":!paused])}
                        Button("Check In Now") {control("checkIn")}
                        Button("Sweep Email Now") {control("sweep")}
                        Button("Stop Golem Service",role:.destructive) {control("stop")}
                        if let controlProblem{Text(controlProblem).foregroundStyle(.orange)}
                    }
                    Section{Text("Automation runs on your Mac while its Golem service is enabled. This app connects when you open it.").font(.caption)}
                }.navigationTitle("Golem Settings")
                    .task{do{paused=try await store.golemPaused();policies=try await store.golemPreferences()}catch{controlProblem=error.localizedDescription}}
            }
    }
    private func control(_ operation:String,_ body:[String:Any]=[:]) {
        Task {
            do {
                try await store.golemControl(operation,body:body)
                if operation != "stop"{paused=try await store.golemPaused()}
                controlProblem=nil
            }catch{controlProblem=error.localizedDescription}
        }
    }
    private func policyLabel(_ key:String)->String {
        switch key{case "dotCheckIns":return "Weekday check-ins";case "dotWatchWaiting":return "Brief me when a chat needs me";case "dotSummarizeFinished":return "Summarize finished work";case "dotOutlookWatch":return "Watch Outlook in Chrome";default:return "Watch email"}
    }
}
/// One journal entry from Golem's service. `group` files it like Chatterbox's pages ("project",
/// "studio", "chat", or "golem" for his own work); older entries have none.
struct GolemJournalEntry:Codable,Identifiable {
    var id:UUID;var date:Date;var kind:String;var title:String;var detail:String?;var chat:UUID?
    var chatName:String?;var group:String?;var groupName:String?
    var page:GolemJournalMobile.Page {
        switch group {
        case "project":return .projects
        case "studio":return .studios
        case "chat":return .chats
        case "golem":return .golem
        default:return kind=="decision" && chat != nil ? .chats : .golem
        }
    }
}

struct GolemJournalMobile:View {
    enum Page:String,CaseIterable,Identifiable {
        case projects="Projects",studios="Studios",chats="Chats",golem="Golem"
        var id:String{rawValue}
    }
    @Environment(MobileStore.self) private var store
    @State private var entries:[GolemJournalEntry]=[]
    @State private var problem:String?
    @State private var missingChatterbox=false
    @AppStorage("golemJournalPage") private var pageName=Page.projects.rawValue
    @Environment(\.openURL) private var openURL
    private var page:Page{Page(rawValue:pageName) ?? .projects}
    /// The page's entries, newest first, in sections: each project or studio by name; chats and Golem in one.
    private var sections:[(title:String?,entries:[GolemJournalEntry])] {
        let shown=entries.filter{!GolemNotesMobile.kinds.contains($0.kind) && $0.page==page}.reversed()
        guard page == .projects || page == .studios else{return shown.isEmpty ? [] : [(nil,Array(shown))]}
        var order:[String]=[];var byName:[String:[GolemJournalEntry]]=[:]
        for entry in shown {
            let name=entry.groupName ?? "Other"
            if byName[name]==nil{order.append(name)}
            byName[name,default:[]].append(entry)
        }
        return order.map{($0,byName[$0] ?? [])}
    }
    var body:some View {
        NavigationStack {
            List {
                Picker("Page",selection:$pageName){ForEach(Page.allCases){Text($0.rawValue).tag($0.rawValue)}}
                    .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if let problem{Text(problem).foregroundStyle(.orange)}
                if sections.isEmpty {
                    Text(page == .golem ? "Golem’s own briefings, check-ins and email appear here." : "Briefings about \(page.rawValue.lowercased()) appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(sections.enumerated()),id:\.offset){_,section in
                    Section(section.title ?? "") {
                        ForEach(section.entries){entry in row(entry)}
                    }
                }
            }.navigationTitle("Journal").refreshable{await refresh()}.task{await refresh()}
                .alert("Chatterbox unavailable",isPresented:$missingChatterbox) {
                    Button("OK",role:.cancel) {}
                } message: { Text("Install Chatterbox and pair it with this Mac to open the original chat. Your briefing remains available here.") }
        }
    }
    /// Plain text with its web addresses made tappable (Outlook summaries carry links).
    static func linked(_ text:String)->AttributedString {
        var out=AttributedString(text)
        guard let detector=try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue) else{return out}
        for match in detector.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
            guard let url=match.url,let range=Range(match.range,in:text),
                  let lower=AttributedString.Index(range.lowerBound,within:out),let upper=AttributedString.Index(range.upperBound,within:out) else{continue}
            out[lower..<upper].link=url
        }
        return out
    }
    private func row(_ entry:GolemJournalEntry)->some View {
        VStack(alignment:.leading,spacing:6){
            Text(entry.title).font(.headline)
            if let name=entry.chatName,entry.page != .golem{Text(name).font(.subheadline).foregroundStyle(.secondary)}
            if let detail=entry.detail{Text(Self.linked(detail))}
            Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
            if let chat=entry.chat,entry.page != .golem {
                Button("Open in Chatterbox") {
                    openURL(URL(string:"chatterbox://chat/\(chat)")!) { accepted in
                        if !accepted { missingChatterbox=true }
                    }
                }
            }
        }
    }
    private func refresh() async {
        do{entries=try Companion.decoder.decode([GolemJournalEntry].self,from:await store.golemJournal());problem=nil}
        catch{problem=error.localizedDescription}
    }
}

/// Golem's notebook. Notes are what Golem confirmed with "Noted:" (recorded by his service in the
/// journal); adding or deleting here asks Golem, so the notebook has one keeper.
struct GolemNotesMobile:View {
    static let kinds:Set<String>=["note","note-deleted"]
    struct Note:Identifiable {var id:UUID;var date:Date;var text:String}
    @Environment(MobileStore.self) private var store
    @State private var notes:[Note]=[]
    @State private var pending:Set<String>=[]
    @State private var draft=""
    @State private var problem:String?
    @State private var sent:String?
    static func notes(from entries:[GolemJournalEntry])->[Note] {
        func key(_ text:String)->String{text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))}
        var notes:[Note]=[]
        for entry in entries.sorted(by:{$0.date<$1.date}) {
            guard let text=entry.detail else{continue}
            if entry.kind=="note"{notes.append(Note(id:entry.id,date:entry.date,text:text))}
            else if entry.kind=="note-deleted",let index=notes.firstIndex(where:{key($0.text)==key(text)}){notes.remove(at:index)}
        }
        return notes.reversed()
    }
    var body:some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a note",text:$draft,axis:.vertical).lineLimit(1...4)
                        Button("Add"){ask("Note: \(draft.trimmingCharacters(in:.whitespacesAndNewlines))");draft=""}
                            .disabled(draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text(sent ?? "Or tell Golem “note: …” in any conversation. He confirms with “Noted:” and the note appears here; ask him “what are my notes?” to hear them.")
                }
                if let problem{Text(problem).foregroundStyle(.orange)}
                Section(notes.isEmpty ? "" : "\(notes.count) note\(notes.count==1 ? "":"s")") {
                    if notes.isEmpty{Text("No notes yet.").foregroundStyle(.secondary)}
                    ForEach(notes){note in
                        VStack(alignment:.leading,spacing:4){
                            Text(note.text)
                            Text(pending.contains(note.text) ? "Deleting…" : note.date.formatted(date:.abbreviated,time:.shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions{Button("Delete",role:.destructive){pending.insert(note.text);ask("Delete note: \(note.text)")}}
                    }
                }
            }.navigationTitle("Notes").refreshable{await refresh()}
                .task{while !Task.isCancelled{await refresh();try? await Task.sleep(for:.seconds(pending.isEmpty && sent == nil ? 15:3))}}
        }
    }
    /// Sends the request to Golem's conversation; his "Noted:"/"Deleted note:" reply updates the notebook.
    private func ask(_ text:String) {
        Task {
            do {
                if store.chatList == nil{await store.loadChats()}
                guard let golem=store.chatList?.groups.first(where:{$0.kind == .dot})?.chats.first else{problem="Golem’s conversation isn’t available yet.";return}
                _ = try await store.send(text,to:golem.id)
                sent="Sent to Golem. The note list updates when he confirms.";problem=nil
            }catch{problem=error.localizedDescription}
        }
    }
    private func refresh() async {
        do {
            let entries=try Companion.decoder.decode([GolemJournalEntry].self,from:await store.golemJournal())
            notes=Self.notes(from:entries)
            pending=pending.filter{text in notes.contains{$0.text==text}}
            if pending.isEmpty{sent=nil}
            problem=nil
        }catch{problem=error.localizedDescription}
    }
}

/// Settings → Quick Prompts: the buttons above Golem's message box.
struct GolemQuickPromptsEditor:View {
    @AppStorage(GolemQuickPrompts.key) private var data=Data()
    private var prompts:[GolemQuickPrompt]{GolemQuickPrompts.decode(data)}
    private func update(_ change:(inout [GolemQuickPrompt])->Void){var list=prompts;change(&list);data=GolemQuickPrompts.encode(list)}
    var body:some View {
        List {
            Section {
                ForEach(prompts){prompt in
                    NavigationLink{GolemQuickPromptForm(prompt:prompt){edited in update{list in
                        if let i=list.firstIndex(where:{$0.id==edited.id}){list[i]=edited}}}
                    } label:{
                        VStack(alignment:.leading,spacing:2){
                            Text(prompt.label)
                            Text(prompt.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete{offsets in update{$0.remove(atOffsets:offsets)}}
                .onMove{from,to in update{$0.move(fromOffsets:from,toOffset:to)}}
                NavigationLink{GolemQuickPromptForm(prompt:GolemQuickPrompt(label:"",text:"")){added in
                    update{$0.append(added)}}
                } label:{Label("Add Prompt",systemImage:"plus")}
            } footer: {
                Text("Choosing a prompt from Golem’s menu sends it right away. In the text, {since} becomes the time an hour ago and {now} the time now.")
            }
            Section{Button("Restore Defaults"){data=GolemQuickPrompts.encode(GolemQuickPrompts.defaults)}}
        }
        .navigationTitle("Quick Prompts")
        .toolbar{EditButton()}
    }
}

struct GolemQuickPromptForm:View {
    @State var prompt:GolemQuickPrompt
    let save:(GolemQuickPrompt)->Void
    @Environment(\.dismiss) private var dismiss
    private var valid:Bool{!prompt.label.trimmingCharacters(in:.whitespaces).isEmpty && !prompt.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    var body:some View {
        Form {
            Section("Button"){TextField("Catch me up",text:$prompt.label)}
            Section {
                TextField("What Golem receives",text:$prompt.text,axis:.vertical).lineLimit(3...10)
            } header:{Text("Message")} footer:{
                Text("Sends as: \(GolemQuickPrompts.expand(prompt.text))").font(.caption)
            }
        }
        .navigationTitle(prompt.label.isEmpty ? "New Prompt" : prompt.label)
        .toolbar{ToolbarItem(placement:.confirmationAction){Button("Save"){
            prompt.label=prompt.label.trimmingCharacters(in:.whitespaces)
            prompt.text=prompt.text.trimmingCharacters(in:.whitespacesAndNewlines)
            save(prompt);dismiss()
        }.disabled(!valid)}}
    }
}
