import AppKit

/// One line of text that ends in "…" when it does not fit, and scrolls through the
/// rest while the pointer is over it. It costs nothing until hovered.
///
/// The scroll eases out to the end, rests, eases back and rests again, with the clipped
/// edges faded, so it never jumps. Swapping to `hoverText` and back crossfades.
final class MarqueeLabel: NSView {
    var text = "" { didSet { if text != oldValue { reset() } } }
    /// Shown in place of `text` while the pointer is over the label, such as the account
    /// behind an "updated 4m ago".
    var hoverText: String? { didSet { if hoverText != oldValue, hovering { reset() } } }
    private var hovering = false
    private var shown: String { hovering ? (hoverText ?? text) : text }
    var font = Theme.sans(12) { didSet { reset() } }
    var color: NSColor = A2.tertiary { didSet { needsDisplay = true } }
    /// Short text sits against the right edge, as a value beside a title does.
    var alignRight = true
    /// Extra space between letters, and whether AppKit thickens the strokes: the menu bar
    /// dropdown sets its text looser and thinner.
    var kern: CGFloat = 0 { didSet { measuredWidth = nil; needsDisplay = true } }
    var smoothsFonts = true

    private var offset: CGFloat = 0
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    /// Points a second at the middle of the eased scroll.
    private static let speed: CGFloat = 30
    private static let restAtStart: CFTimeInterval = 0.7
    private static let restAtEnd: CFTimeInterval = 1.1
    private static let edge: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    // The hover text is part of what the label says; an empty label says nothing at all.
    override func isAccessibilityElement() -> Bool { !text.isEmpty || !(hoverText ?? "").isEmpty }
    override func accessibilityValue() -> Any? { [text, hoverText ?? ""].filter { !$0.isEmpty }.joined(separator: ", ") }

    /// The shown text's width, measured once per change rather than on every frame.
    private var measuredWidth: CGFloat?
    private var textWidth: CGFloat {
        if let measuredWidth { return measuredWidth }
        let width = A2Dev.width(shown, font, kern: kern)
        measuredWidth = width
        return width
    }
    private var overflow: CGFloat { max(0, textWidth - bounds.width) }

    override func draw(_ dirtyRect: NSRect) {
        let line = ceil(font.ascender - font.descender)
        let y = (bounds.height - line) / 2
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        if !smoothsFonts { NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false) }
        guard overflow > 0 else {
            let x = alignRight ? bounds.width - textWidth : 0
            (shown as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            return
        }
        guard timer != nil, let context = NSGraphicsContext.current?.cgContext else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var truncated = attributes
            truncated[.paragraphStyle] = paragraph
            (shown as NSString).draw(with: NSRect(x: 0, y: y, width: bounds.width, height: line + 2),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: truncated)
            return
        }
        // The text, then its clipped ends faded out: the left once it has moved, the
        // right while there is more to come.
        context.saveGState()
        context.clip(to: bounds)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        (shown as NSString).draw(at: NSPoint(x: -offset, y: y), withAttributes: attributes)
        context.setBlendMode(.destinationOut)
        let space = CGColorSpaceCreateDeviceGray()
        let opaque = CGColor(gray: 0, alpha: 1), clear = CGColor(gray: 0, alpha: 0)
        if let gradient = CGGradient(colorsSpace: space, colors: [opaque, clear] as CFArray, locations: [0, 1]) {
            let edge = Self.edge
            if offset > 0.5 {
                let strength = min(1, offset / edge)
                context.setAlpha(strength)
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: edge, y: 0), options: [])
            }
            if offset < overflow - 0.5 {
                let strength = min(1, (overflow - offset) / edge)
                context.setAlpha(strength)
                context.drawLinearGradient(gradient, start: CGPoint(x: bounds.width, y: 0), end: CGPoint(x: bounds.width - edge, y: 0), options: [])
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        measuredWidth = nil
        if hoverText != nil || overflow > 0 { crossfade() }
        needsDisplay = true
        startScrolling()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if hoverText != nil || timer != nil { crossfade(duration: 0.25) }
        reset()
    }

    /// Where the text sits `elapsed` seconds into the hover: rest, ease to the end, rest,
    /// ease back (quicker), and again.
    private func position(_ elapsed: CFTimeInterval) -> CGFloat {
        let distance = overflow
        let forward = max(0.6, Double(distance / Self.speed) * 1.4)
        let back = max(0.45, forward * 0.55)
        let cycle = Self.restAtStart + forward + Self.restAtEnd + back
        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < Self.restAtStart { return 0 }
        t -= Self.restAtStart
        if t < forward { return distance * Self.ease(t / forward) }
        t -= forward
        if t < Self.restAtEnd { return distance }
        t -= Self.restAtEnd
        return distance * (1 - Self.ease(t / back))
    }

    /// Ease in and out (cubic), so the text starts and stops gently.
    private static func ease(_ p: Double) -> CGFloat {
        CGFloat(p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2)
    }

    private func startScrolling() {
        guard overflow > 0, timer == nil, !Theme.reduceMotion else { return }
        offset = 0
        started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A dropdown closes with orderOut, which sends no mouseExited.
                guard self.window?.isVisible == true else {
                    self.hovering = false
                    return self.reset()
                }
                let next = self.position(CACurrentMediaTime() - self.started)
                if abs(next - self.offset) > 0.01 {
                    self.offset = next
                    self.needsDisplay = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if timer != nil {
            hovering = false
            reset()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hovering = false
            reset()
        }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        measuredWidth = nil
        offset = 0
        needsDisplay = true
    }
}
