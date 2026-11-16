import Foundation

@main
enum FramePacerTests {
    static func main() {
        precondition(FramePacer.driverID(displays: [], isMoving: true, constrained: false) == nil)
        precondition(FramePacer.driverID(displays: [(id: 1, nativeMaximum: 60), (id: 2, nativeMaximum: 120)], isMoving: true, constrained: false) == 2,
                     "a slower display with a lower ID must not limit the shared world")
        precondition(FramePacer.driverID(displays: [(id: 7, nativeMaximum: 120), (id: 2, nativeMaximum: 120)], isMoving: true, constrained: false) == 2,
                     "displays with equal refresh rates select a stable driver")
        precondition(FramePacer.driverID(displays: [(id: 1, nativeMaximum: 60)], isMoving: true, constrained: false) == 1,
                     "the remaining active display drives the world")
        let mixed = [(id: UInt32(1), nativeMaximum: 120), (id: UInt32(2), nativeMaximum: 144)]
        guard let motionID = FramePacer.driverID(displays: mixed, isMoving: true, constrained: false),
              let motionScreen = mixed.first(where: { $0.id == motionID }) else {
            preconditionFailure("a clock must be selected")
        }
        var sharedClock = FramePacer(rate: 120)
        let delivered = (0..<(motionScreen.nativeMaximum * 2)).compactMap { tick -> Double? in
            let timestamp = Double(tick) / Double(motionScreen.nativeMaximum)
            return sharedClock.shouldRender(at: timestamp) ? timestamp : nil
        }
        let longest = zip(delivered.dropFirst(), delivered).map(-).max() ?? .infinity
        precondition(delivered.count == 240 && longest <= 1.0 / 120 + 0.000_001,
                     "the shared clock must deliver 120 equally spaced updates on 120/144 Hz displays")
        precondition(FramePacer.driverID(displays: mixed, isMoving: false, constrained: false) == 1,
                     "idle 60 FPS should also use the display with a regular cadence")
        precondition(FramePacer.driverID(displays: mixed, isMoving: true, constrained: true) == 1,
                     "the 30 FPS power limit must be included in driver selection")
        precondition(FramePacer.driverID(displays: [(id: 1, nativeMaximum: 100), (id: 2, nativeMaximum: 144)], isMoving: false, constrained: false) == 1,
                     "when neither rate divides 60 FPS, minimize the longest interval")
        precondition(FramePacer.driverID(displays: [(id: 1, nativeMaximum: 60), (id: 2, nativeMaximum: 75)], isMoving: true, constrained: false) == 2,
                     "a smoother but slower driver must not reduce the available burst rate")
        let changing = [(id: UInt32(1), nativeMaximum: 60), (id: UInt32(2), nativeMaximum: 75)]
        precondition(FramePacer.driverID(displays: changing, isMoving: false, constrained: false) == 1,
                     "idle chooses a regular 60 FPS clock")
        precondition(FramePacer.driverID(displays: changing, isMoving: true, constrained: true) == 1,
                     "entering the constrained mode restores the regular clock")
        precondition(FramePacer.driverID(displays: changing, isMoving: true, constrained: false) == 2,
                     "leaving the constrained mode restores the higher motion rate")
        precondition(FramePacer.driverID(displays: [(id: 7, nativeMaximum: 120), (id: 2, nativeMaximum: 240)], isMoving: true, constrained: false) == 2,
                     "equally regular clocks use the stable display ID")
        for native in [24, 30, 60, 75, 100, 120, 144, 240] {
            precondition(FramePacer.preferredRate(nativeMaximum: native, isMoving: false, constrained: false) == Double(min(native, 60)))
            precondition(FramePacer.preferredRate(nativeMaximum: native, isMoving: true, constrained: false) == Double(min(native, 120)))
            for moving in [false, true] {
                precondition(FramePacer.preferredRate(nativeMaximum: native, isMoving: moving, constrained: true) == Double(min(native, 30)),
                             "economy and reduced motion override the motion burst")
            }
            let rate = FramePacer.preferredRate(nativeMaximum: native, isMoving: true, constrained: false)
            var motion = FramePacer(rate: rate)
            let frames = (0..<(native * 2)).filter { motion.shouldRender(at: Double($0) / Double(native)) }.count
            precondition(abs(Double(frames) - rate * 2) <= 1, "motion rate obeys native refresh and 120 FPS cap")
        }
        precondition(FramePacer.preferredRate(nativeMaximum: 0, isMoving: true, constrained: false) == 1)
        for refresh in [60.0, 75, 100, 120, 144] {
            for target in [30.0, 60] {
                var pacer = FramePacer(rate: target)
                var rendered: [Double] = []
                for tick in 0..<Int(refresh*10) {
                    let time = Double(tick)/refresh
                    if pacer.shouldRender(at: time) { rendered.append(time) }
                }
                precondition(abs(Double(rendered.count)-target*10) <= 1, "Rate on \(refresh) Hz")
                let intervals = zip(rendered.dropFirst(), rendered).map(-)
                precondition((intervals.max() ?? 0) <= ceil(refresh/target)/refresh+0.00001)
            }
        }
        var pacer = FramePacer()
        precondition(pacer.shouldRender(at: 0))
        precondition(!pacer.shouldRender(at: 0.001))
        precondition(pacer.shouldRender(at: 1_000), "Resume without backlog")
        precondition(!pacer.shouldRender(at: 1_000.001))
        pacer.rate = 30
        precondition(pacer.shouldRender(at: 1_000.002), "Rate change resets clock")
        precondition(!pacer.shouldRender(at: .nan))
        pacer.rate = FramePacer.preferredRate(nativeMaximum: 100, isMoving: true, constrained: false)
        precondition(pacer.shouldRender(at: 1_001), "entering native burst does not retain the 30 FPS deadline")
        precondition(!pacer.shouldRender(at: 1_001.001), "burst never catches up with duplicate frames")
        pacer.rate = FramePacer.preferredRate(nativeMaximum: 100, isMoving: false, constrained: false)
        precondition(pacer.shouldRender(at: 1_001.002), "idle restores the ordinary 60 FPS schedule")
        pacer.reset()
        precondition(pacer.shouldRender(at: 20_000) && !pacer.shouldRender(at: 20_000.001), "resume starts one fresh frame without queued work")
        print("Frame pacing: 8 native motion/power policies, 10 steady refresh/rate combinations and pause/burst/resume checks passed")
    }
}
