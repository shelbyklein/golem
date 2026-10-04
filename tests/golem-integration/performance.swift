import AppKit
import SwiftUI
import Darwin

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func cpuTime() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
func processCPU(_ pid:Int32)->Double {
    let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/ps");process.arguments=["-p",String(pid),"-o","time="]
    let output=Pipe();process.standardOutput=output;try? process.run()
    let value=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    process.waitUntilExit()
    let parts=value.split(separator:":").compactMap{Double($0)}
    return parts.reversed().enumerated().reduce(0){$0+$1.element*pow(60,Double($1.offset))}
}
@MainActor func baseline() async throws {
    UserDefaults.standard.setVolatileDomain([
        "dotCheckIns": false, "dotWatchWaiting": false, "dotSummarizeFinished": false,
        "dotEmailWatch": false, "companionEnabled": false, "notifyNeeds": false,
        "notifyReplies": false, "keepMacAwake": false, "golemMiniVisible": false,
        "plugin.nextSteps.enabled": false
    ], forName: UserDefaults.argumentDomain)
    var seed:ConversationRuntime?=try ConversationRuntime()
    let chats = (0..<3).map { i -> ChatSession in
        var r = ConversationRecord(model: "default", effort: "", personality: .neutral)
        r.title = "Seeded benchmark \(i)"
        r.items = (0..<240).flatMap { j -> [DisplayItem] in
            [DisplayItem(kind: .user, text: "Explain the example \(j)."),
             DisplayItem(kind: .assistant, text: "A reproducible response with **formatting**, a short list and code.\n\n- First item\n- Second item\n\n```swift\nlet value = \(j)\n```", phase: .final)]
        }
        return try! seed!.insert(r)
    }
    var assistant = ConversationRecord(model: "default", effort: "", personality: .friendly)
    assistant.isDot = true; assistant.title = "Golem"
    _ = try seed!.insert(assistant)
    seed=nil
    let daemon=Process();daemon.executableURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["PERF_DAEMON"]!);daemon.standardOutput=FileHandle.nullDevice;daemon.standardError=FileHandle.nullDevice;try daemon.run()
    let service=Process();service.executableURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["PERF_SERVICE"]!);service.standardOutput=FileHandle.nullDevice;service.standardError=FileHandle.nullDevice;try service.run()
    defer{service.terminate();daemon.terminate()}
    let model=AppModel()
    while !RuntimeClient.shared.connected || model.sessions.count<3{try await Task.sleep(for:.milliseconds(50))}
    let projected=chats.compactMap{seeded in model.sessions.first{$0.id==seeded.id}}
    for chat in projected {
        model.selectedID=chat.id
        let until=Date().addingTimeInterval(10)
        while chat.items.count<480 {guard Date()<until else{throw RuntimeFailure("Transcript warmup timed out")};try await Task.sleep(for:.milliseconds(20))}
    }
    model.selectedID = chats[0].id
    let window = NSWindow(contentRect: NSRect(x: 50,y: 50,width: 1100,height: 780),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
    let host = NSHostingView(rootView: ContentView().environment(model));host.sizingOptions=[]
    window.contentView=host;window.orderFrontRegardless()
    try await Task.sleep(for: .seconds(3))
    var idle: [[String:Double]]=[]
    for run in 1...3 {
        let start=ProcessInfo.processInfo.systemUptime, cpu=cpuTime(), background=processCPU(daemon.processIdentifier)+processCPU(service.processIdentifier)
        try await Task.sleep(for: .seconds(60))
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let pct=(cpuTime()-cpu)/elapsed*100
        let combined=pct+(processCPU(daemon.processIdentifier)+processCPU(service.processIdentifier)-background)/elapsed*100
        idle.append(["run":Double(run),"seconds":elapsed,"cpu_percent":pct,"combined_cpu_percent":combined])
        print("idle \(run): \(pct)% CPU");fflush(stdout)
    }
    var switches:[Double]=[],stalls:[Double]=[]
    for _ in 0..<8 { for chat in projected {
        let start=ProcessInfo.processInfo.systemUptime
        model.selectedID=chat.id;host.layoutSubtreeIfNeeded();window.displayIfNeeded()
        switches.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        var last=ProcessInfo.processInfo.systemUptime,blocked=0.0
        let until=last+0.5
        while ProcessInfo.processInfo.systemUptime<until {
            try await Task.sleep(for: .milliseconds(2))
            let t=ProcessInfo.processInfo.systemUptime
            if t-last>0.016 { blocked += t-last }
            last=t
        }
        stalls.append(blocked*1000)
    }}
    let samples=Array(switches.dropFirst(3)).sorted()
    let result:[String:Any]=["fixture":"seeded-240-pairs-3-chats-daemon-service-no-rig","idle":idle,"switch_ms":switches,"stall_ms":stalls,"median_ms":samples[samples.count/2],"p95_ms":samples[min(samples.count-1,Int(Double(samples.count)*0.95))],"build_revision":ProcessInfo.processInfo.environment["BASELINE_REVISION"]!]
    let data=try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
    try data.write(to: URL(fileURLWithPath:ProcessInfo.processInfo.environment["BASELINE_OUTPUT"]!))
    print("Baseline recorded.")
}
Task { @MainActor in do {try await baseline();exit(0)}catch { print(error);exit(1) } }
app.run()
