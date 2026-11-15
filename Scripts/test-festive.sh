#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="$PWD/.build/tests/festive"
mkdir -p "$build" .build/module-cache
if [ "${1:-}" != --run-only ]; then
    xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache \
        Sources/SnowCore/*.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift \
        Sources/Podokonnik/SnowplowVisual.swift Sources/Podokonnik/MetalParticleView.swift Sources/Podokonnik/UnifiedSnowView.swift \
        Tests/FestiveRenderTests.swift -o "$build/festive-render-tests"
fi
if [ "${1:-}" == --build-only ]; then exit 0; fi
"$build/festive-render-tests" "${2:-$build/evidence}"
