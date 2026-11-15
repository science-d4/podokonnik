import AppKit
import SpriteKit

/// The shared model owns time and pose. Each display draws the same pose in local points.
final class DuckLayer: SKNode {
    private let actor = SKNode()
    private let body = SKShapeNode(ellipseOf: CGSize(width: 23, height: 15))
    private let wing = SKShapeNode(ellipseOf: CGSize(width: 13, height: 8))
    private let farFlightWing = SKShapeNode(path: DuckLayer.flightWingPath)
    private let nearFlightWing = SKShapeNode(path: DuckLayer.flightWingPath)
    private let head = SKNode()
    private let cheek = SKShapeNode(circleOfRadius: 6.4)
    private let eye = SKShapeNode(circleOfRadius: 1.15)
    private let bill = SKShapeNode(ellipseOf: CGSize(width: 7, height: 4))
    private let feet = (0..<2).map { _ in SKShapeNode(ellipseOf: CGSize(width: 6, height: 2.6)) }
    private var tracks: [SKSpriteNode] = []
    private var flakes: [SKSpriteNode] = []

    override init() {
        super.init()
        name = "duck-layer"
        zPosition = 11
        let cream = NSColor(red: 1, green: 0.94, blue: 0.79, alpha: 1)
        let edge = NSColor(red: 0.57, green: 0.42, blue: 0.32, alpha: 0.82)
        let orange = NSColor(red: 0.95, green: 0.53, blue: 0.20, alpha: 1)
        for node in [body, cheek, wing, eye, bill, farFlightWing, nearFlightWing] + feet {
            node.isAntialiased = true
            node.strokeColor = edge
            node.lineWidth = 0.65
        }
        body.fillColor = cream
        body.name = "duck-body"
        wing.name = "duck-wing"
        head.name = "duck-head"
        cheek.fillColor = cream
        wing.fillColor = NSColor(red: 0.95, green: 0.83, blue: 0.65, alpha: 1)
        farFlightWing.fillColor = NSColor(red: 0.83, green: 0.68, blue: 0.51, alpha: 1)
        nearFlightWing.fillColor = NSColor(red: 1, green: 0.90, blue: 0.72, alpha: 1)
        farFlightWing.zPosition = -0.2
        nearFlightWing.zPosition = 0.2
        farFlightWing.name = "duck-far-flight-wing"
        nearFlightWing.name = "duck-near-flight-wing"
        farFlightWing.isHidden = true
        nearFlightWing.isHidden = true
        bill.fillColor = orange
        eye.fillColor = NSColor(red: 0.20, green: 0.14, blue: 0.13, alpha: 1)
        eye.strokeColor = .clear
        for foot in feet { foot.fillColor = orange; foot.name = "duck-foot"; actor.addChild(foot) }
        actor.addChild(farFlightWing); actor.addChild(nearFlightWing)
        actor.addChild(body)
        body.addChild(wing)
        actor.addChild(head)
        head.addChild(bill); head.addChild(cheek); head.addChild(eye)
        cheek.position = CGPoint(x: -0.7, y: 0)
        bill.position = CGPoint(x: 5.4, y: -2)
        eye.position = CGPoint(x: 1.3, y: 1.5)
        actor.zPosition = 240
        actor.name = "duck"
        addChild(actor)
    }

    required init?(coder: NSCoder) { fatalError("DuckLayer is created programmatically") }

    private static let flightWingPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 2))
        path.addQuadCurve(to: CGPoint(x: -11, y: 7), control: CGPoint(x: -5, y: 8))
        path.addQuadCurve(to: CGPoint(x: -21, y: 2), control: CGPoint(x: -17, y: 6))
        path.addQuadCurve(to: CGPoint(x: -15, y: 0), control: CGPoint(x: -21, y: 0))
        path.addQuadCurve(to: CGPoint(x: -10, y: -2), control: CGPoint(x: -15, y: -2))
        path.addQuadCurve(to: CGPoint(x: 2, y: -2), control: CGPoint(x: -4, y: -5))
        path.closeSubpath()
        return path
    }()

    func update(_ duck: DuckWorld, in display: CGRect, snow: SnowWorld,
                visibleHeight: (DuckAnchor) -> CGFloat) {
        actor.isHidden = true
        if let pose = duck.pose {
            let feet: CGPoint? = pose.anchor.flatMap {
                let anchor = $0
                return duck.groundPoint(anchor, snow: snow) { visibleHeight(anchor) }
            } ?? (pose.anchor == nil ? pose.feet : nil)
            if let feet {
                let bounds = DuckPose.bounds(at: feet, flying: pose.activity == .fly)
                if bounds.intersects(display),
                   pose.anchor.map({ duck.isGroundPoseVisible(at: feet, on: $0, snow: snow) }) ?? duck.isFlightVisible(at: feet) {
                    actor.position = local(feet, display: display)
                    actor.isHidden = false
                    animate(pose)
                }
            }
        }
        draw(duck.prints, nodes: &tracks, texture: Self.printTexture, size: CGSize(width: 5, height: 3),
             in: display, snow: snow, duck: duck, visibleHeight: visibleHeight, isDust: false)
        draw(duck.dust, nodes: &flakes, texture: Self.dustTexture, size: CGSize(width: 3, height: 3),
             in: display, snow: snow, duck: duck, visibleHeight: visibleHeight, isDust: true)
    }

    private func animate(_ pose: DuckPose) {
        let wave = CGFloat(sin(pose.time * 12))
        let slow = CGFloat(sin(pose.time * 4))
        let walking = pose.activity == .walk
        let flying = pose.activity == .fly
        let stroke = flying ? DuckWingbeat(time: pose.time).elevation : 0
        let sitting = pose.activity == .rest || pose.activity == .restByTree
        actor.xScale = pose.facing * DuckPose.scale
        actor.yScale = DuckPose.scale
        actor.zRotation = flying ? pose.facing * pose.flightTilt : 0
        body.position = CGPoint(x: -2, y: sitting ? 7.5 : flying ? 13 - stroke * 0.6 : 10 + (walking ? abs(wave) : 0))
        body.zRotation = walking ? wave * 0.07 : 0
        head.position = CGPoint(x: flying ? 8 : 6.5, y: sitting ? 12.5 : flying ? 19.5 - stroke * 0.3 : 19.5)
        head.zRotation = 0
        wing.position = CGPoint(x: -1, y: 0)
        wing.zRotation = -0.15
        wing.setScale(1)
        wing.isHidden = flying
        farFlightWing.isHidden = !flying
        nearFlightWing.isHidden = !flying
        if flying {
            for (index, wing) in [farFlightWing, nearFlightWing].enumerated() {
                let far = index == 0
                wing.position = CGPoint(x: far ? -1 : -3, y: body.position.y + (far ? 2 : 0))
                wing.zRotation = -stroke * (far ? 0.92 : 0.87) + (far ? -0.18 : 0.05)
                wing.xScale = (far ? 0.81 : 0.98) - 0.18 * max(0, -stroke)
                wing.yScale = (far ? 0.84 : 1) - 0.47 * (1 - abs(stroke))
            }
        }
        eye.yScale = sitting && pose.time > 0.7 && slow < 0.85 ? 0.25 : 1
        for (i, foot) in feet.enumerated() {
            let phase = i == 0 ? wave : -wave
            let tuck = flying ? 1 - pose.feetExtended : 0
            foot.position = CGPoint(x: CGFloat(i * 5 - 3) + (walking ? phase * 3.4 : -tuck * 7),
                                    y: 1.45 + (walking ? max(0, phase) * 3 : tuck * 8))
            foot.zRotation = tuck * -0.33
            foot.isHidden = sitting
        }
        switch pose.activity {
        case .look:
            head.zRotation = slow * 0.2
        case .peck:
            let beat = pose.time < 1.1 ? max(0, CGFloat(sin(pose.time * 18.5))) : 0
            head.position.y -= 12 * beat
            head.position.x += 2 * beat
            head.zRotation = -beat * 0.8
        case .preen:
            head.position = CGPoint(x: 1 + slow, y: 14)
            head.zRotation = -0.8 + slow * 0.22
            wing.zRotation = 0.26 + slow * 0.12
        case .stretch:
            let extensionAmount = max(0, CGFloat(sin(min(pose.time / 2.3, 1) * .pi)))
            head.position.y += 3 * extensionAmount
            head.position.x += 2 * extensionAmount
            wing.zRotation = 0.9 * extensionAmount - 0.15
            wing.xScale = 1 + 0.4 * extensionAmount
        case .shake:
            let shake = CGFloat(sin(pose.time * 25)) * max(0, 1 - CGFloat(pose.time) / 2)
            body.zRotation = shake * 0.18
            head.zRotation = -shake * 0.2
            wing.zRotation = -0.15 + shake * 0.55
        case .listen:
            head.position.y -= 1.5
            head.zRotation = 0.42 * CGFloat(sin(pose.time * 2.1))
        case .watch:
            head.zRotation = -0.36 + slow * 0.12
        case .greet:
            head.position.y += 2 + max(0, slow) * 2
            head.zRotation = 0.24 + slow * 0.42
            bill.yScale = 1 + max(0, slow) * 0.55
            wing.zRotation = -0.15 + max(0, slow) * 0.62
        case .guardSnowman:
            head.position.y += min(3, CGFloat(pose.time) * 4)
            body.zRotation = 0.1
        case .bowSnowman:
            let bow = max(0, CGFloat(sin(pose.time * 3)))
            head.position.y -= 5 * bow
            head.zRotation = -0.65 * bow
        case .inspectTree:
            head.position.x += 2 + max(0, slow) * 2
            head.position.y -= max(0, slow) * 7
            head.zRotation = slow * 0.49
        case .restByTree:
            wing.zRotation = pose.time < 0.9 ? wave * 0.4 : -0.15
        case .inspectLights:
            head.position.y += 3 + 2 * slow
            head.position.x += 2
            head.zRotation = 0.35 + slow * 0.2
        case .startled:
            head.position.y += 2
            wing.zRotation = 0.4
            wing.setScale(1.23)
        case .walk, .rest, .fly:
            break
        }
        if pose.activity != .greet { bill.yScale = 1 }
    }

    private func draw(_ effects: [DuckEffect], nodes: inout [SKSpriteNode], texture: @autoclosure () -> SKTexture,
                      size: CGSize, in display: CGRect, snow: SnowWorld, duck: DuckWorld,
                      visibleHeight: (DuckAnchor) -> CGFloat, isDust: Bool) {
        if nodes.count < effects.count {
            let image = texture()
            for _ in nodes.count..<effects.count {
                let sprite = SKSpriteNode(texture: image, size: size)
                sprite.name = isDust ? "duck-dust" : "duck-track"
                nodes.append(sprite)
                addChild(sprite)
            }
        }
        for (index, node) in nodes.enumerated() {
            node.isHidden = true
            guard index < effects.count else { continue }
            let effect = effects[index]
            guard var p = point(effect.anchor, snow: snow, visibleHeight: visibleHeight),
                  let drift = snow.drifts[effect.anchor.surfaceID],
                  isDust || (visibleHeight(effect.anchor) > 0.6
                             && drift.visibleContour.height(at: effect.anchor.localX) > 0.6) else { continue }
            if isDust {
                p.x += (effect.facing * 10 + effect.foot * 11) * effect.age
                p.y += 1 + max(0, 25 * effect.age - 31 * effect.age * effect.age)
            } else {
                p.y -= min(1.4 + effect.foot * 0.65, visibleHeight(effect.anchor) / 2)
            }
            let rect = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                              width: size.width, height: size.height)
            guard rect.intersects(display), duck.isVisible(rect, on: effect.anchor.surfaceID) else { continue }
            node.position = local(p, display: display)
            node.alpha = effect.opacity * (isDust ? 0.85 : 0.68)
            node.isHidden = false
        }
    }

    private func point(_ anchor: DuckAnchor, snow: SnowWorld, visibleHeight: (DuckAnchor) -> CGFloat) -> CGPoint? {
        guard let surface = snow.drifts[anchor.surfaceID]?.surface, surface.isVisible else { return nil }
        let x = surface.frame.minX + anchor.localX
        guard surface.supports(x: x) else { return nil }
        return CGPoint(x: x, y: surface.top + visibleHeight(anchor))
    }

    private func local(_ point: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: point.x - display.minX, y: point.y - display.minY)
    }

    private static let printTexture = effectTexture { context in
        context.setFillColor(CGColor(red: 0.30, green: 0.42, blue: 0.55, alpha: 0.82))
        context.fillEllipse(in: CGRect(x: 2, y: 4, width: 6, height: 8))
        for y in [1.0, 5.5, 10.0] {
            context.fillEllipse(in: CGRect(x: 6, y: y, width: 8, height: 4))
        }
    }

    private static let dustTexture = effectTexture { context in
        context.setFillColor(CGColor(red: 0.87, green: 0.94, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
    }

    private static func effectTexture(_ draw: (CGContext) -> Void) -> SKTexture {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return SKTexture(cgImage: context.makeImage()!)
    }
}
