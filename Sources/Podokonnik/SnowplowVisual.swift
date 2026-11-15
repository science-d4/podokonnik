import AppKit
import SpriteKit

/// Small toy-like loader. Shared vector textures keep a pass limited to transforms.
final class SnowplowVisual: SKNode {
    private let crop = SKCropNode()
    private let mask = SKShapeNode()
    private let vehicle = SKNode()
    private let rearWheel = SKSpriteNode(texture: SnowplowVisual.wheelTexture)
    private let frontWheel = SKSpriteNode(texture: SnowplowVisual.wheelTexture)
    private var previousBand = CGRect.null
    private var previousOccluders: [CGRect] = []

    override init() {
        super.init()
        mask.fillColor = .white; mask.strokeColor = .clear; mask.lineWidth = 0
        crop.maskNode = mask
        addChild(crop); crop.addChild(vehicle)
        let body = SKSpriteNode(texture: Self.bodyTexture)
        body.size = CGSize(width: 96, height: 62)
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        vehicle.addChild(body)
        rearWheel.size = CGSize(width: 26, height: 26)
        rearWheel.position = CGPoint(x: -22, y: 13)
        frontWheel.size = CGSize(width: 20, height: 20)
        frontWheel.position = CGPoint(x: 11, y: 10)
        vehicle.addChild(rearWheel); vehicle.addChild(frontWheel)
    }

    required init?(coder: NSCoder) { fatalError("SnowplowVisual is created programmatically") }

    func update(pass: SnowplowPass, displayFrame: CGRect, reducedMotion: Bool) {
        vehicle.position = CGPoint(x: pass.x - displayFrame.minX, y: pass.surface.top - displayFrame.minY)
        rearWheel.zRotation = reducedMotion ? 0 : -pass.travelled / 13
        frontWheel.zRotation = reducedMotion ? 0 : -pass.travelled / 10
        let worldBand = CGRect(x: pass.surface.frame.minX, y: pass.surface.top,
                               width: pass.surface.frame.width, height: 64).intersection(displayFrame)
        let band = worldBand.isNull ? .zero : worldBand.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        let occluders = pass.surface.occluders.filter { $0.intersects(worldBand) }
            .map { $0.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY) }
        isHidden = !pass.surface.isVisible || worldBand.isNull
        guard band != previousBand || occluders != previousOccluders else { return }
        previousBand = band; previousOccluders = occluders
        let path = CGMutablePath()
        for rect in RendererGeometry.visibleRectangles(in: band, subtracting: occluders) { path.addRect(rect) }
        mask.path = path
    }

    private static func texture(width: Int, height: Int, draw: (CGContext) -> Void) -> SKTexture {
        let context = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        draw(context)
        let texture = SKTexture(cgImage: context.makeImage()!)
        texture.filteringMode = .linear
        return texture
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }

    private static func gradient(_ c: CGContext, path: CGPath, top: UInt32, bottom: UInt32) {
        let bounds = path.boundingBoxOfPath
        let colors = [color(top), color(bottom)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        c.saveGState(); c.addPath(path); c.clip()
        c.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY),
                             end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
        c.restoreGState()
    }

    private static let bodyTexture = texture(width: 96, height: 62) { c in
        func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
            CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        func fill(_ path: CGPath, _ rgb: UInt32, alpha: CGFloat = 1) {
            c.setFillColor(color(rgb, alpha: alpha)); c.addPath(path); c.fillPath()
        }
        func stroke(_ path: CGPath, _ rgb: UInt32, width: CGFloat, alpha: CGFloat = 1) {
            c.setStrokeColor(color(rgb, alpha: alpha)); c.setLineWidth(width)
            c.setLineCap(.round); c.setLineJoin(.round); c.addPath(path); c.strokePath()
        }
        func line(_ from: CGPoint, _ to: CGPoint, _ rgb: UInt32, width: CGFloat, alpha: CGFloat = 1) {
            let path = CGMutablePath(); path.move(to: from); path.addLine(to: to)
            stroke(path, rgb, width: width, alpha: alpha)
        }
        c.translateBy(x: 48, y: 0)
        c.clip(to: CGRect(x: -48, y: 0, width: 85, height: 62)) // Cutting edge ends at x + 37.

        // A soft contact shadow and rounded chassis anchor the toy at floor level.
        fill(CGPath(ellipseIn: CGRect(x: -36, y: 0.4, width: 70, height: 3.4), transform: nil), 0x243C48, alpha: 0.17)
        let chassis = rounded(CGRect(x: -35, y: 11, width: 55, height: 12), 5)
        gradient(c, path: chassis, top: 0x5B6B70, bottom: 0x2B3E48)

        let body = CGMutablePath()
        body.move(to: CGPoint(x: -35, y: 18))
        body.addCurve(to: CGPoint(x: -35, y: 29), control1: CGPoint(x: -38, y: 20), control2: CGPoint(x: -37, y: 27))
        body.addQuadCurve(to: CGPoint(x: -28, y: 34), control: CGPoint(x: -34, y: 34))
        body.addLine(to: CGPoint(x: -4, y: 34))
        body.addCurve(to: CGPoint(x: 17, y: 31), control1: CGPoint(x: 3, y: 34), control2: CGPoint(x: 14, y: 34))
        body.addQuadCurve(to: CGPoint(x: 21, y: 23), control: CGPoint(x: 21, y: 29))
        body.addQuadCurve(to: CGPoint(x: 15, y: 18), control: CGPoint(x: 21, y: 18))
        body.closeSubpath()
        gradient(c, path: body, top: 0xFFDF78, bottom: 0xEDA32C)
        stroke(body, 0xB87920, width: 0.8, alpha: 0.7)
        line(CGPoint(x: -30, y: 31.5), CGPoint(x: 9, y: 31.5), 0xFFF2BE, width: 1.6, alpha: 0.8)

        // The bowed roof and sloping windscreen replace the old rectangular cab.
        let cab = CGMutablePath()
        cab.move(to: CGPoint(x: -32, y: 29))
        cab.addLine(to: CGPoint(x: -32, y: 47))
        cab.addQuadCurve(to: CGPoint(x: -26, y: 54), control: CGPoint(x: -32, y: 54))
        cab.addLine(to: CGPoint(x: -12, y: 54))
        cab.addQuadCurve(to: CGPoint(x: -7, y: 49), control: CGPoint(x: -8, y: 54))
        cab.addLine(to: CGPoint(x: -2, y: 31))
        cab.addQuadCurve(to: CGPoint(x: -5, y: 28), control: CGPoint(x: -1, y: 28))
        cab.closeSubpath()
        gradient(c, path: cab, top: 0xFFE799, bottom: 0xF4B63E)
        stroke(cab, 0xBD8B35, width: 0.8, alpha: 0.65)

        let glass = CGMutablePath()
        glass.move(to: CGPoint(x: -27.5, y: 33))
        glass.addLine(to: CGPoint(x: -27.5, y: 46.5))
        glass.addQuadCurve(to: CGPoint(x: -24, y: 50), control: CGPoint(x: -27.5, y: 50))
        glass.addLine(to: CGPoint(x: -14, y: 50))
        glass.addQuadCurve(to: CGPoint(x: -11, y: 47), control: CGPoint(x: -12, y: 50))
        glass.addLine(to: CGPoint(x: -7, y: 34))
        glass.addQuadCurve(to: CGPoint(x: -9, y: 32), control: CGPoint(x: -6.5, y: 32))
        glass.closeSubpath()
        gradient(c, path: glass, top: 0xC8EBE8, bottom: 0x63A5B1)
        stroke(glass, 0x527C82, width: 0.9, alpha: 0.85)
        c.saveGState(); c.addPath(glass); c.clip()
        line(CGPoint(x: -25, y: 49), CGPoint(x: -16, y: 33), 0xFFFFFF, width: 3.2, alpha: 0.36)
        line(CGPoint(x: -21, y: 50), CGPoint(x: -12, y: 34), 0xFFFFFF, width: 1, alpha: 0.3)
        fill(rounded(CGRect(x: -24, y: 32, width: 7, height: 4), 1.8), 0x376978, alpha: 0.45)
        c.restoreGState()
        line(CGPoint(x: -14, y: 49), CGPoint(x: -12, y: 33), 0xF7CF6D, width: 1.5)
        line(CGPoint(x: -29, y: 29), CGPoint(x: -7, y: 29), 0xC49032, width: 1)
        fill(rounded(CGRect(x: -28, y: 27, width: 4, height: 1.5), 0.7), 0x8D703E)

        let roof = rounded(CGRect(x: -34.5, y: 51, width: 32, height: 5.5), 2.7)
        gradient(c, path: roof, top: 0xFFF0BA, bottom: 0xE5AD41)
        line(CGPoint(x: -31, y: 55), CGPoint(x: -7, y: 55), 0xFFF9DF, width: 1.3, alpha: 0.9)
        fill(rounded(CGRect(x: -23.5, y: 56.3, width: 8, height: 1.8), 0.8), 0xB08744)
        let beacon = rounded(CGRect(x: -22.5, y: 57.5, width: 6, height: 3.5), 1.7)
        gradient(c, path: beacon, top: 0xFFDF87, bottom: 0xEDA342)
        fill(rounded(CGRect(x: -21.5, y: 59.5, width: 3, height: 0.8), 0.4), 0xFFF8DA, alpha: 0.8)

        // Small mechanical details stay legible without turning into a face.
        for x in [CGFloat(7), CGFloat(10), CGFloat(13)] {
            line(CGPoint(x: x, y: 24), CGPoint(x: x, y: 28), 0xB4812E, width: 1.1, alpha: 0.75)
        }
        fill(rounded(CGRect(x: 17.5, y: 25, width: 3.5, height: 4.5), 1.6), 0xFFF6D5)
        let fender = CGMutablePath()
        fender.move(to: CGPoint(x: -36, y: 18))
        fender.addCurve(to: CGPoint(x: -7, y: 18), control1: CGPoint(x: -34, y: 31), control2: CGPoint(x: -11, y: 32))
        stroke(fender, 0xC88927, width: 5.5)
        stroke(fender, 0xFFDC77, width: 3.6)

        // A chunky lower arm and slim steel piston connect the curved scoop.
        line(CGPoint(x: -1, y: 22), CGPoint(x: 26, y: 10), 0xB67A25, width: 6.6)
        line(CGPoint(x: -1, y: 23), CGPoint(x: 26, y: 11), 0xF7C457, width: 4.4)
        line(CGPoint(x: 2, y: 28), CGPoint(x: 23, y: 18), 0x5D7780, width: 3.4)
        line(CGPoint(x: 3, y: 28.5), CGPoint(x: 23, y: 19), 0xD5E5E4, width: 1.6)
        fill(CGPath(ellipseIn: CGRect(x: -4, y: 19.5, width: 6, height: 6), transform: nil), 0xC78F35)
        fill(CGPath(ellipseIn: CGRect(x: -2.2, y: 21.3, width: 2.4, height: 2.4), transform: nil), 0xEEF0D5)

        let bucket = CGMutablePath()
        bucket.move(to: CGPoint(x: 22, y: 26))
        bucket.addCurve(to: CGPoint(x: 28, y: 14), control1: CGPoint(x: 30, y: 28), control2: CGPoint(x: 27, y: 21))
        bucket.addCurve(to: CGPoint(x: 37, y: 3), control1: CGPoint(x: 29, y: 8), control2: CGPoint(x: 31, y: 5))
        bucket.addLine(to: CGPoint(x: 37, y: 0.7))
        bucket.addLine(to: CGPoint(x: 26, y: 1.5))
        bucket.addCurve(to: CGPoint(x: 18, y: 14), control1: CGPoint(x: 20, y: 3), control2: CGPoint(x: 18, y: 7))
        bucket.addLine(to: CGPoint(x: 19, y: 22))
        bucket.addQuadCurve(to: CGPoint(x: 22, y: 26), control: CGPoint(x: 19, y: 25))
        bucket.closeSubpath()
        gradient(c, path: bucket, top: 0xFFE896, bottom: 0xDE9C37)
        stroke(bucket, 0xAB7B34, width: 0.7, alpha: 0.8)
        let bucketHighlight = CGMutablePath()
        bucketHighlight.move(to: CGPoint(x: 22, y: 23))
        bucketHighlight.addCurve(to: CGPoint(x: 33, y: 3.6), control1: CGPoint(x: 20, y: 10), control2: CGPoint(x: 25, y: 5))
        stroke(bucketHighlight, 0xFFF4CA, width: 2.1, alpha: 0.8)
        let cuttingEdge = CGMutablePath()
        cuttingEdge.move(to: CGPoint(x: 23, y: 3.4)); cuttingEdge.addLine(to: CGPoint(x: 37, y: 1.9))
        cuttingEdge.addLine(to: CGPoint(x: 37, y: 0.2)); cuttingEdge.addLine(to: CGPoint(x: 25, y: 0.9))
        cuttingEdge.closeSubpath()
        gradient(c, path: cuttingEdge, top: 0xCEDDDD, bottom: 0x607782)
    }

    private static let wheelTexture = texture(width: 28, height: 28) { c in
        let tire = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 27, height: 27), transform: nil)
        gradient(c, path: tire, top: 0x53646C, bottom: 0x233944)
        c.setStrokeColor(color(0x263B44)); c.setLineWidth(0.7); c.addPath(tire); c.strokePath()
        c.setLineCap(.round)
        for index in 0..<10 {
            let angle = CGFloat(index) * .pi / 5
            c.setStrokeColor(color(0x859396, alpha: 0.52)); c.setLineWidth(1.2)
            c.move(to: CGPoint(x: 14 + cos(angle) * 10.7, y: 14 + sin(angle) * 10.7))
            c.addLine(to: CGPoint(x: 14 + cos(angle + 0.05) * 12.1, y: 14 + sin(angle + 0.05) * 12.1)); c.strokePath()
        }
        let rim = CGPath(ellipseIn: CGRect(x: 6.8, y: 6.8, width: 14.4, height: 14.4), transform: nil)
        gradient(c, path: rim, top: 0xE7E8CF, bottom: 0xA5B2AC)
        c.setStrokeColor(color(0x71858A)); c.setLineWidth(0.8); c.addPath(rim); c.strokePath()
        let hub = CGPath(ellipseIn: CGRect(x: 8.4, y: 8.4, width: 11.2, height: 11.2), transform: nil)
        gradient(c, path: hub, top: 0xFFE8A0, bottom: 0xDCAA4D)
        for index in 0..<5 {
            let angle = CGFloat(index) * .pi * 2 / 5
            c.setStrokeColor(color(0xBD903D, alpha: 0.7)); c.setLineWidth(1)
            c.move(to: CGPoint(x: 14 + cos(angle) * 2.6, y: 14 + sin(angle) * 2.6))
            c.addLine(to: CGPoint(x: 14 + cos(angle) * 4.5, y: 14 + sin(angle) * 4.5)); c.strokePath()
        }
        let axle = CGPath(ellipseIn: CGRect(x: 11.9, y: 11.9, width: 4.2, height: 4.2), transform: nil)
        gradient(c, path: axle, top: 0xE1E9E6, bottom: 0x758C91)
        c.setFillColor(color(0xFFFFFF, alpha: 0.65))
        c.fillEllipse(in: CGRect(x: 12.8, y: 14, width: 1.5, height: 1.1))
    }
}
