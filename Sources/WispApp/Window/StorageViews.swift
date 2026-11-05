import AppKit
import WispCore

extension StorageCategory {
    var color: NSColor {
        switch self {
        case .apps: return A2.diskApps
        case .developer: return A2.diskDeveloper
        case .documents: return A2.diskDocuments
        case .mail: return Theme.dynamic(0x34C759, 0x30D158)
        case .system: return A2.diskSystem
        case .snapshots: return Theme.dynamic(0xAF52DE, 0xBF5AF2)
        case .purgeable: return Theme.dynamic(0xD1D1D6, 0x48484A)
        case .free: return A2.track
        }
    }

    /// The outline symbol on the kind's rows.
    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .documents: return "doc"
        case .mail: return "envelope"
        case .system: return "gearshape.2"
        case .snapshots: return "clock.arrow.circlepath"
        case .purgeable: return "arrow.3.trianglepath"
        case .free: return "circle.dashed"
        }
    }
}

/// The whole disk as one 14 pt bar, a slice per kind with 2 pt gaps. Clicking a slice
/// picks it; the rest fade so the picked one stands out. Hover shows the size and share.
final class DiskBar: BitmapView {
    struct Slice: Equatable {
        var category: StorageCategory
        var size: UInt64
    }

    var slices: [Slice] = [] { didSet { if slices != oldValue { needsDisplay = true } } }
    var selected: StorageCategory? { didSet { if selected != oldValue { needsDisplay = true } } }
    var onPick: ((StorageCategory?) -> Void)?
    var onHover: ((StorageCategory?, NSRect) -> Void)?
    private var hovered: StorageCategory? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private let gap: CGFloat = 2

    private func frames() -> [(StorageCategory, NSRect)] {
        let total = Double(slices.reduce(0) { $0 + $1.size })
        guard total > 0 else { return [] }
        let shown = slices.filter { $0.size > 0 }
        let room = bounds.width - gap * CGFloat(max(0, shown.count - 1))
        // Every slice gets at least a sliver so small ones stay clickable; the free part gives way.
        var widths = shown.map { max(4, room * CGFloat(Double($0.size) / total)) }
        let excess = widths.reduce(0, +) - room
        if excess > 0, let free = shown.firstIndex(where: { $0.category == .free }) { widths[free] = max(4, widths[free] - excess) }
        var x: CGFloat = 0
        return zip(shown, widths).map { slice, width in
            defer { x += width + gap }
            return (slice.category, NSRect(x: x, y: 0, width: width, height: bounds.height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).addClip()
        let frames = frames()
        if frames.isEmpty {
            A2.track.setFill()
            bounds.fill()
        }
        let focus = selected ?? hovered
        for (category, rect) in frames {
            let faded = focus != nil && focus != category && category != .free
            (faded ? category.color.withAlphaComponent(0.38) : category.color).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func category(at point: NSPoint) -> (StorageCategory, NSRect)? {
        frames().first { $0.1.insetBy(dx: -gap / 2, dy: -4).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = category(at: convert(event.locationInWindow, from: nil))
        hovered = hit?.0
        onHover?(hit?.0, hit?.1 ?? .zero)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        onHover?(nil, .zero)
    }

    override func mouseUp(with event: NSEvent) {
        guard let hit = category(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(hit.0 == selected ? nil : hit.0)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Startup disk" }
    override func accessibilityValue() -> Any? {
        slices.map { "\($0.category.title) \(Format.bytes($0.size))" }.joined(separator: ", ")
    }
}

/// The bar's key: a dot, the kind and its size, four to a row. Clicking an item
/// picks it like clicking its slice; the picked one sits on a light wash. The view
/// reaches 8 pt past the card's padding on each side so the wash lines up with it.
final class DiskLegend: BitmapView {
    struct Item: Equatable {
        var category: StorageCategory
        var value: String
    }

    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var selected: StorageCategory? { didSet { if selected != oldValue { needsDisplay = true } } }
    var onPick: ((StorageCategory?) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    static let itemHeight: CGFloat = 44
    static let rowGap: CGFloat = 2
    static let inset: CGFloat = 8
    private static let columnGap: CGFloat = 12
    private static let labelFont = Theme.sans(11.5)
    private static let valueFont = Theme.digits(13, .semibold)
    private static let wash = A2.dynamic(Theme.hex(0x007AFF, alpha: 0.07), NSColor(white: 1, alpha: 0.07))

    /// The most columns, up to four, in which every label and value fits on one line.
    private func columns(_ width: CGFloat) -> Int {
        let widest = items.map { item in
            max((item.category.title as NSString).size(withAttributes: [.font: Self.labelFont]).width,
                (item.value as NSString).size(withAttributes: [.font: Self.valueFont]).width)
        }.max() ?? 0
        let needed = ceil(widest) + 14 + Self.inset * 2
        return [4, 3].first { (width - Self.columnGap * CGFloat($0 - 1)) / CGFloat($0) >= needed } ?? 2
    }
    private var columns: Int { columns(bounds.width) }

    /// The height for `width`, the width of the card's content.
    func naturalHeight(width: CGFloat) -> CGFloat {
        let columns = columns(width + Self.inset * 2)
        let rows = (items.count + columns - 1) / columns
        return rows == 0 ? 0 : CGFloat(rows) * Self.itemHeight + CGFloat(rows - 1) * Self.rowGap
    }

    private func frame(_ index: Int) -> NSRect {
        let width = (bounds.width - Self.columnGap * CGFloat(columns - 1)) / CGFloat(columns)
        return NSRect(x: CGFloat(index % columns) * (width + Self.columnGap), y: CGFloat(index / columns) * (Self.itemHeight + Self.rowGap),
                      width: width, height: Self.itemHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        for (index, item) in items.enumerated() {
            let rect = frame(index)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
            if item.category == selected {
                Self.wash.setFill()
                shape.fill()
                A2.hairline.setStroke()
                shape.lineWidth = 0.5
                shape.stroke()
            } else if index == hovered {
                A2.rowHover.setFill()
                shape.fill()
            }
            let x = rect.minX + Self.inset
            let labelLine = Self.labelFont.ascender - Self.labelFont.descender
            let labelY = rect.minY + 5
            (item.category == .free ? A2.tertiary : item.category.color).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: labelY + labelLine / 2 - 4, width: 8, height: 8)).fill()
            (item.category.title as NSString).draw(with: NSRect(x: x + 14, y: labelY, width: rect.width - Self.inset * 2 - 14, height: ceil(labelLine)),
                                                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                   attributes: [.font: Self.labelFont, .foregroundColor: A2.secondary, .paragraphStyle: truncating])
            (item.value as NSString).draw(with: NSRect(x: x + 14, y: labelY + labelLine + 3, width: rect.width - Self.inset * 2 - 14, height: 17),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: [.font: Self.valueFont, .foregroundColor: A2.primary, .paragraphStyle: truncating])
        }
    }

    private func index(at point: NSPoint) -> Int? { items.indices.first { frame($0).contains(point) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let category = items[index].category
        onPick?(category == selected ? nil : category)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Kinds of storage" }
    override func accessibilityValue() -> Any? { items.map { "\($0.category.title) \($0.value)" }.joined(separator: ", ") }
}

/// "This Mac › Home › Library": earlier parts are links back up.
final class Breadcrumb: BitmapView {
    var parts: [String] = [] { didSet { if parts != oldValue { needsDisplay = true } } }
    var onPick: ((Int) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let currentFont = Theme.sans(14, .semibold)
    private static let font = Theme.sans(14, .medium)
    private static let separator = "›"
    private static let spacing: CGFloat = 8

    private func font(_ index: Int) -> NSFont { index == parts.count - 1 ? Self.currentFont : Self.font }

    private func frames() -> [NSRect] {
        var x: CGFloat = 0
        var result: [NSRect] = []
        let separatorWidth = ceil((Self.separator as NSString).size(withAttributes: [.font: Self.font]).width) + Self.spacing * 2
        // Long paths keep their last parts; the first ones shrink to an ellipsis.
        let widths = parts.indices.map { min(220, ceil((parts[$0] as NSString).size(withAttributes: [.font: font($0)]).width)) }
        for width in widths {
            result.append(NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + separatorWidth
        }
        let overflow = (result.last?.maxX ?? 0) - bounds.width
        if overflow > 0 { return result.map { $0.offsetBy(dx: -overflow, dy: 0) } }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, rect) in frames().enumerated() where rect.maxX > 0 {
            let last = index == parts.count - 1
            let color = last ? A2.primary : (index == hovered ? A2.pillText : A2.secondary)
            let font = font(index)
            let y = (bounds.height - (font.ascender - font.descender)) / 2
            (parts[index] as NSString).draw(with: NSRect(x: rect.minX, y: y, width: rect.width, height: 18),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            if !last {
                (Self.separator as NSString).draw(at: NSPoint(x: rect.maxX + Self.spacing, y: y),
                                                  withAttributes: [.font: Self.font, .foregroundColor: A2.tertiary])
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func index(at point: NSPoint) -> Int? {
        frames().enumerated().first { $0.element.contains(point) && $0.offset < parts.count - 1 }?.offset
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseUp(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) { onPick?(index) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { parts.joined(separator: ", ") }
}

/// Free space over the last 30 days, one reading an hour, edge to edge on the card's
/// floor. The biggest drops are marked with a dotted line and what grew.
final class SpaceChart: BitmapView {
    struct Mark: Equatable {
        var index: Int
        var label: String
    }

    /// Free bytes per hour, NaN where nothing was recorded.
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var capacity: Double = 1
    var tint: NSColor = A2.up
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }

    private var dx: CGFloat { bounds.width / CGFloat(max(values.count - 1, 1)) }

    private func scale(_ known: [Double]) -> (Double) -> CGFloat {
        let low = known.min() ?? 0, high = known.max() ?? 1
        let pad = max((high - low) * 0.15, capacity * 0.005)
        let bottom = max(0, low - pad), top = high + pad
        let height = bounds.height
        return { value in height - CGFloat((value - bottom) / max(top - bottom, 1)) * height }
    }

    override func draw(_ dirtyRect: NSRect) {
        let known = values.filter { !$0.isNaN }
        // A few hours of readings are a sliver at the right edge; wait for more.
        guard known.count >= 6, let context = NSGraphicsContext.current?.cgContext else {
            let text = A2.plain("Wisp records free space once an hour; the chart fills in over the next days")
            let size = text.size()
            text.draw(at: NSPoint(x: max(A2.padSide, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2))
            return
        }
        let y = scale(known)
        let dx = dx
        let font = Theme.digits(10)
        let axis: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.gridLabel]
        context.saveGState()
        context.addPath(A2.bottomRounded(bounds))
        context.clip()
        // Drops first, under the line: a dotted rule from near the top to the floor.
        context.setStrokeColor((A2.gridLabel.usingColorSpace(.sRGB) ?? A2.gridLabel).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 3])
        for mark in marks where values.indices.contains(mark.index) {
            let x = (CGFloat(mark.index) * dx).rounded() + 0.5
            context.move(to: CGPoint(x: x, y: 8))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        let runs = A2.runs(values.map { Float($0) }, x: { CGFloat($0) * dx }, y: { y(Double($0)) })
        let alpha: CGFloat = A2.drawingDark ? 0.32 : 0.2
        for run in runs {
            let area = CGMutablePath()
            area.move(to: CGPoint(x: run[0].x, y: bounds.height))
            run.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: run[run.count - 1].x, y: bounds.height))
            area.closeSubpath()
            A2.fade(area, color: tint, alpha: alpha, from: run.map(\.y).min() ?? 0, to: bounds.height, in: context)
        }
        context.setStrokeColor((tint.usingColorSpace(.sRGB) ?? tint).cgColor)
        context.setLineWidth(1.8)
        context.setLineJoin(.round)
        for run in runs {
            context.addLines(between: run)
            context.strokePath()
        }
        context.restoreGState()
        // What grew, to the left of each drop's rule, never over another label.
        let rules = marks.filter { values.indices.contains($0.index) }.map { CGFloat($0.index) * dx }
        var taken: [ClosedRange<CGFloat>] = []
        for (mark, x) in zip(marks.filter { values.indices.contains($0.index) }, rules) {
            let width = ceil((mark.label as NSString).size(withAttributes: axis).width)
            // Left of its rule, else right of it; never across another rule or label.
            let fits = { (span: ClosedRange<CGFloat>) in
                span.lowerBound >= A2.padSide && span.upperBound <= self.bounds.width - 4
                    && !rules.contains { $0 != x && span.contains($0) } && !taken.contains { $0.overlaps(span) }
            }
            guard let span = [(x - 6 - width)...(x - 6), (x + 6)...(x + 6 + width)].first(where: fits) else { continue }
            taken.append(span)
            (mark.label as NSString).draw(at: NSPoint(x: span.lowerBound, y: 16 - font.ascender), withAttributes: axis)
        }

        if let index = hoverIndex, values.indices.contains(index), !values[index].isNaN {
            let x = CGFloat(index) * dx
            A2.tertiary.setFill()
            NSRect(x: x.rounded() - 0.5, y: 0, width: 1, height: bounds.height).fill()
            let hours = values.count - 1 - index
            let when = hours < 24 ? "\(hours) h ago" : "\(hours / 24) d ago"
            let text = "\(when)   \(Format.bytes(values[index])) free" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            var box = NSRect(x: x + 8, y: 4, width: ceil(size.width) + 16, height: 22)
            if box.maxX > bounds.width - 4 { box.origin.x = x - 8 - box.width }
            Theme.tooltip.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard values.count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        hoverIndex = min(max(0, Int((x / dx).rounded())), values.count - 1)
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Free space, last 30 days" }
}
