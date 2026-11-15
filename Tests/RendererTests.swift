// Standalone geometry checks. Run separately from CoreTests.swift (@main in each runner):
// swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift \
//   Tests/RendererTests.swift -o /private/tmp/snezhno-renderer-tests && /private/tmp/snezhno-renderer-tests
import AppKit

@main
enum RendererTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func main() {
        var outlines: [[CGPoint]] = []
        for variant in 0..<RendererGeometry.snowballVariantCount {
            let outline = RendererGeometry.snowballOutline(variant: variant)
            check(outline == RendererGeometry.snowballOutline(variant: variant), "ball relief is stationary")
            let radii = outline.map { hypot($0.x, $0.y) }
            check(radii.allSatisfy { abs($0 - 1) <= 0.03 }, "small relief stays inside the ball's padded bounds")
            check((radii.max()! - radii.min()!) > 0.005, "hand-packed balls are not perfect circles")
            check(outline.allSatisfy { abs($0.y) <= 1.000001 }, "relief cannot lift a ball above its physical contact")
            check(outline.contains { abs($0.x) < 0.000001 && abs($0.y - 1) < 0.000001 }
                    && outline.contains { abs($0.x) < 0.000001 && abs($0.y + 1) < 0.000001 },
                  "top and bottom contacts retain the physical radius")
            let edges = zip(outline, outline.dropFirst() + [outline[0]])
            check(edges.allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.06 }, "outline has no discontinuity at its seam")
            check(!outlines.contains(outline), "cached variants have distinct silhouettes")
            outlines.append(outline)
        }
        let ballIDs = (0..<30).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", $0))! }
        let variants = ballIDs.map { RendererGeometry.snowballVariant(for: $0) }
        check(variants == ballIDs.map { RendererGeometry.snowballVariant(for: $0) }, "a ball keeps its variant across scenes")
        check(Set(variants).count == RendererGeometry.snowballVariantCount, "normal ball IDs use the bounded texture palette")

        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let middle = CGRect(x: 20, y: 20, width: 60, height: 60)
        let fragments = RendererGeometry.visibleRectangles(in: bounds, subtracting: [middle])
        check(fragments.reduce(0) { $0 + $1.width * $1.height } == 6_400, "single hole area")
        check(!fragments.contains { $0.contains(CGPoint(x: 50, y: 50)) }, "a tall ball is clipped through its entire area")
        let foreground = CGRect(x: 50, y: 0, width: 50, height: 100)
        let overlap = RendererGeometry.visibleRectangles(in: bounds, subtracting: [middle, foreground])
        check(overlap.reduce(0) { $0 + $1.width * $1.height } == 3_200, "overlapping foreground windows form a union, not an XOR")
        for x in 0..<100 {
            for y in 0..<100 {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let expected = !middle.contains(point) && !foreground.contains(point)
                check(overlap.filter { $0.contains(point) }.count == (expected ? 1 : 0), "mask tiles neither overlap nor expose occluded content")
            }
        }
        check(RendererGeometry.visibleRectangles(in: bounds, subtracting: [bounds]).isEmpty, "fully hidden content")
        check(RendererGeometry.visibleRectangles(in: bounds, subtracting: [CGRect(x: -300, y: -300, width: 50, height: 50)]) == [bounds], "offscreen windows do not remove content")
        check(RendererGeometry.visibleRectangles(in: .zero, subtracting: []).isEmpty, "empty display intersection")

        let negativeDisplay = CGRect(x: -1920, y: -400, width: 1920, height: 1080)
        let negativeOccluder = CGRect(x: -1200, y: -500, width: 300, height: 600)
        let negativeParts = RendererGeometry.visibleRectangles(in: negativeDisplay, subtracting: [negativeOccluder])
        check(negativeParts.reduce(0) { $0 + $1.width * $1.height } == 1920 * 1080 - 300 * 500, "negative display coordinates and partial intersection")
        check(negativeParts.allSatisfy { negativeDisplay.contains($0) }, "mask stays inside display")

        let neighboringDisplay = CGRect(x: 0, y: 0, width: 180, height: 120)
        let nearbyRoof = SnowSurface(id: "neighbor", frame: CGRect(x: -161, y: 20, width: 160, height: 30), kind: .window, topInset: 16)
        let protrudingBall = Snowball(position: CGPoint(x: -17, y: 70), radius: 24, surfaceID: nearbyRoof.id)
        check(RendererGeometry.driftRasterBounds(for: nearbyRoof, displayFrame: neighboringDisplay) == nil, "off-display roof creates no phantom raster strip")
        check(RendererGeometry.ballBounds(protrudingBall).intersects(neighboringDisplay), "attached ball silhouette reaches the neighboring display independently of its roof")
        let aboveRoof = SnowSurface(id: "above", frame: CGRect(x: 10, y: 180, width: 160, height: 30), kind: .window)
        check(RendererGeometry.driftRasterBounds(for: aboveRoof, displayFrame: neighboringDisplay) == nil, "roof above the display has no visible raster band")
        let belowRoof = SnowSurface(id: "below", frame: CGRect(x: 10, y: -40, width: 160, height: 30), kind: .window)
        check(RendererGeometry.driftRasterBounds(for: belowRoof, displayFrame: neighboringDisplay) != nil, "tall accumulation remains visible when its base is below the display")

        let ridge = RendererGeometry.driftRidge(heights: [5, 8, 4, 6], width: 10)
        check(ridge.boundingBoxOfPath.maxX == 10, "short final profile segment")
        check(ridge.boundingBoxOfPath.minX == 0, "profile starts at local origin")
        check(RendererGeometry.driftPath(heights: [], width: 100).isEmpty, "missing profile produces no shape")
        check(RendererGeometry.driftPath(heights: [3, 4], width: 0).isEmpty, "zero-width support produces no shape")
        let limited = RendererGeometry.driftPath(heights: [-4, 8, -3], width: 8).boundingBoxOfPath
        check(limited.minY >= -0.5, "invalid negative heights do not invert the drift")
        check(limited.maxX <= 8, "drift remains within its resized support")
        let cap = RendererGeometry.driftPath(heights: Array(repeating: 10, count: 26), width: 100)
        check(!cap.contains(CGPoint(x: 1, y: 8)), "left cap is rounded rather than a vertical slab")
        check(!cap.contains(CGPoint(x: 99, y: 8)), "right cap is rounded rather than a vertical slab")
        check(cap.contains(CGPoint(x: 50, y: 8)), "edge rounding preserves the central drift height")
        let floor = RendererGeometry.driftPath(heights: Array(repeating: 10, count: 26), width: 100, roundedEnds: false)
        check(floor.contains(CGPoint(x: 1, y: 8)) && floor.contains(CGPoint(x: 99, y: 8)), "floor snow reaches display boundaries without an artificial seam")
        let roundedRoof = RendererGeometry.driftPath(heights: Array(repeating: 18, count: 26), width: 100, topInset: 16)
        check(roundedRoof.boundingBoxOfPath.minX == 16 && roundedRoof.boundingBoxOfPath.maxX == 84, "snow starts and ends on the flat window roof")
        check(!roundedRoof.contains(CGPoint(x: 10, y: 1)) && !roundedRoof.contains(CGPoint(x: 90, y: 1)), "rounded corners remain completely empty")
        check(!roundedRoof.contains(CGPoint(x: 17, y: 12)), "snow cap rises smoothly inside the inset")
        check(roundedRoof.contains(CGPoint(x: 50, y: 16)), "central accumulation retains its height")
        let fractionalRoof = RendererGeometry.driftRidge(heights: Array(repeating: 10, count: 4), width: 10, topInset: 2.5)
        check(fractionalRoof.boundingBoxOfPath.minX == 2.5 && fractionalRoof.boundingBoxOfPath.maxX == 7.5, "fractional narrow-window inset is not rounded to the sample grid")
        check(RendererGeometry.driftPath(heights: [8, 8, 8], width: 8, topInset: 20).isEmpty, "excessive inset cannot invert the profile")
        var supportedHeights = Array(repeating: CGFloat(22), count: 26)
        for index in supportedHeights.indices where index <= 4 || index >= 21 { supportedHeights[index] = 0 }
        let supportedCap = RendererGeometry.driftPath(heights: supportedHeights, width: 100, topInset: 16)
        check(!supportedCap.contains(CGPoint(x: 22, y: 12)) && !supportedCap.contains(CGPoint(x: 78, y: 12)), "zero boundary samples do not collapse a tall cap to a steep four-point wall")
        check(supportedCap.contains(CGPoint(x: 50, y: 20)), "wide window caps preserve the central mound")
        for (width, inset, rounded) in [(CGFloat(100), CGFloat(16), true), (103, 15, true), (10, 2.5, true), (100, 0, false)] {
            let heights = (0...Int(ceil(width / 4))).map { CGFloat(14 + $0 % 7) }
            let contour = SnowContour(heights: heights, width: width, roundedEnds: rounded, topInset: inset)
            let path = RendererGeometry.driftPath(heights: heights, width: width, roundedEnds: rounded, topInset: inset)
            for x in stride(from: inset + 0.125, to: width - inset, by: 0.25) {
                let height = contour.height(at: x)
                if height > 0.03 { check(path.contains(CGPoint(x: x, y: height - 0.02)), "shared support height lies on the actual quadratic drawn contour") }
                check(!path.contains(CGPoint(x: x, y: height + 0.02)), "shared support height does not float above the rendered profile")
                let from = CGPoint(x: x - 2, y: height + 8)
                let to = CGPoint(x: x + 2, y: height - 8)
                let crossings = contour.crossings(from: from, to: to)
                check(!crossings.isEmpty, "diagonal sweep must find the smoothed visible roof")
                for crossing in crossings {
                    let trajectoryY = from.y + (to.y - from.y) * crossing.time
                    check(abs(crossing.point.y - contour.height(at: crossing.point.x)) < 0.00001,
                          "swept contact lies on the visible quadratic curve")
                    check(abs(crossing.point.y - trajectoryY) < 0.00001, "swept contact lies on the moving ball trajectory")
                }
            }
        }
        let collisionDisplay = CGRect(x: -200, y: -100, width: 400, height: 300)
        let collisionSurface = SnowSurface(id: "collision", frame: CGRect(x: -150, y: -80, width: 200, height: 30),
                                           kind: .window, occluders: [CGRect(x: -70, y: -60, width: 40, height: 60)], topInset: 16)
        let collisionDrift = SnowDrift(surface: collisionSurface, heights: (0...50).map { CGFloat($0 % 7) * 3 })
        let collisionBand = ParticleCollisionBand(drift: collisionDrift, displayFrame: collisionDisplay)!
        // Compare the optimized broad phase against the exposed contact rule on
        // the shared visible roof, including translated displays, edges and masks.
        for x in stride(from: CGFloat(-160), through: CGFloat(60), by: CGFloat(0.5)) {
            for y in stride(from: CGFloat(-60), through: CGFloat(-20), by: CGFloat(0.5)) {
                let next = CGPoint(x: x, y: y)
                let old = CGPoint(x: x - 0.5, y: y + 2)
                let top = collisionSurface.top + collisionDrift.visibleContour.height(at: x - collisionSurface.frame.minX)
                let expected = x >= collisionSurface.frame.minX && x <= collisionSurface.frame.maxX
                    && old.y >= top && next.y <= top && collisionSurface.isSupportExposed(CGPoint(x: x, y: top))
                let localOld = CGPoint(x: old.x - collisionDisplay.minX, y: old.y - collisionDisplay.minY)
                let localNext = CGPoint(x: next.x - collisionDisplay.minX, y: next.y - collisionDisplay.minY)
                check(collisionBand.intersects(from: localOld, to: localNext) == expected, "scalar collision matches the original masked contact rule")
            }
        }
        let taperSurface = SnowSurface(id: "taper", frame: CGRect(x: 0, y: -100, width: 100, height: 100), kind: .window, topInset: 16)
        let taperDrift = SnowDrift(surface: taperSurface, heights: supportedHeights)
        let taperBand = ParticleCollisionBand(drift: taperDrift, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100))!
        let taperedHeight = taperDrift.visibleContour.height(at: 22)
        check(!taperBand.intersects(from: CGPoint(x: 22, y: 22), to: CGPoint(x: 22, y: 21)), "snowflakes do not disappear above the lowered visible edge")
        check(taperBand.intersects(from: CGPoint(x: 22, y: taperedHeight + 0.1), to: CGPoint(x: 22, y: taperedHeight - 0.1)), "snowflakes land on the same tapered roof as balls")
        print("Renderer geometry: \(assertions) assertions passed")
    }
}
