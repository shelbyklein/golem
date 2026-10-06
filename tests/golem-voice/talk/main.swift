@testable import Golem
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns":false,"dotWatchWaiting":false,"dotSummarizeFinished":false,"dotEmailWatch":false,"companionEnabled":false,"notifyNeeds":false,"notifyFinished":false,"keepMacAwake":false,GolemMiniWindow.collapsedKey:false,"golemTalkListens":false],forName:UserDefaults.argumentDomain)
    precondition(GolemSpeaker.spoken("**Done** — see https://example.com/x and `code`.") == "Done — see a link and code.", GolemSpeaker.spoken("**Done** — see https://example.com/x and `code`."))
    let model = AppModel(), dot = model.ensureDot()
    dot.appendItem(DisplayItem(kind:.assistant,text:"Old reply before launch.",phase:.final))
    model.showingDot = true
    try await Task.sleep(for:.milliseconds(500))
    let talk = GolemTalk.shared; talk.start(model)
    try await Task.sleep(for:.milliseconds(300))
    precondition(!talk.speaking,"Read an old reply at start")
    dot.appendItem(DisplayItem(kind:.assistant,text:"Testing.",phase:.final))
    try await Task.sleep(for:.milliseconds(400))
    precondition(talk.speaking,"New reply while open was not read")
    print("PASS new reply read while open; old reply stays quiet; markdown/links cleaned")
    model.dotMiniWindow!.setCollapsed(true)
    try await Task.sleep(for:.milliseconds(600))
    precondition(!talk.speaking,"Kept talking after minimizing")
    dot.appendItem(DisplayItem(kind:.assistant,text:"Should stay quiet.",phase:.final))
    try await Task.sleep(for:.milliseconds(400))
    precondition(!talk.speaking,"Read while minimized")
    print("PASS minimizing stops him; replies while minimized stay quiet")
    dot.isRunning = true
    model.dotMiniWindow!.setCollapsed(false); try await Task.sleep(for:.milliseconds(500))
    dot.appendItem(DisplayItem(kind:.assistant,text:"Partial.",phase:.final))
    try await Task.sleep(for:.milliseconds(300))
    precondition(!talk.speaking,"Read before the turn finished")
    talk.reads = false; dot.isRunning = false
    try await Task.sleep(for:.milliseconds(300))
    precondition(!talk.speaking,"Read with the setting off")
    print("PASS waits for the turn to finish; setting off stays quiet")
    model.showingDot = false
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
