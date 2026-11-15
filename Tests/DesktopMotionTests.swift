import AppKit

private struct MotionMessage: Codable {
    let kind: String
    let appliedAt: Double
    let pid: Int32
    let id: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct MotionDelivery: Codable {
    let deliveredAt: Double
    let captureMilliseconds: Double
    let accessibilityTrusted: Bool
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let geometryChanges: [MotionGeometryChanges]?
}

/// Only aggregate kinds leave memory; no unrelated IDs or frames enter evidence.
private struct MotionGeometryChanges: Codable {
    let kind: String
    var added = 0
    var removed = 0
    var moved = 0
}

private struct MotionSummary: Codable {
    let idleBeforeRate: Double
    let idleAfterRate: Double
    let appliedPoseRate: Double
    let observedPoseRate: Double
    let movingDeliveryRate: Double
    let intervalMedianMS: Double
    let intervalP95MS: Double
    let intervalMaximumMS: Double
    let onsetMS: Double
    let capturedPoseAgeMedianMS: Double
    let capturedPoseAgeP95MS: Double
    let heldPositionErrorMeanPT: Double
    let heldPositionErrorP95PT: Double
    let captureMedianMS: Double
    let captureP95MS: Double
    let missingMovingSnapshots: Int
    let axTrusted: Bool
}

private struct MotionReport: Codable {
    let mode: String
    let measurement: String
    let summary: MotionSummary?
    let failures: [String]
    let applied: [MotionMessage]
    let delivered: [MotionDelivery]
}

private final class MotionRunner {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let environment = DesktopEnvironment()
    private let evidence: URL
    private let mode: String
    private let comparison: URL?
    private var buffer = Data()
    private var applied: [MotionMessage] = []
    private var delivered: [MotionDelivery] = []
    private var previousGeometry: [String: (kind: String, frame: CGRect)] = [:]
    private var ready: MotionMessage?
    private var runSent = false
    private var doneReceived = false
    private var deadline = 0.0
    private(set) var finished = false
    private(set) var succeeded = false

    init(fixture: URL, evidence: URL, mode: String, comparison: URL?) {
        process.executableURL = fixture; process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        self.evidence = evidence; self.mode = mode; self.comparison = comparison
    }

    func start() {
        guard !NSScreen.screens.isEmpty else { finish(nil, failures: ["No GUI screen for own-window test"]); return }
        deadline = ProcessInfo.processInfo.systemUptime + 16
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        environment.onSnapshot = { [weak self] in self?.observe($0) }
        do { try process.run() }
        catch { finish(nil, failures: ["Cannot launch own fixture: \(error)"]); return }
        environment.start()
        print("Desktop motion \(mode): autonomous own window, no manual refresh, focus changes or global input")
        fflush(stdout)
    }

    func tick() {
        guard !finished else { return }
        if ProcessInfo.processInfo.systemUptime > deadline { finish(nil, failures: ["Own fixture timed out"]) }
        else if !process.isRunning { finish(nil, failures: ["Own fixture exited before measurement completed"]) }
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let message = try? JSONDecoder().decode(MotionMessage.self, from: line),
                  message.pid == process.processIdentifier,
                  message.appliedAt.isFinite, message.x.isFinite, message.y.isFinite,
                  message.width > 0, message.height > 0 else {
                finish(nil, failures: ["Malformed or foreign fixture message"]); return
            }
            applied.append(message)
            if message.kind == "ready" { ready = message }
            if message.kind == "done", !doneReceived {
                doneReceived = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.evaluate() }
            }
        }
    }

    private func observe(_ snapshot: DesktopSnapshot) {
        guard !finished, let ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Retain only the explicitly-created fixture's geometry. Other window
        // IDs, frames, labels and content are never logged by this measurement.
        let id = "window:\(ready.pid):\(ready.id)"
        let frame = snapshot.surfaces.first { $0.id == id }?.frame
        var currentGeometry: [String: (kind: String, frame: CGRect)] = [:]
        for surface in snapshot.surfaces {
            let kind = surface.id == id ? "own" : surface.kind == .dock ? "dock" : surface.kind == .floor ? "floor" : "other"
            currentGeometry[surface.id] = (kind, surface.frame)
        }
        var changes: [String: MotionGeometryChanges] = [:]
        for (surfaceID, current) in currentGeometry {
            if let previous = previousGeometry[surfaceID] {
                if previous.frame != current.frame {
                    changes[current.kind, default: MotionGeometryChanges(kind: current.kind)].moved += 1
                }
            } else {
                changes[current.kind, default: MotionGeometryChanges(kind: current.kind)].added += 1
            }
        }
        for (surfaceID, previous) in previousGeometry where currentGeometry[surfaceID] == nil {
            changes[previous.kind, default: MotionGeometryChanges(kind: previous.kind)].removed += 1
        }
        previousGeometry = currentGeometry
        delivered.append(MotionDelivery(deliveredAt: now, captureMilliseconds: snapshot.captureMilliseconds,
            accessibilityTrusted: snapshot.accessibilityTrusted, x: frame.map { Double($0.minX) },
            y: frame.map { Double($0.minY) }, width: frame.map { Double($0.width) }, height: frame.map { Double($0.height) },
            geometryChanges: changes.values.sorted { $0.kind < $1.kind }))
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
            finish(nil, failures: ["Own fixture unexpectedly became the active application"]); return
        }
        if !runSent, let frame, abs(Double(frame.minX) - ready.x) <= 1 {
            runSent = true
            try? input.fileHandleForWriting.write(contentsOf: Data("run\n".utf8))
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private func evaluate() {
        guard !finished else { return }
        func time(_ kind: String) -> Double? { applied.first { $0.kind == kind }?.appliedAt }
        guard let idleBefore = time("idleBefore"), let motion = time("motion"), let settle = time("settle"),
              let idleAfter = time("idleAfter"), let end = time("done"), let ready else {
            finish(nil, failures: ["Incomplete fixture phases"]); return
        }
        let steadyStart = motion + 0.3
        let steadyDuration = settle - steadyStart
        let poses = applied.filter { $0.kind == "pose" }
        let moving = delivered.filter { $0.deliveredAt >= steadyStart && $0.deliveredAt < settle }
        let intervals = zip(moving.dropFirst(), moving).map { ($0.deliveredAt - $1.deliveredAt) * 1000 }
        let changed = delivered.first { $0.deliveredAt >= motion && $0.x.map { abs($0 - ready.x) > 1 } == true }
        guard poses.count >= 2, moving.count >= 2, let first = poses.first, let changed, steadyDuration > 0 else {
            finish(nil, failures: ["No measurable continuous own-window movement"]); return
        }
        let validMoving = moving.filter { $0.x != nil }
        let distinct = Set(validMoving.compactMap { $0.x.map { Int(($0 * 1000).rounded()) } })
        let sourcePoses = [ready] + poses
        var ages: [Double] = [], errors: [Double] = []
        // Reconstruct what the consumer knew at each actual application movement.
        // This measures sample-and-hold geometry age, not GPU presentation latency.
        for pose in poses where pose.appliedAt >= steadyStart && pose.appliedAt < settle {
            guard let last = delivered.last(where: { $0.deliveredAt <= pose.appliedAt && $0.x != nil }), let x = last.x,
                  let source = sourcePoses.last(where: { $0.appliedAt <= last.deliveredAt && abs($0.x - x) < 0.5 }) else { continue }
            ages.append(max(0, pose.appliedAt - source.appliedAt) * 1000)
            errors.append(abs(pose.x - x))
        }
        let summary = MotionSummary(
            idleBeforeRate: Double(delivered.filter { $0.deliveredAt >= idleBefore && $0.deliveredAt < motion }.count) / (motion - idleBefore),
            idleAfterRate: Double(delivered.filter { $0.deliveredAt >= idleAfter && $0.deliveredAt < end }.count) / (end - idleAfter),
            appliedPoseRate: Double(poses.count) / (settle - motion), observedPoseRate: Double(distinct.count) / steadyDuration,
            movingDeliveryRate: Double(moving.count) / steadyDuration,
            intervalMedianMS: percentile(intervals, 0.5), intervalP95MS: percentile(intervals, 0.95),
            intervalMaximumMS: intervals.max() ?? 0, onsetMS: (changed.deliveredAt - first.appliedAt) * 1000,
            capturedPoseAgeMedianMS: percentile(ages, 0.5), capturedPoseAgeP95MS: percentile(ages, 0.95),
            heldPositionErrorMeanPT: errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count),
            heldPositionErrorP95PT: percentile(errors, 0.95),
            captureMedianMS: percentile(moving.map(\.captureMilliseconds), 0.5),
            captureP95MS: percentile(moving.map(\.captureMilliseconds), 0.95),
            missingMovingSnapshots: moving.count - validMoving.count,
            axTrusted: delivered.allSatisfy(\.accessibilityTrusted))
        var failures: [String] = []
        if summary.appliedPoseRate < 50 { failures.append("Fixture failed to apply at least50 poses/s") }
        if summary.missingMovingSnapshots > 0 { failures.append("Own fixture disappeared from \(summary.missingMovingSnapshots) moving snapshots") }
        if ages.count < 100 { failures.append("Insufficient matched poses for geometry-age measurement") }
        if mode == "fixed" {
            if summary.intervalMedianMS > 20 { failures.append("Moving delivery median exceeds20ms") }
            if summary.intervalP95MS > 35 { failures.append("Moving delivery p95 exceeds35ms") }
            if summary.idleBeforeRate > 8 || summary.idleAfterRate > 8 { failures.append("Idle delivery rate exceeds8/s") }
            let baseline = comparison.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(MotionReport.self, from: $0) }?.summary
            let doubled = baseline.map { summary.observedPoseRate >= $0.observedPoseRate * 2 } ?? false
            if summary.observedPoseRate < 40 && !doubled { failures.append("Observed poses are below40/s and less than twice baseline") }
        }
        finish(summary, failures: failures)
    }

    private func finish(_ summary: MotionSummary?, failures: [String]) {
        guard !finished else { return }
        finished = true; succeeded = failures.isEmpty
        environment.stop(); output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
            let limit = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < limit {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            if process.isRunning { process.terminate() }
        }
        try? input.fileHandleForWriting.close()
        let report = MotionReport(mode: mode,
            measurement: "Own AppKit geometry applied/delivered timestamps; not GPU presentation. Baseline is observation only.",
            summary: summary, failures: failures, applied: applied, delivered: delivered)
        do {
            try FileManager.default.createDirectory(at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: evidence, options: .atomic)
        } catch { succeeded = false; print("Cannot write evidence: \(error)") }
        if let summary {
            print(String(format: "motion median=%.2fms p95=%.2fms max=%.2fms observed=%.2f/s applied=%.2f/s onset=%.2fms",
                summary.intervalMedianMS, summary.intervalP95MS, summary.intervalMaximumMS,
                summary.observedPoseRate, summary.appliedPoseRate, summary.onsetMS))
            print(String(format: "idle before=%.2f/s after=%.2f/s; held age median=%.2fms p95=%.2fms; error mean=%.2fpt p95=%.2fpt; capture median=%.2fms p95=%.2fms; AX=%@",
                summary.idleBeforeRate, summary.idleAfterRate, summary.capturedPoseAgeMedianMS, summary.capturedPoseAgeP95MS,
                summary.heldPositionErrorMeanPT, summary.heldPositionErrorP95PT, summary.captureMedianMS, summary.captureP95MS,
                summary.axTrusted ? "true" : "false"))
        }
        for failure in failures { print("FAIL: \(failure)") }
        print(succeeded ? (mode == "baseline" ? "BASELINE observation saved (no fixed-speed acceptance claimed)" : "PASS fixed motion/idle acceptance") : "FAILED measurement")
    }
}

@main
private enum DesktopMotionTestsMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4, ["baseline", "fixed"].contains(args[3]) else {
            print("Usage: DesktopMotionTests <fixture executable> <evidence.json> <baseline|fixed> [baseline.json]"); exit(2)
        }
        let runner = MotionRunner(fixture: URL(fileURLWithPath: args[1]), evidence: URL(fileURLWithPath: args[2]),
            mode: args[3], comparison: args.count > 4 ? URL(fileURLWithPath: args[4]) : nil)
        runner.start()
        while !runner.finished { RunLoop.main.run(until: Date().addingTimeInterval(0.005)); runner.tick() }
        exit(runner.succeeded ? 0 : 1)
    }
}
