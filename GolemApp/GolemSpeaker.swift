import AppKit
import AVFoundation
import OSLog

/// Turns a segment of text into playable audio (anything `AVAudioPlayer` decodes).
protocol SpeechProvider: Sendable {
    func speech(for text: String) async throws -> Data
}

/// ElevenLabs as a provider, with the key read from Chatterbox's Secrets.
struct ElevenLabsProvider: SpeechProvider {
    let key: String
    func speech(for text: String) async throws -> Data { try await ElevenLabs.speech(text, key: key) }
}

/// Golem's voice: reads a reply aloud while it is still being written, a sentence or two at a
/// time. With a provider (ElevenLabs) the next segments are fetched while one plays; without one,
/// or once the provider fails, the Mac's own voice reads the rest.
@MainActor @Observable final class GolemSpeaker: NSObject {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")

    /// nil: the Mac's voice.
    @ObservationIgnored var provider: (any SpeechProvider)?
    private(set) var speaking = false
    private(set) var problem: String?
    /// Which voice last read part of a reply, and when: "ElevenLabs (streamed)" or "This Mac's voice".
    private(set) var lastSpoken: (engine: String, at: Date)?
    /// The reply was read to the end. Not called after `stop()`.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Volume of the Mac's voice (fixtures set 0 so tests stay quiet).
    @ObservationIgnored var macVoiceVolume: Float = 1
    /// Called as each segment starts being read: its index and the engine reading it.
    /// For fixtures; the app doesn't use it.
    @ObservationIgnored var onSegment: ((Int, String) -> Void)?

    /// Long replies are read up to here; the rest stays on screen.
    static let spokenLimit = 4000
    /// Short sentences are merged into one request up to about this many characters.
    static let mergeLimit = 240
    /// A sentence longer than this is cut at a comma or semicolon.
    static let sentenceLimit = 600
    /// Segments fetched at once, and how far ahead of the one playing.
    static let maxInFlight = 2
    static let lookahead = 2

    // The reply being read.
    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private var epoch = 0               // bumped by stop() and new replies; stale callbacks check it
    @ObservationIgnored private var halted = false          // stop() was called for `current`
    @ObservationIgnored private var done = false            // `current` finished playing
    @ObservationIgnored private var turnEnded = false       // the turn ended: no more text will come
    @ObservationIgnored private var consumed = ""           // raw text already cut into segments
    @ObservationIgnored private var spokenCount = 0         // cleaned characters queued so far (the cap)
    @ObservationIgnored private var capped = false
    @ObservationIgnored private var segments: [String] = []

    // Provider pipeline.
    @ObservationIgnored private var playIndex = 0           // the segment playing, or next to play
    @ObservationIgnored private var nextFetch = 0
    @ObservationIgnored private var fetching: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetched: [Int: Result<Data, Error>] = [:]
    @ObservationIgnored private var player: AVAudioPlayer?
    // Mac voice.
    @ObservationIgnored private var macMode = false
    @ObservationIgnored private var macQueued = 0           // segments handed to the synthesizer
    @ObservationIgnored private var macPending: [ObjectIdentifier: AVSpeechUtterance] = [:]
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Entry points

    /// The reply's full text so far; `final` once its turn has ended. Text is expected to only
    /// grow; sentences already queued are never spoken again.
    func update(reply id: UUID, text: String, final isFinal: Bool) {
        if id != current { begin(id) }
        guard !halted, !done else { return }
        if isFinal { turnEnded = true }
        absorb(text)
        advance()
    }

    /// Reads a whole reply.
    func speak(reply id: UUID, text: String) {
        if id == current { begin(id) }   // an explicit request restarts, even after stop() or a finished read
        update(reply: id, text: text, final: true)
    }

    /// Cancels fetches, playback and the queue. `onFinished` isn't called, and later updates for
    /// the same reply are ignored.
    func stop() {
        halted = true
        reset()
    }

    private func begin(_ id: UUID) {
        reset()
        current = id
        halted = false
        done = false
        problem = nil
    }

    /// Tears down everything in flight and forgets the reply's progress.
    private func reset() {
        epoch += 1
        fetching.values.forEach { $0.cancel() }
        fetching = [:]
        fetched = [:]
        player?.delegate = nil
        player?.stop()
        player = nil
        let wasSpeaking = !macPending.isEmpty
        macPending = [:]   // before stopping, so the delegate's didCancel finds nothing
        if wasSpeaking || synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        segments = []
        consumed = ""
        spokenCount = 0
        capped = false
        turnEnded = false
        playIndex = 0
        nextFetch = 0
        macMode = false
        macQueued = 0
        speaking = false
    }

    // MARK: - Segmenting

    /// Cuts whatever complete sentences the new text added into segments.
    private func absorb(_ text: String) {
        if !text.hasPrefix(consumed) {
            // Not append-only: continue from what still matches, and never re-speak what's queued.
            let old = Array(consumed), new = Array(text)
            var common = 0
            while common < old.count, common < new.count, old[common] == new[common] { common += 1 }
            Self.log.notice("Reply text changed after \(old.count) characters; continuing from \(common)")
            consumed = String(old[..<common])
        }
        guard !capped else { return }
        let rest = Array(text.dropFirst(consumed.count))
        let (pieces, used) = Self.cut(rest, final: turnEnded)
        guard used > 0 else { return }
        consumed += String(rest[..<used])
        for piece in Self.merge(pieces.map(Self.plain).filter { !$0.isEmpty }) {
            var segment = piece
            let room = Self.spokenLimit - spokenCount
            if segment.count > room {
                segment = String(segment.prefix(max(room, 0))) + "… The rest is on screen."
                capped = true
            }
            spokenCount += segment.count
            segments.append(segment)
            if capped { break }
        }
        if !segments.isEmpty, !speaking { speaking = true }
        Self.log.notice("Reply segments queued: \(self.segments.count)")
    }

    private static let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»", "*", "_", "`"]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "vs", "e.g", "i.e"]

    /// Complete sentences (and over-long runs) in `rest`, plus how many characters they use.
    /// The unfinished tail stays unspoken until `final`.
    static func cut(_ rest: [Character], final ended: Bool) -> (pieces: [String], used: Int) {
        var pieces: [String] = [], start = 0, i = 0
        func emit(_ range: Range<Int>) {
            var from = range.lowerBound
            while range.upperBound - from > sentenceLimit {
                let window = rest[from ..< from + sentenceLimit]
                let at = window.lastIndex { $0 == "," || $0 == ";" }.map { $0 + 1 }
                    ?? window.lastIndex(of: " ").map { $0 + 1 }
                guard let at, at > from else { break }
                pieces.append(String(rest[from ..< at])); from = at
            }
            pieces.append(String(rest[from ..< range.upperBound]))
        }
        while i < rest.count {
            let c = rest[i]
            if c == "\n", i + 1 < rest.count, rest[i + 1] == "\n" {
                emit(start ..< i); i += 2; start = i; continue
            }
            if ".!?…".contains(c), !(c == "." && isAbbreviation(rest, before: i)) {
                var end = i + 1
                while end < rest.count, closers.contains(rest[end]) { end += 1 }
                if end < rest.count, rest[end].isWhitespace {
                    emit(start ..< end); i = end + 1; start = i; continue
                }
                i = max(end, i + 1); continue
            }
            i += 1
        }
        var used = start
        if ended {
            if start < rest.count { emit(start ..< rest.count) }
            used = rest.count
        } else if rest.count - start > sentenceLimit {
            // A very long unfinished sentence: speak up to its last comma so audio isn't held back.
            let before = pieces.count
            emit(start ..< rest.count)
            let tail = pieces.removeLast()   // the part still short enough to wait
            if pieces.count > before { used = rest.count - tail.count }
        }
        return (pieces, used)
    }

    /// "3." at the start of a list line, "Dr.", "e.g." and the like aren't sentence ends.
    private static func isAbbreviation(_ rest: [Character], before i: Int) -> Bool {
        var j = i
        while j > 0, !rest[j - 1].isWhitespace { j -= 1 }
        let word = String(rest[j ..< i])
        if word.isEmpty { return false }
        if word.count <= 3, word.allSatisfy(\.isNumber), j == 0 || rest[j - 1] == "\n" { return true }
        return abbreviations.contains(word.lowercased())
    }

    /// Short sentences share a request, up to `mergeLimit` characters.
    static func merge(_ sentences: [String]) -> [String] {
        var out: [String] = [], group = ""
        for s in sentences {
            if !group.isEmpty, group.count + 1 + s.count > mergeLimit { out.append(group); group = "" }
            group += (group.isEmpty ? "" : " ") + s
        }
        if !group.isEmpty { out.append(group) }
        return out
    }

    // MARK: - Pipeline

    /// Moves the reply along: starts fetches, starts the next segment when nothing is playing,
    /// and finishes once the last one has been read. Called after every event.
    private func advance() {
        guard !halted, !done else { return }
        if macMode {
            speakWithMac()
        } else if let provider {
            prefetch(with: provider)
            if player == nil { playNext() }
        } else if player == nil {
            macMode = true
            macQueued = playIndex
            speakWithMac()
        }
        let drained = macMode ? macQueued == segments.count && macPending.isEmpty
                              : playIndex == segments.count && player == nil
        if turnEnded, drained, !segments.isEmpty, !done, !halted {
            done = true
            Self.log.notice("Reply audio finished (\(self.segments.count) segments)")
            speaking = false
            onFinished?()
        }
    }

    private func prefetch(with provider: any SpeechProvider) {
        while fetching.count < Self.maxInFlight, nextFetch < segments.count, nextFetch <= playIndex + Self.lookahead {
            let index = nextFetch, text = segments[index], epoch = self.epoch
            nextFetch += 1
            fetching[index] = Task { @MainActor [weak self] in
                let result: Result<Data, Error>
                do { result = .success(try await provider.speech(for: text)) } catch { result = .failure(error) }
                guard let self, !Task.isCancelled, self.epoch == epoch else { return }
                self.fetching[index] = nil
                self.fetched[index] = result
                self.advance()
            }
        }
    }

    private func playNext() {
        guard playIndex < segments.count, let result = fetched[playIndex] else { return }
        fetched[playIndex] = nil
        do {
            let player = try AVAudioPlayer(data: try result.get())
            player.delegate = self
            self.player = player
            lastSpoken = ("ElevenLabs (streamed)", Date())
            onSegment?(playIndex, "ElevenLabs (streamed)")
            if !player.play() { self.player = nil; playIndex += 1; advance() }
        } catch {
            problem = "ElevenLabs: \(error.localizedDescription) Using the Mac's voice."
            Self.log.notice("Provider failed on segment \(self.playIndex + 1); using the Mac's voice")
            fetching.values.forEach { $0.cancel() }
            fetching = [:]
            fetched = [:]
            macMode = true
            macQueued = playIndex
            advance()
        }
    }

    private func speakWithMac() {
        while macQueued < segments.count {
            let utterance = AVSpeechUtterance(string: segments[macQueued])
            utterance.voice = Self.voice
            utterance.volume = macVoiceVolume
            macPending[ObjectIdentifier(utterance)] = utterance
            lastSpoken = ("This Mac's voice", Date())
            onSegment?(macQueued, "This Mac's voice")
            macQueued += 1
            synthesizer.speak(utterance)
        }
    }

    fileprivate func playerFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        playIndex += 1
        advance()
    }

    fileprivate func utteranceFinished(_ id: ObjectIdentifier) {
        guard macPending.removeValue(forKey: id) != nil else { return }
        advance()
    }

    /// The best installed voice for your language (Premium or Enhanced when downloaded).
    private static var voice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { ($0.quality.rawValue, $0.language == locale ? 1 : 0) < ($1.quality.rawValue, $1.language == locale ? 1 : 0) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Markdown off and links named rather than spelled out.
    static func plain(_ text: String) -> String {
        var plain = MessageClipboard.plain(text)
        plain = plain.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"[`*_#>|]"#, with: "", options: .regularExpression)
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `plain`, with a cap on length.
    static func spoken(_ text: String) -> String {
        var plain = plain(text)
        if plain.count > spokenLimit { plain = String(plain.prefix(spokenLimit)) + "… The rest is on screen." }
        return plain
    }
}

extension GolemSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }
}

extension GolemSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
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
}
