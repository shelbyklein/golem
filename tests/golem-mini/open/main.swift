@testable import Golem
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns":false,"dotWatchWaiting":false,"dotSummarizeFinished":false,"dotEmailWatch":false,"companionEnabled":false,"notifyNeeds":false,"notifyFinished":false,"keepMacAwake":false,GolemMiniWindow.collapsedKey:true],forName:UserDefaults.argumentDomain)
    let model = AppModel(), dot = model.ensureDot()
    let reply = DisplayItem(kind:.assistant,text:"Done.",phase:.final); dot.appendItem(reply)
    model.showingDot = true
    let mini = model.dotMiniWindow!
    try await Task.sleep(for:.milliseconds(500))
    precondition(mini.collapsed)
    // Click to open with the pointer already over him: the opening hover must not arm.
    mini.setCollapsed(false)
    mini.replyHoverChanged(inside:true,replyID:reply.id)
    mini.replyHoverChanged(inside:false,replyID:reply.id)
    try await Task.sleep(for:.milliseconds(400))
    precondition(!mini.collapsed,"Opening click was taken as reading the reply")
    print("PASS opening to talk stays open")
    // Coming back to read, then leaving, still tucks him away.
    try await Task.sleep(for:.milliseconds(300))
    precondition(!mini.panel!.frame.contains(NSEvent.mouseLocation),"pointer happens to sit over the test panel; move it and rerun")
    mini.replyHoverChanged(inside:true,replyID:reply.id)
    mini.replyHoverChanged(inside:false,replyID:reply.id)
    try await Task.sleep(for:.milliseconds(400))
    precondition(mini.collapsed,"Read-then-leave no longer acknowledges")
    print("PASS read then leave still collapses")
    model.showingDot = false
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
