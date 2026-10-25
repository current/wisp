import AppKit
import WispCore

/// A page made of cards on the grey ground, scrolled as one canvas. Subclasses
/// add cards to `canvas` and place them in `arrange(width:)`, which returns the
/// height used. Layout runs when the width changes or a subclass asks for it.
@MainActor
class CardPage: NSViewController, Page {
    unowned let delegate: AppDelegate
    let scroll = NSScrollView()
    let canvas = Canvas()
    let margin: CGFloat = 20
    let gap: CGFloat = 12
    private var arrangedWidth: CGFloat = 0

    final class Canvas: DrawnView {
        override var mouseDownCanMoveWindow: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = Theme.ground.cgColor }
    }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var demand: Demand { [] }
    func update(system: SystemSnapshot) {}
    func update(table: ProcessTable) {}

    override func loadView() {
        canvas.wantsLayer = true
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.ground
        scroll.contentView.postsBoundsChangedNotifications = false
        view = scroll
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentSize.width
        if width != arrangedWidth { relayout() }
    }

    /// Places every card again. Call when a card's height changes.
    func relayout() {
        let width = scroll.contentSize.width
        arrangedWidth = width
        let height = max(arrange(width: width), scroll.contentSize.height)
        if canvas.frame.size != NSSize(width: width, height: height) {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        // WISP_SCROLL=bottom shows the end of the page, for screenshots.
        if ProcessInfo.processInfo.environment["WISP_SCROLL"] == "bottom" {
            canvas.scroll(NSPoint(x: 0, y: max(0, height - scroll.contentSize.height)))
        }
    }

    func arrange(width: CGFloat) -> CGFloat { 0 }

    /// Places views left to right in equal columns, wrapping to new rows. Returns the bottom edge.
    @discardableResult
    func grid(_ views: [NSView], top: CGFloat, width: CGFloat, columns: Int, height: CGFloat) -> CGFloat {
        guard !views.isEmpty else { return top }
        let inner = width - margin * 2
        // Fit as many as the width allows, then even out the rows: six tiles in
        // four columns become two rows of three.
        let fit = max(1, min(columns, Int((inner + gap) / (170 + gap))))
        let rowsNeeded = (views.count + fit - 1) / fit
        let columns = max(1, (views.count + rowsNeeded - 1) / rowsNeeded)
        let cell = (inner - gap * CGFloat(columns - 1)) / CGFloat(columns)
        for (index, view) in views.enumerated() {
            let x = margin + CGFloat(index % columns) * (cell + gap)
            let y = top + CGFloat(index / columns) * (height + gap)
            view.frame = NSRect(x: x, y: y, width: cell, height: height).integral
        }
        let rows = (views.count + columns - 1) / columns
        return top + CGFloat(rows) * height + CGFloat(rows - 1) * gap
    }

    /// Page heading: a title and a caption line under it.
    func heading(_ title: String) -> (TextLine, TextLine) {
        let titleLine = TextLine(NSAttributedString(string: title, attributes: [.font: Theme.sans(20, .medium), .foregroundColor: Theme.ink]))
        let caption = TextLine()
        canvas.addSubview(titleLine)
        canvas.addSubview(caption)
        return (titleLine, caption)
    }
}

/// A small card with a caption, one figure and a line of context under it, and
/// optionally a tick meter.
final class Tile: CardView {
    let caption = TextLine()
    let figure = BigNumber()
    let note = TextLine()
    let meter = TickMeter()
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; needsLayout = true } }
    var onClick: (() -> Void)?

    init(_ name: String) {
        super.init()
        caption.text = Theme.caption(name)
        figure.font = Theme.figure(24, .regular)
        figure.unitFont = Theme.sans(13)
        figure.format = { (String(format: "%.0f", $0), "") }
        meter.isHidden = true
        for view in [caption, figure, note, meter] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows text in place of a counted number.
    func set(text: String, unit: String = "") { figure.show(text, unit: unit) }

    func set(note text: String, color: NSColor = Theme.inkTertiary) {
        note.text = Theme.caption(text, color: color, size: 9.5)
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 32
        caption.frame = NSRect(x: 16, y: 14, width: width, height: 14)
        figure.frame = NSRect(x: 16, y: 34, width: width, height: 30)
        if showsMeter {
            note.frame = NSRect(x: 16, y: bounds.height - 48, width: width, height: 14)
            meter.frame = NSRect(x: 16, y: bounds.height - 26, width: width, height: 10)
        } else {
            note.frame = NSRect(x: 16, y: bounds.height - 28, width: width, height: 14)
        }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// The big chart at the top of a machine page: caption and state, the current
/// figure, a context line, a Live/Hour/Day switch and a time chart.
final class ChartCard: CardView {
    let caption = TextLine()
    let state = Pill()
    let figure = BigNumber()
    let meta = TextLine()
    let range = Segmented(["Live", "Hour", "Day"])
    let chart = TimeChart()
    let legend = TextLine()
    var onRange: ((Int) -> Void)?

    init(_ name: String) {
        super.init()
        caption.text = Theme.caption(name)
        figure.font = Theme.figure(40, .regular)
        figure.unitFont = Theme.sans(17)
        state.isHidden = true
        range.onChange = { [weak self] index in self?.onRange?(index) }
        for view in [caption, state, figure, meta, range, chart, legend] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        caption.frame = NSRect(x: 20, y: 18, width: caption.naturalWidth + 4, height: 16)
        state.frame = NSRect(x: caption.frame.maxX + 8, y: 17, width: state.naturalWidth, height: 18)
        let rangeWidth = range.naturalWidth
        range.frame = NSRect(x: 20 + width - rangeWidth, y: 14, width: rangeWidth, height: 26)
        figure.frame = NSRect(x: 20, y: 40, width: width / 2, height: 50)
        meta.frame = NSRect(x: 20, y: 94, width: width, height: 14)
        legend.frame = NSRect(x: 20 + width / 2, y: 60, width: width / 2, height: 14)
        legend.alignment = .right
        chart.frame = NSRect(x: 20, y: 120, width: width, height: bounds.height - 136)
    }
}

/// A time chart with one or two series, light grid lines, a time axis and a
/// hover readout. Gaps (NaN) break the line instead of joining across them.
final class TimeChart: BitmapView {
    var primary: [Float] = [] { didSet { needsDisplay = true } }
    var secondary: [Float] = [] { didSet { needsDisplay = true } }
    var primaryColor: NSColor = Theme.accent
    var secondaryColor: NSColor = Theme.series[1]
    var ceiling: Float?
    /// Seconds between samples, for the axis and the readout.
    var step: Double = 2
    var format: (Float) -> String = { String(format: "%.0f", $0) }
    var names = ("", "")
    private var hoverIndex: Int?

    private var plot: NSRect { NSRect(x: 0, y: 6, width: bounds.width - 52, height: bounds.height - 30) }

    private var top: Float {
        if let ceiling { return ceiling }
        let peak = max(primary.filter { !$0.isNaN }.max() ?? 0, secondary.filter { !$0.isNaN }.max() ?? 0)
        return Self.niceCeiling(peak)
    }

    static func niceCeiling(_ value: Float) -> Float {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for factor: Float in [1, 2, 2.5, 5, 10] where value <= factor * magnitude { return factor * magnitude }
        return 10 * magnitude
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = plot
        // Nothing recorded yet (a fresh launch, or an app that just started): no axes to read.
        guard primary.lazy.filter({ !$0.isNaN }).count > 1 || secondary.lazy.filter({ !$0.isNaN }).count > 1 else {
            let text = Theme.caption("Collecting history", size: 9.5)
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }
        let top = self.top
        let axisFont = Theme.mono(9)
        // Grid at 0, half and top, with labels on the right.
        for fraction: CGFloat in [0, 0.5, 1] {
            let y = rect.maxY - fraction * rect.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y + 0.5))
            path.line(to: NSPoint(x: rect.maxX, y: y + 0.5))
            if fraction > 0 { path.setLineDash([2, 3], count: 2, phase: 0) }
            (fraction == 0 ? Theme.cardBorder : Theme.rule).setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = format(top * Float(fraction)) as NSString
            label.draw(at: NSPoint(x: rect.maxX + 8, y: y - 6), withAttributes: [.font: axisFont, .foregroundColor: Theme.inkTertiary])
        }
        let count = max(primary.count, secondary.count)
        guard count > 1 else {
            Theme.caption("Collecting", size: 9.5).draw(at: NSPoint(x: rect.midX - 28, y: rect.midY - 6))
            return
        }
        let dx = rect.width / CGFloat(count - 1)
        func y(_ value: Float) -> CGFloat { rect.maxY - CGFloat(min(1, max(0, value / top))) * rect.height }

        for (values, color, fill) in [(secondary, secondaryColor, false), (primary, primaryColor, true)] where values.count > 1 {
            let offset = count - values.count
            var segment: [NSPoint] = []
            func flush() {
                guard segment.count > 1 else { segment.removeAll(); return }
                let line = NSBezierPath()
                line.move(to: segment[0])
                segment.dropFirst().forEach { line.line(to: $0) }
                if fill {
                    let area = line.copy() as! NSBezierPath
                    area.line(to: NSPoint(x: segment.last!.x, y: rect.maxY))
                    area.line(to: NSPoint(x: segment[0].x, y: rect.maxY))
                    area.close()
                    NSGradient(starting: color.withAlphaComponent(0.14), ending: color.withAlphaComponent(0))?.draw(in: area, angle: -90)
                }
                color.setStroke()
                line.lineWidth = 1.5
                line.lineJoinStyle = .round
                line.stroke()
                segment.removeAll()
            }
            for (index, value) in values.enumerated() {
                if value.isNaN { flush(); continue }
                segment.append(NSPoint(x: rect.minX + CGFloat(index + offset) * dx, y: y(value)))
            }
            flush()
        }

        // Time axis: the oldest point and now.
        let span = Double(count - 1) * step
        let oldest = Theme.caption(Self.ago(span), size: 9)
        oldest.draw(at: NSPoint(x: rect.minX, y: rect.maxY + 8))
        let now = Theme.caption("Now", size: 9)
        now.draw(at: NSPoint(x: rect.maxX - now.size().width, y: rect.maxY + 8))

        if let index = hoverIndex, index < count {
            let x = rect.minX + CGFloat(index) * dx
            Theme.inkTertiary.withAlphaComponent(0.5).setFill()
            NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
            var lines: [(NSColor, String)] = []
            if index < primary.count, !primary[index].isNaN { lines.append((primaryColor, (names.0.isEmpty ? "" : names.0 + "  ") + format(primary[index]))) }
            let secondaryIndex = index - (count - secondary.count)
            if secondaryIndex >= 0, secondaryIndex < secondary.count, !secondary[secondaryIndex].isNaN {
                lines.append((secondaryColor, (names.1.isEmpty ? "" : names.1 + "  ") + format(secondary[secondaryIndex])))
            }
            for (color, _) in lines {
                let value = color == primaryColor ? primary[index] : secondary[secondaryIndex]
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3, y: y(value) - 3, width: 6, height: 6)).fill()
            }
            let when = Self.ago(Double(count - 1 - index) * step)
            let text = ([when] + lines.map(\.1)).joined(separator: "   ") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            var box = NSRect(x: x + 8, y: rect.minY, width: size.width + 16, height: 22)
            if box.maxX > rect.maxX { box.origin.x = x - 8 - box.width }
            Theme.tooltip.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
        }
    }

    static func ago(_ seconds: Double) -> String {
        if seconds < 1 { return "Now" }
        if seconds < 90 { return "\(Int(seconds)) s ago" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min ago" }
        return "\(Int((seconds / 3600).rounded())) h ago"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let count = max(primary.count, secondary.count)
        guard count > 1 else { return }
        let index = Int(((x - plot.minX) / plot.width * CGFloat(count - 1)).rounded())
        let clamped = min(max(0, index), count - 1)
        if clamped != hoverIndex {
            hoverIndex = clamped
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }
}

/// A sortable list of rows with an icon, drawn in one view. Used for the app
/// lists on machine pages: a few dozen rows, so drawing all of them is cheaper
/// than a table view with cell reuse.
final class ColumnTable: DrawnView {
    struct Column {
        var title: String
        var width: CGFloat
        var right = true
        var bar = false
    }

    struct Row {
        var id: String
        var icon: NSImage?
        var cells: [String]
        var fraction: Double = 0
        var faint = false
    }

    var columns: [Column] = [] { didSet { needsDisplay = true } }
    var rows: [Row] = [] {
        didSet {
            if rows.count != oldValue.count { invalidateIntrinsicContentSize() }
            needsDisplay = true
        }
    }
    var sortColumn = 1
    var selectedID: String? { didSet { if selectedID != oldValue { needsDisplay = true } } }
    var onSort: ((Int) -> Void)?
    var onSelect: ((String) -> Void)?
    let rowHeight: CGFloat = 30
    let headerHeight: CGFloat = 30
    private var hoverRow: Int?

    var naturalHeight: CGFloat { headerHeight + CGFloat(rows.count) * rowHeight }

    private func columnFrames() -> [NSRect] {
        let fixed = columns.dropFirst().reduce(0) { $0 + $1.width + 16 }
        let first = max(120, bounds.width - fixed)
        var x: CGFloat = 0
        return columns.enumerated().map { index, column in
            let width = index == 0 ? first : column.width
            defer { x += width + (index == 0 ? 0 : 16) }
            return NSRect(x: index == 0 ? 0 : x + 16, y: 0, width: width, height: rowHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = columnFrames()
        let headerFont = Theme.mono(9.5)
        for (index, column) in columns.enumerated() {
            let sorted = index == sortColumn
            let title = Theme.caption(column.title + (sorted ? " ↓" : ""), color: sorted ? Theme.ink : Theme.inkTertiary, size: 9.5)
            let size = title.size()
            let frame = frames[index]
            let x = column.right && index > 0 ? frame.maxX - size.width : frame.minX + (index == 0 ? 8 : 0)
            title.draw(at: NSPoint(x: x, y: (headerHeight - (headerFont.ascender - headerFont.descender)) / 2))
        }
        Theme.rule.setFill()
        NSRect(x: 0, y: headerHeight - 1, width: bounds.width, height: 1).fill()

        let nameFont = Theme.sans(13)
        let figureFont = Theme.figure(12.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let first = max(0, Int((dirtyRect.minY - headerHeight) / rowHeight))
        let last = min(rows.count, Int((dirtyRect.maxY - headerHeight) / rowHeight) + 1)
        guard first < last else { return }
        for index in first..<last {
            let row = rows[index]
            let y = headerHeight + CGFloat(index) * rowHeight
            if row.id == selectedID {
                Theme.accentLow.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y + 1, width: bounds.width, height: rowHeight - 2), xRadius: 6, yRadius: 6).fill()
            } else if index == hoverRow {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y + 1, width: bounds.width, height: rowHeight - 2), xRadius: 6, yRadius: 6).fill()
            }
            for (column, text) in row.cells.enumerated() where column < columns.count {
                let frame = frames[column].offsetBy(dx: 0, dy: y)
                if column == 0 {
                    var x = frame.minX + 8
                    if let icon = row.icon {
                        icon.draw(in: NSRect(x: x, y: y + 7, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1,
                                  respectFlipped: true, hints: nil)
                        x += 24
                    }
                    (text as NSString).draw(with: NSRect(x: x, y: y + 6, width: frame.maxX - x - 4, height: 18),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: [.font: nameFont, .foregroundColor: row.faint ? Theme.inkTertiary : Theme.ink,
                                                         .paragraphStyle: paragraph])
                    continue
                }
                let attributes: [NSAttributedString.Key: Any] = [.font: figureFont,
                                                                 .foregroundColor: row.faint || text == "–" ? Theme.inkTertiary : Theme.ink]
                let size = (text as NSString).size(withAttributes: attributes)
                if columns[column].bar {
                    let bar = NSRect(x: frame.minX, y: y + rowHeight / 2 - 1.5, width: max(0, frame.width - 66), height: 3)
                    Theme.track.setFill()
                    NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                    Theme.accent.setFill()
                    var filled = bar
                    filled.size.width = max(2, bar.width * CGFloat(min(1, max(0, row.fraction))))
                    NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
                }
                let x = columns[column].right ? frame.maxX - size.width : frame.minX
                (text as NSString).draw(at: NSPoint(x: x, y: y + (rowHeight - size.height) / 2), withAttributes: attributes)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private func rowIndex(_ point: NSPoint) -> Int? {
        guard point.y > headerHeight else { return nil }
        let index = Int((point.y - headerHeight) / rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let index = rowIndex(convert(event.locationInWindow, from: nil))
        if index != hoverRow {
            for row in [hoverRow, index].compactMap({ $0 }) {
                setNeedsDisplay(NSRect(x: 0, y: headerHeight + CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight))
            }
            hoverRow = index
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let row = hoverRow {
            hoverRow = nil
            setNeedsDisplay(NSRect(x: 0, y: headerHeight + CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= headerHeight {
            if let column = columnFrames().firstIndex(where: { $0.minX <= point.x && point.x <= $0.maxX }), column > 0 {
                sortColumn = column
                needsDisplay = true
                onSort?(column)
            }
            return
        }
        if let index = rowIndex(point) {
            selectedID = rows[index].id
            onSelect?(rows[index].id)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Apps" }
    override func accessibilityValue() -> Any? {
        rows.prefix(10).map { $0.cells.joined(separator: " ") }.joined(separator: "; ")
    }
}
