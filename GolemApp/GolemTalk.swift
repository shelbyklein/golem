import AppKit
import OSLog
import SwiftUI

/// Talking with Golem on the Mac: while he's open (the mini, or his chat window on screen), he
/// reads each new reply aloud, then listens for yours and sends it once you pause. Saying
/// nothing, typing, or putting him away ends the back-and-forth.
///
/// The voice is `GolemSpeaker`, the ears `GolemListener`; this ties them to his conversation.
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
    private(set) var problem: String? { didSet { model?.dotMiniWindow?.voiceProblem = problem } }
    var speaking: Bool { speaker.speaking }
    var listening: Bool { listener.listening }
    var lastSpoken: (engine: String, at: Date)? { speaker.lastSpoken }

    /// After you stop talking, how long a pause sends; and how long silence ends listening.
    static let pause: TimeInterval = 1.5, giveUp: TimeInterval = 8

    let speaker = GolemSpeaker()
    let listener = GolemListener()

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var lastReply: UUID?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var startingListening = false
    /// The current utterance's words, as last shown in the box.
    @ObservationIgnored private var heard = ""
    /// What was already typed when you started talking; your words go after it.
    @ObservationIgnored private var prefix = ""
    private func shown(_ words: String) -> String { prefix.isEmpty ? words : words.isEmpty ? prefix : prefix + " " + words }

    override init() {
        super.init()
        speaker.onFinished = { [weak self] in self?.finishedSpeaking() }
        listener.onTranscript = { [weak self] words in self?.transcribed(words) }
        listener.onUtterance = { [weak self] words in self?.finishListening(words) }
        listener.onFailure = { [weak self] message in self?.problem = message; self?.stop() }
        mirror()
    }

    /// Reflects the pieces' state on the mini and in Settings.
    private func mirror() {
        model?.dotMiniWindow?.listening = listener.listening
        if let p = speaker.problem ?? listener.problem, p != problem { problem = p }
        withObservationTracking { _ = speaker.speaking; _ = listener.listening; _ = speaker.problem; _ = listener.problem } onChange: {
            Task { @MainActor [weak self] in self?.mirror() }
        }
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
        speaker.provider = ElevenLabs.key().map(ElevenLabsProvider.init)
        speaker.update(reply: reply.id, text: reply.text, final: true)
        watchWhileActive()
    }

    private func finishedSpeaking() {
        Self.log.notice("Reply audio finished; conversation=\(self.conversationActive), open=\(self.isOpen)")
        guard listens || conversationActive, isOpen else { stopWatching(); return }
        let generation = captureGeneration
        Task { @MainActor in
            // A beat after his voice ends, so the microphone doesn't catch the tail of it.
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == captureGeneration, !speaking, isOpen else { return }
            await startListening()
        }
    }

    // MARK: - Buttons

    /// Muted: replies aren't read aloud (the same as turning off reading in Settings).
    var muted: Bool { !reads }
    func toggleMute() { reads.toggle() }

    /// The listen button: talk now (he stops speaking), or stop listening.
    func toggleListening() {
        if conversationActive || startingListening || listening { stop(); return }
        if speaking { stop() }
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

    // MARK: - Listening

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
        heard = ""
        startingListening = true
        let generation = captureGeneration
        defer { if generation == captureGeneration { startingListening = false } }
        let ready = await listener.warmUp()
        guard generation == captureGeneration else { return }
        guard ready else { conversationActive = false; problem = listener.problem; return }
        listener.giveUp = conversationActive ? 30 : Self.giveUp
        listener.pause = Self.pause
        listener.beginUtterance()
        if listener.listening { problem = nil; watchWhileActive() }
        else if let failure = listener.problem { conversationActive = false; problem = failure }
    }

    /// Your words land in the box after whatever was typed. If the box changed under us, you
    /// typed: that's yours, so stop without sending.
    private func transcribed(_ words: String) {
        guard let dot = model?.dot else { return }
        if dot.draft != shown(heard) { stop(); return }
        heard = words
        dot.draft = shown(words)
    }

    /// You paused (or said nothing): send what was heard, if anything.
    private func finishListening(_ words: String) {
        let text = shown(words).trimmingCharacters(in: .whitespacesAndNewlines)
        let dot = model?.dot
        let attachments = dot?.draftAttachments ?? []
        if !words.isEmpty, dot?.draft == shown(heard) { dot?.draft = ""; dot?.draftAttachments = [] }
        heard = ""
        captureGeneration = UUID()
        if !speaking { stopWatching() }
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
        listener.cancelUtterance()
        if !speaking { stopWatching() }
    }

    func stop() {
        Self.log.notice("Conversation stopped; open=\(self.isOpen), listening=\(self.listening)")
        conversationActive = false
        speaker.stop()
        stopListening()
        stopWatching()
    }

    /// While speaking or listening: stop when he's put away.
    private func watchWhileActive() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if !self.isOpen { self.stop(); return }
                if !self.speaking && !self.listening { self.watcher = nil; return }
            }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }
}
