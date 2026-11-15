import Foundation
import CoreGraphics
import Darwin

/// CPU-only benchmark; it deliberately excludes SpriteKit, AppKit and WindowServer.
/// Compile -O -whole-module-optimization with SnowTypes.swift and SnowWorld.swift.
@main
struct CoreBenchmark {
    static func main() {
        let region = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        var supports: [SnowSurface] = []
        for i in 0..<10 {
            let x = CGFloat(i % 3) * 600 + 80
            let top = 220 + CGFloat(i) * 170
            let occluders = [
                CGRect(x: x + 160, y: top - 60, width: 280, height: 95),
                CGRect(x: x + 690, y: top - 100, width: 300, height: 114),
                CGRect(x: x + 1250, y: top - 90, width: 210, height: 96)
            ]
            supports.append(SnowSurface(id: "bench:\(i)", frame: CGRect(x: x, y: top - 160, width: 1600, height: 160), kind: .window, occluders: occluders))
        }
        supports.append(SnowSurface(id: "floor:1", frame: CGRect(x: 0, y: 0, width: 3840, height: 0), kind: .floor))
        var results: [[String: Double]] = []
        var checksum: Double = 0
        for _ in 0..<3 {
            let world = SnowWorld(seed: 123)
            world.syncSurfaces(supports)
            world.prune(to: [region])
            let weather = SnowWeather(intensity: .steady)
            for _ in 0..<200 { world.step(delta: 0.01, weather: weather, activeRegions: [region]) }
            let startWall = ProcessInfo.processInfo.systemUptime
            let startCPU = clock()
            for _ in 0..<6000 { world.step(delta: 0.01, weather: weather, activeRegions: [region]) }
            let cpu = Double(clock() - startCPU) / Double(CLOCKS_PER_SEC)
            let wall = ProcessInfo.processInfo.systemUptime - startWall
            checksum += world.drifts.values.reduce(0) { $0 + Double($1.heights.reduce(0, +)) }
            results.append(["cpuSeconds": cpu, "wallSeconds": wall, "cpuPercentOfOneCoreAt100Hz": cpu / 60 * 100, "microsecondsPerFrame": cpu / 6000 * 1_000_000])
        }
        let report: [String: Any] = ["windows": 10, "occludersPerWindow": 3, "floorWidth": 3840, "windowWidth": 1600,
                                   "updatesPerTrial": 6000, "simulatedSecondsPerTrial": 60,
                                   "trials": results, "checksum": checksum]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
