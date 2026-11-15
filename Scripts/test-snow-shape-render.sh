#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/tests .build/module-cache
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache \
    Sources/SnowCore/*.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Sources/Podokonnik/SnowplowVisual.swift \
    Sources/Podokonnik/DesktopEnvironment.swift Tests/SnowShapeRenderTests.swift -o .build/tests/snow-shape-render-tests
.build/tests/snow-shape-render-tests "${1:-$ROOT/.build/tests/snow-shape-render}"
