// Isolated production-renderer benchmark, not whole-desktop CPU or a visual test.
// Warmup advances only through real UnifiedSnowView display callbacks and GPU work.
import AppKit
import MetalKit
import SpriteKit

private struct BenchmarkOptions {
    var scenario = "steady"
    var label = "unlabelled"
    var warmup = 25.0
    var seconds = 30.0
    var decorations = "off"
    var output = URL(fileURLWithPath: ".build/gpu-simulation/results/result.json")

    init() {
        let arguments = CommandLine.arguments
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--cpu-particles" { index += 1; continue }
            guard index + 1 < arguments.count else { fatalError("Missing benchmark option value") }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--scenario": scenario = value
            case "--label": label = value
            case "--warmup": warmup = Double(value) ?? 0
            case "--seconds": seconds = Double(value) ?? 0
            case "--output": output = URL(fileURLWithPath: value)
            case "--decorations": decorations = value
            default: fatalError("Unknown benchmark option: \(arguments[index])")
            }
            index += 2
        }
        precondition(["steady", "blizzard"].contains(scenario))
        precondition(["off", "all"].contains(decorations))
        precondition(warmup.isFinite && warmup >= 20 && seconds.isFinite && seconds >= 20,
                     "A benchmark requires at least 20 seconds of real warmup and measurement")
    }
}

private struct EncodedFrame {
    let target: Double
    let encodedAt: Double
    let phase: String
}

private final class GPUSimulationBenchmark: NSObject, NSApplicationDelegate {
    private let options: BenchmarkOptions
    private let region = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let world = SnowWorld(seed: 111)
    #if FESTIVE_FEATURES
    private let festiveWorld = FestiveWorld()
    #endif
    private let weather: SnowWeather
    private var window: NSWindow!
    private var scene: SnowScene!
    private var view: UnifiedSnowView!
    private var pacer = FramePacer()
    private var nativeMaximum = 0
    private var environment: [String: Any] = [:]
    private var startTime = 0.0
    private var measurementStart: ProcessSample?
    private var measurementEnd: ProcessSample?
    private var phaseStart: ProcessSample?
    private var previousSample: ProcessSample?
    private var currentPhase = "warmup"
    private var lastAnimationTime: Double?
    private var latestGeometryOffset: CGFloat = .nan
    private var latestWideFocus = false
    private var pending: [Double: EncodedFrame] = [:]
    private var presented: [[String: Any]] = []
    private var processSamples: [[String: Any]] = []
    private var phases: [[String: Any]] = []
    private var failures: [String] = []
    private var rawCallbacks = 0
    private var skippedByPacer = 0
    private var selectedFrames = 0
    private var warmupParticles = 0
    private var warmupFrames = 0
    private var firstTargetMinusHost: Double?
    private var peakFootprint: UInt64 = 0
    private var submittedAtStart = 0
    private var submittedAtEnd = 0
    private var backend = "cpu-baseline"
    private var sampleTimer: Timer?
    private var boundaryTimer: Timer?
    private var finished = false

    init(options: BenchmarkOptions) {
        self.options = options
        weather = SnowWeather(intensity: options.scenario == "blizzard" ? .blizzard : .steady,
                              wind: CGVector(dx: 0.2, dy: 0))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.width >= region.width && $0.frame.height >= region.height && $0.backingScaleFactor == 1
        }) else {
            failBeforeStart("Requires a 2560×1440-point or larger scale1 display")
            return
        }
        nativeMaximum = screen.maximumFramesPerSecond
        environment = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processors": ProcessInfo.processInfo.processorCount,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
            "nativeMaximumFPS": nativeMaximum,
            "backingScale": screen.backingScaleFactor,
            "viewportPoints": [region.width, region.height],
            "screenPoints": [screen.frame.width, screen.frame.height],
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalStateAtStart": ProcessInfo.processInfo.thermalState.rawValue
        ]
        world.syncSurfaces(makeSurfaces(offset: 0, wideFocused: false))
        world.prune(to: [region])
        latestGeometryOffset = 0
        #if FESTIVE_FEATURES
        scene = SnowScene(world: world, displayFrame: region, festiveWorld: festiveWorld)
        if options.decorations == "all" {
            var options = FestiveOptions()
            options.desktopGarland = true; options.windowGarlands = true
            options.christmasTrees = true; options.aurora = true; options.shootingStars = true
            scene.decorationOptions = options
            scene.decorationVisibleFrame = region.insetBy(dx: 0, dy: 24)
            if let roof = world.surfaces.filter({ $0.kind == .window }).max(by: { $0.top < $1.top }) {
                for offset: CGFloat in [200, 500, 800, 1100] {
                    _ = festiveWorld.place(at: CGPoint(x: roof.frame.minX + offset, y: roof.top + 4),
                                           displayFrame: region, snow: world)
                }
            }
        }
        #else
        guard options.decorations == "off" else { failBeforeStart("Decorations were not compiled into this benchmark"); return }
        scene = SnowScene(world: world, displayFrame: region)
        #endif
        scene.weather = weather
        scene.onFrame = { [weak self] target in self?.advance(target: target) }
        guard let host = UnifiedSnowView(frame: region, scene: scene, maximumFPS: nativeMaximum,
                                        shouldRender: { [weak self] target in self?.select(target: target) ?? false }) else {
            failBeforeStart("Production UnifiedSnowView initialization failed")
            return
        }
        view = host
        #if GPU_SIMULATION_CANDIDATE
        backend = host.usesGPUSimulation ? "gpu" : "cpu"
        let expectedGPU = !CommandLine.arguments.contains("--cpu-particles")
        guard host.usesGPUSimulation == expectedGPU else {
            failBeforeStart("Backend mismatch: expected GPU=\(expectedGPU), actual GPU=\(host.usesGPUSimulation)")
            return
        }
        #endif
        host.onFramePresented = { [weak self] target, actual in self?.didPresent(target: target, actual: actual) }
        host.onFailure = { [weak self] message in
            guard let self else { return }
            self.failures.append(message)
            self.endMeasurement()
        }
        // The only window is ours. No CG list, AX traversal, global input or screen capture.
        window = NSWindow(contentRect: CGRect(origin: screen.frame.origin, size: region.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentView = host
        window.orderFrontRegardless()
        startTime = ProcessInfo.processInfo.systemUptime
        host.isPaused = false
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: options.warmup, repeats: false) { [weak self] _ in
            self?.beginMeasurement()
        }
        print("WARMUP \(options.label) \(options.scenario): \(options.warmup)s real frames, native=\(nativeMaximum)")
        fflush(stdout)
    }

    private func phase(at elapsed: Double) -> String {
        if elapsed < 12 { return "idleBefore" }
        if elapsed < 18 { return "motion" }
        if elapsed < 18.65 { return "grace" }
        return "idleAfter"
    }

    private func select(target: Double) -> Bool {
        guard !finished, measurementEnd == nil else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if firstTargetMinusHost == nil { firstTargetMinusHost = target - now }
        let elapsed = measurementStart.map { now - $0.uptime } ?? -1
        if elapsed >= options.seconds { endMeasurement(); return false }
        let moving = elapsed >= 12 && elapsed < 18.65
        pacer.rate = FramePacer.preferredRate(nativeMaximum: nativeMaximum, isMoving: moving, constrained: false)
        let selected = pacer.shouldRender(at: target)
        if measurementStart != nil {
            rawCallbacks += 1
            if !selected { skippedByPacer += 1 }
        }
        return selected
    }

    private func advance(target: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if let start = measurementStart, measurementEnd == nil {
            let elapsed = now - start.uptime
            let phase = phase(at: elapsed)
            if phase != currentPhase { switchPhase(to: phase) }
            let motionTime = max(0, min(6, elapsed - 12))
            // Smooth translation returns to the exact initial pose after six seconds.
            let offset = elapsed >= 12 && elapsed < 18 ? CGFloat(80 * sin(motionTime * .pi / 3)) : 0
            let wideFocused = elapsed >= 12 && elapsed < 18
            if offset != latestGeometryOffset || wideFocused != latestWideFocus {
                world.syncSurfaces(makeSurfaces(offset: offset, wideFocused: wideFocused))
                #if FESTIVE_FEATURES
                festiveWorld.syncSurfaces(world.surfaces)
                #endif
                latestGeometryOffset = offset
                latestWideFocus = wideFocused
            }
            selectedFrames += 1
            pending[target] = EncodedFrame(target: target, encodedAt: now, phase: phase)
        }
        let delta = lastAnimationTime.map { max(0, min(0.1, target - $0)) } ?? 0
        lastAnimationTime = target
        world.step(delta: delta, weather: weather, activeRegions: [region])
    }

    private func makeSurfaces(offset: CGFloat, wideFocused: Bool) -> [SnowSurface] {
        var surfaces: [SnowSurface] = []
        var foreground: [CGRect] = []
        // Nine overlapping narrow windows plus one full-width ordinary window.
        // Their roofs stay below y=620, preserving a substantial falling workload.
        let order = wideFocused ? [0] + Array((1..<10).reversed()) : Array((0..<10).reversed())
        for index in order {
            let frame: CGRect
            if index == 0 {
                frame = CGRect(x: 0, y: 30, width: region.width, height: 180)
            } else {
                frame = CGRect(x: 60 + CGFloat(index % 3) * 360 + (index == 5 ? offset : 0),
                               y: 80 + CGFloat(index) * 42, width: 1600, height: 140)
            }
            var surface = SnowSurface(id: "benchmark-window:\(index)", frame: frame, kind: .window,
                                      occluders: foreground)
            surface.topInset = 16
            surface.bodyOccluders = foreground
            surface.suppressesSnowfall = wideFocused ? index == 0 : index == 9
            surfaces.append(surface)
            foreground.append(frame)
        }
        let masks = foreground.compactMap { WideWindowPolicy.floorOccluder($0, ordinaryWindow: true, display: region) }
        surfaces.append(SnowSurface(id: "benchmark-floor", frame: CGRect(x: 0, y: -1, width: region.width, height: 1),
                                    kind: .floor, occluders: masks))
        return surfaces
    }

    private func beginMeasurement() {
        guard !finished, measurementStart == nil else { return }
        warmupParticles = scene.renderingStatistics.particles
        warmupFrames = view.submittedFrames
        guard scene.size == region.size, warmupParticles >= 500, warmupFrames > 0 else {
            failures.append("Invalid warmup: size=\(scene.size), particles=\(warmupParticles), frames=\(warmupFrames)")
            endMeasurement()
            return
        }
        let sample = ProcessSample.current()
        measurementStart = sample
        phaseStart = sample
        previousSample = sample
        peakFootprint = sample.physicalBytes
        currentPhase = "idleBefore"
        submittedAtStart = view.submittedFrames
        // Do not reset scene, particle state or world after the real warmup.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sampleProcess() }
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: options.seconds, repeats: false) { [weak self] _ in
            self?.endMeasurement()
        }
        print("MEASURE \(options.label) \(options.scenario): particles=\(warmupParticles), frames=\(warmupFrames), \(options.seconds)s")
        fflush(stdout)
    }

    private func sampleProcess() {
        guard let start = measurementStart, measurementEnd == nil else { return }
        let sample = ProcessSample.current()
        peakFootprint = max(peakFootprint, sample.physicalBytes)
        let previous = previousSample ?? start
        processSamples.append([
            "elapsed": sample.uptime - start.uptime, "phase": currentPhase,
            "duration": sample.uptime - previous.uptime,
            "cpuSeconds": sample.cpuSeconds - previous.cpuSeconds,
            "physicalBytes": sample.physicalBytes,
            "particles": scene.renderingStatistics.particles,
            "submittedFrames": view.submittedFrames - submittedAtStart,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue
        ])
        previousSample = sample
    }

    private func switchPhase(to phase: String) {
        let sample = ProcessSample.current()
        closePhase(at: sample)
        currentPhase = phase
        phaseStart = sample
    }

    private func closePhase(at sample: ProcessSample) {
        guard let start = phaseStart, let measurement = measurementStart else { return }
        let seconds = sample.uptime - start.uptime
        phases.append(["phase": currentPhase, "start": start.uptime - measurement.uptime,
                       "duration": seconds, "cpuPercentOneCore": (sample.cpuSeconds - start.cpuSeconds) / max(1e-9, seconds) * 100])
    }

    private func didPresent(target: Double, actual: Double) {
        guard let frame = pending.removeValue(forKey: target), actual > 0 else { return }
        presented.append(["target": frame.target, "encodedAt": frame.encodedAt, "actual": actual, "phase": frame.phase])
    }

    private func endMeasurement() {
        guard !finished, measurementEnd == nil else { return }
        sampleProcess()
        let end = ProcessSample.current()
        measurementEnd = end
        peakFootprint = max(peakFootprint, end.physicalBytes)
        submittedAtEnd = view?.submittedFrames ?? 0
        closePhase(at: end)
        sampleTimer?.invalidate()
        boundaryTimer?.invalidate()
        // Stop selecting new frames but keep the host unpaused for in-flight
        // presented callbacks. Pausing immediately would discard them by design.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.finish() }
    }

    private func summarizePresentation(_ records: [[String: Any]]) -> [String: Any] {
        let times = records.compactMap { $0["actual"] as? Double }.sorted()
        let intervals = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }
        let age = records.compactMap { row -> Double? in
            guard let actual = row["actual"] as? Double, let encoded = row["encodedAt"] as? Double else { return nil }
            return (actual - encoded) * 1000
        }
        let duration = (times.last ?? 0) - (times.first ?? 0)
        return ["frames": times.count, "actualFPS": duration > 0 ? Double(max(0, times.count - 1)) / duration : 0,
                "intervalMS": quantiles(intervals), "encodeToPresentMS": quantiles(age)]
    }

    private func quantiles(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func at(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count - 1) * p))] }
        return ["p50": at(0.50), "p95": at(0.95), "p99": at(0.99), "max": sorted.last ?? 0]
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let validFrames = presented.count > 0 && selectedFrames > 0
        if measurementStart != nil && !validFrames { failures.append("No measured selected/presented frames") }
        var phaseResults = phases
        for index in phaseResults.indices {
            let name = phaseResults[index]["phase"] as? String ?? ""
            phaseResults[index]["presentation"] = summarizePresentation(presented.filter { $0["phase"] as? String == name })
        }
        let duration = measurementStart.flatMap { start in measurementEnd.map { $0.uptime - start.uptime } } ?? 0
        let cpu = measurementStart.flatMap { start in measurementEnd.map { ($0.cpuSeconds - start.cpuSeconds) / max(1e-9, duration) * 100 } } ?? 0
        let counts = processSamples.compactMap { ($0["particles"] as? Int).map(Double.init) }
        let result: [String: Any] = [
            "label": options.label, "scenario": options.scenario, "particleBackend": backend,
            "decorations": options.decorations,
            "validWorkload": failures.isEmpty && validFrames,
            "scope": "isolated production renderer and SnowWorld; no DesktopEnvironment/CG/AX or whole-app CPU",
            "environment": environment, "arguments": CommandLine.arguments,
            "seed": 111, "surfaceCount": world.surfaces.count, "windowCount": 10, "balls": world.balls.count,
            "warmupRequestedSeconds": options.warmup,
            "warmupActualSeconds": (measurementStart?.uptime ?? measurementEnd?.uptime ?? startTime) - startTime,
            "warmupParticles": warmupParticles, "warmupSubmittedFrames": warmupFrames,
            "measurementRequestedSeconds": options.seconds, "measurementActualSeconds": duration,
            "cpuPercentOneCoreWeighted": cpu, "peakPhysicalBytes": peakFootprint,
            "particleCounts": ["minimum": counts.min() ?? 0, "maximum": counts.max() ?? 0,
                               "mean": counts.reduce(0, +) / Double(max(1, counts.count))],
            "rawDisplayCallbacks": rawCallbacks, "intentionallySkippedByPacer": skippedByPacer,
            "selectedFrames": selectedFrames, "submittedFrames": max(0, submittedAtEnd - submittedAtStart),
            "selectedWithoutSubmission": max(0, selectedFrames - (submittedAtEnd - submittedAtStart)),
            "selectedWithoutPresentedCallbackAfterDrain": pending.count,
            "firstTargetMinusHostSeconds": firstTargetMinusHost ?? 0,
            "presentation": summarizePresentation(presented), "phases": phaseResults,
            "processSamples": processSamples, "presentedFrames": presented, "errors": failures,
            "limitations": ["CPU includes this harness and presentation diagnostics, excludes desktop metadata polling",
                            "Geometry and focus are synthetic; no actual input or window-server latency is measured",
                            "Particle statistics may arrive asynchronously from GPU; sampled at one second intervals",
                            "Selected-without-callback is not a GPU dropped-frame counter; individual GPU timings are not exposed by this host",
                            "Percentiles use the ceil index of sorted actual presentation intervals; no FPS-budget acceptance is inferred"]
        ]
        do {
            try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: options.output, options: .atomic)
        } catch { fputs("Cannot write benchmark JSON: \(error)\n", stderr); exit(3) }
        print("RESULT \(options.output.path) valid=\(failures.isEmpty && validFrames) CPU=\(cpu)% frames=\(presented.count)")
        view?.isPaused = true
        view?.invalidate()
        window?.close()
        fflush(stdout)
        exit(failures.isEmpty && validFrames ? 0 : 2)
    }

    private func failBeforeStart(_ message: String) {
        failures.append(message)
        startTime = ProcessInfo.processInfo.systemUptime
        measurementEnd = ProcessSample.current()
        finish()
    }
}

@main
private enum GPUSimulationBenchmarkMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let benchmark = GPUSimulationBenchmark(options: BenchmarkOptions())
        app.delegate = benchmark
        withExtendedLifetime(benchmark) { app.run() }
    }
}
