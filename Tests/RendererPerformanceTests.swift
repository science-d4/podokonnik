// Synthetic CPU microbenchmark for scene.update only. It does not measure GPU rendering,
// presentation FPS or the specification's live application CPU budget.
// swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift \
//   Tests/RendererPerformanceTests.swift -o /private/tmp/snezhno-renderer-perf
import AppKit
import SpriteKit

@main
enum RendererPerformanceTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let world = SnowWorld(seed: 91)
        var surfaces = (0..<10).map { index in
            SnowSurface(id: "roof-\(index)", frame: CGRect(x: CGFloat(index * 10), y: 100, width: 2400, height: 1320),
                        kind: .window, occluders: [CGRect(x: 0, y: 1410, width: 2560, height: 80)], topInset: 16)
        }
        surfaces.append(SnowSurface(id: "floor", frame: CGRect(x: 0, y: 0, width: frame.width, height: 0), kind: .floor))
        world.syncSurfaces(surfaces)
        world.prune(to: [frame])
        let scene = SnowScene(world: world, displayFrame: frame)
        for tick in 0..<6_000 { scene.update(Double(tick) / 60) }
        let initialCount = scene.renderingStatistics.particles
        var before = timespec()
        var after = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &before)
        for tick in 6_000..<7_800 { scene.update(Double(tick) / 60) }
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &after)
        let cpuSeconds = Double(after.tv_sec - before.tv_sec) + Double(after.tv_nsec - before.tv_nsec) / 1e9
        let normalCount = scene.renderingStatistics.particles
        let steadyCap = SnowIntensity.steady.particleCap * 3
        precondition(initialCount >= steadyCap - 50 && normalCount >= steadyCap - 50, "benchmark must contain the full steady snow population")
        scene.weather.lowPower = true
        for tick in 7_800..<7_860 { scene.update(Double(tick) / 60) }
        let lowPowerCount = scene.renderingStatistics.particles
        precondition(lowPowerCount <= steadyCap / 2, "low-power retirement finishes within one second")
        scene.resetAnimationClock()
        scene.update(1_000_000)
        precondition(scene.renderingStatistics.particles == lowPowerCount, "resume does not simulate hidden time")
        print("updateCPUSeconds=\(cpuSeconds) timedFrames=1800 normalParticles=\(normalCount) lowPowerParticles=\(lowPowerCount)")
    }
}
