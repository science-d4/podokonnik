import AppKit

private struct FixtureWindowState: Codable {
    var name: String
    var id: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var visible: Bool
}

private struct FixtureState: Codable {
    var stage: String
    var pid: Int32
    var windows: [FixtureWindowState]
}

/// These windows never become key/main and the fixture never calls activate().
private final class FixtureWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [String: FixtureWindow] = [:]
    private var ids: [String: UInt32] = [:]
    private var watchdog: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var pendingTransition: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as an accessory to avoid normal launch activation. The geometry
        // provider intentionally supports regular apps, so change policy afterwards.
        NSApp.setActivationPolicy(.regular)
        guard let screen = NSScreen.screens.first else { NSApp.terminate(nil); return }
        let area = screen.visibleFrame
        let origin = CGPoint(x: area.minX + 60, y: area.minY + 80)
        let frames: [(String, CGRect)] = [
            ("A", CGRect(x: origin.x, y: origin.y, width: 360, height: 200)),
            ("B", CGRect(x: origin.x + 100, y: origin.y + 65, width: 320, height: 190)),
            ("C", CGRect(x: origin.x + 180, y: origin.y + 25, width: 250, height: 200))
        ]
        for (name, frame) in frames {
            let window = FixtureWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.title = "Подоконник · тестовое окно \(name)"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = false
            window.level = .normal
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            let label = NSTextField(labelWithString: "Тест геометрии \(name)\nОкно закроется автоматически")
            label.frame = CGRect(x: 18, y: 40, width: 300, height: 60)
            label.font = .systemFont(ofSize: 17)
            window.contentView?.addSubview(label)
            window.orderFrontRegardless()
            windows[name] = window
            ids[name] = UInt32(window.windowNumber)
        }
        if let c = windows["C"] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: c, queue: .main) { [weak self] _ in
                guard let self, self.pendingTransition == "minimize" else { return }
                self.pendingTransition = nil
                self.emit("minimize")
            })
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: c, queue: .main) { [weak self] _ in
                guard let self, self.pendingTransition == "restore" else { return }
                self.pendingTransition = nil
                self.windows["C"]?.orderFrontRegardless()
                self.emit("restore")
            })
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in NSApp.terminate(nil) }
        emit("ready")
        readCommands()
    }

    private func readCommands() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty {
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { self?.apply(line) }
                }
            }
        }
    }

    private func apply(_ command: String) {
        var closed: FixtureWindow?
        switch command {
        case "move":
            if let b = windows["B"] { b.setFrame(b.frame.offsetBy(dx: 140, dy: -35), display: true, animate: false) }
        case "resize":
            if let a = windows["A"] {
                var frame = a.frame
                frame.size.width += 70
                frame.size.height += 30
                a.setFrame(frame, display: true, animate: false)
            }
        case "reorder": windows["B"]?.orderFrontRegardless()
        case "minimize":
            // miniaturize() schedules the transition. isMiniaturized can still be
            // false until AppKit finishes it; acknowledge the did-notification.
            pendingTransition = "minimize"
            windows["C"]?.miniaturize(nil)
            return
        case "restore":
            pendingTransition = "restore"
            windows["C"]?.deminiaturize(nil)
            return
        case "close":
            closed = windows["C"]
            closed?.close()
        case "quit": NSApp.terminate(nil); return
        default: NSApp.terminate(nil); return
        }
        emit(command)
        if closed != nil { windows.removeValue(forKey: "C") }
    }

    private func emit(_ stage: String) {
        let state = FixtureState(stage: stage, pid: getpid(), windows: ["A", "B", "C"].compactMap { name in
            guard let window = windows[name], let id = ids[name] else { return nil }
            let frame = window.frame
            return FixtureWindowState(name: name, id: id, x: Double(frame.minX), y: Double(frame.minY),
                                      width: Double(frame.width), height: Double(frame.height),
                                      visible: window.isVisible && !window.isMiniaturized)
        })
        if let data = try? JSONEncoder().encode(state) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.invalidate()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windows.values.forEach { $0.close() }
    }
}

@main
private struct DesktopFixtureMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
