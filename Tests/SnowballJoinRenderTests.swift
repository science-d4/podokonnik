import AppKit
import SpriteKit

private struct JoinRenderFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum SnowballJoinRenderTests {
    private static var checks = 0
    private static let region = CGRect(x: 0, y: 0, width: 2200, height: 360)
    private static let crop = CGRect(x: 0, y: 0, width: 360, height: 300)

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw JoinRenderFailure(description: message) }
    }

    private static func advance(_ world: SnowWorld, seconds: Double, intensity: SnowIntensity = .light) {
        for _ in 0..<Int((seconds * 120).rounded()) {
            world.step(delta: 1.0 / 120, weather: SnowWeather(intensity: intensity), activeRegions: [region])
        }
    }

    private static func ball(_ world: SnowWorld, id: UUID) -> Snowball {
        world.balls.first { $0.id == id }!
    }

    private static func makeBall(_ world: SnowWorld, floor: SnowSurface, radius: CGFloat, x: CGFloat) throws -> UUID {
        let pointer = CGPoint(x: x, y: floor.top + 5)
        guard let id = world.beginSnowball(at: pointer) else {
            throw JoinRenderFailure(description: "Cannot create radius \(radius) fixture at \(x)")
        }
        // Roll through fresh snow using public gestures. Small steps bound radius
        // error without reproducing the production mass/growth calculation.
        for step in 1...1800 {
            if ball(world, id: id).radius >= radius { break }
            world.drag(to: CGPoint(x: x + CGFloat(step) * 0.25, y: pointer.y))
        }
        world.endDrag()
        let actual = ball(world, id: id).radius
        try check(abs(actual - radius) < 0.06, "Requested radius \(radius), actual \(actual)")
        return id
    }

    private static func place(_ world: SnowWorld, id: UUID, at destination: CGPoint) throws {
        let current = ball(world, id: id)
        try check(world.beginDrag(at: current.position) == id, "Pick up the intended ball")
        world.drag(to: CGPoint(x: current.position.x, y: 280))
        world.drag(to: CGPoint(x: destination.x, y: 280))
        world.drag(to: destination)
        world.endDrag()
        advance(world, seconds: 1.2)
    }

    private static func alpha(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
        let scale = CGFloat(bitmap.pixelsWide) / crop.width
        let px = min(bitmap.pixelsWide - 1, max(0, Int(x * scale)))
        let py = min(bitmap.pixelsHigh - 1, max(0, Int(y * scale)))
        return bitmap.colorAt(x: px, y: bitmap.pixelsHigh - 1 - py)?.alphaComponent ?? 0
    }

    private static func run(_ radii: [CGFloat], name: String, directory: URL) throws {
        let world = SnowWorld(seed: 29)
        let floor = SnowSurface(id: "join-floor", frame: CGRect(x: 0, y: 20, width: region.width, height: 0), kind: .floor)
        world.syncSurfaces([floor]); world.prune(to: [region])
        for _ in 0..<1500 {
            world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [region])
        }
        var ids: [UUID] = []
        for (index, radius) in radii.enumerated() {
            ids.append(try makeBall(world, floor: floor, radius: radius, x: 600 + CGFloat(index) * 500))
        }
        // Remove the measurement lane's drift, not the balls or their future links.
        world.sweepFloor(surfaceID: floor.id, fromX: 0, toX: crop.width)
        for (index, id) in ids.enumerated() {
            let current = ball(world, id: id)
            let y: CGFloat
            if index == 0 { y = floor.top + current.radius + 2 }
            else {
                let support = ball(world, id: ids[index - 1])
                y = support.position.y + support.radius + current.radius + 5
            }
            try place(world, id: id, at: CGPoint(x: 180, y: y))
        }
        // No snowfall renderer update is needed: exportPreview renders the actual
        // production ball tree. Aging model debris avoids unrelated alpha in gaps.
        advance(world, seconds: 1.3)
        let scene = SnowScene(world: world, displayFrame: crop)
        let view = SKView(frame: crop); view.allowsTransparency = true; view.isPaused = true
        let host = NSWindow(contentRect: crop, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = view; view.presentScene(scene)
        defer { view.presentScene(nil); host.close() }
        func render(_ suffix: String) throws -> NSBitmapImageRep {
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            try check(scene.exportPreview(to: url), "Export own production ball scene")
            guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw JoinRenderFailure(description: "Invalid exported PNG")
            }
            return bitmap
        }
        let joined = try render("joined")
        let scale = CGFloat(joined.pixelsWide) / crop.width
        for index in 1..<ids.count {
            let lower = ball(world, id: ids[index - 1]), upper = ball(world, id: ids[index])
            let distance = hypot(upper.position.x - lower.position.x, upper.position.y - lower.position.y)
            let sum = lower.radius + upper.radius
            try check(upper.surfaceID == floor.id && distance <= sum + 0.05 && distance > sum * 0.85,
                      "Settled contact must join without a gap or collapsed balls: \(name), distance=\(distance), radii=\(sum)")
            var minimumAlpha: CGFloat = 1
            for row in Int(ceil(lower.position.y * scale))...Int((upper.position.y * scale).rounded(.down)) {
                let y = (CGFloat(row) + 0.5) / scale
                for dx in stride(from: CGFloat(-1), through: 1, by: 1 / scale) {
                    minimumAlpha = min(minimumAlpha, alpha(joined, x: lower.position.x + dx, y: y))
                }
            }
            print("\(name) join\(index): radii=\(lower.radius),\(upper.radius), centers=\(distance), bridge alpha=\(minimumAlpha), scale=\(scale)")
            try check(minimumAlpha >= 0.75, "Production texture needs a continuous opaque 2pt neck: \(name), alpha=\(minimumAlpha)")
        }
        if ids.count == 3 {
            try check(world.snowmen.count == 1 && world.snowmen[0].ballIDs == ids, "Settled mixed sizes form a decorated snowman")
        }
        let bottom = ball(world, id: ids[0]), head = ball(world, id: ids.last!)
        let physicalHeight = head.position.y + head.radius - (bottom.position.y - bottom.radius)
        try check(physicalHeight <= ids.reduce(CGFloat(0)) { $0 + ball(world, id: $1).radius * 2 } + 0.05,
                  "Stack height cannot exceed the sum of ball diameters")

        let lower = ball(world, id: ids[ids.count - 2])
        try check(world.beginDrag(at: head.position) == head.id, "Lift selects the head")
        world.drag(to: CGPoint(x: head.position.x, y: head.position.y + 28))
        let raised = ball(world, id: head.id)
        try check(raised.surfaceID == nil && raised.position.y - head.position.y > 27.9 && world.snowmen.isEmpty,
                  "Lifting detaches the ball and dismantles the snowman")
        let lifted = try render("lifted")
        let gapY = (lower.position.y + lower.radius + raised.position.y - raised.radius) * 0.5
        var gapAlpha: CGFloat = 0
        for dx in stride(from: CGFloat(-2), through: 2, by: 1 / scale) {
            gapAlpha = max(gapAlpha, alpha(lifted, x: head.position.x + dx, y: gapY))
        }
        try check(gapAlpha < 0.05, "Lifted balls must have a transparent separation: \(name), alpha=\(gapAlpha)")
        world.endDrag()
    }

    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run([8, 8], name: "pair-8", directory: directory)
        try run([18, 18], name: "pair-18", directory: directory)
        try run([36, 36], name: "pair-36", directory: directory)
        try run([36, 18, 8], name: "snowman-36-18-8", directory: directory)
        try run([36, 24, 14], name: "snowman-36-24-14", directory: directory)
        print("Snowball joins: \(checks) checks passed; own synthetic world/GPU textures only")
    }
}
