import Foundation
import CoreGraphics

@main
enum DuckWorldTests {
    static let display = DuckDisplay(frame: CGRect(x: -100, y: -60, width: 600, height: 450), visibleTop: 365)
    static let floor = SnowSurface(id: "floor", frame: CGRect(x: -100, y: -61, width: 600, height: 1), kind: .floor)
    static let window = SnowSurface(id: "owner:window", frame: CGRect(x: 85, y: 25, width: 235, height: 145),
                                    kind: .window, topInset: 16, suppressesSnowfall: true)
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1
    }

    final class Fixture {
        let snow = SnowWorld(seed: 19)
        let duck: DuckWorld
        let trees = FestiveWorld()
        var active = [DuckWorldTests.display]
        var displays = [DuckWorldTests.display.frame]
        var treesEnabled = false
        var reducedMotion = false
        var plows: [String: SnowplowPass] = [:]
        var sweeps: [SnowplowSweep] = []

        init(_ surfaces: [SnowSurface] = [DuckWorldTests.window, DuckWorldTests.floor], enabled: Bool = true,
             seed: UInt64 = 31) {
            duck = DuckWorld(seed: seed)
            sync(surfaces)
            duck.setEnabled(enabled, surfaces: snow.surfaces)
        }

        func sync(_ surfaces: [SnowSurface]) {
            snow.syncSurfaces(surfaces)
            trees.syncSurfaces(snow.surfaces)
            duck.sync(snow.surfaces)
        }

        func tick(_ steps: Int = 1, snowing: Bool = false) {
            for _ in 0..<steps {
                if snowing { snow.step(delta: 0.1, weather: SnowWeather(), activeRegions: displays) }
                duck.advance(delta: 0.1, snow: snow, trees: trees, treesEnabled: treesEnabled, displays: active,
                             allDisplayFrames: displays, plows: plows, sweeps: sweeps, reducedMotion: reducedMotion)
            }
        }

        func until(_ description: String, steps: Int = 7_000, _ predicate: () -> Bool) {
            for _ in 0..<steps {
                if predicate() { return }
                tick()
            }
            precondition(predicate(), description)
        }

        func visitRoof(line: Int = #line) {
            until("a visit must reach the open roof (fixture line \(line))") { duck.pose?.anchor?.surfaceID == DuckWorldTests.window.id }
        }
    }

    static func main() {
        spawningAndEffects()
        relocationAndResize()
        blockersAndLanding()
        curvedFlightsAndRoofWalk()
        spaceAndParity()
        crossDisplay()
        interactions()
        lifeAndMemory()
        dockFlights()
        occasionalCrossing()
        windowAfterFloorStay()
        sustainedFocus()
        floorPauseAfterRoofVisit()
        floorIgnoresWindowChanges()
        routesWithoutDockBounds()
        focusedWindowFlights()
        avoidsMovingTractor()
        snowAndObjectsParity()
        print("PASS DuckWorld: \(count) checks")
    }

    static func spawningAndEffects() {
        let dock = SnowSurface(id: "dock", frame: CGRect(x: 160, y: -60, width: 150, height: 55), kind: .dock)
        let f = Fixture([dock, floor])
        f.tick(20)
        check(f.duck.pose?.anchor?.surfaceID == floor.id, "Dock leaves usable floor at the bottom of the display")
        check(f.duck.pose?.feet.y == -60 && f.duck.prints.isEmpty, "bare floor has contact but no tracks")
        for _ in 0..<400 {
            f.tick(snowing: true)
            if !f.duck.prints.isEmpty { break }
        }
        check(!f.duck.prints.isEmpty && f.duck.prints.count <= 48 && f.duck.dust.count <= 12, "snow produces bounded effects")
        let print = f.duck.prints[0]
        let x = floor.frame.minX + print.anchor.localX
        f.sweeps = [SnowplowSweep(surfaceID: floor.id, fromX: x - 0.01, toX: x + 0.01)]
        f.tick()
        check(!f.duck.prints.contains { $0.anchor == print.anchor }, "tractor sweep removes local tracks")
        f.reducedMotion = true
        f.tick(30)
        let staticFeet = f.duck.pose?.feet
        f.tick(150)
        check(staticFeet != nil && staticFeet == f.duck.pose?.feet && f.duck.pose?.activity == .rest
              && f.duck.prints.isEmpty && f.duck.dust.isEmpty, "Reduce Motion leaves a still resting duck")
        f.duck.setEnabled(false, surfaces: f.snow.surfaces)
        f.tick(200)
        check(f.duck.pose == nil && f.duck.prints.isEmpty, "off clears the duck and stops its updates")

        var wide = window
        wide.frame = CGRect(x: -100, y: -60, width: 600, height: 235)
        for focused in [false, true] {
            wide.suppressesSnowfall = focused
            let hidden = Fixture([wide, floor])
            hidden.tick(20)
            let startedBelow = hidden.duck.pose?.anchor?.surfaceID == floor.id
            var stayedBelow = true
            for _ in 0..<430 {
                hidden.tick()
                stayedBelow = stayedBelow && hidden.duck.pose?.anchor?.surfaceID != wide.id
            }
            check(startedBelow && stayedBelow, "a wide window leaves only the lower floor available for the duck")
        }
    }

    static func relocationAndResize() {
        let f = Fixture()
        f.visitRoof()
        let anchor = f.duck.pose!.anchor!
        let feet = f.duck.pose!.feet
        var moved = window
        moved.frame = moved.frame.offsetBy(dx: 31, dy: 22)
        f.sync([moved, floor]); f.tick(0)
        f.duck.advance(delta: 0, snow: f.snow, trees: f.trees, treesEnabled: false, displays: f.active,
                       allDisplayFrames: f.displays, plows: [:], sweeps: [], reducedMotion: false)
        check(f.duck.pose?.anchor == anchor, "moving an occupied roof keeps the window-local anchor")
        check(f.duck.pose?.feet == CGPoint(x: feet.x + 31, y: feet.y + 22), "roof and duck move together in both axes")
        moved.frame.size.width += 90
        f.sync([moved, floor])
        f.duck.advance(delta: 0, snow: f.snow, trees: f.trees, treesEnabled: false, displays: f.active,
                       allDisplayFrames: f.displays, plows: [:], sweeps: [], reducedMotion: false)
        check(f.duck.pose?.anchor == anchor, "widening preserves the duck's local position")
        moved.frame.origin.x -= 14
        moved.frame.size.width += 14
        f.sync([moved, floor])
        f.duck.advance(delta: 0, snow: f.snow, trees: f.trees, treesEnabled: false, displays: f.active,
                       allDisplayFrames: f.displays, plows: [:], sweeps: [], reducedMotion: false)
        check(f.duck.pose?.anchor == anchor && f.duck.pose?.feet.x == feet.x + 17,
              "left edge resize uses the new world origin and preserves the local position")
        moved.frame.size.width = max(24, anchor.localX + 4)
        f.sync([moved, floor]); f.tick()
        check(f.duck.pose?.anchor?.surfaceID != moved.id, "resize that cuts the usable ledge ends the visit")
        f.sync([floor]); f.tick(50)
        var replacement = window
        replacement.id = "other:window"
        f.sync([replacement, floor]); f.tick()
        check(f.duck.pose?.anchor?.surfaceID == floor.id && !f.duck.prints.contains { $0.anchor.surfaceID == window.id },
              "a new window at the same coordinates cannot inherit the old anchor or tracks")
    }

    static func blockersAndLanding() {
        let f = Fixture()
        f.until("flight starts on the open fixture") { f.duck.pose?.activity == .fly }
        let feet = f.duck.pose!.feet
        var changed = window
        changed.frame = changed.frame.offsetBy(dx: 44, dy: 20)
        changed.occluders = [CGRect(x: feet.x - 19, y: feet.y + 19, width: 38, height: 9)]
        var blockedFloor = floor
        blockedFloor.occluders = changed.occluders
        f.sync([changed, blockedFloor]); f.tick()
        check(f.duck.pose?.activity == .fly && f.duck.pose?.feet == feet,
              "moving the destination replans from the current position")
        f.visitRoof()
        check(f.duck.pose?.feet.y == changed.top && f.duck.pose!.feet.x >= changed.frame.minX,
              "the duck lands on the nearest usable part of the moved roof")

        let baseline = Fixture(), barrier = Fixture()
        for scene in [baseline, barrier] {
            scene.until("fixture must start flight") { scene.duck.pose?.activity == .fly }
        }
        let from = baseline.duck.pose!.bounds
        baseline.tick()
        let to = baseline.duck.pose!.bounds
        // Cover the next flight pose, away from the landing ledge.
        let obstacle: CGRect
        if to.minY > from.minY + 1 {
            let edge = max(from.maxY + 0.25, to.minY + 1)
            obstacle = CGRect(x: to.midX - 2, y: edge, width: 4, height: 0.25)
        } else {
            let edge = to.midX > from.midX ? max(from.maxX + 0.25, to.minX + 1) : min(from.minX - 0.5, to.maxX - 1)
            obstacle = CGRect(x: edge, y: to.midY, width: 0.25, height: 4)
        }
        check(!from.intersects(obstacle) && to.intersects(obstacle), "barrier is newly encountered on the next flight step")
        var occupiedFloor = floor
        occupiedFloor.occluders = [obstacle]
        barrier.sync([window, occupiedFloor]); barrier.tick()
        check(barrier.duck.pose!.bounds.intersects(obstacle) && barrier.duck.isFlightVisible(at: barrier.duck.pose!.feet),
              "an airborne duck passes in front of a surface entering its path")

        let mask = Fixture()
        mask.visitRoof()
        let roof = mask.duck.pose!.feet
        var covered = window
        covered.occluders = [CGRect(x: roof.x - 18, y: roof.y + 12, width: 36, height: 30)]
        mask.sync([covered, floor]); mask.tick()
        check(mask.duck.pose?.anchor?.surfaceID != window.id, "head occlusion invalidates the pose even though the feet remain exposed")

        let frightened = Fixture()
        frightened.visitRoof()
        frightened.duck.windowShook(["other"])
        check(frightened.duck.pose?.activity != .startled, "shake on an unrelated window has no effect")
        frightened.duck.windowShook([window.id])
        check(frightened.duck.pose?.activity == .startled, "confirmed shake interrupts the occupied pose")
        frightened.tick(27)
        check(frightened.duck.pose?.anchor?.surfaceID != window.id, "duck finishes the visit after a confirmed shake")
    }

    static func curvedFlightsAndRoofWalk() {
        let f = Fixture()
        f.until("roof visit starts") { f.duck.pose?.activity == .fly }
        let launch = f.duck.pose!.feet
        var positions: [CGPoint] = [launch]
        var speeds: [CGFloat] = []
        var legPositions: [CGFloat] = []
        while f.duck.pose?.activity == .fly && positions.count < 80 {
            f.tick()
            let next = f.duck.pose!.feet, last = positions.last!
            positions.append(next)
            speeds.append(hypot(next.x - last.x, next.y - last.y) * 10)
            if f.duck.pose?.activity == .fly { legPositions.append(f.duck.pose!.feetExtended) }
        }
        guard let landing = f.duck.pose?.feet else { preconditionFailure("flight must land") }
        check(f.duck.pose?.anchor?.surfaceID == window.id && positions.count >= 10 && speeds.max()! < 400,
              "the ascent is slower and ends on the active roof")
        let middle = positions[positions.count / 2]
        let dx = landing.x - launch.x, dy = landing.y - launch.y
        let offset = abs(dx * (middle.y - launch.y) - dy * (middle.x - launch.x)) / hypot(dx, dy)
        check(abs(middle.x - launch.x) > 8 && offset > 16,
              "both axes move and the trajectory bows above a straight line")
        check(legPositions.min() == 0 && (legPositions.last ?? 0) > 0.4,
              "the duck tucks its feet in flight and extends them before contact")
        var walked: CGFloat = 0
        var previous = landing.x
        for _ in 0..<24 {
            f.tick()
            check(f.duck.pose?.anchor?.surfaceID == window.id && f.duck.pose?.activity == .walk,
                  "arrival dedicates the opening seconds to the roof walk")
            walked += abs(f.duck.pose!.feet.x - previous)
            previous = f.duck.pose!.feet.x
        }
        check(walked > 55, "the duck covers visible ground along the ledge")

        let near = Fixture()
        near.until("second roof visit starts") { near.duck.pose?.activity == .fly }
        near.tick(6)
        let before = near.duck.pose!
        var shifted = window
        shifted.frame.origin.x += 68
        shifted.occluders = [CGRect(x: shifted.frame.minX, y: shifted.top, width: 47, height: 50)]
        near.sync([shifted, floor]); near.tick()
        check(near.duck.pose?.feet == before.feet && near.duck.pose?.time == before.time
              && near.duck.pose?.feetExtended == before.feetExtended,
              "a changed touchdown keeps the flight position, wing phase and tucked feet")
        near.visitRoof()
        check(near.duck.pose!.feet.x > shifted.frame.minX + 67 && near.duck.pose!.feet.x < shifted.frame.midX,
              "the duck chooses the closest free part of the ledge after resize")

        let dock = SnowSurface(id: "rhythm-dock", frame: CGRect(x: 76, y: floor.top, width: 220, height: 45), kind: .dock)
        let rhythm = Fixture([dock, floor])
        rhythm.until("Dock crossing begins", steps: 7_000) { rhythm.duck.pose?.activity == .fly }
        var downDistances: [CGFloat] = [], recoveryDistances: [CGFloat] = []
        for _ in 0..<90 {
            let old = rhythm.duck.pose!
            rhythm.duck.advance(delta: 0.01, snow: rhythm.snow, trees: rhythm.trees, treesEnabled: false,
                                displays: rhythm.active, allDisplayFrames: rhythm.displays, plows: [:], sweeps: [], reducedMotion: false)
            let new = rhythm.duck.pose!
            guard old.time > 0.18, new.activity == .fly else { continue }
            let startWing = DuckWingbeat(time: old.time).elevation
            let endWing = DuckWingbeat(time: new.time).elevation
            let distance = abs(new.feet.x - old.feet.x)
            if endWing < startWing - 0.12 { downDistances.append(distance) }
            if endWing > startWing + 0.08 { recoveryDistances.append(distance) }
        }
        let down = downDistances.reduce(0, +) / CGFloat(max(1, downDistances.count))
        let recovery = recoveryDistances.reduce(0, +) / CGFloat(max(1, recoveryDistances.count))
        check(downDistances.count >= 8 && recoveryDistances.count >= 8 && recovery > 0 && down > recovery * 1.15,
              "the duck advances faster on the downstroke than when it lifts its wings")
    }

    static func spaceAndParity() {
        let on = Fixture()
        let off = Fixture(enabled: false)
        on.tick(450, snowing: true); off.tick(450, snowing: true)
        var inactive = window
        inactive.suppressesSnowfall = false
        for fixture in [on, off] {
            fixture.sync([inactive, floor])
            fixture.sync([window, floor])
        }
        on.visitRoof()
        var animation = WindowSurfaceAnimations()
        var control = WindowSurfaceAnimations()
        let profile = on.snow.drifts[window.id]!.heights
        var miniature = window
        miniature.frame = CGRect(x: 3, y: display.frame.minY + 4, width: 65, height: 2)
        func snapshot(_ surfaces: [SnowSurface], hidden: Set<String> = [], changing: Bool = false, at time: Double) {
            let first = animation.reconcile(surfaces, previous: on.snow.surfaces, hiddenIDs: hidden,
                                            displays: on.displays, pointerPressed: false, spaceChanging: changing, at: time)
            let second = control.reconcile(surfaces, previous: off.snow.surfaces, hiddenIDs: hidden,
                                           displays: off.displays, pointerPressed: false, spaceChanging: changing, at: time)
            on.sync(first); off.sync(second)
            on.tick(); off.tick()
            check(first.map(\.frame) == second.map(\.frame) && first.map(\.isVisible) == second.map(\.isVisible)
                  && on.snow.drifts[window.id]?.heights == off.snow.drifts[window.id]?.heights,
                  "duck toggle cannot affect reconciled geometry or snow")
        }
        snapshot([miniature, floor], at: 1)
        check(on.snow.drifts[window.id]?.surface.isVisible == false && on.snow.drifts[window.id]?.heights == profile,
              "minimize hides and retains the original profile")
        check(on.duck.pose?.anchor?.surfaceID != window.id, "duck cannot ride a hidden intermediate frame")
        snapshot([floor], hidden: [window.id], at: 2)
        for (offset, time) in [(52.0, 3.0), (12.0, 3.02), (0.0, 3.04)] {
            var returning = window
            returning.frame = returning.frame.offsetBy(dx: offset, dy: 0)
            snapshot([returning, floor], at: time)
            check(on.snow.drifts[window.id]?.surface.frame == returning.frame
                  && on.snow.drifts[window.id]?.surface.isVisible == true && on.snow.drifts[window.id]?.heights == profile,
                  "each same-size returning position restores snow before the Space notification")
        }
        on.duck.clear()
        snapshot([floor], changing: true, at: 4)
        var enlarged = window
        enlarged.frame.size.width += 36
        snapshot([enlarged, floor], changing: true, at: 4.02)
        check(on.snow.drifts[window.id]?.surface.isVisible == false, "transient resized return stays hidden")
        snapshot([enlarged, floor], changing: true, at: 4.12)
        check(on.snow.drifts[window.id]?.surface.isVisible == false,
              "the resized return remains hidden during the protection interval")
        snapshot([enlarged, floor], changing: true, at: 4.33)
        check(on.snow.drifts[window.id]?.surface.frame == enlarged.frame
              && on.snow.drifts[window.id]?.surface.isVisible == true && on.duck.prints.isEmpty,
              "a stable resized return restores snow and discards the old duck effects")

        let betweenFrames = Fixture()
        betweenFrames.visitRoof()
        var hidden = window
        hidden.isVisible = false
        betweenFrames.sync([hidden, floor])
        betweenFrames.sync([window, floor])
        betweenFrames.tick()
        check(betweenFrames.duck.pose?.anchor?.surfaceID != window.id,
              "a hide and return between render ticks cannot restore the ended visit")
    }

    static func crossDisplay() {
        let f = Fixture()
        f.visitRoof()
        let anchor = f.duck.pose!.anchor!
        let second = DuckDisplay(frame: CGRect(x: -510, y: -95, width: 410, height: 435), visibleTop: 315)
        f.active.append(second); f.displays.append(second.frame)
        var across = window
        across.frame.origin.x = -100 - anchor.localX
        f.sync([across, floor]); f.tick()
        check(abs((f.duck.pose?.feet.x ?? 1000) + 100) <= 4.1 && f.duck.pose?.anchor?.surfaceID == window.id,
              "a carried pose spans the seam in world points")
        f.active = [second]
        across.frame.origin.x -= 38
        f.sync([across, floor]); f.tick()
        check(f.duck.pose?.anchor?.surfaceID == window.id && f.duck.pose!.bounds.maxX < -100,
              "the remaining active display receives the same passenger")
        f.active = [display]
        let paused = f.duck.pose!.time
        f.tick(50)
        check(f.duck.pose?.time == paused, "fullscreen on the passenger's display freezes only that duck clock")
    }

    static func interactions() {
        let f = Fixture([floor])
        f.treesEnabled = true
        let tree = f.trees.place(at: CGPoint(x: 80, y: -58), displayFrame: display.frame, snow: f.snow)!
        f.until("duck seeks out a distant tree in the first ten seconds", steps: 100) {
            f.duck.pose?.activity.isTreeInteraction == true
        }
        f.trees.remove(id: tree)
        f.tick()
        check(f.duck.pose?.activity == .look && f.trees.placements(in: f.snow).isEmpty,
              "deleting the tree interrupts the scene without creating another object")

        let roof = Fixture()
        roof.treesEnabled = true
        let id = roof.trees.place(at: CGPoint(x: 208, y: window.top + 12), displayFrame: display.frame, snow: roof.snow)!
        roof.until("the duck visits a tree on a long-active roof", steps: 7_000) {
            roof.duck.pose?.activity.isTreeInteraction == true && roof.duck.pose?.anchor?.surfaceID == window.id
        }
        check(roof.trees.placements(in: roof.snow).first?.id == id, "visiting keeps the tree in place")
        roof.until("the first visit finishes", steps: 6_500) { roof.duck.pose?.anchor?.surfaceID == floor.id }
    }

    static func lifeAndMemory() {
        let shortFloor = SnowSurface(id: "memory-floor", frame: CGRect(x: -100, y: -61, width: 280, height: 1), kind: .floor)
        var treeVariants: Set<DuckActivity> = [], snowmanVariants: Set<DuckActivity> = [], ambient: Set<DuckActivity> = []
        for seed in 1...24 {
            let tree = Fixture([shortFloor], seed: UInt64(seed))
            tree.treesEnabled = true
            _ = tree.trees.place(at: CGPoint(x: 10, y: shortFloor.top + 2), displayFrame: display.frame, snow: tree.snow)!
            tree.until("a new tree attracts the duck", steps: 300) { tree.duck.pose?.activity.isTreeInteraction == true }
            treeVariants.insert(tree.duck.pose!.activity)
            let man = Fixture([shortFloor], seed: UInt64(seed))
            check(man.snow.placeSnowman(on: shortFloor, x: 10), "snowman fixture can be placed")
            man.until("a new snowman attracts the duck", steps: 300) { man.duck.pose?.activity.isSnowmanInteraction == true }
            snowmanVariants.insert(man.duck.pose!.activity)
            let everyday = Fixture([shortFloor], seed: UInt64(seed))
            for _ in 0..<600 {
                everyday.tick()
                if let activity = everyday.duck.pose?.activity { ambient.insert(activity) }
            }
        }
        check(treeVariants == [.inspectTree, .restByTree, .inspectLights], "tree reactions vary with random seeds")
        check(snowmanVariants == [.greet, .guardSnowman, .bowSnowman], "snowman reactions vary with random seeds")
        check(ambient.isSuperset(of: [.stretch, .shake, .listen]), "ordinary walks include all new activities")

        var repeatDelays: [Int] = []
        for seed in [UInt64(3), 19, 41, 76] {
            let f = Fixture([shortFloor], seed: seed)
            f.treesEnabled = true
            let first = f.trees.place(at: CGPoint(x: 10, y: shortFloor.top + 2), displayFrame: display.frame, snow: f.snow)!
            f.until("first meeting starts", steps: 300) { f.duck.pose?.activity.isTreeInteraction == true }
            var previous = true
            // Fifty ticks below have the duck disabled, so this is 299.9
            // seconds of active duck time rather than wall-clock time.
            for tick in 1..<3050 {
                if tick == 100 { f.treesEnabled = false }
                if tick == 150 { f.treesEnabled = true }
                if tick == 200 { f.duck.clear(preserveMemory: true) }
                if tick == 300 { f.duck.setEnabled(false, surfaces: f.snow.surfaces) }
                if tick == 350 { f.duck.setEnabled(true, surfaces: f.snow.surfaces) }
                if tick == 400 { var hidden = shortFloor; hidden.isVisible = false; f.sync([hidden]) }
                if tick == 450 { f.sync([shortFloor]) }
                if tick == 500 {
                    check(f.trees.move(id: first, to: CGPoint(x: 20, y: shortFloor.top + 2),
                                       displayFrame: display.frame, snow: f.snow), "remembered tree can move")
                }
                f.tick()
                let reacting = f.duck.pose?.activity.isTreeInteraction == true
                check(!(reacting && !previous), "a remembered tree cannot cause a repeat before five active minutes")
                previous = reacting
            }
            var elapsed = 3049
            f.until("the same tree eventually becomes interesting again", steps: 3_800) {
                let reacting = f.duck.pose?.activity.isTreeInteraction == true
                if reacting && !previous { return true }
                previous = reacting; elapsed += 1
                return false
            }
            repeatDelays.append(elapsed)
            check(elapsed >= 3050 && elapsed <= 6300, "revisit follows the 5–10 minute memory with time to walk back")
            f.trees.remove(id: first)
            f.tick()
            let replacement = f.trees.place(at: CGPoint(x: 10, y: shortFloor.top + 2), displayFrame: display.frame, snow: f.snow)!
            check(replacement != first, "replacement has a new identity")
            f.until("a new tree is not suppressed by the old tree's memory", steps: 300) {
                f.duck.pose?.activity.isTreeInteraction == true
            }
        }
        check(Set(repeatDelays).count > 1, "memory duration varies between seeds")

        let independent = Fixture([shortFloor], seed: 33)
        independent.treesEnabled = true
        _ = independent.trees.place(at: CGPoint(x: -25, y: shortFloor.top + 2), displayFrame: display.frame, snow: independent.snow)!
        independent.until("first tree encounter", steps: 300) { independent.duck.pose?.activity.isTreeInteraction == true }
        check(independent.snow.placeSnowman(on: shortFloor, x: 105), "a second object can be introduced")
        independent.until("a new snowman is interesting while the tree is remembered", steps: 400) {
            independent.duck.pose?.activity.isSnowmanInteraction == true
        }
        var wasSnowman = true
        for _ in 0..<2_999 {
            independent.tick()
            let reaction = independent.duck.pose?.activity.isSnowmanInteraction == true
            check(!(reaction && !wasSnowman), "the same snowman is remembered for at least five minutes")
            wasSnowman = reaction
        }
    }

    static func dockFlights() {
        let dock = SnowSurface(id: "real-dock", frame: CGRect(x: 76, y: -60, width: 220, height: 51), kind: .dock)
        let mask = dock.frame.insetBy(dx: -6, dy: -12)
        let f = Fixture([dock, floor])
        var sawLeftToRight = false, sawRightToLeft = false
        var previousLandingSide: Bool?
        var blockedFrames = 0
        var high: CGFloat = floor.top
        for _ in 0..<14_000 {
            f.tick()
            guard let pose = f.duck.pose else { continue }
            if pose.bounds.intersects(mask) { blockedFrames += 1 }
            if pose.activity == .fly {
                high = max(high, pose.feet.y)
            }
            if pose.anchor != nil {
                let onRight = pose.feet.x > dock.frame.midX
                if let previousLandingSide, previousLandingSide != onRight {
                    if onRight { sawLeftToRight = true } else { sawRightToLeft = true }
                }
                previousLandingSide = onRight
            }
        }
        check(sawLeftToRight && sawRightToLeft && blockedFrames == 0,
              "duck crosses the Dock safely in both directions (right \(sawLeftToRight), left \(sawRightToLeft), blocked \(blockedFrames))")
        check(high >= mask.maxY && high <= mask.maxY + 14,
              "both crossings stay close above the Dock")

        let wideFrame = CGRect(x: 0, y: 0, width: 1_800, height: 900)
        let wideFloor = SnowSurface(id: "wide-floor", frame: CGRect(x: 0, y: -1, width: 1_800, height: 1), kind: .floor)
        let wideDock = SnowSurface(id: "wide-dock", frame: CGRect(x: 340, y: 0, width: 1_120, height: 75), kind: .dock)
        let wide = Fixture([wideDock, wideFloor])
        wide.active = [DuckDisplay(frame: wideFrame, visibleTop: 876)]; wide.displays = [wideFrame]
        var flightStart: CGPoint?, flightSteps = 0, crossings = 0
        var timely = true, clear = true
        for _ in 0..<14_000 {
            wide.tick()
            guard let pose = wide.duck.pose else { continue }
            if pose.activity == .fly {
                if flightStart == nil { flightStart = pose.feet; flightSteps = 0 }
                flightSteps += 1
                clear = clear && !pose.bounds.intersects(wideDock.frame.insetBy(dx: -6, dy: -12))
            } else if let start = flightStart {
                let horizontal = abs(pose.feet.x - start.x)
                if horizontal > wideDock.frame.width {
                    crossings += 1
                    timely = timely && Double(flightSteps) * 0.1 < Double(horizontal / 180) + 1.2
                }
                flightStart = nil
            }
            if crossings >= 2 { break }
        }
        check(crossings >= 2 && timely && clear,
              "wide Dock crossings in both directions remain clear and do not slow the entire flight")

        let destination = Fixture([dock, floor])
        destination.treesEnabled = true
        _ = destination.trees.place(at: CGPoint(x: 410, y: floor.top + 2), displayFrame: display.frame, snow: destination.snow)
        destination.until("duck flies across the Dock after its stay", steps: 7_000) { destination.duck.pose?.activity == .fly }
        destination.until("duck interacts with the tree after crossing", steps: 500) { destination.duck.pose?.activity.isTreeInteraction == true }

        let blocked = Fixture([dock, floor])
        blocked.until("crossing starts above an open Dock", steps: 7_000) { blocked.duck.pose?.activity == .fly }
        var crowded = floor
        crowded.occluders = [CGRect(x: mask.maxX, y: floor.top, width: display.frame.maxX - mask.maxX, height: 110)]
        blocked.sync([dock, crowded])
        blocked.tick(60)
        check(blocked.duck.pose.map { $0.feet.x < mask.maxX } ?? true, "movement of a foreground mask cancels the covered landing")

    }

    static func occasionalCrossing() {
        let room = CGRect(x: 0, y: -60, width: 3_200, height: 470)
        var floor = SnowSurface(id: "room-floor", frame: CGRect(x: 0, y: -61, width: room.width, height: 1), kind: .floor)
        floor.occluders = [CGRect(x: room.midX - 10, y: floor.top, width: 20, height: 65)]
        let f = Fixture([floor])
        f.active = [DuckDisplay(frame: room, visibleTop: room.maxY - 24)]; f.displays = [room]
        var takeoff: Int?, touchdown: Int?
        for step in 1...6_500 {
            f.tick()
            if f.duck.pose?.activity == .fly { takeoff = takeoff ?? step }
            if let pose = f.duck.pose, pose.anchor?.surfaceID == floor.id, pose.feet.x > room.midX + 300 {
                touchdown = step
                break
            }
        }
        check(takeoff.map { (1_200...6_200).contains($0) } == true && touchdown != nil,
              "after a long stay a low flight takes the duck to the farther side")
        var newlyAirborne = false
        for _ in 0..<400 {
            f.tick()
            newlyAirborne = newlyAirborne || f.duck.pose?.activity == .fly
        }
        check(!newlyAirborne, "moving to another side resets the long-stay interval")

        let open = Fixture([DuckWorldTests.floor])
        var stayedOnFirstSide = true
        for _ in 0..<1_200 {
            open.tick()
            if let pose = open.duck.pose { stayedOnFirstSide = stayedOnFirstSide && pose.feet.x <= display.frame.midX }
        }
        check(stayedOnFirstSide, "an unobstructed floor keeps the duck on its side for the first two minutes")
        open.until("the duck eventually moves across an unobstructed floor", steps: 5_100) {
            open.duck.pose?.anchor?.surfaceID == DuckWorldTests.floor.id
                && (open.duck.pose?.feet.x ?? 0) > display.frame.midX + 50
        }
        check(open.duck.pose?.anchor?.surfaceID == DuckWorldTests.floor.id,
              "the long-stay schedule can reach the opposite side without a Dock")
    }

    static func routesWithoutDockBounds() {
        let region = DuckDisplay(frame: display.frame, visibleTop: display.visibleTop, visibleBottom: -5)
        let backdrop = SnowSurface(id: "wide-behind-active", frame: CGRect(x: -100, y: -5, width: 600, height: 330),
                                   kind: .window)
        var floorWithBackdrop = floor
        floorWithBackdrop.occluders = [backdrop.frame, window.frame]
        floorWithBackdrop.floorOverlayOccluders = []
        let unknown = Fixture([window, backdrop, floorWithBackdrop])
        let control = Fixture([window, backdrop, floorWithBackdrop], enabled: false)
        unknown.active = [region]; control.active = [region]
        unknown.tick(20, snowing: true); control.tick(20, snowing: true)
        check(unknown.duck.pose?.anchor?.surfaceID == floor.id && unknown.duck.pose!.feet.y < floor.top + 28,
              "without Dock bounds the duck appears down on the real floor")
        let start = unknown.duck.pose!.feet
        var roofAt: Int?, crossingAt: Int?, last = start
        let dock = CGRect(x: display.frame.minX + display.frame.width * 0.19, y: display.frame.minY,
                          width: display.frame.width * 0.62, height: region.visibleBottom - display.frame.minY)
        var touchedDock = false, jumped = false, walkedAtFloor = true, floorTracks = false
        for frame in 21...6_500 {
            unknown.tick(snowing: true); control.tick(snowing: true)
            guard let pose = unknown.duck.pose else { preconditionFailure("duck vanished with unknown Dock bounds") }
            touchedDock = touchedDock || (pose.anchor != nil && pose.bounds.intersects(dock))
            jumped = jumped || hypot(pose.feet.x - last.x, pose.feet.y - last.y) > 46
            if let anchor = pose.anchor, anchor.surfaceID == floor.id {
                let height = unknown.snow.drifts[floor.id]!.visibleContour.height(at: anchor.localX)
                walkedAtFloor = walkedAtFloor && abs(pose.feet.y - floor.top - height) < 0.001
            }
            floorTracks = floorTracks || unknown.duck.prints.contains { $0.anchor.surfaceID == floor.id }
            last = pose.feet
            if pose.anchor?.surfaceID == window.id { roofAt = roofAt ?? frame; break }
            if pose.anchor?.surfaceID == floor.id && pose.feet.x >= display.frame.maxX - display.frame.width / 3 {
                crossingAt = crossingAt ?? frame
            }
        }
        check(roofAt != nil && crossingAt == nil,
              "with unknown Dock bounds the duck visits the window after the side stay")
        check(!touchedDock && !jumped && walkedAtFloor && floorTracks,
              "real ground contact produces tracks and avoids the estimated Dock (\(touchedDock), \(jumped), \(walkedAtFloor), \(floorTracks))")
        check(unknown.snow.surfaces.map(\.id) == control.snow.surfaces.map(\.id)
              && unknown.snow.drifts[floor.id]?.heights == control.snow.drifts[floor.id]?.heights,
              "the approximate Dock adds no snow surfaces and preserves floor accumulation")

        let confirmed = SnowSurface(id: "real-dock", frame: CGRect(x: 76, y: -60, width: 220, height: 51), kind: .dock)
        unknown.until("a floor pose is available before refining Dock bounds", steps: 6_500) {
            unknown.duck.pose?.anchor?.surfaceID == floor.id
        }
        let previous = unknown.duck.pose!.feet
        unknown.sync([confirmed, window, backdrop, floorWithBackdrop])
        unknown.tick()
        check(unknown.duck.pose?.anchor?.surfaceID == floor.id && abs(unknown.duck.pose!.feet.x - previous.x) < 4,
              "learning exact Dock bounds preserves the ground pose when it is still clear")

        for variant in [DuckDisplay(frame: display.frame, visibleTop: display.visibleTop, visibleLeft: -15),
                        DuckDisplay(frame: display.frame, visibleTop: display.visibleTop, visibleRight: 415),
                        DuckDisplay(frame: display.frame, visibleTop: display.visibleTop, visibleBottom: -56)] {
            let fallback = Fixture([floor])
            fallback.active = [variant]
            fallback.tick(20)
            check(fallback.duck.pose.map {
                $0.bounds.minX >= variant.visibleLeft && $0.bounds.maxX <= variant.visibleRight
                    && $0.feet.y == floor.top
            } == true, "side Dock or autohide trigger strip leaves a visible spawn")
        }

        var inactive = window
        inactive.suppressesSnowfall = false
        let late = Fixture([inactive, floor])
        late.tick(100)
        late.sync([window, floor])
        late.until("the newly focused window can be visited after the floor stay", steps: 6_500) {
            late.duck.pose?.anchor?.surfaceID == window.id
        }
    }

    static func windowAfterFloorStay() {
        var inactive = window
        inactive.suppressesSnowfall = false
        let active = Fixture(), control = Fixture([inactive, floor])
        active.treesEnabled = true
        _ = active.trees.place(at: CGPoint(x: window.frame.midX, y: window.top + 5),
                               displayFrame: display.frame, snow: active.snow)
        var departureStep: Int?
        for step in 1...6_500 {
            active.tick(); control.tick()
            if control.duck.pose?.activity == .fly {
                departureStep = step
                check(active.duck.pose?.activity == .fly,
                      "the window is considered when the full floor timer and activity finish")
                break
            }
            check(active.duck.pose?.anchor == control.duck.pose?.anchor
                  && active.duck.pose?.feet == control.duck.pose?.feet
                  && active.duck.pose?.activity == control.duck.pose?.activity,
                  "a focused window and its tree do not interrupt the floor stay")
        }
        check(departureStep.map { (1_200...6_200).contains($0) } == true,
              "the full randomized floor stay completes before departure")
        active.until("the active window is reached before the opposite side", steps: 5_200) {
            active.duck.pose?.anchor?.surfaceID == window.id
                || (active.duck.pose?.anchor?.surfaceID == floor.id
                    && (active.duck.pose?.feet.x ?? 0) > display.frame.midX + 50)
        }
        check(active.duck.pose?.anchor?.surfaceID == window.id,
              "eligible focused window has priority over the opposite floor side")
        active.until("duck returns to the floor", steps: 6_500) { active.duck.pose?.anchor?.surfaceID == floor.id }
        var stayedBelow = true
        for _ in 0..<1_200 {
            active.tick()
            stayedBelow = stayedBelow && active.duck.pose?.anchor?.surfaceID == floor.id
        }
        check(stayedBelow, "returning from the roof starts a fresh floor stay")
        active.until("same focused window is revisited after the floor stay", steps: 5_200) {
            active.duck.pose?.anchor?.surfaceID == window.id
        }
        check(active.duck.pose?.anchor?.surfaceID == window.id, "unchanged focus allows a later visit")

        var wide = window
        wide.frame = CGRect(x: display.frame.minX, y: floor.top, width: display.frame.width, height: 230)
        let fallback = Fixture([wide, floor])
        fallback.until("a full-width window does not prevent crossing", steps: 6_500) {
            fallback.duck.pose?.anchor?.surfaceID == floor.id
                && (fallback.duck.pose?.feet.x ?? 0) > display.frame.midX + 50
        }
        check(fallback.duck.pose?.anchor?.surfaceID == floor.id,
              "an ineligible active window falls back to the opposite floor side")
    }

    static func sustainedFocus() {
        var other = window
        other.id = "other:window"
        other.frame = other.frame.offsetBy(dx: 40, dy: 10)
        other.suppressesSnowfall = false
        var inactive = window
        inactive.suppressesSnowfall = false
        let f = Fixture([window, other, floor])
        var stayedBelow = true
        for _ in 0..<3 {
            for surfaces in [[window, other, floor], [inactive, windowWithFocus(other), floor]] {
                f.sync(surfaces)
                for _ in 0..<65 {
                    f.tick()
                    stayedBelow = stayedBelow && f.duck.pose?.activity != .fly
                }
            }
        }
        check(stayedBelow, "brief window switches do not interrupt a walk downstairs")
        f.sync([window, other, floor])
        f.visitRoof()
        var sawRoofActivity = false
        var roofSteps = 0
        f.until("duck finishes a visit", steps: 6_500) {
            if let pose = f.duck.pose, pose.anchor?.surfaceID == window.id, pose.activity != .walk {
                sawRoofActivity = true
            }
            if f.duck.pose?.anchor?.surfaceID == window.id { roofSteps += 1 }
            return f.duck.pose?.anchor?.surfaceID == floor.id
        }
        check(sawRoofActivity, "the duck does something on the roof after its walk before leaving")
        check(roofSteps >= 1_200, "the duck stays on a stable focused roof for at least two minutes")
        let another = Fixture(seed: 37)
        another.visitRoof()
        var otherRoofSteps = 0
        another.until("another window visit finishes", steps: 6_500) {
            if another.duck.pose?.anchor?.surfaceID == window.id { otherRoofSteps += 1 }
            return another.duck.pose?.anchor?.surfaceID == floor.id
        }
        check((1_200...6_100).contains(otherRoofSteps) && roofSteps != otherRoofSteps,
              "different random seeds produce window visits within the requested range")
        var stayedOnFloor = true
        for _ in 0..<600 {
            f.tick()
            stayedOnFloor = stayedOnFloor && f.duck.pose?.anchor?.surfaceID == floor.id
        }
        check(stayedOnFloor, "the same sustained focus does not interrupt the new floor stay")
        f.sync([inactive, floor]); f.tick()
        f.sync([window, floor]); f.visitRoof()
        check(f.duck.pose?.anchor?.surfaceID == window.id, "regaining focus makes a window eligible for a new visit")
    }

    private static func windowWithFocus(_ surface: SnowSurface) -> SnowSurface {
        var focused = surface
        focused.suppressesSnowfall = true
        return focused
    }

    static func floorPauseAfterRoofVisit() {
        let f = Fixture()
        f.visitRoof()
        f.until("duck returns after a roof activity", steps: 6_500) { f.duck.pose?.anchor?.surfaceID == floor.id }
        let touchdown = f.duck.pose!.feet
        for _ in 0..<29 {
            f.tick()
            check(f.duck.pose?.anchor?.surfaceID == floor.id, "the duck spends time on the ground after a visit")
        }
        check(abs(f.duck.pose!.feet.x - touchdown.x) > 20, "the duck visibly walks before taking off again")
    }

    static func floorIgnoresWindowChanges() {
        let baseline = Fixture([floor])
        var maskedFloor = floor
        maskedFloor.floorOverlayOccluders = []
        let changing = Fixture([maskedFloor])
        baseline.tick(20); changing.tick(20)
        var reshaped = window
        for index in 0..<30 {
            let feet = baseline.duck.pose!.feet
            if index.isMultiple(of: 3) {
                reshaped.frame = CGRect(x: display.frame.minX, y: floor.top, width: display.frame.width, height: 210)
            } else {
                reshaped.frame = CGRect(x: feet.x - 40, y: floor.top, width: 80, height: 35)
            }
            reshaped.suppressesSnowfall = index.isMultiple(of: 2)
            maskedFloor.occluders = [reshaped.frame]
            changing.sync(index.isMultiple(of: 5) ? [maskedFloor] : [reshaped, maskedFloor])
            changing.tick(); baseline.tick()
            check(changing.duck.pose?.anchor == baseline.duck.pose?.anchor
                  && changing.duck.pose?.feet == baseline.duck.pose?.feet
                  && changing.duck.pose?.activity == baseline.duck.pose?.activity,
                  "window focus and minimize frames leave the floor route alone")
        }
    }

    static func focusedWindowFlights() {
        var background = window
        background.suppressesSnowfall = false
        let inactive = Fixture([background, floor])
        inactive.treesEnabled = true
        _ = inactive.trees.place(at: CGPoint(x: background.frame.midX, y: background.top + 5),
                                 displayFrame: display.frame, snow: inactive.snow)
        var stayedBelow = true
        for _ in 0..<500 {
            inactive.tick()
            stayedBelow = stayedBelow && inactive.duck.pose?.anchor?.surfaceID != background.id
        }
        check(stayedBelow, "inactive roofs cannot attract the duck")
        inactive.sync([window, floor])
        inactive.visitRoof()
        let origin = inactive.duck.pose!.feet
        inactive.sync([background, floor])
        inactive.tick()
        check(inactive.duck.pose?.activity == .fly && inactive.duck.pose?.feet == origin,
              "focus-only update starts a continuous descent at the old position")
        inactive.until("duck lands below the inactive window", steps: 100) { inactive.duck.pose?.anchor?.surfaceID == floor.id }

        let resizing = Fixture()
        resizing.visitRoof()
        let launch = resizing.duck.pose!.feet
        var wide = window
        wide.frame = CGRect(x: display.frame.minX, y: display.frame.minY, width: display.frame.width, height: 230)
        resizing.sync([wide, floor])
        resizing.tick()
        check(resizing.duck.pose?.activity == .fly && resizing.duck.pose?.feet == launch,
              "expanding to whole width starts the descent from the previous feet")
        resizing.until("duck lands below the resized wide window", steps: 100) { resizing.duck.pose?.anchor?.surfaceID == floor.id }

        let incoming = Fixture()
        incoming.until("active roof flight starts") { incoming.duck.pose?.activity == .fly }
        let airborne = incoming.duck.pose!.feet
        incoming.sync([background, floor]); incoming.tick()
        check(incoming.duck.pose?.feet == airborne && incoming.duck.pose?.anchor == nil,
              "loss of focus midflight reroutes in place")
        incoming.until("aborted landing returns to the floor", steps: 100) { incoming.duck.pose?.anchor?.surfaceID == floor.id }

        let blocked = Fixture()
        blocked.visitRoof()
        let blockedOrigin = blocked.duck.pose!.feet
        var coveredFloor = floor
        coveredFloor.occluders = [CGRect(x: display.frame.minX, y: floor.top, width: display.frame.width, height: 80)]
        blocked.sync([background, coveredFloor])
        blocked.tick(40)
        check(blocked.duck.pose?.activity == .fly && blocked.duck.pose?.feet == blockedOrigin,
              "blocked floor keeps the same airborne position")
        blocked.sync([background, floor])
        blocked.until("duck descends after the ground opens", steps: 100) { blocked.duck.pose?.anchor?.surfaceID == floor.id }
    }

    static func avoidsMovingTractor() {
        var wide = window
        wide.frame = CGRect(x: display.frame.minX, y: display.frame.minY, width: display.frame.width, height: 230)
        for speed in [1.25, 2] {
            let on = Fixture([wide, floor])
            let off = Fixture([wide, floor], enabled: false)
            on.tick(20, snowing: true); off.tick(20, snowing: true)
            var schedule = SnowplowSchedule()
            schedule.requestSweep()
            var previous = on.duck.pose!.feet
            var vanished = false, jumped = false, flewOver = false, landedBehind = false
            for _ in 0..<70 {
                let sweeps = schedule.advance(delta: 0.1, surfaces: on.snow.surfaces, activeRegions: on.displays,
                                               intervalMinutes: 10, speedMultiplier: speed)
                for fixture in [on, off] {
                    for sweep in sweeps {
                        fixture.snow.sweepFloor(surfaceID: sweep.surfaceID, fromX: sweep.fromX, toX: sweep.toX)
                    }
                    fixture.plows = schedule.passes; fixture.sweeps = sweeps
                    fixture.tick(snowing: true)
                }
                guard let pose = on.duck.pose else { vanished = true; continue }
                jumped = jumped || hypot(previous.x - pose.feet.x, previous.y - pose.feet.y) > 47
                previous = pose.feet
                if let plow = schedule.passes[floor.id] {
                    if pose.activity == .fly, abs(pose.feet.x - plow.x) < 42, pose.feet.y >= floor.top + 62 {
                        flewOver = true
                    }
                    if flewOver, pose.anchor?.surfaceID == floor.id, pose.feet.x < plow.x - 48 { landedBehind = true }
                }
            }
            check(flewOver && landedBehind && !vanished && !jumped, "duck clears and lands behind the moving plow at speed \(speed)")
            check(on.snow.drifts[floor.id]?.heights == off.snow.drifts[floor.id]?.heights,
                  "a duck flight never changes the tractor's snow")
        }
    }

    private static func buildSnowman(_ f: Fixture) -> [UUID] {
        func advance(_ count: Int) {
            for _ in 0..<count {
                f.snow.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: f.displays)
            }
        }
        advance(150)
        let ids = [160.0, 280, 420].map { x -> UUID in
            let y = floor.top + f.snow.drifts[floor.id]!.visibleContour.height(at: x - floor.frame.minX)
            let id = f.snow.beginSnowball(at: CGPoint(x: x, y: y))!
            f.snow.endDrag()
            return id
        }
        advance(8)
        for (lower, upper) in zip(ids, ids.dropFirst()) {
            let base = f.snow.balls.first { $0.id == lower }!
            let ball = f.snow.balls.first { $0.id == upper }!
            precondition(f.snow.beginDrag(at: ball.position) == upper)
            f.snow.drag(to: CGPoint(x: base.position.x, y: base.position.y + 20))
            f.snow.endDrag()
            advance(8)
        }
        precondition(f.snow.snowmen.first?.ballIDs == ids)
        return ids
    }

    static func snowAndObjectsParity() {
        let on = Fixture([floor])
        let off = Fixture([floor], enabled: false)
        let idsOn = buildSnowman(on), idsOff = buildSnowman(off)
        let treePoint = CGPoint(x: 340, y: -15)
        let treeOn = on.trees.place(at: treePoint, displayFrame: display.frame, snow: on.snow)!
        let treeOff = off.trees.place(at: treePoint, displayFrame: display.frame, snow: off.snow)!
        on.treesEnabled = true; off.treesEnabled = true
        var greetingAt: Int?
        var greetingCount = 0, passedSnowman = false, wasGreeting = false
        let manX = on.snow.balls.first { $0.id == idsOn[0] }!.position.x
        var passedCenterOnFoot = false
        for index in 0..<820 {
            if index == 215 {
                on.sweeps = [SnowplowSweep(surfaceID: floor.id, fromX: -100, toX: 8)]
                off.sweeps = on.sweeps
                for f in [on, off] { f.snow.sweepFloor(surfaceID: floor.id, fromX: -100, toX: 8) }
            }
            on.tick(snowing: true); off.tick(snowing: true)
            if let pose = on.duck.pose {
                let greeting = pose.activity.isSnowmanInteraction
                if greeting && !wasGreeting { greetingCount += 1; greetingAt = greetingAt ?? index }
                wasGreeting = greeting
                if greetingAt != nil && pose.activity == .walk && abs(pose.feet.x - manX) < 5 {
                    passedCenterOnFoot = true
                }
                if greetingAt != nil && pose.activity == .walk && pose.feet.x > manX + 24 && pose.anchor?.surfaceID == floor.id {
                    passedSnowman = true
                }
            }
        }
        check(greetingAt.map { $0 < 100 } == true, "the duck seeks out the snowman in the first ten seconds")
        check(greetingCount == 1 && passedCenterOnFoot && passedSnowman,
              "the duck passes through the snowman's horizontal footprint on foot with one greeting")
        let treeWalk = Fixture([floor])
        treeWalk.treesEnabled = true
        _ = treeWalk.trees.place(at: CGPoint(x: 80, y: floor.top + 2), displayFrame: display.frame, snow: treeWalk.snow)
        treeWalk.until("the duck passes through the tree's horizontal footprint on foot", steps: 1_100) {
            treeWalk.duck.pose?.activity == .walk && abs((treeWalk.duck.pose?.feet.x ?? .infinity) - 80) < 5
        }
        check(treeWalk.duck.pose?.anchor?.surfaceID == floor.id, "the duck walks past the tree on its side")
        check(on.snow.drifts[floor.id]?.heights == off.snow.drifts[floor.id]?.heights, "all snow samples match with the duck on and off")
        check(zip(idsOn, idsOff).allSatisfy { a, b in
            let left = on.snow.balls.first { $0.id == a }
            let right = off.snow.balls.first { $0.id == b }
            return left?.position == right?.position && left?.radius == right?.radius && left?.surfaceID == right?.surfaceID
        }, "duck does not move or resize the snowballs")
        check(on.snow.snowmen.first?.ballIDs == idsOn && off.snow.snowmen.first?.ballIDs == idsOff,
              "the same members remain in each world's snowman")
        check(on.trees.placements(in: on.snow).first?.id == treeOn && off.trees.placements(in: off.snow).first?.id == treeOff
              && on.trees.placements(in: on.snow).first?.base == off.trees.placements(in: off.snow).first?.base,
              "each tree retains its identity and identical position")
    }
}
