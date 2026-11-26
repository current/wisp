import AppKit
import WispCore

// Parts the Clean Up and Storage pages share: the bar of what can go split by kind and
// its key, the chart of what past cleans freed, the note a list card shows when it has
// nothing in it, and the grey placeholders drawn where rows will appear.

/// One slice of a whole: a group of items, an app, a kind of file.
struct CleanPart: Equatable {
    var id: String
    var name: String
    var bytes: Int64
    /// How much of it is ticked to go; the rest of its slice is drawn lighter. Nil draws it whole.
    var ticked: Int64?
    var count: Int
    var color: NSColor
    /// The sizes of the items inside, largest first, drawn as cuts in the slice.
    var pieces: [Int64] = []
}

extension CleanPart {
    /// A part in words: its size, its share of `total` and how much of it is ticked.
    static func spoken(_ part: CleanPart, of total: Double, named: Bool = true) -> String {
        var words = (named ? part.name + " " : "") + Format.bytes(UInt64(max(0, part.bytes)))
        if total > 0 { words += ", " + Format.percent(Double(max(0, part.bytes)) / total) }
        if let ticked = part.ticked, ticked < part.bytes { words += ", " + Format.bytes(UInt64(max(0, ticked))) + " selected" }
        return words
    }
}

enum CleanPalette {
    /// Kinds take these in order of size, the largest first; the rest share grey.
    static let colors: [NSColor] = [A2.cpu, A2.memoryApp, A2.up, A2.down, A2.power, StorageCategory.snapshots.color]
    static let rest = A2.diskSystem

    /// Parts for named sizes, largest first. Past the palette, the smallest are folded into one grey slice.
    static func parts(_ groups: [(id: String, name: String, bytes: Int64, ticked: Int64?, count: Int, pieces: [Int64])],
                      restName: String = "Everything else") -> [CleanPart] {
        let sorted = groups.filter { $0.bytes > 0 }.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
        let limit = sorted.count > colors.count + 1 ? colors.count : colors.count + 1
        var parts = sorted.prefix(limit).enumerated().map { index, group in
            CleanPart(id: group.id, name: group.name, bytes: group.bytes, ticked: group.ticked, count: group.count,
                      color: index < colors.count ? colors[index] : rest, pieces: group.pieces.sorted(by: >))
        }
        let others = sorted.dropFirst(limit)
        if !others.isEmpty {
            let ticked = others.contains { $0.ticked != nil } ? others.reduce(Int64(0)) { $0 + ($1.ticked ?? $1.bytes) } : nil
            parts.append(CleanPart(id: "#rest", name: restName, bytes: others.reduce(0) { $0 + $1.bytes }, ticked: ticked,
                                   count: others.reduce(0) { $0 + $1.count }, color: rest, pieces: others.map(\.bytes)))
        }
        return parts
    }

    /// The colour a part with this id was given, for the rows that belong to it.
    static func color(of id: String, in parts: [CleanPart]) -> NSColor {
        parts.first { $0.id == id }?.color ?? rest
    }
}

/// Grey shapes standing in for text and figures while they load.
enum Ghost {
    static let fill = A2.dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.08))

    static func bar(_ rect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(4, rect.height / 2), yRadius: min(4, rect.height / 2)).fill()
    }

    static func tile(_ rect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    /// Diagonal stripes in `color`, for a part of a bar whose size is not known yet.
    static func hatch(_ rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        color.withAlphaComponent(A2.drawingDark ? 0.16 : 0.12).setFill()
        rect.fill()
        color.withAlphaComponent(A2.drawingDark ? 0.34 : 0.26).setStroke()
        let stripes = NSBezierPath()
        stripes.lineWidth = 3
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            stripes.move(to: NSPoint(x: x, y: rect.maxY))
            stripes.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Widths that vary from row to row so placeholders do not read as a grid.
    static func width(_ index: Int, base: CGFloat, spread: CGFloat) -> CGFloat {
        let steps: [CGFloat] = [0.7, 0.35, 0.9, 0.5, 0.15, 0.8, 0.45, 0.6]
        return (base + spread * steps[index % steps.count]).rounded()
    }
}

/// What can go as one 14 pt bar, a slice per part with 2 pt gaps. Ticked bytes are drawn
/// in the part's colour and the rest of its slice lighter, so the bar shows what a clean
/// would take. While a scan runs, the end of the bar is striped for what is still to come.
final class PartsBar: BitmapView {
    var parts: [CleanPart] = [] { didSet { if parts != oldValue { needsDisplay = true } } }
    var looking = false { didSet { if looking != oldValue { needsDisplay = true } } }
    var onHover: ((CleanPart?, NSRect) -> Void)?
    var onPick: ((CleanPart) -> Void)?
    private var hovered: String? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private let gap: CGFloat = 2
    /// The share kept for "still looking" while a scan runs.
    private static let lookingShare: CGFloat = 0.16

    private func frames() -> [(CleanPart, NSRect)] {
        let total = Double(parts.reduce(0) { $0 + $1.bytes })
        guard total > 0 else { return [] }
        let span = looking ? (bounds.width * (1 - Self.lookingShare)).rounded() - gap : bounds.width
        let room = span - gap * CGFloat(max(0, parts.count - 1))
        var widths = parts.map { max(4, room * CGFloat(Double($0.bytes) / total)) }
        // Slivers kept clickable come out of the largest slice.
        let excess = widths.reduce(0, +) - room
        if excess > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) { widths[largest] -= excess }
        var x: CGFloat = 0
        return zip(parts, widths).map { part, width in
            defer { x += width + gap }
            return (part, NSRect(x: x, y: 0, width: width, height: bounds.height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).addClip()
        let frames = frames()
        if frames.isEmpty, !looking {
            A2.track.setFill()
            bounds.fill()
        }
        for (part, rect) in frames {
            let faded = hovered != nil && hovered != part.id
            let color = faded ? part.color.withAlphaComponent(0.38) : part.color
            if let ticked = part.ticked, ticked < part.bytes {
                let share = part.bytes > 0 ? CGFloat(Double(max(0, ticked)) / Double(part.bytes)) : 0
                let split = (rect.width * share).rounded()
                color.withAlphaComponent(color.alphaComponent * 0.45).setFill()
                rect.fill()
                color.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: split, height: rect.height).fill()
            } else {
                color.setFill()
                rect.fill()
            }
            drawCuts(part, in: rect)
        }
        if looking {
            let start = frames.last.map { $0.1.maxX + gap } ?? 0
            Ghost.hatch(NSRect(x: start, y: 0, width: bounds.width - start, height: bounds.height), color: A2.diskSystem)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A hairline in the card's colour between the items of a slice, where each is wide enough to see.
    private func drawCuts(_ part: CleanPart, in rect: NSRect) {
        guard part.pieces.count > 1, part.bytes > 0 else { return }
        Theme.card.withAlphaComponent(0.85).setFill()
        var x = rect.minX
        var last = rect.minX
        for piece in part.pieces.dropLast() {
            x += rect.width * CGFloat(Double(piece) / Double(part.bytes))
            guard x - last >= 5, rect.maxX - x >= 5 else { continue }
            NSRect(x: x.rounded() - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
            last = x
        }
    }

    private func part(at point: NSPoint) -> (CleanPart, NSRect)? {
        frames().first { $0.1.insetBy(dx: -gap / 2, dy: -4).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = part(at: convert(event.locationInWindow, from: nil))
        hovered = hit?.0.id
        onHover?(hit?.0, hit?.1 ?? .zero)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        onHover?(nil, .zero)
    }

    override func mouseUp(with event: NSEvent) {
        if let hit = part(at: convert(event.locationInWindow, from: nil)) { onPick?(hit.0) }
    }

    override func resetCursorRects() { if onPick != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "What can go" }
    // The slices' widths and their lighter unticked part are the only place the shares
    // and the selection show, so they are said here; clicking a slice is an action.
    override func accessibilityValue() -> Any? {
        let total = Double(parts.reduce(0) { $0 + max(0, $1.bytes) })
        var spoken = parts.map { CleanPart.spoken($0, of: total) }
        if looking { spoken.append("still looking") }
        return spoken.isEmpty ? "Nothing found yet" : spoken.joined(separator: "; ")
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let onPick, !parts.isEmpty else { return nil }
        return parts.map { part in NSAccessibilityCustomAction(name: "Show " + part.name) { onPick(part); return true } }
    }
}

/// The bar's key: a dot, the part's name, then its size and how many items, four to a
/// row. Before anything is found it draws placeholder entries in the same places.
final class PartsLegend: BitmapView {
    var parts: [CleanPart] = [] { didSet { if parts != oldValue { needsDisplay = true } } }
    /// Placeholder entries drawn while there are no parts.
    var ghosts = 0 { didSet { if ghosts != oldValue { needsDisplay = true } } }
    /// "items", or "apps": what a part's count counts.
    var noun = ("item", "items")
    var onPick: ((CleanPart) -> Void)?
    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
    static let itemHeight: CGFloat = 40
    static let rowGap: CGFloat = 2
    static let inset: CGFloat = 8
    private static let columnGap: CGFloat = 12
    private static let labelFont = Theme.sans(11.5)
    private static let valueFont = Theme.digits(13, .semibold)
    private static let countFont = Theme.digits(11.5)

    private var count: Int { parts.isEmpty ? ghosts : parts.count }
    private func columns(_ width: CGFloat) -> Int { width >= 620 ? 4 : width >= 440 ? 3 : 2 }

    /// The height for `width`, the width of the card's content.
    func naturalHeight(width: CGFloat) -> CGFloat {
        let columns = columns(width + Self.inset * 2)
        let rows = (count + columns - 1) / columns
        return rows == 0 ? 0 : CGFloat(rows) * Self.itemHeight + CGFloat(rows - 1) * Self.rowGap
    }

    private func frame(_ index: Int) -> NSRect {
        let columns = columns(bounds.width)
        let width = (bounds.width - Self.columnGap * CGFloat(columns - 1)) / CGFloat(columns)
        return NSRect(x: CGFloat(index % columns) * (width + Self.columnGap), y: CGFloat(index / columns) * (Self.itemHeight + Self.rowGap),
                      width: width, height: Self.itemHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelLine = Self.labelFont.ascender - Self.labelFont.descender
        guard !parts.isEmpty else {
            for index in 0..<ghosts {
                let rect = frame(index)
                let x = rect.minX + Self.inset
                Ghost.fill.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: rect.minY + 5 + labelLine / 2 - 4, width: 8, height: 8)).fill()
                Ghost.bar(NSRect(x: x + 14, y: rect.minY + 7, width: Ghost.width(index, base: 56, spread: 40), height: 9))
                Ghost.bar(NSRect(x: x + 14, y: rect.minY + 24, width: Ghost.width(index + 3, base: 36, spread: 24), height: 11))
            }
            return
        }
        for (index, part) in parts.enumerated() {
            let rect = frame(index)
            if index == hoveredIndex, onPick != nil {
                A2.rowHover.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            }
            let x = rect.minX + Self.inset
            let width = rect.width - Self.inset * 2 - 14
            let labelY = rect.minY + 4
            part.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: labelY + labelLine / 2 - 4, width: 8, height: 8)).fill()
            A2.drawTruncated(part.name, in: NSRect(x: x + 14, y: labelY, width: width, height: ceil(labelLine)), font: Self.labelFont,
                             color: A2.secondary)
            let value = Format.bytes(UInt64(max(0, part.bytes)))
            let mid = labelY + labelLine + 3 + 8
            let valueRight = A2.measuredDraw(value, at: x + 14, mid: mid, font: Self.valueFont, color: A2.primary)
            let count = part.count == 1 ? "1 \(noun.0)" : "\(part.count) \(noun.1)"
            A2.drawTruncated(count, in: NSRect(x: valueRight + 6, y: mid - 8, width: max(0, x + 14 + width - valueRight - 6), height: 16),
                             font: Self.countFont, color: A2.tertiary)
        }
    }

    private func index(at point: NSPoint) -> Int? { parts.indices.first { frame($0).contains(point) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = index(at: convert(event.locationInWindow, from: nil))
        hoveredIndex = index
        toolTip = index.map { parts[$0].name }
    }

    override func mouseExited(with event: NSEvent) { hoveredIndex = nil }
    override func mouseUp(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) { onPick?(parts[index]) }
    }

    // Each entry is a button so VoiceOver can pick a kind, as a click does.
    private final class Entry: NSAccessibilityElement {
        weak var owner: PartsLegend?
        var index = 0
        override func accessibilityPerformPress() -> Bool {
            guard let owner, let onPick = owner.onPick, owner.parts.indices.contains(index) else { return false }
            onPick(owner.parts[index])
            return true
        }
        override func accessibilityFrameInParentSpace() -> NSRect {
            guard let owner else { return .zero }
            let rect = owner.frame(index)
            return NSRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }
    private var entries: [Entry] = []

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Kinds" }
    override func accessibilityValue() -> Any? { parts.isEmpty && ghosts > 0 ? "Looking" : nil }
    override func accessibilityChildren() -> [Any]? {
        while entries.count < parts.count {
            let entry = Entry()
            entry.owner = self
            entry.index = entries.count
            entry.setAccessibilityParent(self)
            entries.append(entry)
        }
        let total = Double(parts.reduce(0) { $0 + max(0, $1.bytes) })
        return parts.indices.map { index in
            let part = parts[index], entry = entries[index]
            entry.setAccessibilityRole(onPick == nil ? .staticText : .button)
            entry.setAccessibilityLabel(part.name)
            entry.setAccessibilityValue((part.count == 1 ? "1 \(noun.0)" : "\(part.count) \(noun.1)") + ", "
                + CleanPart.spoken(part, of: total, named: false))
            return entry
        }
    }
}

/// What cleans have freed, added up over time: a step for each clean on a soft fill, edge
/// to edge on the card's floor, with a dot where each clean happened. Hover shows the clean.
final class CleanTimeline: BitmapView {
    struct Clean: Equatable {
        var date: Date
        var bytes: Int64
        var summary: String
    }

    var cleans: [Clean] = [] { didSet { if cleans != oldValue { needsDisplay = true } } }
    var tint: NSColor = A2.up
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private static let topGap: CGFloat = 30

    /// The span drawn: from a little before the first clean to now, a week at least.
    private var span: (start: Date, end: Date) {
        let end = Date()
        let first = cleans.first?.date ?? end
        let length = max(7 * 86_400, end.timeIntervalSince(first) * 1.08)
        return (end.addingTimeInterval(-length), end)
    }

    private func x(_ date: Date) -> CGFloat {
        let (start, end) = span
        return CGFloat(date.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))) * bounds.width
    }

    private var total: Int64 { cleans.reduce(0) { $0 + max(0, $1.bytes) } }

    private func y(_ bytes: Int64) -> CGFloat {
        let low = bounds.height - 1
        return low - CGFloat(Double(bytes) / Double(max(1, total))) * (low - Self.topGap)
    }

    /// The running total after each clean.
    private var steps: [(x: CGFloat, y: CGFloat)] {
        var sum: Int64 = 0
        return cleans.map { clean in
            sum += max(0, clean.bytes)
            return (x(clean.date), y(sum))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 40, let context = NSGraphicsContext.current?.cgContext else { return }
        let steps = steps
        context.saveGState()
        context.addPath(A2.bottomRounded(bounds))
        context.clip()
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        for (fraction, dashed) in [(0.5, true), (1.0, false)] {
            let lineY = floor(y(Int64(Double(total) * fraction))) + 0.5
            context.setLineDash(phase: 0, lengths: dashed ? [2, 4] : [])
            context.move(to: CGPoint(x: 0, y: lineY))
            context.addLine(to: CGPoint(x: bounds.width, y: lineY))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        guard !steps.isEmpty else {
            context.restoreGState()
            return
        }
        var line: [CGPoint] = [CGPoint(x: 0, y: bounds.height - 1)]
        var level = bounds.height - 1
        for step in steps {
            line.append(CGPoint(x: step.x, y: level))
            line.append(CGPoint(x: step.x, y: step.y))
            level = step.y
        }
        line.append(CGPoint(x: bounds.width, y: level))
        let area = CGMutablePath()
        area.move(to: CGPoint(x: 0, y: bounds.height))
        line.forEach { area.addLine(to: $0) }
        area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        area.closeSubpath()
        A2.fade(area, color: tint, alpha: A2.drawingDark ? 0.32 : 0.2, from: line.map(\.y).min() ?? 0, to: bounds.height, in: context)
        context.setStrokeColor((tint.usingColorSpace(.sRGB) ?? tint).cgColor)
        context.setLineWidth(1.8)
        context.setLineJoin(.round)
        context.addLines(between: line)
        context.strokePath()
        context.restoreGState()
        for (index, step) in steps.enumerated() {
            let radius: CGFloat = index == hoverIndex ? 4.5 : 3
            Theme.card.setFill()
            NSBezierPath(ovalIn: NSRect(x: step.x - radius - 1.5, y: step.y - radius - 1.5, width: (radius + 1.5) * 2, height: (radius + 1.5) * 2)).fill()
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: step.x - radius, y: step.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        let font = Theme.digits(10)
        let label = Format.bytes(UInt64(total)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.gridLabel]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.width - 14 - size.width, y: y(total) - 4 - font.ascender), withAttributes: attributes)
        drawHover(steps)
    }

    private func drawHover(_ steps: [(x: CGFloat, y: CGFloat)]) {
        guard let index = hoverIndex, cleans.indices.contains(index) else { return }
        let clean = cleans[index]
        let x = steps[index].x
        A2.tertiary.setFill()
        NSRect(x: x.rounded() - 0.5, y: Self.topGap - 8, width: 1, height: bounds.height - Self.topGap + 8).fill()
        let sum = cleans.prefix(index + 1).reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        let text = "\(clean.date.formatted(date: .abbreviated, time: .shortened))   \(Format.bytes(UInt64(max(0, clean.bytes)))) freed   "
            + "\(Format.bytes(UInt64(sum))) in all" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        var box = NSRect(x: x + 8, y: 4, width: ceil(size.width) + 16, height: 22)
        if box.maxX > bounds.width - 4 { box.origin.x = max(4, x - 8 - box.width) }
        Theme.tooltip.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let steps = steps
        let nearest = steps.indices.min { abs(steps[$0].x - point.x) < abs(steps[$1].x - point.x) }
        hoverIndex = nearest.flatMap { abs(steps[$0].x - point.x) < 40 ? $0 : nil }
        toolTip = hoverIndex.map { cleans[$0].summary }
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Space freed by cleans over time" }
    // The hover shows one clean at a time; VoiceOver hears the total and the latest few.
    override func accessibilityValue() -> Any? {
        guard !cleans.isEmpty else { return "No cleans yet" }
        let head = "\(Format.bytes(UInt64(total))) in \(cleans.count == 1 ? "1 clean" : "\(cleans.count) cleans")"
        return ([head] + cleans.suffix(5).reversed().map(\.summary)).joined(separator: "; ")
    }
}

/// What a list card shows when it has no rows: a symbol on a tinted tile, a line that says
/// what happened and one that says what to do, centred in the card.
final class CleanNote: DrawnView {
    var symbol = "checkmark" { didSet { if symbol != oldValue { needsDisplay = true } } }
    var tint: NSColor = A2.good { didSet { needsDisplay = true } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var detail = "" { didSet { if detail != oldValue { needsDisplay = true } } }
    static let height: CGFloat = 170
    private static let titleFont = Theme.sans(14, .semibold)
    private static let detailFont = Theme.sans(12)

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSRect(x: (bounds.midX - 20).rounded(), y: (bounds.midY - 52).rounded(), width: 40, height: 40)
        tint.withAlphaComponent(A2.drawingDark ? 0.18 : 0.13).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 11, yRadius: 11).fill()
        IconTile.glyph(symbol, tint: tint, size: 20, appearance: effectiveAppearance)
            .draw(in: NSRect(x: tile.midX - 10, y: tile.midY - 10, width: 20, height: 20), from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: nil)
        let width = min(bounds.width - 40, 520)
        A2.drawTruncated(title, in: NSRect(x: bounds.midX - width / 2, y: tile.maxY + 12, width: width, height: 20), font: Self.titleFont,
                         color: A2.primary, alignment: .center)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        (detail as NSString).draw(with: NSRect(x: bounds.midX - width / 2, y: tile.maxY + 36, width: width, height: 34),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: Self.detailFont, .foregroundColor: A2.secondary, .paragraphStyle: paragraph])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { title + ". " + detail }
}

/// The strip under a page's floating footer, in the page's ground colour, so rows scrolled
/// under the footer fade out instead of showing in the margin below it.
final class FooterShelf: DrawnView {
    static let fade: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Theme.ground.withAlphaComponent(0), ending: Theme.ground)?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: Self.fade), angle: 90)
        Theme.ground.setFill()
        NSRect(x: 0, y: Self.fade, width: bounds.width, height: max(0, bounds.height - Self.fade)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
