#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
build_only=false
baseline_world=""
baseline_support=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-only) build_only=true; shift ;;
        --baseline-world) baseline_world="$2"; shift 2 ;;
        --baseline-support) baseline_support="$2"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
build_dir="$ROOT/.build/tests/unified-input"
if [ -n "$baseline_world" ]; then build_dir="$build_dir-baseline"; fi
mkdir -p "$build_dir" "$ROOT/.build/module-cache"
SOURCES=()
for SOURCE in Sources/SnowCore/*.swift; do
    if [ -n "$baseline_world" ] && [ "$SOURCE" = Sources/SnowCore/SnowWorld.swift ]; then continue; fi
    SOURCES+=("$SOURCE")
done
if [ -n "$baseline_world" ]; then SOURCES+=("$baseline_world"); fi
if [ -n "$baseline_support" ]; then SOURCES+=("$baseline_support"); fi
for SOURCE in Sources/Podokonnik/*.swift; do
    if [ "$SOURCE" != Sources/Podokonnik/Main.swift ]; then SOURCES+=("$SOURCE"); fi
done
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path .build/module-cache -O \
    "${SOURCES[@]}" Tests/UnifiedInputTests.swift -o "$build_dir/unified-input-tests"
if [ "$build_only" = true ]; then
    printf 'Built: %s\n' "$build_dir/unified-input-tests"
    exit 0
fi
"$build_dir/unified-input-tests" --settings-path "$build_dir/settings.json" --input-evidence "$build_dir/evidence.txt"
