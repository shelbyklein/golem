import SwiftUI

@main struct GolemMobileApp:App {
    @UIApplicationDelegateAdaptor(MobilePushAppDelegate.self) private var delegate
    @State private var store=MobileStore()
    var body:some Scene {
        WindowGroup {
            Group {
                if store.isPaired {GolemMobileRoot()}
                else {ConnectView()}
            }.environment(store).defaultAppStorage(AppPreferences.defaults).environment(\.readerStyle,.mobile)
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
    private enum Destination:String,CaseIterable,Identifiable {
        case golem="Golem",journal="Journal",settings="Settings"
        var id:String{rawValue}
        var icon:String{switch self{case .golem:return "sparkles";case .journal:return "book";case .settings:return "gearshape"}}
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
                case .settings:settingsView
                }
            }
        } else {
        TabView {
            GolemHome().tabItem{Label("Golem",systemImage:"sparkles")}
            GolemJournalMobile().tabItem{Label("Journal",systemImage:"book")}
            settingsView.tabItem{Label("Settings",systemImage:"gearshape")}
        }
        }
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
                    Section("Connection"){
                        Text(store.connection?.macName ?? "Mac")
                        if let problem=store.problem{Text(problem).foregroundStyle(.orange)}
                        Button("Disconnect Golem",role:.destructive){store.forget()}
                    }
                    MobileNotificationControls()
                    GolemVoiceSettings()
                    Section("Automation on your Mac") {
                        ForEach(["dotCheckIns","dotWatchWaiting","dotSummarizeFinished","dotEmailWatch"],id:\.self){key in
                            Toggle(policyLabel(key),isOn:Binding(get:{policies[key] ?? true},set:{value in policies[key]=value;control("settings",[key:value])}))
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
        switch key{case "dotCheckIns":return "Weekday check-ins";case "dotWatchWaiting":return "Brief me when a chat needs me";case "dotSummarizeFinished":return "Summarize finished work";default:return "Watch email"}
    }
}
struct GolemJournalMobile:View {
    struct Entry:Codable,Identifiable {var id:UUID;var date:Date;var kind:String;var title:String;var detail:String?;var chat:UUID?}
    @Environment(MobileStore.self) private var store
    @State private var entries:[Entry]=[]
    @State private var problem:String?
    @State private var missingChatterbox=false
    @Environment(\.openURL) private var openURL
    var body:some View {
        NavigationStack {
            List {
                if let problem{Text(problem).foregroundStyle(.orange)}
                ForEach(entries.reversed()){entry in
                    VStack(alignment:.leading,spacing:6){
                        Text(entry.title).font(.headline)
                        if let detail=entry.detail{Text(detail)}
                        Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                        if let chat=entry.chat {
                            Button("Open in Chatterbox") {
                                openURL(URL(string:"chatterbox://chat/\(chat)")!) { accepted in
                                    if !accepted { missingChatterbox=true }
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("Journal").refreshable{await refresh()}.task{await refresh()}
                .alert("Chatterbox unavailable",isPresented:$missingChatterbox) {
                    Button("OK",role:.cancel) {}
                } message: { Text("Install Chatterbox and pair it with this Mac to open the original chat. Your briefing remains available here.") }
        }
    }
    private func refresh() async {
        do{entries=try Companion.decoder.decode([Entry].self,from:await store.golemJournal());problem=nil}
        catch{problem=error.localizedDescription}
    }
}
