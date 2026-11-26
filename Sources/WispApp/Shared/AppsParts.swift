import AppKit
import WispCore

// Pieces the Apps page and the app drawer share, on top of the A2 tokens:
//
//   AppsMetric       the five measures the Apps table shows, with each one's page colour
//   TintLabel        an A2CardLabel whose name and colour can change
//   AppsTotalsStrip  the slim row of totals over the Apps table, one tile per column
//   AppsTableState   the table's loading rows and its "nothing matches" message
//   AppHistoryCard   the drawer's chart: the last hour, or the readings so far while it fills
//   FooterFade       the ground fading in under the drawer's buttons

/// The measures the Apps table shows, each in the colour of the page it belongs to.
enum AppsMetric: String, CaseIterable {
    case cpu, memory, energy, disk, network

    var page: PageID {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .energy: return .energy
        case .disk: return .disk
        case .network: return .network
        }
    }

    var name: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Power"
        case .disk: return "Disk"
        case .network: return "Network"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return PageID.cpu.symbol
        case .memory: return PageID.memory.symbol
        case .energy: return "bolt.fill"
        case .disk: return PageID.disk.symbol
        case .network: return PageID.network.symbol
        }
    }

    /// The colour of bars and fills.
    var tint: NSColor {
        switch self {
        case .cpu: return A2.cpu
        case .memory: return A2.memoryApp
        case .energy: return A2.power
        case .disk: return Self.diskTint
        case .network: return A2.down
        }
    }

    /// A meter's two ends, as the CPU page draws them: the tint into a lighter shade of it.
    var meterColors: (NSColor, NSColor) {
        self == .cpu ? (A2.cpu, A2.cpuLight) : (tint, tint.withAlphaComponent(0.6))
    }

    /// The colour of text and icons, a shade stronger so small type keeps its contrast.
    var labelTint: NSColor { A2.labelTint(page) }

    private static let diskTint = Theme.dynamic(0x30B0C7, 0x40C8E0)

    func value(_ app: AppGroup) -> Double {
        switch self {
        case .cpu: return app.cpu
        case .memory: return Double(app.memory)
        case .energy: return app.watts
        case .disk: return app.diskPerSecond
        case .network: return app.networkPerSecond
        }
    }
}

/// A card label like A2CardLabel (a 14 pt glyph and a 12 pt name in the tint) whose
/// name, glyph and colour can change, with an optional quiet note on the right.
final class TintLabel: DrawnView {
    var name = "" { didSet { if name != oldValue { needsDisplay = true } } }
    var symbol = "circle" { didSet { if symbol != oldValue { needsDisplay = true } } }
    var tint: NSColor = A2.secondary { didSet { if tint != oldValue { needsDisplay = true } } }
    var note = "" { didSet { if note != oldValue { needsDisplay = true } } }

    convenience init(_ name: String, symbol: String, tint: NSColor) {
        self.init(frame: .zero)
        (self.name, self.symbol, self.tint) = (name, symbol, tint)
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.height / 2
        IconTile.glyph(symbol, tint: tint, size: 14, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 0, y: mid - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let noteWidth = note.isEmpty ? 0 : A2Dev.width(note, A2.legendFont)
        let room = bounds.width - 20 - (noteWidth > 0 ? noteWidth + 10 : 0)
        A2Dev.text(name, x: 20, mid: mid, width: room, font: A2.labelFont, color: tint)
        if noteWidth > 0 {
            A2Dev.text(note, x: bounds.width - noteWidth, mid: mid, width: noteWidth, font: A2.legendFont, color: A2.secondary, right: true)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { note.isEmpty ? name : name + ", " + note }
}

// MARK: Apps page totals

/// One total over the Apps table: the measure's label, the figure for every app shown,
/// a bar split between the three heaviest apps and the rest, and their shares.
/// Clicking it sorts the table by that measure.
final class AppsTotalTile: CardView {
    let metric: AppsMetric
    private let label: TintLabel
    private let figure = BigNumber()
    private let bar = A2CapacityBar()
    private let sub = TextLine()
    var active = false { didSet { if active != oldValue { applyActive() } } }

    init(_ metric: AppsMetric) {
        self.metric = metric
        label = TintLabel(metric.name, symbol: metric.symbol, tint: metric.labelTint)
        super.init()
        radius = A2.radius
        figure.font = Theme.figure(24, .semibold)
        figure.unitFont = Theme.sans(13, .medium)
        figure.color = A2.primary
        figure.unitColor = A2.secondary
        figure.kern = -0.8
        figure.unitGap = 3
        figure.show("–")
        bar.parts = []
        for view in [label, figure, bar, sub] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Sort by " + metric.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyActive() {
        stroke = active ? metric.tint.withAlphaComponent(0.55) : Theme.cardBorder
        label.note = active ? "Sorted" : ""
    }

    static let height: CGFloat = 104

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        label.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 15)
        figure.frame = NSRect(x: A2.padSide, y: 34, width: inner, height: 30)
        bar.frame = NSRect(x: A2.padSide, y: 68, width: inner, height: 6)
        sub.frame = NSRect(x: A2.padSide, y: 80, width: inner, height: 14)
    }

    /// `figure` and `unit` are the total; `leaders` the heaviest apps, heaviest first,
    /// with their share of the total for the bar and their own figure for the line under it.
    func set(figure value: String, unit: String, leaders: [(name: String, share: Double, amount: String)], tip: String,
             empty: String = "Nothing measured", caveat: [String] = []) {
        figure.show(value, unit: unit)
        let shades: [CGFloat] = [1, 0.6, 0.34]
        var parts: [A2CapacityBar.Part] = []
        var used = 0.0
        for (index, leader) in leaders.prefix(3).enumerated() {
            parts.append(.init(amount: leader.share, color: metric.tint.withAlphaComponent(shades[index])))
            used += leader.share
        }
        if !parts.isEmpty { parts.append(.init(amount: max(0, 1 - used), color: A2.track)) }
        bar.parts = parts
        // As many leaders as fit, so a narrow tile still names the heaviest.
        let facts = leaders.prefix(2).map { A2.Fact(label: Self.short($0.name), value: $0.amount) }
        // Narrow tiles keep the heaviest app's figure and shorten its name instead.
        let clipped = facts.prefix(1).flatMap { fact in
            [14, 10, 6].compactMap { limit in
                fact.label.count > limit + 1 ? A2.Fact(label: String(fact.label.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…", value: fact.value) : nil
            }
        }
        if !caveat.isEmpty {
            sub.variants = caveat.map(A2.plain)
        } else {
            sub.variants = leaders.isEmpty ? [A2.plain(empty)]
                : [A2.facts(Array(facts)), A2.facts(Array(facts.prefix(1)))] + clipped.map { A2.facts([$0]) }
        }
        toolTip = tip
    }

    /// "com.apple.CoreSimulator.CoreSimulatorService" as "CoreSimulatorService".
    static func short(_ name: String) -> String {
        guard name.count > 14, name.contains("."), let last = name.split(separator: ".").last else { return name }
        return String(last)
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The totals over the Apps table: one tile per column, in the column's order. The
/// tiles for columns the table hides when narrow step aside with them.
final class AppsTotalsStrip: NSView {
    let tiles = AppsMetric.allCases.map(AppsTotalTile.init)
    var onSort: ((AppsMetric) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for tile in tiles {
            addSubview(tile)
            tile.onClick = { [weak self, metric = tile.metric] in self?.onSort?(metric) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Columns the table shows at this width; the same thresholds as its own.
    static func shown(width: CGFloat) -> Set<AppsMetric> {
        var shown: Set<AppsMetric> = [.cpu, .memory]
        if width >= 560 { shown.insert(.energy) }
        if width >= 700 { shown.formUnion([.disk, .network]) }
        return shown
    }

    var pageWidth: CGFloat = 0 { didSet { if pageWidth != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        let shown = Self.shown(width: pageWidth)
        let visible = tiles.filter { shown.contains($0.metric) }
        let gap: CGFloat = 12
        let width = (bounds.width - gap * CGFloat(max(0, visible.count - 1))) / CGFloat(max(1, visible.count))
        var x: CGFloat = 0
        for tile in tiles {
            tile.isHidden = !shown.contains(tile.metric)
            guard !tile.isHidden else { continue }
            tile.frame = NSRect(x: x.rounded(), y: 0, width: width.rounded(.down), height: bounds.height)
            x += width + gap
        }
    }

    func setSorted(_ metric: AppsMetric?) {
        for tile in tiles { tile.active = tile.metric == metric }
    }

    /// Totals over the apps the table shows (all of them, or those the filter keeps).
    func update(apps: [AppGroup], table: ProcessTable, machine: Bool, memoryTotal: Double, filtered: Bool) {
        let cores = table.coreCount
        guard !apps.isEmpty else {
            let note = table.apps.isEmpty ? "Waiting for the first reading" : "No apps match the filter"
            for tile in tiles { tile.set(figure: "–", unit: "", leaders: [], tip: note, empty: note) }
            return
        }
        for tile in tiles {
            let metric = tile.metric
            let total = apps.reduce(0.0) { $0 + metric.value($1) }
            let ranked = apps.lazy.filter { metric.value($0) > 0 }.sorted { metric.value($0) > metric.value($1) }
            func amount(_ app: AppGroup) -> String {
                switch metric {
                case .cpu: return Style.appCPU(app.cpu, machine: machine, coreCount: cores)
                case .memory: return Format.memory(app.memory)
                case .energy: return Format.watts(app.watts)
                case .disk: return Format.rate(app.diskPerSecond)
                case .network: return Format.rate(app.networkPerSecond)
                }
            }
            let leaders = total > 0 ? ranked.prefix(3).map { ($0.name, metric.value($0) / total, amount($0)) } : []
            let (value, unit): (String, String)
            var lines: [String] = []
            switch metric {
            case .cpu:
                (value, unit) = A2Dev.parts(Format.percent(total / Double(max(cores, 1))))
                lines.append((filtered ? "Apps shown" : "All apps") + " use \(value)\(unit) of \(cores) cores")
            case .memory:
                (value, unit) = DashboardView.split(Format.memory(UInt64(total)))
                lines.append((filtered ? "Apps shown" : "Apps") + " hold \(value) \(unit)" + (UInt64(total) > UInt64(memoryTotal)
                    ? ", more than the Mac's \(Format.memory(memoryTotal)): each app's figure counts its memory macOS has compressed or moved to disk"
                    : " of the Mac's \(Format.memory(memoryTotal))"))
            case .energy:
                (value, unit) = total > 0.005 ? DashboardView.split(Format.watts(total)) : ("–", "")
                lines.append("Power drawn by " + (filtered ? "the apps shown" : "apps"))
            case .disk:
                (value, unit) = total > 0 ? DashboardView.split(Format.rate(total)) : ("0", "KB/s")
                lines.append("Read and written by " + (filtered ? "the apps shown" : "apps"))
            case .network:
                if table.networkMeasured {
                    (value, unit) = total > 0 ? DashboardView.split(Format.rate(total)) : ("0", "KB/s")
                    lines.append("Sent and received by " + (filtered ? "the apps shown" : "apps"))
                } else {
                    (value, unit) = ("Off", "")
                    lines.append("Measured while a network view is open")
                }
            }
            for app in ranked.prefix(5) { lines.append("\(app.name)  \(amount(app))") }
            if !lines.isEmpty { lines.append("Click to sort the table by \(metric.name.lowercased())") }
            // Apps' memory counts what macOS has compressed or swapped out, so the sum can pass
            // the Mac's memory; the tile says so where the figure is, not only on hover.
            let caveat = metric == .memory && total > memoryTotal
                ? ["Includes compressed and swapped", "Includes swapped memory", "Includes swap"] : []
            tile.set(figure: value, unit: unit, leaders: metric == .network && !table.networkMeasured ? [] : leaders,
                     tip: lines.joined(separator: "\n"), caveat: caveat)
        }
    }
}

// MARK: Apps table states

/// Laid over the Apps table when it has no rows: faint rows in the table's own shape
/// while the first reading comes in, or what the filter did not find and a way out.
final class AppsTableState: DrawnView {
    enum Mode: Equatable { case hidden, loading, noMatch(String) }

    var mode: Mode = .hidden {
        didSet {
            guard mode != oldValue else { return }
            isHidden = mode == .hidden
            clear.isHidden = { if case .noMatch = mode { return false } else { return true } }()
            needsDisplay = true
            needsLayout = true
        }
    }
    /// The table it covers, read when drawing so ghost figures line up under the header.
    weak var outline: NSTableView?
    let clear = A2PillButton()
    var rowHeight: CGFloat = 30
    var headerHeight: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        clear.title = "Clear Filter"
        clear.isHidden = true
        isHidden = true
        addSubview(clear)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = clear.naturalWidth
        clear.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: (bounds.height * 0.38 + 44).rounded(), width: width, height: 26)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return clear.isHidden || !clear.frame.contains(local) ? nil : clear
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .hidden: return
        case .loading: drawGhostRows()
        case .noMatch(let text): drawNoMatch(text)
        }
    }

    /// Faint rows where the apps will be, fading down the card, with a line saying why.
    private func drawGhostRows() {
        let ghost = A2.track
        var columnEdges: [CGFloat] = []
        if let outline {
            for (index, column) in outline.tableColumns.enumerated() where !column.isHidden {
                columnEdges.append(convert(outline.rect(ofColumn: index), from: outline).maxX - outline.intercellSpacing.width / 2 - 4)
            }
        }
        var y = headerHeight + 4
        var index = 0
        let widths: [CGFloat] = [0.34, 0.22, 0.28, 0.18, 0.3, 0.24, 0.2, 0.26]
        while y + rowHeight <= bounds.height - 4 {
            let fade = max(0.15, 1 - CGFloat(index) * 0.09)
            let mid = y + rowHeight / 2
            ghost.withAlphaComponent(ghost.alphaComponent * fade).setFill()
            NSBezierPath(roundedRect: NSRect(x: 36, y: mid - 9, width: 18, height: 18), xRadius: 5, yRadius: 5).fill()
            let nameWidth = min(260, (columnEdges.first ?? bounds.width) * widths[index % widths.count])
            NSBezierPath(roundedRect: NSRect(x: 62, y: mid - 5, width: max(60, nameWidth), height: 10), xRadius: 5, yRadius: 5).fill()
            for edge in columnEdges.dropFirst() {
                NSBezierPath(roundedRect: NSRect(x: edge - 44, y: mid - 5, width: 40, height: 10), xRadius: 5, yRadius: 5).fill()
            }
            y += rowHeight
            index += 1
        }
        let text = NSAttributedString(string: "Reading every process. Apps appear in a moment.",
                                      attributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
        let size = text.size()
        let box = NSRect(x: (bounds.width - size.width) / 2 - 14, y: headerHeight + rowHeight * 3 - 4, width: size.width + 28, height: size.height + 14)
        Theme.card.setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        A2.hairline.setStroke()
        NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), xRadius: box.height / 2, yRadius: box.height / 2).stroke()
        text.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7))
    }

    // The message is drawn, so VoiceOver gets it here; the Clear Filter button stays a child.
    override func isAccessibilityElement() -> Bool { mode != .hidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        switch mode {
        case .hidden: return nil
        case .loading: return "Reading every process. Apps appear in a moment."
        case .noMatch(let filter): return "Nothing matches \u{201C}\(filter)\u{201D}. The filter looks at app and process names, and at process IDs."
        }
    }

    private func drawNoMatch(_ filter: String) {
        let top = (bounds.height * 0.38).rounded()
        let tile = NSRect(x: bounds.midX - 18, y: top - 44, width: 36, height: 36)
        A2Dev.drawGlyphTile("magnifyingglass", in: tile, appearance: effectiveAppearance)
        let title = NSAttributedString(string: "Nothing matches \u{201C}\(filter)\u{201D}",
                                       attributes: [.font: A2.titleFont, .foregroundColor: A2.primary])
        let detail = NSAttributedString(string: "The filter looks at app and process names, and at process IDs.",
                                        attributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
        for (line, y) in [(title, top + 4), (detail, top + 24)] {
            let width = min(line.size().width, bounds.width - 40)
            line.draw(with: NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 17),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

// MARK: Drawer chart

/// The drawer's chart card. It shows the app's last hour, a minute a point, once Wisp
/// has recorded some of it; until then it shows the readings taken since the drawer
/// opened, every couple of seconds, so the card is never an empty box.
final class AppHistoryCard: CardView {
    let toggle = Segmented(["CPU", "Memory"])
    private let label = TintLabel(frame: .zero)
    private let figure = BigNumber()
    private let sub = TextLine()
    let chart = TimeChart()
    private let waiting = WaitingPlot()

    static let height: CGFloat = 214
    private static let chartTop: CGFloat = 92

    override init() {
        super.init()
        radius = 14
        figure.font = Theme.figure(26, .semibold)
        figure.unitFont = Theme.sans(13, .medium)
        figure.color = A2.primary
        figure.unitColor = A2.secondary
        figure.kern = -0.9
        figure.unitGap = 3
        chart.edgeToEdge = true
        chart.edgeClip = { A2.bottomRounded($0, radius: 17) }
        waiting.isHidden = true
        for view in [label, toggle, figure, sub, chart, waiting] as [NSView] { addSubview(view) }
        toggle.setAccessibilityLabel("Chart shows")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inner = bounds.width - 36
        let toggleWidth = toggle.naturalWidth
        toggle.frame = NSRect(x: bounds.width - 18 - toggleWidth, y: 12, width: toggleWidth, height: 26)
        label.frame = NSRect(x: 18, y: 18, width: inner - toggleWidth - 10, height: 15)
        figure.frame = NSRect(x: 18, y: 40, width: inner, height: 32)
        sub.frame = NSRect(x: 18, y: 74, width: inner, height: 14)
        let plot = NSRect(x: 0, y: Self.chartTop, width: bounds.width, height: bounds.height - Self.chartTop)
        chart.frame = plot
        waiting.frame = plot
    }

    struct Reading {
        var date: Date
        var cpu: Float
        var memory: Float
    }

    /// Fills the card from the minute history and the readings taken while the drawer
    /// was open, whichever covers more time.
    func show(minutes: [Float], readings: [Reading], byCPU: Bool, label scope: String?, running: Bool,
              format: @escaping (Float) -> String) {
        let metric: AppsMetric = byCPU ? .cpu : .memory
        label.symbol = "clock"
        label.tint = metric.labelTint
        chart.primaryColor = metric.tint
        chart.names = (metric.name, "")
        chart.format = format
        // A near-idle app keeps a scale of a tenth of a core rather than magnifying noise.
        chart.minimumCeiling = byCPU ? 0.05 : 0
        let firstMinute = minutes.firstIndex { !$0.isNaN }
        let hour = firstMinute.map { Array(minutes[$0...]) } ?? []
        let hourCount = hour.lazy.filter { !$0.isNaN }.count
        let live = readings.map { byCPU ? $0.cpu : $0.memory }
        let liveSpan = readings.count > 1 ? readings.last!.date.timeIntervalSince(readings.first!.date) : 0
        let values: [Float]
        let span: TimeInterval
        let collecting: Bool
        if hourCount >= 2, Double(hour.count - 1) * 60 >= liveSpan {
            values = hour
            span = Double(hour.count - 1) * 60
            chart.step = 60
            collecting = hour.count < 60
        } else {
            values = live
            span = liveSpan
            chart.step = live.count > 1 ? max(0.5, liveSpan / Double(live.count - 1)) : 2
            collecting = true
        }
        let shown = values.filter { !$0.isNaN }
        label.name = span >= 59 * 60 ? "Last hour" : (shown.count < 2 ? "Last hour" : "Last " + Self.duration(span))
        chart.title = metric.name + ", " + label.name.lowercased()
        guard shown.count >= 2 else {
            chart.isHidden = true
            waiting.isHidden = false
            waiting.color = metric.tint
            figure.show(live.last.map { A2Dev.parts(format($0)).0 } ?? "–", unit: live.last.map { A2Dev.parts(format($0)).1 } ?? "")
            waiting.message = running ? "Waiting for the first readings" : "Not running now"
            sub.text = A2.plain(running ? "First readings in a few seconds. The hour fills in a minute at a time."
                                        : "Nothing recorded in the last hour.")
            label.note = ""
            return
        }
        chart.isHidden = false
        waiting.isHidden = true
        chart.primary = values
        let average = shown.reduce(0, +) / Float(shown.count)
        let peak = shown.max() ?? 0
        let (number, unit) = A2Dev.parts(format(average))
        figure.show(number, unit: unit)
        var facts = [A2.Fact(label: "Peak", value: format(peak)), A2.Fact(label: "Now", value: format(live.last ?? shown.last!))]
        if let scope { facts.append(A2.Fact(label: "All of", value: scope)) }
        func line(_ facts: [A2.Fact]) -> NSAttributedString {
            let text = NSMutableAttributedString(attributedString: A2.plain("Average · "))
            text.append(A2.facts(facts))
            return text
        }
        sub.variants = [line(facts), line(Array(facts.prefix(2))), line(Array(facts.prefix(1)))]
        label.note = collecting ? (A2.same(values, live) ? "Live" : "Filling in") : ""
        toolTip = collecting ? "Wisp records each app a minute at a time. Until it has an hour, this shows what it has so far." : nil
    }

    /// "40 seconds", "1 minute", "12 minutes".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 90 {
            let s = max(2, Int((seconds / 2).rounded()) * 2)
            return "\(s) seconds"
        }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "minute" : "\(minutes) minutes"
    }
}

/// The chart's place before its first two readings: the scale's dotted lines and a
/// flat line at the floor in the measure's colour, so the card already has its shape.
final class WaitingPlot: DrawnView {
    var color: NSColor = A2.cpu { didSet { needsDisplay = true } }
    var message = "Waiting for the first readings" { didSet { if message != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let top: CGFloat = 28
        let rect = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - 1 - top)
        context.saveGState()
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 4])
        for fraction: CGFloat in [0.5, 1] {
            let y = floor(rect.maxY - fraction * rect.height) + 0.5
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
            context.strokePath()
        }
        context.restoreGState()
        let floorPath = A2.bottomRounded(NSRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10), radius: 17)
        A2.fade(floorPath, color: color, alpha: A2.drawingDark ? 0.22 : 0.14, from: bounds.height - 10, to: bounds.height, in: context)
        let text = NSAttributedString(string: message, attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: rect.midY - size.height / 2))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { message }
}

/// The drawer's ground fading in under its buttons, so cards scrolling under them do
/// not show through between the capsules.
final class FooterFade: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        // Rounded like the drawer's bottom corners. The layer has no sublayers, so the
        // clip costs no offscreen pass.
        gradient.cornerRadius = 20
        gradient.cornerCurve = .continuous
        gradient.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        gradient.masksToBounds = true
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ground = Theme.ground.usingColorSpace(.sRGB) ?? Theme.ground
            // Layer y runs up: clear at the top of the fade, solid from just under the buttons' tops.
            gradient.colors = [ground.cgColor, ground.cgColor, ground.withAlphaComponent(0).cgColor]
            gradient.locations = [0, 0.55, 1]
        }
    }
}

/// Faint rows in the shape of a card's part rows (a dot, a name over a note, a share
/// and a figure), for the space a list fills once it has been measured.
final class AppsGhostRows: DrawnView {
    var count = 3 { didSet { if count != oldValue { needsDisplay = true } } }
    static let rowHeight: CGFloat = 40

    override func draw(_ dirtyRect: NSRect) {
        let names: [CGFloat] = [0.42, 0.3, 0.36, 0.26]
        for index in 0..<count {
            let top = CGFloat(index) * Self.rowHeight
            let fade = 1 - CGFloat(index) * 0.22
            let color = A2.track.withAlphaComponent(A2.track.alphaComponent * fade)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: top + 16, width: 8, height: 8)).fill()
            let room = bounds.width - 18 - 84 - 44
            for rect in [NSRect(x: 18, y: top + 8, width: room * names[index % names.count] + 40, height: 9),
                         NSRect(x: 18, y: top + 23, width: room * 0.55, height: 7),
                         NSRect(x: bounds.width - 84 - 28, y: top + 16, width: 28, height: 8),
                         NSRect(x: bounds.width - 46, y: top + 15, width: 46, height: 10)] {
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }
            if index < count - 1 {
                Theme.rule.withAlphaComponent(fade).setFill()
                NSRect(x: 18, y: top + Self.rowHeight - 0.5, width: bounds.width - 18, height: 0.5).fill()
            }
        }
    }
}
