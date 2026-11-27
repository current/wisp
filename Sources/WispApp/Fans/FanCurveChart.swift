import AppKit
import WispCore

/// A fan curve to edit: temperature across, speed up, with a handle on each point.
/// Drag a handle to move it, double-click to add one, drag one well off the chart to
/// remove it. With focus, Tab picks a point, the arrow keys move it (Shift for five),
/// Delete removes it and + adds one after it. The current reading of the curve's sensor
/// shows as a line, with the speed the curve gives there.
@MainActor
final class FanCurveChart: BitmapView {
    /// Sorted by temperature, at most one per degree, as `FanCurve` keeps them.
    var points: [FanCurve.Point] = [] {
        didSet {
            guard points != oldValue else { return }
            if let selected, selected >= points.count { self.selected = points.isEmpty ? nil : points.count - 1 }
            needsDisplay = true
        }
    }
    var celsius: Double? { didSet { if celsius != oldValue { needsDisplay = true } } }
    /// The helper is running the fans at full speed whatever the curve says.
    var overheated = false { didSet { if overheated != oldValue { needsDisplay = true } } }
    var color: NSColor = A2.cpu
    /// Every edit, already sorted.
    var onChange: (([FanCurve.Point]) -> Void)?

    private(set) var selected: Int? { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var dragging: Int?
    /// The dragged point is far enough off the chart that letting go removes it.
    private var removing = false { didSet { if removing != oldValue { needsDisplay = true } } }

    private static let range = FanCurve.celsiusRange
    private static let minimumPoints = 2
    private static let handle: CGFloat = 5.5
    private static let reach: CGFloat = 10
    private static let tearOff: CGFloat = 36
    private static let labelFont = Theme.digits(10)
    private static let tagFont = Theme.figure(11, .medium)

    /// The plot inside the axis labels: percent on the left, degrees underneath.
    var plot: NSRect {
        NSRect(x: 38, y: 12, width: max(10, bounds.width - 38 - 14), height: max(10, bounds.height - 12 - 24))
    }

    private func x(_ celsius: Double) -> CGFloat {
        plot.minX + CGFloat((celsius - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)) * plot.width
    }

    private func y(_ percent: Double) -> CGFloat { plot.maxY - CGFloat(percent / 100) * plot.height }

    private func location(_ point: FanCurve.Point) -> NSPoint { NSPoint(x: x(point.celsius), y: y(point.percent)) }

    /// The temperature and speed under a point in the view, rounded to whole degrees and percent.
    private func value(at point: NSPoint) -> FanCurve.Point {
        let span = Self.range.upperBound - Self.range.lowerBound
        let celsius = Self.range.lowerBound + Double((point.x - plot.minX) / plot.width) * span
        let percent = Double((plot.maxY - point.y) / plot.height) * 100
        return FanCurve.Point(min(max(celsius.rounded(), Self.range.lowerBound), Self.range.upperBound), min(max(percent.rounded(), 0), 100))
    }

    private func percent(at celsius: Double) -> Double {
        FanCurve(name: "", points: points).percent(at: celsius)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let plot = self.plot
        let dark = A2.drawingDark

        // Past the overheat line the helper runs the fans flat out, whatever the curve says.
        let hot = x(FanEngine.overheatCelsius)
        A2.bad.withAlphaComponent(dark ? 0.1 : 0.06).setFill()
        NSRect(x: hot, y: plot.minY, width: plot.maxX - hot, height: plot.height).fill()
        let hotLabel = "Full speed"
        if plot.maxX - hot >= A2.width(hotLabel, Self.labelFont) + 8 {
            A2.draw(hotLabel, at: hot + 4, mid: plot.maxY - 9, font: Self.labelFont, color: A2.bad)
        }

        context.saveGState()
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 4])
        for percent in [0.0, 50, 100] {
            let lineY = floor(y(percent)) + 0.5
            context.move(to: CGPoint(x: plot.minX, y: lineY))
            context.addLine(to: CGPoint(x: plot.maxX, y: lineY))
        }
        context.strokePath()
        context.restoreGState()
        for percent in [0.0, 50, 100] {
            let text = "\(Int(percent))%"
            A2.draw(text, at: plot.minX - 8 - A2.width(text, Self.labelFont), mid: y(percent), font: Self.labelFont, color: A2.gridLabel)
        }
        let step = plot.width < 360 ? 20.0 : 10.0
        for celsius in stride(from: Self.range.lowerBound, through: Self.range.upperBound, by: step) {
            let text = Format.celsius(celsius)
            let width = A2.width(text, Self.labelFont)
            let left = min(max(x(celsius) - width / 2, plot.minX - 4), bounds.width - width)
            A2.draw(text, at: left, mid: plot.maxY + 13, font: Self.labelFont, color: A2.gridLabel)
        }

        guard let first = points.first, let last = points.last else { return }
        var line = [CGPoint(x: plot.minX, y: y(first.percent))]
        line += points.map { location($0) }
        line.append(CGPoint(x: plot.maxX, y: y(last.percent)))
        let area = CGMutablePath()
        area.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        line.forEach { area.addLine(to: $0) }
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        area.closeSubpath()
        A2.fade(area, color: color, alpha: dark ? 0.32 : 0.2, from: plot.minY, to: plot.maxY, in: context)
        context.setStrokeColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.addLines(between: line)
        context.strokePath()

        drawReading(plot)

        for (index, point) in points.enumerated() {
            let center = location(point)
            let faded = removing && index == dragging
            let picked = index == selected
            var radius = Self.handle + (index == hovered || index == dragging ? 1 : 0)
            if picked {
                radius += 0.5
                color.withAlphaComponent(faded ? 0.1 : 0.22).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - radius - 4, y: center.y - radius - 4, width: (radius + 4) * 2, height: (radius + 4) * 2)).fill()
            }
            let circle = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            (picked ? color : Theme.card).withAlphaComponent(faded ? 0.4 : 1).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            (picked ? Theme.card : color).withAlphaComponent(faded ? 0.4 : 1).setStroke()
            ring.stroke()
        }

        if let index = dragging ?? (window?.firstResponder === self ? selected : nil), points.indices.contains(index) {
            let point = points[index]
            let text = removing ? "Let go to remove" : "\(Format.celsius(point.celsius)) · \(Int(point.percent))%"
            drawTag(text, near: location(point), in: plot)
        }
    }

    /// The current reading: a dashed line at its temperature, a dot where it meets the
    /// curve and the speed there.
    private func drawReading(_ plot: NSRect) {
        guard let celsius else { return }
        let lineX = min(max(x(celsius), plot.minX), plot.maxX).rounded() + 0.5
        let guide = NSBezierPath()
        guide.move(to: NSPoint(x: lineX, y: plot.minY))
        guide.line(to: NSPoint(x: lineX, y: plot.maxY))
        guide.setLineDash([3, 3], count: 2, phase: 0)
        guide.lineWidth = 1
        A2.secondary.setStroke()
        guide.stroke()
        let speed = overheated ? 100 : percent(at: celsius)
        let dot = NSPoint(x: lineX, y: y(speed))
        A2.power.setFill()
        NSBezierPath(ovalIn: NSRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)).fill()
        Theme.card.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9))
        ring.lineWidth = 1.5
        ring.stroke()
        let text = "Now \(Format.celsius(celsius)) · " + (overheated ? "full speed" : speed <= 0 ? "macOS" : "\(Int(speed.rounded()))%")
        let font = Theme.digits(11, .semibold)
        let width = A2.width(text, font)
        // Beside the line on whichever side has room, level with the top of the plot.
        let left = lineX + 6 + width <= plot.maxX ? lineX + 6 : lineX - 6 - width
        Theme.card.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: left - 3, y: plot.minY + 1, width: width + 6, height: 16), xRadius: 4, yRadius: 4).fill()
        A2.draw(text, at: left, mid: plot.minY + 9, font: font, color: overheated ? A2.bad : A2.primary)
    }

    /// The dark value tag over a point being moved, kept inside the chart.
    private func drawTag(_ text: String, near anchor: NSPoint, in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.tagFont, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = NSRect(x: anchor.x - (size.width + 16) / 2, y: anchor.y - 14 - 22, width: size.width + 16, height: 22)
        if box.minY < 0 { box.origin.y = anchor.y + 14 }
        box.origin.x = min(max(0, box.minX), bounds.width - box.width)
        Theme.tooltip.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
    }

    // MARK: Editing

    private func index(at point: NSPoint) -> Int? {
        var best: (Int, CGFloat)?
        for (index, value) in points.enumerated() {
            let distance = hypot(location(value).x - point.x, location(value).y - point.y)
            if distance <= Self.reach, distance < (best?.1 ?? .infinity) { best = (index, distance) }
        }
        return best?.0
    }

    private func commit(_ next: [FanCurve.Point]) {
        points = next
        onChange?(next)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Moves a point, kept a degree clear of its neighbours so the order never changes.
    private func move(_ index: Int, to target: FanCurve.Point) {
        guard points.indices.contains(index) else { return }
        let low = index > 0 ? points[index - 1].celsius + 1 : Self.range.lowerBound
        let high = index < points.count - 1 ? points[index + 1].celsius - 1 : Self.range.upperBound
        var next = points
        next[index] = FanCurve.Point(min(max(target.celsius, low), high), min(max(target.percent, 0), 100))
        guard next != points else { return }
        commit(next)
    }

    /// Adds a point, unless one is already at that degree. Returns its index.
    @discardableResult
    private func add(_ point: FanCurve.Point) -> Int? {
        guard !points.contains(where: { Int($0.celsius.rounded()) == Int(point.celsius.rounded()) }) else { return nil }
        let next = (points + [point]).sorted { $0.celsius < $1.celsius }
        commit(next)
        let index = next.firstIndex(of: point)
        selected = index
        return index
    }

    private func remove(_ index: Int) {
        guard points.count > Self.minimumPoints, points.indices.contains(index) else { return NSSound.beep() }
        var next = points
        next.remove(at: index)
        selected = next.isEmpty ? nil : min(index, next.count - 1)
        commit(next)
    }

    /// A point halfway to the next one, or before the first when the last is picked.
    private func addAfter(_ index: Int?) {
        guard !points.isEmpty else { return }
        let from = index ?? 0
        let to = from < points.count - 1 ? from + 1 : from - 1
        guard points.indices.contains(to) else { return }
        let a = points[min(from, to)], b = points[max(from, to)]
        let celsius = ((a.celsius + b.celsius) / 2).rounded(.down)
        guard celsius > a.celsius, celsius < b.celsius else { return NSSound.beep() }
        add(FanCurve.Point(celsius, ((a.percent + b.percent) / 2).rounded()))
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let index = index(at: point) {
            selected = index
            dragging = index
            NSCursor.closedHand.push()
            needsDisplay = true
        } else if event.clickCount == 2, plot.insetBy(dx: -4, dy: -4).contains(point) {
            add(value(at: point))
        } else {
            selected = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let off = !plot.insetBy(dx: -Self.tearOff, dy: -Self.tearOff).contains(point)
        removing = off && points.count > Self.minimumPoints
        if !removing { move(index, to: value(at: point)) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = dragging else { return }
        NSCursor.pop()
        dragging = nil
        if removing {
            removing = false
            remove(index)
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = index(at: convert(event.locationInWindow, from: nil))
        (hovered == nil ? NSCursor.arrow : NSCursor.openHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { NSCursor.arrow.set() }
        hovered = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let index = index(at: point) {
            selected = index
            let delete = ActionItem("Delete Point") { [weak self] in self?.remove(index) }
            delete.isEnabled = points.count > Self.minimumPoints
            menu.addItem(delete)
        } else if plot.contains(point) {
            let value = value(at: point)
            let add = ActionItem("Add Point at \(Format.celsius(value.celsius))") { [weak self] in self?.add(value) }
            add.isEnabled = !points.contains { Int($0.celsius.rounded()) == Int(value.celsius.rounded()) }
            menu.addItem(add)
        } else {
            return nil
        }
        return menu
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { !points.isEmpty }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if selected == nil, !points.isEmpty {
            let backwards = window?.keyViewSelectionDirection == .selectingPrevious
            selected = backwards ? points.count - 1 : 0
        }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        let big = event.modifierFlags.contains(.shift)
        let step: Double = big ? 5 : 1
        switch event.keyCode {
        case 123, 124, 125, 126:
            guard let index = selected, points.indices.contains(index) else { return }
            let point = points[index]
            switch event.keyCode {
            case 123: move(index, to: FanCurve.Point(point.celsius - step, point.percent))
            case 124: move(index, to: FanCurve.Point(point.celsius + step, point.percent))
            case 125: move(index, to: FanCurve.Point(point.celsius, point.percent - step))
            default: move(index, to: FanCurve.Point(point.celsius, point.percent + step))
            }
        case 48:
            // Tab walks the points, then leaves the chart at either end.
            let next = (selected ?? (big ? points.count : -1)) + (big ? -1 : 1)
            if points.indices.contains(next) { selected = next } else { super.keyDown(with: event) }
        case 51, 117:
            if let selected { remove(selected) }
        default:
            if ["+", "="].contains(event.charactersIgnoringModifiers) { addAfter(selected) } else { super.keyDown(with: event) }
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: plot.insetBy(dx: -6, dy: -6), xRadius: 8, yRadius: 8).fill()
    }

    // MARK: Accessibility

    private final class PointElement: NSAccessibilityElement {
        weak var owner: FanCurveChart?
        var index = 0

        override func accessibilityFrameInParentSpace() -> NSRect {
            MainActor.assumeIsolated {
                guard let owner, owner.points.indices.contains(index) else { return .zero }
                let center = owner.location(owner.points[index])
                return NSRect(x: center.x - 10, y: owner.bounds.height - center.y - 10, width: 20, height: 20)
            }
        }

        override func accessibilityPerformIncrement() -> Bool { nudge(0, 1) }
        override func accessibilityPerformDecrement() -> Bool { nudge(0, -1) }

        func nudge(_ celsius: Double, _ percent: Double) -> Bool {
            MainActor.assumeIsolated {
                guard let owner, owner.points.indices.contains(index) else { return false }
                let point = owner.points[index]
                owner.selected = index
                owner.move(index, to: FanCurve.Point(point.celsius + celsius, point.percent + percent))
                return true
            }
        }

        override func isAccessibilityFocused() -> Bool { MainActor.assumeIsolated { owner?.selected == index } }
        override func setAccessibilityFocused(_ focused: Bool) {
            MainActor.assumeIsolated { if focused { owner?.selected = index } }
        }
    }

    private var elements: [PointElement] = []

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Fan curve" }
    override func accessibilityHelp() -> String? {
        "Each point sets the fan speed at a temperature. Tab moves between points, arrow keys move one, Delete removes it, plus adds one."
    }
    override func accessibilityValue() -> Any? {
        var parts = points.map { "\(Format.celsius($0.celsius)) \(Int($0.percent))%" }
        if let celsius { parts.append("now \(Format.celsius(celsius)), " + (overheated ? "full speed" : "\(Int(percent(at: celsius).rounded()))%")) }
        return parts.joined(separator: ", ")
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Add point") { [weak self] in
            guard let self else { return false }
            self.addAfter(self.selected)
            return true
        }]
    }

    override func accessibilityChildren() -> [Any]? {
        while elements.count < points.count {
            let element = PointElement()
            element.owner = self
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.slider)
            elements.append(element)
        }
        return points.indices.map { index -> PointElement in
            let element = elements[index]
            let point = points[index]
            element.index = index
            element.setAccessibilityLabel("Point \(index + 1) of \(points.count), \(Format.celsius(point.celsius))")
            element.setAccessibilityValue("\(Int(point.percent))%")
            element.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Hotter") { [weak element] in element?.nudge(1, 0) ?? false },
                NSAccessibilityCustomAction(name: "Cooler") { [weak element] in element?.nudge(-1, 0) ?? false },
                NSAccessibilityCustomAction(name: "Delete point") { [weak self] in
                    guard let self, self.points.count > Self.minimumPoints else { return false }
                    self.remove(index)
                    return true
                },
            ])
            return element
        }
    }
}
