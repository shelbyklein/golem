import AppKit
import SwiftUI
import Darwin

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func cpuTime() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
@MainActor func baseline() async throws {
    UserDefaults.standard.setVolatileDomain([
        "dotCheckIns": false, "dotWatchWaiting": false, "dotSummarizeFinished": false,
        "dotEmailWatch": false, "companionEnabled": false, "notifyNeeds": false,
        "notifyReplies": false, "keepMacAwake": false, "golemMiniVisible": false,
        "plugin.nextSteps.enabled": false
    ], forName: UserDefaults.argumentDomain)
    let model = AppModel()
    let chats = (0..<3).map { i -> ChatSession in
        var r = ConversationRecord(model: "default", effort: "", personality: .neutral)
        r.title = "Seeded benchmark \(i)"
        r.items = (0..<240).flatMap { j -> [DisplayItem] in
            [DisplayItem(kind: .user, text: "Explain the example \(j)."),
             DisplayItem(kind: .assistant, text: "A reproducible response with **formatting**, a short list and code.\n\n- First item\n- Second item\n\n```swift\nlet value = \(j)\n```", phase: .final)]
        }
        return model.insertSession(r)
    }
    var assistant = ConversationRecord(model: "default", effort: "", personality: .friendly)
    assistant.isDot = true; assistant.title = "Golem"
    _ = model.insertSession(assistant)
    model.selectedID = chats[0].id
    let window = NSWindow(contentRect: NSRect(x: 50,y: 50,width: 1100,height: 780),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
    let host = NSHostingView(rootView: ContentView().environment(model));host.sizingOptions=[]
    window.contentView=host;window.orderFrontRegardless()
    let rigFolder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BASELINE_RIG"]!)
    let mini = NSWindow(contentRect: NSRect(x: 1160,y: 100,width: 180,height: 180),styleMask: [.borderless],backing: .buffered,defer: false)
    guard let rig = GolemRig.load(from: rigFolder) else { fatalError("Fixture rig missing") }
    mini.contentView=NSHostingView(rootView: GolemRigView(rig: rig,mood: "idle"));mini.orderFrontRegardless()
    try await Task.sleep(for: .seconds(3))
    var idle: [[String:Double]]=[]
    for run in 1...3 {
        let start=ProcessInfo.processInfo.systemUptime, cpu=cpuTime()
        try await Task.sleep(for: .seconds(60))
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let pct=(cpuTime()-cpu)/elapsed*100
        idle.append(["run":Double(run),"seconds":elapsed,"cpu_percent":pct])
        print("idle \(run): \(pct)% CPU");fflush(stdout)
    }
    var switches:[Double]=[],stalls:[Double]=[]
    for _ in 0..<8 { for chat in chats {
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
    let result:[String:Any]=["fixture":"seeded-240-pairs-3-chats-live-rig","idle":idle,"switch_ms":switches,"stall_ms":stalls,"median_ms":samples[samples.count/2],"p95_ms":samples[min(samples.count-1,Int(Double(samples.count)*0.95))],"build_revision":ProcessInfo.processInfo.environment["BASELINE_REVISION"]!]
    let data=try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
    try data.write(to: URL(fileURLWithPath:ProcessInfo.processInfo.environment["BASELINE_OUTPUT"]!))
    print("Baseline recorded.")
}
Task { @MainActor in do {try await baseline();exit(0)}catch { print(error);exit(1) } }
app.run()
