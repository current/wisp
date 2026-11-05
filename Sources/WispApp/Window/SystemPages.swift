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
        let colors = [A2.good, Theme.dynamic(0xE6A700, 0xFFD60A), A2.warn, A2.bad]
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

@MainActor
final class NeuralPage: MachinePage {
    private let now = Tile("Power now"), average = Tile("Average"), peak = Tile("Peak")
    private let about = CardView()
    private let aboutLabel = TextLine()
    private let aboutTitle = TextLine()
    private let aboutDetail = A2Paragraph()
    private var ring = RecentRing(capacity: HistoryStore.recentSamples)

    override var chartTint: NSColor { A2.neural }
    override var labelTint: NSColor { A2.neuralLabel }

    override func setUp() {
        hero.range.items = ["Live"]
        hero.chart.format = { String(format: $0 >= 1 || $0 == 0 ? "%.0f W" : "%.1f W", $0) }
        hero.chart.minimumCeiling = 1
        hero.figure.format = { (String(format: $0 >= 1 ? "%.1f" : "%.2f", $0), "W") }
        tiles = [now, average, peak]
        showsTable = false
        canvas.addSubview(about)
        aboutLabel.text = A2.title("Apps", symbol: PageID.apps.symbol, tint: labelTint, size: 12, color: A2.secondary)
        aboutTitle.text = NSAttributedString(string: "macOS does not say which app is using it",
                                             attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: A2.primary])
        aboutDetail.text = "Live Text, Dictation and Core ML models show up here as power, not by app name."
        for view in [aboutLabel, aboutTitle, aboutDetail] as [NSView] { about.addSubview(view) }
        subtitle([Self.chip])
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = margin
        let wide = inner >= 760
        let tilesHeight: CGFloat = wide ? 112 : 112 * 2 + gap
        hero.frame = NSRect(x: margin, y: y, width: inner, height: max(300, room - tilesHeight - gap))
        y = hero.frame.maxY + gap
        if wide {
            row(tiles + [about], weights: [1, 1, 1, 2], y: y, height: 112, width: width)
            y += 112
        } else {
            row(tiles, weights: [1, 1, 1], y: y, height: 112, width: width)
            about.frame = NSRect(x: margin, y: y + 112 + gap, width: inner, height: 112)
            y += tilesHeight
        }
        let aboutWidth = about.bounds.width - A2.padSide * 2
        aboutLabel.frame = NSRect(x: A2.padSide, y: 13, width: aboutWidth, height: 16)
        let detailHeight = min(32, aboutDetail.height(for: aboutWidth))
        aboutDetail.frame = NSRect(x: A2.padSide, y: about.bounds.height - 13 - detailHeight, width: aboutWidth, height: detailHeight)
        aboutTitle.frame = NSRect(x: A2.padSide, y: aboutDetail.frame.minY - 5 - 17, width: aboutWidth, height: 17)
        return y + margin
    }

    override func refreshChart(force: Bool) {
        hero.chart.step = delegate.settings.interval
        hero.chart.primary = ring.values
        let top = Self.peak(ring.values)
        hero.chart.ceiling = Float(ChartScale.ceiling(peak: Double(top), minimum: 1))
        showPeak(String(format: "%.2f W", top))
    }

    override func update(system s: SystemSnapshot) {
        guard let p = s.power else {
            hero.figure.show("–")
            hero.meta.text = A2.plain("Chip power is not readable on this Mac")
            return
        }
        let watts = p.ane ?? 0
        ring.append(Float(watts))
        refreshChart(force: false)
        hero.figure.set(watts)
        hero.meta.text = A2.plain(watts > 0.01 ? "In use · macOS does not say which app is using it" : "Idle · nothing is running models on it now")
        hero.needsLayout = true
        let values = ring.values
        now.set(text: String(format: "%.2f", watts), unit: "W")
        now.set(note: "Right now")
        average.set(text: String(format: "%.2f", Double(values.reduce(0, +)) / Double(max(values.count, 1))), unit: "W")
        average.set(note: "In the chart above")
        peak.set(text: String(format: "%.2f", Double(values.max() ?? 0)), unit: "W")
        peak.set(note: "In the chart above")
    }

    override func update(table: ProcessTable) {}
}

// MARK: - Sound

/// One default device: its volume as a figure with a slider, its name, and the devices
/// it can switch to, the current one ticked.
final class DeviceCard: CardView {
    let header = A2Header()
    let level = A2.figure()
    let slider = A2Slider()
    let current = TextLine()
    private let quiet = DrawnGlyph()
    private let loud = DrawnGlyph()
    private(set) var rows: [A2Row] = []
    var onPick: ((Int) -> Void)?

    init(input: Bool) {
        super.init()
        header.title = input ? "Input" : "Output"
        header.symbol = input ? "mic" : PageID.sound.symbol
        header.tint = A2.sound
        header.titleColor = A2.sound
        quiet.symbol = input ? "mic" : "speaker.fill"
        loud.symbol = input ? "mic" : "speaker.wave.2"
        for view in [header, level, slider, current, quiet, loud] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(volume: Float?) {
        if let volume { level.show(String(format: "%.0f", volume * 100), unit: "%") } else { level.show("Fixed") }
        slider.isEnabled = volume != nil
        if let volume, !slider.dragging { slider.value = volume }
    }

    struct Device {
        var name: String
        var detail: String
        var symbol: String
        var chosen: Bool
    }

    func show(devices: [Device]) {
        while rows.count < devices.count {
            let row = A2Row()
            let index = rows.count
            row.onClick = { [weak self] in self?.onPick?(index) }
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= devices.count
            guard index < devices.count else { continue }
            let device = devices[index]
            row.lead = .glyph(device.symbol, nil)
            row.name = device.name
            row.detail = device.detail
            row.cells = [.init(kind: device.chosen ? .check : .text("", A2.secondary, A2.detailFont, .left), width: 16)]
            row.showsRule = index > 0
        }
        header.items = [.init(text: devices.count == 1 ? "1 device" : "\(devices.count) devices", faint: true)]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        level.frame = A2.figureFrame(x: A2.padSide, baseline: 71, width: 92)
        let sliderX = A2.padSide + 92 + 14
        quiet.frame = NSRect(x: sliderX, y: 52, width: 14, height: 14)
        loud.frame = NSRect(x: bounds.width - A2.padSide - 14, y: 52, width: 14, height: 14)
        slider.frame = NSRect(x: quiet.frame.maxX + 9 - 12, y: 47, width: loud.frame.minX - 9 - quiet.frame.maxX - 9 + 24, height: 24)
        current.frame = NSRect(x: A2.padSide, y: 82, width: inner, height: 15)
        let top: CGFloat = 106, shown = rows.filter { !$0.isHidden }
        let pitch = min(76, ((bounds.height - top - A2.padTop) / CGFloat(max(1, shown.count))).rounded(.down))
        for (index, row) in shown.enumerated() { row.frame = NSRect(x: A2.padSide, y: top + CGFloat(index) * pitch, width: inner, height: pitch) }
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
    private let output = DeviceCard(input: false)
    private let input = DeviceCard(input: true)
    private let apps = A2ListCard()
    private lazy var titleLines = heading("Sound")
    private var caption: TextLine { titleLines.1 }
    private var checkedAt = Date.distantPast
    private var devices: [AudioDevice] = []
    private var shownDevices: [Bool: [AudioDevice]] = [:]
    /// Transport and sample rate per device, read once per device and every ten seconds.
    private var details: [AudioObjectID: String] = [:]
    private var detailsAt = Date.distantPast
    private var shownRows = -1

    override func loadView() {
        super.loadView()
        _ = titleLines
        for view in [output, input, apps] as [NSView] { canvas.addSubview(view) }
        apps.header.title = "Apps with sound open"
        apps.listGap = 6
        apps.maxRowHeight = 58
        apps.emptyText("No app has sound open")
        for (card, isInput) in [(output, false), (input, true)] {
            card.slider.onChange = { [weak self] value in self?.setVolume(value, input: isInput) }
            card.onPick = { [weak self] index in self?.pick(index, input: isInput) }
        }
        refresh()
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let room = scroll.contentSize.height - Self.topInset - margin * 2
        var y = margin
        // 48 pt a device row. Side by side, both cards take the longer list's height.
        let shown = { (card: DeviceCard) in CGFloat(max(2, card.rows.filter { !$0.isHidden }.count)) }
        let height = { (rows: CGFloat) in 106 + A2.padTop + 48 * rows }
        if inner >= 700 {
            let deviceHeight = height(max(3, shown(output), shown(input)))
            let half = ((inner - gap) / 2).rounded()
            output.frame = NSRect(x: margin, y: y, width: half, height: deviceHeight)
            input.frame = NSRect(x: margin + half + gap, y: y, width: inner - half - gap, height: deviceHeight)
            y += deviceHeight + gap
        } else {
            for card in [output, input] {
                card.frame = NSRect(x: margin, y: y, width: inner, height: height(shown(card)))
                y = card.frame.maxY + gap
            }
        }
        let left = room - (y - margin)
        apps.frame = NSRect(x: margin, y: y, width: inner, height: min(apps.fullHeight, max(apps.neededHeight, left)))
        return apps.frame.maxY + margin
    }

    override func update(system: SystemSnapshot) {
        if Date().timeIntervalSince(checkedAt) >= 2 { refresh() }
    }

    private func refresh() {
        checkedAt = Date()
        devices = Audio.devices()
        if Date().timeIntervalSince(detailsAt) > 10 {
            detailsAt = Date()
            details = [:]
        }
        for (card, isInput) in [(output, false), (input, true)] {
            let current = Audio.defaultDevice(input: isInput)
            // The device in use first, then the rest by name.
            let candidates = devices.filter { isInput ? $0.hasInput : $0.hasOutput }
                .sorted { ($0.id == current ? 0 : 1, $0.name) < ($1.id == current ? 0 : 1, $1.name) }
            shownDevices[isInput] = candidates
            card.show(devices: candidates.map { device in
                let (detail, symbol) = describe(device.id, input: isInput)
                return .init(name: device.name, detail: detail, symbol: symbol, chosen: device.id == current)
            })
            card.current.text = A2.plain(candidates.first { $0.id == current }?.name ?? "No device")
            card.show(volume: current.flatMap { Audio.volume($0, input: isInput) })
        }
        let deviceRows = output.rows.filter { !$0.isHidden }.count + input.rows.filter { !$0.isHidden }.count * 100
        if deviceRows != shownRows {
            shownRows = deviceRows
            relayout()
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
        let sorted = byApp.values.sorted { ($0.playing || $0.recording ? 0 : 1, $0.name) < ($1.playing || $1.recording ? 0 : 1, $1.name) }
        let playing = sorted.filter(\.playing).count
        caption.variants = ["\(sorted.count) app\(sorted.count == 1 ? "" : "s") with sound open · \(playing == 0 ? "none" : "\(playing)") playing", ""]
            .map(Toolbar.subtitle)
        let before = apps.neededHeight
        apps.set(count: sorted.count) { row, index in
            let entry = sorted[index]
            row.lead = entry.icon.map { .image($0) } ?? .glyph("app", nil)
            row.name = entry.name
            row.detail = entry.recording && entry.playing ? "Using the microphone" : ""
            row.inline = true
            let status: A2Row.Cell.Kind = entry.playing ? .badge("Playing", "speaker.wave.2.fill", A2.good)
                : entry.recording ? .badge("Recording", "mic.fill", A2.bad) : .text("Silent", A2.tertiary, Theme.sans(12, .medium), .right)
            row.cells = [.init(kind: status, width: 110)]
        }
        if apps.neededHeight != before { relayout() }
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
        (isInput ? input : output).show(volume: value)
    }
}

// MARK: - Bluetooth

@MainActor
final class BluetoothPage: CardPage {
    override var pageTint: NSColor { PageID.bluetooth.tint }
    override var labelTint: NSColor { A2.bluetooth }
    private lazy var settingsButton = A2ToolbarButton("Bluetooth Settings…", symbol: PageID.bluetooth.symbol, tint: A2.bluetooth)
    /// Asks macOS for Bluetooth access, shown in the device list until it is decided.
    private let allow = A2PillButton()
    private var asking = false
    private var batteryCards: [BatteryCard] = []
    private let list = A2ListCard()
    private var checkedAt = Date.distantPast
    private lazy var titleLines = heading("Bluetooth")

    override var toolbarItems: [NSView] { [settingsButton] }

    override func loadView() {
        super.loadView()
        titleLines.1.text = Toolbar.subtitle("Paired devices and their batteries")
        canvas.addSubview(list)
        list.header.title = "Devices"
        list.showsColumns = true
        list.columns.titles("Device", [("Kind", 120, .left), ("Status", 110, .left), ("Battery", 171, .right)])
        list.listGap = 10
        list.maxRowHeight = 64
        list.minRowHeight = 44
        settingsButton.onPress = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        }
        allow.title = "Allow…"
        allow.isHidden = true
        list.addSubview(allow)
        allow.onPress = { [weak self] in
            guard let self else { return }
            self.asking = true
            self.update(system: self.delegate.system)
        }
        list.emptyText(Bluetooth.allowed ? "No paired devices" : "Wisp asks macOS once, then lists your devices and their batteries")
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let room = scroll.contentSize.height - Self.topInset - margin * 2
        var y = margin
        let shown = batteryCards.filter { !$0.isHidden }
        if !shown.isEmpty {
            let columns = inner >= 760 ? 3 : min(2, shown.count)
            let cell = ((inner - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            for (index, card) in shown.enumerated() {
                card.frame = NSRect(x: margin + CGFloat(index % columns) * (cell + gap), y: y + CGFloat(index / columns) * (210 + gap),
                                    width: cell, height: 210)
            }
            let rows = (shown.count + columns - 1) / columns
            y += CGFloat(rows) * (210 + gap)
        }
        let left = room - (y - margin)
        list.frame = NSRect(x: margin, y: y, width: inner, height: min(list.fullHeight, max(list.neededHeight, left)))
        let size = allow.naturalWidth
        allow.frame = NSRect(x: (inner - size) / 2, y: list.empty.frame.maxY + 10, width: size, height: 26)
        return list.frame.maxY + margin
    }

    override func update(system: SystemSnapshot) {
        guard Date().timeIntervalSince(checkedAt) > 10 || asking else { return }
        checkedAt = Date()
        allow.isHidden = !Bluetooth.undecided
        if Bluetooth.undecided, !asking {
            list.showsColumns = false
            list.set(count: 0) { _, _ in }
            list.emptyText("Wisp asks macOS once, then lists your devices and their batteries")
            relayout()
            return
        }
        let devices = Bluetooth.devices(asking: asking)
        asking = false
        let connected = devices.filter(\.connected)
        let batteries = connected.filter { $0.battery != nil }
        titleLines.1.variants = ["Paired devices and their batteries · \(connected.count) connected, \(devices.count - connected.count) away",
                                 "\(connected.count) connected, \(devices.count - connected.count) away", ""].map(Toolbar.subtitle)
        while batteryCards.count < min(3, batteries.count) {
            let card = BatteryCard()
            canvas.addSubview(card)
            batteryCards.append(card)
        }
        for (index, card) in batteryCards.enumerated() {
            card.isHidden = index >= batteries.count
            if index < batteries.count { card.show(batteries[index], symbol: Self.symbol(batteries[index].kind)) }
        }
        list.header.items = devices.isEmpty ? [] : [.init(text: "\(connected.count) connected"),
                                                   .init(text: batteries.count == 1 ? "1 reports a battery" : "\(batteries.count) report a battery"),
                                                   .init(text: "\(devices.count - connected.count) paired, away")]
        list.emptyText(Bluetooth.allowed ? "No paired devices" : "Wisp needs Bluetooth access to list devices")
        list.showsColumns = !devices.isEmpty
        list.set(count: devices.count) { row, index in
            let device = devices[index]
            row.lead = .glyph(Self.symbol(device.kind), nil)
            row.leadSize = 26
            row.name = device.name
            row.nameColor = device.connected ? A2.primary : A2.secondary
            var cells: [A2Row.Cell] = [.init(kind: .text(device.kind, A2.secondary, A2.quietValueFont, .left), width: 120),
                                       .init(kind: .status(device.connected ? "Connected" : "Away", A2.good, device.connected), width: 110)]
            if let battery = device.battery {
                cells += [.init(kind: .meter(Double(battery) / 100, battery <= 15 ? A2.bad : A2.charge, battery <= 15 ? nil : A2.chargeEnd), width: 106),
                          .init(kind: .text("\(battery)%", A2.primary, A2.valueFont, .right), width: 54)]
            } else {
                cells.append(.init(kind: .text(device.connected ? "Not reported" : "Away", A2.tertiary, A2.quietValueFont, .right), width: 171))
            }
            row.cells = cells
        }
        relayout()
    }

    static func symbol(_ kind: String) -> String {
        ["Headphones": "headphones", "Phone": "iphone", "Keyboard": "keyboard", "Mouse": "computermouse",
         "Computer": "laptopcomputer"][kind] ?? "dot.radiowaves.left.and.right"
    }
}

/// A connected device that reports its battery: the charge, a bar, and what it is.
final class BatteryCard: CardView {
    private let header = A2Header()
    private let figure = A2.figure()
    private let sub = TextLine()
    private let bar = A2CapacityBar()
    private let rule = A2Hairline()
    private let keys = A2Keys()

    override init() {
        super.init()
        header.tint = A2.bluetooth
        header.titleColor = A2.bluetooth
        header.size = 12
        header.iconSize = 14
        figure.format = { (String(format: "%.0f", $0), "%") }
        keys.arrangement = .columns(3)
        for view in [header, figure, sub, bar, rule, keys] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ device: BluetoothDevice, symbol: String) {
        let battery = device.battery ?? 0
        header.symbol = symbol
        header.title = device.name
        figure.set(Double(battery))
        sub.text = A2.facts([.init(label: "Battery", value: device.connected ? "Connected" : "Away")])
        let low = battery <= 15
        bar.parts = [.init(amount: Double(battery), color: low ? A2.bad : A2.charge), .init(amount: Double(100 - battery), color: A2.track)]
        keys.keys = [.init(label: "Kind", value: device.kind, color: nil),
                     .init(label: "Status", value: device.connected ? "Connected" : "Away", color: nil)]
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        sub.frame = NSRect(x: A2.padSide, y: 81, width: inner, height: 15)
        let keysHeight = keys.naturalHeight
        keys.frame = NSRect(x: A2.padSide, y: bounds.height - A2.padTop - keysHeight, width: inner, height: keysHeight)
        rule.frame = NSRect(x: A2.padSide, y: keys.frame.minY - 12 - 1, width: inner, height: 1)
        bar.frame = NSRect(x: A2.padSide, y: rule.frame.minY - 14 - 8, width: inner, height: 8)
    }
}
