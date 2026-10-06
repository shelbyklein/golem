# Handoff: Golem Mac voice streaming, barge-in, warm mic, pause tuning

Coordinator instructions and lane specs. Plan: [golem-voice-streaming-2026-10-06.md](golem-voice-streaming-2026-10-06.md). Issue: https://github.com/shelbyklein/golem/issues/9

## Roles and models
- **Coordinator / integration owner:** Claude Fable 5.1 (`claude-fable-5-1`), this session. Owns VS-01, VS-04, VS-05, the plan, and the GitHub issue checklist.
- **Lane A (speaker):** Claude Sonnet 5.5 (`claude-sonnet-5-5`), effort high. Owns VS-02.
- **Lane B (listener):** Claude Sonnet 5.5 (`claude-sonnet-5-5`), effort high. Owns VS-03.

## Repository, baseline, worktrees
- shelbyklein/golem; main checkout `/Users/shelbyklein/Vibes/Golem` on `main` at `77328d8`; Core submodule pinned `4b1212d` (do not change the pin or any file under `Core/`).
- Coordinator lands VS-01 on branch `claude/golem-voice-streaming` and pushes it. Each lane gets its own worktree created from that branch tip (`EnterWorktree`/`git worktree add`), works on `claude/golem-voice-streaming-speaker` / `-listener`, and pushes. The coordinator merges lanes into `claude/golem-voice-streaming` in order A then B, building and running the fixtures after each merge.
- Build: `env -u CHATTERBOX_DATA_DIR xcodebuild -project Golem.xcodeproj -scheme Golem -derivedDataPath build/GolemPlan build` from the worktree root (run `xcodegen generate` first if you add files; `project.yml` globs `GolemApp/`, so new files there are picked up by regeneration). Builds take 1–3 minutes.
- Fixtures: `scripts/test-golem-voice.sh <name>` compiles `tests/golem-voice/<name>/main.swift` against `build/GolemPlan/Build/Products/Debug/Golem.app/Contents/MacOS/Golem.debug.dylib` with `-D DEBUG` and runs it with `CHATTERBOX_DATA_DIR`, `CHATTERBOX_HOST_DIR`, `CHATTERBOX_ASSISTANT_DIR` pointing at a fresh temp dir and `CHATTERBOX_AGENT_PORT=0 CHATTERBOX_COMPANION_PORT=0`. **Never run a fixture or the app against the live store**: shells inherit `CHATTERBOX_DATA_DIR=~/Library/Application Support/Chatterbox`; the script must override it. Fixtures use `UserDefaults.standard.setVolatileDomain([...], forName: UserDefaults.argumentDomain)` to isolate preferences (see existing fixtures after VS-01).
- No paid ElevenLabs calls from fixtures or agents. Fixtures inject a stub `SpeechProvider`. The coordinator runs the one real smoke test in VS-04 with the user's approval.
- Never launch `Golem.app` from an agent shell without `env -u CHATTERBOX_DATA_DIR -u CHATTERBOX_ASSISTANT_DIR -u CHATTERBOX_HOST_DIR -u CHATTERBOX_HOST_BINARY -u CHATTERBOX_MCP_BINARY open -n …`; lanes should not launch it at all.
- Do not install over `/Applications/Golem.app`, touch `golemd`/`chatterboxd`, credentials, Keychain, or Chatterbox Secrets.

## File ownership (after VS-01)
| File | Owner | Others |
|---|---|---|
| `GolemApp/GolemSpeaker.swift` | Lane A | read-only |
| `tests/golem-voice/speaker/main.swift` | Lane A | — |
| `GolemApp/GolemListener.swift` | Lane B | read-only |
| `tests/golem-voice/listener/main.swift` | Lane B | — |
| `GolemApp/GolemTalk.swift`, `GolemVoiceSettings.swift`, `GolemApp.swift`, `scripts/test-golem-voice.sh`, `tests/golem-voice/{talk,buttons,conversation}/` | Coordinator | lanes must not edit; if a lane needs an interface change in `GolemTalk`, it reports the exact signature in its completion report instead |
| `Core/**`, `project.yml`, `Golem.xcodeproj` | Coordinator | lanes must not edit (new files under `GolemApp/` need no project edit beyond `xcodegen generate`, which lanes may run locally but must not commit the pbxproj) |

If two lanes would need the same file, stop and report; the coordinator resolves it. Never reset, rebase, or overwrite another lane's branch.

## Interfaces fixed by VS-01 (lanes implement behind these)
The coordinator's VS-01 refactor establishes these shapes. Lanes may add members but must keep these signatures so `GolemTalk` integration (VS-04) is mechanical.

```swift
// GolemSpeaker.swift
protocol SpeechProvider: Sendable {
    /// Audio (mp3/wav data playable by AVAudioPlayer) for one segment.
    func speech(for text: String) async throws -> Data
}

@MainActor @Observable final class GolemSpeaker: NSObject {
    var provider: (any SpeechProvider)?           // nil → Mac voice (AVSpeechSynthesizer)
    private(set) var speaking: Bool
    private(set) var lastSpoken: (engine: String, at: Date)?
    private(set) var problem: String?
    var onFinished: (() -> Void)?                 // the reply was read to the end (not on stop)
    /// Streaming entry point: call with the reply's full text so far, `final` once the turn ended.
    func update(reply id: UUID, text: String, final: Bool)
    /// Whole-text convenience (final in one go).
    func speak(reply id: UUID, text: String)
    func stop()                                   // cancels fetches, playback, queue; onFinished not called
    static func spoken(_ markdown: String) -> String   // existing cleaner, moved here
}

// GolemListener.swift
@MainActor @Observable final class GolemListener: NSObject {
    static let pauseKey = "golemTalkPause"; static let pauseRange = 0.5...3.0; static let defaultPause = 1.0
    var pause: TimeInterval { get set }           // persisted in AppPreferences.defaults
    var giveUp: TimeInterval                      // 8 (manual) or 30 (conversation); set by GolemTalk
    private(set) var listening: Bool              // an utterance is being captured
    private(set) var engineRunning: Bool
    private(set) var heard: String                // current utterance transcript
    private(set) var problem: String?
    var onTranscript: ((String) -> Void)?         // partial text for the draft (words only; prefix handled by GolemTalk)
    var onSpeechDetected: (() -> Void)?           // first word of an utterance (barge-in hook)
    var onUtterance: ((String) -> Void)?          // pause reached: final words ("" when nothing heard before giveUp)
    var onFailure: ((String) -> Void)?            // user-facing message (keep today's kLSRErrorDomain 201 text)
    func warmUp() async                           // permissions + engine start (idempotent)
    func beginUtterance()                         // new recognition request on the running engine
    func cancelUtterance()                        // drop current words, keep engine
    func stop()                                   // engine down
}
```

`GolemTalk` keeps: `reads`, `listens`, `conversationActive`, `problem` (merged from both), `isOpen`, `follow()`, Shortcuts request loop, `toggleMute`, `toggleListening`, `stop()`, the typed-text guard (compares `dot.draft` to `prefix + heard`), and sending.

## Lane A — VS-02 Streaming speaker (Claude Sonnet 5.5, high)
Goal: speech starts on the first finished sentence of a streaming reply and keeps up with it.

Requirements:
1. **Segmentation.** From the full text so far, take the unspoken remainder, clean it with `spoken(_:)`, and cut complete sentences: a run ending in `.`, `!`, `?`, `…` (optionally followed by a closing quote/paren) and then whitespace/newline, or a paragraph break. Merge consecutive short sentences up to ~240 characters; never split inside a sentence; a very long sentence (> 600 chars) is cut at the last comma/semicolon before 600. When `final` is true, whatever remains (even without punctuation) is the last segment. The existing length cap (`spokenLimit` 4000 + "The rest is on screen.") applies to the whole reply.
2. **Pipeline.** Ordered queue; fetch segment N+1 (and N+2) while N plays; never more than 2 fetches in flight; play strictly in order; if a fetch fails, fall back to the Mac voice for that segment and the rest (set `problem` as today: "ElevenLabs: … Using the Mac's voice."). Mac-voice fallback also speaks per segment (enqueue utterances).
3. **Text revisions.** Streaming text is append-only in practice; if `text` no longer starts with what was already consumed, log and continue from the longest common prefix — never re-speak.
4. **Stop/cancel.** `stop()` cancels in-flight fetches and playback, clears the queue, and ignores later `update` calls for that reply id until a new id arrives. `onFinished` fires only when the final segment finished playing after `final == true`.
5. **Latency.** First fetch starts ≤ 200 ms after the first sentence completes (fixture measures via a stub provider recording request times). No artificial delays.
6. `lastSpoken.engine` = "ElevenLabs (streamed)" or "This Mac's voice". Keep OSLog category "Conversation"; log segment counts, never text.
7. Keep `ElevenLabs` enum (key from Chatterbox Secrets, `speech(_:key:)` using `ElevenLabsSpeechSettings.payload`, `voices`, `check`, `Failure`) as the production `SpeechProvider`; `chunks(_:)` can be removed once segmentation replaces it.

Fixture `tests/golem-voice/speaker/main.swift` (stub provider returning a tiny valid WAV generated in-process, with a configurable delay):
- feed text in 5 increments over ~1 s with `final: false`, then `final: true`; assert first request ≤ 200 ms after the first terminal punctuation; assert requested segments equal the expected cut; assert playback order; assert ≤ 2 in flight.
- `stop()` mid-way: no further requests, `onFinished` not called.
- `final` text without punctuation speaks once.
- provider throws on segment 2 → Mac voice used for 2..n (assert `lastSpoken.engine` and `problem`).
- `spoken(_:)` cases from the existing talk fixture (markdown/link cleaning).

## Lane B — VS-03 Warm listener, barge-in, pause (Claude Sonnet 5.5, high)
Goal: the mic stays live through a conversation; speech is noticed immediately; the send pause is configurable.

Requirements:
1. **Warm engine.** `warmUp()` requests permissions (as today), creates one `AVAudioEngine`, validates input format (today's "No microphone input is available…" message), tries `inputNode.setVoiceProcessingEnabled(true)` (ignore/log failure), installs one tap with `format: nil`, starts. Idempotent. `stop()` tears it down. The tap forwards buffers to whichever recognition request is current (thread-safe box).
2. **Per-utterance recognition.** `beginUtterance()` creates an `SFSpeechAudioBufferRecognitionRequest` (partial results, punctuation, on-device when supported) and a task on the running engine; no engine restart. On pause → `onUtterance(words)`, then end that request; the next `beginUtterance()` reuses the engine. Rotate the request proactively if a single request is open > 50 s with no words (Apple caps tasks around a minute); record observed behavior in the completion report.
3. **Pause detection.** Watcher at 100 ms: when words are non-empty and quiet ≥ effective pause → `onUtterance`. Effective pause = `pause`, or `min(pause, 0.7)` when the transcript ends in `.`, `?` or `!`. When nothing was heard for `giveUp` → `onUtterance("")`.
4. **Barge-in hook.** `onSpeechDetected` fires once per utterance at the first partial with ≥ 1 word of ≥ 2 letters (headphones tuning). Expose `bargeInMinimumWords` (default 1) for later tuning.
5. **Setting.** `pause` persisted under `golemTalkPause`, clamped to 0.5…3.0, default 1.0. `GolemListenerSettings` SwiftUI view: label "Send after a pause of", value "1.0 s", slider 0.5–3.0 step 0.1, caption "Sends sooner after a finished sentence." (coordinator inserts it into Settings → Voice).
6. **Errors.** Keep today's messages: kLSRErrorDomain 201 → Dictation disabled text; others → "Listening stopped: … Try Conversation again." via `onFailure`.
7. Logging: "Microphone started" once per `warmUp`, "Transcription updated: N characters", never text.

Fixture `tests/golem-voice/listener/main.swift` — no real microphone: drive the listener through an injectable recognition source (`RecognitionSource` protocol with a fake that emits partial transcripts) so the pause/shorten/barge-in/rotation logic is tested without audio hardware; assert two utterances complete with `engineRunning` true throughout and one "started" event; pause default 1.0, persisted via isolated defaults, terminal punctuation shortens; `onSpeechDetected` fires once at the first word; `cancelUtterance` drops words and keeps the engine. (Permissions/engine start paths are exercised live in VS-04, not in the fixture.)

## Coordinator — VS-04 integration
- `follow()` observes the latest assistant item (including `phase == .streaming`) and calls `speaker.update(reply:text:final: !dot.isRunning)`; commentary/tool items excluded as today; replies present at launch stay silent; nothing spoken unless `reads || conversationActive` and `isOpen`.
- When speaking starts in a conversation, `listener.warmUp()` + `beginUtterance()` run concurrently so barge-in works; `onSpeechDetected` while `speaker.speaking` → `speaker.stop()` (log "barge-in"); the utterance continues and sends on pause.
- `onUtterance(words)`: if words empty → today's "No speech was recognized…" pause of the conversation; else clear the draft and `dot.send(prefix + words, attachments:)` — also while `dot.isRunning` (sends as an addition). Then, if `conversationActive`, `beginUtterance()` again immediately (warm mic across turns); the 300 ms post-speech delay is removed (voice processing + barge-in guard replace it).
- Typed-text guard, mute (`reads=false` → `speaker.stop()`, listener unaffected), `isOpen` watcher (minimize → stop all), Shortcuts request loop, `lastSpoken`, `problem` merge, settings composition, footer sentence: "Talk over him to interrupt."
- End-to-end fixture `tests/golem-voice/conversation/main.swift` with stub provider + fake recognition: streaming reply → first segment → fake speech → speaker stopped → utterance sent → `dot.items` gains the user message → next reply streams → spoken. Plus the migrated `talk` and `buttons` fixtures.
- One real smoke (user-approved spend): Debug build via Launch Services, Conversation button, confirm first words < 1.5 s and barge-in.

## Completion report (each lane)
Branch and head SHA; files changed; fixture command and its full output; build result; any interface deviation from the shapes above (exact signatures); observations on the open questions (recognition request lifetime, voice processing support); anything left undone and why. Do not open PRs; the coordinator does.

## Exclusions (all roles)
iPhone, Core, ElevenLabs WebSocket, VAD, give-up timers, push, Shortcuts intents, Chatterbox; installing over `/Applications`; any paid speech call; committing another session's uncommitted changes (there are none in this repo at baseline — verify with `git status`).
