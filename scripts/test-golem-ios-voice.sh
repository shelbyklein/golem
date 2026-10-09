#!/bin/bash
# Logic fixtures for Golem's iPhone voice: the Foundation-only pieces in Core/Shared, compiled and
# run on this Mac (no device, no audio, no network). Usage: scripts/test-golem-ios-voice.sh [name|all]
# Each tests/golem-ios-voice/<name>/ has main.swift and a `sources` file listing Core paths to compile with it.
set -uo pipefail
cd "$(dirname "$0")/.."
want=${1:-all}; failed=0; ran=0
for dir in tests/golem-ios-voice/*/; do
  n=$(basename "$dir"); [ -f "$dir/main.swift" ] || continue
  [ "$want" = all ] || [ "$want" = "$n" ] || continue
  ran=1; out=$(mktemp -d "/tmp/golem-ios-voice-$n.XXXXXX")
  srcs=(); [ -f "$dir/sources" ] && while read -r s; do [ -n "$s" ] && srcs+=("$s"); done < "$dir/sources"
  if ! swiftc -D DEBUG -o "$out/test" "${srcs[@]}" "$dir/main.swift" 2>"$out/compile.log"; then
    echo "FAIL $n (compile): $(grep error: "$out/compile.log" | head -3)"; failed=1; continue
  fi
  if "$out/test" >"$out/run.log" 2>&1 && grep -q '^PASS' "$out/run.log"; then
    sed -n 's/^PASS /  PASS /p' "$out/run.log"; echo "ok   $n"
  else
    echo "FAIL $n: $(grep -E 'Precondition|error|PASS' "$out/run.log" | tail -3)"; failed=1
  fi
done
[ $ran = 1 ] || { echo "No fixture named $want"; exit 2; }
exit $failed
