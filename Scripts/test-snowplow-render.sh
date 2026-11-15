#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/tests .build/module-cache
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache \
    Sources/SnowCore/*.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Sources/Podokonnik/SnowplowVisual.swift \
    Tests/SnowplowRenderTests.swift -o .build/tests/snowplow-render-tests
.build/tests/snowplow-render-tests "${1:-$ROOT/.build/tests/snowplow-render}"
