#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
build_dir="$ROOT/.build/tests/application-instance-lock"
mkdir -p "$build_dir" "$ROOT/.build/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache -O \
    Sources/Podokonnik/ApplicationInstanceLock.swift Tests/ApplicationInstanceLockTests.swift \
    -o "$build_dir/application-instance-lock-tests"
"$build_dir/application-instance-lock-tests" | tee "$build_dir/evidence.txt"
