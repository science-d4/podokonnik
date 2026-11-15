import Foundation
import CoreGraphics

struct SnowplowPass {
    var surface: SnowSurface
    var x: CGFloat
    var travelled: CGFloat = 0
    var bucketX: CGFloat { x + 37 }
}

struct SnowplowSweep {
    let surfaceID: String
    let fromX: CGFloat
    let toX: CGFloat
}

/// Uses active simulation time. Pauses, sleep and hidden displays do not accrue work.
struct SnowplowSchedule {
    private(set) var passes: [String: SnowplowPass] = [:]
    private var elapsed: [String: TimeInterval] = [:]
    private var interval = 10
    private var requested = false

    mutating func requestSweep() { requested = true }

    mutating func cancelPasses() {
        for id in passes.keys { elapsed[id] = 0 }
        passes.removeAll()
        requested = false
    }

    mutating func advance(delta: TimeInterval, surfaces: [SnowSurface], activeRegions: [CGRect],
                          intervalMinutes: Int, reducedMotion: Bool = false,
                          speedMultiplier: Double = 1.25) -> [SnowplowSweep] {
        let configured = [5, 10, 30].contains(intervalMinutes) ? intervalMinutes : 10
        if configured != interval {
            interval = configured
            elapsed.removeAll()
        }
        guard delta.isFinite, delta > 0 else { return [] }
        // A resumed display cannot turn a long timestamp gap into missed sweeps.
        let dt = min(delta, 0.1)
        let speed = speedMultiplier.isFinite ? min(2, max(0.5, speedMultiplier)) : 1.25
        let floors = surfaces.filter { $0.kind == .floor }
        let retained = Set(floors.map(\.id))
        elapsed = elapsed.filter { retained.contains($0.key) }
        passes = passes.filter { retained.contains($0.key) }
        var sweeps: [SnowplowSweep] = []
        let force = requested
        requested = false
        for floor in floors {
            guard floor.isVisible, activeRegions.contains(where: {
                floor.frame.minX < $0.maxX && floor.frame.maxX > $0.minX
                    && floor.top >= $0.minY && floor.top < $0.maxY
            }) else { continue }
            if let pass = passes[floor.id], pass.surface.frame != floor.frame {
                passes.removeValue(forKey: floor.id)
                elapsed[floor.id] = 0
            }
            elapsed[floor.id, default: 0] += dt
            if passes[floor.id] == nil {
                if force || elapsed[floor.id, default: 0] >= Double(interval) * 60 {
                    passes[floor.id] = SnowplowPass(surface: floor, x: floor.frame.minX - 54)
                    elapsed[floor.id] = 0
                }
            }
            guard var pass = passes[floor.id] else { continue }
            pass.surface = floor
            let previous = pass.bucketX
            let distance = CGFloat(dt * speed) * (reducedMotion ? 90 : 160)
            pass.x += distance
            pass.travelled += distance
            // Keep the travelled lane clear throughout the pass: slope relaxation
            // otherwise pulls untouched snow back under the rear wheels immediately.
            sweeps.append(SnowplowSweep(surfaceID: floor.id, fromX: min(previous, floor.frame.minX), toX: pass.bucketX))
            if pass.x - 44 > floor.frame.maxX { passes.removeValue(forKey: floor.id) }
            else { passes[floor.id] = pass }
        }
        return sweeps
    }
}
