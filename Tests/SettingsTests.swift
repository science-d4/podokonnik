import Foundation

@main
enum SettingsTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }; count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snezhno-settings-test-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(url: file)
        check(store.load().intensity == .steady, "New installation defaults")
        check(store.load().plowSpeedMultiplier == 1.25, "New tractor defaults to 1.25 speed")
        check(store.load().decorations == FestiveOptions(), "All decorations default to off")
        check(!store.load().pauseForScreenshots, "Screenshot pause defaults to off")
        var settings = AppSettings(); settings.intensity = .blizzard; settings.windX = 0.65; settings.paused = true
        settings.pauseForScreenshots = true
        store.save(settings)
        let restored = SettingsStore(url: file).load()
        check(restored.intensity == .blizzard && restored.windX == 0.65 && restored.paused, "Round trip")
        check(restored.plowIntervalMinutes == 10, "Tractor defaults to ten minutes")
        check(restored.pauseForScreenshots, "Screenshot pause persists")
        for interval in [5, 10, 30] {
            settings.plowIntervalMinutes = interval; store.save(settings)
            check(SettingsStore(url: file).load().plowIntervalMinutes == interval, "Tractor interval round trip")
        }
        for value in ["0", "-5", "8", "999999", "\"bad\"", "null"] {
            let data = Data("{\"plowIntervalMinutes\":\(value)}".utf8)
            let recovered = try JSONDecoder().decode(AppSettings.self, from: data)
            check(recovered.plowIntervalMinutes == 10, "Invalid tractor interval recovers")
        }
        for speed in [0.5, 0.875, 1.25, 2.0] {
            settings.plowSpeedMultiplier = speed; store.save(settings)
            check(SettingsStore(url: file).load().plowSpeedMultiplier == speed, "Tractor speed round trip")
        }
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"plowIntervalMinutes\":5}".utf8))
        check(oldSettings.plowSpeedMultiplier == 1.25 && oldSettings.plowIntervalMinutes == 5,
              "Old settings gain speed default without resetting their interval")
        check(oldSettings.decorations == FestiveOptions() && oldSettings.decorations.duck,
              "Old settings enable the duck and keep the other decoration defaults")
        check(!oldSettings.pauseForScreenshots, "Old settings keep screenshot pause off")
        let invalidScreenshot = try JSONDecoder().decode(AppSettings.self, from: Data("{\"pauseForScreenshots\":\"bad\"}".utf8))
        check(!invalidScreenshot.pauseForScreenshots, "Invalid screenshot pause recovers to off")
        let decorationKeys: [WritableKeyPath<FestiveOptions, Bool>] = [
            \.desktopGarland, \.windowGarlands, \.christmasTrees, \.aurora, \.shootingStars, \.duck
        ]
        for combination in 0..<(1 << decorationKeys.count) {
            var expected = FestiveOptions()
            for (index, key) in decorationKeys.enumerated() { expected[keyPath: key] = combination & (1 << index) != 0 }
            settings.decorations = expected; store.save(settings)
            let restored = SettingsStore(url: file).load()
            check(restored.decorations == expected && restored.windX == settings.windX && restored.intensity == settings.intensity,
                  "All independent decoration combinations persist without resetting existing weather")
        }
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data("{\"decorations\":{\"desktopGarland\":true,\"aurora\":true,\"windowGarlands\":\"bad\",\"duck\":\"bad\"},\"windX\":0.4}".utf8))
        check(partial.decorations.desktopGarland && partial.decorations.aurora
              && !partial.decorations.windowGarlands && !partial.decorations.christmasTrees && !partial.decorations.shootingStars
              && partial.decorations.duck && partial.windX == 0.4, "Decoration fields recover independently")
        for value in ["null", "[]", "17", "\"bad\""] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{\"decorations\":\(value),\"plowIntervalMinutes\":30}".utf8))
            check(decoded.decorations == FestiveOptions() && decoded.plowIntervalMinutes == 30,
                  "Invalid decoration containers recover without losing other preferences")
        }
        for (value, expected) in [("-999", 0.5), ("0.25", 0.5), ("999", 2.0), ("\"bad\"", 1.25), ("null", 1.25)] {
            let data = Data("{\"plowSpeedMultiplier\":\(value)}".utf8)
            let recovered = try JSONDecoder().decode(AppSettings.self, from: data)
            check(recovered.plowSpeedMultiplier == expected, "Invalid tractor speed clamps or recovers")
        }
        let specialDecoder = JSONDecoder()
        specialDecoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for value in ["Infinity", "-Infinity", "NaN"] {
            let recovered = try specialDecoder.decode(AppSettings.self, from: Data("{\"plowSpeedMultiplier\":\"\(value)\"}".utf8))
            check(recovered.plowSpeedMultiplier == 1.25, "Non-finite tractor speeds recover to default")
        }
        try Data("{\"windX\":99,\"windY\":-99,\"intensity\":900,\"paused\":\"oops\"}".utf8).write(to: file)
        let repaired = SettingsStore(url: file).load()
        check(repaired.windX == 1 && repaired.windY == -1 && repaired.intensity == .steady && !repaired.paused, "Field-level recovery")
        let future = Data("{\"schemaVersion\":90,\"futureSecret\":true}".utf8)
        try future.write(to: file)
        let protected = SettingsStore(url: file); _ = protected.load(); protected.save(AppSettings())
        let retained = try Data(contentsOf: file)
        check(protected.isReadOnly && retained == future, "New schema must not be destroyed")
        try Data("broken json".utf8).write(to: file)
        let corrupted = SettingsStore(url: file); _ = corrupted.load()
        check(corrupted.lastError != nil, "Corruption is explained")
        var policy = SessionPolicy(); policy.userPaused = true; policy.sleeping = true
        policy.sleeping = false
        check(!policy.isVisible(displayID: 1), "Wake does not cancel manual pause")
        policy.userPaused = false; policy.fullscreenDisplayIDs = [1]
        check(!policy.isVisible(displayID: 1) && policy.isVisible(displayID: 2), "Fullscreen is per display")
        policy.criticalThermal = true
        check(!policy.isVisible(displayID: 2), "Critical temperature suspends all displays")
        print("Settings and policy: \(count) checks passed")
    }
}
