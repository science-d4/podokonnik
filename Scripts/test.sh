#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/tests .build/module-cache
FLAGS=(-swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$ROOT/.build/module-cache")
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Tests/CoreTests.swift -o .build/tests/core-tests
.build/tests/core-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Tests/PerlinNoiseTests.swift -o .build/tests/perlin-noise-tests
.build/tests/perlin-noise-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/SnowCore/FestiveWorld.swift Sources/SnowCore/AppSettings.swift Tests/SettingsTests.swift -o .build/tests/settings-tests
.build/tests/settings-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/FramePacer.swift Tests/FramePacerTests.swift -o .build/tests/frame-pacer-tests
.build/tests/frame-pacer-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/WindowMotionTracker.swift Tests/WindowMotionTests.swift -o .build/tests/window-motion-tests
.build/tests/window-motion-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/Snowplow.swift Tests/SnowplowTests.swift -o .build/tests/snowplow-tests
.build/tests/snowplow-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/SnowCore/Snowplow.swift Tests/SnowplowCleanupTests.swift -o .build/tests/snowplow-cleanup-tests
.build/tests/snowplow-cleanup-tests
if [ -f Tests/DesktopTests.swift ]; then
    xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/Podokonnik/DesktopEnvironment.swift Tests/DesktopTests.swift -o .build/tests/desktop-tests
    .build/tests/desktop-tests
fi
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/SnowCore/Snowplow.swift Sources/SnowCore/DuckWorld.swift Sources/Podokonnik/SnowplowVisual.swift Sources/SnowCore/FestiveWorld.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Tests/RendererTests.swift -o .build/tests/renderer-tests
.build/tests/renderer-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/SnowCore/Snowplow.swift Sources/SnowCore/DuckWorld.swift Sources/Podokonnik/SnowplowVisual.swift Sources/SnowCore/FestiveWorld.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/SnowScene.swift Tests/ScenePointerTests.swift -o .build/tests/scene-pointer-tests
.build/tests/scene-pointer-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/SnowCore/FestiveWorld.swift Tests/FestiveWorldTests.swift -o .build/tests/festive-world-tests
.build/tests/festive-world-tests
xcrun swiftc "${FLAGS[@]}" Sources/SnowCore/*.swift Tests/DuckWorldTests.swift -o .build/tests/duck-world-tests
.build/tests/duck-world-tests
bash Scripts/test-application-instance-lock.sh
