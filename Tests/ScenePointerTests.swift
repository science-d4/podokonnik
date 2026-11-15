// Direct local-coordinate input routing; no window, SKView, event injection or GUI.
// swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift \
//   Tests/ScenePointerTests.swift -o /private/tmp/snezhno-scene-pointer-tests
import Foundation
import CoreGraphics

@main
enum ScenePointerTests {
    private static var assertions = 0
    private static let display = CGRect(x: -300, y: -100, width: 900, height: 800)
    private static let support = SnowSurface(id: "pointer-roof", frame: CGRect(x: -250, y: 100, width: 700, height: 200), kind: .window, topInset: 16)

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fputs("Pointer regression: \(message)\n", stderr); exit(1) }
    }
    private static func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - display.minX, y: point.y - display.minY) }
    private static func fixture() -> (SnowWorld, SnowScene) {
        let world = SnowWorld(seed: 85)
        world.syncSurfaces([support])
        world.prune(to: [display])
        for _ in 0..<350 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [display]) }
        return (world, SnowScene(world: world, displayFrame: display))
    }

    static func main() {
        let point = local(CGPoint(x: -150, y: 305))
        let (brushWorld, brush) = fixture()
        let initial = brushWorld.drifts[support.id]!.heights
        brush.pointerDown(at: point, timestamp: 0)
        brush.pointerDragged(at: local(CGPoint(x: -50, y: 305)), timestamp: 0.05)
        brush.pointerUp(timestamp: 0.06)
        check(brushWorld.drifts[support.id]!.heights == initial, "passive scene ignores all pointer commands")
        brush.playing = true
        brush.pointerDown(at: point, timestamp: 1)
        let afterDown = brushWorld.drifts[support.id]!.heights
        check(zip(afterDown, initial).contains { $0 < $1 }, "mitten down reaches the translated world support")
        brush.pointerDragged(at: local(CGPoint(x: -50, y: 305)), timestamp: 1.05)
        let afterDrag = brushWorld.drifts[support.id]!.heights
        check(zip(afterDrag, afterDown).contains { $0 < $1 }, "mitten drag paints the path")
        brush.pointerUp(timestamp: 1.06)
        brush.pointerDragged(at: local(CGPoint(x: 100, y: 305)), timestamp: 1.1)
        check(brushWorld.drifts[support.id]!.heights == afterDrag, "pointer up ends painting")
        brush.pointerDown(at: local(CGPoint(x: 200, y: 305)), timestamp: 2)
        let afterSecondDown = brushWorld.drifts[support.id]!.heights
        brush.cancelInteraction()
        brush.pointerDragged(at: local(CGPoint(x: 300, y: 305)), timestamp: 2.05)
        check(brushWorld.drifts[support.id]!.heights == afterSecondDown, "cancel ends painting without another brush command")
        brush.tool = .shovel
        brush.pointerDown(at: point, timestamp: 3)
        check(brushWorld.drifts[support.id]!.heights.allSatisfy { $0 == 0 }, "shovel routes to the selected support")

        let (ballWorld, scene) = fixture()
        scene.playing = true
        scene.tool = .snowball
        scene.pointerDown(at: point, timestamp: 0)
        check(ballWorld.balls.count == 1, "snowball down creates a ball from snow")
        let id = ballWorld.balls[0].id
        let start = ballWorld.balls[0].position
        scene.pointerDragged(at: local(CGPoint(x: -100, y: 610)), timestamp: 0.05)
        check(ballWorld.balls[0].position.x == -100 && ballWorld.balls[0].position.y > start.y,
              "direct y-up coordinates drag the ball in world coordinates")
        check(ballWorld.balls[0].surfaceID == nil, "lifting through the pointer command detaches the ball")
        scene.pointerUp(timestamp: 0.06)
        check(abs(ballWorld.balls[0].velocity.dx - 300) < 0.001 && abs(ballWorld.balls[0].velocity.dy - 300) < 0.001,
              "recent pointer release preserves the existing filtered throw velocity")

        scene.pointerDown(at: local(ballWorld.balls[0].position), timestamp: 1)
        check(ballWorld.balls.count == 1 && ballWorld.balls[0].id == id, "down on an existing ball grabs instead of creating")
        scene.pointerDragged(at: local(CGPoint(x: -50, y: 660)), timestamp: 1.05)
        scene.pointerUp(timestamp: 1.3)
        check(ballWorld.balls[0].velocity == .zero, "delayed release does not throw")
        scene.pointerDown(at: local(ballWorld.balls[0].position), timestamp: 2)
        scene.pointerDragged(at: local(CGPoint(x: 0, y: 680)), timestamp: 2.05)
        scene.cancelInteraction()
        let cancelled = ballWorld.balls[0].position
        scene.pointerDragged(at: local(CGPoint(x: 50, y: 690)), timestamp: 2.1)
        check(ballWorld.balls[0].position == cancelled && ballWorld.balls[0].velocity == .zero,
              "cancel releases the ball without a throw and ignores further drag")
        scene.pointerDown(at: local(cancelled), timestamp: 3)
        scene.pointerDragged(at: local(CGPoint(x: 100, y: 690)), timestamp: 3.05)
        scene.playing = false
        let stopped = ballWorld.balls[0].position
        scene.pointerDragged(at: local(CGPoint(x: 200, y: 650)), timestamp: 3.1)
        scene.pointerUp(timestamp: 3.11)
        check(ballWorld.balls[0].position == stopped && ballWorld.balls[0].velocity == .zero,
              "leaving game cancels the drag and rejects subsequent pointer commands")
        ballWorld.step(delta: 1.0 / 60, weather: SnowWeather(), activeRegions: [display])
        check(ballWorld.balls[0].position.y < stopped.y, "cancelled ball is no longer held by the world")
        scene.playing = true
        scene.pointerDown(at: local(ballWorld.balls[0].position), timestamp: 4)
        scene.pointerDragged(at: CGPoint(x: -999, y: 9999), timestamp: 4.05)
        check(ballWorld.balls[0].position.x == display.minX && ballWorld.balls[0].position.y == display.maxY,
              "direct input retains the active-display clamp")
        scene.pointerUp(timestamp: 4.3)
        print("Scene pointer routing: \(assertions) assertions passed")
    }
}
