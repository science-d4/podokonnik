#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=fixed
build_only=false
run_only=false
evidence=""
comparison=""
baseline_source=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline) mode=baseline ;;
        --baseline-source) shift; baseline_source="${1:?Missing baseline source directory}" ;;
        --build-only) build_only=true ;;
        --run-only) run_only=true ;;
        --comparison) shift; comparison="$1" ;;
        *) evidence="$1" ;;
    esac
    shift
done
build_dir="$PWD/.build/tests/desktop-motion"
if [ "$mode" = baseline ] && [ "$run_only" = false ] && [ -z "$baseline_source" ]; then
    printf '%s\n' 'Use --baseline-source with a directory containing the earlier source tree.' >&2
    exit 2
fi
fixture_app="$build_dir/DesktopMotionFixture.app"
mode_dir="$build_dir/$mode"
mkdir -p "$fixture_app/Contents/MacOS" "$mode_dir" "$build_dir/module-cache"
if [ "$run_only" = false ]; then
    cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ru.snezhno.DesktopMotionFixture</string>
<key>CFBundleName</key><string>DesktopMotionFixture</string>
<key>CFBundleExecutable</key><string>DesktopMotionFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
        -module-cache-path "$build_dir/module-cache" Tests/DesktopMotionFixture.swift \
        -o "$fixture_app/Contents/MacOS/DesktopMotionFixture"
    codesign --force --sign - "$fixture_app"
    if [ "$mode" = baseline ]; then
        app_sources="$baseline_source/Sources/Podokonnik"
        if [ -d "$baseline_source/Sources/Snezhno" ]; then app_sources="$baseline_source/Sources/Snezhno"; fi
        cp "$baseline_source/Sources/SnowCore/SnowTypes.swift" "$mode_dir/SnowTypes.swift"
        cp "$app_sources/DesktopEnvironment.swift" "$mode_dir/DesktopEnvironment.swift"
        source_types="$mode_dir/SnowTypes.swift"
        source_desktop="$mode_dir/DesktopEnvironment.swift"
    else
        source_types=Sources/SnowCore/SnowTypes.swift
        source_desktop=Sources/Podokonnik/DesktopEnvironment.swift
    fi
    shasum -a 256 "$source_types" "$source_desktop" Tests/DesktopMotionTests.swift Tests/DesktopMotionFixture.swift Scripts/test-desktop-motion.sh > "$mode_dir/inputs.sha256"
    xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
        -module-cache-path "$build_dir/module-cache" "$source_types" "$source_desktop" \
        Tests/DesktopMotionTests.swift -o "$mode_dir/DesktopMotionTests"
    shasum -a 256 -c "$mode_dir/inputs.sha256"
fi
if [ "$build_only" = true ]; then exit 0; fi
if [ -z "$evidence" ]; then evidence="$mode_dir/result.json"; fi
args=("$fixture_app/Contents/MacOS/DesktopMotionFixture" "$evidence" "$mode")
if [ -n "$comparison" ]; then args+=("$comparison"); fi
"$mode_dir/DesktopMotionTests" "${args[@]}"
