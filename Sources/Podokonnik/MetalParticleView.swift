import AppKit
import MetalKit

/// A passive particle layer. The existing scene owns simulation and the frame clock.
final class MetalParticleView: MTKView, MTKViewDelegate {
    private let batch: ParticleBatchRenderer
    private var pending: [SnowParticleInstance] = []
    var onPresented: ((TimeInterval) -> Void)?
    var onFailure: ((String) -> Void)?
    private var failureLatched = false
    private var consecutiveFailedSubmissions = 0
    private(set) var submittedFrames = 0
    var recordsPresentation = false
    private(set) var presentationIntervals: [TimeInterval] = []
    private var lastPresentation: TimeInterval?

    init?(frame: CGRect, images: [CGImage]) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let batch = try? ParticleBatchRenderer(device: device, images: images) else { return nil }
        self.batch = batch
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        layer?.isOpaque = false
        delegate = self
        autoresizingMask = [.width, .height]
    }

    required init(coder: NSCoder) { fatalError("MetalParticleView is created programmatically") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func submit(_ particles: [SnowParticleInstance]) {
        guard !failureLatched else { return }
        pending = particles
        draw()
        // draw() synchronously encodes/copies the instances. Do not retain the scene's
        // reusable array across frames and trigger copy-on-write on its next update.
        pending = []
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func resetPresentationClock() {
        lastPresentation = nil
        consecutiveFailedSubmissions = 0
    }

    func draw(in view: MTKView) {
        guard !failureLatched else { return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else {
            recordFailedSubmission()
            return
        }
        let callback: ((TimeInterval) -> Void)? = recordsPresentation ? { [weak self] time in
            guard let self else { return }
            if let previous = self.lastPresentation, time > previous, self.presentationIntervals.count < 1_000_000 {
                self.presentationIntervals.append(time - previous)
            }
            self.lastPresentation = time
            self.onPresented?(time)
        } : onPresented
        if batch.render(pending, viewport: bounds.size, pass: pass, drawable: drawable,
                        onPresented: callback,
                        onFailure: { [weak self] message in self?.reportFailure(message) }) != nil {
            submittedFrames += 1
            consecutiveFailedSubmissions = 0
        } else { recordFailedSubmission() }
    }

    private func recordFailedSubmission() {
        guard window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor else {
            consecutiveFailedSubmissions = 0
            return
        }
        consecutiveFailedSubmissions += 1
        guard consecutiveFailedSubmissions >= 120 else { return }
        reportFailure("Не удалось подготовить кадр снега. Перезапустите приложение.")
    }

    private func reportFailure(_ message: String) {
        guard !failureLatched else { return }
        failureLatched = true
        pending = []
        consecutiveFailedSubmissions = 0
        onFailure?(message)
    }
}

/// A slot is reusable only after its own completion has copied diagnostic data.
/// Completion handlers may run in a different order from submission callbacks.
final class ParticleBufferSlots {
    private let lock = NSLock()
    private var busy: [Bool]
    private var next = 0
    init(count: Int) { busy = Array(repeating: false, count: count) }
    func acquire() -> Int? {
        lock.lock(); defer { lock.unlock() }
        for offset in busy.indices {
            let index = (next + offset) % busy.count
            if !busy[index] { busy[index] = true; next = (index + 1) % busy.count; return index }
        }
        return nil
    }
    func release(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        precondition(busy.indices.contains(index) && busy[index])
        busy[index] = false
    }
}

/// Two textures, one instanced draw, bounded buffers. Used by the view and GPU tests.
final class ParticleBatchRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textures: [MTLTexture]
    private let frameSlots = ParticleBufferSlots(count: 3)
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private let maximumInstances = 8_192

    init(device: MTLDevice, images: [CGImage]) throws {
        self.device = device
        guard images.count == 2, let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Snezhno.ParticleRenderer", code: 1)
        }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "snowVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "snowFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        textures = try images.map {
            try Self.texture(from: $0, device: device)
        }
        precondition(MemoryLayout<SnowParticleInstance>.stride == 32)
    }

    private static func texture(from image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = image.width, height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { throw NSError(domain: "Snezhno.ParticleRenderer", code: 2) }
        // Define premultiplication explicitly; the pipeline uses source factor one.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    @discardableResult
    func render(_ particles: [SnowParticleInstance], viewport: CGSize,
                pass: MTLRenderPassDescriptor, drawable: MTLDrawable? = nil,
                onPresented: ((TimeInterval) -> Void)? = nil,
                beforeParticles: ((MTLCommandBuffer) -> Void)? = nil,
                presentDirectly: Bool = false,
                onFailure: ((String) -> Void)? = nil,
                simulation: SnowGPUParticleSimulation? = nil,
                simulationFrame: SnowGPUParticleFrame? = nil,
                onStatistics: ((SnowGPUParticleSimulation.Statistics) -> Void)? = nil) -> MTLCommandBuffer? {
        // Observe a scene clock reset even when no slot/encoder can be acquired.
        if simulationFrame?.delta == 0 { simulation?.resetClock() }
        guard viewport.width > 0, viewport.height > 0,
              particles.count <= maximumInstances,
              let slot = frameSlots.acquire() else { return nil }
        var committed = false
        defer { if !committed { frameSlots.release(slot) } }
        guard let command = queue.makeCommandBuffer() else { return nil }
        let submittedSlot = slot
        let buffer: MTLBuffer
        if let simulation {
            guard let frame = simulationFrame, simulation.encode(frame, command: command, slot: slot) else { return nil }
            buffer = simulation.output(slot: slot)
        } else {
            let byteCount = particles.count * MemoryLayout<SnowParticleInstance>.stride
            if buffers[slot] == nil {
                buffers[slot] = device.makeBuffer(length: maximumInstances * 32, options: .storageModeShared)
            }
            guard let allocated = buffers[slot] else { return nil }
            buffer = allocated
            if byteCount > 0 {
                particles.withUnsafeBytes { bytes in
                    buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
                }
            }
        }
        beforeParticles?(command)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if simulation != nil || !particles.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var dimensions = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
            encoder.setVertexBytes(&dimensions, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentTexture(textures[0], index: 0)
            encoder.setFragmentTexture(textures[1], index: 1)
            if let simulation {
                encoder.drawPrimitives(type: .triangle, indirectBuffer: simulation.indirect(slot: slot), indirectBufferOffset: 0)
            } else {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count)
            }
        }
        encoder.endEncoding()
        if let drawable {
            if let onPresented {
                drawable.addPresentedHandler { drawable in
                    let time = drawable.presentedTime
                    guard time > 0 else { return }
                    DispatchQueue.main.async { onPresented(time) }
                }
            }
            if !presentDirectly { command.present(drawable) }
        }
        let frameSlots = self.frameSlots
        command.addCompletedHandler { completed in
            // Read this frame's owned statistics before the slot can be reused.
            let statistics = completed.status == .completed && onStatistics != nil
                ? simulation?.statistics(completedSlot: submittedSlot) : nil
            frameSlots.release(submittedSlot)
            if let statistics, let onStatistics { DispatchQueue.main.async { onStatistics(statistics) } }
            guard completed.status == .error, let onFailure else { return }
            DispatchQueue.main.async {
                onFailure("Metal не смог отрисовать снег. Перезапустите приложение.")
            }
        }
        command.commit()
        simulation?.didCommit()
        // CAMetalDisplayLink requires presentation to be registered before its CPU
        // deadline, instead of waiting for a command-buffer scheduled callback.
        if presentDirectly { drawable?.present() }
        committed = true
        return command
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Particle { float4 geometry; float4 appearance; };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float opacity;
        uint crystal [[flat]];
    };
    vertex VertexOut snowVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                const device Particle* particles [[buffer(0)]],
                                constant float2& viewport [[buffer(1)]]) {
        constexpr float2 corners[6] = { float2(-0.5,-0.5), float2(0.5,-0.5), float2(-0.5,0.5),
                                        float2(-0.5,0.5), float2(0.5,-0.5), float2(0.5,0.5) };
        Particle particle = particles[instanceID];
        float2 corner = corners[vertexID];
        float sine = sin(particle.geometry.w), cosine = cos(particle.geometry.w);
        float2 rotated = float2(corner.x * cosine - corner.y * sine,
                                corner.x * sine + corner.y * cosine) * particle.geometry.z;
        float2 point = particle.geometry.xy + rotated;
        VertexOut result;
        result.position = float4(point / viewport * 2.0 - 1.0, 0.0, 1.0);
        result.uv = float2(corner.x + 0.5, 0.5 - corner.y);
        result.opacity = particle.appearance.x;
        result.crystal = uint(particle.appearance.y);
        return result;
    }
    fragment float4 snowFragment(VertexOut input [[stage_in]],
                                  texture2d<float> roundTexture [[texture(0)]],
                                  texture2d<float> crystalTexture [[texture(1)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 texel = input.crystal == 0 ? roundTexture.sample(linearSampler, input.uv)
                                        : crystalTexture.sample(linearSampler, input.uv);
        return texel * input.opacity;
    }
    """
}

/// GPU owns particle lifetime and motion. CPU supplies immutable geometry and a
/// small frame description; completion statistics never drive the simulation.
final class SnowGPUParticleSimulation {
    static let capacity = 8_192
    private struct Parameters {
        var clock: SIMD4<Float>
        var weather: SIMD4<Float>
        var policy: SIMD4<Float>
        var counts: SIMD4<UInt32>
        var bootstrap: SIMD4<UInt32>
        var precision: SIMD4<Float> // residuals for delta and rate; CPU Double policy remains exact
    }
    private final class Slot {
        let output: MTLBuffer
        let indirect: MTLBuffer
        let parameters: MTLBuffer
        let debug: MTLBuffer?
        var solid: MTLBuffer?
        var wide: MTLBuffer?
        var roofs: MTLBuffer?
        var points: MTLBuffer?
        var occluders: MTLBuffer?
        var geometry: SnowGPUParticleGeometry?
        init(device: MTLDevice, diagnostics: Bool) throws {
            guard let output = device.makeBuffer(length: capacity * 32, options: .storageModePrivate),
                  let indirect = device.makeBuffer(length: 32, options: .storageModeShared),
                  let parameters = device.makeBuffer(length: MemoryLayout<Parameters>.stride, options: .storageModeShared)
            else { throw Failure.allocation }
            self.output = output; self.indirect = indirect; self.parameters = parameters
            if diagnostics {
                guard let debug = device.makeBuffer(length: capacity * MemoryLayout<SnowGPUFlake>.stride,
                                                    options: .storageModeShared) else { throw Failure.allocation }
                self.debug = debug
            } else { debug = nil }
        }
    }
    enum Failure: Error { case allocation, shader }
    struct Statistics { let alive: Int; let visible: Int }
    struct DebugSnapshot { let states: [SnowGPUFlake]; let instances: Int; let alive: Int }
    private let device: MTLDevice
    private let service: MTLComputePipelineState
    private let advance: MTLComputePipelineState
    private let state: MTLBuffer
    private let control: MTLBuffer
    private let seedBuffer: MTLBuffer?
    private let seedCount: Int
    private let seedID: UInt32
    private let slots: [Slot]
    private var needsReset = true
    private var lastCommittedTime: TimeInterval?
    private var encodedTime: TimeInterval = 0
    private(set) var lastEncodedSlot = 0

    init(device: MTLDevice, seedParticles: [SnowGPUFlake] = [], diagnosticSnapshots: Bool = false) throws {
        self.device = device
        guard seedParticles.count <= Self.capacity else { throw Failure.allocation }
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let serviceFunction = library.makeFunction(name: "snowService"),
              let advanceFunction = library.makeFunction(name: "snowAdvance") else { throw Failure.shader }
        service = try device.makeComputePipelineState(function: serviceFunction)
        advance = try device.makeComputePipelineState(function: advanceFunction)
        guard let state = device.makeBuffer(length: Self.capacity * MemoryLayout<SnowGPUFlake>.stride,
                                             options: .storageModePrivate),
              let control = device.makeBuffer(length: 32, options: .storageModeShared) else { throw Failure.allocation }
        // A first-command failure must leave a bounded empty control block for
        // already queued work. Production never reads this shared block back.
        control.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        self.state = state; self.control = control
        seedCount = seedParticles.count; seedID = seedParticles.map { $0.identity.x }.max() ?? 0
        if seedParticles.isEmpty { seedBuffer = nil }
        else {
            seedBuffer = seedParticles.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            guard seedBuffer != nil else { throw Failure.allocation }
        }
        slots = try (0..<3).map { _ in try Slot(device: device, diagnostics: diagnosticSnapshots) }
        precondition(MemoryLayout<SnowGPUFlake>.stride == 96 && MemoryLayout<SnowGPURoof>.stride == 32)
    }

    private func upload<T>(_ values: [T], to buffer: inout MTLBuffer?) -> Bool {
        let bytes = values.count * MemoryLayout<T>.stride
        guard bytes <= 16 * 1_048_576 else { return false }
        let length = max(16, bytes)
        if buffer == nil || buffer!.length < length { buffer = device.makeBuffer(length: length, options: .storageModeShared) }
        guard let buffer else { return false }
        if bytes > 0 { values.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) } }
        return true
    }

    /// Caller owns the triple-buffer slot until GPU completion. All dependent
    /// compute/render encoders use the same ordered command queue and tracked buffers.
    func encode(_ frame: SnowGPUParticleFrame, command: MTLCommandBuffer, slot index: Int) -> Bool {
        guard (0..<slots.count).contains(index), frame.cap >= 0, frame.cap <= Self.capacity,
              frame.delta.isFinite, frame.time.isFinite, frame.size.width > 0, frame.size.height > 0 else { return false }
        let slot = slots[index], geometry = frame.geometry
        if slot.geometry !== geometry {
            guard upload(geometry.solid, to: &slot.solid), upload(geometry.wide, to: &slot.wide),
                  upload(geometry.roofs, to: &slot.roofs), upload(geometry.points, to: &slot.points),
                  upload(geometry.occluders, to: &slot.occluders) else { return false }
            slot.geometry = geometry
        }
        let hi = Float(frame.time)
        // A skipped submission must not slow the retained simulation indefinitely.
        // Recover only a bounded step; an explicit clock reset/pause has delta zero.
        let elapsed = frame.time - (lastCommittedTime ?? (frame.time - frame.delta))
        let delta = frame.delta == 0 ? 0 : min(1.0 / 15, elapsed > frame.delta + 1e-9 ? elapsed : frame.delta)
        var parameters = Parameters(clock: SIMD4(Float(delta), hi, Float(frame.time - Double(hi)), Float(frame.rate)),
            weather: SIMD4(Float(frame.wind.dx), Float(frame.wind.dy), Float(frame.size.width), Float(frame.size.height)),
            policy: SIMD4(frame.reducedMotion ? 0.55 : 1, frame.reducedMotion ? 1 : 0, frame.fades ? 1 : 0, needsReset ? 1 : 0),
            counts: SIMD4(UInt32(frame.cap), UInt32(geometry.solid.count), UInt32(geometry.wide.count), UInt32(geometry.roofs.count)),
            bootstrap: SIMD4(UInt32(seedCount), seedID, 0x0D7E9931, 0x45AC63B2),
            precision: SIMD4(Float(delta - Double(Float(delta))), Float(frame.rate - Double(Float(frame.rate))), 0, 0))
        withUnsafeBytes(of: &parameters) { slot.parameters.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if needsReset, let seedBuffer {
            guard let blit = command.makeBlitCommandEncoder() else { return false }
            blit.copy(from: seedBuffer, sourceOffset: 0, to: state, destinationOffset: 0, size: seedBuffer.length)
            blit.endEncoding()
        }
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(service)
        encoder.setBuffer(state, offset: 0, index: 0); encoder.setBuffer(control, offset: 0, index: 1)
        encoder.setBuffer(slot.parameters, offset: 0, index: 2); encoder.setBuffer(slot.indirect, offset: 0, index: 3)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        guard let update = command.makeComputeCommandEncoder() else { return false }
        update.setComputePipelineState(advance)
        for (i, buffer) in [state, control, slot.parameters, slot.roofs!, slot.points!, slot.occluders!,
                             slot.solid!, slot.wide!, slot.output, slot.indirect].enumerated() {
            update.setBuffer(buffer, offset: 0, index: i)
        }
        update.dispatchThreads(MTLSize(width: Self.capacity, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(128, advance.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        update.endEncoding()
        if let debug = slot.debug {
            guard let blit = command.makeBlitCommandEncoder() else { return false }
            blit.copy(from: state, sourceOffset: 0, to: debug, destinationOffset: 0, size: state.length)
            blit.endEncoding()
        }
        lastEncodedSlot = index
        encodedTime = frame.time
        return true
    }
    func resetClock() { lastCommittedTime = nil }
    func didCommit() { needsReset = false; lastCommittedTime = encodedTime }
    func output(slot: Int) -> MTLBuffer { slots[slot].output }
    func indirect(slot: Int) -> MTLBuffer { slots[slot].indirect }
    /// Call only after this slot's GPU work completes and BEFORE releasing it.
    func statistics(completedSlot index: Int) -> Statistics {
        let words = slots[index].indirect.contents().bindMemory(to: UInt32.self, capacity: 8)
        return Statistics(alive: Int(words[4]), visible: Int(words[1]))
    }
    /// Test-only copy, following an explicit completed command. Production has no
    /// debug state buffer and never waits for or reads particle state on the CPU.
    func debugSnapshot(completedSlot index: Int) -> DebugSnapshot? {
        let slot = slots[index]
        guard let debug = slot.debug else { return nil }
        let words = slot.indirect.contents().bindMemory(to: UInt32.self, capacity: 8)
        let count = min(Self.capacity, Int(words[5]))
        let states = Array(UnsafeBufferPointer(start: debug.contents().bindMemory(to: SnowGPUFlake.self, capacity: Self.capacity), count: count))
        return DebugSnapshot(states: states, instances: Int(words[1]), alive: Int(words[4]))
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Flake { float4 geometry, dynamics, style, lifecycle, appearance; uint4 identity; };
    struct Particle { float4 geometry, appearance; };
    struct Control { ulong rng; float emission; uint count; uint nextID; float emissionLow; uint padding1, padding2; };
    struct Parameters { float4 clock, weather, policy; uint4 counts, bootstrap; float4 precision; };
    struct Roof { float4 bounds; uint4 indices; };
    struct Draw { uint vertexCount; atomic_uint instanceCount; uint vertexStart; uint baseInstance;
                  atomic_uint aliveCount; uint stateCount; uint2 padding; };
    float randomSnow(thread ulong& state) {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27;
        return float((state * 2685821657736338717ul) >> 11) * (1.0f / 9007199254740992.0f);
    }
    float2 addPrecise(float2 a, float2 b) {
        float sum = a.x + b.x;
        float v = sum - a.x;
        float error = (a.x - (sum - v)) + (b.x - v) + a.y + b.y;
        float high = sum + error;
        return float2(high, error - (high - sum));
    }
    bool atLeast(float2 value, float threshold) {
        return value.x > threshold || (value.x == threshold && value.y >= 0);
    }
    kernel void snowService(device Flake* flakes [[buffer(0)]], device Control& state [[buffer(1)]],
                            constant Parameters& p [[buffer(2)]], device Draw& draw [[buffer(3)]]) {
        if (p.policy.w > 0.5f) {
            state.rng = (ulong(p.bootstrap.w) << 32) | ulong(p.bootstrap.z);
            state.emission = 0; state.emissionLow = 0; state.count = p.bootstrap.x; state.nextID = p.bootstrap.y;
        }
        state.count = min(state.count, 8192u);
        // Match the CPU's reverse swap-remove, then retire the earliest active flakes.
        for (int i = int(state.count) - 1; i >= 0; --i) {
            if (flakes[i].identity.y == 0) { --state.count; flakes[i] = flakes[state.count]; }
        }
        uint active = 0;
        for (uint i = 0; i < state.count; ++i) if (flakes[i].lifecycle.x < 0) ++active;
        uint excess = active > p.counts.x ? active - p.counts.x : 0;
        for (uint i = 0; i < state.count && excess; ++i) {
            if (flakes[i].lifecycle.x < 0) { flakes[i].lifecycle.x = 0; flakes[i].lifecycle.w = 0; --excess; }
        }
        float product = p.clock.w * p.clock.x;
        float residual = fma(p.clock.w, p.clock.x, -product) + p.clock.w * p.precision.x
                         + p.precision.y * p.clock.x + p.precision.y * p.precision.x;
        float2 emission = addPrecise(float2(state.emission, state.emissionLow), float2(product, residual));
        if (atLeast(emission, 24)) emission = float2(24, 0);
        ulong rng = state.rng;
        while (atLeast(emission, 1) && state.count < p.counts.x && state.count < 8192) {
            float depth = 0.45f + randomSnow(rng) * 0.75f;
            float r = randomSnow(rng); float radius = 0.55f + r * r * 2.0f;
            bool crystal = radius > 1.8f && randomSnow(rng) > 0.5f;
            float2 position = float2(randomSnow(rng) * (p.weather.z + 100) - 50, p.weather.w + 8);
            if (abs(p.weather.x) > 0.1f && randomSnow(rng) < abs(p.weather.x) * 0.35f) {
                position = float2(p.weather.x > 0 ? -8 : p.weather.z + 8, randomSnow(rng) * p.weather.w);
            }
            float rotation = randomSnow(rng) * 6.283185307179586f;
            float phase = randomSnow(rng) * 6.283185307179586f;
            float frequency = 0.6f + randomSnow(rng) * 1.4f;
            float sway = 5 + randomSnow(rng) * 15;
            float spin = (randomSnow(rng) - 0.5f) * 1.3f;
            float opacity = 0.4f + randomSnow(rng) * 0.5f;
            Flake flake;
            flake.geometry = float4(position, radius * 3.2f, rotation);
            flake.dynamics = float4(26 + 54 * depth, depth, phase, frequency);
            flake.style = float4(sway, spin, opacity, 0);
            flake.lifecycle = float4(-1, 1, 0, 0);
            flake.appearance = float4(0, crystal ? 1 : 0, 0, 0);
            flake.identity = uint4(++state.nextID, 1, 1, 0);
            flakes[state.count++] = flake; emission = addPrecise(emission, float2(-1, 0));
        }
        state.rng = rng;
        if (state.count >= p.counts.x && atLeast(emission, 1)) emission = float2(1, 0);
        state.emission = emission.x; state.emissionLow = emission.y;
        draw.vertexCount = 6; draw.vertexStart = 0; draw.baseInstance = 0;
        atomic_store_explicit(&draw.instanceCount, 0, memory_order_relaxed);
        atomic_store_explicit(&draw.aliveCount, 0, memory_order_relaxed);
        draw.stateCount = state.count;
    }
    // Split product/remainder keeps sub-frame phase accuracy after hours of runtime.
    float snowSine(float high, float low, float frequency, float phase) {
        float product = high * frequency;
        float error = fma(high, frequency, -product) + low * frequency + phase;
        float turns = floor(product / 6.283185482025146484375f);
        float reduced = fma(-turns, 6.283185482025146484375f, product)
                        + error + turns * 0.00000017484556000745f;
        return sin(reduced);
    }
    bool inRect(float2 p, float4 r) { return p.x >= r.x && p.x < r.z && p.y >= r.y && p.y < r.w; }
    bool hiddenBy(float4 bounds, const device float4* masks, uint count) {
        for (uint i = 0; i < count; ++i) {
            float4 r = masks[i];
            if (bounds.x <= r.z && bounds.z >= r.x && bounds.y <= r.w && bounds.w >= r.y) return true;
        }
        return false;
    }
    float roofHeight(float x, const device float2* points, uint count) {
        uint lo = 0, hi = count - 1;
        while (lo < hi) {
            uint middle = (lo + hi) / 2;
            float end = (points[middle].x + points[min(middle + 1, count - 1)].x) * 0.5f;
            if (x > end) lo = middle + 1; else hi = middle;
        }
        float2 control = points[lo];
        float2 a = (points[lo > 0 ? lo - 1 : 0] + control) * 0.5f;
        float2 b = (points[min(lo + 1, count - 1)] + control) * 0.5f;
        float ax = a.x - 2 * control.x + b.x, bx = 2 * (control.x - a.x);
        float denominator = bx + sqrt(max(0.0f, bx * bx + 4 * ax * (x - a.x)));
        float t = clamp(denominator > 1e-12f ? 2 * (x - a.x) / denominator : 0.0f, 0.0f, 1.0f);
        float remaining = 1 - t;
        return remaining * remaining * a.y + 2 * remaining * t * control.y + t * t * b.y;
    }
    kernel void snowAdvance(device Flake* flakes [[buffer(0)]], const device Control& state [[buffer(1)]],
                            constant Parameters& p [[buffer(2)]], const device Roof* roofs [[buffer(3)]],
                            const device float2* points [[buffer(4)]], const device float4* occluders [[buffer(5)]],
                            const device float4* solid [[buffer(6)]], const device float4* wide [[buffer(7)]],
                            device Particle* output [[buffer(8)]], device Draw& draw [[buffer(9)]], uint id [[thread_position_in_grid]]) {
        if (id >= state.count) return;
        Flake f = flakes[id]; float dt = p.clock.x; float2 old = f.geometry.xy;
        bool fadingIn = !atLeast(float2(f.style.w, f.appearance.z), 0.5f);
        float2 age = addPrecise(float2(f.style.w, f.appearance.z), float2(dt, p.precision.x));
        f.style.w = age.x; f.appearance.z = age.y;
        if (f.lifecycle.x >= 0) {
            float2 retirement = addPrecise(float2(f.lifecycle.x, f.lifecycle.w), float2(dt, p.precision.x));
            f.lifecycle.x = retirement.x; f.lifecycle.w = retirement.y;
        }
        float offset = p.policy.y > 0.5f ? 0 : snowSine(p.clock.y, p.clock.z, f.dynamics.w, f.dynamics.z) * f.style.x;
        float vx = (p.weather.x * 155 * f.dynamics.y + offset) * p.policy.x;
        float vy = -max(12.0f, f.dynamics.x * (1 - p.weather.y * 0.28f)) * p.policy.x;
        f.geometry.xy += float2(vx, vy) * dt;
        f.geometry.w += f.style.y * dt * p.policy.x;
        if (fadingIn || f.lifecycle.x >= 0) {
            f.appearance.x = f.style.z * min(1.0f, f.style.w / 0.5f)
                * (f.lifecycle.x >= 0 ? max(0.0f, 1 - f.lifecycle.x / 0.5f) : 1);
        }
        bool dead = f.geometry.y < -12 || f.geometry.x < -90 || f.geometry.x > p.weather.z + 90 || atLeast(float2(f.lifecycle.x, f.lifecycle.w), 0.5f);
        for (uint i = 0; !dead && i < p.counts.w; ++i) {
            Roof roof = roofs[i];
            if (old.y < roof.bounds.z || f.geometry.y > roof.bounds.w || f.geometry.x < roof.bounds.x || f.geometry.x > roof.bounds.y) continue;
            float top = roofHeight(f.geometry.x, points + roof.indices.x, roof.indices.y);
            if (old.y < top || f.geometry.y > top) continue;
            bool exposed = true;
            for (uint j = 0; j < roof.indices.w; ++j) if (inRect(float2(f.geometry.x, top), occluders[roof.indices.z + j])) { exposed = false; break; }
            if (exposed) dead = true;
        }
        if (dead) { f.identity.y = 0; flakes[id] = f; return; }
        float halfExtent = f.geometry.z * 0.5f * (abs(cos(f.geometry.w)) + abs(sin(f.geometry.w)));
        float4 bounds = float4(f.geometry.xy - halfExtent, f.geometry.xy + halfExtent);
        bool hard = hiddenBy(bounds, solid, p.counts.y), soft = hiddenBy(bounds, wide, p.counts.z);
        float target = soft ? 0 : 1;
        if (f.lifecycle.z == 0 || p.policy.z < 0.5f) { f.lifecycle.y = target; f.lifecycle.z = 1; }
        else {
            float step = dt / 0.2f, difference = target - f.lifecycle.y;
            f.lifecycle.y = abs(difference) <= step + 1e-9f ? target : f.lifecycle.y + (difference > 0 ? step : -step);
        }
        f.identity.z = !hard && f.lifecycle.y != 0;
        flakes[id] = f;
        atomic_fetch_add_explicit(&draw.aliveCount, 1, memory_order_relaxed);
        if (f.identity.z) {
            uint index = atomic_fetch_add_explicit(&draw.instanceCount, 1, memory_order_relaxed);
            output[index].geometry = f.geometry;
            output[index].appearance = float4(f.appearance.x * f.lifecycle.y, f.appearance.y, 0, 0);
        }
    }
    """
}
