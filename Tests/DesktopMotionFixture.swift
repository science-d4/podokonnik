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

private final class MotionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MotionFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: MotionWindow?
    private var timer: DispatchSourceTimer?
    private var watchdog: Timer?
    private var running = false
    private var origin = CGPoint.zero
    private var travel: CGFloat = 360

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let area = NSScreen.screens.first?.visibleFrame, area.width >= 640, area.height >= 400 else {
            NSApp.terminate(nil); return
        }
        origin = CGPoint(x: area.minX + 50, y: area.minY + 80)
        travel = min(540, area.width - 380)
        let window = MotionWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 280, height: 160)),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Подоконник · проверка движения"
        window.isReleasedWhenClosed = false; window.isFloatingPanel = false
        window.level = .normal; window.hidesOnDeactivate = false; window.animationBehavior = .none
        let label = NSTextField(labelWithString: "Собственное тестовое окно\nЗакроется автоматически")
        label.frame = CGRect(x: 16, y: 45, width: 250, height: 60)
        label.font = .systemFont(ofSize: 15); window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        self.window = window; origin = window.frame.origin
        watchdog = Timer.scheduledTimer(withTimeInterval: 18, repeats: false) { _ in NSApp.terminate(nil) }
        emit("ready")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let data = FileHandle.standardInput.availableData
                guard !data.isEmpty else { DispatchQueue.main.async { NSApp.terminate(nil) }; return }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let command = String(decoding: buffer[..<end], as: UTF8.self)
                    buffer.removeSubrange(...end)
                    DispatchQueue.main.async {
                        if command == "run" { self?.runPhases() }
                        else { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    private func runPhases() {
        guard !running else { return }
        running = true; emit("warmup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.emit("idleBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.move() }
        }
    }

    private func move() {
        emit("motion")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var step = 0
        timer.setEventHandler { [weak self] in
            guard let self, let window = self.window else { return }
            step += 1
            let distance = min(self.travel, CGFloat(step) * self.travel / 180)
            window.setFrameOrigin(CGPoint(x: (self.origin.x + distance).rounded(), y: self.origin.y))
            self.emit("pose")
        }
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        timer.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.timer?.cancel(); self.timer = nil; self.emit("settle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.emit("idleAfter")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.emit("done") }
            }
        }
    }

    private func emit(_ kind: String) {
        guard let window else { return }
        let frame = window.frame
        let message = MotionMessage(kind: kind, appliedAt: ProcessInfo.processInfo.systemUptime,
            pid: getpid(), id: UInt32(window.windowNumber), x: frame.minX, y: frame.minY,
            width: frame.width, height: frame.height)
        if let data = try? JSONEncoder().encode(message) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel(); watchdog?.invalidate(); window?.close()
    }
}

@main
private enum DesktopMotionFixtureMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = MotionFixtureDelegate(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
