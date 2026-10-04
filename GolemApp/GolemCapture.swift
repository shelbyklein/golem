#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit
import Foundation

@MainActor enum GolemCapture {
    private static var running=false
    static func runIfRequested(_ model:AppModel) async {
        guard RuntimePaths.data.path.hasPrefix("/tmp/golem-"),!running else{return}
        running=true
        if ProcessInfo.processInfo.environment["GOLEM_TEST_ROLE_CHECK"]=="1" {
            do {
                let until=Date().addingTimeInterval(15)
                while !RuntimeClient.shared.connected {guard Date()<until else{throw RuntimeFailure("Signed Golem could not connect")};try await Task.sleep(for:.milliseconds(100))}
                _ = try await RuntimeClient.shared.request("ensureAssistant")
                let forbidden=RuntimeClient();forbidden.start(role:"ui")
                try await Task.sleep(for:.seconds(2))
                guard !forbidden.connected,forbidden.problem=="permission_denied" else{throw RuntimeFailure("Golem acquired Chatterbox UI privileges")}
                forbidden.stop();print("PASS signed Golem connects as golem-ui and cannot request Chatterbox ui role");fflush(stdout)
                NSApp.terminate(nil);return
            }catch{fputs("Signed role check: \(error.localizedDescription)\n",stderr);exit(1)}
        }
        if let output=ProcessInfo.processInfo.environment["GOLEM_TEST_PERFORMANCE"] {
            do{try await performance(model,to:output)}catch{fputs("Golem performance: \(error.localizedDescription)\n",stderr);exit(1)}
            NSApp.terminate(nil);return
        }
        guard let output=ProcessInfo.processInfo.environment["GOLEM_TEST_CAPTURE"] else{return}
        do {
            let until=Date().addingTimeInterval(15)
            while model.dot==nil || model.mainChatWindow==nil {
                guard Date()<until else{throw RuntimeFailure("Golem window did not attach")}
                try await Task.sleep(for:.milliseconds(100))
            }
            try await Task.sleep(for:.seconds(2))
            if #available(macOS 14.4,*) {
                try await capture(model.mainChatWindow!,to:output+"/golem-main.png")
                for width in [640,1100,1600] {
                    model.mainChatWindow?.setContentSize(NSSize(width:width,height:760))
                    try await Task.sleep(for:.milliseconds(300))
                    try await capture(model.mainChatWindow!,to:output+"/golem-main-\(width).png")
                }
                model.showingDot=true
                try await Task.sleep(for:.seconds(1))
                if let mini=model.dotMiniWindow?.panel {
                    try await capture(mini,to:output+"/golem-mini.png")
                }
            }
            model.showingDot=false
            if #available(macOS 14.4,*) {
                let settings=NSWindow(contentRect:NSRect(x:80,y:80,width:620,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                settings.contentView=NSHostingView(rootView:GolemServiceSettings().environment(model).defaultAppStorage(AppPreferences.defaults))
                settings.makeKeyAndOrderFront(nil)
                try await Task.sleep(for:.seconds(2))
                try await capture(settings,to:output+"/golem-mac-settings.png");settings.orderOut(nil)
                let reduced=NSWindow(contentRect:NSRect(x:80,y:80,width:1000,height:760),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                reduced.contentView=NSHostingView(rootView:GolemRoot().environment(model).defaultAppStorage(AppPreferences.defaults).environment(\.golemTestReduceMotion,true))
                reduced.makeKeyAndOrderFront(nil);try await Task.sleep(for:.seconds(1))
                try await capture(reduced,to:output+"/golem-reduced-motion.png");reduced.orderOut(nil)
                let main=NSApp.windows.first{$0.title=="Golem" && $0 !== reduced}
                model.mainChatWindow=main;main?.makeKeyAndOrderFront(nil)
                let control=RuntimeClient();control.start()
                for _ in 0..<100 {if control.connected{break};try await Task.sleep(for:.milliseconds(100))}
                _ = try await control.request("integration",body:["enabled":false])
                try await Task.sleep(for:.seconds(4))
                try await capture(model.mainChatWindow!,to:output+"/golem-disabled.png")
                _ = try await control.request("integration",body:["enabled":true]);control.stop()
                try await Task.sleep(for:.seconds(4))
                RuntimeClient.shared.stop();try await Task.sleep(for:.milliseconds(500))
                try await capture(model.mainChatWindow!,to:output+"/golem-disconnected.png")
            }
            NSApp.terminate(nil)
        }catch{fputs("Golem capture: \(error.localizedDescription)\n",stderr);exit(1)}
    }
    private static func performance(_ model:AppModel,to path:String) async throws {
        let until=Date().addingTimeInterval(15)
        while model.dot==nil || model.mainChatWindow==nil {
            guard Date()<until else{throw RuntimeFailure("Golem window did not attach")}
            try await Task.sleep(for:.milliseconds(100))
        }
        func cpu()->Double {
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
        }
        var samples:[[String:Any]]=[]
        for state in ["visible","hidden"] {
            if state=="visible"{model.showingDot=true;model.mainChatWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
            else{model.dotMiniWindow?.panel?.orderOut(nil);model.mainChatWindow?.orderOut(nil)}
            try await Task.sleep(for:.seconds(2))
            for run in 1...3 {
                if state=="visible"{model.dotMiniWindow?.panel?.orderFrontRegardless()}
                let start=ProcessInfo.processInfo.systemUptime,before=cpu(),draws=GolemRenderMetrics.shared.draws
                try await Task.sleep(for:.seconds(60))
                let elapsed=ProcessInfo.processInfo.systemUptime-start
                let delta=GolemRenderMetrics.shared.draws-draws
                samples.append(["state":state,"run":run,"seconds":elapsed,"cpu_percent":(cpu()-before)/elapsed*100,"render_draws":delta])
                try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
                if state=="visible",delta<30{throw RuntimeFailure("Visible rig was not rendering; performance sample is invalid")}
                if state=="hidden",delta>3{throw RuntimeFailure("Hidden rig continued rendering")}
            }
        }
        model.showingDot=false
    }
    @available(macOS 14.4,*) private static func capture(_ window:NSWindow,to path:String) async throws {
        let target=try await SCShareableContent.currentProcess.windows.first{$0.windowID==CGWindowID(window.windowNumber)}!
        let config=SCStreamConfiguration();config.width=Int(window.frame.width);config.height=Int(window.frame.height);config.ignoreShadowsSingleWindow=true
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:target),configuration:config)
        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
    }
}
#endif
