import SwiftUI
import AppKit

@main struct GolemApp:App {
    @NSApplicationDelegateAdaptor private var delegate:GolemAppDelegate
    @State private var model:AppModel
    init() {
        // Golem lives in the mini, shown once his conversation arrives from the service;
        // showing it sooner would create a second, empty assistant.
        AppPreferences.defaults.set(false,forKey:GolemMiniWindow.visibleKey)
        let model=AppModel()
        _model=State(initialValue:model)
        GolemAppDelegate.model=model
    }
    var body:some Scene {
        Window("Golem",id:"main"){
            GolemRoot().environment(model).defaultAppStorage(AppPreferences.defaults)
        }
        .defaultSize(width:1000,height:760)
        .defaultLaunchBehavior(.suppressed)
        .commands {GolemCommands(model:model)}
        Settings {GolemServiceSettings().environment(model).defaultAppStorage(AppPreferences.defaults)}
    }
}

/// Golem lives on the iPhone. On the Mac he's off unless turned back on with
/// `defaults write com.shelbyklein.Golem golemDesktop -bool true`; his service (golemd) runs either way.
enum GolemDesktop {
    static let key="golemDesktop"
    static var enabled:Bool {
        #if DEBUG
        // Test runs drive the desktop app on purpose.
        if ProcessInfo.processInfo.environment.keys.contains(where:{$0.hasPrefix("GOLEM_")}) {return true}
        #endif
        return AppPreferences.defaults.bool(forKey:key)
    }
}

final class GolemAppDelegate:NSObject,NSApplicationDelegate {
    @MainActor static var model:AppModel?
    @MainActor func applicationWillFinishLaunching(_ notification:Notification) {
        // Off on the Mac: no Dock icon, menu bar, mini or window.
        if !GolemDesktop.enabled {NSApp.setActivationPolicy(.prohibited)}
    }
    @MainActor func applicationDidFinishLaunching(_ notification:Notification) {
        guard let model=Self.model else{return}
        Task{await GolemLaunch.run(model)}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
}

struct GolemCommands:Commands {
    let model:AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    var body:some Commands {
        let _ = GolemMiniWindow.openSettings = { [openSettings] in
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        let _ = model.revealMainChatWindow={[openWindow] in openWindow(id:"main")}
        CommandGroup(replacing:.newItem){
            Button("Chat with Golem"){model.dotMiniWindow?.openFullChat() ?? openWindow(id:"main")}.keyboardShortcut("o")
            if let session = model.dot {
                RestartThreadControl(session: session, beforeRestart: { GolemTalk.shared.stop() })
            }
            // Before his conversation arrives, showing the mini would invent an empty local one.
            Button(model.showingDot ? "Hide Golem Mini":"Show Golem Mini"){model.showingDot.toggle()}.keyboardShortcut("j").disabled(model.dot==nil)
        }
    }
}

/// Startup work that used to wait for the main window, which no longer opens at launch.
@MainActor enum GolemLaunch {
    static func run(_ model:AppModel) async {
        guard GolemDesktop.enabled else {await runHidden(model);return}
        Attention.shared.start(model:model)
        #if DEBUG
        let environment=ProcessInfo.processInfo.environment
        if environment["GOLEM_TEST_ROLE_CHECK"]=="1"{await GolemCapture.runIfRequested(model);return}
        if environment["GOLEM_TEST_CAPTURE"] != nil || environment["GOLEM_TEST_PERFORMANCE"] != nil {
            while model.revealMainChatWindow==nil {try? await Task.sleep(for:.milliseconds(100))}
            model.revealMainChatWindow?()
        }
        #endif
        while !RuntimeClient.shared.connected {try? await Task.sleep(for:.milliseconds(100))}
        do{_ = try await RuntimeClient.shared.request("ensureAssistant")}catch{Diagnostics.note(error.localizedDescription)}
        GolemAvatar.shared.refreshIfStale()
        for _ in 0..<100 where model.dot==nil {try? await Task.sleep(for:.milliseconds(100))}
        if model.dot != nil {model.showingDot=true}
        GolemTalk.shared.start(model)
        #if DEBUG
        await GolemModelActivation.runIfRequested(model)
        await GolemCapture.runIfRequested(model)
        await GolemTalk.runSmokeIfRequested()
        #endif
    }

    /// Off on the Mac: make sure his conversation exists on the service and his avatar is
    /// current for the phone, then quit. No mini, window, voice or notifications.
    private static func runHidden(_ model:AppModel) async {
        for _ in 0..<150 where !RuntimeClient.shared.connected {try? await Task.sleep(for:.milliseconds(100))}
        if RuntimeClient.shared.connected {
            do{_ = try await RuntimeClient.shared.request("ensureAssistant")}catch{Diagnostics.note(error.localizedDescription)}
            GolemAvatar.shared.refreshIfStale()
            try? await Task.sleep(for:.seconds(5))
        }
        NSApp.terminate(nil)
    }
}

struct GolemRoot:View {
    @Environment(AppModel.self) private var model
    @State private var integrationEnabled=true
    var body:some View {
        @Bindable var model=model
        Group {
            if !integrationEnabled {
                ContentUnavailableView("Golem connection disabled",systemImage:"puzzlepiece.extension",description:Text("Enable Golem in Chatterbox’s Plugins settings to connect again. Your automation service can be managed separately."))
            } else if !RuntimeClient.shared.connected {
                ContentUnavailableView("Chatterbox service unavailable",systemImage:"network.slash",description:Text(RuntimeClient.shared.problem ?? "Connecting…"))
            } else if let assistant=model.dot {
                ChatView(session:assistant, standaloneWindow:true)
            } else {ProgressView("Opening Golem…")}
        }
        .frame(minWidth:640,minHeight:500)
        .toolbar{GolemVoiceToolbar()}
        .safeAreaInset(edge: .bottom) {
            if GolemTalk.shared.listening {
                Text(GolemTalk.shared.inputStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(.regularMaterial)
            }
            if let problem = GolemTalk.shared.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.regularMaterial)
            }
        }
        .background(ChatWindowReader{model.mainChatWindow=$0})
        .onAppear { if model.showingDot { model.showingDot=false } }
        .sheet(isPresented:$model.editingDotMemory){DotMemorySheet()}
        .onChange(of:model.dot?.id){_,id in model.selectedID=id}
        .task {
            while !Task.isCancelled {
                if let health=try? await RuntimeClient.shared.request("health"){
                    let enabled=health["integrationEnabled"]?.bool ?? false
                    if enabled && !integrationEnabled{_ = try? await RuntimeClient.shared.request("ensureAssistant")}
                    integrationEnabled=enabled
                }
                try? await Task.sleep(for:.seconds(3))
            }
        }
        // Closing the chat window sends Golem back to the mini.
        .onDisappear{if !model.showingDot,model.dot != nil {model.showingDot=true}}
    }
}

struct GolemServiceSettings:View {
    @Environment(AppModel.self) private var model
    @AppStorage("dotCheckIns") private var checkIns=true
    @AppStorage("dotWatchWaiting") private var waiting=true
    @AppStorage("dotSummarizeFinished") private var finished=true
    @AppStorage("dotEmailWatch") private var mail=true
    private let service=GolemServiceClient.shared
    var body:some View {
        Form {
            Section("Background service"){
                LabeledContent("Status",value:service.problem ?? (service.transport.connected ? (service.paused ? "Paused":"Running"):"Unavailable"))
                if !service.transport.connected {Button("Start Enabled Service"){service.startInstalledService()}}
                Button(service.paused ? "Resume automation":"Pause automation"){service.command("pause",["paused":.bool(!service.paused)])}.disabled(!service.transport.connected)
                Button("Stop Golem Service",role:.destructive){service.command("stop")}.disabled(!service.transport.connected)
                Text("Closing a window or quitting Golem closes its interface. The background service continues until you stop it. Your Mac can sleep normally.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Automation"){
                Toggle("Weekday check-ins",isOn:$checkIns).onChange(of:checkIns){_,value in service.command("settings",["dotCheckIns":.bool(value)])}
                Toggle("Brief me when a chat needs me",isOn:$waiting).onChange(of:waiting){_,value in service.command("settings",["dotWatchWaiting":.bool(value)])}
                Toggle("Summarize finished work",isOn:$finished).onChange(of:finished){_,value in service.command("settings",["dotSummarizeFinished":.bool(value)])}
                Toggle("Watch email",isOn:$mail).onChange(of:mail){_,value in service.command("settings",["dotEmailWatch":.bool(value)])}
                ForEach(Array(service.checkInTimes.enumerated()),id:\.offset){index,minutes in
                    DatePicker("Check-in \(index+1)",selection:Binding(get:{Calendar.current.startOfDay(for:Date()).addingTimeInterval(Double(minutes)*60)},set:{date in
                        let parts=Calendar.current.dateComponents([.hour,.minute],from:date)
                        var times=service.checkInTimes;times[index]=(parts.hour ?? 0)*60+(parts.minute ?? 0)
                        service.command("settings",["dotCheckInTimes":(try? .value(times)) ?? []])
                    }),displayedComponents:.hourAndMinute)
                }
                Button("Check In Now"){service.command("checkIn")}
                Button("Sweep Email Now"){service.command("sweep")}
            }.disabled(!service.transport.connected)
            Section("Interface") {
                Button("Show Mini"){model.showingDot=true}
                GolemMiniBackdropSettings()
            }
            GolemModelSettings()
            GolemTalkSettings()
            GolemPushSettings()
            Section("iPhone and iPad") {
                Toggle("Allow mobile connections",isOn:Binding(get:{CompanionServer.shared.isEnabled},set:{CompanionServer.shared.setEnabled($0)}))
                if CompanionServer.shared.isEnabled {
                    LabeledContent("Golem pairing code",value:CompanionServer.shared.golemPairingCode)
                    ForEach(CompanionServer.addresses,id:\.self){Text($0).font(.callout.monospaced()).textSelection(.enabled)}
                    ForEach(CompanionServer.shared.devices.filter{$0.product=="golem"}){device in
                        HStack{Text(device.name);Spacer();Button("Remove",role:.destructive){CompanionServer.shared.forget(device)}}
                    }
                    Text("Open Golem on your iPhone or iPad and enter this code. Each app pairs separately.").font(.caption)
                }
            }
        }
        .formStyle(.grouped).frame(width:620,height:540)
        .task{while !Task.isCancelled{await service.refresh();await CompanionServer.shared.refreshProjection();try? await Task.sleep(for:.seconds(3))}}
    }
}


/// Settings are projected from the process that actually sends notifications.
struct GolemPushSettings: View {
    @State private var optedIn = false
    @State private var configured = false
    @State private var enabled = false
    @State private var delivery = "Checking notification service…"
    @State private var actionStatus: String?
    @State private var busy = false
    @State private var available = false

    var body: some View {
        Section("Push notifications") {
            Toggle("Send Golem notifications", isOn: Binding(get: { optedIn }, set: { value in
                busy = true
                Task {
                    defer { busy = false }
                    do { _ = try await RuntimeClient.shared.request("setGolemPushEnabled", body: ["enabled": .bool(value)]) }
                    catch { actionStatus = explain(error) }
                    await refresh()
                }
            })).disabled(busy || !available)
            Text(delivery).font(.callout).textSelection(.enabled)
            if available && !configured {
                Text("No APNs signing key is configured on this Mac. Import the existing key in Chatterbox’s iPhone settings first.").font(.caption).foregroundStyle(.secondary)
            } else if available && !enabled {
                Text("Mobile notifications or mobile connections are disabled on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Button(busy ? "Waiting…" : "Authorize Keychain Access") {
                busy = true
                actionStatus = "In the macOS prompt for chatterboxd, enter your Mac login password and choose Always Allow."
                Task {
                    defer { busy = false }
                    do {
                        let reply = try await RuntimeClient.shared.request("authorizePush", timeout: .seconds(180))
                        actionStatus = reply["status"]?.string ?? "No authorization result returned."
                    } catch { actionStatus = explain(error) }
                    await refresh()
                }
            }.disabled(busy || !available || !configured)
            ForEach(CompanionServer.shared.devices.filter { $0.product == "golem" }) { device in
                HStack {
                    Text(device.name)
                    Spacer()
                    if device.push?.enabled == true {
                        Button("Send Test") { sendTest(device.id) }.disabled(busy || !available || !enabled)
                    } else {
                        Text("Enable notifications on device").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if CompanionServer.shared.devices.allSatisfy({ $0.product != "golem" }) {
                Text("Pair Golem on your iPhone or iPad below, then enable notifications there.").font(.caption).foregroundStyle(.secondary)
            }
            if let actionStatus { Text(actionStatus).font(.caption).textSelection(.enabled) }
            Text("Golem alerts arrive in the Golem iPhone/iPad app. The Mac must be awake; its shared background service sends them even when both app windows are closed. Apple acceptance confirms sending; check your phone to confirm receipt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func explain(_ error: Error) -> String {
        let message = error.localizedDescription
        return message.contains("unsupported") || message.contains("unknown") || message.contains("permission_denied")
            ? "The notification service needs an update and restart to support Golem’s push controls." : message
    }
    private func refresh() async {
        do {
            let reply = try await RuntimeClient.shared.request("pushStatus", body: ["product": "golem"])
            optedIn = reply["optedIn"]?.bool ?? false
            configured = reply["configured"]?.bool ?? false
            enabled = reply["enabled"]?.bool ?? false
            delivery = reply["status"]?.string ?? "No delivery status returned."
            available = true
        } catch { available = false; delivery = explain(error) }
    }
    private func sendTest(_ id: UUID) {
        busy = true
        actionStatus = "Sending a Golem test notification…"
        Task {
            defer { busy = false }
            do {
                let reply = try await RuntimeClient.shared.request("testPush", body: ["product": "golem", "deviceID": .string(id.uuidString)], timeout: .seconds(45))
                actionStatus = reply["status"]?.string ?? "No delivery result returned."
            } catch { actionStatus = explain(error) }
            await refresh()
        }
    }
}
