@testable import Golem
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns":false,"dotWatchWaiting":false,"dotSummarizeFinished":false,"dotEmailWatch":false,"companionEnabled":false,"notifyNeeds":false,"notifyFinished":false,"keepMacAwake":false,GolemMiniWindow.collapsedKey:false,"golemTalkListens":false],forName:UserDefaults.argumentDomain)
    let model = AppModel(), dot = model.ensureDot()
    model.showingDot = true; try await Task.sleep(for:.milliseconds(500))
    let talk = GolemTalk.shared; talk.start(model)
    let voice = model.dotMiniWindow!.voice!
    precondition(!voice.muted())
    voice.toggleMute(); precondition(voice.muted() && !talk.reads,"mute didn't turn off reading")
    dot.appendItem(DisplayItem(kind:.assistant,text:"Quiet please.",phase:.final))
    try await Task.sleep(for:.milliseconds(400))
    precondition(!talk.speaking,"spoke while muted")
    voice.toggleMute(); precondition(!voice.muted() && talk.reads)
    print("PASS mini has voice controls; mute stops reading, unmute restores")
    model.showingDot = false
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
