// Paired offscreen GPU comparison of this application's own particles only.
// No screen capture, foreign windows, accessibility access or input synthesis.
// swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/snezhno-renderer-module-cache \
//   Sources/SnowCore/SnowTypes.swift Sources/SnowCore/SnowWorld.swift Sources/Podokonnik/SnowScene.swift \
//   Sources/Podokonnik/MetalParticleView.swift Tests/MetalParticleComparisonTests.swift \
//   -o /private/tmp/snezhno-metal-comparison
// Run: /private/tmp/snezhno-metal-comparison <output-directory>
import AppKit
import SpriteKit
import MetalKit

@main
enum MetalParticleComparisonTests {
    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/snezhno-metal-comparison", isDirectory: true)
        do { try run(in: directory) }
        catch {
            fputs("Paired particle GPU comparison failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let world = SnowWorld(seed: 14)
        let fallback = SnowScene(world: world, displayFrame: frame)
        let scalar = SnowScene(world: world, displayFrame: frame)
        var packet: [SnowParticleInstance] = []
        scalar.onParticles = { packet = $0 }
        let weather = SnowWeather(intensity: .steady, wind: CGVector(dx: 0.42, dy: 0.12))
        fallback.weather = weather
        scalar.weather = weather
        let view = SKView(frame: frame)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        view.presentScene(fallback)
        view.isPaused = true
        defer { view.presentScene(nil); window.close() }
        for tick in 0...900 {
            fallback.update(Double(tick) / 60)
            scalar.update(Double(tick) / 60)
        }
        let sprites = fallback.children.flatMap(\.children).compactMap { $0 as? SKSpriteNode }
        let actual = packet.sorted(by: ordered)
        let expected = sprites.map {
            SnowParticleInstance(geometry: SIMD4(Float($0.position.x), Float($0.position.y), Float($0.size.width), Float($0.zRotation)),
                                 appearance: SIMD4(Float($0.alpha), $0.name == "snowflake.crystal" ? 1 : 0, 0, 0))
        }.sorted(by: ordered)
        guard actual.count == expected.count, zip(actual, expected).allSatisfy({ $0.geometry == $1.geometry && $0.appearance == $1.appearance }),
              scalar.children.flatMap(\.children).allSatisfy({ !($0 is SKSpriteNode) }) else {
            throw failure("particle geometry, texture kind, alpha, node count or density differs before rendering")
        }
        let visible = packet.filter {
            $0.geometry.x >= 0 && $0.geometry.x < Float(frame.width) && $0.geometry.y >= 0 && $0.geometry.y < Float(frame.height)
        }
        guard visible.count >= 20, visible.count <= 220,
              visible.contains(where: { $0.appearance.y == 1 }), visible.contains(where: { $0.appearance.y == 0 }) else {
            throw failure("fixture must contain a visible mix of round particles and crystals")
        }
        let spriteURL = directory.appendingPathComponent("spritekit.png")
        guard fallback.exportPreview(to: spriteURL),
              let spriteBitmap = NSBitmapImageRep(data: try Data(contentsOf: spriteURL)), let spriteImage = spriteBitmap.cgImage,
              let device = MTLCreateSystemDefaultDevice() else { throw failure("SpriteKit export or Metal device unavailable") }
        let width = spriteImage.width, height = spriteImage.height
        let renderer = try ParticleBatchRenderer(device: device, images: scalar.particleTextureImages)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw failure("offscreen target allocation failed") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let command = renderer.render(packet, viewport: frame.size, pass: pass) else { throw failure("Metal encoding failed") }
        command.waitUntilCompleted()
        guard command.status == .completed else { throw failure("Metal command did not complete: \(String(describing: command.error))") }
        var metalBGRA = [UInt8](repeating: 0, count: width * height * 4)
        metalBGRA.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(metalBGRA) as CFData),
              let metalImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: metalImage).representation(using: .png, properties: [:]) else { throw failure("Metal PNG conversion failed") }
        try png.write(to: directory.appendingPathComponent("metal.png"), options: .atomic)
        // A dark, unscaled side-by-side view is for human inspection only; all
        // comparisons below use the original transparent premultiplied images.
        if let comparison = CGContext(data: nil, width: width * 2 + 1, height: height, bitsPerComponent: 8,
                                      bytesPerRow: (width * 2 + 1) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            comparison.setFillColor(CGColor(red: 0.035, green: 0.07, blue: 0.13, alpha: 1))
            comparison.fill(CGRect(x: 0, y: 0, width: width * 2 + 1, height: height))
            comparison.draw(spriteImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            comparison.draw(metalImage, in: CGRect(x: width + 1, y: 0, width: width, height: height))
            if let cgImage = comparison.makeImage(), let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                try data.write(to: directory.appendingPathComponent("comparison-left-spritekit-right-metal.png"), options: .atomic)
            }
        }
        let sprite = try rgba(spriteImage)
        let metal = try rgba(metalImage)
        var spriteAlpha = 0, metalAlpha = 0, alphaDifference = 0, rgbDifference = 0, rgbTotal = 0
        var activePixels = 0, maximumAlphaDifference = 0, spriteCoverage = 0, metalCoverage = 0
        for pixel in 0..<(width * height) {
            let index = pixel * 4
            let sa = Int(sprite[index + 3]), ma = Int(metal[index + 3])
            spriteAlpha += sa
            metalAlpha += ma
            alphaDifference += abs(sa - ma)
            maximumAlphaDifference = max(maximumAlphaDifference, abs(sa - ma))
            if sa > 2 || ma > 2 { activePixels += 1 }
            if sa > 12 { spriteCoverage += 1 }
            if ma > 12 { metalCoverage += 1 }
            for channel in 0..<3 {
                let s = Int(sprite[index + channel]), m = Int(metal[index + channel])
                rgbDifference += abs(s - m)
                rgbTotal += s + m
            }
        }
        let alphaRelativeL1 = 2 * Double(alphaDifference) / Double(max(1, spriteAlpha + metalAlpha))
        let rgbRelativeL1 = 2 * Double(rgbDifference) / Double(max(1, rgbTotal))
        let alphaMassRatio = Double(metalAlpha) / Double(max(1, spriteAlpha))
        let coverageRatio = Double(metalCoverage) / Double(max(1, spriteCoverage))
        let activePixelMAE = Double(alphaDifference) / Double(max(1, activePixels) * 255)
        // Normalize by snow mass rather than the mostly transparent frame. These
        // tolerances allow GPU edge sampling differences, not shifted/missing flakes,
        // a second alpha multiplication, a different density or blurred textures.
        let passed = alphaRelativeL1 <= 0.12 && rgbRelativeL1 <= 0.12
            && (0.94...1.06).contains(alphaMassRatio) && (0.90...1.10).contains(coverageRatio)
            && activePixelMAE <= 0.04 && maximumAlphaDifference <= 64
        let report: [String: Any] = ["passed": passed, "width": width, "height": height,
                                     "particleCount": packet.count, "visibleParticleCount": visible.count,
                                     "visibleCrystals": visible.filter { $0.appearance.y == 1 }.count,
                                     "geometryExactlyEqual": true, "scalarParticleNodes": 0,
                                     "spriteAlphaSum": spriteAlpha, "metalAlphaSum": metalAlpha,
                                     "alphaRelativeL1": alphaRelativeL1, "rgbRelativeL1": rgbRelativeL1,
                                     "alphaMassRatio": alphaMassRatio, "coverageRatio": coverageRatio,
                                     "activePixelAlphaMAE": activePixelMAE, "maximumAlphaDifference8Bit": maximumAlphaDifference,
                                     "spriteCoveragePixels": spriteCoverage, "metalCoveragePixels": metalCoverage,
                                     "scope": "same simulated particles; own offscreen GPU images; not live FPS/CPU evidence"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        print("Paired particle GPU comparison: \(report)")
        guard passed else { throw failure("image disagreement exceeds the fixed AA tolerances; inspect both PNG files") }
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else {
            throw failure("RGBA normalization failed")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private static func ordered(_ left: SnowParticleInstance, _ right: SnowParticleInstance) -> Bool {
        if left.geometry.x != right.geometry.x { return left.geometry.x < right.geometry.x }
        if left.geometry.y != right.geometry.y { return left.geometry.y < right.geometry.y }
        return left.geometry.w < right.geometry.w
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "Snezhno.MetalComparison", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
