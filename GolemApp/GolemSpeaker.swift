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

/// Golem's voice: reads a reply aloud with the provider (ElevenLabs) when there is one, otherwise
/// with the Mac's own voice; falls back to the Mac's voice if the provider fails mid-reply.
@MainActor @Observable final class GolemSpeaker: NSObject {
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Conversation")

    /// nil: the Mac's voice.
    @ObservationIgnored var provider: (any SpeechProvider)?
    private(set) var speaking = false
    private(set) var problem: String?
    /// Which voice last read a reply, and when: "ElevenLabs" or "This Mac's voice".
    private(set) var lastSpoken: (engine: String, at: Date)?
    /// The reply was read to the end. Not called after `stop()`.
    @ObservationIgnored var onFinished: (() -> Void)?

    /// Long replies are read up to here; the rest stays on screen.
    static let spokenLimit = 4000

    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var played: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Entry points

    /// The reply's full text so far; `final` once its turn has ended. Until streaming lands,
    /// only the final text is spoken, as one reply.
    func update(reply id: UUID, text: String, final: Bool) {
        guard final, id != current else { return }
        speak(reply: id, text: text)
    }

    /// Reads a whole reply.
    func speak(reply id: UUID, text: String) {
        stop()
        current = id
        let spoken = Self.spoken(text)
        guard !spoken.isEmpty else { return }
        speaking = true
        reading = Task { @MainActor [weak self] in
            guard let self else { return }
            if let provider = self.provider {
                do {
                    try await self.read(spoken, with: provider)
                    self.lastSpoken = ("ElevenLabs", Date())
                    if !Task.isCancelled { self.finished() }
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
            self.synthesizer.speak(utterance)   // the delegate calls finished()
        }
    }

    /// Cancels fetches, playback and the queue. `onFinished` isn't called.
    func stop() {
        reading?.cancel()
        reading = nil
        player?.stop()
        player = nil
        finishedPlaying()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
    }

    private func finished() {
        Self.log.notice("Reply audio finished")
        speaking = false
        onFinished?()
    }

    // MARK: - Playback

    /// A paragraph or so at a time, the next fetched while one plays.
    private func read(_ text: String, with provider: any SpeechProvider) async throws {
        let chunks = ElevenLabs.chunks(text)
        var next: Task<Data, Error>? = Task { try await provider.speech(for: chunks[0]) }
        var index = 0
        while let pending = next, !Task.isCancelled {
            let data = try await pending.value
            let following = index + 1
            next = following < chunks.count ? Task { try await provider.speech(for: chunks[following]) } : nil
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
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { ($0.quality.rawValue, $0.language == locale ? 1 : 0) < ($1.quality.rawValue, $1.language == locale ? 1 : 0) }
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
}

extension GolemSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedPlaying() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishedPlaying() }
    }
}

extension GolemSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
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
