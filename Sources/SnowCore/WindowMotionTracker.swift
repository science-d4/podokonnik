import Foundation
import CoreGraphics

/// WindowServer publishes intermediate Dock animation bounds under the real window ID.
struct WindowSurfaceAnimations {
    private struct Sample {
        var frame: CGRect
        var stableSince: TimeInterval
        var minimumStability: TimeInterval
    }

    private var animated: [String: Sample] = [:]
    private var missionRecovery: Set<String> = []

    mutating func resetForSpaceChange() {
        animated = animated.filter { $0.value.minimumStability >= 0.30 }
    }

    /// CG supplies no public animation flag. A substantial resize outside a
    /// pointer drag, a changed frame reappearing from a hidden state and
    /// changed bounds during a Space transition need a stable sample.
    mutating func reconcile(_ incoming: [SnowSurface], previous: [SnowSurface], hiddenIDs: Set<String>,
                            displays: [CGRect] = [], pointerPressed: Bool, spaceChanging: Bool = false,
                            missionControlActive: Bool = false,
                            at time: TimeInterval) -> [SnowSurface] {
        if missionControlActive {
            animated.removeAll()
            missionRecovery = Set(previous.filter { $0.kind == .window }.map(\.id))
            let otherSurfaces = incoming.filter { $0.kind != .window && !hiddenIDs.contains($0.id) }
            let retained = previous.filter { $0.kind == .window }.map { surface in
                var hidden = surface
                hidden.isVisible = false
                return hidden
            }
            return otherSurfaces + retained
        }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        var next: [String: Sample] = [:]
        var surfaces: [SnowSurface] = []
        var hidden = hiddenIDs
        if spaceChanging {
            let reportedIDs = Set(incoming.map(\.id))
            for surface in previous where surface.kind == .window && !reportedIDs.contains(surface.id) {
                hidden.insert(surface.id)
            }
        }
        for var surface in incoming where !hidden.contains(surface.id) {
            if surface.kind == .window, let stored = old[surface.id], surface.frame != stored.frame {
                let frame = surface.frame
                let onDisplay = displays.contains { $0.intersects(frame) }
                // WindowServer can slide the returning Space onto the screen
                // before NSWorkspace delivers its notification. The Dock
                // animation changes the window's position and dimensions.
                let movingHorizontally = !pointerPressed && frame.minX != stored.frame.minX
                let returningOnSameEdge = (!stored.isVisible || movingHorizontally) && abs(frame.maxY - stored.top) <= 2
                if onDisplay, surface.isVisible, spaceChanging || returningOnSameEdge,
                   !missionRecovery.contains(surface.id) || frame.size == stored.frame.size,
                   abs(frame.width - stored.frame.width) <= 2, abs(frame.height - stored.frame.height) <= 2 {
                    // Trust current visibility and position. Keep the original
                    // dimensions while CG is rounding the window's bounds.
                    surface.frame = CGRect(x: frame.minX, y: frame.maxY - stored.frame.height,
                                           width: stored.frame.width, height: stored.frame.height)
                    surface.topInset = stored.topInset
                    surfaces.append(surface)
                    missionRecovery.remove(surface.id)
                    continue
                }
                let substantialResize = abs(frame.width - stored.frame.width) > 2
                    || abs(frame.height - stored.frame.height) > 2
                if spaceChanging || missionRecovery.contains(surface.id) || animated[surface.id] != nil
                    || !stored.isVisible || (substantialResize && !pointerPressed) {
                    let minimumStability = spaceChanging && !substantialResize
                        && !missionRecovery.contains(surface.id) ? 0.08 : 0.30
                    var sample = animated[surface.id].flatMap { $0.frame == frame ? $0 : nil }
                        ?? Sample(frame: frame, stableSince: time, minimumStability: minimumStability)
                    sample.minimumStability = max(sample.minimumStability, minimumStability)
                    if time - sample.stableSince < sample.minimumStability || (spaceChanging && !onDisplay) {
                        next[surface.id] = sample
                        hidden.insert(surface.id)
                        continue
                    }
                }
            }
            surfaces.append(surface)
            missionRecovery.remove(surface.id)
        }
        animated = next
        for var stored in previous where hidden.contains(stored.id) {
            stored.isVisible = false
            surfaces.append(stored)
        }
        missionRecovery.formIntersection(Set(surfaces.map(\.id)))
        return surfaces
    }
}

/// A manual window drag continues until the pointer is released, even when
/// the window pauses between geometry samples.
struct WindowDragDetector {
    private(set) var isDragging = false

    mutating func reset() { isDragging = false }

    mutating func update(previous: [SnowSurface], current: [SnowSurface], pointerPressed: Bool) -> Bool {
        guard pointerPressed else { reset(); return false }
        if isDragging { return true }
        let frames = Dictionary(uniqueKeysWithValues: previous.filter { $0.kind == .window && $0.isVisible }
            .map { ($0.id, $0.frame) })
        isDragging = current.contains { surface in
            surface.kind == .window && surface.isVisible && frames[surface.id].map { $0 != surface.frame } == true
        }
        return isDragging
    }
}

/// Require a continuous pointer press so CG translations from Spaces, tiling
/// and other system animations cannot trigger the destructive shake effect.
struct WindowShakeDetector {
    private var gate = WindowMotionSampleGate()
    private var motion = WindowMotionTracker()

    mutating func reset() {
        gate.reset()
        motion.reset()
    }

    mutating func update(surfaces: [SnowSurface], dragging: Bool, at time: TimeInterval) -> [String: CGVector] {
        guard dragging else {
            reset()
            return [:]
        }
        return gate.shouldSample(at: time) ? motion.update(surfaces: surfaces, at: time) : [:]
    }
}

/// Preserve the detector's distance threshold when metadata arrives at 120 Hz.
/// Geometry and rendering still consume every snapshot; only shake detection samples.
struct WindowMotionSampleGate {
    private var lastSample: TimeInterval?

    mutating func reset() { lastSample = nil }
    mutating func shouldSample(at time: TimeInterval) -> Bool {
        guard time.isFinite else { lastSample = nil; return true }
        if let previous = lastSample, time >= previous, time - previous + 1e-9 < 0.02 { return false }
        lastSample = time
        return true
    }
}

/// Detects fast translations from consecutive metadata snapshots. The caller
/// resets this history at Space, sleep and other desktop-session boundaries.
struct WindowMotionTracker {
    private struct Sample {
        var frame: CGRect
        var time: TimeInterval
        var lastShedTime: TimeInterval?
    }

    private var samples: [String: Sample] = [:]
    private static let minimumDistance: CGFloat = 20
    private static let minimumSpeed: CGFloat = 1_000
    private static let maximumGap: TimeInterval = 0.35
    private static let cooldown: TimeInterval = 0.7

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    /// Returns AppKit-point velocities per second, once per window cooldown.
    /// Missing, invisible and non-window surfaces have no retained history.
    mutating func update(surfaces: [SnowSurface], at time: TimeInterval) -> [String: CGVector] {
        guard time.isFinite else { reset(); return [:] }
        var next: [String: Sample] = [:]
        var result: [String: CGVector] = [:]
        next.reserveCapacity(surfaces.count)
        for surface in surfaces where surface.kind == .window && surface.isVisible {
            let frame = surface.frame
            guard next[surface.id] == nil,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { continue }
            var current = Sample(frame: frame, time: time, lastShedTime: nil)
            if let previous = samples[surface.id] {
                let elapsed = time - previous.time
                if elapsed >= 0 { current.lastShedTime = previous.lastShedTime }
                // Resize changes the anchor as well as the size. It establishes a
                // fresh baseline instead of being mistaken for a fast translation.
                if elapsed > 0, elapsed <= Self.maximumGap + 1e-9,
                   frame.size == previous.frame.size {
                    let dx = frame.origin.x - previous.frame.origin.x
                    let dy = frame.origin.y - previous.frame.origin.y
                    let distance = hypot(dx, dy)
                    let velocity = CGVector(dx: dx / elapsed, dy: dy / elapsed)
                    let speed = distance / elapsed
                    let ready = previous.lastShedTime.map { time - $0 + 1e-9 >= Self.cooldown } ?? true
                    if ready, distance.isFinite, speed.isFinite,
                       velocity.dx.isFinite, velocity.dy.isFinite,
                       distance + 1e-9 >= Self.minimumDistance,
                       speed + 1e-6 >= Self.minimumSpeed {
                        result[surface.id] = velocity
                        current.lastShedTime = time
                    }
                }
            }
            next[surface.id] = current
        }
        samples = next
        return result
    }
}
