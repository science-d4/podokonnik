import AppKit
import SpriteKit

private struct DuckRenderFailure: Error, CustomStringConvertible { let description: String }

@main
enum DuckRenderTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let display = CGRect(x: -120, y: -50, width: 540, height: 400)
        let region = DuckDisplay(frame: display, visibleTop: 320)
        let floor = SnowSurface(id: "floor", frame: CGRect(x: -120, y: -51, width: 540, height: 1), kind: .floor)
        let roof = SnowSurface(id: "roof", frame: CGRect(x: 65, y: 22, width: 240, height: 155),
                               kind: .window, topInset: 16, suppressesSnowfall: true)
        let snow = SnowWorld(seed: 82), duck = DuckWorld(seed: 31), trees = FestiveWorld()
        snow.syncSurfaces([roof, floor])
        duck.setEnabled(true, surfaces: snow.surfaces)
        for _ in 0..<120 { snow.step(delta: 0.1, weather: SnowWeather(), activeRegions: [display]) }
        snow.syncSurfaces([roof, floor])

        let scene = SnowScene(world: snow, displayFrame: display, festiveWorld: trees)
        scene.duckWorld = duck
        let view = SKView(frame: CGRect(origin: .zero, size: display.size))
        view.isPaused = true; view.allowsTransparency = true
        let host = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view; view.presentScene(scene)
        defer { view.presentScene(nil); host.close() }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
            guard condition() else { throw DuckRenderFailure(description: detail) }
            count += 1
        }
        var treesEnabled = false
        func step(_ delta: Double = 0.1) {
            duck.advance(delta: delta, snow: snow, trees: trees, treesEnabled: treesEnabled, displays: [region],
                         allDisplayFrames: [display], plows: [:], sweeps: [], reducedMotion: false)
        }
        func actor() -> SKNode? {
            guard let layer = scene.childNode(withName: "duck-layer"), !layer.isHidden,
                  let actor = layer.childNode(withName: "duck"), !actor.isHidden else { return nil }
            return actor
        }
        func export(_ name: String) throws {
            guard let texture = view.texture(from: scene, crop: CGRect(origin: .zero, size: display.size)),
                  let png = NSBitmapImageRep(cgImage: texture.cgImage()).representation(using: .png, properties: [:]) else {
                throw DuckRenderFailure(description: "own SpriteKit preview unavailable")
            }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func sampleDuck(at world: CGPoint) throws -> CGFloat {
            guard let layer = scene.childNode(withName: "duck-layer"),
                  let texture = view.texture(from: layer, crop: CGRect(origin: .zero, size: display.size)) else {
                throw DuckRenderFailure(description: "duck layer texture unavailable")
            }
            let image = NSBitmapImageRep(cgImage: texture.cgImage())
            let x = Int((world.x - display.minX) * CGFloat(image.pixelsWide) / display.width)
            let y = Int((world.y - display.minY) * CGFloat(image.pixelsHigh) / display.height)
            return image.colorAt(x: x, y: image.pixelsHigh - 1 - y)?.alphaComponent ?? 0
        }
        for _ in 0..<12 { step() }
        scene.update(1)
        try check(actor() != nil && duck.pose?.anchor?.surfaceID == floor.id, "first active frames show the floor duck")
        try check(abs((actor()?.yScale ?? 0) - 1.2) < 0.001 && abs(abs(actor()?.xScale ?? 0) - 1.2) < 0.001,
                  "duck drawing is scaled on both axes")
        let start = actor()!.position
        let anchor = duck.pose!.anchor!
        let displayed = snow.drifts[floor.id]!.visibleContour.height(at: anchor.localX)
        try check(abs(start.y - displayed) < 0.01 && displayed > 1, "rendered feet align with the snowy floor")
        let body = CGPoint(x: start.x + display.minX - 2, y: start.y + display.minY + 10)
        let bodyAlpha = try sampleDuck(at: body)
        try check(bodyAlpha > 0.8, "duck body is visible in the rendered pixel data")
        try export("01-floor")
        snow.clear(surfaceID: floor.id); step(0)
        scene.update(1.01)
        try check(actor()?.position == start, "the duck still stands on the previously rasterized contour")
        scene.update(1.06)
        try check(actor()?.position.y == 0, "the same duck follows the newly cleared raster")

        for _ in 0..<6_500 {
            if duck.pose?.activity == .fly { break }
            step()
        }
        scene.update(1.12)
        try check(duck.pose?.activity == .fly && actor() != nil, "flight renders on the production scene")
        try export("02-flight")
        let launch = duck.pose!.feet
        var backdrop = roof
        backdrop.id = "background"
        backdrop.frame = CGRect(x: launch.x - 55, y: launch.y + 42, width: 110, height: 70)
        backdrop.suppressesSnowfall = false
        snow.syncSurfaces([roof, backdrop, floor]); duck.sync(snow.surfaces)
        for tick in 0..<12 {
            step()
            scene.update(1.13 + Double(tick) * 0.005)
            if let pose = duck.pose, pose.activity == .fly, backdrop.frame.contains(pose.feet), actor() != nil { break }
        }
        try check(duck.pose.map { $0.activity == .fly && backdrop.frame.contains($0.feet) } == true && actor() != nil,
                  "the airborne actor remains drawn in front of an intersected window")
        try export("02a-flight-front-of-window")
        snow.syncSurfaces([roof, floor]); duck.sync(snow.surfaces)
        var raisedWing: CGFloat?, loweredWing: CGFloat?, tuckedFootY: CGFloat?, landingFootY: CGFloat?
        for tick in 0..<180 {
            if duck.pose?.anchor?.surfaceID == roof.id { break }
            step(0.02)
            scene.update(1.18 + Double(tick) * 0.001)
            guard let pose = duck.pose, pose.activity == .fly, let actor = actor(),
                  let wing = actor.childNode(withName: "duck-near-flight-wing"), !wing.isHidden,
                  let farWing = actor.childNode(withName: "duck-far-flight-wing"), !farWing.isHidden,
                  let foot = actor.childNode(withName: "duck-foot") else { continue }
            let elevation = DuckWingbeat(time: pose.time).elevation
            if pose.feetExtended == 0 {
                tuckedFootY = foot.position.y
                if elevation > 0.9 && raisedWing == nil {
                    raisedWing = wing.zRotation
                    try export("02b-wings-up")
                }
                if elevation < -0.9 && loweredWing == nil {
                    loweredWing = wing.zRotation
                    try export("02c-wings-down")
                }
            } else if tuckedFootY != nil && pose.feetExtended > 0.8 && landingFootY == nil {
                landingFootY = foot.position.y
                try export("02d-feet-ready")
            }
        }
        try check((loweredWing ?? 0) - (raisedWing ?? 0) > 1.4, "both visible flight wings sweep through distinct poses")
        try check((tuckedFootY ?? 0) - (landingFootY ?? 10) > 6 && landingFootY != nil,
                  "the visible feet tuck away in flight and extend before landing")
        scene.update(1.38)
        try check(duck.pose?.anchor?.surfaceID == roof.id && actor() != nil, "landing renders on the window")
        let original = actor()!.position
        var moved = roof
        moved.frame = moved.frame.offsetBy(dx: 33, dy: -20)
        snow.syncSurfaces([moved, floor]); duck.sync(snow.surfaces); step(0)
        scene.update(1.39)
        try check(actor()?.position == CGPoint(x: original.x + 33, y: original.y - 20),
                  "the first frame after window movement uses the new origin")
        try export("03-window-moved")
        let feet = duck.pose!.feet
        let beforeShovel = snow.drifts[roof.id]!.heights.reduce(0, +)
        scene.playing = true
        scene.tool = .shovel
        scene.pointerDown(at: actor()!.position, timestamp: 2)
        scene.pointerUp(timestamp: 2.01)
        try check(snow.drifts[roof.id]!.heights.reduce(0, +) < beforeShovel,
                  "the normal shovel tool reaches the roof underneath the duck")
        scene.playing = false
        moved.bodyOccluders = [CGRect(x: feet.x - 15, y: feet.y + 16, width: 30, height: 30)]
        snow.syncSurfaces([moved, floor]); duck.sync(snow.surfaces); step(0)
        scene.update(1.40)
        try check(duck.pose?.anchor == nil && duck.pose?.activity == .fly && actor() != nil,
                  "changed foreground ends the covered grounded pose and the departure is drawn in front")
        scene.decorationOptions.duck = false
        duck.setEnabled(false, surfaces: snow.surfaces)
        scene.update(1.41)
        try check(scene.childNode(withName: "duck-layer") == nil, "the disabled frame releases the duck visual and effects")

        let dock = SnowSurface(id: "dock", frame: CGRect(x: 25, y: display.minY, width: 130, height: 47), kind: .dock)
        snow.syncSurfaces([dock, floor])
        duck.setEnabled(true, surfaces: snow.surfaces)
        scene.decorationOptions.duck = true
        var crossed = false
        for _ in 0..<7_000 {
            step()
            if let pose = duck.pose, pose.activity == .fly, dock.frame.minX < pose.feet.x, pose.feet.x < dock.frame.maxX {
                crossed = pose.feet.y >= dock.top + 12
                break
            }
        }
        scene.update(1.48)
        try check(crossed && actor() != nil, "first floor crossing visibly clears the Dock glass")
        let dockBody = SKShapeNode(rect: dock.frame.offsetBy(dx: -display.minX, dy: -display.minY), cornerRadius: 10)
        dockBody.fillColor = NSColor(white: 0.25, alpha: 0.85)
        dockBody.strokeColor = .clear
        dockBody.zPosition = 100
        scene.addChild(dockBody)
        try export("04-dock-crossing")
        dockBody.removeFromParent()

        snow.syncSurfaces([roof, floor]); duck.sync(snow.surfaces); duck.clear()
        treesEnabled = true; scene.decorationOptions.christmasTrees = true
        let tree = trees.place(at: CGPoint(x: roof.frame.midX, y: roof.top + 10), displayFrame: display, snow: snow)
        for _ in 0..<7_000 {
            step()
            if duck.pose?.activity.isTreeInteraction == true { break }
        }
        scene.update(1.55)
        try check(tree != nil && duck.pose?.activity.isTreeInteraction == true && actor() != nil,
                  "duck and the window tree are both present after the sustained-focus visit")
        try export("05-window-tree")
        let lastPosition = actor()!.position
        var inactiveRoof = roof
        inactiveRoof.suppressesSnowfall = false
        snow.syncSurfaces([inactiveRoof, floor]); duck.sync(snow.surfaces); step(0)
        scene.update(1.56)
        try check(duck.pose?.activity == .fly && actor()?.position == lastPosition,
                  "loss of focus starts the descent from the last visible position")
        for _ in 0..<65 {
            step()
            if duck.pose?.anchor?.surfaceID == floor.id { break }
        }
        scene.update(1.62)
        try check(duck.pose?.anchor?.surfaceID == floor.id && actor() != nil, "descent lands on the visible floor")

        scene.decorationOptions.christmasTrees = false; treesEnabled = false
        var wide = roof
        wide.frame = CGRect(x: display.minX, y: display.minY, width: display.width, height: 220)
        snow.syncSurfaces([wide, floor]); duck.sync(snow.surfaces); step(0)
        var sweep = SnowplowSchedule()
        sweep.requestSweep()
        for tick in 0..<80 {
            _ = sweep.advance(delta: 0.1, surfaces: snow.surfaces, activeRegions: [display], intervalMinutes: 10)
            duck.advance(delta: 0.1, snow: snow, trees: trees, treesEnabled: false, displays: [region],
                         allDisplayFrames: [display], plows: sweep.passes, sweeps: [], reducedMotion: false)
            if let pose = duck.pose, let plow = sweep.passes[floor.id], pose.activity == .fly,
               abs(plow.x - pose.feet.x) < 35, pose.feet.y >= floor.top + 62 {
                scene.snowplowPasses = sweep.passes
                scene.update(1.7 + Double(tick) / 10)
                try check(actor() != nil, "the airborne duck remains visible above the tractor below a wide window")
                try export("06-over-tractor")
                break
            }
        }
        try check(scene.snowplowPasses[floor.id] != nil, "fixture reached the visible tractor pass")

        scene.snowplowPasses = [:]
        snow.clearAll(); snow.syncSurfaces([floor]); duck.sync(snow.surfaces); duck.clear()
        for _ in 0..<20 { step() }
        guard let pose = duck.pose, snow.placeSnowman(on: floor, x: pose.feet.x) else {
            throw DuckRenderFailure(description: "overlapping snowman fixture unavailable")
        }
        scene.update(30)
        guard let layer = scene.childNode(withName: "duck-layer"),
              let duckTexture = view.texture(from: layer, crop: CGRect(origin: .zero, size: display.size)),
              let sceneTexture = view.texture(from: scene, crop: CGRect(origin: .zero, size: display.size)) else {
            throw DuckRenderFailure(description: "overlapping scene texture unavailable")
        }
        let duckImage = NSBitmapImageRep(cgImage: duckTexture.cgImage())
        let sceneImage = NSBitmapImageRep(cgImage: sceneTexture.cgImage())
        let pixelX = Int(pose.feet.x - display.minX - 2)
        let pixelY = duckImage.pixelsHigh - 1 - Int(pose.feet.y - display.minY + 10)
        guard let duckColor = duckImage.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB),
              let sceneColor = sceneImage.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB) else {
            throw DuckRenderFailure(description: "overlapping body pixel unavailable")
        }
        let difference = abs(duckColor.redComponent - sceneColor.redComponent)
            + abs(duckColor.greenComponent - sceneColor.greenComponent)
            + abs(duckColor.blueComponent - sceneColor.blueComponent)
        try check(duckColor.alphaComponent > 0.9 && difference < 0.08,
                  "duck body pixels remain in front of an overlapping snowman")
        try export("07-duck-in-front-of-snowman")

        // Exercise the production model and SpriteKit artwork together, with
        // deterministic seeds and the real timing of each selected activity.
        let lifeFloor = SnowSurface(id: "life-floor", frame: CGRect(x: -120, y: -51, width: 280, height: 1), kind: .floor)
        let lifeDisplay = DuckDisplay(frame: display, visibleTop: 320)
        for (kind, expected): (String, Set<DuckActivity>) in [
            ("ambient", [.stretch, .shake, .listen]),
            ("tree", [.inspectTree, .restByTree, .inspectLights]),
            ("snowman", [.greet, .guardSnowman, .bowSnowman])
        ] {
            var images: [DuckActivity: Data] = [:]
            for seed in 1...24 where images.count < expected.count {
                let lifeSnow = SnowWorld(), lifeTrees = FestiveWorld(), lifeDuck = DuckWorld(seed: UInt64(seed))
                lifeSnow.syncSurfaces([lifeFloor]); lifeDuck.setEnabled(true, surfaces: lifeSnow.surfaces)
                if kind == "tree" {
                    guard lifeTrees.place(at: CGPoint(x: -10, y: lifeFloor.top + 2), displayFrame: display, snow: lifeSnow) != nil else {
                        throw DuckRenderFailure(description: "life tree fixture unavailable")
                    }
                } else if kind == "snowman" {
                    try check(lifeSnow.placeSnowman(on: lifeFloor, x: -10), "life snowman fixture")
                }
                let lifeScene = SnowScene(world: lifeSnow, displayFrame: display, festiveWorld: lifeTrees)
                lifeScene.duckWorld = lifeDuck
                view.presentScene(lifeScene)
                for _ in 0..<600 where images.count < expected.count {
                    lifeDuck.advance(delta: 0.1, snow: lifeSnow, trees: lifeTrees, treesEnabled: kind == "tree",
                                     displays: [lifeDisplay], allDisplayFrames: [display], plows: [:], sweeps: [], reducedMotion: false)
                    guard let lifePose = lifeDuck.pose, expected.contains(lifePose.activity),
                          images[lifePose.activity] == nil, lifePose.time >= 0.5 else { continue }
                    lifeScene.update(1)
                    guard let actor = lifeScene.childNode(withName: "duck-layer")?.childNode(withName: "duck"),
                          !actor.isHidden, let texture = view.texture(from: actor),
                          let data = NSBitmapImageRep(cgImage: texture.cgImage()).representation(using: .png, properties: [:]) else {
                        throw DuckRenderFailure(description: "life activity image unavailable")
                    }
                    images[lifePose.activity] = data
                    try data.write(to: directory.appendingPathComponent("life-\(kind)-\(lifePose.activity).png"))
                }
            }
            try check(Set(images.keys) == expected, "every \(kind) activity is displayed")
            try check(Set(images.values).count == expected.count, "\(kind) activity images have distinct poses")
        }
        print("PASS DuckRender: \(count) checks")
    }
}
