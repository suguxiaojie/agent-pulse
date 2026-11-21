#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p .tmp/antigravity-tests
fixture_dir="$(mktemp -d "$project_dir/.tmp/antigravity-tests/run.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

swiftc -swift-version 5 Sources/ClaudePulseHelper/*.swift -o "$fixture_dir/helper"

swiftc -swift-version 5 -parse-as-library -lsqlite3 \
  Sources/CodexNotchMonitor/FastTimestamp.swift \
  Sources/CodexNotchMonitor/ClaudeCodePricing.swift \
  Sources/CodexNotchMonitor/ClaudeCodeBridge.swift \
  Sources/CodexNotchMonitor/AntigravityData.swift \
  Sources/CodexNotchMonitor/AntigravityPermissionRequest.swift \
  Sources/CodexNotchMonitor/AntigravityScanner.swift \
  Sources/CodexNotchMonitor/AntigravityInstaller.swift \
  Tests/AntigravityTests.swift \
  -o "$fixture_dir/core"
"$fixture_dir/core" "$fixture_dir/helper"

clang -O2 -mmacosx-version-min=13.0 -c Vendor/Zstd/zstddeclib.c -o "$fixture_dir/zstd.o"
sources=(Sources/CodexNotchMonitor/*.swift)
sources=(${sources:#Sources/CodexNotchMonitor/App.swift})
swiftc -whole-module-optimization -Onone -I Vendor/Zstd/include "$fixture_dir/zstd.o" -lsqlite3 -swift-version 5 -parse-as-library \
  "${sources[@]}" Tests/AntigravityRuntimeTests.swift \
  -o "$fixture_dir/runtime"
"$fixture_dir/runtime" "$fixture_dir/helper"
