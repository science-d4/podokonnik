#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/Podokonnik.app"
test -x "$APP/Contents/MacOS/Podokonnik"
codesign --verify --strict "$APP"
STAGE="$(mktemp -d "$ROOT/.build/dmg-stage.XXXXXX")"
ditto "$APP" "$STAGE/Podokonnik.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/Installation-ru.txt "$STAGE/Установка.txt"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'Invalid application version: %s\n' "$VERSION" >&2
    exit 1
fi
DMG="$ROOT/dist/Podokonnik-$VERSION-arm64.dmg"
hdiutil create -volname 'Подоконник' -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
hdiutil verify "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256"
printf 'Packaged: %s\n' "$DMG"
