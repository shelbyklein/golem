# Mac Conversation microphone fix

User reports crash on mic and asks where Conversation is. Existing linear workflow; no commit/push.

Evidence: unified log 2026-10-05 20:54:43, Golem PID 60169: AVAudioEngine InstallTapOnNode throws Failed to create tap due to format mismatch: hardware 1 channel 24000 Hz, client 1 channel 48000 Hz. Stack points to GolemTalk.startListening. Installed usage descriptions present. No new diagnostic crash report; observed exception evidence rather than claiming a captured process crash.

Fix: fresh audio engine per listen; tap format nil negotiates device format, validates available input. Pending permission/start and recognition callbacks guarded by capture generation. Explicit Conversation/End Conversation state spans listen/send/reply, controls on mini and window; ending cancels playback/listening and preserves draft. New reply preserves active session through playback cleanup. Silent timeout ends session.

Build passed, diff checks passed. Signed app verified and installed at /Applications/Golem.app with backup under Golem-InstallBackups/microphone-fix-20261005-205744. Launched PID 62137. Background golemd PID 82657 retained. Live audio/route switch and UI screenshot not verified: native computer-use pipe startup failed. No paid speech test, credentials, commits, or pushes.

Follow-up crash at 20:58:18 PID 62137: TCC terminated app reporting missing NSSpeechRecognitionUsageDescription. Installed and built Info.plist both verified to contain microphone and speech descriptions. Previous activation executed binary directly from agent-host ancestry; suspected privacy attribution issue, not verified by an attribution log. Relaunched through Launch Services via open with CHATTERBOX_/GOLEM_ env stripped, PID 63049 parent launchd. No new code/install, no privacy reset. Live button retest pending.

Confirmed cause of immediate recognition stop: localspeechrecognition logs at 22:28:10 and 22:28:11 explicitly report kLSRErrorDomain 201, Siri and Dictation are disabled. Added actionable message for this code and persistent error labels in expanded mini and full chat (no hover required). Build/diff/signature checks passed; installed and relaunched through Launch Services. Native visual inspection unavailable. User directed to enable Keyboard > Dictation; no system settings changed. No commit/push.

Voice-send draft clearing: mini local @State copy only synchronized while listening; voice send clears canonical draft and ends listening in same update, skipping local clear. Replaced local draft/attachments with direct session-backed bindings. Build, diff check and signed installation passed. Relaunched via Launch Services. Live voice-send retest pending, no paid speech tests or commits/pushes.

Full-window transcription display: ChatView only propagated local draft outward, missing voice writes. Added Golem-only inward synchronization modifier, guarded by old-value equality to preserve pending typing. Logs record microphone start and transcription character counts, no text. Build/diff/signature checks passed; installed and relaunched. Live microphone and UI verification pending. No commit/push.

Conversation continuity follow-up: discovered draft and attachments were ObservationIgnored, undermining prior voice display sync. Enabled observation only in GOLEM_APP builds, leaving Chatterbox typing behavior unchanged. Explicit conversation waits 30 seconds for initial speech instead of 8, retains 1.5s send pause; silent timeout and blocked-by-draft now surface explanation. Added reply-finished and stop diagnostics, no speech content. Mac build/diff/signature passed; installed/relaunched. Exact cause of user one-turn symptom remains unconfirmed pending live second-turn test. No paid tests, commit, push.
