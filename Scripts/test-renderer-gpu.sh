#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-}"
OUTPUT="${2:-$ROOT/.build/tests/renderer-gpu/evidence}"
BUILD="$ROOT/.build/tests/renderer-gpu"
mkdir -p "$BUILD" "$OUTPUT" "$ROOT/.build/module-cache"
TARGETS=(RendererIntegrationTests ParticleBackendTests MetalParticleTests MetalParticleComparisonTests DuckRenderTests WindowContentDepthRenderTests)
if [ "$MODE" != --run-only ]; then
    for TARGET in "${TARGETS[@]}"; do
        xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache \
            Sources/SnowCore/*.swift Sources/Podokonnik/DesktopEnvironment.swift \
            Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Sources/Podokonnik/SnowplowVisual.swift Sources/Podokonnik/MetalParticleView.swift \
            "Tests/$TARGET.swift" -o "$BUILD/$TARGET"
    done
fi
if [ "$MODE" == --build-only ]; then exit 0; fi
for TARGET in "${TARGETS[@]}"; do
    "$BUILD/$TARGET" "$OUTPUT/$TARGET" 2>&1 | tee "$OUTPUT/$TARGET.log"
done
