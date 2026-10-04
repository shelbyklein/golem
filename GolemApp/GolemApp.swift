import SwiftUI
import AppKit

@main struct GolemApp:App {
    @State private var model=AppModel()
    var body:some Scene {
        WindowGroup("Golem",id:"main"){
            GolemRoot().environment(model).defaultAppStorage(AppPreferences.defaults)
        }
        .defaultSize(width:1000,height:760)
        .commands {
            CommandGroup(replacing:.newItem){Button("Show Golem Mini"){model.showingDot.toggle()}.keyboardShortcut("j")}
        }
        Settings {GolemServiceSettings().environment(model).defaultAppStorage(AppPreferences.defaults)}
        Window("Agent Computer",id:DotComputerPanel.windowID){DotComputerPanel().environment(model)}
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
                ChatView(session:assistant,sidebar:AnyView(GolemSidePanel(session:assistant,showsAvatar:false)))
            } else {ProgressView("Opening Golem…")}
        }
        .frame(minWidth:640,minHeight:500)
        .background(ChatWindowReader{model.mainChatWindow=$0})
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
        .task {
            Attention.shared.start(model:model)
            #if DEBUG
            if ProcessInfo.processInfo.environment["GOLEM_TEST_ROLE_CHECK"]=="1"{await GolemCapture.runIfRequested(model);return}
            #endif
            while !RuntimeClient.shared.connected && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(100))}
            if !Task.isCancelled {do{_ = try await RuntimeClient.shared.request("ensureAssistant")}catch{Diagnostics.note(error.localizedDescription)}}
            GolemAvatar.shared.refreshIfStale()
            #if DEBUG
            await GolemCapture.runIfRequested(model)
            #endif
        }
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
            Section("Interface") {Button("Show Mini"){model.showingDot=true}}
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
