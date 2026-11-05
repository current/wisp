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
    private static let valueFont = Theme.digits(13, .semibold)

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
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.digits(12, .semibold),
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

/// A finding in the diagnosis card: a solid icon tile, a bold line, a quieter line and a button.
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


/// The landing page in the A2 layout: CPU, Memory, GPU and Power across the top;
/// Activity, Storage and Network under them; then the busiest apps and what is worth
/// a look. At 1240 by 780 the three rows fill the window; narrower windows get two
/// columns and scroll.
@MainActor
final class OverviewPage: CardPage {
    override var pageTint: NSColor { PageID.overview.tint }
    private let cpu = A2StatCard("CPU", page: .cpu, body: .spark)
    private let memory = A2StatCard("Memory", page: .memory, body: .capacity)
    private let gpu = A2StatCard("GPU", page: .gpu, body: .spark)
    private let power = A2StatCard("Power", page: .energy, symbol: "bolt", body: .spark)
    private let storage = A2StatCard("Storage", page: .disk, body: .capacity)
    private let network = A2StatCard("Network", page: .network, body: .pair)
    private let activity = CardView()
    private let activityTitle = A2TitleRow()
    private let activityChart = A2ActivityChart()
    private let apps = CardView()
    private let appList = A2AppList()
    private let tips = CardView()
    private let tipsTitle = A2TitleRow()
    private let tipsEmpty = TextLine()
    private var tipRows: [A2TipRow] = []
    private let range = Segmented(["5 Min", "Hour", "Day"])
    private let open: (PageID) -> Void
    private let select: (Selection?) -> Void
    private let devServers = DevServerScanner()
    private var slowAt = Date.distantPast
    private var lastMinute = 0
    private var networkToday = "–"
    private lazy var diagnosis = DiagnosisCard(delegate: delegate, open: open, select: select)

    /// The mockup's row heights at 1240 by 780.
    private static let rowHeights: [CGFloat] = [172, 236, 264]
    private static let maxTips = 4

    init(delegate: AppDelegate, open: @escaping (PageID) -> Void, select: @escaping (Selection?) -> Void) {
        self.open = open
        self.select = select
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var toolbarItems: [NSView] { [diagnosis.button, range] }

    override func loadView() {
        super.loadView()
        _ = heading(PageID.overview.title)
        showUptime()
        let cards: [(A2StatCard, PageID)] = [(cpu, .cpu), (memory, .memory), (gpu, .gpu), (power, .energy), (storage, .disk), (network, .network)]
        for (card, page) in cards {
            canvas.addSubview(card)
            card.onClick = { [weak self] in self?.open(page) }
        }
        range.onChange = { [weak self] _ in self?.refreshCharts(force: true) }

        cpu.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        cpu.spark.color = A2.cpu
        gpu.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        gpu.spark.color = A2.gpu
        power.figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
        power.spark.color = A2.power
        memory.keys.arrangement = .spread
        storage.keys.arrangement = .columns(2)
        storage.keys.rowGap = 12
        storage.figure.format = { value in
            let (number, unit) = DashboardView.split(Format.bytes(UInt64(max(0, value))))
            return (number, unit + " free")
        }
        network.figure.format = { value in
            let (number, unit) = DashboardView.split(Format.rate(value))
            return (number, unit + " down")
        }
        network.spark.color = A2.down
        network.lowerSpark.color = A2.up

        canvas.addSubview(activity)
        activity.addSubview(activityTitle)
        activity.addSubview(activityChart)
        activityTitle.title = "Activity"

        canvas.addSubview(apps)
        apps.addSubview(appList)
        appList.onSelect = { [weak self] id in self?.select(.app(id)) }

        canvas.addSubview(tips)
        tips.addSubview(tipsTitle)
        tips.addSubview(tipsEmpty)
        tipsTitle.title = "Worth a Look"
        tipsEmpty.text = NSAttributedString(string: "Nothing worth a look right now", attributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
        tipsEmpty.alignment = .center
        diagnosis.install(in: canvas) { [weak self] in self?.relayout() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        showUptime()
    }

    /// "MacBook Pro · M3 Max · 36 GB · up 4 days"; narrow toolbars drop the model, then the line.
    private func showUptime() {
        guard let (_, subtitle) = headingLines else { return }
        var parts = MainWindowController.machineSubtitle.components(separatedBy: " · ")
        if let boot = Uptime.bootDate() { parts.append(Uptime.label(Date().timeIntervalSince(boot))) }
        subtitle.variants = [parts, Array(parts.dropFirst()), []].map { Toolbar.subtitle($0.joined(separator: " · ")) }
    }

    // MARK: Layout

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = diagnosis.place(x: margin, y: margin, width: inner, gap: gap)
        /// Card edges on whole points, so every gap is 12 pt or within a point of it.
        func span(_ first: Int, _ count: Int, of columns: Int) -> (x: CGFloat, width: CGFloat) {
            let column = (inner - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let left = (margin + CGFloat(first) * (column + gap)).rounded()
            let right = (margin + CGFloat(first + count) * (column + gap) - gap).rounded()
            return (left, right - left)
        }
        func place(_ view: NSView, _ first: Int, _ count: Int, of columns: Int, height: CGFloat) {
            let (x, w) = span(first, count, of: columns)
            view.frame = NSRect(x: x, y: y, width: w, height: height)
        }
        let four = (inner - gap * 3) / 4 >= 180
        if four {
            // Taller windows grow the rows a little; past that the page ends early.
            let room = scroll.contentSize.height - Self.topInset - margin * 2 - gap * 2
            let scale = min(1.3, max(1, room / Self.rowHeights.reduce(0, +)))
            let heights = Self.rowHeights.map { ($0 * scale).rounded() }
            for (index, card) in [cpu, memory, gpu, power].enumerated() { place(card, index, 1, of: 4, height: heights[0]) }
            y += heights[0] + gap
            place(activity, 0, 2, of: 4, height: heights[1])
            place(storage, 2, 1, of: 4, height: heights[1])
            place(network, 3, 1, of: 4, height: heights[1])
            y += heights[1] + gap
            place(apps, 0, 2, of: 4, height: heights[2])
            place(tips, 2, 2, of: 4, height: heights[2])
            y += heights[2]
        } else {
            let rows: [([NSView], CGFloat)] = [([cpu, memory], 172), ([gpu, power], 172), ([activity], 236), ([storage, network], 236),
                                               ([apps], 264), ([tips], 264)]
            for (index, (views, height)) in rows.enumerated() {
                for (column, view) in views.enumerated() { place(view, column, 1, of: views.count, height: height) }
                y += height + (index < rows.count - 1 ? gap : 0)
            }
        }
        layoutActivity()
        layoutLists()
        return y + margin
    }

    private func layoutActivity() {
        let width = activity.bounds.width
        activityTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: width - A2.padSide * 2, height: 16)
        // The mockup's chart is 176 pt of a 236 pt card, flush with the bottom.
        let top: CGFloat = 60
        activityChart.frame = NSRect(x: 0, y: top, width: width, height: activity.bounds.height - top)
    }

    private func layoutLists() {
        let inner = NSRect(x: A2.padSide, y: A2.padTop, width: apps.bounds.width - A2.padSide * 2, height: apps.bounds.height - A2.padTop * 2)
        appList.frame = inner
        let tipsInner = tips.bounds.width - A2.padSide * 2
        tipsTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: tipsInner, height: 16)
        let listTop = A2.padTop + 16 + 8
        let listHeight = tips.bounds.height - listTop - A2.padTop
        tipsEmpty.frame = NSRect(x: A2.padSide, y: listTop + listHeight / 2 - 8, width: tipsInner, height: 16)
        let shown = tipRows.filter { !$0.isHidden }
        // Rows share the list's height, as in the mockup.
        let rowHeight = listHeight / CGFloat(max(1, shown.count))
        for (index, row) in shown.enumerated() {
            row.frame = NSRect(x: A2.padSide, y: (listTop + CGFloat(index) * rowHeight).rounded(), width: tipsInner, height: rowHeight.rounded())
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

    private static func peak(_ values: [Float]) -> Double { Double(values.lazy.filter { !$0.isNaN }.max() ?? 0) }

    private func refreshCharts(force: Bool) {
        if range.selected != 0 {
            let minute = Int(Date().timeIntervalSince1970 / 60)
            guard force || minute != lastMinute else { return }
            lastMinute = minute
        }
        let cpuSeries = series(.cpu), gpuSeries = series(.gpu)
        cpu.spark.values = cpuSeries
        cpu.spark.ceiling = Float(min(1, ChartScale.ceiling(peak: Self.peak(cpuSeries), minimum: 0.1)))
        gpu.spark.values = gpuSeries
        gpu.spark.ceiling = Float(min(1, ChartScale.ceiling(peak: Self.peak(gpuSeries), minimum: 0.1)))
        let powerSeries = series(.power)
        power.spark.values = powerSeries
        power.spark.ceiling = Float(ChartScale.ceiling(peak: Self.peak(powerSeries), minimum: 1))
        let down = series(.networkIn), up = series(.networkOut)
        let networkTop = Float(ChartScale.ceiling(peak: max(Self.peak(down), Self.peak(up)), minimum: 10_000))
        network.spark.values = down
        network.lowerSpark.values = up
        network.spark.ceiling = networkTop
        network.lowerSpark.ceiling = networkTop
        activityChart.first = cpuSeries
        activityChart.second = gpuSeries
        activityChart.ceiling = Float(min(1, ChartScale.ceiling(peak: max(Self.peak(cpuSeries), Self.peak(gpuSeries)), minimum: 0.1)))
        gpuPeak = Self.peak(gpuSeries)
    }

    private var gpuPeak = 0.0

    private var rangeName: String {
        switch range.selected {
        case 1: return "Last hour"
        case 2: return "Last 24 hours"
        default: return "Last 5 minutes"
        }
    }

    /// Gigabytes as the mockup writes them: "27", or "4.2" under ten.
    private static func gigabytes(_ bytes: Double) -> String {
        let value = bytes / 1_073_741_824
        return String(format: value >= 9.95 ? "%.0f" : "%.1f", value)
    }

    override func update(system s: SystemSnapshot) {
        refreshCharts(force: false)
        if let c = s.cpu {
            cpu.figure.set(c.total)
            cpu.sub.text = A2.facts([.init(label: "User", value: Format.percent(c.user)), .init(label: "System", value: Format.percent(c.system)),
                                     .init(label: "Load", value: String(format: "%.1f", c.loadAverage.first ?? 0))])
        }
        if let m = s.memory {
            let total = "of \(Int((Double(m.total) / 1_073_741_824).rounded())) GB"
            memory.figure.format = { (Self.gigabytes($0), total) }
            memory.figure.set(Double(m.used))
            let pressure: (String, NSColor) = switch m.pressure {
            case .normal: ("Normal", A2.good)
            case .warning: ("Warning", A2.warn)
            default: ("Critical", A2.bad)
            }
            memory.sub.text = A2.facts([.init(label: "Pressure", value: pressure.0, color: pressure.1),
                                        .init(label: "Swap", value: Format.memory(m.swapUsed))])
            let free = Double(m.total) - Double(m.used)
            memory.bar.parts = [.init(amount: Double(m.app), color: A2.memoryApp), .init(amount: Double(m.wired), color: A2.memoryWired),
                                .init(amount: Double(m.compressed), color: A2.memoryCompressed), .init(amount: max(0, free), color: A2.track)]
            memory.keys.keys = [.init(label: "App", value: Format.memory(m.app), color: A2.memoryApp),
                                .init(label: "Wired", value: Format.memory(m.wired), color: A2.memoryWired),
                                .init(label: "Compressed", value: Format.memory(m.compressed), color: A2.memoryCompressed)]
        }
        if let g = s.gpu {
            gpu.figure.set(g.utilization)
            var facts: [A2.Fact] = [.init(label: "Peak", value: Format.percent(gpuPeak))]
            if let used = g.memoryUsed { facts.append(.init(label: "Memory", value: Format.memory(used))) }
            gpu.sub.text = A2.facts(facts)
        }
        if let p = s.power, let cpuWatts = p.cpu {
            power.figure.set(cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0))
            power.sub.text = A2.facts([.init(label: "CPU", value: Format.watts(cpuWatts)), .init(label: "GPU", value: Format.watts(p.gpu ?? 0))])
        }
        if let d = s.disk { showStorage(d) }
        if let n = s.network {
            network.figure.set(n.receivedBytesPerSecond)
            network.sub.text = A2.facts([.init(label: "Up", value: Format.rate(n.sentBytesPerSecond)), .init(label: "Today", value: networkToday)])
        }
        let cpuNow = s.cpu.map { Format.percent($0.total) } ?? "–"
        let gpuNow = s.gpu?.utilization.map { Format.percent($0) } ?? "–"
        activityTitle.items = [.init(text: "CPU " + cpuNow, dot: A2.cpu), .init(text: "GPU " + gpuNow, dot: A2.gpu), .init(text: rangeName, faint: true)]
        if Date().timeIntervalSince(slowAt) > 10 { refreshSlow() }
    }

    /// Used and free from the live reading; the breakdown only when the Storage page
    /// has already measured it this session. The Overview never starts that scan.
    private func showStorage(_ d: DiskReading) {
        storage.figure.set(Double(d.volumeFree))
        let used = d.volumeTotal - min(d.volumeFree, d.volumeTotal)
        storage.sub.text = A2.plain("\(Format.bytes(used)) of \(Format.bytes(d.volumeTotal)) used")
        let freePart = A2CapacityBar.Part(amount: Double(d.volumeFree), color: A2.track)
        let before = storage.keys.keys.count
        if let summary = StoragePage.latestSummary {
            let shown: [(StorageCategory, String, NSColor)] = [(.apps, "Apps", A2.diskApps), (.developer, "Developer", A2.diskDeveloper),
                                                               (.documents, "Documents", A2.diskDocuments), (.system, "System", A2.diskSystem)]
            let others = summary.segments.filter { segment in segment.category != .free && !shown.contains { $0.0 == segment.category } }
            storage.bar.parts = shown.map { .init(amount: Double(summary.segment($0.0)?.size ?? 0), color: $0.2) }
                + others.map { .init(amount: Double($0.size), color: $0.category.color) } + [freePart]
            storage.keys.keys = shown.map { .init(label: $0.1, value: Format.bytes(summary.segment($0.0)?.size ?? 0), color: $0.2) }
        } else {
            storage.bar.parts = [.init(amount: Double(used), color: A2.diskSystem), freePart]
            storage.keys.keys = [.init(label: "Used", value: Format.bytes(used), color: A2.diskSystem),
                                 .init(label: "Free", value: Format.bytes(d.volumeFree), color: A2.track),
                                 .init(label: "Reading", value: Format.rate(d.readBytesPerSecond), color: nil),
                                 .init(label: "Writing", value: Format.rate(d.writeBytesPerSecond), color: nil)]
        }
        if storage.keys.keys.count != before { storage.needsLayout = true }
    }

    override func update(table: ProcessTable) {
        let busiest = table.apps.sorted { $0.cpu > $1.cpu }.prefix(5)
        let top = max(busiest.first?.cpu ?? 0, 0.000_001)
        let machine = delegate.settings.cpuOfMachine
        appList.rows = busiest.map { app in
            A2AppList.Row(id: app.id, icon: Icons.icon(for: app), name: app.name,
                          detail: app.processCount == 1 ? "1 process" : "\(app.processCount) processes",
                          fraction: app.cpu / top, cpu: Self.cpuText(app.cpu, machine: machine, cores: table.coreCount),
                          memory: Format.memory(app.memory))
        }
    }

    /// "182%", "23%", "6.1%": share of one core, a decimal only under 10%.
    private static func cpuText(_ cores: Double, machine: Bool, cores count: Int) -> String {
        if machine { return Style.appCPU(cores, machine: true, coreCount: count) }
        return Format.percent(cores, digits: cores >= 0.0995 ? 0 : 1)
    }

    /// Readings that change slowly or cost more: today's network total and the suggestions.
    private func refreshSlow() {
        slowAt = Date()
        let midnight = Calendar.current.startOfDay(for: Date())
        let history = delegate.monitor.history
        networkToday = Format.bytes(UInt64(max(0, history.total(.networkIn, since: midnight) + history.total(.networkOut, since: midnight))))
        let table = delegate.table
        let projects = devServers.scan(table).filter { !$0.path.isEmpty }
        refreshTips(projects: projects, table: table)
        relayout()
    }

    /// What is worth a look right now, worked out from live readings, then recent alerts.
    private func refreshTips(projects: [DevProject], table: ProcessTable) {
        struct Tip { var symbol: String; var tint: NSColor; var image: NSImage?; var title: String; var detail: String; var button: String?; var action: (() -> Void)? }
        var list: [Tip] = []
        let s = delegate.system
        if let d = s.disk, Strain.disk(d) {
            list.append(Tip(symbol: "internaldrive", tint: Theme.red, image: nil, title: "Disk almost full",
                            detail: "Only \(Format.bytes(d.volumeFree)) left on the startup disk", button: "Show", action: { [weak self] in self?.open(.disk) }))
        }
        if let m = s.memory, m.pressure != .normal, let top = table.apps.max(by: { $0.memory < $1.memory }) {
            list.append(Tip(symbol: "memorychip", tint: A2.memoryApp, image: nil, title: "\(top.name) holds \(Format.memory(top.memory)) of memory",
                            detail: "Memory is under pressure; it is the largest app", button: "Show",
                            action: { [weak self] in self?.select(.app(top.id)) }))
        }
        let idle = projects.flatMap(\.idleServers)
        if !idle.isEmpty {
            list.append(Tip(symbol: "server.rack", tint: A2.cpu, image: nil,
                            title: "\(idle.count) dev server\(idle.count == 1 ? " is" : "s are") idle",
                            detail: "Still holding ports and memory", button: "Review", action: { [weak self] in self?.open(.ports) }))
        }
        if let busiest = table.apps.filter({ $0.processCount >= 8 }).max(by: { $0.memory < $1.memory }),
           busiest.memory > 4 << 30, list.count < Self.maxTips {
            list.append(Tip(symbol: "app", tint: A2.cpu, image: Icons.icon(for: busiest),
                            title: "\(busiest.name) is using \(Format.memory(busiest.memory))",
                            detail: "\(busiest.processCount) processes", button: "Show", action: { [weak self] in self?.select(.app(busiest.id)) }))
        }
        if let t = s.thermal, t.pressure != .nominal, list.count < Self.maxTips {
            list.append(Tip(symbol: "thermometer.medium", tint: A2.power, image: nil, title: "Running warm",
                            detail: "Thermal pressure is \(t.pressure.rawValue)", button: "Show", action: { [weak self] in self?.open(.sensors) }))
        }
        for alert in delegate.monitor.perform({ $0.alerts.recent }).suffix(3).reversed() where list.count < Self.maxTips {
            let (symbol, tint) = Self.look(alert.kind)
            let present = table.app(alert.appID) != nil
            list.append(Tip(symbol: symbol, tint: tint, image: nil, title: alert.title, detail: alert.body, button: present ? "Show" : nil,
                            action: present ? { [weak self] in self?.select(.app(alert.appID)) } : nil))
        }
        list = Array(list.prefix(Self.maxTips))
        while tipRows.count < list.count {
            let row = A2TipRow()
            tips.addSubview(row)
            tipRows.append(row)
        }
        tipsEmpty.isHidden = !list.isEmpty
        tipsTitle.items = list.isEmpty ? [] : [.init(text: list.count == 1 ? "1 suggestion" : "\(list.count) suggestions")]
        for (index, row) in tipRows.enumerated() {
            row.isHidden = index >= list.count
            guard index < list.count else { continue }
            let tip = list[index]
            row.set(symbol: tip.symbol, tint: tip.tint, image: tip.image, title: tip.title, detail: tip.detail, button: tip.button, action: tip.action)
            row.showsRule = index > 0
        }
    }

    private static func look(_ kind: AlertKind) -> (String, NSColor) {
        switch kind {
        case .cpu: return ("flame", A2.power)
        case .memoryGrowth: return ("arrow.up", Theme.dynamic(0xE6A700, 0xFFD60A))
        case .diskWrites: return ("internaldrive", A2.up)
        case .network: return ("network", A2.down)
        case .temperature: return ("thermometer.medium", A2.power)
        case .appLimit: return ("gauge.with.needle", A2.power)
        }
    }
}
