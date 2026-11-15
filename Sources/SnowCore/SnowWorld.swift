import Foundation
import CoreGraphics

/// Deterministic, main-thread-owned simulation. Heights are in points; mass is area.
final class SnowWorld {
    private struct BallPair: Hashable {
        let first: UUID
        let second: UUID

        init(_ a: UUID, _ b: UUID) {
            if a.uuidString < b.uuidString { first = a; second = b }
            else { first = b; second = a }
        }
    }

    private(set) var surfaces: [SnowSurface] = []
    private(set) var drifts: [String: SnowDrift] = [:]
    private(set) var balls: [Snowball] = []
    private(set) var snowmen: [Snowman] = []
    private(set) var debris: [SnowDebris] = []

    private var randomState: UInt64
    private var accumulator: Double = 0
    private var profileTicks = 0
    private var profileDose: CGFloat = 0
    private var profileRegions: [RectBounds] = []
    private var lastActiveRegions: [CGRect] = []
    private var dragID: UUID?
    private var dragOffset = CGVector.zero
    private var supportedBy: [UUID: UUID] = [:]
    private var objectsFrozen = false
    private var overlappingAfterDrag: Set<BallPair> = []
    private var smoothedWind = CGVector.zero
    private var connectedRegions: [CGRect] = []
    private let tick = 1.0 / 120.0
    private let maximumBalls = 30
    private let minimumRadius: CGFloat = 8
    private let maximumRadius: CGFloat = 36
    private let gravity: CGFloat = 480
    private let maximumSpeed: CGFloat = 720
    private let debrisLimit = 384

    init(seed: UInt64 = 42) { randomState = seed }

    func setObjectsFrozen(_ frozen: Bool) {
        guard objectsFrozen != frozen else { return }
        objectsFrozen = frozen
        guard !frozen else { return }
        for (index, ball) in balls.enumerated() {
            for other in balls.dropFirst(index + 1) where ball.surfaceID != other.surfaceID {
                if hypot(ball.position.x - other.position.x, ball.position.y - other.position.y) < ball.radius + other.radius {
                    overlappingAfterDrag.insert(BallPair(ball.id, other.id))
                }
            }
        }
    }

    func syncSurfaces(_ incoming: [SnowSurface]) {
        // Commit time accrued on the old geometry before moving or changing masks.
        flushProfile()
        var seen = Set<String>()
        let valid = incoming.filter {
            seen.insert($0.id).inserted && finite($0.frame) && $0.frame.width > 0 && $0.frame.width <= 65_536
        }
        let old = drifts
        let retained = Set(valid.map(\.id))
        let removedBalls = Set(balls.filter { $0.surfaceID.map { !retained.contains($0) } ?? false }.map(\.id))
        removeBalls(removedBalls)
        var next: [String: SnowDrift] = [:]
        for surface in valid {
            let count = sampleCount(surface.frame.width)
            guard let previous = old[surface.id] else {
                next[surface.id] = SnowDrift(surface: surface, heights: Array(repeating: 0, count: count))
                continue
            }
            var heights = previous.heights
            var limits = previous.heightLimits
            let resized = count != previous.heights.count || abs(surface.frame.width - previous.surface.frame.width) > 0.001
            let envelopeChanged = resized || surface.kind != previous.surface.kind
                || (surface.kind == .floor && surface.frame.minX != previous.surface.frame.minX)
            if envelopeChanged { limits = SnowHeightEnvelope.samples(for: surface, count: count) }
            if resized {
                heights = (0..<count).map { index in
                    let x = min(CGFloat(index) * SnowDrift.spacing, surface.frame.width)
                    return x <= previous.surface.frame.width ? min(limits[index], storedHeight(previous, localX: x)) : 0
                }
                // A partial final cell changes width on resize. Conserve its area;
                // all fully retained cells keep their local position and height.
                if surface.frame.width > previous.surface.frame.width {
                    preserveAreaOnExpansion(old: previous, surface: surface, limits: limits, heights: &heights)
                } else {
                    let removedArea = max(0, area(previous) - profileArea(heights, width: surface.frame.width))
                    if removedArea > 1 {
                        burst(at: CGPoint(x: surface.frame.maxX, y: surface.top), amount: min(12, Int(removedArea / 16) + 1))
                    }
                }
            } else if envelopeChanged {
                for index in heights.indices { heights[index] = min(heights[index], limits[index]) }
            }
            // Retain the full frame/grid, but discard snow whose linear basis
            // would extend over a newly rounded part of the upper edge.
            let inset = min(max(0, surface.topInset), surface.frame.width / 2)
            if inset > 0 {
                for index in heights.indices where !supportedProfileNode(index, count: heights.count,
                                                                           width: surface.frame.width, inset: inset) {
                    heights[index] = 0
                }
            }
            next[surface.id] = SnowDrift(surface: surface, heights: heights, heightLimits: limits)
            let dx = surface.frame.minX - previous.surface.frame.minX
            let dy = surface.top - previous.surface.top
            for index in balls.indices where balls[index].surfaceID == surface.id {
                balls[index].position.x += dx
                balls[index].position.y += dy
                if !surface.supports(x: balls[index].position.x) {
                    balls[index].surfaceID = nil
                    supportedBy.removeValue(forKey: balls[index].id)
                    balls[index].restingTime = 0
                }
            }
        }
        surfaces = valid
        drifts = next
        repairSupports()
        updateSnowmen()
    }

    /// Fullscreen regions are paused, not pruned. Only call on physical display changes.
    func prune(to regions: [CGRect]) {
        let regions = regions.filter { finite($0) && $0.width > 0 && $0.height > 0 }
        connectedRegions = regions
        removeBalls(Set(balls.filter { ball in
            !regions.contains { $0.intersects(ballBounds(ball)) }
        }.map(\.id)))
        debris.removeAll { part in !regions.contains { $0.insetBy(dx: -8, dy: -8).contains(part.position) } }
        let retainedSurfaces = surfaces.filter { surface in
            regions.contains { region in
                surface.frame.maxX > region.minX && surface.frame.minX < region.maxX &&
                    surface.top >= region.minY - 1 && surface.top <= region.maxY + SnowDrift.maximumHeight
            }
        }
        syncSurfaces(retainedSurfaces)
    }

    func step(delta: Double, weather: SnowWeather, activeRegions: [CGRect]) {
        guard delta.isFinite, delta > 0 else { return }
        let regions = activeRegions.filter { finite($0) && $0.width > 0 && $0.height > 0 }
        guard !regions.isEmpty else {
            accumulator = 0
            profileTicks = 0; profileDose = 0
            lastActiveRegions = []; profileRegions = []
            return
        }
        if regions != lastActiveRegions {
            flushProfile()
            lastActiveRegions = regions
            profileRegions = regions.map(RectBounds.init)
        }
        // Drop excess elapsed time after sleep/stalls. Never build a catch-up queue.
        accumulator += min(delta, 0.1)
        var steps = 0
        while accumulator + 1e-10 >= tick && steps < 12 {
            simulate(CGFloat(tick), weather: weather, regions: regions)
            accumulator -= tick
            steps += 1
        }
        if accumulator < 0 { accumulator = 0 }
        if accumulator >= tick { accumulator = accumulator.truncatingRemainder(dividingBy: tick) }
    }

    func surface(at point: CGPoint) -> SnowSurface? {
        guard finite(point) else { return nil }
        for surface in surfaces where surface.isVisible && surface.isExposed(point) {
            guard surface.supports(x: point.x),
                  let drift = drifts[surface.id] else { continue }
            let h = height(drift, localX: point.x - surface.frame.minX)
            if point.y >= surface.top - 5 && point.y <= surface.top + h + 8 { return surface }
        }
        return nil
    }

    func brush(at point: CGPoint, radius: CGFloat = 24) {
        guard radius.isFinite, radius > 0, let target = surface(at: point), var drift = drifts[target.id] else { return }
        var removed: CGFloat = 0
        for index in drift.heights.indices {
            let x = sampleX(index, width: target.frame.width) + target.frame.minX
            let distance = abs(x - point.x)
            guard distance < radius else { continue }
            let exposed = visibleHeight(drift, index: index)
            guard exposed > 0 else { continue }
            let amount = min(exposed, max(0.5, (1 - distance / radius) * 9))
            drift.heights[index] -= amount
            removed += amount * nodeWeight(index, width: target.frame.width)
        }
        drifts[target.id] = drift
        if removed > 0 { burst(at: point, amount: min(16, max(2, Int(removed / 12)))) }
    }

    func clear(surfaceID: String) {
        if var drift = drifts[surfaceID] {
            drift.heights = Array(repeating: 0, count: drift.heights.count)
            drifts[surfaceID] = drift
        }
        removeBalls(Set(balls.filter { $0.surfaceID == surfaceID }.map(\.id)))
    }

    /// A moving cleaner removes only the exposed floor columns it has reached.
    /// Existing balls and their support links belong to the player, not the cleaner.
    func sweepFloor(surfaceID: String, fromX: CGFloat, toX: CGFloat) {
        flushProfile()
        guard fromX.isFinite, toX.isFinite, var drift = drifts[surfaceID],
              drift.surface.kind == .floor, drift.surface.isVisible else { return }
        let lower = max(drift.surface.frame.minX, min(fromX, toX))
        let upper = min(drift.surface.frame.maxX, max(fromX, toX))
        guard lower <= upper else { return }
        for index in drift.heights.indices {
            let x = drift.surface.frame.minX + sampleX(index, width: drift.surface.frame.width)
            guard x >= lower, x <= upper else { continue }
            drift.heights[index] -= visibleHeight(drift, index: index)
        }
        drifts[surfaceID] = drift
    }

    /// A sudden window movement sheds its drift, with debris originating only from
    /// visible snow. The bounded burst never deletes player-made balls or snowmen.
    func shedSnow(surfaceID: String, velocity: CGVector) {
        flushProfile()
        guard var drift = drifts[surfaceID], drift.surface.kind == .window else { return }
        let contour = drift.visibleContour
        var sources: [CGPoint] = []
        var visibleArea: CGFloat = 0
        if drift.surface.isVisible {
            for index in drift.heights.indices {
                let localX = sampleX(index, width: drift.surface.frame.width)
                let height = contour.height(at: localX)
                guard height > 0.05 else { continue }
                let point = CGPoint(x: drift.surface.frame.minX + localX, y: drift.surface.top + height)
                guard drift.surface.isExposed(point) else { continue }
                sources.append(point)
                visibleArea += height * nodeWeight(index, width: drift.surface.frame.width)
            }
        }
        drift.heights = Array(repeating: 0, count: drift.heights.count)
        drifts[surfaceID] = drift
        guard !sources.isEmpty else { return }
        let count = min(96, max(0, debrisLimit - debris.count), max(1, Int(ceil(visibleArea / 24))))
        let inherited = limited(finite(velocity) ? velocity : .zero, to: 640)
        for index in 0..<count {
            let sourceIndex = count > 1 ? index * (sources.count - 1) / (count - 1) : sources.count / 2
            let source = sources[sourceIndex]
            // Snow lags behind the moving window; varied upward lift keeps the
            // released edge visible before gravity spreads the short trail.
            let impulse = CGVector(dx: -inherited.dx * 0.45 + (nextRandom() - 0.5) * 140,
                                   dy: -inherited.dy * 0.45 + 45 + nextRandom() * 95)
            debris.append(SnowDebris(position: source, velocity: limited(impulse, to: 360),
                                    lifetime: 1.1 + nextRandom() * 0.4, radius: 2.2 + nextRandom() * 2.3))
        }
    }

    func clearAll() {
        for key in Array(drifts.keys) {
            guard var drift = drifts[key] else { continue }
            drift.heights = Array(repeating: 0, count: drift.heights.count)
            drifts[key] = drift
        }
        balls.removeAll(keepingCapacity: true)
        snowmen.removeAll(keepingCapacity: true)
        debris.removeAll(keepingCapacity: true)
        supportedBy.removeAll(keepingCapacity: true)
        overlappingAfterDrag.removeAll(keepingCapacity: true)
        dragID = nil
        accumulator = 0
        profileTicks = 0; profileDose = 0
    }

    func reset() {
        clearAll()
        surfaces.removeAll(keepingCapacity: true)
        drifts.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func placeSnowman(on surface: SnowSurface, x: CGFloat) -> Bool {
        guard balls.count <= maximumBalls - 3, let drift = drifts[surface.id], drift.surface.isVisible,
              surface.supports(x: x - 20), surface.supports(x: x + 20) else { return false }
        let base = surface.top + height(drift, localX: x - surface.frame.minX)
        let bottom = Snowball(id: nextID(), position: CGPoint(x: x, y: base + 20), radius: 20,
                              surfaceID: surface.id, restingTime: 0.5)
        let middle = Snowball(id: nextID(), position: CGPoint(x: x, y: bottom.position.y +
            SnowballContact.stackedCenterDistance(radius: 15, otherRadius: 20)), radius: 15,
                              surfaceID: surface.id, restingTime: 0.5)
        let head = Snowball(id: nextID(), position: CGPoint(x: x, y: middle.position.y +
            SnowballContact.stackedCenterDistance(radius: 10, otherRadius: 15)), radius: 10,
                            surfaceID: surface.id, restingTime: 0.5)
        balls.append(contentsOf: [bottom, middle, head])
        supportedBy[middle.id] = bottom.id
        supportedBy[head.id] = middle.id
        updateSnowmen()
        return true
    }

    @discardableResult
    func beginSnowball(at point: CGPoint) -> UUID? {
        guard balls.count < maximumBalls, let target = surface(at: point), let drift = drifts[target.id] else { return nil }
        let mass = CGFloat.pi * minimumRadius * minimumRadius
        let reach: CGFloat = 40
        guard availableMass(in: drift, around: point.x, radius: reach) + 1e-7 >= mass else { return nil }
        let collected = takeSnow(from: target.id, around: point.x, radius: reach, maximum: mass)
        guard collected > 0 else { return nil }
        let radius = sqrt(collected / .pi)
        let current = drifts[target.id]!
        let position = CGPoint(x: point.x, y: target.top + height(current, localX: point.x - target.frame.minX) + radius)
        let ball = Snowball(id: nextID(), position: position, radius: radius, surfaceID: target.id)
        balls.append(ball)
        dragID = ball.id
        dragOffset = CGVector(dx: position.x - point.x, dy: position.y - point.y)
        return ball.id
    }

    @discardableResult
    func beginDrag(at point: CGPoint) -> UUID? {
        guard finite(point) else { return nil }
        for ball in balls.reversed() where length(vector(point, ball.position)) <= ball.radius + 3 {
            if let id = ball.surfaceID, let surface = drifts[id]?.surface, !surface.isExposed(point) { continue }
            detach(ball.id)
            dragID = ball.id
            dragOffset = CGVector(dx: ball.position.x - point.x, dy: ball.position.y - point.y)
            if let index = balls.firstIndex(where: { $0.id == ball.id }) {
                balls[index].velocity = .zero
                balls[index].restingTime = 0
            }
            return ball.id
        }
        return nil
    }

    func drag(to point: CGPoint) {
        guard finite(point), let id = dragID, let index = balls.firstIndex(where: { $0.id == id }) else { return }
        var ball = balls[index]
        let previous = ball.position
        ball.position = CGPoint(x: point.x + dragOffset.dx, y: point.y + dragOffset.dy)
        ball.velocity = .zero
        ball.restingTime = 0
        let target = surfaces.first { surface in
            guard surface.isVisible, let drift = drifts[surface.id],
                  surface.supports(x: ball.position.x) else { return false }
            let y = surface.top + height(drift, localX: ball.position.x - surface.frame.minX)
            let foot = CGPoint(x: ball.position.x, y: y + 0.1)
            return surface.isSupportExposed(foot) && abs(ball.position.y - ball.radius - y) < max(14, ball.radius * 0.75)
        }
        if let target = target {
            let distance = abs(ball.position.x - previous.x)
            let previousRadius = ball.radius
            if distance > 0.1 {
                collectRollingSnow(ball: &ball, surfaceID: target.id, fromX: previous.x, toX: ball.position.x)
            }
            if let drift = drifts[target.id] {
                ball.position.y = target.top + height(drift, localX: ball.position.x - target.frame.minX) + ball.radius
            }
            ball.surfaceID = target.id
            // Growth raises the center during rolling. Do not absorb pointer motion
            // into this offset: small upward events must accumulate into a lift.
            dragOffset.dy += ball.radius - previousRadius
        } else {
            ball.surfaceID = nil
        }
        balls[index] = ball
    }

    func endDrag(velocity: CGVector = .zero) {
        guard let id = dragID, let index = balls.firstIndex(where: { $0.id == id }) else { dragID = nil; return }
        balls[index].velocity = finite(velocity) ? limited(velocity, to: maximumSpeed) : .zero
        balls[index].restingTime = 0
        // Retain a direct surface contact; a lifted ball acquires a support through collision.
        if let sid = balls[index].surfaceID, let drift = drifts[sid] {
            let y = drift.surface.top + height(drift, localX: balls[index].position.x - drift.surface.frame.minX)
            if !drift.surface.supports(x: balls[index].position.x) ||
                abs(balls[index].position.y - balls[index].radius - y) > 2 || balls[index].velocity.dy > 20 {
                balls[index].surfaceID = nil
            }
        }
        dragID = nil
        updateSnowmen()
    }

    private func simulate(_ dt: CGFloat, weather: SnowWeather, regions: [CGRect]) {
        let targetWind = finite(weather.wind) ? limited(weather.wind, to: 1) : .zero
        let smoothing = 1 - exp(-dt * 6)
        smoothedWind.dx += (targetWind.dx - smoothedWind.dx) * smoothing
        smoothedWind.dy += (targetWind.dy - smoothedWind.dy) * smoothing
        // Snow grows less than 0.03 point per profile update. Its independent 30 Hz
        // clock avoids repeating visibility/slope work at the 120 Hz collision rate.
        profileTicks += 1
        profileDose += CGFloat(weather.intensity.deposition) * dt
        if profileTicks == 4 { flushProfile() }
        if !objectsFrozen {
            if !overlappingAfterDrag.isEmpty {
                let byID = Dictionary(uniqueKeysWithValues: balls.map { ($0.id, $0) })
                overlappingAfterDrag = overlappingAfterDrag.filter { pair in
                    guard let a = byID[pair.first], let b = byID[pair.second] else { return false }
                    return hypot(a.position.x - b.position.x, a.position.y - b.position.y) < a.radius + b.radius
                }
            }
            if !balls.isEmpty { simulateBalls(dt, regions: regions) }
        }
        if debris.isEmpty { if !objectsFrozen { updateSnowmen() }; return }
        var remaining: [SnowDebris] = []
        remaining.reserveCapacity(debris.count)
        for var part in debris {
            // Inactive connected displays retain paused fragments. A fragment
            // beyond every physical display has no future visible work to retain.
            if !connectedRegions.isEmpty && !connectedRegions.contains(where: {
                $0.insetBy(dx: -40, dy: -40).contains(part.position)
            }) { continue }
            guard regions.contains(where: { $0.insetBy(dx: -40, dy: -40).contains(part.position) }) else { remaining.append(part); continue }
            part.lifetime -= Double(dt)
            if part.lifetime <= 0 { continue }
            part.velocity.dy -= gravity * 0.45 * dt
            part.position.x += part.velocity.dx * dt
            part.position.y += part.velocity.dy * dt
            remaining.append(part)
        }
        debris = remaining
        if !objectsFrozen { updateSnowmen() }
    }

    private struct RectBounds {
        let minX: CGFloat
        let minY: CGFloat
        let maxX: CGFloat
        let maxY: CGFloat
        init(_ rect: CGRect) {
            // Normalize once; preserve CGRect's handling of negative-size bounds.
            minX = rect.minX; minY = rect.minY; maxX = rect.maxX; maxY = rect.maxY
        }
        @inline(__always) func contains(x: CGFloat, y: CGFloat) -> Bool {
            x >= minX && x < maxX && y >= minY && y < maxY
        }
    }

    private func flushProfile() {
        guard profileTicks > 0 else { return }
        let dt = CGFloat(profileTicks) * CGFloat(tick)
        let dose = profileDose
        profileTicks = 0; profileDose = 0
        guard !profileRegions.isEmpty, dose > 0 else { return }
        deposit(dt, dose: dose, regions: profileRegions)
    }

    private func deposit(_ dt: CGFloat, dose: CGFloat, regions: [RectBounds]) {
        for surface in surfaces where surface.isVisible {
            guard var drift = drifts[surface.id] else { continue }
            let minX = surface.frame.minX
            let width = surface.frame.width
            let top = surface.top
            let baseY = top + 0.01
            let inset = min(max(0, surface.topInset), width / 2)
            let occluders = surface.occluders.map(RectBounds.init)
            let phase: CGFloat = surface.kind == .floor ? 0 : CGFloat(stableHash(surface.id) % 10_000) / 997
            for index in drift.heights.indices {
                guard supportedProfileNode(index, count: drift.heights.count, width: width, inset: inset) else { continue }
                let x = minX + min(CGFloat(index) * SnowDrift.spacing, width)
                let y = baseY + drift.heights[index]
                guard regions.contains(where: { $0.contains(x: x, y: y) }),
                      !occluders.contains(where: { $0.contains(x: x, y: y) || $0.contains(x: x, y: baseY) }) else { continue }
                let variation = 0.85 + 0.12 * sin(x * 0.032 + phase) + 0.09 * sin(x * 0.071 - phase)
                let next = drift.heights[index] + dose * variation
                let limit = drift.heightLimits[index]
                drift.heights[index] = min(limit, next)
                if next > limit && nextRandom() < Double(dt) * 0.06 {
                    burst(at: CGPoint(x: x, y: y), amount: 1)
                }
            }
            relaxSlope(&drift, minX: minX, width: width, inset: inset, baseY: baseY, regions: regions, occluders: occluders)
            drifts[surface.id] = drift
        }
    }

    private func simulateBalls(_ dt: CGFloat, regions: [CGRect]) {
        // Lower balls update first, so supported balls inherit a stable position.
        let ordered = balls.indices.sorted { balls[$0].position.y < balls[$1].position.y }
        var escaped = Set<UUID>()
        let bounds = connectedRegions.reduce(CGRect.null) { $0.union($1) }
        for index in ordered {
            var ball = balls[index]
            guard ball.id != dragID else { continue }
            if let sid = ball.surfaceID, let surface = drifts[sid]?.surface, !surface.isVisible { continue }
            if ball.surfaceID == nil && !bounds.isNull && (ball.position.y + ball.radius < bounds.minY - 8 ||
                ball.position.x + ball.radius < bounds.minX - 8 || ball.position.x - ball.radius > bounds.maxX + 8) {
                escaped.insert(ball.id)
                continue
            }
            let active = regions.contains { $0.insetBy(dx: -ball.radius, dy: -ball.radius).contains(ball.position) }
            guard active else {
                if ball.surfaceID == nil && regions.contains(where: { ball.position.x >= $0.minX && ball.position.x <= $0.maxX }) &&
                    ball.position.y + ball.radius < (regions.map(\.minY).min() ?? 0) - 8 { escaped.insert(ball.id) }
                continue
            }
            if let supportID = supportedBy[ball.id], let support = balls.first(where: { $0.id == supportID }),
               supportID != dragID, let sid = support.surfaceID, abs(ball.position.x - support.position.x) <= support.radius * 0.25 + 0.5 {
                let dx = ball.position.x - support.position.x
                let distance = SnowballContact.stackedCenterDistance(radius: ball.radius, otherRadius: support.radius)
                ball.position.y = support.position.y + sqrt(max(0, distance * distance - dx * dx))
                ball.surfaceID = sid
                ball.velocity = .zero
                ball.restingTime += Double(dt)
                balls[index] = ball
                continue
            }
            supportedBy.removeValue(forKey: ball.id)
            if let sid = ball.surfaceID, let drift = drifts[sid],
               drift.surface.supports(x: ball.position.x), ball.velocity.dy <= 20 {
                let oldPosition = ball.position
                let oldX = ball.position.x
                ball.velocity.dx *= exp(-dt * 3.8)
                if abs(ball.velocity.dx) < 2 { ball.velocity.dx = 0 }
                ball.position.x += ball.velocity.dx * dt
                if drift.surface.supports(x: ball.position.x) {
                    ball.position.y = drift.surface.top + height(drift, localX: ball.position.x - drift.surface.frame.minX) + ball.radius
                    if let collision = firstCollision(ball: ball, from: oldPosition, to: ball.position, regions: regions, includeSurfaces: false) {
                        ball.position.x = collision.position.x
                        ball.velocity.dx = 0
                    }
                    if abs(ball.position.x - oldX) > 0.001 { collectRollingSnow(ball: &ball, surfaceID: sid, fromX: oldX, toX: ball.position.x) }
                    let current = drifts[sid]!
                    ball.position.y = current.surface.top + height(current, localX: ball.position.x - current.surface.frame.minX) + ball.radius
                    ball.velocity.dy = 0
                    ball.restingTime = abs(ball.velocity.dx) < 5 ? ball.restingTime + Double(dt) : 0
                    balls[index] = ball
                    continue
                }
                ball.surfaceID = nil
            }
            ball.surfaceID = nil
            ball.restingTime = 0
            ball.velocity.dx += smoothedWind.dx * 45 * dt
            ball.velocity.dy -= gravity * dt
            ball.velocity = limited(ball.velocity, to: maximumSpeed)
            let start = ball.position
            let end = CGPoint(x: start.x + ball.velocity.dx * dt, y: start.y + ball.velocity.dy * dt)
            let collision = firstCollision(ball: ball, from: start, to: end, regions: regions)
            if let collision = collision {
                ball.position = collision.position
                if let otherID = collision.ballID, let other = balls.first(where: { $0.id == otherID }) {
                    let offset = ball.position.x - other.position.x
                    if collision.normal.dy > 0.7, abs(offset) <= other.radius * 0.25, other.surfaceID != nil, other.id != dragID {
                        supportedBy[ball.id] = otherID
                        let distance = SnowballContact.stackedCenterDistance(radius: ball.radius, otherRadius: other.radius)
                        ball.position.y = other.position.y + sqrt(max(0, distance * distance - offset * offset))
                        ball.surfaceID = other.surfaceID
                        ball.velocity = .zero
                        ball.restingTime = Double(dt)
                    } else {
                        let projection = ball.velocity.dx * collision.normal.dx + ball.velocity.dy * collision.normal.dy
                        if projection < 0 {
                            ball.velocity.dx -= 1.18 * projection * collision.normal.dx
                            ball.velocity.dy -= 1.18 * projection * collision.normal.dy
                        }
                        ball.velocity.dx *= 0.8
                        if abs(ball.velocity.dx) < 4 && collision.normal.dy > 0.5 {
                            ball.velocity.dx = offset >= 0 ? 12 : -12
                        }
                    }
                } else if let sid = collision.surfaceID {
                    ball.surfaceID = sid
                    ball.velocity.dy = 0
                    ball.velocity.dx *= 0.68
                    ball.restingTime = abs(ball.velocity.dx) < 5 ? Double(dt) : 0
                }
            } else {
                ball.position = end
            }
            balls[index] = ball
        }
        removeBalls(escaped)
    }

    private struct Collision {
        var t: CGFloat
        var position: CGPoint
        var normal: CGVector
        var surfaceID: String?
        var ballID: UUID?
    }

    private func firstCollision(ball: Snowball, from: CGPoint, to: CGPoint, regions: [CGRect], includeSurfaces: Bool = true) -> Collision? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        var result: Collision?
        for surface in surfaces where includeSurfaces && surface.isVisible {
            guard let drift = drifts[surface.id], drift.heights.count > 1 else { continue }
            let localFrom = CGPoint(x: from.x - surface.frame.minX, y: from.y - ball.radius - surface.top)
            let localTo = CGPoint(x: to.x - surface.frame.minX, y: to.y - ball.radius - surface.top)
            for crossing in drift.visibleContour.crossings(from: localFrom, to: localTo) {
                let foot = CGPoint(x: crossing.point.x + surface.frame.minX, y: crossing.point.y + surface.top + 0.01)
                guard surface.isSupportExposed(foot), regions.contains(where: { $0.insetBy(dx: 0, dy: -1).contains(foot) }) else { continue }
                if result == nil || crossing.time < result!.t {
                    result = Collision(t: crossing.time, position: CGPoint(x: foot.x, y: foot.y - 0.01 + ball.radius), normal: CGVector(dx: 0, dy: 1), surfaceID: surface.id)
                }
            }
        }
        for other in balls where other.id != ball.id && other.id != dragID {
            if !overlappingAfterDrag.isEmpty && overlappingAfterDrag.contains(BallPair(ball.id, other.id)) { continue }
            // A settled child intentionally overlaps this ball. Its support
            // constraint moves it after the parent, so it must not push the parent.
            if supportedBy[other.id] == ball.id { continue }
            if let sid = other.surfaceID, let surface = drifts[sid]?.surface,
               !surface.isVisible { continue }
            let combined = ball.radius + other.radius
            let offset = vector(other.position, from)
            let movement = CGVector(dx: dx, dy: dy)
            let a = dx * dx + dy * dy
            let b = 2 * (offset.dx * dx + offset.dy * dy)
            let c = offset.dx * offset.dx + offset.dy * offset.dy - combined * combined
            var t: CGFloat?
            if c < -0.01 { t = 0 }
            else if a > 1e-10 {
                let discriminant = b * b - 4 * a * c
                if discriminant >= 0 {
                    let candidate = (-b - sqrt(discriminant)) / (2 * a)
                    if candidate >= -0.00001 && candidate <= 1 { t = max(0, candidate) }
                }
            }
            guard let time = t, result == nil || time < result!.t else { continue }
            let contact = CGPoint(x: from.x + movement.dx * time, y: from.y + movement.dy * time)
            var normal = vector(other.position, contact)
            let distance = length(normal)
            if distance < 0.001 { normal = CGVector(dx: 0, dy: 1) }
            else { normal.dx /= distance; normal.dy /= distance }
            if let sid = other.surfaceID, let surface = drifts[sid]?.surface {
                let touchingPoint = CGPoint(x: other.position.x + normal.dx * other.radius,
                                            y: other.position.y + normal.dy * other.radius)
                guard surface.isExposed(touchingPoint) else { continue }
            }
            // Resolve a hand-placed overlap before applying gravity; no explosive impulse.
            result = Collision(t: time, position: CGPoint(x: other.position.x + normal.dx * combined,
                                                         y: other.position.y + normal.dy * combined),
                               normal: normal, ballID: other.id)
        }
        return result
    }

    private func collectRollingSnow(ball: inout Snowball, surfaceID: String, fromX: CGFloat, toX: CGFloat) {
        let distance = abs(toX - fromX)
        guard distance > 0, ball.radius < maximumRadius else { return }
        let steps = min(128, max(1, Int(ceil(distance / 4))))
        let travel = min(distance, 512)
        for step in 1...steps {
            let x = fromX + (toX - fromX) * CGFloat(step) / CGFloat(steps)
            let capacity = CGFloat.pi * (maximumRadius * maximumRadius - ball.radius * ball.radius)
            guard capacity > 0.001 else { break }
            let collected = takeSnow(from: surfaceID, around: x, radius: max(8, ball.radius * 0.7),
                                     maximum: min(capacity, travel / CGFloat(steps) * max(2, ball.radius * 0.65)))
            ball.radius = min(maximumRadius, sqrt(ball.radius * ball.radius + collected / .pi))
        }
    }

    private func takeSnow(from surfaceID: String, around x: CGFloat, radius: CGFloat, maximum: CGFloat) -> CGFloat {
        guard maximum > 0, var drift = drifts[surfaceID], drift.surface.isVisible else { return 0 }
        let total = availableMass(in: drift, around: x, radius: radius)
        guard total > 0 else { return 0 }
        let fraction = min(1, maximum / total)
        var collected: CGFloat = 0
        for index in drift.heights.indices {
            let nodeX = drift.surface.frame.minX + sampleX(index, width: drift.surface.frame.width)
            guard abs(nodeX - x) <= radius else { continue }
            let removed = visibleHeight(drift, index: index) * fraction
            drift.heights[index] -= removed
            collected += removed * nodeWeight(index, width: drift.surface.frame.width)
        }
        drifts[surfaceID] = drift
        return collected
    }

    private func availableMass(in drift: SnowDrift, around x: CGFloat, radius: CGFloat) -> CGFloat {
        guard drift.surface.isVisible else { return 0 }
        return drift.heights.indices.reduce(CGFloat.zero) { result, index in
            let nodeX = drift.surface.frame.minX + sampleX(index, width: drift.surface.frame.width)
            guard abs(nodeX - x) <= radius else { return result }
            return result + visibleHeight(drift, index: index) * nodeWeight(index, width: drift.surface.frame.width)
        }
    }

    private func visibleHeight(_ drift: SnowDrift, index: Int) -> CGFloat {
        let x = drift.surface.frame.minX + sampleX(index, width: drift.surface.frame.width)
        let h = drift.heights[index]
        guard h > 0, drift.surface.isVisible, drift.surface.supports(x: x) else { return 0 }
        // Only remove a contiguous exposed layer from the top. Hidden lower snow stays put.
        let top = drift.surface.top + h
        var bottom = drift.surface.top
        for rect in drift.surface.occluders where x >= rect.minX && x <= rect.maxX {
            if rect.minY <= top && rect.maxY >= top { return 0 }
            if rect.maxY < top { bottom = max(bottom, rect.maxY) }
        }
        return max(0, top - bottom)
    }

    private func relaxSlope(_ drift: inout SnowDrift, minX: CGFloat, width: CGFloat, inset: CGFloat, baseY: CGFloat,
                            regions: [RectBounds], occluders: [RectBounds]) {
        guard drift.heights.count > 1 else { return }
        for index in 0..<(drift.heights.count - 1) {
            let difference = drift.heights[index] - drift.heights[index + 1]
            let localLeft = min(CGFloat(index) * SnowDrift.spacing, width)
            let localRight = min(CGFloat(index + 1) * SnowDrift.spacing, width)
            let permitted = max(0.1, (localRight - localLeft) * 0.65)
            // Most pairs already satisfy the slope constraint. Visibility matters
            // only for a pair whose mass could actually move.
            guard abs(difference) > permitted,
                  supportedProfileNode(index, count: drift.heights.count, width: width, inset: inset),
                  supportedProfileNode(index + 1, count: drift.heights.count, width: width, inset: inset) else { continue }
            let leftX = minX + localLeft
            let rightX = minX + localRight
            let leftY = baseY + drift.heights[index]
            let rightY = baseY + drift.heights[index + 1]
            guard regions.contains(where: { $0.contains(x: leftX, y: leftY) }),
                  regions.contains(where: { $0.contains(x: rightX, y: rightY) }),
                  !occluders.contains(where: {
                      $0.contains(x: leftX, y: leftY) || $0.contains(x: rightX, y: rightY) ||
                      $0.contains(x: leftX, y: baseY) || $0.contains(x: rightX, y: baseY)
                  }) else { continue }
            let wa = nodeWeight(index, width: width)
            let wb = nodeWeight(index + 1, width: width)
            guard wa > 0 && wb > 0 else { continue }
            let direction: CGFloat = difference > 0 ? 1 : -1
            let receiver = difference > 0 ? index + 1 : index
            let receiverWeight = difference > 0 ? wb : wa
            let capacity = max(0, drift.heightLimits[receiver] - drift.heights[receiver]) * receiverWeight
            let transfer = min(capacity, (abs(difference) - permitted) / (1 / wa + 1 / wb))
            drift.heights[index] -= direction * transfer / wa
            drift.heights[index + 1] += direction * transfer / wb
        }
    }

    private func preserveAreaOnExpansion(old: SnowDrift, surface: SnowSurface, limits: [CGFloat], heights: inout [CGFloat]) {
        let difference = area(old) - profileArea(heights, width: surface.frame.width)
        guard abs(difference) > 1e-8 else { return }
        var remaining = difference
        // Correct only the boundary first; preserve the established interior contour.
        let boundary = min(heights.count - 1, max(0, old.heights.count - 1))
        for index in stride(from: boundary, through: 0, by: -1) {
            let weight = nodeWeight(index, width: surface.frame.width)
            guard weight > 0 else { continue }
            let change = max(-heights[index], min(limits[index] - heights[index], remaining / weight))
            heights[index] += change
            remaining -= change * weight
            if abs(remaining) < 1e-8 { break }
        }
    }

    private func updateSnowmen() {
        guard balls.count >= 3 else {
            if !snowmen.isEmpty { snowmen.removeAll(keepingCapacity: true) }
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: balls.map { ($0.id, $0) })
        var groups: [Snowman] = []
        var used = Set<UUID>()
        for bottom in balls where bottom.surfaceID != nil && supportedBy[bottom.id] == nil && bottom.id != dragID {
            guard bottom.restingTime >= 0.5 && length(bottom.velocity) < 5 && !used.contains(bottom.id) else { continue }
            for middle in balls where supportedBy[middle.id] == bottom.id {
                guard middle.radius <= bottom.radius + 0.001, middle.restingTime >= 0.5,
                      abs(middle.position.x - bottom.position.x) <= bottom.radius * 0.25,
                      length(middle.velocity) < 5, !used.contains(middle.id) else { continue }
                guard let head = balls.first(where: { candidate in
                    supportedBy[candidate.id] == middle.id && candidate.radius <= middle.radius + 0.001 &&
                        candidate.restingTime >= 0.5 && length(candidate.velocity) < 5 &&
                        abs(candidate.position.x - middle.position.x) <= middle.radius * 0.25 &&
                        abs(candidate.position.x - bottom.position.x) <= bottom.radius * 0.25 &&
                        candidate.id != dragID && !used.contains(candidate.id)
                }) else { continue }
                let ids = [bottom.id, middle.id, head.id]
                guard ids.allSatisfy({ byID[$0] != nil }) else { continue }
                groups.append(Snowman(ballIDs: ids))
                used.formUnion(ids)
                break
            }
        }
        snowmen = groups
    }

    private func detach(_ id: UUID) {
        var detached: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for (child, parent) in supportedBy where detached.contains(parent) && !detached.contains(child) {
                detached.insert(child)
                changed = true
            }
        }
        for index in balls.indices where detached.contains(balls[index].id) {
            if balls[index].id != id { balls[index].surfaceID = nil }
            balls[index].restingTime = 0
            supportedBy.removeValue(forKey: balls[index].id)
        }
        snowmen.removeAll { !$0.ballIDs.allSatisfy { !detached.contains($0) } }
    }

    private func removeBalls(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { detach(id) }
        balls.removeAll { ids.contains($0.id) }
        if let id = dragID, ids.contains(id) { dragID = nil }
        repairSupports()
    }

    private func repairSupports() {
        let valid = Set(balls.map(\.id))
        supportedBy = supportedBy.filter { valid.contains($0.key) && valid.contains($0.value) }
        snowmen.removeAll { !$0.ballIDs.allSatisfy(valid.contains) }
    }

    private func burst(at point: CGPoint, amount: Int) {
        let count = min(max(0, amount), max(0, debrisLimit - debris.count))
        for _ in 0..<count {
            debris.append(SnowDebris(position: point,
                                    velocity: CGVector(dx: (nextRandom() - 0.5) * 120, dy: 25 + nextRandom() * 85),
                                    lifetime: 0.45 + nextRandom() * 0.55, radius: 1 + nextRandom() * 2))
        }
    }

    @inline(__always)
    private func supportedProfileNode(_ index: Int, count: Int, width: CGFloat, inset: CGFloat) -> Bool {
        guard inset > 0 else { return true }
        let left = min(CGFloat(max(0, index - 1)) * SnowDrift.spacing, width)
        let right = min(CGFloat(min(count - 1, index + 1)) * SnowDrift.spacing, width)
        return left >= inset && right <= width - inset
    }

    private func sampleCount(_ width: CGFloat) -> Int { max(2, Int(ceil(width / SnowDrift.spacing)) + 1) }
    private func sampleX(_ index: Int, width: CGFloat) -> CGFloat { min(CGFloat(index) * SnowDrift.spacing, width) }
    private func nodeWeight(_ index: Int, width: CGFloat) -> CGFloat {
        let count = sampleCount(width)
        let x = sampleX(index, width: width)
        let before = index > 0 ? x - sampleX(index - 1, width: width) : 0
        let after = index + 1 < count ? sampleX(index + 1, width: width) - x : 0
        return (before + after) * 0.5
    }
    private func height(_ drift: SnowDrift, localX: CGFloat) -> CGFloat {
        drift.visibleContour.height(at: localX)
    }
    private func storedHeight(_ drift: SnowDrift, localX: CGFloat) -> CGFloat {
        guard !drift.heights.isEmpty else { return 0 }
        let x = max(0, min(localX, drift.surface.frame.width))
        let a = min(drift.heights.count - 1, max(0, Int(floor(x / SnowDrift.spacing))))
        let b = min(drift.heights.count - 1, a + 1)
        let xa = sampleX(a, width: drift.surface.frame.width)
        let xb = sampleX(b, width: drift.surface.frame.width)
        guard xb > xa else { return drift.heights[a] }
        let t = (x - xa) / (xb - xa)
        return drift.heights[a] * (1 - t) + drift.heights[b] * t
    }
    private func area(_ drift: SnowDrift) -> CGFloat { profileArea(drift.heights, width: drift.surface.frame.width) }
    private func profileArea(_ heights: [CGFloat], width: CGFloat) -> CGFloat {
        heights.indices.reduce(0) { $0 + heights[$1] * nodeWeight($1, width: width) }
    }
    private func nextRandom() -> Double {
        randomState &+= 0x9e3779b97f4a7c15
        var z = randomState
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Double(z >> 11) / 9_007_199_254_740_992
    }
    private func nextID() -> UUID {
        var bytes = (0..<16).map { _ in UInt8(nextRandom() * 256) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    private func vector(_ from: CGPoint, _ to: CGPoint) -> CGVector { CGVector(dx: to.x - from.x, dy: to.y - from.y) }
    private func length(_ value: CGVector) -> CGFloat { hypot(value.dx, value.dy) }
    private func limited(_ value: CGVector, to maximum: CGFloat) -> CGVector {
        let magnitude = length(value)
        return magnitude > maximum ? CGVector(dx: value.dx / magnitude * maximum, dy: value.dy / magnitude * maximum) : value
    }
    private func ballBounds(_ ball: Snowball) -> CGRect {
        CGRect(x: ball.position.x - ball.radius, y: ball.position.y - ball.radius, width: ball.radius * 2, height: ball.radius * 2)
    }
    private func finite(_ value: CGPoint) -> Bool { value.x.isFinite && value.y.isFinite }
    private func finite(_ value: CGVector) -> Bool { value.dx.isFinite && value.dy.isFinite }
    private func finite(_ value: CGRect) -> Bool {
        value.origin.x.isFinite && value.origin.y.isFinite && value.width.isFinite && value.height.isFinite
    }
}
