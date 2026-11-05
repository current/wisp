import AppKit
import WispCore

// A2 views for the Storage, Battery and Clean Up pages, built on the tokens in
// A2Cards.swift. Lists and charts draw into their own bitmap and redraw only when
// their rows or values change.

/// A capsule button 30 pt tall with a 13 pt label: grey with the A2 pill colours, or
/// the accent with white text for the main action.
final class A2Button: DrawnView {
    var title: String { didSet { if title != oldValue { needsDisplay = true } } }
    var primary = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private static let font = Theme.sans(13, .semibold)
    private static let accent = Theme.dynamic(0x007AFF, 0x0A84FF)
    private static let accentPressed = Theme.dynamic(0x0062CC, 0x0070DD)

    init(_ title: String, primary: Bool = false) {
        self.title = title
        self.primary = primary
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var naturalWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 28 }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = primary ? (pressed ? Self.accentPressed : Self.accent) : (pressed ? A2.pillPressed : A2.pill)
        fill.withAlphaComponent(isEnabled ? fill.alphaComponent : fill.alphaComponent * 0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let color: NSColor = primary ? .white : A2.pillText
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color.withAlphaComponent(isEnabled ? 1 : 0.5)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// A small figure card, 96 pt tall: a quiet 11.5 pt label, a 24 pt figure with a 13 pt
/// unit and a sub line. It keeps the `set(text:)` and `set(note:)` calls of `Tile`.
final class A2SmallTile: CardView {
    let name: String
    private let caption = TextLine(), figure = TextLine(), note = TextLine()
    private static let captionFont = Theme.sans(11.5, .medium)
    private static let figureFont = Theme.figure(24, .semibold)
    private static let unitFont = Theme.sans(13, .medium)
    static let height: CGFloat = 96

    init(_ name: String) {
        self.name = name
        super.init()
        caption.text = NSAttributedString(string: name, attributes: [.font: Self.captionFont, .foregroundColor: A2.secondary])
        for view in [caption, figure, note] { addSubview(view) }
        set(text: "–")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, unit: String = "") {
        let line = NSMutableAttributedString(string: text, attributes: [.font: Self.figureFont, .foregroundColor: A2.primary, .kern: -0.72])
        if !unit.isEmpty {
            line.append(NSAttributedString(string: " " + unit, attributes: [.font: Self.unitFont, .foregroundColor: A2.secondary, .kern: -0.13]))
        }
        figure.text = line
    }

    func set(note text: String, color: NSColor = A2.secondary) {
        note.text = NSAttributedString(string: text, attributes: [.font: A2.subFont, .foregroundColor: color])
    }

    /// The width the label, figure and sub line need on one line each, with the card's padding.
    var naturalWidth: CGFloat { max(caption.naturalWidth, figure.naturalWidth, note.naturalWidth) + A2.padSide * 2 }

    override func layout() {
        super.layout()
        let width = bounds.width - A2.padSide * 2
        caption.frame = NSRect(x: A2.padSide, y: A2.padTop, width: width, height: 15)
        figure.frame = NSRect(x: A2.padSide, y: 36, width: width, height: 30)
        note.frame = NSRect(x: A2.padSide, y: 68, width: width, height: 15)
    }

    override func accessibilityValue() -> Any? { figure.text.string + ", " + note.text.string }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

/// Rows drawn in one view, in the A2 list style: a 22 pt icon or a tinted symbol tile,
/// a name with an optional quieter line under it, an optional meter, a value and an
/// optional quieter second value. Hairlines between rows; rows that open something
/// answer the pointer. `rowHeight` is set by the card so the rows fill it.
final class A2List: BitmapView {
    struct Row: Equatable {
        var id: String
        var name: String
        var note = ""
        var value = ""
        var second = ""
        /// A meter is drawn when this is set.
        var fraction: Double?
        var icon: NSImage?
        var symbol: String?
        var tint: NSColor = A2.secondary
        var opens = false
        var faint = false
        /// A file or folder Finder can show.
        var path: String?
    }

    /// Column titles over the rows: over the names, the meters and the second values.
    struct Header: Equatable {
        var name: String
        var meter: String
        var second: String
    }

    var rows: [Row] = [] { didSet { if rows != oldValue { needsDisplay = true } } }
    var header: Header? { didSet { needsDisplay = true } }
    var rowHeight: CGFloat = 40 { didSet { if rowHeight != oldValue { needsDisplay = true } } }
    var meterWidth: CGFloat = 96
    var meterColors: (NSColor, NSColor?) = (A2.cpu, A2.cpuLight) { didSet { needsDisplay = true } }
    var valueWidth: CGFloat = 52
    /// Nil fits the column to its widest value.
    var secondWidth: CGFloat? = 48
    var onOpen: ((Row) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    static let headerHeight: CGFloat = 22
    private static let spacing: CGFloat = 11
    private static let nameFont = Theme.sans(13, .medium)
    private static let noteFont = Theme.sans(11)
    private static let valueFont = Theme.digits(12.5, .semibold)
    private static let secondFont = Theme.digits(12.5, .medium)
    private static let tileFill = A2.dynamic(NSColor(white: 0, alpha: 0.05), NSColor(white: 1, alpha: 0.09))

    private var top: CGFloat { header == nil ? 0 : Self.headerHeight }
    var naturalHeight: CGFloat { top + CGFloat(rows.count) * rowHeight }
    /// The height left for rows when the list is `height` tall.
    func roomForRows(_ height: CGFloat) -> CGFloat { height - top }

    private func rect(_ index: Int) -> NSRect { NSRect(x: 0, y: top + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight) }

    private struct Columns {
        var second: CGFloat, value: CGFloat, meter: CGFloat, name: CGFloat, nameRight: CGFloat
    }

    private var columns: Columns {
        let secondRight = bounds.width
        let hasSecond = rows.contains { !$0.second.isEmpty } || !(header?.second.isEmpty ?? true)
        let fitted = secondWidth ?? ceil(rows.map { ($0.second as NSString).size(withAttributes: [.font: Self.secondFont]).width }.max() ?? 0)
        let valueRight = hasSecond ? secondRight - fitted - (valueWidth > 0 ? Self.spacing : 0) : secondRight
        let hasMeter = rows.contains { $0.fraction != nil }
        let meterX = hasMeter ? valueRight - valueWidth - Self.spacing - meterWidth : valueRight - valueWidth
        let iconWidth: CGFloat = rows.contains { $0.icon != nil || $0.symbol != nil } ? 22 + Self.spacing : 0
        return Columns(second: secondRight, value: valueRight, meter: meterX, name: iconWidth, nameRight: meterX - Self.spacing)
    }

    override func draw(_ dirtyRect: NSRect) {
        let columns = columns
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        if let header {
            let attributes: [NSAttributedString.Key: Any] = [.font: A2.legendFont, .foregroundColor: A2.tertiary]
            let y = (Self.headerHeight - (A2.legendFont.ascender - A2.legendFont.descender)) / 2
            (header.name as NSString).draw(at: NSPoint(x: columns.name, y: y), withAttributes: attributes)
            (header.meter as NSString).draw(at: NSPoint(x: columns.meter, y: y), withAttributes: attributes)
            let width = (header.second as NSString).size(withAttributes: attributes).width
            (header.second as NSString).draw(at: NSPoint(x: columns.second - width, y: y), withAttributes: attributes)
        }
        let first = max(0, Int((dirtyRect.minY - top) / rowHeight))
        let last = min(rows.count, Int((dirtyRect.maxY - top) / rowHeight) + 1)
        guard first < last else { return }
        for index in first..<last {
            let row = rows[index]
            let frame = rect(index)
            let center = frame.midY
            if index == hovered {
                A2.rowHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: -6, y: frame.minY + 2, width: bounds.width + 12, height: frame.height - 4), xRadius: 8, yRadius: 8).fill()
            } else if index > 0, index - 1 != hovered {
                A2.hairline.setFill()
                NSRect(x: 0, y: frame.minY, width: bounds.width, height: 0.5).fill()
            }
            let iconRect = NSRect(x: 0, y: center - 11, width: 22, height: 22)
            if let icon = row.icon {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if let symbol = row.symbol {
                (row.faint ? Self.tileFill : row.tint.withAlphaComponent(A2.drawingDark ? 0.14 : 0.12)).setFill()
                NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6).fill()
                IconTile.glyph(symbol, tint: row.faint ? A2.secondary : row.tint, size: 13, appearance: effectiveAppearance)
                    .draw(in: NSRect(x: 4.5, y: center - 6.5, width: 13, height: 13), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            }
            let room = max(0, columns.nameRight - columns.name)
            let nameLine = Self.nameFont.ascender - Self.nameFont.descender
            let noteLine = Self.noteFont.ascender - Self.noteFont.descender
            let textTop = row.note.isEmpty ? center - nameLine / 2 : center - (nameLine + 2 + noteLine) / 2
            (row.name as NSString).draw(with: NSRect(x: columns.name, y: textTop, width: room, height: ceil(nameLine)),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: Self.nameFont, .foregroundColor: row.faint ? A2.secondary : A2.primary,
                                                     .paragraphStyle: truncating])
            if !row.note.isEmpty {
                (row.note as NSString).draw(with: NSRect(x: columns.name, y: textTop + nameLine + 2, width: room, height: ceil(noteLine)),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: [.font: Self.noteFont, .foregroundColor: A2.tertiary, .paragraphStyle: truncating])
            }
            if let fraction = row.fraction {
                let meter = NSRect(x: columns.meter, y: center - 2.5, width: meterWidth, height: 5)
                A2.meterTrack.setFill()
                NSBezierPath(roundedRect: meter, xRadius: 2.5, yRadius: 2.5).fill()
                let filled = NSRect(x: meter.minX, y: meter.minY, width: max(2, meter.width * CGFloat(min(1, max(0, fraction)))), height: 5)
                let shape = NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5)
                if let end = meterColors.1 {
                    NSGradient(starting: meterColors.0, ending: end)?.draw(in: shape, angle: 0)
                } else {
                    meterColors.0.setFill()
                    shape.fill()
                }
            }
            let quiet = row.faint || row.value == "–"
            let valueAttributes: [NSAttributedString.Key: Any] = [.font: quiet ? Self.secondFont : Self.valueFont,
                                                                  .foregroundColor: quiet ? A2.secondary : A2.primary]
            let valueSize = (row.value as NSString).size(withAttributes: valueAttributes)
            (row.value as NSString).draw(at: NSPoint(x: columns.value - valueSize.width, y: center - valueSize.height / 2), withAttributes: valueAttributes)
            if !row.second.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: Self.secondFont, .foregroundColor: A2.secondary]
                let size = (row.second as NSString).size(withAttributes: attributes)
                (row.second as NSString).draw(at: NSPoint(x: columns.second - size.width, y: center - size.height / 2), withAttributes: attributes)
            }
        }
    }

    private func index(at point: NSPoint) -> Int? {
        guard point.y >= top else { return nil }
        let index = Int((point.y - top) / rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    private func answers(_ index: Int?) -> Int? {
        guard let index, rows[index].opens || rows[index].path != nil else { return nil }
        return index
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = answers(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}

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
    override func accessibilityValue() -> Any? {
        rows.prefix(16).map { [$0.name, $0.value, $0.second].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "; ")
    }
}

/// Battery charge over the last day or week: a green line with a soft fill, the time
/// spent charging as light bands behind it, a dotted line at half and a line at full,
/// and one scale label. It runs edge to edge on the card's bottom edge. Hovering
/// shows the charge at that time.
final class A2ChargeChart: BitmapView {
    /// Percent, NaN where nothing was logged; the newest last.
    var levels: [Float] = [] { didSet { if !A2.same(levels, oldValue) { needsDisplay = true } } }
    var charging: [Bool] = [] { didSet { if charging != oldValue { needsDisplay = true } } }
    /// Seconds between samples.
    var step: Double = 300
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }

    static let line = Theme.dynamic(0x34C759, 0x30D158)
    private static let band = A2.dynamic(Theme.hex(0x34C759, alpha: 0.14), Theme.hex(0x30D158, alpha: 0.13))
    /// The mockup's 178 pt chart puts full charge 29 pt down and empty on the bottom edge.
    private static let topGap: CGFloat = 29

    private func y(_ value: Float) -> CGFloat {
        let low = bounds.height - 1
        return low - CGFloat(min(100, max(0, value)) / 100) * (low - Self.topGap)
    }

    private var dx: CGFloat { bounds.width / CGFloat(max(1, max(levels.count, charging.count) - 1)) }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 40, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(A2.bottomRounded(bounds))
        context.clip()
        if charging.count > 1, charging.contains(true) {
            context.setFillColor((Self.band.usingColorSpace(.sRGB) ?? Self.band).cgColor)
            var index = 0
            while index < charging.count {
                guard charging[index] else { index += 1; continue }
                let first = index
                while index < charging.count, charging[index] { index += 1 }
                let from = max(0, (CGFloat(first) - 0.5) * dx)
                let to = min(bounds.width, (CGFloat(index - 1) + 0.5) * dx)
                context.fill(CGRect(x: from, y: 0, width: max(1, to - from), height: bounds.height))
            }
        }
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        for (value, dashed) in [(Float(50), true), (Float(100), false)] {
            let lineY = floor(y(value)) + 0.5
            context.setLineDash(phase: 0, lengths: dashed ? [2, 4] : [])
            context.move(to: CGPoint(x: 0, y: lineY))
            context.addLine(to: CGPoint(x: bounds.width, y: lineY))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        let runs = A2.runs(levels, x: { CGFloat($0) * self.dx }, y: y)
        let alpha: CGFloat = A2.drawingDark ? 0.32 : 0.2
        for run in runs {
            let area = CGMutablePath()
            area.move(to: CGPoint(x: run[0].x, y: bounds.height))
            run.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: run[run.count - 1].x, y: bounds.height))
            area.closeSubpath()
            A2.fade(area, color: Self.line, alpha: alpha, from: run.map(\.y).min() ?? 0, to: bounds.height, in: context)
        }
        context.setStrokeColor((Self.line.usingColorSpace(.sRGB) ?? Self.line).cgColor)
        context.setLineWidth(1.8)
        context.setLineJoin(.round)
        for run in runs {
            context.addLines(between: run)
            context.strokePath()
        }
        context.restoreGState()

        let font = Theme.digits(10, .regular)
        let label = "100%" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.gridLabel]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.width - 14 - size.width, y: y(100) - 4 - font.ascender), withAttributes: attributes)
        if levels.allSatisfy(\.isNaN) {
            let text = A2.plain("Wisp logs the charge once a minute; the chart fills in as it does")
            let textSize = text.size()
            text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (y(50) + bounds.height) / 2 - textSize.height / 2))
        }
        drawHover()
    }

    private func drawHover() {
        guard let index = hoverIndex, levels.indices.contains(index), !levels[index].isNaN else { return }
        let x = CGFloat(index) * dx
        A2.tertiary.setFill()
        NSRect(x: x.rounded() - 0.5, y: Self.topGap - 8, width: 1, height: bounds.height - Self.topGap + 8).fill()
        let ago = Double(levels.count - 1 - index) * step
        let when = ago < 60 ? "Now" : Date(timeIntervalSinceNow: -ago).formatted(date: step >= 1800 ? .abbreviated : .omitted, time: .shortened)
        let text = String(format: "%@   %.0f%%", when, levels[index]) + (charging.indices.contains(index) && charging[index] ? "  Charging" : "")
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = NSRect(x: x + 8, y: Self.topGap - 8, width: ceil(size.width) + 16, height: 22)
        if box.maxX > bounds.width - 4 { box.origin.x = x - 8 - box.width }
        Theme.tooltip.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard levels.count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        hoverIndex = min(max(0, Int((x / dx).rounded())), levels.count - 1)
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Charge over time" }
}
