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
