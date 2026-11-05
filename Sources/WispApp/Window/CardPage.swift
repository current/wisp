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

    /// The page's colour, for charts and the icons in card titles.
    var pageTint: NSColor { Theme.accent }
    /// The page's colour for 12 and 13 pt text and icons: darker in light mode for contrast.
    var labelTint: NSColor { pageTint }

    /// A card title in the A2 style: the card's symbol, its name, and a quieter detail after it.
    func cardTitle(_ name: String, _ detail: String) -> NSAttributedString {
        A2.title(name, symbol: Theme.symbol(for: name), tint: labelTint, detail: detail)
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

/// A small A2 card: the name under a symbol in the page's colour, one figure, an
/// optional meter and a line of context on the card's floor. `plain` drops the symbol
/// and sets a smaller figure, as on the Network page's totals.
final class Tile: CardView {
    let caption = TextLine()
    let figure = BigNumber()
    let note = TextLine()
    let meter = A2Meter()
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; needsLayout = true } }
    let name: String
    /// The page's colour for the symbol and meter; pages set it after creating their tiles.
    var tint: NSColor = Theme.accent { didSet { label(); meter.color = tint } }
    var plain = false { didSet { label(); styleFigure(); needsLayout = true } }

    init(_ name: String) {
        self.name = name
        super.init()
        figure.format = { (String(format: "%.0f", $0), "") }
        figure.color = A2.primary
        figure.unitColor = A2.secondary
        figure.unitGap = 3
        styleFigure()
        meter.isHidden = true
        label()
        for view in [caption, figure, note, meter] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label() {
        caption.text = plain
            ? NSAttributedString(string: name, attributes: [.font: Theme.sans(11.5, .medium), .foregroundColor: A2.secondary])
            : A2.title(name, symbol: Theme.symbol(for: name), tint: tint, size: 12, color: A2.secondary)
    }

    private func styleFigure() {
        figure.font = Theme.figure(plain ? 24 : 26, .semibold)
        figure.unitFont = Theme.sans(13, .medium)
        figure.kern = plain ? -0.72 : -0.91
    }

    /// Shows text in place of a counted number.
    func set(text: String, unit: String = "") { figure.show(text, unit: unit) }

    func set(note text: String, color: NSColor = Theme.inkTertiary) {
        let shown = color == Theme.inkTertiary || color == Theme.inkSecondary ? A2.secondary : color
        note.text = NSAttributedString(string: text, attributes: [.font: Theme.digits(11), .foregroundColor: shown])
    }

    override func layout() {
        super.layout()
        let width = bounds.width - A2.padSide * 2
        caption.frame = NSRect(x: A2.padSide, y: 13, width: width, height: 16)
        // The mockup's 26 pt figure sits 13 pt under the label, baseline 63 pt down; the
        // plain 24 pt one 10 pt under a smaller label.
        let baseline: CGFloat = plain ? 57 : 63
        let font = figure.font, height: CGFloat = 34
        figure.frame = NSRect(x: A2.padSide, y: (baseline - (height + font.ascender + font.descender) / 2).rounded(), width: width, height: height)
        let noteY = plain ? max(66, bounds.height - 29) : bounds.height - 27
        note.frame = NSRect(x: A2.padSide, y: noteY, width: width, height: 14)
        meter.frame = NSRect(x: A2.padSide, y: noteY - 8 - 4 + 1, width: width, height: 4)
    }
}

/// The big chart at the top of a machine page: the name in the page's colour with a
/// state badge, the figure and a sub line, a legend on the right, and a time chart that
/// runs edge to edge on the card's floor. The range switch lives in the toolbar.
final class ChartCard: CardView {
    let header = A2Header()
    let state = Pill()
    let figure = A2.figure()
    let meta = TextLine()
    let range = Segmented(["5 Min", "Hour", "Day"])
    let chart = TimeChart()
    /// A legend in the header's corner, for pages that write their own ("● Charging").
    let legend = TextLine()
    var onRange: ((Int) -> Void)?
    /// Where the chart starts, from the card's top.
    var chartTop: CGFloat = 80 { didSet { needsLayout = true } }

    var tint: NSColor = Theme.accent { didSet { chart.primaryColor = tint } }
    /// The page's colour for the name and its symbol.
    var labelTint: NSColor = Theme.accent { didSet { header.tint = labelTint; header.titleColor = labelTint } }
    let title: String
    private var bandsObserver: NSObjectProtocol?

    init(_ name: String) {
        self.title = name
        super.init()
        header.title = name
        header.symbol = Theme.symbol(for: name)
        state.isHidden = true
        chart.edgeToEdge = true
        legend.alignment = .right
        range.onChange = { [weak self] index in self?.onRange?(index) }
        for view in [header, state, figure, meta, legend, range, chart] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { bandsObserver.map(NotificationCenter.default.removeObserver) }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // The battery's charging shading assumes TimeChart's old inset plot; keep it on the
        // edge-to-edge plot instead, whoever moves it.
        guard subview is ChargeBands else { return }
        subview.postsFrameChangedNotifications = true
        bandsObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: subview, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width - A2.padSide * 2
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: width, height: 16)
        state.frame = NSRect(x: A2.padSide + header.titleRight + 10, y: 13, width: state.naturalWidth, height: 18)
        legend.frame = NSRect(x: A2.padSide + width / 2, y: A2.padTop, width: width / 2, height: 16)
        // The switch normally lives in the toolbar; place it only while it is still here.
        range.isHidden = range.superview === self && range.items.count < 2
        if range.superview === self {
            let rangeWidth = range.naturalWidth
            range.frame = NSRect(x: A2.padSide + width - rangeWidth, y: 10, width: rangeWidth, height: 26)
        }
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 71, width: width / 2)
        meta.frame = NSRect(x: A2.padSide, y: 82, width: width, height: 15)
        if meta.text.length > 0 { meta.text = A2Restyle.sub(meta.text) }
        chart.frame = NSRect(x: 0, y: chartTop, width: bounds.width, height: max(40, bounds.height - chartTop))
        for case let bands as ChargeBands in subviews {
            let plot = chart.plotRect
            let wanted = NSRect(x: chart.frame.minX + plot.minX, y: chart.frame.minY + plot.minY - 6, width: plot.width + 46, height: plot.height + 30)
            if bands.frame != wanted { bands.frame = wanted }
        }
    }
}

/// Sub lines other pages still write as captions, moved to the A2 sub-line style.
enum A2Restyle {
    static func sub(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let font = value as? NSFont, font.pointSize == 11, font.fontDescriptor.symbolicTraits.contains(.bold) == false else { return }
            result.addAttribute(.font, value: A2.subFont, range: range)
            if (result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) == Theme.inkSecondary {
                result.addAttribute(.foregroundColor, value: A2.secondary, range: range)
            }
        }
        return result
    }
}

/// A time chart with up to three series, light grid lines and a hover readout. Gaps
/// (NaN) break the line instead of joining across them. `edgeToEdge` is the A2 look:
/// the plot fills the view to its bottom edge, with dotted lines at half and the top
/// of the scale, one label for the top, and every series filled. Otherwise it keeps a
/// label column on the right and a time axis under the plot.
final class TimeChart: BitmapView {
    var primary: [Float] = [] { didSet { needsDisplay = true } }
    var secondary: [Float] = [] { didSet { needsDisplay = true } }
    var tertiary: [Float] = [] { didSet { needsDisplay = true } }
    var primaryColor: NSColor = Theme.accent
    var secondaryColor: NSColor = Theme.series[1]
    var tertiaryColor: NSColor = Theme.series[2]
    /// How strong the second and third fills are against the first's.
    var secondaryFill: CGFloat = 1
    var tertiaryFill: CGFloat = 0.2
    var ceiling: Float?
    /// The lowest the scale goes, so a near-zero series does not fill the chart.
    var minimumCeiling: Float = 0
    /// Seconds between samples, for the axis and the readout.
    var step: Double = 2
    var format: (Float) -> String = { String(format: "%.0f", $0) }
    var names = ("", "")
    var tertiaryName = ""
    /// Bars: `primary` is the whole bar, `secondary` the part of it drawn on top in its own colour
    /// (CPU total with the system share). Line: up to three lines, each filled.
    enum Style { case line, bars }
    var style: Style = .line { didSet { needsDisplay = true } }
    var edgeToEdge = false { didSet { needsDisplay = true } }
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

    /// The mockup's charts keep 28 pt above the top of the scale and end 1 pt above the edge.
    private static let edgeTop: CGFloat = 28

    /// The plot area in the view's coordinates.
    var plotRect: NSRect {
        if edgeToEdge {
            let top = Self.edgeTop + marks.inset
            return NSRect(x: 0, y: top, width: bounds.width, height: max(1, bounds.height - 1 - top))
        }
        return NSRect(x: 0, y: 6 + marks.inset, width: bounds.width - axisWidth - 6, height: bounds.height - (showsTimeAxis ? 30 : 12) - marks.inset)
    }

    private var series: [([Float], NSColor, CGFloat)] {
        [(tertiary, tertiaryColor, tertiaryFill), (secondary, secondaryColor, secondaryFill), (primary, primaryColor, 1)]
    }

    private var count: Int { max(primary.count, secondary.count, tertiary.count) }

    private var top: Float {
        if let ceiling { return ceiling }
        let peak = [primary, secondary, tertiary].map { $0.filter { !$0.isNaN }.max() ?? 0 }.max() ?? 0
        return max(Self.niceCeiling(peak), minimumCeiling)
    }

    static func niceCeiling(_ value: Float) -> Float {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for factor: Float in [1, 2, 2.5, 5, 10] where value <= factor * magnitude { return factor * magnitude }
        return 10 * magnitude
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = plotRect
        // Nothing recorded yet (a fresh launch, or an app that just started): no axes to read.
        guard [primary, secondary, tertiary].contains(where: { $0.lazy.filter { !$0.isNaN }.count > 1 }) else {
            let text = NSAttributedString(string: "Collecting history", attributes: [.font: Theme.sans(11), .foregroundColor: A2.tertiary])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }
        let top = self.top
        let bottom = min(self.bottom, top * 0.99)
        let count = self.count
        let dx = rect.width / CGFloat(max(1, count - 1))
        func y(_ value: Float) -> CGFloat { rect.maxY - CGFloat(min(1, max(0, (value - bottom) / (top - bottom)))) * rect.height }

        if edgeToEdge, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.addPath(A2.bottomRounded(bounds))
            context.clip()
            drawEdgeGrid(rect, context: context)
            if style == .bars {
                drawBars(in: rect, y: y)
            } else {
                drawEdgeSeries(rect, dx: dx, count: count, y: y, context: context)
            }
            context.restoreGState()
            let label = format(top) as NSString
            let font = Theme.digits(10)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.gridLabel]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - 16 - size.width, y: floor(rect.minY) - 5 - font.ascender), withAttributes: attributes)
        } else {
            drawInsetGrid(rect, top: top, bottom: bottom)
            if style == .bars {
                drawBars(in: rect, y: y)
            } else {
                drawInsetSeries(rect, dx: dx, count: count, y: y)
            }
        }

        marks.draw(in: rect, x: { rect.minX + CGFloat($0) * dx }, top: { [primary, secondary] index in
            let tops = [primary, secondary].compactMap { index < $0.count && !$0[index].isNaN ? $0[index] : nil }
            return tops.max().map(y)
        })

        // Time axis: the oldest point and now.
        if showsTimeAxis, !edgeToEdge {
            let span = Double(count - 1) * step
            let oldest = Theme.caption(Self.ago(span), size: 9)
            oldest.draw(at: NSPoint(x: rect.minX, y: rect.maxY + 8))
            let now = Theme.caption("Now", size: 9)
            now.draw(at: NSPoint(x: rect.maxX - now.size().width, y: rect.maxY + 8))
        }

        if let index = hoverIndex, index < count, marks.hovered == nil { drawReadout(index, rect: rect, dx: dx, count: count, y: y) }
    }

    /// Dotted lines at half and at the top of the scale.
    private func drawEdgeGrid(_ rect: NSRect, context: CGContext) {
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 4])
        for fraction: CGFloat in [0.5, 1] {
            let lineY = floor(rect.maxY - fraction * rect.height) + 0.5
            context.move(to: CGPoint(x: 0, y: lineY))
            context.addLine(to: CGPoint(x: bounds.width, y: lineY))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Each series as a line over a fill that fades down the full height to the floor.
    private func drawEdgeSeries(_ rect: NSRect, dx: CGFloat, count: Int, y: (Float) -> CGFloat, context: CGContext) {
        let alpha: CGFloat = A2.drawingDark ? 0.32 : 0.2
        for (values, color, strength) in series where values.count > 1 {
            let offset = count - values.count
            let runs = A2.runs(values, x: { rect.minX + CGFloat($0 + offset) * dx }, y: y)
            for run in runs {
                let area = CGMutablePath()
                area.move(to: CGPoint(x: run[0].x, y: bounds.height))
                run.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: run[run.count - 1].x, y: bounds.height))
                area.closeSubpath()
                A2.fade(area, color: color, alpha: alpha * strength, from: rect.minY, to: bounds.height, in: context)
            }
            context.setStrokeColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
            context.setLineWidth(1.8)
            context.setLineJoin(.round)
            for run in runs {
                context.addLines(between: run)
                context.strokePath()
            }
        }
    }

    /// Grid at the bottom, half and top, with labels on the right.
    private func drawInsetGrid(_ rect: NSRect, top: Float, bottom: Float) {
        let axisFont = Theme.digits(10)
        for fraction: CGFloat in [0, 0.5, 1] {
            let y = rect.maxY - fraction * rect.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y + 0.5))
            path.line(to: NSPoint(x: rect.maxX, y: y + 0.5))
            if fraction > 0 { path.setLineDash([2, 3], count: 2, phase: 0) }
            A2.grid.setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = format(bottom + (top - bottom) * Float(fraction)) as NSString
            label.draw(at: NSPoint(x: rect.maxX + 6, y: y - 7), withAttributes: [.font: axisFont, .foregroundColor: A2.gridLabel])
        }
    }

    private func drawInsetSeries(_ rect: NSRect, dx: CGFloat, count: Int, y: (Float) -> CGFloat) {
        for (values, color, strength) in series where values.count > 1 {
            let offset = count - values.count
            var segment: [NSPoint] = []
            func flush() {
                guard segment.count > 1 else { segment.removeAll(); return }
                let line = NSBezierPath()
                line.move(to: segment[0])
                segment.dropFirst().forEach { line.line(to: $0) }
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: segment.last!.x, y: rect.maxY))
                area.line(to: NSPoint(x: segment[0].x, y: rect.maxY))
                area.close()
                NSGradient(starting: color.withAlphaComponent(0.22 * strength), ending: color.withAlphaComponent(0.04 * strength))?.draw(in: area, angle: -90)
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

    private func drawReadout(_ index: Int, rect: NSRect, dx: CGFloat, count: Int, y: (Float) -> CGFloat) {
        let x = rect.minX + CGFloat(index) * dx
        A2.tertiary.setFill()
        NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
        var lines: [(NSColor, Float, String)] = []
        for (values, color, name) in [(primary, primaryColor, names.0), (secondary, secondaryColor, names.1), (tertiary, tertiaryColor, tertiaryName)] {
            let at = index - (count - values.count)
            guard at >= 0, at < values.count, !values[at].isNaN else { continue }
            lines.append((color, values[at], (name.isEmpty ? "" : name + "  ") + format(values[at])))
        }
        for (color, value, _) in lines {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 3, y: y(value) - 3, width: 6, height: 6)).fill()
        }
        let when = Self.ago(Double(count - 1 - index) * step)
        let text = ([when] + lines.map(\.2)).joined(separator: "   ") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        var box = NSRect(x: x + 8, y: rect.minY, width: size.width + 16, height: 22)
        if box.maxX > rect.maxX { box.origin.x = x - 8 - box.width }
        Theme.tooltip.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
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
        let count = self.count
        guard count > 1 else { return }
        let plot = plotRect
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

/// A sortable list of rows with an icon, drawn in one view, in the A2 table style:
/// quiet column titles, 22 pt icons, hairlines between rows, the bar column's figure in
/// bold and the rest quieter. Used for the app lists on machine pages: a few dozen rows,
/// so drawing all of them is cheaper than a table view with cell reuse.
final class ColumnTable: BitmapView {
    struct Column {
        var title: String
        var width: CGFloat
        var right = true
        var bar = false
        /// For a bar column: the room its figure takes at the right of the column.
        var valueWidth: CGFloat = 55
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
    var rowHeight: CGFloat = 34 { didSet { if rowHeight != oldValue { needsDisplay = true } } }
    let headerHeight: CGFloat = 22
    /// Space at each side, so the hover wash reaches a little past the icons and figures.
    var inset: CGFloat = 8
    /// The bar's colours: the column's own, fading into a lighter one.
    var barColor: NSColor = A2.cpu
    var barEnd: NSColor? = A2.cpuLight
    private var hoverRow: Int?

    var naturalHeight: CGFloat { headerHeight + CGFloat(rows.count) * rowHeight }

    private static let spacing: CGFloat = 11
    private static let iconSize: CGFloat = 22

    private func columnFrames() -> [NSRect] {
        let fixed = columns.dropFirst().reduce(0) { $0 + $1.width + Self.spacing }
        let first = max(120, bounds.width - inset * 2 - fixed)
        var x = inset
        return columns.enumerated().map { index, column in
            let width = index == 0 ? first : column.width
            defer { x += width + Self.spacing }
            return NSRect(x: x, y: 0, width: width, height: rowHeight)
        }
    }

    /// The column whose figure is bold: the bar column, else the first after the name.
    private var strongColumn: Int { columns.firstIndex(where: \.bar) ?? 1 }

    override func draw(_ dirtyRect: NSRect) {
        let frames = columnFrames()
        let headerFont = Theme.sans(11, .medium)
        for (index, column) in columns.enumerated() {
            let color = index == sortColumn && index > 0 ? A2.secondary : A2.tertiary
            let width = A2.width(column.title, headerFont)
            let frame = frames[index]
            let x = column.right && index > 0 ? frame.maxX - width : frame.minX + (index == 0 && rows.contains { $0.icon != nil } ? Self.iconSize + Self.spacing : 0)
            A2.draw(column.title, at: x, mid: headerHeight / 2, font: headerFont, color: color)
        }

        let first = max(0, Int((dirtyRect.minY - headerHeight) / rowHeight))
        let last = min(rows.count, Int((dirtyRect.maxY - headerHeight) / rowHeight) + 1)
        guard first < last else { return }
        let strong = strongColumn
        for index in first..<last {
            let row = rows[index]
            let top = headerHeight + CGFloat(index) * rowHeight
            let mid = top + rowHeight / 2
            let wash = NSRect(x: 0, y: top + 2, width: bounds.width, height: rowHeight - 4)
            if row.id == selectedID {
                Theme.accentLow.setFill()
                NSBezierPath(roundedRect: wash, xRadius: 8, yRadius: 8).fill()
            } else if index == hoverRow {
                A2.rowHover.setFill()
                NSBezierPath(roundedRect: wash, xRadius: 8, yRadius: 8).fill()
            } else if index > 0, index - 1 != hoverRow, rows[index - 1].id != selectedID {
                A2.hairline.setFill()
                NSRect(x: inset, y: top, width: bounds.width - inset * 2, height: 0.5).fill()
            }
            for (column, text) in row.cells.enumerated() where column < columns.count {
                let frame = frames[column].offsetBy(dx: 0, dy: top)
                if column == 0 {
                    var x = frame.minX
                    if let icon = row.icon {
                        icon.draw(in: NSRect(x: x, y: (mid - Self.iconSize / 2).rounded(), width: Self.iconSize, height: Self.iconSize), from: .zero,
                                  operation: .sourceOver, fraction: row.faint ? 0.5 : 1, respectFlipped: true, hints: nil)
                        x += Self.iconSize + Self.spacing
                    }
                    A2.drawTruncated(text, in: NSRect(x: x, y: frame.minY, width: frame.maxX - x, height: rowHeight), font: A2.rowFont,
                                     color: row.faint ? A2.tertiary : A2.primary)
                    continue
                }
                let spec = columns[column]
                let quiet = row.faint || text == "–"
                let font = column == strong ? A2.valueFont : A2.quietValueFont
                let color = quiet ? A2.tertiary : (column == strong ? A2.primary : A2.secondary)
                var textFrame = frame
                if spec.bar {
                    let bar = NSRect(x: frame.minX, y: mid - 2.5, width: max(0, frame.width - spec.valueWidth - Self.spacing), height: 5)
                    A2.meter(bar, fraction: max(0.012, row.fraction), color: barColor, end: barEnd)
                    textFrame = NSRect(x: frame.maxX - spec.valueWidth, y: frame.minY, width: spec.valueWidth, height: frame.height)
                }
                A2.drawTruncated(text, in: textFrame, font: font, color: color, alignment: spec.right ? .right : .left)
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

    /// A row and the hairline under it, which hover hides.
    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: headerHeight + CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight + 1)
    }

    override func mouseMoved(with event: NSEvent) {
        let index = rowIndex(convert(event.locationInWindow, from: nil))
        if index != hoverRow {
            for row in [hoverRow, index].compactMap({ $0 }) { setNeedsDisplay(rowRect(row)) }
            hoverRow = index
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let row = hoverRow {
            hoverRow = nil
            setNeedsDisplay(rowRect(row))
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
