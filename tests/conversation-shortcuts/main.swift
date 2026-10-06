import Foundation
@main struct Checks {
    @MainActor static func main() async throws {
        let bus = GolemConversationRequest.shared
        let start = Task { try await bus.run(start: true) }
        await Task.yield()
        while bus.pending == nil { await Task.yield() }
        let first = bus.pending!
        precondition(first.start)
        bus.finish(first)
        try await start.value
        precondition(bus.pending == nil)
        let end = Task { try await bus.run(start: false) }
        while bus.pending == nil { await Task.yield() }
        precondition(!bus.pending!.start)
        bus.finish(bus.pending!, error: "Test error")
        do { try await end.value; fatalError("Expected surfaced error") } catch { precondition(error.localizedDescription == "Test error") }
        let cancelled = Task { try await bus.run(start: true) }
        while bus.pending == nil { await Task.yield() }
        var stopped = false
        bus.cancelPending = { stopped = true }
        cancelled.cancel()
        do { try await cancelled.value; fatalError("Expected cancellation") } catch {}
        precondition(bus.pending == nil && stopped)
        print("Start/end dispatch, error propagation, cancellation cleanup passed; no microphone or speech calls.")
    }
}
