#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
ARCHIVE="$ROOT/.build/sparkle-$VERSION.tar.xz"
DIRECTORY="$ROOT/.build/sparkle-$VERSION"
mkdir -p "$ROOT/.build"
if [ ! -f "$ARCHIVE" ]; then
    TEMP_ARCHIVE="$(mktemp "$ROOT/.build/sparkle-download.XXXXXX")"
    trap 'rm -f "$TEMP_ARCHIVE"' EXIT
    curl -fsSL --retry 3 -o "$TEMP_ARCHIVE" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
    printf '%s  %s\n' "$SHA256" "$TEMP_ARCHIVE" | shasum -a 256 -c
    mv "$TEMP_ARCHIVE" "$ARCHIVE"
    trap - EXIT
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c
if [ ! -f "$DIRECTORY/Sparkle.framework/Versions/B/Sparkle" ]; then
    mkdir -p "$DIRECTORY"
    tar -xf "$ARCHIVE" -C "$DIRECTORY"
fi
