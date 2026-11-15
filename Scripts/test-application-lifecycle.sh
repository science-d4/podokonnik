#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
build_dir="$ROOT/.build/tests/application-lifecycle"
build_only=false
no_access=false
compile=true
arguments=(--settings-path "$build_dir/settings.json" --lifecycle-evidence "$build_dir/evidence.txt")
evidence_name="evidence.txt"
for argument in "$@"; do
    if [ "$argument" = "--build-only" ]; then
        build_only=true
    elif [ "$argument" = "--run-only" ]; then
        compile=false
    elif [ "$argument" = "--duck-without-access" ]; then
        no_access=true
    else
        arguments+=("$argument")
        if [ "$argument" = "--metal-particles" ]; then evidence_name="evidence-metal.txt"; fi
    fi
done
arguments[3]="$build_dir/$evidence_name"
mkdir -p "$build_dir" "$ROOT/.build/module-cache"
binary="$build_dir/application-lifecycle-tests"
if [ "$compile" = true ]; then
    SOURCES=()
    for SOURCE in Sources/Podokonnik/*.swift; do
        if [ "$SOURCE" != Sources/Podokonnik/Main.swift ]; then SOURCES+=("$SOURCE"); fi
    done
    xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache -O \
        Sources/SnowCore/*.swift "${SOURCES[@]}" Tests/ApplicationLifecycleTests.swift -o "$binary"
fi
if [ "$build_only" = true ]; then
    printf 'Built: %s\n' "$binary"
    exit 0
fi
printf '%s\n' 'Run only after stopping the product benchmark; this test shows its own transparent overlay windows.'
if [ "$no_access" = true ]; then
    # Launch through LaunchServices to test the bundle's own TCC identity.
    run_dir="$(mktemp -d "$build_dir/duck-no-access.XXXXXX")"
    app="$run_dir/SnezhnoDuckTest.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$binary" "$app/Contents/MacOS/SnezhnoDuckTest"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ru.snezhno.tests.duck-routes</string>
    <key>CFBundleExecutable</key><string>SnezhnoDuckTest</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app"
    open -n -W "$app" --args --settings-path "$run_dir/settings.json" --lifecycle-evidence "$run_dir/evidence.txt" \
        --duck-without-access "$binary" "${arguments[@]:4}"
    cat "$run_dir/evidence.txt"
    rg -q '^PASS: ' "$run_dir/evidence.txt"
else
    "$binary" "${arguments[@]}"
fi
