import AppKit
import Foundation

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var updater: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let marker = bundle.object(forInfoDictionaryKey: "UpdateTestMarker") as? String else {
            NSApp.terminate(nil); return
        }
        try? Data(version.utf8).write(to: URL(fileURLWithPath: marker), options: .atomic)
        if version == "1.0.1" { NSApp.terminate(nil); return }
        updater = UpdateController()
        let arguments = CommandLine.arguments
        if arguments.contains("--disable-updates") { updater?.setAutomaticUpdatesEnabled(false) }
        if arguments.contains("--enable-updates") { updater?.setAutomaticUpdatesEnabled(true) }
        if arguments.contains("--expect-disabled") || arguments.contains("--disable-updates") {
            guard updater?.automaticUpdatesEnabled == false else { exit(1) }
            try? Data("disabled".utf8).write(to: URL(fileURLWithPath: marker), options: .atomic)
            updater?.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
            return
        }
        updater?.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updater?.checkInBackgroundForTesting()
        }
        if arguments.contains("--expect-reject") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
        }
    }
}

@main
enum UpdateIntegrationFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
