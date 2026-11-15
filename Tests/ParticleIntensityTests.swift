// Two minutes per mode on a large empty desktop. No SKView, GUI rendering or screen capture.
// The final ten-second averages catch modes converging at a shared population cap.
// swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift \
//   Tests/ParticleIntensityTests.swift -o /private/tmp/snezhno-particle-intensity-tests
import AppKit

@main
enum ParticleIntensityTests {
    static func main() {
        do { try run() }
        catch {
            fputs("Particle intensity regression failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        var means: [Double] = []
        var visibleMeans: [Double] = []
        var finalCounts: [Int] = []
        var qualityLimitsPassed = true
        for mode in SnowIntensity.allCases {
            let scene = SnowScene(world: SnowWorld(seed: 71), displayFrame: frame)
            scene.weather.intensity = mode
            var tick = 0
            var sampleCount = 0
            var total = 0
            var visibleTotal = 0
            var latestCount = 0
            scene.onParticles = { packet in
                latestCount = packet.count
                if tick >= 6_600 && tick < 7_200 {
                    sampleCount += 1
                    total += packet.count
                    visibleTotal += packet.reduce(0) { count, particle in
                        count + (particle.geometry.x >= 0 && particle.geometry.x < Float(frame.width)
                            && particle.geometry.y >= 0 && particle.geometry.y < Float(frame.height)
                            && particle.appearance.x > 0.05 ? 1 : 0)
                    }
                }
            }
            for value in 0..<7_200 { tick = value; scene.update(Double(tick) / 60) }
            guard sampleCount == 600 else { throw failure("missing steady-state samples") }
            means.append(Double(total) / Double(sampleCount))
            visibleMeans.append(Double(visibleTotal) / Double(sampleCount))
            finalCounts.append(latestCount)
            qualityLimitsPassed = qualityLimitsPassed && latestCount <= mode.particleCap * 3
            scene.weather.lowPower = true
            for value in 7_200..<7_260 { tick = value; scene.update(Double(tick) / 60) }
            qualityLimitsPassed = qualityLimitsPassed && latestCount <= Int(Double(mode.particleCap) * 3 * 0.5)
            scene.weather.reducedMotion = true
            for value in 7_260..<7_320 { tick = value; scene.update(Double(tick) / 60) }
            qualityLimitsPassed = qualityLimitsPassed && latestCount <= Int(Double(mode.particleCap) * 3 * 0.5 * 0.4)
        }
        let distinct = means[1] > means[0] * 1.25 && means[2] > means[1] * 1.25
            && visibleMeans[1] > visibleMeans[0] * 1.25 && visibleMeans[2] > visibleMeans[1] * 1.25
        let report: [String: Any] = ["passed": distinct && qualityLimitsPassed,
                                     "modeOrder": ["light", "steady", "blizzard"],
                                     "secondsPerMode": 120, "sampledFinalSeconds": 10,
                                     "meanParticles": means, "meanVisibleParticles": visibleMeans,
                                     "finalParticles": finalCounts, "distinctPopulationAndVisibleDensity": distinct,
                                     "qualityMultipliersAndRetirementPassed": qualityLimitsPassed,
                                     "scope": "long simulation; no GUI or live CPU acceptance"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(data: data, encoding: .utf8)!)
        guard distinct else { throw failure("steady and blizzard must remain visibly distinct after reaching their population limits") }
        guard qualityLimitsPassed else { throw failure("per-mode caps or existing quality multipliers were not respected") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Snezhno.IntensityRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
