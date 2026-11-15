// THROWAWAY G5 architecture probe, not a production renderer or input implementation.
// One CAMetalDisplayLink updates the existing SnowWorld/SnowScene and submits both
// SpriteKit and instanced particles in one Metal command buffer / drawable.
// Compile with SnowCore types/world/pacer, SnowScene, MetalParticleView, ProcessMetrics.
// Run --rate 100 or --rate 60 --seconds 35 --output <directory>, outside GUI sandbox.
import AppKit
import MetalKit
import SpriteKit

private struct UnifiedOptions {
    var rate: Double = 60
    var seconds: Double = 35
    var warmup: Double = 5
    var stress = false
    var output = URL(fileURLWithPath: ".build/unified-renderer-benchmark/results", isDirectory: true)
    init() {
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            if args[i] == "--stress" { stress = true; i += 1; continue }
            guard i + 1 < args.count else { break }
            switch args[i] {
            case "--rate": rate = max(1, Double(args[i + 1]) ?? 60)
            case "--seconds": seconds = max(1, Double(args[i + 1]) ?? 35)
            case "--warmup": warmup = max(1, Double(args[i + 1]) ?? 5)
            case "--output": output = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            default: break
            }
            i += 2
        }
    }
    var name: String { "unified-\(Int(rate))" + (stress ? "-stress" : "-steady") }
}

private final class UnifiedSurface: NSView {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
}

private final class UnifiedProbe: NSObject, NSApplicationDelegate, CAMetalDisplayLinkDelegate, SKSceneDelegate {
    let options: UnifiedOptions
    let region = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let world = SnowWorld(seed: 111)
    let weather: SnowWeather
    var window: NSWindow!
    var surface: UnifiedSurface!
    var metalLayer: CAMetalLayer!
    var renderer: SKRenderer!
    var batch: ParticleBatchRenderer!
    var scene: SnowScene!
    var displayLink: CAMetalDisplayLink!
    var pacer = FramePacer()
    var packet: [SnowParticleInstance] = []
    var lastAnimationTime: Double?
    var metricStart: ProcessSample?
    var metricPrevious: ProcessSample?
    var metricEnd: ProcessSample?
    var timer: Timer?
    var finishTimer: Timer?
    var measuring = false
    var rawCallbacks = 0
    var selectedFrames = 0
    var submittedFrames = 0
    var declinedFrames = 0
    var deadlineMisses = 0
    var commandErrors = 0
    var sceneUpdateCallbacks = 0
    var nativeDelegateCallbacks = 0
    var callbackWork: [Double] = []
    var deadlineMargins: [Double] = []
    var selectedTargets: [Double] = []
    var presentRecords: [[String: Double]] = []
    var gpuSeconds: [Double] = []
    var memoryBytes: [Double] = []
    var samples: [[String: Any]] = []

    init(options: UnifiedOptions) {
        self.options = options
        weather = SnowWeather(intensity: options.stress ? .blizzard : .steady, wind: CGVector(dx: 0.2, dy: 0))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.width >= 2560 && $0.frame.height >= 1440 && $0.backingScaleFactor == 1
        }), let device = MTLCreateSystemDefaultDevice() else {
            fputs("Unified probe requires a Metal device and 2560x1440-point scale1 display.\n", stderr)
            exit(2)
        }
        window = NSWindow(contentRect: CGRect(origin: screen.frame.origin, size: region.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.hidesOnDeactivate = false
        surface = UnifiedSurface(frame: region)
        surface.wantsLayer = true
        metalLayer = surface.layer as? CAMetalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = 1
        metalLayer.drawableSize = region.size
        metalLayer.maximumDrawableCount = 3
        window.contentView = surface

        scene = SnowScene(world: world, displayFrame: region)
        // SKRenderer has no SKView to supply resizeFill's reference dimensions.
        // Keep the logical viewport explicit before its first native render.
        scene.scaleMode = .aspectFit
        scene.size = region.size
        scene.weather = weather
        scene.presentationScale = 1
        scene.onParticles = { [weak self] in self?.packet = $0 }
        scene.onFrame = { [weak self] _ in self?.sceneUpdateCallbacks += 1 }
        scene.delegate = self
        renderer = SKRenderer(device: device)
        renderer.scene = scene
        renderer.ignoresSiblingOrder = true
        renderer.shouldCullNonVisibleNodes = true
        do { batch = try ParticleBatchRenderer(device: device, images: scene.particleTextureImages) }
        catch { fputs("Cannot initialize particle batch: \(error)\n", stderr); exit(3) }
        seedWorld()
        window.orderFrontRegardless()

        pacer.rate = options.rate
        displayLink = CAMetalDisplayLink(metalLayer: metalLayer)
        displayLink.delegate = self
        displayLink.preferredFrameLatency = 2
        let native = Float(screen.maximumFramesPerSecond)
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: native, maximum: native, preferred: native)
        displayLink.add(to: .main, forMode: .common)
        print("UNIFIED_WARMUP rate=\(options.rate) native=\(native) supports=\(world.surfaces.count) balls=\(world.balls.count) particles=\(scene.renderingStatistics.particles) size=\(scene.size)")
        Timer.scheduledTimer(withTimeInterval: options.warmup, repeats: false) { [weak self] _ in
            self?.prepareMeasurement()
        }
    }

    private func seedWorld() {
        // All ten full-width window roofs live in the lower half of this display.
        // Snow still crosses real supports and foreground masks; no collision shortcut.
        var supports: [SnowSurface] = []
        var foreground: [CGRect] = []
        for i in (0..<10).reversed() {
            let frame = CGRect(x: 60 + CGFloat(i % 3) * 360, y: 80 + CGFloat(i) * 42,
                               width: 1600, height: 140)
            var support = SnowSurface(id: "synthetic:\(i)", frame: frame, kind: .window,
                                      occluders: foreground)
            support.topInset = 16
            supports.append(support)
            foreground.append(frame)
        }
        supports.append(SnowSurface(id: "floor", frame: CGRect(x: 0, y: 0, width: region.width, height: 0),
                                    kind: .floor, occluders: foreground))
        world.syncSurfaces(supports)
        world.prune(to: [region])
        for tick in 0...3600 {
            packet.removeAll(keepingCapacity: false)
            world.step(delta: 1.0 / 60, weather: weather, activeRegions: [region])
            updateScene(at: Double(tick) / 60)
        }
        for support in supports where options.stress && support.kind == .window {
            for x in stride(from: support.frame.minX + 40, to: support.frame.maxX - 20, by: 52) {
                guard world.balls.count < 30, let drift = world.drifts[support.id] else { continue }
                let index = min(drift.heights.count - 1, max(0, Int((x - support.frame.minX) / SnowDrift.spacing)))
                if world.beginSnowball(at: CGPoint(x: x, y: support.top + drift.heights[index])) != nil { world.endDrag() }
            }
        }
        scene.resetAnimationClock()
        lastAnimationTime = nil
        pacer.reset()
        guard scene.size == region.size, scene.renderingStatistics.particles > 500 else {
            fputs("Invalid seeded workload: scene=\(scene.size) particles=\(scene.renderingStatistics.particles)\n", stderr)
            exit(4)
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let began = CACurrentMediaTime()
        if measuring { rawCallbacks += 1 }
        let animationTime = update.targetPresentationTimestamp
        guard pacer.shouldRender(at: animationTime) else { return }
        let record = measuring
        if record {
            selectedFrames += 1
            selectedTargets.append(animationTime)
        }
        // Drop our reference before the scene mutates its reusable packet.
        packet = []
        let delta = lastAnimationTime.map { max(0, min(0.1, animationTime - $0)) } ?? 0
        lastAnimationTime = animationTime
        world.step(delta: delta, weather: weather, activeRegions: [region])
        updateScene(at: animationTime)
        let expectedUpdates = sceneUpdateCallbacks
        let pass = makePass(texture: update.drawable.texture)
        let command = batch.render(packet, viewport: region.size, pass: pass, drawable: update.drawable,
            onPresented: { [weak self] time in
                guard record, let self else { return }
                self.presentRecords.append(["target": animationTime, "actual": time])
            }, beforeParticles: { [weak self] command in
                guard let self else { return }
                self.renderer.render(withViewport: CGRect(origin: .zero, size: self.metalLayer.drawableSize),
                                     commandBuffer: command, renderPassDescriptor: pass)
                precondition(self.sceneUpdateCallbacks == expectedUpdates, "Rendering must not advance SnowScene a second time")
                pass.colorAttachments[0].loadAction = .load
                if record {
                    command.addCompletedHandler { [weak self] completed in
                        let duration = completed.gpuEndTime - completed.gpuStartTime
                        let failed = completed.status != .completed
                        DispatchQueue.main.async {
                            if duration > 0 { self?.gpuSeconds.append(duration) }
                            if failed { self?.commandErrors += 1 }
                        }
                    }
                }
            }, presentDirectly: true)
        packet = []
        if record {
            let finished = CACurrentMediaTime()
            callbackWork.append(finished - began)
            deadlineMargins.append(update.targetTimestamp - finished)
            if finished > update.targetTimestamp { deadlineMisses += 1 }
            if command != nil { submittedFrames += 1 } else { declinedFrames += 1 }
        }
    }

    // Own frame driver advances app logic exactly once. The public delegate is
    // deliberately passive if SKRenderer invokes its native scene update cycle.
    func update(_ currentTime: TimeInterval, for scene: SKScene) {
        nativeDelegateCallbacks += 1
    }

    private func updateScene(at time: TimeInterval) {
        let previous = sceneUpdateCallbacks
        scene.update(time)
        renderer.update(atTime: time)
        precondition(sceneUpdateCallbacks == previous + 1, "Exactly one SnowScene update must run per renderer update")
    }

    private func makePass(texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return pass
    }

    private func prepareMeasurement() {
        try! FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        // Only a synthetic owned scene is exported. Rendering here does not update it.
        exportOwnScene()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.metricStart = ProcessSample.current()
            self.metricPrevious = self.metricStart
            self.measuring = true
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            self.finishTimer = Timer.scheduledTimer(withTimeInterval: self.options.seconds, repeats: false) { [weak self] _ in self?.finish() }
            print("UNIFIED_MEASURE rate=\(self.options.rate) seconds=\(self.options.seconds)")
        }
    }

    private func exportOwnScene() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(region.width), height: Int(region.height), mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = metalLayer.device?.makeTexture(descriptor: descriptor) else { return }
        // Rebuild the latest packet without changing simulation time; renderFrame has
        // released its copy. A deterministic scene update with dt0 leaves physics intact.
        updateScene(at: lastAnimationTime ?? 0)
        let pass = makePass(texture: texture)
        let command = batch.render(packet, viewport: region.size, pass: pass, beforeParticles: { [weak self] command in
            guard let self else { return }
            self.renderer.render(withViewport: self.region, commandBuffer: command, renderPassDescriptor: pass)
            pass.colorAttachments[0].loadAction = .load
        })
        packet = []
        command?.waitUntilCompleted()
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                    .union(.byteOrder32Little), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try! png.write(to: options.output.appendingPathComponent(options.name + ".png"))
    }

    private func sample() {
        guard let start = metricStart, let previous = metricPrevious else { return }
        let now = ProcessSample.current()
        let cpu = (now.cpuSeconds - previous.cpuSeconds) / max(0.001, now.uptime - previous.uptime) * 100
        memoryBytes.append(Double(now.physicalBytes))
        samples.append(["elapsed": now.uptime - start.uptime, "cpuPercentOneCore": cpu,
                        "physicalBytes": now.physicalBytes, "particles": scene.renderingStatistics.particles,
                        "balls": world.balls.count, "submitted": submittedFrames,
                        "presented": presentRecords.count])
        metricPrevious = now
    }

    private func finish() {
        timer?.invalidate(); finishTimer?.invalidate()
        metricEnd = ProcessSample.current()
        measuring = false
        displayLink.isPaused = true
        displayLink.invalidate()
        // Let presentation/completion callbacks for the last submitted frame drain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.writeResult() }
    }

    private func writeResult() {
        guard let start = metricStart, let end = metricEnd else { return }
        let elapsed = end.uptime - start.uptime
        let cpu = (end.cpuSeconds - start.cpuSeconds) / elapsed * 100
        let presented = presentRecords.map { $0["actual"]! }.sorted()
        let intervals = zip(presented.dropFirst(), presented).map(-)
        let targetIntervals = zip(selectedTargets.dropFirst(), selectedTargets).map(-)
        var report: [String: Any] = [:]
        report["probe"] = "throwaway unified CAMetalDisplayLink + SKRenderer + particle batch; synthetic scene, no game input"
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["requestedRate"] = options.rate
        report["scenario"] = options.stress ? "blizzard-30balls" : "steady-0balls"
        report["intensity"] = options.stress ? "blizzard" : "steady"
        report["warmupSeconds"] = options.warmup + 2
        report["preferredFrameLatency"] = 2
        report["nativeDisplayHz"] = window.screen?.maximumFramesPerSecond ?? 0
        report["durationSeconds"] = elapsed
        report["sceneWidthPoints"] = region.width
        report["sceneHeightPoints"] = region.height
        report["backingScale"] = window.backingScaleFactor
        report["cpuPercentOneCore"] = cpu
        report["physicalMiBMean"] = mean(memoryBytes) / 1_048_576
        report["physicalMiBPeak"] = (memoryBytes.max() ?? 0) / 1_048_576
        report["rawCallbacksPerSecond"] = Double(rawCallbacks) / elapsed
        report["selectedFramesPerSecond"] = Double(selectedFrames) / elapsed
        report["submittedFrames"] = submittedFrames
        report["presentedFrames"] = presentRecords.count
        report["presentedPerSecond"] = Double(presentRecords.count) / elapsed
        report["presentedIntervalP95Milliseconds"] = percentile(intervals, 0.95) * 1000
        report["presentedIntervalP99Milliseconds"] = percentile(intervals, 0.99) * 1000
        report["selectedTargetIntervalP95Milliseconds"] = percentile(targetIntervals, 0.95) * 1000
        report["callbackWorkP95Milliseconds"] = percentile(callbackWork, 0.95) * 1000
        report["callbackWorkMeanMilliseconds"] = mean(callbackWork) * 1000
        report["gpuP95Milliseconds"] = percentile(gpuSeconds, 0.95) * 1000
        report["deadlineMarginP05Milliseconds"] = percentile(deadlineMargins, 0.05) * 1000
        report["deadlineMisses"] = deadlineMisses
        report["bufferUnavailableOrEncodingFailures"] = declinedFrames
        report["gpuCommandErrors"] = commandErrors
        report["supportsIncludingFloor"] = world.surfaces.count
        report["balls"] = world.balls.count
        report["particles"] = scene.renderingStatistics.particles
        report["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        report["sameWorldAndCollisions"] = true
        report["explicitSceneUpdates"] = sceneUpdateCallbacks
        report["nativeDelegateCallbacks"] = nativeDelegateCallbacks
        report["separateSKViewClock"] = false
        report["samples"] = samples
        report["presentRecords"] = presentRecords
        report["limitations"] = ["one synthetic trial per mode; no CG/AX polling or game input",
                                  "root/frame rendering and particles share one command buffer and drawable",
                                  "not a production acceptance result; CPU must include metadata in integrated app",
                                  "fixed100Hz link with selected60 callbacks is an experiment, not an Apple frame-rate guarantee"]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: options.output.appendingPathComponent(options.name + ".json"), options: .atomic)
        print("UNIFIED_DONE rate=\(options.rate) cpu=\(cpu) presentedHz=\(Double(presentRecords.count) / elapsed) p95ms=\(percentile(intervals, 0.95) * 1000) misses=\(deadlineMisses) errors=\(commandErrors)")
        window.close()
        NSApp.terminate(nil)
    }

    private func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }
}

@main
private enum UnifiedRendererBenchmark {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = UnifiedProbe(options: UnifiedOptions())
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
