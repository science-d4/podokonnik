import AppKit
import QuartzCore

private struct FixturePose: Codable {
    let kind: String
    let appliedAt: Double
    let pid: Int32
    let id: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct GeometryChanges: Codable {
    let kind: String
    var added = 0, removed = 0, moved = 0
}

private struct CaptureRecord: Codable {
    let deliveredAt: Double
    let captureMilliseconds: Double
    let trusted: Bool
    let ownX: Double?
    let dockCount: Int
    let dockVisibleCount: Int
    let changes: [GeometryChanges]
}

private struct FrameGeometry: Codable {
    let targetTime: Double
    let acceptedAt: Double
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
}

private struct PresentedGeometry: Codable {
    let frame: FrameGeometry
    let actualTime: Double
    let actualUptime: Double
    let callbackAt: Double
}

private struct PresentationSummary: Codable {
    let appliedPoseRate: Double
    let captureIdleBeforeRate: Double
    let captureMovingRate: Double
    let captureIdleAfterRate: Double
    let presentIdleBeforeRate: Double
    let presentMovingRate: Double
    let presentIdleAfterRate: Double
    let presentedAgeMedianMS: Double
    let presentedAgeP95MS: Double
    let presentedErrorMeanPT: Double
    let presentedErrorP95PT: Double
    let encodingToPresentMedianMS: Double
    let encodingToPresentP95MS: Double
    let matchedPresentedFrames: Int
    let missingOwnGeometryFrames: Int
    let idleBeforeContaminated: Bool
    let idleAfterContaminated: Bool
    let idleDockAbsentSnapshots: Int
    let idleDockHiddenSnapshots: Int
    let idleDockFrameChanges: Int
    let axTrusted: Bool
    var frameIntervalP95MS: Double? = nil
    var cpuPercentOfCore: Double? = nil
    var physicalMiB: Double? = nil
    var duckFrames: Int? = nil
}

private struct PresentationReport: Codable {
    let mode: String
    let measurement: String
    let clockOffsetBefore: Double
    let clockOffsetAfter: Double
    let nativeMaximumFPS: Int
    let summary: PresentationSummary?
    let failures: [String]
    let applied: [FixturePose]
    let captures: [CaptureRecord]
    let presented: [PresentedGeometry]
    let acceptedFrames: Int
    let unmatchedCallbacks: Int
}

private final class PresentationMotionRunner {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let desktop = DesktopEnvironment()
    private let world = SnowWorld(seed: 14)
    private var pacer = FramePacer()
    private let weather = SnowWeather(intensity: .steady)
    private let evidence: URL
    private let comparison: URL?
    private let mode: String
    private var window: NSWindow?
    private var scene: SnowScene?
    private var view: UnifiedSnowView?
    private var screenFrame = CGRect.zero
    private var nativeMaximum = 60
    private var buffer = Data()
    private var ready: FixturePose?
    private var applied: [FixturePose] = []
    private var captures: [CaptureRecord] = []
    private var presented: [PresentedGeometry] = []
    private var pending: [Double: FrameGeometry] = [:]
    private var previousGeometry: [String: (kind: String, frame: CGRect)] = [:]
    private var seeded = false, runSent = false, doneReceived = false
    private var lastFrame: Double?
    private var acceptedFrames = 0, unmatchedCallbacks = 0
    private var clockOffsetBefore = 0.0
    private var deadline = 0.0
    private var watchdog: Timer?
    private var finished = false
    #if PRESENTATION_FIXED
    private let duck = DuckWorld(seed: 31)
    private let trees = FestiveWorld()
    private var duckFrames = 0
    private var processStart: ProcessSample?
    private var region: DuckDisplay?
    #endif

    init(fixture: URL, evidence: URL, mode: String, comparison: URL?) {
        process.executableURL = fixture; process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        self.evidence = evidence; self.mode = mode; self.comparison = comparison
    }

    func start() {
        guard let screen = NSScreen.screens.first else { finish(nil, failures: ["No GUI screen"]); return }
        screenFrame = screen.frame; nativeMaximum = screen.maximumFramesPerSecond
        clockOffsetBefore = ProcessInfo.processInfo.systemUptime - CACurrentMediaTime()
        deadline = ProcessInfo.processInfo.systemUptime + 20
        let scene = SnowScene(world: world, displayFrame: screenFrame)
        scene.weather = weather; self.scene = scene
        #if PRESENTATION_FIXED
        if mode.hasPrefix("duck-") {
            scene.duckWorld = duck
            scene.decorationOptions.duck = mode == "duck-on"
            duck.setEnabled(scene.decorationOptions.duck, surfaces: [])
            region = DuckDisplay(frame: screenFrame, visibleTop: screen.visibleFrame.maxY)
        }
        #endif
        let frame = CGRect(origin: .zero, size: screenFrame.size)
        guard let view = UnifiedSnowView(frame: frame, scene: scene, maximumFPS: nativeMaximum,
            shouldRender: { [weak self] time in self?.shouldRender(time) ?? false }) else {
            finish(nil, failures: ["Production UnifiedSnowView initialization failed"]); return
        }
        self.view = view
        let window = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.ignoresMouseEvents = true; window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = view; self.window = window
        scene.onFrame = { [weak self] in self?.advance($0) }
        view.onFramePresented = { [weak self] target, actual in self?.didPresent(target, actual) }
        view.onFailure = { [weak self] in self?.finish(nil, failures: ["Renderer failure: \($0)"]) }
        world.prune(to: [screenFrame])
        window.orderFrontRegardless()
        desktop.excludedWindowIDs = [UInt32(window.windowNumber)]
        desktop.onSnapshot = { [weak self] in self?.observe($0) }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        do { try process.run() }
        catch { finish(nil, failures: ["Cannot launch own fixture: \(error)"]); return }
        view.isPaused = false
        desktop.start()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        print("Presentation motion \(mode): own window, production Desktop→World→Scene→Unified→presentedTime; no per-move refresh")
    }

    private func shouldRender(_ time: Double) -> Bool {
        guard !finished else { return false }
        #if PRESENTATION_BASELINE
        pacer.rate = 60 // Unchanged 1.3.1 policy; native display callbacks still bound the output.
        #else
        pacer.rate = FramePacer.preferredRate(nativeMaximum: nativeMaximum,
                                              isMoving: desktop.isGeometryMoving, constrained: false)
        #endif
        return pacer.shouldRender(at: time)
    }

    private func advance(_ time: Double) {
        guard !finished else { return }
        desktop.noteInteraction() // Same production tick hook; this test never synthesizes input.
        let delta = lastFrame.map { max(0, time - $0) } ?? 1.0 / 60
        lastFrame = time
        world.step(delta: min(0.1, delta), weather: weather, activeRegions: [screenFrame])
        #if PRESENTATION_FIXED
        if let region, mode == "duck-on" {
            duck.advance(delta: delta, snow: world, trees: trees, treesEnabled: false, displays: [region],
                         allDisplayFrames: [screenFrame], plows: [:], sweeps: [], reducedMotion: false)
            if duck.pose != nil { duckFrames += 1 }
        }
        #endif
        let frame = world.surfaces.first?.frame
        pending[time] = FrameGeometry(targetTime: time, acceptedAt: ProcessInfo.processInfo.systemUptime,
            x: frame.map { Double($0.minX) }, y: frame.map { Double($0.minY) },
            width: frame.map { Double($0.width) }, height: frame.map { Double($0.height) })
        acceptedFrames += 1
    }

    private func didPresent(_ target: Double, _ actual: Double) {
        guard !finished else { return }
        guard let frame = pending.removeValue(forKey: target) else { unmatchedCallbacks += 1; return }
        presented.append(PresentedGeometry(frame: frame, actualTime: actual,
            actualUptime: actual + clockOffsetBefore, callbackAt: ProcessInfo.processInfo.systemUptime))
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let pose = try? JSONDecoder().decode(FixturePose.self, from: line),
                  pose.pid == process.processIdentifier, pose.appliedAt.isFinite,
                  pose.x.isFinite, pose.y.isFinite, pose.width > 0, pose.height > 0 else {
                finish(nil, failures: ["Malformed or foreign fixture message"]); return
            }
            applied.append(pose)
            if pose.kind == "ready" { ready = pose }
            #if PRESENTATION_FIXED
            if pose.kind == "idleBefore" { processStart = ProcessSample.current() }
            #endif
            if pose.kind == "done", !doneReceived {
                doneReceived = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.evaluate() }
            }
        }
    }

    private func observe(_ snapshot: DesktopSnapshot) {
        guard !finished, let ready else { return }
        let id = "window:\(ready.pid):\(ready.id)"
        let surface = snapshot.surfaces.first { $0.id == id }
        // Only our fixture is rendered. All other geometry is reduced to counts
        // in memory; no foreign IDs, rects, titles, images or content are logged.
        var surfaces = surface.map { [$0] } ?? []
        #if PRESENTATION_FIXED
        if region != nil {
            surfaces.append(SnowSurface(id: "floor:fixture",
                frame: CGRect(x: screenFrame.minX, y: screenFrame.minY - 1, width: screenFrame.width, height: 1), kind: .floor))
        }
        #endif
        world.syncSurfaces(surfaces)
        #if PRESENTATION_FIXED
        duck.sync(world.surfaces)
        #endif
        if surface != nil, !seeded {
            seeded = true
            for _ in 0..<300 { world.step(delta: 0.1, weather: weather, activeRegions: [screenFrame]) }
        }
        var current: [String: (kind: String, frame: CGRect)] = [:]
        for item in snapshot.surfaces {
            let kind = item.id == id ? "own" : item.kind == .dock ? "dock" : item.kind == .floor ? "floor" : "other"
            current[item.id] = (kind, item.frame)
        }
        var changes: [String: GeometryChanges] = [:]
        for (key, value) in current {
            if let old = previousGeometry[key] {
                if old.frame != value.frame { changes[value.kind, default: GeometryChanges(kind: value.kind)].moved += 1 }
            } else { changes[value.kind, default: GeometryChanges(kind: value.kind)].added += 1 }
        }
        for (key, old) in previousGeometry where current[key] == nil {
            changes[old.kind, default: GeometryChanges(kind: old.kind)].removed += 1
        }
        previousGeometry = current
        let dock = snapshot.surfaces.filter { $0.kind == .dock }
        captures.append(CaptureRecord(deliveredAt: ProcessInfo.processInfo.systemUptime,
            captureMilliseconds: snapshot.captureMilliseconds, trusted: snapshot.accessibilityTrusted,
            ownX: surface.map { Double($0.frame.minX) }, dockCount: dock.count,
            dockVisibleCount: dock.filter(\.isVisible).count, changes: changes.values.sorted { $0.kind < $1.kind }))
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
            finish(nil, failures: ["Fixture unexpectedly became active"]); return
        }
        if !runSent, surface != nil, presented.contains(where: { $0.frame.x != nil }) {
            runSent = true
            try? input.fileHandleForWriting.write(contentsOf: Data("run\n".utf8))
        }
    }

    private func tick() {
        guard !finished else { return }
        if ProcessInfo.processInfo.systemUptime > deadline { finish(nil, failures: ["Own presentation fixture timed out"]) }
        else if !process.isRunning { finish(nil, failures: ["Own fixture exited early"]) }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private func evaluate() {
        guard !finished else { return }
        func phase(_ kind: String) -> Double? { applied.first { $0.kind == kind }?.appliedAt }
        guard let idle = phase("idleBefore"), let motion = phase("motion"), let settle = phase("settle"),
              let after = phase("idleAfter"), let end = phase("done"), let ready else {
            finish(nil, failures: ["Missing fixture phases"]); return
        }
        let steady = motion + 0.3
        let moving = presented.filter { $0.actualUptime >= steady && $0.actualUptime < settle }
        let poses = applied.filter { $0.kind == "pose" }
        let source = [ready] + poses
        var ages: [Double] = [], errors: [Double] = []
        for item in moving {
            guard let x = item.frame.x,
                  let used = source.last(where: { $0.appliedAt <= item.frame.acceptedAt && abs($0.x - x) < 0.5 }),
                  let latest = source.last(where: { $0.appliedAt <= item.actualUptime }) else { continue }
            ages.append((item.actualUptime - used.appliedAt) * 1000)
            errors.append(abs(latest.x - x))
        }
        func rate(_ times: [Double], _ start: Double, _ end: Double) -> Double {
            Double(times.filter { $0 >= start && $0 < end }.count) / (end - start)
        }
        func contaminated(_ start: Double, _ end: Double) -> Bool {
            captures.contains { $0.deliveredAt >= start - 0.65 && $0.deliveredAt < end && !$0.changes.isEmpty }
        }
        let idleCaptures = captures.filter { ($0.deliveredAt >= idle && $0.deliveredAt < motion)
            || ($0.deliveredAt >= after && $0.deliveredAt < end) }
        let renderTimes = presented.map(\.actualUptime), captureTimes = captures.map(\.deliveredAt)
        var summary = PresentationSummary(appliedPoseRate: Double(poses.count) / (settle - motion),
            captureIdleBeforeRate: rate(captureTimes, idle, motion), captureMovingRate: rate(captureTimes, steady, settle),
            captureIdleAfterRate: rate(captureTimes, after, end),
            presentIdleBeforeRate: rate(renderTimes, idle, motion), presentMovingRate: rate(renderTimes, steady, settle),
            presentIdleAfterRate: rate(renderTimes, after, end),
            presentedAgeMedianMS: percentile(ages, 0.5), presentedAgeP95MS: percentile(ages, 0.95),
            presentedErrorMeanPT: errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count),
            presentedErrorP95PT: percentile(errors, 0.95),
            encodingToPresentMedianMS: percentile(moving.map { ($0.actualUptime - $0.frame.acceptedAt) * 1000 }, 0.5),
            encodingToPresentP95MS: percentile(moving.map { ($0.actualUptime - $0.frame.acceptedAt) * 1000 }, 0.95),
            matchedPresentedFrames: ages.count, missingOwnGeometryFrames: moving.filter { $0.frame.x == nil }.count,
            idleBeforeContaminated: contaminated(idle, motion), idleAfterContaminated: contaminated(after, end),
            idleDockAbsentSnapshots: idleCaptures.filter { $0.dockCount == 0 }.count,
            idleDockHiddenSnapshots: idleCaptures.filter { $0.dockCount > 0 && $0.dockVisibleCount == 0 }.count,
            idleDockFrameChanges: idleCaptures.flatMap(\.changes).filter { $0.kind == "dock" }.reduce(0) { $0 + $1.moved + $1.added + $1.removed },
            axTrusted: captures.allSatisfy(\.trusted))
        var failures: [String] = []
        if summary.appliedPoseRate < 50 { failures.append("Fixture applied fewer than50 poses/s") }
        if ages.count < 80 || summary.missingOwnGeometryFrames > 0 { failures.append("Insufficient matching presented own geometry") }
        if unmatchedCallbacks != 0 { failures.append("Presented callback has no accepted scene frame") }
        if ages.contains(where: { $0 < 0 }) { failures.append("Presented pose age is negative") }
        if abs(clockOffsetBefore - (ProcessInfo.processInfo.systemUptime - CACurrentMediaTime())) > 0.002 {
            failures.append("Uptime/Metal clock offset changed by more than2ms")
        }
        #if PRESENTATION_FIXED
        if mode.hasPrefix("duck-"), let processStart {
            let end = ProcessSample.current()
            summary.cpuPercentOfCore = (end.cpuSeconds - processStart.cpuSeconds) / (end.uptime - processStart.uptime) * 100
            summary.physicalMiB = Double(end.physicalBytes) / 1_048_576
            summary.frameIntervalP95MS = percentile(zip(moving, moving.dropFirst()).map {
                ($1.actualUptime - $0.actualUptime) * 1000
            }, 0.95)
            summary.duckFrames = duckFrames
            if mode == "duck-on" && duckFrames == 0 { failures.append("Fixture did not exercise duck drawing") }
        }
        #endif
        if mode == "fixed" || mode.hasPrefix("duck-") {
            let idleRenderUpperBound = Double(min(nativeMaximum, 60)) + 5
            if summary.presentIdleBeforeRate > idleRenderUpperBound || summary.presentIdleAfterRate > idleRenderUpperBound {
                failures.append("Renderer did not return to its native-capped60FPS idle policy")
            }
            if summary.idleBeforeContaminated || summary.idleAfterContaminated {
                failures.append("Idle geometry contamination: cadence acceptance inconclusive")
            }
            if summary.captureIdleBeforeRate > 8 || summary.captureIdleAfterRate > 8 { failures.append("Idle completed captures exceed8/s") }
            let baseline = comparison.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(PresentationReport.self, from: $0) }?.summary
            if let baseline {
                if summary.presentedAgeMedianMS >= baseline.presentedAgeMedianMS { failures.append("Presented median pose age did not improve") }
                if summary.presentedAgeP95MS > baseline.presentedAgeP95MS { failures.append("Presented p95 pose age worsened") }
                if summary.presentedErrorMeanPT > baseline.presentedErrorMeanPT { failures.append("Presented mean X error worsened") }
            } else if mode == "fixed" { failures.append("Missing baseline presentation summary") }
        }
        finish(summary, failures: failures)
    }

    private func finish(_ summary: PresentationSummary?, failures: [String]) {
        guard !finished else { return }
        finished = true; watchdog?.invalidate(); desktop.stop()
        view?.invalidate(); window?.close(); window = nil
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
            let limit = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < limit {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            if process.isRunning { process.terminate() }
        }
        let report = PresentationReport(mode: mode,
            measurement: "Applied own setFrameOrigin → production snow drawable.presentedTime; not optical relative lag against the fixture window's own presentation.",
            clockOffsetBefore: clockOffsetBefore, clockOffsetAfter: ProcessInfo.processInfo.systemUptime - CACurrentMediaTime(),
            nativeMaximumFPS: nativeMaximum, summary: summary, failures: failures,
            applied: applied, captures: captures, presented: presented, acceptedFrames: acceptedFrames, unmatchedCallbacks: unmatchedCallbacks)
        var success = failures.isEmpty
        do {
            try FileManager.default.createDirectory(at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: evidence, options: .atomic)
        } catch { success = false; print("Cannot save evidence: \(error)") }
        if let s = summary {
            print(String(format: "presented age median=%.2fms p95=%.2fms; Xerror mean=%.2fpt p95=%.2fpt; encode→present median=%.2fms p95=%.2fms",
                s.presentedAgeMedianMS, s.presentedAgeP95MS, s.presentedErrorMeanPT, s.presentedErrorP95PT,
                s.encodingToPresentMedianMS, s.encodingToPresentP95MS))
            print(String(format: "presentation before/motion/after=%.2f/%.2f/%.2f per sec; capture=%.2f/%.2f/%.2f; AX=%@",
                s.presentIdleBeforeRate, s.presentMovingRate, s.presentIdleAfterRate,
                s.captureIdleBeforeRate, s.captureMovingRate, s.captureIdleAfterRate, s.axTrusted ? "true" : "false"))
            print("idle contamination before=\(s.idleBeforeContaminated) after=\(s.idleAfterContaminated); Dock absent=\(s.idleDockAbsentSnapshots) hidden=\(s.idleDockHiddenSnapshots) changed=\(s.idleDockFrameChanges)")
        }
        for failure in failures { print("FAIL: \(failure)") }
        print(success ? (mode == "baseline" ? "BASELINE presentation observation saved" : "PASS presented motion and stable idle acceptance") : "FAILED presentation measurement")
        exit(success ? 0 : 1)
    }
}

@main
private enum PresentationMotionTestsMain {
    static func main() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count >= 4, ["baseline", "fixed", "duck-on", "duck-off"].contains(args[3]) else { exit(2) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let runner = PresentationMotionRunner(fixture: URL(fileURLWithPath: args[1]), evidence: URL(fileURLWithPath: args[2]),
            mode: args[3], comparison: args.count > 4 ? URL(fileURLWithPath: args[4]) : nil)
        DispatchQueue.main.async { runner.start() }
        NSApp.run()
        withExtendedLifetime(runner) {}
    }
}
