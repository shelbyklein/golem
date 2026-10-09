#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Golem.xcodeproj -scheme Golem -configuration Debug -derivedDataPath build/GolemPlan build -quiet
build=build/GolemPlan/Build/Products/Debug/Golem.app
backup=$(mktemp -d /tmp/golem-before-install.XXXXXX)
if [[ -d /Applications/Golem.app ]]; then ditto /Applications/Golem.app "$backup/Golem.app"; fi
osascript -e 'tell application "Golem" to quit' 2>/dev/null || true
for i in {1..20}; do
 if ! ps -axo command | grep -Fxq /Applications/Golem.app/Contents/MacOS/Golem; then break; fi
 sleep .25
done
if ps -axo command | grep -Fxq /Applications/Golem.app/Contents/MacOS/Golem; then echo 'Golem UI did not exit; retaining installed bundle.' >&2; exit 1; fi
# Running golemd is not restarted; no launch agents/settings/data are changed.
rm -rf /Applications/Golem.app
ditto "$build" /Applications/Golem.app
codesign --verify --deep --strict /Applications/Golem.app
# Golem is phone-only unless golemDesktop is on; opening the app then just refreshes and quits.
if [[ "$(defaults read com.shelbyklein.Golem golemDesktop 2>/dev/null)" == 1 ]]; then open /Applications/Golem.app; fi
echo "Installed Golem UI. Backup: $backup/Golem.app; background services unchanged."
