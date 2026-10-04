# Golem

Standalone Mac assistant app, universal iPhone/iPad client and `golemd` service. Source extracted from Chatterbox 308c681; original history remains in shelbyklein/chatterbox. The rig, icons, app entrypoints and assistant service are owned here. Common UI/engine/mobile/protocol source is pinned in the `Core` submodule (a source package compiled using GOLEM_APP/CHATTERBOX_HEADLESS, not a SwiftPM module).

```sh
git clone --recurse-submodules https://github.com/shelbyklein/golem.git
cd golem
./scripts/bootstrap.sh
xcodebuild -project Golem.xcodeproj -scheme Golem -derivedDataPath build/GolemPlan build
xcodebuild -project Golem.xcodeproj -scheme GolemMobile -sdk iphonesimulator -derivedDataPath build/Mobile CODE_SIGNING_ALLOWED=NO build
```

Requires Xcode and XcodeGen. Existing Chatterbox daemon supplies authenticated conversations; no sibling checkout is needed to build. Existing bundle IDs, user data, pairing, permissions and sockets are unchanged. Building does not install/start services or reactivate paused automation. Do not launch an old legacy writer against daemon-owned data. Shared-source changes must be committed in chatterbox-core and pinned/tested in both app repositories. Compatibility symlinks point within this checkout only.

Mac installation replaces the UI bundle only after backup. Mobile provisioning and real Golem pairing/APNs remain separate acceptance steps, not implied by a build.
