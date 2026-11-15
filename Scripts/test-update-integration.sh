#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash Scripts/prepare-sparkle.sh
SPARKLE="$ROOT/.build/sparkle-2.10.1"
RUN="$(mktemp -d "$ROOT/.build/update-integration.XXXXXX")"
mkdir -p "$RUN/serve" "$RUN/cache"
xcrun swift -module-cache-path "$ROOT/.build/module-cache" Tests/GenerateTestUpdateKey.swift "$RUN/test.key" "$RUN/test.pub" > /dev/null
PUBLIC_KEY="$(cat "$RUN/test.pub")"
BUNDLE_ID="local.podokonnik.updater.test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
PORT_FILE="$RUN/port"
python3 - "$RUN/serve" "$PORT_FILE" > "$RUN/server.log" 2>&1 <<'PY' &
import http.server, os, socketserver, sys
os.chdir(sys.argv[1])
with socketserver.TCPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler) as server:
    with open(sys.argv[2], 'w') as port_file:
        port_file.write(str(server.server_address[1]))
    server.serve_forever()
PY
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for _ in {1..50}; do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE")"
FEED="http://127.0.0.1:$PORT/appcast.xml"
BUNDLE="$RUN/Podokonnik.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$ROOT/.build/module-cache" \
    -D UPDATE_TESTING -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Podokonnik/UpdateController.swift Tests/UpdateIntegrationFixture.swift -o "$BUNDLE/Contents/MacOS/Podokonnik"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Podokonnik</string>
<key>CFBundleExecutable</key><string>Podokonnik</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0.1</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>SUFeedURL</key><string>$FEED</string>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>UpdateTestMarker</key><string>$RUN/version</string>
</dict></plist>
PLIST
codesign --force --sign - "$BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$RUN/serve/Podokonnik-1.0.1.zip"
"$SPARKLE/bin/generate_appcast" --ed-key-file "$RUN/test.key" --maximum-deltas 0 \
    --download-url-prefix "http://127.0.0.1:$PORT/" "$RUN/serve"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1.0.0' "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
open -n -W "$BUNDLE" --args --disable-updates
[ "$(cat "$RUN/version")" = disabled ]
open -n -W "$BUNDLE" --args --expect-disabled
[ "$(cat "$RUN/version")" = disabled ]
if [ -s "$RUN/server.log" ]; then
    printf '%s\n' 'Disabled automatic updates made a network request.' >&2
    exit 1
fi
printf '%s\n' 'PASS: disabling automatic updates persists and sends no requests'
open -n -W "$BUNDLE" --args --check-info
[ "$(cat "$RUN/version")" = available:1.0.1 ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist")" = 1.0.0 ]
if rg -q 'GET /Podokonnik-1.0.1.zip' "$RUN/server.log"; then
    printf '%s\n' 'An informational check downloaded the update.' >&2
    exit 1
fi
printf '%s\n' 'PASS: a manual check finds the version while automatic updates are disabled'
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1.0.2' "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.2' "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
open -n -W "$BUNDLE" --args --check-info
[ "$(cat "$RUN/version")" = no-update ]
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1.0.0' "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
printf '%s\n' 'PASS: a manual check reports when no update is available'
cp "$RUN/serve/appcast.xml" "$RUN/original-appcast.xml"
python3 - "$RUN/serve/appcast.xml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
content = path.read_bytes()
assert b'<title>Podokonnik</title>' in content
path.write_bytes(content.replace(b'<title>Podokonnik</title>', b'<title>Podokonnix</title>', 1))
PY
open -n -W "$BUNDLE" --args --check-info
[ "$(cat "$RUN/version")" = failed ]
printf '%s\n' 'PASS: a manual check reports a feed error'
open -n -W "$BUNDLE" --args --enable-updates --expect-reject
[ "$(cat "$RUN/version")" = 1.0.0 ]
rg -q 'GET /appcast.xml' "$RUN/server.log"
if rg -q 'GET /Podokonnik-1.0.1.zip' "$RUN/server.log"; then
    printf '%s\n' 'An update was downloaded from a modified feed.' >&2
    exit 1
fi
cp "$RUN/original-appcast.xml" "$RUN/serve/appcast.xml"
printf '%s\n' 'PASS: the modified update feed is rejected'
cp "$RUN/serve/Podokonnik-1.0.1.zip" "$RUN/original.zip"
python3 - "$RUN/serve/Podokonnik-1.0.1.zip" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
content = bytearray(path.read_bytes())
content[len(content) // 2] ^= 1
path.write_bytes(content)
PY
open -n -W "$BUNDLE" --args --enable-updates --expect-reject
[ "$(cat "$RUN/version")" = 1.0.0 ]
rg -q 'GET /Podokonnik-1.0.1.zip' "$RUN/server.log"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist")" = 1.0.0 ]
printf '%s\n' 'PASS: the modified update is not installed'
cp "$RUN/original.zip" "$RUN/serve/Podokonnik-1.0.1.zip"
open -n "$BUNDLE"
for _ in {1..120}; do
    if [ -f "$RUN/version" ] && [ "$(cat "$RUN/version")" = 1.0.1 ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist")" = 1.0.1 ]
        printf 'Automatic update installed and relaunched: %s\n' "$RUN"
        exit 0
    fi
    sleep 1
done
printf 'Automatic update did not finish; evidence: %s\n' "$RUN" >&2
exit 1
