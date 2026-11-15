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
        window.close()
        print("AppKit: Escape with focused HUD, accessible title and passive window checks passed")
    }
}
