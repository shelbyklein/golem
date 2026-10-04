#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
kind=${1:-iphone}
case "$kind" in
 iphone) device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
 ipad) device_type=com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro ;;
 *) exit 2 ;;
esac
artifacts=$(mktemp -d "$PWD/build/mobile-ui.XXXXXX")
python3 tests/golem-integration/mobile-server.py > "$artifacts/server.log" 2>&1 &
server_pid=$!
simulator=$(xcrun simctl create "Golem split $kind" "$device_type" com.apple.CoreSimulator.SimRuntime.iOS-26-2)
trap 'kill "$server_pid" 2>/dev/null || true; xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true; echo "Mobile UI artifacts: $artifacts"' EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
xcodebuild -project Golem.xcodeproj -scheme GolemMobileAcceptance -configuration Debug -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "build/MobileUI" -resultBundlePath "$artifacts/Golem.xcresult" CODE_SIGNING_ALLOWED=NO test > "$artifacts/Golem.log" 2>&1
xcrun xcresulttool export attachments --path "$artifacts/Golem.xcresult" --output-path "$artifacts/screenshots"
