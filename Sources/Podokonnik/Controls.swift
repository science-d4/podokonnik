import AppKit

final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .large
        target = self; self.action = #selector(fire)
        actionHandler = action
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageLeading }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { actionHandler?() }
}

final class ActionSlider: NSSlider {
    var change: ((Double) -> Void)?
    init(value: Double, label: String, range: ClosedRange<Double> = -1...1, change: @escaping (Double) -> Void) {
        super.init(frame: .zero)
        minValue = range.lowerBound; maxValue = range.upperBound; doubleValue = value
        self.change = change; target = self; action = #selector(changed); isContinuous = true
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { change?(doubleValue) }
}

final class ActionSegment: NSSegmentedControl {
    var change: ((Int) -> Void)?
    init(labels: [String], selected: Int, change: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        segmentCount = labels.count
        for (i, title) in labels.enumerated() { setLabel(title, forSegment: i); setWidth(0, forSegment: i) }
        selectedSegment = selected; segmentStyle = .rounded
        trackingMode = .selectOne; self.change = change; target = self; action = #selector(changed)
        controlSize = .large
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { change?(selectedSegment) }
}

final class WindPad: NSView {
    var vector: CGVector = .zero {
        didSet {
            needsDisplay = true
            setAccessibilityValue("По горизонтали \(Int(vector.dx*100))%, по вертикали \(Int(vector.dy*100))%")
        }
    }
    var onChange: ((CGVector) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("Направление ветра. Стрелки меняют ветер, пробел — штиль")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 1, dy: 1)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: area, xRadius: 12, yRadius: 12).fill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = min(bounds.width, bounds.height) * 0.36
        NSColor.secondaryLabelColor.setStroke()
        for scale: CGFloat in [0.5, 1] {
            let p = NSBezierPath(ovalIn: CGRect(x: center.x-r*scale, y: center.y-r*scale, width: 2*r*scale, height: 2*r*scale))
            p.lineWidth = 1.5
            p.setLineDash([2, 4], count: 2, phase: 0); p.stroke()
        }
        let dot = CGPoint(x: center.x + vector.dx*r, y: center.y + vector.dy*r)
        NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
        let line = NSBezierPath(); line.move(to: center); line.line(to: dot); line.lineWidth = 2; line.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(ovalIn: CGRect(x: dot.x-12, y: dot.y-12, width: 24, height: 24)).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: dot.x-5, y: dot.y-5, width: 10, height: 10)).fill()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: area, xRadius: 12, yRadius: 12); focus.lineWidth = 2; focus.stroke()
        }
    }
    private func update(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = min(bounds.width, bounds.height) * 0.36
        vector = CGVector(dx: max(-1, min(1, (p.x-bounds.midX)/r)), dy: max(-1, min(1, (p.y-bounds.midY)/r)))
        onChange?(vector)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func keyDown(with event: NSEvent) {
        var v = vector
        switch event.keyCode {
        case 123: v.dx -= 0.1
        case 124: v.dx += 0.1
        case 125: v.dy -= 0.1
        case 126: v.dy += 0.1
        case 49: v = .zero
        default: super.keyDown(with: event); return
        }
        vector = CGVector(dx: max(-1, min(1, v.dx)), dy: max(-1, min(1, v.dy))); onChange?(vector)
    }
}

func textLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

func verticalStack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

func horizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}
