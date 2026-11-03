import AppKit
import WispCore

/// Recent samples as thin bars, newest on the right.
final class BarHistory: BitmapView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var ceiling: Float?
    var color: NSColor = Theme.accent
    var pitch: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        let count = Int(bounds.width / pitch)
        let shown = values.suffix(count)
        let top = ceiling ?? max(shown.filter { !$0.isNaN }.max() ?? 0, 0.0001)
        for slot in 0..<count {
            let x = bounds.width - CGFloat(count - slot) * pitch
            let index = shown.count - (count - slot)
            let value: Float? = index >= 0 ? shown[shown.startIndex + index] : nil
            let rect: NSRect
            if let value, !value.isNaN {
                let height = max(3, bounds.height * CGFloat(min(1, value / top)))
                rect = NSRect(x: x, y: bounds.height - height, width: pitch - 2, height: height)
                color.setFill()
            } else {
                rect = NSRect(x: x, y: bounds.height - 3, width: pitch - 2, height: 3)
                Theme.track.setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// A caption over a figure.
final class Stat: DrawnView {
    private var caption = ""
    private var value = ""

    func set(_ pair: (String, String)) {
        guard pair != (caption, value) else { return }
        (caption, value) = pair
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.caption(caption, size: 9.5).draw(at: .zero)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(with: NSRect(x: 0, y: 15, width: bounds.width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { caption + " " + value }
}

/// Small labelled figures in a row: a caption over a semibold value, an optional dot.
final class Facts: DrawnView, SelfAuditing {
    struct Item: Equatable {
        var label: String
        var value: String
        var dot: NSColor?
    }
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var spacing: CGFloat = 18
    var alignRight = false { didSet { needsDisplay = true } }

    private static let labelFont = Theme.sans(11)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    private func widths() -> [CGFloat] {
        items.map { item in
            let label = ceil((item.label as NSString).size(withAttributes: [.font: Self.labelFont]).width) + (item.dot == nil ? 0 : 12)
            let value = ceil((item.value as NSString).size(withAttributes: [.font: Self.valueFont]).width)
            return max(label, value)
        }
    }

    var naturalWidth: CGFloat { widths().reduce(0, +) + spacing * CGFloat(max(0, items.count - 1)) }

    /// What fits the width: the spacing tightens to 12 first, then trailing items drop.
    private func fitted() -> (count: Int, spacing: CGFloat) {
        let columns = widths()
        for count in stride(from: columns.count, through: 1, by: -1) {
            let content = columns.prefix(count).reduce(0, +)
            let gaps = CGFloat(count - 1)
            if content + gaps * spacing <= bounds.width + 0.5 { return (count, spacing) }
            if content + gaps * 12 <= bounds.width + 0.5 { return (count, 12) }
        }
        return (min(1, columns.count), spacing)
    }

    override func draw(_ dirtyRect: NSRect) {
        let columns = widths()
        let (count, gap) = fitted()
        let used = columns.prefix(count).reduce(0, +) + gap * CGFloat(max(0, count - 1))
        var x = alignRight ? bounds.width - used : 0
        for (item, width) in zip(items.prefix(count), columns) {
            var labelX = x
            if let dot = item.dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: 4, width: 7, height: 7)).fill()
                labelX += 12
            }
            (item.label as NSString).draw(at: NSPoint(x: labelX, y: 0), withAttributes: [.font: Self.labelFont, .foregroundColor: Theme.inkSecondary])
            (item.value as NSString).draw(at: NSPoint(x: x, y: 15), withAttributes: [.font: Self.valueFont, .foregroundColor: Theme.ink])
            x += width + gap
        }
    }

    var auditFaults: [String] {
        let columns = widths()
        return columns.first.map { $0 > bounds.width + 1 ? ["first fact needs \(Int($0)) pt, has \(Int(bounds.width))"] : [] } ?? []
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { items.map { "\($0.label) \($0.value)" }.joined(separator: ", ") }
}

/// Rows of a legend: a dot, a name and a value on the right.
final class LegendRows: DrawnView {
    var rows: [(NSColor, String, String)] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        for (index, (color, name, value)) in rows.enumerated() {
            let y = CGFloat(index) * 20
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: y + 5, width: 8, height: 8)).fill()
            (name as NSString).draw(at: NSPoint(x: 14, y: y + 1), withAttributes: [.font: Theme.sans(12), .foregroundColor: Theme.ink])
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                             .foregroundColor: Theme.ink]
            let width = (value as NSString).size(withAttributes: attributes).width
            (value as NSString).draw(at: NSPoint(x: bounds.width - width, y: y + 1), withAttributes: attributes)
        }
    }
}

/// A horizontal bar split into coloured parts with small gaps.
final class SplitBar: DrawnView {
    var parts: [(Double, NSColor)] = [] { didSet { needsDisplay = true } }
    var track = Theme.track

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        var x: CGFloat = 0
        for (fraction, color) in parts where fraction > 0 {
            let width = bounds.width * CGFloat(min(1, fraction))
            color.setFill()
            NSRect(x: x, y: 0, width: max(0, width - 2), height: bounds.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One part of the machine on the overview, in the Tahoe card style: a coloured
/// symbol and name, a chevron, the figure, a line of context, facts and a chart.
final class SummaryCard: CardView {
    enum Kind { case cpu, memory, gpu, small, disk }
    let kind: Kind
    let caption = TextLine()
    let note = TextLine()
    let state = Pill()
    let figure = BigNumber()
    let context = TextLine()
    let facts = Facts()
    let chart = TimeChart()
    let legend = LegendRows()
    let bar = SplitBar()
    private let chevron = NSImageView()

    init(_ name: String, color: NSColor, kind: Kind = .small) {
        self.kind = kind
        super.init()
        caption.text = Theme.header(name, symbol: Theme.symbol(for: name), tint: color)
        figure.font = Theme.figure(30)
        figure.unitFont = Theme.sans(15, .medium)
        chart.primaryColor = color
        chart.showsTimeAxis = false
        chart.axisWidth = 34
        state.isHidden = true
        chevron.image = IconTile.glyph("chevron.right", tint: Theme.inkTertiary, size: 12, appearance: NSApp.effectiveAppearance)
        for view in [caption, note, state, figure, context, facts, chart, chevron] as [NSView] { addSubview(view) }
        if kind == .memory { addSubview(legend); addSubview(bar) }
        if kind == .disk { addSubview(bar) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width - 32
        let height = bounds.height
        caption.frame = NSRect(x: 16, y: 13, width: caption.naturalWidth + 4, height: 20)
        chevron.frame = NSRect(x: bounds.width - 28, y: 17, width: 12, height: 12)
        let noteWidth = note.naturalWidth
        note.frame = NSRect(x: chevron.frame.minX - 6 - noteWidth, y: 15, width: noteWidth, height: 16)
        let figureWidth = min(width, figure.naturalWidth)
        // The frame stays wide: sized to one reading, the next wider reading would not fit.
        figure.frame = NSRect(x: 16, y: 36, width: max(60, width * (kind == .cpu ? 0.45 : 1)), height: 38)
        let afterFigure = 16 + figureWidth + 10
        switch kind {
        case .cpu:
            context.frame = NSRect(x: 16, y: 76, width: width, height: 14)
            let factsWidth = facts.naturalWidth
            facts.frame = NSRect(x: bounds.width - 16 - factsWidth, y: 44, width: factsWidth, height: 32)
            chart.frame = NSRect(x: 16, y: 100, width: width, height: height - 112)
        case .memory:
            state.frame = NSRect(x: 16, y: 78, width: state.naturalWidth, height: 20)
            bar.frame = NSRect(x: 16, y: 108, width: width, height: 10)
            legend.frame = NSRect(x: 16, y: 128, width: width, height: 60)
            chart.frame = NSRect(x: 16, y: 194, width: width, height: height - 204)
        case .gpu:
            context.frame = NSRect(x: 16, y: 76, width: width, height: 14)
            facts.frame = NSRect(x: 16, y: 98, width: width, height: 32)
            chart.frame = NSRect(x: 16, y: 140, width: width, height: height - 150)
        case .small, .disk:
            state.frame = NSRect(x: afterFigure, y: 46, width: state.naturalWidth, height: 20)
            if kind == .disk {
                bar.frame = NSRect(x: 16, y: 80, width: width, height: 8)
                context.frame = NSRect(x: 16, y: 94, width: width, height: 14)
            } else {
                context.frame = NSRect(x: 16, y: 76, width: width, height: 14)
            }
            let chartTop: CGFloat = kind == .disk ? 114 : 98
            facts.frame = NSRect(x: 16, y: height - 46, width: width, height: 32)
            chart.frame = NSRect(x: 16, y: chartTop, width: width, height: max(20, facts.frame.minY - 8 - chartTop))
        }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}


/// A row in "Worth a Look": a solid icon tile, a bold line, a quieter line and a button.
final class NoticeRow: NSView {
    private let tile = NSImageView()
    private let title = TextLine()
    private let detail = TextLine()
    private let button = CapsuleButton()
    var showsRule = true { didSet { needsDisplay = true } }
    private var action: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [tile, title, detail, button] as [NSView] { addSubview(view) }
        button.onPress = { [weak self] in self?.action?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(symbol: String, tint: NSColor, image: NSImage? = nil, title text: String, detail note: String,
             button label: String?, action: (() -> Void)?) {
        tile.image = image ?? IconTile.image(symbol, tint: tint, size: 30, solid: true, appearance: effectiveAppearance)
        title.text = NSAttributedString(string: text, attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
        detail.text = NSAttributedString(string: note, attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary])
        button.isHidden = label == nil
        button.title = label ?? ""
        self.action = action
        needsLayout = true
    }

    override func layout() {
        super.layout()
        tile.frame = NSRect(x: 0, y: (bounds.height - 30) / 2, width: 30, height: 30)
        let buttonWidth = button.isHidden ? 0 : button.naturalWidth
        button.frame = NSRect(x: bounds.width - buttonWidth, y: (bounds.height - 24) / 2, width: buttonWidth, height: 24)
        let textWidth = bounds.width - 42 - (buttonWidth > 0 ? buttonWidth + 12 : 0)
        title.frame = NSRect(x: 42, y: bounds.height / 2 - 17, width: textWidth, height: 17)
        detail.frame = NSRect(x: 42, y: bounds.height / 2 + 1, width: textWidth, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsRule else { return }
        Theme.rule.setFill()
        NSRect(x: 42, y: bounds.height - 0.5, width: bounds.width - 42, height: 0.5).fill()
    }
}

/// A small grey capsule button, as Tahoe lists use for a row's action.
final class CapsuleButton: DrawnView {
    var title = "" { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private static let font = Theme.sans(12, .medium)

    var naturalWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 24 }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ink.withAlphaComponent(pressed ? 0.12 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: [.font: Self.font, .foregroundColor: Theme.ink])
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// Four figures side by side on a soft grey strip, with hairlines between them.
final class StatStrip: DrawnView, SelfAuditing {
    var items: [(String, String, String)] = [] { didSet { needsDisplay = true } }
    private static let labelFont = Theme.sans(11)

    /// The caption under a value: the label, and the extra only when there is room for it.
    private func caption(_ label: String, _ extra: String, width: CGFloat) -> String {
        let full = extra.isEmpty ? label : label + " · " + extra
        return (full as NSString).size(withAttributes: [.font: Self.labelFont]).width <= width ? full : label
    }

    var auditFaults: [String] {
        guard !items.isEmpty else { return [] }
        let room = bounds.width / CGFloat(items.count) - 20
        return items.compactMap { item in
            let width = ceil((caption(item.1, item.2, width: room) as NSString).size(withAttributes: [.font: Self.labelFont]).width)
            return width > room + 1 ? "\(item.1) needs \(Int(width)) pt, has \(Int(room))" : nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        guard !items.isEmpty else { return }
        let column = bounds.width / CGFloat(items.count)
        for (index, (value, label, extra)) in items.enumerated() {
            let x = CGFloat(index) * column
            if index > 0 {
                Theme.rule.setFill()
                NSRect(x: x, y: 10, width: 0.5, height: bounds.height - 20).fill()
            }
            (value as NSString).draw(at: NSPoint(x: x + 14, y: 10), withAttributes: [.font: Theme.figure(24), .foregroundColor: Theme.ink])
            let text = NSAttributedString(string: caption(label, extra, width: column - 20),
                                          attributes: [.font: Self.labelFont, .foregroundColor: Theme.inkSecondary])
            text.draw(with: NSRect(x: x + 14, y: 42, width: column - 20, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// A coding agent: its mark, its name and how many are running.
final class AgentLine: DrawnView {
    var name = "" { didSet { needsDisplay = true } }
    var count = 0 { didSet { needsDisplay = true } }
    var showsRule = true

    override func draw(_ dirtyRect: NSRect) {
        AgentMark.image(name, size: 18, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 0, y: (bounds.height - 18) / 2, width: 18, height: 18), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        (name as NSString).draw(at: NSPoint(x: 30, y: (bounds.height - 16) / 2), withAttributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink])
        let label = count > 1 ? "\(count) running" : "Running"
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.sans(11, .semibold), .foregroundColor: Theme.good]
        let size = (label as NSString).size(withAttributes: attributes)
        let badge = NSRect(x: bounds.width - size.width - 16, y: (bounds.height - 20) / 2, width: size.width + 16, height: 20)
        Theme.goodWash.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10).fill()
        (label as NSString).draw(at: NSPoint(x: badge.minX + 8, y: badge.midY - size.height / 2), withAttributes: attributes)
        if showsRule {
            Theme.rule.setFill()
            NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        }
    }
}

/// The landing page in the Tahoe layout: CPU, Memory and GPU across the top, the
/// four smaller parts under them, then the developer summary and what is worth a look.
@MainActor
final class OverviewPage: CardPage {
    override var pageTint: NSColor { PageID.overview.tint }
    private let cpu = SummaryCard("CPU", color: PageID.cpu.tint, kind: .cpu)
    private let memory = SummaryCard("Memory", color: PageID.memory.tint, kind: .memory)
    private let gpu = SummaryCard("GPU", color: PageID.gpu.tint, kind: .gpu)
    private let disk = SummaryCard("Disk", color: PageID.disk.tint, kind: .disk)
    private let network = SummaryCard("Network", color: PageID.network.tint)
    private let power = SummaryCard("Power", color: PageID.energy.tint)
    private let thermal = SummaryCard("Temperature", color: PageID.sensors.tint)
    private let developer = CardView()
    private let developerTitle = TextLine()
    private let strip = StatStrip()
    private let agentsTitle = TextLine()
    private let agentsCount = TextLine()
    private var agentLines: [AgentLine] = []
    private let notices = CardView()
    private let noticesTitle = TextLine()
    private let noticesEmpty = TextLine(Theme.caption("Nothing worth a look right now"))
    private var noticeRows: [NoticeRow] = []
    private let range = Segmented(["5 Minutes", "Hour", "Day"])
    private let open: (PageID) -> Void
    private let select: (Selection?) -> Void
    private let devServers = DevServerScanner()
    private let agents = AgentFinder()
    private var slowAt = Date.distantPast
    private var lastMinute = 0
    private var agentKinds: [(String, Int)] = []
    private lazy var diagnosis = DiagnosisCard(delegate: delegate, open: open, select: select)

    init(delegate: AppDelegate, open: @escaping (PageID) -> Void, select: @escaping (Selection?) -> Void) {
        self.open = open
        self.select = select
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var toolbarItems: [NSView] { [diagnosis.button, range] }

    override func loadView() {
        super.loadView()
        let cards: [(SummaryCard, PageID)] = [(cpu, .cpu), (memory, .memory), (gpu, .gpu), (disk, .disk), (network, .network),
                                              (power, .energy), (thermal, .sensors)]
        for (card, page) in cards {
            canvas.addSubview(card)
            card.onClick = { [weak self] in self?.open(page) }
        }
        range.onChange = { [weak self] _ in self?.refreshCharts(force: true) }

        cpu.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        cpu.chart.style = .bars
        cpu.chart.ceiling = 1
        cpu.chart.secondaryColor = Theme.cyan
        cpu.chart.format = { String(format: "%.0f%%", $0 * 100) }
        memory.chart.format = { String(format: "%.0f", Double($0) / 1_073_741_824) }
        gpu.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        gpu.chart.format = { String(format: "%.0f%%", $0 * 100) }
        disk.figure.format = { value in
            let (number, unit) = DashboardView.split(Format.bytes(UInt64(max(0, value))))
            return (number, unit + " free")
        }
        disk.chart.format = { Format.rate(Double($0)).replacingOccurrences(of: "/s", with: "") }
        disk.bar.parts = []
        network.figure.format = { DashboardView.split(Format.rate($0)) }
        network.chart.format = { Format.rate(Double($0)).replacingOccurrences(of: "/s", with: "") }
        for card in [disk, network] { card.chart.axisWidth = 44 }
        power.figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
        power.chart.format = { String(format: "%.0f W", $0) }
        thermal.figure.format = { Format.temperature($0) }
        thermal.chart.format = { String(format: "%.0f°", $0) }

        canvas.addSubview(developer)
        developer.onClick = { [weak self] in self?.open(.ports) }
        developerTitle.text = Theme.header("Developer", symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.inkSecondary)
        agentsTitle.text = NSAttributedString(string: "Coding Agents", attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
        for view in [developerTitle, strip, agentsTitle, agentsCount] as [NSView] { developer.addSubview(view) }

        canvas.addSubview(notices)
        noticesTitle.text = NSAttributedString(string: "Worth a Look", attributes: [.font: Theme.sans(15, .bold), .foregroundColor: Theme.ink])
        notices.addSubview(noticesTitle)
        notices.addSubview(noticesEmpty)
        diagnosis.install(in: canvas) { [weak self] in self?.relayout() }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let wide = width >= 900
        let columns: CGFloat = wide ? 4 : 2
        let column = (inner - gap * (columns - 1)) / columns
        func x(_ index: CGFloat) -> CGFloat { margin + index * (column + gap) }
        var y = diagnosis.place(x: margin, y: margin, width: inner, gap: gap)
        if wide {
            cpu.frame = NSRect(x: x(0), y: y, width: column * 2 + gap, height: 274)
            memory.frame = NSRect(x: x(2), y: y, width: column, height: 274)
            gpu.frame = NSRect(x: x(3), y: y, width: column, height: 274)
            y += 274 + gap
            for (index, card) in [disk, network, power, thermal].enumerated() {
                card.frame = NSRect(x: x(CGFloat(index)), y: y, width: column, height: 214)
            }
            y += 214 + gap
        } else {
            cpu.frame = NSRect(x: margin, y: y, width: inner, height: 250)
            y += 250 + gap
            for (index, card) in [memory, gpu, disk, network, power, thermal].enumerated() {
                let tall = index < 2
                card.frame = NSRect(x: x(CGFloat(index % 2)), y: y, width: column, height: tall ? 274 : 214)
                if index % 2 == 1 { y += (tall ? 274 : 214) + gap }
            }
        }
        for card in [cpu, memory, gpu, disk, network, power, thermal] { card.frame = card.frame.integral }

        let agentRows = CGFloat(max(1, agentLines.filter { !$0.isHidden }.count))
        let developerHeight = 16 + 22 + 12 + 64 + 22 + 22 + agentRows * 40 + 14
        let noticeCount = CGFloat(max(1, noticeRows.filter { !$0.isHidden }.count))
        let noticesHeight = 16 + 22 + 8 + noticeCount * 54 + 12
        let bottomHeight = max(developerHeight, noticesHeight, 220)
        if wide {
            developer.frame = NSRect(x: x(0), y: y, width: column * 2 + gap, height: bottomHeight).integral
            notices.frame = NSRect(x: x(2), y: y, width: column * 2 + gap, height: bottomHeight).integral
            y += bottomHeight
        } else {
            developer.frame = NSRect(x: margin, y: y, width: inner, height: developerHeight).integral
            y += developerHeight + gap
            notices.frame = NSRect(x: margin, y: y, width: inner, height: noticesHeight).integral
            y += noticesHeight
        }
        layoutDeveloper()
        layoutNotices()
        return y + margin
    }

    private func layoutDeveloper() {
        let width = developer.bounds.width - 32
        developerTitle.frame = NSRect(x: 16, y: 13, width: 200, height: 20)
        strip.frame = NSRect(x: 16, y: 44, width: width, height: 66)
        agentsTitle.frame = NSRect(x: 16, y: 128, width: 200, height: 18)
        let countWidth = agentsCount.naturalWidth
        agentsCount.frame = NSRect(x: 16 + width - countWidth, y: 129, width: countWidth, height: 16)
        var y: CGFloat = 150
        for line in agentLines where !line.isHidden {
            line.frame = NSRect(x: 16, y: y, width: width, height: 40)
            y += 40
        }
    }

    private func layoutNotices() {
        let width = notices.bounds.width - 32
        noticesTitle.frame = NSRect(x: 16, y: 14, width: width, height: 22)
        noticesEmpty.frame = NSRect(x: 16, y: 50, width: width, height: 16)
        var y: CGFloat = 46
        for row in noticeRows where !row.isHidden {
            row.frame = NSRect(x: 16, y: y, width: width, height: 54)
            y += 54
        }
    }

    // MARK: Data

    /// The chart for the chosen range: the live ring, or one point a minute for the hour or day.
    private func series(_ metric: SystemMetric) -> [Float] {
        let history = delegate.monitor.history
        switch range.selected {
        case 1: return history.day(metric, minutes: 60)
        case 2: return history.day(metric, minutes: HistoryStore.minutes)
        default: return history.recent(metric)
        }
    }

    private func refreshCharts(force: Bool) {
        if range.selected != 0 {
            let minute = Int(Date().timeIntervalSince1970 / 60)
            guard force || minute != lastMinute else { return }
            lastMinute = minute
        }
        let step = range.selected == 0 ? delegate.settings.interval : 60
        for card in [cpu, memory, gpu, disk, network, power, thermal] { card.chart.step = step }
        cpu.chart.primary = series(.cpu)
        cpu.chart.secondary = series(.cpuSystem)
        memory.chart.primary = series(.memory)
        gpu.chart.primary = series(.gpu)
        disk.chart.primary = zip(series(.diskRead), series(.diskWrite)).map { $0 + $1 }
        network.chart.primary = zip(series(.networkIn), series(.networkOut)).map { $0 + $1 }
        power.chart.primary = series(.power)
        thermal.chart.primary = series(.cpuTemperature)
        let temps = thermal.chart.primary.filter { !$0.isNaN }
        thermal.chart.bottom = max(0, ((temps.min() ?? 40) - 10) / 10 * 10).rounded(.down)
        thermal.chart.ceiling = max(100, ((temps.max() ?? 90) / 10).rounded(.up) * 10)
        let used = memory.chart.primary.filter { !$0.isNaN }
        if let low = used.min(), let total = delegate.system.memory?.total {
            let gb: Float = 1_073_741_824
            memory.chart.bottom = max(0, (low / gb - 5).rounded(.down)) * gb
            memory.chart.ceiling = Float(total)
        }
    }

    override func update(system s: SystemSnapshot) {
        refreshCharts(force: false)
        if let c = s.cpu {
            cpu.figure.set(c.total)
            cpu.note.text = NSAttributedString(string: c.total >= 0.85 ? "Strained" : c.total >= 0.6 ? "Busy" : "",
                                               attributes: [.font: Theme.sans(13, .medium), .foregroundColor: Theme.inkTertiary])
            let performance = c.performanceCores, efficiency = c.efficiencyCores
            cpu.context.variants = (performance > 0
                ? ["\(c.cores.count) cores · \(performance) performance, \(efficiency) efficiency", "\(c.cores.count) cores (\(performance)P + \(efficiency)E)"]
                : ["\(c.cores.count) cores"]).map { Theme.caption($0) }
            cpu.facts.items = [.init(label: "User", value: Format.percent(c.user), dot: Theme.blue),
                               .init(label: "System", value: Format.percent(c.system), dot: Theme.cyan),
                               .init(label: "Load average", value: String(format: "%.1f", c.loadAverage.first ?? 0), dot: nil)]
            cpu.needsLayout = true
        }
        if let m = s.memory {
            memory.figure.set(Double(m.used))
            memory.figure.format = { value in
                let (number, unit) = DashboardView.split(Format.memory(value))
                return (number, unit + " of " + Format.memory(m.total).replacingOccurrences(of: " GB", with: ""))
            }
            memory.state.isHidden = m.pressure == .normal
            memory.state.text = m.pressure == .warning ? "Pressure: Warning" : "Pressure: Critical"
            memory.state.tone = m.pressure == .warning ? .warn : .bad
            memory.state.symbol = "exclamationmark.triangle.fill"
            let total = Double(max(m.total, 1))
            memory.bar.parts = [(Double(m.app) / total, Theme.indigo), (Double(m.wired) / total, Theme.orange),
                                (Double(m.compressed) / total, Theme.indigo.withAlphaComponent(0.45))]
            memory.legend.rows = [(Theme.indigo, "App", Format.memory(m.app)), (Theme.orange, "Wired", Format.memory(m.wired)),
                                  (Theme.indigo.withAlphaComponent(0.45), "Compressed", Format.memory(m.compressed))]
            memory.needsLayout = true
        }
        if let g = s.gpu {
            gpu.figure.set(g.utilization)
            gpu.context.text = Theme.caption([g.coreCount.map { "\($0)-core GPU" }, g.memoryUsed.map { Format.memory($0) + " memory" }]
                .compactMap { $0 }.joined(separator: " · "))
            let recent = gpu.chart.primary.filter { !$0.isNaN }
            let mean = recent.isEmpty ? 0 : Double(recent.reduce(0, +)) / Double(recent.count)
            gpu.facts.items = [.init(label: "Average", value: Format.percent(mean), dot: nil),
                               .init(label: "Peak", value: Format.percent(Double(recent.max() ?? 0)), dot: nil)]
        }
        if let d = s.disk {
            disk.figure.set(Double(d.volumeFree))
            disk.state.isHidden = !Strain.disk(d)
            disk.state.text = "Low Space"
            disk.state.tone = .bad
            let usedFraction = 1 - Double(d.volumeFree) / Double(max(d.volumeTotal, 1))
            disk.bar.parts = [(usedFraction, Strain.disk(d) ? Theme.red : Theme.cyan)]
            disk.context.text = Theme.caption("\(Format.bytes(d.volumeTotal - d.volumeFree)) of \(Format.bytes(d.volumeTotal)) used")
            disk.facts.items = [.init(label: "Reading", value: Format.rate(d.readBytesPerSecond), dot: nil),
                                .init(label: "Writing", value: Format.rate(d.writeBytesPerSecond), dot: nil)]
            disk.needsLayout = true
        }
        if let n = s.network {
            network.figure.set(n.receivedBytesPerSecond)
            network.context.text = Theme.caption("Down · \(Format.rate(n.sentBytesPerSecond)) up")
            network.facts.items = [.init(label: "Today", value: networkToday, dot: nil), .init(label: "Last 7 days", value: networkWeek, dot: nil)]
        }
        if let p = s.power, let cpuWatts = p.cpu {
            power.figure.set(cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0))
            var items: [Facts.Item] = [.init(label: "CPU", value: Format.watts(cpuWatts), dot: nil),
                                       .init(label: "GPU", value: Format.watts(p.gpu ?? 0), dot: nil)]
            if let b = s.battery {
                power.context.text = Theme.caption("Battery \(String(format: "%.0f%%", b.percent))" + (b.isCharging ? " · Charging" : b.isPluggedIn ? " · Plugged in" : ""))
                if let health = b.health { items.append(.init(label: "Health", value: String(format: "%.0f%%", health * 100), dot: nil)) }
                if let cycles = b.cycleCount { items.append(.init(label: "Cycles", value: "\(cycles)", dot: nil)) }
            } else {
                power.context.text = Theme.caption("CPU, GPU and Neural Engine")
            }
            power.facts.items = items
        }
        if let t = s.thermal {
            thermal.figure.set(t.cpuCelsius)
            thermal.state.isHidden = t.pressure == .nominal
            thermal.state.text = t.pressure.rawValue.prefix(1).uppercased() + t.pressure.rawValue.dropFirst()
            thermal.state.tone = t.pressure == .fair ? .warn : .bad
            thermal.context.variants = ["Hottest sensor · thermal pressure \(t.pressure.rawValue)", "Hottest sensor"].map { Theme.caption($0) }
            thermal.facts.items = t.fans.enumerated().prefix(2).map { .init(label: "Fan \($0.offset + 1)", value: "\(Int($0.element.rpm)) rpm", dot: nil) }
            thermal.needsLayout = true
        }
        if Date().timeIntervalSince(slowAt) > 10 { refreshSlow() }
    }

    private var networkToday = "–"
    private var networkWeek = "–"

    /// Readings that change slowly or cost more: totals, projects, containers, agents, notices.
    private func refreshSlow() {
        slowAt = Date()
        let history = delegate.monitor.history
        let midnight = Calendar.current.startOfDay(for: Date())
        networkToday = Format.bytes(UInt64(history.total(.networkIn, since: midnight) + history.total(.networkOut, since: midnight)))
        let week = Date().addingTimeInterval(-7 * 86_400)
        networkWeek = Format.bytes(UInt64(history.total(.networkIn, since: week) + history.total(.networkOut, since: week)))

        let table = delegate.table
        let projects = devServers.scan(table).filter { !$0.path.isEmpty }
        let processes = projects.reduce(0) { $0 + $1.processes.count }
        let ports = Set(projects.flatMap { $0.servers.flatMap { $0.ports.map(\.port) } }).count
        let docker = Docker.status(stats: false)
        let running = docker.containers.filter { $0.state == "running" }.count
        strip.items = [("\(projects.count)", "Projects", ""), ("\(processes)", "Processes", ""), ("\(ports)", "Open ports", ""),
                       ("\(running)", "Containers", docker.socket.map { Docker.engineName($0) } ?? "")]

        let found = agents.find(table)
        let grouped = Dictionary(grouping: found, by: \.kind).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        agentKinds = grouped
        while agentLines.count < grouped.count {
            let line = AgentLine()
            developer.addSubview(line)
            agentLines.append(line)
        }
        for (index, line) in agentLines.enumerated() {
            line.isHidden = index >= grouped.count || index >= 4
            guard !line.isHidden else { continue }
            line.name = grouped[index].0
            line.count = grouped[index].1
            line.showsRule = index < min(grouped.count, 4) - 1
        }
        agentsCount.text = Theme.caption(found.isEmpty ? "None running" : "\(found.count) running")
        refreshNotices(projects: projects, table: table)
        relayout()
    }

    /// What is worth a look right now, worked out from live readings, then recent alerts.
    private func refreshNotices(projects: [DevProject], table: ProcessTable) {
        struct Notice { var symbol: String; var tint: NSColor; var image: NSImage?; var title: String; var detail: String; var button: String?; var action: (() -> Void)? }
        var list: [Notice] = []
        let s = delegate.system
        if let d = s.disk, Strain.disk(d) {
            list.append(Notice(symbol: "internaldrive.fill", tint: Theme.red, image: nil, title: "Disk almost full",
                               detail: "Only \(Format.bytes(d.volumeFree)) left on the startup disk", button: "Show", action: { [weak self] in self?.open(.disk) }))
        }
        if let m = s.memory, m.pressure != .normal, let top = table.apps.max(by: { $0.memory < $1.memory }) {
            list.append(Notice(symbol: "memorychip.fill", tint: Theme.indigo, image: nil, title: "\(top.name) holds \(Format.memory(top.memory)) of memory",
                               detail: "Memory is under pressure; it is the largest app", button: "Show",
                               action: { [weak self] in self?.select(.app(top.id)) }))
        }
        let idle = projects.flatMap(\.idleServers)
        if !idle.isEmpty {
            list.append(Notice(symbol: "folder.fill", tint: Theme.gray, image: nil,
                               title: "\(idle.count) dev server\(idle.count == 1 ? " is" : "s are") idle",
                               detail: "Still holding ports and memory", button: "Review", action: { [weak self] in self?.open(.ports) }))
        }
        if let busiest = table.apps.filter({ $0.processCount >= 8 }).max(by: { $0.memory < $1.memory }),
           busiest.memory > 4 << 30, list.count < 4 {
            list.append(Notice(symbol: "app.fill", tint: Theme.blue, image: Icons.icon(for: busiest),
                               title: "\(busiest.name) is using \(Format.memory(busiest.memory))",
                               detail: "\(busiest.processCount) processes", button: "Show", action: { [weak self] in self?.select(.app(busiest.id)) }))
        }
        if let t = s.thermal, t.pressure != .nominal, list.count < 5 {
            list.append(Notice(symbol: "thermometer.high", tint: Theme.orange, image: nil, title: "Running warm",
                               detail: "Thermal pressure is \(t.pressure.rawValue)", button: "Show", action: { [weak self] in self?.open(.sensors) }))
        }
        for alert in delegate.monitor.perform({ $0.alerts.recent }).suffix(3).reversed() where list.count < 5 {
            list.append(Notice(symbol: "bell.fill", tint: Theme.orange, image: nil, title: alert.title, detail: alert.body, button: nil, action: nil))
        }
        while noticeRows.count < list.count {
            let row = NoticeRow()
            notices.addSubview(row)
            noticeRows.append(row)
        }
        noticesEmpty.isHidden = !list.isEmpty
        for (index, row) in noticeRows.enumerated() {
            row.isHidden = index >= list.count
            guard index < list.count else { continue }
            let notice = list[index]
            row.set(symbol: notice.symbol, tint: notice.tint, image: notice.image, title: notice.title, detail: notice.detail,
                    button: notice.button, action: notice.action)
            row.showsRule = index < list.count - 1
        }
    }
}
