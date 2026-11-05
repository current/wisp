import AppKit
import WispCore

/// A machine page: a large chart with a 5 Min/Hour/Day switch, a row of tiles,
/// optional extra cards and the apps that use the most of this resource.
///
/// The default layout stacks them at their natural heights, for pages that build on it
/// (Storage, Battery, Containers). The CPU, Memory, GPU and Network pages place their
/// cards to fill the window, as in the A2 mockups, through `fill(...)` helpers.
@MainActor
class MachinePage: CardPage {
    let hero: ChartCard
    var tiles: [Tile] = [] { didSet { tiles.forEach(canvas.addSubview) } }
    /// Extra cards under the tiles, each with the height it wants; laid out two to a row.
    var extras: [(CardView, CGFloat)] = [] { didSet { extras.forEach { canvas.addSubview($0.0) } } }
    let tableCard = CardView()
    let tableTitle = TextLine()
    let table: ColumnTable = { let table = ColumnTable(); table.drawsVisibleOnly = true; return table }()
    let onSelect: (Selection?) -> Void
    var metric: SystemMetric
    var secondMetric: SystemMetric?
    /// The hero's height in the default layout.
    var heroHeight: CGFloat = 256
    /// False on pages whose apps card is replaced by other cards (Network).
    var showsTable = true { didSet { tableCard.isHidden = !showsTable } }
    private var lastMinute = 0
    private(set) var lastTable: ProcessTable?
    private let maxRows = 40
    /// How many apps fit when the table fills its card; nil lists up to `maxRows`.
    private var fittedRows: Int?

    init(title: String, metric: SystemMetric, delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        hero = ChartCard(title)
        self.metric = metric
        self.onSelect = onSelect
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        canvas.addSubview(hero)
        canvas.addSubview(tableCard)
        tableCard.addSubview(tableTitle)
        tableCard.addSubview(table)
        hero.onRange = { [weak self] _ in self?.refreshChart(force: true) }
        SpikeLabels.install(on: self)
        table.onSort = { [weak self] _ in
            guard let self, let table = self.lastTable else { return }
            self.fillTable(table)
        }
        table.onSelect = { [weak self] id in self?.onSelect(.app(id)) }
        setUp()
        hero.tint = chartTint
        hero.labelTint = labelTint
        table.barColor = chartTint
        for tile in tiles { tile.tint = labelTint }
    }

    var pageID: PageID { PageID.allCases.first { $0.title == hero.title } ?? .cpu }
    override var pageTint: NSColor { pageID.tint }
    override var labelTint: NSColor { A2.labelTint(pageID) }
    /// The colour of the hero's line.
    var chartTint: NSColor { pageTint }

    /// The 5 Min / Hour / Day switch sits in the toolbar on its glass capsule.
    override var toolbarItems: [NSView] { hero.range.items.count > 1 ? [hero.range] : [] }

    /// Subclasses add tiles, extras and table columns here.
    func setUp() {}

    /// The toolbar's subtitle, longest first; a narrow toolbar shows the first that fits.
    func subtitle(_ variants: [String]) {
        let (_, line) = headingLines ?? heading(hero.title)
        line.variants = (variants + [""]).map(Toolbar.subtitle)
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: heroHeight)
        var y = hero.frame.maxY + gap
        if !tiles.isEmpty {
            let columns = min(tiles.count, 6)
            y = grid(tiles, top: y, width: width, columns: columns, height: 112) + gap
        }
        var index = 0
        while index < extras.count {
            let pair = Array(extras[index..<min(index + 2, extras.count)])
            let single = pair.count == 1 || width < 900
            if single {
                extras[index].0.frame = NSRect(x: margin, y: y, width: inner, height: extras[index].1)
                y += extras[index].1 + gap
                index += 1
            } else {
                let half = (inner - gap) / 2
                let height = max(pair[0].1, pair[1].1)
                pair[0].0.frame = NSRect(x: margin, y: y, width: half, height: height)
                pair[1].0.frame = NSRect(x: margin + half + gap, y: y, width: half, height: height)
                y += height + gap
                index += 2
            }
        }
        guard showsTable else { return y - gap + margin }
        placeTable(NSRect(x: margin, y: y, width: inner, height: 0), fill: false)
        return tableCard.frame.maxY + margin
    }

    // MARK: Filling the window

    /// The height cards may take between the toolbar and the bottom margin.
    var room: CGFloat { scroll.contentSize.height - Self.topInset - margin * 2 }

    /// Card edges on whole points: `count` columns from `first` of a row split by `weights`.
    func span(_ first: Int, _ count: Int, weights: [CGFloat], width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inner = width - margin * 2
        let unit = (inner - gap * CGFloat(weights.count - 1)) / weights.reduce(0, +)
        let start = weights.prefix(first).reduce(0, +) * unit + CGFloat(first) * gap
        let end = start + weights[first..<(first + count)].reduce(0, +) * unit + CGFloat(count - 1) * gap
        let left = (margin + start).rounded(), right = (margin + end).rounded()
        return (left, right - left)
    }

    /// Places views side by side in one row, sized by `weights`.
    func row(_ views: [NSView], weights: [CGFloat], y: CGFloat, height: CGFloat, width: CGFloat) {
        for (index, view) in views.enumerated() {
            let (x, w) = span(index, 1, weights: weights, width: width)
            view.frame = NSRect(x: x, y: y, width: w, height: height)
        }
    }

    /// The tiles in one row when the page is wide enough, else wrapped by `grid`. Returns the bottom edge.
    func placeTiles(top: CGFloat, width: CGFloat, height: CGFloat = 112) -> CGFloat {
        guard width - margin * 2 >= 760 else { return grid(tiles, top: top, width: width, columns: tiles.count, height: height) }
        row(tiles, weights: tiles.map { _ in 1 }, y: top, height: height, width: width)
        return top + height
    }

    /// The apps card at `frame`. With `fill` the table shows as many apps as fit its height
    /// at 34 pt or more a row, sharing the height evenly; otherwise the card grows to its rows.
    func placeTable(_ frame: NSRect, fill: Bool) {
        let top: CGFloat = A2.padTop + 16 + 8, foot: CGFloat = 10
        tableTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: frame.width - A2.padSide * 2, height: 16)
        if fill {
            let body = max(table.headerHeight + 34, frame.height - top - foot) - table.headerHeight
            let rows = max(1, Int(body / 34))
            table.rowHeight = (body / CGFloat(rows) * 2).rounded(.down) / 2
            tableCard.frame = frame
            table.frame = NSRect(x: A2.padSide - table.inset, y: top, width: frame.width - (A2.padSide - table.inset) * 2,
                                 height: frame.height - top - foot)
            if fittedRows != rows {
                fittedRows = rows
                if let lastTable { fillTable(lastTable) }
            }
        } else {
            fittedRows = nil
            table.rowHeight = 34
            table.frame = NSRect(x: A2.padSide - table.inset, y: top, width: frame.width - (A2.padSide - table.inset) * 2, height: table.naturalHeight)
            tableCard.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: top + table.naturalHeight + foot)
        }
    }

    // MARK: Chart

    override func update(system: SystemSnapshot) {
        refreshChart(force: false)
        updateHero(system)
        updateTiles(system)
    }

    func updateHero(_ s: SystemSnapshot) {}
    func updateTiles(_ s: SystemSnapshot) {}

    /// "Last 4 minutes", "Last hour", "Last 24 hours": what the chart spans now.
    var rangeName: String {
        switch hero.range.selected {
        case 0 where hero.range.items.first == "5 Min" || hero.range.items == ["Live"]:
            let minutes = Int((Double(HistoryStore.recentSamples) * delegate.settings.interval / 60).rounded())
            return minutes <= 1 ? "Last minute" : "Last \(minutes) minutes"
        case 1: return "Last hour"
        case 2: return "Last 24 hours"
        default: return ""
        }
    }

    static func peak(_ values: [Float]) -> Float { values.lazy.filter { !$0.isNaN }.max() ?? 0 }

    /// The legend in the hero's corner: the highest point in view, then the span.
    func showPeak(_ text: String) {
        hero.header.items = [.init(text: "Peak", value: text), .init(text: rangeName, faint: true)]
    }

    /// 5 Min redraws every tick; Hour and Day only when a new minute is in.
    func refreshChart(force: Bool) {
        let history = delegate.monitor.history
        switch hero.range.selected {
        case 0:
            hero.chart.step = delegate.settings.interval
            hero.chart.primary = history.recent(metric)
            hero.chart.secondary = secondMetric.map { history.recent($0) } ?? []
            hero.chart.spikes = []
        default:
            let minute = Int(Date().timeIntervalSince1970 / 60)
            guard force || minute != lastMinute else { return }
            lastMinute = minute
            let minutes = hero.range.selected == 1 ? 60 : HistoryStore.minutes
            hero.chart.step = 60
            hero.chart.primary = history.day(metric, minutes: minutes)
            hero.chart.secondary = secondMetric.map { history.day($0, minutes: minutes) } ?? []
            SpikeLabels.refresh(self, minutes: minutes)
        }
        chartChanged()
    }

    /// After the chart has new values: subclasses set its scale and the legend.
    func chartChanged() {}

    // MARK: Table

    override func update(table: ProcessTable) {
        lastTable = table
        if showsTable { fillTable(table) }
        updateApps(table)
    }

    func updateApps(_ table: ProcessTable) {}

    /// The value each table column sorts by, for the given app.
    func sortValue(_ app: AppGroup, column: Int) -> Double { app.cpu }
    func cells(_ app: AppGroup, table: ProcessTable) -> [String] { [app.name] }
    var barColumnValue: (AppGroup) -> Double { { $0.cpu } }

    func fillTable(_ processTable: ProcessTable) {
        let column = table.sortColumn
        let sorted = processTable.apps.sorted { sortValue($0, column: column) > sortValue($1, column: column) }.prefix(fittedRows ?? maxRows)
        let peak = max(sorted.map(barColumnValue).max() ?? 0, 0.000_001)
        let rows = sorted.map { app in
            ColumnTable.Row(id: app.id, icon: Icons.icon(for: app), cells: cells(app, table: processTable),
                            fraction: barColumnValue(app) / peak)
        }
        let countChanged = rows.count != table.rows.count
        table.rows = rows
        if countChanged, fittedRows == nil { relayout() }
    }

    func appCPU(_ app: AppGroup, _ table: ProcessTable) -> String {
        Style.appCPU(app.cpu, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount)
    }

    func busiest(_ table: ProcessTable, by key: (AppGroup) -> Double) -> AppGroup? {
        table.apps.max { key($0) < key($1) }
    }

    /// "Apple M3 Max", from the CPU's brand string.
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()

    static var uptime: String? { Uptime.bootDate().map { Uptime.label(Date().timeIntervalSince($0)) } }

    /// Gigabytes as the mockups write them: "27", or "4.2" under ten.
    static func gigabytes(_ bytes: Double) -> String {
        let value = bytes / 1_073_741_824
        return String(format: value >= 9.95 ? "%.0f" : "%.1f", value)
    }
}

// MARK: - CPU

final class CPUPage: MachinePage {
    private let user = Tile("User"), system = Tile("System"), load = Tile("Load average")
    private let temperature = Tile("Temperature"), processes = Tile("Processes"), busiest = Tile("Busiest app")
    private let coresCard = CardView()
    private let coresHeader = A2Header()
    private let coreMap = A2CoreMap()
    private let heatKey = A2HeatKey()
    private var busiestID: String?

    override var demand: Demand { [.cpuCores] }
    override var chartTint: NSColor { A2.cpu }

    override func setUp() {
        heroHeight = 228
        hero.chart.format = { String(format: "%.0f%%", $0 * 100) }
        hero.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        hero.state.isHidden = false
        for tile in [user, system] { tile.showsMeter = true; tile.figure.format = { (String(format: "%.0f", $0 * 100), "%") } }
        load.figure.format = { (String(format: "%.2f", $0), "") }
        busiest.onClick = { [weak self] in if let id = self?.busiestID { self?.onSelect(.app(id)) } }
        tiles = [user, system, load, temperature, processes, busiest]

        coreMap.columns = HistoryStore.recentCoreSamples
        coresHeader.title = "Cores"
        coresHeader.symbol = "square.grid.2x2"
        coresHeader.tint = labelTint
        for view in [coresHeader, coreMap, heatKey] as [NSView] { coresCard.addSubview(view) }
        canvas.addSubview(coresCard)
        table.columns = [.init(title: "App", width: 0), .init(title: "CPU", width: 143, bar: true, valueWidth: 52),
                         .init(title: "Memory", width: 58), .init(title: "Power", width: 50), .init(title: "Processes", width: 62)]
        table.barEnd = A2.cpuLight
        tableTitle.text = cardTitle("Apps", "by CPU")
        showSubtitle(cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        showSubtitle(cores: delegate.system.cpu?.cores.count ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    private func showSubtitle(cores: Int) {
        let base = [Self.chip, "\(cores) cores"]
        subtitle([(base + [Self.uptime].compactMap { $0 }).joined(separator: " · "), base.joined(separator: " · "), Self.chip])
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: heroHeight)
        var y = placeTiles(top: hero.frame.maxY + gap, width: width) + gap
        let left = room - (y - margin)
        if inner >= 760 {
            let height = max(300, left)
            row([coresCard, tableCard], weights: [2, 3], y: y, height: height, width: width)
            placeTable(tableCard.frame, fill: true)
            y += height
        } else {
            coresCard.frame = NSRect(x: margin, y: y, width: inner, height: 300)
            y += 300 + gap
            placeTable(NSRect(x: margin, y: y, width: inner, height: max(300, left - 300 - gap)), fill: true)
            y = tableCard.frame.maxY
        }
        let cardWidth = coresCard.bounds.width - A2.padSide * 2
        coresHeader.frame = NSRect(x: A2.padSide, y: A2.padTop, width: cardWidth, height: 16)
        let keyHeight: CGFloat = 14
        coreMap.frame = NSRect(x: A2.padSide, y: A2.padTop + 16 + 12, width: cardWidth,
                               height: coresCard.bounds.height - (A2.padTop + 16 + 12) - 12 - keyHeight - A2.padTop)
        heatKey.frame = NSRect(x: A2.padSide, y: coreMap.frame.maxY + 12, width: cardWidth, height: keyHeight)
        return y + margin
    }

    override func chartChanged() {
        let peak = Self.peak(hero.chart.primary)
        hero.chart.ceiling = Float(min(1, ChartScale.ceiling(peak: Double(peak), minimum: 0.1)))
        showPeak(Format.percent(Double(peak)))
    }

    override func updateHero(_ s: SystemSnapshot) {
        guard let c = s.cpu else { return }
        hero.figure.set(c.total)
        hero.state.text = c.total >= 0.85 ? "Strained" : (c.total >= 0.6 ? "Busy" : "Normal")
        hero.state.tone = c.total >= 0.85 ? .bad : (c.total >= 0.6 ? .warn : .good)
        hero.meta.text = A2.plain("\(c.performanceCores) performance and \(c.efficiencyCores) efficiency cores")
        hero.needsLayout = true

        let history = delegate.monitor.history.cores()
        let efficiency = min(c.efficiencyCores, history.count)
        var rows: [A2CoreMap.Row] = []
        for (number, index) in (efficiency..<history.count).enumerated() { rows.append(.init(label: "P\(number + 1)", values: history[index])) }
        for index in 0..<efficiency { rows.append(.init(label: "E\(index + 1)", values: history[index])) }
        coreMap.rows = rows
        coreMap.groupBreak = history.count - efficiency
        coresHeader.detail = "\(c.cores.count)"
        let busy = c.cores.filter { $0 >= 0.8 }.count
        coresHeader.items = [.init(text: "Last \(Int(Double(HistoryStore.recentCoreSamples) * delegate.settings.interval)) s · \(busy) busy now")]
    }

    override func updateTiles(_ s: SystemSnapshot) {
        guard let c = s.cpu else { return }
        user.figure.set(c.user)
        user.meter.fraction = c.user
        user.set(note: "Your apps")
        system.figure.set(c.system)
        system.meter.fraction = c.system
        system.set(note: "macOS")
        load.figure.set(c.loadAverage.first ?? 0)
        load.set(notes: c.loadAverage.count == 3 ? [String(format: "5 min %.1f · 15 min %.1f", c.loadAverage[1], c.loadAverage[2]),
                                                    String(format: "5 min %.1f · 15 min %.1f", c.loadAverage[1], c.loadAverage[2]).replacingOccurrences(of: " min", with: "m")] : [""])
        if let t = s.thermal, let celsius = t.cpuCelsius {
            temperature.set(text: Format.temperature(celsius).0, unit: Format.temperature(celsius).1)
            temperature.set(note: t.fans.isEmpty ? "No fans" : "Fans " + t.fans.map { "\(Int($0.rpm))" }.joined(separator: ", ") + " rpm")
        }
    }

    override func updateApps(_ table: ProcessTable) {
        processes.set(text: "\(table.processes.count)")
        processes.set(note: "In \(table.apps.count) apps")
        if let app = busiest(table, by: { $0.cpu }) {
            busiestID = app.id
            busiest.set(text: app.name)
            busiest.set(notes: [appCPU(app, table) + " · \(app.processCount) processes", appCPU(app, table)])
        }
    }

    override func sortValue(_ app: AppGroup, column: Int) -> Double {
        switch column {
        case 2: return Double(app.memory)
        case 3: return app.watts
        case 4: return Double(app.processCount)
        default: return app.cpu
        }
    }

    override func cells(_ app: AppGroup, table: ProcessTable) -> [String] {
        [app.name, appCPU(app, table), Format.memory(app.memory), app.watts > 0.005 ? Format.watts(app.watts) : "–", "\(app.processCount)"]
    }
}

// MARK: - Memory

final class MemoryPage: MachinePage {
    private let pressure = Tile("Pressure"), available = Tile("Available"), swapTile = Tile("Swap used")
    private let compressed = Tile("Compressed"), largest = Tile("Largest app")
    private let typesCard = CardView()
    private let typesHeader = A2Header()
    private let waffle = A2Waffle()
    private let keys = A2ShareKeys()
    private var largestID: String?
    private var total: UInt64 = 0

    override var chartTint: NSColor { A2.memoryApp }

    override func setUp() {
        heroHeight = 228
        hero.figure.format = { (Self.gigabytes($0), "GB") }
        hero.chart.format = { Format.memory(Double($0)) }
        hero.state.isHidden = false
        available.showsMeter = true
        largest.onClick = { [weak self] in if let id = self?.largestID { self?.onSelect(.app(id)) } }
        tiles = [pressure, available, swapTile, compressed, largest]
        typesHeader.title = "By kind"
        typesHeader.symbol = "square.grid.2x2"
        typesHeader.tint = labelTint
        for view in [typesHeader, waffle, keys] as [NSView] { typesCard.addSubview(view) }
        canvas.addSubview(typesCard)
        table.columns = [.init(title: "App", width: 0), .init(title: "Memory", width: 201, bar: true, valueWidth: 60),
                         .init(title: "CPU", width: 48), .init(title: "Processes", width: 62)]
        table.barEnd = Theme.dynamic(0x8E8CF0, 0xB4B2FF)
        tableTitle.text = cardTitle("Apps", "by memory")
        subtitle(["\(Format.memory(ProcessInfo.processInfo.physicalMemory)) unified memory"])
    }

    override var barColumnValue: (AppGroup) -> Double { { Double($0.memory) } }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: heroHeight)
        var y = placeTiles(top: hero.frame.maxY + gap, width: width) + gap
        let left = room - (y - margin)
        if inner >= 760 {
            let height = max(300, left)
            row([typesCard, tableCard], weights: [2, 3], y: y, height: height, width: width)
            placeTable(tableCard.frame, fill: true)
            y += height
        } else {
            typesCard.frame = NSRect(x: margin, y: y, width: inner, height: 300)
            y += 300 + gap
            placeTable(NSRect(x: margin, y: y, width: inner, height: max(300, left - 300 - gap)), fill: true)
            y = tableCard.frame.maxY
        }
        let cardWidth = typesCard.bounds.width - A2.padSide * 2
        typesHeader.frame = NSRect(x: A2.padSide, y: A2.padTop, width: cardWidth, height: 16)
        // Five kinds in three columns: two rows of keys.
        let keysHeight = A2ShareKeys.keyHeight * 2 + A2ShareKeys.rowGap
        let waffleTop = A2.padTop + 16 + 14
        waffle.frame = NSRect(x: A2.padSide, y: waffleTop, width: cardWidth,
                              height: max(40, typesCard.bounds.height - waffleTop - 16 - keysHeight - A2.padTop))
        keys.frame = NSRect(x: A2.padSide, y: waffle.frame.maxY + 16, width: cardWidth, height: keysHeight)
        return y + margin
    }

    override func chartChanged() {
        if total > 0 { hero.chart.ceiling = Float(total) }
        showPeak(Format.memory(Double(Self.peak(hero.chart.primary))))
    }

    override func updateHero(_ s: SystemSnapshot) {
        guard let m = s.memory else { return }
        if m.total != total {
            total = m.total
            hero.chart.ceiling = Float(m.total)
        }
        hero.figure.set(Double(m.used))
        let level = m.pressure == .normal ? "Normal" : (m.pressure == .warning ? "Warning" : "Critical")
        hero.state.text = level
        hero.state.tone = m.pressure == .normal ? .good : (m.pressure == .warning ? .warn : .bad)
        hero.meta.text = A2.plain("Used of \(Format.memory(m.total)) · \(Format.percent(m.usedFraction))")
        hero.needsLayout = true
        subtitle(["\(Format.memory(m.total)) unified memory · \(Self.gigabytes(Double(m.used))) GB in use", "\(Format.memory(m.total)) unified memory"])
        let parts: [(String, UInt64, NSColor)] = [
            ("App", m.app, A2.memoryApp), ("Wired", m.wired, A2.memoryWired), ("Compressed", m.compressed, A2.memoryCompressed),
            ("Cached", m.cached, A2.teal), ("Free", m.free, A2.track),
        ]
        waffle.parts = parts.map { .init(value: Double($0.1), color: $0.2) }
        let whole = Double(max(m.total, 1))
        keys.keys = parts.map { .init(label: $0.0, share: Format.percent(Double($0.1) / whole), value: Format.memory($0.1), color: $0.2) }
        typesHeader.items = [.init(text: "\(Format.memory(m.total)) total")]
    }

    override func updateTiles(_ s: SystemSnapshot) {
        guard let m = s.memory else { return }
        let level = m.pressure == .normal ? "Normal" : (m.pressure == .warning ? "Warning" : "Critical")
        pressure.set(text: level)
        pressure.figure.color = m.pressure == .normal ? A2.good : (m.pressure == .warning ? A2.warn : A2.bad)
        pressure.set(note: m.pressure == .normal ? "Plenty to spare" : "Apps are being squeezed")
        let free = m.total > m.used ? m.total - m.used : 0
        let (value, unit) = DashboardView.split(Format.memory(free))
        available.set(text: value, unit: unit)
        available.meter.fraction = Double(free) / Double(max(m.total, 1))
        available.set(note: "Free or reclaimable")
        let (swapValue, swapUnit) = DashboardView.split(Format.memory(m.swapUsed))
        swapTile.set(text: swapValue, unit: swapUnit)
        swapTile.set(note: "Moved out to disk")
        let (compressedValue, compressedUnit) = DashboardView.split(Format.memory(m.compressed))
        compressed.set(text: compressedValue, unit: compressedUnit)
        compressed.set(note: "Squeezed in place")
    }

    override func updateApps(_ table: ProcessTable) {
        if let app = busiest(table, by: { Double($0.memory) }) {
            largestID = app.id
            largest.set(text: app.name)
            largest.set(notes: [Format.memory(app.memory) + " · \(app.processCount) processes", Format.memory(app.memory)])
        }
    }

    override func sortValue(_ app: AppGroup, column: Int) -> Double {
        switch column {
        case 2: return app.cpu
        case 3: return Double(app.processCount)
        default: return Double(app.memory)
        }
    }

    override func cells(_ app: AppGroup, table: ProcessTable) -> [String] {
        [app.name, Format.memory(app.memory), appCPU(app, table), "\(app.processCount)"]
    }
}

// MARK: - Disk

class DiskPage: MachinePage {
    private let reading = Tile("Reading"), writing = Tile("Writing"), readToday = Tile("Read today")
    private let writtenToday = Tile("Written today"), writer = Tile("Busiest writer")
    private let volumesCard = CardView()
    private let volumesTitle = TextLine()
    private var volumeRows: [ListRow] = []
    private var volumesCheckedAt = Date.distantPast
    private var writerID: String?

    override func setUp() {
        secondMetric = .diskWrite
        hero.chart.format = { Format.rate(Double($0)) }
        hero.chart.names = ("Read", "Write")
        hero.figure.format = { DashboardView.split(Format.bytes(UInt64(max(0, $0)))) }
        writer.onClick = { [weak self] in if let id = self?.writerID { self?.onSelect(.app(id)) } }
        tiles = [reading, writing, readToday, writtenToday, writer]
        volumesCard.addSubview(volumesTitle)
        volumesTitle.text = cardTitle("Volumes", "")
        extras = [(volumesCard, 120)]
        table.columns = [.init(title: "App", width: 0), .init(title: "Write", width: 150, bar: true), .init(title: "Read", width: 80),
                         .init(title: "CPU", width: 70), .init(title: "Memory", width: 80)]
        tableTitle.text = cardTitle("Apps", "by disk writes")
    }

    override var barColumnValue: (AppGroup) -> Double { { $0.diskWritePerSecond } }

    override func arrange(width: CGFloat) -> CGFloat {
        let bottom = super.arrange(width: width)
        let inner = volumesCard.bounds.width - 40
        volumesTitle.frame = NSRect(x: 20, y: 16, width: inner, height: 20)
        for (index, row) in volumeRows.enumerated() { row.frame = NSRect(x: 20, y: 46 + CGFloat(index) * 32, width: inner, height: 32) }
        return bottom
    }

    override func updateHero(_ s: SystemSnapshot) {
        if Date().timeIntervalSince(volumesCheckedAt) > 30 { refreshVolumes() }
        guard let d = s.disk else { return }
        hero.figure.set(Double(d.volumeFree))
        hero.meta.text = A2.plain("Free on the startup disk of \(Format.bytes(d.volumeTotal)) · read \(Format.rate(d.readBytesPerSecond)) · write \(Format.rate(d.writeBytesPerSecond))")
        hero.state.isHidden = !Strain.disk(d)
        hero.state.text = "Low space"
        hero.state.tone = .bad
        hero.chart.secondaryColor = A2.cpu
        hero.header.items = [.init(text: "Read", dot: chartTint), .init(text: "Write", dot: A2.cpu), .init(text: rangeName, faint: true)]
        hero.needsLayout = true
    }

    private func refreshVolumes() {
        volumesCheckedAt = Date()
        let volumes = Volumes.list()
        while volumeRows.count < volumes.count {
            let row = ListRow()
            volumesCard.addSubview(row)
            volumeRows.append(row)
        }
        for (index, row) in volumeRows.enumerated() {
            guard index < volumes.count else { row.isHidden = true; continue }
            let volume = volumes[index]
            row.isHidden = false
            row.icon = NSWorkspace.shared.icon(forFile: volume.path)
            row.name = volume.name
            row.note = "\(Format.bytes(volume.free)) free of \(Format.bytes(volume.total))"
            row.value = Format.percent(volume.usedFraction)
            row.fraction = volume.usedFraction
            row.barColor = volume.isInternal && volume.usedFraction > 0.95 ? Theme.bad : Theme.series[1]
            row.showsRule = index < volumes.count - 1
        }
        let wanted = 56 + CGFloat(volumes.count) * 32
        if extras.first?.1 != wanted {
            extras = [(volumesCard, wanted)]
            relayout()
        }
    }

    override func updateTiles(_ s: SystemSnapshot) {
        guard let d = s.disk else { return }
        let (r, ru) = DashboardView.split(Format.rate(d.readBytesPerSecond))
        reading.set(text: r, unit: ru)
        reading.set(note: "Right now")
        let (w, wu) = DashboardView.split(Format.rate(d.writeBytesPerSecond))
        writing.set(text: w, unit: wu)
        writing.set(note: "Right now")
        let midnight = Calendar.current.startOfDay(for: Date())
        let history = delegate.monitor.history
        let (rt, rtu) = DashboardView.split(Format.bytes(UInt64(history.total(.diskRead, since: midnight))))
        readToday.set(text: rt, unit: rtu)
        readToday.set(note: "Since midnight")
        let (wt, wtu) = DashboardView.split(Format.bytes(UInt64(history.total(.diskWrite, since: midnight))))
        writtenToday.set(text: wt, unit: wtu)
        writtenToday.set(note: "Since midnight")
    }

    override func updateApps(_ table: ProcessTable) {
        if let app = busiest(table, by: { $0.diskWritePerSecond }), app.diskWritePerSecond > 0 {
            writerID = app.id
            writer.set(text: app.name)
            writer.set(notes: [Format.rate(app.diskWritePerSecond) + " · \(app.processCount) processes", Format.rate(app.diskWritePerSecond)])
        }
    }

    override func sortValue(_ app: AppGroup, column: Int) -> Double {
        switch column {
        case 2: return app.diskReadPerSecond
        case 3: return app.cpu
        case 4: return Double(app.memory)
        default: return app.diskWritePerSecond
        }
    }

    override func cells(_ app: AppGroup, table: ProcessTable) -> [String] {
        [app.name, app.diskWritePerSecond > 0 ? Format.rate(app.diskWritePerSecond) : "–",
         app.diskReadPerSecond > 0 ? Format.rate(app.diskReadPerSecond) : "–", appCPU(app, table), Format.memory(app.memory)]
    }
}

// MARK: - Network

final class NetworkPage: MachinePage {
    private let downToday = Tile("Downloaded today"), upToday = Tile("Uploaded today")
    private let week = Tile("Last 7 days"), month = Tile("Last 30 days"), busiestTile = Tile("Busiest app")
    private var busiestID: String?
    private var totalsAt = Date.distantPast
    private var placeAt = Date.distantPast
    private lazy var cards = NetworkCards(page: self)

    override var demand: Demand { [.appNetwork] }
    override var chartTint: NSColor { A2.down }

    override func setUp() {
        metric = .networkIn
        secondMetric = .networkOut
        heroHeight = 262
        hero.chartTop = 86
        hero.header.title = "Throughput"
        hero.chart.format = { Format.rate(Double($0)) }
        hero.chart.names = ("Down", "Up")
        hero.chart.secondaryColor = A2.up
        hero.figure.format = { value in
            let (number, unit) = DashboardView.split(Format.rate(value))
            return (number, unit + " down")
        }
        busiestTile.onClick = { [weak self] in if let id = self?.busiestID { self?.onSelect(.app(id)) } }
        tiles = [downToday, upToday, week, month, busiestTile]
        for tile in tiles { tile.plain = true }
        extras = cards.extras
        showsTable = false
        subtitle(["Network"])
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: heroHeight)
        var y = hero.frame.maxY + gap
        if inner >= 760 {
            row(tiles, weights: [1, 1, 1, 1, 1.25], y: y, height: 96, width: width)
            y += 96 + gap
        } else {
            y = grid(tiles, top: y, width: width, columns: 3, height: 96) + gap
        }
        let left = room - (y - margin)
        let lists = extras.map(\.0)
        if inner >= 760 {
            let height = max(NetworkCards.height, left)
            row(lists, weights: [1, 1], y: y, height: height, width: width)
            y += height
        } else {
            for card in lists {
                card.frame = NSRect(x: margin, y: y, width: inner, height: NetworkCards.height)
                y += NetworkCards.height + gap
            }
            y -= gap
        }
        return y + margin
    }

    override func chartChanged() {
        let down = Self.peak(hero.chart.primary), up = Self.peak(hero.chart.secondary)
        hero.chart.ceiling = Float(ChartScale.ceiling(peak: Double(max(down, up)), minimum: 10_000))
        peakText = Format.rate(Double(max(down, up)))
    }

    private var peakText = "–"

    override func updateHero(_ s: SystemSnapshot) {
        if Date().timeIntervalSince(placeAt) > 30 {
            placeAt = Date()
            let place = NetworkPlace.current()
            subtitle([place.map { [$0.kind, $0.address].joined(separator: " · ") } ?? "Not connected", place?.kind ?? ""])
        }
        guard let n = s.network else { return }
        hero.figure.set(n.receivedBytesPerSecond)
        hero.meta.text = A2.facts([.init(label: "Upload", value: Format.rate(n.sentBytesPerSecond)), .init(label: "Peak", value: peakText)])
        hero.header.items = [.init(text: "Down \(Format.rate(n.receivedBytesPerSecond))", dot: A2.down),
                             .init(text: "Up \(Format.rate(n.sentBytesPerSecond))", dot: A2.up), .init(text: rangeName, faint: true)]
        hero.needsLayout = true
    }

    override func updateTiles(_ s: SystemSnapshot) {
        // Totals change slowly; read them every half minute.
        guard Date().timeIntervalSince(totalsAt) > 30 else { return }
        totalsAt = Date()
        let history = delegate.monitor.history
        let midnight = Calendar.current.startOfDay(for: Date())
        let down = history.total(.networkIn, since: midnight), up = history.total(.networkOut, since: midnight)
        set(downToday, Format.bytes(UInt64(down)), "Since midnight")
        set(upToday, Format.bytes(UInt64(up)), "Since midnight")
        let weekStart = Date().addingTimeInterval(-7 * 86_400), monthStart = Date().addingTimeInterval(-30 * 86_400)
        let weekDown = history.total(.networkIn, since: weekStart), weekUp = history.total(.networkOut, since: weekStart)
        set(week, Format.bytes(UInt64(weekDown + weekUp)), "↓ \(Format.bytes(UInt64(weekDown))) · ↑ \(Format.bytes(UInt64(weekUp)))")
        let monthDown = history.total(.networkIn, since: monthStart), monthUp = history.total(.networkOut, since: monthStart)
        set(month, Format.bytes(UInt64(monthDown + monthUp)), "↓ \(Format.bytes(UInt64(monthDown))) · ↑ \(Format.bytes(UInt64(monthUp)))")
    }

    private func set(_ tile: Tile, _ text: String, _ note: String) {
        let (value, unit) = DashboardView.split(text)
        tile.set(text: value, unit: unit)
        tile.set(note: note)
    }

    override func updateApps(_ table: ProcessTable) {
        cards.update(table: table)
        if let app = busiest(table, by: { $0.networkPerSecond }), app.networkPerSecond > 0 {
            busiestID = app.id
            busiestTile.set(text: app.name)
            busiestTile.set(note: "↓ \(Format.rate(app.networkInPerSecond)) · ↑ \(Format.rate(app.networkOutPerSecond))")
        } else if !table.networkMeasured {
            busiestTile.set(text: "–")
            busiestTile.set(note: "Per-app traffic is off")
        }
    }
}

// MARK: - GPU

final class GPUPage: MachinePage {
    private let memoryTile = Tile("GPU memory"), average = Tile("Average"), peak = Tile("Peak")
    private let temperature = Tile("Temperature"), power = Tile("GPU power")
    /// GPU time per app, read from the driver only while this page is on screen.
    private let clients = GPUClients()
    private var gpuShare: [String: Double] = [:]

    override var chartTint: NSColor { A2.gpu }

    override func setUp() {
        hero.chart.format = { String(format: "%.0f%%", $0 * 100) }
        hero.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        for tile in [average, peak] { tile.figure.format = { (String(format: "%.0f", $0 * 100), "%") }; tile.showsMeter = true }
        tiles = [memoryTile, average, peak, temperature, power]
        table.columns = [.init(title: "App", width: 0), .init(title: "GPU", width: 295, bar: true, valueWidth: 64), .init(title: "CPU", width: 64),
                         .init(title: "Memory", width: 76), .init(title: "Processes", width: 80)]
        table.barEnd = Theme.dynamic(0xFF7A96, 0xFF8AA0)
        tableTitle.text = cardTitle("Apps", "by GPU time")
        subtitle(["Shares \(Format.memory(ProcessInfo.processInfo.physicalMemory)) of unified memory with the CPU"])
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: heroHeight)
        let y = placeTiles(top: hero.frame.maxY + gap, width: width) + gap
        // A narrow window has no room for the long GPU bar.
        table.columns[1].width = inner >= 760 ? 295 : 140
        placeTable(NSRect(x: margin, y: y, width: inner, height: max(260, room - (y - margin))), fill: true)
        return tableCard.frame.maxY + margin
    }

    override func chartChanged() {
        let top = Self.peak(hero.chart.primary)
        hero.chart.ceiling = Float(min(1, ChartScale.ceiling(peak: Double(top), minimum: 0.1)))
        showPeak(Format.percent(Double(top)))
    }

    override func updateHero(_ s: SystemSnapshot) {
        guard let g = s.gpu else { return }
        hero.figure.set(g.utilization)
        hero.meta.text = A2.plain(g.name + (g.coreCount.map { " · \($0) cores" } ?? ""))
        hero.needsLayout = true
    }

    override func updateTiles(_ s: SystemSnapshot) {
        if let used = s.gpu?.memoryUsed {
            let (value, unit) = DashboardView.split(Format.memory(used))
            memoryTile.set(text: value, unit: unit)
            memoryTile.set(note: "In use")
        }
        let values = hero.chart.primary.filter { !$0.isNaN }
        if !values.isEmpty {
            let mean = Double(values.reduce(0, +)) / Double(values.count)
            average.figure.set(mean)
            average.meter.fraction = mean
            average.set(note: "In the chart above")
            let top = Double(values.max() ?? 0)
            peak.figure.set(top)
            peak.meter.fraction = top
            peak.set(note: "In the chart above")
        }
        if let celsius = s.thermal?.gpuCelsius {
            temperature.set(text: Format.temperature(celsius).0, unit: Format.temperature(celsius).1)
            temperature.set(note: "Hottest GPU sensor")
        }
        if let watts = s.power?.gpu {
            power.set(text: String(format: "%.1f", watts), unit: "W")
            power.set(note: "Right now")
        }
    }

    override func update(table: ProcessTable) {
        let shares = clients.sample()
        var byApp: [String: Double] = [:]
        for process in table.processes {
            if let share = shares[process.pid] { byApp[process.groupID, default: 0] += share }
        }
        gpuShare = byApp
        super.update(table: table)
    }

    override var barColumnValue: (AppGroup) -> Double { { [unowned self] in self.gpuShare[$0.id] ?? 0 } }

    override func sortValue(_ app: AppGroup, column: Int) -> Double {
        switch column {
        case 2: return app.cpu
        case 3: return Double(app.memory)
        case 4: return Double(app.processCount)
        default: return (gpuShare[app.id] ?? 0) + app.cpu * 1e-6
        }
    }

    override func cells(_ app: AppGroup, table: ProcessTable) -> [String] {
        let gpu = gpuShare[app.id].map { $0 >= 0.0005 ? String(format: "%.1f%%", $0 * 100) : "–" } ?? "–"
        // Processes macOS keeps to itself (WindowServer) read as zero; show a dash.
        return [app.name, gpu, app.memory == 0 ? "–" : appCPU(app, table), app.memory == 0 ? "–" : Format.memory(app.memory),
                "\(app.processCount)"]
    }
}

/// "● Read  ● Write" for a chart with two lines.
func legendText(_ first: (String, NSColor), _ second: (String, NSColor)) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for (index, (name, color)) in [first, second].enumerated() {
        if index > 0 { text.append(NSAttributedString(string: "   ")) }
        text.append(NSAttributedString(string: "● ", attributes: [.font: Theme.mono(10), .foregroundColor: color]))
        text.append(Theme.caption(name))
    }
    return text
}
