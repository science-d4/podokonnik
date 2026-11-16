import Foundation

/// Distributes a requested rate over display ticks without assuming that it
/// divides the monitor refresh rate (for example 60 FPS on a 100 Hz display).
struct FramePacer {
    /// Prefer the fastest allowed update rate and then its most regular cadence.
    static func driverID(displays: [(id: UInt32, nativeMaximum: Int)],
                         isMoving: Bool, constrained: Bool) -> UInt32? {
        displays.sorted {
            let leftNative = max(1, $0.nativeMaximum)
            let rightNative = max(1, $1.nativeMaximum)
            let leftRate = Int(preferredRate(nativeMaximum: leftNative, isMoving: isMoving, constrained: constrained))
            let rightRate = Int(preferredRate(nativeMaximum: rightNative, isMoving: isMoving, constrained: constrained))
            if leftRate != rightRate { return leftRate > rightRate }
            // ceil(native / rate) is the longest number of native ticks between
            // delivered frames; integer arithmetic handles exact divisors.
            let leftGap = Double((leftNative - 1) / leftRate + 1) / Double(leftNative)
            let rightGap = Double((rightNative - 1) / rightRate + 1) / Double(rightNative)
            if abs(leftGap - rightGap) > 1e-12 { return leftGap < rightGap }
            return $0.id < $1.id
        }.first?.id
    }

    static func preferredRate(nativeMaximum: Int, isMoving: Bool, constrained: Bool) -> Double {
        let limit = constrained ? 30 : (isMoving ? 120 : 60)
        return Double(min(max(1, nativeMaximum), limit))
    }

    var rate: Double = 60 {
        didSet { if oldValue != rate { reset() } }
    }
    private var nextDeadline: Double?

    init(rate: Double = 60) {
        self.rate = rate
    }

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
