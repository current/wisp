import AppKit
import CoreAudio
import WispCore

/// A card with a title and a list of rows, sized to its rows.
final class ListCard: CardView {
    let title = TextLine()
    let empty = TextLine()
    private(set) var rows: [ListRow] = []

    func set(count: Int, configure: (ListRow, Int) -> Void) {
        while rows.count < count {
            let row = ListRow()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= count
            if index < count {
                row.showsRule = index < count - 1
                configure(row, index)
            }
        }
        empty.isHidden = count > 0
        needsLayout = true
    }

    var wantedHeight: CGFloat { 60 + CGFloat(max(1, rows.filter { !$0.isHidden }.count)) * 34 }

    override init() {
        super.init()
        addSubview(title)
        addSubview(empty)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        title.frame = NSRect(x: 20, y: 16, width: width, height: 20)
        empty.frame = NSRect(x: 20, y: 54, width: width, height: 14)
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 20, y: 46 + CGFloat(index) * 34, width: width, height: 34) }
    }
}

/// An A2 card that holds a header and a list of `A2Row`s sharing its height, with a
/// line of text when the list is empty.
final class A2ListCard: CardView {
    let header = A2Header()
    /// Column titles over the rows, with a hairline under them; nil leaves them out.
    let columns = A2Row()
    var showsColumns = false { didSet { columns.isHidden = !showsColumns; needsLayout = true } }
    let empty = TextLine()
    private(set) var rows: [A2Row] = []
    /// The space between the header and the first row.
    var listGap: CGFloat = 8
    /// Rows never grow past this, so a short list does not stretch.
    var maxRowHeight: CGFloat = 60
    var minRowHeight: CGFloat = 36

    override init() {
        super.init()
        columns.isHidden = true
        columns.nameColor = A2.secondary
        empty.alignment = .center
        for view in [header, columns, empty] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int, configure: (A2Row, Int) -> Void) {
        while rows.count < count {
            let row = A2Row()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= count
            guard index < count else { continue }
            row.showsRule = index > 0
            configure(row, index)
        }
        empty.isHidden = count > 0
        needsLayout = true
    }

    private var shown: Int { rows.filter { !$0.isHidden }.count }
    private var listTop: CGFloat { A2.padTop + 16 + listGap + (showsColumns ? 26 : 0) }

    /// The height that holds every row at the smallest row height.
    var neededHeight: CGFloat { listTop + CGFloat(max(1, shown)) * minRowHeight + A2.padTop }
    /// The height past which rows would grow beyond `maxRowHeight`.
    var fullHeight: CGFloat { listTop + CGFloat(max(1, shown)) * maxRowHeight + A2.padTop }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        columns.frame = NSRect(x: A2.padSide, y: A2.padTop + 16 + listGap, width: inner, height: 26)
        let top = listTop
        let pitch = min(maxRowHeight, ((bounds.height - top - A2.padTop) / CGFloat(max(1, shown))).rounded(.down))
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: A2.padSide, y: top + CGFloat(index) * pitch, width: inner, height: pitch) }
        empty.frame = NSRect(x: A2.padSide, y: top + (bounds.height - top - A2.padTop) / 2 - 9, width: inner, height: 18)
    }

    func emptyText(_ text: String) {
        empty.text = NSAttributedString(string: text, attributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
    }
}

/// The column titles of an `A2ListCard`: text cells in the table header style.
extension A2Row {
    func titles(_ name: String, _ cells: [(String, CGFloat, NSTextAlignment)]) {
        self.name = name
        nameColor = A2.secondary
        nameFont = Theme.sans(11, .medium)
        self.cells = cells.map { .init(kind: .text($0.0, A2.secondary, Theme.sans(11, .medium), $0.2), width: $0.1) }
        ruleBelow = true
    }
}

// MARK: - Sensors

@MainActor
final class SensorsCardPage: CardPage {
    override var pageTint: NSColor { PageID.sensors.tint }
    override var labelTint: NSColor { A2.labelTint(.sensors) }
    private lazy var titleLines = heading("Sensors")
    private let range = Segmented(["5 Min", "Hour", "Day"])
    private let history = CardView()
    private let historyHeader = A2Header()
    private let chart = TimeChart()
    private let state = CardView()
    private let stateHeader = A2Header()
    private let stateFigure = A2.figure()
    private let stateSub = TextLine()
    private let stateBar = A2CapacityBar()
    private let stateEnds = TextLine()
    private let stateEnd = TextLine()
    private let stateLines = A2Lines()
    private let temperatures = A2ListCard()
    private let fans = A2ListCard()
    private let accessories = A2ListCard()
    private var accessoriesAt = Date.distantPast
    /// GPU and SSD readings while the page is open; the CPU's comes from the history.
    private var gpuRing = RecentRing(capacity: HistoryStore.recentSamples)
    private var ssdRing = RecentRing(capacity: HistoryStore.recentSamples)
    private var lastMinute = 0

    override var toolbarItems: [NSView] { [range] }
    override var toolbarHeading: (NSView, NSView)? { (titleLines.0, titleLines.1) }

    override func loadView() {
        super.loadView()
        for view in [history, state, temperatures, fans, accessories] as [NSView] { canvas.addSubview(view) }
        historyHeader.title = "History"
        chart.edgeToEdge = true
        chart.primaryColor = A2.cpu
        chart.secondaryColor = A2.gpu
        chart.tertiaryColor = A2.up
        chart.secondaryFill = 0.3
        chart.tertiaryFill = 0.2
        chart.names = ("CPU", "GPU")
        chart.tertiaryName = "SSD"
        chart.format = { Format.celsius(Double($0)) }
        for view in [historyHeader, chart] as [NSView] { history.addSubview(view) }
        stateHeader.title = "Thermal state"
        stateHeader.symbol = "gauge.with.dots.needle.33percent"
        stateHeader.size = 12
        stateHeader.iconSize = 14
        for view in [stateHeader, stateFigure, stateSub, stateBar, stateEnds, stateEnd, stateLines] as [NSView] { state.addSubview(view) }
        stateEnd.alignment = .right
        stateEnd.text = NSAttributedString(string: "Critical", attributes: [.font: Theme.sans(10.5), .foregroundColor: A2.tertiary])
        temperatures.header.title = "Temperatures"
        temperatures.showsColumns = true
        temperatures.columns.titles("Group", [("Sensors", 226, .left), ("", 96, .left), ("Hottest", 54, .right)])
        temperatures.emptyText("No temperature sensors found")
        temperatures.maxRowHeight = 72
        fans.header.title = "Fans"
        fans.listGap = 6
        fans.emptyText("This Mac has no fans")
        accessories.header.title = "Accessories"
        accessories.listGap = 6
        accessories.emptyText("No accessory reports a battery")
        range.onChange = { [weak self] _ in self?.refreshChart(force: true) }
        if let index = ["hour": 1, "day": 2][ProcessInfo.processInfo.environment["WISP_RANGE"] ?? ""] { range.select(index, animated: false) }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let room = scroll.contentSize.height - Self.topInset - margin * 2
        var y = margin
        if inner >= 760 {
            let column = (inner - gap * 3) / 4
            let left = (column * 3 + gap * 2).rounded(), rightX = margin + left + gap, rightWidth = inner - left - gap
            let top: CGFloat = 300
            let lower = max(384, room - top - gap)
            let half = ((lower - gap) / 2).rounded()
            history.frame = NSRect(x: margin, y: y, width: left, height: top)
            state.frame = NSRect(x: rightX, y: y, width: rightWidth, height: top)
            y += top + gap
            temperatures.frame = NSRect(x: margin, y: y, width: left, height: max(lower, temperatures.neededHeight))
            fans.frame = NSRect(x: rightX, y: y, width: rightWidth, height: half)
            accessories.frame = NSRect(x: rightX, y: y + half + gap, width: rightWidth, height: lower - half - gap)
            y = max(temperatures.frame.maxY, accessories.frame.maxY)
        } else {
            history.frame = NSRect(x: margin, y: y, width: inner, height: 260)
            y += 260 + gap
            state.frame = NSRect(x: margin, y: y, width: inner, height: 280)
            y += 280 + gap
            for card in [temperatures, fans, accessories] {
                card.frame = NSRect(x: margin, y: y, width: inner, height: min(card.fullHeight, max(card.neededHeight, 186)))
                y = card.frame.maxY + gap
            }
            y -= gap
        }
        historyHeader.frame = NSRect(x: A2.padSide, y: A2.padTop, width: history.bounds.width - A2.padSide * 2, height: 16)
        chart.frame = NSRect(x: 0, y: 54, width: history.bounds.width, height: history.bounds.height - 54)
        placeState()
        return y + margin
    }

    private func placeState() {
        let inner = state.bounds.width - A2.padSide * 2, height = state.bounds.height
        stateHeader.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        stateFigure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        stateSub.frame = NSRect(x: A2.padSide, y: 81, width: inner, height: 15)
        let linesHeight: CGFloat = 4 * 28
        stateLines.frame = NSRect(x: A2.padSide, y: height - A2.padTop - linesHeight, width: inner, height: linesHeight)
        // The current state on the left, the scale's far end on the right, each in its own half.
        stateEnds.frame = NSRect(x: A2.padSide, y: stateLines.frame.minY - 6 - 13, width: floor(inner / 2), height: 13)
        stateEnd.frame = NSRect(x: stateEnds.frame.maxX, y: stateEnds.frame.minY, width: inner - stateEnds.frame.width, height: 13)
        stateBar.frame = NSRect(x: A2.padSide, y: stateEnds.frame.minY - 6 - 8, width: inner, height: 8)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshChart(force: true)
    }

    private func refreshChart(force: Bool) {
        let store = delegate.monitor.history
        switch range.selected {
        case 0:
            chart.step = delegate.settings.interval
            chart.primary = store.recent(.cpuTemperature)
            chart.secondary = gpuRing.values
            chart.tertiary = ssdRing.values
        default:
            let minute = Int(Date().timeIntervalSince1970 / 60)
            guard force || minute != lastMinute else { return }
            lastMinute = minute
            chart.step = 60
            // GPU and SSD temperatures are only kept while this page is open.
            chart.primary = store.day(.cpuTemperature, minutes: range.selected == 1 ? 60 : HistoryStore.minutes)
            chart.secondary = []
            chart.tertiary = []
        }
        let values = (chart.primary + chart.secondary + chart.tertiary).filter { !$0.isNaN && $0 > 0 }
        let high = values.max() ?? 70, low = values.min() ?? 30
        // Round tens, with the lines in the upper half of the card where the readings sit.
        let top = max(30, (ceil((high + 2) / 10) * 10))
        var bottom = top - 40
        while bottom > 0, bottom > low - 2 { bottom -= 20 }
        chart.ceiling = top
        chart.bottom = max(0, bottom)
    }

    override func update(system s: SystemSnapshot) {
        guard let t = s.thermal else { return }
        let sensors = t.sensors
        let ssd = sensors.filter { $0.name.hasPrefix("SSD") }.map(\.celsius).max()
        gpuRing.append(Float(t.gpuCelsius ?? .nan))
        ssdRing.append(Float(ssd ?? .nan))
        refreshChart(force: false)
        var legend: [A2Header.Item] = []
        if let cpu = t.cpuCelsius { legend.append(.init(text: "CPU \(Format.celsius(cpu))", dot: A2.cpu)) }
        if let gpu = t.gpuCelsius { legend.append(.init(text: "GPU \(Format.celsius(gpu))", dot: A2.gpu)) }
        if let ssd { legend.append(.init(text: "SSD \(Format.celsius(ssd))", dot: A2.up)) }
        legend.append(.init(text: ["Last \(Int((Double(HistoryStore.recentSamples) * delegate.settings.interval / 60).rounded())) minutes",
                                   "Last hour", "Last 24 hours"][range.selected], faint: true))
        historyHeader.items = legend

        let groups = Self.groups(sensors)
        let hottest = sensors.max { $0.celsius < $1.celsius }
        titleLines.1.variants = [
            "Thermal pressure \(t.pressure.rawValue) · \(sensors.count) sensors · \(t.fans.count) fan\(t.fans.count == 1 ? "" : "s")",
            "Thermal pressure \(t.pressure.rawValue)", "",
        ].map(Toolbar.subtitle)
        showState(t, hottest: hottest)

        let before = temperatures.neededHeight
        temperatures.header.items = sensors.isEmpty ? [] : [
            .init(text: "\(sensors.count) sensors in \(groups.count) groups"),
            .init(text: hottest.map { "Hottest \($0.name), \(Format.celsius($0.celsius))" } ?? ""),
        ]
        temperatures.set(count: groups.count) { row, index in
            let group = groups[index]
            let (symbol, tint) = Self.look(group.name)
            row.lead = .glyph(symbol, tint)
            row.name = group.name
            row.detail = group.values.count == 1 ? "1 sensor" : "\(group.values.count) sensors"
            row.inline = true
            let top = group.values.max() ?? 0
            row.cells = [.init(kind: .chips(group.values.map { Format.celsius($0) }), width: 226),
                         .init(kind: .meter(top / 110, A2.warm, A2.warmEnd), width: 96),
                         .init(kind: .text(Format.celsius(top), A2.primary, A2.valueFont, .right), width: 54)]
        }

        let spinning = t.fans.filter { $0.rpm > 1 }.count
        fans.header.items = t.fans.isEmpty ? [] : [.init(text: spinning == 0 ? (t.fans.count == 2 ? "Both off" : "Off") : "\(spinning) spinning")]
        fans.set(count: t.fans.count) { row, index in
            let fan = t.fans[index]
            row.name = "Fan \(fan.index + 1)"
            row.detail = [fan.minRPM, fan.maxRPM].compactMap { $0 }.count == 2 ? "\(Int(fan.minRPM!)) to \(Int(fan.maxRPM!)) rpm" : ""
            row.cells = [.init(kind: .text("\(Int(fan.rpm)) rpm", A2.primary, A2.valueFont, .right), width: 64)]
        }

        if Date().timeIntervalSince(accessoriesAt) > 30 {
            accessoriesAt = Date()
            let batteries = Accessories.batteries()
            accessories.header.items = batteries.isEmpty ? [] : [.init(text: "Battery")]
            accessories.set(count: batteries.count) { row, index in
                let battery = batteries[index]
                row.name = battery.name
                row.meterBelow = Double(battery.percent) / 100
                row.meterColor = battery.percent <= 15 ? A2.bad : A2.charge
                row.meterEnd = battery.percent <= 15 ? nil : A2.chargeEnd
                row.cells = [.init(kind: .text("\(battery.percent)%", A2.primary, A2.valueFont, .right), width: 44)]
            }
        }
        if before != temperatures.neededHeight { relayout() }
    }

    private func showState(_ t: ThermalReading, hottest: TemperatureSensor?) {
        let levels: [ThermalPressure] = [.nominal, .fair, .serious, .critical]
        let level = levels.firstIndex(of: t.pressure) ?? 0
        let colors = [A2.good, A2.caution, A2.warn, A2.bad]
        let name = t.pressure.rawValue.prefix(1).uppercased() + t.pressure.rawValue.dropFirst()
        stateHeader.tint = colors[level]
        stateHeader.titleColor = colors[level]
        stateFigure.show(name)
        let notes = ["macOS is not slowing the chip", "Warm, with little or no slowing", "macOS is slowing the chip to cool it",
                     "macOS is slowing the chip hard"]
        stateSub.text = A2.plain(notes[level])
        stateBar.parts = levels.indices.map { .init(amount: 1, color: $0 <= level ? colors[level] : A2.track) }
        stateEnds.text = NSAttributedString(string: name, attributes: [.font: Theme.sans(10.5, .semibold), .foregroundColor: A2.primary])
        stateEnd.isHidden = level == 3
        let cpu = t.sensors.filter { $0.name.hasPrefix("CPU") }.map(\.celsius)
        let gpu = t.sensors.filter { $0.name.hasPrefix("GPU") }.map(\.celsius)
        let average = { (values: [Double]) in values.isEmpty ? "–" : Format.celsius(values.reduce(0, +) / Double(values.count)) }
        let rpm = t.fans.map(\.rpm)
        stateLines.lines = [
            .init(label: "Hottest", value: hottest.map { "\($0.name) · \(Format.celsius($0.celsius))" } ?? "–"),
            .init(label: "CPU average", value: average(cpu)),
            .init(label: "GPU average", value: average(gpu)),
            .init(label: "Fans", value: rpm.isEmpty ? "None" : (rpm.allSatisfy { $0 < 1 } ? "Off" : "\(Int(rpm.max() ?? 0)) rpm")),
        ]
    }

    /// Sensors grouped by their name without its number ("CPU 3" is in "CPU"): CPU, GPU,
    /// memory, SSD, battery, enclosure, then any others in the collector's order.
    static func groups(_ sensors: [TemperatureSensor]) -> [(name: String, values: [Double])] {
        var order: [String] = [], values: [String: [Double]] = [:]
        for sensor in sensors {
            var parts = sensor.name.components(separatedBy: " ")
            if parts.count > 1, Int(parts.last!) != nil { parts.removeLast() }
            let name = parts.joined(separator: " ")
            if values[name] == nil { order.append(name) }
            values[name, default: []].append(sensor.celsius)
        }
        let preferred = ["CPU", "GPU", "Memory", "SSD", "Battery", "Enclosure"]
        let rank = { (name: String) in preferred.firstIndex(of: name) ?? preferred.count }
        return order.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map { ($0.element, values[$0.element]!) }
    }

    private static func look(_ group: String) -> (String, NSColor) {
        switch group {
        case "CPU": return (PageID.cpu.symbol, A2.labelTint(.cpu))
        case "GPU": return (PageID.gpu.symbol, A2.labelTint(.gpu))
        case "Memory": return (PageID.memory.symbol, A2.labelTint(.memory))
        case "SSD": return ("internaldrive", A2.labelTint(.disk))
        case "Battery": return ("battery.75percent", A2.good)
        default: return (PageID.sensors.symbol, A2.labelTint(.energy))
        }
    }
}

// MARK: - Neural Engine

/// Today on the Neural Engine from the minute history (and the hourly archive for the
/// hours before this run), worked out off the main thread once a minute.
struct NeuralDay: Equatable {
    /// Milliwatt hours in each hour from midnight; nil where nothing was recorded.
    var hours: [Double?] = []
    var current = 0
    var peak = 0.0
    var peakAt: Date?
    var activeMinutes = 0
    var busiestHour: Int?
    /// Milliwatt hours since midnight.
    var energy = 0.0
    /// The first reading today, when Wisp started reading after midnight.
    var since: Date?
    var lastBusy: Date?

    static let busy = 0.05

    static func read(_ history: HistoryStore, now: Date = Date()) -> NeuralDay {
        let midnight = Calendar.current.startOfDay(for: now)
        let start = HistoryStore.minute(midnight), end = HistoryStore.minute(now)
        let values = history.day(.neural, minutes: max(1, end - start), now: now)
        let archived = Dictionary((history.archive?.system(.neural, since: start / 60) ?? []).map { ($0.hour, $0.value) }, uniquingKeysWith: { a, _ in a })
        var day = NeuralDay()
        day.current = min(23, max(0, (end - start) / 60))
        let date = { (index: Int) in Date(timeIntervalSince1970: Double(start + index) * 60) }
        for hour in 0...day.current {
            let from = min(values.count, hour * 60), to = min(values.count, hour * 60 + 60)
            let slice = values[from..<to].filter { !$0.isNaN }
            if !slice.isEmpty {
                day.hours.append(Double(slice.reduce(0, +)) / 60 * 1000)
            } else if let watts = archived[(start + hour * 60) / 60] {
                day.hours.append(watts * 1000)
                if day.since == nil { day.since = date(hour * 60) }
            } else {
                day.hours.append(nil)
            }
        }
        for (index, value) in values.enumerated() where !value.isNaN {
            if day.since == nil || date(index) < day.since! { day.since = date(index) }
            if Double(value) > day.peak { (day.peak, day.peakAt) = (Double(value), date(index)) }
            if Double(value) >= busy {
                day.activeMinutes += 1
                day.lastBusy = date(index + 1)
            }
        }
        day.energy = day.hours.compactMap { $0 }.reduce(0, +)
        if let top = day.hours.compactMap({ $0 }).max(), top > 0 { day.busiestHour = day.hours.firstIndex { $0 == top } }
        return day
    }
}

@MainActor
final class NeuralPage: MachinePage {
    private let average = Tile("Average"), peakToday = Tile("Peak today"), active = Tile("Active today")
    private let energy = Tile("Energy today"), share = Tile("Share of chip")
    private let today = CardView()
    private let todayHeader = A2Header()
    private let hours = HourColumns()
    private let todayFoot = TextLine()
    private let services = A2ListCard()
    private let servicesFoot = TextLine()
    private let quiet = ChartNote()
    private var day = NeuralDay()
    private var dayMinute = -1
    private var reading = false
    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// The system services that run models on the Neural Engine, by the processes that do the work.
    private static let feeders: [(name: String, symbol: String, detail: String, processes: [String])] = [
        ("Apple Intelligence", "sparkles", "Writing Tools and summaries",
         ["TGOnDeviceInferenceProviderService", "generativeexperiencesd", "PrivateMLClientInferenceProviderService", "modelmanagerd"]),
        ("Photos", "photo.on.rectangle", "Faces, scenes and memories", ["photoanalysisd", "photosfaced"]),
        ("Live Text and Look Up", "text.viewfinder", "Text and objects in images and video", ["mediaanalysisd", "visualintelligenced"]),
        ("Dictation and Siri", "waveform", "Speech recognised on this Mac", ["localspeechrecognition", "corespeechd", "siriinferenced"]),
        ("Translation", "translate", "Translate and Live Translation", ["translationd"]),
        ("Core ML in apps", "square.stack.3d.up", "Models that apps run on this Mac", ["aned", "ANECompilerService", "aneuserd"]),
    ]

    override var chartTint: NSColor { A2.neural }
    override var labelTint: NSColor { A2.neuralLabel }

    override func setUp() {
        metric = .neural
        hero.chart.format = { $0 == 0 || $0 >= 1 ? String(format: "%.0f W", $0) : String(format: "%.1f W", $0) }
        hero.chart.minimumCeiling = 1
        hero.figure.format = { (String(format: $0 >= 1 ? "%.1f" : "%.2f", $0), "W") }
        hero.addSubview(quiet)
        average.showsMeter = true
        share.showsMeter = true
        tiles = [average, peakToday, active, energy, share]
        showsTable = false
        for view in [today, services] as [NSView] { canvas.addSubview(view) }
        todayHeader.title = "Today"
        todayHeader.detail = "energy by hour"
        todayHeader.symbol = "calendar"
        todayHeader.size = 13
        hours.color = A2.neural
        hours.end = Theme.dynamic(0xE59BF2, 0xEBC2FF)
        hours.format = Self.energyText
        hours.onHover = { [weak self] _ in self?.showToday() }
        todayFoot.text = A2.plain("Dashed hours were not recorded · hover an hour for its energy")
        for view in [todayHeader, hours, todayFoot] as [NSView] { today.addSubview(view) }
        services.header.title = "What uses it"
        services.header.detail = "by CPU now"
        services.header.symbol = "cpu"
        services.showsColumns = true
        services.columns.titles("Service", [("CPU now", 90 + A2Row.spacing + 70, .right)])
        services.listGap = 6
        services.minRowHeight = 44
        services.maxRowHeight = 52
        servicesFoot.text = A2.plain("macOS reports the Neural Engine's power as a whole, never by app")
        services.addSubview(servicesFoot)
        fillServices(nil)
        subtitle([Self.chip])
    }

    override func loadView() {
        super.loadView()
        // The shared tile labels know only their stock names; these four get their own symbols.
        for (tile, symbol) in [(peakToday, "arrow.up.to.line"), (active, "clock.fill"), (energy, "bolt.batteryblock.fill"), (share, "chart.pie.fill")] {
            tile.caption.text = A2.title(tile.name, symbol: symbol, tint: labelTint, size: 12, color: A2.secondary)
        }
        todayHeader.tint = labelTint
        todayHeader.titleColor = A2.primary
        services.header.tint = labelTint
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        readDay(force: true)
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: heroHeight)
        quiet.frame = NSRect(x: 0, y: hero.chartTop + 26, width: hero.bounds.width - 46, height: max(40, hero.bounds.height - hero.chartTop - 50))
        var y = placeTiles(top: hero.frame.maxY + gap, width: width) + gap
        let servicesHeight = services.neededHeight + 28
        if inner >= 760 {
            let height = max(servicesHeight, 300, room - (y - margin))
            row([today, services], weights: [3, 2], y: y, height: height, width: width)
            y += height
        } else {
            today.frame = NSRect(x: margin, y: y, width: inner, height: 280)
            services.frame = NSRect(x: margin, y: today.frame.maxY + gap, width: inner, height: servicesHeight)
            y = services.frame.maxY
        }
        let todayInner = today.bounds.width - A2.padSide * 2
        todayHeader.frame = NSRect(x: A2.padSide, y: A2.padTop, width: todayInner, height: 16)
        todayFoot.frame = NSRect(x: A2.padSide, y: today.bounds.height - A2.padTop - 14, width: todayInner, height: 14)
        hours.frame = NSRect(x: A2.padSide, y: A2.padTop + 16 + 16, width: todayInner, height: todayFoot.frame.minY - 14 - (A2.padTop + 32))
        // Rows stop above the footer line.
        let listTop = A2.padTop + 16 + services.listGap + 26
        services.maxRowHeight = min(56, ((services.bounds.height - listTop - A2.padTop - 28) / CGFloat(Self.feeders.count)).rounded(.down))
        servicesFoot.frame = NSRect(x: A2.padSide, y: services.bounds.height - A2.padTop - 14, width: services.bounds.width - A2.padSide * 2, height: 14)
        services.needsLayout = true
        return y + margin
    }

    override func chartChanged() {
        let values = hero.chart.primary.filter { !$0.isNaN }
        let top = Self.peak(hero.chart.primary)
        hero.chart.ceiling = Float(ChartScale.ceiling(peak: Double(top), minimum: 1))
        showPeak(Self.watts(Double(top)))
        let idle = values.count > 1 && top < Float(NeuralDay.busy)
        quiet.isHidden = !idle
        if idle {
            let detail: String
            if let last = day.lastBusy {
                detail = "Last busy at \(clock.string(from: last)) · peak today \(Self.watts(day.peak))"
            } else {
                detail = "It wakes for Live Text, dictation, Photos and Apple Intelligence"
            }
            quiet.show("Nothing has run on it in the \(rangeName.lowercased())", detail: detail)
        }
    }

    override func updateHero(_ s: SystemSnapshot) {
        readDay(force: false)
        guard let watts = s.power?.ane else {
            hero.figure.show("–")
            hero.state.isHidden = true
            hero.meta.text = A2.plain("Chip power is not readable on this Mac")
            return
        }
        let busy = watts >= NeuralDay.busy
        hero.figure.set(watts)
        hero.state.isHidden = false
        hero.state.text = busy ? "In use" : "Idle"
        hero.state.tone = busy ? .good : .neutral
        hero.state.dot = busy
        if busy {
            hero.meta.text = A2.plain("Running a model now · macOS does not say for which app")
        } else if let last = day.lastBusy {
            hero.meta.text = A2.plain("Idle since \(clock.string(from: last)) · \(Self.minutes(day.activeMinutes)) of work today")
        } else if let since = day.since, since.timeIntervalSince(Calendar.current.startOfDay(for: Date())) > 300 {
            hero.meta.text = A2.plain("Idle · nothing has run on it since \(clock.string(from: since))")
        } else {
            hero.meta.text = A2.plain("Idle · nothing has run on it today")
        }
        hero.needsLayout = true
    }

    override func updateTiles(_ s: SystemSnapshot) {
        let values = hero.chart.primary.filter { !$0.isNaN }
        let mean = values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
        average.set(text: String(format: "%.2f", mean), unit: "W")
        average.meter.fraction = mean / Double(hero.chart.ceiling ?? 1)
        average.set(note: "In the chart above")

        // The minute history keeps averages; the last few minutes add the momentary highs.
        let recent = delegate.monitor.history.recent(.neural).filter { !$0.isNaN }
        var peak = day.peak, peakAt = day.peakAt
        if let high = recent.max(), Double(high) > peak { (peak, peakAt) = (Double(high), Date()) }
        peakToday.set(text: String(format: peak >= 1 ? "%.1f" : "%.2f", peak), unit: "W")
        peakToday.set(note: peak >= NeuralDay.busy ? "At \(clock.string(from: peakAt ?? Date()))" : "Nothing yet today")

        let minutes = day.activeMinutes
        if minutes < 60 {
            active.set(text: "\(minutes)", unit: "min")
        } else {
            active.set(text: "\(minutes / 60)h \(minutes % 60)", unit: "min")
        }
        active.set(notes: day.busiestHour.map { ["Busiest hour \(hourName($0))", "Busiest \(hourName($0))"] } ?? ["Minutes over 0.05 W", "Over 0.05 W"])

        let (figure, unit) = Self.energyParts(day.energy)
        energy.set(text: figure, unit: unit)
        energy.set(note: day.since.map { $0.timeIntervalSince(Calendar.current.startOfDay(for: Date())) > 300 ? "Read since \(clock.string(from: $0))" : "Since midnight" }
            ?? "First minute still to come")

        if let p = s.power, let cpu = p.cpu {
            let ane = p.ane ?? 0, total = cpu + (p.gpu ?? 0) + ane
            let fraction = total > 0 ? ane / total : 0
            share.set(text: fraction > 0 && fraction < 0.01 ? "<1" : String(format: "%.0f", fraction * 100), unit: "%")
            share.meter.fraction = fraction
            share.set(notes: ["CPU \(Format.watts(cpu)) · GPU \(Format.watts(p.gpu ?? 0))", "Of \(Format.watts(total))"])
        }
    }

    override func update(table: ProcessTable) {
        super.update(table: table)
        fillServices(table)
    }

    private func fillServices(_ table: ProcessTable?) {
        var byName: [String: (cpu: Double, readable: Bool, count: Int)] = [:]
        for process in table?.processes ?? [] {
            let name = process.path.map { ($0 as NSString).lastPathComponent } ?? process.name
            var entry = byName[name] ?? (0, true, 0)
            entry.cpu += process.cpu
            entry.readable = entry.readable && process.readable
            entry.count += 1
            byName[name] = entry
        }
        let rows = Self.feeders.map { feeder -> (cpu: Double, running: Int, readable: Bool, names: [String]) in
            let found = feeder.processes.compactMap { name in byName[name].map { (name, $0) } }
            return (found.reduce(0) { $0 + $1.1.cpu }, found.reduce(0) { $0 + $1.1.count }, found.allSatisfy { $0.1.readable }, found.map(\.0))
        }
        let top = max(0.05, rows.map(\.cpu).max() ?? 0)
        let running = rows.filter { $0.running > 0 }.count
        services.header.items = table == nil ? [] : [.init(text: "\(running) of \(Self.feeders.count) running", faint: true)]
        services.set(count: Self.feeders.count) { row, index in
            let feeder = Self.feeders[index], reading = rows[index]
            row.lead = .glyph(feeder.symbol, reading.cpu >= 0.001 ? labelTint : nil)
            row.leadSize = 26
            row.name = feeder.name
            row.detail = feeder.detail
            row.nameColor = reading.running > 0 ? A2.primary : A2.secondary
            let figure: A2Row.Cell.Kind
            if table == nil {
                figure = .text("–", A2.tertiary, A2.quietValueFont, .right)
            } else if reading.running == 0 {
                figure = .text("Not running", A2.tertiary, A2.quietValueFont, .right)
            } else if !reading.readable, reading.cpu < 0.001 {
                figure = .text("Running", A2.secondary, A2.quietValueFont, .right)
            } else if reading.cpu < 0.001 {
                figure = .text("Idle", A2.secondary, A2.quietValueFont, .right)
            } else {
                figure = .text(String(format: reading.cpu < 0.1 ? "%.1f%%" : "%.0f%%", reading.cpu * 100), A2.primary, A2.valueFont, .right)
            }
            row.cells = [.init(kind: .meter(reading.cpu / top, A2.neural, hours.end), width: 90), .init(kind: figure, width: 70)]
            let processes = feeder.processes.joined(separator: ", ")
            row.toolTip = reading.names.isEmpty ? "Not running now: \(processes)" : "Running: \(reading.names.joined(separator: ", "))"
        }
    }

    /// Reads today's history again once a minute, off the main thread: the archive is SQLite.
    private func readDay(force: Bool) {
        let minute = HistoryStore.minute(Date())
        guard force || minute != dayMinute, !reading else { return }
        dayMinute = minute
        reading = true
        let history = delegate.monitor.history
        DispatchQueue.global(qos: .utility).async {
            let day = NeuralDay.read(history)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                self.day = day
                self.showToday()
                self.chartChanged()
            }
        }
    }

    private func showToday() {
        hours.values = day.hours
        hours.current = day.current
        hours.ceiling = ChartScale.ceiling(peak: day.hours.compactMap { $0 }.max() ?? 0, minimum: 10)
        if let index = hours.hovered {
            let value = index < day.hours.count ? day.hours[index] : nil
            todayHeader.items = [.init(text: hourName(index) + (index == day.current ? ", so far" : "")),
                                 .init(text: "", value: value.map(Self.energyText) ?? "Not recorded")]
        } else {
            var items: [A2Header.Item] = [.init(text: "Total", value: Self.energyText(day.energy))]
            if let hour = day.busiestHour {
                items.append(.init(text: "Busiest", value: hourName(hour)))
            } else if let since = day.since, since.timeIntervalSince(Calendar.current.startOfDay(for: Date())) > 300 {
                items.append(.init(text: "Read since \(clock.string(from: since))", faint: true))
            }
            todayHeader.items = items
        }
    }

    private func hourName(_ index: Int) -> String {
        let start = Calendar.current.date(byAdding: .hour, value: index, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return clock.string(from: start)
    }

    static func watts(_ value: Double) -> String { String(format: value >= 1 ? "%.1f W" : "%.2f W", value) }

    static func minutes(_ count: Int) -> String { count < 60 ? "\(count) min" : "\(count / 60)h \(count % 60)m" }

    static func energyParts(_ milliwattHours: Double) -> (String, String) {
        if milliwattHours >= 1000 { return (String(format: "%.2f", milliwattHours / 1000), "Wh") }
        return (String(format: milliwattHours >= 10 || milliwattHours == 0 ? "%.0f" : "%.1f", milliwattHours), "mWh")
    }

    static func energyText(_ milliwattHours: Double) -> String {
        let (figure, unit) = energyParts(milliwattHours)
        return figure + " " + unit
    }
}

// MARK: - Sound

/// A default device's level: the name in the page's colour with a state pill, the
/// volume as a figure with a slider beside it, the device under it and one line on
/// who is using it.
final class LevelCard: CardView {
    let header = A2Header()
    let state = Pill()
    let level = A2.figure()
    let slider = A2Slider()
    let device = TextLine()
    let status = TextLine()
    /// When the microphone was in use while the page was open, with its span under it.
    let use = UseStrip()
    let useStart = TextLine()
    let useEnd = TextLine()
    let foot = TextLine()
    private let quiet = DrawnGlyph()
    private let loud = DrawnGlyph()

    init(input: Bool) {
        super.init()
        header.title = input ? "Input" : "Output"
        header.symbol = input ? "mic.fill" : "speaker.wave.2.fill"
        header.tint = A2.sound
        header.titleColor = A2.sound
        quiet.symbol = input ? "mic" : "speaker.fill"
        loud.symbol = input ? "mic.fill" : "speaker.wave.3.fill"
        useEnd.alignment = .right
        if input { use.title = "Microphone use" }
        for view in [header, state, level, slider, device, status, use, useStart, useEnd, foot, quiet, loud] as [NSView] { addSubview(view) }
        foot.text = NSAttributedString(string: input ? "Drag the slider to set the input level" : "Drag the slider to set the volume",
                                       attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(volume: Float?) {
        if let volume { level.show(String(format: "%.0f", volume * 100), unit: "%") } else { level.show("Fixed") }
        slider.isEnabled = volume != nil
        if let volume, !slider.dragging { slider.value = volume }
        slider.toolTip = volume == nil ? "This device sets its own volume" : nil
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        state.frame = NSRect(x: A2.padSide + header.titleRight + 10, y: 13, width: state.naturalWidth, height: 18)
        level.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: 96)
        let sliderX = A2.padSide + 100
        quiet.frame = NSRect(x: sliderX, y: 51, width: 14, height: 14)
        loud.frame = NSRect(x: bounds.width - A2.padSide - 14, y: 51, width: 14, height: 14)
        slider.frame = NSRect(x: quiet.frame.maxX + 9 - 12, y: 46, width: loud.frame.minX - 9 - quiet.frame.maxX - 9 + 24, height: 24)
        device.frame = NSRect(x: A2.padSide, y: 81, width: inner, height: 15)
        status.frame = NSRect(x: A2.padSide, y: 101, width: inner, height: 15)
        foot.frame = NSRect(x: A2.padSide, y: bounds.height - A2.padTop - 14, width: inner, height: 14)
        useStart.frame = NSRect(x: A2.padSide, y: foot.frame.minY - 16 - 13, width: inner / 2, height: 13)
        useEnd.frame = NSRect(x: A2.padSide + inner / 2, y: useStart.frame.minY, width: inner / 2, height: 13)
        use.frame = NSRect(x: A2.padSide, y: useStart.frame.minY - 6 - 10, width: inner, height: 10)
    }
}

/// A small symbol in the tertiary label colour.
private final class DrawnGlyph: DrawnView {
    var symbol = "" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        IconTile.glyph(symbol, tint: A2.tertiary, size: bounds.width, appearance: effectiveAppearance)
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

@MainActor
final class SoundPage: CardPage {
    override var pageTint: NSColor { PageID.sound.tint }
    override var labelTint: NSColor { A2.sound }
    private let hero = ChartCard("Output")
    private let heroSlider = A2Slider()
    private let heroQuiet = DrawnGlyph(), heroLoud = DrawnGlyph()
    private let bands = ChargeBands()
    private let quietNote = ChartNote()
    private let input = LevelCard(input: true)
    private let outputs = A2ListCard()
    private let inputs = A2ListCard()
    private let apps = A2ListCard()
    private let outputsFoot = TextLine(), inputsFoot = TextLine()
    private lazy var titleLines = heading("Sound")
    private var caption: TextLine { titleLines.1 }
    private var checkedAt = Date.distantPast
    private var shownDevices: [Bool: [AudioDevice]] = [:]
    /// Transport and sample rate per device, read once per device and every ten seconds.
    private var details: [AudioObjectID: String] = [:]
    private var detailsAt = Date.distantPast
    private var shownRows = -1
    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// What the page saw on each pass while it was open: the output volume and the apps
    /// playing and recording. macOS keeps no such history, so it starts when the page opens.
    private struct Sample {
        var date: Date
        var volume: Float
        var playing: Set<String>
        var recording: Set<String>
    }
    private var samples: [Sample] = []
    private static let window: TimeInterval = 5 * 60

    override func loadView() {
        super.loadView()
        _ = titleLines
        for view in [hero, input, outputs, inputs, apps] as [NSView] { canvas.addSubview(view) }
        hero.tint = A2.sound
        hero.labelTint = A2.sound
        hero.range.items = ["Live"]
        hero.chartTop = 108
        hero.chart.format = { String(format: "%.0f%%", $0 * 100) }
        hero.chart.ceiling = 1
        hero.chart.secondaryFill = 0.3
        hero.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        heroQuiet.symbol = "speaker.fill"
        heroLoud.symbol = "speaker.wave.3.fill"
        for view in [heroSlider, heroQuiet, heroLoud, quietNote] as [NSView] { hero.addSubview(view) }
        hero.addSubview(bands)
        bands.title = "Playing"
        heroSlider.setAccessibilityLabel("Output volume")
        input.slider.setAccessibilityLabel("Input level")
        heroSlider.onChange = { [weak self] value in self?.setVolume(value, input: false) }
        input.slider.onChange = { [weak self] value in self?.setVolume(value, input: true) }
        for (card, title, isInput) in [(outputs, "Output devices", false), (inputs, "Input devices", true)] {
            card.header.title = title
            card.header.symbol = isInput ? "mic" : "hifispeaker.2"
            card.header.tint = A2.sound
            card.listGap = 6
            card.minRowHeight = 46
            card.maxRowHeight = 48
            card.emptyText(isInput ? "No microphone connected" : "No speakers or headphones connected")
        }
        for (card, foot) in [(outputs, outputsFoot), (inputs, inputsFoot)] {
            foot.text = NSAttributedString(string: "Click a device to switch to it", attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
            card.addSubview(foot)
        }
        apps.header.title = "Apps with sound open"
        apps.header.symbol = "music.note"
        apps.header.tint = A2.sound
        apps.showsColumns = true
        apps.columns.titles("App", [("Played", 130 + A2Row.spacing + 64, .right), ("Now", 104, .right)])
        apps.listGap = 6
        apps.minRowHeight = 42
        apps.maxRowHeight = 50
        apps.emptyText("No app has sound open")
        refresh()
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let room = scroll.contentSize.height - Self.topInset - margin * 2
        var y = margin
        hero.frame = NSRect(x: margin, y: y, width: inner, height: 268)
        placeHero()
        y = hero.frame.maxY + gap
        // The longer device list at 48 pt a row, with a line for the footer under it.
        let longest = CGFloat(max(2, outputs.rows.filter { !$0.isHidden }.count, inputs.rows.filter { !$0.isHidden }.count))
        let lists = A2.padTop + 16 + 6 + longest * 48 + 26 + A2.padTop
        if inner >= 760 {
            let third = ((inner - gap * 2) / 3).rounded(.down)
            input.frame = NSRect(x: margin, y: y, width: third, height: lists)
            outputs.frame = NSRect(x: margin + third + gap, y: y, width: third, height: lists)
            inputs.frame = NSRect(x: margin + (third + gap) * 2, y: y, width: inner - (third + gap) * 2, height: lists)
            y += lists + gap
        } else {
            input.frame = NSRect(x: margin, y: y, width: inner, height: 206)
            y = input.frame.maxY + gap
            for card in [outputs, inputs] {
                let rows = CGFloat(max(1, card.rows.filter { !$0.isHidden }.count))
                card.frame = NSRect(x: margin, y: y, width: inner, height: A2.padTop + 16 + 6 + rows * 48 + 26 + A2.padTop)
                y = card.frame.maxY + gap
            }
        }
        for (card, foot) in [(outputs, outputsFoot), (inputs, inputsFoot)] {
            foot.frame = NSRect(x: A2.padSide, y: card.bounds.height - A2.padTop - 14, width: card.bounds.width - A2.padSide * 2, height: 14)
            foot.isHidden = card.rows.filter { !$0.isHidden }.count < 2
        }
        let left = room - (y - margin)
        apps.frame = NSRect(x: margin, y: y, width: inner, height: min(apps.fullHeight, max(apps.neededHeight, left)))
        return apps.frame.maxY + margin
    }

    private func placeHero() {
        let width = hero.bounds.width
        // The slider takes the half of the figure row the legend does not need.
        let sliderX = A2.padSide + 120, sliderRight = min(width - A2.padSide, sliderX + 440)
        heroQuiet.frame = NSRect(x: sliderX, y: 51, width: 14, height: 14)
        heroLoud.frame = NSRect(x: sliderRight - 14, y: 51, width: 14, height: 14)
        heroSlider.frame = NSRect(x: heroQuiet.frame.maxX + 9 - 12, y: 46, width: heroLoud.frame.minX - 9 - heroQuiet.frame.maxX - 9 + 24, height: 24)
        quietNote.frame = NSRect(x: 0, y: hero.chartTop + 22, width: width - 46, height: 60)
    }

    override func update(system: SystemSnapshot) {
        if Date().timeIntervalSince(checkedAt) >= 2 { refresh() }
    }

    private func refresh() {
        checkedAt = Date()
        let devices = Audio.devices()
        if Date().timeIntervalSince(detailsAt) > 10 {
            detailsAt = Date()
            details = [:]
        }
        let clients = Audio.clients()
        let table = delegate.table
        var groupOf: [Int32: AppGroup] = [:]
        for app in table.apps { for pid in app.pids { groupOf[pid] = app } }
        var byApp: [String: (name: String, icon: NSImage?, playing: Bool, recording: Bool)] = [:]
        for client in clients {
            // Helpers and audio services count toward the app they belong to; background
            // daemons are left out unless they are making sound.
            let group = groupOf[client.pid]
            guard group?.kind == .app || client.playing || client.recording else { continue }
            let name = group?.name ?? NSRunningApplication(processIdentifier: client.pid)?.localizedName ?? "Process \(client.pid)"
            let icon = group.map { Icons.icon(for: $0) } ?? NSRunningApplication(processIdentifier: client.pid)?.icon
            var entry = byApp[name] ?? (name, icon, false, false)
            entry.playing = entry.playing || client.playing
            entry.recording = entry.recording || client.recording
            byApp[name] = entry
        }
        let playingNow = byApp.values.filter(\.playing).map(\.name).sorted()
        let recordingNow = byApp.values.filter(\.recording).map(\.name).sorted()

        // Output: the hero.
        let output = Audio.defaultDevice(input: false)
        let volume = output.flatMap { Audio.volume($0, input: false) }
        let muted = output.map { Self.muted($0) } ?? false
        samples.append(Sample(date: Date(), volume: muted ? 0 : (volume ?? 1), playing: Set(playingNow), recording: Set(recordingNow)))
        samples.removeAll { Date().timeIntervalSince($0.date) > Self.window }
        showHero(output: output, devices: devices, volume: volume, muted: muted, playing: playingNow)

        // Input: its level card.
        let mic = Audio.defaultDevice(input: true)
        input.show(volume: mic.flatMap { Audio.volume($0, input: true) })
        input.device.text = A2.plain(devices.first { $0.id == mic }.map { device in
            "\(device.name) · \(describe(device.id, input: true).0)"
        } ?? "No microphone")
        let micUsed = !recordingNow.isEmpty
        input.state.text = micUsed ? "In use" : "Not in use"
        input.state.tone = micUsed ? .warn : .neutral
        input.state.dot = micUsed
        input.status.text = NSAttributedString(string: micUsed ? "\(Self.list(recordingNow)) \(recordingNow.count == 1 ? "is" : "are") using it now"
            : "No app is using the microphone", attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
        input.use.flags = samples.map { !$0.recording.isEmpty }
        let minutesUsed = samples.enumerated().reduce(0.0) { total, item in
            guard item.offset > 0, !item.element.recording.isEmpty else { return total }
            return total + min(10, item.element.date.timeIntervalSince(samples[item.offset - 1].date))
        }
        input.use.toolTip = minutesUsed > 0 ? "In use for \(Format.duration(minutesUsed)) while this page was open" : "Not used while this page was open"
        let quietText: [NSAttributedString.Key: Any] = [.font: Theme.sans(10.5), .foregroundColor: A2.tertiary]
        input.useStart.text = NSAttributedString(string: minutesUsed > 0 ? "Microphone in use for \(Format.duration(minutesUsed))" : "Microphone use",
                                                 attributes: [.font: Theme.sans(10.5, .semibold), .foregroundColor: A2.secondary])
        input.useEnd.text = NSAttributedString(string: samples.first.map { "Since \(clock.string(from: $0.date))" } ?? "", attributes: quietText)
        input.needsLayout = true

        for (card, isInput) in [(outputs, false), (inputs, true)] {
            let current = Audio.defaultDevice(input: isInput)
            // The device in use first, then the rest by name.
            let candidates = devices.filter { isInput ? $0.hasInput : $0.hasOutput }
                .sorted { ($0.id == current ? 0 : 1, $0.name) < ($1.id == current ? 0 : 1, $1.name) }
            shownDevices[isInput] = candidates
            card.header.items = [.init(text: candidates.count == 1 ? "1 device" : "\(candidates.count) devices", faint: true)]
            card.set(count: candidates.count) { row, index in
                let device = candidates[index]
                let (detail, symbol) = describe(device.id, input: isInput)
                let chosen = device.id == current
                row.lead = .glyph(symbol, chosen ? A2.sound : nil)
                row.leadSize = 26
                row.name = device.name
                row.detail = detail
                row.cells = [.init(kind: chosen ? .check : .text("Use", A2.pillText, Theme.sans(12, .semibold), .right), width: 30)]
                row.onClick = chosen ? nil : { [weak self] in self?.pick(index, input: isInput) }
                row.spokenNote = chosen ? "In use" : ""
                row.toolTip = chosen ? "In use for \(isInput ? "input" : "output")" : "Use \(device.name) for \(isInput ? "input" : "output")"
            }
        }
        let deviceRows = outputs.rows.filter { !$0.isHidden }.count + inputs.rows.filter { !$0.isHidden }.count * 100
        if deviceRows != shownRows {
            shownRows = deviceRows
            relayout()
        }
        showApps(Array(byApp.values))
    }

    private func showHero(output: AudioObjectID?, devices: [AudioDevice], volume: Float?, muted: Bool, playing: [String]) {
        if muted {
            hero.figure.show("Muted")
        } else if let volume {
            hero.figure.set(Double(volume))
        } else {
            hero.figure.show("Fixed")
        }
        heroSlider.isEnabled = volume != nil
        if let volume, !heroSlider.dragging { heroSlider.value = volume }
        hero.state.isHidden = false
        hero.state.text = muted ? "Muted" : playing.isEmpty ? "Silent" : "Playing"
        hero.state.tone = muted ? .warn : playing.isEmpty ? .neutral : .good
        hero.state.dot = !playing.isEmpty && !muted
        let name = devices.first { $0.id == output }.map { "\($0.name) · \(describe($0.id, input: false).0)" } ?? "No output device"
        let what = playing.isEmpty ? "nothing playing" : "\(Self.list(playing)) playing"
        hero.meta.variants = ["\(name) · \(what)", name].map(A2.plain)
        hero.chart.step = samples.count > 1 ? samples.last!.date.timeIntervalSince(samples.first!.date) / Double(samples.count - 1) : 2
        hero.chart.primary = samples.map(\.volume)
        bands.charging = samples.map { !$0.playing.isEmpty }
        let span = samples.first.map { Date().timeIntervalSince($0.date) } ?? 0
        let since = span >= Self.window - 10 ? "Last 5 minutes" : "Since \(clock.string(from: samples.first?.date ?? Date()))"
        hero.header.items = [.init(text: "Volume", dot: A2.sound), .init(text: "Playing", dot: Theme.good.withAlphaComponent(0.5)), .init(text: since, faint: true)]
        let played = samples.contains { !$0.playing.isEmpty }
        quietNote.isHidden = played || samples.count < 2
        if !played {
            quietNote.show(span >= Self.window - 10 ? "Nothing has played in the last 5 minutes" : "Nothing has played since you opened Sound",
                           detail: "Green bands mark the moments an app plays sound")
        }
        caption.variants = ["\(what.prefix(1).uppercased() + what.dropFirst()) · \(name)", String(what.prefix(1).uppercased() + what.dropFirst()), ""]
            .map(Toolbar.subtitle)
        hero.needsLayout = true
    }

    private func showApps(_ entries: [(name: String, icon: NSImage?, playing: Bool, recording: Bool)]) {
        // Seconds each app played inside the window, from the gaps between passes.
        var played: [String: TimeInterval] = [:], last: [String: Date] = [:]
        for (index, sample) in samples.enumerated() {
            let step = index > 0 ? sample.date.timeIntervalSince(samples[index - 1].date) : 2
            for name in sample.playing.union(sample.recording) {
                played[name, default: 0] += min(step, 10)
                last[name] = sample.date
            }
        }
        let span = max(1, samples.last.map { $0.date.timeIntervalSince(samples.first!.date) } ?? 1)
        let sorted = entries.sorted {
            ($0.playing || $0.recording ? 0 : 1, -(played[$0.name] ?? 0), $0.name.lowercased())
                < ($1.playing || $1.recording ? 0 : 1, -(played[$1.name] ?? 0), $1.name.lowercased())
        }
        let playingCount = entries.filter(\.playing).count
        apps.header.items = entries.isEmpty ? [] : [.init(text: playingCount == 0 ? "None playing" : "\(playingCount) playing"),
                                                     .init(text: "\(entries.count) open", faint: true)]
        let before = apps.neededHeight
        apps.set(count: sorted.count) { row, index in
            let entry = sorted[index]
            let seconds = played[entry.name] ?? 0
            row.lead = entry.icon.map { .image($0) } ?? .glyph("app", nil)
            row.name = entry.name
            if entry.recording {
                row.detail = entry.playing ? "Playing and using the microphone" : "Using the microphone"
            } else if entry.playing {
                row.detail = "Playing now"
            } else if let at = last[entry.name] {
                row.detail = "Last played at \(clock.string(from: at))"
            } else {
                row.detail = "Open, silent"
            }
            let now: A2Row.Cell.Kind = entry.recording ? .badge("Recording", "mic.fill", A2.warn)
                : entry.playing ? .badge("Playing", "speaker.wave.2.fill", A2.good) : .text("", A2.tertiary, A2.quietValueFont, .right)
            row.cells = [.init(kind: .meter(seconds / span, A2.sound, A2.soundEnd), width: 130),
                         .init(kind: .text(seconds > 0 ? Format.duration(seconds) : "–", seconds > 0 ? A2.primary : A2.tertiary,
                                           seconds > 0 ? A2.valueFont : A2.quietValueFont, .right), width: 64),
                         .init(kind: now, width: 104)]
            row.toolTip = seconds > 0 ? "\(entry.name) played for \(Format.duration(seconds)) of the last \(Format.duration(span))" : nil
        }
        if apps.neededHeight != before { relayout() }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) others"
        }
    }

    private static func muted(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectHasProperty(device, &address) && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// "Built-in · 48 kHz" and a symbol, from the device's transport and sample rate.
    private func describe(_ id: AudioObjectID, input: Bool) -> (String, String) {
        let transport = Self.property(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        let (kind, symbol): (String, String) = switch transport {
        case kAudioDeviceTransportTypeBuiltIn: ("Built-in", input ? "mic" : "speaker.wave.2")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: ("Bluetooth", "headphones")
        case kAudioDeviceTransportTypeAirPlay: ("AirPlay", "airplayaudio")
        case kAudioDeviceTransportTypeVirtual: ("Virtual", "waveform")
        case kAudioDeviceTransportTypeAggregate: ("Aggregate", "waveform")
        case kAudioDeviceTransportTypeUSB: ("USB", input ? "mic" : "hifispeaker")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: ("Display", "display")
        case kAudioDeviceTransportTypeThunderbolt: ("Thunderbolt", "hifispeaker")
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: ("Continuity", "iphone")
        default: ("Audio device", input ? "mic" : "hifispeaker")
        }
        if let cached = details[id] { return (cached, symbol) }
        var parts = [kind]
        if let rate = Self.property(id, kAudioDevicePropertyNominalSampleRate, Float64(0)), rate > 0 {
            parts.append(rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000))
        }
        let detail = parts.joined(separator: " · ")
        details[id] = detail
        return (detail, symbol)
    }

    private static func property(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: UInt32) -> UInt32? {
        var value = initial
        return read(device, selector, &value, size: UInt32(MemoryLayout<UInt32>.size)) ? value : nil
    }

    private static func property(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: Float64) -> Float64? {
        var value = initial
        return read(device, selector, &value, size: UInt32(MemoryLayout<Float64>.size)) ? value : nil
    }

    private static func read(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UnsafeMutableRawPointer, size: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = size
        return AudioObjectHasProperty(device, &address) && AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr
    }

    private func pick(_ index: Int, input: Bool) {
        let candidates = shownDevices[input] ?? []
        if candidates.indices.contains(index) { Audio.setDefaultDevice(candidates[index].id, input: input) }
        refresh()
    }

    private func setVolume(_ value: Float, input isInput: Bool) {
        if let id = Audio.defaultDevice(input: isInput) { Audio.setVolume(id, input: isInput, to: value) }
        if isInput { input.show(volume: value) } else { hero.figure.set(Double(value)) }
    }
}

// MARK: - Bluetooth

@MainActor
final class BluetoothPage: CardPage {
    override var pageTint: NSColor { PageID.bluetooth.tint }
    override var labelTint: NSColor { A2.bluetooth }
    private lazy var settingsButton = A2ToolbarButton("Bluetooth Settings…", symbol: PageID.bluetooth.symbol, tint: A2.bluetooth)
    private lazy var titleLines = heading("Bluetooth")
    // The summary: how many are connected, then either the facts and the split by kind,
    // or, before access, what the page will show and the one button that asks.
    private let hero = CardView()
    private let heroHeader = A2Header()
    private let heroState = Pill()
    private let heroFigure = A2.figure()
    private let heroSub = TextLine()
    private let heroLines = A2Lines()
    private let heroText = A2Paragraph()
    private let allow = A2Button("Allow Bluetooth Access…", primary: true)
    private let kindBar = A2CapacityBar()
    private let kindKeys = A2Keys()
    private let batteries = A2ListCard()
    private let batteriesGhost = SkeletonRows()
    private let batteriesNote = TextLine()
    private let batteriesFoot = TextLine()
    private let list = A2ListCard()
    private let listGhost = SkeletonRows()
    private let listFoot = TextLine()
    private var asking = false
    private var checkedAt = Date.distantPast
    private var access = Access.allowed
    private var listed: [BluetoothDevice] = []
    /// A narrow list drops the Kind and Last used columns and puts the kind under the name.
    private var compact: Bool?
    private lazy var ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private enum Access { case allowed, undecided, denied }

    /// WISP_BLUETOOTH_DEMO=1 lists made-up devices and =denied shows access turned off,
    /// for screenshots on a Mac where the debug build cannot be given access.
    private static let demo = ProcessInfo.processInfo.environment["WISP_BLUETOOTH_DEMO"]

    override var toolbarItems: [NSView] { [settingsButton] }

    override func loadView() {
        super.loadView()
        titleLines.1.text = Toolbar.subtitle("Paired devices and their batteries")
        for view in [hero, batteries, list] as [NSView] { canvas.addSubview(view) }
        heroHeader.title = "Bluetooth"
        heroHeader.symbol = PageID.bluetooth.symbol
        heroHeader.tint = A2.bluetooth
        heroHeader.titleColor = A2.bluetooth
        kindKeys.arrangement = .columns(4)
        heroFigure.unitGap = 6
        heroText.color = A2.secondary
        heroText.lineHeight = 16
        heroText.font = Theme.sans(12)
        for view in [heroHeader, heroState, heroFigure, heroSub, heroLines, heroText, allow, kindBar, kindKeys] as [NSView] { hero.addSubview(view) }
        batteries.header.title = "Batteries"
        batteries.header.symbol = "battery.75percent"
        batteries.header.tint = A2.bluetooth
        batteries.listGap = 8
        batteries.minRowHeight = 44
        batteries.maxRowHeight = 50
        batteries.emptyText("")
        batteries.addSubview(batteriesGhost)
        batteries.addSubview(batteriesNote)
        batteries.addSubview(batteriesFoot)
        batteriesGhost.symbols = ["keyboard", "computermouse", "headphones"]
        batteriesGhost.cells = [44]
        list.header.title = "Devices"
        list.header.symbol = "list.bullet"
        list.header.tint = A2.bluetooth
        list.showsColumns = true
        list.columns.titles("Device", [("Kind", 120, .left), ("Status", 96, .left), ("Last used", 120, .left), ("Battery", 171, .right)])
        list.listGap = 10
        list.maxRowHeight = 60
        list.minRowHeight = 46
        list.addSubview(listGhost)
        list.addSubview(listFoot)
        listGhost.symbols = ["headphones", "iphone", "keyboard", "computermouse", "hifispeaker", "applewatch"]
        listGhost.cells = [120, 96, 120, 171]
        settingsButton.onPress = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        }
        allow.onPress = { [weak self] in
            guard let self else { return }
            if self.access == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
            } else {
                self.asking = true
                self.update(system: self.delegate.system)
            }
        }
        update(system: delegate.system)
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let room = scroll.contentSize.height - Self.topInset - margin * 2
        var y = margin
        let top: CGFloat = 256
        if inner >= 760 {
            let left = ((inner - gap) * 2 / 3).rounded()
            hero.frame = NSRect(x: margin, y: y, width: left, height: top)
            batteries.frame = NSRect(x: margin + left + gap, y: y, width: inner - left - gap, height: top)
            y += top + gap
        } else {
            hero.frame = NSRect(x: margin, y: y, width: inner, height: top)
            y += top + gap
            batteries.frame = NSRect(x: margin, y: y, width: inner, height: max(176, batteries.neededHeight + 28))
            y += batteries.frame.height + gap
        }
        if compact != (inner < 760) {
            compact = inner < 760
            list.columns.titles("Device", compact! ? [("Status", 96, .left), ("Battery", 171, .right)]
                : [("Kind", 120, .left), ("Status", 96, .left), ("Last used", 120, .left), ("Battery", 171, .right)])
            listGhost.cells = compact! ? [96, 171] : [120, 96, 120, 171]
            if access == .allowed { fillList(listed) }
        }
        let ghostRows: CGFloat = 6
        let wanted = access == .allowed ? list.neededHeight + 30 : A2.padTop + 16 + 10 + 26 + ghostRows * 52 + 30 + A2.padTop
        list.frame = NSRect(x: margin, y: y, width: inner, height: max(wanted, room - (y - margin)))
        placeHero()
        let listTop = A2.padTop + 16 + list.listGap + 26
        listFoot.frame = NSRect(x: A2.padSide, y: list.bounds.height - A2.padTop - 14, width: list.bounds.width - A2.padSide * 2, height: 14)
        listGhost.frame = NSRect(x: A2.padSide, y: listTop, width: list.bounds.width - A2.padSide * 2, height: listFoot.frame.minY - 12 - listTop)
        listGhost.count = Int(listGhost.frame.height / listGhost.rowHeight)
        list.maxRowHeight = min(60, max(list.minRowHeight, ((listFoot.frame.minY - 10 - listTop) / CGFloat(max(1, list.rows.filter { !$0.isHidden }.count))).rounded(.down)))
        let batteriesTop = A2.padTop + 16 + batteries.listGap
        batteriesGhost.frame = NSRect(x: A2.padSide, y: batteriesTop + 34, width: batteries.bounds.width - A2.padSide * 2,
                                      height: batteries.bounds.height - batteriesTop - 34 - A2.padTop)
        batteriesGhost.count = Int(batteriesGhost.frame.height / batteriesGhost.rowHeight)
        batteriesFoot.frame = NSRect(x: A2.padSide, y: batteries.bounds.height - A2.padTop - 14, width: batteries.bounds.width - A2.padSide * 2, height: 14)
        batteriesFoot.isHidden = batteries.rows.filter { !$0.isHidden }.count > 3 || access != .allowed
        batteriesNote.frame = NSRect(x: A2.padSide, y: batteriesTop + 2, width: batteries.bounds.width - A2.padSide * 2, height: 32)
        return list.frame.maxY + margin
    }

    private func placeHero() {
        let inner = hero.bounds.width - A2.padSide * 2, height = hero.bounds.height
        heroHeader.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        heroState.frame = NSRect(x: A2.padSide + heroHeader.titleRight + 10, y: 13, width: heroState.naturalWidth, height: 18)
        heroFigure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        heroSub.frame = NSRect(x: A2.padSide, y: 81, width: inner, height: 15)
        let keysHeight = A2Keys.keyHeight
        kindKeys.frame = NSRect(x: A2.padSide, y: height - A2.padTop - keysHeight, width: inner, height: keysHeight)
        kindBar.frame = NSRect(x: A2.padSide, y: kindKeys.frame.minY - 10 - 8, width: inner, height: 8)
        heroLines.frame = NSRect(x: A2.padSide, y: 108, width: inner, height: kindBar.frame.minY - 16 - 108)
        let buttonWidth = allow.naturalWidth
        allow.frame = NSRect(x: A2.padSide, y: kindBar.frame.minY - 16 - 30, width: buttonWidth, height: 30)
        heroText.frame = NSRect(x: A2.padSide, y: 104, width: min(inner, 640), height: allow.frame.minY - 8 - 104)
    }

    override func update(system: SystemSnapshot) {
        guard Date().timeIntervalSince(checkedAt) > 10 || asking else { return }
        checkedAt = Date()
        if Self.demo == "denied" {
            access = .denied
        } else if Self.demo == "1" || Bluetooth.allowed {
            access = .allowed
        } else {
            access = Bluetooth.undecided ? .undecided : .denied
        }
        // Reading the list is what raises the system prompt, so it waits for the button.
        let devices = Self.demo == "1" ? Self.demoDevices : access == .allowed || asking ? Bluetooth.devices(asking: asking) : []
        asking = false
        if access == .allowed || !devices.isEmpty {
            access = .allowed
            showDevices(devices)
        } else {
            showLocked()
        }
        relayout()
    }

    // MARK: Before access

    private func showLocked() {
        let denied = access == .denied
        titleLines.1.variants = [denied ? "Bluetooth access is off for Wisp" : "Allow access to list paired devices and their batteries",
                                 "Paired devices and their batteries", ""].map(Toolbar.subtitle)
        heroState.isHidden = false
        heroState.text = denied ? "Access off" : "Not asked yet"
        heroState.tone = denied ? .warn : .neutral
        heroState.dot = false
        heroState.symbol = denied ? "lock.fill" : nil
        heroFigure.show("No access")
        heroSub.text = A2.plain(denied ? "Bluetooth access for Wisp is turned off in Privacy & Security"
            : "macOS asks once before an app can see Bluetooth devices")
        heroText.text = "With access, Wisp lists every paired device, whether it is connected, when it was last used and the charge of "
            + "those that report one. It only reads; it never pairs, connects or changes a device."
        heroText.isHidden = false
        heroLines.isHidden = true
        allow.title = denied ? "Open Privacy & Security…" : "Allow Bluetooth Access…"
        allow.isHidden = false
        // The split by kind it will draw, as a placeholder in the same place.
        kindBar.parts = [0.4, 0.25, 0.2, 0.15].map { .init(amount: $0, color: A2.track) }
        kindKeys.keys = ["Headphones", "Keyboards", "Mice", "Phones"].map { .init(label: $0, value: "–", color: A2.track) }

        let accessories = Self.demo == nil ? Accessories.batteries() : []
        showBatteries(accessories.map { ($0.name, $0.percent, "keyboard") }, locked: true)

        list.header.items = [.init(text: denied ? "Turned off" : "Waiting for access", faint: true)]
        list.set(count: 0) { _, _ in }
        list.empty.isHidden = true
        listGhost.isHidden = false
        listFoot.text = NSAttributedString(string: denied ? "Turn Wisp on under Privacy & Security, Bluetooth, then come back to this page"
            : "Your paired devices take these rows once access is allowed", attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
    }

    // MARK: With access

    private func showDevices(_ devices: [BluetoothDevice]) {
        let connected = devices.filter(\.connected)
        let away = devices.count - connected.count
        let reporting = devices.filter { $0.connected && $0.battery != nil }
        let low = reporting.filter { ($0.battery ?? 100) <= 20 }
        titleLines.1.variants = ["Paired devices and their batteries · \(connected.count) connected, \(away) away",
                                 "\(connected.count) connected, \(away) away", ""].map(Toolbar.subtitle)
        heroState.isHidden = low.isEmpty
        heroState.text = low.count == 1 ? "Low battery" : "\(low.count) low batteries"
        heroState.tone = .warn
        heroState.symbol = "battery.25percent"
        heroFigure.show("\(connected.count)", unit: "connected")
        heroSub.text = A2.plain(devices.isEmpty ? "No paired devices" : "\(devices.count) paired · \(away) away")
        heroText.isHidden = true
        allow.isHidden = true
        heroLines.isHidden = false
        let lowest = reporting.min { ($0.battery ?? 100) < ($1.battery ?? 100) }
        let recent = devices.filter { !$0.connected && $0.lastUsed != nil }.max { $0.lastUsed! < $1.lastUsed! }
        heroLines.lines = [
            .init(label: "Lowest battery", value: lowest.map { "\($0.name) · \($0.battery ?? 0)%" } ?? "None reported",
                  color: lowest.map { ($0.battery ?? 100) <= 20 ? A2.warn : nil } ?? A2.tertiary),
            .init(label: "Last used of those away", value: recent.map { "\($0.name) · \(ago.localizedString(for: $0.lastUsed!, relativeTo: Date()))" } ?? "–"),
        ]
        // Paired devices by kind, the most common first.
        let palette = [A2.bluetooth, A2.teal, A2.memoryApp, A2.neural, A2.gpu, A2.diskSystem]
        var counts: [String: Int] = [:]
        for device in devices { counts[Self.plural(device.kind), default: 0] += 1 }
        let kinds = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let shown = Array(kinds.prefix(3)) + (kinds.count > 3 ? [("Other", kinds.dropFirst(3).reduce(0) { $0 + $1.value })] : [])
        kindBar.parts = shown.enumerated().map { .init(amount: Double($0.element.1), color: palette[$0.offset % palette.count]) }
        kindKeys.keys = shown.enumerated().map { .init(label: $0.element.0, value: "\($0.element.1)", color: palette[$0.offset % palette.count]) }

        showBatteries(reporting.map { ($0.name, $0.battery ?? 0, Self.symbol($0.kind)) }, locked: false)

        listGhost.isHidden = !devices.isEmpty
        listGhost.count = devices.isEmpty ? 3 : 0
        list.empty.isHidden = true
        list.header.items = devices.isEmpty ? [] : [.init(text: "\(connected.count) connected"), .init(text: "\(away) away", faint: true)]
        listFoot.text = NSAttributedString(string: devices.isEmpty ? "Pair a device in Bluetooth Settings and it appears here"
            : "Hover a device for its address · pair or forget devices in Bluetooth Settings", attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
        listed = devices
        fillList(devices)
    }

    private func fillList(_ devices: [BluetoothDevice]) {
        let compact = self.compact ?? false
        list.set(count: devices.count) { row, index in
            let device = devices[index]
            row.lead = .glyph(Self.symbol(device.kind), device.connected ? A2.bluetooth : nil)
            row.leadSize = 26
            row.name = device.name
            row.nameColor = device.connected ? A2.primary : A2.secondary
            row.toolTip = "\(device.name) · \(device.kind)" + (device.address.isEmpty ? "" : " · \(device.address)")
            let used = device.connected ? "Now" : device.lastUsed.map { ago.localizedString(for: $0, relativeTo: Date()) } ?? "Not known"
            let when = device.connected ? " · in use now" : device.lastUsed == nil ? "" : " · last used \(used)"
            row.detail = compact ? device.kind + when : ""
            var cells: [A2Row.Cell] = compact ? [.init(kind: .status(device.connected ? "Connected" : "Away", A2.good, device.connected), width: 96)]
                : [.init(kind: .text(device.kind, A2.secondary, A2.quietValueFont, .left), width: 120),
                   .init(kind: .status(device.connected ? "Connected" : "Away", A2.good, device.connected), width: 96),
                   .init(kind: .text(used, device.connected ? A2.primary : A2.secondary, A2.quietValueFont, .left), width: 120)]
            if let battery = device.battery, device.connected {
                cells += [.init(kind: .meter(Double(battery) / 100, battery <= 20 ? A2.warn : A2.charge, battery <= 20 ? nil : A2.chargeEnd), width: 106),
                          .init(kind: .text("\(battery)%", battery <= 20 ? A2.warn : A2.primary, A2.valueFont, .right), width: 54)]
            } else {
                cells.append(.init(kind: .text(device.connected ? "Not reported" : "–", A2.tertiary, A2.quietValueFont, .right), width: 171))
            }
            row.cells = cells
            row.spokenNote = device.connected && (device.battery ?? 100) <= 20 ? "Low battery" : ""
        }
    }

    private func showBatteries(_ items: [(name: String, percent: Int, symbol: String)], locked: Bool) {
        batteries.header.items = items.isEmpty ? [] : [.init(text: items.count == 1 ? "1 reports" : "\(items.count) report", faint: true)]
        batteries.set(count: items.count) { row, index in
            let item = items[index]
            let low = item.percent <= 20
            row.lead = .glyph(item.symbol, A2.bluetooth)
            row.leadSize = 26
            row.name = item.name
            row.meterBelow = Double(item.percent) / 100
            row.meterColor = low ? A2.warn : A2.charge
            row.meterEnd = low ? nil : A2.chargeEnd
            row.cells = [.init(kind: .text("\(item.percent)%", low ? A2.warn : A2.primary, A2.valueFont, .right), width: 44)]
            row.spokenNote = low ? "Low" : ""
        }
        batteriesNote.isHidden = !items.isEmpty
        batteriesFoot.text = NSAttributedString(string: items.isEmpty ? "" : "Read every 10 seconds · low at 20% or less",
                                                attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
        batteriesGhost.isHidden = !items.isEmpty
        let text = NSMutableAttributedString(string: locked ? "Keyboards, mice and trackpads show here without access\n"
            : "No connected device reports its battery\n", attributes: [.font: Theme.sans(12, .medium), .foregroundColor: A2.secondary])
        text.append(NSAttributedString(string: locked ? "None is connected now; headphones need access" : "Headphones and accessories show here while connected",
                                       attributes: [.font: Theme.sans(11), .foregroundColor: A2.tertiary]))
        batteriesNote.text = text
    }

    private static func plural(_ kind: String) -> String {
        ["Headphones": "Headphones", "Phone": "Phones", "Keyboard": "Keyboards", "Mouse": "Mice", "Computer": "Computers",
         "Keyboard and mouse": "Keyboards", "Input device": "Input devices", "Wearable": "Wearables", "Device": "Other"][kind] ?? kind
    }

    static func symbol(_ kind: String) -> String {
        ["Headphones": "headphones", "Phone": "iphone", "Keyboard": "keyboard", "Mouse": "computermouse",
         "Computer": "laptopcomputer", "Wearable": "applewatch"][kind] ?? "dot.radiowaves.left.and.right"
    }

    private static var demoDevices: [BluetoothDevice] {
        let day: TimeInterval = 86400
        return [
            .init(name: "AirPods Pro", address: "70-AE-2A-00-00-01", connected: true, kind: "Headphones", battery: 64),
            .init(name: "Magic Keyboard", address: "70-AE-2A-00-00-02", connected: true, kind: "Keyboard", battery: 82),
            .init(name: "Magic Mouse", address: "70-AE-2A-00-00-03", connected: true, kind: "Mouse", battery: 14),
            .init(name: "iPhone", address: "70-AE-2A-00-00-04", connected: true, kind: "Phone", battery: nil),
            .init(name: "AirPods Max", address: "70-AE-2A-00-00-05", connected: false, kind: "Headphones", battery: nil,
                  lastUsed: Date().addingTimeInterval(-2 * day)),
            .init(name: "Bedroom speaker", address: "70-AE-2A-00-00-06", connected: false, kind: "Device", battery: nil,
                  lastUsed: Date().addingTimeInterval(-9 * day)),
            .init(name: "Beats Flex", address: "70-AE-2A-00-00-07", connected: false, kind: "Headphones", battery: nil,
                  lastUsed: Date().addingTimeInterval(-40 * day)),
        ]
    }
}
