import AppKit
import WispCore

/// The Battery and Power items' dropdown: the charge (or, on a Mac without a battery,
/// the chip's power) over the last few minutes, the battery's state and health, where
/// the power goes right now, and the apps using the most energy.
@MainActor
final class PowerDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart: TimeChart
    private let battery = SoftCard()
    private let power = SoftCard()
    private let apps = SoftCard()
    private let hasBattery = MachinePower.hasBattery

    init(delegate: AppDelegate, metric: MenuMetric) {
        chart = hasBattery
            ? SoftDropdown.makeChart(A2.charge, format: { String(format: "%.0f%%", $0) })
            : SoftDropdown.makeChart(A2.power, format: { Format.watts(Double($0)) })
        super.init(delegate: delegate, title: metric.title, page: .energy)
        plate.title = "This Mac"
        if hasBattery {
            chart.ceiling = 100
        } else {
            chart.minimumCeiling = 10
        }
        history.chart = chart
        history.chartHeight = 104
        for card in [history, battery, power, apps] { addSubview(card) }
        prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        update(delegate.system, history: delegate.monitor.history)
        update(delegate.table)
    }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        chart.step = delegate.settings.interval
        chart.primary = store.recent(hasBattery ? .battery : .power)
        let chip = s.power.flatMap { p in p.cpu.map { $0 + (p.gpu ?? 0) + (p.ane ?? 0) } }
        history.isHidden = false
        if let b = s.battery {
            history.show(mark: .glyph(PageID.energy.symbol, A2.labelTint(.energy)), title: "Charge", meta: recentSpan,
                         tag: Format.percent(b.percent / 100), lines: [])
        } else {
            history.show(mark: .glyph("bolt", A2.labelTint(.energy)), title: "Chip power", meta: recentSpan,
                         tag: chip.map { Format.watts($0) }, lines: [])
        }
        showBattery(s.battery)
        showPower(s)
        head.status = Self.status(s.battery, chip: chip)
        plate.count = s.battery?.lowPowerMode == true ? "Low Power Mode" : ""
        place()
    }

    private func showBattery(_ reading: BatteryReading?) {
        battery.isHidden = reading == nil
        guard let b = reading else { return }
        let low = Strain.battery(b)
        let state = b.isCharging ? "Charging" : b.chargeHeld == true ? "Held" : b.isPluggedIn ? "Plugged in" : "On battery"
        let left = b.minutesRemaining.flatMap { $0 > 0 ? Format.duration(Double($0) * 60) : nil }
        var lines = [SoftCard.Line(label: "Charge", fraction: b.percent / 100, color: low ? A2.bad : A2.charge,
                                   figure: Format.percent(b.percent / 100), detail: state,
                                   hover: left.map { b.isCharging ? "Full in \($0)" : b.isPluggedIn ? state : "\($0) left" })]
        if let health = b.health {
            let mah = { (value: Int) in value.formatted(.number.grouping(.automatic)) }
            let capacity = b.fullChargeCapacity.flatMap { full in b.designCapacity.map { "\(mah(full)) of \(mah($0)) mAh" } }
            lines.append(.init(label: "Health", fraction: health, color: health < 0.8 ? A2.power : A2.charge,
                               figure: Format.percent(health), detail: b.cycleCount.map { "\($0) cycles" } ?? "", hover: capacity))
        }
        if let watts = b.watts, abs(watts) >= 0.1 {
            let adapter = b.adapterWatts.map { Double($0) } ?? 100
            lines.append(.init(label: watts > 0 ? "Charging at" : "Draining at", fraction: min(1, abs(watts) / max(adapter, 1)),
                               color: watts > 0 ? A2.charge : A2.power, figure: Format.watts(abs(watts)), detail: ""))
        }
        battery.show(mark: .glyph(PageID.energy.symbol, A2.labelTint(.energy)), title: "Battery",
                     meta: b.isPluggedIn ? (b.adapterWatts.map { "\($0) W adapter" } ?? "") : (left.map { "\($0) left" } ?? ""),
                     tag: low ? "Low" : nil, lines: lines)
    }

    private func showPower(_ s: SystemSnapshot) {
        guard let p = s.power, let cpu = p.cpu else {
            power.isHidden = true
            return
        }
        let parts: [(String, Double?, NSColor, String)] = [
            ("CPU", cpu, A2.cpu, "The processor cores"),
            ("GPU", p.gpu, A2.gpu, "Graphics"),
            ("Neural Engine", p.ane, A2.memoryApp, "Machine learning"),
        ]
        let chip = parts.compactMap(\.1).reduce(0, +)
        let whole = s.battery?.systemWatts ?? p.system
        power.isHidden = false
        power.show(mark: .glyph("bolt", A2.labelTint(.energy)), title: "Power now",
                   meta: whole.map { "\(Format.watts($0)) whole Mac" } ?? "\(Format.watts(chip)) chip",
                   lines: parts.compactMap { name, watts, color, about in
                       watts.map { SoftCard.Line(label: name, fraction: chip > 0 ? $0 / chip : 0, color: color, figure: Format.watts($0),
                                                 detail: chip > 0 ? Format.percent($0 / chip) : "", hover: about) }
                   })
    }

    override func update(_ table: ProcessTable) {
        showApps(apps, title: "Using the most energy", table: table, color: A2.power, value: { $0.watts },
                 figure: { Format.watts($0.watts) })
        place()
    }

    private func place() {
        plate.footer = apps.isHidden ? "Hover a line for more." : "Click an app to see it in Wisp."
        arrange([history, battery, power, apps].filter { !$0.isHidden })
    }

    /// The dot and line under the title: the charge and what it is doing, or the chip's
    /// power on a Mac without a battery.
    private static func status(_ reading: BatteryReading?, chip: Double?) -> Head.Status {
        guard let b = reading else {
            return .init(dot: A2Dev.live, lines: [chip.map { "\(Format.watts($0)) now" } ?? "No reading yet"])
        }
        let percent = Format.percent(b.percent / 100)
        let left = b.minutesRemaining.flatMap { $0 > 0 ? Format.duration(Double($0) * 60) : nil }
        let state = b.isCharging ? (left.map { "Charging, full in \($0)" } ?? "Charging")
            : b.isPluggedIn ? (b.chargeHeld == true ? "Charge held" : "Plugged in")
            : (left.map { "\($0) left" } ?? "On battery")
        let dot = b.isPluggedIn ? A2Dev.live : b.percent <= 10 ? A2.bad : b.percent <= 20 ? A2Dev.idle : A2Dev.live
        return .init(dot: dot, lines: ["\(percent) · \(state)", percent])
    }
}
