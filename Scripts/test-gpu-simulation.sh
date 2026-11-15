#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=.build/tests/gpu-simulation
mkdir -p "$build" .build/module-cache
if [ "${1:-}" != --run-only ]; then
    xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache \
        Sources/SnowCore/*.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Sources/Podokonnik/SnowplowVisual.swift \
        Sources/Podokonnik/MetalParticleView.swift Sources/Podokonnik/UnifiedSnowView.swift \
        Tests/GPUParticleSimulationTests.swift -o "$build/gpu-simulation-tests"
fi
if [ "${1:-}" == --build-only ]; then exit 0; fi
"$build/gpu-simulation-tests"
