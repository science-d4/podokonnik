import Foundation
import CoreGraphics

private struct CoreFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct CoreTests {
    static let region = CGRect(x: -500, y: 0, width: 2000, height: 1000)
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw CoreFailure(description: message) }
    }
    static func close(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001, _ message: String) throws {
        try require(abs(a - b) <= tolerance, "\(message): \(a) != \(b)")
    }
    static func window(_ id: String = "window", x: CGFloat = 0, top: CGFloat = 300, width: CGFloat = 600) -> SnowSurface {
        SnowSurface(id: id, frame: CGRect(x: x, y: top - 200, width: width, height: 200), kind: .window)
    }
    static func advance(_ world: SnowWorld, _ seconds: Double, intensity: SnowIntensity = .blizzard, regions: [CGRect] = [region]) {
        var weather = SnowWeather()
        weather.intensity = intensity
        for _ in 0..<Int((seconds * 10).rounded()) { world.step(delta: 0.1, weather: weather, activeRegions: regions) }
    }
    static func filled(_ surface: SnowSurface = window(), seconds: Double = 35) -> SnowWorld {
        let world = SnowWorld(seed: 123)
        world.syncSurfaces([surface])
        advance(world, seconds)
        return world
    }
    static func area(_ drift: SnowDrift) -> CGFloat {
        guard drift.heights.count > 1 else { return 0 }
        return (0..<(drift.heights.count - 1)).reduce(0) { total, index in
            let xa = min(CGFloat(index) * 4, drift.surface.frame.width)
            let xb = min(CGFloat(index + 1) * 4, drift.surface.frame.width)
            return total + (drift.heights[index] + drift.heights[index + 1]) * 0.5 * (xb - xa)
        }
    }
    static func totalMass(_ world: SnowWorld) -> CGFloat {
        world.drifts.values.reduce(0) { $0 + area($1) } + world.balls.reduce(0) { $0 + .pi * $1.radius * $1.radius }
    }
    static func create(_ world: SnowWorld, x: CGFloat) throws -> UUID {
        let target = world.surfaces.first!
        guard let id = world.beginSnowball(at: CGPoint(x: x, y: target.top + 5)) else {
            throw CoreFailure(description: "Ball creation failed at \(x)")
        }
        return id
    }
    static func place(_ world: SnowWorld, id: UUID, at position: CGPoint) throws {
        guard let ball = world.balls.first(where: { $0.id == id }) else { throw CoreFailure(description: "Missing ball") }
        _ = world.beginDrag(at: ball.position)
        world.drag(to: position)
        world.endDrag()
    }

    static func smallSnowman(_ world: SnowWorld) throws -> [UUID] {
        let bottom = try create(world, x: 60); world.endDrag()
        let middle = try create(world, x: 250); world.endDrag()
        let head = try create(world, x: 450); world.endDrag()
        let base = world.balls.first { $0.id == bottom }!
        try place(world, id: middle, at: CGPoint(x: base.position.x, y: base.position.y + 20))
        advance(world, 0.8)
        let mid = world.balls.first { $0.id == middle }!
        try place(world, id: head, at: CGPoint(x: mid.position.x, y: mid.position.y + 20))
        advance(world, 0.8)
        try require(world.snowmen.count == 1, "Fixture must contain a stable snowman")
        return [bottom, middle, head]
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("shake debris moves and expires during manual window drag", {
                let support = window(top: 600)
                let world = filled(support)
                try require(world.placeSnowman(on: support, x: 300), "fixture contains a snowman")
                let balls = world.balls
                world.setObjectsFrozen(true)
                world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: 1200, dy: 0))
                let initial = world.debris
                try require(!initial.isEmpty, "shaken window produces visible fragments during drag")
                advance(world, 0.3)
                try require(world.debris.count == initial.count, "the trail remains visible while dragging")
                try require(zip(world.debris, initial).allSatisfy { $0.position != $1.position && $0.lifetime < $1.lifetime },
                            "every fragment moves and ages before mouse release")
                try require(zip(world.balls, balls).allSatisfy { $0.position == $1.position && $0.velocity.dx == $1.velocity.dx && $0.velocity.dy == $1.velocity.dy },
                            "snowman physics remains paused while fragments move")
                advance(world, 1.3)
                try require(world.debris.isEmpty, "the trail expires even if the window is still held")
                try require(world.snowmen.count == 1, "the frozen snowman remains intact")
            }),
            ("manual window drag pauses objects and protects overlapping snowmen", {
                let a = window("a", x: 0), b = window("b", x: 400)
                let world = SnowWorld(seed: 99)
                world.syncSurfaces([a, b])
                try require(world.placeSnowman(on: a, x: 180) && world.placeSnowman(on: b, x: 580),
                            "two separate stable snowmen must be created")
                let ids = world.snowmen.map(\.ballIDs)
                let old = world.balls
                world.setObjectsFrozen(true)
                var moved = b
                moved.frame.origin.x -= 400
                world.syncSurfaces([a, moved])
                advance(world, 1)
                try require(world.snowmen.map(\.ballIDs) == ids, "a moving window must keep both snowmen intact")
                for ball in old {
                    let current = world.balls.first { $0.id == ball.id }!
                    try close(current.position.x, ball.position.x + (ball.surfaceID == b.id ? -400 : 0),
                              "each ball follows only its own window during the pause")
                    try close(current.position.y, ball.position.y, "paused ball does not move vertically")
                    try require(current.velocity.dx == ball.velocity.dx && current.velocity.dy == ball.velocity.dy,
                                "paused ball keeps its velocity")
                }
                world.setObjectsFrozen(false)
                advance(world, 1)
                try require(world.snowmen.map(\.ballIDs) == ids, "overlap at release must not break either snowman")
                world.syncSurfaces([a, b])
                advance(world, 1)
                try require(world.snowmen.map(\.ballIDs) == ids, "separation restores normal independent stacks")
                var overlappingAgain = moved
                overlappingAgain.frame.origin.x += 8
                world.syncSurfaces([a, overlappingAgain])
                advance(world, 0.2)
                try require(world.balls.contains { ball in
                    let original = old.first { $0.id == ball.id }!
                    let expected = original.position.x + (ball.surfaceID == b.id ? -392 : 0)
                    return abs(ball.position.x - expected) > 1
                }, "collisions are active again after the objects separate")

                let falling = filled(seconds: 30)
                let id = try create(falling, x: 300)
                falling.endDrag(velocity: CGVector(dx: 70, dy: 100))
                let before = falling.balls.first { $0.id == id }!
                falling.setObjectsFrozen(true)
                advance(falling, 1)
                let paused = falling.balls.first { $0.id == id }!
                try require(paused.position == before.position && paused.velocity.dx == before.velocity.dx
                            && paused.velocity.dy == before.velocity.dy, "a free ball keeps position and velocity while frozen")
                falling.setObjectsFrozen(false)
                advance(falling, 0.1)
                try require(falling.balls.first { $0.id == id }!.position != paused.position,
                            "a free ball resumes motion immediately after release")
            }),
            ("deterministic deposition and intensity", {
                let a = filled(seconds: 20)
                let b = filled(seconds: 20)
                try require(a.drifts["window"]!.heights == b.drifts["window"]!.heights, "Equal seed/time must give equal profiles")
                let light = SnowWorld(); light.syncSurfaces([window()]); advance(light, 20, intensity: .light)
                try require(area(a.drifts["window"]!) > area(light.drifts["window"]!) * 3, "Blizzard must deposit distinctly more snow")
                try require(Set(a.drifts["window"]!.heights).count > 10, "Contour must not be a flat slab")
            }),
            ("height and transient limits", {
                let world = filled(seconds: 100)
                try require(world.drifts["window"]!.heights.allSatisfy { $0 >= 0 && $0 <= 28 }, "Height must remain bounded")
                for _ in 0..<200 { world.brush(at: CGPoint(x: 200, y: 304), radius: 100) }
                try require(world.debris.count <= 384, "Debris must have a hard cap")
                advance(world, 2)
                try require(world.debris.count < 384, "Debris must expire")
            }),
            ("saturated snow keeps a stationary uneven roof", {
                let world = filled(seconds: 150)
                let saturated = world.drifts["window"]!.heights
                try require(saturated.max()! - saturated.min()! > 4,
                            "Long snowfall must retain distinct hills instead of converging to a flat height cap")
                advance(world, 150)
                try require(world.drifts["window"]!.heights == saturated,
                            "The saturated envelope is stationary rather than animated noise")
                world.syncSurfaces([window(x: -180, top: 500)])
                try require(world.drifts["window"]!.heights == saturated, "Translation must preserve the local pattern")
                advance(world, 100)
                try require(world.drifts["window"]!.heights == saturated,
                            "A moved saturated window must keep the same local cap during further snowfall")
            }),
            ("local height limits survive resize and profile relaxation", {
                let world = filled(window(width: 403), seconds: 150)
                let limits = world.drifts["window"]!.heightLimits
                let mass = totalMass(world)
                world.syncSurfaces([window(x: -120, top: 420, width: 601)])
                let expanded = world.drifts["window"]!
                try require(expanded.heightLimits.prefix(101).elementsEqual(limits.prefix(101)),
                            "Width changes retain the local cap at every unchanged grid position")
                try close(totalMass(world), mass, tolerance: 0.01, "Expansion conserves saturated snow mass under the new cap")
                try require(zip(expanded.heights, expanded.heightLimits).allSatisfy { $0 <= $1 + 1e-9 },
                            "Expansion mass correction cannot exceed the local height limit")
                world.syncSurfaces([window(x: -120, top: 420, width: 203)])
                let shrunk = world.drifts["window"]!
                try require(totalMass(world) < mass, "Shrink removes only snow beyond the retained area")
                try require(zip(shrunk.heights, shrunk.heightLimits).allSatisfy { $0 <= $1 + 1e-9 },
                            "A partial last cell must obey its newly sampled cap")
                world.brush(at: CGPoint(x: -20, y: 424), radius: 14)
                for _ in 0..<500 {
                    world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [region])
                    let drift = world.drifts["window"]!
                    try require(zip(drift.heights, drift.heightLimits).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= $1 + 1e-9 },
                                "Deposition and slope transfers must stay under each cached local cap")
                }
                let rebuilt = SnowWorld(seed: 999)
                rebuilt.syncSurfaces([window(x: 400, top: 600, width: 203)])
                try require(rebuilt.drifts["window"]!.heightLimits == shrunk.heightLimits,
                            "Height limits depend on surface ID and local X, not world RNG or origin")
            }),
            ("occlusion, topmost picking and isolated brush", {
                let front = window("front", x: 150, top: 360, width: 200)
                var rear = window("rear")
                rear.occluders = [front.frame]
                let world = SnowWorld(); world.syncSurfaces([front, rear]); advance(world, 30)
                let heights = world.drifts["rear"]!.heights
                try close(heights[60], 0, "Covered rear must not collect snow")
                try require(heights[15] > 0, "Exposed rear must collect snow")
                try require(world.surface(at: CGPoint(x: 240, y: 304)) == nil, "Hidden rear must not be interactive")
                let frontArea = area(world.drifts["front"]!)
                let rearArea = area(world.drifts["rear"]!)
                world.brush(at: CGPoint(x: 60, y: 304))
                try close(area(world.drifts["front"]!), frontArea, "Brush must not affect another support")
                try require(area(world.drifts["rear"]!) < rearArea, "Brush removes visible local snow")
            }),
            ("move and resize preserve local profile", {
                let original = window(width: 400)
                let world = filled(original)
                let profile = world.drifts["window"]!.heights
                let id = try create(world, x: 80); world.endDrag()
                let oldBall = world.balls.first { $0.id == id }!
                let profileAfterBall = world.drifts["window"]!.heights
                world.syncSurfaces([window(x: -180, top: 500, width: 400)])
                try require(world.drifts["window"]!.heights == profileAfterBall, "Move must not regenerate profile")
                try close(world.balls[0].position.x, oldBall.position.x - 180, "Attached ball moves horizontally")
                try close(world.balls[0].position.y, oldBall.position.y + 200, "Attached ball moves vertically")
                world.syncSurfaces([window(x: -180, top: 500, width: 600)])
                try require(world.drifts["window"]!.heights.prefix(80).elementsEqual(profileAfterBall.prefix(80)), "Growth must not stretch retained interior")
                try require(world.drifts["window"]!.heights.suffix(20).allSatisfy { $0 == 0 }, "New area must be empty")
                world.syncSurfaces([window(x: -180, top: 500, width: 200)])
                try require(world.drifts["window"]!.heights.count == 51, "Shrink must remove clipped samples")
                try require(profile.count == 101, "Original profile geometry")
            }),
            ("partial resize conserves mass", {
                let world = filled(window(width: 403))
                let before = area(world.drifts["window"]!)
                world.syncSurfaces([window(width: 601)])
                try close(area(world.drifts["window"]!), before, tolerance: 0.01, "Partial endpoint must not create mass")
                world.syncSurfaces([window(width: 203)])
                try require(area(world.drifts["window"]!) < before, "Shrink removes clipped snow")
            }),
            ("creation, rolling and minimum mass", {
                let empty = SnowWorld(); empty.syncSurfaces([window()])
                try require(empty.beginSnowball(at: CGPoint(x: 50, y: 304)) == nil, "No snowball from empty support")
                let world = filled()
                let before = totalMass(world)
                let id = try create(world, x: 60)
                try close(totalMass(world), before, tolerance: 0.01, "Creation conserves mass")
                let first = world.balls.first { $0.id == id }!
                try close(first.radius, 8, "Minimum radius")
                world.drag(to: CGPoint(x: 440, y: 305))
                try require(world.balls[0].radius > first.radius, "Rolling grows the snowball")
                try close(totalMass(world), before, tolerance: 0.01, "Rolling conserves profile plus sphere area")
                try require(world.balls[0].radius <= 36, "Radius maximum")
                world.endDrag()
            }),
            ("small pointer movements lift existing and newly created balls", {
                for newlyCreated in [false, true] {
                    let world = filled()
                    world.prune(to: [region])
                    let id = try create(world, x: 100)
                    let initial = world.balls.first { $0.id == id }!
                    let pickup: CGPoint
                    if newlyCreated {
                        pickup = CGPoint(x: 100, y: 305)
                    } else {
                        world.endDrag()
                        pickup = CGPoint(x: initial.position.x - 3, y: initial.position.y + 2)
                        try require(world.beginDrag(at: pickup) == id, "An off-center grab must select the existing ball")
                    }
                    for step in 1...80 {
                        world.drag(to: CGPoint(x: pickup.x, y: pickup.y + CGFloat(step) * 0.75))
                        world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .light), activeRegions: [region])
                    }
                    let lifted = world.balls.first { $0.id == id }!
                    try require(lifted.surfaceID == nil && lifted.position.y >= initial.position.y + 59,
                                "Repeated sub-point moves must accumulate into a real lift")
                    try close(lifted.position.x, initial.position.x, "The grab offset preserves horizontal position")
                    try close(lifted.radius, initial.radius, "Vertical lifting must not collect rolling snow")
                    world.endDrag()
                    world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .light), activeRegions: [region])
                    try require(world.balls.first { $0.id == id }!.position.y < lifted.position.y,
                                "Release after a gradual lift resumes falling in the active region")
                }
            }),
            ("gradual lift carry and release builds a snowman", {
                let world = filled()
                world.prune(to: [region])
                let bottom = try create(world, x: 100); world.endDrag()
                let middle = try create(world, x: 280); world.endDrag()
                let head = try create(world, x: 470); world.endDrag()
                func carry(_ id: UUID, onto supportID: UUID) throws {
                    let moving = world.balls.first { $0.id == id }!
                    try require(world.beginDrag(at: moving.position) == id, "User path starts by grabbing a ball")
                    let liftedY = moving.position.y + 80
                    for step in 1...80 {
                        world.drag(to: CGPoint(x: moving.position.x, y: moving.position.y + CGFloat(step)))
                        world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .light), activeRegions: [region])
                    }
                    try require(world.balls.first { $0.id == id }!.surfaceID == nil,
                                "A smooth upward gesture must detach before horizontal transport")
                    let support = world.balls.first { $0.id == supportID }!
                    let horizontalSteps = max(1, Int(ceil(abs(support.position.x - moving.position.x) / 2)))
                    for step in 1...horizontalSteps {
                        let x = moving.position.x + (support.position.x - moving.position.x) * CGFloat(step) / CGFloat(horizontalSteps)
                        world.drag(to: CGPoint(x: x, y: liftedY))
                        world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .light), activeRegions: [region])
                    }
                    let currentSupport = world.balls.first { $0.id == supportID }!
                    let destinationY = currentSupport.position.y + currentSupport.radius + moving.radius + 2
                    let downwardSteps = max(1, Int(ceil(liftedY - destinationY)))
                    for step in 1...downwardSteps {
                        let y = liftedY + (destinationY - liftedY) * CGFloat(step) / CGFloat(downwardSteps)
                        world.drag(to: CGPoint(x: currentSupport.position.x, y: y))
                        world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .light), activeRegions: [region])
                    }
                    world.endDrag(velocity: CGVector(dx: 0, dy: -60))
                    advance(world, 0.8, intensity: .light)
                    let placed = world.balls.first { $0.id == id }!
                    let base = world.balls.first { $0.id == supportID }!
                    try close(placed.radius, moving.radius, "Carrying through the air must not roll or grow the ball")
                    try close(placed.position.y - base.position.y,
                              SnowballContact.stackedCenterDistance(radius: placed.radius, otherRadius: base.radius), tolerance: 0.05,
                              "A gradual release settles onto the chosen lower ball")
                }
                try carry(middle, onto: bottom)
                try carry(head, onto: middle)
                try require(world.snowmen.count == 1 && world.snowmen[0].ballIDs == [bottom, middle, head],
                            "The complete gradual pointer path must build a decorated snowman")
            }),
            ("clear one support and all", {
                let world = SnowWorld(); world.syncSurfaces([window("a"), window("b", top: 700)]); advance(world, 30)
                _ = try create(world, x: 50); world.endDrag()
                let untouched = area(world.drifts["b"]!)
                world.clear(surfaceID: "a")
                try close(area(world.drifts["a"]!), 0, "Selected drift must clear")
                try close(area(world.drifts["b"]!), untouched, "Other support must survive shovel")
                try require(world.balls.isEmpty, "Shovel removes associated balls")
                world.clearAll()
                try require(world.drifts.values.allSatisfy { area($0) == 0 } && world.debris.isEmpty, "Clear all removes transient snow")
                try require(world.surfaces.count == 2, "Clear must not discard geometry")
            }),
            ("floor sweep is bounded exposed and preserves player objects", {
                var floor = SnowSurface(id: "floor", frame: CGRect(x: 0, y: 0, width: 600, height: 0), kind: .floor)
                let other = window("other", x: 700, top: 700, width: 200)
                var dock = window("dock", x: 800, top: 80, width: 300); dock.kind = .dock
                let world = SnowWorld(seed: 123)
                world.syncSurfaces([floor, other, dock]); advance(world, 35)
                let ids = try smallSnowman(world)
                let positions = world.balls.map(\.position)
                floor.occluders = [CGRect(x: 200, y: 0, width: 100, height: 60)]
                world.syncSurfaces([floor, other, dock])
                let retained = world.drifts[floor.id]!.heights
                let otherHeights = world.drifts[other.id]!.heights
                let dockHeights = world.drifts[dock.id]!.heights
                world.sweepFloor(surfaceID: floor.id, fromX: -1000, toX: 260)
                let swept = world.drifts[floor.id]!.heights
                for index in swept.indices {
                    let x = CGFloat(index) * SnowDrift.spacing
                    let expected: CGFloat = x < 200 ? 0 : retained[index]
                    try close(swept[index], expected, "Sweep only touches exposed sample columns inside its clamped range")
                }
                world.sweepFloor(surfaceID: other.id, fromX: -1000, toX: 2000)
                world.sweepFloor(surfaceID: dock.id, fromX: -1000, toX: 2000)
                try require(world.drifts[other.id]!.heights == otherHeights && world.drifts[dock.id]!.heights == dockHeights,
                            "The cleaner cannot remove window or Dock snow")
                world.sweepFloor(surfaceID: floor.id, fromX: 10_000, toX: -10_000)
                try require(world.drifts[floor.id]!.heights.enumerated().allSatisfy { index, value in
                    (200...300).contains(CGFloat(index) * SnowDrift.spacing) ? value == retained[index] : value == 0
                }, "Reverse out-of-range sweep is clamped and retains occluded columns")
                try require(world.balls.map(\.id) == ids && world.balls.map(\.position) == positions,
                            "Sweeping must not delete or move balls")
                try require(world.snowmen.count == 1 && world.snowmen[0].ballIDs == ids, "Sweeping must preserve a snowman's support links")
                floor.isVisible = false; world.syncSurfaces([floor, other, dock])
                let hidden = world.drifts[floor.id]!.heights
                world.sweepFloor(surfaceID: floor.id, fromX: -1000, toX: 1000)
                try require(world.drifts[floor.id]!.heights == hidden, "Hidden floor snow is not swept")
            }),
            ("window shedding clears snow with bounded visible debris and preserves snowmen", {
                var support = window()
                let world = filled(support)
                let ids = try smallSnowman(world)
                let positions = world.balls.map(\.position)
                support.occluders = [CGRect(x: 300, y: 290, width: 100, height: 100)]
                world.syncSurfaces([support])
                let before = world.debris.count
                world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: 100_000, dy: -100_000))
                let emitted = world.debris.dropFirst(before)
                try require(!emitted.isEmpty && emitted.count <= 96, "One shake produces a bounded visible burst")
                try require(emitted.allSatisfy { support.isExposed($0.position) }, "Hidden snow cannot be a visible burst source")
                try require(emitted.allSatisfy { hypot($0.velocity.dx, $0.velocity.dy) <= 360.0001 }, "Inherited shake velocity is bounded")
                try require(world.drifts[support.id]!.heights.allSatisfy { $0 == 0 }, "A shake clears the entire window drift")
                try require(world.balls.map(\.id) == ids && world.balls.map(\.position) == positions,
                            "Shedding must not delete or move balls")
                try require(world.snowmen.count == 1 && world.snowmen[0].ballIDs == ids, "Shedding keeps the snowman group")
                let count = world.debris.count
                world.shedSnow(surfaceID: support.id, velocity: .zero)
                try require(world.debris.count == count, "An empty drift cannot manufacture more debris")
            }),
            ("a window translated off the display keeps its snowman", {
                let support = window()
                let world = filled(support)
                world.prune(to: [region])
                let ids = try smallSnowman(world)
                let heights = world.drifts[support.id]!.heights
                for outside in [window(x: 3000), window(top: -300)] {
                    world.syncSurfaces([outside])
                    advance(world, 0.5)
                    try require(world.balls.map(\.id) == ids && world.snowmen.first?.ballIDs == ids,
                                "off-display coordinates cannot cull balls attached to a live window")
                }
                world.syncSurfaces([support])
                try require(world.drifts[support.id]?.heights == heights && world.snowmen.first?.ballIDs == ids,
                            "the same window brings back its profile and snowman")
                world.syncSurfaces([])
                try require(world.balls.isEmpty && world.snowmen.isEmpty, "closing that window still removes its snowman")
            }),
            ("hidden and non-window shedding is safe and global debris stays bounded", {
                for hiddenFlag in [false, true] {
                    var support = window()
                    let world = filled(support)
                    if hiddenFlag { support.isVisible = false }
                    else { support.occluders = [region] }
                    world.syncSurfaces([support])
                    let debrisBefore = world.debris.count
                    world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: CGFloat.nan, dy: CGFloat.infinity))
                    try require(world.debris.count == debrisBefore, "A hidden surface or fully covered contour must not emit debris")
                    try require(world.drifts[support.id]!.heights.allSatisfy { $0 == 0 }, "Explicit shedding clears even retained hidden snow")
                }
                for kind in [SurfaceKind.floor, .dock] {
                    var support = window(); support.kind = kind
                    let world = filled(support)
                    let before = world.drifts[support.id]!.heights
                    let debrisBefore = world.debris.count
                    world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: 500, dy: 500))
                    try require(world.drifts[support.id]!.heights == before && world.debris.count == debrisBefore,
                                "Window shedding cannot affect a floor or Dock")
                }
                let world = SnowWorld(seed: 123)
                let surfaces = (0..<10).map { window("burst-\($0)") }
                world.syncSurfaces(surfaces); advance(world, 35)
                for surface in surfaces { world.shedSnow(surfaceID: surface.id, velocity: CGVector(dx: 1000, dy: 1000)) }
                try require(world.debris.count == 384, "Repeated shedding obeys the existing global debris cap")
            }),
            ("shake leaves a dense distributed trail against the movement", {
                var support = window(x: 300, top: 600)
                let world = filled(support)
                support.isVisible = false; world.syncSurfaces([support]); advance(world, 1.6)
                support.isVisible = true
                support.occluders = [CGRect(x: 550, y: 590, width: 100, height: 100)]
                world.syncSurfaces([support])
                world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: 1200, dy: 0))
                let emitted = world.debris
                try require(emitted.count > 48 && emitted.count <= 96, "A filled edge needs a denser yet bounded shake trail")
                try require(emitted.allSatisfy { support.isExposed($0.position) }, "The dense trail still excludes covered parts of the edge")
                let xs = emitted.map { $0.position.x }
                try require(xs.max()! - xs.min()! > support.frame.width * 0.9,
                            "Fragments must span the visible edge, including both ends")
                try require(emitted.filter { $0.position.x < 550 }.count >= 24 && emitted.filter { $0.position.x > 650 }.count >= 24,
                            "Both exposed sections receive a substantial share of fragments")
                let visibleArea = emitted.reduce(CGFloat.zero) { $0 + .pi * $1.radius * $1.radius }
                try require(visibleArea > 1800 && emitted.allSatisfy { $0.radius >= 2.2 && $0.radius <= 4.5 },
                            "The trail must contain visible snow clumps rather than sparse subpixel dust")
                try require(emitted.allSatisfy { $0.lifetime >= 1.1 && $0.lifetime <= 1.5 && $0.velocity.dx < -200 },
                            "Fragments persist for 1–1.5 seconds and initially oppose a rightward jerk")
                let meanX = xs.reduce(0, +) / CGFloat(xs.count)
                support.isVisible = false; world.syncSurfaces([support])
                advance(world, 0.8)
                try require(world.debris.count == emitted.count, "The complete trail must still exist after 0.8 seconds")
                let laterX = world.debris.reduce(CGFloat.zero) { $0 + $1.position.x } / CGFloat(world.debris.count)
                try require(laterX < meanX - 160, "The visible trail travels behind the window instead of following it")
                advance(world, 0.8)
                try require(world.debris.isEmpty, "The short effect must finish by 1.6 seconds without a persistent particle tail")
            }),
            ("shake debris expires offscreen but pauses on connected inactive displays", {
                let left = CGRect(x: 0, y: 0, width: 600, height: 1000)
                let right = CGRect(x: 600, y: 0, width: 600, height: 1000)
                var support = window(x: 0, top: 600, width: 300)
                let world = filled(support)
                world.prune(to: [left])
                support.isVisible = false; world.syncSurfaces([support]); advance(world, 1.6, regions: [left])
                support.isVisible = true; world.syncSurfaces([support])
                world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: 1200, dy: 0))
                try require(!world.debris.isEmpty, "Edge fixture must start with a visible trail")
                support.isVisible = false; world.syncSurfaces([support])
                advance(world, 1.6, regions: [left])
                try require(world.debris.isEmpty, "Fragments escaping the physical display cannot permanently occupy the global budget")

                var pausedSupport = window(x: 750, top: 600, width: 300)
                let paused = filled(pausedSupport)
                paused.prune(to: [left, right])
                pausedSupport.isVisible = false; paused.syncSurfaces([pausedSupport]); advance(paused, 1.6, regions: [left, right])
                pausedSupport.isVisible = true; paused.syncSurfaces([pausedSupport])
                paused.shedSnow(surfaceID: pausedSupport.id, velocity: CGVector(dx: 1200, dy: 0))
                let retained = paused.debris
                paused.setObjectsFrozen(true)
                pausedSupport.isVisible = false; paused.syncSurfaces([pausedSupport])
                advance(paused, 2, regions: [left])
                try require(paused.debris.map(\.position) == retained.map(\.position)
                            && paused.debris.map(\.lifetime) == retained.map(\.lifetime),
                            "A connected inactive display freezes its own trail even during a manual window drag")
                advance(paused, 1.6, regions: [left, right])
                try require(paused.debris.isEmpty, "Resuming the connected display lets the retained effect finish normally")
            }),
            ("hidden Dock retains state, removed window deletes state", {
                var dock = window("dock", top: 80, width: 300); dock.kind = .dock
                let world = filled(dock)
                _ = try create(world, x: 60); world.endDrag()
                let before = world.drifts["dock"]!.heights
                let ball = world.balls[0]
                dock.isVisible = false; world.syncSurfaces([dock]); advance(world, 2)
                try require(world.drifts["dock"]!.heights == before, "Hidden Dock must not accumulate")
                try require(world.balls[0].position == ball.position, "Hidden Dock objects must freeze")
                try require(world.beginDrag(at: ball.position) == nil, "Hidden Dock ball must not be interactive")
                dock.isVisible = true; world.syncSurfaces([dock])
                try require(world.drifts["dock"]!.heights == before, "Dock reappearance restores snow")
                world.syncSurfaces([])
                try require(world.balls.isEmpty && world.drifts.isEmpty, "Removed support must remove its objects")
            }),
            ("pause and oversized delta do not catch up", {
                let world = filled()
                let before = world.drifts["window"]!.heights
                world.step(delta: 500, weather: SnowWeather(), activeRegions: [])
                try require(world.drifts["window"]!.heights == before, "Paused world must freeze")
                let a = filled(seconds: 1), b = filled(seconds: 1)
                a.step(delta: 1000, weather: SnowWeather(), activeRegions: [region])
                b.step(delta: 0.1, weather: SnowWeather(), activeRegions: [region])
                try require(a.drifts["window"]!.heights == b.drifts["window"]!.heights, "Long delta must be capped to 100ms")
                a.step(delta: .nan, weather: SnowWeather(), activeRegions: [region])
                try require(a.drifts["window"]!.heights.allSatisfy(\.isFinite), "NaN delta must not corrupt state")
            }),
            ("swept falling collision", {
                let world = filled()
                let id = try create(world, x: 100); world.endDrag()
                try place(world, id: id, at: CGPoint(x: 100, y: 850))
                _ = world.beginDrag(at: world.balls[0].position)
                world.endDrag(velocity: CGVector(dx: 0, dy: -10_000))
                advance(world, 2)
                let ball = world.balls.first { $0.id == id }!
                try require(ball.surfaceID == "window", "Fast fall must land on support")
                try require(ball.position.y >= 300 + ball.radius, "Ball must not tunnel below support")
                try require(abs(ball.velocity.dy) < 0.01, "Resting ball must not jitter vertically")
            }),
            ("stack, snowman, dragging and support motion", {
                let world = filled()
                let bottom = try create(world, x: 60); world.endDrag()
                let middle = try create(world, x: 250); world.endDrag()
                let head = try create(world, x: 450); world.endDrag()
                advance(world, 0.7)
                let base = world.balls.first { $0.id == bottom }!
                try place(world, id: middle, at: CGPoint(x: base.position.x, y: base.position.y + 20))
                advance(world, 0.7)
                let mid = world.balls.first { $0.id == middle }!
                try require(mid.surfaceID == "window", "Middle inherits support")
                try place(world, id: head, at: CGPoint(x: mid.position.x, y: mid.position.y + 20))
                advance(world, 1.5)
                try require(world.snowmen.count == 1, "Three stable equal-size balls form a snowman")
                try require(world.snowmen[0].ballIDs == [bottom, middle, head], "Snowman order is bottom-middle-head")
                let positions = world.balls.map(\.position)
                world.syncSurfaces([window(x: -100, top: 350)])
                for i in world.balls.indices {
                    try close(world.balls[i].position.x, positions[i].x - 100, "Entire snowman follows x")
                    try close(world.balls[i].position.y, positions[i].y + 50, "Entire snowman follows y")
                }
                let h = world.balls.first { $0.id == head }!
                try require(world.beginDrag(at: h.position) == head, "Head can be grabbed")
                try require(world.snowmen.isEmpty, "Grabbing a member dismantles decoration immediately")
                world.endDrag()
                advance(world, 1)
                world.syncSurfaces([])
                try require(world.balls.isEmpty && world.snowmen.isEmpty, "Removing the support removes the group")
            }),
            ("rolling collision and offscreen removal", {
                let world = filled()
                world.prune(to: [region])
                let left = try create(world, x: 100); world.endDrag()
                let right = try create(world, x: 180); world.endDrag()
                _ = world.beginDrag(at: world.balls.first { $0.id == left }!.position)
                world.endDrag(velocity: CGVector(dx: 500, dy: 0))
                advance(world, 1)
                let a = world.balls.first { $0.id == left }!, b = world.balls.first { $0.id == right }!
                try require(a.position.x < b.position.x, "Rolling ball must not pass through parked ball")
                try require(hypot(a.position.x - b.position.x, a.position.y - b.position.y) >= a.radius + b.radius - 1, "Balls must remain separated")
                try place(world, id: left, at: CGPoint(x: -700, y: 400))
                advance(world, 0.2)
                try require(!world.balls.contains { $0.id == left }, "Escaped ball must be removed from world bounds")
            }),
            ("free balls leave the physical display without occupying the limit", {
                let display = CGRect(x: 0, y: 0, width: 600, height: 400)
                let trajectories: [(CGPoint, CGVector)] = [
                    (CGPoint(x: 580, y: 380), CGVector(dx: 500, dy: 0)),
                    (CGPoint(x: 20, y: 380), CGVector(dx: -500, dy: 0)),
                    (CGPoint(x: 300, y: 20), CGVector(dx: 0, dy: -500))
                ]
                for (position, velocity) in trajectories {
                    let world = filled()
                    world.prune(to: [display])
                    let id = try create(world, x: 300); world.endDrag()
                    try place(world, id: id, at: position)
                    _ = world.beginDrag(at: position)
                    world.endDrag(velocity: velocity)
                    advance(world, 2, regions: [display])
                    try require(!world.balls.contains { $0.id == id }, "A thrown ball beyond the display must be removed")
                }
            }),
            ("a ball above the display returns under gravity", {
                let display = CGRect(x: 0, y: 0, width: 600, height: 400)
                let world = filled()
                world.prune(to: [display])
                let id = try create(world, x: 300); world.endDrag()
                try place(world, id: id, at: CGPoint(x: 300, y: 380))
                _ = world.beginDrag(at: CGPoint(x: 300, y: 380))
                world.endDrag(velocity: CGVector(dx: 0, dy: 500))
                advance(world, 0.5, regions: [display])
                guard let above = world.balls.first(where: { $0.id == id }) else {
                    throw CoreFailure(description: "The ball must not be removed above the display")
                }
                try require(above.position.y - above.radius > display.maxY, "The ball must rise entirely above the display")
                advance(world, 2, regions: [display])
                guard let returned = world.balls.first(where: { $0.id == id }) else {
                    throw CoreFailure(description: "The returning ball must remain in the world")
                }
                try require(returned.position.y < display.maxY, "Gravity must bring the ball back onto the display")
            }),
            ("a free ball crosses the gap between active displays", {
                let left = CGRect(x: 0, y: 0, width: 600, height: 1000)
                let right = CGRect(x: 1000, y: 0, width: 600, height: 1000)
                let world = filled()
                world.prune(to: [left, right])
                let id = try create(world, x: 300); world.endDrag()
                try place(world, id: id, at: CGPoint(x: 580, y: 800))
                _ = world.beginDrag(at: CGPoint(x: 580, y: 800))
                world.endDrag(velocity: CGVector(dx: 500, dy: 0))
                advance(world, 1, regions: [left, right])
                guard let ball = world.balls.first(where: { $0.id == id }) else {
                    throw CoreFailure(description: "The ball must survive crossing the display gap")
                }
                try require(ball.position.x > right.minX, "The ball must continue moving across the gap")
            }),
            ("a ball in the display gap resumes when the nearest display resumes", {
                let left = CGRect(x: 0, y: 0, width: 600, height: 1000)
                let right = CGRect(x: 1000, y: 0, width: 600, height: 1000)
                let world = filled()
                world.prune(to: [left, right])
                let id = try create(world, x: 300); world.endDrag()
                try place(world, id: id, at: CGPoint(x: 580, y: 800))
                _ = world.beginDrag(at: CGPoint(x: 580, y: 800))
                world.endDrag(velocity: CGVector(dx: 500, dy: 0))
                advance(world, 1, regions: [left])
                let paused = world.balls.first { $0.id == id }!
                try require(paused.position.x > left.maxX && paused.position.x < right.minX,
                            "The ball pauses in the gap near the inactive display")
                advance(world, 0.5, regions: [left])
                try require(world.balls.first { $0.id == id }!.position == paused.position,
                            "The gap ball remains paused without losing velocity")
                advance(world, 1, regions: [left, right])
                guard let resumed = world.balls.first(where: { $0.id == id }) else {
                    throw CoreFailure(description: "The gap ball must survive display resumption")
                }
                try require(resumed.position.x > right.minX, "The gap ball resumes and reaches the active display")
            }),
            ("stable snowball joins compress once and survive lift release", {
                try close(SnowballContact.stackedCenterDistance(radius: 8, otherRadius: 8), 15.04,
                          "Small balls overlap by twelve percent of the smaller radius")
                try close(SnowballContact.stackedCenterDistance(radius: 18, otherRadius: 36), 51.84,
                          "Mixed sizes use the smaller radius")
                try close(SnowballContact.stackedCenterDistance(radius: 36, otherRadius: 36), 69,
                          "Large balls cap overlap at three points")
                let world = filled()
                let bottomID = try create(world, x: 100); world.endDrag()
                let topID = try create(world, x: 450); world.endDrag()
                let base = world.balls.first { $0.id == bottomID }!
                let upper = world.balls.first { $0.id == topID }!
                let radii = world.balls.map(\.radius)
                let offset: CGFloat = 1.5
                let fullDistance = base.radius + upper.radius
                try place(world, id: topID, at: CGPoint(x: base.position.x + offset,
                    y: base.position.y + sqrt(fullDistance * fullDistance - offset * offset) + 0.01))
                world.step(delta: 1.0 / 120, weather: SnowWeather(intensity: .light), activeRegions: [region])
                func verifyContact(_ reason: String) throws {
                    let bottom = world.balls.first { $0.id == bottomID }!
                    let top = world.balls.first { $0.id == topID }!
                    let expected = SnowballContact.stackedCenterDistance(radius: bottom.radius, otherRadius: top.radius)
                    try close(hypot(top.position.x - bottom.position.x, top.position.y - bottom.position.y), expected,
                              tolerance: 0.00001, reason)
                    try require(top.surfaceID == bottom.surfaceID && top.velocity == .zero, "Settled join retains its real support without an impulse")
                }
                try verifyContact("The first confirmed landing must apply the same overlap as stable following")
                advance(world, 1, intensity: .light)
                try verifyContact("Further physics ticks must not progressively compress or separate the pair")
                let joined = world.balls.first { $0.id == topID }!
                try require(world.beginDrag(at: joined.position) == topID, "A joined ball remains independently draggable")
                for step in 1...20 { world.drag(to: CGPoint(x: joined.position.x, y: joined.position.y + CGFloat(step) * 2)) }
                let lifted = world.balls.first { $0.id == topID }!
                try close(lifted.position.y, joined.position.y + 40, "Lifting a joined ball preserves the pointer offset")
                try require(lifted.surfaceID == nil, "Lift removes the stable support connection")
                world.endDrag()
                advance(world, 1, intensity: .light)
                try verifyContact("Release must re-form the bounded join through normal collision detection")
                try require(world.balls.map(\.radius) == radii && world.balls.count == 2,
                            "Joining and separating cannot merge objects, change radii or create mass")
            }),
            ("flying side impacts keep full collision radii", {
                let world = filled()
                let leftID = try create(world, x: 100); world.endDrag()
                let rightID = try create(world, x: 450); world.endDrag()
                try place(world, id: leftID, at: CGPoint(x: 100, y: 700))
                try place(world, id: rightID, at: CGPoint(x: 125, y: 700))
                _ = world.beginDrag(at: world.balls.first { $0.id == rightID }!.position)
                world.endDrag(velocity: CGVector(dx: -720, dy: 0))
                world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .light), activeRegions: [region])
                let left = world.balls.first { $0.id == leftID }!, right = world.balls.first { $0.id == rightID }!
                let distance = hypot(right.position.x - left.position.x, right.position.y - left.position.y)
                try require(right.position.x > left.position.x && right.velocity.dx >= 0,
                            "A fast side impact must bounce before crossing through the other ball")
                try require(distance >= left.radius + right.radius - 0.001,
                            "Flying collisions cannot borrow the smaller stable-stack distance")
                try require(left.surfaceID == nil && right.surfaceID == nil && world.snowmen.isEmpty,
                            "A free side impact must not create a support or snowman decoration")
            }),
            ("visible snowball cap remains a collision support when its center is hidden", {
                let world = filled()
                let lowerID = try create(world, x: 100); world.endDrag()
                let fallingID = try create(world, x: 450); world.endDrag()
                let lower = world.balls.first { $0.id == lowerID }!
                let falling = world.balls.first { $0.id == fallingID }!
                var support = window()
                support.occluders = [CGRect(x: 70, y: 290, width: 60, height: lower.position.y + 1 - 290)]
                world.syncSurfaces([support])
                try require(!support.isExposed(lower.position), "Fixture must hide the lower ball center")
                try require(support.isExposed(CGPoint(x: lower.position.x, y: lower.position.y + lower.radius)), "Fixture must expose its upper cap")
                try place(world, id: fallingID, at: CGPoint(x: lower.position.x, y: lower.position.y + lower.radius + falling.radius + 3))
                advance(world, 0.3, intensity: .light)
                let top = world.balls.first { $0.id == fallingID }!
                let bottom = world.balls.first { $0.id == lowerID }!
                try require(top.surfaceID == support.id, "A visible cap must support a falling ball")
                try close(top.position.y - bottom.position.y,
                          SnowballContact.stackedCenterDistance(radius: top.radius, otherRadius: bottom.radius), tolerance: 0.05,
                          "Visible cap contact must settle into the small stable overlap")
            }),
            ("hidden snowball contact does not block a fall when its center is exposed", {
                let world = filled()
                let lowerID = try create(world, x: 100); world.endDrag()
                let fallingID = try create(world, x: 450); world.endDrag()
                let lower = world.balls.first { $0.id == lowerID }!
                let falling = world.balls.first { $0.id == fallingID }!
                var support = window()
                support.occluders = [CGRect(x: 70, y: lower.position.y + 2, width: 60, height: 20)]
                world.syncSurfaces([support])
                try require(support.isExposed(lower.position), "Fixture must expose the lower ball center")
                try require(!support.isExposed(CGPoint(x: lower.position.x, y: lower.position.y + lower.radius)), "Fixture must hide its upper cap")
                try place(world, id: fallingID, at: CGPoint(x: lower.position.x, y: lower.position.y + lower.radius + falling.radius + 3))
                advance(world, 0.2, intensity: .light)
                let top = world.balls.first { $0.id == fallingID }!
                let bottom = world.balls.first { $0.id == lowerID }!
                try require(top.surfaceID == nil && top.velocity.dy < 0, "A hidden contact must not attach or bounce the falling ball")
                try require(top.position.y < bottom.position.y + top.radius + bottom.radius - 1, "The ball must pass the hidden cap")
            }),
            ("ball limit preserves existing objects", {
                let world = SnowWorld(); world.syncSurfaces([window(width: 4000)])
                advance(world, 50, regions: [CGRect(x: 0, y: 0, width: 4500, height: 1000)])
                for index in 0..<30 { _ = try create(world, x: CGFloat(index) * 100 + 50); world.endDrag() }
                let ids = world.balls.map(\.id)
                try require(world.beginSnowball(at: CGPoint(x: 3500, y: 304)) == nil, "31st snowball must be rejected")
                try require(world.balls.map(\.id) == ids, "Limit must not evict existing snowballs")
            }),
            ("inactive display freeze versus unplug pruning", {
                let world = filled(window(x: -400, width: 300))
                _ = try create(world, x: -300); world.endDrag()
                let ball = world.balls[0]
                advance(world, 1, regions: [CGRect(x: 0, y: 0, width: 1000, height: 1000)])
                try require(world.balls[0].position == ball.position, "Fullscreen on other display must not move objects")
                world.prune(to: [CGRect(x: 0, y: 0, width: 1000, height: 1000)])
                try require(world.balls.isEmpty && world.surfaces.isEmpty, "Unplug must prune offscreen state")
            }),
            ("free ball on a lower inactive display remains paused", {
                let lower = CGRect(x: 0, y: 0, width: 600, height: 400)
                let upper = CGRect(x: 0, y: 400, width: 600, height: 400)
                let world = filled()
                world.prune(to: [lower, upper])
                let id = try create(world, x: 300); world.endDrag()
                try place(world, id: id, at: CGPoint(x: 300, y: 200))
                _ = world.beginDrag(at: CGPoint(x: 300, y: 200))
                world.endDrag(velocity: CGVector(dx: 50, dy: -50))
                let before = world.balls.first { $0.id == id }!
                advance(world, 1, regions: [upper])
                guard let after = world.balls.first(where: { $0.id == id }) else {
                    throw CoreFailure(description: "A ball on an inactive connected display must not be removed")
                }
                try require(after.position == before.position && after.velocity == before.velocity,
                            "A free ball on an inactive display keeps its position and velocity")
                try place(world, id: id, at: CGPoint(x: 300, y: 850))
                _ = world.beginDrag(at: CGPoint(x: 300, y: 850))
                world.endDrag(velocity: CGVector(dx: 0, dy: 100))
                let above = world.balls.first { $0.id == id }!
                advance(world, 1, regions: [lower])
                guard let pausedAbove = world.balls.first(where: { $0.id == id }) else {
                    throw CoreFailure(description: "A ball above an inactive display must not be removed")
                }
                try require(pausedAbove.position == above.position && pausedAbove.velocity == above.velocity,
                            "A ball above an inactive display remains paused")
            }),
            ("partial-display pause freezes profile", {
                let world = filled()
                world.brush(at: CGPoint(x: 290, y: 304), radius: 30)
                let paused = Array(world.drifts["window"]!.heights.dropFirst(76))
                advance(world, 1, regions: [CGRect(x: 0, y: 0, width: 300, height: 1000)])
                try require(Array(world.drifts["window"]!.heights.dropFirst(76)) == paused, "Slope relaxation must not modify the paused half of a spanning window")
            }),
            ("maximum radius stops collecting mass", {
                let world = SnowWorld(seed: 123)
                world.syncSurfaces([window(width: 5000)])
                advance(world, 45, regions: [CGRect(x: 0, y: 0, width: 5500, height: 1000)])
                let before = totalMass(world)
                _ = try create(world, x: 60)
                world.drag(to: CGPoint(x: 4400, y: 305))
                try close(world.balls[0].radius, 36, tolerance: 0.001, "Long roll must reach maximum radius")
                try close(totalMass(world), before, tolerance: 0.01, "Growth up to the cap conserves mass")
                let driftAtLimit = area(world.drifts["window"]!)
                world.drag(to: CGPoint(x: 2500, y: 305))
                try close(area(world.drifts["window"]!), driftAtLimit, tolerance: 0.001, "Capped ball must stop consuming the drift")
                try close(world.balls[0].radius, 36, tolerance: 0.001, "Further movement must not exceed maximum radius")
            }),
            ("snowman requires ordered size, alignment and rest", {
                func stack(headGrows: Bool = false, middleOffset: CGFloat = 0) throws -> (SnowWorld, UUID) {
                    let world = filled(window(width: 900), seconds: 15)
                    let bottom = try create(world, x: 100); world.endDrag()
                    let middle = try create(world, x: 350); world.endDrag()
                    let head = try create(world, x: 650)
                    if headGrows { world.drag(to: CGPoint(x: 780, y: 305)) }
                    world.endDrag()
                    advance(world, 0.7)
                    let base = world.balls.first { $0.id == bottom }!
                    let middleBall = world.balls.first { $0.id == middle }!
                    try place(world, id: middle, at: CGPoint(x: base.position.x + middleOffset,
                                                           y: base.position.y + base.radius + middleBall.radius + 0.1))
                    advance(world, 0.7)
                    let mid = world.balls.first { $0.id == middle }!
                    let headBall = world.balls.first { $0.id == head }!
                    try place(world, id: head, at: CGPoint(x: mid.position.x,
                                                         y: mid.position.y + mid.radius + headBall.radius + 0.1))
                    return (world, head)
                }
                let (ordered, headID) = try stack()
                advance(ordered, 0.4)
                try require(ordered.snowmen.isEmpty, "Less than half a second of rest must not form a snowman")
                advance(ordered, 0.3)
                try require(ordered.snowmen.count == 1, "Aligned ordered stack forms after sufficient rest")
                _ = ordered.beginDrag(at: ordered.balls.first { $0.id == headID }!.position)
                ordered.endDrag(velocity: CGVector(dx: 60, dy: 30))
                advance(ordered, 0.2)
                try require(ordered.snowmen.isEmpty, "Moving ball must break stable recognition")
                let (wrongSize, _) = try stack(headGrows: true)
                advance(wrongSize, 1.2)
                try require(wrongSize.snowmen.isEmpty, "Head larger than middle must not form a snowman")
                let (misaligned, _) = try stack(middleOffset: 3)
                advance(misaligned, 1.2)
                try require(misaligned.snowmen.isEmpty, "Stack outside the 25 percent alignment limit must not form a snowman")
            }),
            ("diagonal swept collision respects narrow exposed support", {
                func thrown(fromX: CGFloat) throws -> (SnowWorld, UUID) {
                    let world = filled(seconds: 15)
                    let id = try create(world, x: 80); world.endDrag()
                    var narrow = window("narrow", x: 210, top: 500, width: 12)
                    narrow.occluders = [CGRect(x: 212, y: 490, width: 80, height: 170)]
                    world.syncSurfaces([narrow, window()])
                    try place(world, id: id, at: CGPoint(x: fromX, y: 600))
                    _ = world.beginDrag(at: world.balls.first { $0.id == id }!.position)
                    world.endDrag(velocity: CGVector(dx: 600, dy: -600))
                    return (world, id)
                }
                let (visible, visibleID) = try thrown(fromX: 127)
                var landed = false
                for _ in 0..<70 {
                    visible.step(delta: 1.0 / 120, weather: SnowWeather(), activeRegions: [region])
                    if let ball = visible.balls.first(where: { $0.id == visibleID }), ball.surfaceID == "narrow" {
                        landed = true
                        try require(ball.position.x < 212.001, "Collision must be on exposed half")
                        break
                    }
                }
                try require(landed, "Diagonal high-speed throw must not skip a two-point exposed segment")
                let (hidden, hiddenID) = try thrown(fromX: 129)
                var hitHidden = false
                for _ in 0..<70 {
                    hidden.step(delta: 1.0 / 120, weather: SnowWeather(), activeRegions: [region])
                    if hidden.balls.first(where: { $0.id == hiddenID })?.surfaceID == "narrow" { hitHidden = true }
                }
                try require(!hitHidden, "Covered segment must not act as an invisible collider")
            }),
            ("adjacent floors share the same snow contour", {
                let world = SnowWorld()
                world.syncSurfaces([
                    SnowSurface(id: "floor:1", frame: CGRect(x: -400, y: 0, width: 400, height: 0), kind: .floor),
                    SnowSurface(id: "floor:2", frame: CGRect(x: 0, y: 0, width: 400, height: 0), kind: .floor)
                ])
                advance(world, 15)
                try close(world.drifts["floor:1"]!.heights.last!, world.drifts["floor:2"]!.heights.first!,
                          tolerance: 0.00001, "Touching equal-height displays must not have an artificial floor seam")
                advance(world, 150)
                let left = world.drifts["floor:1"]!, right = world.drifts["floor:2"]!
                try close(left.heights.last!, right.heights.first!, tolerance: 0.00001,
                          "Saturated adjacent floors must retain the same boundary height despite different IDs")
                try close(left.visibleContour.height(at: left.surface.frame.width), right.visibleContour.height(at: 0),
                          tolerance: 0.00001, "The rendered and physical saturated roofs must meet at the display seam")
            }),
            ("floor cap follows world coordinates while window and Dock caps stay local", {
                let originalFloor = SnowSurface(id: "floor:move", frame: CGRect(x: -400, y: 0, width: 400, height: 0), kind: .floor)
                let world = filled(originalFloor, seconds: 150)
                let oldFloor = world.drifts[originalFloor.id]!
                var movedFloor = originalFloor; movedFloor.frame.origin.x += 80
                world.syncSurfaces([movedFloor])
                let moved = world.drifts[originalFloor.id]!
                try require(moved.heightLimits != oldFloor.heightLimits, "Moving a display must invalidate its world-coordinate cap cache")
                try require(moved.heightLimits.prefix(81).elementsEqual(oldFloor.heightLimits.dropFirst(20)),
                            "Overlapping world positions retain identical caps after a display shift")
                for index in moved.heights.indices {
                    try close(moved.heights[index], min(oldFloor.heights[index], moved.heightLimits[index]),
                              "A changed floor cap only clips excess snow, without resetting or creating mass")
                }
                let fresh = SnowWorld()
                var anotherID = movedFloor; anotherID.id = "floor:other-id"
                fresh.syncSurfaces([anotherID])
                try require(fresh.drifts[anotherID.id]!.heightLimits == moved.heightLimits,
                            "Floor cap sampling must ignore display IDs")
                let fractional = SnowWorld()
                var boundary = originalFloor; boundary.frame.size.width = 400.0001
                fractional.syncSurfaces([boundary])
                boundary.frame.size.width = 399.9999; boundary.frame.origin.x += 20
                fractional.syncSurfaces([boundary])
                let resampled = fractional.drifts[boundary.id]!
                try require(resampled.heights.count == 101 && resampled.heightLimits.count == 101,
                            "Crossing a sample boundary must resize both arrays even below coordinate tolerance")
                for kind in [SurfaceKind.window, .dock] {
                    var surface = window(); surface.kind = kind
                    let localWorld = filled(surface, seconds: 150)
                    let original = localWorld.drifts[surface.id]!
                    surface.frame.origin.x -= 240; surface.frame.origin.y += 80
                    localWorld.syncSurfaces([surface])
                    let translated = localWorld.drifts[surface.id]!
                    try require(translated.heightLimits == original.heightLimits && translated.heights == original.heights,
                                "Window and Dock translations retain their local cap and accumulated profile")
                }
            }),
            ("profile clock preserves timing, weather and pause", {
                func simulate(rate: Int) throws -> SnowWorld {
                    let world = filled(seconds: 15)
                    let id = try create(world, x: 80); world.endDrag()
                    try place(world, id: id, at: CGPoint(x: 150, y: 800))
                    _ = world.beginDrag(at: world.balls[0].position)
                    world.endDrag(velocity: CGVector(dx: 150, dy: -500))
                    for _ in 0..<rate { world.step(delta: 1 / Double(rate), weather: SnowWeather(), activeRegions: [region]) }
                    return world
                }
                let baseline = try simulate(rate: 120)
                for rate in [30, 60, 100] {
                    let candidate = try simulate(rate: rate)
                    try require(candidate.drifts["window"]!.heights == baseline.drifts["window"]!.heights, "Profile must be independent of callback rate at \(rate) Hz")
                    try require(candidate.balls[0].position == baseline.balls[0].position, "Physics must retain its fixed 120 Hz integration at \(rate) Hz")
                    try close(candidate.balls[0].radius, baseline.balls[0].radius, "Rolling mass must be independent of callback rate")
                }
                func empty() -> SnowWorld { let w = SnowWorld(); w.syncSurfaces([window()]); return w }
                let mixed = empty(), light = empty(), heavy = empty()
                mixed.step(delta: 1.0 / 120, weather: SnowWeather(intensity: .light), activeRegions: [region])
                mixed.step(delta: 3.0 / 120, weather: SnowWeather(intensity: .blizzard), activeRegions: [region])
                light.step(delta: 4.0 / 120, weather: SnowWeather(intensity: .light), activeRegions: [region])
                heavy.step(delta: 4.0 / 120, weather: SnowWeather(intensity: .blizzard), activeRegions: [region])
                for i in mixed.drifts["window"]!.heights.indices {
                    try close(mixed.drifts["window"]!.heights[i], light.drifts["window"]!.heights[i] * 0.25 + heavy.drifts["window"]!.heights[i] * 0.75,
                              tolerance: 1e-9, "Subcycle intensity changes must retain their full weighted dose")
                }
                let paused = empty(), fresh = empty()
                paused.step(delta: 3.0 / 120, weather: SnowWeather(), activeRegions: [region])
                paused.step(delta: 500, weather: SnowWeather(), activeRegions: [])
                paused.step(delta: 4.0 / 120, weather: SnowWeather(), activeRegions: [region])
                fresh.step(delta: 4.0 / 120, weather: SnowWeather(), activeRegions: [region])
                try require(paused.drifts["window"]!.heights == fresh.drifts["window"]!.heights, "Pause must discard pending profile time instead of replaying it")
                let left = CGRect(x: 0, y: 0, width: 300, height: 1000)
                let right = CGRect(x: 300, y: 0, width: 300, height: 1000)
                let transition = empty(), leftOnly = empty(), rightOnly = empty()
                transition.step(delta: 3.0 / 120, weather: SnowWeather(), activeRegions: [left])
                transition.step(delta: 1.0 / 120, weather: SnowWeather(), activeRegions: [right])
                transition.syncSurfaces([window()])
                leftOnly.step(delta: 3.0 / 120, weather: SnowWeather(), activeRegions: [left]); leftOnly.syncSurfaces([window()])
                rightOnly.step(delta: 1.0 / 120, weather: SnowWeather(), activeRegions: [right]); rightOnly.syncSurfaces([window()])
                for i in transition.drifts["window"]!.heights.indices {
                    try close(transition.drifts["window"]!.heights[i], leftOnly.drifts["window"]!.heights[i] + rightOnly.drifts["window"]!.heights[i],
                              tolerance: 1e-9, "Changing active displays must not credit old elapsed time to the new display")
                }
            }),
            ("rounded upper edge retains full geometry without snow tails", {
                var rounded = window(width: 603)
                rounded.topInset = 15
                let world = filled(rounded)
                let drift = world.drifts["window"]!
                try require(drift.surface.frame == rounded.frame, "Inset must not shrink the underlying window frame")
                try require(drift.heights.count == 152, "Inset must preserve the full-frame sampling coordinates")
                func contour(_ x: CGFloat) -> CGFloat {
                    let i = min(drift.heights.count - 2, Int(x / 4))
                    let left = CGFloat(i) * 4
                    let right = min(CGFloat(i + 1) * 4, rounded.frame.width)
                    return drift.heights[i] + (drift.heights[i + 1] - drift.heights[i]) * (x - left) / (right - left)
                }
                for x in stride(from: CGFloat(0), to: 15, by: 0.5) {
                    try close(contour(x), 0, "Interpolated left corner must have no snow tail")
                    try close(contour(603 - x), 0, "Interpolated right corner must have no snow tail")
                }
                try require(contour(300) > 0, "Flat middle must keep accumulating at the normal rate")
                try require(world.surface(at: CGPoint(x: 8, y: 304)) == nil, "Rounded corner must not be an interactive support")
                try require(world.beginSnowball(at: CGPoint(x: 8, y: 304)) == nil, "Rounded corner must not create a snowball")
                world.brush(at: CGPoint(x: 24, y: 304), radius: 24)
                advance(world, 1)
                try require(world.drifts["window"]!.heights.prefix(5).allSatisfy { $0 == 0 }, "Slope relaxation must not refill rounded corners")
            }),
            ("rounded support releases balls but preserves silhouette hit testing", {
                var rounded = window(); rounded.topInset = 16
                let world = filled(rounded)
                let id = try create(world, x: 20); world.endDrag()
                let ball = world.balls.first { $0.id == id }!
                let protrudingPoint = CGPoint(x: ball.position.x - 7, y: ball.position.y)
                try require(!rounded.supports(x: protrudingPoint.x), "Test point must lie outside the flat support")
                try require(world.beginDrag(at: protrudingPoint) == id, "Visible protruding side of a supported ball must remain draggable")
                world.endDrag()
                try place(world, id: id, at: CGPoint(x: 8, y: 550))
                advance(world, 1.3)
                let falling = world.balls.first { $0.id == id }!
                try require(falling.surfaceID == nil && falling.position.y < rounded.top, "A falling ball must not land on the rounded corner")
                let changing = filled()
                _ = try create(changing, x: 8); changing.endDrag()
                changing.syncSurfaces([rounded])
                try require(changing.balls[0].surfaceID == nil, "A newly inset edge must release an existing unsupported ball")
                try require(changing.drifts["window"]!.heights.prefix(5).allSatisfy { $0 == 0 }, "Changing inset must remove old corner snow immediately")
            }),
            ("rounded visual roof supports created, rolling and stacked balls without floating", {
                var support = window(); support.topInset = 16
                let world = filled(support)
                let beforeMass = totalMass(world)
                let lowerID = try create(world, x: 24); world.endDrag()
                try close(totalMass(world), beforeMass, tolerance: 0.01, "Visual cap must not change stored creation mass")
                var lower = world.balls.first { $0.id == lowerID }!
                var drift = world.drifts[support.id]!
                try require(drift.heights[6] - drift.visibleContour.height(at: 24) > 2, "Fixture must contain a substantial tapered edge")
                try close(lower.position.y - lower.radius, support.top + drift.visibleContour.height(at: 24), "Created ball must touch the drawn contour")
                _ = world.beginDrag(at: lower.position)
                let destinationX: CGFloat = 32
                world.drag(to: CGPoint(x: destinationX, y: support.top + drift.visibleContour.height(at: destinationX) + lower.radius))
                world.endDrag()
                lower = world.balls.first { $0.id == lowerID }!
                drift = world.drifts[support.id]!
                try close(lower.position.y - lower.radius, support.top + drift.visibleContour.height(at: destinationX), "Rolling ball must follow the same contour after collecting mass")
                let upperID = try create(world, x: 450); world.endDrag()
                let upper = world.balls.first { $0.id == upperID }!
                try place(world, id: upperID, at: CGPoint(x: lower.position.x, y: lower.position.y + lower.radius + upper.radius + 3))
                advance(world, 0.4, intensity: .light)
                let stacked = world.balls.first { $0.id == upperID }!
                lower = world.balls.first { $0.id == lowerID }!
                drift = world.drifts[support.id]!
                try close(lower.position.y - lower.radius, support.top + drift.visibleContour.height(at: lower.position.x), tolerance: 0.01, "The stack base must remain on the visible cap")
                try close(stacked.position.y - lower.position.y,
                          SnowballContact.stackedCenterDistance(radius: stacked.radius, otherRadius: lower.radius), tolerance: 0.05,
                          "Stacked balls retain the same compressed contact on a tapered roof")
                try require(stacked.surfaceID == support.id, "The upper ball inherits the real support")
            }),
            ("ceiling occluder stops accumulation and hides attached ball input", {
                let support = window(top: 970)
                let world = filled(support, seconds: 20)
                let id = try create(world, x: 200); world.endDrag()
                var masked = support
                masked.topInset = 16
                masked.occluders = [CGRect(x: 0, y: 970, width: 600, height: 40)]
                world.syncSurfaces([masked])
                let retained = world.drifts["window"]!.heights
                let ball = world.balls.first { $0.id == id }!
                advance(world, 1)
                try require(world.drifts["window"]!.heights == retained, "A window under the menu ceiling must not keep adding hidden snow")
                try require(world.surface(at: CGPoint(x: 200, y: 975)) == nil, "The masked top must not accept snow-tool input")
                try require(world.beginDrag(at: ball.position) == nil, "Ceiling mask must still apply to the entire ball silhouette")
            }),
            ("coordinate conversion and malformed geometry", {
                let rect = WorldCoordinates.fromQuartz(CGRect(x: -500, y: 100, width: 300, height: 200), primaryHeight: 1000)
                try require(rect == CGRect(x: -500, y: 700, width: 300, height: 200), "Quartz y-down converts to AppKit y-up")
                let world = SnowWorld()
                world.syncSurfaces([window(), window(), window("bad", width: .nan)])
                try require(world.surfaces.count == 1, "Reject duplicate IDs and nonfinite bounds")
                world.reset()
                try require(world.surfaces.isEmpty && world.balls.isEmpty && world.drifts.isEmpty, "Space reset clears transient state")
            })
        ]
        var failed = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failed)/\(tests.count) scenarios; \(checks) assertions")
        if failed > 0 { exit(1) }
    }
}
