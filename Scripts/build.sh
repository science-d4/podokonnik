#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTPUT="${1:-$ROOT/dist}"
if [[ "$OUTPUT" != /* ]]; then OUTPUT="$ROOT/$OUTPUT"; fi
mkdir -p .build/module-cache "$OUTPUT"
APP="$OUTPUT/Podokonnik.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SWIFT_FLAGS=(-swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$ROOT/.build/module-cache")
source_digest() {
    shasum -a 256 Sources/SnowCore/*.swift Sources/Podokonnik/*.swift Resources/Info.plist Scripts/GenerateIcon.swift Scripts/build.sh | shasum -a 256 | cut -d ' ' -f 1
}
SOURCE_BEFORE="$(source_digest)"
xcrun swiftc "${SWIFT_FLAGS[@]}" -O Scripts/GenerateIcon.swift -o .build/generate-icon
.build/generate-icon .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc "${SWIFT_FLAGS[@]}" -O -whole-module-optimization Sources/SnowCore/*.swift Sources/Podokonnik/*.swift -o "$APP/Contents/MacOS/Podokonnik"
SOURCE_AFTER="$(source_digest)"
if [ "$SOURCE_BEFORE" != "$SOURCE_AFTER" ]; then
    printf '%s\n' 'Sources changed during compilation; run build again.' >&2
    exit 1
fi
printf '{"sourceDigest":"%s","version":"1.7.1","architecture":"arm64","minimumOS":"14.0"}\n' "$SOURCE_AFTER" > "$APP/Contents/Resources/BuildInfo.json"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.snezhno.mac "$APP"
codesign --verify --strict --verbose=2 "$APP"
file "$APP/Contents/MacOS/Podokonnik"
printf 'Built: %s\n' "$APP"
