# Installed Mac development trial — 2026-10-04

User authorized the switch after waiting for main and requiring the worktree merge. Main and Golem source were reconciled and pushed at `91809cf64be5eed47a1596b22767c241ab15fb25`; PR #32 is merged. Installed optimized Debug Mac bundles correspond to that revision.

Verified installed evidence:
- Both installed apps pass deep/strict code-signature verification and per-file staged manifest hashes.
- Graceful legacy UI quit preserved provider processes. The verified unchanged host writer was suspended only during the offline snapshot, then resumed for daemon reattachment.
- Private backups include the old installed app(s), preference domains, data, assistant, host, Claude memory, hash manifest and all 58 UI draft projections. All drafts were empty at the switch. Offline backup hashes and unchanged conversation file hashes were checked before services started.
- Both user LaunchAgents run from stable /Applications paths. chatterboxd health/readback contains all 58 original conversation UUIDs. golemd state is durably paused; its signed Golem UI transport reports connected and paused. Existing provider host/session continuity was observed in this very chat after cutover.
- Installed Chatterbox and Golem signed UI transports both report connected. Native installed captures were inspected locally. They contain private chats and are deliberately excluded from this public repository.
- Golem interface quit/reopen left both services running and reconnected. Restored window state initially produced no visible Golem window; reopening once with ApplePersistenceIgnoreState YES restored the actual interface.
- No new provider test turn, automation resumption or real push delivery was requested. Offline rollback fixtures pass; an actual live rollback was not performed.

Main regressions passed: native Home, Command Center, Sidechat, Studio conversion, Restart Thread and mini controls; colored terminal behavior/startup and inspected native render. Terminal capture uses view bitmap caching because ScreenCaptureKit capture failed in the unsigned test harness; no app behavior changed.

Remaining acceptance: physical mobile provisioning/pairing/APNs, full iPad rotation/multitasking, VoiceOver, RSS/wakeup/energy/real workload, a new approved real headless test turn and live rollback rehearsal. Original CPU fixture passed narrowly before main integration; full combined performance was not remeasured for this installed revision. Issue #31 remains open.
