# Mini replies fit their message

Shelby asked for iMessage-like reply bubbles: show the entire message when screen space permits. The existing mini capped reply content at 140 points, regardless of available room, and required a manual expansion button. Preserve its visual style, hover protection, character/composer location, drafts and baseline saved size.

Linear execution: GPT-6.1 Sol, Medium effort, verified in active Chatterbox UI. Scope and implementation now authorized by direct request. Shared Core change in GolemMiniWindow.swift, parent pin and isolated regression fixture; no other shared files edited.

Flow: measured reply height -> temporary panel height capped to current screen -> full text, or scroll when oversized -> baseline height for next short reply. Screenshots: [short](../tests/mini-fit/artifacts/short.png), [medium](../tests/mini-fit/artifacts/medium-full.png). Runtime verification covers the real NSHostingView/layout, not a mockup.

- [x] Remove 140-point cap; content-driven temporary panel height with fixed lower anchor and bounded screen top.
- [x] Remove 8,000-character clipping; oversized content remains available by scrolling.
- [x] Verify short/medium/oversized, short-after-long, collapse/reopen, draft retention and avatar location using python3 tests/mini-fit/run.py against built signed Golem Debug module.
- [x] Build with current Core main, install backed-up app, inspect installed mini, commit/push Core and parent pin.

Acceptance: medium fixture rendered all 12 lines; baseline 420 points -> 550, oversized reaches screen cap, short returns to baseline; draft unchanged. Mechanical detector passed. Screenshots visually inspected. Rollback uses backed-up installed bundle; temporary heights do not overwrite baseline preferences. No transcript data migration.

Related operational change: project label saved as Golem Development; assistant remains Golem in its separate record and memory, verified via daemon readback.

Issue: https://github.com/shelbyklein/golem/issues/2. Core d53e339 pushed on current main; regenerated Xcode project to include upstream ProjectIcons source. Rebuilt successfully and repeated the isolated real-layout fixture, all checks passed. Installed /Applications/Golem.app with backup mini-content-fit-20261004-181435; neither background service restarted.

## Dismissal refinement

User requested a more graceful dismissal. Motion thesis: let the message disappear in place, preserving the reading position and Golem anchor; use a single 180ms opacity exit, then trim empty panel bounds without animation. Cancel pending dismissal on reopen; Reduce Motion skips the transition. No service restart required.

Implemented in shared mini controller/view. Built successfully; native fixture verifies unchanged panel bounds during fade, quick-reopen cancellation, completed collapse anchor, and existing content-fitting/draft behavior. Inspected midpoint and completed snapshots at `/tmp/golem-mini-fit.hs47w17o`. Installed backed-up UI at `/Applications/Golem.app`; backup `mini-dismiss-20261004-182245`. Opening was subsequently simplified to a 180ms opacity transition with immediate panel bounds; the normal size is preserved during synchronous layout. User accepted the installed result and authorized publishing/reconciliation.

Reconciled with Core upstream 345d0ab (Settings and chat reload fixes); combined Debug build and native regression fixture passed at `/tmp/golem-mini-fit.hh_1o7oq`. Core PR: https://github.com/shelbyklein/chatterbox-core/pull/1. The Golem pin and regression assertions land together. No automation or notification configuration changes.
