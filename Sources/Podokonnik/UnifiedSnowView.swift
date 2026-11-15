import AppKit
import MetalKit
import SpriteKit

/// One explicit clock and drawable for SpriteKit objects and instanced particles.
/// Rendering remains independent of whether this accessory application is active.
final class UnifiedSnowView: NSView, CAMetalDisplayLinkDelegate, SKSceneDelegate {
    private let scene: SnowScene
    private let renderer: SKRenderer
    private let batch: ParticleBatchRenderer
    private let simulation: SnowGPUParticleSimulation?
    var usesGPUSimulation: Bool { simulation != nil }
    private var simulationFrame: SnowGPUParticleFrame?
    private var lastStatisticsTime: TimeInterval = -.infinity
    private let shouldRender: (TimeInterval) -> Bool
    private let maximumFPS: Int
    private var displayLink: CAMetalDisplayLink?
    private var packet: [SnowParticleInstance] = []
    private var paused = true
    private var invalidated = false
    private var failureLatched = false
    private var consecutiveFailedSubmissions = 0
    private var lastPresentation: TimeInterval?
    private var presentationGeneration: UInt64 = 0

    var onFailure: ((String) -> Void)?
    /// Optional own-scene diagnostics: target time and actual drawable presentation.
    var onFramePresented: ((TimeInterval, TimeInterval) -> Void)?
    var recordsPresentation = false
    private(set) var submittedFrames = 0
    private(set) var presentationIntervals: [TimeInterval] = []

    var isPaused: Bool {
        get { paused }
        set {
            guard !invalidated, !failureLatched, paused != newValue else { return }
            paused = newValue
            scene.isPaused = newValue
            scene.resetAnimationClock()
            resetPresentationClock()
            updateDisplayLinkState()
        }
    }

    init?(frame: CGRect, scene: SnowScene, maximumFPS: Int,
          shouldRender: @escaping (TimeInterval) -> Bool) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let batch = try? ParticleBatchRenderer(device: device, images: scene.particleTextureImages) else { return nil }
        self.scene = scene
        self.batch = batch
        simulation = CommandLine.arguments.contains("--cpu-particles") ? nil : try? SnowGPUParticleSimulation(device: device)
        self.renderer = SKRenderer(device: device)
        self.maximumFPS = max(1, maximumFPS)
        self.shouldRender = shouldRender
        super.init(frame: frame)
        wantsLayer = true
        guard let metalLayer = layer as? CAMetalLayer else { return nil }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        autoresizingMask = [.width, .height]

        // Finish every fallible operation before configuring the scene's permanent
        // particle sink, so an initialization failure can still use its fallback.
        scene.scaleMode = .aspectFit
        scene.isPaused = true
        scene.delegate = self
        scene.onParticles = { [weak self] particles in
            guard let self, !self.invalidated else { return }
            self.packet = particles
        }
        if simulation != nil {
            scene.onGPUParticles = { [weak self] frame in
                guard let self, !self.invalidated else { return }
                self.simulationFrame = frame
            }
        }
        renderer.scene = scene
        renderer.ignoresSiblingOrder = true
        renderer.shouldCullNonVisibleNodes = true
        updateDrawableGeometry()
    }

    required init?(coder: NSCoder) { fatalError("UnifiedSnowView is created programmatically") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { scene.playing && !paused && !invalidated }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard scene.playing, !paused, !invalidated else { return nil }
        // AppKit resolves HUD subviews before the uncovered game surface.
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !invalidated else { return }
        updateDrawableGeometry()
        if window != nil, displayLink == nil, let metalLayer = layer as? CAMetalLayer {
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self
            link.preferredFrameLatency = 1
            let native = Float(maximumFPS)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: native, maximum: native, preferred: native)
            link.isPaused = true
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
        updateDisplayLinkState()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableGeometry()
    }

    private func updateDrawableGeometry() {
        guard !invalidated, let metalLayer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded(.up)),
                                         height: max(1, (bounds.height * scale).rounded(.up)))
        scene.presentationScale = scale
        if scene.size != bounds.size { scene.size = bounds.size }
    }

    private func updateDisplayLinkState() {
        displayLink?.isPaused = paused || invalidated || failureLatched || window == nil
    }

    func resetPresentationClock() {
        lastPresentation = nil
        presentationGeneration &+= 1
        consecutiveFailedSubmissions = 0
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard !paused, !invalidated, !failureLatched, window != nil,
              bounds.width > 0, bounds.height > 0,
              shouldRender(update.targetPresentationTimestamp) else { return }

        // Release our reference before SnowScene mutates its reusable array.
        packet = []
        scene.update(update.targetPresentationTimestamp)
        renderer.update(atTime: update.targetPresentationTimestamp)
        guard !paused, !invalidated, !failureLatched else { packet = []; return }

        let drawable = update.drawable
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let viewport = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let generation = presentationGeneration
        let targetTime = update.targetPresentationTimestamp
        let presented: ((TimeInterval) -> Void)? = recordsPresentation || onFramePresented != nil ? { [weak self] time in
            guard let self, !self.invalidated, !self.paused,
                  self.presentationGeneration == generation, time > 0 else { return }
            if self.recordsPresentation {
                if let previous = self.lastPresentation, time > previous, self.presentationIntervals.count < 1_000_000 {
                    self.presentationIntervals.append(time - previous)
                }
                self.lastPresentation = time
            }
            self.onFramePresented?(targetTime, time)
        } : nil
        let reportStatistics = targetTime - lastStatisticsTime >= 0.5
        let statistics: ((SnowGPUParticleSimulation.Statistics) -> Void)? = reportStatistics ? { [weak self] value in
            guard let self, !self.invalidated, !self.paused, self.presentationGeneration == generation else { return }
            self.scene.recordGPUParticleCount(value.alive)
        } : nil
        let command = batch.render(packet, viewport: bounds.size, pass: pass, drawable: drawable,
            onPresented: presented, beforeParticles: { [weak self] command in
                guard let self else { return }
                self.renderer.render(withViewport: viewport, commandBuffer: command, renderPassDescriptor: pass)
                pass.colorAttachments[0].loadAction = .load
            }, presentDirectly: true, onFailure: { [weak self] message in
                self?.reportFailure(message)
            }, simulation: simulation, simulationFrame: simulationFrame, onStatistics: statistics)
        // ParticleBatchRenderer has synchronously copied all instance bytes.
        packet = []
        if command != nil {
            if reportStatistics { lastStatisticsTime = targetTime }
            submittedFrames += 1
            consecutiveFailedSubmissions = 0
        } else { recordFailedSubmission() }
    }

    // SKRenderer owns SpriteKit's native cycle. Our explicit call above is the
    // sole update of SnowScene's simulation; this delegate must remain passive.
    func update(_ currentTime: TimeInterval, for scene: SKScene) {}

    private func recordFailedSubmission() {
        guard window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor else {
            consecutiveFailedSubmissions = 0
            return
        }
        consecutiveFailedSubmissions += 1
        guard consecutiveFailedSubmissions >= 120 else { return }
        reportFailure("Не удалось подготовить кадр снега. Перезапустите приложение.")
    }

    private func reportFailure(_ message: String) {
        // Both the main-run-loop display link and ParticleBatchRenderer's GPU
        // completion callback deliver here on main, as required by AppKit.
        dispatchPrecondition(condition: .onQueue(.main))
        guard !invalidated, !failureLatched else { return }
        isPaused = true
        failureLatched = true
        packet = []
        updateDisplayLinkState()
        onFailure?(message)
    }

    override func mouseDown(with event: NSEvent) {
        guard scene.playing, !paused else { return }
        window?.makeFirstResponder(self)
        scene.pointerDown(at: convert(event.locationInWindow, from: nil), timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard scene.playing, !paused else { return }
        scene.pointerDragged(at: convert(event.locationInWindow, from: nil), timestamp: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard scene.playing, !paused else { return }
        scene.pointerUp(timestamp: event.timestamp)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        paused = true
        scene.isPaused = true
        scene.resetAnimationClock()
        displayLink?.isPaused = true
        displayLink?.delegate = nil
        displayLink?.invalidate()
        displayLink = nil
        renderer.scene = nil
        if scene.delegate === self { scene.delegate = nil }
        packet = []
        simulationFrame = nil
        onFailure = nil
        onFramePresented = nil
        // Do not mutate onParticles after the first update. Its weak sink is safe
        // to leave on the retiring scene and cannot retain this view.
    }

    deinit { invalidate() }
}
