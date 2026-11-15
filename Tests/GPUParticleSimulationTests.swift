import AppKit
import MetalKit
import SpriteKit

private struct GPUSimulationFailure: Error, CustomStringConvertible {
    let description: String
}
@main
enum GPUParticleSimulationTests {
    private static var checks = 0
    private static let size = CGSize(width: 640, height: 420)
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw GPUSimulationFailure(description: message) }
    }
    private static func flake(_ id: UInt32, x: Float, y: Float, side: Float = 4) -> SnowGPUFlake {
        SnowGPUFlake(geometry: SIMD4(x, y, side, 0.23), dynamics: SIMD4(43, 0.7, 1.1, 1.234567),
            style: SIMD4(12, 0.13, 0.8, 2), lifecycle: SIMD4(-1, 1, 1, 0),
            appearance: SIMD4(0.8, 0, 0, 0), identity: SIMD4(id, 1, 1, 0))
    }
    private final class Harness {
        let simulation: SnowGPUParticleSimulation
        let batch: ParticleBatchRenderer
        let target: MTLTexture
        let scene: SnowScene
        init(device: MTLDevice, scene: SnowScene, seeds: [SnowGPUFlake] = []) throws {
            self.scene = scene
            simulation = try SnowGPUParticleSimulation(device: device, seedParticles: seeds, diagnosticSnapshots: true)
            batch = try ParticleBatchRenderer(device: device, images: scene.particleTextureImages)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 420, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let target = device.makeTexture(descriptor: descriptor) else { throw GPUSimulationFailure(description: "No target") }
            self.target = target
        }
        func step(_ frame: SnowGPUParticleFrame) throws -> SnowGPUParticleSimulation.DebugSnapshot {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let command = batch.render([], viewport: size, pass: pass, simulation: simulation, simulationFrame: frame)
            else { throw GPUSimulationFailure(description: "GPU submission failed") }
            // A deterministic test barrier, never used by the product's frame path.
            command.waitUntilCompleted()
            try require(command.status == .completed, "Compute and indirect draw complete: \(command.error?.localizedDescription ?? "unknown")")
            guard let snapshot = simulation.debugSnapshot(completedSlot: simulation.lastEncodedSlot) else {
                throw GPUSimulationFailure(description: "Missing owned diagnostic snapshot")
            }
            try require(snapshot.alive == snapshot.states.filter { $0.identity.y != 0 }.count, "GPU statistics reflect surviving states")
            try require(snapshot.instances == snapshot.states.filter { $0.identity.y != 0 && $0.identity.z != 0 }.count,
                        "Indirect draw contains exactly visible survivors, including empty frames")
            return snapshot
        }
    }
    private static func compare(_ actual: SnowGPUParticleSimulation.DebugSnapshot, _ expected: [SnowGPUFlake], tick: Int) throws {
        let states = Dictionary(uniqueKeysWithValues: actual.states.filter { $0.identity.y != 0 }.map { ($0.identity.x, $0) })
        try require(Set(states.keys) == Set(expected.map { $0.identity.x }), "Same surviving IDs at tick \(tick): GPU \(states.count), CPU \(expected.count)")
        for reference in expected {
            guard let value = states[reference.identity.x] else { continue }
            let error = hypot(value.geometry.x - reference.geometry.x, value.geometry.y - reference.geometry.y)
            try require(error < 0.055, "Trajectory tolerance at tick \(tick), id \(reference.identity.x): \(error) pt")
            try require(abs(value.geometry.w - reference.geometry.w) < 0.001, "Rotation is preserved")
            try require(abs(value.appearance.x * value.lifecycle.y - reference.appearance.x * reference.lifecycle.y) < 0.001,
                        "Focus fade/reversal and lifetime alpha match CPU")
            try require(value.identity.z == reference.identity.z, "Whole-quad hard/wide visibility matches CPU at tick \(tick), id \(reference.identity.x)")
        }
    }
    private static func replay(device: MTLDevice) throws {
        let display = CGRect(x: -640, y: -100, width: size.width, height: size.height)
        let world = SnowWorld(seed: 97)
        let floor = SnowSurface(id: "floor", frame: CGRect(x: -640, y: -100, width: 640, height: 0), kind: .floor)
        var roof = SnowSurface(id: "roof", frame: CGRect(x: -560, y: 40, width: 260, height: 70), kind: .window, topInset: 16)
        roof.occluders = [CGRect(x: -420, y: 110, width: 1.1, height: 70)]
        var wide = SnowSurface(id: "wide", frame: CGRect(x: -640, y: 120, width: 640, height: 180), kind: .window)
        world.syncSurfaces([roof, floor]); world.prune(to: [display])
        for _ in 0..<200 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [display]) }
        let cpu = SnowScene(world: world, displayFrame: display), gpu = SnowScene(world: world, displayFrame: display)
        cpu.onParticles = { _ in }
        let seeds = [flake(1, x: 96, y: 230), flake(2, x: 220.5, y: 230), flake(3, x: 160, y: 350),
                     flake(4, x: 500, y: 310), flake(5, x: 83, y: 218), flake(6, x: 610, y: 2)]
        cpu.seedParticleReference(seeds)
        let harness = try Harness(device: device, scene: gpu, seeds: seeds)
        var frame: SnowGPUParticleFrame?
        gpu.onGPUParticles = { frame = $0 }
        try require(gpu.particleSimulationBackend == "gpu" && cpu.particleSimulationBackend == "cpu", "Replay explicitly uses different simulation backends")
        var time: TimeInterval = 0
        for tick in 0..<900 {
            if tick == 50 { world.syncSurfaces([roof, wide, floor]) }
            if tick == 100 || tick == 107 { wide.suppressesSnowfall = true; world.syncSurfaces([roof, wide, floor]) }
            if tick == 105 || tick == 112 { wide.suppressesSnowfall = false; world.syncSurfaces([roof, wide, floor]) }
            if tick == 160 { roof.frame.origin.x += 45; world.syncSurfaces([roof, wide, floor]) }
            if tick == 200 { world.syncSurfaces([wide, floor]) }
            if tick == 520 { cpu.resetAnimationClock(); gpu.resetAnimationClock(); time += 100_000 }
            let weather = SnowWeather(intensity: .blizzard,
                wind: CGVector(dx: sin(Double(tick) / 160) * 0.3, dy: 0.2),
                reducedMotion: tick >= 650 && tick < 740, lowPower: tick >= 650 && tick < 740)
            cpu.weather = weather; gpu.weather = weather
            cpu.update(time); gpu.update(time)
            guard let frame else { throw GPUSimulationFailure(description: "No geometry frame") }
            let result = try harness.step(frame)
            try compare(result, cpu.referenceParticleStates, tick: tick)
            try require(gpu.referenceParticleStates.isEmpty, "GPU scene performs no shadow flake simulation")
            time += 1.0 / 60
        }
        print("PASS CPU/GPU replay: birth IDs, moving masks, narrow/wide overlap, fade/reversal, exact roofs, wind, retirement, pause")
    }
    private static func longClockAndFailures(device: MTLDevice) throws {
        let world = SnowWorld(), scene = SnowScene(world: world, displayFrame: CGRect(origin: .zero, size: size))
        let seed = flake(1, x: 100, y: 350)
        let harness = try Harness(device: device, scene: scene, seeds: [seed])
        let empty = SnowGPUParticleGeometry(solid: [], wide: [], roofs: [], points: [], occluders: [])
        var reference = seed
        for index in 0..<120 {
            let time = 4_194_304.0 + Double(index) / 60 // Float(time) alone cannot represent a frame here.
            let delta = index == 0 || index == 61 ? 0.0 : 1.0 / 60
            let frame = SnowGPUParticleFrame(delta: delta, time: time, rate: 0, wind: .zero, size: size,
                                              cap: 1, reducedMotion: false, fades: false, geometry: empty)
            let result = try harness.step(frame)
            let velocityX = sin(time * Double(reference.dynamics.w) + Double(reference.dynamics.z)) * Double(reference.style.x)
            reference.geometry.x = Float(Double(reference.geometry.x) + velocityX * delta)
            reference.geometry.y = Float(Double(reference.geometry.y) - Double(reference.dynamics.x) * delta)
            guard let actual = result.states.first else { throw GPUSimulationFailure(description: "Seed vanished") }
            try require(hypot(actual.geometry.x - reference.geometry.x, actual.geometry.y - reference.geometry.y) < 0.002,
                        "Split clock preserves movement after weeks and zero-delta resume")
        }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = harness.target
        let invalid = SnowGPUParticleFrame(delta: .nan, time: 0, rate: 0, wind: .zero, size: size, cap: 1,
                                            reducedMotion: false, fades: false, geometry: empty)
        try require(harness.batch.render([], viewport: size, pass: pass, simulation: harness.simulation, simulationFrame: invalid) == nil,
                    "Invalid compute input is rejected before commit")
        let valid = SnowGPUParticleFrame(delta: 0, time: 0, rate: 0, wind: .zero, size: size, cap: 1,
                                          reducedMotion: false, fades: false, geometry: empty)
        _ = try harness.step(valid)
        let blankHarness = try Harness(device: device, scene: scene)
        let blank = try blankHarness.step(valid)
        try require(blank.alive == 0 && blank.instances == 0, "An empty GPU frame is valid")
        let recovery = try Harness(device: device, scene: scene, seeds: [seed])
        func recoveryFrame(_ time: Double, _ delta: Double, cap: Int = 1) -> SnowGPUParticleFrame {
            SnowGPUParticleFrame(delta: delta, time: time, rate: 0, wind: .zero, size: size, cap: cap,
                                 reducedMotion: true, fades: false, geometry: empty)
        }
        _ = try recovery.step(recoveryFrame(0, 0))
        try require(recovery.batch.render([], viewport: size, pass: pass, simulation: recovery.simulation,
                    simulationFrame: recoveryFrame(1.0 / 60, 1.0 / 60, cap: 8193)) == nil, "Rejected step does not commit state")
        let recovered = try recovery.step(recoveryFrame(2.0 / 60, 1.0 / 60))
        let recoveredY = recovered.states[0].geometry.y
        try require(abs(recoveredY - (350 - 43 * 0.55 / 30)) < 0.0001, "Next submission restores only the missing bounded step")
        // Even a zero-delta resume frame that fails before encoding cancels debt.
        try require(recovery.batch.render([], viewport: .zero, pass: pass, simulation: recovery.simulation,
                    simulationFrame: recoveryFrame(0.2, 0)) == nil, "Resume frame can fail before encoder acquisition")
        let resumed = try recovery.step(recoveryFrame(0.2 + 1.0 / 60, 1.0 / 60))
        try require(abs(resumed.states[0].geometry.y - (recoveredY - 43 * 0.55 / 60)) < 0.0001,
                    "Rejected zero-delta resume still discards pre-pause debt")
        let stalled = try recovery.step(recoveryFrame(10, 1.0 / 60))
        try require(abs(stalled.states[0].geometry.y - (resumed.states[0].geometry.y - 43 * 0.55 / 15)) < 0.0001,
                    "Long rejected interval cannot create an unbounded catch-up")
        let slots = ParticleBufferSlots(count: 3)
        let a = slots.acquire()!, b = slots.acquire()!, c = slots.acquire()!
        try require(slots.acquire() == nil, "Three in-flight slots bound the queue without waiting")
        slots.release(b)
        try require(slots.acquire() == b && slots.acquire() == nil, "Out-of-order completion can release only its own slot")
        slots.release(a); slots.release(c); slots.release(b)
        let hostScene = SnowScene(world: world, displayFrame: CGRect(origin: .zero, size: size))
        guard let host = UnifiedSnowView(frame: CGRect(origin: .zero, size: size), scene: hostScene, maximumFPS: 60, shouldRender: { _ in true }) else {
            throw GPUSimulationFailure(description: "Unified host unavailable")
        }
        try require(host.usesGPUSimulation && hostScene.particleSimulationBackend == "gpu", "Production defaults to real GPU simulation")
        host.invalidate()
        print("PASS long clock, zero-delta retention, empty frame, invalid input recovery, slots, production backend")
    }
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard let device = MTLCreateSystemDefaultDevice() else { throw GPUSimulationFailure(description: "Metal unavailable") }
        try replay(device: device)
        try longClockAndFailures(device: device)
        print("GPU particle simulation: \(checks) checks passed")
    }
}
