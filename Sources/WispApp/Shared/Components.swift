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

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill.cgColor
        layer.borderColor = stroke.cgColor
        layer.borderWidth = stroke == .clear ? 0 : 1
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }
}

/// One line of attributed text. Changing the text redraws only this view.
final class TextLine: DrawnView {
    var text = NSAttributedString() {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }

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

/// A large figure with a quieter unit after it. When the figure changes on
/// screen the new one rolls in with a short Core Animation push, which the
/// window server runs on the GPU; the app draws each value once.
final class BigNumber: DrawnView {
    var font = Theme.figure(32, .regular) { didSet { render() } }
    var unitFont = Theme.sans(15) { didSet { render() } }
    var color: NSColor = Theme.ink { didSet { render() } }
    /// Turns a value into the figure and its unit.
    var format: (Double) -> (String, String) = { (String(format: "%.0f", $0), "") }

    private(set) var value: Double?
    private var fixed: (String, String)?
    private var drawn: (String, String) = ("", "")
    // The figure is a bitmap on a layer. A change slides the old one out and the new
    // one in with plain position and opacity animations, which the render server runs.
    // A CATransition would snapshot the layer in-process and keep Metal buffers around.
    private let front = CALayer()
    private let back = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for sub in [back, front] {
            sub.anchorPoint = .zero
            sub.contentsGravity = .topLeft
            layer?.addSublayer(sub)
        }
        back.opacity = 0
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
        let rising = (Double(next.0.filter { $0.isNumber || $0 == "." }) ?? 0) >= (Double(drawn.0.filter { $0.isNumber || $0 == "." }) ?? 0)
        let animate = !drawn.0.isEmpty && window?.isVisible == true && !Theme.reduceMotion && next.1 == drawn.1
        drawn = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animate {
            back.contents = front.contents
            back.opacity = 0
        }
        render()
        CATransaction.commit()
        guard animate else { return }
        let distance = min(12, bounds.height / 3) * (rising ? 1 : -1)
        slide(front, from: distance, to: 0, fade: (0, 1))
        slide(back, from: 0, to: -distance, fade: (1, 0))
    }

    private func slide(_ layer: CALayer, from: CGFloat, to: CGFloat, fade: (Float, Float)) {
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        // The view is flipped, so a positive offset is lower on screen.
        move.fromValue = from
        move.toValue = to
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fade.0
        opacity.toValue = fade.1
        let group = CAAnimationGroup()
        group.animations = [move, opacity]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "slide")
    }

    override func layout() {
        super.layout()
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

    /// Draws the figure into a bitmap the size of the view and puts it on the front layer.
    private func render() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let (figure, unit) = drawn.0.isEmpty ? current : drawn
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = effectiveAppearance
        let font = self.font, unitFont = self.unitFont, color = self.color
        let image = NSImage(size: size, flipped: true) { bounds in
            appearance.performAsCurrentDrawingAppearance {
                let unitText = NSAttributedString(string: unit, attributes: [.font: unitFont, .foregroundColor: Theme.inkTertiary])
                let room = bounds.width - (unit.isEmpty ? 0 : ceil(unitText.size().width) + 4)
                // Long text, such as an app name, shrinks to fit rather than running out of the card.
                var used = font
                var figureText = NSAttributedString(string: figure, attributes: [.font: used, .foregroundColor: color, .kern: -0.6])
                let width = figureText.size().width
                if width > room, room > 0 {
                    used = NSFont(descriptor: font.fontDescriptor, size: max(12, floor(font.pointSize * room / width))) ?? font
                    figureText = NSAttributedString(string: figure, attributes: [.font: used, .foregroundColor: color, .kern: -0.4])
                }
                let baseline = (bounds.height + used.ascender + used.descender) / 2
                figureText.draw(at: NSPoint(x: 0, y: baseline - used.ascender))
                if !unit.isEmpty {
                    unitText.draw(at: NSPoint(x: ceil(figureText.size().width) + 4, y: baseline - unitFont.ascender))
                }
            }
            return true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in [front, back] {
            sub.frame = CGRect(origin: .zero, size: size)
            sub.contentsScale = scale
        }
        front.contents = image.layerContents(forContentsScale: scale)
        CATransaction.commit()
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

    var naturalWidth: CGFloat { ceil(Theme.caption(text).size().width) + (dot ? 26 : 16) }

    private var colors: (NSColor, NSColor) {
        switch tone {
        case .good: return (Theme.good, Theme.goodWash)
        case .warn: return (Theme.warn, Theme.warnWash)
        case .bad: return (Theme.bad, Theme.badWash)
        case .neutral: return (Theme.inkSecondary, Theme.rule)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let (ink, wash) = colors
        wash.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var x: CGFloat = 8
        if dot {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: bounds.midY - 3, width: 6, height: 6)).fill()
            x = 19
        }
        let label = Theme.caption(text, color: ink)
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

    override func draw(_ dirtyRect: NSRect) {
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
                let label = Theme.caption(owner.items[index], color: index == owner.selected ? Theme.ink : Theme.inkTertiary)
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
        knob.cornerRadius = 9
        knob.cornerCurve = .continuous
        knob.borderWidth = 1
        knob.shadowOpacity = 0.08
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knob)
        labels.owner = self
        addSubview(labels)
    }

    required init?(coder: NSCoder) { fatalError() }

    var naturalWidth: CGFloat {
        items.reduce(8) { $0 + ceil(Theme.caption($1).size().width) + 22 }
    }

    func select(_ index: Int, animated: Bool) {
        guard index != selected, items.indices.contains(index) else { return }
        selected = index
        placeKnob(animated: animated)
        labels.needsDisplay = true
        setAccessibilityValue(items[index])
    }

    fileprivate func frames() -> [NSRect] {
        var x: CGFloat = 4
        return items.map { item in
            let width = ceil(Theme.caption(item).size().width) + 22
            defer { x += width }
            return NSRect(x: x, y: 3, width: width, height: bounds.height - 6)
        }
    }

    private func placeKnob(animated: Bool) {
        let rects = frames()
        guard rects.indices.contains(selected) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Theme.reduceMotion)
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // The layer is not flipped; mirror the y origin.
        let r = rects[selected]
        knob.frame = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
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
            knob.backgroundColor = Theme.card.cgColor
            knob.borderColor = Theme.cardBorder.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.cardBorder.setStroke()
        outline.lineWidth = 1
        outline.stroke()
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
