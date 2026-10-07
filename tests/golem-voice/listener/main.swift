@testable import Golem
import AppKit
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)

/// A recognition source the fixture drives: no microphone, no recognizer.
final class FakeSource: RecognitionSource, @unchecked Sendable {
    var running = false
    var starts = 0, begins = 0, ends = 0, stops = 0
    var handlers: [@Sendable (RecognitionEvent) -> Void] = []
    var stopped: (@Sendable (String) -> Void)?
    var meter: (@Sendable (Float) -> Void)?
    func onInputLevel(_ handler: @escaping @Sendable (Float) -> Void) { meter = handler }
    var isRunning: Bool { running }
    func start() async -> String? { if !running { running = true; starts += 1 }; return nil }
    func begin(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) -> String? { begins += 1; handlers.append(handler); return nil }
    func end() { ends += 1 }
    func stop() { stops += 1; running = false }
    func onEngineStopped(_ handler: @escaping @Sendable (String) -> Void) { stopped = handler }
    /// An event on the newest request.
    func emit(_ event: RecognitionEvent) { handlers.last?(event) }
}

@MainActor func settle(_ ms: Int = 40) async { try? await Task.sleep(for: .milliseconds(ms)) }
@MainActor func elapsed(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

@MainActor func run() async throws {
    let defaults = AppPreferences.defaults
    defaults.removeObject(forKey: GolemListener.pauseKey)

    // MARK: pause setting
    let fake = FakeSource()
    let listener = GolemListener(source: fake)
    precondition(GolemListener.pauseKey == "golemTalkPause" && GolemListener.defaultPause == 1.0 && GolemListener.pauseRange == 0.5...3.0)
    precondition(listener.pause == 1.0, "default pause is \(listener.pause)")
    listener.pause = 2.2
    precondition(defaults.double(forKey: GolemListener.pauseKey) == 2.2, "pause wasn't saved")
    precondition(GolemListener(source: FakeSource()).pause == 2.2, "a new listener didn't read the saved pause")
    listener.pause = 9; precondition(listener.pause == 3.0, "upper clamp: \(listener.pause)")
    listener.pause = 0.1; precondition(listener.pause == 0.5, "lower clamp: \(listener.pause)")
    precondition(defaults.double(forKey: GolemListener.pauseKey) == 0.5, "clamped value wasn't what got saved")
    print("PASS pause defaults to 1.0, persists under golemTalkPause, clamps to 0.5...3.0")
    _ = NSHostingView(rootView: GolemListenerSettings()).fittingSize
    print("PASS GolemListenerSettings builds")

    // MARK: effective pause
    precondition(GolemListener.effectivePause(1.5, after: "Hello there.") == 0.7)
    precondition(GolemListener.effectivePause(1.5, after: "Really? ") == 0.7)
    precondition(GolemListener.effectivePause(1.5, after: "Stop!") == 0.7)
    precondition(GolemListener.effectivePause(1.5, after: "Hello there,") == 1.5)
    precondition(GolemListener.effectivePause(1.5, after: "Hello there") == 1.5)
    precondition(GolemListener.effectivePause(0.5, after: "Hello there.") == 0.5, "a short pause must not be lengthened")
    print("PASS terminal . ? ! shorten the pause to at most 0.7, nothing else does")

    // MARK: warm engine, two utterances, barge-in, shortening (measured)
    listener.pause = 1.5
    listener.giveUp = 5
    var events: [String] = [], detected = 0, utterances: [String] = [], transcripts: [String] = [], failures: [String] = []
    listener.onSpeechDetected = { detected += 1 }
    listener.onUtterance = { utterances.append($0) }
    listener.onTranscript = { transcripts.append($0) }
    listener.onFailure = { failures.append($0) }
    let warm1 = await listener.warmUp(), warm2 = await listener.warmUp()
    precondition(warm1 && warm2 && listener.engineRunning, "warmUp isn't idempotent")
    async let second = listener.warmUp()
    async let third = listener.warmUp()
    let both = await (second, third)
    precondition(both.0 && both.1)
    precondition(fake.starts == 1, "engine started \(fake.starts) times")
    events.append("started")

    // Utterance 1: no punctuation, so the full pause applies.
    listener.beginUtterance()
    precondition(listener.listening && fake.begins == 1)
    fake.meter?(0); await settle()
    precondition(listener.inputStatus.contains("No microphone sound") && listener.heard.isEmpty)
    fake.meter?(0.2); await settle()
    precondition(listener.inputStatus.contains("Hearing audio") && listener.heard.isEmpty)
    print("PASS microphone signal feedback distinguishes silence from audio without inventing recognized words")
    fake.emit(.partial("")); await settle()
    precondition(detected == 0 && transcripts.isEmpty, "empty partial counted as speech")
    fake.emit(.partial("I")); await settle()
    precondition(detected == 0, "a one-letter word fired barge-in")
    fake.emit(.partial("I am")); await settle()
    precondition(detected == 1, "first qualifying word didn't fire barge-in (\(detected))")
    fake.meter?(0); await settle()
    precondition(listener.inputStatus == "Hearing you — pause to send")
    print("PASS recognized words take priority over microphone metering")
    fake.emit(.partial("I am here")); await settle()
    let spoke1 = Date()
    fake.emit(.partial("I am here now")); await settle()
    precondition(detected == 1, "barge-in fired \(detected) times in one utterance")
    precondition(listener.heard == "I am here now" && transcripts.last == "I am here now")
    while utterances.isEmpty && elapsed(since: spoke1) < 4 { await settle(20) }
    let wait1 = elapsed(since: spoke1)
    precondition(utterances == ["I am here now"], "utterance 1: \(utterances)")
    precondition(wait1 >= 1.5 && wait1 < 2.1, "no-punctuation pause was \(wait1) s")
    precondition(listener.engineRunning && fake.running && !listener.listening && fake.ends >= 1 && fake.stops == 0)

    // Utterance 2 on the same engine: a finished sentence sends sooner.
    listener.beginUtterance()
    precondition(listener.listening && fake.begins == 2 && listener.heard == "")
    let spoke2 = Date()
    fake.emit(.partial("Hello there.")); await settle()
    precondition(detected == 2, "barge-in fired \(detected) in total; wanted once per utterance")
    while utterances.count < 2 && elapsed(since: spoke2) < 4 { await settle(20) }
    let wait2 = elapsed(since: spoke2)
    precondition(utterances == ["I am here now", "Hello there."], "utterances: \(utterances)")
    precondition(wait2 >= 0.7 && wait2 < 1.2, "sentence-end pause was \(wait2) s")
    precondition(wait2 < wait1 - 0.5, "a finished sentence didn't shorten the pause (\(wait2) vs \(wait1))")
    precondition(listener.engineRunning && fake.starts == 1 && fake.stops == 0 && failures.isEmpty)
    print("PASS two utterances on one engine (starts=\(fake.starts), engineRunning throughout); pause \(String(format: "%.2f", wait1)) s without punctuation, \(String(format: "%.2f", wait2)) s after a sentence")
    print("PASS onSpeechDetected fired exactly once per utterance, at the first word of two letters")

    // Stale events from an ended request are ignored.
    fake.handlers[1](.partial("ghost words")); await settle()
    precondition(listener.heard == "Hello there." && utterances.count == 2 && !listener.listening)

    // MARK: a final result ends the utterance at once
    listener.beginUtterance()
    fake.emit(.final("Final words.")); await settle()
    precondition(utterances.last == "Final words." && !listener.listening && listener.engineRunning)
    print("PASS a final recognition result ends the utterance immediately")

    // MARK: barge-in minimum words
    listener.bargeInMinimumWords = 2
    detected = 0
    listener.beginUtterance()
    fake.emit(.partial("Wait")); await settle()
    precondition(detected == 0, "fired at one word with minimum 2")
    fake.emit(.partial("Wait stop")); await settle()
    precondition(detected == 1)
    listener.cancelUtterance()
    listener.bargeInMinimumWords = 1
    print("PASS bargeInMinimumWords gates the hook")

    // MARK: cancel drops words, keeps the engine
    let before = utterances.count
    listener.pause = 0.5
    listener.beginUtterance()
    fake.emit(.partial("Never mind this")); await settle()
    precondition(listener.heard == "Never mind this")
    let ends = fake.ends
    listener.cancelUtterance()
    precondition(listener.heard == "" && !listener.listening && listener.engineRunning && fake.running && fake.stops == 0 && fake.ends == ends + 1)
    fake.emit(.partial("late words")); fake.emit(.final("late words")); await settle(900)
    precondition(listener.heard == "" && utterances.count == before, "cancelled words were reported: \(utterances)")
    listener.beginUtterance()
    precondition(listener.listening && fake.starts == 1)
    fake.emit(.partial("After cancel")); await settle()
    precondition(listener.heard == "After cancel")
    listener.cancelUtterance()
    print("PASS cancelUtterance drops the words, reports nothing, keeps the engine running")

    // MARK: give up with no words
    listener.giveUp = 0.5
    let quiet = Date()
    let count = utterances.count
    listener.beginUtterance()
    while utterances.count == count && elapsed(since: quiet) < 3 { await settle(20) }
    let gave = elapsed(since: quiet)
    precondition(utterances.last == "" && utterances.count == count + 1, "giveUp: \(utterances)")
    precondition(gave >= 0.5 && gave < 0.9, "gave up after \(gave) s")
    precondition(listener.engineRunning && !listener.listening)
    print("PASS silence for giveUp reports \"\" after \(String(format: "%.2f", gave)) s, engine still running")

    // MARK: rotating a request that stays empty
    listener.giveUp = 3
    listener.rotateAfter = 0.3
    let begins = fake.begins, rotCount = utterances.count
    listener.beginUtterance()
    await settle(1000)
    precondition(listener.listening && fake.begins >= begins + 3, "begins \(fake.begins - begins) in 1 s with rotation 0.3 s")
    precondition(fake.starts == 1 && fake.stops == 0 && utterances.count == rotCount)
    fake.handlers[begins](.partial("ghost")); await settle()
    precondition(listener.heard == "", "a replaced request's words were accepted")
    fake.emit(.partial("Still here")); await settle()
    precondition(listener.heard == "Still here" && detected >= 1)
    listener.cancelUtterance()
    listener.rotateAfter = 50
    print("PASS an empty request is replaced after rotateAfter without restarting the engine or ending the utterance (\(fake.begins - begins) requests in 1 s)")

    // MARK: failures keep today's messages
    listener.beginUtterance()
    fake.emit(.failure(domain: "kLSRErrorDomain", code: 201, description: "x")); await settle()
    precondition(failures.last == "Dictation is disabled on this Mac. Turn on System Settings → Keyboard → Dictation, then try Conversation again.", "\(failures)")
    precondition(!listener.listening && !listener.engineRunning && listener.problem == failures.last)
    let again = await listener.warmUp()
    precondition(again && fake.starts == 2, "couldn't warm up again after a failure")
    listener.beginUtterance()
    fake.emit(.failure(domain: "kAFAssistantErrorDomain", code: 1110, description: "No speech detected")); await settle()
    precondition(failures.last == "Listening stopped: No speech detected. Try Conversation again.", "\(failures.last ?? "nil")")
    precondition(failures.count == 2)
    print("PASS recognition failures report today's messages through onFailure")

    // MARK: engine lost, stop
    let warm3 = await listener.warmUp()
    precondition(warm3)
    fake.stopped?("Listening stopped: the microphone changed. Try Conversation again.")
    await settle()
    precondition(!listener.engineRunning && failures.last == "Listening stopped: the microphone changed. Try Conversation again.")
    let warm4 = await listener.warmUp()
    precondition(warm4 && listener.engineRunning)
    listener.beginUtterance(); fake.emit(.partial("some words")); await settle()
    listener.stop()
    precondition(!listener.engineRunning && !listener.listening && !fake.running)
    listener.beginUtterance()
    precondition(!listener.listening, "began an utterance with the engine down")
    print("PASS an engine that stops itself is reported; stop() tears everything down")

    // MARK: out-of-range stored values are clamped on read
    defaults.removeObject(forKey: GolemListener.pauseKey)
    UserDefaults.standard.setVolatileDomain([GolemListener.pauseKey: 10.0], forName: UserDefaults.argumentDomain)
    precondition(GolemListener(source: FakeSource()).pause == 3.0, "stored 10 wasn't clamped")
    UserDefaults.standard.setVolatileDomain([GolemListener.pauseKey: 0.0], forName: UserDefaults.argumentDomain)
    precondition(GolemListener(source: FakeSource()).pause == 0.5, "stored 0 wasn't clamped")
    UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    defaults.removeObject(forKey: GolemListener.pauseKey)
    precondition(GolemListener(source: FakeSource()).pause == 1.0)
    print("PASS stored pauses outside 0.5...3.0 are clamped when read")
    _ = events
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
