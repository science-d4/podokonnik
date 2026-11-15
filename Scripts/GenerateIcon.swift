import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let rect = CGRect(x: 44, y: 44, width: 936, height: 936)
    let path = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.16, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.28, green: 0.49, blue: 0.76, alpha: 1)])!
    gradient.draw(in: path, angle: 70)
    path.addClip()
    NSColor.white.withAlphaComponent(0.65).setFill()
    for i in 0..<50 {
        let x = CGFloat((i*167+79)%960+32), y = CGFloat((i*251+93)%960+32)
        let r = CGFloat(i%3+2)
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: r*2, height: r*2)).fill()
    }
    NSColor(srgbRed: 0.84, green: 0.92, blue: 1, alpha: 1).setFill()
    let drift = NSBezierPath(); drift.move(to: CGPoint(x: 0, y: 0)); drift.line(to: CGPoint(x: 0, y: 240))
    drift.curve(to: CGPoint(x: 1024, y: 180), controlPoint1: CGPoint(x: 340, y: 340), controlPoint2: CGPoint(x: 590, y: 100))
    drift.line(to: CGPoint(x: 1024, y: 0)); drift.close(); drift.fill()
    let snow = NSBezierPath(); snow.move(to: CGPoint(x: 0, y: 0)); snow.line(to: CGPoint(x: 0, y: 210))
    snow.curve(to: CGPoint(x: 1024, y: 220), controlPoint1: CGPoint(x: 350, y: 180), controlPoint2: CGPoint(x: 680, y: 320))
    snow.line(to: CGPoint(x: 1024, y: 0)); snow.close(); NSColor.white.setFill(); snow.fill()
    let flake = NSBezierPath(); flake.lineWidth = 26; flake.lineCapStyle = .round; flake.lineJoinStyle = .round
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi/3
        let ux = cos(angle), uy = sin(angle), vx = -uy, vy = ux
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: 512+ux*a+vx*b, y: 560+uy*a+vy*b) }
        flake.move(to: p(0,0)); flake.line(to: p(235,0))
        for d: CGFloat in [110, 178] {
            flake.move(to: p(d+48, -48)); flake.line(to: p(d,0)); flake.line(to: p(d+48,48))
        }
    }
    NSColor.white.setStroke(); flake.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16,32,128,256,512] {
    try render(size: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size*2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
