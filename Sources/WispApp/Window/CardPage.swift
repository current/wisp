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
    /// Space at the page's sides and foot; the first row of cards starts right under the toolbar.
    static let margin: CGFloat = 22
    var margin: CGFloat { Self.margin }
    let gap: CGFloat = 12
    /// The toolbar floats over the top of the page; content starts under it and scrolls beneath.
    static let topInset: CGFloat = Toolbar.height - margin
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
        // No title bar to keep clear of; insets would start the page scrolled.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.topInset, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: Toolbar.height - 8, left: 0, bottom: 0, right: 0)
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
        let first = arrangedWidth == 0
        arrangedWidth = width
        let before = first ? [:] : Dictionary(uniqueKeysWithValues: canvas.subviews.map { (ObjectIdentifier($0), $0.frame.origin) })
        let height = max(arrange(width: width), scroll.contentSize.height - Self.topInset)
        glide(from: before)
        if canvas.frame.size != NSSize(width: width, height: height) {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        // WISP_SCROLL=bottom shows the end of the page, for screenshots.
        if ProcessInfo.processInfo.environment["WISP_SCROLL"] == "bottom" {
            canvas.scroll(NSPoint(x: 0, y: max(0, height - scroll.contentSize.height)))
        } else if first, let points = ProcessInfo.processInfo.environment["WISP_SCROLL"].flatMap(Double.init) {
            // WISP_SCROLL=<points> scrolls part of the way, for screenshots.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -Self.topInset + points))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if first {
            scrollToTop()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if ProcessInfo.processInfo.environment["WISP_SCROLL"] == nil { scrollToTop() }
    }

    func scrollToTop() {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -Self.topInset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func arrange(width: CGFloat) -> CGFloat { 0 }

    /// Cards that jumped to a new row or column (the grid changed its column count)
    /// glide there from where they were instead of snapping. A transform animation
    /// on each moved card; small, continuous moves are left alone.
    private func glide(from before: [ObjectIdentifier: NSPoint]) {
        guard !before.isEmpty, !Theme.reduceMotion, view.window?.isVisible == true else { return }
        for card in canvas.subviews {
            guard let old = before[ObjectIdentifier(card)], let layer = card.layer, !card.isHidden else { continue }
            let dx = old.x - card.frame.minX, dy = old.y - card.frame.minY
            guard hypot(dx, dy) > 40 else { continue }
            let move = CABasicAnimation(keyPath: "transform.translation")
            move.fromValue = NSValue(size: NSSize(width: dx, height: dy))
            move.toValue = NSValue(size: .zero)
            move.isAdditive = true
            move.duration = 0.32
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            layer.add(move, forKey: "glide")
        }
    }

    /// The page's colour, for the icon tiles in card titles.
    var pageTint: NSColor { Theme.accent }

    /// A card title: the card's icon tile, its name, and a quieter detail after it.
    func cardTitle(_ name: String, _ detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: Theme.header(name, symbol: Theme.symbol(for: name), tint: pageTint,
                                                                            size: 14, tile: 20, color: Theme.ink, weight: .semibold))
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: Theme.sans(13), .foregroundColor: Theme.inkTertiary]))
        }
        return text
    }

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
        let rows = (views.count + columns - 1) / columns
        // A short last row stretches across the width instead of leaving a hole.
        let lastCount = views.count - (rows - 1) * columns
        let lastCell = (inner - gap * CGFloat(lastCount - 1)) / CGFloat(lastCount)
        for (index, view) in views.enumerated() {
            let row = index / columns
            let width = row == rows - 1 ? lastCell : cell
            let x = margin + CGFloat(index % columns) * (width + gap)
            let y = top + CGFloat(row) * (height + gap)
            view.frame = NSRect(x: x, y: y, width: width, height: height).integral
        }
        return top + CGFloat(rows) * height + CGFloat(rows - 1) * gap
    }

    /// Page heading: a title and a caption line under it. They live in the toolbar.
    private(set) var headingLines: (TextLine, TextLine)?

    func heading(_ title: String) -> (TextLine, TextLine) {
        let lines = (TextLine(Toolbar.title(title)), TextLine())
        headingLines = lines
        return lines
    }

    var toolbarHeading: (NSView, NSView)? { headingLines.map { ($0.0, $0.1) } }
    var toolbarItems: [NSView] { [] }
    var pageScroll: NSScrollView? { scroll }

    /// Headings sit in the toolbar now; the cards start at the top margin.
    func place(_ title: TextLine, _ caption: TextLine, width: CGFloat) -> CGFloat { margin }
}

/// A small card with a caption, one figure and a line of context under it, and
/// optionally a tick meter.
final class Tile: CardView {
    let caption = TextLine()
    let figure = BigNumber()
    let note = TextLine()
    let meter = TickMeter()
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; needsLayout = true } }
    let name: String
    /// The page's colour for the icon tile; pages set it after creating their tiles.
    var tint: NSColor = Theme.accent { didSet { caption.text = Theme.header(name, symbol: Theme.symbol(for: name), tint: tint) } }

    init(_ name: String) {
        self.name = name
        super.init()
        caption.text = Theme.header(name, symbol: Theme.symbol(for: name), tint: tint)
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
        caption.frame = NSRect(x: 16, y: 12, width: width, height: 22)
        figure.frame = NSRect(x: 16, y: 38, width: width, height: 30)
        if showsMeter {
            note.frame = NSRect(x: 16, y: bounds.height - 40, width: width, height: 14)
            meter.frame = NSRect(x: 16, y: bounds.height - 20, width: width, height: 8)
        } else {
            note.frame = NSRect(x: 16, y: bounds.height - 28, width: width, height: 14)
        }
    }

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

    var tint: NSColor = Theme.accent { didSet { setHeader() } }
    let title: String
    private var name: String { title }

    private func setHeader() {
        caption.text = Theme.header(name, symbol: Theme.symbol(for: name), tint: tint, size: 14, tile: 24, color: Theme.ink, weight: .semibold)
        chart.primaryColor = tint
    }

    init(_ name: String) {
        self.title = name
        super.init()
        figure.font = Theme.figure(40, .regular)
        figure.unitFont = Theme.sans(17)
        state.isHidden = true
        range.onChange = { [weak self] index in self?.onRange?(index) }
        for view in [caption, state, figure, meta, range, chart, legend] as [NSView] { addSubview(view) }
        setHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        caption.frame = NSRect(x: 20, y: 14, width: caption.naturalWidth + 4, height: 26)
        state.frame = NSRect(x: caption.frame.maxX + 8, y: 17, width: state.naturalWidth, height: 18)
        let rangeWidth = range.naturalWidth
        // The switch normally lives in the toolbar; place it only while it is still here.
        if range.superview === self { range.frame = NSRect(x: 20 + width - rangeWidth, y: 14, width: rangeWidth, height: 26) }
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
    /// The lowest the scale goes, so a near-zero series does not fill the chart.
    var minimumCeiling: Float = 0
    /// Seconds between samples, for the axis and the readout.
    var step: Double = 2
    var format: (Float) -> String = { String(format: "%.0f", $0) }
    var names = ("", "")
    /// Bars: `primary` is the whole bar, `secondary` the part of it drawn on top in its own colour
    /// (CPU total with the system share). Line: two lines, the primary filled.
    enum Style { case line, bars }
    var style: Style = .line { didSet { needsDisplay = true } }
    /// The time labels under the plot; compact cards leave them off.
    var showsTimeAxis = true { didSet { needsDisplay = true } }
    /// The value at the bottom of the scale, for series that never reach zero (memory, temperature).
    var bottom: Float = 0 { didSet { needsDisplay = true } }
    /// Width of the label column on the right.
    var axisWidth: CGFloat = 40
    private var hoverIndex: Int?
    /// Labelled spikes (Shared/Charts.swift); clicking one calls `onSpike`.
    let marks = SpikeMarks()
    var spikes: [ChartSpike] { get { marks.spikes } set { marks.spikes = newValue; marks.color = primaryColor; needsDisplay = true } }
    var onSpike: ((ChartSpike) -> Void)?

    private var plot: NSRect {
        NSRect(x: 0, y: 6 + marks.inset, width: bounds.width - axisWidth - 6, height: bounds.height - (showsTimeAxis ? 30 : 12) - marks.inset)
    }

    private var top: Float {
        if let ceiling { return ceiling }
        let peak = max(primary.filter { !$0.isNaN }.max() ?? 0, secondary.filter { !$0.isNaN }.max() ?? 0)
        return max(Self.niceCeiling(peak), minimumCeiling)
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
        let bottom = min(self.bottom, top * 0.99)
        let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        // Grid at the bottom, half and top, with labels on the right.
        for fraction: CGFloat in [0, 0.5, 1] {
            let y = rect.maxY - fraction * rect.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y + 0.5))
            path.line(to: NSPoint(x: rect.maxX, y: y + 0.5))
            if fraction > 0 { path.setLineDash([2, 3], count: 2, phase: 0) }
            Theme.rule.setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = format(bottom + (top - bottom) * Float(fraction)) as NSString
            label.draw(at: NSPoint(x: rect.maxX + 6, y: y - 7), withAttributes: [.font: axisFont, .foregroundColor: Theme.inkSecondary])
        }
        let count = max(primary.count, secondary.count)
        guard count > 1 else {
            Theme.caption("Collecting", size: 9.5).draw(at: NSPoint(x: rect.midX - 28, y: rect.midY - 6))
            return
        }
        let dx = rect.width / CGFloat(count - 1)
        func y(_ value: Float) -> CGFloat { rect.maxY - CGFloat(min(1, max(0, (value - bottom) / (top - bottom)))) * rect.height }

        if style == .bars {
            drawBars(in: rect, y: y)
        } else {
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
                    NSGradient(starting: color.withAlphaComponent(0.22), ending: color.withAlphaComponent(0.02))?.draw(in: area, angle: -90)
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
        }

        marks.draw(in: rect, x: { rect.minX + CGFloat($0) * dx }, top: { [primary, secondary] index in
            let tops = [primary, secondary].compactMap { index < $0.count && !$0[index].isNaN ? $0[index] : nil }
            return tops.max().map(y)
        })

        // Time axis: the oldest point and now.
        if showsTimeAxis {
            let span = Double(count - 1) * step
            let oldest = Theme.caption(Self.ago(span), size: 9)
            oldest.draw(at: NSPoint(x: rect.minX, y: rect.maxY + 8))
            let now = Theme.caption("Now", size: 9)
            now.draw(at: NSPoint(x: rect.maxX - now.size().width, y: rect.maxY + 8))
        }

        if let index = hoverIndex, index < count, marks.hovered == nil {
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

    /// Stacked bars, newest on the right, as many as fit at a comfortable width.
    private func drawBars(in rect: NSRect, y: (Float) -> CGFloat) {
        let pitch: CGFloat = 12.5, width: CGFloat = 9
        let slots = max(1, Int((rect.width + pitch - width) / pitch))
        let totals = Array(primary.suffix(slots))
        let tops = Array(secondary.suffix(totals.count))
        let start = rect.maxX - CGFloat(totals.count - 1) * pitch - width
        for (index, total) in totals.enumerated() where !total.isNaN {
            let x = start + CGFloat(index) * pitch
            let full = NSRect(x: x, y: y(total), width: width, height: max(2, rect.maxY - y(total)))
            let share = index < tops.count && !tops[index].isNaN ? min(tops[index], total) : 0
            let upper = NSRect(x: x, y: full.minY, width: width, height: max(0, rect.maxY - y(share)))
            let lower = NSRect(x: x, y: upper.maxY, width: width, height: max(0, full.maxY - upper.maxY))
            primaryColor.setFill()
            NSBezierPath(roundedRect: lower, xRadius: 2, yRadius: 2).fill()
            if upper.height > 0.5 {
                secondaryColor.setFill()
                NSBezierPath(roundedRect: upper, xRadius: 2, yRadius: 2).fill()
                if lower.height > 2 { NSRect(x: x, y: upper.maxY - 2, width: width, height: 2).fill() }
            }
        }
    }

    static func ago(_ seconds: Double) -> String {
        if seconds < 1 { return "Now" }
        if seconds < 90 { return "\(Int(seconds)) s ago" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min ago" }
        if seconds >= 172_800 { return "\(Int((seconds / 86400).rounded())) days ago" }
        return "\(Int((seconds / 3600).rounded())) h ago"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if marks.hover(at: convert(event.locationInWindow, from: nil)) { needsDisplay = true }
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

    override func mouseDown(with event: NSEvent) {
        if let spike = marks.hit(convert(event.locationInWindow, from: nil)) { onSpike?(spike) } else { super.mouseDown(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        _ = marks.hover(at: nil)
        hoverIndex = nil
        needsDisplay = true
    }
}

/// A sortable list of rows with an icon, drawn in one view. Used for the app
/// lists on machine pages: a few dozen rows, so drawing all of them is cheaper
/// than a table view with cell reuse.
final class ColumnTable: BitmapView {
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
            } else if index % 2 == 1 {
                Theme.stripe.setFill()
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
