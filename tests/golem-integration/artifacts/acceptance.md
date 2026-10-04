# Switch checkpoint evidence

Optimized signed Mac apps are staged in `build/GolemReview/Apps`. The backed-up Mac development switch is now installed at revision 91809cf with Golem automation paused; see installed-verification.md. Physical pairing, new provider test turns and real APNs remain pending.

Verified:
- Foundation conversation runtime: fake Claude/Codex turns, questions, denial, steering, stop, queue, replay, single-writer lock, drafts and receipt retries with UIs absent.
- RPC role boundaries, metadata forgery rejection, integration revocation, cursor replay/resync and durable crash uncertainty. Genuine signed Golem connects as golem-ui without a trust override and cannot claim Chatterbox ui privileges.
- Native Chatterbox projection reconnects without duplicate rows/providers and preserves drafts. Headless companion/MCP contracts and independent mobile product pairing/scopes pass.
- Golem scheduling, waiting/finished/email policies, durable receipts, pause, successful stop and crash recovery fixtures pass with UIs absent.
- Mac external plugin launch/revocation, mini controls and conversation rendering pass. Connected, disconnected, disabled, reduced-motion and size captures were inspected.
- iPhone and iPad simulator tests pass for both apps, conversation controls, journal, settings, pairing/revocation, links, keyboard, large text and offline/reconnect. Chatterbox retains its mobile bundle identity and ordinary chat UI. Adaptive iPad sidebar inspected.
- Offline adoption/retry/hash/restore with additive recovery passes. Isolated LaunchAgents recover crashes and retain successful stop. App-specific APNs/JWT/topic/privacy fixtures and delayed notification read suppression pass.
- Ordinary chat regression suites passed as recorded in the implementation handoff. Final optimized Mac builds and staged deep/strict signature verification pass.
- Accepted CPU fixture narrowly meets the combined visible budget: 6.627% versus 6.652%; all three hidden samples recorded zero draws. Chat switching median/p95 improved in the fixture. See performance-report.md and golem-animation-performance-schedule.json.

Remaining acceptance:
- Physical iPhone/iPad provisioning, pairing and real push delivery remain GOLEM-09 work.
- Full physical iPad rotation/window multitasking and VoiceOver remain unverified. Simulator orientation commands did not establish a landscape window despite historical capture filenames.
- RSS/wakeup, physical-device energy and real-provider workload comparisons remain unverified. CPU results do not establish these properties.
- GOLEM-06 and GOLEM-08 remain review pending for these limits; criteria have not been waived. GOLEM-07 source fixtures pass; real push is gated separately.
- Mac adoption/installation and signed UI/service readback are verified. Remaining GOLEM-09 physical/provider/rollback criteria are pending. See installed-verification.md and plans/golem-activation.md.
