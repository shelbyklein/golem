import AppKit
import SwiftUI
import ScreenCaptureKit
import Darwin
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
@MainActor func wait(_ label:String,_ predicate:()->Bool) async throws {
    let until=Date().addingTimeInterval(12)
    while !predicate(){guard Date()<until else{throw RuntimeFailure("Timed out: \(label)")};try await Task.sleep(for:.milliseconds(30))}
    print("PASS \(label)")
}
@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns":false,"dotEmailWatch":false,"notifyNeeds":false,"notifyFinished":false,"companionEnabled":false],forName:UserDefaults.argumentDomain)
    let model=AppModel()
    try await wait("UI connected to daemon"){RuntimeClient.shared.connected}
    let chat=model.newChat(backend:.claude)
    try await wait("creation projected"){chat.remoteCommand != nil && model.sessions.contains{$0.id==chat.id}}
    chat.send("hello")
    try await wait("daemon reply projected"){chat.items.contains{$0.kind == .assistant} && !chat.isRunning}
    guard chat.claudeProcess==nil,!CodexAppServer.shared.isRunning else{throw RuntimeFailure("UI started provider")}
    print("PASS UI owns no provider")
    let studio=Studio(name:"Daemon studio",folder:RuntimePaths.data.path,instructions:"Preserved instructions")
    _ = try await RuntimeClient.shared.request("studios",body:["studios":try .value([studio])])
    try await wait("studio update reaches UI projection"){model.studios.contains{$0.id==studio.id && $0.instructions==studio.instructions}}
    let pin=Pin(title:"Fixture folder",kind:.file,target:RuntimePaths.data.path)
    _ = try await RuntimeClient.shared.request("pins",body:["pins":try .value([pin])])
    try await wait("pin update reaches UI projection"){PinStore.shared.pins.contains{$0.id==pin.id}}
    _ = try await RuntimeClient.shared.request("preferences",body:["defaultEffort":"high"])
    try await wait("runtime preference update reaches UI projection"){AppPreferences.defaults.string(forKey:"defaultEffort")=="high"}
    let count=chat.items.count
    chat.draft="remember this draft"
    try await Task.sleep(for:.milliseconds(300))
    RuntimeClient.shared.stop();RuntimeClient.shared.start()
    try await wait("reconnected"){RuntimeClient.shared.connected}
    try await Task.sleep(for:.milliseconds(300))
    guard chat.items.count==count,chat.draft=="remember this draft" else{throw RuntimeFailure("Reconnect changed rows or draft")}
    print("PASS reconnect retains one copy and draft")
    guard model.studios.contains{$0.id==studio.id},PinStore.shared.pins.contains{$0.id==pin.id},AppPreferences.defaults.string(forKey:"defaultEffort")=="high" else{throw RuntimeFailure("Reconnect lost configuration")}
    if ProcessInfo.processInfo.environment["GOLEM_TEST_APP_PATH"] != nil {
        await GolemIntegration.shared.refresh()
        guard GolemIntegration.shared.enabled,GolemIntegration.shared.installed else{throw RuntimeFailure("Plugin missing fixture app")}
        GolemIntegration.shared.setEnabled(false)
        try await wait("plugin toggle revokes integration"){!GolemIntegration.shared.enabled}
        GolemIntegration.shared.setEnabled(true)
        try await wait("plugin toggle restores integration"){GolemIntegration.shared.enabled}
        let path=ProcessInfo.processInfo.environment["GOLEM_TEST_CAPTURE"]!+"/golem-main.png"
        try? FileManager.default.removeItem(atPath:path)
        GolemIntegration.shared.open()
        try await wait("plugin launches actual standalone Golem with isolated data"){FileManager.default.fileExists(atPath:path)}
    }
    let window=NSWindow(contentRect:NSRect(x:60,y:60,width:1100,height:780),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    window.contentView=NSHostingView(rootView:ContentView().environment(model));window.orderFrontRegardless()
    try await Task.sleep(for:.seconds(1))
    if #available(macOS 14.4,*) {
        let target=try await SCShareableContent.currentProcess.windows.first{$0.windowID==CGWindowID(window.windowNumber)}!
        let config=SCStreamConfiguration();config.width=1100;config.height=780;config.ignoreShadowsSingleWindow=true
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:target),configuration:config)
        let dest=URL(fileURLWithPath:ProcessInfo.processInfo.environment["PROJECTION_CAPTURE"]!)
        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:dest)
    }
    RuntimeClient.shared.stop()
}
Task{@MainActor in do{try await run();exit(0)}catch{print("FAIL \(error.localizedDescription)");exit(1)}}
app.run()
