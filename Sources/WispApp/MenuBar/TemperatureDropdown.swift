import AppKit
import WispCore

/// The Temperature item's dropdown: the CPU and GPU over the last few minutes as the
/// Sensors page charts them, then the sensors by group (the hottest reading of each, on
/// a slim bar; hovering a group lists its readings) and the fans' speeds. The title's
/// figure is the CPU reading the menu bar shows, which can sit below the hottest core.
@MainActor
final class TemperatureDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart = TimeChart()
    private let sensors = SoftCard()
    private let fans = SoftCard()
    /// The GPU's readings while the dropdown is open; the CPU's come from the history.
    private var gpuRing = RecentRing(capacity: HistoryStore.recentSamples)
    private static let groupLimit = 6

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.temperature.title, page: .sensors)
        plate.title = "This Mac"
        chart.edgeToEdge = true
        chart.primaryColor = A2.cpu
        chart.secondaryColor = A2.gpu
        // The GPU's line starts when the dropdown opens; filled, its first point would
        // leave a hard edge in the middle of the chart.
        chart.secondaryFill = 0
        chart.names = ("CPU", "GPU")
        chart.format = { Format.celsius(Double($0)) }
        chart.edgeClip = SoftCard.chartClip
        history.chart = chart
        history.chartHeight = 104
        for card in [history, sensors, fans] { addSubview(card) }
        update(delegate.system, history: delegate.monitor.history)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        gpuRing = RecentRing(capacity: HistoryStore.recentSamples)
        update(delegate.system, history: delegate.monitor.history)
    }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        guard let t = s.thermal, !t.sensors.isEmpty || t.cpuCelsius != nil else {
            head.status = .init(dot: A2Dev.quiet, lines: ["No readings yet"])
            plate.count = ""
            plate.footer = ""
            for card in [history, sensors, fans] { card.isHidden = true }
            showEmpty("This Mac reports no temperatures yet.")
            arrange([])
            return
        }
        showEmpty(nil)
        gpuRing.append(Float(t.gpuCelsius ?? .nan))
        showHistory(t, store: store)
        showSensors(t)
        showFans(t)
        head.status = Self.status(t)
        let fanCount = t.fans.isEmpty ? "" : t.fans.count == 1 ? ", 1 fan" : ", \(t.fans.count) fans"
        plate.count = "\(t.sensors.count) sensors" + fanCount
        plate.footer = "Hover a group for its readings."
        arrange([history, sensors, fans].filter { !$0.isHidden })
    }

    private func showHistory(_ t: ThermalReading, store: HistoryStore) {
        chart.step = delegate.settings.interval
        chart.primary = store.recent(.cpuTemperature)
        chart.secondary = gpuRing.values
        // Round tens, with the lines in the upper half of the card where the readings sit,
        // as the Sensors page does.
        let values = (chart.primary + chart.secondary).filter { !$0.isNaN && $0 > 0 }
        let high = values.max() ?? 70, low = values.min() ?? 30
        let top = max(30, ceil((high + 2) / 10) * 10)
        var bottom = top - 40
        while bottom > 0, bottom > low - 2 { bottom -= 20 }
        chart.ceiling = top
        chart.bottom = max(0, bottom)
        let minutes = Int((Double(HistoryStore.recentSamples) * delegate.settings.interval / 60).rounded())
        var parts: [String] = []
        if let cpu = t.cpuCelsius { parts.append("CPU \(Format.celsius(cpu))") }
        if let gpu = t.gpuCelsius { parts.append("GPU \(Format.celsius(gpu))") }
        history.isHidden = false
        history.show(mark: .glyph(PageID.sensors.symbol, A2.labelTint(.sensors)), title: "CPU and GPU",
                     meta: "Last \(minutes) minutes", metaHover: parts.joined(separator: ", "),
                     tag: t.cpuCelsius.map { Format.celsius($0) }, lines: [])
    }

    private func showSensors(_ t: ThermalReading) {
        let groups = SensorsCardPage.groups(t.sensors)
        sensors.isHidden = groups.isEmpty
        let hottest = t.sensors.max { $0.celsius < $1.celsius }
        sensors.show(mark: .glyph("sensor", A2.labelTint(.energy)), title: "Sensors",
                     meta: hottest.map { "Hottest: \($0.name)" } ?? "",
                     lines: groups.prefix(Self.groupLimit).map { group in
                         let top = group.values.max() ?? 0
                         let readings = group.values.sorted(by: >).map { Format.celsius($0) }
                         return SoftCard.Line(label: group.name, fraction: top / 105, color: Self.heat(top), figure: Format.celsius(top),
                                              detail: group.values.count == 1 ? "1 sensor" : "Hottest of \(group.values.count)",
                                              hover: readings.count > 1 ? readings.joined(separator: " ") : nil)
                     })
    }

    private func showFans(_ t: ThermalReading) {
        fans.isHidden = t.fans.isEmpty
        guard !t.fans.isEmpty else { return }
        let spinning = t.fans.filter { $0.rpm > 1 }.count
        fans.show(mark: .glyph("fan", A2.labelTint(.cpu)), title: t.fans.count == 1 ? "Fan" : "Fans",
                  meta: spinning == 0 ? (t.fans.count == 1 ? "Off" : "All off") : spinning == t.fans.count ? "Spinning" : "\(spinning) spinning",
                  lines: t.fans.map { fan in
                      let top = fan.maxRPM ?? 6000
                      let fraction = fan.rpm > 1 ? min(1, fan.rpm / max(top, 1)) : 0
                      let range = fan.minRPM.flatMap { low in fan.maxRPM.map { "\(Self.rpm(low)) to \(Self.rpm($0)) rpm" } }
                      return SoftCard.Line(label: t.fans.count == 1 ? "Speed" : "Fan \(fan.index + 1)", fraction: fraction,
                                           color: fraction >= 0.8 ? A2.power : A2.cpu, figure: Format.percent(fraction),
                                           detail: fan.rpm > 1 ? "\(Self.rpm(fan.rpm)) rpm" : "Off", hover: range)
                  })
    }

    /// A reading's bar colour: calm, then amber from 75° and red from 90°, as the limit
    /// meters step.
    private static func heat(_ celsius: Double) -> NSColor {
        celsius >= 90 ? A2.bad : celsius >= 75 ? A2.power : A2.cpu
    }

    private static func rpm(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// The dot and line under the title: the CPU's temperature and how hard macOS is
    /// working to cool the chip.
    private static func status(_ t: ThermalReading) -> Head.Status {
        let names: [ThermalPressure: (String, NSColor)] = [.nominal: ("normal", A2Dev.live), .fair: ("fair", A2Dev.idle),
                                                           .serious: ("serious", A2.bad), .critical: ("critical", A2.bad)]
        let (name, dot) = names[t.pressure] ?? ("normal", A2Dev.live)
        let reading = (t.cpuCelsius ?? t.sensors.map(\.celsius).max()).map { "CPU \(Format.celsius($0))" } ?? "No CPU reading"
        return .init(dot: dot, lines: ["\(reading) · Thermal state \(name)", "\(reading) · \(name.prefix(1).uppercased() + name.dropFirst())", reading])
    }
}
