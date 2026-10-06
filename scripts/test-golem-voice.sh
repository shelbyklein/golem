#!/bin/bash
# Runs the Golem voice and mini fixtures against the Debug build, each in a throwaway data
# directory so nothing touches the live store. Usage: scripts/test-golem-voice.sh [name|all]
# Names are directories under tests/golem-voice and tests/golem-mini.
set -uo pipefail
cd "$(dirname "$0")/.."
products=build/GolemPlan/Build/Products/Debug
dylib="$(pwd)/$products/Golem.app/Contents/MacOS/Golem.debug.dylib"
[ -f "$dylib" ] || { echo "Build Golem first: env -u CHATTERBOX_DATA_DIR xcodebuild -project Golem.xcodeproj -scheme Golem -derivedDataPath build/GolemPlan build"; exit 2; }
want=${1:-all}
names=()
for dir in tests/golem-voice/* tests/golem-mini/*; do
  n=$(basename "$dir"); [ -f "$dir/main.swift" ] || continue
  if [ "$want" = all ] || [ "$want" = "$n" ]; then names+=("$dir"); fi
done
[ ${#names[@]} -gt 0 ] || { echo "No fixture named $want"; exit 2; }
failed=0
for dir in "${names[@]}"; do
  n=$(basename "$dir")
  fixture=$(mktemp -d "/tmp/golem-fixture-$n.XXXXXX")
  mkdir -p "$fixture/Dot"
  [ -d "$HOME/Chatterbox/Dot/Avatar" ] && cp -R "$HOME/Chatterbox/Dot/Avatar" "$fixture/Dot/Avatar"
  if ! swiftc -I "$products" "$dylib" -Xlinker -rpath -Xlinker "$(dirname "$dylib")" -D DEBUG -o "$fixture/test" "$dir/main.swift" 2>"$fixture/compile.log"; then
    echo "FAIL $n (compile): $(grep error: "$fixture/compile.log" | head -3)"; failed=1; continue
  fi
  # The fixtures share the plain `test` defaults domain; start each one clean.
  defaults delete test >/dev/null 2>&1 || true
  env -u CHATTERBOX_HOST_BINARY -u CHATTERBOX_MCP_BINARY \
    CHATTERBOX_DATA_DIR="$fixture" CHATTERBOX_HOST_DIR="$fixture/host" CHATTERBOX_ASSISTANT_DIR="$fixture/Dot" \
    CHATTERBOX_AGENT_PORT=0 CHATTERBOX_COMPANION_PORT=0 \
    "$fixture/test" >"$fixture/run.log" 2>&1 &
  pid=$!
  ( sleep 90; kill "$pid" 2>/dev/null ) & killer=$!
  wait "$pid"; status=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  if [ $status -eq 0 ] && grep -q '^PASS' "$fixture/run.log"; then
    sed -n 's/^PASS /  PASS /p' "$fixture/run.log"; echo "ok   $n"
  else
    echo "FAIL $n (exit $status): $(grep -E 'Precondition|error|PASS' "$fixture/run.log" | tail -3)"; failed=1
  fi
  defaults delete test >/dev/null 2>&1 || true
done
exit $failed
