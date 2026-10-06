@testable import Golem
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
@MainActor func run() async throws {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    let view = MiniDragRegion.DragView(frame: window.contentView!.bounds)
    window.contentView!.addSubview(view); window.orderFrontRegardless()
    var clicks = 0, opens = 0
    view.onClick = { clicks += 1 }; view.onOpenFull = { opens += 1 }
    func click(_ count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
        }
    }
    click(1); try await Task.sleep(for: .milliseconds(450))
    precondition(clicks == 1 && opens == 0, "single click: \(clicks) \(opens)")
    click(1); click(2); try await Task.sleep(for: .milliseconds(450))
    precondition(clicks == 1 && opens == 1, "double click: \(clicks) \(opens)")
    print("PASS single click toggles once; double-click opens the chat without toggling")
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
