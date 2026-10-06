# Golem orchestrator model default

Shelby requests everyday Golem conversation/orchestration on Claude Haiku, with complex work delegated to appropriate worker chats; no worker defaults change. Add a Golem-specific provider/model default with explicit application to the existing assistant. Preserve pending mobile UI work, credentials, proxies, connected capabilities and the separate Codex email watcher.

## Evidence
- Claude initialize reports `haiku` resolves to `claude-haiku-4-5-20251001`, no supported effort knob.
- Real Haiku probe successfully called `list_chats`; no Gmail tools in init inventory or discovery. First text 10.124 s, completion 10.769 s (one cold CLI sample including tool setup, not a performance comparison).
- Runtime assistant is Codex `gpt-6-luna`, idle at inspection.
- AssistantConfiguration deliberately selects direct ChatGPT for Codex apps; Claude only gains chatterbox plus separately configured MCPs. EmailSweep independently runs Codex.

## Work preparation
Linear/current session; exact-model waiver accepted earlier. Implementation authorized, provider switch approved by Shelby: Do it all, explicitly including Haiku plus direct Codex app workers. No commit/push. Existing worker defaults must remain byte-for-byte unchanged. No global auth/proxy edits.

## Tasks
- [x] Verify model availability and actual tool inventory.
- [x] Implement Mac Settings > Golem model with provider, model, Save Default and Save and Apply; capability notice and busy guard.
- [x] Extend assistant creation/default handling for Claude without changing normal-chat defaults.
- [x] Draft assistant-specific concise routing/handoff guidance.
- [ ] Verify installed UI and persisted default round trip without switching provider prematurely.
- [x] User approved Haiku with Codex app workers.
- [ ] Activate selected settings and orchestrator instructions through owning service when safe; verify actual session backend, routing, progress and worker result handoff.
- [ ] Measure comparable runtime first-visible versus completion latency; no speedup claim until supported.

Flow: Settings choice -> explicit Save and Apply -> signed Golem UI RPC -> chatterboxd assistant settings only. Save Default alone changes future assistant defaults without altering existing chat. Separate worker chats retain their own providers/models. Visual verification uses native Golem Settings.

Rollback: back up installed Golem before UI replacement; preserve runtime model/default snapshot before switching; restore only assistant settings and prior app if needed. Shared runtime/instruction changes require chatterboxd build/idle activation, not merely Golem UI installation. No forced service restart during active replies.

Validation: Mac xcodebuild, diff checks, real read-only Claude/Codex capability probes (no mail contents), native settings UI inspection. Evidence files in work/orchestrator contain selected metadata only, not keys. Mobile UI changes preserved.

## Activation evidence
Signed Golem app installed with provider/model controls. Explicit debug activation through signed UI changed only assistant settings and Golem-specific defaults; runtime readback confirms claude/haiku/empty effort and saved defaults claude/haiku. Existing general/worker default values match pre-change snapshot. Worker 44830808-7243-44B7-BF18-0D55403E5C8D created with gpt-6-luna/low/direct/readOnly, separate from Golem. No broader default/auth/proxy changes. Native UI automation unavailable (Sky pipe startup failure), so installed model-controls screenshot is pending; SwiftUI build passed.

Chatterbox development chat notified to integrate only AssistantInstructions.swift and ConversationRuntime.swift and activate chatterboxd when idle, leaving all mobile/UI changes untouched. Existing process received same orchestration instructions in its authorized acceptance turn; compiled service activation remains separately tracked.

## Verified results
- Installed Golem Mac app with Golem-specific model/provider settings. Applied Haiku through signed app while assistant idle; readback claude/haiku/empty effort, persisted defaults claude/haiku.
- Global/worker model/effort/proxy defaults match before snapshot. Separate email sweep code unchanged.
- Live Golem handed off to Golem App Tools. Initial attempt used name instead of UUID and stopped before reading result; then worker asked for account. Corrected exact-UUID, Work-account request performed gmail.search_emails (done), final “Success; nonzero results.” Haiku read and reported the result, and the normal completed-worker callback reached Golem. Other apps (ClickUp/Google) only discovered, not exercised. No external writes/sends.
- Routing guidance now explicitly requires UUIDs, wait/read result, reuse direct app worker and established account label. Chatterbox session integrating/staging shared runtime guidance for idle activation; not yet claiming live service restart.
- Timing: initial real Haiku handoff first visible at 18.15 s, turn end 24.67 s, but that ended with “waiting” and is NOT completed end-to-end work. Earlier isolated CLI probes: Haiku list_chats 10.124/10.769 s; Codex tool discovery 3.964/6.234 s. Different work, not a speed comparison; no speedup established.
- iPhone seamless-header installed; launch blocked by locked phone. Screenshot seamless.png shows matching background, no divider/panel. Native Mac UI automation failed (Sky pipe), so no installed-settings screenshot this round.
