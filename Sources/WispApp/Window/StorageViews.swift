import AppKit
import WispCore

extension StorageCategory {
    var color: NSColor {
        switch self {
        case .apps: return Theme.blue
        case .developer: return Theme.indigo
        case .documents: return Theme.orange
        case .mail: return Theme.green
        case .system: return Theme.gray
        case .snapshots: return Theme.purple
        case .purgeable: return Theme.dynamic(0xD1D1D6, 0x48484A)
        case .free: return Theme.track
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2.fill"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .documents: return "doc.fill"
        case .mail: return "envelope.fill"
        case .system: return "gearshape.2.fill"
        case .snapshots: return "clock.arrow.circlepath"
        case .purgeable: return "arrow.3.trianglepath"
        case .free: return "circle.dashed"
        }
    }
}

/// The whole disk as one bar, a slice per kind. Clicking a slice picks it; the
/// rest fade so the picked one stands out. Hover shows the size and share.
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
        let frames = frames()
        if frames.isEmpty {
            Theme.track.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            return
        }
        for (category, rect) in frames {
            let faded = (selected != nil && selected != category) || (selected == nil && hovered != nil && hovered != category)
            category.color.withAlphaComponent(faded ? 0.3 : 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if category == .free {
                Theme.cardBorder.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                outline.lineWidth = 1
                outline.stroke()
            }
        }
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
/// picks it like clicking its slice.
final class DiskLegend: BitmapView {
    struct Item: Equatable {
        var category: StorageCategory
        var value: String
    }

    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var selected: StorageCategory? { didSet { if selected != oldValue { needsDisplay = true } } }
    var onPick: ((StorageCategory?) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    static let rowHeight: CGFloat = 40

    private var columns: Int { bounds.width < 560 ? 2 : 4 }
    var naturalHeight: CGFloat { CGFloat((items.count + 3) / 4) * Self.rowHeight }
    func naturalHeight(width: CGFloat) -> CGFloat {
        let columns = width < 560 ? 2 : 4
        return CGFloat((items.count + columns - 1) / columns) * Self.rowHeight
    }

    private func frame(_ index: Int) -> NSRect {
        let width = bounds.width / CGFloat(columns)
        return NSRect(x: CGFloat(index % columns) * width, y: CGFloat(index / columns) * Self.rowHeight, width: width, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in items.enumerated() {
            let rect = frame(index)
            let faded = selected != nil && selected != item.category
            if index == hovered {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -6, dy: 2).offsetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
            }
            let alpha: CGFloat = faded ? 0.4 : 1
            (item.category == .free ? Theme.inkTertiary : item.category.color).withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.minY + 9, width: 8, height: 8)).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (item.category.title as NSString).draw(with: NSRect(x: rect.minX + 14, y: rect.minY + 5, width: rect.width - 22, height: 16),
                                                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                   attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary.withAlphaComponent(alpha),
                                                                .paragraphStyle: paragraph])
            (item.value as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 21),
                                          withAttributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink.withAlphaComponent(alpha)])
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
    private static let font = Theme.sans(14, .semibold)
    private static let separator = "  ›  "

    private func frames() -> [NSRect] {
        var x: CGFloat = 0
        var result: [NSRect] = []
        let separatorWidth = (Self.separator as NSString).size(withAttributes: [.font: Self.font]).width
        // Long paths keep their last parts; the first ones shrink to an ellipsis.
        let widths = parts.map { min(220, ceil(($0 as NSString).size(withAttributes: [.font: Self.font]).width)) }
        for width in widths {
            result.append(NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + separatorWidth
        }
        let overflow = (result.last?.maxX ?? 0) - bounds.width
        if overflow > 0 { return result.map { $0.offsetBy(dx: -overflow, dy: 0) } }
        return result
    }

    var naturalWidth: CGFloat { frames().last.map { $0.maxX - (frames().first?.minX ?? 0) } ?? 0 }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, rect) in frames().enumerated() where rect.maxX > 0 {
            let last = index == parts.count - 1
            let color = last ? Theme.ink : (index == hovered ? Theme.accent : Theme.inkSecondary)
            (parts[index] as NSString).draw(with: NSRect(x: rect.minX, y: (bounds.height - 18) / 2, width: rect.width, height: 18),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph])
            if !last {
                (Self.separator as NSString).draw(at: NSPoint(x: rect.maxX, y: (bounds.height - 18) / 2),
                                                  withAttributes: [.font: Self.font, .foregroundColor: Theme.inkTertiary])
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

/// A list of places with a size bar, drawn in one view: an icon, the name, a quiet
/// line under it, the bar and the size. Rows that lead somewhere answer the pointer.
final class StorageList: BitmapView {
    struct Row: Equatable {
        var id: String
        var name: String
        var note: String
        var value: String
        var fraction: Double
        var symbol: String
        var tint: NSColor
        var opens: Bool
        var faint = false
        var bar = true
        /// A folder Finder can show.
        var path: String?
    }

    var rows: [Row] = [] { didSet { if rows != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var onOpen: ((Row) -> Void)?
    static let rowHeight: CGFloat = 46
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for row in [hovered, oldValue].compactMap({ $0 }) { setNeedsDisplay(rect(row)) }
        }
    }

    var naturalHeight: CGFloat { CGFloat(rows.count) * Self.rowHeight }

    private func rect(_ index: Int) -> NSRect { NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int(dirtyRect.minY / Self.rowHeight))
        let last = min(rows.count, Int(dirtyRect.maxY / Self.rowHeight) + 1)
        guard first < last else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let valueWidth: CGFloat = 76
        for index in first..<last {
            let row = rows[index]
            let barWidth: CGFloat = row.bar ? min(160, bounds.width * 0.18) : -12
            let frame = rect(index)
            if index == hovered, row.opens || row.path != nil {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: -8, dy: 2), xRadius: 8, yRadius: 8).fill()
            }
            IconTile.glyph(row.symbol, tint: row.faint ? Theme.inkTertiary : row.tint, size: 16, appearance: effectiveAppearance)
                .draw(in: NSRect(x: frame.minX + 2, y: frame.minY + 15, width: 16, height: 16), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            let textX = frame.minX + 30
            let textWidth = bounds.width - textX - valueWidth - barWidth - 40
            (row.name as NSString).draw(with: NSRect(x: textX, y: frame.minY + (row.note.isEmpty ? 14 : 6), width: textWidth, height: 18),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: Theme.sans(13), .foregroundColor: row.faint ? Theme.inkSecondary : Theme.ink,
                                                     .paragraphStyle: paragraph])
            if !row.note.isEmpty {
                (row.note as NSString).draw(with: NSRect(x: textX, y: frame.minY + 25, width: textWidth, height: 16),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.inkSecondary, .paragraphStyle: paragraph])
            }
            // The chevron's room is kept on every row so sizes and bars line up.
            let right = bounds.width - (rows.contains(where: \.opens) ? 20 : 0)
            let barX = right - valueWidth - barWidth - 12
            if row.bar {
                let bar = NSRect(x: barX, y: frame.midY - 2, width: barWidth, height: 4)
                Theme.track.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
                if row.fraction > 0 {
                    row.tint.setFill()
                    var filled = bar
                    filled.size.width = max(3, bar.width * CGFloat(min(1, row.fraction)))
                    NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
                }
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(13, .medium),
                                                             .foregroundColor: row.faint || row.value == "–" ? Theme.inkSecondary : Theme.ink]
            let size = (row.value as NSString).size(withAttributes: attributes)
            (row.value as NSString).draw(at: NSPoint(x: right - size.width, y: frame.midY - size.height / 2), withAttributes: attributes)
            if row.opens {
                IconTile.glyph("chevron.right", tint: Theme.inkTertiary, size: 10, appearance: effectiveAppearance)
                    .draw(in: NSRect(x: bounds.width - 10, y: frame.midY - 5, width: 10, height: 10), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
            }
            if index < rows.count - 1 {
                Theme.rule.setFill()
                NSRect(x: textX, y: frame.maxY - 0.5, width: bounds.width - textX, height: 0.5).fill()
            }
        }
    }

    private func index(at point: NSPoint) -> Int? {
        let index = Int(point.y / Self.rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), rows[index].opens else { return }
        onOpen?(rows[index])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), let path = rows[index].path else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
        menu.addItem(ActionItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        return menu
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityValue() -> Any? { rows.prefix(12).map { "\($0.name) \($0.value)" }.joined(separator: "; ") }
}

/// Free space over the last 30 days, one reading an hour, with the biggest drops
/// marked and named by what grew.
final class SpaceChart: BitmapView {
    struct Mark: Equatable {
        var index: Int
        var label: String
    }

    /// Free bytes per hour, NaN where nothing was recorded.
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var capacity: Double = 1
    var tint: NSColor = Theme.accent
    private var hoverIndex: Int?

    private var plot: NSRect { NSRect(x: 0, y: 8, width: bounds.width - 52, height: bounds.height - 34) }

    override func draw(_ dirtyRect: NSRect) {
        let known = values.enumerated().filter { !$0.element.isNaN }
        // A few hours of readings are a sliver at the right edge; wait for more.
        guard known.count >= 6 else {
            let text = Theme.caption("Wisp records free space once an hour; the chart fills in over the next days", size: 9.5)
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }
        let rect = plot
        let low = known.map(\.element).min() ?? 0, high = known.map(\.element).max() ?? 1
        let pad = max((high - low) * 0.15, capacity * 0.01)
        let bottom = max(0, low - pad), top = high + pad
        func y(_ value: Double) -> CGFloat { rect.maxY - CGFloat((value - bottom) / max(top - bottom, 1)) * rect.height }
        let dx = rect.width / CGFloat(max(values.count - 1, 1))
        let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        for fraction: CGFloat in [0, 0.5, 1] {
            let lineY = rect.maxY - fraction * rect.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: lineY + 0.5))
            path.line(to: NSPoint(x: rect.maxX, y: lineY + 0.5))
            if fraction > 0 { path.setLineDash([2, 3], count: 2, phase: 0) }
            Theme.rule.setStroke()
            path.stroke()
            (Format.bytes(bottom + (top - bottom) * Double(fraction)) as NSString)
                .draw(at: NSPoint(x: rect.maxX + 6, y: lineY - 7), withAttributes: [.font: axisFont, .foregroundColor: Theme.inkSecondary])
        }
        var segment: [NSPoint] = []
        func flush() {
            defer { segment.removeAll() }
            guard segment.count > 1 else { return }
            let line = NSBezierPath()
            line.move(to: segment[0])
            segment.dropFirst().forEach { line.line(to: $0) }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: segment.last!.x, y: rect.maxY))
            area.line(to: NSPoint(x: segment[0].x, y: rect.maxY))
            area.close()
            tint.withAlphaComponent(0.1).setFill()
            area.fill()
            tint.setStroke()
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.stroke()
        }
        for (index, value) in values.enumerated() {
            if value.isNaN { flush(); continue }
            segment.append(NSPoint(x: rect.minX + CGFloat(index) * dx, y: y(value)))
        }
        flush()
        // Drops: a dot on the line and what grew, above it.
        var lastLabelEnd: CGFloat = -1000
        for mark in marks where values.indices.contains(mark.index) && !values[mark.index].isNaN {
            let point = NSPoint(x: rect.minX + CGFloat(mark.index) * dx, y: y(values[mark.index]))
            Theme.card.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            Theme.warn.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
            ring.lineWidth = 2
            ring.stroke()
            let text = NSAttributedString(string: mark.label, attributes: [.font: Theme.sans(11, .medium), .foregroundColor: Theme.ink])
            let size = text.size()
            var x = min(max(rect.minX, point.x - size.width / 2), rect.maxX - size.width)
            if x < lastLabelEnd + 8 { x = lastLabelEnd + 8 }
            guard x + size.width <= rect.maxX + 40 else { continue }
            text.draw(at: NSPoint(x: x, y: max(rect.minY - 6, point.y - 24)))
            lastLabelEnd = x + size.width
        }
        let oldest = Theme.caption("30 days ago", size: 9)
        oldest.draw(at: NSPoint(x: rect.minX, y: rect.maxY + 8))
        let now = Theme.caption("Now", size: 9)
        now.draw(at: NSPoint(x: rect.maxX - now.size().width, y: rect.maxY + 8))

        if let index = hoverIndex, values.indices.contains(index), !values[index].isNaN {
            let x = rect.minX + CGFloat(index) * dx
            Theme.inkTertiary.withAlphaComponent(0.5).setFill()
            NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
            let hours = values.count - 1 - index
            let when = hours < 24 ? "\(hours) h ago" : "\(hours / 24) d ago"
            let text = "\(when)   \(Format.bytes(values[index])) free" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            var box = NSRect(x: x + 8, y: rect.minY, width: size.width + 16, height: 22)
            if box.maxX > rect.maxX { box.origin.x = x - 8 - box.width }
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
        let index = min(max(0, Int(((x - plot.minX) / plot.width * CGFloat(values.count - 1)).rounded())), values.count - 1)
        if index != hoverIndex {
            hoverIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Free space, last 30 days" }
}
