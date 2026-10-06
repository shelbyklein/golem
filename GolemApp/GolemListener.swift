import AVFoundation
import OSLog
import Speech
import SwiftUI

// MARK: - Recognition source

/// What the listener hears from the recognizer for the request that is currently open.
enum RecognitionEvent: Sendable {
    case partial(String)
    case final(String)
    case failure(domain: String, code: Int, description: String)
}

/// The microphone engine and speech recognizer behind `GolemListener`. The production source keeps one audio
/// engine running and opens a recognition request per utterance; a fixture drives the same listener logic
/// with a fake. Handlers may be called on any thread.
protocol RecognitionSource: AnyObject, Sendable {
    /// The audio engine is running.
    var isRunning: Bool { get }
    /// Permissions, then the one engine. Idempotent. Returns a user-facing problem, or nil when it's running.
    func start() async -> String?
    /// Opens a recognition request on the running engine. Returns a user-facing problem, or nil.
    func begin(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) -> String?
    /// Ends the open request; the engine keeps running.
    func end()
    /// Everything down.
    func stop()
    /// Called with a user-facing message if the engine stops by itself and can't be restarted.
    func onEngineStopped(_ handler: @escaping @Sendable (String) -> Void)
}

/// Hands the tap's buffers to whichever request is current.
private final class AudioRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let old = request
        request = new
        return old
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = request; lock.unlock()
        current?.append(buffer)
    }
}

/// The real thing: `AVAudioEngine` with one tap, and `SFSpeechRecognizer` requests on top of it.
final class SpeechRecognitionSource: RecognitionSource, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")
    static let noInput = "No microphone input is available. Choose an input in System Settings → Sound."

    private let lock = NSLock()
    private let recognizer = SFSpeechRecognizer()
    private let box = AudioRequestBox()
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var observer: NSObjectProtocol?
    private var stopped: (@Sendable (String) -> Void)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return engine?.isRunning == true }

    func onEngineStopped(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock(); stopped = handler; lock.unlock()
    }

    func start() async -> String? {
        if isRunning { return nil }
        guard await Self.permitted() else {
            return "Golem needs the microphone and speech recognition to hear you. Allow them in System Settings → Privacy & Security."
        }
        guard let recognizer, recognizer.isAvailable else { return "Speech recognition isn't available right now." }
        if isRunning { return nil }
        var failure = Self.noInput
        // Voice processing (echo cancellation) lets Golem hear you over his own voice; when this Mac's input
        // refuses it, listen without it.
        for voiceProcessing in [true, false] {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if voiceProcessing {
                do { try input.setVoiceProcessingEnabled(true) } catch {
                    Self.log.notice("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else { failure = Self.noInput; continue }
            let box = self.box
            // A Bluetooth input can change sample rate when its microphone activates; nil lets the engine negotiate.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in box.append(buffer) }
            engine.prepare()
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                failure = "Couldn't start listening: \(error.localizedDescription)"
                Self.log.error("Engine start failed (voice processing \(voiceProcessing))")
                continue
            }
            Self.log.notice("Voice processing \(voiceProcessing ? "on" : "off")")
            let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.configurationChanged()
            }
            install(engine, observer: token)
            return nil
        }
        return failure
    }

    private func install(_ engine: AVAudioEngine, observer token: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        self.engine = engine; observer = token
    }

    func begin(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) -> String? {
        guard isRunning, let recognizer else { return "Listening isn't ready. Try Conversation again." }
        end()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        _ = box.set(request)
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                handler(result.isFinal ? .final(text) : .partial(text))
            }
            if let error {
                let failure = error as NSError
                handler(.failure(domain: failure.domain, code: failure.code, description: failure.localizedDescription))
            }
        }
        lock.lock(); self.task = task; lock.unlock()
        return nil
    }

    func end() {
        let old = box.set(nil)
        lock.lock(); let task = self.task; self.task = nil; lock.unlock()
        old?.endAudio()
        task?.cancel()
    }

    func stop() {
        end()
        lock.lock()
        let engine = self.engine, token = observer
        self.engine = nil; observer = nil
        lock.unlock()
        if let token { NotificationCenter.default.removeObserver(token) }
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// The route changed (a Bluetooth microphone woke, headphones came out): the engine stops itself, so restart it.
    private func configurationChanged() {
        lock.lock(); let engine = self.engine; let handler = stopped; lock.unlock()
        guard let engine, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            Self.log.notice("Microphone restarted after a configuration change")
        } catch {
            Self.log.error("Microphone could not restart after a configuration change")
            stop()
            handler?("Listening stopped: the microphone changed. Try Conversation again.")
        }
    }

    private static func permitted() async -> Bool {
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: - Listener

/// Golem's ears. One audio engine stays up for a whole conversation (`warmUp()`); each utterance opens a
/// recognition request on it (`beginUtterance()`), reports the words as they come, notices the first word
/// (the barge-in hook) and ends once you pause.
@MainActor @Observable final class GolemListener: NSObject {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")

    static let pauseKey = "golemTalkPause"
    static let pauseRange = 0.5...3.0
    static let defaultPause = 1.0
    /// After a finished sentence (. ? !) the pause is cut to at most this.
    static let sentencePause: TimeInterval = 0.7

    /// After you stop talking, how long a pause ends the utterance. Saved in the app's preferences.
    @ObservationIgnored var pause: TimeInterval {
        get {
            let stored = AppPreferences.defaults.object(forKey: Self.pauseKey) as? Double
            return min(max(stored ?? Self.defaultPause, Self.pauseRange.lowerBound), Self.pauseRange.upperBound)
        }
        set {
            guard newValue.isFinite else { return }
            AppPreferences.defaults.set(min(max(newValue, Self.pauseRange.lowerBound), Self.pauseRange.upperBound), forKey: Self.pauseKey)
        }
    }
    /// How long silence with no words at all ends the utterance (empty).
    @ObservationIgnored var giveUp: TimeInterval = 8
    /// How many words of two letters or more count as speech for `onSpeechDetected`.
    @ObservationIgnored var bargeInMinimumWords = 1
    /// A request open this long with no words is replaced (Apple ends recognition tasks near a minute).
    @ObservationIgnored var rotateAfter: TimeInterval = 50

    /// An utterance is being captured.
    private(set) var listening = false
    /// The microphone engine is up.
    private(set) var engineRunning = false
    /// The current utterance so far.
    private(set) var heard = ""
    private(set) var problem: String?

    /// Partial words of the current utterance, each time they change.
    @ObservationIgnored var onTranscript: ((String) -> Void)?
    /// The first word of an utterance (the barge-in hook).
    @ObservationIgnored var onSpeechDetected: (() -> Void)?
    /// The utterance ended: the words heard, or "" when nothing was heard before `giveUp`.
    @ObservationIgnored var onUtterance: ((String) -> Void)?
    /// A user-facing reason listening stopped.
    @ObservationIgnored var onFailure: ((String) -> Void)?

    @ObservationIgnored private let source: any RecognitionSource
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var warming: Task<Bool, Never>?
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var requestOpened = Date()
    /// Identifies the recognition request whose events count; changes whenever one ends or is replaced.
    @ObservationIgnored private var request = UUID()
    /// Invalidates a `warmUp()` in flight when `stop()` is called.
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var detected = false

    init(source: any RecognitionSource = SpeechRecognitionSource()) {
        self.source = source
        super.init()
        source.onEngineStopped { [weak self] message in
            Task { @MainActor in self?.engineStopped(message) }
        }
    }

    /// The pause that applies to this transcript: `pause`, or at most `sentencePause` once a sentence is finished.
    static func effectivePause(_ pause: TimeInterval, after transcript: String) -> TimeInterval {
        guard let last = transcript.trimmingCharacters(in: .whitespacesAndNewlines).last, ".?!".contains(last) else { return pause }
        return min(pause, sentencePause)
    }

    /// Permissions and the one audio engine. Idempotent. False (with `problem` set) when listening can't start.
    @discardableResult func warmUp() async -> Bool {
        if engineRunning { return true }
        if let warming { return await warming.value }
        let generation = self.generation
        let source = self.source
        let task = Task { @MainActor [weak self] () -> Bool in
            let failure = await source.start()
            guard let self else { return false }
            self.warming = nil
            guard generation == self.generation else { source.stop(); return false }
            if let failure { self.problem = failure; return false }
            self.problem = nil
            self.engineRunning = true
            Self.log.notice("Microphone started")
            return true
        }
        warming = task
        return await task.value
    }

    /// Starts capturing one utterance on the running engine. Call `warmUp()` first.
    func beginUtterance() {
        guard !listening, engineRunning else { return }
        heard = ""
        detected = false
        lastHeard = Date()
        guard open() else { return }
        problem = nil
        listening = true
        watch(request)
    }

    /// Drops the current words and ends the utterance without reporting it. The engine keeps running.
    func cancelUtterance() {
        closeRequest()
        listening = false
        heard = ""
    }

    /// Everything down.
    func stop() {
        generation = UUID()
        warming = nil
        closeRequest()
        source.stop()
        listening = false
        engineRunning = false
    }

    /// Opens a recognition request; false (with the failure reported) when the source refuses.
    private func open() -> Bool {
        let id = UUID()
        request = id
        requestOpened = Date()
        let failure = source.begin { [weak self] event in
            Task { @MainActor in self?.handle(event, from: id) }
        }
        guard let failure else { return true }
        request = UUID()
        problem = failure
        onFailure?(failure)
        return false
    }

    /// Ends the open request (if any) and stops the watcher; events from it are ignored from here on.
    private func closeRequest() {
        watcher?.cancel()
        watcher = nil
        request = UUID()
        source.end()
    }

    private func handle(_ event: RecognitionEvent, from id: UUID) {
        guard id == request, listening else { return }
        switch event {
        case .partial(let text):
            update(text)
        case .final(let text):
            update(text)
            if heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Date().timeIntervalSince(requestOpened) >= 1 {
                // The recognizer closed an empty request on its own; keep listening on a new one.
                Self.log.info("Recognition ended with no words; opening a new request")
                rotate()
            } else {
                Self.log.info("Recognition finished")
                finishUtterance()
            }
        case .failure(let domain, let code, let description):
            Self.log.error("Recognition failed: \(domain, privacy: .public) code \(code)")
            let message = domain == "kLSRErrorDomain" && code == 201
                ? "Dictation is disabled on this Mac. Turn on System Settings → Keyboard → Dictation, then try Conversation again."
                : "Listening stopped: \(description). Try Conversation again."
            problem = message
            stop()
            onFailure?(message)
        }
    }

    private func update(_ text: String) {
        guard text != heard else { return }
        Self.log.notice("Transcription updated: \(text.count) characters")
        heard = text
        lastHeard = Date()
        if !detected, Self.words(in: text) >= max(1, bargeInMinimumWords) {
            detected = true
            onSpeechDetected?()
        }
        onTranscript?(text)
    }

    /// Words of two letters or more.
    private static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.filter(\.isLetter).count >= 2 }.count
    }

    /// The utterance is over: end its request, then report it.
    private func finishUtterance() {
        guard listening else { return }
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        closeRequest()
        listening = false
        onUtterance?(words)
    }

    /// Replaces the open request with a fresh one inside the same utterance.
    private func rotate() {
        Self.log.info("Replacing the recognition request")
        request = UUID()
        source.end()
        guard open() else { stop(); return }
        watch(request)
    }

    private func engineStopped(_ message: String) {
        Self.log.error("Microphone engine stopped")
        stop()
        problem = message
        onFailure?(message)
    }

    /// Notices the pause after your words, or the silence when there were none.
    private func watch(_ id: UUID) {
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled, self.listening, id == self.request else { return }
                let now = Date()
                let quiet = now.timeIntervalSince(self.lastHeard)
                if self.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if quiet >= self.giveUp { self.finishUtterance(); return }
                    if now.timeIntervalSince(self.requestOpened) >= self.rotateAfter {
                        self.rotate()
                        return
                    }
                } else if quiet >= Self.effectivePause(self.pause, after: self.heard) {
                    self.finishUtterance()
                    return
                }
            }
        }
    }
}

// MARK: - Settings

/// The send pause, for Settings → Voice.
struct GolemListenerSettings: View {
    @AppStorage(GolemListener.pauseKey) private var stored = GolemListener.defaultPause
    private var pause: Binding<Double> {
        Binding(
            get: { min(max(stored, GolemListener.pauseRange.lowerBound), GolemListener.pauseRange.upperBound) },
            set: { stored = min(max($0, GolemListener.pauseRange.lowerBound), GolemListener.pauseRange.upperBound) }
        )
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Send after a pause of", value: String(format: "%.1f s", pause.wrappedValue))
            Slider(value: pause, in: GolemListener.pauseRange, step: 0.1) { Text("Send after a pause of") }
                .labelsHidden()
            Text("Sends sooner after a finished sentence.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
