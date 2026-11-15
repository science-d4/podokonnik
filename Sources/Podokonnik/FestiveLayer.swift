import AppKit
import SpriteKit

/// Optional decorations share the application's clock. Disabled layers neither
/// build geometry nor create textures; every resource has a fixed upper bound.
final class FestiveLayer: SKNode {
    private let world: FestiveWorld
    private var previous = FestiveOptions()
    private var desktop: FestiveMaskedNode?
    private var desktopWire: FestiveGarland?
    private var windowWires: [String: FestiveGarland] = [:]
    private var trees: [UUID: FestiveMaskedNode] = [:]
    private var treeSprites: [UUID: SKSpriteNode] = [:]
    private var maskGeometry: [SnowSurface]?
    private var cachedDesktopMasks: [CGRect] = []
    private var cachedTreeMasks: [String: [CGRect]] = [:]
    private var auroras: [SKSpriteNode] = []
    private var meteor: SKSpriteNode?
    private var glowTime: TimeInterval = 0
    private var auroraTime: TimeInterval = 0
    private var meteorDelay: TimeInterval = 2
    private var meteorAge: TimeInterval?
    private var meteorStart = CGPoint.zero
    private var meteorEnd = CGPoint.zero
    private var rng: UInt64 = 0x76AD_253B_07C1_1D65
    private(set) var rasterizations = 0 // Geometry-dependent garland textures; shared artwork is cached globally.
    var windowGarlandCount: Int { windowWires.values.filter { !$0.isHidden && !isHidden }.count }
    var activeMeteorCount: Int { !isHidden && meteorAge != nil ? 1 : 0 }
    var enabledNodeCount: Int {
        func count(_ node: SKNode) -> Int { node.isHidden ? 0 : 1 + node.children.reduce(0) { $0 + count($1) } }
        return isHidden ? 0 : children.reduce(0) { $0 + count($1) }
    }
    var maskRebuilds: Int {
        (desktop?.rebuilds ?? 0) + windowWires.values.reduce(0) { $0 + $1.rebuilds }
            + trees.values.reduce(0) { $0 + $1.rebuilds }
    }

    init(world: FestiveWorld) {
        self.world = world
        super.init()
        isHidden = true
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("FestiveLayer is created programmatically") }

    func update(options: FestiveOptions, snow: SnowWorld, displayFrame: CGRect, visibleFrame: CGRect,
                delta: TimeInterval, time: TimeInterval, weather: SnowWeather) {
        let enabled = options.desktopGarland || options.windowGarlands || options.christmasTrees
            || options.aurora || options.shootingStars
        guard enabled else {
            if !isHidden { meteor?.isHidden = true }
            isHidden = true
            previous = options
            glowTime = 0; auroraTime = 0; meteorDelay = 2; meteorAge = nil
            return
        }
        isHidden = false
        let dt = delta.isFinite ? min(0.1, max(0, delta)) : 0
        let motion = weather.reducedMotion ? 0 : dt * (weather.lowPower ? 0.45 : 1)
        if (!previous.desktopGarland && options.desktopGarland) || (!previous.windowGarlands && options.windowGarlands) { glowTime = 0 }
        glowTime += motion
        if !previous.aurora && options.aurora { auroraTime = 0 }
        auroraTime += motion
        let visible = visibleFrame.intersection(displayFrame)
        let needsDesktop = options.desktopGarland || options.aurora || options.shootingStars
        if needsDesktop || options.christmasTrees { refreshMasks(snow: snow) }
        let desktopMasks = cachedDesktopMasks
        if needsDesktop, !visible.isNull, !visible.isEmpty {
            let node: FestiveMaskedNode
            if let desktop { node = desktop }
            else { node = FestiveMaskedNode(); desktop = node; addChild(node) }
            node.apply(bounds: visible, occluders: desktopMasks, display: displayFrame)
            updateDesktopGarland(options: options, node: node, visible: visible, display: displayFrame, weather: weather)
            updateAurora(options: options, node: node, visible: visible, display: displayFrame, weather: weather)
            updateMeteor(options: options, node: node, visible: visible, display: displayFrame, delta: dt, weather: weather)
        } else { desktop?.isHidden = true; meteor?.isHidden = true; meteorAge = nil; meteorDelay = 2 }
        updateWindowGarlands(options: options, snow: snow, display: displayFrame, weather: weather)
        updateTrees(options: options, snow: snow, display: displayFrame)
        previous = options
    }

    private func refreshMasks(snow: SnowWorld) {
        let surfaces = snow.surfaces
        if let old = maskGeometry, old.count == surfaces.count {
            var unchanged = true
            for index in surfaces.indices {
                let a = surfaces[index], b = old[index]
                if a.id != b.id || a.kind != b.kind || a.frame != b.frame || a.isVisible != b.isVisible
                    || a.occluders != b.occluders || a.bodyOccluders != b.bodyOccluders {
                    unchanged = false; break
                }
            }
            if unchanged { return }
        }
        maskGeometry = surfaces
        cachedDesktopMasks = canonicalMasks(FestiveWorld.desktopOccluders(in: snow))
        cachedTreeMasks.removeAll(keepingCapacity: true)
        for surface in surfaces {
            cachedTreeMasks[surface.id] = surface.kind == .floor ? cachedDesktopMasks
                : canonicalMasks(FestiveWorld.occluders(for: surface, in: snow))
        }
    }

    private func canonicalMasks(_ values: [CGRect]) -> [CGRect] {
        Array(Set(values.map(FestiveRectKey.init))).map(\.rect)
            .sorted { ($0.minX, $0.minY, $0.width, $0.height) < ($1.minX, $1.minY, $1.width, $1.height) }
    }
    private func phase(for id: String) -> Double {
        let hash = id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return Double(hash % 10_000) / 10_000 * 2 * .pi
    }

    private func updateDesktopGarland(options: FestiveOptions, node: FestiveMaskedNode, visible: CGRect,
                                      display: CGRect, weather: SnowWeather) {
        guard options.desktopGarland else { desktopWire?.isHidden = true; return }
        if desktopWire == nil {
            desktopWire = FestiveGarland()
            node.addChild(desktopWire!)
        }
        let bounds = CGRect(x: visible.minX + 3, y: visible.maxY - 38, width: max(1, visible.width - 6), height: 34)
        if desktopWire!.update(bounds: bounds, occluders: [], display: display) { rasterizations += 1 }
        desktopWire!.alpha = weather.reducedMotion ? 0.95 : 0.89 + 0.09 * sin(glowTime * 0.75)
    }

    private func updateWindowGarlands(options: FestiveOptions, snow: SnowWorld, display: CGRect, weather: SnowWeather) {
        guard options.windowGarlands else { windowWires.values.forEach { $0.isHidden = true }; return }
        let surfaces = Array(snow.surfaces.filter {
            $0.kind == .window && $0.isVisible && $0.frame.intersects(display)
                && SnowSurface.meetsWindowSupportSize($0.frame)
        }.prefix(32))
        let ids = Set(surfaces.map(\.id))
        for id in Array(windowWires.keys) where !ids.contains(id) { windowWires.removeValue(forKey: id)?.removeFromParent() }
        for (index, surface) in surfaces.enumerated() {
            let node: FestiveGarland
            if let existing = windowWires[surface.id] { node = existing }
            else { node = FestiveGarland(); node.phase = phase(for: surface.id); windowWires[surface.id] = node; addChild(node) }
            let inset = min(16, surface.frame.width / 4)
            let bounds = CGRect(x: surface.frame.minX + inset, y: surface.top - 36,
                                width: surface.frame.width - inset * 2, height: 34)
            if node.update(bounds: bounds, occluders: surface.bodyOccluders, display: display) { rasterizations += 1 }
            node.zPosition = CGFloat(surfaces.count - index) * 0.01 + 1
            node.alpha = weather.reducedMotion ? 0.94 : 0.87 + 0.11 * sin(glowTime * 0.7 + node.phase)
        }
    }

    private func updateTrees(options: FestiveOptions, snow: SnowWorld, display: CGRect) {
        guard options.christmasTrees else { trees.values.forEach { $0.isHidden = true }; return }
        let placements = Array(world.placements(in: snow).prefix(8))
        let ids = Set(placements.map(\.id))
        for id in Array(trees.keys) where !ids.contains(id) {
            trees.removeValue(forKey: id)?.removeFromParent(); treeSprites.removeValue(forKey: id)
        }
        // Match hitTest: foreground support first, newest tree first on each support.
        let ranked: [(placement: FestiveTreePlacement, creation: Int, support: Int)] = placements.enumerated().map { index, placement in
            let support = snow.surfaces.firstIndex { $0.id == placement.surface.id } ?? snow.surfaces.count
            return (placement: placement, creation: index, support: support)
        }
        let frontToBack = ranked.sorted {
            $0.support == $1.support ? $0.creation > $1.creation : $0.support < $1.support
        }
        for entry in frontToBack {
            let placement = entry.placement
            let node: FestiveMaskedNode
            let sprite: SKSpriteNode
            if let existing = trees[placement.id], let image = treeSprites[placement.id] { node = existing; sprite = image }
            else {
                node = FestiveMaskedNode()
                sprite = SKSpriteNode(texture: FestiveTextures.trees[abs(placement.variant % 3)])
                sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
                node.addChild(sprite); addChild(node)
                trees[placement.id] = node; treeSprites[placement.id] = sprite
            }
            guard placement.surface.isVisible else { node.isHidden = true; continue }
            let masks = cachedTreeMasks[placement.surface.id] ?? []
            node.apply(bounds: placement.bounds, occluders: masks, display: display)
            // FestiveLayer is two points behind the snow layer. Within each
            // support interval, trees are above its drift and below its balls.
            let step = SurfaceRenderDepth.step(count: snow.surfaces.count)
            node.zPosition = 2 + SurfaceRenderDepth.base(count: snow.surfaces.count, index: entry.support)
                + step * (0.15 + CGFloat(entry.creation) * 0.02)
            sprite.position = CGPoint(x: placement.base.x - display.minX, y: placement.base.y - display.minY)
            sprite.size = placement.bounds.size
        }
    }

    private func updateAurora(options: FestiveOptions, node: FestiveMaskedNode, visible: CGRect, display: CGRect, weather: SnowWeather) {
        guard options.aurora else { auroras.forEach { $0.isHidden = true }; return }
        if auroras.isEmpty {
            auroras = FestiveTextures.auroras.map { texture in
                let sprite = SKSpriteNode(texture: texture)
                sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5); sprite.zPosition = -2
                node.addChild(sprite)
                return sprite
            }
        }
        let height = min(290, visible.height * 0.4)
        for (index, sprite) in auroras.enumerated() {
            sprite.isHidden = weather.lowPower && index == 1
            let phase = auroraTime * 0.18 + Double(index) * 2
            let x = weather.reducedMotion ? 0 : sin(phase) * 16
            let y = weather.reducedMotion ? 0 : cos(phase * 0.8) * 4
            sprite.size = CGSize(width: visible.width * 1.08, height: height)
            sprite.position = CGPoint(x: visible.midX - display.minX + x,
                                      y: visible.maxY - display.minY - height * 0.49 + y)
            sprite.alpha = weather.reducedMotion ? 0.85 : 0.77 + 0.12 * sin(phase * 0.6)
        }
    }

    private func updateMeteor(options: FestiveOptions, node: FestiveMaskedNode, visible: CGRect, display: CGRect,
                              delta: TimeInterval, weather: SnowWeather) {
        guard options.shootingStars && !weather.reducedMotion else {
            meteor?.isHidden = true; meteorAge = nil; meteorDelay = 2
            return
        }
        if !previous.shootingStars { meteorAge = nil; meteorDelay = 2; meteor?.isHidden = true }
        let dt = delta * (weather.lowPower ? 0.6 : 1)
        if let age = meteorAge {
            let next = age + dt
            if next >= 1.35 {
                meteorAge = nil; meteor?.isHidden = true; meteorDelay = 8 + random() * 8
            } else { meteorAge = next }
        } else {
            meteorDelay -= dt
            if meteorDelay <= 0 {
                if meteor == nil {
                    meteor = SKSpriteNode(texture: FestiveTextures.meteor)
                    meteor!.anchorPoint = CGPoint(x: 0.9, y: 0.5)
                    meteor!.size = CGSize(width: 132, height: 18)
                    meteor!.zPosition = -1
                    node.addChild(meteor!)
                }
                meteorStart = CGPoint(x: visible.minX + visible.width * CGFloat(0.12 + random() * 0.35),
                                      y: visible.maxY - CGFloat(35 + random() * 45))
                meteorEnd = CGPoint(x: meteorStart.x + max(180, visible.width * 0.38),
                                    y: meteorStart.y - min(170, visible.height * 0.24))
                meteorAge = 0
            }
        }
        if let age = meteorAge, let meteor {
            let t = CGFloat(age / 1.35)
            meteor.position = CGPoint(x: meteorStart.x + (meteorEnd.x - meteorStart.x) * t - display.minX,
                                      y: meteorStart.y + (meteorEnd.y - meteorStart.y) * t - display.minY)
            meteor.zRotation = atan2(meteorEnd.y - meteorStart.y, meteorEnd.x - meteorStart.x)
            meteor.alpha = min(1, age / 0.12) * min(1, (1.35 - age) / 0.35)
            meteor.isHidden = false
        }
    }
    private func random() -> Double {
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        return Double((rng &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
    }
}

private struct FestiveRectKey: Hashable {
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
private class FestiveMaskedNode: SKCropNode {
    private let mask = SKShapeNode()
    private var previousBounds = CGRect.null
    private var previousMasks: [CGRect] = []
    private var fullyOccluded = true
    private(set) var rebuilds = 0
    override init() {
        super.init()
        mask.fillColor = .white; mask.strokeColor = .clear; mask.lineWidth = 0
        maskNode = mask
    }
    required init?(coder: NSCoder) { fatalError("FestiveMaskedNode is created programmatically") }
    func apply(bounds: CGRect, occluders: [CGRect], display: CGRect) {
        let clipped = bounds.intersection(display)
        let local = clipped.isNull ? CGRect.zero : clipped.offsetBy(dx: -display.minX, dy: -display.minY)
        let masks = occluders.filter { $0.intersects(clipped) }.map { $0.offsetBy(dx: -display.minX, dy: -display.minY) }
        if local != previousBounds || masks != previousMasks {
            previousBounds = local; previousMasks = masks
            let visible = RendererGeometry.visibleRectangles(in: local, subtracting: masks)
            fullyOccluded = visible.isEmpty
            let path = CGMutablePath()
            for rect in visible { path.addRect(rect) }
            mask.path = path
            rebuilds += 1
        }
        isHidden = clipped.isNull || clipped.isEmpty || fullyOccluded
    }
}
private final class FestiveGarland: FestiveMaskedNode {
    var phase: Double = 0
    private let sprite = SKSpriteNode()
    private var width: CGFloat = -1
    override init() { super.init(); sprite.anchorPoint = .zero; addChild(sprite) }
    required init?(coder: NSCoder) { fatalError("FestiveGarland is created programmatically") }
    @discardableResult
    func update(bounds: CGRect, occluders: [CGRect], display: CGRect) -> Bool {
        apply(bounds: bounds, occluders: occluders, display: display)
        sprite.position = CGPoint(x: bounds.minX - display.minX, y: bounds.minY - display.minY)
        sprite.size = bounds.size
        guard width != bounds.width else { return false }
        width = bounds.width
        sprite.texture = FestiveTextures.garland(width: width)
        return true
    }
}

private enum FestiveTextures {
    private static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
    private static func texture(width: CGFloat, height: CGFloat, draw: (CGContext) -> Void) -> SKTexture {
        let w = max(1, Int(ceil(width * 2))), h = max(1, Int(ceil(height * 2)))
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        draw(context)
        let result = SKTexture(cgImage: context.makeImage()!)
        result.filteringMode = .linear
        return result
    }
    private static func gradient(_ context: CGContext, colors: [CGColor], start: CGPoint, end: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }
    static func garland(width: CGFloat) -> SKTexture {
        let width = max(1, min(4096, width))
        return texture(width: width, height: 34) { c in
            func wireY(_ x: CGFloat) -> CGFloat { 28 - sin((x.truncatingRemainder(dividingBy: 150)) / 150 * .pi) * 7 }
            let path = CGMutablePath()
            for index in 0...Int(ceil(width / 3)) {
                let x = min(width, CGFloat(index) * 3), p = CGPoint(x: x, y: wireY(x))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            c.setStrokeColor(color(0x344F46, 0.75)); c.setLineWidth(1.3); c.addPath(path); c.strokePath()
            let palette: [UInt32] = [0xFFD383, 0xFF7D91, 0x7DE5CF, 0xA9BAFF, 0xFFE9A3]
            for (index, x) in stride(from: CGFloat(15), through: max(15, width - 10), by: 31).enumerated() {
                let y = wireY(x) - 6, tint = palette[index % palette.count]
                c.setStrokeColor(color(0x415B51, 0.9)); c.setLineWidth(1)
                c.move(to: CGPoint(x: x, y: y + 5)); c.addLine(to: CGPoint(x: x, y: y + 1)); c.strokePath()
                c.saveGState(); c.setShadow(offset: .zero, blur: 9, color: color(tint, 0.85))
                c.setFillColor(color(tint, 0.95)); c.fillEllipse(in: CGRect(x: x - 2.6, y: y - 3.4, width: 5.2, height: 6.8))
                c.restoreGState()
                c.setFillColor(color(0xFFFFFF, 0.9)); c.fillEllipse(in: CGRect(x: x - 1.3, y: y + 0.2, width: 1.6, height: 2.4))
            }
        }
    }
    static let trees: [SKTexture] = (0..<3).map { variant in
        texture(width: 100, height: 156) { c in
            c.setFillColor(color(0x2E4855, 0.18)); c.fillEllipse(in: CGRect(x: 14, y: 0, width: 72, height: 7))
            c.setFillColor(color(0x865B45)); c.fill(CGRect(x: 44, y: 2, width: 12, height: 26))
            c.setFillColor(color(0xC48B61)); c.fill(CGRect(x: 45, y: 3, width: 3, height: 23))
            let tops: [CGFloat] = [84, 111, 136]
            let bottoms: [CGFloat] = [17, 46, 78]
            let widths: [CGFloat] = [88, 67, 45]
            for index in 0..<3 {
                let top = tops[index], bottom = bottoms[index], half = widths[index] / 2
                let branches = CGMutablePath()
                branches.move(to: CGPoint(x: 50, y: top))
                branches.addCurve(to: CGPoint(x: 50 - half, y: bottom + 7), control1: CGPoint(x: 42, y: top - 23), control2: CGPoint(x: 23 - half * 0.25, y: bottom + 17))
                branches.addQuadCurve(to: CGPoint(x: 50 + half, y: bottom + 7), control: CGPoint(x: 50, y: bottom - 8))
                branches.addCurve(to: CGPoint(x: 50, y: top), control1: CGPoint(x: 77 + half * 0.25, y: bottom + 17), control2: CGPoint(x: 58, y: top - 23))
                branches.closeSubpath()
                c.saveGState(); c.addPath(branches); c.clip()
                gradient(c, colors: [color(variant == 1 ? 0x5AAB9B : 0x5DAE8B), color(0x1D6551), color(0x114A3E)],
                         start: CGPoint(x: 42, y: top), end: CGPoint(x: 60, y: bottom))
                c.restoreGState()
                let snow = CGMutablePath()
                snow.move(to: CGPoint(x: 50, y: top + 1))
                snow.addCurve(to: CGPoint(x: 50 - half * 0.52, y: bottom + (top - bottom) * 0.47),
                              control1: CGPoint(x: 47, y: top - 9), control2: CGPoint(x: 41 - half * 0.25, y: top - 26))
                snow.addQuadCurve(to: CGPoint(x: 50 + half * 0.51, y: bottom + (top - bottom) * 0.47), control: CGPoint(x: 50, y: bottom + (top - bottom) * 0.60))
                snow.addCurve(to: CGPoint(x: 50, y: top + 1), control1: CGPoint(x: 59 + half * 0.25, y: top - 26), control2: CGPoint(x: 53, y: top - 9))
                snow.closeSubpath()
                c.setFillColor(color(0xEAF6F6)); c.addPath(snow); c.fillPath()
            }
            let ornaments: [(CGFloat, CGFloat)] = [(30, 36), (66, 30), (46, 52), (69, 65), (34, 74), (55, 91), (47, 114)]
            let palette: [UInt32] = variant == 2 ? [0xFFD88A, 0xB8A7F1, 0xEED8A7] : [0xF28D99, 0xF5D18B, 0x9DCEEE]
            for (i, position) in ornaments.enumerated() {
                let (x, y) = position
                c.setFillColor(color(0x123F39, 0.5)); c.fillEllipse(in: CGRect(x: x - 3.3, y: y - 3.8, width: 7, height: 7))
                c.setFillColor(color(palette[i % palette.count])); c.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                c.setFillColor(color(0xFFFFFF, 0.8)); c.fillEllipse(in: CGRect(x: x - 1.8, y: y + 0.5, width: 1.5, height: 1.5))
            }
            let star = CGMutablePath()
            for i in 0..<10 {
                let angle = CGFloat(i) * .pi / 5 + .pi / 2, radius: CGFloat = i.isMultiple(of: 2) ? 8.4 : 3.7
                let p = CGPoint(x: 50 + cos(angle) * radius, y: 145 + sin(angle) * radius)
                if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath(); c.setShadow(offset: .zero, blur: 6, color: color(0xFFE4A1, 0.5))
            c.setFillColor(color(0xFFE5A1)); c.addPath(star); c.fillPath()
        }
    }
    static let auroras: [SKTexture] = (0..<2).map { variant in
        texture(width: 768, height: 256) { c in
            c.setBlendMode(.plusLighter)
            for i in stride(from: 0, through: 768, by: 5) {
                let x = CGFloat(i), t = x / 768
                let base = 55 + sin(t * 6.8 + CGFloat(variant) * 2) * 24 + sin(t * 16) * 9
                let height = 75 + sin(t * 10 + 1) * 22
                c.saveGState()
                c.clip(to: CGRect(x: x - 6, y: base, width: 13, height: height))
                let tint: UInt32 = variant == 0 ? (t < 0.55 ? 0x79E7BE : 0x95C5ED) : 0xBCA2EF
                let opacity: CGFloat = 0.10 + (sin(t * 93) + 1) * 0.025
                gradient(c, colors: [color(tint, 0), color(tint, opacity), color(tint, 0)],
                         start: CGPoint(x: x, y: base), end: CGPoint(x: x, y: base + height))
                c.restoreGState()
            }
        }
    }
    static let meteor = texture(width: 132, height: 18) { c in
        let tail = CGMutablePath(); tail.move(to: CGPoint(x: 1, y: 9)); tail.addLine(to: CGPoint(x: 118, y: 12))
        tail.addQuadCurve(to: CGPoint(x: 118, y: 6), control: CGPoint(x: 124, y: 9)); tail.closeSubpath()
        c.saveGState(); c.addPath(tail); c.clip()
        gradient(c, colors: [color(0xA5D7EB, 0), color(0xD9ECF9, 0.8)], start: CGPoint(x: 0, y: 9), end: CGPoint(x: 120, y: 9))
        c.restoreGState()
        c.setShadow(offset: .zero, blur: 7, color: color(0xD8F3FF, 0.7))
        c.setFillColor(color(0xF9FCFF)); c.fillEllipse(in: CGRect(x: 116, y: 6, width: 6, height: 6))
    }
}
