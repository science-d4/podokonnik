import Foundation

/// Distributes a requested rate over display ticks without assuming that it
/// divides the monitor refresh rate (for example 60 FPS on a 100 Hz display).
struct FramePacer {
    static func preferredRate(nativeMaximum: Int, isMoving: Bool, constrained: Bool) -> Double {
        let limit = constrained ? 30 : (isMoving ? 120 : 60)
        return Double(min(max(1, nativeMaximum), limit))
    }

    var rate: Double = 60 {
        didSet { if oldValue != rate { reset() } }
    }
    private var nextDeadline: Double?
    mutating func reset() { nextDeadline = nil }
    mutating func shouldRender(at time: Double) -> Bool {
        guard time.isFinite, rate.isFinite, rate > 0 else { return false }
        let step = 1 / min(240, rate)
        guard let deadline = nextDeadline, time >= deadline - step * 10 else {
            nextDeadline = time + step; return true
        }
        guard time + 0.000_001 >= deadline else { return false }
        if time - deadline > 0.25 {
            nextDeadline = time + step
        } else {
            var next = deadline + step
            while next <= time + 0.000_001 { next += step }
            nextDeadline = next
        }
        return true
    }
}
