#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
build_only=false
if [ "${1:-}" = --build-only ]; then build_only=true; shift; fi
mkdir -p .build/tests .build/module-cache
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache \
    Sources/SnowCore/*.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Sources/Podokonnik/SnowplowVisual.swift \
    Tests/SnowballJoinRenderTests.swift -o .build/tests/snowball-join-render-tests
if [ "$build_only" = true ]; then exit 0; fi
.build/tests/snowball-join-render-tests "${1:-$ROOT/.build/tests/snowball-joins}"
