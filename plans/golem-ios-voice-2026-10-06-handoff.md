# Handoff: Golem iPhone voice — streaming speech, talk-over, warm mic, pause

Plan: [golem-ios-voice-2026-10-06.md](golem-ios-voice-2026-10-06.md). Issue: see plan header.

## Roles and models
- **Coordinator / integration owner:** Claude Opus 5.5 (`claude-opus-5-5`), this session. IV-01, IV-04, IV-05, plan, issue.
- **Lane A (speaker, IV-02):** Claude Sonnet 5.5 (`claude-sonnet-5-5`).
- **Lane B (listener + audio session, IV-03):** Claude Sonnet 5.5 (`claude-sonnet-5-5`).

## Repositories, baseline, worktrees
- Golem: shelbyklein/golem, branch `claude/golem-ios-voice` (IV-01 commit). Core: shelbyklein/chatterbox-core, branch `claude/golem-ios-voice` (IV-01 commit, from Core `main` `076fe5e`). The Golem branch pins `Core` to the Core IV-01 commit.
- Each lane gets its own Golem worktree under `/Users/shelbyklein/Vibes/Golem/.claude/worktrees/ios-<lane>` on Golem branch `claude/golem-ios-voice-<lane>`, with `Core` checked out on Core branch `claude/golem-ios-voice-<lane>` (both from the IV-01 commits). The coordinator creates them. **Do not run `git submodule update`** (the configured submodule URL is a stale local mirror); Core is already checked out. Commit Core changes inside `Core/` and push the Core lane branch to `origin` (GitHub). Do not commit the Golem pin; the coordinator repins.
- Build (from the lane's Golem worktree root): `env -u CHATTERBOX_DATA_DIR xcodebuild -project Golem.xcodeproj -scheme GolemMobile -sdk iphonesimulator -derivedDataPath build/IOSVoiceSim CODE_SIGNING_ALLOWED=NO build` (several minutes). Run `xcodegen generate` first only if you add a file; never commit `project.pbxproj` (Core folders are globbed, so new files under `Core/ChatterboxMobile` and `Core/Shared` are picked up).
- Logic fixtures: `scripts/test-golem-ios-voice.sh <name>` compiles `tests/golem-ios-voice/<name>/main.swift` together with the Core paths listed one per line in `tests/golem-ios-voice/<name>/sources` (relative to the Golem worktree root, e.g. `Core/Shared/SpeechSegments.swift`) with plain `swiftc` on macOS and passes when it exits 0 printing `PASS …` lines. Only Foundation-only files can be listed.
- No device installs, no paid ElevenLabs calls, no launching apps on the user's devices, no changes to Mac Golem (`GolemApp/`, `GolemService/`, `Core/Chatterbox/**`), no force-push, no rebase, no other branches.

## File ownership
| File | Owner |
|---|---|
| `Core/Shared/SpeechSegments.swift` (new), `Core/ChatterboxMobile/GolemVoice.swift`, `tests/golem-ios-voice/segments/*` | Lane A |
| `Core/Shared/UtterancePause.swift` (new), `Core/ChatterboxMobile/Dictation.swift`, `Core/ChatterboxMobile/GolemAudioSession.swift`, `tests/golem-ios-voice/pause/*` | Lane B |
| `Core/ChatterboxMobile/ChatDetailView.swift`, `GolemVoiceSettings` struct inside `GolemVoice.swift` (coordinator edits it after Lane A merges), `scripts/*`, `project.yml`, pbxproj, plans | Coordinator |

Lane A must not edit `GolemVoiceSettings` beyond what its own changes require; if `GolemVoice`'s settings need a new row, report it. Need another file? Stop and report.

## Interfaces fixed by IV-01
```swift
// Core/ChatterboxMobile/GolemAudioSession.swift (exists; Lane B owns the implementation)
@MainActor final class GolemAudioSession {
    static let shared: GolemAudioSession
    var headphonesConnected: Bool { get }
    func beginPlayback(); func endPlayback()        // counted
    func beginCapture() throws; func endCapture()   // counted
}
```
`GolemVoice.activate()/deactivate()` and `Dictation.start/stop` already call it (one hold each).

Lane A adds to `GolemVoice` (keep all existing members working: `speak(_:text:then:)`, `toggle`, `stop`, `speakingID`, `problem`, `autoRead`, `listensAfter`, `voiceID`, voices/key API, `static spoken(_:)`):
```swift
/// Streaming entry: the reply's full text so far; `final` once its turn ended. `then` as in speak(_:text:then:):
/// runs only if the reply was read to the end (final received and queue drained), never after stop().
func update(reply id: UUID, text: String, final: Bool, then: (() -> Void)? = nil)
```
Lane B adds to `Dictation` (keep `start(pause:giveUp:onPause:onText:)` and `stop()` behaving as today for the plain composer path):
```swift
static let pauseKey = "golemTalkPause", pauseRange = 0.5...3.0, defaultPause = 1.0
var pause: TimeInterval { get set }               // persisted in AppPreferences.defaults, clamped
var bargeInMinimumWords: Int                      // 1 with headphones, 2 on the speaker (set from GolemAudioSession)
private(set) var conversationActive: Bool         // engine + session held across utterances
func startConversation(giveUp: TimeInterval, onSpeechDetected: @escaping () -> Void,
                       onUtterance: @escaping (String) -> Void,       // "" when nothing heard before giveUp
                       onText: @escaping (String) -> Void) async -> Bool // false with `problem` set
func nextUtterance()                              // new recognition request on the running engine
func cancelUtterance()                            // drop words, keep engine
// stop() ends everything (also ends a conversation)
```
plus `struct DictationPauseControl: View` (label "Send after a pause of", value "1.0 s", slider 0.5–3.0 step 0.1, caption "Sends sooner after a finished sentence.").

## Lane A — IV-02 Streaming speaker
1. `Core/Shared/SpeechSegments.swift` (Foundation-only, no `@MainActor` needed): `enum SpeechSegments { static func cut(_ rest: String, final: Bool) -> (segments: [String], consumed: Int); static func merge(_ sentences: [String], limit: Int = 240) -> [String] }`. Sentence end = `.`, `!`, `?`, `…` (optionally followed by a closing quote/paren) then whitespace/newline, or a paragraph break; not after `Dr Mr Mrs Ms vs e.g i.e` or a 1–3 digit list number at line start. A sentence over 600 characters is cut at its last comma/semicolon (else last space) before 600. With `final`, the remainder is a segment. Port the logic from Mac `GolemApp/GolemSpeaker.swift` (`cut`/`merge`, in the golem repo on branch `claude/golem-voice-streaming`; read with `git -C /Users/shelbyklein/Vibes/Golem show origin/claude/golem-voice-streaming:GolemApp/GolemSpeaker.swift`), adapted to work on `String`.
2. Cleaning: segment the **raw** markdown into sentences first only if that's safe; otherwise clean the whole text so far with the existing `GolemVoice.spoken(_:)` (it reads tables row by row and names links — keep that behavior) and segment the cleaned text, tracking consumed characters of the cleaned text. Pick the approach that never re-speaks or skips text when more text arrives; document it. Keep the 5000-character cap with "The rest is in the chat."-style tail (current `spokenLimit`).
3. `update(reply:text:final:then:)`: new id → stop previous, start fresh; same id → append; ordered queue; ≤ 2 ElevenLabs fetches in flight; play strictly in order; a fetch failure falls back to the phone's voice (`AVSpeechSynthesizer`) for that segment and the rest, setting `problem` as today ("ElevenLabs: … Using the phone's voice."). Without a key, every segment uses the phone's voice. `stop()` cancels fetches, playback and the queue, and further `update`s for that id are ignored until a new id. `speakingID` = the reply being read. Hold the audio session (`activate()`) for the whole reply and release it when the reply finishes or stops. `speak(_:text:then:)` = `update(final: true)`.
4. Logging: counts only, never text.
5. Fixture `tests/golem-ios-voice/segments/main.swift` + `sources` (`Core/Shared/SpeechSegments.swift`): sentence cuts, abbreviations, list numbers, quotes/ellipsis, paragraph breaks, long-sentence cut, merge ≤ 240, incremental feeding (text arriving in 5 pieces yields the same segments as all at once, nothing repeated or lost), `final` remainder.
6. Build GolemMobile for the simulator.

## Lane B — IV-03 Warm listener and shared audio session
1. `Core/Shared/UtterancePause.swift` (Foundation-only): pure state machine `struct UtterancePause { init(pause:giveUp:minimumWords:); mutating func heard(_ text: String, at: Date) -> Bool /* true once: barge-in */; func due(at: Date) -> Outcome? /* .send(words) after the effective pause, .silent after giveUp */ ; static func effectivePause(_ pause: TimeInterval, after: String) -> TimeInterval }` — effective pause = `pause` or `min(pause, 0.7)` after `.`/`?`/`!`; qualifying word = ≥ 2 letters; barge-in after `minimumWords` qualifying words; also a `shouldRotate(openedAt:now:)` for empty requests > 50 s.
2. `GolemAudioSession` real implementation: when capturing (with or without playback): `.playAndRecord`, mode `.default`, options `[.allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]` (no `.allowBluetooth`/HFP), then `setPreferredInput` to the built-in microphone port when present; playback-only keeps today's `.playback/.spokenAudio`. Switching categories while both are in use must not interrupt playback audibly: configure `.playAndRecord` once capture begins and keep it until both counts reach 0. `headphonesConnected` from the current route. Handle `AVAudioSession.routeChangeNotification` (re-prefer the built-in mic) and `interruptionNotification` (report via a callback Dictation can turn into `problem` + stop).
3. `Dictation` conversation mode per the interface: `startConversation` = permissions, `beginCapture()`, one `AVAudioEngine`, input voice processing enabled **only when not on headphones** (try/log failure), one tap (`format: nil`) feeding the current request via a thread-safe box, first utterance opened. `nextUtterance()` opens a new `SFSpeechAudioBufferRecognitionRequest` (partial results, punctuation, on-device when supported) without restarting the engine. Pause/barge-in/rotation via `UtterancePause` with a 100 ms watcher; `bargeInMinimumWords` = 1 on headphones, 2 otherwise. Errors keep today's messages (Golem/Chatterbox permission texts, "Speech recognition isn't available right now.", "Couldn't start listening: …"). `stop()` ends the conversation and releases the session. The existing `start(...)` path must keep working unchanged in behavior for the plain composer/dictation button.
4. `pause` persisted under `golemTalkPause` in `AppPreferences.defaults`, clamped; `DictationPauseControl` view.
5. Logging: "Microphone started" once per conversation, "Transcription updated: N characters", never text.
6. Fixture `tests/golem-ios-voice/pause/main.swift` + `sources` (`Core/Shared/UtterancePause.swift`): default/clamp of effective pause; terminal punctuation shortens; barge-in fires once at the first qualifying word (1-word and 2-word rules); `.send` after pause with words; `.silent` after giveUp; rotation rule. Time is injected (no sleeping needed).
7. Build GolemMobile for the simulator.

## Coordinator — IV-04 integration (after merging A then B)
- `ChatDetailView`: follow the latest assistant item **including** `isStreaming`; `GolemVoice.update(reply:text:final: !isStreaming && !summary.isRunning)`; when speaking starts in a conversation (or auto-read + listensAfter), `dictation.startConversation(...)` so the mic is live during speech; `onSpeechDetected` while speaking → `GolemVoice.stop()`; `onUtterance(words)` → send (also while running), then `nextUtterance()`; empty → end conversation as today; typed text guard; background/close ends everything; Shortcuts path uses `startConversation`.
- Settings: add `DictationPauseControl()` under "Then listen for my reply"; footer sentence about talk-over and the iPhone mic.
- Builds (simulator + device), `scripts/test-mobile-ui.sh iphone`, all logic fixtures, rendered Settings capture.

## Completion report (each lane)
Golem lane branch + Core lane branch and head SHAs; files changed; fixture command + full output; simulator build result; interface deviations (exact signatures); open-question observations; anything left undone and why. Don't open PRs.
