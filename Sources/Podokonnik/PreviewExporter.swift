import AppKit
import SpriteKit

/// An entirely synthetic scene for visual QA. No pixels or contents from other applications
/// are read. This path does not run during normal application startup.
enum PreviewExporter {
    static func export(to directory: URL) -> [String: Bool] {
        let frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
        let world = SnowWorld(seed: 0x51_0F_2026)
        let backRect = CGRect(x: 72, y: 212, width: 566, height: 326)
        let frontRect = CGRect(x: 535, y: 142, width: 492, height: 420)
        let dockRect = CGRect(x: 369, y: 32, width: 362, height: 61)
        var frontSurface = SnowSurface(id: "preview-front", frame: frontRect, kind: .window)
        frontSurface.topInset = 16
        var backSurface = SnowSurface(id: "preview-back", frame: backRect, kind: .window, occluders: [frontRect])
        backSurface.topInset = 16
        let surfaces = [
            frontSurface,
            backSurface,
            SnowSurface(id: "preview-dock", frame: dockRect, kind: .dock),
            SnowSurface(id: "preview-floor", frame: CGRect(x: 0, y: 0, width: frame.width, height: 0),
                        kind: .floor, occluders: [frontRect, backRect, dockRect])
        ]
        world.syncSurfaces(surfaces)
        world.prune(to: [frame])
        let depositWeather = SnowWeather(intensity: .blizzard)
        advance(world, seconds: 35, weather: depositWeather, region: frame)
        let snowmanMade = makeSnowman(world, source: surfaces[0], destination: surfaces[1], region: frame)

        let scene = SnowScene(world: world, displayFrame: frame)
        scene.weather = SnowWeather(intensity: .steady, wind: CGVector(dx: 0.22, dy: 0.08))
        scene.addChild(desktopBackground(frame: frame))
        scene.addChild(backWindow(frame: backRect))
        scene.addChild(frontWindow(frame: frontRect))
        scene.addChild(dock(frame: dockRect))
        let view = SKView(frame: frame)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 60
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        view.presentScene(scene)
        // Direct ticks are only composition setup, not an FPS benchmark or runtime evidence.
        for tick in 0...1_800 { scene.update(Double(tick) / 60) }
        view.isPaused = true
        defer { view.presentScene(nil); window.close() }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return ["effect.png": false, "snowmanModel": snowmanMade] }
        let exported = scene.exportPreview(to: directory.appendingPathComponent("effect.png"))
        return ["effect.png": exported, "snowmanModel": snowmanMade]
    }

    private static func advance(_ world: SnowWorld, seconds: Double, weather: SnowWeather, region: CGRect) {
        for _ in 0..<Int(seconds * 60) { world.step(delta: 1.0 / 60, weather: weather, activeRegions: [region]) }
    }

    /// Creates each ball by collecting and rolling actual snow, then drops it onto the stack.
    /// No direct writes to world state or special preview-only simulation shortcuts.
    private static func makeSnowman(_ world: SnowWorld, source: SnowSurface,
                                    destination: SnowSurface, region: CGRect) -> Bool {
        let targetX: CGFloat = 326
        var previousID: UUID?
        for (index, targetRadius) in [CGFloat(24), CGFloat(18), CGFloat(12)].enumerated() {
            // Fresh regions of the long front roof provide enough mass for three different sizes.
            let startX = source.frame.minX + [CGFloat(32), CGFloat(420), CGFloat(235)][index]
            let direction: CGFloat = index == 1 ? -1 : 1
            let start = CGPoint(x: startX, y: source.top + driftHeight(world, surfaceID: source.id, x: startX))
            guard let id = world.beginSnowball(at: start) else { return false }
            for step in 1...95 {
                guard let ball = world.balls.first(where: { $0.id == id }) else { return false }
                if ball.radius >= targetRadius { break }
                let x = min(source.frame.maxX - 10, max(source.frame.minX + 10, startX + direction * CGFloat(step) * 4))
                world.drag(to: CGPoint(x: x, y: source.top + driftHeight(world, surfaceID: source.id, x: x)))
            }
            world.endDrag()
            guard let ball = world.balls.first(where: { $0.id == id }) else { return false }
            guard world.beginDrag(at: ball.position) == id else { return false }
            let y: CGFloat
            if let previousID, let below = world.balls.first(where: { $0.id == previousID }) {
                y = below.position.y + below.radius + ball.radius + 2
            } else {
                y = destination.top + driftHeight(world, surfaceID: destination.id, x: targetX) + ball.radius + 2
            }
            // Lift before horizontal transport so this gesture cannot accidentally roll
            // across either roof and collect more snow during placement.
            world.drag(to: CGPoint(x: targetX, y: region.maxY - 10))
            world.drag(to: CGPoint(x: targetX, y: y))
            world.endDrag()
            advance(world, seconds: 1.4, weather: SnowWeather(intensity: .light), region: region)
            previousID = id
        }
        return !world.snowmen.isEmpty
    }

    private static func driftHeight(_ world: SnowWorld, surfaceID: String, x: CGFloat) -> CGFloat {
        guard let drift = world.drifts[surfaceID], !drift.heights.isEmpty else { return 0 }
        let index = min(drift.heights.count - 1, max(0, Int((x - drift.surface.frame.minX) / SnowDrift.spacing)))
        return drift.heights[index]
    }

    private static func desktopBackground(frame: CGRect) -> SKNode {
        let root = SKNode()
        root.zPosition = -1_000
        let background = SKSpriteNode(color: NSColor(calibratedRed: 0.035, green: 0.06, blue: 0.12, alpha: 1), size: frame.size)
        background.anchorPoint = .zero
        root.addChild(background)
        let glow = SKShapeNode(ellipseOf: CGSize(width: 970, height: 430))
        glow.position = CGPoint(x: 820, y: 60)
        glow.fillColor = NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.25, alpha: 0.7)
        glow.strokeColor = .clear
        glow.zPosition = 0.1
        root.addChild(glow)
        let bar = SKSpriteNode(color: NSColor(calibratedWhite: 1, alpha: 0.055), size: CGSize(width: frame.width, height: 31))
        bar.anchorPoint = .zero
        bar.position = CGPoint(x: 0, y: frame.height - 31)
        bar.zPosition = 0.2
        root.addChild(bar)
        addLabel("❄  Подоконник", to: root, at: CGPoint(x: 23, y: 739), size: 13, weight: .semibold)
        addLabel("Маленькая зима на вашем Mac", to: root, at: CGPoint(x: 173, y: 739), size: 12, color: NSColor(calibratedWhite: 0.77, alpha: 1))
        addLabel("ДЕМОНСТРАЦИОННАЯ СЦЕНА", to: root, at: CGPoint(x: 772, y: 739), size: 10,
                 color: NSColor(calibratedWhite: 0.6, alpha: 1))
        addLabel("Снег. Тишина. Немного волшебства.", to: root, at: CGPoint(x: 72, y: 700), size: 25, weight: .light)
        addLabel("Сугробы следуют за окнами. Снежки можно собирать своими руками.", to: root,
                 at: CGPoint(x: 74, y: 679), size: 13, color: NSColor(calibratedWhite: 0.63, alpha: 1))
        return root
    }

    private static func window(frame: CGRect, title: String, front: Bool) -> SKNode {
        let root = SKNode()
        root.position = frame.origin
        root.zPosition = front ? -800 : -900
        let shadow = SKShapeNode(rect: CGRect(x: -5, y: -12, width: frame.width + 10, height: frame.height + 10), cornerRadius: 18)
        shadow.fillColor = NSColor(calibratedWhite: 0, alpha: 0.24)
        shadow.strokeColor = .clear
        root.addChild(shadow)
        let body = SKShapeNode(rect: CGRect(origin: .zero, size: frame.size), cornerRadius: 14)
        body.fillColor = front ? NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.20, alpha: 1)
            : NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.17, alpha: 1)
        body.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.14)
        body.lineWidth = 1
        body.zPosition = 0.1
        root.addChild(body)
        let separator = SKShapeNode()
        let separatorPath = CGMutablePath()
        separatorPath.move(to: CGPoint(x: 0, y: frame.height - 42))
        separatorPath.addLine(to: CGPoint(x: frame.width, y: frame.height - 42))
        separator.path = separatorPath
        separator.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.1)
        separator.zPosition = 0.2
        root.addChild(separator)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = SKShapeNode(circleOfRadius: 5.5)
            dot.position = CGPoint(x: 20 + CGFloat(index) * 19, y: frame.height - 21)
            dot.fillColor = color
            dot.strokeColor = .clear
            dot.zPosition = 0.3
            root.addChild(dot)
        }
        addLabel(title, to: root, at: CGPoint(x: 100, y: frame.height - 25), size: 12,
                 color: NSColor(calibratedWhite: 0.67, alpha: 1))
        return root
    }

    private static func backWindow(frame: CGRect) -> SKNode {
        let root = window(frame: frame, title: "Зимние заметки", front: false)
        addLabel("Сегодня можно чуть медленнее.", to: root, at: CGPoint(x: 30, y: frame.height - 93), size: 21, weight: .medium)
        addLabel("За окном — ноябрь. На рабочем столе — снег.", to: root,
                 at: CGPoint(x: 31, y: frame.height - 124), size: 13, color: NSColor(calibratedWhite: 0.64, alpha: 1))
        let rows = ["Заварить чай", "Дописать хорошую идею", "Скатать маленького снеговика"]
        for (index, text) in rows.enumerated() {
            let y = frame.height - 180 - CGFloat(index) * 38
            let circle = SKShapeNode(circleOfRadius: 7)
            circle.position = CGPoint(x: 39, y: y + 4)
            circle.strokeColor = NSColor(calibratedRed: 0.37, green: 0.68, blue: 0.88, alpha: 1)
            circle.fillColor = .clear
            circle.lineWidth = 1.3
            circle.zPosition = 1
            root.addChild(circle)
            addLabel(text, to: root, at: CGPoint(x: 59, y: y), size: 14,
                     color: NSColor(calibratedWhite: 0.82, alpha: 1))
        }
        return root
    }

    private static func frontWindow(frame: CGRect) -> SKNode {
        let root = window(frame: frame, title: "Тихий вечер", front: true)
        addLabel("Небольшая пауза", to: root, at: CGPoint(x: 30, y: frame.height - 92), size: 26, weight: .light)
        addLabel("Устроим зиму там, где мы работаем.", to: root, at: CGPoint(x: 31, y: frame.height - 122), size: 13,
                 color: NSColor(calibratedWhite: 0.65, alpha: 1))
        let cover = SKShapeNode(rect: CGRect(x: 30, y: 89, width: frame.width - 60, height: 164), cornerRadius: 10)
        cover.fillColor = NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.31, alpha: 1)
        cover.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.06)
        cover.zPosition = 0.5
        root.addChild(cover)
        addLabel("❄", to: root, at: CGPoint(x: 205, y: 161), size: 53, color: NSColor(calibratedWhite: 0.9, alpha: 1))
        addLabel("СНЕГ ИДЁТ, РАБОТА ПРОДОЛЖАЕТСЯ", to: root, at: CGPoint(x: 76, y: 119), size: 10,
                 color: NSColor(calibratedWhite: 0.7, alpha: 1))
        addLabel("Ровный снег     ·     Лёгкий ветер", to: root, at: CGPoint(x: 32, y: 50), size: 12,
                 color: NSColor(calibratedWhite: 0.7, alpha: 1))
        return root
    }

    private static func dock(frame: CGRect) -> SKNode {
        let root = SKNode()
        root.position = frame.origin
        root.zPosition = -700
        let plate = SKShapeNode(rect: CGRect(origin: .zero, size: frame.size), cornerRadius: 17)
        plate.fillColor = NSColor(calibratedWhite: 0.3, alpha: 0.5)
        plate.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.15)
        root.addChild(plate)
        let symbols = ["snowflake", "folder.fill", "doc.text.fill", "music.note", "photo", "gearshape.fill"]
        for (index, symbol) in symbols.enumerated() {
            let x = 22 + CGFloat(index) * 55
            let tile = SKShapeNode(rect: CGRect(x: x - 6, y: 11, width: 43, height: 40), cornerRadius: 10)
            tile.fillColor = NSColor(calibratedRed: 0.2 + CGFloat(index % 3) * 0.05, green: 0.38, blue: 0.58, alpha: 1)
            tile.strokeColor = .clear
            tile.zPosition = 0.2
            root.addChild(tile)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let whiteImage = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? image
                let sprite = SKSpriteNode(texture: SKTexture(image: whiteImage))
                sprite.size = CGSize(width: 23, height: 23)
                sprite.position = CGPoint(x: x + 15, y: 31)
                sprite.color = .white
                sprite.colorBlendFactor = 0
                sprite.zPosition = 0.3
                root.addChild(sprite)
            }
        }
        return root
    }

    private static func addLabel(_ text: String, to root: SKNode, at position: CGPoint, size: CGFloat,
                                 weight: NSFont.Weight = .regular, color: NSColor = .white) {
        let label = SKLabelNode(fontNamed: NSFont.systemFont(ofSize: size, weight: weight).fontName)
        label.text = text
        label.fontSize = size
        label.fontColor = color
        label.position = position
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .baseline
        label.zPosition = 1
        root.addChild(label)
    }
}
