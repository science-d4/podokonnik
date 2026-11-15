import AppKit
import MetalKit

@main
enum MetalParticleTests {
    static func main() throws {
        setbuf(stdout, nil)
        print("Metal particle GPU checks starting")
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("A Metal device is required") }
        func image(red: CGFloat, green: CGFloat, alpha: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                    bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: red, green: green, blue: 0, alpha: alpha)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return context.makeImage()!
        }
        let renderer = try ParticleBatchRenderer(device: device, images: [
            image(red: 1, green: 0, alpha: 0.5), image(red: 0, green: 1, alpha: 1)
        ])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let target = device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        func particle(_ x: Float, _ y: Float, _ alpha: Float, _ kind: Float, _ rotation: Float = 0) -> SnowParticleInstance {
            SnowParticleInstance(geometry: SIMD4(x, y, 12, rotation), appearance: SIMD4(alpha, kind, 0, 0))
        }
        let particles = [particle(16, 16, 1, 0), particle(48, 48, 0.5, 1),
                         particle(32, 32, 1, 0), particle(32, 32, 0.5, 1),
                         particle(48, 16, 1, 1, .pi / 4)]
        let command = renderer.render(particles, viewport: CGSize(width: 64, height: 64), pass: pass)!
        command.waitUntilCompleted()
        precondition(command.status == .completed, "Metal command must finish successfully")
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        func pixels() {
            bytes.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: 64 * 4,
                                from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            }
        }
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = ((63 - y) * 64 + x) * 4
            return (0..<4).map { Int(bytes[offset + $0]) } // BGRA; AppKit y-up
        }
        func near(_ actual: [Int], _ expected: [Int], _ label: String) {
            print("\(label): \(actual)")
            precondition(zip(actual, expected).allSatisfy { abs($0 - $1) <= 3 }, "\(label): \(actual) != \(expected)")
        }
        pixels()
        near(pixel(0, 0), [0, 0, 0, 0], "transparent background")
        near(pixel(16, 16), [0, 0, 128, 128], "first texture, premultiplied alpha, coordinates")
        near(pixel(48, 48), [0, 128, 0, 128], "second texture and opacity")
        near(pixel(32, 32), [0, 128, 64, 192], "source-over blending")
        precondition(pixel(55, 16)[3] > 100 && pixel(55, 23)[3] == 0, "rotation must turn the square into a diamond")
        let clear = renderer.render([], viewport: CGSize(width: 64, height: 64), pass: pass)!
        clear.waitUntilCompleted(); pixels()
        precondition(bytes.allSatisfy { $0 == 0 }, "empty frame must remove all previous particles")
        print("Metal particles: coordinates, textures, premultiplication, opacity, overlap, rotation and empty-frame clear passed")
    }
}
