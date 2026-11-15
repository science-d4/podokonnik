import AppKit
import SpriteKit

private struct DepthFailure: Error, CustomStringConvertible { let description: String }

@main
enum WindowContentDepthRenderTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let display = CGRect(x: 0, y: 0, width: 400, height: 350)
        let treeRoof = SnowSurface(id: "tree", frame: CGRect(x: 40, y: 60, width: 320, height: 140), kind: .window)
        let snowRoof = SnowSurface(id: "snow", frame: CGRect(x: 40, y: 60, width: 320, height: 140), kind: .window)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw DepthFailure(description: message) }
            checks += 1
        }
        for snowman in [false, true] {
            let snow = SnowWorld(seed: 81), trees = FestiveWorld()
            snow.syncSurfaces([snowRoof])
            if snowman {
                try check(snow.placeSnowman(on: snowRoof, x: 200), "Create attached snowman")
            } else {
                for _ in 0..<1500 {
                    snow.step(delta: 0.1, weather: SnowWeather(intensity: .blizzard), activeRegions: [display])
                }
            }
            snow.syncSurfaces([treeRoof, snowRoof])
            try check(trees.place(at: CGPoint(x: 200, y: treeRoof.top + 2), displayFrame: display, snow: snow) != nil,
                      "Create tree on its own window")
            let scene = SnowScene(world: snow, displayFrame: display, festiveWorld: trees)
            scene.decorationOptions = FestiveOptions(christmasTrees: true, duck: false)
            let view = SKView(frame: display); view.isPaused = true; view.allowsTransparency = true
            view.ignoresSiblingOrder = true
            let host = NSWindow(contentRect: display, styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false; host.contentView = view; view.presentScene(scene)
            defer { view.presentScene(nil); host.close() }
            func bitmap() throws -> NSBitmapImageRep {
                guard let texture = view.texture(from: scene, crop: display) else { throw DepthFailure(description: "No SpriteKit image") }
                return NSBitmapImageRep(cgImage: texture.cgImage())
            }
            for treeInFront in [true, false] {
                var tree = treeRoof, other = snowRoof
                if treeInFront { other.occluders = [tree.frame]; other.bodyOccluders = [tree.frame] }
                else { tree.occluders = [other.frame]; tree.bodyOccluders = [other.frame] }
                // A foreground panel also intersects both objects. This exercises
                // the snowball crop path as well as ordinary unmasked rendering.
                let panel = CGRect(x: 196, y: 226, width: 8, height: 8)
                tree.occluders.append(panel); tree.bodyOccluders.append(panel)
                other.occluders.append(panel); other.bodyOccluders.append(panel)
                snow.syncSurfaces(treeInFront ? [tree, other] : [other, tree])
                scene.update(treeInFront ? 1 : 2)
                guard let decorations = scene.children.first(where: { $0 is FestiveLayer }),
                      let objects = scene.children.first(where: { $0.zPosition == 10 && !($0 is FestiveLayer) }) else {
                    throw DepthFailure(description: "Production layers unavailable")
                }
                let both = try bitmap()
                objects.isHidden = true; let onlyTree = try bitmap(); objects.isHidden = false
                decorations.isHidden = true; let onlySnow = try bitmap(); decorations.isHidden = false
                if snowman {
                    let px = Int(panel.midX * CGFloat(onlySnow.pixelsWide) / display.width)
                    let py = onlySnow.pixelsHigh - 1 - Int(panel.midY * CGFloat(onlySnow.pixelsHigh) / display.height)
                    try check((onlySnow.colorAt(x: px, y: py)?.alphaComponent ?? 1) < 0.01,
                              "Foreground panel clips the attached snowman")
                }
                var overlap = 0, correct = 0
                for y in 0..<both.pixelsHigh {
                    for x in 0..<both.pixelsWide {
                        guard let a = onlyTree.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              let b = onlySnow.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              let actual = both.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              a.alphaComponent > 0.99, b.alphaComponent > 0.99 else { continue }
                        func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
                            abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent)
                                + abs(lhs.blueComponent - rhs.blueComponent)
                        }
                        guard distance(a, b) > 0.4 else { continue }
                        overlap += 1
                        if distance(actual, treeInFront ? a : b) < 0.12 { correct += 1 }
                    }
                }
                try check(overlap > 20, "Fixture must contain opaque overlapping pixels")
                try check(Double(correct) / Double(overlap) > 0.95,
                          "\(snowman ? "Snowman" : "Snow") and tree follow window order, tree front=\(treeInFront): \(correct)/\(overlap)")
            }
        }
        print("Window content depth: \(checks) checks passed")
    }
}
