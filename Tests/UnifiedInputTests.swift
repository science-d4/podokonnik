import AppKit

private struct InputFailure: Error, CustomStringConvertible { let description: String }

@MainActor
private final class UnifiedInputChecks {
    private var checks = 0
    private var eventNumber = 0
    private var eventTime = ProcessInfo.processInfo.systemUptime
    private(set) var lines: [String] = []

    func log(_ text: String) { lines.append(text); print(text); fflush(stdout) }
    private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw InputFailure(description: message) }
        checks += 1
    }
    private func action(_ control: NSControl?) throws {
        guard let control, let selector = control.action,
              NSApp.sendAction(selector, to: control.target, from: control) else {
            throw InputFailure(description: "Own control target/action is unavailable")
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func wait(_ condition: () -> Bool, seconds: Double = 3) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
    }

    private func send(_ type: NSEvent.EventType, world point: CGPoint, overlay: DisplayOverlay,
                      delay: TimeInterval = 1.0 / 60) throws {
        eventTime += delay; eventNumber += 1
        let local = CGPoint(x: point.x - overlay.scene.displayFrame.minX, y: point.y - overlay.scene.displayFrame.minY)
        let location = overlay.view.convert(local, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: eventTime, windowNumber: overlay.window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            throw InputFailure(description: "Cannot construct a local own-window mouse event")
        }
        // Real NSWindow dispatch, never global input or direct pointer/mouse API calls.
        overlay.window.sendEvent(event)
    }

    func run() async throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else {
            throw InputFailure(description: "GUI test requires the existing pointer on a display; pointer was not moved")
        }
        let controller = ApplicationController()
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp))
        defer {
            controller.endGame()
            controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: NSApp))
            if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        guard let overlay = controller.overlays[displayID], overlay.particles != nil else {
            throw InputFailure(description: "Expected production UnifiedSnowView on the selected display")
        }
        let region = screen.frame
        let support = SnowSurface(id: "own-input-roof", frame: CGRect(x: region.minX + 80, y: region.minY + 180,
            width: min(900, region.width - 160), height: 120), kind: .window, topInset: 16)
        try action(controller.pauseControl)
        controller.desktop.onSnapshot?(DesktopSnapshot(generation: 90_001, surfaces: [support], fullscreenDisplayIDs: [],
            accessibilityTrusted: false, dockDetected: false, windowCount: 1, captureMilliseconds: 0))
        controller.desktop.onSnapshot = nil
        controller.desktop.stop()
        await wait { !overlay.isPaused }
        try check(!overlay.isPaused && overlay.window.isVisible, "own unified overlay must render before input")
        try check(overlay.window.level.rawValue < Int(CGWindowLevelForKey(.dockWindow)),
                  "native Dock must composite above the passive snow overlay")
        try action(controller.gameControl)
        await wait { NSApp.isActive && overlay.window.isKeyWindow }
        try check(controller.playingDisplay == displayID && overlay.scene.playing && !overlay.window.ignoresMouseEvents,
                  "actual game action must enable production window input")
        try check(overlay.window.level.rawValue < Int(CGWindowLevelForKey(.dockWindow)),
                  "entering the game must preserve native Dock compositing order")
        guard let hud = overlay.hud, let tools = descendants(hud).compactMap({ $0 as? ActionSegment }).first else {
            throw InputFailure(description: "Actual game HUD tool selector is missing")
        }
        tools.selectedSegment = SnowTool.snowball.rawValue
        try action(tools)
        try check(controller.currentTool == .snowball && overlay.scene.tool == .snowball,
                  "actual HUD target/action must select Snowball")
        overlay.view.layoutSubtreeIfNeeded()
        let hudPoint = hud.convert(CGPoint(x: hud.bounds.midX, y: hud.bounds.midY), to: overlay.view)
        let hudHit = overlay.view.hitTest(hudPoint)
        try check(hudHit === hud || hudHit?.isDescendant(of: hud) == true, "HUD must remain hittable above game surface")

        controller.world.syncSurfaces([support]); controller.world.prune(to: [region])
        let weather = SnowWeather(intensity: .blizzard)
        for _ in 0..<350 { controller.world.step(delta: 0.1, weather: weather, activeRegions: [region]) }
        controller.world.syncSurfaces([support])
        let start = CGPoint(x: support.frame.minX + 120, y: support.top + 5)
        let localStart = CGPoint(x: start.x - region.minX, y: start.y - region.minY)
        try check(overlay.view.hitTest(localStart) === overlay.view, "snow support must hit unified surface outside HUD")
        try send(.leftMouseDown, world: start, overlay: overlay)
        try check(controller.world.balls.count == 1, "NSWindow mouseDown must create a ball through actual view")
        let ballID = controller.world.balls[0].id
        let before = controller.world.balls[0].position
        try send(.leftMouseDragged, world: CGPoint(x: start.x + 50, y: start.y), overlay: overlay)
        try check(abs(controller.world.balls[0].position.x - before.x - 50) < 0.01,
                  "NSWindow dragged must preserve point coordinates and move held ball horizontally")
        try send(.leftMouseUp, world: CGPoint(x: start.x + 50, y: start.y), overlay: overlay, delay: 0.2)
        let released = controller.world.balls[0].position
        let empty = CGPoint(x: start.x + 220, y: support.top + 200)
        try send(.leftMouseDown, world: empty, overlay: overlay)
        try send(.leftMouseDragged, world: CGPoint(x: empty.x + 20, y: empty.y + 20), overlay: overlay)
        try send(.leftMouseUp, world: empty, overlay: overlay, delay: 0.2)
        try check(controller.world.balls[0].position == released, "mouseUp must release previous ball before an empty-space gesture")
        log("PASS actual mouse route: HUD selection, own NSWindow down/drag/up, x coordinates and release")

        try send(.leftMouseDown, world: released, overlay: overlay)
        try check(controller.world.balls.count == 1 && controller.world.balls[0].id == ballID,
                  "mouseDown on existing ball must pick it up rather than create another")
        for step in 1...18 {
            try send(.leftMouseDragged, world: CGPoint(x: released.x, y: released.y + CGFloat(step * 2)), overlay: overlay)
        }
        let lifted = controller.world.balls[0]
        log("Lift via NSWindow: pointerDeltaY=36 ballDeltaY=\(lifted.position.y - released.y) attached=\(lifted.surfaceID != nil)")
        try check(lifted.position.y >= released.y + 30 && lifted.surfaceID == nil,
                  "small real drag events must lift existing ball clear of its support")
        try send(.leftMouseUp, world: lifted.position, overlay: overlay, delay: 0.2)
        for _ in 0..<30 { controller.world.step(delta: 0.1, weather: weather, activeRegions: [region]) }
        log("PASS existing ball: AppKit events pick up and lift through 18 small pointer steps")

        // All manipulation still uses NSWindow; stepping only settles this fixture.
        for offset in [CGFloat(350), CGFloat(550)] {
            let point = CGPoint(x: support.frame.minX + offset, y: support.top + 5)
            try send(.leftMouseDown, world: point, overlay: overlay)
            try send(.leftMouseUp, world: point, overlay: overlay, delay: 0.2)
        }
        try check(controller.world.balls.count == 3, "own mouse events must create three stack components")
        for index in 1...2 {
            let top = controller.world.balls[index], lower = controller.world.balls[index - 1]
            try send(.leftMouseDown, world: top.position, overlay: overlay)
            let destination = CGPoint(x: lower.position.x, y: lower.position.y + lower.radius + top.radius + 1)
            try send(.leftMouseDragged, world: CGPoint(x: top.position.x, y: destination.y + 50), overlay: overlay)
            try send(.leftMouseDragged, world: destination, overlay: overlay)
            try send(.leftMouseUp, world: destination, overlay: overlay, delay: 0.2)
            for _ in 0..<30 { controller.world.step(delta: 0.1, weather: weather, activeRegions: [region]) }
        }
        try check(controller.world.snowmen.contains { Set($0.ballIDs) == Set(controller.world.balls.map(\.id)) },
                  "components moved via NSWindow events must form a stable snowman")
        log("PASS snowman: actual down/drag/up gestures stack three components")

        let playerBalls = Set(controller.world.balls.map(\.id))
        let floor = SnowSurface(id: "own-input-floor", frame: CGRect(x: support.frame.minX,
            y: region.minY - 1, width: support.frame.width, height: 1), kind: .floor)
        controller.world.syncSurfaces([support, floor])
        for _ in 0..<150 { controller.world.step(delta: 0.1, weather: weather, activeRegions: [region]) }
        controller.world.syncSurfaces([support, floor])
        guard let beforeSweep = controller.world.drifts[floor.id]?.heights, beforeSweep.count > 5,
              let driverID = controller.driverID, let driver = controller.overlays[driverID],
              let frame = driver.scene.onFrame else {
            throw InputFailure(description: "Floor fixture or production frame driver is unavailable")
        }
        let left = 2, right = beforeSweep.count - 3
        try check(beforeSweep[left] > 2 && beforeSweep[right] > 2,
                  "plow wiring fixture must have accumulated snow on both sides of the floor")
        try check(controller.plowNowControl?.isEnabled == true, "actual plow-now control must be enabled")
        try action(controller.plowNowControl)
        let origin = max(controller.lastFrame, ProcessInfo.processInfo.systemUptime)
        controller.lastFrame = origin
        frame(origin + 1.0 / 60)
        try check(controller.snowplowSchedule.passes.count == 1
                  && controller.snowplowSchedule.passes[floor.id] != nil
                  && overlay.scene.snowplowPasses[floor.id] != nil,
                  "real button and driver callback must start one floor pass and publish it to the scene")
        let leftX = floor.frame.minX + CGFloat(left) * SnowDrift.spacing
        var heightImmediatelyAfterSweep: CGFloat?
        for tick in 2...60 {
            let previousBucket = controller.snowplowSchedule.passes[floor.id]?.bucketX
            frame(origin + Double(tick) / 60)
            if let previousBucket, let bucket = controller.snowplowSchedule.passes[floor.id]?.bucketX,
               previousBucket <= leftX && bucket >= leftX {
                heightImmediatelyAfterSweep = controller.world.drifts[floor.id]?.heights[left]
            }
        }
        guard let afterSweep = controller.world.drifts[floor.id]?.heights else {
            throw InputFailure(description: "Swept floor disappeared")
        }
        let pass = controller.snowplowSchedule.passes[floor.id]
        log("Plow diagnostic: floorMinX=\(floor.frame.minX) leftX=\(leftX) beforeLeft=\(beforeSweep[left]) immediatelyAfter=\(heightImmediatelyAfterSweep ?? -1) afterLeft=\(afterSweep[left]) beforeRight=\(beforeSweep[right]) afterRight=\(afterSweep[right]) bucketX=\(pass?.bucketX ?? -1) travelled=\(pass?.travelled ?? -1) reducedMotion=\(controller.weather.reducedMotion) lastFrameDelta=\(controller.lastFrame - origin) balls=\(controller.world.balls.count)")
        // Both the first contact and the live trail must stay clear for this pass.
        try check(heightImmediatelyAfterSweep.map { abs($0) < 0.000001 } == true
                  && abs(afterSweep[left]) < 0.000001,
                  "production sweep must keep the entire crossed lane clear while the tractor is driving")
        try check(afterSweep[right] >= beforeSweep[right] * 0.9 && afterSweep[right] > afterSweep[left] + 2,
                  "snow ahead of the plow must remain")
        try check(controller.world.balls.count == 3 && Set(controller.world.balls.map(\.id)) == playerBalls,
                  "manual floor cleaning must preserve all three player-created balls")
        log("PASS plow wiring: actual button → driver onFrame → schedule → floor sweep → scene pass; left=\(beforeSweep[left])→\(afterSweep[left]), right=\(afterSweep[right]), all3balls preserved")

        guard let speedSlider = controller.plowSpeedSlider, let initialPass = pass else {
            throw InputFailure(description: "Actual tractor speed slider or active pass is missing")
        }
        let baseSpeed: CGFloat = controller.weather.reducedMotion ? 90 : 160
        try check(speedSlider.minValue == 0.5 && speedSlider.maxValue == 2
                  && speedSlider.doubleValue == 1.25 && speedSlider.accessibilityLabel() == "Скорость трактора",
                  "actual slider must expose its saved default, 0.5–2 range and accessible name")
        guard let speedValue = controller.plowSpeedLabel, let controls = controller.popover.contentViewController?.view else {
            throw InputFailure(description: "Tractor speed value is missing from controls")
        }
        controls.layoutSubtreeIfNeeded()
        speedSlider.scrollToVisible(speedSlider.bounds)
        controls.layoutSubtreeIfNeeded()
        let valueFrame = speedValue.convert(speedValue.bounds, to: controls)
        try check(valueFrame.width >= 48 && valueFrame.height >= 12 && controls.bounds.contains(valueFrame),
                  "the speed value must have visible space inside the actual settings panel")
        try check(abs(initialPass.travelled - baseSpeed * 1.25) < 1e-4,
                  "the production driver must apply default 1.25 speed throughout its first second")
        speedSlider.doubleValue = 0.5
        try action(speedSlider)
        try check(controller.settings.plowSpeedMultiplier == 0.5
                  && controller.plowSpeedLabel?.stringValue == "0.50×"
                  && controller.snowplowSchedule.passes[floor.id]?.x == initialPass.x,
                  "real slider action updates visible value without restarting the active pass")
        frame(origin + 1.05)
        guard let slower = controller.snowplowSchedule.passes[floor.id] else {
            throw InputFailure(description: "Changing tractor speed unexpectedly ended the pass")
        }
        try check(abs(slower.x - initialPass.x - baseSpeed * 0.5 * 0.05) < 1e-4,
                  "actual driver uses the slower slider value on the next update")
        speedSlider.doubleValue = 2
        try action(speedSlider)
        try check(controller.settings.plowSpeedMultiplier == 2
                  && controller.plowSpeedLabel?.stringValue == "2.00×"
                  && controller.snowplowSchedule.passes[floor.id]?.x == slower.x,
                  "maximum slider speed preserves position until the next update")
        frame(origin + 1.10)
        try check(abs((controller.snowplowSchedule.passes[floor.id]?.x ?? 0) - slower.x - baseSpeed * 2 * 0.05) < 1e-4,
                  "actual driver immediately applies the maximum slider speed")
        try check(abs(controller.world.drifts[floor.id]!.heights[left]) < 1e-8,
                  "changing slider speed mid-pass keeps the crossed floor clear")
        await wait { SettingsStore(url: controller.store.url).load().plowSpeedMultiplier == 2 }
        try check(SettingsStore(url: controller.store.url).load().plowSpeedMultiplier == 2,
                  "actual changedSettings debounce persists the slider value")
        log("PASS tractor speed: actual slider target/action → immediate distance change → cumulative cleaning → persisted 2.00×")
        controller.settings.decorations.christmasTrees = true
        controller.changedSettings()
        controller.festiveWorld.syncSurfaces(controller.world.surfaces)
        guard let treeHUD = overlay.hud,
              let treeTools = descendants(treeHUD).compactMap({ $0 as? ActionSegment }).first,
              let treeIndex = (0..<treeTools.segmentCount).first(where: { treeTools.label(forSegment: $0) == "Ёлочка" }) else {
            throw InputFailure(description: "Enabled trees must appear in the real game HUD")
        }
        treeTools.selectedSegment = treeIndex
        try action(treeTools)
        try check(overlay.scene.tool == .tree && controller.currentTool == .tree, "filtered HUD index selects the tree tool")
        let planting = CGPoint(x: support.frame.minX + 350, y: support.top + 40)
        try send(.leftMouseDown, world: planting, overlay: overlay)
        try send(.leftMouseUp, world: planting, overlay: overlay)
        guard let tree = controller.festiveWorld.placements(in: controller.world).first else {
            throw InputFailure(description: "Own-window click must plant a Christmas tree")
        }
        try check(tree.surface.id == support.id, "tree attaches to the selected window")
        let branch = CGPoint(x: tree.base.x + 10, y: tree.base.y + tree.height * 0.5)
        try send(.leftMouseDown, world: branch, overlay: overlay)
        let movedPointer = CGPoint(x: branch.x + 60, y: branch.y)
        try send(.leftMouseDragged, world: movedPointer, overlay: overlay)
        try send(.leftMouseUp, world: movedPointer, overlay: overlay)
        guard let movedTree = controller.festiveWorld.placements(in: controller.world).first else {
            throw InputFailure(description: "Tree must survive drag")
        }
        try check(movedTree.id == tree.id && abs(movedTree.base.x - tree.base.x - 60) < 0.01,
                  "drag preserves the tree and pointer offset without a jump")
        let grabbed = CGPoint(x: movedTree.base.x, y: movedTree.base.y + 30)
        try send(.leftMouseDown, world: grabbed, overlay: overlay)
        controller.settings.decorations.christmasTrees = false
        controller.changedSettings()
        try check(overlay.scene.tool == .mitten && controller.currentTool == .mitten,
                  "disabling trees resets the selected tool and cancels its drag")
        try send(.leftMouseDragged, world: CGPoint(x: grabbed.x + 50, y: grabbed.y), overlay: overlay)
        try send(.leftMouseUp, world: grabbed, overlay: overlay)
        try check(controller.festiveWorld.placements(in: controller.world).first?.base == movedTree.base,
                  "disabled tree cannot move through an old drag gesture")
        controller.settings.decorations.christmasTrees = true
        controller.changedSettings()
        guard let eraseHUD = overlay.hud,
              let eraseTools = descendants(eraseHUD).compactMap({ $0 as? ActionSegment }).first,
              let shovelIndex = (0..<eraseTools.segmentCount).first(where: { eraseTools.label(forSegment: $0) == "Лопата" }) else {
            throw InputFailure(description: "Shovel must remain available after restoring trees")
        }
        eraseTools.selectedSegment = shovelIndex
        try action(eraseTools)
        let snowBeforeErase = controller.world.drifts[support.id]!.heights
        try send(.leftMouseDown, world: grabbed, overlay: overlay)
        try send(.leftMouseUp, world: grabbed, overlay: overlay)
        try check(controller.festiveWorld.placements(in: controller.world).isEmpty
                  && controller.world.drifts[support.id]!.heights == snowBeforeErase,
                  "shovel removes the hit tree without clearing its whole roof")
        log("PASS trees: actual HUD and NSWindow plant/drag/remove, pointer offset, disable-cancel and restore")
        log("PASS: \(checks) own-window input checks; no global input, pointer movement, TCC or system settings")
    }
}

@main
@MainActor
private struct UnifiedInputTestsMain {
    static func main() {
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let settings = argument("--settings-path"), let evidence = argument("--input-evidence") else { exit(2) }
        var initial = AppSettings(); initial.paused = true; initial.onboardingComplete = true
        SettingsStore(url: URL(fileURLWithPath: settings)).save(initial)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let checks = UnifiedInputChecks()
        _ = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in
            fputs("FAIL: own-window input test timed out\n", stderr); exit(3)
        }
        Task { @MainActor in
            var success = false
            do { try await checks.run(); success = true }
            catch { checks.log("FAIL: \(error)") }
            let url = URL(fileURLWithPath: evidence)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? checks.lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            exit(success ? 0 : 1)
        }
        NSApp.run()
    }
}
