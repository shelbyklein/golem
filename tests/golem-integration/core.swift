import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message:String) throws {
    guard condition() else {throw RuntimeFailure(message)}
    print("PASS \(message)")
}
@MainActor func wait(_ message:String, until predicate: () -> Bool) async throws {
    let until=Date().addingTimeInterval(8)
    while !predicate() { if Date()>until { throw RuntimeFailure("Timed out: \(message)") };try await Task.sleep(for:.milliseconds(20)) }
}
@MainActor func test() async throws {
    let root=RuntimePaths.data
    UserDefaults.standard.setVolatileDomain([
        "claudePath":ProcessInfo.processInfo.environment["FAKE_PROVIDER"]!,"codexPath":ProcessInfo.processInfo.environment["FAKE_PROVIDER"]!,
        "easyCLIProxyEnabled":false,"remoteControlClaudeChats":false
    ], forName:UserDefaults.argumentDomain)
    var runtime:ConversationRuntime?=try ConversationRuntime(root:root)
    await runtime!.resume()
    do { let second=try ConversationRuntime(root:root);_ = second;throw RuntimeFailure("Duplicate writer accepted") }
    catch {try check(error.localizedDescription.contains("active writer"),"duplicate writer refused")}
    for backend in Backend.allCases {
        var r=ConversationRecord(model:"default",effort:"",personality:.neutral)
        r.activeBackend=backend
        r.projectFolder=root.path
        if backend == .codex {r.codex=CodexSettings(folder:root.path,canEdit:false,mode:"readOnly")}
        let s=try runtime!.insert(r)
        s.send("hello")
        try await wait("\(backend) reply") { !s.isRunning && s.items.contains {$0.kind == .assistant} }
        try check(s.items.filter {$0.kind == .assistant}.count==1,"\(backend) ordinary reply")
        s.send("question")
        try await wait("question") {s.items.contains {$0.kind == .questions && $0.approvalState == .pending}}
        let q=s.items.last {$0.kind == .questions}!
        s.answerQuestions(q.id,answers:[q.questions!.first!.id:["A"]])
        try await wait("answered") {!s.isRunning}
        try check(s.items.first {$0.id==q.id}?.approvalState == .approved,"\(backend) user answer")
        s.send("approval")
        try await wait("approval") {s.items.contains {$0.kind == .approval && $0.approvalState == .pending}}
        let a=s.items.last {$0.kind == .approval}!
        s.resolveApproval(a.id,.denied)
        try await wait("denied") {!s.isRunning}
        try check(s.items.first {$0.id==a.id}?.approvalState == .denied,"\(backend) user denial")
        s.send("hold")
        try await wait("running") {s.isRunning}
        try await Task.sleep(for:.milliseconds(150))
        s.send("steer")
        try await wait("steered") {!s.isRunning}
        try check(s.items.contains {$0.kind == .user && $0.steered},"\(backend) steering")
        s.send("hold")
        try await Task.sleep(for:.milliseconds(150));s.interrupt()
        try await wait("stopped") {!s.isRunning}
        try check(!s.canStop,"\(backend) stop")
        s.send("hold")
        s.send("queued immediately")
        try await wait("queued drain") {!s.isRunning}
        try check(s.items.contains {$0.text=="queued immediately" && $0.steered},"\(backend) queued while starting")
        s.send("hold")
        try await Task.sleep(for:.milliseconds(150))
        try runtime!.flush()
        let beforeRestart=s.items.count
        let chatID=s.id
        for old in runtime!.sessions {old.onChange=nil;old.onStreamed=nil}
        runtime=nil
        runtime=try ConversationRuntime(root:root)
        await runtime!.resume()
        let reattached=runtime!.session(chatID)!
        try check(reattached.isRunning,"\(backend) active turn reattached headlessly")
        reattached.interrupt()
        try await wait("reattached stop") {!reattached.isRunning}
        try check(reattached.items.count <= beforeRestart+1,"\(backend) active replay without duplicate user row")
        try runtime!.updateDraft(reattached,text:"unsent",attachments:[])
    }
    let request="dedupe"
    let first=try runtime!.execute(id:request,operation:"insert",fingerprint:"same") {let s=try runtime!.insert(ConversationRecord(model:"default",effort:"",personality:.neutral));return .string(s.id.uuidString)}
    let second=try runtime!.execute(id:request,operation:"insert",fingerprint:"same") {throw RuntimeFailure("Repeated side effect")}
    try check(first==second,"idempotent command returns original result")
    try runtime!.flush()
    let counts=Dictionary(uniqueKeysWithValues:runtime!.sessions.map {($0.id,$0.items.count)})
    for s in runtime!.sessions {s.onChange=nil;s.onStreamed=nil}
    runtime=nil
    let reopened=try ConversationRuntime(root:root)
    await reopened.resume()
    try check(reopened.sessions.allSatisfy {counts[$0.id]==$0.items.count},"restart retains row counts")
    try check(reopened.sessions.filter {$0.draft=="unsent"}.count==2,"restart retains drafts")
    try await Task.sleep(for:.milliseconds(200))
    try check(reopened.sessions.allSatisfy {counts[$0.id]==$0.items.count},"provider replay does not duplicate rows")
    for s in reopened.sessions {s.shutdown()}
    CodexAppServer.shared.terminate();HostClient.shared.disconnect()
    print("PASS Foundation runtime, both providers, restart and ownership")
}
Task { @MainActor in do {try await test();exit(0)}catch {print("FAIL \(error.localizedDescription)");exit(1)} }
RunLoop.main.run()
