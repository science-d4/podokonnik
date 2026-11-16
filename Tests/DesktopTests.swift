import AppKit

private final class TestWindowMetadata {
    private let lock = NSLock()
    private var records: [[String: Any]]?

    init(_ records: [[String: Any]]?) { self.records = records }
    func set(_ records: [[String: Any]]?) { lock.lock(); self.records = records; lock.unlock() }
    func read() -> [[String: Any]]? { lock.lock(); defer { lock.unlock() }; return records }
}

private final class StalledWindowMetadata {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var shouldBlock = false
    private var active = 0
    private var mostActive = 0
    private var blocked = false
    private var returnNil = false
    private var reads = 0
    private var delayedNil: TimeInterval?

    func blockNext(returningNil: Bool = false) {
        lock.lock(); shouldBlock = true; blocked = false; returnNil = returningNil; lock.unlock()
    }
    func delayNextNil(_ delay: TimeInterval) { lock.lock(); delayedNil = delay; lock.unlock() }
    func unblock() { lock.lock(); shouldBlock = false; returnNil = false; lock.unlock(); release.signal() }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    var maximumConcurrentReads: Int { lock.lock(); defer { lock.unlock() }; return mostActive }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    func read() -> [[String: Any]]? {
        lock.lock()
        active += 1
        reads += 1
        mostActive = max(mostActive, active)
        let wait = shouldBlock
        let delay = delayedNil
        delayedNil = nil
        let returnsNil = returnNil || delay != nil
        if wait { blocked = true }
        lock.unlock()
        if wait { _ = release.wait(timeout: .now() + 5) }
        if let delay { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); active -= 1; lock.unlock()
        return returnsNil ? nil : []
    }
}

/// Compile separately with SnowTypes.swift and DesktopEnvironment.swift.
/// Geometry tests are pure. Lifecycle checks read metadata but never request TCC,
/// change other applications or require a WindowServer-backed screen to exist.
@main
struct DesktopTests {
    private static var checks = 0

    static func main() {
        geometry()
        ceilingSupports()
        wideWindowPolicy()
        spotlightFocus()
        spotlightCapture()
        dockSupports()
        dockContact()
        cursorOcclusion()
        nativeMenuAndScreenshotGeometry()
        missionControlGeometry()
        missionControlCapture()
        hiddenWindowSupports()
        applicationMetadataCache()
        captureTiming()
        captureWatchdogTiming()
        dockGeometryCache()
        notificationOcclusion()
        notificationGeometryCache()
        failedWindowMetadata()
        stalledWindowMetadata()
        captureCompletesBeforeTimerHandler()
        lifecycle()
        print("DesktopTests: \(checks) checks passed")
    }

    private static func wideWindowPolicy() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let short = CGRect(x: 0, y: 250, width: 1440, height: 200)
        expect(WideWindowPolicy.mask(forWindow: short, display: display) == short,
               "a full-width ordinary window suppresses only its own short rectangle")
        expect(!DesktopGeometry.coversDisplay(short, display), "wide does not imply fullscreen")
        let tolerance = CGRect(x: 2, y: 0, width: 1436, height: 876)
        expect(WideWindowPolicy.mask(forWindow: tolerance, display: display) == tolerance,
               "both window edges may be inset by at most two points")
        expect(WideWindowPolicy.mask(forWindow: tolerance.insetBy(dx: 0.1, dy: 0), display: display) == nil,
               "shrinking beyond the tolerance restores snowfall")
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let spanning = CGRect(x: -20, y: -100, width: 1720, height: 1100)
        expect(WideWindowPolicy.mask(forWindow: spanning, display: display) == display
               && WideWindowPolicy.mask(forWindow: spanning, display: other) == nil,
               "a spanning window suppresses only the display whose full width it covers")
        let negative = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let negativeWindow = CGRect(x: -1440, y: -1100, width: 1440, height: 1000)
        let negativeMask = WideWindowPolicy.mask(forWindow: negativeWindow, display: negative)
        expect(negativeMask == CGRect(x: -1440, y: -900, width: 1440, height: 800),
               "negative-origin masks use world coordinates and clip to their own display")
        expect(negativeMask?.intersects(display) == false,
               "a lower display mask cannot bleed into a vertically adjacent display")
        expect(WideWindowPolicy.mask(forWindow: CGRect(x: CGFloat.nan, y: 0, width: 1440, height: 50), display: display) == nil,
               "invalid geometry produces no snowfall mask")

        var window = SnowSurface(id: "wide", frame: short, kind: .window)
        expect(WideWindowPolicy.snowfallMasks(surfaces: [window], display: display).isEmpty,
               "inactive wide windows do not suppress snowfall")
        window.suppressesSnowfall = true
        expect(WideWindowPolicy.snowfallMasks(surfaces: [window], display: display) == [short],
               "the active visible wide ordinary window suppresses snowfall")
        window.isVisible = false
        expect(WideWindowPolicy.snowfallMasks(surfaces: [window], display: display).isEmpty,
               "a hidden window stops suppressing snowfall immediately")
        window.isVisible = true; window.kind = .dock
        expect(WideWindowPolicy.snowfallMasks(surfaces: [window], display: display).isEmpty,
               "Dock and floor never activate the wide-window snowfall rule")
        expect(WideWindowPolicy.snowfallMasks(surfaces: [], display: display).isEmpty,
               "removing a wide window leaves no stale mask")

        let low = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let floorMask = WideWindowPolicy.floorOccluder(low, ordinaryWindow: true, display: display)
        expect(floorMask == CGRect(x: 0, y: 30, width: 1440, height: 846),
               "a wide window leaves maximum floor height plus two points exposed")
        expect(WideWindowPolicy.floorOccluder(low, ordinaryWindow: false, display: display) == low,
               "a full-width panel keeps its original floor mask")
        let narrow = CGRect(x: 80, y: 0, width: 900, height: 876)
        expect(WideWindowPolicy.floorOccluder(narrow, ordinaryWindow: true, display: display) == narrow,
               "other ordinary windows still occlude the floor")
        expect(WideWindowPolicy.floorOccluder(short, ordinaryWindow: true, display: display) == short,
               "a wide window above the floor band retains its entire mask")
        let negativeFloorMask = WideWindowPolicy.floorOccluder(negativeWindow, ordinaryWindow: true, display: negative)
        expect(negativeFloorMask?.minY == -870, "the floor exemption follows a negative display origin")

        expect(WideWindowPolicy.hidesParticle(center: CGPoint(x: 500, y: 454), side: 8, rotation: .pi / 4, masks: [short]),
               "a rotated quad corner entering the window hides the entire flake")
        expect(!WideWindowPolicy.hidesParticle(center: CGPoint(x: 500, y: 458), side: 8, rotation: .pi / 4, masks: [short]),
               "a complete quad outside the window remains visible")

        let order: [(id: UInt32, pid: pid_t)] = [(10, 100), (20, 200), (11, 100)]
        expect(DesktopGeometry.activeWindowID(ordered: order, frontmostPID: 100) == 10,
               "frontmost app selects its topmost eligible window")
        expect(DesktopGeometry.activeWindowID(ordered: order, frontmostPID: 200) == 20,
               "activating another application changes the selected window")
        expect(DesktopGeometry.activeWindowID(ordered: [(11, 100), (10, 100), (20, 200)], frontmostPID: 100) == 11,
               "switching windows of the same application follows the new public Z-order")
        expect(DesktopGeometry.activeWindowID(ordered: order, frontmostPID: 300) == nil
               && DesktopGeometry.activeWindowID(ordered: order, frontmostPID: nil) == nil,
               "missing active normal window never leaves a stale suppression ID")
    }

    private static func spotlightFocus() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 0, y: 100, width: 1440, height: 700)
        var first = SnowSurface(id: "window:100:10", frame: frame, kind: .window)
        var second = SnowSurface(id: "window:200:20", frame: frame, kind: .window)
        var policy = DesktopFocusPolicy()
        var surfaces = [first, second]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "com.apple.Spotlight")
        expect(WideWindowPolicy.snowfallMasks(surfaces: surfaces, display: display).isEmpty,
               "starting in Spotlight must not invent an active window")

        first.suppressesSnowfall = true
        surfaces = [first, second]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "example.first")
        expect(WideWindowPolicy.snowfallMasks(surfaces: surfaces, display: display) == [frame],
               "the active wide window initially suppresses snowfall")
        first.suppressesSnowfall = false
        for _ in 0..<3 {
            surfaces = [first, second]
            policy.apply(to: &surfaces, frontmostBundleIdentifier: "com.apple.Spotlight")
            expect(surfaces[0].suppressesSnowfall && !surfaces[1].suppressesSnowfall
                   && WideWindowPolicy.snowfallMasks(surfaces: surfaces, display: display) == [frame],
                   "Spotlight pauses and input retain the same wide-window mask")
        }
        second.suppressesSnowfall = true
        surfaces = [first, second]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "example.second")
        expect(!surfaces[0].suppressesSnowfall && surfaces[1].suppressesSnowfall,
               "another application replaces the retained window")
        second.suppressesSnowfall = false
        surfaces = [first, second]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "com.apple.Spotlight")
        expect(!surfaces[0].suppressesSnowfall && surfaces[1].suppressesSnowfall,
               "Spotlight retains the newly selected window")
        surfaces = [first]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "com.apple.Spotlight")
        surfaces = [first, second]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "com.apple.Spotlight")
        expect(surfaces.allSatisfy { !$0.suppressesSnowfall },
               "a disappeared window is not revived from stale focus")
        first.suppressesSnowfall = true
        surfaces = [first]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "example.first")
        first.suppressesSnowfall = false
        surfaces = [first]
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "example.other")
        policy.apply(to: &surfaces, frontmostBundleIdentifier: "com.apple.Spotlight")
        expect(!surfaces[0].suppressesSnowfall,
               "another app without an eligible window clears the previous selection")
    }

    private static func missionControlGeometry() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let other = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        func detected(_ frame: CGRect, _ layer: Int, _ manager: Bool) -> Bool {
            DesktopGeometry.isMissionControlWindow(frame, layer: layer, windowManager: manager,
                                                   displays: [screen, other])
        }
        expect(detected(screen, dockLevel - 1, true),
               "the full-screen WindowManager canvas identifies Mission Control on macOS 27")
        expect(detected(screen.union(other), dockLevel - 1, true),
               "a canvas covering multiple displays is recognized")
        expect(!detected(screen, dockLevel, false)
               && !detected(screen, dockLevel - 1, false)
               && !detected(screen, dockLevel - 2, true),
               "normal Dock canvases and unrelated owner/layer combinations are ignored")
        expect(!detected(screen.insetBy(dx: 20, dy: 20), dockLevel - 1, true)
               && !detected(screen, dockLevel - 1, false),
               "a smaller panel or another process is not Mission Control")
    }

    private static func missionControlCapture() {
        let display = DesktopDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleTop: 876)
        let manager: pid_t = 987125
        let canvas: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: manager),
            kCGWindowNumber as String: NSNumber(value: 987126),
            kCGWindowBounds as String: display.frame.dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: Int(CGWindowLevelForKey(.dockWindow)) - 1),
            kCGWindowAlpha as String: NSNumber(value: 1)
        ]
        let metadata = TestWindowMetadata([])
        let environment = DesktopEnvironment(windowMetadata: { metadata.read() }, displays: { [display] },
            primaryDisplayTop: { display.frame.maxY }, applicationMetadata: {
                DesktopApplicationMetadata(dockPID: nil, supportPIDs: [], windowManagerPIDs: [manager])
            }, frontmostApplication: { DesktopFrontmostApplication(pid: nil, bundleIdentifier: nil) })
        var snapshots: [DesktopSnapshot] = []
        environment.onSnapshot = { snapshots.append($0) }
        environment.start()
        wait(until: { !snapshots.isEmpty })
        expect(snapshots.last?.missionControlActive == false, "ordinary capture has no Mission Control flag")
        metadata.set([canvas]); environment.refresh()
        wait(until: { snapshots.last?.missionControlActive == true })
        expect(snapshots.last?.missionControlActive == true, "system canvas propagates to the desktop snapshot")
        metadata.set([]); environment.refresh()
        wait(until: { snapshots.last?.missionControlActive == false })
        expect(snapshots.last?.missionControlActive == false, "removing the canvas clears the desktop flag")
        environment.stop()
    }

    private static func spotlightCapture() {
        let display = DesktopDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleTop: 876)
        let pid: pid_t = 987120
        let record: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: 987121),
            kCGWindowBounds as String: CGRect(x: 0, y: 100, width: 1440, height: 700).dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1)
        ]
        let blocker = StalledWindowMetadata()
        var frontmost = DesktopFrontmostApplication(pid: pid, bundleIdentifier: "example.first")
        let environment = DesktopEnvironment(windowMetadata: { _ = blocker.read(); return [record] },
                                             displays: { [display] }, primaryDisplayTop: { display.frame.maxY },
                                             applicationMetadata: { DesktopApplicationMetadata(dockPID: nil, supportPIDs: [pid]) },
                                             frontmostApplication: { frontmost })
        var snapshots: [DesktopSnapshot] = []
        environment.onSnapshot = { snapshots.append($0) }
        environment.start()
        wait(until: { !snapshots.isEmpty })
        expect(snapshots.last?.surfaces.first(where: { $0.kind == .window })?.suppressesSnowfall == true,
               "capture selects the active application's window")

        blocker.blockNext()
        environment.refresh()
        wait(until: { blocker.isBlocked })
        let before = snapshots.count
        frontmost = DesktopFrontmostApplication(pid: 987122, bundleIdentifier: "com.apple.Spotlight")
        blocker.unblock()
        wait(until: { snapshots.count > before })
        expect(snapshots.count > before && blocker.readCount >= 3,
               "a capture started before a focus change is discarded and retried")
        expect(snapshots.dropFirst(before).allSatisfy {
            $0.surfaces.first(where: { $0.kind == .window })?.suppressesSnowfall == true
        }, "delivered Spotlight snapshots retain the previously active wide window")
        frontmost = DesktopFrontmostApplication(pid: 987123, bundleIdentifier: "example.other")
        environment.refresh()
        wait(until: { snapshots.last?.surfaces.first(where: { $0.kind == .window })?.suppressesSnowfall == false })
        expect(snapshots.last?.surfaces.first(where: { $0.kind == .window })?.suppressesSnowfall == false,
               "a different frontmost application clears the retained selection")
        environment.stop()
    }

    private static func ceilingSupports() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maximized = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let ordinary = CGRect(x: 100, y: 100, width: 600, height: 700)
        let maximumMask = DesktopGeometry.ceilingExclusion(for: maximized, display: screen, visibleTop: 876)
        expect(maximumMask != nil, "maximized ordinary window has no upper snow shelf")
        expect(!DesktopGeometry.coversDisplay(maximized, screen), "suppressing the shelf must not classify maximized as fullscreen")
        expect(DesktopGeometry.ceilingExclusion(for: ordinary, display: screen, visibleTop: 876) == nil, "ordinary window with space above keeps its shelf")
        let exactGap = CGRect(x: 100, y: 100, width: 600, height: 742)
        expect(DesktopGeometry.ceilingExclusion(for: exactGap, display: screen, visibleTop: 876) == nil, "34 points of clearance are sufficient")
        let shortGap = exactGap.offsetBy(dx: 0, dy: 0.1)
        expect(DesktopGeometry.ceilingExclusion(for: shortGap, display: screen, visibleTop: 876) != nil, "clearance below 34 points suppresses the shelf")
        expect(maximumMask?.contains(CGRect(x: 2, y: maximized.maxY, width: 72, height: screen.maxY - maximized.maxY)) == true,
               "ceiling mask hides the entire attached silhouette visible on this display")
        let negativeScreen = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let negativeWindow = CGRect(x: -1300, y: -500, width: 900, height: 464)
        let negativeMask = DesktopGeometry.ceilingExclusion(for: negativeWindow, display: negativeScreen, visibleTop: -24)
        expect(negativeMask?.minX == -1440 && negativeMask?.minY == -39,
               "clearance and masks use world coordinates on negative-origin displays")
        let secondScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let spanning = CGRect(x: 1100, y: 400, width: 600, height: 466)
        let firstMask = DesktopGeometry.ceilingExclusion(for: spanning, display: screen, visibleTop: 876)
        let secondMask = DesktopGeometry.ceilingExclusion(for: spanning, display: secondScreen, visibleTop: 1056)
        expect(firstMask != nil && secondMask == nil, "a spanning window suppresses only the display with insufficient clearance")
        expect(firstMask?.contains(CGPoint(x: 1400, y: 880)) == true
               && firstMask?.contains(CGPoint(x: 1500, y: 880)) == false,
               "one display's mask must not hide the adjacent display's shelf")
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        expect(maximumMask?.maxY == screen.maxY && maximumMask?.intersects(above) == false,
               "ceiling mask must not bleed onto a vertically adjacent display")
        expect(DesktopGeometry.ceilingExclusion(for: spanning, display: above, visibleTop: 1776) == nil,
               "a window edge below a vertically stacked display cannot suppress that display")
        let upperWindow = CGRect(x: 100, y: 1000, width: 800, height: 750)
        expect(DesktopGeometry.ceilingExclusion(for: upperWindow, display: screen, visibleTop: 876) == nil,
               "a top edge on an upper display cannot introduce a mask on the lower display")
        expect(DesktopGeometry.windowTopInset(for: ordinary) == 16, "ordinary window support avoids the rounded corners")
        expect(DesktopGeometry.windowTopInset(for: CGRect(x: 0, y: 0, width: 40, height: 100)) == 10,
               "small window inset is bounded by a quarter of its width")
    }

    private static func applicationMetadataCache() {
        var cache = DesktopApplicationCache()
        var reads = 0
        let load = { () -> DesktopApplicationMetadata in
            reads += 1
            return DesktopApplicationMetadata(dockPID: pid_t(reads), supportPIDs: [pid_t(reads * 10)])
        }
        let initial = cache.snapshot(now: 100, load: load)
        expect(reads == 1 && initial.supportPIDs == [10], "application metadata is fetched initially")
        let fastPoll = cache.snapshot(now: 100.035, load: load)
        let idlePoll = cache.snapshot(now: 100.999, load: load)
        expect(reads == 1 && fastPoll.dockPID == 1 && idlePoll.dockPID == 1,
               "fast/150ms geometry polling must reuse application metadata within the TTL")
        let expired = cache.snapshot(now: 101, load: load)
        expect(reads == 2 && expired.supportPIDs == [20], "one-second expiry catches silent activation-policy changes")
        cache.invalidate()
        let changed = cache.snapshot(now: 101.01, load: load)
        expect(reads == 3 && changed.dockPID == 3, "start/invalidate forces a fresh metadata read")
        cache.invalidate()
        cache.invalidate()
        _ = cache.snapshot(now: 101.02, load: load)
        expect(reads == 4, "multiple pending invalidations coalesce into one metadata refresh")

        var events = DesktopApplicationCache()
        var allReads = 0, targetedReads: [pid_t] = []
        var live = DesktopApplicationMetadata(dockPID: 70, supportPIDs: [10, 20], notificationCenterPIDs: [80])
        let loadAll = { () -> DesktopApplicationMetadata in allReads += 1; return live }
        let reconcile = { (pid: pid_t) -> DesktopApplicationMetadata in
            targetedReads.append(pid)
            return DesktopApplicationMetadata(dockPID: live.dockPID == pid ? pid : nil,
                supportPIDs: live.supportPIDs.contains(pid) ? [pid] : [],
                notificationCenterPIDs: live.notificationCenterPIDs.contains(pid) ? [pid] : [])
        }
        _ = events.snapshot(now: 200, load: loadAll)
        live.supportPIDs.insert(30)
        events.handle(NSWorkspace.didLaunchApplicationNotification, pid: 30, at: 200.1, load: reconcile)
        var result = events.snapshot(now: 200.1, load: loadAll)
        expect(result.supportPIDs == [10, 20, 30] && allReads == 1 && targetedReads == [30],
               "launch reconciles only its PID without rereading all applications")
        live.supportPIDs.remove(20)
        events.handle(NSWorkspace.didHideApplicationNotification, pid: 20, at: 200.2, load: reconcile)
        result = events.snapshot(now: 200.2, load: loadAll)
        expect(result.supportPIDs == [10, 30] && result.dockPID == 70 && result.notificationCenterPIDs == [80],
               "hide removes its support and preserves unrelated Dock/notification metadata")
        live.supportPIDs.insert(20)
        events.handle(NSWorkspace.didUnhideApplicationNotification, pid: 20, at: 200.3, load: reconcile)
        expect(events.snapshot(now: 200.3, load: loadAll).supportPIDs == [10, 20, 30],
               "unhide immediately restores its current eligibility")
        live.supportPIDs.remove(30)
        events.handle(NSWorkspace.didActivateApplicationNotification, pid: 30, at: 200.4, load: reconcile)
        expect(events.snapshot(now: 200.4, load: loadAll).supportPIDs == [10, 20],
               "activation reconciles changed policy without invalidating unrelated applications")
        live.notificationCenterPIDs.remove(80)
        events.handle(NSWorkspace.didTerminateApplicationNotification, pid: 80, at: 200.5, load: reconcile)
        expect(events.snapshot(now: 200.5, load: loadAll).notificationCenterPIDs.isEmpty,
               "termination removes an exited Notification Center PID")

        // The production loader resolves the current process by PID, not the
        // notification's old NSRunningApplication object or its past state.
        events.handle(NSWorkspace.didHideApplicationNotification, pid: 20, at: 200.6, load: reconcile)
        expect(events.snapshot(now: 200.6, load: loadAll).supportPIDs.contains(20),
               "a delayed hide cannot re-hide an application that is currently visible")
        live.dockPID = nil; live.supportPIDs.insert(70)
        events.handle(NSWorkspace.didTerminateApplicationNotification, pid: 70, at: 200.7, load: reconcile)
        result = events.snapshot(now: 200.7, load: loadAll)
        expect(result.dockPID == nil && result.supportPIDs.contains(70),
               "a late termination reconciles a reused PID and removes its old Dock identity")
        live.supportPIDs.remove(20)
        events.handle(NSWorkspace.didUnhideApplicationNotification, pid: 20, at: 200.8, load: reconcile)
        expect(!events.snapshot(now: 200.8, load: loadAll).supportPIDs.contains(20),
               "a delayed unhide cannot resurrect an already exited process")
        expect(allReads == 1 && targetedReads.count == 8,
               "all five native notification kinds keep one full scan within the TTL")

        live.supportPIDs.insert(40) // Simulate a lost launch/policy event.
        events.handle(NSWorkspace.didActivateApplicationNotification, pid: 10, at: 200.999, load: reconcile)
        expect(!events.snapshot(now: 200.999, load: loadAll).supportPIDs.contains(40),
               "a targeted event does not fabricate unrelated application state")
        expect(events.snapshot(now: 201, load: loadAll).supportPIDs.contains(40) && allReads == 2,
               "events never extend TTL; expiry reconciles lost events and silent policy changes")
        let beforeExpiredEvent = targetedReads.count
        events.handle(NSWorkspace.didLaunchApplicationNotification, pid: 50, at: 202, load: reconcile)
        _ = events.snapshot(now: 202, load: loadAll)
        expect(targetedReads.count == beforeExpiredEvent && allReads == 3,
               "an expired cache uses one full refresh rather than a redundant targeted read")

        events.handle(NSWorkspace.didActivateApplicationNotification, pid: nil, at: 202.1, load: reconcile)
        _ = events.snapshot(now: 202.1, load: loadAll)
        expect(allReads == 4, "missing native userInfo falls back to full invalidation")
        events.handle(NSWorkspace.didLaunchApplicationNotification, pid: 0, at: 202.2, load: reconcile)
        _ = events.snapshot(now: 202.2, load: loadAll)
        expect(allReads == 5, "invalid process identity falls back to full invalidation")
        events.invalidate()
        let beforeColdEvent = targetedReads.count
        events.handle(NSWorkspace.didActivateApplicationNotification, pid: 10, at: 202.3, load: reconcile)
        _ = events.snapshot(now: 202.3, load: loadAll)
        expect(allReads == 6 && targetedReads.count == beforeColdEvent,
               "restart/cold cache cannot build a partial application list from one event")
        events.handle(NSWorkspace.didActivateApplicationNotification, pid: 10, at: 100, load: reconcile)
        _ = events.snapshot(now: 100, load: loadAll)
        expect(allReads == 7, "a reversed clock invalidates the cache before event reconciliation")
    }

    private static func captureWatchdogTiming() {
        var watchdog = DesktopCaptureWatchdog()
        expect(watchdog.arm(at: 10), "the first capture arms the watchdog")
        expect(!watchdog.arm(at: 10.4), "repeated refreshes do not postpone the first deadline")
        watchdog.reset()
        expect(watchdog.arm(at: 10.2), "a completed capture allows a new deadline")
        let remaining = watchdog.consume(at: 10.5)
        expect(remaining != nil && abs(remaining! - 0.2) < 1e-9,
               "a queued event from the previous deadline must reschedule instead of timing out the new capture")
        expect(watchdog.consume(at: 10.7) == 0, "the current deadline produces one timeout")
        expect(watchdog.consume(at: 10.8) == nil && !watchdog.arm(at: 10.8),
               "a timed-out capture cannot trigger or rearm until it completes")
        watchdog.reset()
        expect(watchdog.arm(at: 11), "stop or completion resets the watchdog for the next capture")
        expect(!watchdog.expired(at: 11.49) && watchdog.expired(at: 11.51),
               "completion after the deadline must detect timeout even before the timer handler runs")
        watchdog.reset()
        expect(!watchdog.expired(at: 12), "stop or completion clears the previous deadline")
        expect(watchdog.arm(at: 12) && !watchdog.expired(at: 12.1),
               "a restarted capture must not inherit the old generation's deadline")
    }

    private static func captureTiming() {
        var timing = DesktopCaptureTiming()
        expect(timing.interval(at: 10) == 0.15, "stationary captures retain the 150 ms idle interval")
        timing.captureStarted(at: 10)
        expect(abs(timing.delayAfterCapture(at: 10.008) - 0.142) < 1e-9,
               "idle interval counts capture time instead of adding it after completion")
        timing.noteMotion(at: 10)
        expect(abs(timing.interval(at: 10.008) - 1.0 / 120) < 1e-9
               && abs(timing.delayAfterCapture(at: 10.008) - (1.0 / 120 - 0.008)) < 1e-9,
               "an eight-ms capture leaves only the remainder of the 120 Hz motion interval")
        expect(timing.isGeometryMoving(at: 10.008), "real geometry motion enables the renderer burst")
        expect(timing.delayAfterCapture(at: 10.055) == 0,
               "a slow capture schedules one immediate successor instead of an extra idle delay")
        timing.captureStarted(at: 10.055)
        expect(abs(timing.delayAfterCapture(at: 10.060) - (1.0 / 120 - 0.005)) < 1e-9,
               "the successor starts a new period without accumulated catch-up debt")
        expect(timing.interval(at: 10.651) == 0.15, "motion polling returns to idle after the 650 ms grace")
        expect(!timing.isGeometryMoving(at: 10.651), "renderer burst ends with the real-motion grace")

        timing.reset()
        expect(timing.noteInteraction(pressed: true, at: 20), "a rising button edge starts the same-app drag probe")
        expect(!timing.isGeometryMoving(at: 20.01), "a button probe alone must not increase the renderer rate")
        expect(!timing.noteInteraction(pressed: true, at: 20.5), "holding a button does not start another probe")
        expect(timing.interval(at: 20.651) == 0.15,
               "stationary text selection cannot keep metadata polling at 120 Hz")
        timing.noteMotion(at: 20.7)
        expect(timing.interval(at: 21) < 0.15, "actual geometric motion extends fast polling during a held drag")
        expect(timing.isGeometryMoving(at: 21), "observed movement promotes a polling probe to a render burst")
        expect(!timing.noteInteraction(pressed: false, at: 21.1), "release does not extend the motion grace")
        expect(timing.interval(at: 21.351) == 0.15, "unchanged geometry returns to idle after the last real move")
        expect(timing.noteInteraction(pressed: true, at: 22), "the next distinct press gets a fresh fast probe")
        expect(!timing.isGeometryMoving(at: 22.1), "a later stationary press cannot revive expired geometry motion")
        timing.noteMotion(at: 22.2)
        timing.reset()
        expect(timing.interval(at: 1) == 0.15 && !timing.isGeometryMoving(at: 1)
               && timing.noteInteraction(pressed: true, at: 1),
               "restart clears actual-motion, polling deadlines and sampled button state")
    }

    private static func dockGeometryCache() {
        let cache = DesktopDockGeometryCache()
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let key = DesktopDockGeometryKey(generation: 1, pid: 42, windowIDs: [7], canvases: [screen],
                                         displays: [screen], primaryTop: 1440)
        let shelf = CGRect(x: 885, y: 10, width: 790, height: 63)
        expect(cache.snapshot(key: key, at: 10) == nil, "first CG snapshot never waits for AX Dock")
        let first = cache.requestIfNeeded(at: 10)!
        expect(cache.requestIfNeeded(at: 10.017) == nil && cache.snapshot(key: key, at: 10.034) == nil,
               "multiple motion frames keep one bounded AX query in flight")
        expect(cache.requestIfNeeded(at: 10.054) == nil,
               "a 55 ms AX lookup never starts overlapping work while CG motion frames continue")
        expect(cache.complete(first, result: .visible(shelf), at: 10.055), "first discovered Dock geometry requests one refresh")
        expect(cache.snapshot(key: key, at: 10.06) == shelf && cache.requestIfNeeded(at: 10.124) == nil,
               "60 Hz CG captures reuse Dock geometry for at least 125 ms")
        let unchanged = cache.requestIfNeeded(at: 10.151)!
        expect(cache.snapshot(key: key, at: 10.18) == shelf,
               "previous Dock geometry remains boundedly available during refresh")
        expect(!cache.complete(unchanged, result: .visible(shelf), at: 10.20),
               "an unchanged AX result must not double idle CG polling")
        expect(!cache.complete(unchanged, result: .hidden, at: 10.21) && cache.snapshot(key: key, at: 10.21) == shelf,
               "duplicate completion cannot overwrite the accepted result")
        let hidden = cache.requestIfNeeded(at: 10.302)!
        expect(cache.complete(hidden, result: .hidden, at: 10.32) && cache.snapshot(key: key, at: 10.33) == nil,
               "Dock autohide removes geometry and requests one visibility refresh")
        expect(cache.requestIfNeeded(at: 10.426) == nil, "negative AX results are also cached")
        let stillHidden = cache.requestIfNeeded(at: 10.453)!
        expect(!cache.complete(stillHidden, result: .hidden, at: 10.47),
               "an unchanged negative AX result produces no extra CG snapshot")
        let revealed = cache.requestIfNeeded(at: 10.604)!
        expect(cache.complete(revealed, result: .visible(shelf), at: 10.62), "revealed Dock geometry requests one refresh")
        expect(cache.snapshot(key: key, at: 11.121) == nil,
               "cached Dock geometry cannot survive an unbounded worker or delivery stall")

        var variants: [DesktopDockGeometryKey] = []
        var changed = key; changed.generation += 1; variants.append(changed)
        changed = key; changed.pid += 1; variants.append(changed)
        changed = key; changed.windowIDs = [8]; variants.append(changed)
        changed = key; changed.canvases = [screen.offsetBy(dx: 10, dy: 0)]; variants.append(changed)
        changed = key; changed.displays = [screen.offsetBy(dx: -2560, dy: 0)]; variants.append(changed)
        changed = key; changed.primaryTop = 900; variants.append(changed)
        for variant in variants {
            let stale = DesktopDockGeometryCache()
            _ = stale.snapshot(key: key, at: 20)
            let request = stale.requestIfNeeded(at: 20)!
            expect(stale.snapshot(key: variant, at: 20.01) == nil && stale.requestIfNeeded(at: 20.01) == nil,
                   "key changes discard visible cache without overlapping the previous AX request")
            expect(!stale.complete(request, result: .visible(shelf), at: 20.02)
                   && stale.snapshot(key: variant, at: 20.02) == nil,
                   "a stale generation/PID/window/display response must not be published")
            expect(stale.requestIfNeeded(at: 20.126) != nil, "the current key can load once the old request finishes")
        }
        let reopened = DesktopDockGeometryCache()
        _ = reopened.snapshot(key: key, at: 30)
        let old = reopened.requestIfNeeded(at: 30)!
        expect(reopened.snapshot(key: nil, at: 30.01) == nil && reopened.requestIfNeeded(at: 30.01) == nil,
               "missing Dock CG metadata or AX trust neither keeps geometry nor starts queries")
        _ = reopened.snapshot(key: key, at: 30.02)
        expect(!reopened.complete(old, result: .visible(shelf), at: 30.03)
               && reopened.snapshot(key: key, at: 30.03) == nil,
               "close/reopen with identical IDs cannot revive a pre-closure AX result")
        expect(reopened.requestIfNeeded(at: 30.03) != nil, "reopening schedules fresh Dock geometry")

        let jittered = DesktopDockGeometryCache()
        _ = jittered.snapshot(key: key, at: 40)
        let seed = jittered.requestIfNeeded(at: 40)!
        expect(jittered.complete(seed, result: .visible(shelf), at: 40.006), "jitter regression starts with a visible Dock")
        expect(jittered.snapshot(key: key, at: 40.149) == shelf,
               "a 149 ms idle capture keeps the existing Dock visible")
        let early = jittered.requestIfNeeded(at: 40.149)
        expect(early != nil, "a 149 ms tick must refresh before the next idle capture can exceed maxAge")
        expect(!jittered.complete(early!, result: .visible(shelf), at: 40.155),
               "refreshing unchanged Dock geometry at 149 ms schedules no extra snapshot")
        expect(jittered.snapshot(key: key, at: 40.299) == shelf,
               "the 299 ms idle capture must not briefly hide unchanged Dock geometry")
        let following = jittered.requestIfNeeded(at: 40.299)!
        expect(!jittered.complete(following, result: .visible(shelf), at: 40.305),
               "the following identical result also preserves the one-capture idle cadence")

        let list = CGRect(x: 885, y: 10, width: 790, height: 68)
        let items: [CGRect?] = [CGRect(x: 900, y: 5, width: 52, height: 68), CGRect(x: 952, y: 5, width: 52, height: 68)]
        expect(DesktopDockReadResult.geometry(listFrame: list, itemFrames: items) == .visible(shelf),
               "a complete direct-item read confirms the fine contact geometry")
        let partial = DesktopDockReadResult.geometry(listFrame: list, itemFrames: [items[0], nil])
        expect(partial == .unavailable, "a failed DockItem read cannot create a coarse five-point fallback")
        expect(DesktopDockReadResult.geometry(listFrame: list, itemFrames: nil) == .unavailable
               && DesktopDockReadResult.geometry(listFrame: list, itemFrames: []) == .unavailable
               && DesktopDockReadResult.geometry(listFrame: list, itemFrames: [items[0], CGRect.zero]) == .unavailable,
               "missing, empty or invalid direct-item metadata is unknown, not authoritative hidden")

        let coarse = DesktopDockGeometryCache()
        _ = coarse.snapshot(key: key, at: 50)
        expect(coarse.resolvedFrame(cgFallback: list, at: 50) == list
               && coarse.complete(coarse.requestIfNeeded(at: 50)!, result: .hidden, at: 50.01)
               && coarse.resolvedFrame(cgFallback: list, at: 50.01) == nil,
               "the first confirmed hidden result immediately publishes removal of a visible CG fallback")
        expect(!coarse.complete(coarse.requestIfNeeded(at: 50.15)!, result: .hidden, at: 50.16),
               "repeated confirmed hidden results cannot add idle CG captures")

        let stationary = DesktopDockGeometryCache()
        _ = stationary.snapshot(key: key, at: 60)
        expect(stationary.resolvedFrame(cgFallback: list, at: 60) == list,
               "a real CG edge strip is usable before AX has produced any complete result")
        let stationarySeed = stationary.requestIfNeeded(at: 60)!
        _ = stationary.complete(stationarySeed, result: .visible(shelf), at: 60.006)
        let failed = stationary.requestIfNeeded(at: 60.15)!
        expect(!stationary.complete(failed, result: .unavailable, at: 60.16)
               && stationary.snapshot(key: key, at: 60.17) == shelf,
               "one stationary AX timeout keeps the visible Dock without a refresh notification")
        expect(stationary.requestIfNeeded(at: 60.274) == nil,
               "an unavailable result still throttles the next attempt to 125 ms")
        let partialRead = stationary.requestIfNeeded(at: 60.3)!
        expect(!stationary.complete(partialRead, result: partial, at: 60.31)
               && stationary.resolvedFrame(cgFallback: list, at: 60.32) == shelf,
               "partial items retain the known fine shelf instead of jumping to the coarse CG strip")
        let recovered = stationary.requestIfNeeded(at: 60.45)!
        expect(!stationary.complete(recovered, result: .visible(shelf), at: 60.46)
               && stationary.snapshot(key: key, at: 60.47) == shelf,
               "success after two failures preserves the same static Dock without hide/reveal")
        let actualHide = stationary.requestIfNeeded(at: 60.6)!
        expect(stationary.complete(actualHide, result: .hidden, at: 60.61)
               && stationary.resolvedFrame(cgFallback: list, at: 60.62) == nil,
               "confirmed hidden overrides a CG edge strip immediately, without a ghost shelf")

        let expiring = DesktopDockGeometryCache()
        _ = expiring.snapshot(key: key, at: 70)
        _ = expiring.complete(expiring.requestIfNeeded(at: 70)!, result: .visible(shelf), at: 70.005)
        for attempt in [70.15, 70.3, 70.45] {
            let request = expiring.requestIfNeeded(at: attempt)!
            expect(!expiring.complete(request, result: .unavailable, at: attempt + 0.01),
                   "repeated failures do not notify or renew the last successful geometry")
        }
        expect(expiring.snapshot(key: key, at: 70.504) == shelf,
               "the transient grace is measured from the last complete success")
        expect(expiring.snapshot(key: key, at: 70.506) == nil
               && expiring.resolvedFrame(cgFallback: list, at: 70.506) == nil,
               "500 ms without evidence removes the shelf and cannot revive a coarse fallback")

        let orderCache = DesktopDockGeometryCache()
        var ordered = key; ordered.windowIDs = [7, 8]; ordered.canvases = [screen, CGRect(x: 800, y: 0, width: 1000, height: 100)]
        _ = orderCache.snapshot(key: ordered, at: 80)
        _ = orderCache.complete(orderCache.requestIfNeeded(at: 80)!, result: .visible(shelf), at: 80.005)
        var reordered = ordered
        reordered.windowIDs.reverse(); reordered.canvases.reverse()
        expect(orderCache.snapshot(key: reordered, at: 80.05) == shelf && orderCache.requestIfNeeded(at: 80.05) == nil,
               "reordering identical CG ID/frame pairs cannot invalidate the static Dock cache")
        let pending = orderCache.requestIfNeeded(at: 80.15)!
        var replacement = key; replacement.windowIDs = [9]
        expect(orderCache.snapshot(key: replacement, at: 80.16) == shelf,
               "same-context canvas replacement keeps a still-corroborated shelf within its existing grace")
        expect(!orderCache.complete(pending, result: .hidden, at: 80.17)
               && orderCache.snapshot(key: replacement, at: 80.17) == shelf,
               "soft churn still advances the epoch and rejects the old response")
        expect(orderCache.requestIfNeeded(at: 80.274) == nil,
               "CG churn cannot bypass the AX query rate limit")
        expect(orderCache.snapshot(key: replacement, at: 80.506) == nil,
               "soft key churn does not restart the last-success grace")
        let replacementRead = orderCache.requestIfNeeded(at: 80.506)!
        _ = orderCache.complete(replacementRead, result: .visible(shelf), at: 80.51)
        var unrelated = replacement; unrelated.canvases = [CGRect(x: 0, y: 0, width: 200, height: 100)]
        expect(orderCache.snapshot(key: unrelated, at: 80.52) == nil,
               "a canvas that no longer corroborates the shelf cannot retain its old geometry")
        for variant in variants.filter({ !$0.hasSameContext(as: key) }) {
            let hard = DesktopDockGeometryCache()
            _ = hard.snapshot(key: key, at: 90)
            _ = hard.complete(hard.requestIfNeeded(at: 90)!, result: .visible(shelf), at: 90.005)
            expect(hard.snapshot(key: variant, at: 90.01) == nil,
                   "PID/generation/display replacement discards good geometry immediately")
        }
        _ = stationary.snapshot(key: key, at: 100)
        _ = stationary.complete(stationary.requestIfNeeded(at: 100)!, result: .visible(shelf), at: 100.005)
        expect(stationary.snapshot(key: nil, at: 100.01) == nil && stationary.requestIfNeeded(at: 100.01) == nil,
               "loss of CG evidence or AX trust clears good geometry immediately")
    }

    private static func dockSupports() {
        // Actual Dock AXList geometry: Quartz [859,1362,842,68], primary top 1440.
        let frame = WorldCoordinates.fromQuartz(CGRect(x: 859, y: 1362, width: 842, height: 68), primaryHeight: 1440)
        var dock = SnowSurface(id: "dock", frame: frame, kind: .dock)
        dock.topInset = DesktopGeometry.dockTopInset(for: frame)
        expect(dock.topInset == 32, "the measured Dock needs a wider corner inset than an ordinary window")
        expect(!dock.supports(x: frame.minX + 20) && !dock.supports(x: frame.maxX - 20),
               "Dock snow cannot rest on the curved end caps")
        expect(dock.supports(x: frame.midX) && dock.supports(x: frame.minX + 32),
               "the flat Dock center and inset boundary remain accumulation supports")
        expect(dock.frame == CGRect(x: 859, y: 10, width: 842, height: 68),
               "horizontal support insets must preserve the chosen contact frame")
        expect(dock.isExposed(CGPoint(x: frame.minX + 2, y: frame.maxY + 8)),
               "a ball overhanging the inset must retain its complete visible silhouette")
        let small = CGRect(x: -900, y: 10, width: 500, height: 40)
        expect(DesktopGeometry.dockTopInset(for: small) == 20, "small horizontal Dock caps scale with their height")
        let side = CGRect(x: -1440, y: 150, width: 80, height: 700)
        expect(DesktopGeometry.dockTopInset(for: side) == 32, "vertical Dock caps scale with their width")
        let narrow = CGRect(x: 1400, y: 150, width: 40, height: 700)
        let narrowInset = DesktopGeometry.dockTopInset(for: narrow)
        expect(narrowInset == 16 && narrow.width - 2 * narrowInset == SnowDrift.spacing * 2,
               "a narrow vertical Dock keeps a usable upper support instead of collapsing it")
        expect(DesktopGeometry.dockTopInset(for: CGRect(x: 0, y: 0, width: 20, height: 25)) == 6,
               "very small Dock geometry never receives overlapping corner insets")
        expect(DesktopGeometry.dockTopInset(for: .zero) == 0,
               "invalid Dock geometry must not produce an invalid inset")
    }

    private static func dockContact() {
        // Observed AXList [885,1362,790,68] and direct AXDockItem top 1367
        // in Quartz. These are metadata bounds, not a measured glass silhouette.
        let list = WorldCoordinates.fromQuartz(CGRect(x: 885, y: 1362, width: 790, height: 68), primaryHeight: 1440)
        let items = [892.6, 944.6, 996.6, 1048.6, 1100.6].map { x in
            WorldCoordinates.fromQuartz(CGRect(x: x, y: 1367, width: 52, height: 68), primaryHeight: 1440)
        }
        let contact = DesktopGeometry.dockSupportFrame(for: list, itemFrames: items)
        expect(list.maxY == 78 && contact.maxY == 73,
               "the measured direct items lower the old floating support by five points")
        expect(contact.minX == list.minX && contact.width == list.width && contact.minY == list.minY,
               "contact adjustment preserves the Dock horizontal span and bottom")
        var dock = SnowSurface(id: "dock", frame: contact, kind: .dock)
        dock.topInset = DesktopGeometry.dockTopInset(for: contact)
        expect(dock.top == 73 && dock.topInset == 31.5 && dock.supports(x: list.midX),
               "physics and rendering receive the same lower support with a usable center")

        let invalid = [CGRect.zero, CGRect(x: CGFloat.nan, y: 5, width: 52, height: 68),
                       CGRect(x: 5000, y: 5, width: 52, height: 68),
                       CGRect(x: 1200, y: 10, width: 23.4, height: 68)]
        let magnified = CGRect(x: 1200, y: 5, width: 104, height: 136)
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: items + invalid + [magnified]) == contact,
               "separators, invalid or distant items and magnification cannot lift the common support")
        let slightlyMagnified = CGRect(x: 1200, y: 5, width: 68, height: 84)
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: items + [slightlyMagnified]) == contact,
               "the ordinary-size median rejects an enlarged item still inside the broad size bounds")
        let uneven = [items[0].offsetBy(dx: 0, dy: -1), items[1], items[2].offsetBy(dx: 0, dy: 1)]
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: uneven).maxY == 73,
               "horizontal contact uses median top instead of the highest item")
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: []).maxY == 73,
               "missing or timed-out child geometry uses the bounded contact fallback")
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: [items[0].offsetBy(dx: 0, dy: -3)]).maxY == 73,
               "one surviving item is insufficient to shift the whole Dock")
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: items.map { $0.offsetBy(dx: 0, dy: -30) }).maxY == 73,
               "a large metadata gap cannot move the support deep into the Dock")
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: items.map { $0.offsetBy(dx: 0, dy: 20) }).maxY == 73,
               "item tops above the AXList cannot raise snow over magnification")
        expect(DesktopGeometry.dockSupportFrame(for: list, itemFrames: items.map { $0.offsetBy(dx: 0, dy: 5) }).maxY == 78,
               "aligned child and list tops need no artificial lowering")

        let small = CGRect(x: -900, y: 10, width: 500, height: 40)
        let smallItems = [CGRect(x: -890, y: 7, width: 28, height: 40), CGRect(x: -862, y: 7, width: 28, height: 40)]
        expect(DesktopGeometry.dockSupportFrame(for: small, itemFrames: smallItems).maxY == 47,
               "small Dock geometry uses the observed three-point contact in world coordinates")
        expect(DesktopGeometry.dockSupportFrame(for: small, itemFrames: []).maxY == 46,
               "fallback scales below five points on a small Dock")
        let scaled = CGRect(x: 0, y: 20, width: 1580, height: 136)
        let scaledItems = [CGRect(x: 15, y: 10, width: 104, height: 136), CGRect(x: 119, y: 10, width: 104, height: 136)]
        expect(DesktopGeometry.dockSupportFrame(for: scaled, itemFrames: scaledItems).maxY == 146,
               "larger metadata can use a ten-point contact while remaining within the absolute bound")

        let side = CGRect(x: -1440, y: 150, width: 80, height: 700)
        let sideItems = [CGFloat(845), 789, 733, 677, 621, 565, 509, 453, 397, 341, 285, 229].map { top in
            CGRect(x: -1445, y: top - 56, width: 80, height: 56)
        }
        let sideContact = DesktopGeometry.dockSupportFrame(for: side, itemFrames: sideItems)
        expect(sideContact.maxY == 845,
               "a long vertical Dock anchors to its upper normal item, never the middle of the list")
        expect(sideContact.minX == side.minX && sideContact.width == side.width && sideContact.minY == side.minY,
               "vertical contact adjustment preserves the side Dock footprint")
        let enlargedSide = CGRect(x: -1445, y: 770, width: 160, height: 112)
        expect(DesktopGeometry.dockSupportFrame(for: side, itemFrames: sideItems + [enlargedSide]) == sideContact,
               "a magnified side item cannot lift the upper support")
        expect(DesktopGeometry.dockSupportFrame(for: side, itemFrames: Array(sideItems.dropFirst())).maxY == 845,
               "missing upper side items use the small fallback instead of a lower item's edge")
        let narrow = CGRect(x: 1400, y: 150, width: 40, height: 700)
        let narrowItems = [CGRect(x: 1398, y: 819, width: 40, height: 28), CGRect(x: 1398, y: 791, width: 40, height: 28)]
        expect(DesktopGeometry.dockSupportFrame(for: narrow, itemFrames: narrowItems).maxY == 847,
               "narrow side Dock still uses its upper direct child")
        expect(DesktopGeometry.dockSupportFrame(for: .zero, itemFrames: items) == .zero,
               "invalid list bounds cannot become a fabricated support")
        expect(Int(CGWindowLevelForKey(.dockWindow)) > NSWindow.Level.floating.rawValue,
               "the native Dock compositor is above the effect overlay and owns its true silhouette")
    }

    private static func cursorOcclusion() {
        // Observed during stationary hover: AppKit [1957,-27,42,60], alpha 1.
        // This is the public cursor level, not a menu or an application tooltip.
        let level = 2_147_483_630
        let cursor = CGRect(x: 1957, y: -27, width: 42, height: 60)
        expect(level == Int(CGWindowLevelForKey(.cursorWindow)), "the observed backing rectangle uses the public cursor window level")
        let cases: [(CGRect, CGPoint)] = [
            (cursor, CGPoint(x: 1965, y: 0)),
            (cursor.offsetBy(dx: -465, dy: 78), CGPoint(x: 1500, y: 78)),
            (cursor.offsetBy(dx: -965, dy: 700), CGPoint(x: 1000, y: 700))
        ]
        for (frame, supportPoint) in cases {
            expect(frame.contains(supportPoint), "the old 42x60 bounding-box mask removes snow on floor, Dock or window roof")
            let mask: CGRect? = DesktopGeometry.isSnowOccluder(layer: level, alpha: 1) ? frame : nil
            expect(mask?.contains(supportPoint) != true, "the cursor must not punch a rectangular hole in any snow support")
        }
        for legitimate in [0, Int(CGWindowLevelForKey(.floatingWindow)), Int(CGWindowLevelForKey(.dockWindow)),
                           Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.popUpMenuWindow)),
                           Int(CGWindowLevelForKey(.statusWindow)), Int(CGWindowLevelForKey(.helpWindow)),
                           Int(CGWindowLevelForKey(.screenSaverWindow)), level - 1, level + 1] {
            expect(DesktopGeometry.isSnowOccluder(layer: legitimate, alpha: 1),
                   "ordinary windows, menus, help/tooltips and neighboring high layers must retain occlusion")
        }
        expect(!DesktopGeometry.isSnowOccluder(layer: 0, alpha: 0.01), "the existing invisible-alpha filter is preserved")
        expect(!DesktopGeometry.isSnowOccluder(layer: -1, alpha: 1), "the existing desktop/background-layer filter is preserved")
    }

    private static func notificationOcclusion() {
        // Geometry-only fixture captured from the open NC panel on macOS 27.2.
        // Its scalar alpha was 1, but the layer-23 window is a transparent canvas.
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        expect(DesktopGeometry.isNotificationCenterCanvas(screen, layer: 23, notificationCenter: true, displays: [screen]),
               "the verified NC full-display canvas must not become a full-screen snow mask")
        expect(!DesktopGeometry.isNotificationCenterCanvas(screen, layer: 23, notificationCenter: false, displays: [screen]),
               "same-size windows belonging to another app must keep ordinary occlusion")
        expect(!DesktopGeometry.isNotificationCenterCanvas(screen, layer: 0, notificationCenter: false, displays: [screen])
               && DesktopGeometry.coversDisplay(screen, screen), "real fullscreen apps retain their suppression rule")
        expect(!DesktopGeometry.isNotificationCenterCanvas(screen, layer: 0, notificationCenter: true, displays: [screen]),
               "a low-layer window is not the service canvas above our overlay")
        let banner = CGRect(x: 2200, y: 1300, width: 344, height: 90)
        expect(!DesktopGeometry.isNotificationCenterCanvas(banner, layer: 23, notificationCenter: true, displays: [screen]),
               "real NC panels and banners retain their CG occlusion bounds")
        expect(!DesktopGeometry.isNotificationCenterCanvas(screen.insetBy(dx: -100, dy: 0), layer: 23,
                                                           notificationCenter: true, displays: [screen]),
               "an arbitrary oversized NC window is not silently discarded")

        let scroll = WorldCoordinates.fromQuartz(CGRect(x: 1808, y: 0, width: 752, height: 1346), primaryHeight: 1440)
        let panel = WorldCoordinates.fromQuartz(CGRect(x: 2200, y: 52, width: 344, height: 477), primaryHeight: 1440)
        let widget = WorldCoordinates.fromQuartz(CGRect(x: 2200, y: 545, width: 164, height: 164), primaryHeight: 1440)
        let masks = [panel, widget].compactMap { DesktopGeometry.notificationContentMask($0, scrollArea: scroll, canvas: screen) }
        expect(masks == [panel, widget], "use actual content rectangles instead of the broad transparent AX container")
        let roof = CGPoint(x: 1000, y: 900), floor = CGPoint(x: 1000, y: 0)
        expect(screen.contains(roof) && screen.contains(floor), "the original full-canvas mask reproduces both disappearing snow areas")
        expect(!masks.contains(where: { $0.contains(roof) || $0.contains(floor) }),
               "ordinary window roofs and the floor outside the panel remain visible")
        expect(masks.contains(where: { $0.contains(CGPoint(x: panel.midX, y: panel.midY)) })
               && masks.contains(where: { $0.contains(CGPoint(x: widget.midX, y: widget.midY)) }),
               "both real notifications and widgets still occlude snow")
        expect(!masks.contains(where: { $0.contains(CGPoint(x: 1900, y: 1000)) }),
               "the AX animation buffer left of the visible panel remains transparent")
        expect(DesktopGeometry.notificationContentMask(screen, scrollArea: screen, canvas: screen) == nil,
               "AX may not reintroduce the full canvas as content")
        expect(DesktopGeometry.notificationContentMask(.zero, scrollArea: scroll, canvas: screen) == nil,
               "zero-sized AX placeholders cannot occlude snow")
        let offscreenChild = CGRect(x: 2500, y: 1400, width: 200, height: 200)
        expect(DesktopGeometry.notificationContentMask(offscreenChild, scrollArea: screen, canvas: screen)
               == CGRect(x: 2500, y: 1400, width: 60, height: 40), "content is clipped to the corroborated canvas")
        let leftDisplay = screen.offsetBy(dx: -2560, dy: 0)
        expect(DesktopGeometry.isNotificationCenterCanvas(leftDisplay, layer: 23, notificationCenter: true,
                                                          displays: [screen, leftDisplay]), "canvas matching supports negative-coordinate displays")
        let leftMask = DesktopGeometry.notificationContentMask(panel.offsetBy(dx: -2560, dy: 0),
                                                               scrollArea: scroll.offsetBy(dx: -2560, dy: 0), canvas: leftDisplay)
        expect(leftMask != nil && leftMask?.intersects(screen) == false, "NC masks must not bleed onto a neighboring display")
    }

    private static func nativeMenuAndScreenshotGeometry() {
        let menu = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        expect(menu > floating && DesktopGeometry.usesNativeMenuOcclusion(layer: menu),
               "the native context menu occludes via compositing, without masking its transparent margins")
        for layer in [0, floating, menu - 1, menu + 1] {
            expect(!DesktopGeometry.usesNativeMenuOcclusion(layer: layer),
                   "ordinary windows and neighboring panel levels retain their masks")
        }
        let display = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let menuBar = Int(CGWindowLevelForKey(.mainMenuWindow))
        expect(DesktopGeometry.canBeScreenshotWindow(layer: menuBar, frame: display.insetBy(dx: 8, dy: 5), displays: [display]),
               "the near-full-display selection canvas is a screenshot owner candidate")
        expect(!DesktopGeometry.canBeScreenshotWindow(layer: menuBar,
                    frame: CGRect(x: display.minX, y: 1410, width: display.width, height: 30), displays: [display]),
               "the actual menu bar does not trigger screenshot lookup")
        let shield = Int(CGWindowLevelForKey(.assistiveTechHighWindow)) - 2
        expect(DesktopGeometry.canBeScreenshotWindow(layer: shield, frame: display, displays: [display]),
               "the system region-selection shield is a screenshot owner candidate")
        let thumbnail = CGRect(x: display.maxX - 220, y: display.minY + 24, width: 196, height: 126)
        expect(!DesktopGeometry.canBeScreenshotWindow(layer: shield, frame: thumbnail, displays: [display]),
               "a floating preview at the selection layer must not keep screenshot pause active")
        let helper = CGRect(x: display.minX, y: display.minY, width: 8, height: 8)
        expect(!DesktopGeometry.canBeScreenshotWindow(layer: shield + 1, frame: helper, displays: [display]),
               "a small helper at the selection layer must not keep screenshot pause active")
    }

    private static func hiddenWindowSupports() {
        let window = kCGWindowNumber as String
        let owner = kCGWindowOwnerPID as String
        let previous: [UInt32: pid_t] = [8: 80, 9: 90, 10: 100]
        let inventory = [[window: 8, owner: 80], [window: 9, owner: 91], [window: 11, owner: 110]]
        expect(DesktopGeometry.survivingWindowSupports(previous, in: inventory) == [8: 80],
               "only a known offscreen ID with the same owner retains its support")
    }

    private static func notificationGeometryCache() {
        let cache = DesktopNotificationGeometryCache()
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let canvas = DesktopNotificationCanvas(id: 1, pid: 42, frame: frame)
        let content = CGRect(x: 2200, y: 100, width: 344, height: 600)
        var reads = 0
        let load = { () -> [UInt32: [CGRect]] in reads += 1; return [1: [content]] }
        let initial = cache.snapshot(generation: 1, canvases: [canvas], now: 10, load: load)
        expect(reads == 1 && initial[1] == [content], "NC geometry is fetched once while the canvas is present")
        _ = cache.snapshot(generation: 1, canvases: [canvas], now: 10.035, load: load)
        _ = cache.snapshot(generation: 1, canvases: [canvas], now: 10.499, load: load)
        expect(reads == 1, "35 ms polling must reuse NC geometry for half a second")
        _ = cache.snapshot(generation: 1, canvases: [canvas], now: 10.5, load: load)
        expect(reads == 2, "NC geometry refreshes at the 500 ms TTL boundary")
        _ = cache.snapshot(generation: 2, canvases: [canvas], now: 10.51, load: load)
        expect(reads == 3, "Space and screen invalidation cannot reuse stale NC masks")
        var moved = canvas; moved.frame = frame.offsetBy(dx: -2560, dy: 0)
        _ = cache.snapshot(generation: 2, canvases: [moved], now: 10.52, load: load)
        expect(reads == 4, "a moved canvas invalidates the cached geometry immediately")
        let closed = cache.snapshot(generation: 2, canvases: [], now: 10.53, load: load)
        expect(closed.isEmpty && reads == 4, "closed NC neither retains masks nor performs AX reads")
        _ = cache.snapshot(generation: 2, canvases: [moved], now: 10.54, load: load)
        expect(reads == 5, "reopening NC requires fresh geometry even within the old TTL")
        var restarted = moved; restarted.pid = 43; restarted.id = 2
        let failed = cache.snapshot(generation: 2, canvases: [restarted], now: 10.55) { reads += 1; return [:] }
        expect(reads == 6 && failed.isEmpty, "a new NC process cannot inherit old masks; unavailable AX uses no guessed full-screen mask")
        _ = cache.snapshot(generation: 2, canvases: [restarted], now: 10.585, load: load)
        expect(reads == 6, "AX failure must be cached instead of retried on each 35 ms poll")
        let recovered = cache.snapshot(generation: 2, canvases: [restarted], now: 11.05, load: load)
        expect(reads == 7 && !recovered.isEmpty, "AX failure is retried after the bounded cache TTL")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        checks += 1
    }

    private static func geometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        expect(DesktopGeometry.isDock(CGRect(x: 200, y: 10, width: 1000, height: 80), displays: [screen]), "bottom Dock")
        expect(DesktopGeometry.isDock(CGRect(x: 0, y: 200, width: 80, height: 600), displays: [screen]), "left Dock")
        expect(DesktopGeometry.isDock(CGRect(x: 1360, y: 200, width: 80, height: 600), displays: [screen]), "right Dock")
        expect(!DesktopGeometry.isDock(CGRect(x: 200, y: -79, width: 1000, height: 80), displays: [screen]), "hidden Dock activation strip is not a visible surface")
        expect(!DesktopGeometry.isDock(CGRect(x: 300, y: 350, width: 800, height: 200), displays: [screen]), "app switcher is not Dock")
        expect(!DesktopGeometry.isDock(screen, displays: [screen]), "desktop or Mission Control background is not Dock")
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        expect(DesktopGeometry.isDock(CGRect(x: -1440, y: 200, width: 80, height: 600), displays: [left]), "Dock on negative-coordinate display")
        expect(!DesktopGeometry.isDock(CGRect(x: 0, y: 0, width: 1000, height: 0), displays: [screen]), "zero-height bounds rejected")
        expect(!DesktopGeometry.valid(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)), "invalid coordinates rejected")
        expect(DesktopGeometry.coversDisplay(screen, screen), "borderless fullscreen detected")
        expect(!DesktopGeometry.coversDisplay(CGRect(x: 0, y: 0, width: 1440, height: 876), screen), "maximized below menu bar is not fullscreen")
        expect(!DesktopGeometry.coversDisplay(CGRect(x: 0, y: 80, width: 1440, height: 820), screen), "window above visible Dock is not fullscreen")
        expect(!DesktopGeometry.coversDisplay(left, screen), "fullscreen only affects its display")
        let converted = WorldCoordinates.fromQuartz(CGRect(x: -1440, y: -400, width: 500, height: 300), primaryHeight: 900)
        expect(converted == CGRect(x: -1440, y: 1000, width: 500, height: 300), "Quartz conversion uses primary top for a display above/left")
    }

    private static func failedWindowMetadata() {
        let display = DesktopDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleTop: 876)
        let bounds = CGRect(x: 100, y: 700, width: 500, height: 200)
        let record: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: ProcessInfo.processInfo.processIdentifier),
            kCGWindowNumber as String: NSNumber(value: 987654),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1)
        ]
        let dockPID: pid_t = 987123
        let dock: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: dockPID),
            kCGWindowNumber as String: NSNumber(value: 987655),
            kCGWindowBounds as String: CGRect(x: 200, y: 830, width: 1000, height: 60).dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: CGWindowLevelForKey(.dockWindow)),
            kCGWindowAlpha as String: NSNumber(value: 1)
        ]
        let metadata = TestWindowMetadata([record, dock])
        let environment = DesktopEnvironment(windowMetadata: { metadata.read() }, displays: { [display] },
                                             primaryDisplayTop: { display.frame.maxY },
                                             applicationMetadata: { DesktopApplicationMetadata(dockPID: dockPID, supportPIDs: []) })
        var snapshots: [DesktopSnapshot] = []
        var failures = 0
        environment.onSnapshot = { snapshots.append($0) }
        environment.onCaptureUnavailable = { _ in failures += 1 }
        environment.start()
        wait(until: { !snapshots.isEmpty })
        expect(!snapshots.isEmpty, "initial metadata produces a snapshot")
        let initialFloor = snapshots[0].surfaces.first { $0.kind == .floor }
        expect(initialFloor?.occluders.isEmpty == false, "initial snapshot contains the window mask")
        let dockID = snapshots[0].surfaces.first { $0.kind == .dock }?.id
        expect(dockID != nil, "initial snapshot contains a visible Dock")

        metadata.set(nil)
        environment.refresh()
        wait(until: { failures > 0 })
        expect(failures > 0, "nil window metadata reports an unavailable capture")
        let countBeforeRetry = snapshots.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(snapshots.count == countBeforeRetry, "a failed capture never publishes empty surfaces or masks")
        expect(failures < 10, "repeated failures are retried at a bounded cadence")

        metadata.set([record])
        wait(until: { snapshots.count > countBeforeRetry })
        expect(snapshots.count > countBeforeRetry, "polling recovers after metadata becomes available")
        let recoveredFloor = snapshots.last?.surfaces.first { $0.kind == .floor }
        expect(recoveredFloor?.occluders == initialFloor?.occluders,
               "a later successful capture restores the same window mask")
        let hiddenDock = snapshots.last?.surfaces.first { $0.kind == .dock }
        expect(hiddenDock?.id == dockID && hiddenDock?.isVisible == false,
               "the same Dock survives autohide after an unavailable capture")
        metadata.set([record, dock])
        environment.refresh()
        wait(until: { snapshots.last?.surfaces.first(where: { $0.kind == .dock })?.isVisible == true })
        expect(snapshots.last?.surfaces.first(where: { $0.kind == .dock })?.id == dockID,
               "the same Dock becomes visible again after autohide")
        environment.stop()
    }

    private static func stalledWindowMetadata() {
        let display = DesktopDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleTop: 576)
        let metadata = StalledWindowMetadata()
        let environment = DesktopEnvironment(windowMetadata: { metadata.read() }, displays: { [display] },
                                             primaryDisplayTop: { display.frame.maxY },
                                             applicationMetadata: { DesktopApplicationMetadata(dockPID: nil, supportPIDs: []) })
        var snapshots: [DesktopSnapshot] = []
        var timeouts = 0
        var failures = 0
        var failureElapsed: TimeInterval = 0
        environment.onSnapshot = { snapshots.append($0) }
        environment.onCaptureTimeout = { timeouts += 1 }
        environment.onCaptureUnavailable = { elapsed in failures += 1; failureElapsed = elapsed }
        environment.start()
        wait(until: { !snapshots.isEmpty })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        expect(timeouts == 0, "completed captures must not later fire their watchdogs")

        metadata.delayNextNil(0.2)
        environment.refresh()
        wait(until: { failures == 1 || timeouts > 0 })
        expect(failures == 1 && timeouts == 0 && failureElapsed >= 0.19,
               "a delayed nil reports elapsed capture time without triggering an early watchdog")
        failures = 0

        metadata.blockNext()
        environment.refresh()
        wait(until: { metadata.isBlocked })
        let before = snapshots.count
        wait(until: { timeouts == 1 })
        expect(timeouts == 1 && snapshots.count == before, "a blocked capture reports a timeout without publishing an empty snapshot")
        environment.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        expect(timeouts == 1 && metadata.maximumConcurrentReads == 1,
               "repeated refreshes neither restart the watchdog nor run another capture")
        let readsBeforeRelease = metadata.readCount
        metadata.unblock()
        wait(until: { snapshots.count > before })
        expect(snapshots.count > before && metadata.readCount > readsBeforeRelease,
               "a timed-out success is discarded and a fresh capture recovers")
        expect(snapshots.dropFirst(before).allSatisfy { $0.captureMilliseconds < 500 },
               "a stale successful result must not be published")

        metadata.blockNext(returningNil: true)
        environment.refresh()
        wait(until: { metadata.isBlocked })
        let beforeNil = snapshots.count
        wait(until: { timeouts == 2 })
        let readsBeforeNilRelease = metadata.readCount
        metadata.unblock()
        wait(until: { snapshots.count > beforeNil })
        expect(timeouts == 2 && failures == 0 && metadata.readCount > readsBeforeNilRelease,
               "a timed-out nil must not restart the failure grace period and a fresh capture recovers")

        metadata.blockNext()
        environment.refresh()
        wait(until: { metadata.isBlocked })
        environment.invalidate()
        let beforeInvalidated = snapshots.count
        wait(until: { timeouts == 3 })
        expect(timeouts == 3, "an invalidated call that still blocks capture must time out")
        metadata.unblock()
        wait(until: { snapshots.count > beforeInvalidated })
        expect(snapshots.count > beforeInvalidated && snapshots.last?.generation == 2,
               "the invalidated result is discarded and a new capture recovers")

        metadata.blockNext()
        environment.refresh()
        wait(until: { metadata.isBlocked })
        environment.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        expect(timeouts == 3, "a stopped environment must not report a pending timeout")
        environment.start()
        wait(until: { timeouts == 4 })
        expect(timeouts == 4 && metadata.maximumConcurrentReads == 1,
               "a restarted environment reports the old blocking call without a concurrent capture")
        let beforeRestart = snapshots.count
        metadata.unblock()
        wait(until: { snapshots.count > beforeRestart })
        expect(snapshots.count > beforeRestart && snapshots.last?.generation == 4,
               "restart discards the old result and delivers a fresh snapshot")
        environment.stop()
    }

    private static func captureCompletesBeforeTimerHandler() {
        let display = DesktopDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleTop: 576)
        let metadata = StalledWindowMetadata()
        var time: TimeInterval = 0
        let environment = DesktopEnvironment(windowMetadata: { metadata.read() }, displays: { [display] },
                                             primaryDisplayTop: { display.frame.maxY },
                                             applicationMetadata: { DesktopApplicationMetadata(dockPID: nil, supportPIDs: []) },
                                             watchdogTime: { time }, watchdogSchedule: { _ in .distantFuture })
        var snapshots: [DesktopSnapshot] = []
        var snapshotsAtTimeout: [Int] = []
        var failures = 0
        environment.onSnapshot = { snapshots.append($0) }
        environment.onCaptureTimeout = { snapshotsAtTimeout.append(snapshots.count) }
        environment.onCaptureUnavailable = { _ in failures += 1 }
        environment.start()
        wait(until: { !snapshots.isEmpty })
        expect(!snapshots.isEmpty, "the watchdog completion fixture needs an initial snapshot")

        // The timer is unscheduled and the monotonic clock advances explicitly,
        // so only completion can report the expired deadline.
        for mode in [0, 1, 2, 3] {
            metadata.blockNext(returningNil: mode == 1)
            environment.refresh()
            wait(until: { metadata.isBlocked })
            if mode == 2 { environment.invalidate() }
            if mode == 3 { environment.stop(); environment.start() }
            let before = snapshots.count
            let previousTimeouts = snapshotsAtTimeout.count
            let previousReads = metadata.readCount
            time += 0.6
            metadata.unblock()
            wait(until: { snapshotsAtTimeout.count > previousTimeouts && snapshots.count > before })
            expect(snapshotsAtTimeout.count == previousTimeouts + 1 && snapshotsAtTimeout.last == before,
                   "completion past the deadline reports exactly one timeout before publishing any snapshot")
            expect(snapshots.count > before && metadata.readCount > previousReads && failures == 0,
                   "late success/nil and old generations are discarded before the fresh capture")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        expect(snapshotsAtTimeout.count == 4, "old queued timer events must not repeat timeouts after recovery")
        expect(metadata.maximumConcurrentReads == 1, "deadline completion must not create concurrent captures")
        environment.stop()
    }

    private static func lifecycle() {
        let environment = DesktopEnvironment()
        var generations: [UInt64] = []
        environment.onSnapshot = { snapshot in
            expect(Thread.isMainThread, "snapshot callback must be on main")
            generations.append(snapshot.generation)
        }
        environment.start()
        environment.invalidate()
        wait(until: { !generations.isEmpty })
        expect(!generations.isEmpty, "capture should finish even with zero available screens")
        expect(generations.allSatisfy { $0 == 2 }, "invalidation must discard the first in-flight generation")
        let beforeExclusion = generations.count
        environment.excludedWindowIDs = [123]
        wait(until: { generations.count > beforeExclusion })
        expect(generations.last == 3, "changing overlay exclusions invalidates pending snapshots")
        environment.excludedWindowIDs = [123]
        environment.stop()
        let stoppedCount = generations.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        expect(generations.count == stoppedCount, "no periodic captures or callbacks after stop")
        environment.refresh()
        environment.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(generations.count == stoppedCount, "refresh and repeated stop while stopped are inert")
        environment.start()
        environment.start()
        wait(until: { generations.count > stoppedCount })
        expect(generations.count > stoppedCount, "restart resumes captures")
        expect(generations.last == 5, "start, stop and assigning the same exclusions must be idempotent")
        environment.stop()
    }

    private static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
