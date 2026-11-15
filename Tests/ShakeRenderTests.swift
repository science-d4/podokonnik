import AppKit
import SpriteKit

private struct ShakeRenderFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum ShakeRenderTests {
    private static let display = CGRect(x: 0, y: 0, width: 1120, height: 720)
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw ShakeRenderFailure(description: message) }
    }

    private static func advance(_ world: SnowWorld, seconds: Double) {
        for _ in 0..<Int((seconds * 120).rounded()) {
            world.step(delta: 1.0 / 120, weather: SnowWeather(intensity: .light), activeRegions: [display])
        }
    }

    private static func metrics(_ url: URL) throws -> (area: Double, centerX: Double) {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)), let image = bitmap.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data else {
            throw ShakeRenderFailure(description: "Cannot measure own PNG")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = bytes.assumingMemoryBound(to: UInt8.self)
        let scale = Double(image.width) / Double(display.width)
        var sum = 0.0, weightedX = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = Double(data[(y * image.width + x) * 4 + 3]) / 255
                sum += alpha
                weightedX += alpha * Double(x)
            }
        }
        return (sum / (scale * scale), sum > 0 ? weightedX / sum / scale : 0)
    }

    private static func backdrop(window: CGRect) -> SKNode {
        let root = SKNode(); root.zPosition = -100
        let background = SKSpriteNode(color: NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.11, alpha: 1), size: display.size)
        background.anchorPoint = .zero; background.position = .zero; root.addChild(background)
        let shadow = SKShapeNode(path: CGPath(roundedRect: window.offsetBy(dx: 0, dy: -8), cornerWidth: 18, cornerHeight: 18, transform: nil))
        shadow.fillColor = NSColor.black.withAlphaComponent(0.35); shadow.strokeColor = .clear; root.addChild(shadow)
        let panel = SKShapeNode(path: CGPath(roundedRect: window, cornerWidth: 16, cornerHeight: 16, transform: nil))
        panel.fillColor = NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.27, alpha: 1)
        panel.strokeColor = NSColor.white.withAlphaComponent(0.12); panel.lineWidth = 1; root.addChild(panel)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = SKShapeNode(circleOfRadius: 5)
            dot.position = CGPoint(x: window.minX + 22 + CGFloat(index) * 18, y: window.maxY - 23)
            dot.fillColor = color; dot.strokeColor = .clear; root.addChild(dot)
        }
        let title = SKLabelNode(fontNamed: "HelveticaNeue-Medium")
        title.text = "Подоконник · собственная тестовая сцена"
        title.fontSize = 18; title.fontColor = .white
        title.position = CGPoint(x: window.midX, y: window.midY - 5); root.addChild(title)
        let arrow = SKLabelNode(fontNamed: "HelveticaNeue")
        arrow.text = "рывок окна →      снег остаётся позади"
        arrow.fontSize = 16; arrow.fontColor = NSColor(calibratedWhite: 0.76, alpha: 1)
        arrow.position = CGPoint(x: display.midX, y: 650); root.addChild(arrow)
        return root
    }

    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var support = SnowSurface(id: "own-shake-window", frame: CGRect(x: 260, y: 280, width: 640, height: 180), kind: .window)
        support.topInset = 16
        let world = SnowWorld(seed: 27)
        world.syncSurfaces([support]); world.prune(to: [display])
        for _ in 0..<1500 { world.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [display]) }
        support.isVisible = false; world.syncSurfaces([support]); advance(world, seconds: 1.6)
        support.isVisible = true; support.frame.origin.x += 60
        world.syncSurfaces([support])
        // Keep the pointer held for the entire sequence, including expiry.
        world.setObjectsFrozen(true)
        world.shedSnow(surfaceID: support.id, velocity: CGVector(dx: 1200, dy: 0))
        try check(world.debris.count > 48 && world.debris.count <= 96, "Filled fixture must emit a dense bounded trail")
        try check(world.drifts[support.id]!.heights.allSatisfy { $0 == 0 }, "The source drift disappears immediately")
        // Stop deposition, keeping only the actual emitted debris in alpha measurements.
        support.isVisible = false; world.syncSurfaces([support])
        let scene = SnowScene(world: world, displayFrame: display)
        let view = SKView(frame: display); view.allowsTransparency = true; view.isPaused = true
        let host = NSWindow(contentRect: display, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = view; view.presentScene(scene)
        defer { view.presentScene(nil); host.close() }
        let stage = backdrop(window: support.frame)
        let caption = SKLabelNode(fontNamed: "HelveticaNeue-Medium")
        caption.fontSize = 20; caption.fontColor = .white; caption.position = CGPoint(x: display.midX, y: 58)
        stage.addChild(caption)
        var measurements: [(time: Double, area: Double, centerX: Double, count: Int)] = []
        var previous = 0.0
        for time in [0.0, 0.3, 0.8, 1.3, 1.6] {
            advance(world, seconds: time - previous); previous = time
            let name = String(format: "%.1f", time)
            let alphaURL = directory.appendingPathComponent("trail-\(name).png")
            try check(scene.exportPreview(to: alphaURL), "Export production debris at \(name)s")
            let result = try metrics(alphaURL)
            measurements.append((time, result.area, result.centerX, world.debris.count))
            if time != 1.3 {
                caption.text = "После рывка: \(name) с"
                scene.addChild(stage)
                try check(scene.exportPreview(to: directory.appendingPathComponent("scene-\(name).png")), "Export own backdrop at \(name)s")
                stage.removeFromParent()
            }
            print("shake t=\(name)s fragments=\(world.debris.count) alphaArea=\(result.area) centerX=\(result.centerX)")
        }
        let start = measurements[0], early = measurements[1], trail = measurements[2], fade = measurements[3], end = measurements[4]
        try check(start.area > 900, "The initial trail needs substantial visible pixel area")
        try check(early.area > start.area * 0.5 && trail.area > start.area * 0.4,
                  "Actual renderer alpha must remain visible at 0.3 and 0.8 seconds")
        try check(trail.centerX < start.centerX - 150, "Rendered trail travels against the rightward jerk")
        try check(fade.area > 0 && fade.area < trail.area * 0.3, "The final half-second fades smoothly before removal")
        try check(end.area < 0.01 && end.count == 0, "No stale visible nodes remain after 1.6 seconds")
        let json: [[String: Any]] = measurements.map { ["seconds": $0.time, "alphaArea": $0.area, "centerX": $0.centerX, "fragments": $0.count] }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("metrics.json"))
        print("Shake renderer: \(checks) checks passed; own synthetic scene only")
    }
}
