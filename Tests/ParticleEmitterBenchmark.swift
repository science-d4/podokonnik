// THROWAWAY G5 probe. This is not an alternative production renderer.
// Compare the current SnowScene's particle-only workload with native SKEmitterNode.
// Compile with SnowTypes.swift, SnowWorld.swift, FramePacer.swift, ProcessMetrics.swift,
// and SnowScene.swift. Run each mode in a fresh process, sequentially:
//   <binary> --mode sprites --seconds 35 --warmup 5 --output <directory>
//   <binary> --mode emitters --seconds 35 --warmup 5 --output <directory>
// No desktop metadata, screen capture, global input, Accessibility or settings changes.
// A 2560 x 1440, scale-1 display is required. Output is own-scene PNG + metrics JSON.
import AppKit
import SpriteKit
import QuartzCore

private enum ParticleMode: String { case sprites, emitters }

private struct ProbeOptions {
    var mode = ParticleMode.sprites
    var seconds: Double = 35
    var warmup: Double = 5
    var output = URL(fileURLWithPath: ".build/particle-emitter-benchmark", isDirectory: true)

    init() {
        let arguments = CommandLine.arguments
        var index = 1
        while index + 1 < arguments.count {
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--mode": mode = ParticleMode(rawValue: value) ?? .sprites
            case "--seconds": seconds = max(1, Double(value) ?? 35)
            case "--warmup": warmup = max(1, Double(value) ?? 5)
            case "--output": output = URL(fileURLWithPath: value, isDirectory: true)
            default: break
            }
            index += 2
        }
    }
}

private final class ProbeLimiter: NSObject, SKViewDelegate {
    var pacer = FramePacer(rate: 60)
    var measuring = false
    var displayCallbacks = 0
    var acceptedCallbacks = 0
    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        let accepted = pacer.shouldRender(at: time)
        if measuring {
            displayCallbacks += 1
            if accepted { acceptedCallbacks += 1 }
        }
        return accepted
    }
}

private final class ProbeObserver: NSObject, SKSceneDelegate {
    var measuring = false
    var updateIntervals: [Double] = []
    var updateWork: [Double] = []
    var updates = 0
    private var previous: Double?
    private var started: Double?

    func begin(_ time: Double) {
        guard measuring else { return }
        if let previous { updateIntervals.append(time - previous) }
        previous = time
        updates += 1
        started = CACurrentMediaTime()
    }

    func didFinishUpdate(for scene: SKScene) {
        guard measuring, let started else { return }
        updateWork.append(CACurrentMediaTime() - started)
        self.started = nil
    }
}

private final class EmitterProbeScene: SKScene {
    var onFrame: ((TimeInterval) -> Void)?
    let emitterSpecifications: [[String: Double]]
    private let emitters: [SKEmitterNode]

    override init(size: CGSize) {
        let round = Self.particleTexture(crystal: false)
        let crystal = Self.particleTexture(crystal: true)
        var specifications: [[String: Double]] = []
        var nodes: [SKEmitterNode] = []
        // 4 depth bands, each with 3 size groups and 2 shared textures.
        // 4 * (472 + 135 + 68) = 2700 steady-state particles in expectation.
        let groups: [(count: Int, radius: CGFloat, crystal: Bool)] = [
            (472, 0.9, false), (135, 1.6, false), (68, 2.2, true)
        ]
        for (depthIndex, depth) in [CGFloat(0.54), 0.73, 0.92, 1.11].enumerated() {
            for group in groups {
                let vy = 26 + 54 * depth
                let vx = 0.2 * 155 * depth
                let lifetime = (size.height + 20) / vy
                let emitter = SKEmitterNode()
                emitter.position = CGPoint(x: size.width / 2, y: size.height + 8)
                emitter.particlePositionRange = CGVector(dx: size.width + 100, dy: 0)
                emitter.particleTexture = group.crystal ? crystal : round
                emitter.particleSize = CGSize(width: group.radius * 3.2, height: group.radius * 3.2)
                emitter.particleScale = 1
                emitter.particleScaleRange = group.crystal ? 0.25 : 0.5
                emitter.particleAlpha = 0.65
                emitter.particleAlphaRange = 0.5
                emitter.particleAlphaSpeed = 0
                emitter.particleRotation = .pi
                emitter.particleRotationRange = .pi * 2
                emitter.particleRotationSpeed = depthIndex.isMultiple(of: 2) ? 0.25 : -0.25
                emitter.particleSpeed = hypot(vx, vy)
                emitter.emissionAngle = atan2(-vy, vx)
                emitter.particleBirthRate = CGFloat(group.count) / lifetime
                emitter.particleLifetime = lifetime
                emitter.numParticlesToEmit = 0
                emitter.particleColorBlendFactor = 0
                emitter.particleBlendMode = .alpha
                emitter.particleRenderOrder = .dontCare
                emitter.fieldBitMask = 0
                emitter.advanceSimulationTime(TimeInterval(lifetime + 1))
                nodes.append(emitter)
                specifications.append(["expectedCount": Double(group.count), "depth": Double(depth),
                                       "radius": Double(group.radius), "lifetimeSeconds": Double(lifetime),
                                       "birthsPerSecond": Double(emitter.particleBirthRate),
                                       "verticalSpeed": Double(vy), "horizontalSpeed": Double(vx),
                                       "crystal": group.crystal ? 1 : 0])
            }
        }
        emitters = nodes
        emitterSpecifications = specifications
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        anchorPoint = .zero
        for emitter in emitters { addChild(emitter) }
    }

    required init?(coder: NSCoder) { fatalError("Probe is programmatic") }
    override func update(_ currentTime: TimeInterval) { onFrame?(currentTime) }

    // Same 32-pixel radial/crystal construction as production RendererTextures.
    // Duplicated locally because production helpers remain private and unchanged.
    private static func particleTexture(crystal: Bool) -> SKTexture {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.65),
                      CGColor(gray: 1, alpha: 0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                  locations: [0, 0.35, 1])!
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                                   endCenter: CGPoint(x: 16, y: 16), endRadius: crystal ? 12 : 15, options: [])
        if crystal {
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
            context.setLineWidth(1.1)
            context.setLineCap(.round)
            context.translateBy(x: 16, y: 16)
            for _ in 0..<6 {
                context.move(to: .zero); context.addLine(to: CGPoint(x: 0, y: 11))
                context.move(to: CGPoint(x: 0, y: 7)); context.addLine(to: CGPoint(x: -2.5, y: 9.5))
                context.move(to: CGPoint(x: 0, y: 7)); context.addLine(to: CGPoint(x: 2.5, y: 9.5))
                context.strokePath()
                context.rotate(by: .pi / 3)
            }
        }
        let texture = SKTexture(cgImage: context.makeImage()!)
        texture.filteringMode = .linear
        return texture
    }
}

private final class ParticleProbe: NSObject, NSApplicationDelegate {
    let options: ProbeOptions
    let observer = ProbeObserver()
    let limiter = ProbeLimiter()
    var window: NSWindow!
    var view: SKView!
    var scene: SKScene!
    var sampleTimer: Timer?
    var finishTimer: Timer?
    var metricStart: ProcessSample?
    var metricPrevious: ProcessSample?
    var samples: [[String: Any]] = []
    var measuredCPU: [Double] = []
    var measuredMemory: [Double] = []
    var measuredParticles: [Int] = []
    var previewInfo: [String: Any] = [:]

    init(options: ProbeOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.width >= 2560 && $0.frame.height >= 1440 && $0.backingScaleFactor == 1
        }) else {
            fputs("Probe requires a 2560x1440-point display at backing scale 1.\n", stderr)
            exit(2)
        }
        let size = CGSize(width: 2560, height: 1440)
        let frame = CGRect(origin: screen.frame.origin, size: size)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.hidesOnDeactivate = false
        view = SKView(frame: CGRect(origin: .zero, size: size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        view.delegate = limiter
        if options.mode == .sprites {
            let snow = SnowScene(world: SnowWorld(seed: 1), displayFrame: CGRect(origin: .zero, size: size))
            snow.weather = SnowWeather(intensity: .blizzard, wind: CGVector(dx: 0.2, dy: 0))
            // The real production particle loop reaches its 2700 cap before measurement.
            for tick in 0...3600 { snow.update(Double(tick) / 60) }
            snow.resetAnimationClock()
            snow.onFrame = { [weak observer] in observer?.begin($0) }
            scene = snow
        } else {
            let emitterScene = EmitterProbeScene(size: size)
            emitterScene.onFrame = { [weak observer] in observer?.begin($0) }
            scene = emitterScene
        }
        scene.delegate = observer
        window.contentView = view
        view.presentScene(scene)
        window.orderFrontRegardless()
        print("PARTICLE_PROBE_WARMUP mode=\(options.mode.rawValue) seconds=\(options.warmup) refresh=\(screen.maximumFramesPerSecond) scale=\(screen.backingScaleFactor)")
        Timer.scheduledTimer(withTimeInterval: options.warmup, repeats: false) { [weak self] _ in
            self?.beginMeasurement()
        }
    }

    private func beginMeasurement() {
        try! FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        // Only our own scene is exported; no screen or foreign window is captured.
        if let texture = view.texture(from: scene, crop: CGRect(origin: .zero, size: scene.size)) {
            let bitmap = NSBitmapImageRep(cgImage: texture.cgImage())
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try! data.write(to: options.output.appendingPathComponent("\(options.mode.rawValue)-preview.png"))
            }
            previewInfo = ["widthPixels": bitmap.pixelsWide, "heightPixels": bitmap.pixelsHigh]
        }
        // Export readback has finished; let its GPU/CPU work settle before collecting.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.metricStart = ProcessSample.current()
            self.metricPrevious = self.metricStart
            self.observer.measuring = true
            self.limiter.measuring = true
            self.sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            self.finishTimer = Timer.scheduledTimer(withTimeInterval: self.options.seconds, repeats: false) { [weak self] _ in self?.finish() }
            print("PARTICLE_PROBE_MEASURE mode=\(self.options.mode.rawValue) seconds=\(self.options.seconds)")
        }
    }

    private func sample() {
        guard let start = metricStart, let previous = metricPrevious else { return }
        let now = ProcessSample.current()
        let cpu = (now.cpuSeconds - previous.cpuSeconds) / max(0.001, now.uptime - previous.uptime) * 100
        let particles = (scene as? SnowScene)?.renderingStatistics.particles ?? 2700
        measuredCPU.append(cpu)
        measuredMemory.append(Double(now.physicalBytes))
        measuredParticles.append(particles)
        samples.append(["elapsedSeconds": now.uptime - start.uptime, "cpuPercentOneCore": cpu,
                        "physicalBytes": now.physicalBytes, "particles": particles,
                        "particleCountIsEstimated": options.mode == .emitters,
                        "sceneUpdates": observer.updates])
        metricPrevious = now
    }

    private func finish() {
        sampleTimer?.invalidate()
        finishTimer?.invalidate()
        guard let start = metricStart else { return }
        observer.measuring = false
        limiter.measuring = false
        let end = ProcessSample.current()
        let elapsed = end.uptime - start.uptime
        let cpu = (end.cpuSeconds - start.cpuSeconds) / elapsed * 100
        let report: [String: Any] = [
            "probe": "throwaway particle-only comparison; not production acceptance",
            "mode": options.mode.rawValue,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "durationSeconds": elapsed, "warmupSeconds": options.warmup + 2,
            "sceneWidthPoints": 2560, "sceneHeightPoints": 1440,
            "backingScaleFactor": window.backingScaleFactor,
            "displayMaximumHz": window.screen?.maximumFramesPerSecond ?? 0,
            "requestedUpdateHz": 60,
            "viewBackingPixelWidth": view.convertToBacking(view.bounds).width,
            "viewBackingPixelHeight": view.convertToBacking(view.bounds).height,
            "cpuPercentOneCore": cpu,
            "cpuOneSecondSamplesP95": percentile(measuredCPU, 0.95),
            "physicalMiBMean": mean(measuredMemory) / 1_048_576,
            "physicalMiBP95": percentile(measuredMemory, 0.95) / 1_048_576,
            "physicalMiBPeak": (measuredMemory.max() ?? 0) / 1_048_576,
            "displayDelegateCallbacksPerSecond": Double(limiter.displayCallbacks) / elapsed,
            "pacerAcceptedCallbacksPerSecond": Double(limiter.acceptedCallbacks) / elapsed,
            "sceneUpdatesPerSecond": Double(observer.updates) / elapsed,
            "sceneUpdateIntervalMillisecondsP95": percentile(observer.updateIntervals, 0.95) * 1000,
            "sceneUpdateWorkMicrosecondsMean": mean(observer.updateWork) * 1_000_000,
            "sceneUpdateWorkMicrosecondsP95": percentile(observer.updateWork, 0.95) * 1_000_000,
            "updateWorkDefinition": "wall time from scene update entry through didFinishUpdate; excludes renderer submission and GPU presentation",
            "actualPresentedFPSMeasured": false,
            "particlesMin": measuredParticles.min() ?? 0,
            "particlesMax": measuredParticles.max() ?? 0,
            "particleCountIsEstimated": options.mode == .emitters,
            "emitterSpecifications": (scene as? EmitterProbeScene)?.emitterSpecifications ?? [],
            "preview": previewInfo,
            "samples": samples,
            "limitations": Self.limitations
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: options.output.appendingPathComponent("\(options.mode.rawValue).json"), options: .atomic)
        try! Self.limitations.joined(separator: "\n\n").write(to: options.output.appendingPathComponent("limitations.txt"),
                                                            atomically: true, encoding: .utf8)
        print("PARTICLE_PROBE_DONE mode=\(options.mode.rawValue) cpu=\(cpu) memoryMiB=\(mean(measuredMemory) / 1_048_576) updatesHz=\(Double(observer.updates) / elapsed)")
        view.presentScene(nil)
        window.close()
        NSApp.terminate(nil)
    }

    private static let limitations = [
        "Изолированная проба частиц: у обоих режимов нет окон, сугробов, шаров, AX и core step. Она не подтверждает общий CPU бюджет приложения и не заменяет production-модель.",
        "Sprites: настоящий SnowScene с полным циклом частиц, blizzard, постоянный wind.dx=0.2; cap=2700. Emitters: 12 SKEmitterNode, 4 дискретные глубины, 3 группы размеров, 2 такие же текстуры. Распределение близкое, но не идентичное.",
        "Emitter считает 2700 как сумму birthRate*lifetime после advanceSimulationTime. Публичного счётчика/массива частиц нет; это ожидаемая нагрузка, не проверенный точный живой count. Часть частиц находится за экраном у обоих режимов.",
        "В emitter-пробе нет индивидуального синусоидального sway, upwind-side emission и production fade-in. Это различия качества/траекторий; CPU выигрыш не доказывает равноценную замену.",
        "Native emitter поддерживает начальный speed/angle, xAcceleration/yAcceleration и fields для общего ветра. Это не эквивалент текущему сглаженному заданию скорости каждой частицы. particleAction может приблизить sway/fade; Apple предупреждает, что сложные actions заметно ухудшают производительность. В этой пробе actions не измеряются.",
        "Публичный API SKEmitterNode не даёт доступ к отдельным частицам и callbacks приземления. Проверка swept landing на текущих опорах/масках не выполнена. Нельзя просто заменить production частицы emitter и убрать collision. Для полного решения нужна отдельная проверенная схема render clipping/landing либо другой renderer с контролем частиц.",
        "p95 callback interval и scene update work не являются actual presented FPS. CPU измерен getrusage через ProcessSample, память — phys_footprint; GPU time, WindowServer CPU и системное энергопотребление не измерены. Режимы запускаются последовательно в свежих процессах; порядок/фон могут повлиять на результат."
    ]

    private func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }
}

@main
private enum ParticleEmitterBenchmark {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = ParticleProbe(options: ProbeOptions())
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
