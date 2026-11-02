import AppKit
import WispCore

/// A machine page: a large chart with a Live/Hour/Day switch, a row of tiles,
/// optional extra cards and the apps that use the most of this resource.
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
    private var lastMinute = 0
    private(set) var lastTable: ProcessTable?
    private let maxRows = 40

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
        let tint = pageTint
        hero.tint = tint
        for tile in tiles { tile.tint = tint }
    }

    override var pageTint: NSColor { (PageID.allCases.first { $0.title == hero.title } ?? .cpu).tint }

    /// The Live / Hour / Day switch sits in the toolbar on its glass capsule.
    override var toolbarItems: [NSView] { hero.range.items.count > 1 ? [hero.range] : [] }

    /// Subclasses add tiles, extras and table columns here.
    func setUp() {}

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: 300)
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
        tableTitle.frame = NSRect(x: 20, y: 16, width: inner - 40, height: 20)
        table.frame = NSRect(x: 12, y: 44, width: inner - 24, height: table.naturalHeight)
        tableCard.frame = NSRect(x: margin, y: y, width: inner, height: table.naturalHeight + 56)
        return tableCard.frame.maxY + margin
    }

    // MARK: Chart

    override func update(system: SystemSnapshot) {
        refreshChart(force: false)
        updateHero(system)
        updateTiles(system)
    }

    func updateHero(_ s: SystemSnapshot) {}
    func updateTiles(_ s: SystemSnapshot) {}

    /// Live redraws every tick; Hour and Day only when a new minute is in.
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
    }

    // MARK: Table

    override func update(table: ProcessTable) {
        lastTable = table
        fillTable(table)
        updateApps(table)
    }

    func updateApps(_ table: ProcessTable) {}

    /// The value each table column sorts by, for the given app.
    func sortValue(_ app: AppGroup, column: Int) -> Double { app.cpu }
    func cells(_ app: AppGroup, table: ProcessTable) -> [String] { [app.name] }
    var barColumnValue: (AppGroup) -> Double { { $0.cpu } }

    func fillTable(_ processTable: ProcessTable) {
        let column = table.sortColumn
        let sorted = processTable.apps.sorted { sortValue($0, column: column) > sortValue($1, column: column) }.prefix(maxRows)
        let peak = max(sorted.map(barColumnValue).max() ?? 0, 0.000_001)
        let rows = sorted.map { app in
            ColumnTable.Row(id: app.id, icon: Icons.icon(for: app), cells: cells(app, table: processTable),
                            fraction: barColumnValue(app) / peak)
        }
        let countChanged = rows.count != table.rows.count
        table.rows = rows
        if countChanged { relayout() }
    }

    func appCPU(_ app: AppGroup, _ table: ProcessTable) -> String {
        Style.appCPU(app.cpu, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount)
    }

    func busiest(_ table: ProcessTable, by key: (AppGroup) -> Double) -> AppGroup? {
        table.apps.max { key($0) < key($1) }
    }
}

// MARK: - CPU

final class CPUPage: MachinePage {
    private let user = Tile("User"), system = Tile("System"), load = Tile("Load average")
    private let temperature = Tile("Temperature"), processes = Tile("Processes"), busiest = Tile("Busiest app")
    private let coresCard = CardView()
    private let coresTitle = TextLine()
    private let coresMeta = TextLine()
    private let heatmap = Heatmap()
    private let heatKey = HeatKey()
    private var busiestID: String?

    override var demand: Demand { [.cpuCores] }

    override func setUp() {
        hero.chart.ceiling = 1
        hero.chart.format = { String(format: "%.0f%%", $0 * 100) }
        hero.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        hero.state.isHidden = false
        for tile in [user, system] { tile.showsMeter = true; tile.figure.format = { (String(format: "%.0f", $0 * 100), "%") } }
        load.figure.format = { (String(format: "%.2f", $0), "") }
        busiest.onClick = { [weak self] in if let id = self?.busiestID { self?.onSelect(.app(id)) } }
        tiles = [user, system, load, temperature, processes, busiest]

        heatmap.columns = HistoryStore.recentCoreSamples
        heatmap.rowPitch = 14
        heatmap.labelWidth = 34
        for view in [coresTitle, coresMeta, heatmap, heatKey] as [NSView] { coresCard.addSubview(view) }
        extras = [(coresCard, 60 + 14 * 14 + 40)]
        table.columns = [.init(title: "App", width: 0), .init(title: "CPU", width: 150, bar: true),
                         .init(title: "Memory", width: 80), .init(title: "Power", width: 70), .init(title: "Processes", width: 70)]
        tableTitle.text = cardTitle("Apps", "by CPU")
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let bottom = super.arrange(width: width)
        let inner = coresCard.bounds.width - 40
        coresTitle.frame = NSRect(x: 20, y: 16, width: inner, height: 20)
        coresMeta.frame = NSRect(x: 20, y: 38, width: inner, height: 14)
        heatmap.frame = NSRect(x: 20, y: 62, width: inner, height: heatmap.naturalHeight)
        heatKey.frame = NSRect(x: 20 + inner - 160, y: heatmap.frame.maxY + 14, width: 160, height: 14)
        return bottom
    }

    override func updateHero(_ s: SystemSnapshot) {
        guard let c = s.cpu else { return }
        hero.figure.set(c.total)
        hero.state.text = c.total >= 0.85 ? "Strained" : (c.total >= 0.6 ? "Busy" : "Normal")
        hero.state.tone = c.total >= 0.85 ? .bad : (c.total >= 0.6 ? .warn : .good)
        hero.meta.text = Theme.caption("\(c.performanceCores) performance and \(c.efficiencyCores) efficiency cores")
        hero.needsLayout = true

        let history = delegate.monitor.history.cores()
        let efficiency = min(c.efficiencyCores, history.count)
        var rows: [Heatmap.Row] = []
        for (number, index) in (efficiency..<history.count).enumerated() { rows.append(.init(label: "P\(number + 1)", tag: "", values: history[index])) }
        for index in 0..<efficiency { rows.append(.init(label: "E\(index + 1)", tag: "", values: history[index])) }
        heatmap.rows = rows
        coresTitle.text = cardTitle("Cores", "\(c.cores.count)")
        let busy = c.cores.filter { $0 >= 0.8 }.count
        coresMeta.text = Theme.caption("Last \(Int(Double(HistoryStore.recentCoreSamples) * delegate.settings.interval)) s · \(busy) busy now")
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
        load.set(note: c.loadAverage.count == 3 ? String(format: "5 min %.1f · 15 min %.1f", c.loadAverage[1], c.loadAverage[2]) : "")
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
            busiest.set(note: appCPU(app, table) + " · \(app.processCount) processes")
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
    private let typesTitle = TextLine()
    private let waffle = Waffle()
    private let legend = LegendStrip()
    private var largestID: String?

    override func setUp() {
        hero.figure.format = { value in DashboardView.split(Format.memory(value)) }
        hero.chart.format = { Format.memory(Double($0)) }
        hero.state.isHidden = false
        available.showsMeter = true
        largest.onClick = { [weak self] in if let id = self?.largestID { self?.onSelect(.app(id)) } }
        tiles = [pressure, available, swapTile, compressed, largest]
        waffle.cell = 9
        waffle.gap = 3
        for view in [typesTitle, waffle, legend] as [NSView] { typesCard.addSubview(view) }
        typesTitle.text = cardTitle("By kind", "")
        waffle.onHover = { [weak self] hover in self?.legend.highlighted = hover?.0 }
        legend.onHover = { [weak self] index in self?.waffle.highlighted = index }
        extras = [(typesCard, 190)]
        table.columns = [.init(title: "App", width: 0), .init(title: "Memory", width: 160, bar: true),
                         .init(title: "CPU", width: 70), .init(title: "Processes", width: 70)]
        tableTitle.text = cardTitle("Apps", "by memory")
    }

    override var barColumnValue: (AppGroup) -> Double { { Double($0.memory) } }

    override func arrange(width: CGFloat) -> CGFloat {
        let bottom = super.arrange(width: width)
        let inner = typesCard.bounds.width - 40
        typesTitle.frame = NSRect(x: 20, y: 16, width: inner, height: 20)
        waffle.frame = NSRect(x: 20, y: 48, width: inner, height: 6 * 12 - 3)
        legend.frame = NSRect(x: 20, y: 136, width: inner, height: 36)
        return bottom
    }

    override func updateHero(_ s: SystemSnapshot) {
        guard let m = s.memory else { return }
        hero.figure.set(Double(m.used))
        hero.chart.ceiling = Float(m.total)
        let level = m.pressure == .normal ? "Normal" : (m.pressure == .warning ? "Warning" : "Critical")
        hero.state.text = level
        hero.state.tone = m.pressure == .normal ? .good : (m.pressure == .warning ? .warn : .bad)
        hero.meta.text = Theme.caption("Used of \(Format.memory(m.total)) · \(Format.percent(m.usedFraction))")
        hero.needsLayout = true
        let parts: [(String, UInt64, NSColor)] = [
            ("App", m.app, Theme.indigo), ("Wired", m.wired, Theme.orange), ("Compressed", m.compressed, Theme.indigo.withAlphaComponent(0.45)),
            ("Cached", m.cached, Theme.teal), ("Free", m.free, Theme.track),
        ]
        waffle.parts = parts.map { .init(name: $0.0, value: Double($0.1), color: $0.2) }
        legend.items = parts.map {
            .init(name: $0.0, value: Format.memory($0.1), share: Format.percent(Double($0.1) / Double(max(m.total, 1))), color: $0.2)
        }
    }

    override func updateTiles(_ s: SystemSnapshot) {
        guard let m = s.memory else { return }
        let level = m.pressure == .normal ? "Normal" : (m.pressure == .warning ? "Warning" : "Critical")
        pressure.set(text: level)
        pressure.figure.color = m.pressure == .normal ? Theme.good : (m.pressure == .warning ? Theme.warn : Theme.bad)
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
            largest.set(note: Format.memory(app.memory) + " · \(app.processCount) processes")
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

final class DiskPage: MachinePage {
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
        hero.meta.text = Theme.caption("Free on the startup disk of \(Format.bytes(d.volumeTotal)) · read \(Format.rate(d.readBytesPerSecond)) · write \(Format.rate(d.writeBytesPerSecond))")
        hero.state.isHidden = !Strain.disk(d)
        hero.state.text = "Low space"
        hero.state.tone = .bad
        hero.chart.secondaryColor = PageID.cpu.tint
        hero.legend.text = legendText(("Read", pageTint), ("Write", PageID.cpu.tint))
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
            writer.set(note: Format.rate(app.diskWritePerSecond) + " · \(app.processCount) processes")
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

    override var demand: Demand { [.appNetwork] }

    override func setUp() {
        metric = .networkIn
        secondMetric = .networkOut
        hero.chart.format = { Format.rate(Double($0)) }
        hero.chart.names = ("Down", "Up")
        hero.figure.format = { DashboardView.split(Format.rate($0)) }
        busiestTile.onClick = { [weak self] in if let id = self?.busiestID { self?.onSelect(.app(id)) } }
        tiles = [downToday, upToday, week, month, busiestTile]
        table.columns = [.init(title: "App", width: 0), .init(title: "Download", width: 150, bar: true), .init(title: "Upload", width: 80),
                         .init(title: "CPU", width: 70), .init(title: "Memory", width: 80)]
        tableTitle.text = cardTitle("Apps", "by download")
    }

    override var barColumnValue: (AppGroup) -> Double { { $0.networkInPerSecond } }

    override func updateHero(_ s: SystemSnapshot) {
        guard let n = s.network else { return }
        hero.figure.set(n.receivedBytesPerSecond)
        hero.meta.text = Theme.caption("Download · upload \(Format.rate(n.sentBytesPerSecond))")
        hero.chart.secondaryColor = PageID.cpu.tint
        hero.legend.text = legendText(("Down", pageTint), ("Up", PageID.cpu.tint))
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
        if let app = busiest(table, by: { $0.networkPerSecond }), app.networkPerSecond > 0 {
            busiestID = app.id
            busiestTile.set(text: app.name)
            busiestTile.set(note: "↓ \(Format.rate(app.networkInPerSecond)) · ↑ \(Format.rate(app.networkOutPerSecond))")
        } else if !table.networkMeasured {
            busiestTile.set(text: "–")
            busiestTile.set(note: "Per-app traffic is off")
        }
    }

    override func sortValue(_ app: AppGroup, column: Int) -> Double {
        switch column {
        case 2: return app.networkOutPerSecond
        case 3: return app.cpu
        case 4: return Double(app.memory)
        default: return app.networkInPerSecond
        }
    }

    override func cells(_ app: AppGroup, table: ProcessTable) -> [String] {
        let measured = table.networkMeasured
        return [app.name, measured && app.networkInPerSecond > 0 ? Format.rate(app.networkInPerSecond) : "–",
                measured && app.networkOutPerSecond > 0 ? Format.rate(app.networkOutPerSecond) : "–",
                appCPU(app, table), Format.memory(app.memory)]
    }
}

// MARK: - GPU

final class GPUPage: MachinePage {
    private let memoryTile = Tile("GPU memory"), average = Tile("Average"), peak = Tile("Peak")
    private let temperature = Tile("Temperature"), power = Tile("GPU power")
    /// GPU time per app, read from the driver only while this page is on screen.
    private let clients = GPUClients()
    private var gpuShare: [String: Double] = [:]

    override func setUp() {
        hero.chart.ceiling = 1
        hero.chart.format = { String(format: "%.0f%%", $0 * 100) }
        hero.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        for tile in [average, peak] { tile.figure.format = { (String(format: "%.0f", $0 * 100), "%") }; tile.showsMeter = true }
        tiles = [memoryTile, average, peak, temperature, power]
        table.columns = [.init(title: "App", width: 0), .init(title: "GPU", width: 150, bar: true), .init(title: "CPU", width: 80),
                         .init(title: "Memory", width: 80), .init(title: "Processes", width: 70)]
        tableTitle.text = cardTitle("Apps", "by GPU time")
    }

    override func updateHero(_ s: SystemSnapshot) {
        guard let g = s.gpu else { return }
        hero.figure.set(g.utilization)
        hero.meta.text = Theme.caption(g.name + (g.coreCount.map { " · \($0) cores" } ?? ""))
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

// MARK: - Energy

final class EnergyPage: MachinePage {
    private let charging = Tile("Battery power"), capacity = Tile("Maximum capacity"), cycles = Tile("Cycle count")
    private let batteryTemp = Tile("Battery temperature"), mostPower = Tile("Using most power")
    private let batteryCard = CardView()
    private let batteryTitle = TextLine()
    private let batteryFigure = BigNumber()
    private let batteryNote = TextLine()
    private let batteryLine = TimeChart()
    private let awakeCard = CardView()
    private let awakeTitle = TextLine()
    private let awakeEmpty = TextLine(Theme.caption("Nothing is keeping this Mac awake"))
    private var awakeRows: [ListRow] = []
    private var awakeCheckedAt = Date.distantPast
    private var mostID: String?

    override func setUp() {
        metric = .power
        hero.chart.format = { String(format: "%.0f W", $0) }
        hero.figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
        capacity.showsMeter = true
        mostPower.onClick = { [weak self] in if let id = self?.mostID { self?.onSelect(.app(id)) } }
        tiles = [charging, capacity, cycles, batteryTemp, mostPower]
        batteryFigure.font = Theme.figure(30)
        batteryFigure.unitFont = Theme.sans(14)
        batteryFigure.format = { (String(format: "%.0f", $0), "%") }
        batteryLine.ceiling = 100
        batteryLine.format = { String(format: "%.0f%%", $0) }
        batteryLine.primaryColor = Theme.good
        for view in [batteryTitle, batteryFigure, batteryNote, batteryLine] as [NSView] { batteryCard.addSubview(view) }
        for view in [awakeTitle, awakeEmpty] as [NSView] { awakeCard.addSubview(view) }
        batteryTitle.text = cardTitle("Battery", "")
        awakeTitle.text = cardTitle("Keeping this Mac awake", "")
        extras = [(batteryCard, 230), (awakeCard, 230)]
        table.columns = [.init(title: "App", width: 0), .init(title: "Power", width: 150, bar: true), .init(title: "Wake-ups", width: 80),
                         .init(title: "CPU", width: 70), .init(title: "Memory", width: 80)]
        tableTitle.text = cardTitle("Apps", "by power")
    }

    override var barColumnValue: (AppGroup) -> Double { { $0.watts } }

    override func arrange(width: CGFloat) -> CGFloat {
        let bottom = super.arrange(width: width)
        let inner = batteryCard.bounds.width - 40
        batteryTitle.frame = NSRect(x: 20, y: 16, width: inner, height: 20)
        batteryFigure.frame = NSRect(x: 20, y: 42, width: 140, height: 38)
        batteryNote.frame = NSRect(x: 20, y: 84, width: inner, height: 14)
        batteryLine.frame = NSRect(x: 20, y: 108, width: inner, height: batteryCard.bounds.height - 124)
        let awakeInner = awakeCard.bounds.width - 40
        awakeTitle.frame = NSRect(x: 20, y: 16, width: awakeInner, height: 20)
        awakeEmpty.frame = NSRect(x: 20, y: 52, width: awakeInner, height: 14)
        for (index, row) in awakeRows.enumerated() { row.frame = NSRect(x: 20, y: 46 + CGFloat(index) * 34, width: awakeInner, height: 34) }
        return bottom
    }

    override func updateHero(_ s: SystemSnapshot) {
        if let p = s.power, let cpu = p.cpu {
            let total = cpu + (p.gpu ?? 0) + (p.ane ?? 0)
            hero.figure.set(total)
            hero.meta.text = Theme.caption("Chip power · CPU \(Format.watts(cpu)) · GPU \(Format.watts(p.gpu ?? 0)) · Neural Engine \(Format.watts(p.ane ?? 0))")
        } else {
            hero.meta.text = Theme.caption("Chip power is not readable on this Mac")
        }
        hero.needsLayout = true
        if let b = s.battery {
            batteryFigure.set(b.percent)
            var note = b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in, not charging" : "On battery")
            if let minutes = b.minutesRemaining, minutes > 0 { note += " · " + Format.duration(Double(minutes) * 60) + (b.isCharging ? " until full" : " left") }
            batteryNote.text = Theme.caption(note)
            batteryLine.step = delegate.settings.interval
            batteryLine.primary = delegate.monitor.history.recent(.battery)
        } else {
            batteryNote.text = Theme.caption("This Mac has no battery")
        }
        if Date().timeIntervalSince(awakeCheckedAt) > 10 { refreshAwake() }
    }

    private func refreshAwake() {
        awakeCheckedAt = Date()
        let blockers = SleepBlockers.list()
        while awakeRows.count < blockers.count {
            let row = ListRow()
            awakeCard.addSubview(row)
            awakeRows.append(row)
        }
        awakeEmpty.isHidden = !blockers.isEmpty
        for (index, row) in awakeRows.enumerated() {
            guard index < blockers.count else { row.isHidden = true; continue }
            let blocker = blockers[index]
            row.isHidden = false
            let app = NSRunningApplication(processIdentifier: blocker.pid)
            row.icon = app?.icon ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            row.name = app?.localizedName ?? blocker.process
            row.note = blocker.keepsDisplayOn ? "Display on" : "System awake"
            row.value = blocker.since.map { Format.duration(Date().timeIntervalSince($0)) } ?? ""
            row.showsBar = false
            row.showsRule = index < blockers.count - 1
            row.toolTip = blocker.reason
        }
        let wanted = max(230, 60 + CGFloat(blockers.count) * 34)
        if extras.count == 2, extras[1].1 != wanted {
            extras = [(batteryCard, wanted), (awakeCard, wanted)]
            relayout()
        }
        relayout()
    }

    override func updateTiles(_ s: SystemSnapshot) {
        guard let b = s.battery else {
            for tile in [charging, capacity, cycles, batteryTemp] { tile.set(text: "–"); tile.set(note: "No battery") }
            return
        }
        if let watts = b.watts {
            charging.set(text: String(format: "%.1f", abs(watts)), unit: "W")
            charging.set(note: b.isCharging ? "Going in" : (b.isPluggedIn ? "From the adapter" : "Drawn from the battery"))
        }
        if let health = b.health {
            capacity.set(text: String(format: "%.0f", health * 100), unit: "%")
            capacity.meter.fraction = health
            capacity.meter.color = health < 0.8 ? Theme.warn : Theme.good
            capacity.set(note: "Of when it was new")
        }
        if let count = b.cycleCount {
            cycles.set(text: "\(count)")
            cycles.set(note: "Full charges used")
        }
        if let temp = b.temperature {
            batteryTemp.set(text: Format.temperature(temp).0, unit: Format.temperature(temp).1)
            batteryTemp.set(note: b.adapterWatts.map { "\($0) W adapter" } ?? "")
        }
    }

    override func updateApps(_ table: ProcessTable) {
        if let app = busiest(table, by: { $0.watts }), app.watts > 0 {
            mostID = app.id
            mostPower.set(text: app.name)
            mostPower.set(note: Format.watts(app.watts) + " · \(app.processCount) processes")
        }
    }

    override func sortValue(_ app: AppGroup, column: Int) -> Double {
        switch column {
        case 2: return app.wakeupsPerSecond
        case 3: return app.cpu
        case 4: return Double(app.memory)
        default: return app.watts
        }
    }

    override func cells(_ app: AppGroup, table: ProcessTable) -> [String] {
        [app.name, app.watts > 0.005 ? Format.watts(app.watts) : "–",
         app.wakeupsPerSecond >= 0.5 ? String(format: "%.0f/s", app.wakeupsPerSecond) : "–",
         appCPU(app, table), Format.memory(app.memory)]
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
