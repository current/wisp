import AppKit
import WispCore

/// The Power page. On a Mac with a battery it is the Battery page: charge now and
/// over the last day or week, battery health, what used the battery, and what keeps
/// the Mac awake. A Mac without one gets chip power over time and the same per-app
/// and sleep cards, with no battery cards at all. `PowerPageLayout` decides which.
@MainActor
final class PowerPage: MachinePage {
    nonisolated static var title: String { MachinePower.hasBattery ? "Battery" : "Power" }

    private let layout = PowerPageLayout(hasBattery: MachinePower.hasBattery, hasSystemPower: MachinePower.hasBattery)
    private var hasBattery: Bool { layout.batteryFilter }

    private let systemPower = Tile("Mac draws now"), adapter = Tile("Adapter"), chip = Tile("Chip power")
    private let lowPower = Tile("Low Power Mode"), screenOn = Tile("Screen on"), drain = Tile("Drain"), mostPower = Tile("Using most power")
    private let bands = ChargeBands()
    private let health = HealthCard()
    private let awake = ListCard()
    private let energy = AppEnergyCard()
    private var mostID: String?
    private var awakeCheckedAt = Date.distantPast
    private var blockers: [SleepBlocker] = []

    /// Charge history read from the log on a background queue, once a minute while open.
    private var samples: [BatteryLogSample] = []
    private var samplesMinute = 0
    private var energyAt = Date.distantPast
    private var chartGeneration = 0
    private var energyGeneration = 0
    private static let work = DispatchQueue(label: "app.wisp.power-page", qos: .utility)

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        super.init(title: Self.title, metric: .power, delegate: delegate, onSelect: onSelect)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setUp() {
        metric = .power
        tiles = layout.tiles.map(tile)
        mostPower.onClick = { [weak self] in if let id = self?.mostID { self?.onSelect(.app(id)) } }
        lowPower.onClick = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
        }

        if hasBattery {
            hero.range.items = ["Day", "Week"]
            hero.figure.format = { (String(format: "%.0f", $0), "%") }
            hero.chart.ceiling = 100
            hero.chart.format = { String(format: "%.0f%%", $0) }
            hero.chart.names = ("Charge", "")
            hero.addSubview(bands, positioned: .below, relativeTo: hero.chart)
            hero.chart.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(chartMoved), name: NSView.frameDidChangeNotification, object: hero.chart)
            hero.legend.text = chargingLegend()
            hero.onRange = { [weak self] _ in self?.drawCharge() }
        } else {
            hero.chart.format = { String(format: "%.0f W", $0) }
            hero.figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
        }

        awake.title.text = cardTitle("Keeping this Mac awake", "")
        awake.empty.text = Theme.caption("Nothing is keeping this Mac awake")
        energy.title.text = cardTitle(hasBattery ? "Battery used by apps" : "Energy used by apps", "")
        energy.filter.isHidden = !hasBattery
        energy.onChange = { [weak self] in self?.refreshEnergy() }
        energy.table.onSelect = { [weak self] id in self?.onSelect(.app(id)) }
        health.title.text = cardTitle("Battery health", "")
        placeExtras()

        table.columns = [.init(title: "App", width: 0), .init(title: "Power", width: 150, bar: true), .init(title: "Wake-ups", width: 80),
                         .init(title: "CPU", width: 70), .init(title: "Memory", width: 80)]
        tableTitle.text = cardTitle("Apps now", "by power")
    }

    private func tile(_ kind: PowerTile) -> Tile {
        switch kind {
        case .systemPower: return systemPower
        case .adapter: return adapter
        case .chip: return chip
        case .lowPower: return lowPower
        case .screenOn: return screenOn
        case .drain: return drain
        case .mostPower: return mostPower
        }
    }

    private func placeExtras() {
        let side = max(awake.wantedHeight, layout.cards.contains(.health) ? health.wantedHeight : 0)
        var cards: [(CardView, CGFloat)] = []
        if layout.cards.contains(.health) { cards.append((health, side)) }
        cards.append((awake, side))
        cards.append((energy, energy.wantedHeight))
        if cards.map(\.1) != extras.map(\.1) || extras.isEmpty { extras = cards }
    }

    override var barColumnValue: (AppGroup) -> Double { { $0.watts } }

    override func arrange(width: CGFloat) -> CGFloat {
        let bottom = super.arrange(width: width)
        chartMoved()
        return bottom
    }

    @objc private func chartMoved() {
        bands.frame = hero.chart.frame
    }

    private func chargingLegend() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "● ", attributes: [.font: Theme.mono(10), .foregroundColor: Theme.good])
        text.append(Theme.caption("Charging"))
        return text
    }

    // MARK: Updates

    override func refreshChart(force: Bool) {
        guard hasBattery else { return super.refreshChart(force: force) }
        let minute = HistoryStore.minute(Date())
        guard force || minute != samplesMinute else { return }
        samplesMinute = minute
        chartGeneration += 1
        let token = chartGeneration
        let log = delegate.monitor.history.batteryLog
        let since = minute - 7 * 1440 - 60
        Self.work.async { [weak self] in
            let samples = log.samples(since: since)
            DispatchQueue.main.async {
                guard let self, self.chartGeneration == token else { return }
                self.samples = samples
                self.drawCharge()
                self.updateBatteryTiles()
            }
        }
    }

    private func drawCharge() {
        let week = hero.range.selected == 1
        let now = HistoryStore.minute(Date())
        let series = BatteryStats.series(samples, endingAt: now, minutes: week ? 7 * 1440 : 1440, bucket: week ? 30 : 5)
        // The newest reading, so the line reaches now before the next logged minute.
        var levels = series.levels
        if let b = delegate.system.battery, !levels.isEmpty, levels[levels.count - 1].isNaN { levels[levels.count - 1] = Float(b.percent) }
        hero.chart.step = series.step
        hero.chart.primary = levels
        bands.charging = series.charging
    }

    private var dayStart: Int { HistoryStore.minute(Calendar.current.startOfDay(for: Date())) }

    private func updateBatteryTiles() {
        let today = dayStart
        let minutes = BatteryStats.screenOnMinutes(samples, since: today)
        if minutes > 0 {
            screenOn.set(text: Format.duration(Double(minutes) * 60))
            screenOn.set(note: "On battery today")
        } else {
            screenOn.set(text: "–")
            screenOn.set(note: "No time on battery today")
        }
        if let rate = BatteryStats.drainPerHour(samples, since: today) {
            drain.set(text: String(format: rate >= 10 ? "%.0f" : "%.1f", rate), unit: "% an hour")
            drain.set(note: "Average on battery today")
        } else {
            drain.set(text: "–")
            drain.set(note: minutes > 0 ? "Needs ten minutes on battery" : "No time on battery today")
        }
    }

    override func updateHero(_ s: SystemSnapshot) {
        if !hasBattery {
            if let p = s.power, let cpu = p.cpu {
                hero.figure.set(cpu + (p.gpu ?? 0) + (p.ane ?? 0))
                hero.meta.text = Theme.caption("Chip power · CPU \(Format.watts(cpu)) · GPU \(Format.watts(p.gpu ?? 0)) · Neural Engine \(Format.watts(p.ane ?? 0))")
            } else {
                hero.meta.text = Theme.caption("Chip power is not readable on this Mac")
            }
        } else if let b = s.battery {
            hero.figure.set(b.percent)
            hero.meta.text = Theme.caption(Self.state(b))
            let before = health.wantedHeight
            health.show(b)
            if health.wantedHeight != before { placeExtras(); relayout() }
        }
        hero.needsLayout = true
        if Date().timeIntervalSince(awakeCheckedAt) > 10 { refreshAwake() }
        if Date().timeIntervalSince(energyAt) > 300 { refreshEnergy() }
    }

    /// "On battery · 4h 10m left", "Charging · 1h 5m until full", "Plugged in · holding at 80%".
    static func state(_ b: BatteryReading) -> String {
        var parts: [String]
        if b.isCharging {
            parts = ["Charging"]
            if let minutes = b.minutesRemaining { parts.append(Format.duration(Double(minutes) * 60) + " until full") }
        } else if b.isPluggedIn {
            parts = ["Plugged in", b.chargeHeld == true ? String(format: "holding at %.0f%%", b.percent) : "fully charged"]
        } else {
            parts = ["On battery"]
            if let minutes = b.minutesRemaining { parts.append(Format.duration(Double(minutes) * 60) + " left") }
        }
        if b.lowPowerMode == true { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }

    override func updateTiles(_ s: SystemSnapshot) {
        if let p = s.power, let cpu = p.cpu {
            chip.set(text: String(format: "%.1f", cpu + (p.gpu ?? 0) + (p.ane ?? 0)), unit: "W")
            chip.set(note: "CPU \(Format.watts(cpu)) · GPU \(Format.watts(p.gpu ?? 0))")
        } else {
            chip.set(text: "–")
            chip.set(note: "Not readable on this Mac")
        }
        let lowPowerOn = s.battery?.lowPowerMode ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        lowPower.set(text: lowPowerOn ? "On" : "Off")
        lowPower.set(note: lowPowerOn ? "Slower, lasts longer" : "Change in System Settings")
        guard let b = s.battery else { return }
        if let watts = b.systemWatts {
            systemPower.set(text: String(format: watts >= 10 ? "%.0f" : "%.1f", watts), unit: "W")
            systemPower.set(note: b.isPluggedIn ? "From the adapter" : "From the battery")
        } else if let watts = b.watts {
            systemPower.set(text: String(format: "%.1f", abs(watts)), unit: "W")
            systemPower.set(note: b.isCharging ? "Going into the battery" : "Drawn from the battery")
        }
        if b.isPluggedIn {
            if let watts = b.adapterWatts { adapter.set(text: "\(watts)", unit: "W") } else { adapter.set(text: "On") }
            if b.isCharging, let watts = b.watts, watts > 0.5 {
                adapter.set(note: String(format: "Charging at %.0f W", watts))
            } else {
                adapter.set(note: b.chargeHeld == true ? "Not charging, charge held" : "Battery full")
            }
        } else {
            adapter.set(text: "–")
            adapter.set(note: "Not connected")
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

    // MARK: Keeping the Mac awake

    private func refreshAwake() {
        awakeCheckedAt = Date()
        blockers = SleepBlockers.list()
        let table = delegate.table
        awake.set(count: blockers.count) { [weak self] row, index in
            guard let self else { return }
            let blocker = self.blockers[index]
            let group = table.apps.first { $0.pids.contains(blocker.pid) }
            let app = NSRunningApplication(processIdentifier: blocker.pid)
            row.icon = group.map { Icons.icon(for: $0) } ?? app?.icon ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            row.name = group?.name ?? app?.localizedName ?? blocker.process
            row.note = blocker.keepsDisplayOn ? "Keeps the display on" : "Keeps the Mac awake"
            row.value = blocker.since.map { Format.duration(Date().timeIntervalSince($0)) } ?? ""
            row.showsBar = false
            row.toolTip = blocker.reason.isEmpty ? nil : blocker.reason
            let selection: Selection = group.map { .app($0.id) } ?? .process(blocker.pid)
            row.onClick = { [weak self] in self?.onSelect(selection) }
        }
        let before = extras.map(\.1)
        placeExtras()
        if extras.map(\.1) != before { relayout() }
    }

    // MARK: Energy per app

    private func refreshEnergy() {
        energyAt = Date()
        let week = energy.period.selected == 1
        let batteryOnly = hasBattery && energy.filter.selected == 0
        let calendar = Calendar.current
        let start = week ? calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))! : calendar.startOfDay(for: Date())
        let history = delegate.monitor.history
        energyGeneration += 1
        let token = energyGeneration
        Self.work.async { [weak self] in
            var minuteWeight: ((Int) -> Double)?
            var hourWeight: ((Int, Int) -> Double)?
            if batteryOnly {
                let minutes = BatteryStats.onBatteryMinutes(history.batteryLog.samples(since: HistoryStore.minute(start)), since: HistoryStore.minute(start))
                var perHour: [Int: Int] = [:]
                for minute in minutes { perHour[minute / 60, default: 0] += 1 }
                minuteWeight = { minutes.contains($0) ? 1 : 0 }
                hourWeight = { hour, recorded in
                    let on = perHour[hour] ?? 0
                    return on == 0 ? 0 : min(1, Double(on) / Double(max(recorded, on)))
                }
            }
            let apps = history.appEnergy(since: start, minuteWeight: minuteWeight, hourWeight: hourWeight)
            DispatchQueue.main.async {
                guard let self, self.energyGeneration == token else { return }
                self.showEnergy(apps, week: week, batteryOnly: batteryOnly)
            }
        }
    }

    private func showEnergy(_ apps: [HistoryStore.AppEnergy], week: Bool, batteryOnly: Bool) {
        let total = apps.reduce(0) { $0 + $1.wh }
        let top = apps.prefix(AppEnergyCard.maxRows)
        let peak = max(top.first?.wh ?? 0, 0.000_001)
        energy.table.rows = top.map { app in
            ColumnTable.Row(id: app.id, icon: Icons.icon(id: app.id, kind: app.kind, bundlePath: app.bundlePath),
                            cells: [app.name, Self.wattHours(app.wh), total > 0 ? Format.percent(app.wh / total) : "–"],
                            fraction: app.wh / peak)
        }
        let when = week ? "last 7 days" : "today"
        energy.title.text = cardTitle(batteryOnly ? "Battery used by apps" : "Energy used by apps",
                                      total > 0 ? "\(Self.wattHours(total)) \(when)" : "")
        energy.empty.text = Theme.caption(batteryOnly ? "No time on battery \(when)" : "Nothing recorded \(when)")
        energy.empty.isHidden = !top.isEmpty
        energy.needsLayout = true
        let before = extras.map(\.1)
        placeExtras()
        if extras.map(\.1) != before { relayout() }
    }

    static func wattHours(_ wh: Double) -> String {
        if wh >= 10 { return String(format: "%.0f Wh", wh) }
        if wh >= 0.1 { return String(format: "%.1f Wh", wh) }
        return String(format: "%.0f mWh", wh * 1000)
    }

}

/// Shading behind the charge chart where the Mac was charging. Sits under the
/// chart's own bitmap and matches its plot area.
final class ChargeBands: BitmapView {
    var charging: [Bool] = [] { didSet { if charging != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard charging.count > 1, charging.contains(true) else { return }
        // TimeChart's plot: the label column on the right, the time axis below.
        let plot = NSRect(x: 0, y: 6, width: bounds.width - 40 - 6, height: bounds.height - 30)
        let dx = plot.width / CGFloat(charging.count - 1)
        Theme.good.withAlphaComponent(0.16).setFill()
        var index = 0
        while index < charging.count {
            guard charging[index] else { index += 1; continue }
            let first = index
            while index < charging.count, charging[index] { index += 1 }
            let from = max(plot.minX, plot.minX + (CGFloat(first) - 0.5) * dx)
            let to = min(plot.maxX, plot.minX + (CGFloat(index - 1) + 0.5) * dx)
            NSRect(x: from, y: plot.minY, width: max(1, to - from), height: plot.height).fill()
        }
    }
}

/// Maximum capacity, cycles, condition and temperature, with a line on what they mean.
final class HealthCard: CardView {
    var wantedHeight: CGFloat { 124 + CGFloat(max(1, rows.filter { !$0.isHidden }.count)) * 30 + 50 }
    let title = TextLine()
    private let figure = BigNumber()
    private let caption = TextLine()
    private let meter = TickMeter()
    private let rows = (0..<5).map { _ in ListRow() }
    private let explain = TextLine()

    override init() {
        super.init()
        figure.font = Theme.figure(30)
        figure.unitFont = Theme.sans(14)
        figure.format = { (String(format: "%.0f", $0), "%") }
        caption.text = Theme.caption("Maximum capacity")
        for row in rows { row.showsBar = false }
        // The longest line that fits; narrow cards keep the part that matters.
        explain.variants = [Theme.caption("Charge it holds when full, against when new. Below 80% the battery counts as worn"),
                            Theme.caption("Charge it holds now, against when new. Below 80% counts as worn"),
                            Theme.caption("Below 80% the battery counts as worn")]
        for view in [title, figure, caption, meter, explain] + rows as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ b: BatteryReading) {
        if let health = b.health {
            figure.set(health * 100)
            meter.fraction = health
            meter.color = health < 0.8 ? Theme.warn : Theme.good
        } else {
            figure.show("–")
        }
        var lines: [(String, String)] = []
        if let full = b.fullChargeCapacity, let design = b.designCapacity {
            lines.append(("Full charge", "\(Self.grouped(full)) of \(Self.grouped(design)) mAh"))
        }
        if let cycles = b.cycleCount {
            lines.append(("Cycles", b.designCycleCount.map { "\(Self.grouped(cycles)) of \(Self.grouped($0))" } ?? Self.grouped(cycles)))
        }
        if let health = b.health { lines.append(("Condition", health < 0.8 ? "Service recommended" : "Normal")) }
        if let temp = b.temperature {
            let (value, unit) = Format.temperature(temp)
            lines.append(("Temperature", value + " " + unit))
        }
        if let made = b.manufactured {
            lines.append(("Made", made.formatted(.dateTime.month(.abbreviated).year())))
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= lines.count
            guard index < lines.count else { continue }
            row.name = lines[index].0
            row.value = lines[index].1
            row.showsRule = index < lines.count - 1
        }
    }

    static func grouped(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        title.frame = NSRect(x: 20, y: 16, width: width, height: 20)
        figure.frame = NSRect(x: 20, y: 46, width: 110, height: 38)
        caption.frame = NSRect(x: 20, y: 86, width: width, height: 14)
        meter.frame = NSRect(x: 20, y: 108, width: width, height: 8)
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 20, y: 124 + CGFloat(index) * 30, width: width, height: 30) }
        let shown = CGFloat(rows.filter { !$0.isHidden }.count)
        explain.frame = NSRect(x: 20, y: 124 + shown * 30 + 14, width: width, height: 14)
    }
}

/// Energy per app over today or the last week, optionally only while on battery.
final class AppEnergyCard: CardView {
    static let maxRows = 10
    let title = TextLine()
    let period = Segmented(["Today", "7 days"])
    let filter = Segmented(["On battery", "Any power"])
    let table = ColumnTable()
    let empty = TextLine()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        table.columns = [.init(title: "App", width: 0), .init(title: "Energy", width: 170, bar: true), .init(title: "Share", width: 60)]
        table.onSort = { [weak self] _ in self?.table.sortColumn = 1 }
        period.onChange = { [weak self] _ in self?.onChange?() }
        filter.onChange = { [weak self] _ in self?.onChange?() }
        empty.isHidden = true
        for view in [title, period, filter, table, empty] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    var wantedHeight: CGFloat { 64 + max(table.naturalHeight, table.headerHeight + 40) + 12 }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        var right = 20 + width
        for control in [period, filter] where !control.isHidden {
            let w = control.naturalWidth
            control.frame = NSRect(x: right - w, y: 14, width: w, height: 26)
            right -= w + 8
        }
        title.frame = NSRect(x: 20, y: 16, width: max(0, right - 28), height: 20)
        table.frame = NSRect(x: 12, y: 52, width: bounds.width - 24, height: max(table.naturalHeight, table.headerHeight))
        empty.frame = NSRect(x: 20, y: 52 + table.headerHeight + 14, width: width, height: 14)
    }
}
