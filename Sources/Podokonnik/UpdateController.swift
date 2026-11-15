import AppKit

enum UpdateStatus: Equatable {
    case unknown
    case checking
    case available(String)
    case noUpdate
    case failed

    var description: String {
        switch self {
        case .unknown: return "Обновления ещё не проверены"
        case .checking: return "Проверяем обновления…"
        case .available(let version): return "Доступна версия: \(version)"
        case .noUpdate: return "Доступных обновлений нет"
        case .failed: return "Не удалось проверить обновления. Попробуйте ещё раз."
        }
    }
}

#if canImport(Sparkle)
import Sparkle

final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var pendingInstall: (() -> Void)?
    private(set) var status: UpdateStatus = .unknown {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((UpdateStatus) -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    var automaticUpdatesEnabled: Bool { controller.updater.automaticallyChecksForUpdates }

    func start() { controller.startUpdater() }

    func checkNow() {
        guard !controller.updater.sessionInProgress else {
            onStatusChange?(.checking)
            return
        }
        status = .checking
        controller.updater.checkForUpdateInformation()
    }

    func installUpdate() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    #if UPDATE_TESTING
    func checkInBackgroundForTesting() { controller.updater.checkForUpdatesInBackground() }
    #endif

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
        if enabled { installPendingUpdate() }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        status = .checking
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = .noUpdate
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil, status != .noUpdate { status = .failed }
        else if status == .checking { status = .noUpdate }
        else { onStatusChange?(status) }
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
    private(set) var status: UpdateStatus = .unknown
    var onStatusChange: ((UpdateStatus) -> Void)?
    func start() {}
    func checkNow() { status = .failed; onStatusChange?(status) }
    func installUpdate() {}
    func setAutomaticUpdatesEnabled(_ enabled: Bool) { automaticUpdatesEnabled = enabled }
}
#endif
