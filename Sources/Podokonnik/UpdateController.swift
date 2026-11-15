import AppKit
#if canImport(Sparkle)
import Sparkle

final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var pendingInstall: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    var automaticUpdatesEnabled: Bool { controller.updater.automaticallyChecksForUpdates }

    func start() { controller.startUpdater() }

    #if UPDATE_TESTING
    func checkInBackgroundForTesting() { controller.updater.checkForUpdatesInBackground() }
    #endif

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
        if enabled { installPendingUpdate() }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        pendingInstall = install
        installPendingUpdate()
        return true
    }

    private func installPendingUpdate() {
        guard automaticUpdatesEnabled, let install = pendingInstall else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.automaticUpdatesEnabled, self.pendingInstall != nil else { return }
            self.pendingInstall = nil
            install()
        }
    }
}
#else
// Standalone UI and lifecycle test executables do not embed Sparkle.
final class UpdateController {
    private(set) var automaticUpdatesEnabled = true
    func start() {}
    func setAutomaticUpdatesEnabled(_ enabled: Bool) { automaticUpdatesEnabled = enabled }
}
#endif
