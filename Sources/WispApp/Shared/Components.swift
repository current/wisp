import AppKit
import QuartzCore

// The pieces the card style is built from. Each one draws itself and is laid out
// by frame: a new value marks one small view for redraw and never asks the window
// to re-run layout. Nothing animates unless a value changes while it is on screen.

/// A view drawn top-down.
class DrawnView: NSView {
    override var isFlipped: Bool { true }
}

/// A drawn view that renders into its own bitmap and hands it to its layer.
/// AppKit switches views that redraw often (charts) to asynchronous drawing, which
/// renders through Metal inside the app and keeps a buffer pool of about 190 MB.
/// Drawing into a plain bitmap skips that path; the cost per frame is the same.
class BitmapView: DrawnView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // A layer that clips its children to rounded corners has Core Animation draw
        // the card inside the app, about 190 MB of buffers. Nothing in a card should
        // reach its corners anyway; the layout audit reports anything that spills.
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        guard let layer, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        // Flip to match the view, then draw with AppKit as usual.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { draw(bounds) }
        NSGraphicsContext.restoreGraphicsState()
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.contents = context.makeImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}

/// White card with a hairline border. Colours are applied in updateLayer, so the
/// card costs nothing to redraw and follows light and dark.
class CardView: NSView {
    var fill: NSColor = Theme.card { didSet { needsDisplay = true } }
    var stroke: NSColor = Theme.cardBorder { didSet { needsDisplay = true } }
    var radius: CGFloat = Theme.radius { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Set on cards that open something. They answer the pointer: the border
    /// darkens on hover and the card gives a little while pressed. No shadow: a
    /// shadow on every card makes Core Animation render them inside the app.
    var onClick: (() -> Void)? { didSet { updateTrackingAreas() } }
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill.cgColor
        layer.borderColor = (hovering ? Theme.cardBorderHover : stroke).cgColor
        layer.borderWidth = stroke == .clear ? 0 : 0.5
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard onClick != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false); press(false) }

    private func setHover(_ on: Bool) {
        guard onClick != nil, on != hovering, let layer else { return }
        hovering = on
        let from = layer.presentation()?.borderColor ?? layer.borderColor
        updateLayer()
        guard !Theme.reduceMotion else { return }
        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = from
        border.duration = on ? 0.14 : 0.24
        border.timingFunction = Motion.ease
        layer.add(border, forKey: "borderColor")
    }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { return super.mouseDown(with: event) }
        press(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return super.mouseUp(with: event) }
        press(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    private var pressed = false

    /// Scales the card about its centre; AppKit leaves a view layer's transform alone.
    private func press(_ down: Bool) {
        guard down != pressed, let layer, !Theme.reduceMotion else { return }
        pressed = down
        let w = bounds.width / 2, h = bounds.height / 2
        var target = CATransform3DMakeTranslation(w, h, 0)
        if down { target = CATransform3DScale(target, 0.985, 0.985, 1) }
        target = CATransform3DTranslate(target, -w, -h, 0)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = target
        animation.duration = down ? 0.1 : 0.3
        animation.timingFunction = Motion.ease
        layer.transform = down ? target : CATransform3DIdentity
        layer.add(animation, forKey: "press")
    }
}

/// One line of attributed text. Changing the text redraws only this view.
final class TextLine: DrawnView {
    var text = NSAttributedString() {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }
    /// Longest first: the line shows the first one that fits its width, else the last.
    var variants: [NSAttributedString] = [] { didSet { if variants != oldValue { pickVariant() } } }

    private func pickVariant() {
        guard let last = variants.last else { return }
        text = variants.first { ceil($0.size().width) <= bounds.width } ?? last
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pickVariant()
    }

    convenience init(_ text: NSAttributedString, alignment: NSTextAlignment = .left) {
        self.init(frame: .zero)
        self.text = text
        self.alignment = alignment
    }

    var naturalWidth: CGFloat { ceil(text.size().width) }
    var naturalHeight: CGFloat {
        guard text.length > 0 else { return 14 }
        // The tallest font in the line; an icon attachment at the start has none.
        var height: CGFloat = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { height = max(height, ceil(font.ascender - font.descender + font.leading)) }
        }
        return height > 0 ? height : 14
    }

    override func draw(_ dirtyRect: NSRect) {
        guard text.length > 0 else { return }
        let width = min(naturalWidth, bounds.width)
        let x: CGFloat
        switch alignment {
        case .right: x = bounds.width - width
        case .center: x = (bounds.width - width) / 2
        default: x = 0
        }
        // Icon attachments can be taller than the text; centre whichever is taller.
        let height = max(naturalHeight, ceil(text.size().height))
        let y = (bounds.height - height) / 2
        text.draw(with: NSRect(x: x, y: y, width: bounds.width - x, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.string }
}

/// A large figure with a quieter unit after it. When a number changes on screen,
/// only the digits that changed pop in, one after another, rising for a higher
/// value and dropping for a lower one; the digits the two numbers share stay
/// still. Text that is not a number cross-fades in place. Every piece is a small
/// bitmap moved by Core Animation, so the window server does the motion.
final class BigNumber: DrawnView {
    var font = Theme.figure(32, .regular) { didSet { if font != oldValue { render() } } }
    var unitFont = Theme.sans(15) { didSet { if unitFont != oldValue { render() } } }
    var color: NSColor = Theme.ink { didSet { if color != oldValue { render() } } }
    /// Turns a value into the figure and its unit.
    var format: (Double) -> (String, String) = { (String(format: "%.0f", $0), "") }

    private(set) var value: Double?
    private var fixed: (String, String)?
    private var drawn: (String, String) = ("", "")
    // At rest the whole figure is one bitmap on `base`. While digits pop in, `base`
    // holds only what stayed, each new digit has its own small layer, and `outgoing`
    // carries the digits that left.
    private let base = CALayer()
    private let outgoing = CALayer()
    private var pieces: [CALayer] = []
    private var settle: DispatchWorkItem?

    private static let pop = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.64, 1)
    private static let duration: CFTimeInterval = 0.3
    private static let stagger: CFTimeInterval = 0.035
    private static let distance: CGFloat = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for sub in [base, outgoing] {
            sub.anchorPoint = .zero
            sub.contentsGravity = .topLeft
            layer?.addSublayer(sub)
        }
        outgoing.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows text that is not a number, such as "Normal".
    func show(_ text: String, unit: String = "") {
        fixed = (text, unit)
        refresh()
    }

    func set(_ newValue: Double?) {
        fixed = nil
        value = newValue
        refresh()
    }

    private var current: (String, String) {
        fixed ?? (value.map(format) ?? ("–", ""))
    }

    private func refresh() {
        let next = current
        guard next != drawn else { return }
        let old = drawn
        drawn = next
        let animate = !old.0.isEmpty && window?.isVisible == true && !Theme.reduceMotion
        guard animate else { return render() }
        let numeric = { (text: String) in text.contains(where: \.isNumber) && !text.contains(where: \.isLetter) }
        if numeric(old.0), numeric(next.0), old.1 == next.1, fit(next).fits, fit(old).fits {
            popDigits(from: old.0, to: next.0, unit: next.1)
        } else {
            crossFade(from: old)
        }
    }

    // MARK: Drawing

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func attributes(_ font: NSFont, kern: CGFloat = -0.6) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .kern: kern]
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: attributes(font)).size().width)
    }

    /// The font the figure fits in, and whether it fits without shrinking.
    private func fit(_ text: (String, String)) -> (font: NSFont, fits: Bool) {
        let unitWidth = text.1.isEmpty ? 0 : ceil(NSAttributedString(string: text.1, attributes: [.font: unitFont]).size().width) + 4
        let room = bounds.width - unitWidth
        let full = width(text.0, font)
        guard full > room, room > 0 else { return (font, true) }
        let size = max(15, floor(font.pointSize * room / full))
        return (NSFont(descriptor: font.fontDescriptor, size: size) ?? font, false)
    }

    private func baseline(_ font: NSFont) -> CGFloat { (bounds.height + font.ascender + font.descender) / 2 }

    /// A bitmap of the given size drawn in the current appearance.
    private func bitmap(_ size: CGSize, _ draw: @escaping () -> Void) -> Any? {
        guard size.width > 0, size.height > 0 else { return nil }
        let appearance = effectiveAppearance
        let image = NSImage(size: size, flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance(draw)
            return true
        }
        return image.layerContents(forContentsScale: scale)
    }

    /// Draws `figure` (all of it, or only its first `keep` characters) and the unit.
    private func drawFigure(_ text: (String, String), keep: Int? = nil) {
        let (used, fits) = fit(text)
        let top = baseline(used) - used.ascender
        let shown = keep.map { String(text.0.prefix($0)) } ?? text.0
        let unitText = NSAttributedString(string: text.1, attributes: [.font: unitFont, .foregroundColor: Theme.inkTertiary])
        let room = bounds.width - (text.1.isEmpty ? 0 : ceil(unitText.size().width) + 4)
        if fits {
            NSAttributedString(string: shown, attributes: attributes(used)).draw(at: NSPoint(x: 0, y: top))
        } else {
            // Past the smallest size it still fits, the end gives way to an ellipsis.
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var attrs = attributes(used, kern: -0.4)
            attrs[.paragraphStyle] = style
            NSAttributedString(string: shown, attributes: attrs)
                .draw(with: NSRect(x: 0, y: top, width: max(room, 1), height: ceil(used.ascender - used.descender + used.leading)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if !text.1.isEmpty {
            let x = (fits ? width(text.0, used) : min(width(text.0, used), room)) + 4
            unitText.draw(at: NSPoint(x: x, y: baseline(used) - unitFont.ascender))
        }
    }

    /// The figure at rest: one bitmap, no pieces.
    private func render() {
        settle?.cancel()
        settle = nil
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let text = drawn.0.isEmpty ? current : drawn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.removeAllAnimations()
        base.frame = CGRect(origin: .zero, size: size)
        base.contentsScale = scale
        base.opacity = 1
        base.contents = bitmap(size) { [weak self] in self?.drawFigure(text) }
        outgoing.opacity = 0
        outgoing.removeAllAnimations()
        pieces.forEach { $0.removeFromSuperlayer() }
        pieces.removeAll()
        CATransaction.commit()
    }

    // MARK: Motion

    /// Number pop-in: the digits after the shared start leave quickly and the new
    /// ones rise (or drop) into place with a slight overshoot, a few ms apart. Each
    /// change also starts after a short random wait so figures across the window
    /// do not all move on the same frame.
    private func popDigits(from old: String, to new: String, unit: String) {
        settle?.cancel()
        let oldChars = Array(old), newChars = Array(new)
        var shared = 0
        while shared < min(oldChars.count, newChars.count), oldChars[shared] == newChars[shared] { shared += 1 }
        let number = { (text: String) in Double(text.filter { $0.isNumber || $0 == "." }) ?? 0 }
        let direction: CGFloat = number(new) >= number(old) ? 1 : -1
        let size = bounds.size
        let used = font
        let top = baseline(used) - used.ascender
        let lineHeight = ceil(used.ascender - used.descender + used.leading) + 2
        let attrs = attributes(used)
        let now = CACurrentMediaTime()
        let wait = Double.random(in: 0...0.12)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pieces.forEach { $0.removeFromSuperlayer() }
        pieces.removeAll()
        base.removeAllAnimations()
        base.frame = CGRect(origin: .zero, size: size)
        base.contentsScale = scale
        base.contents = bitmap(size) { [weak self] in self?.drawFigure((new, unit), keep: shared) }

        // What left: one bitmap of the old digits after the shared start.
        let oldTail = String(oldChars[shared...])
        let oldX = width(String(oldChars[..<shared]), used)
        let oldWidth = width(oldTail, used) + 4
        outgoing.frame = CGRect(x: oldX, y: top, width: oldWidth, height: lineHeight)
        outgoing.contentsScale = scale
        outgoing.contents = bitmap(outgoing.frame.size) { NSAttributedString(string: oldTail, attributes: attrs).draw(at: .zero) }
        outgoing.opacity = 0
        CATransaction.commit()

        let leave = CAAnimationGroup()
        leave.animations = [Self.basic("opacity", 1, 0), Self.basic("transform.translation.y", 0, -direction * 4)]
        leave.duration = 0.1
        leave.beginTime = now + wait
        leave.fillMode = .both
        leave.timingFunction = CAMediaTimingFunction(name: .easeIn)
        outgoing.add(leave, forKey: "leave")

        // What came: each changed digit on its own layer.
        var end = now + wait
        for index in shared..<newChars.count {
            let character = String(newChars[index])
            let x = width(String(newChars[..<index]), used)
            let piece = CALayer()
            piece.anchorPoint = .zero
            piece.contentsGravity = .topLeft
            piece.contentsScale = scale
            piece.frame = CGRect(x: x, y: top, width: width(character, used) + 4, height: lineHeight)
            piece.contents = bitmap(piece.frame.size) { NSAttributedString(string: character, attributes: attrs).draw(at: .zero) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.addSublayer(piece)
            CATransaction.commit()
            pieces.append(piece)

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1]
            opacity.keyTimes = [0, 0.55, 1]
            opacity.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
            let move = Self.basic("transform.translation.y", direction * Self.distance, 0)
            move.timingFunction = Self.pop
            let enter = CAAnimationGroup()
            enter.animations = [opacity, move]
            enter.duration = Self.duration
            enter.beginTime = now + wait + 0.06 + Double(index - shared) * Self.stagger
            enter.fillMode = .backwards
            piece.add(enter, forKey: "enter")
            end = max(end, enter.beginTime + enter.duration)
        }

        // Once everything has landed, fold the pieces back into one bitmap.
        let work = DispatchWorkItem { [weak self] in self?.render() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (end - now) + 0.03, execute: work)
    }

    /// Text that is not a number: the old and new cross-fade in place, no movement.
    private func crossFade(from old: (String, String)) {
        settle?.cancel()
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.frame = CGRect(origin: .zero, size: size)
        outgoing.contentsScale = scale
        outgoing.contents = base.contents
        outgoing.opacity = 0
        CATransaction.commit()
        render()
        let now = CACurrentMediaTime()
        let fadeOut = Self.basic("opacity", 1, 0)
        fadeOut.duration = 0.12
        fadeOut.beginTime = now
        fadeOut.fillMode = .backwards
        outgoing.add(fadeOut, forKey: "leave")
        let fadeIn = Self.basic("opacity", 0, 1)
        fadeIn.duration = 0.18
        fadeIn.beginTime = now + 0.03
        fadeIn.fillMode = .backwards
        base.add(fadeIn, forKey: "enter")
    }

    private static func basic(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private var laidOutSize = CGSize.zero

    /// Width of the figure and its unit as drawn, for placing something after it.
    var naturalWidth: CGFloat {
        let text = drawn.0.isEmpty ? current : drawn
        let unit = text.1.isEmpty ? 0 : ceil(NSAttributedString(string: text.1, attributes: [.font: unitFont]).size().width) + 4
        return width(text.0, fit(text).font) + unit
    }

    override func layout() {
        super.layout()
        // Only a new size needs a new bitmap; a parent's layout pass must not cut a pop short.
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    override func draw(_ dirtyRect: NSRect) {}

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { current.0 + " " + current.1 }
}

/// A short capsule with uppercase text, for states like NORMAL or BUSY.
final class Pill: DrawnView {
    enum Tone { case good, warn, bad, neutral }

    var tone: Tone = .good { didSet { if tone != oldValue { needsDisplay = true } } }
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var dot = false

    /// A leading symbol, such as the warning triangle.
    var symbol: String? { didSet { needsDisplay = true } }

    private var label: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(11, .semibold), .foregroundColor: colors.0])
    }

    var naturalWidth: CGFloat { ceil(label.size().width) + 16 + (symbol != nil || dot ? 15 : 0) }

    private var colors: (NSColor, NSColor) {
        switch tone {
        case .good: return (Theme.good, Theme.goodWash)
        case .warn: return (Theme.warn, Theme.warnWash)
        case .bad: return (Theme.bad, Theme.badWash)
        case .neutral: return (Theme.inkSecondary, Theme.fill)
        }
    }

    /// A Tahoe badge: a capsule in a wash of its colour with semibold text.
    override func draw(_ dirtyRect: NSRect) {
        let (ink, wash) = colors
        wash.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var x: CGFloat = 8
        if let symbol {
            IconTile.glyph(symbol, tint: ink, size: 12, appearance: effectiveAppearance)
                .draw(in: NSRect(x: 7, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            x = 22
        } else if dot {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: bounds.midY - 3, width: 6, height: 6)).fill()
            x = 21
        }
        let label = self.label
        let height = label.size().height
        label.draw(at: NSPoint(x: x, y: (bounds.height - height) / 2))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// A row of thin ticks, filled from the left. Cheaper to read at a glance than a
/// bar and it shows the scale.
final class TickMeter: DrawnView {
    var fraction: Double = 0 {
        didSet { if Int(fraction * 200) != Int(oldValue * 200) { needsDisplay = true } }
    }
    var color: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var tickWidth: CGFloat = 2
    var pitch: CGFloat = 4.5

    /// Tahoe draws a thin capsule; the tick style stays for places that want it.
    var ticks = false

    override func draw(_ dirtyRect: NSRect) {
        if !ticks {
            let height = min(6, bounds.height)
            let track = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            Theme.track.setFill()
            NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
            let filled = track.width * CGFloat(min(1, max(0, fraction)))
            if filled > 0.5 {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: max(height, filled), height: height),
                             xRadius: height / 2, yRadius: height / 2).fill()
            }
            return
        }
        let count = max(1, Int((bounds.width + pitch - tickWidth) / pitch))
        let filled = Int((min(1, max(0, fraction)) * Double(count)).rounded())
        for index in 0..<count {
            (index < filled ? color : Theme.track).setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * pitch, y: 0, width: tickWidth, height: bounds.height),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// A line of recent samples with a soft fill and a dot on the newest value.
final class LiveLine: BitmapView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var ceiling: Float?
    var color: NSColor = Theme.accent { didSet { needsDisplay = true } }
    /// How many samples the width holds, so a short history starts at the right.
    var capacity = 120

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 5, dy: 5)
        let points = values.filter { !$0.isNaN }
        guard points.count > 1, rect.width > 0 else { return }
        let top = ceiling ?? max(points.max() ?? 0, 0.0001) * 1.15
        let step = rect.width / CGFloat(max(capacity - 1, 1))
        let start = rect.maxX - CGFloat(points.count - 1) * step
        func point(_ index: Int) -> NSPoint {
            NSPoint(x: start + CGFloat(index) * step, y: rect.maxY - CGFloat(min(1, points[index] / top)) * rect.height)
        }
        let line = NSBezierPath()
        line.move(to: point(0))
        for index in 1..<points.count { line.line(to: point(index)) }

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: point(points.count - 1).x, y: bounds.maxY))
        area.line(to: NSPoint(x: start, y: bounds.maxY))
        area.close()
        NSGradient(starting: color.withAlphaComponent(0.16), ending: color.withAlphaComponent(0))?.draw(in: area, angle: -90)

        color.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.stroke()

        let end = point(points.count - 1)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)).fill()
        Theme.card.setFill()
        NSBezierPath(ovalIn: NSRect(x: end.x - 2.75, y: end.y - 2.75, width: 5.5, height: 5.5)).fill()
        color.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: end.x - 2.75, y: end.y - 2.75, width: 5.5, height: 5.5))
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// A one-pixel dashed rule between parts of a card.
final class DashedRule: DrawnView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0.5))
        path.line(to: NSPoint(x: bounds.width, y: 0.5))
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.lineWidth = 1
        Theme.cardBorder.setStroke()
        path.stroke()
    }
}

/// Uppercase choices in a capsule. The selected one sits on a raised white pill
/// that slides between choices on a Core Animation layer, so the move costs the
/// app nothing. The labels draw in a subview above the pill.
final class Segmented: DrawnView {
    var items: [String] { didSet { labels.needsDisplay = true } }
    private(set) var selected = 0
    var onChange: ((Int) -> Void)?
    private let knob = CALayer()
    private let labels = Labels()

    private final class Labels: DrawnView {
        weak var owner: Segmented?
        override func draw(_ dirtyRect: NSRect) {
            guard let owner else { return }
            for (index, rect) in owner.frames().enumerated() {
                let label = Segmented.label(owner.items[index], on: index == owner.selected)
                let size = label.size()
                label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init(_ items: [String]) {
        self.items = items
        super.init(frame: .zero)
        wantsLayer = true
        knob.cornerCurve = .continuous
        layer?.addSublayer(knob)
        labels.owner = self
        addSubview(labels)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Set when the control sits on a glass capsule, which draws the track.
    var onGlass = false { didSet { needsDisplay = true } }

    static func label(_ text: String, on: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(12.5, on ? .semibold : .regular),
                                                     .foregroundColor: Theme.ink])
    }

    private static func itemWidth(_ text: String) -> CGFloat {
        ceil(label(text, on: true).size().width) + 26
    }

    var naturalWidth: CGFloat {
        items.reduce(6) { $0 + Self.itemWidth($1) }
    }

    func select(_ index: Int, animated: Bool) {
        guard index != selected, items.indices.contains(index) else { return }
        selected = index
        placeKnob(animated: animated)
        labels.needsDisplay = true
        setAccessibilityValue(items[index])
    }

    fileprivate func frames() -> [NSRect] {
        var x: CGFloat = 3
        return items.map { item in
            let width = Self.itemWidth(item)
            defer { x += width }
            return NSRect(x: x, y: 3, width: width, height: bounds.height - 6)
        }
    }

    private func placeKnob(animated: Bool) {
        let rects = frames()
        guard rects.indices.contains(selected) else { return }
        // Tabs sliding: 0.25 s on a smooth-out curve.
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Theme.reduceMotion)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1))
        // The layer is not flipped; mirror the y origin.
        let r = rects[selected]
        knob.frame = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        knob.cornerRadius = r.height / 2
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        labels.frame = bounds
        placeKnob(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            knob.backgroundColor = Theme.ink.withAlphaComponent(0.08).cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !onGlass else { return }
        Theme.ink.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = frames().firstIndex(where: { $0.contains(point) }) else { return }
        choose(index)
    }

    // Each choice is its own radio button so VoiceOver and scripts can press it.
    private var choiceElements: [Choice] = []

    private final class Choice: NSAccessibilityElement {
        weak var owner: Segmented?
        var index = 0
        override func accessibilityPerformPress() -> Bool {
            guard let owner else { return false }
            owner.choose(index)
            return true
        }
        override func accessibilityValue() -> Any? { owner?.selected == index ? 1 : 0 }
        override func accessibilityFrameInParentSpace() -> NSRect {
            guard let owner, owner.frames().indices.contains(index) else { return .zero }
            let rect = owner.frames()[index]
            return NSRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    fileprivate func choose(_ index: Int) {
        guard index != selected else { return }
        select(index, animated: true)
        onChange?(index)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override func accessibilityChildren() -> [Any]? {
        if choiceElements.count != items.count {
            choiceElements = items.enumerated().map { index, item in
                let element = Choice()
                element.owner = self
                element.index = index
                element.setAccessibilityRole(.radioButton)
                element.setAccessibilityLabel(item)
                element.setAccessibilityParent(self)
                return element
            }
        }
        return choiceElements
    }
}

/// The capsule button used for the one main action on a surface.
final class ActionButton: NSButton {
    /// A white capsule with a hairline, for actions that are not the main one.
    var secondary = false { didSet { needsDisplay = true } }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        font = Theme.sans(12.5, .medium)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font as Any]).width) + (secondary ? 24 : 32), height: secondary ? 26 : 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if secondary {
            (isHighlighted ? Theme.hover : Theme.card).setFill()
            shape.fill()
            Theme.cardBorder.setStroke()
            shape.stroke()
        } else {
            (isHighlighted ? Theme.actionPressed : Theme.action).setFill()
            shape.fill()
        }
        let text = NSAttributedString(string: title, attributes: [.font: font as Any, .foregroundColor: secondary ? Theme.ink : NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// A borderless symbol button for headers and footers.
final class SymbolButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = Theme.inkSecondary
        toolTip = label
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A dark hover card with a title line and up to a few value lines.
final class Tooltip: DrawnView {
    struct Line {
        var color: NSColor?
        var name: String
        var value: String
    }

    var title = ""
    var detail = ""
    var lines: [Line] = []

    private static let titleFont = Theme.sans(12, .medium)
    private static let bodyFont = Theme.sans(12)
    private static let figureFont = Theme.figure(12, .medium)

    func fittingSize() -> NSSize {
        let titleWidth = (title as NSString).size(withAttributes: [.font: Self.titleFont]).width
            + (detail.isEmpty ? 0 : (detail as NSString).size(withAttributes: [.font: Self.bodyFont]).width + 20)
        let lineWidth = lines.map {
            ($0.name as NSString).size(withAttributes: [.font: Self.bodyFont]).width
                + ($0.value as NSString).size(withAttributes: [.font: Self.figureFont]).width + ($0.color == nil ? 24 : 40)
        }.max() ?? 0
        return NSSize(width: ceil(max(titleWidth, lineWidth)) + 24, height: 32 + CGFloat(lines.count) * 21)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tooltip.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let white = NSColor.white
        let dim = NSColor.white.withAlphaComponent(0.55)
        (title as NSString).draw(at: NSPoint(x: 12, y: 9), withAttributes: [.font: Self.titleFont, .foregroundColor: white])
        if !detail.isEmpty {
            let size = (detail as NSString).size(withAttributes: [.font: Self.bodyFont])
            (detail as NSString).draw(at: NSPoint(x: bounds.width - 12 - size.width, y: 9),
                                      withAttributes: [.font: Self.bodyFont, .foregroundColor: dim])
        }
        for (index, line) in lines.enumerated() {
            let y = 33 + CGFloat(index) * 21
            var x: CGFloat = 12
            if let color = line.color {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y + 4.5, width: 7, height: 7)).fill()
                x += 16
            }
            (line.name as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: Self.bodyFont, .foregroundColor: dim])
            let size = (line.value as NSString).size(withAttributes: [.font: Self.figureFont])
            (line.value as NSString).draw(at: NSPoint(x: bounds.width - 12 - size.width, y: y),
                                          withAttributes: [.font: Self.figureFont, .foregroundColor: white])
        }
    }

    /// Shows the tooltip in `host` above `anchor` (a rect in host coordinates), kept inside the host.
    func show(in host: NSView, above anchor: NSRect) {
        if superview !== host { host.addSubview(self) }
        let size = fittingSize()
        var x = anchor.midX - size.width / 2
        x = min(max(8, x), host.bounds.width - size.width - 8)
        let flipped = host.isFlipped
        var y = flipped ? anchor.minY - size.height - 6 : anchor.maxY + 6
        if flipped, y < 4 { y = anchor.maxY + 6 }
        frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        isHidden = false
        needsDisplay = true
    }

    func hide() { isHidden = true }
}

/// A Tahoe pull-down for choosing one of a few things inside a card: the choice and a
/// small up-down chevron on a soft grey capsule, with a menu of the choices on click.
final class MenuButton: DrawnView {
    var titles: [String] = [] { didSet { if titles != oldValue { needsDisplay = true } } }
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onPick: ((Int) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private static let font = Theme.sans(12.5, .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var title: String { titles.indices.contains(selected) ? titles[selected] : "" }

    var naturalWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 40 }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Theme.ink.withAlphaComponent(0.09) : Theme.fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(with: NSRect(x: 12, y: (bounds.height - 16) / 2, width: bounds.width - 38, height: 16),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: Self.font, .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
        IconTile.glyph("chevron.up.chevron.down", tint: Theme.inkSecondary, size: 10, appearance: effectiveAppearance)
            .draw(in: NSRect(x: bounds.width - 22, y: (bounds.height - 10) / 2, width: 10, height: 10), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        setAccessibilityValue(title)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { showMenu() }
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
        // The current choice opens over the button, as a macOS pop-up menu does.
        menu.popUp(positioning: menu.item(at: selected), at: NSPoint(x: 4, y: bounds.height - 4), in: self)
        hovering = false
    }

    @objc private func picked(_ item: NSMenuItem) {
        selected = item.tag
        onPick?(item.tag)
    }
}
