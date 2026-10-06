import AVFoundation
import OSLog
import Speech

/// Golem's ears: the microphone and speech recognition for one utterance at a time. Reports the
/// words as they're recognized and the finished utterance once you pause. Until the warm-mic work
/// lands, each utterance brings its own audio engine up and down.
@MainActor @Observable final class GolemListener: NSObject {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")

    /// After you stop talking, how long a pause ends the utterance.
    @ObservationIgnored var pause: TimeInterval = 1.5
    /// How long silence with no words at all ends the utterance (empty).
    @ObservationIgnored var giveUp: TimeInterval = 8

    /// An utterance is being captured.
    private(set) var listening = false
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

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var detected = false

    /// Permissions and recognizer availability. Idempotent. False (with `problem` set) when
    /// listening can't start.
    @discardableResult func warmUp() async -> Bool {
        let generation = self.generation
        let permitted = await Self.permitted()
        guard generation == self.generation else { return false }
        guard permitted else {
            problem = "Golem needs the microphone and speech recognition to hear you. Allow them in System Settings → Privacy & Security."
            return false
        }
        guard let recognizer, recognizer.isAvailable else { problem = "Speech recognition isn't available right now."; return false }
        problem = nil
        return true
    }

    /// Starts capturing one utterance. Call `warmUp()` first.
    func beginUtterance() {
        guard !listening, let recognizer else { return }
        let generation = self.generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        // A Bluetooth input can change sample rate when its microphone activates.
        // Recreate the engine and let AVAudioEngine negotiate the tap format.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            problem = "No microphone input is available. Choose an input in System Settings → Sound."
            onFailure?(problem!)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start listening: \(error.localizedDescription)"
            onFailure?(problem!)
            return
        }
        engineRunning = true
        self.request = request
        problem = nil
        heard = ""
        detected = false
        lastHeard = Date()
        listening = true
        Self.log.notice("Microphone started")
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self, generation == self.generation, self.listening else { return }
                if let text, text != self.heard {
                    Self.log.notice("Transcription updated: \(text.count) characters")
                    self.heard = text
                    self.lastHeard = Date()
                    if !self.detected, text.contains(where: \.isLetter) {
                        self.detected = true
                        self.onSpeechDetected?()
                    }
                    self.onTranscript?(text)
                }
                if let error {
                    let failure = error as NSError
                    Self.log.error("Recognition failed: \(failure.domain, privacy: .public) code \(failure.code)")
                    let message = failure.domain == "kLSRErrorDomain" && failure.code == 201
                        ? "Dictation is disabled on this Mac. Turn on System Settings → Keyboard → Dictation, then try Conversation again."
                        : "Listening stopped: \(error.localizedDescription). Try Conversation again."
                    self.problem = message
                    self.stop()
                    self.onFailure?(message)
                    return
                }
                if done { Self.log.info("Recognition finished"); self.finishUtterance() }
            }
        }
        watch()
    }

    /// Drops the current words and ends the utterance without reporting it.
    func cancelUtterance() {
        generation = UUID()
        tearDown()
    }

    /// Everything down.
    func stop() {
        generation = UUID()
        tearDown()
    }

    /// The utterance is over: report it.
    private func finishUtterance() {
        guard listening else { return }
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        generation = UUID()
        tearDown()
        onUtterance?(words)
    }

    private func tearDown() {
        watcher?.cancel()
        watcher = nil
        guard listening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        listening = false
        engineRunning = false
    }

    /// Notices the pause after your words, or the silence when there were none.
    private func watch() {
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled, self.listening else { return }
                if Date().timeIntervalSince(self.lastHeard) >= (self.heard.isEmpty ? self.giveUp : self.pause) {
                    self.finishUtterance()
                    return
                }
            }
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
