import SwiftUI

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

/// Conversation and mute in Golem's chat window toolbar.
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
