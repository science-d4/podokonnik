#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/tests .build/module-cache
SOURCES=()
for SOURCE in Sources/Podokonnik/*.swift; do
    if [ "$SOURCE" != Sources/Podokonnik/Main.swift ]; then SOURCES+=("$SOURCE"); fi
done
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache -O \
    Sources/SnowCore/*.swift "${SOURCES[@]}" Tests/AppKitTests.swift -o .build/tests/appkit-tests
.build/tests/appkit-tests
