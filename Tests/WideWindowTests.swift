import AppKit
import SpriteKit

@main
enum WideWindowTests {
    private static var checks = 0
    private static let frame = CGRect(x: -640, y: -100, width: 640, height: 420)
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }

    private static func sprites(_ scene: SnowScene) -> [SKSpriteNode] {
        scene.children.flatMap(\.children).compactMap { $0 as? SKSpriteNode }
            .filter { $0.name?.hasPrefix("snowflake.") == true }
            .sorted {
                if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
                if $0.position.y != $1.position.y { return $0.position.y < $1.position.y }
                return $0.zRotation < $1.zRotation
            }
    }

    private static func floorAccumulation() {
        let wide = SnowSurface(id: "wide", frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 396), kind: .window)
        let panel = CGRect(x: frame.minX + 200, y: frame.minY, width: 80, height: 200)
        let floorFrame = CGRect(x: frame.minX, y: frame.minY - 1, width: frame.width, height: 1)
        var floor = SnowSurface(id: "floor", frame: floorFrame, kind: .floor)
        floor.occluders = [WideWindowPolicy.floorOccluder(wide.frame, ordinaryWindow: true, display: frame), panel].compactMap { $0 }
        let world = SnowWorld(seed: 71)
        world.syncSurfaces([wide, floor]); world.prune(to: [frame])
        for _ in 0..<600 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame]) }
        let drift = world.drifts[floor.id]!
        check(drift.heights[25] > 10 && drift.heights[100] > 10,
              "floor accumulates under a full-width bottom-reaching ordinary window")
        check(drift.heights[60] == 0, "another foreground panel still masks the floor")
        check(floor.isExposed(CGPoint(x: frame.minX + 100, y: frame.minY + 28)),
              "the entire maximum-height floor silhouette remains exposed")
        floor.occluders = [WideWindowPolicy.floorOccluder(wide.frame, ordinaryWindow: false, display: frame)!]
        let covered = SnowWorld(seed: 71); covered.syncSurfaces([floor])
        for _ in 0..<100 { covered.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame]) }
        check(covered.drifts[floor.id]!.heights.allSatisfy { $0 == 0 },
              "an ordinary-window exemption must not remove a full-width panel mask")
    }

    private static func transitionsAndOrder() {
        let world = SnowWorld(seed: 19)
        var wide = SnowSurface(id: "wide-transition", frame: CGRect(x: frame.minX, y: frame.minY + 80, width: frame.width, height: 260), kind: .window)
        world.syncSurfaces([wide])
        let legacy = SnowScene(world: world, displayFrame: frame)
        let scalar = SnowScene(world: world, displayFrame: frame)
        var packet: [SnowParticleInstance] = []
        scalar.onParticles = { packet = $0.map { $0 } }
        legacy.weather = SnowWeather(intensity: .blizzard); scalar.weather = legacy.weather
        var time: TimeInterval = 0
        func step(_ delta: TimeInterval) {
            time += delta
            legacy.update(time); scalar.update(time)
            let visible = sprites(legacy).filter { !$0.isHidden }
            check(packet.count == visible.count, "transition packet and SpriteKit submit the same visible population")
            for node in visible {
                let geometry = SIMD4(Float(node.position.x), Float(node.position.y), Float(node.size.width), Float(node.zRotation))
                check(packet.contains { $0.geometry == geometry && $0.appearance.x == Float(node.alpha) },
                      "transition packet uses exactly the same effective alpha as SpriteKit")
            }
        }
        step(0)
        for _ in 0..<480 { step(1.0 / 60) }
        guard let tracked = sprites(legacy).first(where: {
            $0.position.x > 180 && $0.position.x < 460 && $0.position.y > 180 && $0.position.y < 240 && $0.alpha > 0.3
        }) else { fatalError("fixture needs an existing mature particle inside the wide window") }
        let naturalAlpha = tracked.alpha
        let population = legacy.renderingStatistics.particles
        wide.suppressesSnowfall = true; world.syncSurfaces([wide]); step(0)
        check(tracked.alpha == naturalAlpha && !tracked.isHidden, "focus activation starts from the current opacity, without a jump")
        check(legacy.renderingStatistics.particles == population, "changing focus alone cannot respawn particles")
        step(0.05); step(0.05)
        check(abs(tracked.alpha / naturalAlpha - 0.5) < 0.001, "active-wide fade reaches half opacity at 0.10 seconds")
        step(0.05); step(0.05)
        check(tracked.alpha == 0 && tracked.isHidden, "active-wide fade finishes at 0.20 seconds")
        wide.suppressesSnowfall = false; world.syncSurfaces([wide]); step(0)
        check(tracked.alpha == 0, "focus loss does not instantly reveal the hidden population")
        step(0.05); step(0.05)
        check(abs(tracked.alpha / naturalAlpha - 0.5) < 0.001, "focus-loss fade rises from zero to half opacity")
        let halfway = tracked.alpha
        let beforeToggle = legacy.renderingStatistics.nodes
        wide.suppressesSnowfall = true; world.syncSurfaces([wide]); step(0)
        check(tracked.alpha == halfway && legacy.renderingStatistics.nodes == beforeToggle,
              "rapid focus reversal continues from current alpha without creating nodes")
        step(0.05)
        check(abs(tracked.alpha / naturalAlpha - 0.25) < 0.001, "a reversed fade decreases smoothly")
        wide.suppressesSnowfall = false; world.syncSurfaces([wide]); step(0)
        check(abs(tracked.alpha / naturalAlpha - 0.25) < 0.001, "second reversal also preserves current alpha")
        for _ in 0..<4 { step(0.05) }
        check(abs(tracked.alpha - naturalAlpha) < 0.001, "a completed return restores the same natural opacity")

        let point = CGPoint(x: tracked.position.x + frame.minX, y: tracked.position.y + frame.minY)
        var narrow = SnowSurface(id: "narrow-transition", frame: CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100), kind: .window)
        world.syncSurfaces([narrow, wide]); step(0)
        check(tracked.isHidden, "a foreground narrow body hides an existing flake immediately")
        narrow.occluders = [wide.frame]
        world.syncSurfaces([wide, narrow]); step(0)
        check(!tracked.isHidden, "the same narrow body behind an inactive wide window cannot punch a false hole")
        narrow.occluders = [frame]
        world.syncSurfaces([narrow, wide]); step(0)
        check(tracked.isHidden, "roof-only ceiling occluders never subtract the window's body mask")
        narrow.bodyOccluders = [frame]
        world.syncSurfaces([narrow, wide]); step(0)
        check(!tracked.isHidden, "real foreground metadata subtracts covered body regions")
        narrow.bodyOccluders = []
        narrow.frame.origin.x += 200
        world.syncSurfaces([narrow, wide]); step(0)
        check(!tracked.isHidden, "moving a narrow body away invalidates the cached mask")
        narrow.frame.origin.x -= 200
        world.syncSurfaces([narrow, wide]); step(0)
        check(tracked.isHidden, "moving a narrow body over an existing flake hides it in the same frame")
        wide.suppressesSnowfall = true
        world.syncSurfaces([narrow, wide]); step(0); step(0.05)
        check(tracked.isHidden, "narrow body occlusion takes priority during a wide-window fade")

        wide.frame = frame
        world.syncSurfaces([wide])
        for _ in 0..<5 { step(0.05) }
        legacy.weather.wind = CGVector(dx: 1, dy: 0); scalar.weather = legacy.weather
        var newInside = 0
        var oldIDs = Set(sprites(legacy).map(ObjectIdentifier.init))
        for _ in 0..<60 {
            step(0.05)
            let nodes = sprites(legacy)
            for node in nodes where !oldIDs.contains(ObjectIdentifier(node)) && node.position.y > 0 && node.position.y < frame.height {
                let half = node.size.width / 2 * (abs(cos(node.zRotation)) + abs(sin(node.zRotation)))
                if node.position.x + half > 0 && node.position.x - half < frame.width {
                    newInside += 1
                    check(node.alpha == 0 && node.isHidden, "new or recycled particles inside an established wide mask cannot flash")
                }
            }
            oldIDs = Set(nodes.map(ObjectIdentifier.init))
        }
        check(newInside > 0, "the windy fixture actually exercises new particles born inside the active mask")
        print("Transition regression: focus fade0.20s, rapid reversals, narrow move/Z-order/body metadata, new hidden particles=\(newInside)")
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        floorAccumulation()
        let world = SnowWorld(seed: 8), referenceWorld = SnowWorld(seed: 8)
        let floor = SnowSurface(id: "floor", frame: CGRect(x: frame.minX, y: frame.minY - 1, width: frame.width, height: 1), kind: .floor)
        var window = SnowSurface(id: "wide", frame: CGRect(x: frame.minX, y: frame.minY + 80, width: frame.width, height: 260), kind: .window)
        window.suppressesSnowfall = true
        func sync(includeWindow: Bool = true) {
            var inactive = window; inactive.suppressesSnowfall = false
            world.syncSurfaces(includeWindow ? [window, floor] : [floor])
            referenceWorld.syncSurfaces(includeWindow ? [inactive, floor] : [floor])
        }
        sync()
        let legacy = SnowScene(world: world, displayFrame: frame)
        let scalar = SnowScene(world: world, displayFrame: frame)
        let reference = SnowScene(world: referenceWorld, displayFrame: frame)
        var packet: [SnowParticleInstance] = []
        scalar.onParticles = { packet = $0.map { $0 } }
        for scene in [legacy, scalar, reference] { scene.weather = SnowWeather(intensity: .blizzard) }
        var activeHidden = 0, insideInactive = 0, visibleBelow = 0, hiddenRetirement = 0
        var shrinkVisible = 0, removeVisible = 0
        var previousHiddenIDs: Set<ObjectIdentifier> = []
        for tick in 0..<1620 {
            if tick == 720 { window.suppressesSnowfall = false; sync() }
            if tick == 900 {
                window.suppressesSnowfall = true
                window.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 340)
                sync()
            }
            if tick == 1080 { window.suppressesSnowfall = false; sync() }
            if tick == 1260 {
                window.suppressesSnowfall = true
                window.frame = CGRect(x: frame.minX + 5, y: frame.minY + 80, width: frame.width - 10, height: 260)
                sync()
            }
            if tick == 1440 { sync(includeWindow: false) }
            let time = Double(tick) / 60
            reference.update(time); legacy.update(time); scalar.update(time)
            let all = sprites(legacy), expected = sprites(reference)
            if tick >= 900 && tick < 1080 {
                hiddenRetirement += previousHiddenIDs.subtracting(Set(all.map(ObjectIdentifier.init))).count
            }
            previousHiddenIDs = Set(all.filter(\.isHidden).map(ObjectIdentifier.init))
            check(all.count == expected.count, "masked flakes keep the same simulated population")
            for (node, baseline) in zip(all, expected) {
                check(node.position == baseline.position && node.zRotation == baseline.zRotation && node.alpha <= baseline.alpha + 0.00001,
                      "suppression changes opacity, never particle trajectory, and cannot exceed natural opacity")
            }
            let visible = all.filter { !$0.isHidden }
            let actual = packet.sorted {
                if $0.geometry.x != $1.geometry.x { return $0.geometry.x < $1.geometry.x }
                if $0.geometry.y != $1.geometry.y { return $0.geometry.y < $1.geometry.y }
                return $0.geometry.w < $1.geometry.w
            }
            check(actual.count == visible.count, "Metal packet contains exactly the visible legacy particles")
            for (instance, node) in zip(actual, visible) {
                check(instance.geometry == SIMD4(Float(node.position.x), Float(node.position.y), Float(node.size.width), Float(node.zRotation))
                      && instance.appearance.x == Float(node.alpha), "both backends submit identical visible geometry and opacity")
            }
            let active = tick < 720 || tick >= 900 && tick < 1080
            if active {
                let local = window.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
                for node in all {
                    // Independently transform all four quad corners. A visible
                    // texture must not overlap the active wide window's interior.
                    let half = node.size.width / 2
                    let corners = [CGPoint(x: -half, y: -half), CGPoint(x: half, y: -half),
                                   CGPoint(x: half, y: half), CGPoint(x: -half, y: half)].map { point in
                        CGPoint(x: node.position.x + point.x * cos(node.zRotation) - point.y * sin(node.zRotation),
                                y: node.position.y + point.x * sin(node.zRotation) + point.y * cos(node.zRotation))
                    }
                    if !node.isHidden && !(900..<912).contains(tick) {
                        check(!corners.contains(where: local.contains), "visible rotated quad cannot protrude into the active window")
                    }
                    if node.isHidden { activeHidden += 1 }
                    if tick < 720 && node.position.y < 70 && !node.isHidden { visibleBelow += 1 }
                }
            } else {
                if tick < 1260 || tick >= 1440 {
                    check(all.allSatisfy { !$0.isHidden }, "focus loss and removal restore every surviving or pooled sprite")
                } else {
                    check(all.contains(where: \.isHidden), "a shrunken ordinary window immediately masks its visible body")
                }
                if tick < 900 { insideInactive += all.filter { $0.position.y > 100 && $0.position.y < 300 }.count }
                if tick >= 1260 && tick < 1440 { shrinkVisible += visible.count }
                if tick >= 1440 { removeVisible += visible.count }
            }
        }
        check(activeHidden > 100, "the fixture actually exercises masked particles")
        check(insideInactive > 100, "inactive wide window admits falling flakes through its interior")
        check(visibleBelow > 100, "masked flakes continue and reappear below the short wide window")
        check(hiddenRetirement > 0, "bottom-reaching masking exercises hidden sprites reaching retirement")
        check(shrinkVisible > 100 && removeVisible > 100, "shrink and removal leave live visible snowfall")
        transitionsAndOrder()
        print("Wide windows: \(checks) checks passed; hidden=\(activeHidden), inactive interior=\(insideInactive), below=\(visibleBelow), hidden retirement=\(hiddenRetirement); both particle paths")
    }
}
