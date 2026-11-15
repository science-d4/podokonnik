#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required to sign updates}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
APP="$ROOT/dist/Podokonnik.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || [[ ! "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf '%s\n' 'Invalid version or repository.' >&2
    exit 1
fi
xcrun swift -module-cache-path "$ROOT/.build/module-cache" Scripts/verify-update-key.swift "$APP"
STAGE="$(mktemp -d "$ROOT/.build/appcast.XXXXXX")"
cp "$ROOT/dist/Podokonnik-$VERSION-arm64.dmg" "$STAGE/"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$ROOT/.build/sparkle-2.10.1/bin/generate_appcast" \
    --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION/" "$STAGE"
cp "$STAGE/appcast.xml" "$ROOT/dist/appcast.xml"
printf 'Appcast ready: %s\n' "$ROOT/dist/appcast.xml"
