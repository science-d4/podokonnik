import Foundation
import CoreGraphics

struct DuckDisplay: Equatable {
    let frame: CGRect
    let visibleTop: CGFloat
    let visibleBottom: CGFloat
    let visibleLeft: CGFloat
    let visibleRight: CGFloat

    init(frame: CGRect, visibleTop: CGFloat, visibleBottom: CGFloat? = nil,
         visibleLeft: CGFloat? = nil, visibleRight: CGFloat? = nil) {
        self.frame = frame
        self.visibleTop = visibleTop
        self.visibleBottom = visibleBottom ?? frame.minY
        self.visibleLeft = visibleLeft ?? frame.minX
        self.visibleRight = visibleRight ?? frame.maxX
    }

    var navigationFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width,
               height: max(0, min(visibleTop, frame.maxY) - frame.minY))
    }
}

struct DuckAnchor: Equatable {
    let surfaceID: String
    var localX: CGFloat

    init(_ surface: SnowSurface, x: CGFloat) {
        surfaceID = surface.id
        localX = x - surface.frame.minX
    }
}

enum DuckActivity: Hashable {
    case walk, look, peck, preen, rest, watch, stretch, shake, listen
    case greet, guardSnowman, bowSnowman, inspectTree, restByTree, inspectLights, startled, fly

    var isTreeInteraction: Bool { self == .inspectTree || self == .restByTree || self == .inspectLights }
    var isSnowmanInteraction: Bool { self == .greet || self == .guardSnowman || self == .bowSnowman }
}

struct DuckWingbeat {
    private static let frequency = 4.2
    private static let downstroke = 0.36
    private let phase: Double

    init(time: Double) {
        let beats = time * Self.frequency
        phase = beats - floor(beats)
    }

    var elevation: CGFloat {
        if phase < Self.downstroke {
            return CGFloat(cos(.pi * phase / Self.downstroke))
        }
        return -CGFloat(cos(.pi * (phase - Self.downstroke) / (1 - Self.downstroke)))
    }

    // The downstroke gains a little ground and the recovery gives it back.
    // Use a periodic time offset so the flight still ends at the same point.
    var travelOffset: Double {
        0.007 * sin(2 * .pi * (phase - Self.downstroke / 2))
    }
}

struct DuckPose {
    static let scale: CGFloat = 1.2
    static let groundRadius = 17 * scale
    static let footRadius = 7 * scale
    static let flightRadius = 21 * scale
    static let flightHeight = 36 * scale

    var anchor: DuckAnchor?
    var feet: CGPoint
    var facing: CGFloat
    var activity: DuckActivity
    var time: Double
    var flightTilt: CGFloat = 0
    var feetExtended: CGFloat = 1

    var bounds: CGRect { Self.bounds(at: feet, flying: activity == .fly) }

    static func bounds(at feet: CGPoint, flying: Bool) -> CGRect {
        let radius = flying ? flightRadius : groundRadius
        return CGRect(x: feet.x - radius, y: feet.y,
                      width: radius * 2, height: flying ? flightHeight : 30 * scale)
    }
}

struct DuckEffect {
    let anchor: DuckAnchor
    let facing: CGFloat
    let foot: CGFloat
    let lifetime: Double
    var age: Double = 0

    var opacity: CGFloat { max(0, 1 - age / lifetime) }
}

private struct DuckTarget {
    enum ID: Hashable {
        case snowman([UUID]), tree(UUID)
    }
    let id: ID
    let surfaceID: String
    let bounds: CGRect
    let localX: CGFloat
}

private struct DockCrossing {
    let entry: CGFloat
    let exit: CGFloat
    let clearance: CGFloat
    let crest: CGFloat
    private var samples: [(progress: CGFloat, distance: CGFloat)] = [(0, 0)]
    private var length: CGFloat = 0

    init?(dock: CGRect, from start: CGPoint, to end: CGPoint, ceiling: CGFloat) {
        let dx = end.x - start.x
        guard dx != 0 else { return nil }
        let a = (dock.minX - DuckPose.flightRadius - start.x) / dx
        let b = (dock.maxX + DuckPose.flightRadius - start.x) / dx
        entry = min(a, b)
        exit = max(a, b)
        guard entry > 0, exit < 1 else { return nil }
        clearance = min(dock.maxY + 7, ceiling)
        guard clearance >= dock.maxY else { return nil }
        crest = min(6, ceiling - clearance)
        var previous = start
        for (lower, upper) in [(CGFloat(0), entry), (entry, exit), (exit, CGFloat(1))] {
            for step in 1...16 {
                let progress = lower + (upper - lower) * CGFloat(step) / 16
                let point = CGPoint(x: start.x + dx * progress,
                                    y: height(at: progress, from: start.y, to: end.y))
                length += hypot(point.x - previous.x, point.y - previous.y)
                samples.append((progress, length))
                previous = point
            }
        }
    }

    func height(at t: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        func ease(_ value: CGFloat) -> CGFloat { value * value * (3 - 2 * value) }
        if t < entry { return start + (clearance - start) * ease(t / entry) }
        if t > exit { return end + (clearance - end) * ease((1 - t) / (1 - exit)) }
        let span = (t - entry) / (exit - entry)
        let hump = sin(.pi * span)
        return clearance + crest * hump * hump
    }

    func duration(speed: CGFloat) -> Double {
        Double(length / (speed * 1.12))
    }

    func progress(at fraction: CGFloat) -> CGFloat {
        let distance = min(max(fraction, 0), 1) * length
        guard let index = samples.firstIndex(where: { $0.distance >= distance }), index > 0 else {
            return distance <= 0 ? 0 : 1
        }
        let before = samples[index - 1], after = samples[index]
        let fraction = (distance - before.distance) / (after.distance - before.distance)
        return before.progress + (after.progress - before.progress) * fraction
    }
}

private struct DuckFlight {
    let start: CGPoint
    let end: CGPoint
    let lift: CGFloat
    let bend: CGFloat
    let destination: DuckAnchor?
    let display: DuckDisplay
    let duration: Double
    let dockCrossing: DockCrossing?
    let animationStart: Double
    var time: Double = 0

    var position: CGPoint { point(at: time) }

    func point(at elapsed: Double) -> CGPoint {
        let timeLeft = duration - elapsed
        let envelope = min(1, elapsed / 0.16, timeLeft / 0.20)
        let beat = DuckWingbeat(time: animationStart + elapsed)
        let time = CGFloat((elapsed + envelope * beat.travelOffset) / duration)
        // Mild easing at takeoff and touchdown keeps long crossings moving.
        let fraction = 0.72 * time + 0.28 * time * time * (3 - 2 * time)
        let t = dockCrossing?.progress(at: fraction) ?? fraction
        let arc = 4 * t * (1 - t)
        let height = dockCrossing?.height(at: t, from: start.y, to: end.y)
            ?? start.y + (end.y - start.y) * t + lift * arc
        return CGPoint(x: start.x + (end.x - start.x) * t + bend * arc, y: height)
    }
}

private struct DuckTerrain {
    var surfaces: [SnowSurface] = []
    var floors: [SnowSurface] = []
    var windows: [SnowSurface] = []
    var docks: [CGRect] = []
    var masks: [String: [CGRect]] = [:]
    private var knownDocks: [CGRect] = []
    private var displays: [DuckDisplay] = []

    mutating func sync(_ incoming: [SnowSurface]) {
        let visible = incoming.filter(\.isVisible)
        guard visible.count != surfaces.count || !zip(visible, surfaces).allSatisfy({ a, b in
            a.id == b.id && a.frame == b.frame && a.topInset == b.topInset && a.kind == b.kind
                && a.occluders == b.occluders && a.bodyOccluders == b.bodyOccluders
                && a.floorOverlayOccluders == b.floorOverlayOccluders
                && a.suppressesSnowfall == b.suppressesSnowfall
        }) else { return }
        surfaces = visible
        floors = surfaces.filter { $0.kind == .floor }
        windows = surfaces.filter { $0.kind == .window }
        // The snow shelf follows the icons. Give the duck clearance for the
        // surrounding Dock glass, while leaving the snow geometry untouched.
        knownDocks = surfaces.filter { $0.kind == .dock }.map { $0.frame.insetBy(dx: -6, dy: -12) }
        refreshMasks()
    }

    mutating func setDisplays(_ displays: [DuckDisplay]) {
        guard displays != self.displays else { return }
        self.displays = displays
        refreshMasks()
    }

    private mutating func refreshMasks() {
        docks = knownDocks + displays.compactMap { display in
            let frame = display.frame
            let height = display.visibleBottom - frame.minY
            guard height > 6, !knownDocks.contains(where: { overlaps($0, frame) }) else { return nil }
            // The work area supplies a height only. Leave ground corridors on
            // both sides of the approximate centered Dock.
            return CGRect(x: frame.minX + frame.width * 0.19, y: frame.minY,
                          width: frame.width * 0.62, height: height)
        }
        masks = Dictionary(uniqueKeysWithValues: floors.map { floor in
            (floor.id, unique((floor.floorOverlayOccluders ?? floor.occluders) + docks))
        } + windows.map { ($0.id, unique($0.occluders + $0.bodyOccluders + docks)) })
    }

    func point(_ anchor: DuckAnchor, snow: SnowWorld, height: (SnowDrift) -> CGFloat) -> CGPoint? {
        guard let drift = snow.drifts[anchor.surfaceID], drift.surface.isVisible,
              drift.surface.kind != .dock else { return nil }
        let surface = drift.surface
        let x = surface.frame.minX + anchor.localX
        guard surface.supports(x: x) else { return nil }
        return CGPoint(x: x, y: surface.top + height(drift))
    }

    func grounded(_ anchor: DuckAnchor, snow: SnowWorld, displays: [DuckDisplay]) -> CGPoint? {
        guard let feet = point(anchor, snow: snow, height: { $0.visibleContour.height(at: anchor.localX) }),
              let surface = snow.drifts[anchor.surfaceID]?.surface,
              supportsFeet(at: feet.x, on: surface) else { return nil }
        let bounds = DuckPose.bounds(at: feet, flying: false)
        let edgeClearance = DuckPose.flightRadius - DuckPose.groundRadius
        let withWingRoom = bounds.insetBy(dx: -edgeClearance, dy: 0)
        guard covered(withWingRoom, by: displays.map(\.navigationFrame)),
              !blocked(bounds, on: anchor.surfaceID, displays: displays),
              !docks.contains(where: { overlaps($0.insetBy(dx: -12, dy: 0), withWingRoom) }) else { return nil }
        return feet
    }

    func supportsFeet(at x: CGFloat, on surface: SnowSurface) -> Bool {
        let radius = DuckPose.footRadius - 1e-6
        return surface.supports(x: x - radius) && surface.supports(x: x + radius)
    }

    func acceptsLanding(on surface: SnowSurface, in display: DuckDisplay) -> Bool {
        surface.isVisible && (surface.kind == .floor || (surface.kind == .window && surface.suppressesSnowfall
            && WideWindowPolicy.mask(forWindow: surface.frame, display: display.frame) == nil))
    }

    func dockAtFloor(on display: DuckDisplay) -> CGRect? {
        docks.first { $0.width > $0.height && $0.intersects(display.frame) && $0.minY <= display.frame.minY }
    }

    func routeCrosses(_ dock: CGRect, from x: CGFloat, to end: CGFloat) -> Bool {
        (x < dock.minX && end > dock.maxX) || (x > dock.maxX && end < dock.minX)
    }

    func candidates(on surface: SnowSurface, in displays: [DuckDisplay], nearest: CGFloat) -> [DuckAnchor] {
        var positions: [CGFloat] = []
        for display in displays {
            let margin = DuckPose.flightRadius + 2
            let minX = max(surface.frame.minX + surface.topInset + DuckPose.footRadius, display.visibleLeft + margin)
            let maxX = min(surface.frame.maxX - surface.topInset - DuckPose.footRadius, display.visibleRight - margin)
            guard minX <= maxX else { continue }
            positions += [min(maxX, max(minX, nearest)), minX, maxX, (minX + maxX) / 2]
            for mask in masks[surface.id] ?? [] where mask.maxY > surface.top && mask.minY < surface.top + 64 {
                let clearance = docks.contains(mask) ? margin + 12 : margin
                positions += [mask.minX - clearance, mask.maxX + clearance].filter { $0 >= minX && $0 <= maxX }
            }
        }
        return Array(Set(positions)).sorted { a, b in
            let da = abs(a - nearest), db = abs(b - nearest)
            return da == db ? a < b : da < db
        }.map { DuckAnchor(surface, x: $0) }
    }

    func blocked(_ bounds: CGRect, on id: String, displays: [DuckDisplay]) -> Bool {
        return displays.contains { display in
            let portion = bounds.intersection(display.navigationFrame)
            guard !portion.isNull else { return false }
            return (masks[id] ?? []).contains { overlaps($0, portion) }
                || sideDockReservations(on: display).contains { overlaps($0, portion) }
        }
    }

    private func sideDockReservations(on display: DuckDisplay) -> [CGRect] {
        guard !knownDocks.contains(where: { overlaps($0, display.frame) }) else { return [] }
        let frame = display.frame
        return [CGRect(x: frame.minX, y: frame.minY, width: display.visibleLeft - frame.minX, height: frame.height),
                CGRect(x: display.visibleRight, y: frame.minY, width: frame.maxX - display.visibleRight, height: frame.height)]
            .filter { !$0.isEmpty }
    }

    func flightBounds(on display: DuckDisplay) -> CGRect {
        // The overlay composes flight above ordinary windows. Dock and menu
        // chrome can still cover it at the system compositor level.
        display.navigationFrame
    }

    private func unique(_ rectangles: [CGRect]) -> [CGRect] {
        var seen: Set<[CGFloat]> = []
        return rectangles.filter { seen.insert([$0.minX, $0.minY, $0.width, $0.height]).inserted }
    }

    func covered(_ bounds: CGRect, by frames: [CGRect]) -> Bool {
        // Displays tile the world in points, but can have gaps or different top edges.
        if frames.contains(where: { $0.contains(bounds) }) { return true }
        let cuts = [bounds.minX, bounds.maxX] + frames.flatMap {
            [$0.minX, $0.maxX].filter { $0 > bounds.minX && $0 < bounds.maxX }
        }
        let sorted = cuts.sorted()
        return zip(sorted, sorted.dropFirst()).allSatisfy { left, right in
            guard right > left else { return true }
            var y = bounds.minY
            for frame in frames.sorted(by: { $0.minY < $1.minY })
                where frame.minX <= left && frame.maxX >= right && frame.minY <= y && frame.maxY > y {
                y = frame.maxY
            }
            return y >= bounds.maxY
        }
    }
}

private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let overlap = a.intersection(b)
    return !overlap.isNull && !overlap.isEmpty
}

/// One character for the shared world. The snow, actors and their random stream are read-only inputs.
final class DuckWorld {
    private var terrain = DuckTerrain()
    private var rng: UInt64
    private var enabled = false
    private var clock: Double = 0
    private var nextSpawn: Double = 1
    private var focusedWindowID: String?
    private var focusedSince: Double = 0
    private var flight: DuckFlight?
    private var roofWalkUntil: Double = 0
    private var roofStayUntil: Double = 0
    private var avoidingPlow: String?
    private var retryAt: Double = 0
    private var activityUntil: Double = 0
    private var footDistance: CGFloat = 0
    private var foot: CGFloat = 1
    private var target: DuckTarget?
    private var interactionCooldowns: [DuckTarget.ID: Double] = [:]
    private var nextDecision: Double = 0
    private var groundedUntil: Double = 0
    private var roamFloorID: String?
    private var roamRight = false
    private var roamTime: Double = 0
    private var roamAfter: Double = 0
    private var approachLocalX: CGFloat?
    private var lastAmbientActivity: DuckActivity?
    private var lastPeck = -1
    private var reducedMotion = false
    private var activeDisplays: [DuckDisplay] = []
    private var landingObjects: [DuckTarget] = []

    private(set) var pose: DuckPose?
    private(set) var prints: [DuckEffect] = []
    private(set) var dust: [DuckEffect] = []

    init(seed: UInt64 = 0xDE17_C98A_3C06_276D) { rng = seed }

    func setEnabled(_ value: Bool, surfaces: [SnowSurface]) {
        guard enabled != value else { return }
        enabled = value
        clear(preserveMemory: true)
        terrain.sync(value ? surfaces : [])
    }

    func sync(_ surfaces: [SnowSurface], fullscreenFrames: [CGRect] = []) {
        guard enabled else { return }
        terrain.sync(surfaces)
        updateFocus()
        let retained = Set(surfaces.map(\.id))
        prints.removeAll { !retained.contains($0.anchor.surfaceID) }
        dust.removeAll { !retained.contains($0.anchor.surfaceID) }
        if let pose, let anchor = pose.anchor, terrain.masks[anchor.surfaceID] == nil,
           !retained.contains(anchor.surfaceID) || !fullscreenFrames.contains(where: { $0.contains(pose.feet) }) {
            leaveSupport(at: pose.feet)
        }
    }

    func clear(preserveMemory: Bool = false) {
        pose = nil; flight = nil; target = nil
        if !preserveMemory { interactionCooldowns.removeAll(); clock = 0 }
        nextDecision = clock; approachLocalX = nil
        roamFloorID = nil; roamTime = 0
        prints.removeAll(); dust.removeAll()
        nextSpawn = clock + 1
        focusedWindowID = nil; focusedSince = clock
        groundedUntil = 0
        avoidingPlow = nil; retryAt = 0; landingObjects.removeAll()
        roofWalkUntil = 0; roofStayUntil = 0; footDistance = 0
        lastAmbientActivity = nil
    }

    func windowShook(_ ids: Set<String>) {
        guard let anchor = pose?.anchor, ids.contains(anchor.surfaceID) else { return }
        target = nil; approachLocalX = nil
        setActivity(.startled, duration: 0.32)
    }

    private func updateFocus() {
        let focused = terrain.windows.first(where: \.suppressesSnowfall)?.id
        guard focused != focusedWindowID else { return }
        focusedWindowID = focused
        focusedSince = clock
    }

    func advance(delta: Double, snow: SnowWorld, trees: FestiveWorld, treesEnabled: Bool,
                 displays: [DuckDisplay], allDisplayFrames: [CGRect], plows: [String: SnowplowPass],
                 sweeps: [SnowplowSweep], reducedMotion reduce: Bool) {
        updateDisplayVisibility(displays)
        guard enabled, delta.isFinite, !displays.isEmpty else { return }
        if isOnPausedDisplay(displays, all: allDisplayFrames) { return }
        if reduce != reducedMotion {
            reducedMotion = reduce
            clear(preserveMemory: true)
        }
        updateFocus()
        let dt = max(0, min(delta, 0.1))
        clock += dt
        ageEffects(dt, snow: snow, sweeps: sweeps)
        landingObjects = targets(snow: snow, trees: trees, treesEnabled: treesEnabled)
        if flight != nil {
            advanceFlight(dt, snow: snow, displays: displays, plows: plows)
            return
        }
        if pose?.activity == .fly {
            pose?.time += dt
            if clock >= retryAt { findLanding(snow: snow, displays: displays, plows: plows) }
            return
        }
        guard let anchor = pose?.anchor else {
            if clock >= nextSpawn { spawn(snow: snow, displays: displays, plows: plows) }
            return
        }
        guard let feet = terrain.grounded(anchor, snow: snow, displays: displays) else {
            if reducedMotion { pose = nil }
            else if let feet = pose?.feet {
                leaveSupport(at: feet)
                findLanding(snow: snow, displays: displays, plows: plows)
            }
            return
        }
        let previousFeet = pose?.feet
        pose?.feet = feet
        if pose?.activity == .peck && snowHeight(at: anchor, snow: snow) <= 0.6 {
            setActivity(.look, duration: 0.75)
        }
        if reducedMotion { return }
        guard let surface = snow.drifts[anchor.surfaceID]?.surface else { return }
        let display = displays.first { $0.frame.contains(feet) }
        if surface.kind == .floor, let display { updateRoam(on: surface, at: feet, in: display, delta: dt) }
        if surface.kind == .window && !displays.contains(where: {
            overlaps($0.frame, DuckPose.bounds(at: feet, flying: false))
                && terrain.acceptsLanding(on: surface, in: $0)
        }) {
            // For a resize that also moves the window, keep the existing
            // presented position as the origin of the descent.
            leaveSupport(at: previousFeet ?? feet)
            findLanding(snow: snow, displays: displays, plows: plows)
            return
        }
        pose?.time += dt
        if let plow = plows[surface.id], feet.x - plow.x >= -48, feet.x - plow.x <= 170 {
            leaveSupport(at: feet)
            avoidingPlow = surface.id
            findLanding(snow: snow, displays: displays, plows: plows)
            return
        }
        if let target {
            let object = landingObjects.first { $0.id == target.id && $0.surfaceID == target.surfaceID }
            if clock >= activityUntil || (object.map { abs($0.localX - target.localX) > 3 } ?? true) {
                self.target = nil
                setActivity(.look, duration: 0.9)
                nextDecision = clock + 0.9
            }
            animateDust(anchor, snow: snow)
            return
        }
        if surface.kind == .window && clock >= activityUntil && (pose?.activity == .startled
            || (pose?.activity != .walk && clock >= roofStayUntil)) {
            leaveSupport(at: feet)
            findLanding(snow: snow, displays: displays, plows: plows)
            return
        }
        if surface.kind == .floor, clock >= activityUntil, clock >= groundedUntil, roamTime >= roamAfter,
           approachLocalX == nil, plows[surface.id] == nil, let display {
            if canVisitFocusedWindow,
               let window = terrain.windows.first(where: { $0.id == focusedWindowID }),
               startTrip(from: feet, to: [window], snow: snow, displays: displays, plows: plows) { return }
            if roamAcross(from: feet, on: surface, in: display, snow: snow) { return }
            roamTime = 0
        }
        if clock >= nextDecision && (pose?.activity == .walk || clock >= activityUntil) && pose?.activity != .startled {
            nextDecision = clock + 0.75
            if !interactionCooldowns.isEmpty {
                let snowmanIDs = Set(snow.snowmen.map { DuckTarget.ID.snowman($0.ballIDs) })
                let treeIDs = Set(trees.placements(in: snow).map { DuckTarget.ID.tree($0.id) })
                interactionCooldowns = interactionCooldowns.filter { id, _ in
                    snowmanIDs.contains(id) || treeIDs.contains(id)
                }
            }
            approachLocalX = nil
            if approachTarget(from: feet, on: surface, snow: snow, displays: displays, plows: plows) { return }
        }
        if pose?.activity == .walk {
            walk(anchor, at: feet, dt: dt, snow: snow, displays: displays, plows: plows)
        } else if clock >= activityUntil {
            setActivity(.walk, duration: random(4...8))
        }
        animateDust(anchor, snow: snow)
    }

    private func updateRoam(on floor: SnowSurface, at feet: CGPoint, in display: DuckDisplay, delta: Double) {
        let center = terrain.dockAtFloor(on: display)?.midX ?? display.frame.midX
        if roamFloorID != floor.id || (abs(feet.x - center) > 24 && roamRight != (feet.x > center)) {
            roamFloorID = floor.id
            roamRight = feet.x > center
            roamTime = 0
            roamAfter = random(120...600)
        }
        roamTime += delta
    }

    private func roamAcross(from feet: CGPoint, on floor: SnowSurface, in display: DuckDisplay, snow: SnowWorld) -> Bool {
        if let dock = terrain.dockAtFloor(on: display) {
            return crossDock(from: feet, on: floor, in: display, dock: dock, toRight: !roamRight, snow: snow)
        }
        let frame = display.frame
        let preferred = frame.minX + frame.width * (roamRight ? 0.25 : 0.75)
        for anchor in terrain.candidates(on: floor, in: [display], nearest: preferred) {
            guard let end = landingPoint(anchor, on: floor, in: display, snow: snow, plow: nil),
                  (end.x > frame.midX) != roamRight, abs(end.x - frame.midX) >= frame.width / 6 else { continue }
            if beginFlight(from: feet, to: end, anchor: anchor, in: display, low: true) { return true }
        }
        return false
    }

    private var canVisitFocusedWindow: Bool {
        clock >= groundedUntil && focusedWindowID != nil && clock - focusedSince >= 8
    }

    private func animateDust(_ anchor: DuckAnchor, snow: SnowWorld) {
        if let current = pose, current.activity == .peck || current.activity == .restByTree {
            let beat = Int(current.time / 0.34)
            if beat != lastPeck && (0...2).contains(beat) {
                lastPeck = beat
                addDust(anchor, facing: current.facing, snow: snow)
            }
        }
    }

    func isVisible(_ bounds: CGRect, on surfaceID: String) -> Bool {
        !terrain.blocked(bounds, on: surfaceID, displays: activeDisplays)
    }

    func updateDisplayVisibility(_ displays: [DuckDisplay]) {
        guard enabled else { return }
        activeDisplays = displays
        terrain.setDisplays(displays)
    }

    func isGroundPoseVisible(at point: CGPoint, on anchor: DuckAnchor, snow: SnowWorld) -> Bool {
        guard let surface = snow.drifts[anchor.surfaceID]?.surface,
              terrain.supportsFeet(at: point.x, on: surface) else { return false }
        let bounds = DuckPose.bounds(at: point, flying: false)
        return terrain.covered(bounds, by: activeDisplays.map(\.navigationFrame)) && isVisible(bounds, on: anchor.surfaceID)
    }

    func groundPoint(_ anchor: DuckAnchor, snow: SnowWorld, visibleHeight: () -> CGFloat) -> CGPoint? {
        terrain.point(anchor, snow: snow, height: { _ in visibleHeight() })
    }

    private func snowHeight(at anchor: DuckAnchor, snow: SnowWorld) -> CGFloat {
        guard let drift = snow.drifts[anchor.surfaceID] else { return 0 }
        return drift.visibleContour.height(at: anchor.localX)
    }

    func isFlightVisible(at point: CGPoint) -> Bool {
        activeDisplays.contains { terrain.flightBounds(on: $0).contains(point) }
    }

    private func isOnPausedDisplay(_ displays: [DuckDisplay], all: [CGRect]) -> Bool {
        guard let pose else { return false }
        let active = displays.map(\.frame)
        if let flight { return !active.contains(flight.display.frame) && all.contains(flight.display.frame) }
        // A moved window can carry its passenger to another active display.
        let x = pose.anchor.flatMap { anchor in
            terrain.surfaces.first { $0.id == anchor.surfaceID }.map {
                CGPoint(x: $0.frame.minX + anchor.localX, y: $0.top)
            }
        } ?? pose.feet
        return all.contains { $0.contains(x) && !active.contains($0) } && !active.contains { $0.contains(x) }
    }

    private func ageEffects(_ dt: Double, snow: SnowWorld, sweeps: [SnowplowSweep]) {
        for i in prints.indices { prints[i].age += dt }
        for i in dust.indices { dust[i].age += dt }
        prints.removeAll { mark in
            guard mark.age < mark.lifetime, let drift = snow.drifts[mark.anchor.surfaceID],
                  drift.visibleContour.height(at: mark.anchor.localX) > 0.6 else { return true }
            let x = drift.surface.frame.minX + mark.anchor.localX
            return sweeps.contains { $0.surfaceID == mark.anchor.surfaceID && x >= $0.fromX && x <= $0.toX }
        }
        dust.removeAll { $0.age >= $0.lifetime }
    }

    private func spawn(snow: SnowWorld, displays: [DuckDisplay], plows: [String: SnowplowPass]) {
        for floor in terrain.floors {
            let near = floor.frame.minX + floor.frame.width * 0.15
            for anchor in terrain.candidates(on: floor, in: displays, nearest: near) {
                if let feet = terrain.grounded(anchor, snow: snow, displays: displays),
                   plows[floor.id].map({ abs($0.x - feet.x) > 100 }) ?? true {
                    land(anchor, at: feet)
                    if reducedMotion { setActivity(.rest, duration: .infinity) }
                    return
                }
            }
        }
        nextSpawn = clock + 1
    }

    private func walk(_ anchor: DuckAnchor, at feet: CGPoint, dt: Double, snow: SnowWorld,
                      displays: [DuckDisplay], plows: [String: SnowplowPass]) {
        guard let current = pose else { return }
        let support = snow.drifts[anchor.surfaceID]?.surface
        var next = anchor
        let stride = 34 * CGFloat(dt)
        let travel = approachLocalX.map { min(stride, max(-stride, $0 - anchor.localX)) } ?? stride * current.facing
        next.localX += travel
        var nextFeet = terrain.grounded(next, snow: snow, displays: displays)
        if let support, support.kind == .floor,
           let display = displays.first(where: { $0.frame.contains(feet) }), terrain.dockAtFloor(on: display) == nil {
            let center = display.frame.midX
            let nextX = support.frame.minX + next.localX
            if (nextX > center) != roamRight { nextFeet = nil }
        }
        if (clock >= activityUntil && approachLocalX == nil) || nextFeet == nil {
            approachLocalX = nil
            if nextFeet == nil || clock < activityUntil { pose?.facing *= -1 }
            if clock < roofWalkUntil || (support?.kind == .floor && clock < groundedUntil) { return }
            let snowy = snowHeight(at: anchor, snow: snow)
            let activities: [DuckActivity] = [.look, .preen, .rest, .stretch, .shake, .listen]
                + (snowy > 0.6 ? [.peck] : [])
                + (snow.drifts[anchor.surfaceID]?.surface.kind == .window ? [.watch] : [])
            let choices = activities.filter { $0 != lastAmbientActivity }
            let activity = choices[min(choices.count - 1, Int(random(0...Double(choices.count))))]
            lastAmbientActivity = activity
            setActivity(activity, duration: activity == .rest ? random(3...6) : random(1.8...3.4))
            return
        }
        pose?.anchor = next
        pose?.feet = nextFeet ?? feet
        footDistance += abs(next.localX - anchor.localX)
        if footDistance >= 7 {
            footDistance -= 7
            foot *= -1
            if snowHeight(at: next, snow: snow) > 0.6 {
                prints.append(DuckEffect(anchor: next, facing: current.facing, foot: foot, lifetime: 12))
                if prints.count > 48 { prints.removeFirst() }
            }
        }
    }

    private func approachTarget(from feet: CGPoint, on current: SnowSurface, snow: SnowWorld,
                                displays: [DuckDisplay], plows: [String: SnowplowPass]) -> Bool {
        guard let display = displays.first(where: { $0.frame.contains(feet) }) else { return false }
        let objects = landingObjects
        let floorDock = current.kind == .floor ? terrain.dockAtFloor(on: display) : nil
        let ready = objects.filter { object in
            guard let until = interactionCooldowns[object.id] else { return true }
            guard clock >= until else { return false }
            if case .snowman = object.id {
                return object.surfaceID == current.id && abs(object.bounds.midX - feet.x) <= object.bounds.width / 2 + 40
            }
            return true
        }
            .sorted {
                cost(to: $0, from: feet) < cost(to: $1, from: feet)
            }
        for object in ready {
            guard let surface = snow.drifts[object.surfaceID]?.surface,
                  terrain.acceptsLanding(on: surface, in: display) else { continue }
            if current.kind == .floor && surface.kind == .floor && roamTime < roamAfter {
                let center = floorDock?.midX ?? display.frame.midX
                if (feet.x < center) != (object.bounds.midX < center) { continue }
            }
            if surface.kind == .window && current.kind == .floor { continue }
            if current.kind == .window && surface.id != current.id { continue }
            let gap = DuckPose.flightRadius + 5
            let sides = [object.bounds.minX - gap, object.bounds.maxX + gap]
                .sorted { abs($0 - feet.x) < abs($1 - feet.x) }
            for x in sides {
                let anchor = DuckAnchor(surface, x: x)
                guard let end = terrain.grounded(anchor, snow: snow, displays: [display]),
                      !objectBlocksLanding(at: end, objects: objects, surfaceID: surface.id) else { continue }
                if surface.id == current.id {
                    let distance = abs(feet.x - x)
                    if distance <= 4 {
                        if clock < roofWalkUntil { continue }
                        interact(object, at: feet)
                        return true
                    }
                    let bounds = DuckPose.bounds(at: feet, flying: false)
                        .union(DuckPose.bounds(at: end, flying: false))
                    if !terrain.blocked(bounds, on: current.id, displays: [display]) {
                        approachLocalX = anchor.localX
                        pose?.facing = x > feet.x ? 1 : -1
                        if pose?.activity != .walk { setActivity(.walk, duration: 7) }
                        return false
                    }
                    if clock < roofWalkUntil || (current.kind == .floor && clock < groundedUntil) { continue }
                }
                if current.kind == .floor && clock < groundedUntil { continue }
                var dockToCross: CGRect?
                if current.kind == .floor && surface.kind == .floor {
                    if let floorDock {
                        guard terrain.routeCrosses(floorDock, from: feet.x, to: end.x) else { continue }
                        dockToCross = floorDock
                    } else if (feet.x < display.frame.midX) == (end.x < display.frame.midX) {
                        continue
                    }
                }
                if beginFlight(from: feet, to: end, anchor: anchor, in: display, plow: plows[surface.id], over: dockToCross) {
                    return true
                }
            }
        }
        return false
    }

    private func cost(to object: DuckTarget, from point: CGPoint) -> CGFloat {
        abs(object.bounds.midX - point.x) + abs(object.bounds.minY - point.y) * 1.4
    }

    private func objectBlocksLanding(at point: CGPoint, objects: [DuckTarget], surfaceID: String) -> Bool {
        let bounds = DuckPose.bounds(at: point, flying: true)
        return objects.contains { $0.surfaceID == surfaceID && overlaps($0.bounds, bounds) }
    }

    private func crossDock(from feet: CGPoint, on floor: SnowSurface, in display: DuckDisplay,
                           dock: CGRect, toRight: Bool, snow: SnowWorld) -> Bool {
        let gap = DuckPose.flightRadius + 52
        let preferred = toRight ? dock.maxX + gap : dock.minX - gap
        for anchor in terrain.candidates(on: floor, in: [display], nearest: preferred) {
            guard let end = landingPoint(anchor, on: floor, in: display, snow: snow, plow: nil),
                  toRight ? end.x > dock.maxX : end.x < dock.minX else { continue }
            if beginFlight(from: feet, to: end, anchor: anchor, in: display, over: dock) { return true }
        }
        return false
    }

    private func targets(snow: SnowWorld, trees: FestiveWorld, treesEnabled: Bool) -> [DuckTarget] {
        let snowmen = snow.snowmen.compactMap { man -> DuckTarget? in
            let balls = man.ballIDs.compactMap { id in snow.balls.first { $0.id == id } }
            guard balls.count == man.ballIDs.count, let support = balls.first?.surfaceID,
                  snow.drifts[support]?.surface.isVisible == true else { return nil }
            let bounds = balls.reduce(CGRect.null) { rect, ball in
                rect.union(CGRect(x: ball.position.x - ball.radius, y: ball.position.y - ball.radius,
                                  width: ball.radius * 2, height: ball.radius * 2))
            }
            guard !terrain.blocked(bounds, on: support, displays: activeDisplays) else { return nil }
            let localX = bounds.midX - (snow.drifts[support]?.surface.frame.minX ?? 0)
            return DuckTarget(id: .snowman(man.ballIDs), surfaceID: support, bounds: bounds, localX: localX)
        }
        guard treesEnabled else { return snowmen }
        return snowmen + trees.placements(in: snow).compactMap {
            guard $0.surface.isVisible, !terrain.blocked($0.bounds, on: $0.surface.id, displays: activeDisplays) else { return nil }
            return DuckTarget(id: .tree($0.id), surfaceID: $0.surface.id, bounds: $0.bounds,
                              localX: $0.bounds.midX - $0.surface.frame.minX)
        }
    }

    private func interact(_ object: DuckTarget, at feet: CGPoint) {
        target = object
        approachLocalX = nil
        pose?.facing = object.bounds.midX >= feet.x ? 1 : -1
        interactionCooldowns[object.id] = clock + random(300...600)
        switch object.id {
        case .snowman:
            let choices: [DuckActivity] = [.greet, .guardSnowman, .bowSnowman]
            setActivity(choices[min(choices.count - 1, Int(random(0...Double(choices.count))))], duration: random(3.6...5.2))
        case .tree:
            let choices: [DuckActivity] = [.inspectTree, .restByTree, .inspectLights]
            setActivity(choices[min(choices.count - 1, Int(random(0...Double(choices.count))))], duration: random(3.6...5.5))
        }
    }

    private func addDust(_ anchor: DuckAnchor, facing: CGFloat, snow: SnowWorld) {
        var source = anchor
        source.localX += 11 * facing
        guard snowHeight(at: source, snow: snow) > 0.6 else { return }
        for offset in [-1.0, 0, 1] {
            dust.append(DuckEffect(anchor: source, facing: facing, foot: offset, lifetime: 0.72))
        }
        if dust.count > 12 { dust.removeFirst(dust.count - 12) }
    }

    private func setActivity(_ activity: DuckActivity, duration: Double) {
        pose?.activity = activity
        pose?.time = 0
        activityUntil = clock + duration
        lastPeck = -1
    }

    private func leaveSupport(at feet: CGPoint) {
        pose = DuckPose(anchor: nil, feet: feet, facing: pose?.facing ?? 1, activity: .fly, time: 0)
        flight = nil; target = nil; approachLocalX = nil
        roofWalkUntil = 0; roofStayUntil = 0; retryAt = clock
    }

    private func findLanding(snow: SnowWorld, displays: [DuckDisplay], plows: [String: SnowplowPass]) {
        guard let start = pose?.feet else { return }
        retryAt = clock + 0.3
        if let id = avoidingPlow, let plow = plows[id],
           let display = displays.first(where: { $0.frame.contains(start) }) {
            let safeX = plow.x - 48 - DuckPose.flightRadius - 8
            let nearest = min(start.x, safeX)
            for anchor in terrain.candidates(on: plow.surface, in: [display], nearest: nearest) {
                guard let end = landingPoint(anchor, on: plow.surface, in: display, snow: snow, plow: plow) else { continue }
                if beginFlight(from: start, to: end, anchor: anchor, in: display, plow: plow) { return }
            }
            // When there is no floor behind the tractor yet, take off in
            // place. Land once it has driven far enough to open a gap.
            let high = plow.surface.top + 82
            let hover = CGPoint(x: start.x, y: high)
            if start.y < high {
                _ = beginFlight(from: start, to: hover, anchor: nil, in: display)
            }
            return
        }
        avoidingPlow = nil
        _ = startTrip(from: start, to: terrain.floors, snow: snow, displays: displays, plows: plows)
    }

    private func land(_ anchor: DuckAnchor, at feet: CGPoint) {
        target = nil; approachLocalX = nil; nextDecision = clock
        avoidingPlow = nil
        pose = DuckPose(anchor: anchor, feet: feet, facing: pose?.facing ?? 1, activity: .walk, time: 0)
        if terrain.windows.contains(where: { $0.id == anchor.surfaceID }) {
            roofWalkUntil = clock + 4
            roofStayUntil = clock + random(120...600)
            roamFloorID = nil
            setActivity(.walk, duration: random(5...9))
        } else {
            roofWalkUntil = 0
            groundedUntil = clock + 3
            setActivity(.walk, duration: random(4...8))
        }
    }

    private func startTrip(from start: CGPoint, to surfaces: [SnowSurface],
                           snow: SnowWorld, displays: [DuckDisplay], plows: [String: SnowplowPass]) -> Bool {
        guard let display = displays.first(where: { $0.frame.contains(start) }) else { return false }
        let nearby = surfaces.filter { $0.frame.maxX > display.frame.minX && $0.frame.minX < display.frame.maxX }
            .sorted { abs($0.top - start.y) < abs($1.top - start.y) }
        for surface in nearby where terrain.acceptsLanding(on: surface, in: display) {
            let candidates = terrain.candidates(on: surface, in: [display], nearest: start.x)
            for anchor in candidates {
                guard let end = landingPoint(anchor, on: surface, in: display, snow: snow, plow: plows[surface.id]) else { continue }
                if beginFlight(from: start, to: end, anchor: anchor, in: display, plow: plows[surface.id]) {
                    return true
                }
            }
        }
        return false
    }

    private func beginFlight(from start: CGPoint, to end: CGPoint, anchor: DuckAnchor?, in display: DuckDisplay,
                             plow: SnowplowPass? = nil, over dock: CGRect? = nil, low: Bool = false) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        let region = terrain.flightBounds(on: display)
        guard distance > 0.01, region.contains(start), region.contains(end),
              anchor == nil || landingClear(of: plow, at: end) else { return false }

        let ceiling = region.maxY - DuckPose.flightHeight
        let crossing = dock.flatMap { DockCrossing(dock: $0, from: start, to: end, ceiling: ceiling) }
        if dock != nil && crossing == nil { return false }
        var lift = min(low ? 32 : 82, 16 + distance * 0.17)
        if dy < -80 { lift = min(lift, -dy / 5) }
        if crossing == nil && abs(dx) > 1 {
            for dock in terrain.docks where dock.intersects(display.frame) && dock.width > dock.height {
                let near = (dock.minX - DuckPose.flightRadius - start.x) / dx
                let far = (dock.maxX + DuckPose.flightRadius - start.x) / dx
                for t in [near, far] where t > 0 && t < 1 {
                    lift = max(lift, (dock.maxY + 5 - start.y - dy * t) / (4 * t * (1 - t)))
                }
            }
        }
        if let plow, avoidingPlow != nil {
            lift = max(lift, plow.surface.top + 92 - (start.y + end.y) / 2)
        }
        lift = max(0, min(lift, region.maxY - DuckPose.flightHeight - max(start.y, end.y)))
        let roomLeft = max(0, min(start.x, end.x) - region.minX - DuckPose.flightRadius)
        let roomRight = max(0, region.maxX - max(start.x, end.x) - DuckPose.flightRadius)
        let side = pose?.facing ?? 1
        let clearOfDock = !terrain.docks.contains {
            $0.insetBy(dx: -DuckPose.flightRadius - 28, dy: 0).contains(start)
                || $0.insetBy(dx: -DuckPose.flightRadius - 28, dy: 0).contains(end)
        }
        let bend = crossing == nil && abs(dx) < 40 && clearOfDock ? side * min(28, side > 0 ? roomRight : roomLeft) : 0
        // Lift off promptly when the tractor is approaching. Ordinary flights
        // are noticeably slower, including the long trip across the display.
        let speed: CGFloat = avoidingPlow == nil ? 240 : 310
        let duration = max(0.75, crossing?.duration(speed: speed)
                           ?? Double(hypot(distance, 2 * lift) / speed))
        let animationStart = pose?.activity == .fly ? (pose?.time ?? 0) : 0
        let tilt = pose?.flightTilt ?? 0
        flight = DuckFlight(start: start, end: end, lift: lift, bend: bend, destination: anchor,
                            display: display, duration: duration, dockCrossing: crossing, animationStart: animationStart)
        target = nil; approachLocalX = nil
        let facing: CGFloat = dx == 0 ? side : dx > 0 ? 1 : -1
        let feetExtended = pose?.activity == .fly ? (pose?.feetExtended ?? 0) : 1
        pose = DuckPose(anchor: nil, feet: start, facing: facing, activity: .fly, time: animationStart,
                        flightTilt: tilt, feetExtended: feetExtended)
        return true
    }

    private func landingClear(of plow: SnowplowPass?, at point: CGPoint) -> Bool {
        guard let plow else { return true }
        return point.x <= plow.x - 48 - DuckPose.flightRadius - 8
    }

    private func landingPoint(_ anchor: DuckAnchor, on surface: SnowSurface, in display: DuckDisplay,
                              snow: SnowWorld, plow: SnowplowPass?) -> CGPoint? {
        guard terrain.acceptsLanding(on: surface, in: display),
              let end = terrain.grounded(anchor, snow: snow, displays: [display]),
              landingClear(of: plow, at: end),
              !objectBlocksLanding(at: end, objects: landingObjects, surfaceID: surface.id) else { return nil }
        return end
    }

    private func advanceFlight(_ dt: Double, snow: SnowWorld, displays: [DuckDisplay], plows: [String: SnowplowPass]) {
        guard let trip = flight,
              let display = displays.first(where: { $0.frame == trip.display.frame }) else { return }
        var landing: CGPoint?
        if let anchor = trip.destination {
            let surface = snow.drifts[anchor.surfaceID]?.surface
            let plow = plows[anchor.surfaceID]
            landing = surface.flatMap { landingPoint(anchor, on: $0, in: display, snow: snow, plow: plow) }
            if landing.map({ hypot($0.x - trip.end.x, $0.y - trip.end.y) > 3 }) ?? true {
                flight = nil
                if let surface, terrain.acceptsLanding(on: surface, in: display) {
                    if trip.dockCrossing == nil, startTrip(from: trip.position, to: [surface], snow: snow, displays: displays,
                                                          plows: plows) { return }
                }
                if plow != nil { avoidingPlow = anchor.surfaceID }
                findLanding(snow: snow, displays: displays, plows: plows)
                return
            }
        }
        let old = trip.position
        flight?.time = min(trip.duration, trip.time + dt)
        guard let updated = flight else { return }
        pose?.feet = updated.position
        pose?.time = updated.animationStart + updated.time
        let preparingToLand = updated.destination != nil && updated.duration - updated.time <= 0.22
        let legs = pose?.feetExtended ?? 0
        let legStep = CGFloat(dt / 0.18)
        pose?.feetExtended = preparingToLand ? min(1, legs + legStep) : max(0, legs - legStep)
        let deltaY = updated.position.y - old.y
        let deltaX = abs(updated.position.x - old.x)
        if deltaX + abs(deltaY) > 0.01 {
            let pitch = atan2(deltaY, deltaX) * 0.12
            let previous = pose?.flightTilt ?? 0
            pose?.flightTilt = previous + (pitch - previous) * CGFloat(min(1, dt * 10))
        }
        if updated.time >= trip.duration {
            flight = nil
            if let destination = trip.destination, let landing {
                land(destination, at: landing)
            }
        }
    }

    private func random(_ range: ClosedRange<Double>) -> Double {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(rng >> 11) / 9_007_199_254_740_992
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
