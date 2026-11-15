#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=fixed
build_only=false
run_only=false
evidence=""
comparison=""
duck=""
baseline_source=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline) mode=baseline ;;
        --baseline-source) shift; baseline_source="${1:?Missing baseline source directory}" ;;
        --build-only) build_only=true ;;
        --run-only) run_only=true ;;
        --comparison) shift; comparison="$1" ;;
        --duck-on) duck=duck-on ;;
        --duck-off) duck=duck-off ;;
        *) evidence="$1" ;;
    esac
    shift
done
build="$PWD/.build/tests/presentation-motion"
mode_dir="$build/$mode"
fixture_app="$build/DesktopMotionFixture.app"
app_sources=Sources/Podokonnik
if [ "$mode" = baseline ] && [ "$run_only" = false ]; then
    if [ -z "$baseline_source" ] || [ ! -d "$baseline_source/Sources/SnowCore" ]; then
        printf '%s\n' 'Use --baseline-source with a directory containing the earlier source tree.' >&2
        exit 2
    fi
    if [ -d "$baseline_source/Sources/Snezhno" ]; then app_sources=Sources/Snezhno; fi
fi
mkdir -p "$mode_dir/inputs/Sources/SnowCore" "$mode_dir/inputs/$app_sources" "$fixture_app/Contents/MacOS" "$PWD/.build/module-cache"
if [ "$run_only" = false ]; then
    cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ru.snezhno.PresentationMotionFixture</string>
<key>CFBundleName</key><string>PresentationMotionFixture</string>
<key>CFBundleExecutable</key><string>DesktopMotionFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
        -module-cache-path .build/module-cache Tests/DesktopMotionFixture.swift \
        -o "$fixture_app/Contents/MacOS/DesktopMotionFixture"
    codesign --force --sign - "$fixture_app"
    source_files=(Sources/SnowCore/AppSettings.swift Sources/SnowCore/FramePacer.swift
                  Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift
                  Sources/SnowCore/Snowplow.swift Sources/SnowCore/WindowMotionTracker.swift)
    if [ "$mode" = fixed ]; then
        source_files+=(Sources/SnowCore/FestiveWorld.swift Sources/SnowCore/DuckWorld.swift
                       Sources/Podokonnik/FestiveLayer.swift Sources/Podokonnik/DuckLayer.swift Sources/Podokonnik/ProcessMetrics.swift)
    fi
    source_files+=("$app_sources/DesktopEnvironment.swift" "$app_sources/SnowScene.swift" \
        "$app_sources/SnowplowVisual.swift" "$app_sources/MetalParticleView.swift" "$app_sources/UnifiedSnowView.swift")
    for file in "${source_files[@]}"; do
        if [ "$mode" = baseline ]; then cp "$baseline_source/$file" "$mode_dir/inputs/$file"
        else cp "$file" "$mode_dir/inputs/$file"; fi
    done
    shasum -a 256 "${source_files[@]/#/$mode_dir/inputs/}" > "$mode_dir/production-inputs-before-instrumentation.sha256"
    definitions=(-D PRESENTATION_FIXED)
    if [ "$mode" = baseline ]; then
        definitions=(-D PRESENTATION_BASELINE)
        python3 - "$mode_dir/inputs/$app_sources/UnifiedSnowView.swift" "$mode_dir/baseline-instrumentation.diff" <<'PY'
from pathlib import Path
import difflib,sys
path=Path(sys.argv[1]); original=path.read_text(); changed=original
changed=changed.replace('    var recordsPresentation = false\n','    var recordsPresentation = false\n    var onFramePresented: ((TimeInterval, TimeInterval) -> Void)?\n',1)
old='''        let presented: ((TimeInterval) -> Void)? = recordsPresentation ? { [weak self] time in
            guard let self, !self.invalidated, !self.paused,
                  self.presentationGeneration == generation, time > 0 else { return }
            if let previous = self.lastPresentation, time > previous, self.presentationIntervals.count < 1_000_000 {
                self.presentationIntervals.append(time - previous)
            }
            self.lastPresentation = time
        } : nil'''
new='''        let targetTime = update.targetPresentationTimestamp
        let records = recordsPresentation
        let presented: ((TimeInterval) -> Void)? = (records || onFramePresented != nil) ? { [weak self] time in
            guard let self, !self.invalidated, !self.paused,
                  self.presentationGeneration == generation, time > 0 else { return }
            if records {
                if let previous = self.lastPresentation, time > previous, self.presentationIntervals.count < 1_000_000 {
                    self.presentationIntervals.append(time - previous)
                }
                self.lastPresentation = time
            }
            self.onFramePresented?(targetTime, time)
        } : nil'''
assert changed.count(old)==1, 'Baseline instrumentation anchor changed'
changed=changed.replace(old,new,1)
changed=changed.replace('        onFailure = nil\n','        onFailure = nil\n        onFramePresented = nil\n',1)
assert 'link.preferredFrameLatency = 2' in changed
path.write_text(changed)
Path(sys.argv[2]).write_text(''.join(difflib.unified_diff(original.splitlines(True),changed.splitlines(True),fromfile='baseline/UnifiedSnowView.swift',tofile='test-only/UnifiedSnowView.swift')))
PY
    fi
    shasum -a 256 "${source_files[@]/#/$mode_dir/inputs/}" Tests/PresentationMotionTests.swift \
        Tests/DesktopMotionFixture.swift Scripts/test-presentation-motion.sh > "$mode_dir/checked-inputs.sha256"
    xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
        -module-cache-path .build/module-cache "${definitions[@]}" \
        "${source_files[@]/#/$mode_dir/inputs/}" Tests/PresentationMotionTests.swift \
        -o "$mode_dir/PresentationMotionTests"
    shasum -a 256 -c "$mode_dir/checked-inputs.sha256"
    shasum -a 256 "$mode_dir/PresentationMotionTests" > "$mode_dir/binary.sha256"
fi
if [ "$build_only" = true ]; then exit 0; fi
if [ -z "$evidence" ]; then evidence="$mode_dir/result.json"; fi
args=("$fixture_app/Contents/MacOS/DesktopMotionFixture" "$evidence" "$mode")
if [ -n "$duck" ]; then
    if [ "$mode" != fixed ] || [ -n "$comparison" ]; then
        printf '%s\n' 'Duck measurements use the current build in both modes.' >&2
        exit 2
    fi
    args[2]="$duck"
fi
if [ -n "$comparison" ]; then args+=("$comparison"); fi
"$mode_dir/PresentationMotionTests" "${args[@]}"
