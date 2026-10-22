import AppKit

/// Rows of small cells coloured by value, newest on the right, with the latest
/// value as a figure at the end of each row.
final class Heatmap: DrawnView {
    struct Row {
        var label: String
        var tag: String
        var values: [Float]
    }

    var rows: [Row] = [] { didSet { needsDisplay = true } }
    /// Cells per row; older samples fall off the left.
    var columns = 24
    var labelWidth: CGFloat = 46
    var valueWidth: CGFloat = 38
    var rowPitch: CGFloat = 11
    var cellGap: CGFloat = 2
    /// Reports the hovered row and column (0 is the newest), or nil when the mouse leaves.
    var onHover: ((Int, Int, NSRect)?) -> Void = { _ in }

    private var palette: [NSColor] = []
    private var paletteAppearance: NSAppearance.Name?
    private var hovered: (Int, Int)?

    var naturalHeight: CGFloat { CGFloat(rows.count) * rowPitch - cellGap }

    private var cellWidth: CGFloat {
        (bounds.width - labelWidth - valueWidth - 8 - CGFloat(columns - 1) * cellGap) / CGFloat(columns)
    }

    private func color(_ value: Float) -> NSColor {
        let name = effectiveAppearance.name
        if palette.isEmpty || paletteAppearance != name {
            palette = (0...32).map { Theme.heat(Float($0) / 32, appearance: effectiveAppearance) }
            paletteAppearance = name
        }
        return palette[Int((min(1, max(0, value)) * 32).rounded())]
    }

    func cellRect(row: Int, column: Int) -> NSRect {
        let width = cellWidth
        let x = labelWidth + CGFloat(columns - 1 - column) * (width + cellGap)
        return NSRect(x: x, y: CGFloat(row) * rowPitch, width: width, height: rowPitch - cellGap)
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelFont = Theme.mono(9, .medium)
        let tagFont = Theme.mono(9.5, .regular)
        let valueFont = Theme.figure(10)
        let width = cellWidth
        guard width > 1 else { return }
        for (rowIndex, row) in rows.enumerated() {
            let y = CGFloat(rowIndex) * rowPitch
            let height = rowPitch - cellGap
            let focused = hovered?.0 == rowIndex
            (row.label as NSString).draw(at: NSPoint(x: 0, y: y + (height - 11) / 2),
                                         withAttributes: [.font: labelFont, .foregroundColor: focused ? Theme.ink : Theme.inkSecondary])
            if !row.tag.isEmpty {
                (row.tag as NSString).draw(at: NSPoint(x: 24, y: y + (height - 12) / 2),
                                           withAttributes: [.font: tagFont, .foregroundColor: Theme.inkTertiary])
            }
            let shown = row.values.suffix(columns)
            for column in 0..<columns {
                let rect = cellRect(row: rowIndex, column: column)
                let index = shown.count - 1 - column
                if index >= 0, !shown[shown.startIndex + index].isNaN {
                    color(shown[shown.startIndex + index]).setFill()
                } else {
                    Theme.track.withAlphaComponent(0.5).setFill()
                }
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                if let hovered, hovered == (rowIndex, column) {
                    Theme.ink.setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 2.5, yRadius: 2.5)
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
            }
            if let last = shown.last, !last.isNaN {
                let text = String(format: "%.0f%%", last * 100) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: focused ? Theme.ink : Theme.inkSecondary]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: bounds.width - size.width, y: y + (height - size.height) / 2), withAttributes: attributes)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let width = cellWidth
        let row = Int(point.y / rowPitch)
        let column = columns - 1 - Int((point.x - labelWidth) / (width + cellGap))
        guard point.x >= labelWidth, rows.indices.contains(row), (0..<columns).contains(column) else { return clearHover() }
        if hovered.map({ $0 != (row, column) }) ?? true {
            hovered = (row, column)
            needsDisplay = true
            onHover((row, column, cellRect(row: row, column: column)))
        }
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    private func clearHover() {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
        onHover(nil)
    }
}

/// A gradient key for the heat scale: "0%" ticks "100%".
final class HeatKey: DrawnView {
    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.mono(9.5)
        let low = Theme.caption("0%", color: Theme.inkTertiary, size: 9.5)
        let high = Theme.caption("100%", color: Theme.inkTertiary, size: 9.5)
        let lowWidth = ceil(low.size().width), highWidth = ceil(high.size().width)
        let y = (bounds.height - (font.ascender - font.descender)) / 2
        low.draw(at: NSPoint(x: 0, y: y))
        high.draw(at: NSPoint(x: bounds.width - highWidth, y: y))
        let start = lowWidth + 6, end = bounds.width - highWidth - 6
        let count = max(2, Int((end - start) / 3))
        for index in 0..<count {
            Theme.heat(Float(index) / Float(count - 1), appearance: effectiveAppearance).setFill()
            NSRect(x: start + CGFloat(index) * 3, y: bounds.midY - 5, width: 1.5, height: 10).fill()
        }
    }
}

/// A grid of dots split into coloured parts, like a waffle chart. Hovering a part
/// fades the others.
final class Waffle: DrawnView {
    struct Part {
        var name: String
        var value: Double
        var color: NSColor
    }

    var parts: [Part] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var cell: CGFloat = 7
    var gap: CGFloat = 2.5
    var onHover: ((Int, NSRect)?) -> Void = { _ in }

    private var columns: Int { max(1, Int((bounds.width + gap) / (cell + gap))) }
    private var rows: Int { max(1, Int((bounds.height + gap) / (cell + gap))) }

    /// Which part each dot belongs to, filled column by column so each part forms a block.
    private func assignment() -> [Int] {
        let total = parts.reduce(0) { $0 + max(0, $1.value) }
        let count = columns * rows
        guard total > 0 else { return [Int](repeating: -1, count: count) }
        var result: [Int] = []
        result.reserveCapacity(count)
        var carried = 0.0
        for (index, part) in parts.enumerated() {
            let exact = max(0, part.value) / total * Double(count) + carried
            let dots = Int(exact.rounded())
            carried = exact - Double(dots)
            result += [Int](repeating: index, count: max(0, min(dots, count - result.count)))
        }
        while result.count < count { result.append(parts.count - 1) }
        return result
    }

    private func rect(_ index: Int) -> NSRect {
        let column = index / rows, row = index % rows
        return NSRect(x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap), width: cell, height: cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        let owners = assignment()
        for (index, owner) in owners.enumerated() {
            var color = owner >= 0 && owner < parts.count ? parts[owner].color : Theme.track
            if let highlighted, highlighted != owner { color = color.withAlphaComponent(0.22) }
            color.setFill()
            NSBezierPath(roundedRect: rect(index), xRadius: 1.75, yRadius: 1.75).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / (cell + gap)), row = Int(point.y / (cell + gap))
        let index = column * rows + row
        let owners = assignment()
        guard column < columns, row < rows, owners.indices.contains(index), owners[index] >= 0 else { return }
        let owner = owners[index]
        if owner != highlighted {
            highlighted = owner
            // Anchor the tooltip on the part's first dot.
            let first = owners.firstIndex(of: owner) ?? index
            onHover((owner, rect(first).union(rect(index))))
        }
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
        onHover(nil)
    }
}

/// Legend items side by side: dot, caption, then the figure and its share.
/// Hovering an item reports it so the chart above can fade the rest.
final class LegendStrip: DrawnView {
    struct Item {
        var name: String
        var value: String
        var share: String
        var color: NSColor
    }

    var items: [Item] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var onHover: (Int?) -> Void = { _ in }

    private var itemWidth: CGFloat { bounds.width / CGFloat(max(items.count, 1)) }

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in items.enumerated() {
            let x = CGFloat(index) * itemWidth
            let faded = highlighted != nil && highlighted != index
            let alpha: CGFloat = faded ? 0.35 : 1
            item.color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 3.5, width: 6, height: 6)).fill()
            let caption = NSMutableAttributedString(attributedString: Theme.caption(item.name, color: Theme.inkTertiary.withAlphaComponent(alpha), size: 9))
            caption.append(NSAttributedString(string: " " + item.share, attributes: [
                .font: Theme.mono(9), .foregroundColor: Theme.inkTertiary.withAlphaComponent(alpha * 0.7),
            ]))
            caption.draw(at: NSPoint(x: x + 11, y: 0))
            let figure = NSAttributedString(string: item.value, attributes: [
                .font: Theme.figure(13, .medium), .foregroundColor: Theme.ink.withAlphaComponent(faded ? 0.3 : 1),
            ])
            figure.draw(at: NSPoint(x: x, y: 16))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let index = Int(x / itemWidth)
        let value = items.indices.contains(index) ? index : nil
        if value != highlighted {
            highlighted = value
            onHover(value)
        }
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
        onHover(nil)
    }
}

/// One line of a short list: icon or dot, name, a quiet uppercase tag, a small
/// bar for scale and the figure. Draws itself; hover tints the row.
final class ListRow: DrawnView {
    var icon: NSImage? { didSet { if icon !== oldValue { needsDisplay = true } } }
    var dot: NSColor?
    var name = "" { didSet { if name != oldValue { needsDisplay = true } } }
    var note = "" { didSet { if note != oldValue { needsDisplay = true } } }
    var value = "" { didSet { if value != oldValue { needsDisplay = true } } }
    var fraction: Double = 0 { didSet { if Int(fraction * 100) != Int(oldValue * 100) { needsDisplay = true } } }
    var barColor: NSColor = Theme.accent
    var showsRule = true
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, onClick != nil {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        var x: CGFloat = 0
        if let icon {
            icon.draw(in: NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            x = 24
        } else if let dot {
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
            x = 18
        }
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink]
        let valueWidth = max(52, ceil((value as NSString).size(withAttributes: valueAttributes).width))
        let barWidth: CGFloat = 52
        let barX = bounds.width - valueWidth - 12 - barWidth

        let nameAttributes: [NSAttributedString.Key: Any] = [.font: Theme.sans(13), .foregroundColor: Theme.ink]
        let tagText = Theme.caption(note, color: Theme.inkTertiary, size: 9.5)
        let room = barX - x - 12
        let nameWidth = min(ceil((name as NSString).size(withAttributes: nameAttributes).width), room)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var named = nameAttributes
        named[.paragraphStyle] = paragraph
        (name as NSString).draw(with: NSRect(x: x, y: (bounds.height - 17) / 2, width: nameWidth, height: 17),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: named)
        if !note.isEmpty, nameWidth + ceil(tagText.size().width) + 8 < room {
            tagText.draw(at: NSPoint(x: x + nameWidth + 8, y: (bounds.height - tagText.size().height) / 2 + 1))
        }

        Theme.track.setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: bounds.midY - 1.5, width: barWidth, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        barColor.setFill()
        let filled = max(3, barWidth * CGFloat(min(1, max(0, fraction))))
        NSBezierPath(roundedRect: NSRect(x: barX, y: bounds.midY - 1.5, width: filled, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let size = (value as NSString).size(withAttributes: valueAttributes)
        (value as NSString).draw(at: NSPoint(x: bounds.width - size.width, y: (bounds.height - size.height) / 2), withAttributes: valueAttributes)

        if showsRule {
            Theme.rule.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? .staticText : .button }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}
