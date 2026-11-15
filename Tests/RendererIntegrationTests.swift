// GPU regression test: only renders this application's synthetic node tree.
// Requires a graphical macOS session; never captures the screen or reads another app.
// Compile separately from other @main test runners:
// swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift Sources/Podokonnik/DesktopEnvironment.swift \
//   Tests/RendererIntegrationTests.swift -o /private/tmp/snezhno-renderer-integration
// Run: /private/tmp/snezhno-renderer-integration <output-directory>
import AppKit
import SpriteKit

@main
enum RendererIntegrationTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("Snezhno-renderer-\(UUID().uuidString)")
        do { try run(in: directory) }
        catch {
            fputs("Renderer GPU regression failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = CGRect(x: 0, y: 0, width: 180, height: 120)
        let world = SnowWorld(seed: 1)
        var support = SnowSurface(id: "roof", frame: CGRect(x: 10, y: 20, width: 160, height: 30), kind: .window)
        support.topInset = 16
        world.syncSurfaces([support])
        world.prune(to: [frame])
        for _ in 0..<2_400 {
            world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame])
        }
        guard let drift = world.drifts["roof"], drift.heights.count > 12 else { throw failure("missing drift") }
        _ = world.beginSnowball(at: CGPoint(x: 58, y: support.top + drift.heights[12]))
        world.endDrag()
        guard world.balls.count == 1, world.balls[0].surfaceID == support.id else { throw failure("fixture must contain an attached ball") }
        let scene = SnowScene(world: world, displayFrame: frame)
        let view = SKView(frame: frame)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        view.presentScene(scene)
        defer { view.presentScene(nil); window.close() }

        func render(_ name: String) throws -> NSBitmapImageRep {
            let url = directory.appendingPathComponent(name)
            guard scene.exportPreview(to: url), let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw failure("PNG export failed: \(name)")
            }
            return bitmap
        }
        func alphaCount(_ bitmap: NSBitmapImageRep, xRange: Range<CGFloat>) -> Int {
            let scale = CGFloat(bitmap.pixelsWide) / frame.width
            let lower = max(0, Int(ceil(xRange.lowerBound * scale)))
            let upper = min(bitmap.pixelsWide, Int(floor(xRange.upperBound * scale)))
            var count = 0
            for x in lower..<upper {
                for y in 0..<bitmap.pixelsHigh {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { count += 1 }
                }
            }
            return count
        }
        let visibleBitmap = try render("visible.png")
        let visible = alphaCount(visibleBitmap, xRange: 0..<180)
        let initialRasters = scene.driftRasterizations
        let cornerPixels = alphaCount(visibleBitmap, xRange: 10..<25) + alphaCount(visibleBitmap, xRange: 155..<170)
        var hidden = support
        hidden.occluders = [frame]
        world.syncSurfaces([hidden])
        let hiddenPixels = alphaCount(try render("fully-occluded.png"), xRange: 0..<180)
        let hiddenRasters = scene.driftRasterizations
        var half = support
        half.occluders = [CGRect(x: 0, y: 0, width: 90, height: 120)]
        world.syncSurfaces([half])
        let halfBitmap = try render("partly-occluded.png")
        let leftPixels = alphaCount(halfBitmap, xRange: 0..<89)
        let rightPixels = alphaCount(halfBitmap, xRange: 91..<180)
        world.syncSurfaces([support])
        let restored = alphaCount(try render("restored.png"), xRange: 0..<180)
        let revealRasters = scene.driftRasterizations
        var bandHidden = support
        bandHidden.occluders = [CGRect(x: 0, y: support.top - 3, width: frame.width, height: SnowDrift.maximumHeight + 6)]
        world.syncSurfaces([bandHidden])
        let protrudingBallPixels = alphaCount(try render("drift-hidden-ball-protruding.png"), xRange: 0..<180)
        let ballOnlyRasters = scene.driftRasterizations
        var narrower = support
        narrower.topInset = 24
        world.syncSurfaces([narrower])
        let changedInset = alphaCount(try render("larger-inset.png"), xRange: 26..<33)

        // Use the real platform ceiling mask: a normal maximized window stays present,
        // but its roof and attached ball must not leave a stripe under the menu bar.
        var ceiling = support
        guard let ceilingMask = DesktopGeometry.ceilingExclusion(for: support.frame, display: frame,
                                                                 visibleTop: support.top + 8) else {
            throw failure("expected near-ceiling exclusion")
        }
        ceiling.occluders = [ceilingMask]
        world.syncSurfaces([ceiling])
        let ceilingPixels = alphaCount(try render("ceiling-excluded.png"), xRange: 0..<180)

        // A second fixture isolates thick accumulation at both corners. The simulation
        // intentionally discards unsupported snow, so regrow before the reverse check.
        let thickWorld = SnowWorld(seed: 2)
        var thickSupport = support
        thickSupport.id = "thick-roof"
        thickSupport.topInset = 0
        thickWorld.syncSurfaces([thickSupport])
        thickWorld.prune(to: [frame])
        var thickDebrisBeforeSettling: [Int] = []
        func fillThickRoof() throws {
            for _ in 0..<4_800 {
                thickWorld.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame])
            }
            // Saturated deposition emits airborne fragments. The corner probe
            // measures the settled roof, so age them without changing its profile.
            // Otherwise an unrelated fragment below the roof can fail all-height
            // alphaCount and the exact inset-reversal comparison.
            thickDebrisBeforeSettling.append(thickWorld.debris.count)
            let profile = thickWorld.drifts[thickSupport.id]!.heights
            var hidden = thickSupport
            hidden.isVisible = false
            thickWorld.syncSurfaces([hidden])
            for _ in 0..<12 {
                thickWorld.step(delta: 0.1, weather: SnowWeather(), activeRegions: [frame])
            }
            thickWorld.syncSurfaces([thickSupport])
            guard thickWorld.debris.isEmpty, thickWorld.drifts[thickSupport.id]!.heights == profile else {
                throw failure("settling airborne fragments must preserve the measured thick roof")
            }
        }
        try fillThickRoof()
        let thickScene = SnowScene(world: thickWorld, displayFrame: frame)
        view.presentScene(thickScene)
        func thickCorners(_ name: String) throws -> Int {
            let url = directory.appendingPathComponent(name)
            guard thickScene.exportPreview(to: url), let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw failure("thick profile PNG export failed")
            }
            return alphaCount(bitmap, xRange: 10..<25) + alphaCount(bitmap, xRange: 155..<170)
        }
        let beforeInset = try thickCorners("thick-inset-zero.png")
        thickSupport.topInset = 16
        thickWorld.syncSurfaces([thickSupport])
        let afterInset = try thickCorners("thick-inset-sixteen.png")
        thickSupport.topInset = 0
        thickWorld.syncSurfaces([thickSupport])
        try fillThickRoof()
        let insetReversed = try thickCorners("thick-inset-restored.png")

        // The supporting window ends before the neighboring display, but a large
        // attached snowball extends across the seam. Only its silhouette is visible.
        let seamWorld = SnowWorld(seed: 3)
        var seamSupport = SnowSurface(id: "seam-roof", frame: CGRect(x: -401, y: 20, width: 400, height: 30),
                                      kind: .window, topInset: 16)
        seamWorld.syncSurfaces([seamSupport])
        let bothDisplays = CGRect(x: -420, y: 0, width: 600, height: 120)
        seamWorld.prune(to: [bothDisplays])
        for _ in 0..<4_800 {
            seamWorld.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .blizzard), activeRegions: [bothDisplays])
        }
        func seamSnowPoint(x: CGFloat) -> CGPoint {
            let heights = seamWorld.drifts[seamSupport.id]!.heights
            let index = Int((x - seamSupport.frame.minX) / SnowDrift.spacing)
            return CGPoint(x: x, y: seamSupport.top + heights[index])
        }
        guard seamWorld.beginSnowball(at: seamSnowPoint(x: -349)) != nil else { throw failure("missing seam snowball") }
        for x in stride(from: CGFloat(-345), through: CGFloat(-21), by: CGFloat(4)) {
            seamWorld.drag(to: seamSnowPoint(x: x))
        }
        seamWorld.endDrag()
        guard let seamBall = seamWorld.balls.first, seamBall.surfaceID == seamSupport.id,
              seamBall.position.x + seamBall.radius > 4 else { throw failure("seam ball must protrude onto the neighboring display") }
        let seamScene = SnowScene(world: seamWorld, displayFrame: frame)
        view.presentScene(seamScene)
        func seamPixels(_ name: String) throws -> Int {
            let url = directory.appendingPathComponent(name)
            guard seamScene.exportPreview(to: url), let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw failure("neighboring display PNG export failed")
            }
            return alphaCount(bitmap, xRange: 0..<180)
        }
        let seamVisible = try seamPixels("neighboring-ball-visible.png")
        seamSupport.occluders = [frame]
        seamWorld.syncSurfaces([seamSupport])
        let seamHidden = try seamPixels("neighboring-ball-occluded.png")
        seamSupport.occluders = []
        seamWorld.syncSurfaces([seamSupport])
        let seamRestored = try seamPixels("neighboring-ball-restored.png")

        // Exercise the raster cache with real deposition. Quarter-pixel changes may
        // reuse the bitmap; reveals, rounded-edge changes and scale changes may not.
        let cacheWorld = SnowWorld(seed: 4)
        var cacheSupport = support
        cacheSupport.id = "cache-roof"
        cacheWorld.syncSurfaces([cacheSupport])
        cacheWorld.prune(to: [frame])
        func advanceCache(_ frames: Int) {
            for _ in 0..<frames {
                cacheWorld.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame])
            }
        }
        advanceCache(60)
        let cacheScene = SnowScene(world: cacheWorld, displayFrame: frame)
        cacheScene.presentationScale = 1
        view.presentScene(cacheScene)
        func cacheImage(_ name: String) throws -> NSBitmapImageRep {
            let url = directory.appendingPathComponent(name)
            guard cacheScene.exportPreview(to: url), let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw failure("cache regression export failed")
            }
            return bitmap
        }
        _ = try cacheImage("cache-initial.png")
        let baselineProfile = cacheWorld.drifts[cacheSupport.id]!.heights
        func profileDelta() -> CGFloat {
            zip(baselineProfile, cacheWorld.drifts[cacheSupport.id]!.heights).map { abs($0 - $1) }.max() ?? 0
        }
        while profileDelta() < 0.12 { advanceCache(1) }
        guard profileDelta() < 0.25 else { throw failure("fixture must stay below a quarter pixel") }
        _ = try cacheImage("cache-subpixel-growth.png")
        let subpixelRasters = cacheScene.driftRasterizations
        while profileDelta() < 0.28 { advanceCache(1) }
        _ = try cacheImage("cache-quarter-pixel-growth.png")
        let changedRasters = cacheScene.driftRasterizations
        cacheSupport.occluders = [frame]
        cacheWorld.syncSurfaces([cacheSupport])
        _ = try cacheImage("cache-hidden.png")
        cacheWorld.clear(surfaceID: cacheSupport.id)
        cacheSupport.frame.size.width -= 20
        cacheSupport.topInset = 24
        cacheScene.presentationScale = 2
        cacheWorld.syncSurfaces([cacheSupport])
        _ = try cacheImage("cache-hidden-cleared-resized.png")
        let hiddenChangedRasters = cacheScene.driftRasterizations
        cacheSupport.occluders = []
        cacheWorld.syncSurfaces([cacheSupport])
        let clearedRevealPixels = alphaCount(try cacheImage("cache-revealed-cleared.png"), xRange: 0..<180)
        let clearedRevealRasters = cacheScene.driftRasterizations
        advanceCache(2_400)
        let regrown = try cacheImage("cache-revealed-regrown-rounded.png")
        let regrownPixels = alphaCount(regrown, xRange: 0..<180)
        let regrownCornerPixels = alphaCount(regrown, xRange: 10..<33)
            + alphaCount(regrown, xRange: 127..<150)
        let beforeScaleChange = cacheScene.driftRasterizations
        cacheScene.presentationScale = 1
        _ = try cacheImage("cache-visible-scale-change.png")
        let scaleChangeRasters = cacheScene.driftRasterizations
        let cachePassed = initialRasters == 1 && hiddenRasters == initialRasters && revealRasters == 3
            && protrudingBallPixels > 0 && protrudingBallPixels < visible && ballOnlyRasters == revealRasters
            && subpixelRasters == 1 && changedRasters == 2 && hiddenChangedRasters == changedRasters
            && clearedRevealPixels == 0 && clearedRevealRasters == hiddenChangedRasters + 1
            && regrownPixels > 100 && regrownCornerPixels == 0 && scaleChangeRasters == beforeScaleChange + 1
        let passed = visible > 100 && hiddenPixels == 0 && leftPixels == 0 && rightPixels > 100
            && restored == visible && cornerPixels == 0 && changedInset == 0 && ceilingPixels == 0
            && beforeInset > 100 && afterInset == 0 && insetReversed == beforeInset
            && seamVisible > 100 && seamHidden == 0 && seamRestored == seamVisible
            && cachePassed
        let report: [String: Any] = ["passed": passed, "visiblePixels": visible, "hiddenPixels": hiddenPixels,
                                     "occludedHalfPixels": leftPixels, "visibleHalfPixels": rightPixels,
                                     "restoredPixels": restored, "attachedBalls": world.balls.count,
                                     "roundedCornerPixels": cornerPixels, "changedInsetCornerPixels": changedInset,
                                     "ceilingExcludedPixels": ceilingPixels, "thickCornersBeforeInset": beforeInset,
                                     "thickCornersAfterInset": afterInset, "thickCornersRestored": insetReversed,
                                     "thickDebrisBeforeSettling": thickDebrisBeforeSettling,
                                     "neighboringBallPixels": seamVisible, "neighboringBallOccludedPixels": seamHidden,
                                     "neighboringBallRestoredPixels": seamRestored, "cachePassed": cachePassed,
                                     "initialRasters": initialRasters, "fullyHiddenRasters": hiddenRasters,
                                     "revealRasters": revealRasters, "protrudingBallPixels": protrudingBallPixels,
                                     "protrudingBallRasters": ballOnlyRasters, "subpixelGrowthRasters": subpixelRasters,
                                     "quarterPixelGrowthRasters": changedRasters, "hiddenClearedResizedRasters": hiddenChangedRasters,
                                     "clearedRevealPixels": clearedRevealPixels, "clearedRevealRasters": clearedRevealRasters,
                                     "regrownRoundedPixels": regrownPixels, "regrownCornerPixels": regrownCornerPixels,
                                     "beforeScaleChangeRasters": beforeScaleChange, "afterScaleChangeRasters": scaleChangeRasters]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        print("Renderer GPU clipping: \(report)")
        guard passed else { throw failure("visible, full occlusion, partial occlusion or restoration mismatch") }
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "Snezhno.RendererRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
