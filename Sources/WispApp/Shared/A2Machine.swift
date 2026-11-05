import AppKit
import WispCore

// A2 views for the machine pages (CPU, Memory, GPU, Neural Engine, Network, Sound,
// Bluetooth, Sensors), on top of the shared ones in A2Cards.swift:
//
//   A2Header         icon, title, quiet detail and a legend on the right, for card heads
//   A2Meter          a thin capsule filled from the left
//   A2CoreMap        one row of heat cells per core, performance cores first
//   A2HeatKey        "P performance · E efficiency" and the 0% to 100% scale
//   A2Waffle         dots in fixed rows, split into coloured parts, with A2ShareKeys under it
//   A2Row            a list row: icon, name over a detail, then fixed-width cells on the right
//   A2Lines          label and bold value pairs between hairlines
//   A2Paragraph      wrapped text in one style
//   A2Slider         a volume track with a capsule knob
//   A2ToolbarButton  a symbol and a label on a toolbar capsule
//
// Like the rest of A2 they draw themselves, never clip with a layer and cast no shadow.

extension A2 {
    /// Purple for the Neural Engine, darker in light mode for 12 pt text.
    static let neural = Theme.dynamic(0xCB30E0, 0xDA8FFF)
    static let neuralLabel = Theme.dynamic(0xA42BBD, 0xDA8FFF)
    static let teal = Theme.dynamic(0x00B5C2, 0x40CBE0)
    static let sound = Theme.dynamic(0xE0284F, 0xFF5C7A)
    static let soundEnd = Theme.dynamic(0xFF9500, 0xFF9F0A)
    static let bluetooth = Theme.dynamic(0x007AFF, 0x3D9BFF)
    /// The good end of a battery bar: green into a paler green.
    static let charge = Theme.dynamic(0x34C759, 0x30D158)
    static let chargeEnd = Theme.dynamic(0x7EE59A, 0x7EE59A)
    static let warm = Theme.dynamic(0xFF9500, 0xFF9F0A)
    static let warmEnd = Theme.dynamic(0xFFCC00, 0xFFD60A)
    /// A neutral glyph tile behind a symbol when a row has no app icon.
    static let glyphTile = dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.09))
    static let glyphInk = dynamic(Theme.hex(0x3C3C43, alpha: 0.62), Theme.hex(0xEBEBF5, alpha: 0.75))
    /// The knob of a slider, white in both modes.
    static let knob = Theme.dynamic(0xFFFFFF, 0xF5F5F7)

    static let rowFont = Theme.sans(13, .medium)
    static let detailFont = Theme.sans(11)
    static let valueFont = Theme.digits(12.5, .semibold)
    static let quietValueFont = Theme.digits(12.5)

    /// A card title as one attributed string, for a `TextLine`: the symbol in the page's
    /// colour, the name, and a quieter detail after it.
    @MainActor
    static func title(_ name: String, symbol: String?, tint: NSColor, detail: String = "", size: CGFloat = 13,
                      color: NSColor = A2.primary) -> NSAttributedString {
        let font = Theme.sans(size, .semibold)
        let text = NSMutableAttributedString()
        if let symbol {
            let glyph: CGFloat = size >= 13 ? 15 : 14
            let attachment = NSTextAttachment()
            attachment.image = IconTile.glyph(symbol, tint: tint, size: glyph, appearance: NSApp.effectiveAppearance)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - glyph) / 2, width: glyph, height: glyph)
            text.append(NSAttributedString(attachment: attachment))
            // Kern on an attachment is ignored; a space narrowed to the gap sets it instead.
            let gap: CGFloat = size >= 13 ? 7 : 6
            text.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: gap - (" " as NSString).size(withAttributes: [.font: font]).width]))
        }
        text.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color]))
        if !detail.isEmpty {
            text.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 7 - (" " as NSString).size(withAttributes: [.font: font]).width]))
            text.append(NSAttributedString(string: detail, attributes: [.font: Theme.sans(size, .medium), .foregroundColor: tertiary]))
        }
        return text
    }

    /// Draws `text` vertically centred on `mid` with its left edge at `x`; returns the right edge.
    @discardableResult
    static func draw(_ text: String, at x: CGFloat, mid: CGFloat, font: NSFont, color: NSColor) -> CGFloat {
        (text as NSString).draw(at: NSPoint(x: x, y: mid - (font.ascender - font.descender) / 2), withAttributes: [.font: font, .foregroundColor: color])
        return x + ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Draws `text` in `rect`, one line, cut short with an ellipsis when it does not fit.
    static func drawTruncated(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        guard rect.width > 4 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let height = ceil(font.ascender - font.descender + font.leading)
        (text as NSString).draw(with: NSRect(x: rect.minX, y: rect.midY - (font.ascender - font.descender) / 2, width: rect.width, height: height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// A capsule meter: the track, then the filled part in `color` (fading into `end`).
    static func meter(_ rect: NSRect, fraction: Double, color: NSColor, end: NSColor? = nil) {
        let radius = rect.height / 2
        meterTrack.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let width = max(rect.height, rect.width * CGFloat(min(1, max(0, fraction))))
        guard fraction > 0 else { return }
        let filled = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), xRadius: radius, yRadius: radius)
        if let end, let gradient = NSGradient(starting: color, ending: end) {
            gradient.draw(in: filled, angle: 0)
        } else {
            color.setFill()
            filled.fill()
        }
    }

    /// The 22 pt rounded tile with a symbol that stands in for an app icon.
    static func glyphTile(_ symbol: String, in rect: NSRect, tint: NSColor?, appearance: NSAppearance) {
        let radius = rect.width * 0.27
        (tint.map { $0.withAlphaComponent(drawingDark ? 0.14 : 0.12) } ?? glyphTile).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let size = (rect.width * 0.6).rounded()
        IconTile.glyph(symbol, tint: tint ?? glyphInk, size: size, appearance: appearance)
            .draw(in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A card's head: an optional symbol, the title and a quiet detail on the left, and a
/// legend on the right ("Peak 34%", "Last 5 minutes", a dot and "CPU 13%"). 16 pt tall.
final class A2Header: DrawnView {
    struct Item: Equatable {
        var text: String
        var value: String = ""
        var dot: NSColor? = nil
        var faint = false
    }

    var symbol: String? { didSet { if symbol != oldValue { needsDisplay = true } } }
    var tint: NSColor = A2.cpu { didSet { needsDisplay = true } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    /// The title's colour; the page's colour on hero cards and A2.secondary on tiles.
    var titleColor: NSColor = A2.primary { didSet { needsDisplay = true } }
    var detail = "" { didSet { if detail != oldValue { needsDisplay = true } } }
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var size: CGFloat = 13 { didSet { needsDisplay = true } }
    var iconSize: CGFloat = 15

    private var font: NSFont { Theme.sans(size, .semibold) }
    private var iconGap: CGFloat { size >= 13 ? 7 : 6 }

    /// Where the title ends, for a badge placed after it.
    var titleRight: CGFloat {
        (symbol == nil ? 0 : iconSize + iconGap) + A2.width(title, font)
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.height / 2
        var x: CGFloat = 0
        if let symbol {
            IconTile.glyph(symbol, tint: tint, size: iconSize, appearance: effectiveAppearance)
                .draw(in: NSRect(x: 0, y: mid - iconSize / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            x = iconSize + iconGap
        }
        // The legend first, so the title gives way to it.
        let legend = A2.legendFont, bold = Theme.digits(11, .semibold)
        var right = bounds.width
        for item in items.reversed() {
            let valueWidth = item.value.isEmpty ? 0 : A2.width(item.value, bold)
            let textWidth = A2.width(item.text, legend)
            let gap: CGFloat = item.value.isEmpty || item.text.isEmpty ? 0 : 3
            right -= valueWidth + gap + textWidth
            var at = right
            at = A2.draw(item.text, at: at, mid: mid, font: legend, color: item.faint ? A2.tertiary : A2.secondary)
            if !item.value.isEmpty { A2.draw(item.value, at: at + gap, mid: mid, font: bold, color: A2.primary) }
            if let dot = item.dot {
                right -= 13
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: right, y: mid - 4, width: 8, height: 8)).fill()
            }
            right -= 12
        }
        let room = max(0, right - x)
        let titleWidth = min(A2.width(title, font), room)
        A2.drawTruncated(title, in: NSRect(x: x, y: 0, width: titleWidth, height: bounds.height), font: font, color: titleColor)
        if !detail.isEmpty, x + titleWidth + 7 + 20 < right {
            A2.drawTruncated(detail, in: NSRect(x: x + titleWidth + 7, y: 0, width: right - x - titleWidth - 7, height: bounds.height),
                             font: Theme.sans(size, .medium), color: A2.tertiary)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? {
        ([title, detail] + items.map { [$0.text, $0.value].filter { !$0.isEmpty }.joined(separator: " ") }).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A thin capsule filled from the left, in one colour or fading into a second.
final class A2Meter: DrawnView {
    var fraction: Double = 0 { didSet { if Int(fraction * 400) != Int(oldValue * 400) { needsDisplay = true } } }
    var color: NSColor = A2.cpu { didSet { needsDisplay = true } }
    var end: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        A2.meter(bounds, fraction: fraction, color: color, end: end)
    }
}

/// Every core's recent load as a row of heat cells, newest on the right. Rows share
/// the height (cells at most 15 pt tall); a small gap sets the efficiency cores apart.
final class A2CoreMap: BitmapView {
    struct Row: Equatable {
        var label: String
        var values: [Float]
    }

    var rows: [Row] = [] { didSet { if rows != oldValue { needsDisplay = true } } }
    var columns = 32
    /// Rows from this index on are efficiency cores, drawn after a gap.
    var groupBreak: Int?
    private var palette: [NSColor] = []
    private var paletteDark: Bool?

    private static let labelFont = Theme.digits(10.5, .medium)
    private static let labelWidth: CGFloat = 30
    private static let rowGap: CGFloat = 3
    private static let cellGap: CGFloat = 2
    private static let groupGap: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = A2.drawingDark
        if palette.isEmpty || paletteDark != dark {
            palette = (0...32).map { Theme.heat(Float($0) / 32, appearance: effectiveAppearance) }
            paletteDark = dark
        }
        let groups = groupBreak.map { $0 > 0 && $0 < rows.count } ?? false
        let room = bounds.height - (groups ? Self.groupGap : 0) - Self.rowGap * CGFloat(rows.count - 1)
        let pitch = room / CGFloat(rows.count)
        let cellHeight = min(15, pitch)
        let width = (bounds.width - Self.labelWidth - Self.cellGap * CGFloat(columns - 1)) / CGFloat(columns)
        guard width > 0.5 else { return }
        let paths = (0...33).map { _ in CGMutablePath() }
        for (index, row) in rows.enumerated() {
            let slot = CGFloat(index) * (pitch + Self.rowGap) + (groups && index >= groupBreak! ? Self.groupGap : 0)
            let y = slot + (pitch - cellHeight) / 2
            A2.draw(row.label, at: 0, mid: y + cellHeight / 2, font: Self.labelFont, color: A2.tertiary)
            let shown = row.values.suffix(columns)
            for column in 0..<columns {
                let sample = shown.count - columns + column
                var bucket = 33
                if sample >= 0 {
                    let value = shown[shown.startIndex + sample]
                    if !value.isNaN { bucket = Int((min(1, max(0, value)) * 32).rounded()) }
                }
                let x = Self.labelWidth + CGFloat(column) * (width + Self.cellGap)
                paths[bucket].addRoundedRect(in: CGRect(x: x, y: y, width: width, height: cellHeight), cornerWidth: 2.5, cornerHeight: 2.5)
            }
        }
        for (bucket, path) in paths.enumerated() where !path.isEmpty {
            context.addPath(path)
            context.setFillColor((bucket == 33 ? A2.meterTrack : palette[bucket]).cgColor)
            context.fillPath()
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Load per core" }
}

/// The key under the core map: what P and E mean on the left, the heat scale on the right.
final class A2HeatKey: DrawnView {
    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.digits(10.5), mid = bounds.height / 2
        A2.draw("P performance · E efficiency", at: 0, mid: mid, font: font, color: A2.tertiary)
        let high = "100%", low = "0%"
        let highX = bounds.width - A2.width(high, font)
        A2.draw(high, at: highX, mid: mid, font: font, color: A2.tertiary)
        let bar = NSRect(x: highX - 7 - 110, y: mid - 3, width: 110, height: 6)
        A2.draw(low, at: bar.minX - 7 - A2.width(low, font), mid: mid, font: font, color: A2.tertiary)
        let stops = (0...8).map { Theme.heat(Float($0) / 8, appearance: effectiveAppearance) }
        NSGradient(colors: stops)?.draw(in: NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3), angle: 0)
    }
}

/// Dots in a fixed number of rows, filled column by column so each part forms a block.
/// The columns stretch to the width, so the grid always ends at both edges.
final class A2Waffle: BitmapView {
    struct Part: Equatable {
        var value: Double
        var color: NSColor
    }

    var parts: [Part] = [] { didSet { if parts != oldValue { needsDisplay = true } } }
    var rows = 15
    var gap: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        let cell = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cell > 1 else { return }
        let columns = max(1, Int((bounds.width + gap) / (cell + gap)))
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let count = rows * columns
        let total = parts.reduce(0) { $0 + max(0, $1.value) }
        var owners: [NSColor] = []
        owners.reserveCapacity(count)
        if total > 0 {
            var carried = 0.0
            for part in parts {
                let exact = max(0, part.value) / total * Double(count) + carried
                let dots = Int(exact.rounded())
                carried = exact - Double(dots)
                owners += [NSColor](repeating: part.color, count: max(0, min(dots, count - owners.count)))
            }
        }
        while owners.count < count { owners.append(parts.last?.color ?? A2.track) }
        for (index, color) in owners.enumerated() {
            let column = index / rows, row = index % rows
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(column) * (width + gap), y: CGFloat(row) * (cell + gap), width: width, height: cell),
                         xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// The key under a waffle: a colour square, the name and its share, the amount in bold.
final class A2ShareKeys: DrawnView {
    struct Key: Equatable {
        var label: String
        var share: String
        var value: String
        var color: NSColor
    }

    var keys: [Key] = [] { didSet { if keys != oldValue { needsDisplay = true } } }
    var columns = 3
    static let labelFont = Theme.sans(10.5)
    static let valueFont = Theme.digits(12.5, .semibold)
    static let keyHeight: CGFloat = 30
    static let rowGap: CGFloat = 12

    var naturalHeight: CGFloat {
        let rows = (keys.count + columns - 1) / max(1, columns)
        return rows == 0 ? 0 : CGFloat(rows) * Self.keyHeight + CGFloat(rows - 1) * Self.rowGap
    }

    override func draw(_ dirtyRect: NSRect) {
        let column = (bounds.width - 8 * CGFloat(columns - 1)) / CGFloat(columns)
        for (index, key) in keys.enumerated() {
            let x = CGFloat(index % columns) * (column + 8), y = CGFloat(index / columns) * (Self.keyHeight + Self.rowGap)
            let mid = y + 7
            key.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: mid - 3.5, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
            let after = A2.draw(key.label, at: x + 13, mid: mid, font: Self.labelFont, color: A2.secondary)
            A2.draw(key.share, at: after + 4, mid: mid, font: Self.labelFont, color: A2.tertiary)
            A2.draw(key.value, at: x + 13, mid: y + 22, font: Self.valueFont, color: A2.primary)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { keys.map { "\($0.label) \($0.value)" }.joined(separator: ", ") }
}

/// One row of an A2 list: an icon (an app's, or a symbol on a tile), the name with a
/// detail under it or after it, and cells laid out from the right edge at fixed widths.
/// A hairline above every row but the first.
final class A2Row: DrawnView {
    enum Lead: Equatable {
        case none
        case image(NSImage)
        /// A symbol on a rounded tile, in a wash of `tint`, or neutral grey without one.
        case glyph(String, NSColor?)
    }

    struct Cell: Equatable {
        enum Kind: Equatable {
            case text(String, NSColor, NSFont, NSTextAlignment)
            case meter(Double, NSColor, NSColor?)
            case check
            /// A tinted capsule with a symbol and a label ("Playing").
            case badge(String, String?, NSColor)
            /// A status dot and its text; a hollow dot when `filled` is false.
            case status(String, NSColor, Bool)
            /// Numbered readings side by side ("1 66°  2 65°").
            case chips([String])
        }
        var kind: Kind
        var width: CGFloat
    }

    var lead: Lead = .none { didSet { if lead != oldValue { needsDisplay = true } } }
    var leadSize: CGFloat = 22
    var name = "" { didSet { if name != oldValue { needsDisplay = true } } }
    var nameColor: NSColor = A2.primary { didSet { needsDisplay = true } }
    var nameFont = A2.rowFont { didSet { needsDisplay = true } }
    /// Under the name in 11 pt, or after it on the same line when `inline` is set.
    var detail = "" { didSet { if detail != oldValue { needsDisplay = true } } }
    var inline = false
    /// A 4 pt meter under the name in place of a detail, as for accessory batteries.
    var meterBelow: Double? { didSet { if meterBelow != oldValue { needsDisplay = true } } }
    var meterColor = A2.charge
    var meterEnd: NSColor? = A2.chargeEnd
    var cells: [Cell] = [] { didSet { if cells != oldValue { needsDisplay = true } } }
    var faded = false { didSet { if faded != oldValue { needsDisplay = true } } }
    var showsRule = false { didSet { if showsRule != oldValue { needsDisplay = true } } }
    /// A hairline under the row instead, for a row of column titles.
    var ruleBelow = false { didSet { if ruleBelow != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    static let spacing: CGFloat = 11

    override func draw(_ dirtyRect: NSRect) {
        if hovering, onClick != nil {
            A2.rowHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
        } else if showsRule {
            A2.hairline.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        }
        if ruleBelow {
            A2.hairline.setFill()
            NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        }
        let mid = bounds.height / 2
        let alpha: CGFloat = faded ? 0.5 : 1
        var x: CGFloat = 0
        let leadRect = NSRect(x: 0, y: (mid - leadSize / 2).rounded(), width: leadSize, height: leadSize)
        switch lead {
        case .none: break
        case .image(let image):
            image.draw(in: leadRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            x = leadSize + Self.spacing
        case .glyph(let symbol, let tint):
            A2.glyphTile(symbol, in: leadRect, tint: tint, appearance: effectiveAppearance)
            x = leadSize + Self.spacing
        }
        var right = bounds.width
        for cell in cells.reversed() {
            let rect = NSRect(x: right - cell.width, y: 0, width: cell.width, height: bounds.height)
            drawCell(cell.kind, in: rect)
            right = rect.minX - Self.spacing
        }
        let room = max(0, right - x)
        let font = nameFont
        if let meterBelow {
            let nameLine = font.ascender - font.descender
            let top = mid - (nameLine + 6 + 4) / 2
            A2.drawTruncated(name, in: NSRect(x: x, y: top, width: room, height: nameLine), font: font, color: nameColor)
            A2.meter(NSRect(x: x, y: top + nameLine + 6, width: room, height: 4), fraction: meterBelow, color: meterColor, end: meterEnd)
        } else if detail.isEmpty || inline {
            let nameWidth = min(A2.width(name, font), room)
            A2.drawTruncated(name, in: NSRect(x: x, y: 0, width: nameWidth, height: bounds.height), font: font, color: nameColor)
            if inline, !detail.isEmpty, nameWidth + 6 + 24 < room {
                // On the name's baseline: centre the detail's line box that far below the middle.
                let detail = A2.detailFont
                let shift = (font.ascender + font.descender) / 2 - (detail.ascender + detail.descender) / 2
                A2.drawTruncated(self.detail, in: NSRect(x: x + nameWidth + 6, y: shift, width: room - nameWidth - 6, height: bounds.height),
                                 font: detail, color: A2.tertiary)
            }
        } else {
            let nameLine = font.ascender - font.descender, detailLine = A2.detailFont.ascender - A2.detailFont.descender
            let top = mid - (nameLine + 2 + detailLine) / 2
            A2.drawTruncated(name, in: NSRect(x: x, y: top, width: room, height: nameLine), font: font, color: nameColor)
            A2.drawTruncated(detail, in: NSRect(x: x, y: top + nameLine + 2, width: room, height: detailLine), font: A2.detailFont, color: A2.tertiary)
        }
    }

    private func drawCell(_ kind: Cell.Kind, in rect: NSRect) {
        let mid = rect.midY
        switch kind {
        case .text(let text, let color, let font, let alignment):
            A2.drawTruncated(text, in: rect, font: font, color: color, alignment: alignment)
        case .meter(let fraction, let color, let end):
            A2.meter(NSRect(x: rect.minX, y: mid - 2.5, width: rect.width, height: 5), fraction: fraction, color: color, end: end)
        case .check:
            let path = NSBezierPath()
            let x = rect.midX - 7, scale: CGFloat = 14 / 16
            path.move(to: NSPoint(x: x + 3.4 * scale, y: mid + 0.4 * scale))
            path.line(to: NSPoint(x: x + 6.4 * scale, y: mid + 3.4 * scale))
            path.line(to: NSPoint(x: x + 12.6 * scale, y: mid - 3.4 * scale))
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            A2.cpu.setStroke()
            path.stroke()
        case .badge(let text, let symbol, let tint):
            let font = Theme.sans(11.5, .semibold)
            let width = A2.width(text, font) + 20 + (symbol == nil ? 0 : 19)
            let capsule = NSRect(x: rect.maxX - width, y: mid - 12, width: width, height: 24)
            tint.withAlphaComponent(A2.drawingDark ? 0.14 : 0.12).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 12, yRadius: 12).fill()
            var x = capsule.minX + 10
            if let symbol {
                IconTile.glyph(symbol, tint: tint, size: 13, appearance: effectiveAppearance)
                    .draw(in: NSRect(x: x, y: mid - 6.5, width: 13, height: 13), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
                x += 19
            }
            A2.draw(text, at: x, mid: mid, font: font, color: tint)
        case .status(let text, let color, let filled):
            let dot = NSRect(x: rect.minX, y: mid - 3.5, width: 7, height: 7)
            if filled {
                color.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                A2.meterTrack.setFill()
                NSBezierPath(ovalIn: dot).fill()
                A2.tertiary.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            }
            A2.drawTruncated(text, in: NSRect(x: rect.minX + 14, y: rect.minY, width: rect.width - 14, height: rect.height),
                             font: filled ? Theme.sans(12.5, .medium) : Theme.sans(12.5), color: filled ? A2.primary : A2.secondary)
        case .chips(let values):
            let index = Theme.digits(10, .medium), value = A2.valueFont
            var x = rect.minX
            for (number, text) in values.enumerated() {
                guard x + 40 <= rect.maxX + 1 else { break }
                if values.count > 1 { x = A2.draw("\(number + 1)", at: x, mid: mid + 1, font: index, color: A2.tertiary) + 4 }
                A2.draw(text, at: x, mid: mid, font: value, color: A2.primary)
                x = rect.minX + CGFloat(number + 1) * 52
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard onClick != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? .staticText : .button }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? {
        ([detail] + cells.compactMap { cell -> String? in
            switch cell.kind {
            case .text(let text, _, _, _), .badge(let text, _, _), .status(let text, _, _): return text
            case .chips(let values): return values.joined(separator: ", ")
            default: return nil
            }
        }).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Label and bold value pairs between hairlines, sharing the height.
final class A2Lines: DrawnView {
    struct Line: Equatable {
        var label: String
        var value: String
        var color: NSColor? = nil
    }

    var lines: [Line] = [] { didSet { if lines != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { return }
        let pitch = bounds.height / CGFloat(lines.count)
        let label = Theme.sans(12), value = Theme.digits(12, .semibold)
        for (index, line) in lines.enumerated() {
            let top = CGFloat(index) * pitch
            if index > 0 {
                A2.hairline.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
            }
            let mid = top + pitch / 2
            let valueWidth = A2.width(line.value, value)
            A2.draw(line.value, at: bounds.width - valueWidth, mid: mid, font: value, color: line.color ?? A2.primary)
            A2.drawTruncated(line.label, in: NSRect(x: 0, y: top, width: bounds.width - valueWidth - 10, height: pitch), font: label, color: A2.secondary)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { lines.map { "\($0.label) \($0.value)" }.joined(separator: ", ") }
}

/// A hairline across the view's top edge.
final class A2Hairline: DrawnView {
    override func draw(_ dirtyRect: NSRect) {
        A2.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
}

/// Wrapped text in one font and colour, drawn from the top.
final class A2Paragraph: DrawnView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var font = Theme.sans(11.5)
    var color = A2.secondary
    var lineHeight: CGFloat = 16

    private var attributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    func height(for width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin],
                                             attributes: attributes).height)
    }

    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// A volume control: a 5 pt track filled in the page's colours and a white capsule
/// knob. Dragging or clicking sets the value; arrow keys step it.
final class A2Slider: DrawnView {
    var value: Float = 0 { didSet { if value != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var color = A2.sound
    var end: NSColor? = A2.soundEnd
    var onChange: ((Float) -> Void)?
    private(set) var dragging = false

    private var track: NSRect { NSRect(x: 12, y: bounds.midY - 2.5, width: bounds.width - 24, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let track = self.track
        A2.meter(track, fraction: isEnabled ? Double(value) : 0, color: color, end: end)
        guard isEnabled else { return }
        let x = track.minX + track.width * CGFloat(min(1, max(0, value)))
        let knob = NSRect(x: x - 12, y: bounds.midY - 8, width: 24, height: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        shadow.set()
        A2.knob.setFill()
        NSBezierPath(roundedRect: knob, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.18).setStroke()
        let edge = NSBezierPath(roundedRect: knob.insetBy(dx: 0.25, dy: 0.25), xRadius: 8, yRadius: 8)
        edge.lineWidth = 0.5
        edge.stroke()
    }

    private func set(from event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = Float(min(1, max(0, (point.x - track.minX) / max(1, track.width))))
        guard next != value else { return }
        value = next
        onChange?(next)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dragging = true
        set(from: event)
    }

    override func mouseDragged(with event: NSEvent) { if dragging { set(from: event) } }
    override func mouseUp(with event: NSEvent) { dragging = false }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: step(-0.0625)
        case 124, 126: step(0.0625)
        default: super.keyDown(with: event)
        }
    }

    private func step(_ by: Float) {
        value = min(1, max(0, value + by))
        onChange?(value)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: Int((value * 100).rounded())) }
    override func accessibilityPerformIncrement() -> Bool { step(0.0625); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-0.0625); return true }
}

/// A toolbar action: a symbol in its colour and a short label, on the toolbar's glass capsule.
final class A2ToolbarButton: DrawnView {
    let label: String
    let symbol: String
    let tint: NSColor
    var onPress: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private static let font = Theme.sans(12, .semibold)

    init(_ label: String, symbol: String, tint: NSColor) {
        self.label = label
        self.symbol = symbol
        self.tint = tint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The capsule adds 6 pt each side: 12 pt before the icon and 14 after the text.
    override var fittingSize: NSSize { NSSize(width: 6 + 14 + 7 + A2.width(label, Self.font) + 8, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let fade: CGFloat = pressed ? 0.6 : 1
        IconTile.glyph(symbol, tint: tint.withAlphaComponent(fade), size: 14, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 6, y: (bounds.height - 14) / 2, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: nil)
        A2.draw(label, at: 27, mid: bounds.height / 2, font: Self.font, color: A2.primary.withAlphaComponent(fade))
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
