import AppKit
import AVFoundation
import Speech
import SwiftUI
import OSLog

/// Talking with Golem on the Mac: while he's open (the mini, or his chat window on screen), he
/// reads each new reply aloud, then listens for yours and sends it once you pause. Saying
/// nothing, typing, or putting him away ends the back-and-forth.
@MainActor @Observable final class GolemTalk: NSObject {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")
    static let shared = GolemTalk()
    static let readsKey = "golemTalkReads", listensKey = "golemTalkListens"

    var reads: Bool {
        get { access(keyPath: \.reads); return AppPreferences.defaults.object(forKey: Self.readsKey) as? Bool ?? true }
        set { withMutation(keyPath: \.reads) { AppPreferences.defaults.set(newValue, forKey: Self.readsKey) }; if !newValue { stop() } }
    }
    var listens: Bool {
        get { access(keyPath: \.listens); return AppPreferences.defaults.object(forKey: Self.listensKey) as? Bool ?? true }
        set { withMutation(keyPath: \.listens) { AppPreferences.defaults.set(newValue, forKey: Self.listensKey) }; if !newValue { stopListening() } }
    }
    private(set) var conversationActive = false { didSet { model?.dotMiniWindow?.conversationActive = conversationActive } }
    private var captureGeneration = UUID()
    private var startingListening = false
    private(set) var speaking = false
    private(set) var listening = false { didSet { model?.dotMiniWindow?.listening = listening } }
    private(set) var problem: String? { didSet { model?.dotMiniWindow?.voiceProblem = problem } }
    /// Which voice last read a reply, and when: "ElevenLabs" or "This Mac's voice".
    private(set) var lastSpoken: (engine: String, at: Date)?

    /// After you stop talking, how long a pause sends; and how long silence ends listening.
    static let pause: TimeInterval = 1.5, giveUp: TimeInterval = 8
    /// Long replies are read up to here; the rest stays on screen.
    static let spokenLimit = 4000

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var lastReply: UUID?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var played: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var heard = ""
    /// What was already typed when you started talking; your words go after it.
    @ObservationIgnored private var prefix = ""
    private func shown(_ words: String) -> String { prefix.isEmpty ? words : words.isEmpty ? prefix : prefix + " " + words }
    @ObservationIgnored private var lastHeard = Date()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts following Golem's conversation. Replies already there when it starts stay quiet.
    func start(_ model: AppModel) {
        self.model = model
        model.dotMiniWindow?.voice = MiniVoiceControls(muted: { [weak self] in self?.muted ?? false },
                                                         toggleMute: { [weak self] in self?.toggleMute() },
                                                         toggleListening: { [weak self] in self?.toggleListening() },
                                                         stopConversation: { [weak self] in self?.stop() })
        lastReply = model.dot.flatMap(Self.latestReply)?.id
        follow()
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let request = GolemConversationRequest.shared.pending, let self {
                    if !request.start { self.stop(); GolemConversationRequest.shared.finish(request) }
                    else if self.model?.dot != nil {
                        if self.conversationActive { GolemConversationRequest.shared.finish(request) }
                        else if let dot = self.model?.dot, dot.isRunning || !dot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !dot.draftAttachments.isEmpty {
                            GolemConversationRequest.shared.finish(request, error: "Wait for Golem to finish and send or clear your draft before starting Conversation.")
                        } else {
                            if !self.isOpen {
                                self.model?.showingDot = true
                                self.model?.dotMiniWindow?.setCollapsed(false)
                            }
                            NSApp.activate(ignoringOtherApps: true)
                            if self.isOpen {
                                GolemConversationRequest.shared.cancelPending = { [weak self] in self?.stop() }
                                self.conversationActive = true
                                await self.startListening(manual: true)
                                GolemConversationRequest.shared.finish(request, error: self.listening ? nil : self.problem ?? "Listening did not start.")
                            }
                        }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func follow() {
        withObservationTracking {
            _ = model?.dot.flatMap(Self.latestReply)?.id
            _ = model?.dot?.isRunning
        } onChange: {
            Task { @MainActor [weak self] in self?.replyChanged(); self?.follow() }
        }
    }

    static func latestReply(_ session: ChatSession) -> DisplayItem? {
        session.items.last { $0.kind == .assistant && $0.phase != .commentary && !$0.text.isEmpty }
    }

    /// He's open: the mini isn't minimized, or his chat window is on screen.
    var isOpen: Bool {
        guard let model else { return false }
        if model.showingDot, let mini = model.dotMiniWindow, !mini.collapsed { return true }
        if let window = model.mainChatWindow, window.isVisible, !window.isMiniaturized,
           window.occlusionState.contains(.visible) { return true }
        return false
    }

    private func replyChanged() {
        guard let dot = model?.dot, !dot.isRunning, let reply = Self.latestReply(dot), reply.id != lastReply else { return }
        lastReply = reply.id
        guard reads || conversationActive, isOpen else { return }
        let active = conversationActive
        stop()
        conversationActive = active
        speak(reply.text)
    }

    // MARK: - Speaking

    private func speak(_ text: String) {
        let spoken = Self.spoken(text)
        guard !spoken.isEmpty else { return }
        speaking = true
        watchWhileActive()
        reading = Task { @MainActor [weak self] in
            guard let self else { return }
            if let key = ElevenLabs.key() {
                do {
                    try await self.readWithElevenLabs(spoken, key: key)
                    self.lastSpoken = ("ElevenLabs", Date())
                    if !Task.isCancelled { self.finishedSpeaking() }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.problem = "ElevenLabs: \(error.localizedDescription) Using the Mac's voice."
                }
            }
            guard !Task.isCancelled else { return }
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = Self.voice
            self.lastSpoken = ("This Mac's voice", Date())
            self.synthesizer.speak(utterance)   // the delegate calls finishedSpeaking
        }
    }

    /// A paragraph or so at a time, the next fetched while one plays.
    private func readWithElevenLabs(_ text: String, key: String) async throws {
        let chunks = ElevenLabs.chunks(text)
        var next: Task<Data, Error>? = Task { try await ElevenLabs.speech(chunks[0], key: key) }
        var index = 0
        while let pending = next, !Task.isCancelled {
            let data = try await pending.value
            let following = index + 1
            next = following < chunks.count ? Task { try await ElevenLabs.speech(chunks[following], key: key) } : nil
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            await withCheckedContinuation { continuation in
                played = continuation
                if !player.play() { finishedPlaying() }
            }
            index += 1
        }
        next?.cancel()
        problem = nil
    }

    private func finishedPlaying() {
        let continuation = played
        played = nil
        continuation?.resume()
    }

    /// The best installed voice for your language (Premium or Enhanced when downloaded).
    private static var voice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { ($0.quality.rawValue, $0.language == Locale.current.identifier.replacingOccurrences(of: "_", with: "-") ? 1 : 0)
                 < ($1.quality.rawValue, $1.language == Locale.current.identifier.replacingOccurrences(of: "_", with: "-") ? 1 : 0) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Markdown off, links named rather than spelled out, and a cap on length.
    static func spoken(_ text: String) -> String {
        var plain = MessageClipboard.plain(text)
        plain = plain.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"[`*_#>|]"#, with: "", options: .regularExpression)
        plain = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.count > spokenLimit { plain = String(plain.prefix(spokenLimit)) + "… The rest is on screen." }
        return plain
    }

    private func finishedSpeaking() {
        Self.log.notice("Reply audio finished; conversation=\(self.conversationActive), open=\(self.isOpen)")
        speaking = false
        guard listens || conversationActive, isOpen else { stopWatching(); return }
        let generation = captureGeneration
        Task { @MainActor in
            // A beat after his voice ends, so the microphone doesn't catch the tail of it.
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == captureGeneration, !speaking, isOpen else { return }
            await startListening()
        }
    }

    // MARK: - Listening

    // MARK: - Buttons

    /// Muted: replies aren't read aloud (the same as turning off reading in Settings).
    var muted: Bool { !reads }
    func toggleMute() { reads.toggle() }

    /// The listen button: talk now (he stops speaking), or stop listening.
    func toggleListening() {
        if conversationActive || startingListening || listening { stop(); return }
        if synthesizer.isSpeaking || player != nil { stop() }
        conversationActive = true
        // Listening needs him open; from the minimized mini, open it so you see your words.
        if !isOpen, let mini = model?.dotMiniWindow, model?.showingDot == true { mini.setCollapsed(false) }
        let generation = captureGeneration
        Task { @MainActor in
            for _ in 0..<20 where !isOpen { try? await Task.sleep(for: .milliseconds(50)) }
            guard generation == captureGeneration, conversationActive else { return }
            await startListening(manual: true)
        }
    }

    /// Automatically only into an empty box; from the button, after whatever's typed.
    private func startListening(manual: Bool = false) async {
        guard !listening, !startingListening, let dot = model?.dot else { return }
        guard manual || (dot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dot.draftAttachments.isEmpty) else {
            Self.log.notice("Listen-after-reply blocked by unsent draft")
            problem = "Your unsent text is still in the box. Send or clear it, then start Conversation again."
            conversationActive = false
            return
        }
        prefix = manual ? dot.draft.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        startingListening = true
        let generation = captureGeneration
        defer { if generation == captureGeneration { startingListening = false } }
        let permitted = await Self.permitted()
        guard generation == captureGeneration else { return }
        guard permitted else {
            conversationActive = false
            problem = "Golem needs the microphone and speech recognition to hear you. Allow them in System Settings → Privacy & Security."
            return
        }
        guard let recognizer, recognizer.isAvailable else { conversationActive = false; problem = "Speech recognition isn't available right now."; return }
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
            conversationActive = false
            problem = "No microphone input is available. Choose an input in System Settings → Sound."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            conversationActive = false
            problem = "Couldn't start listening: \(error.localizedDescription)"
            return
        }
        self.request = request
        problem = nil
        heard = ""
        lastHeard = Date()
        listening = true
        Self.log.notice("Microphone started")
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self, generation == self.captureGeneration, self.listening else { return }
                if let text, text != self.heard {
                    // You typed in the box meanwhile: that's yours; stop without sending.
                    if let dot = self.model?.dot, dot.draft != self.shown(self.heard) { self.stop(); return }
                    Self.log.notice("Transcription updated: \(text.count) characters")
                    self.heard = text
                    self.lastHeard = Date()
                    self.model?.dot?.draft = self.shown(text)
                }
                if let error {
                    let failure = error as NSError
                    Self.log.error("Recognition failed: \(failure.domain, privacy: .public) code \(failure.code)")
                    self.problem = failure.domain == "kLSRErrorDomain" && failure.code == 201
                        ? "Dictation is disabled on this Mac. Turn on System Settings → Keyboard → Dictation, then try Conversation again."
                        : "Listening stopped: \(error.localizedDescription). Try Conversation again."
                    self.stop()
                    return
                }
                if done { Self.log.info("Recognition finished"); self.finishListening() }
            }
        }
        watchWhileActive()
    }

    /// You paused (or said nothing): send what was heard, if anything.
    private func finishListening() {
        guard listening else { return }
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = shown(words).trimmingCharacters(in: .whitespacesAndNewlines)
        let dot = model?.dot
        let attachments = dot?.draftAttachments ?? []
        if !words.isEmpty, dot?.draft == shown(heard) { dot?.draft = ""; dot?.draftAttachments = [] }
        stopListening()
        if !words.isEmpty, let dot { dot.send(text, attachments: attachments) }
        else {
            if conversationActive { problem = "No speech was recognized. Conversation paused; press Conversation to try again." }
            conversationActive = false
        }
    }

    /// Stops listening without sending. Anything heard stays in the box.
    func stopListening() {
        captureGeneration = UUID()
        startingListening = false
        guard listening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        listening = false
        if !speaking { stopWatching() }
    }

    func stop() {
        Self.log.notice("Conversation stopped; open=\(self.isOpen), listening=\(self.listening)")
        conversationActive = false
        reading?.cancel()
        reading = nil
        player?.stop()
        player = nil
        finishedPlaying()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
        stopListening()
        stopWatching()
    }

    /// While speaking or listening: notice pauses, and stop when he's put away.
    private func watchWhileActive() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if !self.isOpen { self.stop(); return }
                if self.listening, Date().timeIntervalSince(self.lastHeard) >= (self.heard.isEmpty ? (self.conversationActive ? 30 : Self.giveUp) : Self.pause) {
                    self.finishListening()
                }
                if !self.speaking && !self.listening { self.watcher = nil; return }
            }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private static func permitted() async -> Bool {
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

extension GolemTalk: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedPlaying() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishedPlaying() }
    }
}

/// ElevenLabs, with the key you saved in Chatterbox → Settings → Secrets as ELEVENLABS.
/// The key is read from this Mac's Keychain and sent only to ElevenLabs.
enum ElevenLabs {
    static let voiceKey = "golemTalkElevenLabsVoice"
    /// ElevenLabs' example voice, until one is picked.
    static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"
    static var voice: String { AppPreferences.defaults.string(forKey: voiceKey) ?? defaultVoice }

    static func key() -> String? {
        let file = RuntimePaths.data.appendingPathComponent("Secrets.json")
        struct Entry: Decodable { var id: UUID; var name: String; var variable: String }
        guard let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([Entry].self, from: data),
              let entry = entries.first(where: { $0.variable == "ELEVENLABS" || $0.variable == "ELEVENLABS_API_KEY" || $0.name.lowercased() == "elevenlabs" })
        else { return nil }
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.shelbyklein.Chatterbox.secrets",
                                          kSecAttrAccount: entry.id.uuidString, kSecReturnData: true,
                                          kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func speech(_ text: String, key: String) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try ElevenLabsSpeechSettings.payload(text: text, speed: ElevenLabsSpeechSettings.speed())
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    struct Voice: Decodable, Identifiable, Hashable { var voice_id: String; var name: String; var id: String { voice_id } }
    static func voices(key: String) async throws -> [Voice] {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100")!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        struct Page: Decodable { var voices: [Voice] }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(Page.self, from: data).voices.sorted { $0.name < $1.name }
    }

    /// ElevenLabs answers 401 both for a bad key and for a good key missing a permission
    /// (a key limited to text to speech can't list voices); its body says which.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure("No response.") }
        guard http.statusCode != 200 else { return }
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? [String: Any]
        let status = detail?["status"] as? String, message = detail?["message"] as? String
        switch http.statusCode {
        case 401 where status == "missing_permissions" || message?.localizedCaseInsensitiveContains("permission") == true:
            throw Failure(message ?? "The key is missing a permission.", missingPermission: true)
        case 401: throw Failure("The API key wasn't accepted\(message.map { ": \($0)" } ?? ".")")
        case 429: throw Failure("Rate or quota limit reached.")
        default: throw Failure(message ?? "Request failed (\(http.statusCode)).")
        }
    }
    struct Failure: LocalizedError {
        var message: String
        var missingPermission = false
        init(_ m: String, missingPermission: Bool = false) { message = m; self.missingPermission = missingPermission }
        var errorDescription: String? { message }
    }

    /// Paragraphs, merged up to about 600 characters, so the first one starts playing quickly.
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = [], current = ""
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            if !current.isEmpty, current.count + paragraph.count > 600 { chunks.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }
}

extension GolemTalk: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

/// Settings → Voice.
struct GolemTalkSettings: View {
    private var talk: GolemTalk { .shared }
    @State private var hasKey = false
    @State private var voices: [ElevenLabs.Voice] = []
    @State private var voiceProblem: String?
    @AppStorage(ElevenLabs.voiceKey) private var voice = ElevenLabs.defaultVoice
    var body: some View {
        Section {
            Toggle("Read new replies aloud while Golem is open", isOn: Binding(get: { talk.reads }, set: { talk.reads = $0 }))
            if talk.reads {
                Toggle("Then listen for my reply", isOn: Binding(get: { talk.listens }, set: { talk.listens = $0 }))
            }
            ElevenLabsSpeedControl()
            if hasKey {
                if voices.isEmpty {
                    LabeledContent("ElevenLabs voice", value: voiceProblem == nil ? "Loading\u{2026}" : "Default voice")
                    if let voiceProblem {
                        Text(voiceProblem).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("ElevenLabs voice", selection: $voice) { ForEach(voices) { Text($0.name).tag($0.voice_id) } }
                }
            } else {
                LabeledContent("Voice", value: "This Mac's voice")
                Text("For an ElevenLabs voice, add a secret named ELEVENLABS in Chatterbox → Settings → Secrets.").font(.caption).foregroundStyle(.secondary)
            }
            if let last = talk.lastSpoken {
                LabeledContent("Last reply read with", value: "\(last.engine), \(last.at.formatted(date: .omitted, time: .shortened))")
            }
            if let problem = talk.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Voice")
        } footer: {
            Text((hasKey ? "Replies are spoken with ElevenLabs using your ELEVENLABS key from Chatterbox's Secrets: their text goes to ElevenLabs and uses your credits. " : "") + "Open means the mini isn't minimized, or his chat window is on screen. After reading, he listens and sends what you say when you pause; stay quiet, type, or minimize him to stop. Speech is recognized on this Mac when possible.")
        }
        .task {
            guard let key = ElevenLabs.key() else { hasKey = false; return }
            hasKey = true
            do {
                voices = try await ElevenLabs.voices(key: key)
                if !voices.contains(where: { $0.voice_id == voice }), let first = voices.first { voice = first.voice_id }
            } catch let failure as ElevenLabs.Failure where failure.missingPermission {
                voiceProblem = "Your key can speak but isn't allowed to list voices, so Golem uses the default voice. To pick one here, give the key Voices: Read access in ElevenLabs."
            } catch {
                voiceProblem = "Couldn't list your voices (\(error.localizedDescription)). Speaking can still work; Golem uses the default voice."
            }
        }
    }
}

/// Listen and mute in Golem's chat window toolbar.
struct GolemVoiceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    private var talk: GolemTalk { .shared }
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let session = model.dot {
                RestartThreadControl(session: session, beforeRestart: { talk.stop() })
            }
            Button { talk.toggleListening() } label: {
                Label(talk.conversationActive ? "End Conversation" : "Conversation", systemImage: talk.conversationActive ? "stop.fill" : "waveform")
            }
            .foregroundStyle(talk.listening ? Color.red : Color.primary)
            .help(talk.conversationActive ? "End conversation; keep unsent words" : "Start a conversation: speak, pause to send, and hear Golem reply")
            if let problem = talk.problem {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(problem)
                    .accessibilityLabel(problem)
            }
            Button { talk.toggleMute() } label: {
                Label(talk.muted ? "Unmute" : "Mute", systemImage: talk.muted ? "speaker.slash" : "speaker.wave.2")
            }
            .help(talk.muted ? "Unmute: read replies aloud" : "Mute: stop reading replies aloud")
        }
    }
}
