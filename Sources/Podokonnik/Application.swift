import AppKit
import SpriteKit

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class SnowFrameLimiter: NSObject, SKViewDelegate {
    var pacer = FramePacer()
    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        pacer.shouldRender(at: time)
    }
}

final class OverlayWindow: NSWindow {
    var receivesGameInput = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { receivesGameInput }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if receivesGameInput && event.type == .keyDown && event.keyCode == 53 {
            onEscape?(); return
        }
        super.sendEvent(event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

final class DisplayOverlay {
    let id: UInt32
    let window: OverlayWindow
    let view: NSView
    let spriteView: SKView?
    let scene: SnowScene
    let particles: UnifiedSnowView?
    let maximumFPS: Int
    let backingScale: CGFloat
    let frameLimiter = SnowFrameLimiter()
    var renderingFailure: String?
    var hud: NSVisualEffectView?
    init(screen: NSScreen, world: SnowWorld, festiveWorld: FestiveWorld? = nil) {
        id = Self.displayID(screen)
        maximumFPS = screen.maximumFramesPerSecond
        backingScale = screen.backingScaleFactor
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.level = .floating
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false
        let frame = CGRect(origin: CGPoint.zero, size: screen.frame.size)
        scene = SnowScene(world: world, displayFrame: screen.frame, festiveWorld: festiveWorld)
        scene.scaleMode = .resizeFill; scene.backgroundColor = .clear
        let limiter = frameLimiter
        let batch = CommandLine.arguments.contains("--spritekit-particles")
            ? nil : UnifiedSnowView(frame: frame, scene: scene, maximumFPS: maximumFPS,
                                   shouldRender: { limiter.pacer.shouldRender(at: $0) })
        particles = batch
        if let batch {
            batch.recordsPresentation = CommandLine.arguments.contains("--smoke-presentation")
            view = batch
            spriteView = nil
            window.contentView = batch
        } else {
            let sprite = SKView(frame: frame)
            sprite.allowsTransparency = true; sprite.ignoresSiblingOrder = true
            sprite.shouldCullNonVisibleNodes = true
            sprite.autoresizingMask = [.width, .height]
            sprite.delegate = frameLimiter
            view = sprite
            spriteView = sprite
            window.contentView = sprite
            sprite.presentScene(scene)
        }
    }

    static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func matches(_ screen: NSScreen) -> Bool {
        window.frame == screen.frame && backingScale == screen.backingScaleFactor && maximumFPS == screen.maximumFramesPerSecond
    }

    var isPaused: Bool { particles?.isPaused ?? spriteView?.isPaused ?? true }
    func setPaused(_ value: Bool) {
        particles?.isPaused = value
        spriteView?.isPaused = value
    }

    func close() {
        particles?.onFailure = nil
        particles?.invalidate()
        scene.cancelInteraction(); spriteView?.presentScene(nil); window.close()
    }
}

final class ApplicationController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let world = SnowWorld()
    let festiveWorld = FestiveWorld()
    let duckWorld = DuckWorld()
    var snowplowSchedule = SnowplowSchedule()
    private var windowShake = WindowShakeDetector()
    private var windowAnimations = WindowSurfaceAnimations()
    private var windowDrag = WindowDragDetector()
    private var windowDragReleasedAt: TimeInterval?
    var primaryPointerDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    private var spaceGeometryUntil: TimeInterval = 0
    let desktop: DesktopEnvironment
    let store: SettingsStore
    var settings: AppSettings
    private var updateController: UpdateController?
    var automaticUpdatesEnabled: Bool { updateController?.automaticUpdatesEnabled ?? true }
    private var ownsSession = false
    private var instanceLock: ApplicationInstanceLock?
    private var cachedWeather = SnowWeather()
    private var stressSeeded = false
    private var smokeStage = -1
    var policy = SessionPolicy()
    var overlays: [UInt32: DisplayOverlay] = [:]
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var welcome: NSWindow?
    var monitors: [NSObjectProtocol] = []
    var playingDisplay: UInt32?
    var previousApp: NSRunningApplication?
    var appBeforePopover: NSRunningApplication?
    var activatePreviousApp: (NSRunningApplication) -> Void = { $0.activate(options: []) }
    var currentTool: SnowTool = .mitten
    var snapshot: DesktopSnapshot?
    var lastFrame: TimeInterval = 0
    var frameIntervals: [Double] = []
    var lastRefresh: TimeInterval = 0
    var awaitingFreshSnapshot = true
    private var geometryUnavailable = false
    private var captureFailureToken: UUID?
    var desktopActive = false
    var intensityControl: ActionSegment?
    var pauseControl: ActionButton?
    var gameControl: ActionButton?
    var plowNowControl: ActionButton?
    var plowSpeedSlider: ActionSlider?
    var plowSpeedLabel: NSTextField?
    var windPad: WindPad?
    var windXSlider: ActionSlider?
    var windYSlider: ActionSlider?
    var infoLabel: NSTextField?
    var permissionLabel: NSTextField?
    var settingsTabControl: ActionSegment?
    var decorationControls: [String: NSButton] = [:]
    private var updateStatusLabel: NSTextField?
    private var installUpdateButton: ActionButton?
    var clearControl: ActionButton?
    private var settingsPages: [NSScrollView] = []
    private var hudTools: [SnowTool] = []
    var smokeTimer: Timer?
    var metricTimer: Timer?
    var metricStart: ProcessSample?
    var metricPrevious: ProcessSample?
    var performanceSamples: [[String: Any]] = []
    var saveWork: DispatchWorkItem?
    var gameKeyMonitor: Any?
    let smokeSeconds: Double?
    let evidenceDirectory: URL?
    let buildInfo: [String: String]

    override convenience init() { self.init(desktop: DesktopEnvironment()) }

    init(desktop: DesktopEnvironment) {
        self.desktop = desktop
        let args = CommandLine.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i+1 < args.count else { return nil }; return args[i+1]
        }
        smokeSeconds = value("--smoke-test").flatMap(Double.init)
        evidenceDirectory = value("--evidence").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "json"),
           let data = try? Data(contentsOf: url), let info = try? JSONDecoder().decode([String: String].self, from: data) {
            buildInfo = info
        } else { buildInfo = ["sourceDigest": "development"] }
        store = SettingsStore(url: value("--settings-path").map { URL(fileURLWithPath: $0) })
        settings = store.load()
        if smokeSeconds != nil {
            settings.paused = args.contains("--smoke-paused")
            if args.contains("--smoke-blizzard") || args.contains("--smoke-stress") { settings.intensity = .blizzard }
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let instanceLock = ApplicationInstanceLock(settingsURL: store.url)
        switch instanceLock.acquire() {
        case .alreadyRunning:
            NSApp.terminate(nil); return
        case .failed(let reason):
            let alert = NSAlert()
            alert.messageText = "Не удалось запустить «Подоконник»"
            alert.informativeText = "Проверьте доступ к папке настроек. \(reason)"
            alert.runModal()
            NSApp.terminate(nil); return
        case .acquired:
            self.instanceLock = instanceLock
            ownsSession = true
        }
        // Another instance may have saved between initialization and lock acquisition.
        if smokeSeconds == nil { settings = store.load() }
        NSApp.setActivationPolicy(.accessory)
        policy.userPaused = settings.paused
        if smokeSeconds == nil {
            updateController = UpdateController()
            updateController?.onStatusChange = { [weak self] status in self?.showUpdateStatus(status) }
            updateController?.start()
        }
        setupMenu(); observeSystem(); rebuildDisplays()
        desktop.onSnapshot = { [weak self] snapshot in self?.receive(snapshot) }
        desktop.onCaptureUnavailable = { [weak self] elapsed in self?.captureUnavailable(elapsed: elapsed) }
        desktop.onCaptureTimeout = { [weak self] in self?.captureUnavailable(graceExpired: true) }
        refreshPolicy()
        if smokeSeconds != nil { beginSmokeTest() }
        else if !settings.onboardingComplete { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A rejected second launch must not save its stale settings or clean up
        // resources belonging to the running instance.
        guard ownsSession else { return }
        captureFailureToken = nil
        defer { ownsSession = false; instanceLock?.release(); instanceLock = nil }
        desktop.stop(); smokeTimer?.invalidate(); metricTimer?.invalidate(); saveWork?.cancel()
        if let gameKeyMonitor { NSEvent.removeMonitor(gameKeyMonitor) }
        if smokeSeconds == nil { store.save(settings) }
        monitors.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        overlays.values.forEach { $0.close() }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping () -> Void) {
            monitors.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in block() })
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.rebuildDisplays() }
        observe(.default, NSApplication.didResignActiveNotification) { [weak self] in self?.endGame(restoreFocus: false) }
        observe(.default, NSWindow.didChangeOcclusionStateNotification) { [weak self] in self?.refreshPolicy() }
        observe(.default, .NSProcessInfoPowerStateDidChange) { [weak self] in self?.refreshPolicy() }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.refreshPolicy() }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.refreshPolicy() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.policy.sleeping = true; self?.refreshPolicy() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.policy.sleeping = false; self?.spaceChanged() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.policy.inactive = true; self?.refreshPolicy() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.policy.inactive = false; self?.spaceChanged() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.spaceChanged() }
    }

    private func rebuildDisplays() {
        let screens = NSScreen.screens
        if screens.count == overlays.count,
           screens.allSatisfy({ overlays[DisplayOverlay.displayID($0)]?.matches($0) == true }) {
            desktop.refresh()
            refreshPolicy()
            return
        }
        endGame(restoreFocus: false)
        resetWindowMotion(); snowplowSchedule.cancelPasses()
        duckWorld.clear(preserveMemory: true)
        awaitingFreshSnapshot = true
        overlays.values.forEach { $0.close() }; overlays.removeAll(); lastFrame = 0
        windowAnimations = WindowSurfaceAnimations()
        for screen in screens {
            let overlay = DisplayOverlay(screen: screen, world: world, festiveWorld: festiveWorld)
            overlay.scene.duckWorld = duckWorld
            overlay.scene.onFrame = { [weak self, weak overlay] time in
                guard let self, let overlay, self.driverID == overlay.id else { return }
                self.advance(time)
            }
            overlay.scene.onExitGame = { [weak self] in self?.endGame() }
            overlay.scene.onToolChange = { [weak self] tool in self?.currentTool = tool }
            overlay.window.onEscape = { [weak self] in self?.endGame() }
            overlay.scene.onLimit = { [weak self] text in self?.showGameHint(text) }
            overlay.particles?.onFailure = { [weak self, weak overlay] message in
                guard let self, let overlay else { return }
                overlay.renderingFailure = message
                self.endGame(restoreFocus: false)
                self.refreshPolicy()
            }
            overlays[overlay.id] = overlay
        }
        let frames = screens.map(\.frame)
        world.prune(to: frames)
        festiveWorld.prune(to: frames, snow: world)
        desktop.excludedWindowIDs = Set(overlays.values.compactMap { $0.window.windowNumber > 0 ? UInt32($0.window.windowNumber) : nil })
        desktop.invalidate(); desktop.refresh(); refreshPolicy()
    }

    var driverID: UInt32? {
        FramePacer.driverID(displays: overlays.values.filter { !$0.isPaused }.map {
            (id: $0.id, nativeMaximum: $0.maximumFPS)
        }, isMoving: desktop.isGeometryMoving, constrained: weather.lowPower || weather.reducedMotion)
    }

    private var activeDuckDisplays: [DuckDisplay] {
        overlays.values.filter { !$0.isPaused }.sorted { $0.id < $1.id }.map {
            let visible = $0.scene.decorationVisibleFrame
            return DuckDisplay(frame: $0.window.frame, visibleTop: visible.maxY, visibleBottom: visible.minY,
                               visibleLeft: visible.minX, visibleRight: visible.maxX)
        }
    }

    private func advance(_ time: TimeInterval) {
        updateRenderRates()
        desktop.noteInteraction()
        if windowDrag.isDragging {
            if !primaryPointerDown() {
                let now = ProcessInfo.processInfo.systemUptime
                if windowDragReleasedAt == nil { windowDragReleasedAt = now }
                if let released = windowDragReleasedAt, now - released >= 0.35 {
                    windowDrag.reset(); windowDragReleasedAt = nil
                    world.setObjectsFrozen(false)
                }
            } else {
                windowDragReleasedAt = nil
            }
        }
        let delta = lastFrame == 0 ? 1.0/60 : max(0, time-lastFrame)
        // Different display links may report their target timestamps out of order
        // when the driver changes. Never count an interval twice.
        lastFrame = max(lastFrame, time)
        if smokeSeconds != nil && delta > 0 && frameIntervals.count < 1_000_000 { frameIntervals.append(delta) }
        let regions = overlays.values.filter { !$0.isPaused }.map { $0.window.frame }
        world.step(delta: min(delta, 0.1), weather: weather, activeRegions: regions)
        let sweeps = snowplowSchedule.advance(delta: min(delta, 0.1), surfaces: world.surfaces,
                                              activeRegions: regions, intervalMinutes: settings.plowIntervalMinutes,
                                              reducedMotion: weather.reducedMotion,
                                              speedMultiplier: settings.plowSpeedMultiplier)
        for sweep in sweeps {
            world.sweepFloor(surfaceID: sweep.surfaceID, fromX: sweep.fromX, toX: sweep.toX)
        }
        for overlay in overlays.values { overlay.scene.snowplowPasses = snowplowSchedule.passes }
        if settings.decorations.duck {
            duckWorld.advance(delta: delta, snow: world, trees: festiveWorld,
                              treesEnabled: settings.decorations.christmasTrees, displays: activeDuckDisplays,
                              allDisplayFrames: overlays.values.map { $0.window.frame },
                              plows: snowplowSchedule.passes, sweeps: sweeps, reducedMotion: weather.reducedMotion)
        }
    }

    var weather: SnowWeather { cachedWeather }

    private func updateRenderRates() {
        let moving = desktop.isGeometryMoving
        let constrained = weather.lowPower || weather.reducedMotion
        for overlay in overlays.values {
            overlay.frameLimiter.pacer.rate = FramePacer.preferredRate(nativeMaximum: overlay.maximumFPS,
                                                                      isMoving: moving, constrained: constrained)
        }
    }

    private func refreshWeather() {
        let thermal = ProcessInfo.processInfo.thermalState
        cachedWeather = SnowWeather(intensity: settings.intensity,
                                    wind: CGVector(dx: settings.windX, dy: settings.windY),
                                    reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                    lowPower: settings.economy || ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious)
    }

    private func receive(_ new: DesktopSnapshot) {
        captureFailureToken = nil
        let trustLost = snapshot?.accessibilityTrusted == true && !new.accessibilityTrusted
        snapshot = new
        if trustLost { endGame(restoreFocus: false) }
        if new.missionControlActive { endGame(restoreFocus: false) }
        policy.fullscreenDisplayIDs = new.fullscreenDisplayIDs
        let fullscreenFrames = overlays.values.filter { new.fullscreenDisplayIDs.contains($0.id) }.map { $0.window.frame }
        // Fullscreen geometry can temporarily replace the same window ID with
        // a much larger frame. Preserve the stored window-local profile.
        let motionTime = ProcessInfo.processInfo.systemUptime
        let pointerPressed = primaryPointerDown()
        let spaceChanging = motionTime < spaceGeometryUntil
        let fullscreenSupports = Set(new.surfaces.filter { surface in
            surface.kind != .floor && fullscreenFrames.contains {
                $0.insetBy(dx: -2, dy: -2).contains(surface.frame) || DesktopGeometry.coversDisplay(surface.frame, $0)
            }
        }.map(\.id))
        let hiddenIDs = new.hiddenWindowSupportIDs.union(fullscreenSupports)
        let surfaces = windowAnimations.reconcile(new.surfaces, previous: world.surfaces, hiddenIDs: hiddenIDs,
            displays: overlays.values.map { $0.window.frame },
            pointerPressed: pointerPressed, spaceChanging: spaceChanging,
            missionControlActive: new.missionControlActive, at: motionTime)
        let shakes = windowShake.update(surfaces: surfaces, dragging: pointerPressed && !spaceChanging, at: motionTime)
        let draggingWindow = windowDrag.update(previous: world.surfaces, current: surfaces,
            pointerPressed: pointerPressed && !spaceChanging && playingDisplay == nil)
        if draggingWindow { world.setObjectsFrozen(true) }
        world.syncSurfaces(surfaces)
        if !draggingWindow { world.setObjectsFrozen(false); windowDragReleasedAt = nil }
        festiveWorld.syncSurfaces(surfaces)
        duckWorld.sync(world.surfaces, fullscreenFrames: fullscreenFrames)
        for (id, velocity) in shakes { world.shedSnow(surfaceID: id, velocity: velocity) }
        if !shakes.isEmpty { duckWorld.windowShook(Set(shakes.keys)) }
        geometryUnavailable = false
        awaitingFreshSnapshot = false
        refreshPolicy()
    }

    private func captureUnavailable(elapsed: TimeInterval = 0, graceExpired: Bool = false) {
        guard !geometryUnavailable else { return }
        if graceExpired || elapsed >= 0.5 {
            captureFailureToken = nil
            geometryUnavailable = true
        } else {
            guard captureFailureToken == nil else { return }
            captureFailureToken = UUID()
        }
        awaitingFreshSnapshot = true
        endGame()
        resetWindowMotion()
        lastFrame = 0
        refreshPolicy()
        guard let token = captureFailureToken else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.5 - elapsed)) { [weak self] in
            guard let self, self.captureFailureToken == token else { return }
            self.captureFailureToken = nil
            self.geometryUnavailable = true
            self.refreshPolicy()
        }
    }

    private func resetWindowMotion() {
        windowShake.reset()
        windowDrag.reset(); windowDragReleasedAt = nil
        world.setObjectsFrozen(false)
    }

    private func refreshPolicy() {
        refreshWeather()
        duckWorld.setEnabled(settings.decorations.duck, surfaces: world.surfaces)
        policy.userPaused = settings.paused
        policy.screenshotPaused = settings.pauseForScreenshots && snapshot?.screenshotSelectionActive == true
        policy.criticalThermal = ProcessInfo.processInfo.thermalState == .critical
        if policy.globallySuspended || playingDisplay.map({ !policy.isVisible(displayID: $0) }) == true { endGame(restoreFocus: false) }
        if policy.globallySuspended {
            resetWindowMotion()
            desktop.stop(); desktopActive = false; lastFrame = 0
        } else {
            if !desktopActive { awaitingFreshSnapshot = true; desktopActive = true }
            desktop.start()
        }
        updateRenderRates()
        let screens = NSScreen.screens
        for overlay in overlays.values {
            let allowed = policy.isVisible(displayID: overlay.id) && snapshot?.missionControlActive != true
                && overlay.renderingFailure == nil && !geometryUnavailable
            let geometryReady = !awaitingFreshSnapshot
            overlay.scene.weather = weather
            overlay.scene.decorationOptions = settings.decorations
            overlay.scene.decorationVisibleFrame = screens.first {
                DisplayOverlay.displayID($0) == overlay.id
            }?.visibleFrame ?? overlay.window.frame
            // Let the display tick at its native rate; the public SKView delegate
            // skips update + render to maintain 60 (or 30) on non-divisible rates.
            overlay.spriteView?.preferredFramesPerSecond = max(1, overlay.maximumFPS)
            if allowed {
                // Only order on state transition: repeated ordering would move overlays above menus.
                if geometryReady && !overlay.window.isVisible { overlay.window.orderFrontRegardless() }
            } else if overlay.window.isVisible { overlay.window.orderOut(nil) }
            // WindowServer can carry the already presented frame across Spaces.
            // Leave the window ordered while we wait for the new geometry.
            let rendering = allowed && geometryReady && overlay.window.occlusionState.contains(.visible)
            if overlay.isPaused == rendering {
                overlay.scene.resetAnimationClock(); overlay.frameLimiter.pacer.reset(); lastFrame = 0
                overlay.particles?.resetPresentationClock()
            }
            overlay.scene.isPaused = !rendering; overlay.setPaused(!rendering)
        }
        if settings.decorations.duck { duckWorld.updateDisplayVisibility(activeDuckDisplays) }
        statusItem?.button?.appearsDisabled = settings.paused
        updateLabels()
    }

    private func spaceChanged() {
        awaitingFreshSnapshot = true
        spaceGeometryUntil = ProcessInfo.processInfo.systemUptime + 0.65
        windowAnimations.resetForSpaceChange()
        resetWindowMotion(); snowplowSchedule.cancelPasses()
        duckWorld.clear(preserveMemory: true)
        overlays.values.forEach { $0.scene.snowplowPasses = [:] }
        endGame(restoreFocus: false); lastFrame = 0
        desktop.invalidate()
        refreshPolicy()
    }

    func changedSettings() {
        let tools = availableTools
        if !tools.contains(currentTool) {
            currentTool = .mitten
            overlays.values.forEach { $0.scene.cancelInteraction(); $0.scene.tool = .mitten }
        }
        if let id = playingDisplay, let overlay = overlays[id], hudTools != tools {
            let focusedHUD = (overlay.window.firstResponder as? NSView).map { view in
                overlay.hud.map { view === $0 || view.isDescendant(of: $0) } ?? false
            } ?? false
            overlay.hud?.removeFromSuperview()
            addHUD(to: overlay)
            if focusedHUD { overlay.window.makeFirstResponder(overlay.view) }
        }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.store.save(self.settings); self.updateLabels()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.25, execute: work)
        refreshPolicy()
        windPad?.vector = CGVector(dx: settings.windX, dy: settings.windY)
        windXSlider?.doubleValue = settings.windX; windYSlider?.doubleValue = settings.windY
        plowSpeedSlider?.doubleValue = settings.plowSpeedMultiplier
        for (id, _, _, keyPath) in Self.decorationFields {
            decorationControls[id]?.state = settings.decorations[keyPath: keyPath] ? .on : .off
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Подоконник")
        statusItem.button?.toolTip = "Подоконник"
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient; popover.delegate = self
        popover.contentSize = NSSize(width: 352, height: menuHeight(for: NSScreen.main))
        let vc = NSViewController(); vc.view = makeControls(); popover.contentViewController = vc
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: 352, height: menuHeight(for: button.window?.screen))
        appBeforePopover = NSWorkspace.shared.frontmostApplication
        updateLabels(); NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makeControls() -> NSView {
        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: popover.contentSize))
        content.material = .popover; content.state = .active
        let title = textLabel("❄  Подоконник", size: 25, weight: .semibold)
        let subtitle = textLabel("Снег на рабочем столе", secondary: true)
        let section = { (text: String) in textLabel(text.uppercased(), size: 10, weight: .semibold, secondary: true) }
        intensityControl = ActionSegment(labels: SnowIntensity.allCases.map(\.title), selected: settings.intensity.rawValue) { [weak self] i in
            self?.settings.intensity = SnowIntensity(rawValue: i) ?? .steady; self?.changedSettings()
        }
        let wind = WindPad(frame: .zero); wind.vector = CGVector(dx: settings.windX, dy: settings.windY)
        wind.onChange = { [weak self] v in self?.settings.windX = Double(v.dx); self?.settings.windY = Double(v.dy); self?.changedSettings() }
        windPad = wind
        windXSlider = ActionSlider(value: settings.windX, label: "Ветер влево или вправо") { [weak self] v in self?.settings.windX = v; self?.changedSettings() }
        windYSlider = ActionSlider(value: settings.windY, label: "Вертикальный ветер") { [weak self] v in self?.settings.windY = v; self?.changedSettings() }
        let windHeader = horizontalStack([section("Ветер"), ActionButton("Штиль", symbol: "arrow.counterclockwise") { [weak self] in self?.settings.windX = 0; self?.settings.windY = 0; self?.changedSettings() }])
        let windXLabel = textLabel("↔", secondary: true)
        let windYLabel = textLabel("↕", secondary: true)
        let sliders = horizontalStack([windXLabel, windXSlider!, windYLabel, windYSlider!])
        pauseControl = ActionButton("Пауза", symbol: "pause.fill") { [weak self] in self?.settings.paused.toggle(); self?.changedSettings() }
        gameControl = ActionButton("Играть со снегом", symbol: "hand.draw") { [weak self] in
            guard let self else { return }
            if self.playingDisplay != nil { self.endGame() } else { self.startGame() }
        }
        let clear = ActionButton("Очистить всё", symbol: "sparkles") { [weak self] in
            self?.overlays.values.forEach { $0.scene.cancelInteraction() }
            self?.world.clearAll(); self?.festiveWorld.clear()
            self?.duckWorld.clear()
        }
        clearControl = clear
        let economy = NSButton(checkboxWithTitle: "Экономный режим", target: self, action: #selector(toggleEconomy(_:)))
        economy.state = settings.economy ? .on : .off
        let screenshotPause = NSButton(checkboxWithTitle: "Пауза при скриншоте", target: self, action: #selector(toggleScreenshotPause(_:)))
        screenshotPause.state = settings.pauseForScreenshots ? .on : .off
        screenshotPause.toolTip = "Скрывать снег и украшения при выделении области в штатном «Снимке экрана»."
        let automaticUpdates = NSButton(checkboxWithTitle: "Автоматически обновлять приложение", target: self, action: #selector(toggleAutomaticUpdates(_:)))
        automaticUpdates.identifier = NSUserInterfaceItemIdentifier("automaticUpdates")
        automaticUpdates.setAccessibilityIdentifier("automaticUpdates")
        automaticUpdates.toolTip = "Проверять GitHub и устанавливать новые версии автоматически."
        automaticUpdates.state = automaticUpdatesEnabled ? .on : .off
        let intervals = [5, 10, 30]
        let plowInterval = ActionSegment(labels: intervals.map { "\($0) мин" },
                                        selected: intervals.firstIndex(of: settings.plowIntervalMinutes) ?? 1) { [weak self] index in
            self?.settings.plowIntervalMinutes = intervals[index]; self?.changedSettings()
        }
        plowInterval.setAccessibilityLabel("Интервал уборки снега трактором")
        plowNowControl = ActionButton("Сейчас", symbol: "play.fill") { [weak self] in
            self?.snowplowSchedule.requestSweep(); self?.popover.performClose(nil)
        }
        let plowControls = horizontalStack([plowInterval, plowNowControl!])
        plowSpeedLabel = textLabel(String(format: "%.2f×", settings.plowSpeedMultiplier), size: 12, secondary: true)
        plowSpeedLabel?.setContentCompressionResistancePriority(.required, for: .horizontal)
        let plowSpeedHeader = horizontalStack([textLabel("Скорость трактора", size: 12), plowSpeedLabel!])
        plowSpeedSlider = ActionSlider(value: settings.plowSpeedMultiplier, label: "Скорость трактора", range: 0.5...2) { [weak self] value in
            self?.settings.plowSpeedMultiplier = value; self?.changedSettings()
        }
        permissionLabel = textLabel("", size: 11, secondary: true)
        let permission = ActionButton("Доступ к окнам…", symbol: "lock.open") { [weak self] in self?.showWelcome() }
        infoLabel = textLabel("Снег запускается…", size: 11, secondary: true)
        let quit = ActionButton("Завершить", symbol: "power") { NSApp.terminate(nil) }
        let snow = verticalStack([section("Снегопад"), intensityControl!, windHeader, wind, sliders, screenshotPause,
                                  section("Уборка трактором"), plowControls, plowSpeedHeader, plowSpeedSlider!, economy], spacing: 10)
        var decorationRows: [NSView] = [section("Праздничное настроение")]
        for (id, label, hint, _) in Self.decorationFields {
            let checkbox = NSButton(checkboxWithTitle: label, target: self, action: #selector(toggleDecoration(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(id)
            checkbox.setAccessibilityIdentifier(id)
            checkbox.setAccessibilityLabel(label)
            checkbox.setAccessibilityHelp(hint)
            checkbox.toolTip = hint
            decorationControls[id] = checkbox
            let explanation = textLabel(hint, size: 11, secondary: true)
            let row = verticalStack([checkbox, explanation], spacing: 4)
            explanation.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            decorationRows.append(row)
        }
        let decorations = verticalStack(decorationRows, spacing: 16)
        for row in decorationRows { row.widthAnchor.constraint(equalTo: decorations.widthAnchor).isActive = true }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let currentVersion = textLabel("Текущая версия: \(version)")
        currentVersion.identifier = NSUserInterfaceItemIdentifier("currentVersion")
        updateStatusLabel = textLabel((updateController?.status ?? .unknown).description, secondary: true)
        updateStatusLabel?.identifier = NSUserInterfaceItemIdentifier("updateStatus")
        let checkUpdates = ActionButton("Проверить обновления", symbol: "arrow.clockwise") { [weak self] in
            self?.updateController?.checkNow()
        }
        checkUpdates.identifier = NSUserInterfaceItemIdentifier("checkUpdates")
        installUpdateButton = ActionButton("Установить обновление", symbol: "arrow.down.circle") { [weak self] in
            self?.updateController?.installUpdate()
        }
        installUpdateButton?.identifier = NSUserInterfaceItemIdentifier("installUpdate")
        let updates = verticalStack([section("Обновления"), currentVersion, updateStatusLabel!,
                                     checkUpdates, installUpdateButton!, automaticUpdates], spacing: 12)
        showUpdateStatus(updateController?.status ?? .unknown)
        settingsPages = [scrollingPage(snow), scrollingPage(decorations), scrollingPage(updates)]
        let pages = NSView(); pages.translatesAutoresizingMaskIntoConstraints = false
        for page in settingsPages {
            pages.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pages.leadingAnchor), page.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
                page.topAnchor.constraint(equalTo: pages.topAnchor), page.bottomAnchor.constraint(equalTo: pages.bottomAnchor)
            ])
        }
        settingsTabControl = ActionSegment(labels: ["Снег", "Украшения", "Обновления"], selected: 0) { [weak self] index in
            guard let self, self.settingsPages.indices.contains(index) else { return }
            for (i, page) in self.settingsPages.enumerated() { page.isHidden = i != index }
        }
        settingsTabControl?.identifier = NSUserInterfaceItemIdentifier("settingsTabs")
        settingsTabControl?.setAccessibilityLabel("Раздел настроек")
        for page in settingsPages.dropFirst() { page.isHidden = true }
        for (id, _, _, keyPath) in Self.decorationFields {
            decorationControls[id]?.state = settings.decorations[keyPath: keyPath] ? .on : .off
        }
        let stack = verticalStack([title, subtitle, settingsTabControl!, pages,
                                   horizontalStack([pauseControl!, gameControl!]), clear,
                                   permissionLabel!, horizontalStack([permission, quit]), infoLabel!], spacing: 10)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            pages.widthAnchor.constraint(equalTo: stack.widthAnchor), pages.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            settingsTabControl!.widthAnchor.constraint(equalTo: stack.widthAnchor),
            infoLabel!.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionLabel!.widthAnchor.constraint(equalTo: stack.widthAnchor),
            wind.widthAnchor.constraint(equalTo: snow.widthAnchor), wind.heightAnchor.constraint(equalToConstant: 102),
            intensityControl!.widthAnchor.constraint(equalTo: snow.widthAnchor),
            windXSlider!.widthAnchor.constraint(equalToConstant: 128),
            windYSlider!.widthAnchor.constraint(equalToConstant: 128),
            windXLabel.widthAnchor.constraint(equalToConstant: 16),
            windYLabel.widthAnchor.constraint(equalToConstant: 16),
            sliders.widthAnchor.constraint(equalTo: snow.widthAnchor), clear.widthAnchor.constraint(equalTo: stack.widthAnchor),
            plowSpeedHeader.widthAnchor.constraint(equalTo: snow.widthAnchor),
            plowSpeedLabel!.widthAnchor.constraint(equalToConstant: 52),
            plowSpeedSlider!.widthAnchor.constraint(equalTo: snow.widthAnchor)
        ])
        return content
    }

    private static let decorationFields: [(String, String, String, WritableKeyPath<FestiveOptions, Bool>)] = [
        ("desktopGarland", "Гирлянда рабочего стола", "Тёплые огни по верхнему краю, за окнами.", \.desktopGarland),
        ("windowGarlands", "Гирлянды на окнах", "Огоньки следуют за верхними кромками окон.", \.windowGarlands),
        ("christmasTrees", "Новогодние ёлочки", "«Ёлочка» в игре ставит и переносит; «Лопата» удаляет.", \.christmasTrees),
        ("aurora", "Северное сияние", "Мягкое цветное свечение на свободном рабочем столе.", \.aurora),
        ("shootingStars", "Падающие звёзды", "Редкие короткие следы за открытыми окнами.", \.shootingStars),
        ("duck", "Уточка", "Гуляет по снегу и иногда навещает окна.", \.duck)
    ]

    private func menuHeight(for screen: NSScreen?) -> CGFloat {
        min(666, max(440, (screen?.visibleFrame.height ?? 698) - 32))
    }

    private func scrollingPage(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        return scroll
    }

    @objc private func toggleDecoration(_ button: NSButton) {
        guard let id = button.identifier?.rawValue,
              let field = Self.decorationFields.first(where: { $0.0 == id }) else { return }
        settings.decorations[keyPath: field.3] = button.state == .on
        changedSettings()
    }

    @objc private func toggleAutomaticUpdates(_ button: NSButton) {
        updateController?.setAutomaticUpdatesEnabled(button.state == .on)
    }

    private func showUpdateStatus(_ status: UpdateStatus) {
        updateStatusLabel?.stringValue = status.description
        if case .available = status { installUpdateButton?.isHidden = false }
        else { installUpdateButton?.isHidden = true }
    }

    @objc private func toggleEconomy(_ button: NSButton) { settings.economy = button.state == .on; changedSettings() }
    @objc private func toggleScreenshotPause(_ button: NSButton) {
        settings.pauseForScreenshots = button.state == .on
        changedSettings()
    }

    private func updateLabels() {
        pauseControl?.title = settings.paused ? "Продолжить" : "Пауза"
        gameControl?.title = playingDisplay == nil ? "Играть со снегом" : "Закончить игру"
        gameControl?.isEnabled = !policy.globallySuspended && driverID != nil
        plowNowControl?.isEnabled = !policy.globallySuspended && driverID != nil && snowplowSchedule.passes.isEmpty
        plowSpeedLabel?.stringValue = String(format: "%.2f×", settings.plowSpeedMultiplier)
        permissionLabel?.stringValue = DesktopEnvironment.accessibilityTrusted() ? "Доступ разрешён · только геометрия окон" : "Базовый режим · доступ к окнам можно разрешить"
        if let error = overlays.values.compactMap(\.renderingFailure).first { infoLabel?.stringValue = error }
        else if let error = store.lastError { infoLabel?.stringValue = error }
        else if policy.globallySuspended { infoLabel?.stringValue = "Пауза · снег сохранён" }
        else if policy.screenshotPaused { infoLabel?.stringValue = "Пауза на время снимка экрана" }
        else if geometryUnavailable { infoLabel?.stringValue = "Не удалось получить положение окон · повторяем попытку" }
        else if playingDisplay != nil { infoLabel?.stringValue = "Игра включена · Esc возвращает рабочий стол" }
        else { infoLabel?.stringValue = "Снег идёт · клики проходят в приложения" }
    }

    private func startGame() {
        guard !policy.globallySuspended else { return }
        let point = NSEvent.mouseLocation
        guard let overlay = overlays.values.first(where: { $0.window.frame.contains(point) && !$0.isPaused }) else { return }
        previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() ? appBeforePopover : NSWorkspace.shared.frontmostApplication
        popover.performClose(nil)
        playingDisplay = overlay.id
        gameKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.playingDisplay != nil, event.keyCode == 53 else { return event }
            self.endGame(); return nil
        }
        overlay.window.receivesGameInput = true; overlay.window.ignoresMouseEvents = false
        overlay.scene.playing = true; overlay.scene.tool = currentTool
        addHUD(to: overlay)
        NSApp.activate(ignoringOtherApps: true)
        overlay.window.makeKeyAndOrderFront(nil); overlay.window.makeFirstResponder(overlay.view)
        updateLabels()
    }

    func endGame(restoreFocus: Bool = true) {
        guard let id = playingDisplay else { return }
        let shouldRestoreFocus = restoreFocus && NSApp.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        playingDisplay = nil
        if let gameKeyMonitor { NSEvent.removeMonitor(gameKeyMonitor); self.gameKeyMonitor = nil }
        if let overlay = overlays[id] {
            overlay.scene.cancelInteraction(); overlay.scene.playing = false
            overlay.window.ignoresMouseEvents = true; overlay.window.receivesGameInput = false
            overlay.hud?.removeFromSuperview(); overlay.hud = nil
            overlay.window.resignKey()
        }
        if shouldRestoreFocus, let previousApp { activatePreviousApp(previousApp) }
        previousApp = nil; updateLabels()
    }

    private func addHUD(to overlay: DisplayOverlay) {
        let hud = NSVisualEffectView(); hud.material = .hudWindow; hud.state = .active
        hud.wantsLayer = true; hud.layer?.cornerRadius = 16; hud.translatesAutoresizingMaskIntoConstraints = false
        let label = textLabel("Режим игры · Esc — закончить", size: 12, weight: .medium)
        label.identifier = NSUserInterfaceItemIdentifier("gameHint")
        let choices = availableTools
        hudTools = choices
        let tools = ActionSegment(labels: choices.map(\.title), selected: choices.firstIndex(of: currentTool) ?? 0) { [weak self, weak overlay] index in
            guard choices.indices.contains(index) else { return }
            let tool = choices[index]
            self?.currentTool = tool; overlay?.scene.cancelInteraction(); overlay?.scene.tool = tool
        }
        tools.identifier = NSUserInterfaceItemIdentifier("gameTools")
        tools.setAccessibilityLabel("Инструмент игры")
        let close = ActionButton("Закончить", symbol: "xmark") { [weak self] in self?.endGame() }
        let row = horizontalStack([tools, close])
        let scatter = ActionButton("Расставить ёлочки и снеговиков", symbol: "shuffle") { [weak self, weak overlay] in
            guard let self, let overlay, self.playingDisplay == overlay.id else { return }
            overlay.scene.cancelInteraction()
            var generator = SystemRandomNumberGenerator()
            let result = self.festiveWorld.scatter(in: overlay.window.frame, snow: self.world, using: &generator)
            if !self.settings.decorations.christmasTrees {
                self.settings.decorations.christmasTrees = true
                self.changedSettings()
            }
            let message = result.trees + result.snowmen == 0 ? "Нет свободного места или достигнут лимит"
                : "Добавлено ёлочек: \(result.trees), снеговиков: \(result.snowmen)"
            self.showGameHint(message)
        }
        scatter.identifier = NSUserInterfaceItemIdentifier("scatterDecorations")
        guard let host = overlay.window.contentView else { return }
        let stack = verticalStack([label, row, scatter], spacing: 8); hud.addSubview(stack); host.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            hud.topAnchor.constraint(equalTo: host.topAnchor, constant: 54),
            stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: hud.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -12)
        ])
        overlay.hud = hud
    }

    var availableTools: [SnowTool] { SnowTool.allCases.filter { $0 != .tree || settings.decorations.christmasTrees } }

    private func showGameHint(_ text: String) {
        guard let id = playingDisplay, let hud = overlays[id]?.hud else { return }
        func find(_ view: NSView) -> NSTextField? {
            if view.identifier?.rawValue == "gameHint" { return view as? NSTextField }
            return view.subviews.compactMap(find).first
        }
        find(hud)?.stringValue = text + " · Esc — закончить"
    }

    private func showWelcome() {
        endGame(restoreFocus: false)
        popover.performClose(nil)
        if let welcome { welcome.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Добро пожаловать в «Подоконник»"; window.isReleasedWhenClosed = false
        let view = NSVisualEffectView(); view.material = .windowBackground; view.state = .active
        let title = textLabel("Пусть идёт снег", size: 30, weight: .semibold)
        let intro = textLabel("Снег живёт поверх рабочего стола. В обычном режиме клики проходят в ваши приложения.", size: 15)
        let game = textLabel("Хотите поиграть? Выберите «Играть со снегом» в строке меню. Варежка смахивает снег, лопата очищает опору, снежок собирает шар. Выход — Esc.", size: 13, secondary: true)
        let privacy = textLabel("«Универсальный доступ» помогает учитывать положение окон и Dock. Приложение не читает содержимое окон и не записывает экран. Для обновлений оно подключается к GitHub; это можно отключить в настройках.", size: 13, secondary: true)
        let allow = ActionButton("Открыть настройки доступа", symbol: "lock.open") {
            DesktopEnvironment.requestAccessibility()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        let later = ActionButton("Начать снегопад", symbol: "snowflake") { [weak self, weak window] in
            self?.settings.onboardingComplete = true; self?.changedSettings(); window?.orderOut(nil)
        }
        let stack = verticalStack([title, intro, game, privacy, allow, later], spacing: 16)
        view.addSubview(stack); window.contentView = view
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
        welcome = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func beginSmokeTest() {
        guard let seconds = smokeSeconds else { return }
        print("SNEZHNO_SMOKE_START screens=\(overlays.count) AX=\(DesktopEnvironment.accessibilityTrusted())")
        fflush(stdout)
        metricStart = ProcessSample.current(); metricPrevious = metricStart
        metricTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordMetrics() }
        smokeTimer = Timer.scheduledTimer(withTimeInterval: max(3, seconds), repeats: false) { [weak self] _ in self?.finishSmokeTest() }
    }

    private func recordMetrics() {
        let now = ProcessSample.current()
        guard let start = metricStart, let previous = metricPrevious else { return }
        let elapsed = now.uptime - previous.uptime
        let cpu = elapsed > 0 ? (now.cpuSeconds - previous.cpuSeconds) / elapsed * 100 : 0
        performanceSamples.append(["elapsed": now.uptime-start.uptime, "cpuPercentOneCore": cpu,
                                   "physicalBytes": now.physicalBytes, "updates": frameIntervals.count,
                                   "balls": world.balls.count,
                                   "stage": smokeStage,
                                   "overlayCount": overlays.count,
                                   "observerCount": monitors.count,
                                   "nodes": overlays.values.reduce(0) { $0 + $1.scene.renderingStatistics.nodes }])
        metricPrevious = now
        if CommandLine.arguments.contains("--smoke-soak"), CommandLine.arguments.contains("--settings-path") {
            let stage = Int((now.uptime - start.uptime) / 60) % 5
            if stage != smokeStage {
                smokeStage = stage
                settings.paused = stage == 3
                settings.economy = stage == 1
                settings.intensity = stage == 2 ? .blizzard : .steady
                refreshPolicy()
                if stage == 2 { seedStressScene() }
                print("SNEZHNO_SOAK_STAGE \(stage) elapsed=\(now.uptime-start.uptime)")
                fflush(stdout)
            }
        }
        if !stressSeeded && now.uptime-start.uptime >= 3 && CommandLine.arguments.contains("--smoke-stress") {
            seedStressScene()
        }
        // Persist a live checkpoint for long runs. No window content or identities.
        if let directory = evidenceDirectory, performanceSamples.count % 10 == 0 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: performanceSamples, options: [.sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("performance.json"), options: .atomic)
            }
        }
    }

    /// Benchmark-only setup through the same public simulation commands as the
    /// game. No synthetic input, private APIs or changes to another application.
    private func seedStressScene() {
        guard !world.surfaces.isEmpty else { return }
        stressSeeded = true
        let regions = overlays.values.filter { !$0.isPaused }.map { $0.window.frame }
        for _ in 0..<500 { world.step(delta: 0.1, weather: weather, activeRegions: regions) }
        for surface in world.surfaces where surface.isVisible {
            for x in stride(from: surface.frame.minX+40, to: surface.frame.maxX-20, by: 64) {
                guard world.balls.count < 30, let drift = world.drifts[surface.id], !drift.heights.isEmpty else { continue }
                let index = min(drift.heights.count-1, max(0, Int((x-surface.frame.minX)/SnowDrift.spacing)))
                let point = CGPoint(x: x, y: surface.top+drift.heights[index])
                if world.beginSnowball(at: point) != nil { world.endDrag() }
            }
        }
        print("SNEZHNO_STRESS_SEEDED balls=\(world.balls.count)"); fflush(stdout)
    }

    private func finishSmokeTest() {
        metricTimer?.invalidate(); recordMetrics()
        let sorted = frameIntervals.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(Double(sorted.count-1)*p))]*1000 }
        let presented = overlays.values.flatMap { $0.particles?.presentationIntervals ?? [] }.sorted()
        func presentedPercentile(_ p: Double) -> Double {
            presented.isEmpty ? 0 : presented[min(presented.count-1, Int(Double(presented.count-1)*p))]*1000
        }
        var report: [String: Any] = ["build": buildInfo, "screens": overlays.count, "frames": frameIntervals.count,
            "particleRenderers": overlays.values.map { $0.particles == nil ? "SpriteKit" : "Metal + SKRenderer" },
            "particleSimulationBackends": overlays.values.map { $0.scene.particleSimulationBackend },
            "presentationMetricsEnabled": overlays.values.contains { $0.particles?.recordsPresentation == true },
            "soakTransitionsEnabled": CommandLine.arguments.contains("--smoke-soak") && CommandLine.arguments.contains("--settings-path"),
            "presentedParticleFrames": presented.count,
            "p95PresentedParticleIntervalMs": presentedPercentile(0.95),
            "p99PresentedParticleIntervalMs": presentedPercentile(0.99),
            "p95UpdateIntervalMs": percentile(0.95), "p99UpdateIntervalMs": percentile(0.99), "axTrusted": DesktopEnvironment.accessibilityTrusted(),
            "windowCount": snapshot?.windowCount ?? 0, "dockDetected": snapshot?.dockDetected ?? false,
            "geometryMs": snapshot?.captureMilliseconds ?? 0,
            "drifts": world.drifts.count, "balls": world.balls.count,
            "passThrough": overlays.values.allSatisfy { $0.window.ignoresMouseEvents },
            "targetFPS": overlays.values.map { $0.frameLimiter.pacer.rate },
            "displayMaximumFPS": overlays.values.map { $0.maximumFPS },
            "displaySizes": NSScreen.screens.map { ["widthPoints": $0.frame.width,
                                                      "heightPoints": $0.frame.height,
                                                      "backingScale": $0.backingScaleFactor] },
            "particles": overlays.values.map { $0.scene.renderingStatistics.particles },
            "nodes": overlays.values.map { $0.scene.renderingStatistics.nodes },
            "overlayVisible": overlays.values.map { $0.window.isVisible },
            "overlayUnoccluded": overlays.values.map { $0.window.occlusionState.contains(.visible) },
            "renderingPaused": overlays.values.map { $0.isPaused },
            "scenePaused": overlays.values.map { $0.scene.isPaused },
            "renderingFailures": overlays.values.compactMap { $0.renderingFailure },
            "applicationActive": NSApp.isActive,
            "architecture": "arm64", "os": ProcessInfo.processInfo.operatingSystemVersionString]
        if let evidenceDirectory {
            try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: performanceSamples, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: evidenceDirectory.appendingPathComponent("performance.json"), options: .atomic)
            }
            report["previews"] = PreviewExporter.export(to: evidenceDirectory)
            report["controlsPreview"] = exportControls(to: evidenceDirectory)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: evidenceDirectory.appendingPathComponent("smoke.json"), options: .atomic)
            }
        }
        print("SNEZHNO_SMOKE_RESULT \(report)"); fflush(stdout)
        NSApp.terminate(nil)
    }

    /// Exports our own control view, never a screen/window image from another process.
    private func exportControls(to directory: URL) -> Bool {
        guard let view = popover.contentViewController?.view else { return false }
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(origin: .zero, size: popover.contentSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: directory.appendingPathComponent("controls.png")); return true }
        catch { return false }
    }
}
