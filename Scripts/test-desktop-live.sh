#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
build_dir="$PWD/.build/tests/desktop-live"
fixture_app="$build_dir/DesktopFixture.app"
mkdir -p "$fixture_app/Contents/MacOS" "$build_dir/module-cache"

cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ru.snezhno.DesktopFixture</string>
<key>CFBundleName</key><string>DesktopFixture</string>
<key>CFBundleExecutable</key><string>DesktopFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library \
    -module-cache-path "$build_dir/module-cache" \
    Tests/DesktopFixture.swift -o "$fixture_app/Contents/MacOS/DesktopFixture"
codesign --force --sign - "$fixture_app"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library \
    -module-cache-path "$build_dir/module-cache" \
    Sources/SnowCore/SnowTypes.swift Sources/Podokonnik/DesktopEnvironment.swift Tests/DesktopLiveTests.swift \
    -o "$build_dir/DesktopLiveTests"

printf '%s\n' 'Running own-window live integration test (requires the current GUI session).'
"$build_dir/DesktopLiveTests" "$fixture_app/Contents/MacOS/DesktopFixture" "$build_dir/evidence.txt"
