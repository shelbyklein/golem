@testable import Golem
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
@MainActor func run() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"]!)
    precondition(root.path.hasPrefix("/tmp/golem-mini-fit."))
    AppPreferences.defaults.setVolatileDomain([
        "dotCheckIns":false,"dotWatchWaiting":false,"dotSummarizeFinished":false,"dotEmailWatch":false,
        "companionEnabled":false,"notifyNeeds":false,"notifyFinished":false,
        GolemMiniWindow.collapsedKey:false,GolemMiniWindow.sizeKey:1.0,"golemBubbleStyle":"solid"
    ],forName:UserDefaults.argumentDomain)
    let model = AppModel(), dot = model.ensureDot()
    dot.setTitle("Golem")
    dot.draft = "Keep my draft"
    dot.appendItem(DisplayItem(kind:.assistant,text:"Your calendar is clear this afternoon.",phase:.final))
    model.showingDot = true
    let mini=model.dotMiniWindow!, panel=mini.panel!
    let screen=NSScreen.main!.visibleFrame
    panel.setFrame(NSRect(x:screen.maxX-450,y:screen.minY+40,width:400,height:420),display:true)
    try await Task.sleep(for:.milliseconds(700))
    let baseline=panel.frame, center=mini.characterCenter(in:baseline.size)
    let avatarY=baseline.minY+center.y
    func capture(_ name:String) throws {
        let view=panel.contentView!
        guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw RuntimeFailure("No snapshot bitmap")}
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let png=rep.representation(using:.png,properties:[:]) else {throw RuntimeFailure("No PNG snapshot")}
        try png.write(to:root.appendingPathComponent(name+".png"))
    }
    try capture("short")
    let medium="Here is what needs your attention:\n\n" + (1...12).map { "\($0). Review this appointment and its next step." }.joined(separator:"\n")
    dot.appendItem(DisplayItem(kind:.assistant,text:medium,phase:.final))
    try await Task.sleep(for:.milliseconds(900))
    precondition(panel.frame.height>baseline.height+100,"Reply did not automatically grow")
    precondition(abs(panel.frame.minY+mini.characterCenter(in:panel.frame.size).y-avatarY)<1,"Avatar moved while growing")
    precondition(panel.frame.maxY<=screen.maxY,"Reply grew off screen")
    let mediumFrame=panel.frame
    try capture("medium-full")
    print("PASS medium reply grows without an expand click, avatar/composer stay anchored")
    mini.setCollapsed(true)
    try await Task.sleep(for:.milliseconds(80))
    precondition(mini.dismissing && !mini.collapsed,"Dismissal did not preserve outgoing layout")
    precondition(panel.frame == mediumFrame,"Panel resized during outgoing fade")
    try capture("dismiss-midpoint")
    mini.toggleCollapsed()
    try await Task.sleep(for:.milliseconds(250))
    precondition(!mini.collapsed && !mini.dismissing,"Reopening did not cancel dismissal")
    precondition(panel.frame == mediumFrame,"Interrupted dismissal changed the frame")
    mini.setCollapsed(true)
    try await Task.sleep(for:.milliseconds(300))
    precondition(mini.collapsed && !mini.dismissing,"Dismissal did not finish")
    precondition(abs(panel.frame.minY+mini.characterCenter(in:panel.frame.size).y-avatarY)<1,"Dismissal moved Golem")
    try capture("dismiss-complete")
    mini.setCollapsed(false)
    let openingFrame = panel.frame
    precondition(openingFrame.height >= baseline.height,"Opening did not immediately restore panel bounds")
    try await Task.sleep(for:.milliseconds(700))
    print("PASS dismissal holds layout while fading, stays anchored, and cancels on reopen")

    dot.appendItem(DisplayItem(kind:.assistant,text:Array(repeating:"A much longer reply needs a scrollable viewport.",count:240).joined(separator:"\n"),phase:.final))
    try await Task.sleep(for:.milliseconds(900))
    precondition(panel.frame.height>=mediumFrame.height && panel.frame.maxY<=screen.maxY,"Long reply was not screen bounded")
    try capture("long-scroll")
    print("PASS oversized reply uses available screen height and remains bounded")
    dot.appendItem(DisplayItem(kind:.assistant,text:"All set.",phase:.final))
    try await Task.sleep(for:.milliseconds(900))
    precondition(abs(panel.frame.height-baseline.height)<1,"Short reply did not restore baseline height")
    try capture("short-again")
    mini.setCollapsed(true);try await Task.sleep(for:.milliseconds(500));mini.setCollapsed(false)
    try await Task.sleep(for:.milliseconds(700))
    precondition(abs(panel.frame.height-baseline.height)<1,"Reopening retained tall temporary size")
    precondition(dot.draft=="Keep my draft","Sizing changed unsent draft")
    print("PASS short reply shrinks, reopening restores normal size, unsent draft survives")
    try JSONSerialization.data(withJSONObject:["baselineHeight":baseline.height,"mediumHeight":mediumFrame.height,"screenHeight":screen.height],options:.prettyPrinted).write(to:root.appendingPathComponent("result.json"))
    model.showingDot=false
}
Task { @MainActor in do{try await run();exit(0)}catch{print(error);exit(1)} }
app.run()
