@testable import Golem
import AppKit
import SwiftUI

// End to end: a conversation with a fake microphone and a silent Mac voice. Streaming reply →
// speech starts before the turn ends → the ears are open → talking over him doesn't stop him or
// send → your words send on a pause after he finishes → the mic stays warm → minimizing stops all.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)

final class FakeSource: RecognitionSource, @unchecked Sendable {
    var running = false
    var starts = 0, begins = 0
    var handlers: [@Sendable (RecognitionEvent) -> Void] = []
    var isRunning: Bool { running }
    func start() async -> String? { if !running { running = true; starts += 1 }; return nil }
    func begin(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) -> String? { begins += 1; handlers.append(handler); return nil }
    func end() {}
    func stop() { running = false }
    func onEngineStopped(_ handler: @escaping @Sendable (String) -> Void) {}
    func emit(_ event: RecognitionEvent) { handlers.last?(event) }
}

@MainActor func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
@MainActor func waitUntil(_ what: String, _ ms: Int = 3000, _ check: @MainActor () -> Bool) async {
    let until = Date().addingTimeInterval(Double(ms) / 1000)
    while !check() { precondition(Date() < until, "Timed out waiting for \(what)"); await settle(25) }
}

@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns": false, "dotWatchWaiting": false, "dotSummarizeFinished": false, "dotEmailWatch": false,
                                             "companionEnabled": false, "notifyNeeds": false, "notifyFinished": false, "keepMacAwake": false,
                                             GolemMiniWindow.collapsedKey: false, GolemTalk.listensKey: true,
                                             GolemListener.pauseKey: 1.0], forName: UserDefaults.argumentDomain)
    AppPreferences.defaults.set(true, forKey: GolemTalk.readsKey)
    let model = AppModel(), dot = model.ensureDot()
    dot.appendItem(DisplayItem(kind: .assistant, text: "Old reply before launch.", phase: .final))
    model.showingDot = true
    await settle(500)
    let fake = FakeSource()
    let talk = GolemTalk(speaker: GolemSpeaker(), listener: GolemListener(source: fake))
    talk.speaker.macVoiceVolume = 0
    var sent: [String] = []
    talk.send = { _, text, _ in sent.append(text) }
    talk.start(model)
    await settle(200)
    precondition(!talk.speaking, "Read an old reply at start")

    // Conversation button: the mic warms up and listens; the first utterance sends on a pause.
    talk.toggleListening()
    await waitUntil("listening after the Conversation button") { talk.listening }
    precondition(talk.conversationActive && fake.starts == 1 && talk.listener.engineRunning)
    fake.emit(.partial("Hi there.")); await settle(50)
    precondition(dot.draft == "Hi there.", "words didn't reach the box: \(dot.draft)")
    await waitUntil("the first utterance to send", 1500) { sent == ["Hi there."] }
    precondition(dot.draft.isEmpty && talk.listener.engineRunning && fake.starts == 1, "mic didn't stay warm after sending")
    await waitUntil("the next utterance to open") { talk.listening }
    print("PASS conversation: warm mic, words shown, sent after the pause, mic still up")

    // A streaming reply: speech starts before the turn ends, and the ears stay open.
    dot.isRunning = true
    let reply = dot.appendItem(DisplayItem(kind: .assistant, text: "Here is the first sentence. ", phase: .streaming))
    await waitUntil("speech to start while streaming", 2500) { talk.speaking }
    precondition(dot.isRunning && talk.listening && fake.starts == 1, "listening stopped when he started talking")
    print("PASS streaming reply is read before the turn ends, with the ears open")

    // Talking over him doesn't stop him (only stop and mute do): the words are ignored, never
    // typed or sent, since they may be his own voice. Your turn starts once he's done.
    fake.emit(.partial("Stop")); await settle(100)
    precondition(talk.speaking, "talking over him stopped him")
    precondition(dot.draft.isEmpty, "words heard while he talked reached the box: \(dot.draft)")
    dot.updateItem(reply) { $0.text += "And a second one that keeps streaming. "; $0.phase = .final }
    dot.isRunning = false
    await waitUntil("him to finish the whole reply", 10000) { !talk.speaking }
    precondition(sent.count == 1, "words heard while he talked were sent: \(sent)")
    precondition(model.dotMiniWindow?.hiddenSpokenReply == reply, "a fully spoken reply kept its bubble")
    await waitUntil("listening after he finished") { talk.listening }
    fake.emit(.partial("Now my turn.")); await settle(50)
    await waitUntil("your words after his reply to send", 1500) { sent.count == 2 }
    precondition(sent[1] == "Now my turn." && talk.listener.engineRunning && fake.starts == 1)
    print("PASS speech while he talks doesn't stop him or send; your turn starts when he finishes")

    // Nothing said while he talks is fine: the next reply is read to the end, then listening resumes.
    dot.isRunning = true
    let second = dot.appendItem(DisplayItem(kind: .assistant, text: "Okay.", phase: .streaming))
    dot.updateItem(second) { $0.phase = .final }
    dot.isRunning = false
    await waitUntil("the second reply to start", 2500) { talk.speaking }
    await waitUntil("the second reply to finish", 6000) { !talk.speaking }
    await waitUntil("listening after the reply") { talk.listening }
    precondition(talk.conversationActive && fake.starts == 1 && talk.lastSpoken?.engine == "This Mac's voice")
    precondition(model.dotMiniWindow?.hiddenSpokenReply == second, "finished speech didn't hide its reply bubble")
    precondition(!model.dotMiniWindow!.collapsed && talk.listening, "hiding the reply closed the composer or listening")
    await waitUntil("the hidden bubble's space to shrink") {
        guard let mini = model.dotMiniWindow, let panel = mini.panel else { return false }
        return panel.frame.height <= mini.collapsedSize.height + 1
    }
    print("PASS a finished reply hands straight back to listening on the same engine")

    // Speaking while his turn runs sends right away.
    dot.isRunning = true
    fake.emit(.partial("Also check the calendar.")); await settle(50)
    await waitUntil("the mid-turn words to send", 1500) { sent.count == 3 }
    precondition(sent[2] == "Also check the calendar." && dot.isRunning)
    dot.isRunning = false
    print("PASS speech during his turn sends immediately")

    // Mute stops speech but not the ears.
    dot.isRunning = true
    let third = dot.appendItem(DisplayItem(kind: .assistant, text: "A longer reply that would take a while to say out loud. ", phase: .streaming))
    await waitUntil("the third reply to start", 2500) { talk.speaking }
    talk.toggleMute()
    await settle(100)
    precondition(!talk.speaking && talk.muted && talk.listener.engineRunning && talk.conversationActive, "mute changed more than speech")
    talk.toggleMute()
    dot.updateItem(third) { $0.phase = .final }; dot.isRunning = false
    print("PASS mute stops speech and keeps the conversation and ears")
    talk.toggleMute()
    let mutedReply = dot.appendItem(DisplayItem(kind: .assistant, text: "Keep this quiet.", phase: .final))
    await settle(300)
    precondition(!talk.speaking && model.dotMiniWindow?.hiddenSpokenReply != mutedReply,
                 "muted conversation spoke or hid a new reply")
    print("PASS completed audio hides only its bubble; interrupted and muted replies stay available")

    // Minimizing him ends everything.
    model.dotMiniWindow!.setCollapsed(true)
    await waitUntil("everything to stop after minimizing") { !talk.listener.engineRunning && !talk.conversationActive && !talk.listening }
    print("PASS minimizing stops speech, listening and the engine")
    model.dotMiniWindow!.setCollapsed(false)
    await settle(500)
    dot.draft = "Typed prefix"
    talk.toggleListening()
    await waitUntil("manual listen with typed prefix") { talk.listening }
    fake.emit(.partial("and spoken words")); await settle(50)
    precondition(dot.draft == "Typed prefix and spoken words")
    talk.stop()
    await settle(1100)
    precondition(dot.draft == "Typed prefix and spoken words" && sent.count == 3,
                 "ending the session lost or sent unsent words")
    print("PASS typed prefix combines with speech; End retains unsent words without sending")
    dot.draft = ""
    talk.toggleListening()
    await waitUntil("manual listen again") { talk.listening }
    dot.draft = "I am typing"
    fake.emit(.partial("Unexpected speech")); await settle(100)
    precondition(dot.draft == "I am typing" && !talk.conversationActive && !talk.listener.engineRunning && sent.count == 3)
    print("PASS typing preserves the draft and ends listening without sending")
    model.showingDot = false
}
Task { do { try await run(); exit(0) } catch { print(error); exit(1) } }
app.run()
