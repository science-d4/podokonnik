import AppKit
import SpriteKit

private struct FestiveRenderFailure: Error, CustomStringConvertible { let description: String }
@main
enum FestiveRenderTests {
    private static var checks = 0
    private static let display = CGRect(x: -100, y: -50, width: 960, height: 640)
    private static let visible = CGRect(x: -100, y: -50, width: 960, height: 612)
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw FestiveRenderFailure(description: message) }
    }
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snow = SnowWorld(), world = FestiveWorld()
        var rear = SnowSurface(id: "rear", frame: CGRect(x: 90, y: 100, width: 480, height: 275), kind: .window, topInset: 16)
        var front = SnowSurface(id: "front", frame: CGRect(x: 390, y: 180, width: 280, height: 290), kind: .window, topInset: 16)
        let floor = SnowSurface(id: "floor", frame: CGRect(x: display.minX, y: display.minY, width: display.width, height: 0), kind: .floor)
        rear.occluders = [front.frame]; rear.bodyOccluders = [front.frame]
        snow.syncSurfaces([front, rear, floor]); snow.prune(to: [display])
        let layer = FestiveLayer(world: world)
        let scene = SKScene(size: display.size); scene.scaleMode = .resizeFill; scene.backgroundColor = .clear
        let background = SKSpriteNode(color: NSColor(calibratedRed: 0.045, green: 0.085, blue: 0.14, alpha: 1), size: display.size)
        background.anchorPoint = .zero; background.zPosition = -20; scene.addChild(background)
        func window(_ surface: SnowSurface, tint: NSColor) -> SKShapeNode {
            let rect = surface.frame.offsetBy(dx: -display.minX, dy: -display.minY)
            let node = SKShapeNode(rect: rect, cornerRadius: 14)
            node.fillColor = tint; node.strokeColor = NSColor(white: 0.7, alpha: 0.15); node.lineWidth = 1
            node.zPosition = -10; scene.addChild(node)
            return node
        }
        let backWindow = window(rear, tint: NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.22, alpha: 1))
        let frontWindow = window(front, tint: NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.29, alpha: 1))
        scene.addChild(layer)
        let view = SKView(frame: CGRect(origin: .zero, size: display.size)); view.isPaused = true; view.allowsTransparency = true
        let host = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = view; view.presentScene(scene)
        defer { view.presentScene(nil); host.close() }
        var time: Double = 0
        var options = FestiveOptions()
        var weather = SnowWeather()
        func update(_ delta: Double = 0) {
            time += delta
            layer.update(options: options, snow: snow, displayFrame: display, visibleFrame: visible, delta: delta, time: time, weather: weather)
        }
        func bitmap(_ node: SKNode) throws -> NSBitmapImageRep {
            guard let texture = view.texture(from: node, crop: CGRect(origin: .zero, size: display.size)) else {
                throw FestiveRenderFailure(description: "Own SpriteKit preview unavailable")
            }
            return NSBitmapImageRep(cgImage: texture.cgImage())
        }
        func export(_ name: String) throws {
            let image = try bitmap(scene)
            guard let data = image.representation(using: .png, properties: [:]) else { throw FestiveRenderFailure(description: "PNG encoding failed") }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func alpha(_ image: NSBitmapImageRep, worldPoint: CGPoint) -> CGFloat {
            let x = min(image.pixelsWide - 1, max(0, Int((worldPoint.x - display.minX) / display.width * CGFloat(image.pixelsWide))))
            let y = min(image.pixelsHigh - 1, max(0, Int((worldPoint.y - display.minY) / display.height * CGFloat(image.pixelsHigh))))
            return image.colorAt(x: x, y: image.pixelsHigh - 1 - y)?.alphaComponent ?? 0
        }
        for _ in 0..<200 { update(1.0 / 60) }
        try check(layer.children.isEmpty && layer.rasterizations == 0 && layer.maskRebuilds == 0 && layer.enabledNodeCount == 0,
                  "Default-off neither creates textures/nodes nor builds masks")
        try export("00-off")
        options.desktopGarland = true; update()
        try check(layer.enabledNodeCount > 0, "Desktop garland can be enabled independently")
        let desktopOnly = try bitmap(layer)
        try check(alpha(desktopOnly, worldPoint: CGPoint(x: visible.minX + 18, y: visible.maxY - 16)) > 0.05,
                  "Desktop lights exist near the visible top edge")
        try export("01-desktop-garland")
        options.desktopGarland = false; options.windowGarlands = true; update()
        let windowsOnly = try bitmap(layer)
        try check(alpha(windowsOnly, worldPoint: CGPoint(x: visible.minX + 18, y: visible.maxY - 16)) < 0.01,
                  "Window mode does not enable the desktop garland")
        try check(alpha(windowsOnly, worldPoint: CGPoint(x: rear.frame.minX + 31, y: rear.top - 18)) > 0.04,
                  "Window lights lie just below their roof")
        try check(alpha(windowsOnly, worldPoint: CGPoint(x: 500, y: rear.top - 18)) < 0.01,
                  "Foreground body hides the rear window garland")
        try export("02-window-garlands")
        let rasters = layer.rasterizations, masks = layer.maskRebuilds
        for _ in 0..<120 { update(1.0 / 60) }
        try check(layer.rasterizations == rasters && layer.maskRebuilds == masks, "Stationary animation reuses textures and masks")
        front.frame.origin.x += 35; frontWindow.path = CGPath(roundedRect: front.frame.offsetBy(dx: -display.minX, dy: -display.minY), cornerWidth: 14, cornerHeight: 14, transform: nil)
        rear.bodyOccluders = [front.frame]; rear.occluders = [front.frame]
        snow.syncSurfaces([front, rear, floor]); world.syncSurfaces(snow.surfaces); update()
        try check(layer.rasterizations == rasters && layer.maskRebuilds > masks, "Moving windows updates placement/masks without rasterizing unchanged wires")
        try check(world.place(at: CGPoint(x: 220, y: rear.top + 2), displayFrame: display, snow: snow) != nil, "Place a tree on the rear roof")
        try check(world.place(at: CGPoint(x: 20, y: floor.top + 2), displayFrame: display, snow: snow) != nil, "Place a floor tree")
        try check(world.place(at: CGPoint(x: 740, y: floor.top + 2), displayFrame: display, snow: snow) != nil, "Place the third cached tree variant")
        options = FestiveOptions(desktopGarland: true, windowGarlands: true, christmasTrees: true, aurora: true, shootingStars: true)
        update()
        for _ in 0..<24 { update(0.1) }
        try check(layer.activeMeteorCount == 1, "The first meteor starts after two active seconds")
        try export("03-all-effects")
        let all = try bitmap(layer)
        try check(alpha(all, worldPoint: CGPoint(x: front.frame.midX, y: front.top - 60)) < 0.01,
                  "Desktop effects never leak inside an ordinary window")
        let tree = world.placements(in: snow).first!
        let panel = CGRect(x: tree.bounds.midX - 12, y: tree.bounds.midY - 8, width: 24, height: 45)
        rear.bodyOccluders.append(panel); rear.occluders.append(panel)
        snow.syncSurfaces([front, rear, floor]); world.syncSurfaces(snow.surfaces); update()
        let occluded = try bitmap(layer)
        try check(alpha(occluded, worldPoint: CGPoint(x: panel.midX, y: panel.midY)) < 0.01,
                  "A foreground panel clips the whole tree, not just its base")
        try export("04-tree-occluded")
        weather.reducedMotion = true; update()
        try check(layer.activeMeteorCount == 0, "Reduce Motion cancels meteors")
        let still = try bitmap(layer).representation(using: .png, properties: [:])!
        for _ in 0..<90 { update(0.1) }
        let repeated = try bitmap(layer).representation(using: .png, properties: [:])!
        try check(still == repeated, "Reduce Motion leaves lights and aurora static")
        try export("05-reduce-motion")
        let nodeCount = layer.enabledNodeCount
        let beforeOffRasters = layer.rasterizations, beforeOffMasks = layer.maskRebuilds
        options = FestiveOptions(); update()
        for _ in 0..<200 { update(0.1) }
        try check(layer.enabledNodeCount == 0 && layer.activeMeteorCount == 0 && layer.rasterizations == beforeOffRasters
                    && layer.maskRebuilds == beforeOffMasks, "Turning everything off stops animation and geometry work")
        options = FestiveOptions(desktopGarland: true, windowGarlands: true, christmasTrees: true, aurora: true, shootingStars: true)
        weather.reducedMotion = false; update()
        try check(layer.activeMeteorCount == 0 && layer.enabledNodeCount <= nodeCount + 2, "Re-enable has bounded nodes and a fresh meteor countdown")
        for _ in 0..<200 { update(0.1); try check(layer.activeMeteorCount <= 1, "At most one meteor is active") }
        try check(world.placements(in: snow).count == 3, "Decoration toggles retain tree placements")
        // Dimensions come from an actual own-app NSSpellChecker correction indicator.
        let panelSnow = SnowWorld(), panelWorld = FestiveWorld()
        var correctionPanel = SnowSurface(id: "correction", frame: CGRect(x: 300, y: 300, width: 143, height: 52), kind: .window)
        var backgroundWindow = SnowSurface(id: "correctionPanel-background", frame: CGRect(x: 120, y: 60, width: 500, height: 260), kind: .window)
        let panelLayer = FestiveLayer(world: panelWorld); scene.addChild(panelLayer)
        func updatePanel(_ surfaces: [SnowSurface]) {
            panelSnow.syncSurfaces(surfaces)
            panelLayer.update(options: FestiveOptions(windowGarlands: true), snow: panelSnow,
                displayFrame: display, visibleFrame: visible, delta: 0, time: 0, weather: SnowWeather())
        }
        updatePanel([backgroundWindow, floor])
        let withoutPanel = try bitmap(panelLayer)
        let coveredPoints = (300..<443).flatMap { x in
            (300..<320).map { y in CGPoint(x: x, y: y) }
        }.filter { alpha(withoutPanel, worldPoint: $0) > 0.05 }
        try check(!coveredPoints.isEmpty && panelLayer.windowGarlandCount == 1,
                  "A large window has a visible garland where the panel will appear")
        backgroundWindow.bodyOccluders = [correctionPanel.frame]; backgroundWindow.occluders = [correctionPanel.frame]
        updatePanel([correctionPanel, backgroundWindow, floor])
        try check(panelLayer.windowGarlandCount == 1, "A correction panel does not create a garland")
        let withPanel = try bitmap(panelLayer)
        try check(coveredPoints.allSatisfy { alpha(withPanel, worldPoint: $0) < 0.01 },
                  "A correction panel masks the rear garland")
        backgroundWindow.bodyOccluders = []; backgroundWindow.occluders = []
        updatePanel([backgroundWindow, floor])
        let afterPanel = try bitmap(panelLayer)
        try check(coveredPoints.allSatisfy { alpha(afterPanel, worldPoint: $0) > 0.05 },
                  "The rear garland reappears after the panel closes")
        for (width, height, expected) in [(159.0, 100.0, 0), (160.0, 99.0, 0), (160.0, 100.0, 1),
                                          (300.0, 52.0, 0), (143.0, 300.0, 0), (500.0, 200.0, 1),
                                          (143.0, 52.0, 0)] {
            correctionPanel.frame.size = CGSize(width: width, height: height)
            updatePanel([correctionPanel, floor])
            try check(panelLayer.windowGarlandCount == expected,
                      "Resizing around the size threshold adds and removes only the window garland")
        }
        let smallPanels = (0..<35).map { index in
            SnowSurface(id: "small-\(index)", frame: CGRect(x: 100, y: 200, width: 143, height: 52), kind: .window)
        }
        updatePanel(smallPanels + [backgroundWindow, floor])
        try check(panelLayer.windowGarlandCount == 1, "Filtered panels do not consume the 32-window limit")
        panelLayer.removeFromParent()

        let many = (0..<40).map { index in
            SnowSurface(id: "bounded-\(index)", frame: CGRect(x: -80 + index * 8, y: 100 + index * 3, width: 500, height: 100), kind: .window)
        }
        snow.syncSurfaces(many + [floor]); world.syncSurfaces(snow.surfaces)
        options = FestiveOptions(windowGarlands: true); update()
        try check(layer.windowGarlandCount == 32 && layer.enabledNodeCount <= 96, "Many visible windows keep a bounded set of garlands")
        let orderSnow = SnowWorld(), orderWorld = FestiveWorld()
        var orderFront = SnowSurface(id: "order-front", frame: CGRect(x: 200, y: 100, width: 300, height: 200), kind: .window)
        var orderRear = SnowSurface(id: "order-rear", frame: CGRect(x: 200, y: 100, width: 300, height: 206), kind: .window)
        orderSnow.syncSurfaces([orderFront, floor])
        let olderFront = orderWorld.place(at: CGPoint(x: 350, y: 302), displayFrame: display, snow: orderSnow)!
        orderRear.bodyOccluders = [orderFront.frame]; orderRear.occluders = [orderFront.frame]
        orderSnow.syncSurfaces([orderFront, orderRear, floor])
        let newerRear = orderWorld.place(at: CGPoint(x: 358, y: 308), displayFrame: display, snow: orderSnow)!
        let orderLayer = FestiveLayer(world: orderWorld); scene.addChild(orderLayer)
        func updateOrder() {
            orderLayer.update(options: FestiveOptions(christmasTrees: true), snow: orderSnow,
                displayFrame: display, visibleFrame: visible, delta: 0, time: 0, weather: SnowWeather())
        }
        func checkTreeOrder(_ expected: UUID, _ message: String) throws {
            let point = CGPoint(x: 354, y: 350) // Both crowns, above both window bodies.
            try check(orderWorld.hitTest(point, displayFrame: display, snow: orderSnow) == expected, message + " selection")
            let base = orderWorld.placements(in: orderSnow).first { $0.id == expected }!.base
            let chosen = orderLayer.children.first { node in
                node.children.contains { ($0 as? SKSpriteNode)?.position.x == base.x - display.minX }
            }!
            let actual = try bitmap(orderLayer).representation(using: .png, properties: [:])!
            let originalDepth = chosen.zPosition
            chosen.zPosition = 100
            let expectedPixels = try bitmap(orderLayer).representation(using: .png, properties: [:])!
            chosen.zPosition = -100
            let oppositePixels = try bitmap(orderLayer).representation(using: .png, properties: [:])!
            chosen.zPosition = originalDepth
            try check(expectedPixels != oppositePixels, message + " has visibly intersecting crowns")
            try check(actual == expectedPixels, message + " rendered top matches selection")
        }
        updateOrder()
        try checkTreeOrder(olderFront, "An older foreground tree covers a newer rear tree")
        orderFront.bodyOccluders = [orderRear.frame]; orderFront.occluders = [orderRear.frame]
        orderRear.bodyOccluders = []; orderRear.occluders = []
        orderSnow.syncSurfaces([orderRear, orderFront, floor]); updateOrder()
        try checkTreeOrder(newerRear, "Changing support order changes crown depth without recreating trees")
        orderFront.bodyOccluders = []; orderFront.occluders = []
        orderSnow.syncSurfaces([orderFront, orderRear, floor])
        try check(orderWorld.move(id: newerRear, to: CGPoint(x: 358, y: 300), displayFrame: display, snow: orderSnow),
                  "Move the newer tree to the same support")
        // Reverse child insertion to ensure equal-support order comes from creation, not SpriteKit ties.
        for child in orderLayer.children.reversed() { child.removeFromParent(); orderLayer.addChild(child) }
        updateOrder()
        try checkTreeOrder(newerRear, "The latest tree on one support remains visually on top")
        orderLayer.removeFromParent()
        _ = backWindow
        print("Festive rendering: \(checks) checks passed; own SpriteKit previews only; nodes=\(layer.enabledNodeCount), rasters=\(layer.rasterizations), masks=\(layer.maskRebuilds)")
    }
}
