@testable import Golem
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)

func now() -> Double { ProcessInfo.processInfo.systemUptime }

/// 0.05 s of 16-bit mono silence at 22.05 kHz, as a WAV file in memory.
func tinyWAV() -> Data {
    let rate: UInt32 = 22050, samples = 1102, bytes = UInt32(samples * 2)
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes); d.append(Data(count: Int(bytes)))
    return d
}

struct StubFailure: LocalizedError { var errorDescription: String? { "stub failure." } }

/// Records every request (text, time), how many ran at once, and answers after a delay.
final class StubProvider: SpeechProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(text: String, at: Double)] = []
    private var running = 0, peak = 0
    var delay: @Sendable (Int) -> Double = { _ in 0.1 }
    var failIndex: Int?
    let wav = tinyWAV()
    var requests: [(text: String, at: Double)] { lock.withLock { log } }
    var maxInFlight: Int { lock.withLock { peak } }
    func speech(for text: String) async throws -> Data {
        let n = lock.withLock { () -> Int in
            log.append((text, now())); running += 1; peak = max(peak, running); return log.count - 1
        }
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(for: .seconds(delay(n)))
        if n == failIndex { throw StubFailure() }
        return wav
    }
}

@MainActor func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = now() + seconds
    while now() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return condition()
}

@MainActor final class Events {
    var played: [(index: Int, engine: String)] = []
    var finished = 0
}

@MainActor func makeSpeaker(_ provider: StubProvider?) -> (GolemSpeaker, Events) {
    let speaker = GolemSpeaker(), events = Events()
    speaker.provider = provider
    speaker.macVoiceVolume = 0
    speaker.onSegment = { events.played.append(($0, $1)) }
    speaker.onFinished = { events.finished += 1 }
    return (speaker, events)
}

@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["dotCheckIns":false,"dotWatchWaiting":false,"dotSummarizeFinished":false,"dotEmailWatch":false,"companionEnabled":false,"notifyNeeds":false,"notifyFinished":false,"keepMacAwake":false,GolemMiniWindow.collapsedKey:false,"golemTalkListens":false],forName:UserDefaults.argumentDomain)

    // 5. Cleaning.
    precondition(GolemSpeaker.spoken("**Done** — see https://example.com/x and `code`.") == "Done — see a link and code.", GolemSpeaker.spoken("**Done** — see https://example.com/x and `code`."))
    let long = String(repeating: "x", count: 5000)
    precondition(GolemSpeaker.spoken(long).hasSuffix("… The rest is on screen."), "length cap")
    print("PASS spoken(_:) cleans markdown and links, caps length")

    // Segmentation rules.
    func cut(_ s: String, final: Bool = false) -> [String] { GolemSpeaker.cut(Array(s), final: final).pieces.map { $0.trimmingCharacters(in: .whitespaces) } }
    precondition(cut("One. Two! Three? Four") == ["One.", "Two!", "Three?"], "\(cut("One. Two! Three? Four"))")
    precondition(cut("One. Two! Three? Four", final: true) == ["One.", "Two!", "Three?", "Four"], "final flushes the tail")
    precondition(cut("Dr. Smith left. 3.5 is fine. ") == ["Dr. Smith left.", "3.5 is fine."], "\(cut("Dr. Smith left. 3.5 is fine. "))")
    precondition(cut("1. First item\n2. Second item\n\nNext") == ["1. First item\n2. Second item"], "list numbers and paragraph break: \(cut("1. First item\n2. Second item\n\nNext"))")
    precondition(cut("He said \"go.\" Then went. ") == ["He said \"go.\"", "Then went."], "closing quote: \(cut("He said \"go.\" Then went. "))")
    precondition(cut("Wait... what? ok") == ["Wait...", "what?"], "ellipsis: \(cut("Wait... what? ok"))")
    precondition(cut("No end yet.") .isEmpty, "a sentence with nothing after its period isn't complete yet")
    let clause = String(repeating: "this clause runs on, ", count: 40)   // 840 chars, commas only
    let pieces = GolemSpeaker.cut(Array(clause + "end."), final: true).pieces
    precondition(pieces.count >= 2 && pieces.allSatisfy { $0.count <= 600 } && pieces.joined() == clause + "end.", "long sentence cut at commas: \(pieces.map(\.count))")
    let unfinished = GolemSpeaker.cut(Array(clause), final: false)   // still streaming: speak up to a comma, hold the rest
    precondition(!unfinished.pieces.isEmpty && unfinished.pieces.allSatisfy { $0.count <= 600 } && unfinished.used < clause.count && unfinished.used > 0, "unfinished long sentence: \(unfinished.pieces.map(\.count)) used \(unfinished.used)")
    precondition(GolemSpeaker.merge(["a.", "b."]) == ["a. b."] && GolemSpeaker.merge([String(repeating: "a", count: 200), String(repeating: "b", count: 100)]).count == 2, "merge")
    print("PASS segmentation: sentences, abbreviations, list numbers, quotes, ellipsis, paragraphs, long runs, merge")

    // 1. Streaming: five increments over about a second, then final.
    do {
        let stub = StubProvider()
        stub.delay = { $0 == 0 ? 0.4 : 0.3 }   // the first answer is the slowest: order must still hold
        let (speaker, events) = makeSpeaker(stub)
        let id = UUID()
        let steps = ["Hello there, this is the first sentence. ",
                     "Here comes the second one! And a third",
                     "? Finally a fourth sentence ends here.",
                     " Then one more",
                     " thing"]
        var text = "", firstPunct = 0.0
        for (n, step) in steps.enumerated() {
            text += step
            if n == 0 { firstPunct = now() }
            speaker.update(reply: id, text: text, final: false)
            try await Task.sleep(for: .milliseconds(200))
        }
        precondition(events.finished == 0, "finished before the turn ended")
        speaker.update(reply: id, text: text, final: true)
        let ok1 = await until(10) { events.finished == 1 }; precondition(ok1, "never finished; played \(events.played), requests \(stub.requests.map(\.text))")
        let expected = ["Hello there, this is the first sentence.", "Here comes the second one!", "And a third?",
                        "Finally a fourth sentence ends here.", "Then one more thing"]
        precondition(stub.requests.map(\.text) == expected, "segments: \(stub.requests.map(\.text))")
        let latency = stub.requests[0].at - firstPunct
        precondition(latency <= 0.2, "first request \(Int(latency * 1000)) ms after the first sentence")
        precondition(events.played.map(\.index) == [0, 1, 2, 3, 4], "playback order \(events.played)")
        precondition(events.played.allSatisfy { $0.engine == "ElevenLabs (streamed)" }, "engines \(events.played)")
        precondition(stub.maxInFlight <= 2, "\(stub.maxInFlight) fetches at once")
        precondition(stub.maxInFlight == 2, "never prefetched the next segment (peak \(stub.maxInFlight))")
        precondition(speaker.lastSpoken?.engine == "ElevenLabs (streamed)" && speaker.problem == nil && !speaker.speaking, "state after finish")
        try await Task.sleep(for: .milliseconds(300))
        precondition(events.finished == 1, "finished more than once")
        speaker.update(reply: id, text: text + " More.", final: true)
        try await Task.sleep(for: .milliseconds(200))
        precondition(stub.requests.count == 5, "finished reply spoke again")
        print("PASS streams in order: first request \(Int(latency * 1000)) ms after the first sentence, 5 segments, peak \(stub.maxInFlight) in flight, one finish")
    }

    // 2. stop() mid-way.
    do {
        let stub = StubProvider(); stub.delay = { _ in 0.4 }
        let (speaker, events) = makeSpeaker(stub)
        let id = UUID()
        speaker.update(reply: id, text: "First sentence here. Second one follows. ", final: false)
        speaker.update(reply: id, text: "First sentence here. Second one follows. Third arrives. ", final: false)
        let ok2 = await until(1) { stub.requests.count >= 1 }; precondition(ok2, "no request")
        speaker.stop()
        let before = stub.requests.count
        precondition(!speaker.speaking, "speaking after stop")
        speaker.update(reply: id, text: "First sentence here. Second one follows. Third arrives. Fourth too. ", final: true)
        try await Task.sleep(for: .milliseconds(900))
        precondition(stub.requests.count == before, "requests after stop: \(before) -> \(stub.requests.count)")
        precondition(events.finished == 0 && events.played.isEmpty && !speaker.speaking, "played or finished after stop")
        // A new reply id starts fresh.
        speaker.update(reply: UUID(), text: "Fresh start.", final: true)
        let ok3 = await until(5) { events.finished == 1 }; precondition(ok3, "new reply after stop never finished")
        precondition(stub.requests.last?.text == "Fresh start.", "new reply text")
        print("PASS stop() cancels the queue: no requests, no onFinished; same id ignored; a new id speaks")
    }

    // 3. Final text without punctuation speaks once.
    do {
        let stub = StubProvider()
        let (speaker, events) = makeSpeaker(stub)
        speaker.speak(reply: UUID(), text: "Hello there")
        let ok4 = await until(5) { events.finished == 1 }; precondition(ok4, "never finished")
        precondition(stub.requests.map(\.text) == ["Hello there"], "\(stub.requests.map(\.text))")
        try await Task.sleep(for: .milliseconds(300))
        precondition(stub.requests.count == 1 && events.finished == 1 && events.played.count == 1, "spoke more than once")
        print("PASS final text without punctuation is spoken exactly once")
    }

    // 4. Provider fails on segment 2: the Mac's voice reads 2..n.
    do {
        let stub = StubProvider(); stub.delay = { _ in 0.05 }; stub.failIndex = 1
        let (speaker, events) = makeSpeaker(stub)
        let id = UUID()
        var text = ""
        for sentence in ["Yes. ", "No. ", "Ok. "] {
            text += sentence
            speaker.update(reply: id, text: text, final: false)
            try await Task.sleep(for: .milliseconds(120))
        }
        speaker.update(reply: id, text: text, final: true)
        let ok5 = await until(15) { events.finished == 1 }; precondition(ok5, "never finished; played \(events.played), problem \(speaker.problem ?? "nil")")
        precondition(events.played.map(\.index) == [0, 1, 2], "order \(events.played)")
        precondition(events.played[0].engine == "ElevenLabs (streamed)" && events.played[1].engine == "This Mac's voice" && events.played[2].engine == "This Mac's voice", "engines \(events.played)")
        precondition(speaker.lastSpoken?.engine == "This Mac's voice", "lastSpoken \(String(describing: speaker.lastSpoken))")
        precondition(speaker.problem?.hasPrefix("ElevenLabs:") == true && speaker.problem?.hasSuffix("Using the Mac's voice.") == true, "problem \(speaker.problem ?? "nil")")
        print("PASS provider failure on segment 2 falls back to the Mac's voice for 2..n; problem: \(speaker.problem ?? "")")
    }

    // 6. Without a provider the Mac's voice reads per segment.
    do {
        let (speaker, events) = makeSpeaker(nil)
        let id = UUID()
        speaker.update(reply: id, text: "Yes. ", final: false)
        speaker.update(reply: id, text: "Yes. No. ", final: false)
        speaker.update(reply: id, text: "Yes. No. Ok", final: true)
        let ok6 = await until(15) { events.finished == 1 }; precondition(ok6, "never finished; played \(events.played)")
        precondition(events.played.map(\.index) == [0, 1, 2] && events.played.allSatisfy { $0.engine == "This Mac's voice" }, "\(events.played)")
        precondition(speaker.lastSpoken?.engine == "This Mac's voice" && speaker.problem == nil, "state")
        print("PASS Mac voice only: three segments in order, one finish")
    }

    // 7. Text that stops matching what was consumed continues from the common prefix.
    do {
        let stub = StubProvider(); stub.delay = { _ in 0.05 }
        let (speaker, events) = makeSpeaker(stub)
        let id = UUID()
        speaker.update(reply: id, text: "Alpha one. ", final: false)
        speaker.update(reply: id, text: "Alpha one. Beta two. ", final: false)
        speaker.update(reply: id, text: "Alpha one. Gamma three.", final: true)
        let ok7 = await until(10) { events.finished == 1 }; precondition(ok7, "never finished")
        precondition(stub.requests.map(\.text) == ["Alpha one.", "Beta two.", "Gamma three."], "\(stub.requests.map(\.text))")
        print("PASS revised text continues from the common prefix without re-speaking")
    }

    // 8. The length cap applies to the whole reply.
    do {
        let stub = StubProvider(); stub.delay = { _ in 0.01 }
        let (speaker, events) = makeSpeaker(stub)
        let id = UUID(), sentence = String(repeating: "word ", count: 50) + "end. "   // ~255 chars
        var text = ""
        for _ in 0..<20 { text += sentence; speaker.update(reply: id, text: text, final: false) }
        speaker.update(reply: id, text: text, final: true)
        let ok8 = await until(15) { events.finished == 1 }; precondition(ok8, "never finished")
        let total = stub.requests.map(\.text.count).reduce(0, +)
        precondition(stub.requests.last!.text.hasSuffix("… The rest is on screen.") && total <= GolemSpeaker.spokenLimit + 30, "cap: \(total) chars in \(stub.requests.count) requests")
        print("PASS length cap holds across segments (\(total) characters in \(stub.requests.count) requests)")
    }
}
Task {do {try await run();exit(0)} catch {print(error);exit(1)}}
app.run()
