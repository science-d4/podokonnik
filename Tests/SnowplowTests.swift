import Foundation
import CoreGraphics

@main
enum SnowplowTests {
    private static var checks = 0
    private static let tick = 1.0 / 16 // Exact binary steps keep boundary tests deterministic.
    private static let region = CGRect(x: -300, y: -100, width: 600, height: 500)
    private static let floor = SnowSurface(id: "floor:test", frame: CGRect(x: -300, y: -101, width: 600, height: 1), kind: .floor)

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Snowplow: \(message)") }
        checks += 1
    }
    @discardableResult
    private static func advance(_ schedule: inout SnowplowSchedule, minutes: Int = 5,
                                surfaces: [SnowSurface] = [floor], regions: [CGRect] = [region],
                                delta: TimeInterval = tick) -> [SnowplowSweep] {
        schedule.advance(delta: delta, surfaces: surfaces, activeRegions: regions, intervalMinutes: minutes)
    }

    static func main() {
        speedChanges()
        for minutes in [5, 10, 30] {
            var schedule = SnowplowSchedule()
            var startedEarly = false
            for _ in 0..<(minutes * 60 * 16 - 1) {
                if !advance(&schedule, minutes: minutes).isEmpty { startedEarly = true }
            }
            check(!startedEarly && schedule.passes.isEmpty, "\(minutes)-minute pass must not start before its boundary")
            let sweeps = advance(&schedule, minutes: minutes)
            check(sweeps.count == 1 && sweeps[0].surfaceID == floor.id && schedule.passes.count == 1,
                  "\(minutes)-minute active-time boundary must start exactly one floor pass")
        }

        var paused = SnowplowSchedule()
        for _ in 0..<(299 * 16) { advance(&paused) }
        var hiddenFloor = floor; hiddenFloor.isVisible = false
        for _ in 0..<1600 {
            checkNoSweeps(advance(&paused, regions: []))
            checkNoSweeps(advance(&paused, surfaces: [hiddenFloor]))
            checkNoSweeps(advance(&paused, delta: 0))
        }
        for _ in 0..<15 { checkNoSweeps(advance(&paused)) }
        check(paused.passes.isEmpty, "hidden/paused time must neither advance nor reset accumulated active time")
        check(advance(&paused).count == 1, "resume must start only after the final active second")

        var gap = SnowplowSchedule()
        check(advance(&gap, delta: 24 * 60 * 60).isEmpty && gap.passes.isEmpty,
              "a sleep-sized delta must not cause catch-up sweeps")
        gap.requestSweep()
        check(advance(&gap).count == 1, "manual request must start an active floor without waiting for its interval")
        let x = gap.passes[floor.id]!.x
        gap.requestSweep()
        let resumed = advance(&gap, delta: 1000)
        check(resumed.count == 1 && gap.passes.count == 1 && gap.passes[floor.id]!.x > x
              && gap.passes[floor.id]!.x - x <= 20.001,
              "manual requests cannot duplicate/restart a pass; large dt advances it by at most one bounded step")
        for _ in 0..<1000 where !gap.passes.isEmpty { advance(&gap) }
        check(gap.passes.isEmpty, "one pass must finish after crossing the floor")
        check(advance(&gap).isEmpty, "completed manual pass must not repeat without another request or interval")

        var cadence = SnowplowSchedule()
        for _ in 0..<(300 * 16) { advance(&cadence) }
        var prematureRestart = false
        for _ in 0..<(300 * 16 - 1) {
            let wasEmpty = cadence.passes.isEmpty
            advance(&cadence)
            if wasEmpty && !cadence.passes.isEmpty { prematureRestart = true }
        }
        check(!prematureRestart && cadence.passes.isEmpty, "next automatic pass cannot start before another five active minutes")
        check(advance(&cadence).count == 1,
              "interval must measure start-to-start and include time spent driving the previous pass")

        var changed = SnowplowSchedule()
        changed.requestSweep(); advance(&changed)
        var resized = floor; resized.frame.size.width += 120
        check(advance(&changed, surfaces: [resized]).isEmpty && changed.passes.isEmpty,
              "resizing a floor must cancel its old trajectory without teleporting a pass")
        changed.requestSweep(); advance(&changed, surfaces: [resized])
        check(advance(&changed, surfaces: []).isEmpty && changed.passes.isEmpty, "removing a floor must remove its active pass")
        check(advance(&changed).isEmpty, "reconnecting the floor must not restore its removed pass or elapsed time")

        var kinds = SnowplowSchedule()
        var window = floor; window.id = "window"; window.kind = .window
        var dock = floor; dock.id = "dock"; dock.kind = .dock
        var other = floor; other.id = "hidden-display-floor"; other.frame.origin.x += 1000
        kinds.requestSweep()
        let sweeps = advance(&kinds, surfaces: [window, dock, floor, other])
        check(sweeps.map(\.surfaceID) == [floor.id] && Set(kinds.passes.keys) == [floor.id],
              "sweeps apply only to floor surfaces on active displays, never windows or Dock")
        kinds.cancelPasses()
        check(kinds.passes.isEmpty && advance(&kinds).isEmpty, "cancel must clear active passes and pending manual work")
        print("SnowplowSchedule: \(checks) checks passed")
    }

    private static func speedChanges() {
        for reducedMotion in [false, true] {
            let base: CGFloat = reducedMotion ? 90 : 160
            for (input, expected) in [(0.5, 0.5), (1.25, 1.25), (2.0, 2.0), (-100, 0.5), (100, 2.0),
                                      (Double.nan, 1.25), (Double.infinity, 1.25)] {
                var schedule = SnowplowSchedule(); schedule.requestSweep()
                for _ in 0..<8 {
                    _ = schedule.advance(delta: tick, surfaces: [floor], activeRegions: [region], intervalMinutes: 5,
                                         reducedMotion: reducedMotion, speedMultiplier: input)
                }
                check(abs(schedule.passes[floor.id]!.travelled - base * CGFloat(expected) * 0.5) < 1e-8,
                      "distance follows finite bounded speed and the Reduce Motion coefficient")
            }
        }

        var schedule = SnowplowSchedule(); schedule.requestSweep()
        advance(&schedule)
        check(schedule.passes[floor.id]!.travelled == 200 * tick, "default speed is 200pt/s")
        let initial = schedule.passes[floor.id]!
        let changed = schedule.advance(delta: tick, surfaces: [floor], activeRegions: [region], intervalMinutes: 5,
                                       speedMultiplier: 2)
        let fast = schedule.passes[floor.id]!
        check(abs(fast.x - initial.x - 320 * tick) < 1e-8
              && abs(fast.travelled - initial.travelled - 320 * tick) < 1e-8 && changed.count == 1,
              "changing speed during a pass advances its current position without a restart")
        let slow = schedule.advance(delta: tick, surfaces: [floor], activeRegions: [region], intervalMinutes: 5,
                                    speedMultiplier: 0.5)
        check(abs(schedule.passes[floor.id]!.x - fast.x - 80 * tick) < 1e-8
              && slow[0].fromX <= changed[0].toX && slow[0].toX > changed[0].toX,
              "slowing mid-pass preserves cumulative swept coverage")
        let beforePause = schedule.passes[floor.id]!.x
        _ = schedule.advance(delta: tick, surfaces: [floor], activeRegions: [], intervalMinutes: 5, speedMultiplier: 2)
        check(schedule.passes[floor.id]!.x == beforePause, "speed changes cannot advance an inactive display")

        var cadence = SnowplowSchedule()
        for tickIndex in 0..<(300 * 16 - 1) {
            _ = cadence.advance(delta: tick, surfaces: [floor], activeRegions: [region], intervalMinutes: 5,
                                speedMultiplier: tickIndex.isMultiple(of: 2) ? 0.5 : 2)
        }
        check(cadence.passes.isEmpty, "speed changes do not start a scheduled pass early")
        check(!cadence.advance(delta: tick, surfaces: [floor], activeRegions: [region], intervalMinutes: 5,
                               speedMultiplier: 2).isEmpty,
              "continuous speed changes do not reset the automatic interval")
    }

    private static func checkNoSweeps(_ sweeps: [SnowplowSweep]) {
        guard sweeps.isEmpty else { fatalError("Snowplow advanced during hidden/paused time or before its boundary") }
    }
}
