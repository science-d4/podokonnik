import AppKit
import SpriteKit

@main
enum SnowplowRenderTests {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = CGRect(x: 0, y: 0, width: 600, height: 180)
        let world = SnowWorld(seed: 7)
        var floor = SnowSurface(id: "floor", frame: CGRect(x: 0, y: 0, width: 600, height: 0), kind: .floor)
        world.syncSurfaces([floor]); world.prune(to: [frame])
        for _ in 0..<600 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame]) }
        var scene = SnowScene(world: world, displayFrame: frame)
        let view = SKView(frame: frame); view.allowsTransparency = true
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.presentScene(scene)
        defer { view.presentScene(nil); window.close() }
        var schedule = SnowplowSchedule(); schedule.requestSweep()
        for _ in 0..<215 {
            world.step(delta: 1.0 / 120, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame])
            for sweep in schedule.advance(delta: 1.0 / 120, surfaces: [floor], activeRegions: [frame], intervalMinutes: 10) {
                world.sweepFloor(surfaceID: sweep.surfaceID, fromX: sweep.fromX, toX: sweep.toX)
            }
        }
        // Inspect the settled lane independently of flying particles from the snowbank.
        var hiddenFloor = floor; hiddenFloor.isVisible = false
        world.syncSurfaces([hiddenFloor])
        for _ in 0..<12 { world.step(delta: 0.1, weather: SnowWeather(), activeRegions: [frame]) }
        world.syncSurfaces([floor])
        scene.snowplowPasses = schedule.passes
        let pass = schedule.passes[floor.id]!
        func render(_ name: String) throws -> NSBitmapImageRep {
            let url = directory.appendingPathComponent(name)
            precondition(scene.exportPreview(to: url), "Own tractor scene exports")
            return NSBitmapImageRep(data: try Data(contentsOf: url))!
        }
        func alpha(_ bitmap: NSBitmapImageRep, region: CGRect) -> Int {
            let scale = CGFloat(bitmap.pixelsWide) / frame.width
            var result = 0
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
                    if (bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)?.alphaComponent ?? 0) > 0.1 { result += 1 }
                }
            }
            return result
        }
        let clean = try render("tractor.png")
        precondition(alpha(clean, region: CGRect(x: 5, y: 0, width: 100, height: 60)) == 0, "Traversed snow is cleared")
        precondition(alpha(clean, region: CGRect(x: 450, y: 0, width: 100, height: 30)) > 100, "Future snow remains")
        precondition(alpha(clean, region: CGRect(x: pass.x - 35, y: 30, width: 35, height: 30)) > 100, "Tractor cab is visible")
        // Isolate the vehicle mask from airborne debris produced by the snowfall fixture.
        scene = SnowScene(world: SnowWorld(), displayFrame: frame)
        view.presentScene(scene)
        floor.occluders = [CGRect(x: pass.x - 50, y: 0, width: 100, height: 100)]
        var hidden = pass; hidden.surface = floor; scene.snowplowPasses = [floor.id: hidden]
        let masked = try render("tractor-occluded.png")
        precondition(alpha(masked, region: CGRect(x: pass.x - 40, y: 0, width: 80, height: 60)) == 0, "Tractor stays behind foreground geometry")
        scene.snowplowPasses = [:]
        let finished = try render("tractor-finished.png")
        precondition(alpha(finished, region: CGRect(x: pass.x - 35, y: 30, width: 35, height: 30)) == 0, "Finished pass removes tractor visual")
        print("Snowplow render: 5 checks passed; own synthetic scene only")
    }
}
