import AppKit
import OSLog
import SwiftUI

/// Talking with Golem on the Mac: while he's open (the mini, or his chat window on screen), he
/// reads each reply aloud as it arrives, listens the whole time, and sends what you say once you
/// pause. Talking over him interrupts him. Staying quiet, typing, or putting him away ends it.
///
/// The voice is `GolemSpeaker`, the ears `GolemListener`; this ties them to his conversation.
@MainActor @Observable final class GolemTalk: NSObject {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")
    static let shared = GolemTalk()
    static let readsKey = "golemTalkReads", listensKey = "golemTalkListens"

    var reads: Bool {
        get { access(keyPath: \.reads); return AppPreferences.defaults.object(forKey: Self.readsKey) as? Bool ?? true }
        set { withMutation(keyPath: \.reads) { AppPreferences.defaults.set(newValue, forKey: Self.readsKey) }; if !newValue { speaker.stop() } }
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

    /// How long silence with no words ends listening outside a conversation (30 s inside one).
    static let giveUp: TimeInterval = 8

    let speaker: GolemSpeaker
    let listener: GolemListener
    /// How a finished utterance reaches the chat; fixtures record instead.
    @ObservationIgnored var send: (ChatSession, String, [Attachment]) -> Void = { $0.send($1, attachments: $2) }

    @ObservationIgnored private weak var model: AppModel?
    /// The newest reply seen; replies there at launch stay quiet.
    @ObservationIgnored private var lastReply: UUID?
    /// The reply being read, if its reading was allowed when it began.
    @ObservationIgnored private var spokenReply: UUID?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var startingListening = false
    /// The current utterance's words, as last shown in the box.
    @ObservationIgnored private var heard = ""
    /// What was already typed when you started talking; your words go after it.
    @ObservationIgnored private var prefix = ""
    private func shown(_ words: String) -> String { prefix.isEmpty ? words : words.isEmpty ? prefix : prefix + " " + words }

    init(speaker: GolemSpeaker? = nil, listener: GolemListener? = nil) {
        self.speaker = speaker ?? GolemSpeaker()
        self.listener = listener ?? GolemListener()
        super.init()
        self.speaker.onFinished = { [weak self] in self?.finishedSpeaking() }
        self.listener.onTranscript = { [weak self] words in self?.transcribed(words) }
        self.listener.onSpeechDetected = { [weak self] in self?.speechDetected() }
        self.listener.onUtterance = { [weak self] words in self?.finishListening(words) }
        self.listener.onFailure = { [weak self] message in self?.problem = message; self?.stop() }
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
            let reply = model?.dot.flatMap(Self.latestReply)
            _ = reply?.id; _ = reply?.text; _ = reply?.phase
            _ = model?.dot?.isRunning
        } onChange: {
            Task { @MainActor [weak self] in self?.replyChanged(); self?.follow() }
        }
    }

    /// The newest reply, streaming or finished.
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

    /// Each change to the newest reply: a new one starts being read as it streams; the rest of
    /// its text follows; `final` once its turn has ended.
    private func replyChanged() {
        guard let dot = model?.dot, let reply = Self.latestReply(dot) else { return }
        if reply.id != lastReply {
            lastReply = reply.id
            guard reads, isOpen else { spokenReply = nil; return }
            spokenReply = reply.id
            speaker.provider = ElevenLabs.key().map(ElevenLabsProvider.init)
            listenWhileSpeaking()
            watchWhileActive()
        }
        guard spokenReply == reply.id else { return }
        speaker.update(reply: reply.id, text: reply.text, final: !dot.isRunning)
    }

    /// The ears stay open while he talks, so you can interrupt him.
    private func listenWhileSpeaking() {
        guard listens || conversationActive, !listener.listening, !startingListening, let dot = model?.dot,
              dot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, dot.draftAttachments.isEmpty else { return }
        Task { @MainActor in await startListening() }
    }

    private func finishedSpeaking() {
        Self.log.notice("Reply audio finished; conversation=\(self.conversationActive), open=\(self.isOpen)")
        if speaker.fullyRead, let id = spokenReply {
            model?.dotMiniWindow?.hideSpokenReply(id)
        }
        guard listens || conversationActive, isOpen else { stopWatching(); return }
        if !listener.listening { Task { @MainActor in await startListening() } }
    }

    /// Your first word while he's talking: he stops and lets you finish.
    private func speechDetected() {
        guard speaker.speaking else { return }
        Self.log.notice("Barge-in: stopping playback")
        speaker.stop()
    }

    // MARK: - Buttons

    /// Muted: replies aren't read aloud (the same as turning off reading in Settings).
    var muted: Bool { !reads }
    func toggleMute() { reads.toggle() }

    /// The Conversation button: talk now (he stops speaking), or end the conversation.
    func toggleListening() {
        if conversationActive || startingListening || listening { stop(); return }
        if speaking { speaker.stop() }
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

    /// Automatically only into an empty box; from the button, after whatever's typed. The engine
    /// warms once and stays up; each call opens one utterance on it.
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
        guard isOpen else { return }
        listener.giveUp = conversationActive ? 30 : Self.giveUp
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

    /// You paused (or said nothing): send what was heard, if anything, and keep listening.
    private func finishListening(_ words: String) {
        let text = shown(words).trimmingCharacters(in: .whitespacesAndNewlines)
        let dot = model?.dot
        let attachments = dot?.draftAttachments ?? []
        if !words.isEmpty, dot?.draft == shown(heard) { dot?.draft = ""; dot?.draftAttachments = [] }
        heard = ""
        prefix = ""
        if words.isEmpty {
            // Nothing said while he talked: keep the ears open for him finishing.
            if speaker.speaking, isOpen { listener.beginUtterance(); return }
            if conversationActive { problem = "No speech was recognized. Conversation paused; press Conversation to try again." }
            conversationActive = false
            listener.stop()
            if !speaking { stopWatching() }
            return
        }
        if let dot { send(dot, text, attachments) }
        // In a conversation the microphone stays warm across turns; otherwise this listen is over.
        if conversationActive, isOpen { listener.beginUtterance() }
        else if !speaker.speaking { listener.stop(); stopWatching() }
    }

    /// Stops listening without sending. Anything heard stays in the box.
    func stopListening() {
        captureGeneration = UUID()
        startingListening = false
        listener.cancelUtterance()
        if !conversationActive { listener.stop() }
        if !speaking { stopWatching() }
    }

    func stop() {
        Self.log.notice("Conversation stopped; open=\(self.isOpen), listening=\(self.listening)")
        conversationActive = false
        captureGeneration = UUID()
        startingListening = false
        speaker.stop()
        listener.stop()
        stopWatching()
    }

    /// While speaking or the microphone is up: stop everything when he's put away.
    private func watchWhileActive() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if !self.isOpen { self.stop(); return }
                if !self.speaking && !self.listening && !self.listener.engineRunning { self.watcher = nil; return }
            }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }
}
