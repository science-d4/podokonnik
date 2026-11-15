import Foundation

@main
enum FramePacerTests {
    static func main() {
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
