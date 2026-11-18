import AppKit

/// One line of text that ends in "…" when it does not fit, and scrolls through the
/// rest while the pointer is over it. It costs nothing until hovered.
final class MarqueeLabel: NSView {
    var text = "" { didSet { if text != oldValue { reset() } } }
    var font = Theme.sans(12) { didSet { reset() } }
    var color: NSColor = A2.tertiary { didSet { needsDisplay = true } }
    /// Short text sits against the right edge, as a value beside a title does.
    var alignRight = true

    private var offset: CGFloat = 0
    private var timer: Timer?
    private var pauseUntil: CFTimeInterval = 0
    private static let speed: CGFloat = 32
    private static let pause: CFTimeInterval = 0.9

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> Any? { text }

    private var textWidth: CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    private var overflow: CGFloat { max(0, textWidth - bounds.width) }

    override func draw(_ dirtyRect: NSRect) {
        let line = ceil(font.ascender - font.descender)
        let y = (bounds.height - line) / 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard overflow > 0 else {
            let x = alignRight ? bounds.width - textWidth : 0
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            return
        }
        if timer == nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var truncated = attributes
            truncated[.paragraphStyle] = paragraph
            (text as NSString).draw(with: NSRect(x: 0, y: y, width: bounds.width, height: line + 2),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: truncated)
        } else {
            NSBezierPath(rect: bounds).addClip()
            (text as NSString).draw(at: NSPoint(x: -offset, y: y), withAttributes: attributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard overflow > 0, timer == nil, !Theme.reduceMotion else { return }
        offset = 0
        pauseUntil = CACurrentMediaTime() + Self.pause / 2
        var last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                defer { last = now }
                guard now >= self.pauseUntil else { return }
                if self.offset >= self.overflow {
                    // At the end: rest, then start over from the beginning.
                    self.offset = 0
                    self.pauseUntil = now + Self.pause
                } else {
                    self.offset = min(self.overflow, self.offset + Self.speed * CGFloat(now - last))
                    if self.offset >= self.overflow { self.pauseUntil = now + Self.pause }
                }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { reset() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { reset() }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        offset = 0
        needsDisplay = true
    }
}
