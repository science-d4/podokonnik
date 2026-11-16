import AppKit
import ApplicationServices

/// Reads window metadata only. No screen images, window titles, input taps or private APIs.
/// Public entry points and snapshot delivery are confined to the main queue.
final class DesktopEnvironment {
    var onSnapshot: ((DesktopSnapshot) -> Void)?
    var onCaptureUnavailable: ((TimeInterval) -> Void)?
    var onCaptureTimeout: (() -> Void)?
    /// Exclude only our full-screen effect windows. Other own windows (onboarding,
    /// popovers, menus) still occlude snow and never become accumulation surfaces.
    var excludedWindowIDs: Set<UInt32> = [] {
        didSet {
            if oldValue != excludedWindowIDs { invalidate() }
        }
    }

    private let queue = DispatchQueue(label: "ru.snezhno.desktop", qos: .userInitiated)
    private let dockQueue = DispatchQueue(label: "ru.snezhno.desktop.dock", qos: .userInitiated)
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationCache = DesktopApplicationCache()
    // Accessed only by the serial capture queue; generation is part of its key.
    private let notificationGeometryCache = DesktopNotificationGeometryCache()
    private let dockGeometryCache = DesktopDockGeometryCache()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var inFlight = false
    private var refreshPending = false
    private var generation: UInt64 = 0
    private var cancellation: DesktopCaptureCancellation?
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdogSourceID: UUID?
    private var captureWatchdog = DesktopCaptureWatchdog()
    private var captureTimedOut = false
    private var captureStartedAt: TimeInterval = 0
    private var lastDock: SnowSurface?
    private var lastDockPID: pid_t?
    private var previousFrames: [String: CGRect] = [:]
    private var trackedWindowSupports: [UInt32: pid_t] = [:]
    private var focusPolicy = DesktopFocusPolicy()
    private var captureTiming = DesktopCaptureTiming()
    private let windowMetadata: () -> [[String: Any]]?
    private let displays: () -> [DesktopDisplay]
    private let primaryDisplayTop: () -> CGFloat
    private let applicationMetadata: () -> DesktopApplicationMetadata
    private let frontmostApplication: () -> DesktopFrontmostApplication
    private let watchdogTime: () -> TimeInterval
    private let watchdogSchedule: (TimeInterval) -> DispatchTime

    init(windowMetadata: @escaping () -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }, displays: @escaping () -> [DesktopDisplay] = {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DesktopDisplay(id: number.uint32Value, frame: screen.frame, visibleTop: screen.visibleFrame.maxY)
        }
    }, primaryDisplayTop: @escaping () -> CGFloat = { NSScreen.screens.first?.frame.maxY ?? 0 },
       applicationMetadata: @escaping () -> DesktopApplicationMetadata = {
        DesktopApplicationMetadata.read(NSWorkspace.shared.runningApplications)
    }, frontmostApplication: @escaping () -> DesktopFrontmostApplication = {
        let application = NSWorkspace.shared.frontmostApplication
        return DesktopFrontmostApplication(pid: application?.processIdentifier, bundleIdentifier: application?.bundleIdentifier)
    }, watchdogTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       watchdogSchedule: @escaping (TimeInterval) -> DispatchTime = { .now() + $0 }) {
        self.windowMetadata = windowMetadata
        self.displays = displays
        self.primaryDisplayTop = primaryDisplayTop
        self.applicationMetadata = applicationMetadata
        self.frontmostApplication = frontmostApplication
        self.watchdogTime = watchdogTime
        self.watchdogSchedule = watchdogSchedule
    }

    /// A button press starts polling, but rendering accelerates only after a
    /// retained surface has actually changed its geometry.
    var isGeometryMoving: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return running && captureTiming.isGeometryMoving(at: ProcessInfo.processInfo.systemUptime)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        running = true
        generation &+= 1
        captureTiming.reset()
        focusPolicy = DesktopFocusPolicy()
        previousFrames.removeAll()
        applicationCache.invalidate()
        observeApplications()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        let watchdogID = UUID()
        watchdogSourceID = watchdogID
        watchdog.setEventHandler { [weak self] in self?.captureWatchdogFired(sourceID: watchdogID) }
        watchdogTimer = watchdog
        watchdog.schedule(deadline: .distantFuture)
        watchdog.resume()
        refresh()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running else { return }
        running = false
        generation &+= 1
        cancellation?.cancel()
        captureWatchdog.reset()
        watchdogSourceID = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        timer?.cancel()
        timer = nil
        refreshPending = false
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        applicationCache.invalidate()
        // An already executing CG call cannot be cancelled. Its result is discarded;
        // keeping inFlight set prevents a stopped/started instance queuing more work.
    }

    func invalidate() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        applicationCache.invalidate()
        cancellation?.cancel()
        previousFrames.removeAll()
        captureTiming.noteProbe(at: ProcessInfo.processInfo.systemUptime)
        refresh()
    }

    /// Called by the existing render tick. A press only starts a short probe;
    /// holding a button without geometric motion must not keep CG polling fast.
    func noteInteraction() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running else { return }
        if captureTiming.noteInteraction(pressed: NSEvent.pressedMouseButtons != 0,
                                         at: ProcessInfo.processInfo.systemUptime) {
            refresh()
        }
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running else { return }
        guard !inFlight else {
            refreshPending = true
            // A previous-generation call can still be executing after a restart.
            // It blocks the next capture, so the wait also needs a watchdog.
            if !displays().isEmpty { startCaptureWatchdog() }
            return
        }
        timer?.schedule(deadline: .distantFuture)
        captureTiming.captureStarted(at: ProcessInfo.processInfo.systemUptime)

        let displays = self.displays()
        // NSScreen.screens[0] is the primary/menu-bar display, not NSScreen.main
        // (which changes with the key window). Quartz's Y origin is its top edge.
        let primaryTop = primaryDisplayTop()
        // activationPolicy/isHidden fetch dynamic process properties. Cache those
        // separately from fast window geometry, expiring them within one second.
        let applications = applicationCache.snapshot(now: ProcessInfo.processInfo.systemUptime, load: applicationMetadata)
        let token = DesktopCaptureCancellation()
        let frontmost = frontmostApplication()
        let context = DesktopCaptureContext(
            generation: generation, displays: displays, primaryTop: primaryTop,
            ownPID: ProcessInfo.processInfo.processIdentifier, dockPID: applications.dockPID,
            frontmost: frontmost,
            supportPIDs: applications.supportPIDs, notificationCenterPIDs: applications.notificationCenterPIDs,
            // A newly launched WindowManager must not wait for the one-second
            // general application-cache expiry during Mission Control entry.
            windowManagerPIDs: applications.windowManagerPIDs.union(
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager")
                    .map(\.processIdentifier)),
            excludedWindowIDs: excludedWindowIDs, trackedWindowSupports: trackedWindowSupports
        )
        inFlight = true
        refreshPending = false
        cancellation = token
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        captureTimedOut = false
        if !displays.isEmpty { startCaptureWatchdog() }
        let notificationCache = notificationGeometryCache
        let dockCache = dockGeometryCache, dockQueue = dockQueue, captureQueue = queue
        let windowMetadata = windowMetadata
        queue.async { [weak self] in
            let result = DesktopCapture.capture(context, cancellation: token, notificationCache: notificationCache,
                                                dockCache: dockCache, dockQueue: dockQueue, captureQueue: captureQueue,
                                                windowMetadata: windowMetadata) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.running, self.generation == context.generation else { return }
                    self.refresh()
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.complete(result, context: context, cancellation: token)
            }
        }
    }

    static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    private func observeApplications() {
        for name in DesktopApplicationCache.workspaceNotifications {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, self.running else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.applicationCache.handle(notification.name, pid: application?.processIdentifier,
                                             at: ProcessInfo.processInfo.systemUptime) { pid in
                    // Reconcile current state, not the event's old application object:
                    // a delayed termination/hide can arrive after the PID was reused.
                    guard let current = NSRunningApplication(processIdentifier: pid) else {
                        return DesktopApplicationMetadata(dockPID: nil, supportPIDs: [])
                    }
                    return DesktopApplicationMetadata.read([current])
                }
                if notification.name == NSWorkspace.didActivateApplicationNotification {
                    // Activation can lead the Space notification. Poll through
                    // that animation even if the first list still shows the old Space.
                    self.captureTiming.noteProbe(at: ProcessInfo.processInfo.systemUptime)
                }
                self.refresh()
            })
        }
    }

    /// Only invoke from the user's explicit permission button, never from polling.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func complete(_ result: DesktopCaptureResult?, context: DesktopCaptureContext,
                          cancellation token: DesktopCaptureCancellation) {
        // Completion can reach the main queue ahead of an already-due timer.
        let deadlineExpired = captureWatchdog.expired(at: watchdogTime())
        inFlight = false
        cancellation = nil
        captureWatchdog.reset()
        watchdogTimer?.schedule(deadline: .distantFuture)
        let timedOut = captureTimedOut
        captureTimedOut = false
        guard running else { return }
        // A cancelled call can still block the current generation. If its wait
        // has expired, hide stale geometry before starting the replacement.
        if timedOut || deadlineExpired {
            if !timedOut { onCaptureTimeout?() }
            refresh()
            return
        }
        guard !token.isCancelled, context.generation == generation, let result else {
            refresh()
            return
        }
        // Do not publish a capture made for an application that lost focus
        // while WindowServer was being queried.
        guard context.frontmost == frontmostApplication() else {
            refresh()
            return
        }
        if !result.hasWindowMetadata && !context.displays.isEmpty {
            // No geometry is better than an incomplete snapshot: the latter
            // deletes the Dock and loses all window occlusion masks.
            let now = ProcessInfo.processInfo.systemUptime
            let delay = max(0.05, captureTiming.delayAfterCapture(at: now))
            timer?.schedule(deadline: .now() + delay, leeway: .milliseconds(8))
            refreshPending = false
            onCaptureUnavailable?(max(0, now - captureStartedAt))
            return
        }
        var snapshot = result.snapshot
        focusPolicy.apply(to: &snapshot.surfaces, frontmostBundleIdentifier: context.frontmost.bundleIdentifier)
        if result.hasWindowMetadata {
            if snapshot.missionControlActive {
                trackedWindowSupports.merge(result.windowSupports) { _, current in current }
            } else {
                trackedWindowSupports = result.windowSupports
            }
        } else {
            // A failed metadata read gives no evidence that an existing window closed.
            snapshot.hiddenWindowSupportIDs = Set(trackedWindowSupports.map {
                DesktopGeometry.windowSupportID(pid: $0.value, id: $0.key)
            })
        }

        if let dock = snapshot.surfaces.first(where: { $0.kind == .dock }) {
            lastDock = dock
            lastDockPID = context.dockPID
        } else if result.hasWindowMetadata, let pid = context.dockPID, pid == lastDockPID, var dock = lastDock {
            // Preserve snow through autohide without inventing a visible Dock surface.
            dock.isVisible = false
            snapshot.surfaces.append(dock)
        } else {
            lastDock = nil
            lastDockPID = nil
        }

        let now = ProcessInfo.processInfo.systemUptime
        let frames = Dictionary(uniqueKeysWithValues: snapshot.surfaces.map { ($0.id, $0.frame) })
        if frames.contains(where: { id, frame in previousFrames[id].map { $0 != frame } ?? false }) {
            captureTiming.noteMotion(at: now)
        } else if frames != previousFrames {
            captureTiming.noteProbe(at: now)
        }
        previousFrames = frames
        // Measure cadence from capture start. Slow captures coalesce into one
        // immediate next capture, never a burst of missed timer firings.
        let delay = captureTiming.delayAfterCapture(at: now)
        let fast = captureTiming.interval(at: now) < 0.15
        timer?.schedule(deadline: .now() + delay, leeway: .milliseconds(fast ? 1 : 8))
        let needsAnother = refreshPending
        refreshPending = false
        onSnapshot?(snapshot)
        if needsAnother && running { refresh() }
    }

    private func startCaptureWatchdog() {
        guard captureWatchdog.arm(at: watchdogTime()) else { return }
        watchdogTimer?.schedule(deadline: watchdogSchedule(0.5))
    }

    private func captureWatchdogFired(sourceID: UUID) {
        guard watchdogSourceID == sourceID, running, inFlight,
              let remaining = captureWatchdog.consume(at: watchdogTime()) else { return }
        // An old event can already be queued when a new capture is armed.
        if remaining > 0 {
            watchdogTimer?.schedule(deadline: watchdogSchedule(remaining))
            return
        }
        watchdogTimer?.schedule(deadline: .distantFuture)
        captureTimedOut = true
        onCaptureTimeout?()
    }

    deinit {
        cancellation?.cancel()
        timer?.cancel()
        watchdogTimer?.cancel()
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
    }
}

/// Deadline state is independent of dispatch-source events, which can arrive
/// late after a previous capture was cancelled and a new one was armed.
struct DesktopCaptureWatchdog {
    private var deadline: TimeInterval?
    private var fired = false

    mutating func reset() { deadline = nil; fired = false }

    mutating func arm(at time: TimeInterval) -> Bool {
        guard deadline == nil && !fired else { return false }
        deadline = time + 0.5
        return true
    }

    func expired(at time: TimeInterval) -> Bool {
        deadline.map { time >= $0 } ?? fired
    }

    /// Returns remaining seconds, zero for the one timeout, or nil if disarmed.
    mutating func consume(at time: TimeInterval) -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline - time
        guard remaining <= 0 else { return remaining }
        self.deadline = nil
        fired = true
        return 0
    }
}

/// Uses the same monotonic clock as capture. No catch-up debt survives a slow call.
struct DesktopCaptureTiming {
    private var startedAt: TimeInterval?
    private var fastUntil: TimeInterval = -.infinity
    private var geometryMovingUntil: TimeInterval = -.infinity
    private var wasPressed = false

    mutating func reset() { startedAt = nil; fastUntil = -.infinity; geometryMovingUntil = -.infinity; wasPressed = false }
    mutating func captureStarted(at time: TimeInterval) { startedAt = time }
    mutating func noteProbe(at time: TimeInterval) { fastUntil = time + 0.65 }
    mutating func noteMotion(at time: TimeInterval) {
        noteProbe(at: time)
        geometryMovingUntil = time + 0.65
    }
    mutating func noteInteraction(pressed: Bool, at time: TimeInterval) -> Bool {
        let rising = pressed && !wasPressed
        wasPressed = pressed
        if rising { noteProbe(at: time) }
        return rising
    }
    func isGeometryMoving(at time: TimeInterval) -> Bool { time < geometryMovingUntil }
    func interval(at time: TimeInterval) -> TimeInterval { time < fastUntil ? 1.0 / 120 : 0.15 }
    func delayAfterCapture(at time: TimeInterval) -> TimeInterval {
        max(0, (startedAt ?? time) + interval(at: time) - time)
    }
}

struct DesktopDockGeometryKey: Equatable {
    var generation: UInt64
    var pid: pid_t
    var windowIDs: [UInt32]
    var canvases: [CGRect]
    var displays: [CGRect]
    var primaryTop: CGFloat

    var canonical: Self {
        var result = self
        let pairs = zip(windowIDs, canvases).sorted { $0.0 < $1.0 }
        result.windowIDs = pairs.map(\.0); result.canvases = pairs.map(\.1)
        return result
    }

    func hasSameContext(as other: Self) -> Bool {
        generation == other.generation && pid == other.pid && displays == other.displays && primaryTop == other.primaryTop
    }

    func corroborates(_ frame: CGRect) -> Bool {
        canvases.contains { $0.insetBy(dx: -4, dy: -4).contains(frame) }
    }
}

enum DesktopDockReadResult: Equatable {
    case visible(CGRect), hidden, unavailable

    static func geometry(listFrame: CGRect, itemFrames: [CGRect?]?) -> Self {
        guard DesktopGeometry.valid(listFrame), let itemFrames, !itemFrames.isEmpty,
              itemFrames.allSatisfy({ $0.map(DesktopGeometry.valid) == true }) else { return .unavailable }
        return .visible(DesktopGeometry.dockSupportFrame(for: listFrame, itemFrames: itemFrames.compactMap { $0 }))
    }
}

/// Accessed on the serial capture queue, including asynchronous completions.
/// The separate AX worker never reads or writes this state directly.
final class DesktopDockGeometryCache {
    struct Request {
        fileprivate let id: UInt64
        fileprivate let keyEpoch: UInt64
        let key: DesktopDockGeometryKey
        let startedAt: TimeInterval
    }
    private var key: DesktopDockGeometryKey?
    private var value: CGRect?
    private var lastAttemptAt: TimeInterval = -.infinity
    private var lastSuccessAt: TimeInterval = -.infinity
    private(set) var hasAuthoritativeResult = false
    private var inFlight: UInt64?
    private var nextID: UInt64 = 0
    private var keyEpoch: UInt64 = 0

    func snapshot(key: DesktopDockGeometryKey?, at time: TimeInterval) -> CGRect? {
        let key = key?.canonical
        if self.key != key {
            let sameContext = self.key.flatMap { previous in key.map { previous.hasSameContext(as: $0) } } == true
            let retain = sameContext && currentValue(at: time).map { key?.corroborates($0) == true } == true
            keyEpoch &+= 1
            self.key = key
            if !retain { value = nil; lastSuccessAt = -.infinity }
            if !sameContext {
                lastAttemptAt = -.infinity
                hasAuthoritativeResult = false
            }
        }
        return currentValue(at: time)
    }

    func requestIfNeeded(at time: TimeInterval) -> Request? {
        // Refresh ahead of the 150 ms idle cadence: variable CG duration can
        // otherwise turn a 149 ms tick into a missed refresh and a stale shelf.
        guard let key, inFlight == nil,
              time < lastAttemptAt || time - lastAttemptAt >= 0.125 else { return nil }
        nextID &+= 1
        inFlight = nextID
        lastAttemptAt = time
        return Request(id: nextID, keyEpoch: keyEpoch, key: key, startedAt: time)
    }

    func resolvedFrame(cgFallback: CGRect?, at time: TimeInterval) -> CGRect? {
        if let frame = currentValue(at: time) { return frame }
        // Confirmed AX hidden/expired geometry must never fall back to a coarser
        // CG strip. Before the first complete AX result, a real CG strip is usable.
        return hasAuthoritativeResult ? nil : cgFallback
    }

    /// True only when the visible geometry actually changes. Identical and
    /// negative refreshes must not schedule a second idle CG capture each TTL.
    func complete(_ request: Request, result: DesktopDockReadResult, at time: TimeInterval) -> Bool {
        guard inFlight == request.id else { return false }
        inFlight = nil
        guard keyEpoch == request.keyEpoch, key == request.key else { return false }
        let previous = currentValue(at: time)
        let firstHidden = result == .hidden && !hasAuthoritativeResult
        switch result {
        case .visible(let frame):
            guard DesktopGeometry.valid(frame), request.key.corroborates(frame) else { return false }
            value = frame; lastSuccessAt = time; hasAuthoritativeResult = true
        case .hidden:
            value = nil; lastSuccessAt = -.infinity; hasAuthoritativeResult = true
        case .unavailable:
            break // A failed read neither hides good geometry nor renews its age.
        }
        return firstHidden || previous != currentValue(at: time)
    }

    private func currentValue(at time: TimeInterval) -> CGRect? {
        // Bound stale geometry even if WindowServer or the delivery queue stalls.
        guard key != nil, time >= lastSuccessAt, time - lastSuccessAt <= 0.5 else { return nil }
        return value
    }
}

struct DesktopApplicationMetadata {
    var dockPID: pid_t?
    var supportPIDs: Set<pid_t>
    var notificationCenterPIDs: Set<pid_t> = []
    var windowManagerPIDs: Set<pid_t> = []

    static func read(_ applications: [NSRunningApplication]) -> Self {
        var result = Self(dockPID: nil, supportPIDs: [])
        for application in applications {
            let bundle = application.bundleIdentifier
            let isDock = bundle == "com.apple.dock"
            let isNotificationCenter = bundle == "com.apple.notificationcenterui"
            let isWindowManager = bundle == "com.apple.WindowManager"
            let visibleRegular = application.activationPolicy == .regular && !application.isHidden
            let terminated = (visibleRegular || isNotificationCenter || isDock || isWindowManager) ? application.isTerminated : false
            guard !terminated && (isDock || isNotificationCenter || isWindowManager || visibleRegular) else { continue }
            let pid = application.processIdentifier
            if isDock && result.dockPID == nil { result.dockPID = pid }
            if isNotificationCenter { result.notificationCenterPIDs.insert(pid) }
            if isWindowManager { result.windowManagerPIDs.insert(pid) }
            if visibleRegular { result.supportPIDs.insert(pid) }
        }
        return result
    }
}

/// Retains values only. Events reconcile one current PID without extending the
/// one-second full-refresh deadline; expiry catches missed events/policy changes.
struct DesktopApplicationCache {
    static let workspaceNotifications: [Notification.Name] = [
        NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
        NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
        NSWorkspace.didUnhideApplicationNotification
    ]
    private var value: DesktopApplicationMetadata?
    private var fetchedAt: TimeInterval = -.infinity

    mutating func invalidate() { value = nil }

    mutating func handle(_ name: Notification.Name, pid: pid_t?, at time: TimeInterval,
                         load: (pid_t) -> DesktopApplicationMetadata) {
        guard Self.workspaceNotifications.contains(name) else { return }
        guard var current = value, time >= fetchedAt, time - fetchedAt < 1,
              let pid, pid > 0 else { invalidate(); return }
        let fresh = load(pid)
        current.supportPIDs.remove(pid)
        current.notificationCenterPIDs.remove(pid)
        current.windowManagerPIDs.remove(pid)
        if current.dockPID == pid { current.dockPID = nil }
        if fresh.supportPIDs.contains(pid) { current.supportPIDs.insert(pid) }
        if fresh.notificationCenterPIDs.contains(pid) { current.notificationCenterPIDs.insert(pid) }
        if fresh.windowManagerPIDs.contains(pid) { current.windowManagerPIDs.insert(pid) }
        if fresh.dockPID == pid { current.dockPID = pid }
        value = current
    }

    mutating func snapshot(now: TimeInterval, load: () -> DesktopApplicationMetadata) -> DesktopApplicationMetadata {
        if let value, now >= fetchedAt, now - fetchedAt < 1 { return value }
        let fresh = load()
        value = fresh
        fetchedAt = now
        return fresh
    }
}

struct DesktopNotificationCanvas: Equatable {
    var id: UInt32
    var pid: pid_t
    var frame: CGRect
}

/// AX geometry changes more slowly than window polling. Cache failures as well,
/// so a temporarily busy Notification Center cannot cause AX IPC every 35 ms.
final class DesktopNotificationGeometryCache {
    private var generation: UInt64?
    private var canvases: [DesktopNotificationCanvas] = []
    private var fetchedAt: TimeInterval = -.infinity
    private var value: [UInt32: [CGRect]] = [:]

    func snapshot(generation: UInt64, canvases: [DesktopNotificationCanvas], now: TimeInterval,
                  load: () -> [UInt32: [CGRect]]) -> [UInt32: [CGRect]] {
        guard !canvases.isEmpty else {
            self.generation = nil
            self.canvases = []
            value = [:]
            return [:]
        }
        if self.generation == generation, self.canvases == canvases,
           now >= fetchedAt, now - fetchedAt < 0.5 { return value }
        value = load()
        self.generation = generation
        self.canvases = canvases
        fetchedAt = now
        return value
    }
}

struct DesktopDisplay {
    let id: UInt32
    let frame: CGRect
    let visibleTop: CGFloat
}

struct DesktopFrontmostApplication: Equatable {
    let pid: pid_t?
    let bundleIdentifier: String?
}

/// Spotlight temporarily owns keyboard focus without replacing the underlying
/// ordinary window. Keep its snowfall state only while that exact window exists.
struct DesktopFocusPolicy {
    private var lastActiveWindowID: String?

    mutating func apply(to surfaces: inout [SnowSurface], frontmostBundleIdentifier: String?) {
        if frontmostBundleIdentifier == "com.apple.Spotlight" {
            for index in surfaces.indices { surfaces[index].suppressesSnowfall = false }
            guard let id = lastActiveWindowID,
                  let index = surfaces.firstIndex(where: { $0.kind == .window && $0.isVisible && $0.id == id }) else {
                lastActiveWindowID = nil
                return
            }
            surfaces[index].suppressesSnowfall = true
        } else {
            lastActiveWindowID = surfaces.first(where: { $0.kind == .window && $0.isVisible && $0.suppressesSnowfall })?.id
        }
    }
}

private struct DesktopCaptureContext {
    let generation: UInt64
    let displays: [DesktopDisplay]
    let primaryTop: CGFloat
    let ownPID: pid_t
    let dockPID: pid_t?
    let frontmost: DesktopFrontmostApplication
    let supportPIDs: Set<pid_t>
    let notificationCenterPIDs: Set<pid_t>
    let windowManagerPIDs: Set<pid_t>
    let excludedWindowIDs: Set<UInt32>
    let trackedWindowSupports: [UInt32: pid_t]
}

private final class DesktopCaptureCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct DesktopWindowRecord {
    let id: UInt32
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let frame: CGRect
}

private struct DesktopCaptureResult {
    var snapshot: DesktopSnapshot
    let hasWindowMetadata: Bool
    var windowSupports: [UInt32: pid_t] = [:]
}

private enum DesktopCapture {
    static func capture(_ context: DesktopCaptureContext,
                        cancellation: DesktopCaptureCancellation,
                        notificationCache: DesktopNotificationGeometryCache,
                        dockCache: DesktopDockGeometryCache, dockQueue: DispatchQueue, captureQueue: DispatchQueue,
                        windowMetadata: () -> [[String: Any]]?,
                        onDockChange: @escaping () -> Void) -> DesktopCaptureResult? {
        guard !cancellation.isCancelled else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        let trusted = DesktopEnvironment.accessibilityTrusted()
        guard !context.displays.isEmpty else {
            _ = dockCache.snapshot(key: nil, at: start)
            return DesktopCaptureResult(snapshot: DesktopSnapshot(generation: context.generation, surfaces: [], fullscreenDisplayIDs: [],
                                   accessibilityTrusted: trusted, dockDetected: false, windowCount: 0,
                                   captureMilliseconds: 0), hasWindowMetadata: false)
        }
        // Extract only geometric metadata. We never access kCGWindowName,
        // kCGWindowOwnerName, sharing state or image APIs.
        let metadata = windowMetadata()
        guard !cancellation.isCancelled else { return nil }
        guard let metadata else {
            return DesktopCaptureResult(snapshot: DesktopSnapshot(generation: context.generation, surfaces: [], fullscreenDisplayIDs: [],
                                       accessibilityTrusted: trusted, dockDetected: false, windowCount: 0,
                                       captureMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000),
                                        hasWindowMetadata: false)
        }
        let records = metadata.compactMap { dictionary -> DesktopWindowRecord? in
            guard let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (dictionary[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !context.excludedWindowIDs.contains(id),
                  let bounds = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds),
                  let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  DesktopGeometry.isSnowOccluder(layer: layer, alpha: alpha) else { return nil }
            let frame = WorldCoordinates.fromQuartz(quartzFrame, primaryHeight: context.primaryTop)
            guard DesktopGeometry.valid(frame), context.displays.contains(where: { $0.frame.intersects(frame) }) else { return nil }
            return DesktopWindowRecord(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame)
        }

        let displayFrames = context.displays.map(\.frame)
        let missionControlActive = records.contains { record in
            DesktopGeometry.isMissionControlWindow(record.frame, layer: record.layer,
                windowManager: context.windowManagerPIDs.contains(record.pid),
                displays: displayFrames)
        }
        let notificationCanvases = records.compactMap { record -> DesktopNotificationCanvas? in
            guard DesktopGeometry.isNotificationCenterCanvas(record.frame, layer: record.layer,
                notificationCenter: context.notificationCenterPIDs.contains(record.pid), displays: displayFrames) else { return nil }
            return DesktopNotificationCanvas(id: record.id, pid: record.pid, frame: record.frame)
        }
        let notificationMasks = notificationCache.snapshot(generation: context.generation, canvases: notificationCanvases,
                                                           now: ProcessInfo.processInfo.systemUptime) {
            guard trusted, !cancellation.isCancelled else { return [:] }
            return DesktopNotificationAccessibility.frames(canvases: notificationCanvases, primaryTop: context.primaryTop,
                                                           cancellation: cancellation)
        }
        let notificationCanvasIDs = Set(notificationCanvases.map(\.id))

        // On newer macOS the Dock's CG window can be a transparent full-display
        // canvas. Its scalar alpha does not describe pixel opacity or shelf bounds.
        // Only a real edge strip or corroborated AX bounds can become a surface.
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let dockWindows = records.filter { $0.pid == context.dockPID && $0.layer == dockLevel }
        let dockCandidates = dockWindows.filter { DesktopGeometry.isDock($0.frame, displays: context.displays.map(\.frame)) }
        var dockRecord = dockCandidates.max { area($0.frame) < area($1.frame) }
        var dockFrame = dockRecord.map { DesktopGeometry.dockSupportFrame(for: $0.frame, itemFrames: []) }
        let dockKey = trusted && !dockWindows.isEmpty ? context.dockPID.map {
            DesktopDockGeometryKey(generation: context.generation, pid: $0, windowIDs: dockWindows.map(\.id),
                                   canvases: dockWindows.map(\.frame), displays: displayFrames, primaryTop: context.primaryTop)
        } : nil
        let dockTime = ProcessInfo.processInfo.systemUptime
        _ = dockCache.snapshot(key: dockKey, at: dockTime)
        dockFrame = dockCache.resolvedFrame(cgFallback: dockFrame, at: dockTime)
        dockRecord = dockFrame.flatMap { frame in
            dockWindows.first { $0.frame.insetBy(dx: -4, dy: -4).contains(frame) }
        }
        if let request = dockCache.requestIfNeeded(at: dockTime) {
            dockQueue.async {
                let result = DesktopDockAccessibility.frame(pid: request.key.pid, context: context,
                    corroboratedBy: request.key.canvases, cancellation: cancellation)
                captureQueue.async {
                    if dockCache.complete(request, result: result, at: ProcessInfo.processInfo.systemUptime) {
                        onDockChange()
                    }
                }
            }
        }
        guard !cancellation.isCancelled else { return nil }

        var surfaces: [SnowSurface] = []
        var foreground: [CGRect] = []
        var floorForeground: [(frame: CGRect, ordinary: Bool)] = []
        var floorOverlays: [CGRect] = []
        var fullscreen: Set<UInt32> = []
        var examinedTopWindow: Set<UInt32> = []
        var windowSupports: [UInt32: pid_t] = [:]
        let screenshotCandidates = Set(records.filter {
            DesktopGeometry.canBeScreenshotWindow(layer: $0.layer, frame: $0.frame, displays: displayFrames)
        }.map(\.pid))
        let screenshotOwners = screenshotCandidates.filter(isScreenshotOwner(pid:))
        func isOrdinary(_ record: DesktopWindowRecord) -> Bool {
            record.pid != context.ownPID && record.layer == 0 && context.supportPIDs.contains(record.pid)
                && SnowSurface.meetsWindowSupportSize(record.frame) && record.alpha >= 0.8
        }
        let activeID = DesktopGeometry.activeWindowID(
            ordered: records.filter(isOrdinary).map { (id: $0.id, pid: $0.pid) }, frontmostPID: context.frontmost.pid)
        for record in records {
            if screenshotOwners.contains(record.pid) { continue }
            if notificationCanvasIDs.contains(record.id) {
                foreground.append(contentsOf: notificationMasks[record.id] ?? [])
                floorForeground.append(contentsOf: (notificationMasks[record.id] ?? []).map { (frame: $0, ordinary: false) })
                floorOverlays.append(contentsOf: notificationMasks[record.id] ?? [])
                // A scalar-alpha-one NC canvas contains transparent pixels over
                // the desktop. AX supplies only the actual content rectangles.
                // If AX is unavailable, native NC windows above our floating
                // overlay still occlude their content; never mask the full screen.
                continue
            }
            if record.pid == context.dockPID && record.layer == dockLevel {
                if record.id == dockRecord?.id, let frame = dockFrame, let pid = context.dockPID {
                    var surface = SnowSurface(id: "dock:\(pid)", frame: frame, kind: .dock,
                                              occluders: foreground)
                    surface.topInset = DesktopGeometry.dockTopInset(for: frame)
                    surfaces.append(surface)
                    // The native Dock is above our floating overlay. Its own
                    // rounded glass silhouette occludes the snow; a rectangular
                    // mask here would cut square holes into the floor drift.
                }
                // Never let the transparent Dock canvas mask every ordinary window.
                continue
            }
            // The compositor draws native pop-up menus above the floating overlay.
            // Their CG bounds also include transparent margins and shadows.
            if DesktopGeometry.usesNativeMenuOcclusion(layer: record.layer) { continue }

            let ordinary = isOrdinary(record)
            if ordinary {
                for display in context.displays where record.frame.intersects(display.frame) {
                    if !examinedTopWindow.contains(display.id) {
                        examinedTopWindow.insert(display.id)
                        if DesktopGeometry.coversDisplay(record.frame, display.frame) { fullscreen.insert(display.id) }
                    }
                }
                let ceilingMasks = context.displays.compactMap { display in
                    DesktopGeometry.ceilingExclusion(for: record.frame, display: display.frame,
                                                     visibleTop: display.visibleTop)
                }
                windowSupports[record.id] = record.pid
                var surface = SnowSurface(id: DesktopGeometry.windowSupportID(pid: record.pid, id: record.id), frame: record.frame,
                                          kind: .window, occluders: foreground + ceilingMasks)
                surface.topInset = DesktopGeometry.windowTopInset(for: record.frame)
                surface.bodyOccluders = foreground
                surface.suppressesSnowfall = record.id == activeID
                surfaces.append(surface)
            }
            foreground.append(record.frame)
            floorForeground.append((frame: record.frame, ordinary: ordinary))
            if record.layer != 0 || (!context.supportPIDs.contains(record.pid) && record.pid != context.ownPID) {
                floorOverlays.append(record.frame)
            }
        }
        for display in context.displays {
            let floor = CGRect(x: display.frame.minX, y: display.frame.minY - 1, width: display.frame.width, height: 1)
            let occluders = floorForeground.compactMap {
                WideWindowPolicy.floorOccluder($0.frame, ordinaryWindow: $0.ordinary, display: display.frame)
            }
            var surface = SnowSurface(id: "floor:\(display.id)", frame: floor, kind: .floor, occluders: occluders)
            // A minimization can shrink an ordinary window below the size needed
            // for a snow shelf. Only real overlays should block the duck's floor.
            surface.floorOverlayOccluders = floorOverlays
            surfaces.append(surface)
        }
        let missing = context.trackedWindowSupports.filter { windowSupports[$0.key] == nil }
        var hiddenSupportIDs: Set<String> = []
        if !missing.isEmpty {
            let windowInventory = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
            guard !cancellation.isCancelled else { return nil }
            // A nil inventory is transient. Retry on the next poll.
            let surviving = windowInventory.map { DesktopGeometry.survivingWindowSupports(missing, in: $0) } ?? missing
            for (id, pid) in surviving {
                windowSupports[id] = pid
                hiddenSupportIDs.insert(DesktopGeometry.windowSupportID(pid: pid, id: id))
            }
        }
        return DesktopCaptureResult(snapshot: DesktopSnapshot(generation: context.generation, surfaces: surfaces,
                               fullscreenDisplayIDs: fullscreen, accessibilityTrusted: trusted,
                               dockDetected: dockFrame != nil,
                               windowCount: surfaces.filter { $0.kind == .window }.count,
                               captureMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                               hiddenWindowSupportIDs: hiddenSupportIDs,
                               screenshotSelectionActive: !screenshotOwners.isEmpty,
                               missionControlActive: missionControlActive),
                                    hasWindowMetadata: true, windowSupports: windowSupports)
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func isScreenshotOwner(pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = String(cString: path)
        return executable == "/usr/sbin/screencapture"
            || executable == "/System/Library/CoreServices/screencaptureui.app/Contents/MacOS/screencaptureui"
    }
}

/// Pure bounds rules, independent of WindowServer and Accessibility permission.
enum DesktopGeometry {
    /// This is a WindowServer geometry heuristic, not an OS-provided mode flag.
    static func isMissionControlWindow(_ frame: CGRect, layer: Int, windowManager: Bool,
                                       displays: [CGRect]) -> Bool {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        guard windowManager && layer == dockLevel - 1 else { return false }
        return displays.contains { coversDisplay(frame, $0) }
    }
    static func windowSupportID(pid: pid_t, id: UInt32) -> String { "window:\(pid):\(id)" }

    static func survivingWindowSupports(_ previous: [UInt32: pid_t], in inventory: [[String: Any]]) -> [UInt32: pid_t] {
        var surviving: [UInt32: pid_t] = [:]
        for window in inventory {
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = previous[id],
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { continue }
            surviving[id] = pid
        }
        return surviving
    }

    static func usesNativeMenuOcclusion(layer: Int) -> Bool {
        layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
    }

    static func canBeScreenshotWindow(layer: Int, frame: CGRect, displays: [CGRect]) -> Bool {
        let assistiveLevel = Int(CGWindowLevelForKey(.assistiveTechHighWindow))
        guard (assistiveLevel - 2...assistiveLevel).contains(layer)
                || layer == Int(CGWindowLevelForKey(.mainMenuWindow)) else { return false }
        // A small window owned by Screenshot can outlive the selection canvas.
        return displays.contains { coversDisplay(frame.insetBy(dx: -8, dy: -8), $0) }
    }

    /// CG's public front-to-back order also changes when switching two normal
    /// windows of one app. This avoids inspecting titles or adding AX polling.
    static func activeWindowID(ordered: [(id: UInt32, pid: pid_t)], frontmostPID: pid_t?) -> UInt32? {
        guard let frontmostPID else { return nil }
        return ordered.first { $0.pid == frontmostPID }?.id
    }

    static func isSnowOccluder(layer: Int, alpha: Double) -> Bool {
        // CG exposes the system cursor's transparent backing window after hover.
        // Its rectangular bounds are not an opaque obstacle.
        alpha > 0.01 && layer >= 0 && layer != Int(CGWindowLevelForKey(.cursorWindow))
    }

    static func isNotificationCenterCanvas(_ frame: CGRect, layer: Int, notificationCenter: Bool,
                                           displays: [CGRect]) -> Bool {
        guard notificationCenter, layer > Int(CGWindowLevelForKey(.floatingWindow)), valid(frame) else { return false }
        return displays.contains { display in
            abs(frame.minX - display.minX) <= 2 && abs(frame.minY - display.minY) <= 2
                && abs(frame.maxX - display.maxX) <= 2 && abs(frame.maxY - display.maxY) <= 2
        }
    }

    static func notificationContentMask(_ frame: CGRect, scrollArea: CGRect, canvas: CGRect) -> CGRect? {
        guard valid(frame), valid(scrollArea), valid(canvas) else { return nil }
        let clipped = frame.intersection(scrollArea).intersection(canvas)
        guard valid(clipped), !coversDisplay(clipped, canvas) else { return nil }
        return clipped
    }

    static func windowTopInset(for frame: CGRect) -> CGFloat {
        min(16, max(0, frame.width / 4))
    }

    static func dockTopInset(for frame: CGRect) -> CGFloat {
        guard valid(frame) else { return 0 }
        // Dock caps scale with the short side, unlike ordinary window corners.
        // Keep two profile intervals on a narrow vertical Dock's upper edge.
        let roundedEnd = min(32, min(frame.width, frame.height) / 2)
        return min(roundedEnd, max(0, (frame.width - SnowDrift.spacing * 2) / 2))
    }

    static func dockSupportFrame(for listFrame: CGRect, itemFrames: [CGRect]) -> CGRect {
        guard valid(listFrame) else { return listFrame }
        let horizontal = listFrame.width >= listFrame.height
        let shortSide = min(listFrame.width, listFrame.height)
        let fallbackDrop = min(5, shortSide * 0.1)
        let maximumDrop = min(12, shortSide * 0.25)
        // Direct AXDockItem bounds include separators and magnified icons. Use
        // ordinary-sized items; they need not be contained by the AXList because
        // the observed item bottoms extend below the list by five points.
        let candidates = itemFrames.filter { item in
            guard valid(item), item.intersects(listFrame) else { return false }
            let across = horizontal ? item.height : item.width
            let along = horizontal ? item.width : item.height
            let center = horizontal ? item.midX : item.midY
            let lower = horizontal ? listFrame.minX : listFrame.minY
            let upper = horizontal ? listFrame.maxX : listFrame.maxY
            return across >= shortSide * 0.5 && across <= shortSide * 1.25
                && along >= shortSide * 0.4 && along <= shortSide * 1.25
                && center >= lower && center <= upper
        }
        let lengths = candidates.map { horizontal ? $0.width : $0.height }.sorted()
        var drop = fallbackDrop
        if lengths.count >= 2 {
            let middle = lengths.count / 2
            let typical = lengths.count.isMultiple(of: 2)
                ? (lengths[middle - 1] + lengths[middle]) / 2 : lengths[middle]
            let tops = candidates.filter {
                let length = horizontal ? $0.width : $0.height
                return length >= typical * 0.75 && length <= typical * 1.25
            }.map(\.maxY).sorted()
            if tops.count >= 2 {
                let middleTop = tops.count / 2
                // Vertical lists need their uppermost normal item, not the
                // median Y of every item halfway down the Dock.
                let anchor = horizontal
                    ? (tops.count.isMultiple(of: 2) ? (tops[middleTop - 1] + tops[middleTop]) / 2 : tops[middleTop])
                    : tops[tops.count - 1]
                let candidateDrop = listFrame.maxY - anchor
                if candidateDrop >= 0 && candidateDrop <= maximumDrop { drop = candidateDrop }
            }
        }
        // This small inward overlap is a contact policy, not a measured glass
        // frame or corner radius. Preserve the list's X range and bottom.
        return CGRect(x: listFrame.minX, y: listFrame.minY, width: listFrame.width,
                      height: listFrame.height - drop)
    }

    /// A maximized window remains an ordinary window: only its snow support is
    /// suppressed where the display has no room for a full drift above that edge.
    static func ceilingExclusion(for window: CGRect, display: CGRect, visibleTop: CGFloat) -> CGRect? {
        let top = window.maxY
        guard valid(window), valid(display), visibleTop.isFinite,
              window.maxX > display.minX, window.minX < display.maxX,
              top >= display.minY, top <= display.maxY,
              visibleTop - top < SnowDrift.maximumHeight + 6 else { return nil }
        // This mask belongs only to this surface. Cover the whole display width so
        // an attached ball's overhang cannot leave a small visible side fragment.
        // Adjacent displays keep their own independent clearance decision.
        let bottom = max(display.minY, top - 3)
        return CGRect(x: display.minX, y: bottom, width: display.width,
                      height: display.maxY - bottom)
    }

    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 1 && rect.height > 1 && rect.width < 100_000 && rect.height < 100_000
    }

    static func isDock(_ rect: CGRect, displays: [CGRect]) -> Bool {
        guard valid(rect) else { return false }
        return displays.contains { screen in
            let visible = rect.intersection(screen)
            guard !visible.isNull else { return false }
            let horizontal = rect.width >= 100 && rect.height >= 20 && rect.height < screen.height * 0.32
                && rect.width > rect.height * 1.5 && abs(rect.minY - screen.minY) <= 48
                && visible.height >= min(20, rect.height * 0.5)
            let vertical = rect.height >= 100 && rect.width >= 20 && rect.width < screen.width * 0.25
                && rect.height > rect.width * 1.5
                && (abs(rect.minX - screen.minX) <= 48 || abs(rect.maxX - screen.maxX) <= 48)
                && visible.width >= min(20, rect.width * 0.5)
            return horizontal || vertical
        }
    }

    static func coversDisplay(_ window: CGRect, _ screen: CGRect) -> Bool {
        // Strict borderless heuristic: a maximized window below the menu bar does
        // not count. Native fullscreen Spaces must also be excluded by NSWindow's
        // collectionBehavior; safe-area-only bounds cannot prove fullscreen.
        let tolerance: CGFloat = 2
        return window.minX <= screen.minX + tolerance && window.maxX >= screen.maxX - tolerance
            && window.minY <= screen.minY + tolerance && window.maxY >= screen.maxY - tolerance
    }
}

/// Reads roles and rectangles only, and only beneath a corroborated NC canvas.
/// In particular, it does not descend into notification text or widget content.
private final class DesktopNotificationAccessibility {
    private let cancellation: DesktopCaptureCancellation
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.12
    private let primaryTop: CGFloat
    private var visited = 0

    private init(primaryTop: CGFloat, cancellation: DesktopCaptureCancellation) {
        self.primaryTop = primaryTop
        self.cancellation = cancellation
    }

    static func frames(canvases: [DesktopNotificationCanvas], primaryTop: CGFloat,
                       cancellation: DesktopCaptureCancellation) -> [UInt32: [CGRect]] {
        let reader = DesktopNotificationAccessibility(primaryTop: primaryTop, cancellation: cancellation)
        var result: [UInt32: [CGRect]] = [:]
        for (pid, ownedCanvases) in Dictionary(grouping: canvases, by: \.pid) {
            let application = AXUIElementCreateApplication(pid)
            guard let windows = reader.attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] else { continue }
            for window in windows.prefix(16) {
                guard let frame = reader.geometry(window), let canvas = ownedCanvases.first(where: {
                    abs(frame.minX - $0.frame.minX) <= 2 && abs(frame.minY - $0.frame.minY) <= 2
                        && abs(frame.width - $0.frame.width) <= 2 && abs(frame.height - $0.frame.height) <= 2
                }) else { continue }
                result[canvas.id] = reader.contentFrames(window: window, canvas: canvas.frame)
            }
        }
        return result
    }

    private func contentFrames(window: AXUIElement, canvas: CGRect) -> [CGRect] {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var masks: [CGRect] = []
        while !queue.isEmpty, available, visited < 24 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = attribute(element, kAXRoleAttribute as CFString) as? String
            guard let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else { continue }
            if role == kAXScrollAreaRole, let scrollArea = geometry(element) {
                // The broad scroll/container bounds include transparent animation
                // space. Its immediate children describe visible panels/widgets.
                for child in children.prefix(24) where available {
                    guard let frame = geometry(child),
                          let mask = DesktopGeometry.notificationContentMask(frame, scrollArea: scrollArea, canvas: canvas) else { continue }
                    if !masks.contains(mask) { masks.append(mask) }
                }
                continue
            }
            if depth < 4 {
                queue.append(contentsOf: children.prefix(max(0, 24 - visited - queue.count)).map { ($0, depth + 1) })
            }
        }
        return masks
    }

    private var available: Bool { !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        guard available else { return nil }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, remaining))))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func geometry(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as CFString),
              let size = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = position as! AXValue, sizeValue = size as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return WorldCoordinates.fromQuartz(CGRect(origin: point, size: dimensions), primaryHeight: primaryTop)
    }
}

private enum DesktopDockAccessibility {
    static func frame(pid: pid_t, context: DesktopCaptureContext, corroboratedBy cgFrames: [CGRect],
                      cancellation: DesktopCaptureCancellation) -> DesktopDockReadResult {
        let application = AXUIElementCreateApplication(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.055
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var visited = 0
        var incomplete = false
        while !queue.isEmpty && visited < 24 && !cancellation.isCancelled
            && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = attribute(element, kAXRoleAttribute as CFString, deadline: deadline,
                                 cancellation: cancellation, incomplete: &incomplete) as? String
            if let role,
               role == kAXListRole || role == kAXGroupRole,
               let rect = geometry(element, primaryTop: context.primaryTop, deadline: deadline,
                                   cancellation: cancellation, optional: role == kAXGroupRole, incomplete: &incomplete),
               DesktopGeometry.isDock(rect, displays: context.displays.map(\.frame)),
               cgFrames.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(rect) }) {
                var visibilityFailed = false
                let visibleChildren = attribute(element, kAXVisibleChildrenAttribute as CFString, deadline: deadline,
                                                 cancellation: cancellation, optional: true,
                                                 incomplete: &visibilityFailed) as? [AXUIElement]
                guard !visibilityFailed, !cancellation.isCancelled,
                      ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
                // A hidden candidate must not hide a different visible Dock
                // candidate elsewhere in the same successfully-read tree.
                if visibleChildren?.isEmpty == true { continue }
                let items = itemFrames(element, primaryTop: context.primaryTop, deadline: deadline,
                                       cancellation: cancellation)
                return DesktopDockReadResult.geometry(listFrame: rect, itemFrames: items)
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString, deadline: deadline,
                                         cancellation: cancellation, optional: role == kAXDockItemRole as String,
                                         incomplete: &incomplete) as? [AXUIElement] {
                let capacity = depth < 2 ? max(0, 24 - visited - queue.count) : 0
                if children.count > capacity { incomplete = true }
                queue.append(contentsOf: children.prefix(capacity).map { ($0, depth + 1) })
            }
        }
        // Only a completed metadata traversal can confirm absence. A timeout,
        // cancelled request or truncated tree says nothing about Dock visibility.
        guard !incomplete, queue.isEmpty, !cancellation.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
        return .hidden
    }

    private static func itemFrames(_ element: AXUIElement, primaryTop: CGFloat, deadline: TimeInterval,
                                   cancellation: DesktopCaptureCancellation) -> [CGRect?]? {
        var incomplete = false
        guard let children = attribute(element, kAXChildrenAttribute as CFString, deadline: deadline,
                                       cancellation: cancellation, incomplete: &incomplete) as? [AXUIElement],
              !incomplete, children.count <= 64 else { return nil }
        var frames: [CGRect?] = []
        for child in children {
            guard !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let role = attribute(child, kAXRoleAttribute as CFString, deadline: deadline,
                                       cancellation: cancellation, incomplete: &incomplete) as? String else { return nil }
            guard role == kAXDockItemRole as String else { continue }
            guard let frame = geometry(child, primaryTop: primaryTop, deadline: deadline, cancellation: cancellation,
                                       incomplete: &incomplete), DesktopGeometry.valid(frame) else { return nil }
            frames.append(frame)
        }
        // A timeout must not turn the first few children into a biased median.
        guard !incomplete, !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return frames
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString, deadline: TimeInterval,
                                  cancellation: DesktopCaptureCancellation, optional: Bool = false,
                                  incomplete: inout Bool) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !cancellation.isCancelled, remaining > 0 else { incomplete = true; return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(0.015, remaining)))
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &result)
        guard status == .success, result != nil else {
            // Unsupported optional attributes are different from a busy Dock.
            if !(optional && (status == .attributeUnsupported || status == .noValue)) { incomplete = true }
            return nil
        }
        return result
    }

    private static func geometry(_ element: AXUIElement, primaryTop: CGFloat, deadline: TimeInterval,
                                 cancellation: DesktopCaptureCancellation, optional: Bool = false,
                                 incomplete: inout Bool) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute as CFString, deadline: deadline,
                                             cancellation: cancellation, optional: optional, incomplete: &incomplete),
              let sizeValue = attribute(element, kAXSizeAttribute as CFString, deadline: deadline,
                                       cancellation: cancellation, optional: optional, incomplete: &incomplete) else { return nil }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            incomplete = true; return nil
        }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        guard AXValueGetType(positionAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize else { incomplete = true; return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &point), AXValueGetValue(sizeAX, .cgSize, &size) else {
            incomplete = true; return nil
        }
        let frame = WorldCoordinates.fromQuartz(CGRect(origin: point, size: size), primaryHeight: primaryTop)
        guard DesktopGeometry.valid(frame) else { incomplete = true; return nil }
        return frame
    }
}
