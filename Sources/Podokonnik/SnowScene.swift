import AppKit
import SpriteKit

/// A transparent presentation of a shared world. Only the designated scene's onFrame
/// advances that world, so adding a second monitor cannot double simulation speed.
final class SnowScene: SKScene {
    var weather = SnowWeather()
    var decorationOptions = FestiveOptions() {
        didSet {
            guard decorationOptions != oldValue else { return }
            if oldValue.christmasTrees && !decorationOptions.christmasTrees {
                draggingTreeID = nil
                if tool == .tree { tool = .mitten; onToolChange?(.mitten) }
            }
            refreshDecorations(delta: 0)
        }
    }
    var decorationVisibleFrame: CGRect
    var duckWorld: DuckWorld?
    var snowplowPasses: [String: SnowplowPass] = [:]
    var onFrame: ((TimeInterval) -> Void)?
    var onExitGame: (() -> Void)?
    var onToolChange: ((SnowTool) -> Void)?
    var onLimit: ((String) -> Void)?
    /// Set before the first update. The synchronous sink must copy GPU data without
    /// retaining the array, so its storage can be reused for the next frame.
    var onParticles: (([SnowParticleInstance]) -> Void)? {
        didSet { precondition(!particlesStarted, "Configure particle rendering before the first update") }
    }
    var onGPUParticles: ((SnowGPUParticleFrame) -> Void)? {
        didSet { precondition(!particlesStarted, "Configure GPU simulation before the first update") }
    }
    var particleSimulationBackend: String { onGPUParticles == nil ? "cpu" : "gpu" }
    private var gpuParticleCount = 0
    func recordGPUParticleCount(_ count: Int) { gpuParticleCount = count }
    private var gpuGeometryCache = SnowGPUGeometryCache()
    private var nextParticleID: UInt32 = 0
    var referenceParticleStates: [SnowGPUFlake] { flakes.map(\.gpuState) }
    /// Deterministic replay fixture; the normal emitter never calls this.
    func seedParticleReference(_ states: [SnowGPUFlake]) {
        precondition(!particlesStarted && onGPUParticles == nil && onParticles != nil)
        flakes = states.map { f in
            Flake(id: f.identity.x, node: nil, position: CGPoint(x: CGFloat(f.geometry.x), y: CGFloat(f.geometry.y)),
                rotation: CGFloat(f.geometry.w), sideSize: CGFloat(f.geometry.z), crystal: f.appearance.y != 0,
                alpha: CGFloat(f.appearance.x), speed: CGFloat(f.dynamics.x), depth: CGFloat(f.dynamics.y),
                phase: CGFloat(f.dynamics.z), frequency: CGFloat(f.dynamics.w), sway: CGFloat(f.style.x),
                spin: CGFloat(f.style.y), opacity: CGFloat(f.style.z), age: Double(f.style.w),
                retirementAge: f.lifecycle.x < 0 ? nil : Double(f.lifecycle.x), hiddenByWindows: f.identity.z == 0,
                wideVisibility: CGFloat(f.lifecycle.y), visibilityInitialized: f.lifecycle.z != 0)
        }
        nextParticleID = states.map { $0.identity.x }.max() ?? 0
    }
    var particleTextureImages: [CGImage] { [roundTexture.cgImage(), crystalTexture.cgImage()] }
    private(set) var driftRasterizations = 0
    /// Explicit backing scale when hosted by SKRenderer instead of an SKView.
    var presentationScale: CGFloat?
    var playing = false { didSet { if !playing { cancelInteraction() } } }
    var tool: SnowTool = .mitten { didSet { if oldValue != tool { cancelInteraction() } } }

    private let world: SnowWorld
    private let festiveWorld: FestiveWorld
    private let festiveLayer: FestiveLayer
    private var duckLayer: DuckLayer?
    private(set) var displayFrame: CGRect
    private var lastTime: TimeInterval?
    private var sceneTime: TimeInterval = 0
    private var lastShapeUpdate: TimeInterval = -1
    private var emissionFraction: Double = 0
    private var smoothRate: Double = 0
    private var smoothWind = CGVector.zero
    private var flakes: [Flake] = []
    private var flakePool: [SKSpriteNode] = []
    private var particlePacket: [SnowParticleInstance] = []
    private var particleMasks = ParticleOcclusionCache()
    private var particlesStarted = false
    private var surfaceVisuals: [String: SurfaceVisual] = [:]
    private var ballVisuals: [UUID: BallVisual] = [:]
    private var snowplowVisuals: [String: SnowplowVisual] = [:]
    private var debrisNodes: [SKSpriteNode] = []
    private var lastPointer: CGPoint?
    private var previousPointerTime: TimeInterval = 0
    private var releaseVelocity = CGVector.zero
    private var isDraggingBall = false
    private var draggingTreeID: UUID?
    private var treeDragOffset = CGVector.zero
    private var isPainting = false
    private var lastLimitTime: TimeInterval = -10
    private var rng: UInt64 = 0x45AC_63B2_0D7E_9931
    private let particleLayer = SKNode()
    private let objectLayer = SKNode()
    private let snowplowLayer = SKNode()
    private let looseBallLayer = SKNode()
    private let debrisLayer = SKNode()
    private let roundTexture: SKTexture
    private let crystalTexture: SKTexture

    init(world: SnowWorld, displayFrame: CGRect, festiveWorld: FestiveWorld? = nil) {
        self.world = world
        let decorations = festiveWorld ?? FestiveWorld()
        self.festiveWorld = decorations
        festiveLayer = FestiveLayer(world: decorations)
        self.displayFrame = displayFrame
        decorationVisibleFrame = displayFrame.insetBy(dx: 0, dy: 24)
        roundTexture = RendererTextures.particle(crystal: false)
        crystalTexture = RendererTextures.particle(crystal: true)
        super.init(size: displayFrame.size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        anchorPoint = .zero
        isUserInteractionEnabled = true
        objectLayer.zPosition = 10
        snowplowLayer.zPosition = 12
        looseBallLayer.zPosition = 200
        debrisLayer.zPosition = 220
        particleLayer.zPosition = 240
        festiveLayer.zPosition = 8
        addChild(festiveLayer)
        addChild(objectLayer)
        addChild(snowplowLayer)
        addChild(looseBallLayer)
        addChild(debrisLayer)
        addChild(particleLayer)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("SnowScene is created programmatically") }

    func refreshGeometry(frame: CGRect) {
        displayFrame = frame
        decorationVisibleFrame = frame.insetBy(dx: 0, dy: 24)
        size = frame.size
        // Local particle coordinates remain valid; off-screen particles recycle on the next frame.
        for visual in surfaceVisuals.values { visual.maskSignature = nil }
        lastTime = nil
        lastShapeUpdate = -1
        cancelInteraction()
    }

    func cancelInteraction() {
        if isDraggingBall { world.endDrag() }
        isDraggingBall = false
        draggingTreeID = nil
        treeDragOffset = .zero
        isPainting = false
        lastPointer = nil
        releaseVelocity = .zero
    }

    /// Call when the SKView is paused or resumed. Hidden time must not become simulated time.
    func resetAnimationClock() {
        lastTime = nil
        cancelInteraction()
    }

    override func update(_ currentTime: TimeInterval) {
        particlesStarted = true
        onFrame?(currentTime)
        let delta = min(1.0 / 15.0, max(0, currentTime - (lastTime ?? currentTime)))
        lastTime = currentTime
        sceneTime += delta
        let blend = 1 - exp(-delta / 0.22)
        smoothWind.dx += (weather.wind.dx - smoothWind.dx) * blend
        smoothWind.dy += (weather.wind.dy - smoothWind.dy) * blend
        let areaFactor = min(3, max(0.35, Double(size.width * size.height) / 1_100_000))
        let quality = (weather.lowPower ? 0.5 : 1.0) * (weather.reducedMotion ? 0.4 : 1.0)
        let requestedRate = weather.intensity.particleRate * areaFactor * quality
        smoothRate += (requestedRate - smoothRate) * blend
        if let onGPUParticles {
            particleMasks.update(surfaces: world.surfaces, display: displayFrame)
            let fades = particleMasks.advanceTransition(by: delta)
            let geometry = gpuGeometryCache.snapshot(drifts: world.drifts, display: displayFrame,
                                                     solid: particleMasks.solid, wide: particleMasks.wide)
            onGPUParticles(SnowGPUParticleFrame(delta: delta, time: sceneTime, rate: smoothRate,
                wind: smoothWind, size: size, cap: Int(Double(weather.intensity.particleCap) * areaFactor * quality),
                reducedMotion: weather.reducedMotion, fades: fades, geometry: geometry))
        } else {
            updateParticles(delta: delta, areaFactor: areaFactor, quality: quality)
        }
        if onGPUParticles == nil, let onParticles {
            particlePacket.removeAll(keepingCapacity: true)
            particlePacket.reserveCapacity(flakes.count)
            for index in flakes.indices where !flakes[index].hiddenByWindows {
                particlePacket.append(flakes[index].instance)
            }
            onParticles(particlePacket)
        }
        // Shape rebuilding is decoupled from pointer/world updates. Position and masks still
        // update each frame, so a moving window does not wait for the contour refresh.
        let refreshPaths = sceneTime - lastShapeUpdate >= 1.0 / 30.0
        renderWorld(refreshPaths: refreshPaths)
        refreshDecorations(delta: delta)
        renderDuck()
        if refreshPaths { lastShapeUpdate = sceneTime }
    }

    private func renderDuck() {
        guard decorationOptions.duck, let duckWorld else {
            duckLayer?.removeFromParent()
            duckLayer = nil
            return
        }
        guard duckWorld.pose != nil || !duckWorld.prints.isEmpty || !duckWorld.dust.isEmpty else {
            duckLayer?.isHidden = true
            return
        }
        let layer: DuckLayer
        if let duckLayer { layer = duckLayer }
        else {
            layer = DuckLayer()
            duckLayer = layer
            addChild(layer)
        }
        layer.isHidden = false
        layer.update(duckWorld, in: displayFrame, snow: world) { [self] anchor in
            guard let drift = world.drifts[anchor.surfaceID] else { return 0 }
            let surface = drift.surface
            guard let visual = surfaceVisuals[anchor.surfaceID], !visual.container.isHidden,
                  visual.snow.texture != nil else { return drift.visibleContour.height(at: anchor.localX) }
            guard !visual.snow.isHidden else { return 0 }
            return SnowContour(heights: visual.lastHeights, width: surface.frame.width,
                               roundedEnds: surface.kind != .floor, topInset: surface.topInset)
                .height(at: anchor.localX)
        }
    }

    private func refreshDecorations(delta: TimeInterval) {
        festiveLayer.update(options: decorationOptions, snow: world, displayFrame: displayFrame,
                            visibleFrame: decorationVisibleFrame, delta: delta, time: sceneTime, weather: weather)
    }

    private func updateParticles(delta: TimeInterval, areaFactor: Double, quality: Double) {
        let cap = Int(Double(weather.intensity.particleCap) * areaFactor * quality)
        // Counting the scalar state avoids copying/retaining thousands of node references.
        var active = 0
        for index in flakes.indices where flakes[index].retirementAge == nil { active += 1 }
        var excess = max(0, active - cap)
        if excess > 0 {
            for index in flakes.indices where excess > 0 && flakes[index].retirementAge == nil {
                flakes[index].retirementAge = 0
                excess -= 1
            }
        }
        emissionFraction = min(24, emissionFraction + smoothRate * delta)
        while emissionFraction >= 1 && flakes.count < cap {
            addFlake()
            emissionFraction -= 1
        }
        if flakes.count >= cap { emissionFraction = min(emissionFraction, 1) }
        particleMasks.update(surfaces: world.surfaces, display: displayFrame)
        let fadesVisibility = particleMasks.advanceTransition(by: delta)
        let collisionBands = world.drifts.values.compactMap { drift -> ParticleCollisionBand? in
            // Wide windows must not consume every flake at their upper edge.
            // Hidden flakes keep moving and can reappear below or after focus changes.
            if drift.surface.kind == .window,
               WideWindowPolicy.mask(forWindow: drift.surface.frame, display: displayFrame) != nil { return nil }
            return ParticleCollisionBand(drift: drift, displayFrame: displayFrame)
        }
        let motionScale: CGFloat = weather.reducedMotion ? 0.55 : 1
        let wind = smoothWind
        let time = CGFloat(sceneTime)
        let width = size.width
        var index = flakes.count
        while index > 0 {
            index -= 1
            if flakes[index].advance(delta: delta, time: time, wind: wind, motionScale: motionScale,
                                     reducedMotion: weather.reducedMotion, width: width, collisionBands: collisionBands) {
                recycleFlake(at: index)
            } else {
                let hardHidden = WideWindowPolicy.hidesParticle(center: flakes[index].position, side: flakes[index].sideSize,
                                                               rotation: flakes[index].rotation, masks: particleMasks.solid)
                let wideHidden = WideWindowPolicy.hidesParticle(center: flakes[index].position, side: flakes[index].sideSize,
                                                               rotation: flakes[index].rotation, masks: particleMasks.wide)
                flakes[index].updateVisibility(hardHidden: hardHidden, wideHidden: wideHidden,
                                               delta: delta, fades: fadesVisibility)
            }
        }
        // The spare pool has a hard cap independent of the largest screen ever connected.
        if flakePool.count > 128 { flakePool.removeLast(flakePool.count - 128) }
    }

    private func addFlake() {
        let depth = CGFloat(0.45 + random() * 0.75)
        let radius = CGFloat(0.55 + pow(random(), 2) * 2.0)
        let crystal = radius > 1.8 && random() > 0.5
        let sideSize = CGFloat(Float(radius * 3.2))
        var position = CGPoint(x: CGFloat(random()) * (size.width + 100) - 50, y: size.height + 8)
        // Enter from the upwind side as well, avoiding an empty wedge in strong wind.
        if abs(smoothWind.dx) > 0.1 && random() < Double(abs(smoothWind.dx)) * 0.35 {
            position = CGPoint(x: smoothWind.dx > 0 ? -8 : size.width + 8,
                               y: CGFloat(random()) * size.height)
        }
        // SpriteKit stores these values as Float. Match that precision in both paths
        // so switching the presentation backend cannot change particle trajectories.
        position = CGPoint(x: CGFloat(Float(position.x)), y: CGFloat(Float(position.y)))
        let rotation = CGFloat(Float(CGFloat(random()) * .pi * 2))
        var node: SKSpriteNode?
        if onParticles == nil {
            let sprite = flakePool.popLast() ?? SKSpriteNode(texture: roundTexture)
            sprite.texture = crystal ? crystalTexture : roundTexture
            sprite.name = crystal ? "snowflake.crystal" : "snowflake.round"
            sprite.size = CGSize(width: sideSize, height: sideSize)
            sprite.position = position
            sprite.zRotation = rotation
            sprite.alpha = 0
            sprite.isHidden = false
            particleLayer.addChild(sprite)
            node = sprite
        }
        nextParticleID &+= 1
        flakes.append(Flake(id: nextParticleID, node: node, position: position, rotation: rotation, sideSize: sideSize,
                            crystal: crystal, alpha: 0, speed: 26 + 54 * depth, depth: depth,
                            phase: CGFloat(random()) * .pi * 2, frequency: 0.6 + CGFloat(random()) * 1.4,
                            sway: 5 + CGFloat(random()) * 15, spin: CGFloat(random() - 0.5) * 1.3,
                            opacity: 0.4 + CGFloat(random()) * 0.5, age: 0))
    }

    private func recycleFlake(at index: Int) {
        if let node = flakes[index].node {
            node.removeFromParent()
            flakePool.append(node)
        }
        flakes.swapAt(index, flakes.count - 1)
        flakes.removeLast()
    }

    private func renderWorld(refreshPaths: Bool) {
        let surfaceIDs = Set(world.drifts.keys)
        for id in Array(surfaceVisuals.keys) where !surfaceIDs.contains(id) {
            surfaceVisuals.removeValue(forKey: id)?.container.removeFromParent()
        }
        let surfaceOrder = Dictionary(uniqueKeysWithValues: world.surfaces.enumerated().map { ($0.element.id, $0.offset) })
        var attachedBounds: [String: CGRect] = [:]
        for ball in world.balls {
            guard let id = ball.surfaceID else { continue }
            attachedBounds[id] = (attachedBounds[id] ?? .null).union(RendererGeometry.ballBounds(ball))
        }
        for (id, drift) in world.drifts {
            let surface = drift.surface
            let visual: SurfaceVisual
            if let existing = surfaceVisuals[id] { visual = existing }
            else {
                visual = SurfaceVisual()
                surfaceVisuals[id] = visual
                objectLayer.addChild(visual.container)
            }
            visual.container.zPosition = SurfaceRenderDepth.base(count: world.surfaces.count, index: surfaceOrder[id] ?? world.surfaces.count)
            let rasterBounds = RendererGeometry.driftRasterBounds(for: surface, displayFrame: displayFrame)
            let ballBounds = attachedBounds[id] ?? .null
            let hasDisplayIntersection = rasterBounds != nil || ballBounds.intersects(displayFrame)
            visual.container.isHidden = !surface.isVisible || !hasDisplayIntersection
            guard !visual.container.isHidden else { continue }
            updateMask(visual, surface: surface, contentBounds: ballBounds)
            // A ball can extend onto this display while its entire roof is elsewhere.
            // Keep the ball container, but do not allocate a one-pixel phantom roof.
            guard let rasterBounds else {
                visual.snow.isHidden = true
                visual.rasterBounds = .null
                continue
            }
            let scale = presentationScale ?? view?.window?.backingScaleFactor ?? 2
            let rasterOccluders = surface.occluders.map {
                CGRect(x: $0.minX - surface.frame.minX, y: $0.minY - surface.top,
                       width: $0.width, height: $0.height)
            }.filter { $0.intersects(rasterBounds) }
            // Ignore only pixels that cannot be presented. The bitmap has a padding
            // margin; that transparent/off-display margin must not defeat full occlusion.
            var visibleRasterBounds = rasterBounds.intersection(CGRect(
                x: displayFrame.minX - surface.frame.minX, y: displayFrame.minY - surface.top,
                width: displayFrame.width, height: displayFrame.height))
            let inset = min(max(0, surface.topInset), surface.frame.width / 2)
            if inset > 0 {
                visibleRasterBounds = visibleRasterBounds.intersection(CGRect(
                    x: inset, y: rasterBounds.minY, width: surface.frame.width - inset * 2, height: rasterBounds.height))
            }
            let layoutChanged = visual.rasterBounds != rasterBounds || visual.lastWidth != surface.frame.width
                || visual.rasterScale != scale || visual.rasterOccluders != rasterOccluders
                || visual.lastTopInset != surface.topInset || visual.visibleRasterBounds != visibleRasterBounds
            if layoutChanged {
                visual.rasterFullyOccluded = RendererGeometry.visibleRectangles(in: visibleRasterBounds, subtracting: rasterOccluders).isEmpty
                visual.lastWidth = surface.frame.width
                visual.lastTopInset = surface.topInset
                visual.rasterBounds = rasterBounds
                visual.rasterScale = scale
                visual.rasterOccluders = rasterOccluders
                visual.visibleRasterBounds = visibleRasterBounds
            }
            if visual.rasterFullyOccluded {
                // Keep the independent ball container and its live mask. A ball can
                // protrude above a foreground window that covers the whole drift band.
                visual.snow.isHidden = true
                continue
            }
            let contourTolerance = 0.25 / max(1, scale)
            let hasVisibleSnow = drift.heights.contains { $0 > 0.05 }
            let contourChanged = refreshPaths && (visual.lastHeights.count != drift.heights.count
                || visual.snow.isHidden == hasVisibleSnow
                || zip(visual.lastHeights, drift.heights).contains { abs($0 - $1) >= contourTolerance })
            if visual.snow.texture == nil || layoutChanged || contourChanged {
                visual.snow.texture = RendererTextures.drift(drift, bounds: rasterBounds, scale: scale,
                                                            occluders: rasterOccluders)
                driftRasterizations += 1
                visual.snow.size = rasterBounds.size
                visual.snow.isHidden = !hasVisibleSnow
                visual.lastHeights = drift.heights
            }
            visual.snow.position = toLocal(CGPoint(x: surface.frame.minX + rasterBounds.minX,
                                                  y: surface.top + rasterBounds.minY))
        }
        renderBalls()
        renderDebris()
        renderSnowplows()
    }

    private func renderSnowplows() {
        for id in Array(snowplowVisuals.keys) where snowplowPasses[id] == nil {
            snowplowVisuals.removeValue(forKey: id)?.removeFromParent()
        }
        for (id, pass) in snowplowPasses {
            let visual: SnowplowVisual
            if let existing = snowplowVisuals[id] { visual = existing }
            else {
                visual = SnowplowVisual(); snowplowVisuals[id] = visual
                snowplowLayer.addChild(visual)
            }
            visual.update(pass: pass, displayFrame: displayFrame, reducedMotion: weather.reducedMotion)
        }
    }

    private func updateMask(_ visual: SurfaceVisual, surface: SnowSurface, contentBounds: CGRect) {
        // Drifts are clipped into their cached bitmap. Only moving attached balls
        // require a live GPU crop, so an ordinary desktop uses no extra crop passes.
        guard !contentBounds.isNull else {
            visual.maskSignature = nil
            visual.setMasked(false)
            return
        }
        let worldBand = contentBounds.intersection(displayFrame)
        let localOccluders = surface.occluders.filter { $0.intersects(worldBand) }
            .map { CGRect(x: $0.minX - displayFrame.minX, y: $0.minY - displayFrame.minY,
                          width: $0.width, height: $0.height) }
        let band = worldBand.isNull ? CGRect.zero : CGRect(x: worldBand.minX - displayFrame.minX,
                                                         y: worldBand.minY - displayFrame.minY,
                                                         width: worldBand.width, height: worldBand.height)
        let signature = MaskSignature(bounds: band, occluders: localOccluders)
        guard signature != visual.maskSignature else { return }
        visual.maskSignature = signature
        visual.setMasked(!localOccluders.isEmpty)
        guard !localOccluders.isEmpty else { return }
        let path = CGMutablePath()
        for rect in RendererGeometry.visibleRectangles(in: signature.bounds, subtracting: localOccluders) {
            path.addRect(rect)
        }
        visual.mask.path = path
    }

    private func renderBalls() {
        let ids = Set(world.balls.map(\.id))
        for id in Array(ballVisuals.keys) where !ids.contains(id) {
            ballVisuals.removeValue(forKey: id)?.root.removeFromParent()
        }
        var decorations: [UUID: Int] = [:]
        for snowman in world.snowmen {
            for (index, id) in snowman.ballIDs.enumerated() { decorations[id] = index }
        }
        for ball in world.balls {
            let visual = ballVisuals[ball.id] ?? makeBall(id: ball.id)
            let parent = ball.surfaceID.flatMap { surfaceVisuals[$0]?.contents } ?? looseBallLayer
            if visual.root.parent !== parent {
                visual.root.removeFromParent()
                parent.addChild(visual.root)
            }
            visual.root.position = toLocal(ball.position)
            visual.snow.size = RendererTextures.snowballSize(radius: ball.radius)
            visual.root.isHidden = !RendererGeometry.ballBounds(ball).intersects(displayFrame)
            let detailStep = ball.surfaceID == nil ? 1 : SurfaceRenderDepth.step(count: world.surfaces.count)
            visual.root.zPosition = 0.5 * detailStep
            visual.face.zPosition = 0.05 * detailStep
            visual.buttons.zPosition = 0.05 * detailStep
            visual.face.isHidden = decorations[ball.id] != 2
            visual.buttons.isHidden = decorations[ball.id] != 1
            let scale = ball.radius / 18
            visual.face.setScale(scale)
            visual.buttons.setScale(scale)
        }
    }

    private func makeBall(id: UUID) -> BallVisual {
        let visual = BallVisual(texture: RendererTextures.snowball(id: id))
        ballVisuals[id] = visual
        return visual
    }

    private func renderDebris() {
        let fragments = world.debris.filter { displayFrame.insetBy(dx: -8, dy: -8).contains($0.position) }.prefix(500)
        while debrisNodes.count < fragments.count {
            let node = SKSpriteNode(texture: roundTexture)
            debrisLayer.addChild(node)
            debrisNodes.append(node)
        }
        for (index, node) in debrisNodes.enumerated() {
            if index >= fragments.count { node.isHidden = true; continue }
            let fragment = fragments[fragments.startIndex + index]
            node.isHidden = false
            node.position = toLocal(fragment.position)
            node.size = CGSize(width: fragment.radius * 3, height: fragment.radius * 3)
            let fade = min(1, max(0, fragment.lifetime / 0.5))
            node.alpha = 0.9 * fade * fade * (3 - 2 * fade)
        }
        if debrisNodes.count > max(32, fragments.count + 32) {
            let excess = debrisNodes.count - max(32, fragments.count + 32)
            for node in debrisNodes.suffix(excess) { node.removeFromParent() }
            debrisNodes.removeLast(excess)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pointerDown(at: event.location(in: self), timestamp: event.timestamp)
    }

    func pointerDown(at localPoint: CGPoint, timestamp: TimeInterval) {
        guard playing else { return }
        let point = clampedWorldPoint(localPoint)
        previousPointerTime = timestamp
        lastPointer = point
        releaseVelocity = .zero
        switch tool {
        case .mitten:
            isPainting = true
            world.brush(at: point, radius: 24)
        case .shovel:
            if decorationOptions.christmasTrees,
               let id = festiveWorld.hitTest(point, displayFrame: displayFrame, snow: world) {
                festiveWorld.remove(id: id)
            } else if let surface = world.surface(at: point) { world.clear(surfaceID: surface.id) }
        case .snowball:
            if world.beginDrag(at: point) != nil || world.beginSnowball(at: point) != nil {
                isDraggingBall = true
            } else {
                showLimit(world.balls.count >= 30 ? "Уже 30 снежков. Уберите часть лопатой." : "Нужно больше снега. Начните на сугробе.")
            }
        case .tree:
            guard decorationOptions.christmasTrees else { return }
            draggingTreeID = festiveWorld.hitTest(point, displayFrame: displayFrame, snow: world)
                ?? festiveWorld.place(at: point, displayFrame: displayFrame, snow: world)
            if let id = draggingTreeID, let placement = festiveWorld.placements(in: world).first(where: { $0.id == id }) {
                treeDragOffset = CGVector(dx: placement.base.x - point.x, dy: placement.base.y - point.y)
            }
            if draggingTreeID == nil { showLimit("Поставьте ёлочку у сугроба на полу или окне. Не больше восьми.") }
        }
        refreshDecorations(delta: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        pointerDragged(at: event.location(in: self), timestamp: event.timestamp)
    }

    func pointerDragged(at localPoint: CGPoint, timestamp: TimeInterval) {
        guard playing else { return }
        let point = clampedWorldPoint(localPoint)
        if let id = draggingTreeID, decorationOptions.christmasTrees {
            let base = CGPoint(x: point.x + treeDragOffset.dx, y: point.y + treeDragOffset.dy)
            _ = festiveWorld.move(id: id, to: base, displayFrame: displayFrame, snow: world)
            refreshDecorations(delta: 0)
        }
        if isPainting {
            if let previous = lastPointer {
                let distance = hypot(point.x - previous.x, point.y - previous.y)
                let count = min(80, max(1, Int(ceil(distance / 8))))
                for step in 1...count {
                    let t = CGFloat(step) / CGFloat(count)
                    world.brush(at: CGPoint(x: previous.x + (point.x - previous.x) * t,
                                            y: previous.y + (point.y - previous.y) * t), radius: 24)
                }
            } else { world.brush(at: point, radius: 24) }
        }
        if isDraggingBall {
            world.drag(to: point)
            if let previous = lastPointer {
                let elapsed = max(1.0 / 240.0, timestamp - previousPointerTime)
                // No throw from delayed events or a discontinuity after a modal menu.
                if elapsed < 0.15 {
                    let vx = max(-500, min(500, (point.x - previous.x) / elapsed))
                    let vy = max(-500, min(500, (point.y - previous.y) / elapsed))
                    releaseVelocity = CGVector(dx: releaseVelocity.dx * 0.4 + vx * 0.6,
                                               dy: releaseVelocity.dy * 0.4 + vy * 0.6)
                } else { releaseVelocity = .zero }
            }
        }
        lastPointer = point
        previousPointerTime = timestamp
    }

    override func mouseUp(with event: NSEvent) {
        pointerUp(timestamp: event.timestamp)
    }

    func pointerUp(timestamp: TimeInterval) {
        guard playing else { return }
        if isDraggingBall {
            let velocity = timestamp - previousPointerTime < 0.12 ? releaseVelocity : .zero
            world.endDrag(velocity: velocity)
        }
        isDraggingBall = false
        draggingTreeID = nil
        treeDragOffset = .zero
        isPainting = false
        lastPointer = nil
        releaseVelocity = .zero
    }

    override func keyDown(with event: NSEvent) {
        if playing && event.keyCode == 53 { cancelInteraction(); onExitGame?() }
        else { super.keyDown(with: event) }
    }

    private func showLimit(_ message: String) {
        guard sceneTime - lastLimitTime > 1 else { return }
        lastLimitTime = sceneTime
        onLimit?(message)
    }

    private func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + displayFrame.minX, y: point.y + displayFrame.minY)
    }

    private func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - displayFrame.minX, y: point.y - displayFrame.minY)
    }

    private func clampedWorldPoint(_ local: CGPoint) -> CGPoint {
        toWorld(CGPoint(x: min(size.width, max(0, local.x)), y: min(size.height, max(0, local.y))))
    }

    private func random() -> Double {
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        return Double((rng &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
    }

    /// Renders this application's node tree only. Does not capture other windows or the display.
    @discardableResult
    func exportPreview(to url: URL) -> Bool {
        renderWorld(refreshPaths: true)
        refreshDecorations(delta: 0)
        guard let view, let texture = view.texture(from: self, crop: CGRect(origin: .zero, size: size)) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: texture.cgImage())
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    /// Useful for integration evidence without requiring access to window contents.
    var renderingStatistics: (particles: Int, surfaces: Int, balls: Int, nodes: Int) {
        (onGPUParticles == nil ? flakes.count : gpuParticleCount, surfaceVisuals.count, ballVisuals.count, countNodes(self))
    }

    private func countNodes(_ node: SKNode) -> Int { 1 + node.children.reduce(0) { $0 + countNodes($1) } }
}

/// Rectangle subtraction runs only when order, geometry, foreground or focus changes.
private struct ParticleOcclusionCache {
    private struct Window: Equatable {
        let id: String
        let frame: CGRect
        let bodyOccluders: [CGRect]
        let active: Bool
    }
    private var previous: [Window] = []
    private var previousDisplay = CGRect.null
    private var activeWideIDs: Set<String> = []
    private var transitionRemaining: TimeInterval = 0
    private(set) var solid: [CGRect] = []
    private(set) var wide: [CGRect] = []

    mutating func update(surfaces: [SnowSurface], display: CGRect) {
        let windows = surfaces.filter { $0.kind == .window && $0.isVisible && $0.frame.intersects(display) }
            .map { Window(id: $0.id, frame: $0.frame, bodyOccluders: $0.bodyOccluders, active: $0.suppressesSnowfall) }
        guard windows != previous || display != previousDisplay else { return }
        let active = Set(windows.filter { $0.active && WideWindowPolicy.mask(forWindow: $0.frame, display: display) != nil }.map(\.id))
        if active != activeWideIDs && !previousDisplay.isNull { transitionRemaining = 0.2 }
        activeWideIDs = active
        previous = windows; previousDisplay = display
        solid.removeAll(keepingCapacity: true); wide.removeAll(keepingCapacity: true)
        var foreground: [CGRect] = []
        for window in windows {
            defer { foreground.append(window.frame) }
            let isWide = WideWindowPolicy.mask(forWindow: window.frame, display: display) != nil
            // The inactive wide window is intentionally transparent to snowfall,
            // but its foreground body must still hide masks belonging to windows behind it.
            guard !isWide || window.active else { continue }
            let visible = RendererGeometry.visibleRectangles(in: window.frame.intersection(display),
                subtracting: window.bodyOccluders + foreground)
                .map { $0.offsetBy(dx: -display.minX, dy: -display.minY) }
            if isWide { wide.append(contentsOf: visible) }
            else { solid.append(contentsOf: visible) }
        }
    }

    mutating func advanceTransition(by delta: TimeInterval) -> Bool {
        let fades = transitionRemaining > 1e-9
        transitionRemaining = max(0, transitionRemaining - delta)
        return fades
    }
}

private struct Flake {
    let id: UInt32
    var gpuState: SnowGPUFlake {
        SnowGPUFlake(geometry: SIMD4(Float(position.x), Float(position.y), Float(sideSize), Float(rotation)),
            dynamics: SIMD4(Float(speed), Float(depth), Float(phase), Float(frequency)),
            style: SIMD4(Float(sway), Float(spin), Float(opacity), Float(age)),
            lifecycle: SIMD4(Float(retirementAge ?? -1), Float(wideVisibility), visibilityInitialized ? 1 : 0, 0),
            appearance: SIMD4(Float(alpha), crystal ? 1 : 0, 0, 0), identity: SIMD4(id, 1, hiddenByWindows ? 0 : 1, 0))
    }
    var node: SKSpriteNode?
    var position: CGPoint
    var rotation: CGFloat
    var sideSize: CGFloat
    var crystal: Bool
    var alpha: CGFloat
    var speed: CGFloat
    var depth: CGFloat
    var phase: CGFloat
    var frequency: CGFloat
    var sway: CGFloat
    var spin: CGFloat
    var opacity: CGFloat
    var age: TimeInterval
    var retirementAge: TimeInterval? = nil
    var hiddenByWindows = false
    var wideVisibility: CGFloat = 1
    var visibilityInitialized = false
    private var presentationAlpha: CGFloat { CGFloat(Float(alpha * wideVisibility)) }

    var instance: SnowParticleInstance {
        SnowParticleInstance(geometry: SIMD4(Float(position.x), Float(position.y), Float(sideSize), Float(rotation)),
                             appearance: SIMD4(Float(presentationAlpha), crystal ? 1 : 0, 0, 0))
    }

    mutating func updateVisibility(hardHidden: Bool, wideHidden: Bool, delta: TimeInterval, fades: Bool) {
        let target: CGFloat = wideHidden ? 0 : 1
        if !visibilityInitialized || !fades {
            wideVisibility = target
            visibilityInitialized = true
        } else {
            let step = CGFloat(delta / 0.2)
            if abs(target - wideVisibility) <= step + 1e-9 { wideVisibility = target }
            else { wideVisibility += target > wideVisibility ? step : -step }
        }
        let hidden = hardHidden || wideVisibility == 0
        if hidden != hiddenByWindows {
            hiddenByWindows = hidden
            node?.isHidden = hidden
        }
        let effectiveAlpha = presentationAlpha
        if node?.alpha != effectiveAlpha { node?.alpha = effectiveAlpha }
    }

    mutating func advance(delta: TimeInterval, time: CGFloat, wind: CGVector, motionScale: CGFloat,
                          reducedMotion: Bool, width: CGFloat, collisionBands: [ParticleCollisionBand]) -> Bool {
        let old = position
        let wasFadingIn = age < 0.5
        age += delta
        if let value = retirementAge { retirementAge = value + delta }
        let offset = reducedMotion ? 0 : sin(time * frequency + phase) * sway
        let vx = (wind.dx * 155 * depth + offset) * motionScale
        let vy = -max(12, speed * (1 - wind.dy * 0.28)) * motionScale
        let next = CGPoint(x: old.x + vx * delta, y: old.y + vy * delta)
        position = CGPoint(x: CGFloat(Float(next.x)), y: CGFloat(Float(next.y)))
        rotation = CGFloat(Float(rotation + spin * delta * motionScale))
        node?.position = position
        node?.zRotation = rotation
        // Stable opacity does not need to invalidate the SpriteKit node every frame.
        if wasFadingIn || retirementAge != nil {
            let retirementOpacity = retirementAge.map { max(0, 1 - $0 / 0.5) } ?? 1
            alpha = CGFloat(Float(opacity * min(1, age / 0.5) * retirementOpacity))
        }
        if next.y < -12 || next.x < -90 || next.x > width + 90 || (retirementAge ?? 0) >= 0.5 { return true }
        for band in collisionBands where band.intersects(from: old, to: next) { return true }
        return false
    }
}

/// Scalar broad phase is built once per frame, rather than reading CGRect for every flake.
/// The final crossing still checks the complete foreground masks and exact sample grid.
struct ParticleCollisionBand {
    private let originX: CGFloat
    private let minimumX: CGFloat
    private let maximumX: CGFloat
    private let baseY: CGFloat
    private let maximumY: CGFloat
    private let contour: SnowContour
    private let surface: SnowSurface
    private let displayOrigin: CGPoint

    init?(drift: SnowDrift, displayFrame: CGRect) {
        let surface = drift.surface
        guard surface.isVisible, !drift.heights.isEmpty,
              surface.frame.maxX >= displayFrame.minX, surface.frame.minX <= displayFrame.maxX,
              surface.top <= displayFrame.maxY, surface.top >= displayFrame.minY else { return nil }
        self.surface = surface
        contour = drift.visibleContour
        displayOrigin = displayFrame.origin
        originX = surface.frame.minX - displayFrame.minX
        let inset = min(max(0, surface.topInset), surface.frame.width / 2)
        minimumX = originX + inset
        maximumX = originX + surface.frame.width - inset
        baseY = surface.top - displayFrame.minY
        maximumY = baseY + (drift.heights.max() ?? 0)
    }

    @inline(__always)
    func intersects(from old: CGPoint, to next: CGPoint) -> Bool {
        guard old.y >= baseY, next.y <= maximumY, next.x >= minimumX, next.x <= maximumX else { return false }
        let top = baseY + contour.height(at: next.x - originX)
        return old.y >= top && next.y <= top
            && surface.isExposed(CGPoint(x: next.x + displayOrigin.x, y: top + displayOrigin.y))
    }
}

/// Reserve one depth interval per support so objects cannot cross window order.
enum SurfaceRenderDepth {
    static func step(count: Int) -> CGFloat { 1 / CGFloat(max(1, count + 1)) }
    static func base(count: Int, index: Int) -> CGFloat { CGFloat(max(0, count - index)) * step(count: count) }
}

private struct MaskSignature: Equatable {
    var bounds: CGRect
    var occluders: [CGRect]
}

private final class SurfaceVisual {
    let container = SKNode()
    let crop = SKCropNode()
    let contents = SKNode()
    let mask = SKShapeNode()
    let snow = SKSpriteNode()
    var maskSignature: MaskSignature?
    var lastWidth: CGFloat = -1
    var lastTopInset: CGFloat = -1
    var lastHeights: [CGFloat] = []
    var rasterBounds = CGRect.null
    var visibleRasterBounds = CGRect.null
    var rasterFullyOccluded = false
    var rasterScale: CGFloat = 0
    var rasterOccluders: [CGRect] = []
    private var masked = false

    init() {
        mask.fillColor = .white
        mask.strokeColor = .clear
        mask.lineWidth = 0
        mask.isAntialiased = false
        crop.maskNode = mask
        snow.anchorPoint = .zero
        container.addChild(snow)
        container.addChild(contents)
    }

    func setMasked(_ value: Bool) {
        guard value != masked else { return }
        masked = value
        contents.removeFromParent()
        if value {
            container.addChild(crop)
            crop.addChild(contents)
        } else {
            crop.removeFromParent()
            container.addChild(contents)
        }
    }
}

private final class BallVisual {
    let root = SKNode()
    let snow: SKSpriteNode
    let face = SKSpriteNode(texture: RendererTextures.snowmanFace)
    let buttons = SKSpriteNode(texture: RendererTextures.snowmanButtons)

    init(texture: SKTexture) {
        snow = SKSpriteNode(texture: texture)
        root.addChild(snow)
        root.addChild(face)
        root.addChild(buttons)
        face.size = CGSize(width: 36, height: 36)
        buttons.size = CGSize(width: 36, height: 36)
        face.zPosition = 0.1
        buttons.zPosition = 0.1
        face.isHidden = true
        buttons.isHidden = true
    }
}

/// Geometry stays separate from SpriteKit so masks can be checked with deterministic tests.
enum RendererGeometry {
    static let snowballVariantCount = 8

    static func snowballVariant(for id: UUID) -> Int {
        let hash = id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(snowballVariantCount))
    }

    /// Sample Perlin on a circle: the seam and its slope match without a join.
    /// Keep the vertical contacts circular so settled balls still touch the floor
    /// and one another. Physics uses the nominal radius; this is visual relief only.
    static func snowballOutline(variant: Int) -> [CGPoint] {
        let seed = UInt64(variant) &* 0x9e3779b97f4a7c15 &+ 0x51a7
        return (0..<128).map { index in
            let angle = Double(index) * 2 * .pi / 128
            let x = cos(angle), y = sin(angle)
            func octave(_ frequency: Double, _ salt: UInt64) -> Double {
                SnowHeightEnvelope.noise(at: x * frequency + 11.31, seed: seed ^ salt)
                    + SnowHeightEnvelope.noise(at: y * frequency + 7.73, seed: seed ^ salt ^ 0xbf58476d1ce4e5b9)
            }
            let noise = octave(2.3, 0) * 0.75 + octave(6.1, 0x94d049bb133111eb) * 0.25
            let radius = 1 + 0.03 * noise * x * x
            return CGPoint(x: x * radius, y: y * radius)
        }
    }

    static func ballBounds(_ ball: Snowball) -> CGRect {
        CGRect(x: ball.position.x - ball.radius - 2, y: ball.position.y - ball.radius - 2,
               width: ball.radius * 2 + 4, height: ball.radius * 2 + 4)
    }

    static func driftRasterBounds(for surface: SnowSurface, displayFrame: CGRect) -> CGRect? {
        let left = max(0, displayFrame.minX - surface.frame.minX)
        let right = min(surface.frame.width, displayFrame.maxX - surface.frame.minX)
        guard right > left, surface.top + SnowDrift.maximumHeight + 3 > displayFrame.minY,
              surface.top - 3 < displayFrame.maxY else { return nil }
        return CGRect(x: left - 2, y: -3, width: right - left + 4, height: SnowDrift.maximumHeight + 6)
    }

    static func visibleRectangles(in bounds: CGRect, subtracting occluders: [CGRect]) -> [CGRect] {
        guard bounds.width > 0 && bounds.height > 0 else { return [] }
        var rectangles = [bounds]
        for occluder in occluders {
            guard occluder.width > 0 && occluder.height > 0 else { continue }
            var next: [CGRect] = []
            for rect in rectangles {
                let cut = rect.intersection(occluder)
                if cut.isNull || cut.isEmpty { next.append(rect); continue }
                if cut.minY > rect.minY { next.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY)) }
                if cut.maxY < rect.maxY { next.append(CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY)) }
                if cut.minX > rect.minX { next.append(CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height)) }
                if cut.maxX < rect.maxX { next.append(CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)) }
            }
            // An adversarial window arrangement cannot grow an unbounded mask. Hiding the
            // surface is preferable to drawing any of its snow over a foreground window.
            if next.count > 2_048 { return [] }
            rectangles = next
            if rectangles.isEmpty { break }
        }
        return rectangles
    }

    static func driftPath(heights: [CGFloat], width: CGFloat, roundedEnds: Bool = true, topInset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let points = ridgePoints(heights: heights, width: width, roundedEnds: roundedEnds, topInset: topInset)
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: -0.5))
        path.addLine(to: first)
        addRidge(to: path, points: points)
        path.addLine(to: CGPoint(x: last.x, y: -0.5))
        path.closeSubpath()
        return path
    }

    static func driftRidge(heights: [CGFloat], width: CGFloat, roundedEnds: Bool = true, topInset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let points = ridgePoints(heights: heights, width: width, roundedEnds: roundedEnds, topInset: topInset)
        guard let first = points.first else { return path }
        path.move(to: first)
        addRidge(to: path, points: points)
        return path
    }

    private static func ridgePoints(heights: [CGFloat], width: CGFloat, roundedEnds: Bool, topInset: CGFloat) -> [CGPoint] {
        let contour = SnowContour(heights: heights, width: width, roundedEnds: roundedEnds, topInset: topInset)
        return (0..<contour.pointCount).map { contour.point(at: $0) }
    }

    private static func addRidge(to path: CGMutablePath, points: [CGPoint]) {
        for index in 1..<points.count {
            let previous = points[index - 1]
            let point = points[index]
            let middle = CGPoint(x: (previous.x + point.x) * 0.5, y: (previous.y + point.y) * 0.5)
            path.addQuadCurve(to: middle, control: previous)
        }
        if let end = points.last { path.addQuadCurve(to: end, control: end) }
    }
}

private enum RendererTextures {
    private static let snowballTextureSide: CGFloat = 128
    private static let snowballTextureInset: CGFloat = 3
    // Bounded shared textures: no Perlin sampling or image creation in renderBalls.
    private static let snowballs = (0..<RendererGeometry.snowballVariantCount).map { makeSnowball(variant: $0) }

    static func snowball(id: UUID) -> SKTexture {
        snowballs[RendererGeometry.snowballVariant(for: id)]
    }

    static func snowballSize(radius: CGFloat) -> CGSize {
        // Padding belongs to the texture, not the physical ball. A fixed +2 pt
        // correction shrinks large balls and leaves a visible gap in their stack.
        let side = radius * 2 * snowballTextureSide / (snowballTextureSide - snowballTextureInset * 2)
        return CGSize(width: side, height: side)
    }

    // Static high-resolution glyph textures retain smooth tiny circles without relying
    // on an off-screen crop pass to antialias each snowman's separate shape nodes.
    static let snowmanFace = texture(size: 128) { context, _ in
        context.scaleBy(x: 128 / 36, y: 128 / 36)
        context.translateBy(x: 18, y: 18)
        context.setFillColor(CGColor(red: 0.12, green: 0.19, blue: 0.25, alpha: 1))
        for x: CGFloat in [-5, 5] {
            context.fillEllipse(in: CGRect(x: x - 1.65, y: 4 - 1.65, width: 3.3, height: 3.3))
        }
        context.setFillColor(CGColor(red: 1, green: 0.46, blue: 0.15, alpha: 1))
        context.move(to: CGPoint(x: -1, y: 0))
        context.addLine(to: CGPoint(x: 11, y: -2))
        context.addLine(to: CGPoint(x: -1, y: -4))
        context.closePath()
        context.fillPath()
        context.setFillColor(CGColor(gray: 0.22, alpha: 0.85))
        for i in -1...1 {
            context.fillEllipse(in: CGRect(x: CGFloat(i) * 3 - 0.85,
                                           y: -8 + CGFloat(abs(i)) - 0.85, width: 1.7, height: 1.7))
        }
    }

    static let snowmanButtons = texture(size: 128) { context, _ in
        context.scaleBy(x: 128 / 36, y: 128 / 36)
        context.translateBy(x: 18, y: 18)
        context.setFillColor(CGColor(red: 0.2, green: 0.29, blue: 0.36, alpha: 1))
        for i in -1...1 {
            context.fillEllipse(in: CGRect(x: -1.9, y: CGFloat(i) * 7 - 1.9, width: 3.8, height: 3.8))
        }
    }

    /// Rasterize a contour only when its visible shape changes. Keeping long stroked
    /// SKShapeNodes in an SKCropNode makes SpriteKit restroke them for bounds every frame.
    static func drift(_ drift: SnowDrift, bounds: CGRect, scale: CGFloat, occluders: [CGRect]) -> SKTexture? {
        let scale = max(1, min(3, scale))
        let pixelWidth = max(1, Int(ceil(bounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(bounds.height * scale)))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        let inset = drift.surface.topInset.isFinite
            ? min(max(0, drift.surface.topInset), drift.surface.frame.width / 2) : 0
        if inset > 0 {
            // Keep antialiased cap strokes and their shadow off the rounded corners too.
            context.clip(to: CGRect(x: inset, y: bounds.minY,
                                    width: max(0, drift.surface.frame.width - inset * 2), height: bounds.height))
        }
        if !occluders.isEmpty {
            let visible = RendererGeometry.visibleRectangles(in: bounds, subtracting: occluders)
            // CoreGraphics treats clipping with an empty current path as a no-op.
            // Return the untouched transparent bitmap instead of drawing hidden snow.
            if visible.isEmpty {
                guard let image = context.makeImage() else { return nil }
                return SKTexture(cgImage: image)
            }
            let clip = CGMutablePath()
            for rect in visible { clip.addRect(rect) }
            context.addPath(clip)
            context.clip()
        }
        let rounded = drift.surface.kind != .floor
        let contour = RendererGeometry.driftPath(heights: drift.heights, width: drift.surface.frame.width,
                                                roundedEnds: rounded, topInset: drift.surface.topInset)
        context.saveGState()
        context.translateBy(x: 0, y: -0.9)
        context.setFillColor(CGColor(red: 0.57, green: 0.67, blue: 0.79, alpha: 0.48))
        context.addPath(contour)
        context.fillPath()
        context.restoreGState()
        context.setFillColor(CGColor(red: 0.94, green: 0.965, blue: 1, alpha: 0.99))
        context.addPath(contour)
        context.fillPath()
        if drift.surface.kind == .floor {
            // A ridge stroke at zero height leaves a white line behind the tractor.
            // Keep the floor highlight inside the remaining snow silhouette.
            context.addPath(contour)
            context.clip()
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.94))
        context.setLineWidth(1.1)
        context.setLineCap(.round)
        context.addPath(RendererGeometry.driftRidge(heights: drift.heights, width: drift.surface.frame.width,
                                                  roundedEnds: rounded, topInset: drift.surface.topInset))
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return texture
    }

    static func particle(crystal: Bool) -> SKTexture {
        texture(size: 32) { context, rect in
            let colors = [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.65), CGColor(gray: 1, alpha: 0)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1])!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                                       endCenter: CGPoint(x: 16, y: 16), endRadius: crystal ? 12 : 15, options: [])
            if crystal {
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
                context.setLineWidth(1.1)
                context.setLineCap(.round)
                context.translateBy(x: 16, y: 16)
                for _ in 0..<6 {
                    context.move(to: .zero); context.addLine(to: CGPoint(x: 0, y: 11))
                    context.move(to: CGPoint(x: 0, y: 7)); context.addLine(to: CGPoint(x: -2.5, y: 9.5))
                    context.move(to: CGPoint(x: 0, y: 7)); context.addLine(to: CGPoint(x: 2.5, y: 9.5))
                    context.strokePath()
                    context.rotate(by: .pi / 3)
                }
            }
        }
    }

    private static func makeSnowball(variant: Int) -> SKTexture {
        texture(size: Int(snowballTextureSide)) { context, rect in
            let radius = (rect.width - snowballTextureInset * 2) / 2
            let outline = RendererGeometry.snowballOutline(variant: variant).map {
                CGPoint(x: rect.midX + $0.x * radius, y: rect.midY + $0.y * radius)
            }
            context.addLines(between: outline)
            context.closePath()
            context.clip()
            let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                          CGColor(red: 0.94, green: 0.965, blue: 1, alpha: 1),
                          CGColor(red: 0.68, green: 0.77, blue: 0.88, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.65, 1])!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 44, y: 87), startRadius: 0,
                                       endCenter: CGPoint(x: 64, y: 64), endRadius: 74, options: [.drawsAfterEndLocation])
            // Sparse fixed grain prevents a polished-plastic look without per-frame texture work.
            for i in 0..<38 {
                let x = CGFloat((i * 37 + 13) % 112 + 8)
                let y = CGFloat((i * 53 + 29) % 112 + 8)
                context.setFillColor(CGColor(gray: i.isMultiple(of: 3) ? 0.7 : 1, alpha: 0.15))
                context.fillEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
            }
        }
    }

    private static func texture(size: Int, draw: (CGContext, CGRect) -> Void) -> SKTexture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture(image: NSImage(size: CGSize(width: size, height: size)))
        }
        draw(context, CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { return SKTexture(image: NSImage(size: CGSize(width: size, height: size))) }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return texture
    }
}


/// Immutable geometry input. GPU-owned state never needs a synchronous CPU readback.
struct SnowGPUFlake {
    var geometry: SIMD4<Float>
    var dynamics: SIMD4<Float>
    var style: SIMD4<Float>
    var lifecycle: SIMD4<Float>
    var appearance: SIMD4<Float>
    var identity: SIMD4<UInt32>
}
struct SnowGPURoof {
    var bounds: SIMD4<Float> // minX, maxX, baseY, maximumY in scene points
    var indices: SIMD4<UInt32> // first point, count, first occluder, count
}
final class SnowGPUParticleGeometry {
    let solid: [SIMD4<Float>]
    let wide: [SIMD4<Float>]
    let roofs: [SnowGPURoof]
    let points: [SIMD2<Float>]
    let occluders: [SIMD4<Float>]
    init(solid: [SIMD4<Float>], wide: [SIMD4<Float>], roofs: [SnowGPURoof],
         points: [SIMD2<Float>], occluders: [SIMD4<Float>]) {
        self.solid = solid; self.wide = wide; self.roofs = roofs
        self.points = points; self.occluders = occluders
    }
}
struct SnowGPUParticleFrame {
    let delta: TimeInterval
    let time: TimeInterval
    let rate: Double
    let wind: CGVector
    let size: CGSize
    let cap: Int
    let reducedMotion: Bool
    let fades: Bool
    let geometry: SnowGPUParticleGeometry
}
private struct SnowGPUGeometryCache {
    private struct Signature: Equatable {
        let surface: SnowSurface
        let heights: [CGFloat]
        static func == (a: Self, b: Self) -> Bool {
            a.surface.id == b.surface.id && a.surface.frame == b.surface.frame && a.surface.kind == b.surface.kind
                && a.surface.topInset == b.surface.topInset && a.surface.occluders == b.surface.occluders
                && a.heights == b.heights
        }
    }
    private var previous: [Signature] = []
    private var display = CGRect.null
    private var solid: [CGRect] = []
    private var wide: [CGRect] = []
    private var value: SnowGPUParticleGeometry?
    mutating func snapshot(drifts: [String: SnowDrift], display: CGRect, solid: [CGRect], wide: [CGRect]) -> SnowGPUParticleGeometry {
        let selected = drifts.values.filter {
            let s = $0.surface
            return s.isVisible && !$0.heights.isEmpty && s.frame.maxX >= display.minX && s.frame.minX <= display.maxX
                && s.top <= display.maxY && s.top >= display.minY
                && !(s.kind == .window && WideWindowPolicy.mask(forWindow: s.frame, display: display) != nil)
        }.sorted { $0.surface.id < $1.surface.id }
        let signatures = selected.map { Signature(surface: $0.surface, heights: $0.heights) }
        if signatures == previous, display == self.display, solid == self.solid, wide == self.wide, let value { return value }
        previous = signatures; self.display = display; self.solid = solid; self.wide = wide
        func rect(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)) }
        var roofs: [SnowGPURoof] = [], points: [SIMD2<Float>] = [], occluders: [SIMD4<Float>] = []
        for drift in selected {
            let surface = drift.surface, contour = drift.visibleContour
            guard contour.pointCount > 1 else { continue }
            let x = surface.frame.minX - display.minX, y = surface.top - display.minY
            let inset = min(max(0, surface.topInset), surface.frame.width / 2)
            roofs.append(SnowGPURoof(bounds: SIMD4(Float(x + inset), Float(x + surface.frame.width - inset),
                Float(y), Float(y + (drift.heights.max() ?? 0))), indices: SIMD4(UInt32(points.count),
                UInt32(contour.pointCount), UInt32(occluders.count), UInt32(surface.occluders.count))))
            for i in 0..<contour.pointCount {
                let p = contour.point(at: i)
                points.append(SIMD2(Float(p.x + x), Float(p.y + y)))
            }
            occluders += surface.occluders.map { rect($0.offsetBy(dx: -display.minX, dy: -display.minY)) }
        }
        let fresh = SnowGPUParticleGeometry(solid: solid.map(rect), wide: wide.map(rect), roofs: roofs,
                                           points: points, occluders: occluders)
        value = fresh
        return fresh
    }
}
