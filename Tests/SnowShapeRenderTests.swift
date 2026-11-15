import AppKit
import SpriteKit

@main
enum SnowShapeRenderTests {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = CGRect(x: 0, y: 0, width: 900, height: 360)
        var dock = SnowSurface(id: "fixture-dock", frame: CGRect(x: 80, y: 30, width: 740, height: 68), kind: .dock)
        dock.topInset = DesktopGeometry.dockTopInset(for: dock.frame)
        var window = SnowSurface(id: "fixture-window", frame: CGRect(x: 30, y: 180, width: 840, height: 120), kind: .window)
        window.topInset = DesktopGeometry.windowTopInset(for: window.frame)
        let world = SnowWorld(seed: 11)
        world.syncSurfaces([window, dock]); world.prune(to: [frame])
        for _ in 0..<1500 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [frame]) }
        precondition(world.drifts[dock.id]!.heights.allSatisfy { $0 <= 22 }, "Saturated Dock respects the smaller physical cap")
        precondition(world.drifts[window.id]!.heights.max()! > 22, "Window snow retains the existing taller envelope")
        // Age airborne debris without changing the settled profiles being measured.
        var hiddenWindow = window; hiddenWindow.isVisible = false
        var hiddenDock = dock; hiddenDock.isVisible = false
        world.syncSurfaces([hiddenWindow, hiddenDock])
        for _ in 0..<12 { world.step(delta: 0.1, weather: SnowWeather(), activeRegions: [frame]) }
        world.syncSurfaces([window, dock])
        let scene = SnowScene(world: world, displayFrame: frame)
        let view = SKView(frame: frame); view.allowsTransparency = true
        let host = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = view; view.presentScene(scene)
        defer { view.presentScene(nil); host.close() }
        let url = directory.appendingPathComponent("profiles.png")
        precondition(scene.exportPreview(to: url))
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
        let scale = CGFloat(bitmap.pixelsWide) / frame.width
        func alpha(x: CGFloat, y: CGFloat) -> CGFloat {
            bitmap.colorAt(x: Int(x * scale), y: bitmap.pixelsHigh - 1 - Int(y * scale))?.alphaComponent ?? 0
        }
        // A fully transparent fixed gap here is the Dock's rounded cap policy.
        var cornerPixels = 0
        for x in stride(from: dock.frame.minX, to: dock.frame.minX + dock.topInset - 2, by: 1) {
            for y in stride(from: dock.top - 1, to: dock.top + 4, by: 1) {
                if alpha(x: x, y: y) > 0.1 { cornerPixels += 1 }
            }
        }
        for x in stride(from: dock.frame.maxX - dock.topInset + 2, to: dock.frame.maxX, by: 1) {
            for y in stride(from: dock.top - 1, to: dock.top + 4, by: 1) {
                if alpha(x: x, y: y) > 0.1 { cornerPixels += 1 }
            }
        }
        precondition(cornerPixels == 0, "Dock snow cannot reach either rounded corner")
        let drift = world.drifts[window.id]!
        let candidates = Array(25..<(drift.heights.count - 25))
        let high = candidates.max { drift.heights[$0] < drift.heights[$1] }!
        let low = candidates.min { drift.heights[$0] < drift.heights[$1] }!
        func ridge(_ index: Int) -> CGFloat {
            let x = window.frame.minX + CGFloat(index) * SnowDrift.spacing
            return Array(stride(from: CGFloat(0), through: 32, by: 1)).last { alpha(x: x, y: window.top + $0) > 0.5 } ?? 0
        }
        let highPixel = ridge(high), lowPixel = ridge(low)
        precondition(highPixel - lowPixel > 4, "Saturated rendered snow must retain distinct hills and valleys")

        // Add only our own simple support artwork for a readable visual preview.
        for (surface, radius) in [(window, CGFloat(16)), (dock, CGFloat(32))] {
            let body = SKShapeNode(path: CGPath(roundedRect: surface.frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            body.fillColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.32, alpha: 1)
            body.strokeColor = NSColor(calibratedRed: 0.35, green: 0.44, blue: 0.53, alpha: 1)
            body.lineWidth = 1; body.zPosition = -10; scene.addChild(body)
        }
        precondition(scene.exportPreview(to: directory.appendingPathComponent("profiles-preview.png")))
        print("Snow shape render: Dock corner pixels=\(cornerPixels), saturated ridge range=\(lowPixel)...\(highPixel) pt; own scene only")
    }
}
