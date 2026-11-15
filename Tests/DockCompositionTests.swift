import AppKit
import SpriteKit

@main
enum DockCompositionTests {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let display = CGRect(x: 0, y: 0, width: 600, height: 180)
        let list = CGRect(x: 130, y: 10, width: 340, height: 68)
        let items = (0..<5).map { CGRect(x: 142 + CGFloat($0) * 68, y: 5, width: 52, height: 68) }
        let contact = DesktopGeometry.dockSupportFrame(for: list, itemFrames: items)
        precondition(contact.maxY == 73 && contact.minX == list.minX && contact.width == list.width)
        var dock = SnowSurface(id: "fixture-dock-contact", frame: list, kind: .dock)
        dock.topInset = DesktopGeometry.dockTopInset(for: list)
        var floor = SnowSurface(id: "fixture-floor", frame: CGRect(x: 0, y: 0, width: 600, height: 0), kind: .floor)
        let world = SnowWorld(seed: 27)
        world.syncSurfaces([dock, floor]); world.prune(to: [display])
        for _ in 0..<1500 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [display]) }
        var hiddenDock = dock; hiddenDock.isVisible = false
        var hiddenFloor = floor; hiddenFloor.isVisible = false
        world.syncSurfaces([hiddenDock, hiddenFloor])
        for _ in 0..<12 { world.step(delta: 0.1, weather: SnowWeather(), activeRegions: [display]) }

        let scene = SnowScene(world: world, displayFrame: display)
        let view = SKView(frame: display); view.allowsTransparency = true
        let host = NSWindow(contentRect: display, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = view; view.presentScene(scene)
        defer { view.presentScene(nil); host.close() }
        // Our own foreground panel represents native rounded compositing. Its
        // silhouette is intentionally distinct from the logical AX hit rectangle.
        let panel = SKShapeNode(path: CGPath(roundedRect: contact, cornerWidth: 31.5, cornerHeight: 31.5, transform: nil))
        panel.fillColor = NSColor(calibratedRed: 0.16, green: 0.23, blue: 0.31, alpha: 1)
        panel.strokeColor = .clear; panel.lineWidth = 0; panel.zPosition = 1000
        scene.addChild(panel)
        func render(_ name: String) throws -> NSBitmapImageRep {
            let url = directory.appendingPathComponent(name)
            precondition(scene.exportPreview(to: url))
            return NSBitmapImageRep(data: try Data(contentsOf: url))!
        }
        func alpha(_ image: NSBitmapImageRep, _ point: CGPoint) -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / display.width
            return image.colorAt(x: Int(point.x * scale), y: image.pixelsHigh - 1 - Int(point.y * scale))?.alphaComponent ?? 0
        }
        floor.occluders = [list]
        world.syncSurfaces([dock, floor])
        let before = try render("old-logical-rectangle.png")
        let left = CGPoint(x: list.minX + 2, y: list.minY + 2)
        let right = CGPoint(x: list.maxX - 3, y: list.minY + 2)
        let gap = CGPoint(x: list.midX, y: contact.maxY + 2)
        precondition(alpha(before, left) < 0.1 && alpha(before, right) < 0.1, "Old rectangle reproduces square cuts beside the rounded panel")
        precondition(alpha(before, gap) < 0.1, "Raw list top reproduces the support gap")

        dock.frame = contact; dock.topInset = DesktopGeometry.dockTopInset(for: contact)
        floor.occluders = []
        world.syncSurfaces([dock, floor])
        let after = try render("native-shape-and-contact.png")
        precondition(alpha(after, left) > 0.9 && alpha(after, right) > 0.9, "Snow remains around both rounded lower corners")
        for y in stride(from: contact.maxY - 2, through: contact.maxY + 4, by: 1) {
            precondition(alpha(after, CGPoint(x: list.midX, y: y)) > 0.9, "No transparent row between support and snow")
        }
        print("Dock composition: old cuts/gap reproduced; both rounded corners restored and 7 contact rows joined; own scene only")
    }
}
