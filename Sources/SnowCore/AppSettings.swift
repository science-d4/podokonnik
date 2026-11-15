import Foundation

struct AppSettings: Codable {
    var schemaVersion = 1
    var intensity: SnowIntensity = .steady
    var windX: Double = 0
    var windY: Double = 0
    var paused = false
    var economy = false
    var pauseForScreenshots = false
    var plowIntervalMinutes = 10
    var plowSpeedMultiplier = 1.25
    var onboardingComplete = false
    var decorations = FestiveOptions()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, intensity, windX, windY, paused, economy, pauseForScreenshots
        case plowIntervalMinutes, plowSpeedMultiplier, onboardingComplete, decorations
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        intensity = (try? c.decode(SnowIntensity.self, forKey: .intensity)) ?? .steady
        windX = (try? c.decode(Double.self, forKey: .windX)) ?? 0
        windY = (try? c.decode(Double.self, forKey: .windY)) ?? 0
        windX = windX.isFinite ? min(1, max(-1, windX)) : 0
        windY = windY.isFinite ? min(1, max(-1, windY)) : 0
        paused = (try? c.decode(Bool.self, forKey: .paused)) ?? false
        economy = (try? c.decode(Bool.self, forKey: .economy)) ?? false
        pauseForScreenshots = (try? c.decode(Bool.self, forKey: .pauseForScreenshots)) ?? false
        let interval = (try? c.decode(Int.self, forKey: .plowIntervalMinutes)) ?? 10
        plowIntervalMinutes = [5, 10, 30].contains(interval) ? interval : 10
        let speed = (try? c.decode(Double.self, forKey: .plowSpeedMultiplier)) ?? 1.25
        plowSpeedMultiplier = speed.isFinite ? min(2, max(0.5, speed)) : 1.25
        onboardingComplete = (try? c.decode(Bool.self, forKey: .onboardingComplete)) ?? false
        decorations = (try? c.decode(FestiveOptions.self, forKey: .decorations)) ?? FestiveOptions()
    }
}

final class SettingsStore {
    let url: URL
    private(set) var isReadOnly = false
    private(set) var lastError: String?
    init(url: URL? = nil) {
        // Keep the original path so updates retain settings and the instance lock.
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snezhno/settings.json")
    }
    func load() -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
            if settings.schemaVersion > 1 {
                isReadOnly = true
                lastError = "Настройки созданы более новой версией. Файл сохранён без изменений."
                return AppSettings()
            }
            return settings
        } catch {
            lastError = "Не удалось прочитать настройки. Используются значения по умолчанию."
            return AppSettings()
        }
    }
    func save(_ settings: AppSettings) {
        guard !isReadOnly else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
            lastError = nil
        } catch { lastError = "Не удалось сохранить настройки: \(error.localizedDescription)" }
    }
}

struct SessionPolicy {
    var userPaused = false
    var sleeping = false
    var inactive = false
    var criticalThermal = false
    var screenshotPaused = false
    var fullscreenDisplayIDs: Set<UInt32> = []
    var globallySuspended: Bool { userPaused || sleeping || inactive || criticalThermal }
    func isVisible(displayID: UInt32) -> Bool {
        !globallySuspended && !screenshotPaused && !fullscreenDisplayIDs.contains(displayID)
    }
}
