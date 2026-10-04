#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/runtime
manifest=$(mktemp /tmp/golem-service-sources.XXXXXX)
trap 'rm -f "$manifest"' EXIT
./scripts/runtime-sources.sh > "$manifest"
printf '%s\n' ChatterboxRuntime/RuntimeClient.swift >> "$manifest"
rg --follow --files GolemService -g '*.swift' >> "$manifest"
swiftc -D DEBUG -D CHATTERBOX_HEADLESS -whole-module-optimization -Onone -o build/runtime/golemd @"$manifest"
