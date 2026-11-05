import AppKit

/// The controls a settings row ends in, in the A2 style: a pop-up capsule, a switch
/// and a small pill button. Both SettingsPage and CleanUpSettings build rows from these.
@MainActor
enum SettingsControls {
    static func toggle(_ on: Bool, _ body: @escaping (Bool) -> Void) -> NSView {
        SettingsSwitch(on: on, body)
    }

    /// As wide as the longest choice, so picking one does not move the button.
    static func popup(_ titles: [String], _ selected: Int, _ body: @escaping (Int) -> Void) -> NSView {
        let button = SettingsPopUp()
        button.titles = titles
        button.selected = selected
        button.onPick = body
        button.frame.size = NSSize(width: SettingsPopUp.width(for: titles), height: SettingsPopUp.height)
        return button
    }

    static func pill(_ title: String, _ body: @escaping () -> Void) -> NSView {
        let pill = A2PillButton()
        pill.title = title
        pill.onPress = body
        pill.frame.size = NSSize(width: pill.naturalWidth, height: 26)
        return pill
    }
}

/// A pop-up for one setting: the choice and a small up-down chevron on a white capsule
/// with a hairline in light mode, a faint lighter capsule in dark. Shows a menu of the
/// choices on click, the current one over the button.
final class SettingsPopUp: DrawnView {
    var titles: [String] = [] { didSet { if titles != oldValue { needsDisplay = true } } }
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onPick: ((Int) -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    /// The capsule is 24 pt tall; the view keeps a point above and below it for the
    /// light-mode drop shadow, which is drawn, not a layer shadow.
    static let height: CGFloat = 26
    private static let font = Theme.sans(12.5, .medium)
    private static let fill = A2.dynamic(.white, NSColor(white: 1, alpha: 0.1))
    private static let fillHover = A2.dynamic(NSColor(white: 0.965, alpha: 1), NSColor(white: 1, alpha: 0.14))
    private static let ring = A2.dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.08))

    /// 11 pt before the text, 7 to the 11 pt chevron and 7 after it.
    static func width(for titles: [String]) -> CGFloat {
        let widest = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        return widest + 11 + 7 + 11 + 7
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var title: String { titles.indices.contains(selected) ? titles[selected] : "" }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2)
        let shape = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
        let dark = A2.drawingDark
        NSGraphicsContext.saveGraphicsState()
        if !dark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.08)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 1.5
            shadow.set()
        }
        (hovering ? Self.fillHover : Self.fill).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.25, dy: 0.25), xRadius: capsule.height / 2 - 0.25, yRadius: capsule.height / 2 - 0.25)
        ring.lineWidth = 0.5
        Self.ring.setStroke()
        ring.stroke()
        if dark {
            // The dark capsule's lit top edge.
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor(white: 1, alpha: 0.16).setFill()
            NSRect(x: capsule.minX, y: capsule.minY, width: capsule.width, height: 0.5).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let font = Self.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let lineHeight = ceil(font.ascender - font.descender)
        (title as NSString).draw(with: NSRect(x: capsule.minX + 11, y: capsule.midY - lineHeight / 2, width: capsule.width - 36, height: lineHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: font, .foregroundColor: A2.primary, .paragraphStyle: paragraph])

        // The mockup's up-down chevron: a 1.8 pt stroke on a 16 pt grid, drawn at 11 pt.
        let scale: CGFloat = 11 / 16
        let origin = NSPoint(x: capsule.maxX - 7 - 11, y: capsule.midY - 5.5)
        let point = { (x: CGFloat, y: CGFloat) in NSPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        let chevron = NSBezierPath()
        chevron.move(to: point(5, 6.2)); chevron.line(to: point(8, 3.4)); chevron.line(to: point(11, 6.2))
        chevron.move(to: point(5, 9.8)); chevron.line(to: point(8, 12.6)); chevron.line(to: point(11, 9.8))
        chevron.lineWidth = 1.8 * scale
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        A2.secondary.setStroke()
        chevron.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { showMenu() }

    override func accessibilityValue() -> Any? { title }
    override func accessibilityPerformPress() -> Bool { showMenu(); return true }

    private func showMenu() {
        guard !titles.isEmpty else { return }
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: selected), at: NSPoint(x: 5, y: bounds.height - 4), in: self)
        hovering = false
    }

    @objc private func picked(_ item: NSMenuItem) {
        selected = item.tag
        onPick?(item.tag)
    }
}

/// An on-off switch, 38 by 22, blue when on. Drawn by Wisp rather than NSSwitch so it
/// keeps its colour while another app is active, as the rest of the window does.
final class SettingsSwitch: NSView {
    private let body: (Bool) -> Void
    private(set) var isOn: Bool
    private let track = CALayer()
    private let knob = CALayer()
    private var animates = false

    static let size = NSSize(width: 38, height: 22)
    private static let onColor = A2.cpu
    private static let offColor = A2.dynamic(NSColor(white: 0, alpha: 0.09), NSColor(white: 1, alpha: 0.14))

    init(on: Bool, _ body: @escaping (Bool) -> Void) {
        self.body = body
        isOn = on
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        track.cornerRadius = Self.size.height / 2
        knob.cornerRadius = 9
        knob.borderWidth = 0.5
        knob.shadowOpacity = 1
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -1)
        knob.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 18, height: 18), transform: nil)
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(!animates || Theme.reduceMotion)
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(Motion.ease)
        track.frame = bounds
        track.backgroundColor = (isOn ? Self.onColor : Self.offColor).cgColor
        knob.frame = CGRect(x: isOn ? bounds.width - 20 : 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
        knob.backgroundColor = NSColor.white.cgColor
        knob.borderColor = NSColor(white: 0, alpha: 0.06).cgColor
        knob.shadowColor = NSColor(white: 0, alpha: 0.28).cgColor
        CATransaction.commit()
        animates = false
    }

    private func flip() {
        isOn.toggle()
        animates = window != nil
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        body(isOn)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { flip() }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { flip() } else { super.keyDown(with: event) }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityRoleDescription() -> String? { "switch" }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
}
