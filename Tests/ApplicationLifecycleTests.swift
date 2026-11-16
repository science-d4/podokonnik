import AppKit
import MetalKit

private struct LifecycleFailure: Error, CustomStringConvertible {
    let description: String
}

private final class LifecycleWindowMetadata {
    private let lock = NSLock()
    private var failing = false
    private var delayNext: TimeInterval = 0
    private var delayedStart: TimeInterval?
    func setFailing(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func delayNextRead(_ delay: TimeInterval) { lock.lock(); delayNext = delay; delayedStart = nil; lock.unlock() }
    func delayedReadStartedAt() -> TimeInterval? { lock.lock(); defer { lock.unlock() }; return delayedStart }
    func read() -> [[String: Any]]? {
        lock.lock(); let shouldFail = failing; let delay = delayNext; delayNext = 0
        if delay > 0 { delayedStart = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if shouldFail { return nil }
        return CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }
}

@MainActor
private final class LifecycleChecks {
    private(set) var count = 0
    private(set) var lines: [String] = []
    private var evidenceDirectory: URL?

    func verify(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw LifecycleFailure(description: description) }
        count += 1
    }

    func log(_ line: String) { lines.append(line); print(line); fflush(stdout) }

    func verifyDuckWithoutAccess(settingsURL: URL, fixtureURL: URL) async throws {
        try verify(!DesktopEnvironment.accessibilityTrusted(), "this launch must have no real Accessibility grant")
        try verify(!FileManager.default.fileExists(atPath: settingsURL.path), "the no-access test needs fresh settings")
        guard let screen = NSScreen.screens.first else { throw LifecycleFailure(description: "A GUI session is required") }
        let controller = ApplicationController()
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp))
        let fixture = Process()
        fixture.executableURL = fixtureURL
        fixture.arguments = ["--duck-fixture-window"]
        defer {
            if fixture.isRunning { fixture.terminate() }
            controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: NSApp))
            if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
            controller.welcome?.orderOut(nil)
        }
        try verify(controller.settings.decorations.duck, "fresh settings must enable the duck")
        let startButton = descendants(controller.welcome?.contentView).compactMap { $0 as? NSButton }
            .first { $0.title == "Начать снегопад" }
        try sendAction(startButton)
        try verify(controller.settings.onboardingComplete, "onboarding must allow starting without opening privacy settings")
        try fixture.run()
        let start = ProcessInfo.processInfo.systemUptime
        var firstFrame: Double?, activeSince: Double?, appeared: Double?, windowAt: Double?, crossingAt: Double?
        var firstFloorY: CGFloat?, roofLanding: Double?, roofVisitDuration: Double?, stayedOnRoof = false
        var returnToGround: Double?, stayedGroundedFor: Double?
        var crossingLaunch: CGPoint?, lastPose: DuckPose?
        var ownWindowFrame: CGRect?, ownWindowMasks: Int?, flights: [String] = []
        func ownWindowID() -> String? {
            let prefix = "window:\(fixture.processIdentifier):"
            return controller.snapshot?.surfaces.first { $0.suppressesSnowfall && $0.id.hasPrefix(prefix) }?.id
        }
        await wait(until: {
            let now = ProcessInfo.processInfo.systemUptime
            guard let snapshot = controller.snapshot, !snapshot.accessibilityTrusted,
                  let overlay = controller.overlays.values.first(where: { $0.window.frame == screen.frame }),
                  !overlay.isPaused else { return false }
            if firstFrame == nil { firstFrame = now }
            let windowID = ownWindowID()
            if let windowID {
                if activeSince == nil { activeSince = now }
                let roof = snapshot.surfaces.first { $0.id == windowID }
                ownWindowFrame = roof?.frame
                ownWindowMasks = roof?.occluders.count
            }
            guard let pose = controller.duckWorld.pose else { return false }
            let actor = overlay.scene.childNode(withName: "duck-layer")?.childNode(withName: "duck")
            let visible = actor?.isHidden == false
            if visible && appeared == nil {
                appeared = now - (firstFrame ?? start)
                if pose.anchor?.surfaceID.hasPrefix("floor:") == true { firstFloorY = pose.feet.y }
            }
            if visible, let windowID, pose.anchor?.surfaceID == windowID, let activeSince, windowAt == nil {
                windowAt = now - activeSince
                roofLanding = now
            }
            if let windowID, pose.anchor?.surfaceID == windowID, let roofLanding, now - roofLanding >= 5 {
                stayedOnRoof = true
            }
            if pose.anchor == nil, let previous = lastPose, previous.anchor != nil {
                if previous.anchor?.surfaceID == windowID, let roofLanding, roofVisitDuration == nil {
                    roofVisitDuration = now - roofLanding
                }
                if let returnToGround, stayedGroundedFor == nil { stayedGroundedFor = now - returnToGround }
                crossingLaunch = previous.anchor?.surfaceID.hasPrefix("floor:") == true ? previous.feet : nil
                flights.append("\(Int(now - (firstFrame ?? start)))s from \(previous.feet)")
            }
            if windowAt != nil, returnToGround == nil, pose.anchor?.surfaceID.hasPrefix("floor:") == true {
                returnToGround = now
            }
            if visible, crossingAt == nil, pose.anchor?.surfaceID.hasPrefix("floor:") == true,
               let origin = crossingLaunch, let firstFrame,
               (origin.x < screen.frame.midX) != (pose.feet.x < screen.frame.midX),
               abs(pose.feet.x - origin.x) >= screen.frame.width / 6 {
                crossingAt = now - firstFrame
            }
            lastPose = pose
            return appeared != nil && windowAt != nil && stayedOnRoof
        }, timeout: 35)
        log("AX=\(DesktopEnvironment.accessibilityTrusted()) Dock mapped=\(controller.snapshot?.dockDetected ?? false) visibleFrame=\(screen.visibleFrame) display=\(screen.frame)")
        log("Duck seconds: visible=\(appeared as Any) active window=\(windowAt as Any) crossing=\(crossingAt as Any); fixture active=\(activeSince != nil)")
        log("Floor: first feet Y=\(firstFloorY as Any), roof visit=\(roofVisitDuration as Any), early takeoff after return=\(stayedGroundedFor as Any)")
        log("Fixture roof=\(ownWindowFrame as Any) masks=\(ownWindowMasks as Any); takeoffs=\(flights.joined(separator: ", "))")
        try verify((appeared ?? .infinity) <= 2, "duck must render within two seconds of starting the scene")
        try verify(firstFloorY.map { $0 >= screen.frame.minY && $0 <= screen.frame.minY + SnowDrift.maximumHeight } == true,
                   "the first floor pose must touch the real floor or its snow contour")
        try verify((windowAt ?? 0) >= 8 && windowAt != nil,
                   "the fixture window must be visited only after sustained focus")
        try verify(stayedOnRoof && roofVisitDuration == nil, "the duck must keep walking on the active roof")
        try verify(!DesktopEnvironment.accessibilityTrusted(), "Accessibility must remain ungranted")
    }

    func run(settingsURL: URL) async throws {
        evidenceDirectory = settingsURL.deletingLastPathComponent()
        guard let screen = NSScreen.screens.first else {
            throw LifecycleFailure(description: "A GUI session is required; run outside the sandbox after stopping the product's benchmark.")
        }
        try verifyUnlaunchedCleanup(settingsURL: settingsURL)
        let metadata = LifecycleWindowMetadata()
        let controller = ApplicationController(desktop: DesktopEnvironment(windowMetadata: { metadata.read() }))
        var newer = SettingsStore(url: settingsURL).load()
        newer.windX = 0.125
        SettingsStore(url: settingsURL).save(newer)
        let launch = Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp)
        controller.applicationDidFinishLaunching(launch)
        var completed = false
        defer {
            if !completed { logState(controller, stage: "failure before cleanup") }
            controller.endGame()
            controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: NSApp))
            if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
            controller.welcome?.orderOut(nil)
        }

        try verify(controller.store.url.standardizedFileURL == settingsURL.standardizedFileURL, "settings must use the isolated test path")
        try verify(controller.settings.windX == newer.windX,
                   "successful lock acquisition must reload settings saved after controller initialization")
        try await verifyRejectedLaunch(settingsURL: settingsURL)
        try verify(controller.welcome == nil, "test onboarding must not open or activate a welcome window")
        try verify(controller.overlays.count == NSScreen.screens.count && !controller.overlays.isEmpty,
                   "one actual overlay must be created for each available display")
        try verify(controller.policy.userPaused && !controller.desktopActive,
                   "persisted manual pause must prevent starting the desktop reader")
        try verify(controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "paused startup must leave all own overlay windows hidden and render loops paused")
        try verify(controller.overlays.values.allSatisfy { $0.window.ignoresMouseEvents && !$0.window.canBecomeKey },
                   "lifecycle operations must leave overlays in pass-through mode")
        let overlayIdentities = identities(controller)
        let observerIdentities = controller.monitors.map { ObjectIdentifier($0 as AnyObject) }
        log("PASS startup: isolated settings, actual own overlays, persisted pause, passive input")
        if !CommandLine.arguments.contains("--spritekit-particles") { try verifyMetalHosts(controller) }

        // Exercise actual NSControl target/action wiring without posting input to
        // WindowServer or opening the popover over another application.
        try sendAction(controller.pauseControl)
        try verify(!controller.settings.paused && controller.desktopActive, "resume control must start the reader")
        try verify(controller.awaitingFreshSnapshot, "resume must wait for a new geometry snapshot")
        try verify(controller.overlays.values.allSatisfy { !$0.window.isVisible },
                   "resume must not expose stale geometry before a fresh snapshot")

        let support = SnowSurface(id: "lifecycle:own-test-support",
                                  frame: CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 140, width: 360, height: 1),
                                  kind: .window, suppressesSnowfall: true)
        let injectedGeneration: UInt64 = 90_000
        let ownSnapshot = DesktopSnapshot(generation: injectedGeneration, surfaces: [support],
            fullscreenDisplayIDs: [], accessibilityTrusted: DesktopEnvironment.accessibilityTrusted(),
            dockDetected: false, windowCount: 1, captureMilliseconds: 0)
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(!controller.awaitingFreshSnapshot && controller.snapshot?.generation == injectedGeneration,
                   "snapshot callback must clear the fresh-geometry gate through the production receive path")
        try verify(controller.world.surfaces.map(\.id) == [support.id], "snapshot callback must update the world")
        try verify(controller.overlays.values.allSatisfy { $0.window.isVisible }, "accepted geometry must allow own overlays to be ordered onscreen")
        log("PASS fresh-snapshot gate: hidden before delivery, world updated and own windows shown after injected delivery")

        // Prevent the real reader from replacing the synthetic support while
        // testing the failure timer and its cancellation.
        metadata.setFailing(true)
        controller.desktop.invalidate()
        guard let gameOverlay = controller.overlays.values.first else {
            throw LifecycleFailure(description: "failure test needs an overlay")
        }
        controller.playingDisplay = gameOverlay.id
        gameOverlay.window.receivesGameInput = true
        gameOverlay.window.ignoresMouseEvents = false
        gameOverlay.scene.playing = true
        controller.desktop.onCaptureUnavailable?(0)
        try verify(controller.awaitingFreshSnapshot && controller.overlays.values.allSatisfy { $0.window.isVisible && $0.isPaused },
                   "a short capture failure must freeze the last frame without hiding it")
        try verify(controller.playingDisplay == nil && gameOverlay.window.ignoresMouseEvents
                   && controller.gameControl?.isEnabled == false,
                   "a failed capture must end game input and prevent starting it during the grace period")
        metadata.setFailing(false)
        controller.desktop.onSnapshot?(ownSnapshot)
        try await Task.sleep(nanoseconds: 650_000_000)
        try verify(controller.overlays.values.allSatisfy { $0.window.isVisible },
                   "a successful capture must cancel the previous hide timer")
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(controller.world.placeSnowman(on: support, x: support.frame.midX), "failure test needs an attached snowman")
        let ballIDs = controller.world.balls.map(\.id)
        metadata.setFailing(true)
        controller.desktop.invalidate()
        controller.desktop.onCaptureUnavailable?(0)
        try await Task.sleep(nanoseconds: 300_000_000)
        controller.desktop.onCaptureUnavailable?(0)
        try await Task.sleep(nanoseconds: 300_000_000)
        try verify(controller.awaitingFreshSnapshot,
                   "a failed geometry capture must keep waiting for recovery")
        try verify(controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "repeated failures must not extend the grace period")
        try verify(controller.infoLabel?.stringValue == "Не удалось получить положение окон · повторяем попытку",
                   "the menu must explain why the effects are hidden and that capture will retry")
        try verify(controller.world.balls.map(\.id) == ballIDs, "a failed capture must preserve attached objects")
        metadata.setFailing(false)
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(!controller.awaitingFreshSnapshot && controller.overlays.values.allSatisfy { $0.window.isVisible },
                   "a successful capture must restore the overlays")
        try verify(controller.infoLabel?.stringValue != "Не удалось получить положение окон · повторяем попытку",
                   "the capture error must disappear after recovery")
        try verify(controller.world.balls.map(\.id) == ballIDs, "recovery must preserve attached objects")
        metadata.setFailing(true)
        controller.desktop.invalidate()
        controller.desktop.onCaptureUnavailable?(0.45)
        await drain(for: 0.15)
        try verify(controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "a slow failed read must use only its remaining grace time")
        metadata.setFailing(false)
        controller.desktop.onSnapshot?(ownSnapshot)
        controller.world.clearAll()

        for _ in 0..<40 { controller.world.step(delta: 0.1, weather: controller.weather, activeRegions: [screen.frame]) }
        // Flush the profile's bounded accumulation batch before comparing state.
        controller.world.syncSurfaces([support])
        let snow = controller.world.drifts[support.id]?.heights ?? []
        try verify(snow.reduce(0, +) > 0, "economy test must start with actual accumulated snow")
        let normalRates = controller.overlays.mapValues { $0.frameLimiter.pacer.rate }
        guard let economy = descendants(controller.popover.contentViewController?.view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Экономный режим" }) else {
            throw LifecycleFailure(description: "Economy checkbox is missing")
        }
        economy.state = .on
        try sendAction(economy)
        try verify(controller.settings.economy && controller.weather.lowPower, "economy checkbox must update settings and effective weather")
        try verify(controller.overlays.values.allSatisfy { $0.frameLimiter.pacer.rate == 30 && $0.scene.weather.lowPower },
                   "economy must bind the 30 FPS pacer and lower-density weather to every scene")
        try verify(controller.world.drifts[support.id]?.heights == snow, "economy must not delete or alter accumulated snow")
        economy.state = .off
        try sendAction(economy)
        try verify(!controller.settings.economy && controller.overlays.allSatisfy { normalRates[$0.key] == $0.value.frameLimiter.pacer.rate },
                   "leaving economy must restore the effective pre-existing rate, respecting real system power/motion settings")
        try verify(controller.world.drifts[support.id]?.heights == snow, "leaving economy must preserve snow too")
        log("PASS economy: actual checkbox target/action configures pacer=30 and lowPower weather; accumulated snow survives both directions")

        guard let updates = descendants(controller.popover.contentViewController?.view).compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier?.rawValue == "automaticUpdates" }) else {
            throw LifecycleFailure(description: "Automatic updates checkbox is missing")
        }
        try verify(updates.state == .on && controller.automaticUpdatesEnabled, "automatic updates should default to on")
        updates.state = .off
        try sendAction(updates)
        try verify(!controller.automaticUpdatesEnabled, "the checkbox must disable automatic updates")
        updates.state = .on
        try sendAction(updates)
        try verify(controller.automaticUpdatesEnabled, "the checkbox must re-enable automatic updates")
        controller.settingsTabControl?.selectedSegment = 2
        try sendAction(controller.settingsTabControl)
        let controls = descendants(controller.popover.contentViewController?.view)
        guard let version = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "currentVersion" }),
              let status = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "updateStatus" }),
              let check = controls.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "checkUpdates" }) else {
            throw LifecycleFailure(description: "Update tab controls are missing")
        }
        try verify(version.stringValue.hasPrefix("Текущая версия:"), "update tab must show the running version")
        try verify(status.stringValue == UpdateStatus.unknown.description, "update tab starts with an unknown status")
        try sendAction(check)
        try verify(status.stringValue == UpdateStatus.failed.description, "manual check must update the visible status")
        controller.popover.contentViewController?.view.layoutSubtreeIfNeeded()
        if let content = controller.popover.contentViewController?.view { try saveOwnView(content, name: "settings-updates.png") }
        controller.settingsTabControl?.selectedSegment = 0
        try sendAction(controller.settingsTabControl)
        log("PASS updates: tab, version, status, manual check and automatic preference")

        controller.changedSettings()
        controller.changedSettings()
        try verify(identities(controller) == overlayIdentities, "repeated policy refresh must reuse all overlay instances")
        try verify(controller.monitors.map { ObjectIdentifier($0 as AnyObject) } == observerIdentities,
                   "repeated policy refresh must not register more system observers")
        try verify(controller.world.drifts[support.id]?.heights == snow, "repeated policy refresh must preserve the world")
        log("PASS repeated policy refresh: overlay and observer identities remain unchanged")
        try verifyScreenshotPause(controller, snapshot: ownSnapshot, snow: snow)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        try verify(controller.awaitingFreshSnapshot && controller.overlays.values.allSatisfy { $0.window.isVisible && $0.isPaused },
                   "a Space notification must keep an already presented frame ordered")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try verify(identities(controller) == overlayIdentities
                   && controller.overlays.values.allSatisfy { $0.window.isVisible },
                   "an unchanged screen configuration must not replace or hide the overlay")
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(!controller.awaitingFreshSnapshot && controller.desktopActive,
                   "the first fresh snapshot must release the gate without a fixed Space delay")

        controller.intensityControl?.selectedSegment = SnowIntensity.light.rawValue
        try sendAction(controller.intensityControl)
        controller.windXSlider?.doubleValue = 0.6
        try sendAction(controller.windXSlider)
        controller.windYSlider?.doubleValue = -0.35
        try sendAction(controller.windYSlider)
        try verify(controller.settings.intensity == .light && controller.weather.intensity == .light,
                   "intensity control must update effective weather")
        try verify(abs(controller.settings.windX - 0.6) < 0.001 && abs(controller.settings.windY + 0.35) < 0.001,
                   "both wind slider target/actions must update settings")
        try verify(abs((controller.windPad?.vector.dx ?? 0) - 0.6) < 0.001
                   && abs((controller.windPad?.vector.dy ?? 0) + 0.35) < 0.001,
                   "wind pad must stay synchronized with accessible slider alternatives")

        try sendAction(controller.pauseControl)
        try verify(controller.settings.paused && controller.policy.userPaused && !controller.desktopActive,
                   "pause control must stop the reader while retaining manual pause")
        try verify(controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "pause must hide own effects and stop their render loops")
        try verify(controller.pauseControl?.title == "Продолжить", "pause control must show the next action")
        log("PASS settings controls: intensity, both wind axes, synchronized pad and pause action")
        try await verifyDecorationControls(controller)
        await drain(for: 0.7)
        try verifyDuckGeometry(controller, snapshot: ownSnapshot, screen: screen.frame)
        let snowman = try buildSnowman(controller.world, support: support, display: screen.frame)
        controller.world.syncSurfaces([support])
        let spaceSnow = controller.world.drifts[support.id]?.heights
        try verify(spaceSnow?.contains(where: { $0 > 0 }) == true, "Space regression starts with accumulated snow")

        // These are local test notifications in this process. They do not change
        // the macOS session, put a display to sleep or modify a system preference.
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: NSWorkspace.shared)
        try verify(controller.policy.inactive && controller.settings.paused, "inactive-session notification must preserve manual pause")
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        var otherSpace = ownSnapshot
        otherSpace.surfaces = []
        otherSpace.hiddenWindowSupportIDs = [support.id]
        try verify(controller.awaitingFreshSnapshot && controller.world.surfaces.first?.isVisible == true,
                   "rapid Space notifications preserve the last frame pending fresh geometry")
        try verify(!controller.policy.inactive && controller.policy.userPaused && controller.settings.paused,
                   "returning to an active session must not clear manual pause")
        try verify(!controller.desktopActive && controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "active-session notification must not resume manually paused rendering or polling")
        try verify(controller.settings.paused && !controller.desktopActive,
                   "invalidating geometry must also retain manual pause")
        try verify(controller.snapshot?.generation == injectedGeneration, "stopped reader must not deliver its old in-flight snapshot")
        let retainedTree = controller.festiveWorld.placements(in: controller.world).first?.id
        try verify(retainedTree != nil, "Space notification must retain the original tree")
        var displaced = ownSnapshot
        displaced.surfaces[0].frame = support.frame.offsetBy(dx: screen.frame.width + 100, dy: 0)
        controller.desktop.onSnapshot?(displaced)
        try verify(controller.world.surfaces.first?.frame == support.frame
                   && controller.world.surfaces.first?.isVisible == false
                   && controller.world.snowmen.first?.ballIDs == snowman,
                   "a same-size system translation after Space must retain the original snowman and geometry")
        var missingDuringTransition = ownSnapshot
        missingDuringTransition.surfaces = []
        controller.desktop.onSnapshot?(missingDuringTransition)
        try verify(controller.world.drifts[support.id]?.heights == spaceSnow
                   && controller.world.snowmen.first?.ballIDs == snowman,
                   "a missing window during the Space animation must not clear its model")
        controller.desktop.onSnapshot?(ownSnapshot)
        var shrinking = ownSnapshot
        shrinking.surfaces[0].frame = CGRect(x: support.frame.midX, y: support.top - 100, width: 95, height: 1)
        controller.desktop.onSnapshot?(shrinking)
        try verify(controller.world.surfaces.first?.isVisible == false
                   && controller.world.surfaces.first?.frame == support.frame
                   && controller.world.drifts[support.id]?.heights == spaceSnow
                   && controller.world.snowmen.first?.ballIDs == snowman
                   && controller.festiveWorld.placements(in: controller.world).first?.surface.isVisible == false,
                   "minimizing must hide the original geometry before a resize can destroy the drift or snowman")
        controller.desktop.onSnapshot?(otherSpace)
        try verify(controller.world.surfaces.first?.isVisible == false
                   && controller.festiveWorld.placements(in: controller.world).first?.id == retainedTree,
                   "the other Space must hide the known window and retain its tree")
        try verify(controller.world.drifts[support.id]?.heights == spaceSnow, "a hidden window must retain its drift")
        await drain(for: 5)
        for offset in [48.0, 12, 0] {
            var sliding = ownSnapshot
            sliding.surfaces[0].frame = support.frame.offsetBy(dx: offset, dy: 0)
            controller.desktop.onSnapshot?(sliding)
            try verify(controller.world.surfaces.first?.isVisible == true
                       && controller.world.surfaces.first?.frame == sliding.surfaces[0].frame
                       && controller.world.drifts[support.id]?.heights == spaceSnow
                       && controller.world.snowmen.first?.ballIDs == snowman,
                       "the returning window must carry its snow and snowman before the Space notification")
        }
        controller.desktop.onSnapshot?(otherSpace)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        var resizedReturn = ownSnapshot
        resizedReturn.surfaces[0].frame.size.width += 8
        controller.desktop.onSnapshot?(resizedReturn)
        try verify(controller.world.surfaces.first?.isVisible == false
                   && controller.world.drifts[support.id]?.heights == spaceSnow,
                   "the first resized frame must keep the hidden drift intact after five seconds away")
        await drain(for: 0.31)
        controller.desktop.onSnapshot?(resizedReturn)
        try verify(controller.world.surfaces.first?.isVisible == true
                   && controller.world.surfaces.first?.frame == resizedReturn.surfaces[0].frame
                   && controller.world.drifts[support.id]?.heights.contains(where: { $0 > 0 }) == true
                   && controller.world.snowmen.first?.ballIDs == snowman
                   && controller.festiveWorld.placements(in: controller.world).first?.id == retainedTree,
                   "a stable resized window must show its snowman and tree during Space protection")
        controller.desktop.onSnapshot?(ownSnapshot)
        await drain(for: 0.31)
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(controller.world.surfaces.first?.isVisible == true
                   && controller.world.drifts[support.id]?.heights.contains(where: { $0 > 0 }) == true,
                   "resizing back must retain accumulated snow")
        let returnedSnow = controller.world.drifts[support.id]?.heights
        let returnedTree = controller.festiveWorld.placements(in: controller.world).first
        controller.desktop.onSnapshot?(otherSpace)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        var returning = ownSnapshot
        returning.surfaces[0].frame = CGRect(x: support.frame.minX + 24, y: support.frame.minY + 3,
                                           width: support.frame.width + 1, height: support.frame.height + 1)
        controller.desktop.onSnapshot?(returning)
        try verify(controller.world.surfaces.first?.isVisible == true
                   && controller.world.surfaces.first?.frame.minX == returning.surfaces[0].frame.minX
                   && controller.world.surfaces.first?.top == returning.surfaces[0].top
                   && controller.world.drifts[support.id]?.heights == returnedSnow
                   && controller.world.snowmen.first?.ballIDs == snowman
                   && controller.festiveWorld.placements(in: controller.world).first?.id == retainedTree,
                   "the first visible snapshot must show the original effects at the returning window")
        controller.desktop.onSnapshot?(ownSnapshot)
        var fullscreen = ownSnapshot
        fullscreen.fullscreenDisplayIDs = Set(controller.overlays.keys)
        fullscreen.surfaces[0].frame = screen.frame
        controller.desktop.onSnapshot?(fullscreen)
        try verify(controller.world.surfaces.first?.frame == support.frame
                   && controller.world.drifts[support.id]?.heights == returnedSnow,
                   "fullscreen animation bounds must not resize the stored drift")
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(controller.world.surfaces.first?.isVisible == true
                   && controller.world.drifts[support.id]?.heights == returnedSnow
                   && controller.world.snowmen.first?.ballIDs == snowman
                   && controller.festiveWorld.placements(in: controller.world).first?.id == retainedTree
                   && controller.festiveWorld.placements(in: controller.world).first?.base == returnedTree?.base,
                   "the returning support must restore its exact drift, snowman and tree position")
        var mission = ownSnapshot
        mission.missionControlActive = true
        mission.surfaces[0].frame = CGRect(x: support.frame.minX + 40, y: support.frame.minY + 30,
                                           width: support.frame.width * 0.5, height: support.frame.height * 0.5)
        controller.desktop.onSnapshot?(mission)
        await drain(for: 0.2)
        controller.primaryPointerDown = { true }
        controller.desktop.onSnapshot?(mission)
        try verify(controller.world.surfaces.first?.isVisible == false
                   && controller.world.drifts[support.id]?.heights == returnedSnow
                   && controller.world.snowmen.first?.ballIDs == snowman
                   && controller.festiveWorld.placements(in: controller.world).first?.base == returnedTree?.base,
                   "a stable Mission Control thumbnail and mouse selection must preserve the full snow and tree anchor")
        controller.primaryPointerDown = { false }
        controller.desktop.onSnapshot?(ownSnapshot)
        try verify(controller.world.surfaces.first?.isVisible == true
                   && controller.world.drifts[support.id]?.heights == returnedSnow
                   && controller.festiveWorld.placements(in: controller.world).first?.base == returnedTree?.base,
                   "returning from Mission Control restores the exact profile and tree position")
        controller.primaryPointerDown = { NSEvent.pressedMouseButtons & 1 != 0 }
        await drain(for: 0.7)
        otherSpace.hiddenWindowSupportIDs = []
        controller.desktop.onSnapshot?(otherSpace)
        try verify(controller.world.drifts[support.id] == nil && controller.world.snowmen.isEmpty
                   && controller.festiveWorld.placements(in: controller.world).isEmpty,
                   "closing the support must discard its drift, snowman and tree")
        let persisted = SettingsStore(url: settingsURL).load()
        try verify(persisted.paused && persisted.intensity == .light && abs(persisted.windX - 0.6) < 0.001
                   && abs(persisted.windY + 0.35) < 0.001, "debounced settings save must persist the tested control values")
        log("PASS Space return: the stable resized window reveals retained effects after five seconds away")
        log("PASS local session notifications: manual pause survives inactive/active and Space changes; isolated settings persist")

        try sendAction(controller.pauseControl)
        try verify(controller.awaitingFreshSnapshot && controller.overlays.values.allSatisfy { !$0.window.isVisible },
                   "resuming after the inactive-session path must again require fresh geometry")
        await wait(until: { !controller.awaitingFreshSnapshot && controller.snapshot?.generation != injectedGeneration }, timeout: 3)
        try verify(!controller.awaitingFreshSnapshot && controller.desktopActive && controller.snapshot?.generation != injectedGeneration,
                   "an actual asynchronous DesktopEnvironment snapshot must release the resumed gate")
        try verify(identities(controller) == overlayIdentities
                   && controller.monitors.map { ObjectIdentifier($0 as AnyObject) } == observerIdentities,
                   "pause/resume and session transitions must not duplicate overlays or observers")
        log("PASS real metadata callback: DesktopEnvironment supplies fresh geometry after resume")
        if !CommandLine.arguments.contains("--spritekit-particles") { try await verifyMetalFrameLifecycle(controller) }
        try verifyDriverClock(controller)
        try await verifyGameHost(controller)
        try await verifyFailureFocus(controller)
        try await verifySlowCapture(controller, metadata: metadata)
        try await verifyPermissionFromGame(controller)
        if !CommandLine.arguments.contains("--spritekit-particles") { try await verifyRenderingFailure(controller) }
        controller.settings.paused = true
        controller.changedSettings()
        completed = true
    }

    private func buildSnowman(_ world: SnowWorld, support: SnowSurface, display: CGRect) throws -> [UUID] {
        func advance(_ ticks: Int) {
            for _ in 0..<ticks {
                world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [display])
            }
        }
        advance(140)
        let ids = try [60.0, 170, 280].map { localX -> UUID in
            let x = support.frame.minX + localX
            let height = world.drifts[support.id]?.visibleContour.height(at: localX) ?? 0
            guard let id = world.beginSnowball(at: CGPoint(x: x, y: support.top + height)) else {
                throw LifecycleFailure(description: "Snowman fixture requires three real snowballs")
            }
            world.endDrag()
            return id
        }
        advance(8)
        for (lower, upper) in zip(ids, ids.dropFirst()) {
            guard let base = world.balls.first(where: { $0.id == lower }),
                  let ball = world.balls.first(where: { $0.id == upper }),
                  world.beginDrag(at: ball.position) == upper else {
                throw LifecycleFailure(description: "Cannot stack the snowman fixture")
            }
            world.drag(to: CGPoint(x: base.position.x, y: base.position.y + 20))
            world.endDrag()
            advance(8)
        }
        try verify(world.snowmen.first?.ballIDs == ids, "the fixture must start with a stable snowman on the window")
        return ids
    }

    private func verifyScreenshotPause(_ controller: ApplicationController, snapshot: DesktopSnapshot,
                                       snow: [CGFloat]) throws {
        guard let toggle = descendants(controller.popover.contentViewController?.view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Пауза при скриншоте" }) else {
            throw LifecycleFailure(description: "Screenshot pause checkbox is missing")
        }
        var selection = snapshot
        selection.screenshotSelectionActive = true
        controller.desktop.onSnapshot?(selection)
        try verify(toggle.state == .off && !controller.policy.screenshotPaused
                   && controller.overlays.values.allSatisfy { $0.window.isVisible },
                   "a screenshot with pause off must keep the overlay visible")
        toggle.state = .on
        try sendAction(toggle)
        try verify(controller.policy.screenshotPaused && controller.desktopActive
                   && controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "screenshot pause must hide and stop all overlay views while polling for dismissal")
        controller.desktop.onSnapshot?(snapshot)
        try verify(!controller.policy.screenshotPaused && controller.overlays.values.allSatisfy { $0.window.isVisible }
                   && controller.world.drifts[snapshot.surfaces[0].id]?.heights == snow,
                   "ending screenshot selection must restore the overlay and its exact drift")
        controller.desktop.onSnapshot?(selection)
        try sendAction(controller.pauseControl)
        controller.desktop.onSnapshot?(snapshot)
        try verify(controller.policy.userPaused && !controller.desktopActive
                   && controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "ending selection must preserve manual pause")
        toggle.state = .off
        try sendAction(toggle)
        try sendAction(controller.pauseControl)
        controller.desktop.onSnapshot?(snapshot)
        log("PASS screenshot selection: disabled, enabled, dismissal, manual pause and drift retention")
    }

    private func logState(_ controller: ApplicationController, stage: String) {
        let policy = controller.policy
        log("DIAGNOSTIC \(stage): sleeping=\(policy.sleeping) inactive=\(policy.inactive) settingsPaused=\(controller.settings.paused) userPaused=\(policy.userPaused) criticalThermal=\(policy.criticalThermal) fullscreen=\(policy.fullscreenDisplayIDs.sorted()) awaitingFresh=\(controller.awaitingFreshSnapshot) desktopActive=\(controller.desktopActive) driver=\(controller.driverID.map(String.init) ?? "none") lastFrame=\(controller.lastFrame)")
        for overlay in controller.overlays.values.sorted(by: { $0.id < $1.id }) {
            log("DIAGNOSTIC own overlay \(overlay.id): visible=\(overlay.window.isVisible) occlusionRaw=\(overlay.window.occlusionState.rawValue) unoccluded=\(overlay.window.occlusionState.contains(.visible)) viewPaused=\(overlay.isPaused) scenePaused=\(overlay.scene.isPaused) viewHidden=\(overlay.view.isHiddenOrHasHiddenAncestor) unifiedHost=\(overlay.particles != nil) failure=\(overlay.renderingFailure ?? "none") submitted=\(overlay.particles?.submittedFrames ?? -1) metalHidden=\(overlay.particles?.isHiddenOrHasHiddenAncestor ?? true) particleCallback=\(overlay.scene.onParticles != nil)")
        }
    }

    private func verifyUnlaunchedCleanup(settingsURL: URL) throws {
        let before = try Data(contentsOf: settingsURL)
        let unlaunched = ApplicationController()
        unlaunched.settings.paused = false
        unlaunched.settings.windX = -0.9
        let termination = Notification(name: NSApplication.willTerminateNotification, object: NSApp)
        unlaunched.applicationWillTerminate(termination)
        unlaunched.applicationWillTerminate(termination)
        let after = try Data(contentsOf: settingsURL)
        try verify(before == after, "cleanup without session ownership must never write stale settings")
        try verify(unlaunched.overlays.isEmpty && unlaunched.monitors.isEmpty,
                   "unlaunched controller cleanup must not create windows or observers")
        log("PASS ownership: repeated cleanup of an unlaunched controller leaves the settings bytes unchanged")
    }

    private func verifyRejectedLaunch(settingsURL: URL) async throws {
        let before = try Data(contentsOf: settingsURL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--rejected-launch-child", "--settings-path", settingsURL.path]
        try child.run()
        await wait(until: { !child.isRunning }, timeout: 5)
        if child.isRunning {
            child.terminate() // Only this test's own child; no other process is touched.
            await wait(until: { !child.isRunning }, timeout: 1)
            throw LifecycleFailure(description: "Rejected-launch child did not exit within five seconds")
        }
        try verify(child.terminationStatus == 0, "a real lock-rejected ApplicationController must terminate normally")
        let after = try Data(contentsOf: settingsURL)
        try verify(before == after, "a rejected process must not overwrite the owner's settings with its stale in-memory values")
        log("PASS rejected process: actual AppKit launch/termination under a held lock exits normally and preserves settings bytes")
    }

    private func verifyMetalHosts(_ controller: ApplicationController) throws {
        for overlay in controller.overlays.values {
            guard let particles = overlay.particles, let host = overlay.window.contentView,
                  let layer = particles.layer as? CAMetalLayer else {
                throw LifecycleFailure(description: "Default renderer must create a UnifiedSnowView with CAMetalLayer on every display")
            }
            let expectedGPU = !CommandLine.arguments.contains("--cpu-particles")
            try verify(particles.usesGPUSimulation == expectedGPU
                       && overlay.scene.particleSimulationBackend == (expectedGPU ? "gpu" : "cpu"),
                       "lifecycle must exercise the requested simulation backend without silent fallback")
            try verify(!overlay.window.isOpaque && overlay.window.backgroundColor.alphaComponent == 0
                       && overlay.scene.backgroundColor.alphaComponent == 0, "own overlay and scene must remain transparent")
            try verify(!particles.isOpaque && !layer.isOpaque && layer.pixelFormat == .bgra8Unorm,
                       "unified Metal backing must remain transparent and use the expected pixel format")
            try verify(particles.hitTest(CGPoint(x: particles.bounds.midX, y: particles.bounds.midY)) == nil
                       && !particles.acceptsFirstResponder, "passive unified host must not consume mouse or keyboard focus")
            try verify(particles.isPaused && overlay.isPaused,
                       "the explicit display-link clock must start paused")
            try verify(host === particles && overlay.view === particles && overlay.spriteView == nil && host.subviews.isEmpty,
                       "production must have one unified host and no independent SKView or renderer sibling")
            let scale = overlay.window.backingScaleFactor
            try verify(overlay.scene.scaleMode == .aspectFit && overlay.scene.size == host.bounds.size
                       && overlay.scene.presentationScale == scale && layer.contentsScale == scale,
                       "scene logical points and explicit raster scale must match the actual host")
            try verify(layer.drawableSize == CGSize(width: (host.bounds.width * scale).rounded(.up),
                                                     height: (host.bounds.height * scale).rounded(.up)),
                       "Metal drawable must use backing pixels rather than logical points")
            try verify(particles.frame == host.bounds, "the unified renderer must occupy the actual host bounds")
        }
        log("PASS unified host: one transparent CAMetalLayer host, no SKView, passive hit testing, explicit point/pixel scale")
    }

    private func verifyMetalFrameLifecycle(_ controller: ApplicationController) async throws {
        if NSApp.isActive { NSApp.deactivate() }
        await wait(until: { !NSApp.isActive }, timeout: 1)
        try verify(!NSApp.isActive, "the renderer must be tested with its own accessory application inactive")
        let inactiveFrames = controller.overlays.mapValues { $0.particles?.submittedFrames ?? 0 }
        logState(controller, stage: "before waiting for Metal frame")
        await wait(until: { controller.overlays.values.contains { ($0.particles?.submittedFrames ?? 0) > 0 } }, timeout: 3)
        try verify(controller.overlays.values.contains { ($0.particles?.submittedFrames ?? 0) > 0 },
                   "actual display ticks must submit at least one Metal frame")
        await wait(until: { controller.overlays.contains {
            ($0.value.particles?.submittedFrames ?? 0) > (inactiveFrames[$0.key] ?? 0)
        } }, timeout: 3)
        try verify(!NSApp.isActive && controller.overlays.contains {
            ($0.value.particles?.submittedFrames ?? 0) > (inactiveFrames[$0.key] ?? 0)
        }, "explicit display-link frames must advance while the application remains inactive")
        try sendAction(controller.pauseControl)
        let stoppedFrames = controller.overlays.mapValues { $0.particles?.submittedFrames ?? 0 }
        await drain(for: 0.2)
        try verify(controller.overlays.allSatisfy { stoppedFrames[$0.key] == $0.value.particles?.submittedFrames },
                   "pause must stop Metal frame submissions, not only hide the host")
        try sendAction(controller.pauseControl)
        try verify(controller.awaitingFreshSnapshot && controller.overlays.allSatisfy { stoppedFrames[$0.key] == $0.value.particles?.submittedFrames },
                   "Metal must remain stopped while resume awaits fresh geometry")
        await wait(until: {
            !controller.awaitingFreshSnapshot && controller.overlays.contains {
                ($0.value.particles?.submittedFrames ?? 0) > (stoppedFrames[$0.key] ?? 0)
            }
        }, timeout: 3)
        try verify(!controller.awaitingFreshSnapshot && controller.overlays.contains {
            ($0.value.particles?.submittedFrames ?? 0) > (stoppedFrames[$0.key] ?? 0)
        }, "fresh geometry must resume actual Metal submissions")
        let before = stoppedFrames.values.reduce(0, +)
        let after = controller.overlays.values.reduce(0) { $0 + ($1.particles?.submittedFrames ?? 0) }
        log("PASS Metal frames: submitted=\(before) stayed fixed during pause; fresh resume advanced to \(after). This is frame progression, not an FPS benchmark.")
    }

    private func verifyDriverClock(_ controller: ApplicationController) throws {
        guard let id = controller.driverID, let frame = controller.overlays[id]?.scene.onFrame else {
            throw LifecycleFailure(description: "driver clock test needs a running display")
        }
        let timestamp = ProcessInfo.processInfo.systemUptime + 1
        frame(timestamp)
        frame(timestamp - 0.01)
        try verify(controller.lastFrame == timestamp,
                   "an earlier target timestamp must not rewind the shared clock when the driver changes")
        frame(timestamp + 0.01)
        try verify(controller.lastFrame == timestamp + 0.01, "the shared clock must resume from the latest timestamp")
        controller.lastFrame = 0
        log("PASS driver clock: out-of-order display timestamps do not rewind shared time")
    }

    private func verifyGameHost(_ controller: ApplicationController) async throws {
        let pointer = NSEvent.mouseLocation
        guard let overlay = controller.overlays.values.first(where: { $0.window.frame.contains(pointer) && !$0.isPaused }) else {
            log("SKIP game host: pointer is not on a currently rendering display; pointer position was not changed")
            return
        }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        try sendAction(controller.gameControl)
        try verify(controller.playingDisplay == overlay.id && overlay.window.receivesGameInput && !overlay.window.ignoresMouseEvents,
                   "actual game control target/action must enable input on the selected own overlay")
        guard let hud = overlay.hud, let host = overlay.window.contentView else {
            throw LifecycleFailure(description: "game must create a HUD in the actual overlay host")
        }
        try verify(hud.superview === host && host.subviews.last === hud, "HUD must be the last, topmost host sibling")
        if let particles = overlay.particles {
            host.layoutSubtreeIfNeeded()
            let point = hud.convert(CGPoint(x: hud.bounds.midX, y: hud.bounds.midY), to: host)
            let hit = particles.hitTest(point)
            try verify(host === particles && hud.superview === particles && host.subviews.last === hud
                       && (hit === hud || hit?.isDescendant(of: hud) == true),
                       "game HUD must be a topmost hittable child of the unified host")
            try verify(particles.acceptsFirstResponder && particles.hitTest(CGPoint(x: 10, y: 10)) === particles,
                       "uncovered unified host must accept game input only while playing")
        }
        await wait(until: { NSApp.isActive }, timeout: 1)
        try verify(NSApp.isActive, "own game window must become active before checking Escape and focus return")
        try verifyTreeToolControls(controller, overlay: overlay)
        if let control = descendants(overlay.hud).compactMap({ $0 as? NSControl }).first {
            _ = overlay.window.makeFirstResponder(control)
        }
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
            throw LifecycleFailure(description: "Cannot construct own-window Escape event")
        }
        // Direct dispatch into this NSWindow only; never post a global CG/NSEvent.
        overlay.window.sendEvent(escape)
        try verify(controller.playingDisplay == nil && controller.gameKeyMonitor == nil && overlay.hud == nil,
                   "own Escape must end game and remove HUD/local event monitor")
        try verify(overlay.window.ignoresMouseEvents && !overlay.window.receivesGameInput && !overlay.window.canBecomeKey,
                   "Escape must restore passive own-overlay input")
        if let previousApplication, previousApplication.processIdentifier != getpid(), !previousApplication.isTerminated {
            await wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier }, timeout: 1)
            try verify(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier,
                       "leaving the own game must restore its previous foreground application")
        }
        controller.endGame() // Idempotent cleanup after Escape.
        log("PASS game host: actual control action, HUD child above the unified scene, own-window Escape and passive input; previous focus checked when an external foreground app was available")
    }

    private func verifyFailureFocus(_ controller: ApplicationController) async throws {
        let original = NSWorkspace.shared.frontmostApplication
        var restoredPIDs: [pid_t] = []
        controller.activatePreviousApp = { application in
            restoredPIDs.append(application.processIdentifier)
            application.activate(options: [])
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0],
                             relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        let first = Process()
        let second = Process()
        first.executableURL = executable; first.arguments = ["--duck-fixture-window"]
        second.executableURL = executable; second.arguments = ["--duck-fixture-window"]
        defer {
            controller.activatePreviousApp = { $0.activate(options: []) }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmost == first.processIdentifier || frontmost == second.processIdentifier || frontmost == getpid() {
                if let original, original.processIdentifier != getpid(), !original.isTerminated { original.activate(options: []) }
            }
            if first.isRunning { first.terminate() }
            if second.isRunning { second.terminate() }
        }
        try first.run()
        await wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == first.processIdentifier }, timeout: 3)
        try verify(NSWorkspace.shared.frontmostApplication?.processIdentifier == first.processIdentifier,
                   "own focus fixture must be the foreground application")
        guard let snapshot = controller.snapshot else { throw LifecycleFailure(description: "focus test needs a snapshot") }
        try sendAction(controller.gameControl)
        await wait(until: { NSApp.isActive && controller.playingDisplay != nil }, timeout: 2)
        try verify(NSApp.isActive && controller.playingDisplay != nil
                   && controller.previousApp?.processIdentifier == first.processIdentifier,
                   "starting the game must remember the own foreground fixture")
        controller.desktop.onCaptureUnavailable?(0)
        await wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == first.processIdentifier }, timeout: 2)
        try verify(controller.playingDisplay == nil
                   && NSWorkspace.shared.frontmostApplication?.processIdentifier == first.processIdentifier,
                   "capture failure must return focus to the previous own application")
        try verify(restoredPIDs == [first.processIdentifier],
                   "capture failure must explicitly request activation of the previously active application")
        controller.desktop.onSnapshot?(snapshot)
        try sendAction(controller.gameControl)
        await wait(until: { NSApp.isActive && controller.playingDisplay != nil }, timeout: 2)
        try verify(NSApp.isActive && controller.playingDisplay != nil
                   && controller.previousApp?.processIdentifier == first.processIdentifier,
                   "the second game must also remember the original own fixture")
        try second.run()
        await wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == second.processIdentifier }, timeout: 3)
        try verify(NSWorkspace.shared.frontmostApplication?.processIdentifier == second.processIdentifier,
                   "second own fixture must become foreground")
        controller.desktop.onCaptureUnavailable?(0)
        await drain(for: 0.1)
        try verify(NSWorkspace.shared.frontmostApplication?.processIdentifier == second.processIdentifier,
                   "failure after switching applications must not take focus from the user's choice")
        try verify(restoredPIDs == [first.processIdentifier],
                   "switching applications before the failure must not request restoration")
        controller.desktop.onSnapshot?(snapshot)
        log("PASS capture failure focus: previous own application restored; later selected own application remains active")
    }

    private func verifySlowCapture(_ controller: ApplicationController, metadata: LifecycleWindowMetadata) async throws {
        await wait(until: { !controller.awaitingFreshSnapshot && controller.overlays.values.contains { !$0.isPaused } }, timeout: 3)
        try verify(!controller.awaitingFreshSnapshot, "slow capture test needs a live scene")
        controller.desktop.stop()
        await drain(for: 0.2)
        metadata.setFailing(true)
        metadata.delayNextRead(0.4)
        controller.desktop.start()
        await wait(until: { metadata.delayedReadStartedAt() != nil }, timeout: 2)
        guard let started = metadata.delayedReadStartedAt() else {
            throw LifecycleFailure(description: "delayed failed metadata read did not start")
        }
        await wait(until: { controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused } }, timeout: 1)
        let delay = ProcessInfo.processInfo.systemUptime - started
        try verify(controller.awaitingFreshSnapshot && controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "a delayed nil result must hide effects after the total grace period")
        try verify(delay >= 0.4 && delay < 0.8,
                   "a 400 ms read failure must not start a second 500 ms grace period")
        metadata.setFailing(false)
        await wait(until: { !controller.awaitingFreshSnapshot && controller.overlays.values.contains { $0.window.isVisible } }, timeout: 3)
        try verify(!controller.awaitingFreshSnapshot && controller.overlays.values.contains { $0.window.isVisible },
                   "a valid read must restore the scene after the delayed failure")
        controller.desktop.stop()
        await drain(for: 0.2)
        metadata.delayNextRead(1.3)
        controller.desktop.start()
        await wait(until: { controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused } }, timeout: 1.1)
        try verify(controller.awaitingFreshSnapshot && controller.overlays.values.allSatisfy { !$0.window.isVisible && $0.isPaused },
                   "an unfinished metadata read must hide effects after its timeout")
        await wait(until: { !controller.awaitingFreshSnapshot && controller.overlays.values.contains { $0.window.isVisible } }, timeout: 4)
        try verify(!controller.awaitingFreshSnapshot && controller.overlays.values.contains { $0.window.isVisible },
                   "a fresh capture after a timed-out read must restore the scene")
        log("PASS delayed metadata: timed-out in-flight capture hides effects and a fresh read restores them")
    }

    private func verifyDecorationControls(_ controller: ApplicationController) async throws {
        let fields: [(String, WritableKeyPath<FestiveOptions, Bool>)] = [
            ("desktopGarland", \.desktopGarland), ("windowGarlands", \.windowGarlands),
            ("christmasTrees", \.christmasTrees), ("aurora", \.aurora), ("shootingStars", \.shootingStars),
            ("duck", \.duck)
        ]
        try verify(controller.settings.decorations == FestiveOptions() && controller.decorationControls.count == fields.count,
                   "all decoration controls exist, with only the duck defaulting to on")
        guard let content = controller.popover.contentViewController?.view else {
            throw LifecycleFailure(description: "Settings view is missing")
        }
        content.frame = CGRect(origin: .zero, size: controller.popover.contentSize)
        try saveOwnView(content, name: "settings-snow.png")
        controller.settingsTabControl?.selectedSegment = 1
        try sendAction(controller.settingsTabControl)
        controller.popover.contentViewController?.view.layoutSubtreeIfNeeded()
        try verify(controller.popover.contentSize.height <= 666,
                   "decoration settings must preserve the bounded menu height")
        try saveOwnView(content, name: "settings-decorations.png")
        for (id, key) in fields {
            guard let control = controller.decorationControls[id] else { throw LifecycleFailure(description: "Missing decoration \(id)") }
            try verify(control.identifier?.rawValue == id && !control.isHiddenOrHasHiddenAncestor
                       && control.accessibilityLabel()?.isEmpty == false && control.toolTip?.isEmpty == false,
                       "each decoration must be visible in its tab and have an accessible name/hint")
            var expected = FestiveOptions(); expected[keyPath: key].toggle()
            control.state = expected[keyPath: key] ? .on : .off; try sendAction(control)
            try verify(controller.settings.decorations == expected
                       && controller.overlays.values.allSatisfy { $0.scene.decorationOptions == expected },
                       "a checkbox must change only its own flag and update every scene")
            control.state = expected[keyPath: key] ? .off : .on; try sendAction(control)
            try verify(controller.settings.decorations == FestiveOptions(), "each decoration restores its own default")
        }
        controller.decorationControls["desktopGarland"]?.state = .on
        try sendAction(controller.decorationControls["desktopGarland"])
        controller.decorationControls["aurora"]?.state = .on
        try sendAction(controller.decorationControls["aurora"])
        controller.decorationControls["duck"]?.state = .off
        try sendAction(controller.decorationControls["duck"])
        await wait(until: {
            let saved = SettingsStore(url: controller.store.url).load().decorations
            return saved.desktopGarland && saved.aurora && !saved.duck
        }, timeout: 1)
        try verify(SettingsStore(url: controller.store.url).load().decorations == controller.settings.decorations,
                   "actual checkbox actions must persist decoration preferences through the debounced store")
        for id in ["desktopGarland", "aurora"] {
            controller.decorationControls[id]?.state = .off; try sendAction(controller.decorationControls[id])
        }
        controller.decorationControls["duck"]?.state = .on
        try sendAction(controller.decorationControls["duck"])
        controller.settingsTabControl?.selectedSegment = 0
        try sendAction(controller.settingsTabControl)
        guard let support = controller.world.surfaces.first,
              let display = controller.overlays.values.first(where: { $0.window.frame.contains(support.frame.origin) })?.window.frame else {
            throw LifecycleFailure(description: "Own synthetic support is missing for decoration cleanup")
        }
        let point = CGPoint(x: support.frame.midX, y: support.top + SnowDrift.maximumHeight + 1)
        try verify(controller.festiveWorld.place(at: point, displayFrame: display, snow: controller.world) != nil,
                   "cleanup regression starts with a real anchored tree")
        controller.decorationControls["christmasTrees"]?.state = .on
        try sendAction(controller.decorationControls["christmasTrees"])
        controller.decorationControls["christmasTrees"]?.state = .off
        try sendAction(controller.decorationControls["christmasTrees"])
        try verify(controller.festiveWorld.placements(in: controller.world).count == 1,
                   "disabling tree rendering must retain placements")
        try sendAction(controller.clearControl)
        try verify(controller.festiveWorld.placements(in: controller.world).isEmpty,
                   "actual clear-all target/action must clear transient decorations too")
        try verify(controller.festiveWorld.place(at: point, displayFrame: display, snow: controller.world) != nil,
                   "Space regression starts with a real anchored tree")
        log("PASS decoration settings: independent accessible checkboxes, fixed-height tabs, scene binding and persisted target/actions")
    }

    private func verifyDuckGeometry(_ controller: ApplicationController, snapshot: DesktopSnapshot, screen: CGRect) throws {
        let wasPaused = controller.settings.paused
        controller.settings.paused = false
        controller.changedSettings()
        defer {
            controller.settings.paused = wasPaused
            controller.changedSettings()
        }
        let deck = snapshot.surfaces[0]
        let fixtureFrame = CGRect(x: screen.minX, y: screen.minY,
                                  width: min(680, screen.width), height: min(420, screen.height))
        let floor = SnowSurface(id: "lifecycle:own-floor",
                                frame: CGRect(x: screen.minX, y: screen.minY - 1, width: fixtureFrame.width, height: 1), kind: .floor)
        let region = DuckDisplay(frame: fixtureFrame, visibleTop: fixtureFrame.maxY - 24)
        var onFloor = snapshot
        onFloor.surfaces.append(floor)
        controller.desktop.onSnapshot?(onFloor)
        // A ground walk can last up to 600 seconds before the next window visit.
        for _ in 0..<7200 {
            if controller.duckWorld.pose?.anchor?.surfaceID == deck.id { break }
            controller.duckWorld.advance(delta: 0.1, snow: controller.world, trees: controller.festiveWorld,
                                         treesEnabled: false, displays: [region], allDisplayFrames: [fixtureFrame],
                                         plows: [:], sweeps: [], reducedMotion: false)
        }
        guard let local = controller.duckWorld.pose?.anchor, local.surfaceID == deck.id else {
            throw LifecycleFailure(description: "Duck fixture must reach the real scene's accepted roof")
        }
        let objectRoof = SnowSurface(id: "lifecycle:drag-objects",
            frame: CGRect(x: screen.minX + 400, y: screen.minY + 60, width: 180, height: 40), kind: .window)
        var withObjects = onFloor
        withObjects.surfaces.append(objectRoof)
        controller.desktop.onSnapshot?(withObjects)
        guard controller.world.placeSnowman(on: objectRoof, x: objectRoof.frame.midX),
              let headID = controller.world.snowmen.last?.ballIDs.last,
              let head = controller.world.balls.first(where: { $0.id == headID }),
              controller.world.beginDrag(at: head.position) == headID else {
            throw LifecycleFailure(description: "Window drag physics fixture unavailable")
        }
        controller.world.endDrag(velocity: CGVector(dx: 40, dy: 100))
        let freeBefore = controller.world.balls.first { $0.id == headID }!
        controller.primaryPointerDown = { true }
        defer { controller.primaryPointerDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
        let profile = controller.world.drifts[deck.id]?.heights
        var moved = withObjects
        moved.surfaces[0].frame = deck.frame.offsetBy(dx: 30, dy: 17)
        controller.desktop.onSnapshot?(moved)
        try verify(controller.duckWorld.pose?.anchor == local && controller.world.drifts[deck.id]?.heights == profile,
                   "moving the roof keeps the duck anchor and snow profile")
        let duckTime = controller.duckWorld.pose?.time
        controller.world.step(delta: 0.1, weather: SnowWeather(), activeRegions: [fixtureFrame])
        controller.duckWorld.advance(delta: 0.1, snow: controller.world, trees: controller.festiveWorld,
                                     treesEnabled: false, displays: [region], allDisplayFrames: [fixtureFrame],
                                     plows: [:], sweeps: [], reducedMotion: false)
        try verify(controller.world.balls.first { $0.id == headID }?.position == freeBefore.position
                   && controller.duckWorld.pose?.time != duckTime,
                   "accepted manual window movement freezes ball physics while the duck continues")
        controller.primaryPointerDown = { false }
        controller.desktop.onSnapshot?(moved)
        controller.world.step(delta: 0.1, weather: SnowWeather(), activeRegions: [fixtureFrame])
        try verify(controller.world.balls.first { $0.id == headID }?.position != freeBefore.position,
                   "the accepted release resumes free-ball physics")
        moved.surfaces.removeAll { $0.id == objectRoof.id }
        controller.desktop.onSnapshot?(moved)
        let profileAfterDrag = controller.world.drifts[deck.id]?.heights
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        try verify(controller.duckWorld.pose == nil && controller.duckWorld.prints.isEmpty
                   && controller.awaitingFreshSnapshot, "Space resets the visited roof, tracks and pending flight")
        var returning = onFloor
        returning.surfaces[0].frame = deck.frame.offsetBy(dx: 42, dy: 17)
        controller.desktop.onSnapshot?(returning)
        try verify(controller.world.drifts[deck.id]?.surface.frame == returning.surfaces[0].frame
                   && controller.world.drifts[deck.id]?.heights == profileAfterDrag && controller.duckWorld.pose == nil,
                   "first accepted same-size return restores the snow while the old duck visit stays cleared")
        controller.desktop.onSnapshot?(snapshot)
        log("PASS duck geometry: shared window anchor and immediate snow restoration after Space")
    }

    private func verifyTreeToolControls(_ controller: ApplicationController, overlay: DisplayOverlay) throws {
        func tools() -> ActionSegment? {
            descendants(overlay.hud).first { $0.identifier?.rawValue == "gameTools" } as? ActionSegment
        }
        try verify(!controller.availableTools.contains(.tree) && tools()?.segmentCount == 3,
                   "tree tool must be absent while its decoration is disabled")
        guard let checkbox = controller.decorationControls["christmasTrees"] else {
            throw LifecycleFailure(description: "Tree checkbox missing")
        }
        checkbox.state = .on; try sendAction(checkbox)
        guard let expanded = tools(), let treeIndex = controller.availableTools.firstIndex(of: .tree) else {
            throw LifecycleFailure(description: "Tree tool missing after enabling it during game")
        }
        try verify(expanded.segmentCount == 4 && controller.playingDisplay == overlay.id,
                   "enabling trees rebuilds the active HUD without ending game")
        overlay.window.contentView?.layoutSubtreeIfNeeded()
        if let hud = overlay.hud { try saveOwnView(hud, name: "game-tools-four.png") }
        expanded.selectedSegment = treeIndex; try sendAction(expanded)
        try verify(controller.currentTool == .tree && overlay.scene.tool == .tree,
                   "HUD index must map through the filtered tools array")
        _ = overlay.window.makeFirstResponder(expanded)
        checkbox.state = .off; try sendAction(checkbox)
        try verify(controller.currentTool == .mitten && overlay.scene.tool == .mitten
                   && tools()?.segmentCount == 3 && tools()?.selectedSegment == 0,
                   "disabling trees must cancel that tool and restore mitten in scene and HUD")
        try verify(controller.playingDisplay == overlay.id && controller.gameKeyMonitor != nil
                   && overlay.window.receivesGameInput && overlay.window.firstResponder !== expanded,
                   "HUD replacement keeps game/Escape active and does not retain a detached focused control")
        guard let scatter = descendants(overlay.hud).first(where: { $0.identifier?.rawValue == "scatterDecorations" }) as? NSControl else {
            throw LifecycleFailure(description: "Random placement button missing")
        }
        try sendAction(scatter)
        let hint = descendants(overlay.hud).first { $0.identifier?.rawValue == "gameHint" } as? NSTextField
        try verify(controller.settings.decorations.christmasTrees && tools()?.segmentCount == 4
                   && controller.playingDisplay == overlay.id && hint?.stringValue.contains("Esc") == true,
                   "random placement enables trees, rebuilds HUD and reports its outcome without ending game")
    }

    private func saveOwnView(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let directory = evidenceDirectory,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw LifecycleFailure(description: "Cannot export own view \(name), bounds=\(view.bounds)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw LifecycleFailure(description: "Cannot encode own view \(name)")
        }
        try data.write(to: directory.appendingPathComponent(name))
        log("Own-view PNG: \(directory.appendingPathComponent(name).path)")
    }

    private func verifyPermissionFromGame(_ controller: ApplicationController) async throws {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let pointer = NSEvent.mouseLocation
        await wait(until: {
            controller.overlays.values.contains { $0.window.frame.contains(pointer) && !$0.isPaused }
        }, timeout: 1)
        guard let overlay = controller.overlays.values.first(where: { $0.window.frame.contains(pointer) && !$0.isPaused }) else {
            throw LifecycleFailure(description: "Permission regression requires the existing pointer on a rendering display; pointer was not moved")
        }
        try sendAction(controller.gameControl)
        try verify(controller.playingDisplay == overlay.id && !overlay.window.ignoresMouseEvents,
                   "permission regression must begin with a real interactive game overlay")
        await wait(until: { NSApp.isActive }, timeout: 1)
        let permission = descendants(controller.popover.contentViewController?.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Доступ к окнам…" }
        try sendAction(permission)
        try verify(controller.playingDisplay == nil && controller.gameKeyMonitor == nil && overlay.hud == nil,
                   "opening own permission information must end game and remove its HUD/local key monitor")
        try verify(controller.overlays.values.allSatisfy { $0.window.ignoresMouseEvents && !$0.window.receivesGameInput },
                   "own permission window must never remain under an input-intercepting overlay")
        guard let welcome = controller.welcome, let content = welcome.contentView else {
            throw LifecycleFailure(description: "Permission target/action did not show the own welcome window")
        }
        content.layoutSubtreeIfNeeded()
        await wait(until: { welcome.isKeyWindow }, timeout: 1)
        try verify(welcome.isVisible && welcome.isKeyWindow,
                   "own permission information must be visible and receive keyboard focus")
        guard let later = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Начать снегопад" }) else {
            throw LifecycleFailure(description: "Own welcome window has no safe dismiss action")
        }
        let center = later.convert(CGPoint(x: later.bounds.midX, y: later.bounds.midY), to: content)
        try verify(later.isEnabled && content.hitTest(center) === later,
                   "safe welcome action must be enabled and reachable through its actual content view")
        controller.settings.onboardingComplete = false
        try sendAction(later) // Never invoke the button that opens system privacy settings.
        try verify(controller.settings.onboardingComplete && !welcome.isVisible,
                   "the actual safe welcome action must complete onboarding and hide its window")
        if let previousApplication, previousApplication.processIdentifier != getpid(), !previousApplication.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApplication.activate(options: [])
            await wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier }, timeout: 1)
        }
        log("PASS permission during game: actual menu control ends interception; own welcome is key and its safe action works; no TCC/system-settings action")
    }

    private func verifyRenderingFailure(_ controller: ApplicationController) async throws {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let pointer = NSEvent.mouseLocation
        guard let overlay = controller.overlays.values.first(where: { $0.window.frame.contains(pointer) && !$0.isPaused }),
              let particles = overlay.particles, let failure = particles.onFailure else {
            throw LifecycleFailure(description: "Rendering failure regression requires an active Metal overlay with its production callback")
        }
        try sendAction(controller.gameControl)
        try verify(controller.playingDisplay == overlay.id && !overlay.window.ignoresMouseEvents,
                   "rendering failure regression must start during a real game")
        await wait(until: { NSApp.isActive }, timeout: 1)
        let message = "Lifecycle test: injected renderer failure"
        failure(message) // Wiring injection only; not a claim that hardware failure was reproduced.
        try verify(controller.playingDisplay == nil && controller.gameKeyMonitor == nil && overlay.hud == nil,
                   "renderer failure callback must terminate the active game")
        try verify(overlay.window.ignoresMouseEvents && !overlay.window.receivesGameInput
                   && !overlay.window.isVisible && overlay.isPaused && overlay.scene.isPaused,
                   "failed overlay must become passive, hidden and paused")
        try verify(overlay.renderingFailure == message && controller.infoLabel?.stringValue == message,
                   "renderer failure must be retained and explained by the menu status")
        let frames = particles.submittedFrames
        controller.changedSettings()
        await drain(for: 0.1)
        try verify(!overlay.window.isVisible && overlay.isPaused && particles.submittedFrames == frames,
                   "a later settings refresh must not restart the failed renderer")
        if let previousApplication, previousApplication.processIdentifier != getpid(), !previousApplication.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApplication.activate(options: [])
            await wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier }, timeout: 1)
        }
        log("PASS injected renderer callback: game ends, overlay is passive/hidden/paused, menu shows error; later refresh cannot restart it. No GPU fault was induced.")
    }

    private func identities(_ controller: ApplicationController) -> [UInt32: ObjectIdentifier] {
        controller.overlays.mapValues { ObjectIdentifier($0) }
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func sendAction(_ control: NSControl?) throws {
        guard let control, let action = control.action,
              NSApp.sendAction(action, to: control.target, from: control) else {
            throw LifecycleFailure(description: "A required own control has no working target/action")
        }
    }

    private func drain(for seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { await drain(for: 0.01) }
    }
}

@main
@MainActor
private struct ApplicationLifecycleTestsMain {
    static func main() {
        func argument(_ key: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        if CommandLine.arguments.contains("--duck-fixture-window") {
            _ = NSApplication.shared
            guard let frame = NSScreen.screens.first?.frame else { exit(2) }
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: CGRect(x: frame.minX + frame.width * 0.36,
                                                       y: frame.minY + frame.height * 0.25,
                                                       width: frame.width * 0.27, height: frame.height * 0.24),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Podokonnik duck route test"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            withExtendedLifetime(window) {}
            exit(0)
        }
        if CommandLine.arguments.contains("--rejected-launch-child") {
            guard argument("--settings-path") != nil else { exit(2) }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let rejected = ApplicationController()
            rejected.settings.paused = false
            rejected.settings.windX = -0.9
            NSApp.delegate = rejected
            // A regression that accepts the launch must not create a long-lived child.
            _ = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in exit(3) }
            NSApp.run()
            exit(4)
        }
        guard let settingsPath = argument("--settings-path"), let reportPath = argument("--lifecycle-evidence") else {
            print("Usage: application-lifecycle-tests --settings-path <isolated.json> --lifecycle-evidence <report.txt>")
            exit(2)
        }
        let settingsURL = URL(fileURLWithPath: settingsPath)
        let reportURL = URL(fileURLWithPath: reportPath)
        let checks = LifecycleChecks()
        checks.log("ApplicationLifecycleTests: own AppKit windows and target/action controls only")
        checks.log("Renderer mode: \(!CommandLine.arguments.contains("--spritekit-particles") ? "Unified Metal + SKRenderer" : "SpriteKit particles")")
        let duckFixture = argument("--duck-without-access").map { URL(fileURLWithPath: $0) }
        if duckFixture == nil {
            checks.log("Scope: local injected session notifications and geometry snapshots; final resume uses a real metadata callback.")
            checks.log("Not measured: real sleep/wake, real user switching, system Low Power Mode, presented FPS or other apps' input.")
            var initial = AppSettings()
            initial.paused = true
            initial.onboardingComplete = true
            initial.decorations = FestiveOptions()
            SettingsStore(url: settingsURL).save(initial)
        } else {
            checks.log("Scope: fresh settings, real Accessibility status, WindowServer geometry, own foreground window and live scene frames.")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            var success = false
            do {
                if let duckFixture { try await checks.verifyDuckWithoutAccess(settingsURL: settingsURL, fixtureURL: duckFixture) }
                else { try await checks.run(settingsURL: settingsURL) }
                success = true
                checks.log("PASS: \(checks.count) lifecycle checks; own overlays and observers cleaned up")
            } catch { checks.log("FAIL: \(error)") }
            do {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try checks.lines.joined(separator: "\n").appending("\n").write(to: reportURL, atomically: true, encoding: .utf8)
            } catch { print("Cannot write lifecycle evidence: \(error)") }
            exit(success ? 0 : 1)
        }
        // Display ticks and WindowServer occlusion changes need the actual AppKit
        // event loop. Async waits above yield to it; no manual scene.update/draw.
        NSApp.run()
    }
}
