# iPhone Golem header and message colors

User approved the reference-led layout and configurable outgoing bubble colors, and explicitly requested implementation. Linear/current session under previous model-identification waiver. Preserve voice loop, composer Send/text/attachments, pairings, keys and neutral assistant replies.

Implemented in ChatDetailView.swift: fixed top avatar/name/live status, removed lower avatar, permanent composer, compact working indicator, outgoing color and automatically selected black/white text. GolemAppearance.swift adds per-device AppStorage RGB preference, five presets, custom opaque color and preview. GolemMobileApp.swift registers Appearance settings and isolated DEBUG inspection entry. Xcode project regenerated.

Both simulator and signed iPhone builds passed; diff checks passed. Actual simulator chat with both message directions and Appearance form visually inspected. Evidence: assets/golem-chat-header/chat.png and appearance.png. No speech tests/credits. Physical user acceptance pending. Source uncommitted; no push. Install in place preserves app data; rollback by reinstalling prior build without deleting data.

Follow-up: removed composing-driven tab-bar hiding in MobileHome.swift. Golem/Journal/Settings stay visible with the composer above them. Simulator launched with composing=true and screenshot inspected: assets/golem-chat-header/composer-with-tabs.png. Both iOS builds passed and installed/launched on iPhone 17 Pro.

Seamless follow-up approved by Do it all: replace header material with the same system background as chat, hide navigation-bar material, and overlay a 24-point transparent gradient over the upper transcript edge. No divider. Avatar/name/status remain fixed; composer and bottom tabs retained. Simulator and device builds passed, seamless.png inspected, installed on iPhone 17 Pro. No microphone/TTS tests initiated.

Avatar-only follow-up: removed the Golem name and Ready/listening/working status text from conversationHeader in Core/ChatterboxMobile/ChatDetailView.swift. Avatar and seamless fade retained. Simulator and device builds passed; Core diff check passed. Inspected assets/golem-chat-header/avatar-only.png: header text absent, composer and bottom tabs visible. Installed updated signed build on iPhone 17 Pro. No speech tests; no commit or push.

Toolbar avatar revision: user authorizes moving avatar into top-leading navigation toolbar, removing dedicated header. Preserve composer/tabs and all pending work. Linear execution under existing waiver. Acceptance: device/simulator builds, inspect screenshot, install phone; no commit/push.

Completed toolbar avatar revision: both builds passed (/tmp/golem-toolbar-device.log and /tmp/golem-toolbar-sim.log). Inspected actual simulator screenshot assets/golem-chat-header/toolbar-avatar.png: avatar at top left aligned with menu row, dedicated header gone, composer and three tabs visible. Updated app installed and launched on iPhone 17 Pro. No commit/push.

Stop-slot follow-up: Stop replaces Send while Golem runs, with matching 34-point symbol and 44-point hit area. Ordinary chat queue controls retained. Both builds passed; stop-replaces-send.png inspected with a running fixture; installed on iPhone. UI and its voice/settings dependencies pushed separately from pending orchestrator changes.
