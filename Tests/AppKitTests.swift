import AppKit

@main
enum AppKitTests {
    static func main() {
        _ = NSApplication.shared
        let window = OverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = ActionButton("Закончить") {}
        window.contentView?.addSubview(button)
        var exits = 0
        window.onEscape = { exits += 1 }
        window.receivesGameInput = true
        window.makeFirstResponder(button)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(event)
        precondition(exits == 1, "Escape exits even while a HUD control has keyboard focus")
        button.title = "Продолжить"
        precondition(button.accessibilityTitle() == "Продолжить", "VoiceOver title follows the actual action")
        window.receivesGameInput = false; window.ignoresMouseEvents = true
        precondition(!window.canBecomeKey && !window.canBecomeMain && window.ignoresMouseEvents)
        verifyWindPad(in: window)
        window.close()
        print("AppKit: Escape, accessible title, passive window and wind guide contrast passed")
    }

    private static func verifyWindPad(in window: NSWindow) {
        let pad = WindPad(frame: CGRect(x: 0, y: 0, width: 312, height: 102))
        pad.vector = .zero
        window.contentView?.addSubview(pad)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            pad.appearance = NSAppearance(named: appearance)
            let bitmap = pad.bitmapImageRepForCachingDisplay(in: pad.bounds)!
            pad.cacheDisplay(in: pad.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / pad.bounds.width
            func brightness(x: CGFloat, y: CGFloat) -> CGFloat {
                let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            for radius in [18.36, 36.72] {
                let visibleSamples = (0..<180).filter { degrees in
                    let angle = CGFloat(degrees) * .pi / 180
                    let x = pad.bounds.midX + cos(angle) * radius
                    let y = pad.bounds.midY + sin(angle) * radius
                    let backgroundX = pad.bounds.midX + cos(angle) * (radius + 4)
                    let backgroundY = pad.bounds.midY + sin(angle) * (radius + 4)
                    return abs(brightness(x: x, y: y) - brightness(x: backgroundX, y: backgroundY)) > 0.20
                }
                guard visibleSamples.count > 24 else {
                    fatalError("Wind guide at radius \(radius) has only \(visibleSamples.count) visible samples in \(appearance)")
                }
            }
        }
    }
}
