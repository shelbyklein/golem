@testable import Golem
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns":false,"dotWatchWaiting":false,"dotSummarizeFinished":false,"dotEmailWatch":false,"companionEnabled":false,"notifyNeeds":false,"notifyFinished":false,"keepMacAwake":false,GolemMiniWindow.collapsedKey:false],forName:UserDefaults.argumentDomain)
    let model = AppModel(), dot = model.ensureDot()
    dot.appendItem(DisplayItem(kind:.assistant,text:(1...60).map{"Line \($0) of a long briefing."}.joined(separator:"\n"),phase:.final))
    model.showingDot = true
    let mini = model.dotMiniWindow!, panel = mini.panel!
    panel.setFrame(NSRect(x:200,y:120,width:400,height:520),display:true)
    try await Task.sleep(for:.milliseconds(600))
    let before = panel.frame
    let screen = NSScreen.screens.map(\.visibleFrame).first{$0.contains(NSPoint(x:before.midX,y:before.minY))}!
    mini.setBubbleExpanded(true)
    try await Task.sleep(for:.milliseconds(600))
    print("expanded", panel.frame, "screen top", screen.maxY)
    precondition(panel.frame.height > 600 && abs(panel.frame.minY-before.minY)<1 && panel.frame.maxY <= screen.maxY+0.5,"Did not grow upward to the screen top with Golem fixed")
    precondition(UserDefaults.standard.string(forKey:"golemMiniExpandedFrame").map(NSRectFromString)?.height ?? 0 < 600,"Expanded frame was saved as the usual size")
    mini.setBubbleExpanded(false)
    try await Task.sleep(for:.milliseconds(600))
    precondition(abs(panel.frame.height-before.height)<1 && abs(panel.frame.minY-before.minY)<1,"Did not return to usual size: \(panel.frame) vs \(before)")
    print("PASS expand grows to screen top with Golem fixed; shrink restores")
    mini.setBubbleExpanded(true); try await Task.sleep(for:.milliseconds(600))
    mini.setCollapsed(true); try await Task.sleep(for:.milliseconds(600))
    mini.setCollapsed(false); try await Task.sleep(for:.milliseconds(800))
    precondition(!mini.bubbleExpanded && abs(panel.frame.height-before.height)<1,"Minimizing while expanded did not restore usual size: \(panel.frame)")
    print("PASS minimize while expanded reopens at usual size")
    model.showingDot = false
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
