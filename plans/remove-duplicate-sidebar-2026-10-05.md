<!-- remove-duplicate-sidebar-2026-10-05 -->
# Remove duplicate Golem sidebar

The full Golem window supplies GolemSidePanel as a leading sidebar while ChatView also supplies it as the trailing inspector. User explicitly requested removing the left copy. Before: activity | chat | activity. After: chat | activity.

Linear execution in this session; no delegation or model override. Scope: remove GolemRoot leading panel and retain standalone Golem window columns/inspector with no inline duplicate avatar. Preserve Chatterbox sidebar behavior, embedded chats, mini, drafts, services and data. No open design decisions.

- [x] Remove leading panel and preserve trailing inspector.
- [x] Build Golem, install with backup, inspect rendered full window for exactly one activity panel on the right.

Validation: native build and installed screenshot; this is a low-impact layout change, no new unit test. Rollback: restore backed-up app or revert scoped view changes. Implementation authorized by direct request.

Verified installed full window with native screenshot: no leading sidebar; one trailing activity panel with avatar, Needs You and Recent. Toolbar panel toggle works. Build/signature passed. Backup: ~/Library/Application Support/Golem-InstallBackups/single-sidebar-20261005-104012/Golem.app. Source changes uncommitted. Issue: https://github.com/shelbyklein/golem/issues/4.

Follow-up user requests: opening mini hides full chat and vice versa; full window starts with avatar/status and no selected activity tab. Implemented local optional tab selection, click-again deselection, and standalone panel reset. Installed screenshot confirms quiet right panel; native Activity select/deselect verified. Dedicated window-mode fixture passed at /tmp/golem-mini-fit.lvjdxbpx. Full legacy mini fixture still intermittently fails short-reply baseline height; not claimed fixed here.
