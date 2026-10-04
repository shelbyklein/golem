#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${GOLEM_TEST_ENGINE_DIR:-}" ]]; then
  printf '%s\n' "$GOLEM_TEST_ENGINE_DIR"
  exit 0
fi
test_dir=$(mktemp -d /tmp/golem-test-engine.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
rg --follow --files Chatterbox ChatterboxRuntime Shared -g '*.swift' -g '!ChatterboxApp.swift' | sort > "$test_dir/files.txt"
# Cache the unchanged engine, so iterating on native-event fixtures does not recompile the app.
engine_key=$({ swiftc --version; cat "$test_dir/files.txt"; while IFS= read -r source; do cat "$source"; done < "$test_dir/files.txt"; } | shasum -a 256 | cut -c 1-16)
engine_dir="/tmp/chatterbox-mini-engine.$engine_key"
if [[ ! -f "$engine_dir/libChatterboxTestEngine.dylib" || ! -f "$engine_dir/ChatterboxTestEngine.swiftmodule" ]]; then
  mkdir -p "$engine_dir"
  swiftc -I build/GolemPlan/Build/Products/Debug build/GolemPlan/Build/Products/Debug/SwiftTerm.o -D DEBUG -D GOLEM_APP -whole-module-optimization -Onone -enable-testing \
    -emit-library -emit-module -module-name ChatterboxTestEngine \
    -emit-module-path "$engine_dir/ChatterboxTestEngine.swiftmodule" \
    -o "$engine_dir/libChatterboxTestEngine.dylib" @"$test_dir/files.txt"
fi
printf '%s\n' "$engine_dir"
