import Foundation
import CoreGraphics

private struct WindowMotionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum WindowMotionTests {
    private static var checks = 0

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw WindowMotionFailure(description: message) }
    }

    private static func window(_ id: String = "window", x: CGFloat = 0, y: CGFloat = 100,
                               width: CGFloat = 600, height: CGFloat = 300,
                               visible: Bool = true, kind: SurfaceKind = .window) -> SnowSurface {
        SnowSurface(id: id, frame: CGRect(x: x, y: y, width: width, height: height),
                    kind: kind, isVisible: visible)
    }

    static func main() {
        let scenarios: [(String, () throws -> Void)] = [
            ("manual window drag freezes until release", {
                var detector = WindowDragDetector()
                let initial = window(), moved = window(x: 25), resized = window(x: 25, width: 550)
                try require(!detector.update(previous: [initial], current: [initial], pointerPressed: true),
                            "a click without window movement must not pause objects")
                try require(detector.update(previous: [initial], current: [moved], pointerPressed: true),
                            "a window translation while pressed starts the pause")
                try require(detector.update(previous: [moved], current: [moved], pointerPressed: true),
                            "a stationary held window keeps the pause")
                try require(!detector.update(previous: [moved], current: [resized], pointerPressed: false),
                            "release ends the pause even if the last frame changed")
                try require(!detector.update(previous: [moved], current: [resized], pointerPressed: false),
                            "system geometry changes without a press do not start the pause")
                try require(detector.update(previous: [moved], current: [resized], pointerPressed: true),
                            "a manual resize also pauses objects")
                detector.reset()
                try require(!detector.isDragging, "session reset releases the pause")
            }),
            ("Mission Control retains window geometry throughout a long selection", {
                let original = window(), other = window("other", x: 650)
                let floor = window("floor", width: 1400, height: 1, kind: .floor)
                let miniature = window(x: 120, y: 300, width: 300, height: 150)
                let newMiniature = window("new", x: 500, y: 300, width: 300, height: 150)
                var animations = WindowSurfaceAnimations()
                var surfaces = [original, other, floor]
                for (time, pressed) in [(0.0, false), (0.15, false), (5.0, false), (10.0, true)] {
                    surfaces = animations.reconcile([miniature, newMiniature, floor], previous: surfaces,
                        hiddenIDs: [], pointerPressed: pressed, missionControlActive: true, at: time)
                    try require(surfaces.first(where: { $0.id == original.id })?.frame == original.frame
                                && surfaces.first(where: { $0.id == original.id })?.isVisible == false,
                                "a stationary thumbnail and mouse selection must never replace the stored frame")
                    try require(surfaces.first(where: { $0.id == other.id })?.frame == other.frame
                                && surfaces.first(where: { $0.id == other.id })?.isVisible == false,
                                "an unreported window keeps its hidden original frame")
                    try require(!surfaces.contains(where: { $0.id == newMiniature.id })
                                && surfaces.contains(where: { $0.id == floor.id }),
                                "new thumbnails do not create supports and the floor remains available")
                }
                let restored = animations.reconcile([original, other, floor], previous: surfaces,
                    hiddenIDs: [], pointerPressed: true, at: 10.01)
                try require(restored.first(where: { $0.id == original.id })?.frame == original.frame
                            && restored.first(where: { $0.id == original.id })?.isVisible == true
                            && restored.first(where: { $0.id == other.id })?.isVisible == true,
                            "the original geometry returns immediately after Mission Control")
            }),
            ("resize before Mission Control signal waits for stability", {
                let original = window()
                let display = CGRect(x: 0, y: 0, width: 1400, height: 900)
                let thumbnail = window(x: 0, y: 100, width: 300, height: 300)
                var animations = WindowSurfaceAnimations()
                let first = animations.reconcile([thumbnail], previous: [original], hiddenIDs: [],
                    displays: [display], pointerPressed: false, at: 0)
                try require(first.first?.frame == original.frame && first.first?.isVisible == false,
                            "a horizontal shrink cannot change the stored geometry in its first frame")
                let beforeSignal = animations.reconcile([thumbnail], previous: first, hiddenIDs: [],
                    displays: [display], pointerPressed: false, at: 0.15)
                try require(beforeSignal.first?.frame == original.frame && beforeSignal.first?.isVisible == false,
                            "a stationary thumbnail remains uncommitted after an idle polling interval")
                animations.resetForSpaceChange()
                let spaceNotification = animations.reconcile([thumbnail], previous: beforeSignal, hiddenIDs: [],
                    displays: [display], pointerPressed: false, spaceChanging: true, at: 0.16)
                try require(spaceNotification.first?.frame == original.frame && spaceNotification.first?.isVisible == false,
                            "a Space notification cannot shorten an already pending resize interval")
                let overview = animations.reconcile([thumbnail], previous: spaceNotification, hiddenIDs: [],
                    displays: [display], pointerPressed: false, missionControlActive: true, at: 0.17)
                let held = animations.reconcile([thumbnail], previous: overview, hiddenIDs: [],
                    displays: [display], pointerPressed: true, missionControlActive: true, at: 5)
                try require(held.first?.frame == original.frame && held.first?.isVisible == false,
                            "the later Mission Control signal must retain the original frame")

                var ordinary = WindowSurfaceAnimations()
                let verticalResize = window(x: 0, y: 100, width: 600, height: 200)
                let pending = ordinary.reconcile([verticalResize], previous: [original], hiddenIDs: [],
                    displays: [display], pointerPressed: false, at: 1)
                let settled = ordinary.reconcile([verticalResize], previous: pending, hiddenIDs: [],
                    displays: [display], pointerPressed: false, at: 1.31)
                try require(pending.first?.frame == original.frame && pending.first?.isVisible == false
                            && settled.first?.frame == verticalResize.frame && settled.first?.isVisible == true,
                            "a programmatic height-only resize commits once stable")
                var manual = WindowSurfaceAnimations()
                let dragged = manual.reconcile([thumbnail], previous: [original], hiddenIDs: [],
                    displays: [display], pointerPressed: true, at: 2)
                try require(dragged.first?.frame == thumbnail.frame && dragged.first?.isVisible == true,
                            "a user resize is still immediate")
            }),
            ("Space before a thumbnail cannot shorten resize protection", {
                let original = window()
                let display = CGRect(x: 0, y: 0, width: 1400, height: 900)
                let thumbnail = window(x: 0, y: 100, width: 300, height: 300)
                for initiallyVisible in [true, false] {
                    var animations = WindowSurfaceAnimations()
                    var stored = original
                    stored.isVisible = initiallyVisible
                    animations.resetForSpaceChange()
                    let first = animations.reconcile([thumbnail], previous: [stored], hiddenIDs: [],
                        displays: [display], pointerPressed: false, spaceChanging: true, at: 0)
                    let next = animations.reconcile([thumbnail], previous: first, hiddenIDs: [],
                        displays: [display], pointerPressed: false, spaceChanging: true, at: 0.15)
                    try require(next.first?.frame == original.frame && next.first?.isVisible == false,
                                "a Space notification before resize must not commit a thumbnail at 150 ms")
                    let overview = animations.reconcile([thumbnail], previous: next, hiddenIDs: [],
                        displays: [display], pointerPressed: false, missionControlActive: true, at: 0.16)
                    let held = animations.reconcile([thumbnail], previous: overview, hiddenIDs: [],
                        displays: [display], pointerPressed: true, missionControlActive: true, at: 5)
                    try require(held.first?.frame == original.frame && held.first?.isVisible == false,
                                "Mission Control must preserve the original geometry after the Space notification")
                }
            }),
            ("Mission Control recovery confirms changed sizes before committing", {
                let original = window()
                let display = CGRect(x: 0, y: 0, width: 1400, height: 900)
                var animations = WindowSurfaceAnimations()
                let hidden = animations.reconcile([window(x: 100, y: 300, width: 300, height: 150)],
                    previous: [original], hiddenIDs: [], displays: [display], pointerPressed: false,
                    missionControlActive: true, at: 0)
                animations.resetForSpaceChange()
                let resized = window(x: 25, y: 100, width: 601, height: 301)
                let first = animations.reconcile([resized], previous: hidden, hiddenIDs: [],
                    displays: [display], pointerPressed: true, spaceChanging: true, at: 5)
                try require(first.first?.frame == original.frame && first.first?.isVisible == false,
                            "even a one-point change waits for a stable final size during recovery")
                let changed = window(x: 25, y: 100, width: 620, height: 310)
                let second = animations.reconcile([changed], previous: first, hiddenIDs: [],
                    displays: [display], pointerPressed: true, at: 5.05)
                try require(second.first?.frame == original.frame && second.first?.isVisible == false,
                            "a changing final frame restarts the stability interval")
                let stillPending = animations.reconcile([changed], previous: second, hiddenIDs: [],
                    displays: [display], pointerPressed: true, spaceChanging: true, at: 5.20)
                try require(stillPending.first?.frame == original.frame && stillPending.first?.isVisible == false,
                            "a stationary post-Mission-Control frame waits beyond one idle polling interval")
                let final = animations.reconcile([changed], previous: stillPending, hiddenIDs: [],
                    displays: [display], pointerPressed: true, at: 5.36)
                try require(final.first?.frame == changed.frame && final.first?.isVisible == true,
                            "a stable changed frame eventually becomes the actual support")

                let manualResize = window(x: 25, y: 100, width: 640, height: 310)
                let manual = animations.reconcile([manualResize], previous: final, hiddenIDs: [],
                    displays: [display], pointerPressed: true, at: 6)
                try require(manual.first?.frame == manualResize.frame && manual.first?.isVisible == true,
                            "recovery ends and a later manual resize remains immediate")
                let programmaticResize = window(x: 25, y: 120, width: 650, height: 310)
                let pending = animations.reconcile([programmaticResize], previous: manual, hiddenIDs: [],
                    displays: [display], pointerPressed: false, at: 7)
                let settled = animations.reconcile([programmaticResize], previous: pending, hiddenIDs: [],
                    displays: [display], pointerPressed: false, at: 7.31)
                try require(pending.first?.isVisible == false && settled.first?.frame == programmaticResize.frame
                            && settled.first?.isVisible == true,
                            "ordinary programmatic resize still commits once stable")
            }),
            ("returning window snow follows the horizontal Space animation before the notification", {
                let original = window()
                let display = CGRect(x: 0, y: 0, width: 1400, height: 900)
                var animations = WindowSurfaceAnimations()
                var surfaces = animations.reconcile([], previous: [original], hiddenIDs: [original.id],
                                                     pointerPressed: false, at: 1)
                let positions: [CGFloat] = [-350, -180, -20, 0]
                for (index, x) in positions.enumerated() {
                    let frame = window(x: x, y: 99, width: 601, height: 301)
                    surfaces = animations.reconcile([frame], previous: surfaces, hiddenIDs: [],
                                                    displays: [display], pointerPressed: false,
                                                    at: 6 + Double(index) * 0.02)
                    try require(surfaces.first?.isVisible == true && surfaces.first?.frame.minX == x
                                && surfaces.first?.top == original.top && surfaces.first?.frame.size == original.frame.size,
                                "the returning window must publish geometry without waiting for a stable X or Space notification")
                }
                let hidden = animations.reconcile([], previous: [original], hiddenIDs: [original.id],
                                                  pointerPressed: false, at: 10)
                let dockAnimation = window(x: -350, y: -170)
                let stillHidden = animations.reconcile([dockAnimation], previous: hidden, hiddenIDs: [],
                                                       displays: [display], pointerPressed: false, at: 15)
                try require(stillHidden.first?.isVisible == false && stillHidden.first?.frame == original.frame,
                            "a same-size vertical move from Dock is not a horizontal Space return")
            }),
            ("system translation never sheds snow outside a manual drag", {
                var detector = WindowShakeDetector()
                _ = detector.update(surfaces: [window()], dragging: false, at: 0)
                try require(detector.update(surfaces: [window(x: 200)], dragging: false, at: 0.035).isEmpty,
                            "same-size Space animation is not a shake")
                try require(detector.update(surfaces: [window(x: 400)], dragging: true, at: 0.07).isEmpty,
                            "the first pressed sample cannot use the system animation as its baseline")
                try require(detector.update(surfaces: [window(x: 450)], dragging: true, at: 0.105)["window"] != nil,
                            "a fast dragging movement still sheds snow")
                try require(detector.update(surfaces: [window(x: 500)], dragging: false, at: 0.14).isEmpty,
                            "the released button stops shedding before the next geometry update")
            }),
            ("a resized window returns promptly after five seconds on another Space", {
                let original = window()
                let display = CGRect(x: 0, y: 0, width: 1400, height: 900)
                var animations = WindowSurfaceAnimations()
                let away = animations.reconcile([], previous: [original], hiddenIDs: [original.id],
                                                pointerPressed: false, at: 1)
                let returning = window(x: 24, y: 100, width: 610)
                let first = animations.reconcile([returning], previous: away, hiddenIDs: [],
                                                displays: [display], pointerPressed: false, spaceChanging: true, at: 6)
                try require(first.first?.isVisible == false && first.first?.frame == original.frame,
                            "an unconfirmed resize must preserve the original support")
                let intermediate = window(x: 24, y: 100, width: 620)
                let second = animations.reconcile([intermediate], previous: first, hiddenIDs: [],
                                                 displays: [display], pointerPressed: false, spaceChanging: true, at: 6.05)
                try require(second.first?.isVisible == false && second.first?.frame == original.frame,
                            "changed intermediate bounds must restart the stability check")
                let settled = animations.reconcile([intermediate], previous: second, hiddenIDs: [],
                                                  displays: [display], pointerPressed: false, spaceChanging: true, at: 6.36)
                try require(settled.first?.isVisible == true && settled.first?.frame == intermediate.frame,
                            "stable geometry must reveal the window while Space protection is still active")
            }),
            ("animated window geometry preserves the last usable support", {
                let original = window()
                var animations = WindowSurfaceAnimations()
                func reconcile(_ next: [SnowSurface], old: [SnowSurface], hidden: Set<String> = [],
                               pressed: Bool = false, at time: TimeInterval) -> [SnowSurface] {
                    animations.reconcile(next, previous: old, hiddenIDs: hidden, pointerPressed: pressed, at: time)
                }
                let first = window(x: 4, y: 45, width: 590)
                let shrinking = reconcile([first], old: [original], at: 0)
                try require(shrinking.first?.frame == original.frame && shrinking.first?.isVisible == false,
                            "a translating shrink immediately hides the original support")
                let last = window(x: 425, y: 5, width: 88, height: 120)
                let later = reconcile([last], old: shrinking, pressed: true, at: 0.2)
                try require(later.first?.frame == original.frame && later.first?.isVisible == false,
                            "later animation frames preserve geometry even if the pointer is now pressed")
                let minimized = reconcile([], old: later, hidden: [original.id], at: 0.4)
                try require(minimized.first?.frame == original.frame && minimized.first?.isVisible == false,
                            "the offscreen window retains its original frame")
                let expanding = reconcile([last], old: minimized, at: 1)
                try require(expanding.first?.frame == original.frame && expanding.first?.isVisible == false,
                            "the growing window stays hidden during restore")
                let returned = reconcile([original], old: expanding, at: 1.3)
                try require(returned.first?.frame == original.frame && returned.first?.isVisible == true,
                            "the exact original frame resumes without delay")

                let dragged = reconcile([first], old: [original], pressed: true, at: 2)
                try require(dragged.first?.frame == first.frame && dragged.first?.isVisible == true,
                            "normal pointer resize publishes geometry immediately")
                let final = window(x: 30, y: 140, width: 350)
                let pending = reconcile([final], old: dragged, at: 3)
                let settled = reconcile([final], old: pending, at: 3.31)
                try require(pending.first?.isVisible == false && settled.first?.frame == final.frame
                            && settled.first?.isVisible == true, "a stable new frame eventually commits a programmatic resize")
                try require(reconcile([], old: settled, at: 4).isEmpty, "an destroyed window no longer retains support")

                let offscreen = window(x: -900)
                let shifted = animations.reconcile([offscreen], previous: [original], hiddenIDs: [],
                                                   pointerPressed: false, spaceChanging: true, at: 5)
                let pausedShift = animations.reconcile([offscreen], previous: shifted, hiddenIDs: [],
                                                       pointerPressed: false, spaceChanging: true, at: 5.15)
                try require(pausedShift.first?.frame == original.frame && pausedShift.first?.isVisible == false,
                            "a held intermediate frame cannot replace the original bounds during a Space transition")
                let restored = reconcile([original], old: pausedShift, at: 5.2)
                try require(restored.first?.isVisible == true && restored.first?.frame == original.frame,
                            "the original bounds may resume immediately")

                let rounded = window(x: 24, y: 100, width: 601, height: 301)
                let visible = animations.reconcile([rounded], previous: pausedShift, hiddenIDs: [],
                                                   displays: [CGRect(x: 0, y: 0, width: 1400, height: 900)],
                                                   pointerPressed: false, spaceChanging: true, at: 5.21)
                try require(visible.first?.isVisible == true && visible.first?.frame.minX == rounded.frame.minX
                            && visible.first?.top == rounded.top && visible.first?.frame.size == original.frame.size,
                            "an on-display return uses the first reported position and keeps the original profile size")
            }),
            ("120 Hz metadata retains shake detection through the sample gate", {
                func run(speed: CGFloat, jitter: Bool = false, gated: Bool = true) -> [CGVector] {
                    var tracker = WindowMotionTracker(), gate = WindowMotionSampleGate()
                    var velocities: [CGVector] = []
                    for index in 0...120 {
                        let time = Double(index) / 120
                        let x = jitter ? CGFloat(index.isMultiple(of: 2) ? -3 : 3) : speed * CGFloat(time)
                        if !gated || gate.shouldSample(at: time) {
                            velocities.append(contentsOf: tracker.update(surfaces: [window(x: x)], at: time).values)
                        }
                    }
                    return velocities
                }
                try require(run(speed: 1_200, gated: false).isEmpty,
                            "Ungated 120 Hz reproduces sub-20-point snapshots that fail to shed")
                let fast = run(speed: 1_200)
                try require(!fast.isEmpty && fast.count <= 2, "The production sample gate restores shaking and preserves cooldown")
                try require(fast.allSatisfy { abs($0.dx - 1_200) < 0.001 }, "Sample gating preserves the actual points-per-second velocity")
                try require(run(speed: 300).isEmpty, "Higher metadata cadence cannot make slow motion shed")
                try require(run(speed: 0, jitter: true).isEmpty, "Small oscillating jitter cannot accumulate into a false shake")
                var gate = WindowMotionSampleGate()
                try require(gate.shouldSample(at: 10) && !gate.shouldSample(at: 10.008), "Only the first high-rate snapshot starts a detector sample")
                gate.reset()
                try require(gate.shouldSample(at: 10.009), "Session reset admits a fresh detector baseline immediately")
                try require(gate.shouldSample(at: 9), "Reversed time is delivered so the detector can reset its own baseline")
                try require(gate.shouldSample(at: .nan) && gate.shouldSample(at: 11), "Invalid time cannot retain a sample deadline")
            }),
            ("startup and slow movement", {
                var tracker = WindowMotionTracker()
                try require(tracker.update(surfaces: [window(x: -8_000)], at: 80).isEmpty, "Startup must only record metadata")
                try require(tracker.update(surfaces: [window(x: -7_900)], at: 80.15).isEmpty, "Large but slow translation must preserve snow")
                try require(tracker.update(surfaces: [window(x: -7_875)], at: 80.185).isEmpty, "35 ms samples still require the speed threshold")
            }),
            ("fast translation at both polling intervals", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                let fast = tracker.update(surfaces: [window(x: 42, y: 72)], at: 0.035)
                try require(fast.count == 1, "Fast diagonal motion must shed once")
                try require(abs((fast["window"]?.dx ?? 0) - 1_200) < 0.001, "Horizontal velocity must use points per second")
                try require(abs((fast["window"]?.dy ?? 0) + 800) < 0.001, "Vertical velocity must preserve AppKit direction")
                tracker.reset()
                _ = tracker.update(surfaces: [window()], at: 10)
                let idle = tracker.update(surfaces: [window(x: -180)], at: 10.15)
                try require(abs((idle["window"]?.dx ?? 0) + 1_200) < 0.001, "Fast movement must also work at the idle polling interval")
            }),
            ("small jitter does not accumulate", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                for index in 1...6 {
                    try require(tracker.update(surfaces: [window(x: CGFloat(index) * 19)], at: Double(index) * 0.005).isEmpty,
                                "Sub-20-point changes must not shed, even at high calculated velocity")
                }
            }),
            ("inclusive distance and speed boundaries", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 1)
                try require(tracker.update(surfaces: [window(x: 20)], at: 1.02)["window"] != nil, "Exactly 20 pt at 1000 pt/s must qualify")
                tracker.reset()
                _ = tracker.update(surfaces: [window()], at: 1)
                try require(tracker.update(surfaces: [window(x: 20)], at: 1.0201).isEmpty, "A speed below 1000 pt/s must not qualify")
                tracker.reset()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(x: 19.99)], at: 0.005).isEmpty, "A distance below 20 pt must not qualify")
            }),
            ("resize establishes a new baseline", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(x: 200, width: 800)], at: 0.035).isEmpty, "Left-edge resize must not count as translation")
                try require(tracker.update(surfaces: [window(x: 242, width: 800)], at: 0.07)["window"] != nil, "Translation after resize uses the resized frame")
                tracker.reset()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(y: 300, height: 100)], at: 0.035).isEmpty, "Vertical resize must not shed")
            }),
            ("snapshot gap", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(x: 1_000)], at: 0.351).isEmpty, "A gap above 350 ms must discard apparent velocity")
                try require(tracker.update(surfaces: [window(x: 1_042)], at: 0.386)["window"] != nil, "The next continuous sample can qualify")
                tracker.reset()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(x: 350)], at: 0.35)["window"] != nil, "The 350 ms gap boundary remains valid")
            }),
            ("per-window cooldown", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(x: 42)], at: 0.035)["window"] != nil, "Initial fast movement must shed")
                for index in 2...20 {
                    try require(tracker.update(surfaces: [window(x: CGFloat(index) * 42)], at: Double(index) * 0.035).isEmpty,
                                "Continuous fast movement cannot retrigger within 700 ms")
                }
                try require(tracker.update(surfaces: [window(x: 882)], at: 0.735)["window"] != nil, "Retrigger is allowed at the 700 ms boundary")
            }),
            ("independent window cooldowns", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window("a"), window("b")], at: 0)
                try require(Set(tracker.update(surfaces: [window("a", x: 42), window("b")], at: 0.035).keys) == ["a"], "First window triggers independently")
                try require(Set(tracker.update(surfaces: [window("a", x: 84), window("b", x: -42)], at: 0.07).keys) == ["b"], "Second window is not blocked by another window's cooldown")
            }),
            ("reset rejects Space and sleep teleports", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                _ = tracker.update(surfaces: [window(x: 42)], at: 0.035)
                tracker.reset()
                try require(tracker.update(surfaces: [window(x: 50_000)], at: 0.07).isEmpty, "Reset must make even a nearby-timestamp teleport a first snapshot")
                try require(tracker.update(surfaces: [window(x: 50_042)], at: 0.105)["window"] != nil, "Reset also discards the old cooldown")
            }),
            ("missing and reopened window", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                _ = tracker.update(surfaces: [window(x: 42)], at: 0.035)
                try require(tracker.update(surfaces: [], at: 0.07).isEmpty, "Closed window emits nothing")
                try require(tracker.update(surfaces: [window(x: 2_000)], at: 0.105).isEmpty, "A reused ID starts with a new baseline")
                try require(tracker.update(surfaces: [window(x: 2_042)], at: 0.14)["window"] != nil, "A reopened window does not inherit cooldown")
            }),
            ("invisible window loses motion history", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 0)
                try require(tracker.update(surfaces: [window(x: 500, visible: false)], at: 0.035).isEmpty, "Hidden windows do not shed")
                try require(tracker.update(surfaces: [window(x: 1_000)], at: 0.07).isEmpty, "Reveal starts a new baseline")
                try require(tracker.update(surfaces: [window(x: 1_042)], at: 0.105)["window"] != nil, "Continuous motion after reveal can qualify")
            }),
            ("Dock and floor are excluded", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window("dock", kind: .dock), window("floor", kind: .floor)], at: 0)
                try require(tracker.update(surfaces: [window("dock", x: 500, kind: .dock), window("floor", y: 600, kind: .floor)], at: 0.035).isEmpty,
                            "Dock and floor motion must never shed")
                try require(tracker.update(surfaces: [window("dock", x: 1_000)], at: 0.07).isEmpty, "A non-window ID has no reusable history")
            }),
            ("invalid and non-monotonic timestamps", {
                var tracker = WindowMotionTracker()
                _ = tracker.update(surfaces: [window()], at: 1)
                try require(tracker.update(surfaces: [window(x: 500)], at: 1).isEmpty, "Duplicate timestamps cannot divide by zero")
                try require(tracker.update(surfaces: [window(x: 1_000)], at: 0.5).isEmpty, "Reversed time establishes a new baseline")
                try require(tracker.update(surfaces: [window(x: 1_042)], at: 0.535)["window"] != nil, "Motion recovers after reversed time")
                try require(tracker.update(surfaces: [window(x: 2_000)], at: .nan).isEmpty, "NaN time cannot emit a velocity")
                try require(tracker.update(surfaces: [window(x: 4_000)], at: 2).isEmpty, "Invalid time clears stale history")
            })
        ]
        do {
            for (name, scenario) in scenarios {
                try scenario()
                print("PASS \(name)")
            }
            print("Window motion: \(scenarios.count) scenarios, \(checks) checks passed")
        } catch {
            fputs("FAIL window motion: \(error)\n", stderr)
            exit(1)
        }
    }
}
