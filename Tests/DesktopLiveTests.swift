import AppKit

private struct FixtureWindowState: Codable {
    var name: String
    var id: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var visible: Bool
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct FixtureState: Codable {
    var stage: String
    var pid: Int32
    var windows: [FixtureWindowState]
}

private final class DesktopLiveRunner {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let environment = DesktopEnvironment()
    private var buffer = Data()
    private var expected: FixtureState?
    private var logs: [String] = []
    private let stages = ["ready", "move", "resize", "reorder", "minimize", "restore", "close"]
    private var index = 0
    private var deadline = Date()
    private var sentAt = ProcessInfo.processInfo.systemUptime
    private var initialFrames: [String: CGRect] = [:]
    private var frontmostBefore: pid_t?
    private var evidence: URL
    private(set) var finished = false
    private(set) var succeeded = false
    private var lastProblem = "fixture has not reported readiness"

    init(fixture: URL, evidence: URL) {
        process.executableURL = fixture
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        self.evidence = evidence
    }

    func start() {
        guard !NSScreen.screens.isEmpty else {
            finish(false, "No GUI screens are available. Run this test outside the sandbox in the current GUI session.")
            return
        }
        frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        log("DesktopLiveTests: own fixture windows only; no screen capture, global events or TCC changes")
        log("OS: \(ProcessInfo.processInfo.operatingSystemVersionString); screens: \(NSScreen.screens.count)")
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        do { try process.run() }
        catch { finish(false, "Cannot launch own fixture: \(error)"); return }
        deadline = Date().addingTimeInterval(3)
        sentAt = ProcessInfo.processInfo.systemUptime
        environment.onSnapshot = { [weak self] snapshot in self?.check(snapshot) }
        environment.start()
    }

    func tick() {
        guard !finished else { return }
        if Date() > deadline { finish(false, "Timeout at \(stages[index]): \(lastProblem)") }
        else if !process.isRunning { finish(false, "Fixture exited before test completion") }
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let state = try? JSONDecoder().decode(FixtureState.self, from: line),
                  state.pid == process.processIdentifier, state.stage == stages[index] else {
                finish(false, "Unexpected or malformed fixture response")
                return
            }
            expected = state
            lastProblem = "waiting for geometry to match fixture"
            if index == 0 { initialFrames = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.name, $0.frame) }) }
            environment.refresh()
        }
    }

    private func check(_ snapshot: DesktopSnapshot) {
        guard !finished, let expected else { return }
        let prefix = "window:\(expected.pid):"
        let surfaces = snapshot.surfaces.filter { $0.id.hasPrefix(prefix) }
        let byName = Dictionary(uniqueKeysWithValues: expected.windows.map { ($0.name, $0) })
        func surface(_ name: String) -> SnowSurface? {
            guard let window = byName[name] else { return nil }
            return surfaces.first { $0.id == prefix + String(window.id) }
        }
        for window in expected.windows {
            let actual = surface(window.name)
            if window.visible {
                guard let actual, near(actual.frame, window.frame) else {
                    lastProblem = "visible window \(window.name) missing or bounds differ"
                    return
                }
            } else if actual != nil {
                lastProblem = "hidden/closed window \(window.name) still has a surface"
                return
            }
        }
        let visibleCount = expected.windows.filter(\.visible).count
        guard surfaces.count == visibleCount else {
            lastProblem = "unexpected number of own fixture surfaces"
            return
        }

        let order = index == 3 || index == 4 ? ["B", "C", "A"] : ["C", "B", "A"]
        let visibleOrder = order.filter { byName[$0]?.visible == true }
        for (position, name) in visibleOrder.enumerated() {
            guard let current = surface(name) else { return }
            for above in visibleOrder.prefix(position) {
                guard let frame = byName[above]?.frame,
                      current.occluders.contains(where: { near($0, frame) }) else {
                    lastProblem = "\(name) lacks foreground occluder \(above)"
                    return
                }
            }
            for below in visibleOrder.dropFirst(position + 1) {
                if let frame = byName[below]?.frame, current.occluders.contains(where: { near($0, frame) }) {
                    lastProblem = "background window \(below) incorrectly occludes \(name)"
                    return
                }
            }
        }
        if index >= 1, let initialB = initialFrames["B"], let a = surface("A"),
           a.occluders.contains(where: { near($0, initialB) }) {
            lastProblem = "old B position remains in the foreground mask"
            return
        }
        if index == 4 || index == 6, let c = byName["C"]?.frame,
           surfaces.contains(where: { $0.occluders.contains(where: { near($0, c) }) }) {
            lastProblem = "minimized/closed C remains an occluder"
            return
        }
        if let c = byName["C"], ["minimize", "restore", "close"].contains(expected.stage) {
            let retained = snapshot.hiddenWindowSupportIDs.contains(prefix + String(c.id))
            if retained != (expected.stage == "minimize") {
                lastProblem = "offscreen support identity did not match \(expected.stage)"
                return
            }
        }
        let frontmostNow = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostNow != process.processIdentifier else {
            finish(false, "Fixture stole application focus")
            return
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - sentAt) * 1000
        log(String(format: "PASS %@: %d own surfaces, bounds/order/removal verified, %.1f ms", stages[index], surfaces.count, milliseconds))
        if index == stages.count - 1 {
            if frontmostNow != frontmostBefore { log("NOTE: foreground app changed externally; fixture was never observed active") }
            finish(true, "PASS: 7 live stages; foreign window names/content were neither read nor logged")
            return
        }
        index += 1
        self.expected = nil
        sentAt = ProcessInfo.processInfo.systemUptime
        deadline = Date().addingTimeInterval(2)
        lastProblem = "fixture has not acknowledged command"
        do { try input.fileHandleForWriting.write(contentsOf: Data((stages[index] + "\n").utf8)) }
        catch { finish(false, "Cannot send command to own fixture: \(error)") }
    }

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    private func log(_ text: String) { logs.append(text); print(text); fflush(stdout) }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }
        finished = true
        succeeded = success
        environment.stop()
        log(message)
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if process.isRunning { process.terminate() } // Only the child created by this runner.
        }
        try? input.fileHandleForWriting.close()
        do {
            try FileManager.default.createDirectory(at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
            try logs.joined(separator: "\n").appending("\n").write(to: evidence, atomically: true, encoding: .utf8)
        } catch { print("Cannot save evidence: \(error)") }
    }
}

@main
private struct DesktopLiveTestsMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            print("Usage: DesktopLiveTests <DesktopFixture.app/Contents/MacOS/DesktopFixture> <evidence.txt>")
            exit(2)
        }
        let runner = DesktopLiveRunner(fixture: URL(fileURLWithPath: args[1]), evidence: URL(fileURLWithPath: args[2]))
        runner.start()
        while !runner.finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            runner.tick()
        }
        exit(runner.succeeded ? 0 : 1)
    }
}
