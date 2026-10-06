# ElevenLabs speaking speed

Approved scope: simple persistent speed control in Mac and iPhone Voice settings, 0.7–1.2 with default 1.0. Both current TTS paths previously sent text/model only. Each paragraph and prefetch now uses one shared payload builder with `voice_settings.speed`. Existing endpoints, models, key access, playback and native fallback are preserved.

Execution: linear/current session under previously accepted model-identification waiver; implement and install iPhone authorized. No paid speech test, commit, push, or Mac activation.

- [x] Inspect Mac/iOS request and AppPreferences paths.
- [x] Shared clamping/default/payload builder and persistent per-device settings slider.
- [x] Offline Swift test covers default, persistence, boundary/intermediate speeds, invalid values, JSON nesting and unchanged text/model.
- [x] Inspect simulator Voice settings and native Mac control render.
- [x] Final Mac, simulator, and device builds passed; updated iPhone 17 Pro app installed successfully.

Validation command:
`swiftc Core/Shared/AppPreferences.swift Core/Shared/ElevenLabsSpeechSettings.swift tests/voice-speed/main.swift -o /tmp/golem-speed-payload-test && /tmp/golem-speed-payload-test`

Builds: Golem (build/SpeedMac), GolemMobile device (build/ConversationDevice), GolemMobile simulator (build/ConversationButton). Screenshots: [iPhone settings](assets/voice-speed/iphone-speed-settings.png), [native Mac control fixture](assets/voice-speed/mac-speed-control.png). Mac screenshot is an isolated NSHostingView render of the actual shared control, not installed-app acceptance. iPhone uses a DEBUG-only Voice settings launch entry and isolated preferences.

Rollback: revert this task's source edits and rebuild/reinstall in place without removing pairing, keys or app data. The new local preference can remain safely unused. Existing conversation feature work remains separate and uncommitted.

No speech network calls were initiated for testing. Mac app was built, not installed or relaunched. No commits or pushes.
