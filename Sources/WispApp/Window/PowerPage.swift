import AppKit
import WispCore

/// The Power page. On a Mac with a battery it is the Battery page: charge over the
/// last day or week beside battery health, a row of figures, what used the battery
/// beside what keeps the Mac awake, then the apps drawing power now. A Mac without
/// one gets chip power over time in place of the charge and health cards.
/// `PowerPageLayout` decides which.
@MainActor
final class PowerPage: MachinePage {
    nonisolated static var title: String { MachinePower.hasBattery ? "Battery" : "Power" }

    private let layout = PowerPageLayout(hasBattery: MachinePower.hasBattery, hasSystemPower: MachinePower.hasBattery)
    private var hasBattery: Bool { layout.batteryFilter }

    private let systemPower = A2SmallTile("Mac draws now"), adapter = A2SmallTile("Adapter"), chip = A2SmallTile("Chip power")
    private let lowPower = A2SmallTile("Low Power Mode"), screenOn = A2SmallTile("Screen on"), drain = A2SmallTile("Drain")
    private let mostPower = A2SmallTile("Using most power")
    private var shownTiles: [A2SmallTile] = []
    private let charge = ChargeCard()
    private let health = HealthCard()
    private let awake = AwakeCard()
    private let energy = AppEnergyCard()
    private let range = Segmented(["Day", "Week"])
    private var mostID: String?
    private var awakeCheckedAt = Date.distantPast

    /// Charge history read from the log on a background queue, once a minute while open.
    private var samples: [BatteryLogSample] = []
    private var samplesMinute = 0
    private var energyAt = Date.distantPast
    private var chartGeneration = 0
    private var energyGeneration = 0
    private static let work = DispatchQueue(label: "app.wisp.power-page", qos: .utility)

    /// The mockup's row heights at 1240 by 780: charge and health, the figures, apps and sleep.
    private static let rowHeights: [CGFloat] = [290, A2SmallTile.height, 286]

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        super.init(title: Self.title, metric: .power, delegate: delegate, onSelect: onSelect)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var myCards: [NSView] { [charge, health, awake, energy] + shownTiles }

    override func setUp() {
        metric = .power
        _ = heading(Self.title)
        shownTiles = layout.tiles.map(tile)
        mostPower.onClick = { [weak self] in if let id = self?.mostID { self?.onSelect(.app(id)) } }
        lowPower.onClick = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
        }
        if hasBattery {
            hero.isHidden = true
            range.onChange = { [weak self] _ in self?.drawCharge() }
        } else {
            let machine = MainWindowController.machineSubtitle
            headingLines?.1.variants = [machine, machine.components(separatedBy: " · ").dropFirst().joined(separator: " · ")].map(Toolbar.subtitle)
            charge.isHidden = true
            health.isHidden = true
            hero.chart.format = { String(format: "%.0f W", $0) }
            hero.figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
        }
        for view in myCards { canvas.addSubview(view) }

        energy.batteryOnly = hasBattery
        energy.onChange = { [weak self] in self?.refreshEnergy() }
        energy.list.onOpen = { [weak self] row in self?.onSelect(.app(row.id)) }
        awake.list.onOpen = { [weak self] row in self?.openBlocker(row.id) }

        table.columns = [.init(title: "App", width: 0), .init(title: "Power", width: 150, bar: true), .init(title: "Wake-ups", width: 80),
                         .init(title: "CPU", width: 70), .init(title: "Memory", width: 80)]
        tableTitle.text = cardTitle("Apps now", "by power")
    }

    private func tile(_ kind: PowerTile) -> A2SmallTile {
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

    override var toolbarItems: [NSView] { hasBattery ? [range] : super.toolbarItems }

    override var barColumnValue: (AppGroup) -> Double { { $0.watts } }

    // MARK: Layout

    /// The rows grow with the window's height, so a taller window lays them out again.
    private var arrangedHeight: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        if scroll.contentSize.height != arrangedHeight { relayout() }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        arrangedHeight = scroll.contentSize.height
        // The base places the hero and the apps table; the rows here go between them.
        let bottom = super.arrange(width: width)
        let inner = width - margin * 2
        var y = hasBattery ? margin : hero.frame.maxY + gap
        let tableTop = tableCard.frame.minY
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
        let wide = inner >= 860
        var heights = Self.rowHeights
        if wide, hasBattery {
            // Taller windows grow the chart and list rows a little; past that the page ends early.
            let room = scroll.contentSize.height - Self.topInset - margin * 2 - gap * 2
            let scale = min(1.3, max(1, room / heights.reduce(0, +)))
            heights[0] = (heights[0] * scale).rounded()
            heights[2] = (heights[2] * scale).rounded()
        }
        if hasBattery {
            if wide {
                place(charge, 0, 3, of: 4, height: heights[0])
                place(health, 3, 1, of: 4, height: heights[0])
                y += heights[0] + gap
            } else {
                place(charge, 0, 1, of: 1, height: heights[0])
                y += heights[0] + gap
            }
        }
        y = placeTiles(top: y, inner: inner) + gap
        if wide {
            place(energy, 0, 3, of: 4, height: heights[2])
            place(awake, 3, 1, of: 4, height: heights[2])
            y += heights[2] + gap
        } else {
            if hasBattery {
                place(health, 0, 1, of: 2, height: heights[0])
                place(awake, 1, 1, of: 2, height: heights[0])
                y += heights[0] + gap
            } else {
                place(awake, 0, 1, of: 1, height: heights[2])
                y += heights[2] + gap
            }
            place(energy, 0, 1, of: 1, height: heights[2])
            y += heights[2] + gap
        }
        let shift = y - tableTop
        let mine = Set(myCards.map(ObjectIdentifier.init) + [ObjectIdentifier(hero)])
        for view in canvas.subviews where !mine.contains(ObjectIdentifier(view)) { view.frame.origin.y += shift }
        return bottom + shift
    }

    /// One row of figures sized to what each says, as in the mockup; two rows when they do not fit.
    private func placeTiles(top: CGFloat, inner: CGFloat) -> CGFloat {
        guard !shownTiles.isEmpty else { return top - gap }
        let natural = shownTiles.map(\.naturalWidth)
        let room = inner - gap * CGFloat(shownTiles.count - 1)
        // Sub lines may lose a few points to an ellipsis before the row splits in two.
        let oneRow = natural.reduce(0, +) * 0.9 <= room
        let half = (shownTiles.count + 1) / 2
        let rows = oneRow ? [shownTiles[...]] : [shownTiles.prefix(half), shownTiles.dropFirst(half)]
        var y = top
        for row in rows {
            let free = inner - gap * CGFloat(row.count - 1)
            let weights = Self.share(free, among: row.map(\.naturalWidth))
            let total = weights.reduce(0, +)
            var x = margin
            for (index, tile) in row.enumerated() {
                let right = index == row.count - 1 ? margin + inner : (x + free * weights[index] / total).rounded()
                tile.frame = NSRect(x: x, y: y, width: right - x, height: A2SmallTile.height)
                x = right + gap
            }
            y += A2SmallTile.height + gap
        }
        return y - gap
    }

    /// Widths that add up to `room`. Spare room goes out in proportion; a shortfall comes
    /// off the widest tiles only, so a short sub line like "Battery full" never loses text
    /// to make room for a long one.
    static func share(_ room: CGFloat, among natural: [CGFloat]) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > room else { return natural }
        var cap = room / CGFloat(natural.count)
        for width in natural.sorted() {
            let below = natural.filter { $0 <= width }
            let above = natural.count - below.count
            guard above > 0 else { break }
            let level = (room - below.reduce(0, +)) / CGFloat(above)
            if level < width { break }
            cap = level
        }
        return natural.map { min($0, cap) }
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
        let week = range.selected == 1
        let now = HistoryStore.minute(Date())
        let series = BatteryStats.series(samples, endingAt: now, minutes: week ? 7 * 1440 : 1440, bucket: week ? 30 : 5)
        // The newest reading, so the line reaches now before the next logged minute.
        var levels = series.levels
        if let b = delegate.system.battery, !levels.isEmpty, levels[levels.count - 1].isNaN { levels[levels.count - 1] = Float(b.percent) }
        charge.chart.step = series.step
        charge.chart.levels = levels
        charge.chart.charging = series.charging
        charge.key.period = week ? "Last 7 days" : "Last 24 hours"
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
            drain.set(note: "Average on battery")
        } else {
            drain.set(text: "–")
            drain.set(note: minutes > 0 ? "Needs ten minutes on battery" : "No time on battery today")
        }
        relayout()
    }

    override func updateHero(_ s: SystemSnapshot) {
        if !hasBattery {
            if let p = s.power, let cpu = p.cpu {
                hero.figure.set(cpu + (p.gpu ?? 0) + (p.ane ?? 0))
                hero.meta.text = Theme.caption("Chip power · CPU \(Format.watts(cpu)) · GPU \(Format.watts(p.gpu ?? 0)) · Neural Engine \(Format.watts(p.ane ?? 0))")
            } else {
                hero.meta.text = Theme.caption("Chip power is not readable on this Mac")
            }
            hero.needsLayout = true
        } else if let b = s.battery {
            charge.figure.set(b.percent)
            charge.sub.text = A2.plain(Self.state(b))
            health.show(b)
            showSubtitle(b)
        }
        if Date().timeIntervalSince(awakeCheckedAt) > 10 { refreshAwake() }
        if Date().timeIntervalSince(energyAt) > 300 { refreshEnergy() }
    }

    /// "6,249 mAh battery · 96 W adapter connected", or "· on battery".
    private func showSubtitle(_ b: BatteryReading) {
        guard let (_, subtitle) = headingLines else { return }
        let power = b.isPluggedIn ? (b.adapterWatts.map { "\($0) W adapter connected" } ?? "Adapter connected") : "On battery"
        let parts = (b.designCapacity.map { ["\(HealthCard.grouped($0)) mAh battery"] } ?? []) + [power]
        subtitle.variants = [parts.joined(separator: " · "), power].map(Toolbar.subtitle)
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
        let before = shownTiles.map(\.naturalWidth)
        if let p = s.power, let cpu = p.cpu {
            chip.set(text: String(format: "%.1f", cpu + (p.gpu ?? 0) + (p.ane ?? 0)), unit: "W")
            chip.set(note: "CPU \(Format.watts(cpu)) · GPU \(Format.watts(p.gpu ?? 0))")
        } else {
            chip.set(text: "–")
            chip.set(note: "Not readable on this Mac")
        }
        let lowPowerOn = s.battery?.lowPowerMode ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        lowPower.set(text: lowPowerOn ? "On" : "Off")
        lowPower.set(note: lowPowerOn ? "Slower, lasts longer" : "Set in System Settings")
        if let b = s.battery {
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
        // The row is shared by what each figure needs; a longer line moves the others.
        if shownTiles.map(\.naturalWidth) != before { relayout() }
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

    private var blockerSelections: [String: Selection] = [:]

    private func refreshAwake() {
        awakeCheckedAt = Date()
        let blockers = SleepBlockers.list()
        let table = delegate.table
        blockerSelections = [:]
        awake.list.rows = blockers.map { blocker in
            let group = table.apps.first { $0.pids.contains(blocker.pid) }
            let app = NSRunningApplication(processIdentifier: blocker.pid)
            let id = "\(blocker.pid)·\(blocker.reason)"
            blockerSelections[id] = group.map { .app($0.id) } ?? .process(blocker.pid)
            return A2List.Row(id: id, name: group?.name ?? app?.localizedName ?? blocker.process,
                              note: blocker.keepsDisplayOn ? "Keeps the display on" : "Keeps the Mac awake",
                              second: blocker.since.map { Format.duration(Date().timeIntervalSince($0)) } ?? "",
                              icon: group.map { Icons.icon(for: $0) } ?? app?.icon, symbol: "gearshape", opens: true)
        }
        awake.count = blockers.count
    }

    private func openBlocker(_ id: String) {
        if let selection = blockerSelections[id] { onSelect(selection) }
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
        energy.list.rows = top.map { app in
            A2List.Row(id: app.id, name: app.name, value: Self.wattHours(app.wh), second: total > 0 ? Format.percent(app.wh / total) : "–",
                       fraction: app.wh / peak, icon: Icons.icon(id: app.id, kind: app.kind, bundlePath: app.bundlePath), opens: true)
        }
        let when = week ? "last 7 days" : "today"
        energy.set(title: batteryOnly ? "Battery used by apps" : "Energy used by apps", detail: total > 0 ? "\(Self.wattHours(total)) \(when)" : "")
        energy.empty.text = A2.plain(batteryOnly ? "No time on battery \(when)" : "Nothing recorded \(when)")
        energy.empty.isHidden = !top.isEmpty
        energy.needsLayout = true
    }

    static func wattHours(_ wh: Double) -> String {
        if wh >= 10 { return String(format: "%.0f Wh", wh) }
        if wh >= 0.1 { return String(format: "%.1f Wh", wh) }
        return String(format: "%.0f mWh", wh * 1000)
    }
}

/// The charge card: the label with the chart's key, the level now and what the
/// power source is doing, and the chart on the card's floor.
final class ChargeCard: CardView {
    let label = A2CardLabel("Charge", symbol: PageID.energy.symbol, tint: A2.good)
    let key = ChargeKey()
    let figure = A2.figure()
    let sub = TextLine()
    let chart = A2ChargeChart()

    override init() {
        super.init()
        label.showsChevron = false
        figure.format = { (String(format: "%.0f", $0), "%") }
        for view in [chart, label, key, figure, sub] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        label.frame = NSRect(x: A2.padSide, y: A2.padTop, width: 120, height: 15)
        key.frame = NSRect(x: A2.padSide + 130, y: A2.padTop, width: inner - 130, height: 15)
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        sub.frame = NSRect(x: A2.padSide, y: A2StatCard.subTop, width: inner, height: 14)
        // The mockup's chart is the bottom 178 pt of a 290 pt card.
        let top = min(112, bounds.height - 120)
        chart.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    }
}

/// "Charging" with the band's swatch, then the period, on the right of the charge card's label row.
final class ChargeKey: DrawnView {
    var period = "Last 24 hours" { didSet { if period != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let font = A2.legendFont
        let y = (bounds.height - (font.ascender - font.descender)) / 2
        let faint: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.tertiary]
        let quiet: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.secondary]
        var x = bounds.width - (period as NSString).size(withAttributes: faint).width
        (period as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: faint)
        x -= 12 + ("Charging" as NSString).size(withAttributes: quiet).width
        ("Charging" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: quiet)
        let swatch = NSRect(x: x - 13, y: bounds.midY - 4, width: 8, height: 8)
        A2ChargeChart.line.withAlphaComponent(0.14).setFill()
        let shape = NSBezierPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        shape.fill()
        A2ChargeChart.line.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { "Charging shaded, " + period }
}

/// Maximum capacity as a figure and a meter, then full charge, cycles, condition,
/// temperature and age as rows that share the card's height, and what "worn" means.
final class HealthCard: CardView {
    private let title = TextLine()
    private let figure = A2.figure()
    private let caption = TextLine()
    private let meter = HealthTicks()
    private let rows = HealthRows()
    private let explain = TextLine()

    override init() {
        super.init()
        title.text = NSAttributedString(string: "Battery health", attributes: [.font: A2.titleFont, .foregroundColor: A2.primary])
        figure.font = Theme.figure(30, .semibold)
        figure.kern = -1.2
        figure.format = { (String(format: "%.0f", $0), "%") }
        caption.text = A2.plain("Maximum capacity")
        explain.variants = [NSAttributedString(string: "Below 80% the battery counts as worn",
                                               attributes: [.font: Theme.sans(10.5), .foregroundColor: A2.tertiary]),
                            NSAttributedString(string: "Below 80% counts as worn", attributes: [.font: Theme.sans(10.5), .foregroundColor: A2.tertiary])]
        for view in [title, figure, caption, meter, rows, explain] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ b: BatteryReading) {
        if let health = b.health {
            figure.set(health * 100)
            meter.fraction = health
        } else {
            figure.show("–")
        }
        var lines: [HealthRows.Line] = []
        if let full = b.fullChargeCapacity, let design = b.designCapacity {
            lines.append(.init(name: "Full charge", value: "\(Self.grouped(full)) of \(Self.grouped(design)) mAh"))
        }
        if let cycles = b.cycleCount {
            lines.append(.init(name: "Cycles", value: b.designCycleCount.map { "\(Self.grouped(cycles)) of \(Self.grouped($0))" } ?? Self.grouped(cycles)))
        }
        if let health = b.health {
            lines.append(health < 0.8 ? .init(name: "Condition", value: "Service recommended", color: A2.warn)
                                      : .init(name: "Condition", value: "Normal", color: A2.good))
        }
        if let temp = b.temperature {
            let (value, unit) = Format.temperature(temp)
            lines.append(.init(name: "Temperature", value: value + " " + unit))
        }
        if let made = b.manufactured {
            lines.append(.init(name: "Made", value: made.formatted(.dateTime.month(.abbreviated).year())))
        }
        rows.lines = lines
    }

    static func grouped(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        title.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        let figureFont = Theme.figure(30, .semibold)
        // The mockup's 30 pt figure sits on a baseline 68 pt down.
        figure.frame = NSRect(x: A2.padSide, y: 68 - (42 + figureFont.ascender + figureFont.descender) / 2, width: 70, height: 42)
        let digits = (figure.value ?? 0) >= 100 ? 3 : 2
        let figureWidth = ceil(("8" as NSString).size(withAttributes: [.font: figureFont]).width) * CGFloat(digits) + 22
        caption.frame = NSRect(x: A2.padSide + figureWidth, y: 54, width: inner - figureWidth, height: 16)
        meter.frame = NSRect(x: A2.padSide, y: 84, width: inner, height: 8)
        let explainHeight: CGFloat = 14
        explain.frame = NSRect(x: A2.padSide, y: bounds.height - A2.padTop - explainHeight, width: inner, height: explainHeight)
        rows.frame = NSRect(x: A2.padSide, y: 100, width: inner, height: explain.frame.minY - 4 - 100)
    }
}

/// 25 ticks with 2 pt gaps, filled to the battery's maximum capacity.
final class HealthTicks: DrawnView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    private static let count = 25

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(Self.count - 1)) / CGFloat(Self.count)
        let filled = Int((fraction * Double(Self.count)).rounded())
        let fill = fraction < 0.8 ? A2.power : A2ChargeChart.line
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).addClip()
        for index in 0..<Self.count {
            (index < filled ? fill : A2.meterTrack).setFill()
            NSRect(x: (CGFloat(index) * (width + gap)).rounded(), y: 0, width: width, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Name and value rows that share the view's height, with hairlines between them.
final class HealthRows: DrawnView {
    struct Line: Equatable {
        var name: String
        var value: String
        var color: NSColor? = nil
    }

    var lines: [Line] = [] { didSet { if lines != oldValue { needsDisplay = true } } }
    private static let nameFont = Theme.sans(12)
    private static let valueFont = Theme.digits(12, .semibold)

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { return }
        let height = bounds.height / CGFloat(lines.count)
        for (index, line) in lines.enumerated() {
            let top = (CGFloat(index) * height).rounded()
            if index > 0 {
                A2.hairline.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
            }
            let center = top + height / 2
            let name: [NSAttributedString.Key: Any] = [.font: Self.nameFont, .foregroundColor: A2.secondary]
            (line.name as NSString).draw(at: NSPoint(x: 0, y: center - (Self.nameFont.ascender - Self.nameFont.descender) / 2), withAttributes: name)
            let value: [NSAttributedString.Key: Any] = [.font: Self.valueFont, .foregroundColor: line.color ?? A2.primary]
            let width = (line.value as NSString).size(withAttributes: value).width
            (line.value as NSString).draw(at: NSPoint(x: bounds.width - width, y: center - (Self.valueFont.ascender - Self.valueFont.descender) / 2),
                                          withAttributes: value)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityValue() -> Any? { lines.map { "\($0.name) \($0.value)" }.joined(separator: ", ") }
}

/// What keeps the Mac awake: a title with the count, and the apps holding it awake.
final class AwakeCard: CardView {
    private let title = A2TitleRow()
    let list = A2List()
    private let empty = TextLine()
    var count = 0 { didSet { title.items = count > 0 ? [.init(text: "\(count)")] : []; empty.isHidden = count > 0; needsLayout = true } }

    override init() {
        super.init()
        title.title = "Keeping this Mac awake"
        list.valueWidth = 0
        list.secondWidth = nil
        empty.text = A2.plain("Nothing is keeping this Mac awake")
        empty.alignment = .center
        for view in [title, list, empty] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        title.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        let top = A2.padTop + 16 + 6
        let room = bounds.height - top - A2.padTop
        // Four rows share the card, as in the mockup; more get the same share and scroll the card taller.
        list.rowHeight = max(44, (room / CGFloat(max(4, list.rows.count))).rounded(.down))
        list.frame = NSRect(x: A2.padSide, y: top, width: inner, height: room)
        empty.frame = NSRect(x: A2.padSide, y: top + room / 2 - 8, width: inner, height: 16)
    }
}

/// Energy per app over today or the last week, optionally only while on battery.
final class AppEnergyCard: CardView {
    static let maxRows = 5
    private let title = TextLine()
    let period = Segmented(["Today", "7 days"])
    let filter = Segmented(["On battery", "Any power"])
    let list = A2List()
    let empty = TextLine()
    var onChange: (() -> Void)?
    var batteryOnly = true { didSet { filter.isHidden = !batteryOnly } }

    override init() {
        super.init()
        list.header = .init(name: "App", meter: "Energy", second: "Share")
        list.meterWidth = 170
        list.meterColors = (Theme.dynamic(0x34C759, 0x30D158), Theme.dynamic(0x32ADE6, 0x64D2FF))
        list.valueWidth = 62
        list.secondWidth = 48
        period.onChange = { [weak self] _ in self?.onChange?() }
        filter.onChange = { [weak self] _ in self?.onChange?() }
        empty.isHidden = true
        empty.alignment = .center
        set(title: "Battery used by apps", detail: "")
        for view in [title, period, filter, list, empty] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title name: String, detail: String) {
        let text = NSMutableAttributedString(string: name, attributes: [.font: A2.titleFont, .foregroundColor: A2.primary])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: Theme.sans(12, .medium), .foregroundColor: A2.tertiary]))
        }
        title.text = text
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        var right = A2.padSide + inner
        for control in [period, filter] where !control.isHidden {
            let width = control.naturalWidth
            control.frame = NSRect(x: right - width, y: A2.padTop - 5, width: width, height: 26)
            right -= width + 8
        }
        title.frame = NSRect(x: A2.padSide, y: A2.padTop, width: max(0, right - A2.padSide - 8), height: 16)
        let top: CGFloat = 46
        let room = list.roomForRows(bounds.height - top - A2.padTop)
        list.rowHeight = max(36, (room / CGFloat(max(Self.maxRows, list.rows.count))).rounded(.down))
        list.frame = NSRect(x: A2.padSide, y: top, width: inner, height: bounds.height - top - A2.padTop)
        empty.frame = NSRect(x: A2.padSide, y: top + A2List.headerHeight + room / 2 - 8, width: inner, height: 16)
    }
}

/// Shading behind TimeChart's plot where the Mac was charging. The Battery page now
/// draws its bands in A2ChargeChart; this stays because CardPage still places it.
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
