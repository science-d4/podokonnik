// Compares scalar packets with actual SpriteKit node properties; no view or screen capture.
// swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift \
//   Tests/ParticleBackendTests.swift -o /private/tmp/snezhno-particle-backend-tests
// For pre-change trajectory evidence, compile the previous SnowScene snapshot with
// -D PARTICLE_REFERENCE. The shared fixture prints the same deterministic node digest.
import AppKit
import SpriteKit

@main
enum ParticleBackendTests {
    private static var assertions = 0
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else {
            fputs("Particle backend failed: \(message) [assertion \(assertions)]\n", stderr)
            exit(1)
        }
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let world = SnowWorld(seed: 91)
        var roof = SnowSurface(id: "roof", frame: CGRect(x: 140, y: 200, width: 1200, height: 500), kind: .window, topInset: 16)
        let floor = SnowSurface(id: "floor", frame: CGRect(x: 0, y: 0, width: frame.width, height: 0), kind: .floor)
        world.syncSurfaces([roof, floor])
        world.prune(to: [frame])
        for _ in 0..<2_400 {
            world.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .steady), activeRegions: [frame])
        }
        let fallback = SnowScene(world: world, displayFrame: frame)
        var digest: UInt64 = 14_695_981_039_346_656_037
        var sampledFrames = 0
        #if !PARTICLE_REFERENCE
        let scalar = SnowScene(world: world, displayFrame: frame)
        let textures = scalar.particleTextureImages
        check(textures.count == 2 && textures.allSatisfy { $0.width == 32 && $0.height == 32 }, "both original particle textures are exported")
        check(MemoryLayout<SnowParticleInstance>.stride == 32, "GPU instance layout is 32 bytes")
        var callbacks = 0
        var tickBeingTested = 0
        scalar.onParticles = { packet in
            callbacks += 1
            check(packet.count == sprites(fallback).filter { !$0.isHidden }.count, "scalar packet matches visible SpriteKit particles every frame")
            if tickBeingTested.isMultiple(of: 47) || tickBeingTested >= 6_000 && tickBeingTested <= 6_060 {
                let expected = spriteInstances(fallback).sorted(by: ordered)
                let actual = packet.sorted(by: ordered)
                check(actual.count == expected.count, "packet contains every visible fallback node")
                for (left, right) in zip(actual, expected) {
                    check(left.geometry == right.geometry && left.appearance == right.appearance,
                          "position, rotation, size, alpha and crystal kind match SpriteKit exactly")
                }
                check(sprites(scalar).isEmpty, "scalar mode allocates no particle nodes")
            }
        }
        #endif
        for tick in 0..<7_200 {
            var weather = SnowWeather(intensity: tick < 6_500 ? .steady : .blizzard,
                                      wind: CGVector(dx: sin(Double(tick) / 600) * 0.8, dy: cos(Double(tick) / 400) * 0.3))
            weather.lowPower = tick >= 6_000 && tick < 6_300
            weather.reducedMotion = tick >= 6_300 && tick < 6_600
            if tick == 2_000 || tick == 4_000 {
                roof.occluders = tick == 2_000 ? [CGRect(x: 0, y: 650, width: 2560, height: 150)] : []
                world.syncSurfaces([roof, floor])
            }
            if tick == 5_000 {
                fallback.resetAnimationClock()
                #if !PARTICLE_REFERENCE
                scalar.resetAnimationClock()
                #endif
            }
            if tick == 6_800 {
                let movedFrame = CGRect(x: -1280, y: -100, width: frame.width, height: frame.height)
                fallback.refreshGeometry(frame: movedFrame)
                #if !PARTICLE_REFERENCE
                scalar.refreshGeometry(frame: movedFrame)
                #endif
            }
            let time = Double(tick) / 60 + (tick >= 5_000 ? 100_000 : 0)
            fallback.weather = weather
            fallback.update(time)
            #if !PARTICLE_REFERENCE
            scalar.weather = weather
            tickBeingTested = tick
            scalar.update(time)
            #endif
            if tick.isMultiple(of: 47) {
                sampledFrames += 1
                // Geometry/alpha digest also works with the pre-change renderer, whose
                // nodes did not have diagnostic names. Texture choice is checked above.
                for value in spriteInstances(fallback).sorted(by: ordered) {
                    for bits in [value.geometry.x.bitPattern, value.geometry.y.bitPattern,
                                 value.geometry.z.bitPattern, value.geometry.w.bitPattern, value.appearance.x.bitPattern] {
                        digest = (digest ^ UInt64(bits)) &* 1_099_511_628_211
                    }
                }
            }
        }
        #if !PARTICLE_REFERENCE
        check(callbacks == 7_200, "one packet is published per update, including the initial empty frame")
        #endif
        print("Particle backend: \(assertions) assertions passed; samples=\(sampledFrames) trajectoryDigest=\(String(digest, radix: 16))")
    }

    private static func sprites(_ scene: SnowScene) -> [SKSpriteNode] {
        scene.children.flatMap(\.children).compactMap { $0 as? SKSpriteNode }
    }

    private static func spriteInstances(_ scene: SnowScene) -> [SnowParticleInstance] {
        sprites(scene).filter { !$0.isHidden }.map { node in
            SnowParticleInstance(geometry: SIMD4(Float(node.position.x), Float(node.position.y), Float(node.size.width), Float(node.zRotation)),
                                 appearance: SIMD4(Float(node.alpha), node.name == "snowflake.crystal" ? 1 : 0, 0, 0))
        }
    }

    private static func ordered(_ left: SnowParticleInstance, _ right: SnowParticleInstance) -> Bool {
        if left.geometry.x != right.geometry.x { return left.geometry.x < right.geometry.x }
        if left.geometry.y != right.geometry.y { return left.geometry.y < right.geometry.y }
        return left.geometry.w < right.geometry.w
    }
}
