import Foundation
import CoreGraphics

@main
enum SnowplowCleanupTests {
    static func main() {
        checkPass(speed: 1.25, delta: 1.0 / 60)
        checkPass(speed: 2, delta: 0.1)
    }

    private static func checkPass(speed: Double, delta: TimeInterval) {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        var floor = SnowSurface(id: "cleanup-floor", frame: CGRect(x: 0, y: 0, width: 600, height: 0), kind: .floor)
        let roof = SnowSurface(id: "untouched-roof", frame: CGRect(x: 30, y: 120, width: 200, height: 40), kind: .window)
        let world = SnowWorld(seed: 9)
        world.syncSurfaces([roof, floor]); world.prune(to: [region])
        let weather = SnowWeather(intensity: .blizzard)
        for _ in 0..<600 { world.step(delta: 0.1, weather: weather, activeRegions: [region]) }
        let hiddenIndex = 75
        let hiddenHeight = world.drifts[floor.id]!.heights[hiddenIndex]
        floor.occluders = [CGRect(x: 260, y: 0, width: 80, height: 60)]
        world.syncSurfaces([roof, floor])
        let roofBefore = world.drifts[roof.id]!.heights.reduce(0, +)
        var schedule = SnowplowSchedule(); schedule.requestSweep()
        var checkedColumns = 0
        var lastBucket: CGFloat = -100
        for frame in 0..<400 {
            world.step(delta: delta, weather: weather, activeRegions: [region])
            let sweeps = schedule.advance(delta: delta, surfaces: world.surfaces,
                                           activeRegions: [region], intervalMinutes: 10, speedMultiplier: speed)
            for sweep in sweeps {
                lastBucket = sweep.toX
                world.sweepFloor(surfaceID: sweep.surfaceID, fromX: sweep.fromX, toX: sweep.toX)
            }
            let heights = world.drifts[floor.id]!.heights
            for index in heights.indices {
                let x = min(CGFloat(index) * SnowDrift.spacing, floor.frame.width)
                // Occluder boundary columns are conservatively retained by the model.
                guard x <= lastBucket,
                      !floor.occluders.contains(where: { x >= $0.minX && x <= $0.maxX }) else { continue }
                guard abs(heights[index]) < 1e-8 else {
                    fputs("FAIL: snow returned behind bucket at frame \(frame), x=\(x), height=\(heights[index]), bucket=\(lastBucket)\n", stderr)
                    exit(1)
                }
                checkedColumns += 1
            }
            if frame > 0 && schedule.passes.isEmpty { break }
        }
        precondition(checkedColumns > 1000 && schedule.passes.isEmpty, "A complete pass must clean the entire exposed floor")
        precondition(world.drifts[floor.id]!.heights[hiddenIndex] >= hiddenHeight - 1e-8, "Hidden snow is retained")
        precondition(world.drifts[roof.id]!.heights.reduce(0, +) >= roofBefore - 1e-8, "Other supports are not cleaned")
        for _ in 0..<60 { world.step(delta: 1.0 / 60, weather: weather, activeRegions: [region]) }
        precondition(world.drifts[floor.id]!.heights[10] > 0.05, "Ordinary snowfall resumes after the pass")
        print("Snowplow cleanup \(speed)× dt=\(delta): \(checkedColumns) swept columns stay clear during live simulation; hidden snow/roof retained; snowfall resumes")
    }
}
