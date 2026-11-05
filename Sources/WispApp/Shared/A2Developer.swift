import AppKit
import WispCore

// A2 pieces for the Developer pages (Projects, Containers, Coding Agents, Login &
// Background), on top of the shared tokens and views in A2Cards.swift:
//
//   A2Tile        a 110 pt card: label, 34 pt figure, sub line, an optional small meter
//   A2Table       a card's table: icon and name, then fixed columns of text, a status,
//                 a meter or pill buttons; rows share the height they are given
//   A2NoticeCard  one A2TipRow on a card of its own, warm when it is a warning
//
// Tables draw into one bitmap, only the part on screen when they are tall.

/// Colours and type the Developer pages share, from their mockups.
enum A2Dev {
    /// The label and icon colour of each Developer page.
    static func tint(_ page: PageID) -> NSColor {
        switch page {
        case .ports: return Theme.dynamic(0x007AFF, 0x3D9BFF)
        case .docker: return Theme.dynamic(0x0F8A9F, 0x40C8E0)
        case .agents: return Theme.dynamic(0x9B45CF, 0xBF5AF2)
        case .startup: return Theme.dynamic(0x0E7F93, 0x40C8E0)
        default: return A2.labelTint(page)
        }
    }

    /// The two ends of a meter's fill on each page.
    static func meter(_ page: PageID) -> (NSColor, NSColor) {
        switch page {
        case .agents: return (Theme.dynamic(0xAF52DE, 0xBF5AF2), Theme.dynamic(0xD08AF0, 0xDA8FFF))
        case .docker: return (Theme.dynamic(0x30B0C7, 0x30B0C7), Theme.dynamic(0x5AC8FA, 0x64D2FF))
        default: return (A2.cpu, A2.cpuLight)
        }
    }

    /// The quiet square behind a glyph that stands in for an icon.
    static let tile = A2.dynamic(NSColor(white: 0, alpha: 0.05), NSColor(white: 1, alpha: 0.08))
    static let tileGlyph = A2.dynamic(Theme.hex(0x3C3C43, alpha: 0.75), Theme.hex(0xEBEBF5, alpha: 0.75))
    static let chip = A2.dynamic(NSColor(white: 1, alpha: 0.75), NSColor(white: 1, alpha: 0.06))
    static let chipLine = A2.dynamic(NSColor(white: 0, alpha: 0.1), NSColor(white: 1, alpha: 0.12))
    static let warnWash = A2.dynamic(Theme.hex(0xFF9500, alpha: 0.14), Theme.hex(0xFF9F0A, alpha: 0.12))
    static let warnLine = Theme.hex(0xFF9F0A, alpha: 0.32)
    /// Status dots: serving a connection, idle, or neither.
    static let live = Theme.dynamic(0x34C759, 0x30D158)
    static let idle = Theme.dynamic(0xFF9500, 0xFF9F0A)
    static let quiet = A2.dynamic(Theme.hex(0x3C3C43, alpha: 0.3), Theme.hex(0xEBEBF5, alpha: 0.3))
    /// The warm card behind a warning that spans the page.
    static let warnCard = A2.dynamic(Theme.hex(0xFFF1E1), Theme.hex(0x2F271D))
    static let warnCardLine = A2.dynamic(Theme.hex(0xFF9500, alpha: 0.3), Theme.hex(0xFF9F0A, alpha: 0.24))

    static let nameFont = Theme.sans(13, .medium)
    static let noteFont = Theme.digits(11, .regular)
    static let detailFont = Theme.sans(11.5)
    static let cellFont = Theme.digits(12.5, .regular)
    static let cellBold = Theme.digits(12.5, .semibold)
    static let columnFont = Theme.sans(11, .medium)
    static let tagFont = Theme.sans(10.5, .semibold)

    /// "232.7%" as ("232.7", "%"), "3.7 GB" as ("3.7", "GB").
    @MainActor
    static func parts(_ text: String) -> (String, String) {
        if text.hasSuffix("%") { return (String(text.dropLast()), "%") }
        return DashboardView.split(text)
    }

    /// A capsule meter: the track and a fill running from one colour to the other.
    static func drawMeter(_ rect: NSRect, fraction: Double, colors: (NSColor, NSColor)) {
        let radius = rect.height / 2
        A2.meterTrack.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let width = rect.width * CGFloat(min(1, max(0, fraction)))
        guard width > 0.5 else { return }
        let filled = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, width), height: rect.height)
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius), angle: 0)
    }

    /// A glyph on a quiet rounded square, for things without an icon of their own.
    @MainActor
    static func drawGlyphTile(_ symbol: String, tint: NSColor? = nil, in rect: NSRect, appearance: NSAppearance) {
        tile.setFill()
        let radius = (rect.width * 0.27).rounded()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let size = (rect.width * 0.58).rounded()
        IconTile.glyph(symbol, tint: tint ?? tileGlyph, size: size, appearance: appearance)
            .draw(in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Draws one line of text centred on `mid`, cut to `width` with an ellipsis.
    /// Returns the width it took.
    @discardableResult
    static func text(_ text: String, x: CGFloat, mid: CGFloat, width: CGFloat, font: NSFont, color: NSColor,
                     right: Bool = false) -> CGFloat {
        guard width > 4, !text.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = right ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let line = ceil(font.ascender - font.descender)
        (text as NSString).draw(with: NSRect(x: x, y: mid - line / 2, width: width, height: line + 2),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return min(width, ceil((text as NSString).size(withAttributes: [.font: font]).width))
    }

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A small warning capsule ("Left over", "1 idle").
    static func drawTag(_ text: String, x: CGFloat, mid: CGFloat, font: NSFont = tagFont) -> CGFloat {
        let width = Self.width(text, font) + 14
        let rect = NSRect(x: x, y: (mid - 9).rounded(), width: width, height: 18)
        warnWash.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        Self.text(text, x: x + 7, mid: mid, width: width, font: font, color: A2.warn)
        return width
    }
}

/// A 5 pt capsule meter, as in the "Closest to its limit" tile.
final class A2MiniMeter: BitmapView {
    var fraction: Double = 0 { didSet { if Int(fraction * 200) != Int(oldValue * 200) { needsDisplay = true } } }
    var color: NSColor = A2.good { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        A2Dev.drawMeter(bounds, fraction: fraction, colors: (color, color))
    }
}

/// A top tile on a Developer page: label, a 34 pt figure and a sub line, 110 pt tall
/// in the mockups. `showsMeter` puts a small meter before the sub line.
final class A2Tile: CardView {
    let label: A2CardLabel
    let figure = A2.figure()
    let sub = TextLine()
    let meter = A2MiniMeter()
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; needsLayout = true } }

    init(_ name: String, symbol: String, tint: NSColor) {
        label = A2CardLabel(name, symbol: symbol, tint: tint)
        label.showsChevron = false
        super.init()
        meter.isHidden = true
        for view in [label, figure, sub, meter] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A figure written out: "8.2%" shows as 8.2 with a quieter %, "3.7 GB" as 3.7 GB.
    func show(_ text: String) {
        let (number, unit) = A2Dev.parts(text)
        figure.show(number, unit: unit)
    }

    /// A word in place of a number, cut to fit the tile.
    func show(word: String) {
        let room = bounds.width - A2.padSide * 2
        var text = word
        if room > 40, A2Dev.width(text, A2.figureFont) > room {
            while text.count > 1, A2Dev.width(text + "…", A2.figureFont) > room { text.removeLast() }
            text += "…"
        }
        figure.show(text)
    }

    func set(sub text: String) { sub.text = A2.plain(text) }
    func set(facts: [A2.Fact]) { sub.text = A2.facts(facts) }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        label.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 15)
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        let subTop = A2StatCard.subTop
        if showsMeter {
            meter.frame = NSRect(x: A2.padSide, y: subTop + 4.5, width: 72, height: 5)
            sub.frame = NSRect(x: A2.padSide + 80, y: subTop, width: inner - 80, height: 14)
        } else {
            sub.frame = NSRect(x: A2.padSide, y: subTop, width: inner, height: 14)
        }
    }
}

/// A card holding one A2TipRow: a tinted symbol, a bold line, a quieter line and a
/// pill button. `warning` gives it the warm fill of the idle dev servers card.
final class A2NoticeCard: CardView {
    let row = A2TipRow()
    static let height: CGFloat = 60

    var warning = false {
        didSet {
            fill = warning ? A2Dev.warnCard : Theme.card
            stroke = warning ? A2Dev.warnCardLine : Theme.cardBorder
        }
    }

    override init() {
        super.init()
        addSubview(row)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        row.frame = bounds.insetBy(dx: A2.padSide, dy: 0)
    }
}

/// A table on an A2 card. The first column is the item: an icon (or a glyph on a
/// quiet square), the name in 13 pt medium, a quiet note after it and an optional
/// second line. The other columns have fixed widths and are placed from the right
/// edge. Rows are at least `rowHeight` tall and share any extra height evenly.
final class A2Table: BitmapView {
    enum Kind: Equatable {
        case text
        /// A dot and the text in the primary colour, or the row's tag in its place.
        case status
        /// A meter of the given width, then the text right-aligned in what is left.
        case meter(CGFloat)
        /// Only a meter.
        case bar
        /// Pill buttons with these titles, right-aligned.
        case buttons([String])
    }

    struct Column: Equatable {
        var title: String
        var width: CGFloat
        var kind = Kind.text
        var right = false
        var bold = false
        /// When the name would get narrower than `minimumNameWidth`, columns step aside
        /// in this order, lowest first; 0 always stays.
        var drop = 0
    }

    struct Row: Equatable {
        var id: String
        var icon: NSImage? = nil
        var glyph: String? = nil
        var glyphTint: NSColor? = nil
        var name: String
        var note = ""
        var detail = ""
        var cells: [String] = []
        var fraction: Double = 0
        var dot: NSColor? = nil
        var tag: String? = nil
        var faint = false
    }

    var columns: [Column] = [] { didSet { if columns != oldValue { needsDisplay = true } } }
    var rows: [Row] = [] { didSet { if rows != oldValue { needsDisplay = true } } }
    /// The name column's title, or a card title and a count drawn in its place.
    var nameTitle = "" { didSet { needsDisplay = true } }
    var heading: (title: String, count: String)? { didSet { needsDisplay = true } }
    var headerHeight: CGFloat = 26
    var headerRule = true
    var rowHeight: CGFloat = 40
    var iconSize: CGFloat = 26
    var spacing: CGFloat = 11
    var minimumNameWidth: CGFloat = 150
    var meterColors = (A2.cpu, A2.cpuLight)
    var onSort: ((Int) -> Void)?
    var onSelect: ((String) -> Void)?
    var onButton: ((String, Int) -> Void)?
    var emptyText = "" { didSet { needsDisplay = true } }

    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    var naturalHeight: CGFloat { headerHeight + CGFloat(max(1, rows.count)) * rowHeight }

    private var shownRowHeight: CGFloat {
        max(rowHeight, (bounds.height - headerHeight) / CGFloat(max(1, rows.count))).rounded(.down)
    }

    private func rowTop(_ index: Int) -> CGFloat { headerHeight + CGFloat(index) * shownRowHeight }

    /// Each column's left edge from the right edge, nil for a column that stepped
    /// aside; the name column takes what is left.
    private func columnXs() -> (name: CGFloat, columns: [CGFloat?]) {
        var shown = Set(columns.indices)
        func nameRoom() -> CGFloat { bounds.width - shown.reduce(0) { $0 + columns[$1].width + spacing } }
        for index in columns.indices.filter({ columns[$0].drop > 0 }).sorted(by: { columns[$0].drop < columns[$1].drop }) {
            guard nameRoom() < minimumNameWidth else { break }
            shown.remove(index)
        }
        var right = bounds.width
        var xs = [CGFloat?](repeating: nil, count: columns.count)
        for index in columns.indices.reversed() where shown.contains(index) {
            xs[index] = right - columns[index].width
            right -= columns[index].width + spacing
        }
        return (max(0, right), xs)
    }

    private static let pillFont = Theme.sans(12, .semibold)

    private func pillFrames(_ titles: [String], x: CGFloat, width: CGFloat, mid: CGFloat) -> [NSRect] {
        var right = x + width
        var frames: [NSRect] = []
        for title in titles.reversed() {
            let w = A2Dev.width(title, Self.pillFont) + 22
            frames.append(NSRect(x: right - w, y: (mid - 12).rounded(), width: w, height: 24))
            right -= w + 6
        }
        return frames.reversed()
    }

    override func draw(_ dirtyRect: NSRect) {
        let (nameRight, xs) = columnXs()
        let appearance = effectiveAppearance
        drawHeader(nameRight: nameRight, xs: xs)
        if rows.isEmpty {
            A2Dev.text(emptyText, x: 0, mid: headerHeight + rowHeight / 2, width: bounds.width, font: A2.subFont, color: A2.secondary)
            return
        }
        let height = shownRowHeight
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, row) in rows.enumerated() {
            let top = rowTop(index)
            guard top < dirtyRect.maxY, top + height > dirtyRect.minY else { continue }
            let mid = top + height / 2
            if index == hovered, onSelect != nil {
                A2.rowHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: -6, y: top + 2, width: bounds.width + 12, height: height - 4), xRadius: 8, yRadius: 8).fill()
            } else if index > 0, index - 1 != hovered {
                A2.hairline.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
            }
            context.saveGState()
            if row.faint { context.setAlpha(0.6) }
            var x: CGFloat = 0
            let iconRect = NSRect(x: 0, y: (mid - iconSize / 2).rounded(), width: iconSize, height: iconSize)
            if let icon = row.icon {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x = iconSize + 11
            } else if let glyph = row.glyph {
                A2Dev.drawGlyphTile(glyph, tint: row.glyphTint, in: iconRect, appearance: appearance)
                x = iconSize + 11
            }
            let room = nameRight - x
            let nameMid = row.detail.isEmpty ? mid : mid - 8.5
            let used = A2Dev.text(row.name, x: x, mid: nameMid, width: room, font: A2Dev.nameFont, color: A2.primary)
            if !row.note.isEmpty, used + 30 < room {
                // On the name's baseline.
                let shift = (A2Dev.nameFont.ascender - A2Dev.noteFont.ascender) / 2 + 0.5
                A2Dev.text(row.note, x: x + used + 6, mid: nameMid + shift, width: room - used - 6, font: A2Dev.noteFont, color: A2.tertiary)
            }
            if !row.detail.isEmpty {
                A2Dev.text(row.detail, x: x, mid: mid + 9, width: room, font: A2Dev.detailFont, color: A2.secondary)
            }
            for (index, column) in columns.enumerated() {
                guard let columnX = xs[index] else { continue }
                let cell = index < row.cells.count ? row.cells[index] : ""
                drawCell(column, text: cell, row: row, x: columnX, mid: mid, context: context)
            }
            context.restoreGState()
        }
    }

    private func drawHeader(nameRight: CGFloat, xs: [CGFloat?]) {
        let mid = headerRule ? headerHeight / 2 : 8
        if let heading {
            let used = A2Dev.text(heading.title, x: 0, mid: mid, width: nameRight, font: A2.titleFont, color: A2.primary)
            if !heading.count.isEmpty {
                A2Dev.text(heading.count, x: used + 6, mid: mid, width: nameRight - used - 6, font: Theme.sans(13, .medium), color: A2.tertiary)
            }
        } else {
            A2Dev.text(nameTitle, x: 0, mid: mid, width: nameRight, font: A2Dev.columnFont, color: A2.secondary)
        }
        for (index, column) in columns.enumerated() where !column.title.isEmpty {
            guard let columnX = xs[index] else { continue }
            A2Dev.text(column.title, x: columnX, mid: mid, width: column.width, font: A2Dev.columnFont, color: A2.secondary, right: column.right)
        }
        if headerRule {
            A2.hairline.setFill()
            NSRect(x: 0, y: headerHeight - 0.5, width: bounds.width, height: 0.5).fill()
        }
    }

    private func drawCell(_ column: Column, text: String, row: Row, x: CGFloat, mid: CGFloat, context: CGContext) {
        let color = column.bold ? A2.primary : A2.secondary
        switch column.kind {
        case .text:
            A2Dev.text(text, x: x, mid: mid, width: column.width, font: column.bold ? A2Dev.cellBold : A2Dev.cellFont,
                       color: color, right: column.right)
        case .status:
            if let tag = row.tag {
                context.saveGState()
                context.setAlpha(1)
                A2Dev.drawTag(tag, x: x, mid: mid)
                context.restoreGState()
                return
            }
            var textX = x
            if let dot = row.dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: mid - 3.5, width: 7, height: 7)).fill()
                textX += 14
            }
            A2Dev.text(text, x: textX, mid: mid, width: column.width - (textX - x), font: A2Dev.cellFont, color: A2.primary)
        case .meter(let width):
            let valueWidth = column.width - width - 8
            if text == "–" || text.isEmpty {
                A2Dev.text(text, x: x + width + 8, mid: mid, width: valueWidth, font: A2Dev.cellFont, color: A2.secondary, right: true)
                return
            }
            A2Dev.drawMeter(NSRect(x: x, y: mid - 2.5, width: width, height: 5), fraction: row.fraction, colors: meterColors)
            A2Dev.text(text, x: x + width + 8, mid: mid, width: valueWidth, font: A2Dev.cellBold, color: A2.primary, right: true)
        case .bar:
            A2Dev.drawMeter(NSRect(x: x, y: mid - 2.5, width: column.width, height: 5), fraction: row.fraction, colors: meterColors)
        case .buttons(let titles):
            for (title, frame) in zip(titles, pillFrames(titles, x: x, width: column.width, mid: mid)) {
                A2.pill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
                A2Dev.text(title, x: frame.minX + 11, mid: frame.midY, width: frame.width - 20, font: Self.pillFont, color: A2.pillText)
            }
        }
    }

    // MARK: Pointer

    private func row(at point: NSPoint) -> Int? {
        guard point.y >= headerHeight else { return nil }
        let index = Int((point.y - headerHeight) / shownRowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (nameRight, xs) = columnXs()
        if point.y < headerHeight {
            guard let onSort else { return }
            if point.x < nameRight { return onSort(0) }
            if let index = xs.indices.first(where: { column in
                xs[column].map { point.x >= $0 && point.x <= $0 + columns[column].width } ?? false
            }) {
                onSort(index + 1)
            }
            return
        }
        guard let index = row(at: point) else { return }
        let id = rows[index].id
        let mid = rowTop(index) + shownRowHeight / 2
        for (column, x) in zip(columns, xs) {
            guard let x, case .buttons(let titles) = column.kind else { continue }
            if let hit = pillFrames(titles, x: x, width: column.width, mid: mid).firstIndex(where: { $0.contains(point) }) {
                onButton?(id, hit)
                return
            }
        }
        onSelect?(id)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { heading?.title ?? nameTitle }
    override func accessibilityValue() -> Any? {
        rows.map { ([$0.name] + $0.cells.filter { !$0.isEmpty }).joined(separator: " ") }.joined(separator: "; ")
    }
}

/// Hairlines across the width at the given heights, for lists whose rows do not draw
/// their own.
final class A2Rules: BitmapView {
    var lines: [CGFloat] = [] { didSet { if lines != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        A2.hairline.setFill()
        for y in lines { NSRect(x: 0, y: y, width: bounds.width, height: 0.5).fill() }
    }
}
