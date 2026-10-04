# Legacy combined UI baseline

Revision: `03b4bf371748d7ff90bd23fa2eb1770796f391b6`. Fixture: seeded-240-pairs-3-chats-live-rig. All data and ports isolated; automation disabled; no providers resumed. `scripts/test-golem-baseline.sh` uses a supplied idle rig beside production ContentView and three seeded ordinary chats, each with 240 user/reply pairs.

Three 60-second idle runs: 6.05%, 6.47%, 5.43% process CPU. Chat switch median 24.29 ms; p95 25.94 ms. Raw samples and stall totals: baseline.json. This is reproducible combined UI cost, not an attribution of the installed app's earlier 82% snapshot.

## Ownership reconciliation
Main finished its mini-hover acknowledgment work as commit `7f45863`; cherry-picked intact as `03b4bf3` in the isolated golem worktree. Main is now clean. No daemon code or matching daemon issue found in the checked repository; current ChatterboxHost only supervises raw processes. Other worktrees and live helpers are left alone.

## Extraction map
- Conversation ownership: AppModel persistence/load/host acknowledgment -> ConversationRuntime, sole daemon writer.
- Provider state: ChatSession, ClaudeCode, CodexAppServer, HostClient -> shared Foundation runtime, preserving parsing/replay.
- UI effects: AppKit lifecycle, diagnostics screenshots, Attention watching/badges, window state -> Chatterbox/Golem UI adapters.
- Assistant jobs: DotActivity, EmailWatch, GolemJournal -> Golem service.
- Companion/MCP: UI-dependent CompanionServer -> daemon gateway adapters.
- Animation: GolemRigView, avatar cache, mini -> Golem targets only.
- Mobile: MobileHome/MobileGolem/assistant layout -> separate GolemMobile; ordinary chat client keeps IDs/pairing.

No legacy headless conversation runtime exists to benchmark; final headless service measurements are required in GOLEM-08. Foundation compile verifies UI imports can be excluded, not provider behavioral acceptance.
