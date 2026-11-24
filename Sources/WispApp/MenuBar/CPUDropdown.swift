import AppKit
import WispCore

/// The CPU item's dropdown: total and system time over the last few minutes, the load
/// right now (apps, macOS, the busiest core, the load average), and the apps using it most.
@MainActor
final class CPUDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart = SoftDropdown.makeChart(A2.cpu, A2.cpuLight, names: ("Total", "System"), format: { Format.percent(Double($0)) })
    private let load = SoftCard()
    private let apps = SoftCard()

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.cpu.title, page: .cpu)
        plate.title = "This Mac"
        chart.ceiling = 1
        history.chart = chart
        history.chartHeight = 104
        for card in [history, load, apps] { addSubview(card) }
        prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        update(delegate.system, history: delegate.monitor.history)
        update(delegate.table)
    }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        guard let c = s.cpu else {
            head.status = .init(dot: A2Dev.quiet, lines: ["No reading yet"])
            for card in [history, load, apps] { card.isHidden = true }
            showEmpty("The CPU has not been read yet.")
            arrange([])
            return
        }
        showEmpty(nil)
        chart.step = delegate.settings.interval
        chart.primary = store.recent(.cpu)
        chart.secondary = store.recent(.cpuSystem)
        history.isHidden = false
        history.show(mark: .glyph(PageID.cpu.symbol, A2.labelTint(.cpu)), title: "CPU", meta: recentSpan,
                     metaHover: "System \(Format.percent(c.system))", tag: Format.percent(c.total), lines: [])

        var lines = [
            SoftCard.Line(label: "Apps", fraction: c.user, color: A2.cpu, figure: Format.percent(c.user), detail: "User",
                          hover: "Running apps"),
            SoftCard.Line(label: "macOS", fraction: c.system, color: A2.cpuLight, figure: Format.percent(c.system), detail: "System",
                          hover: "macOS itself"),
        ]
        if let busiest = c.cores.max() {
            lines.append(.init(label: "Busiest core", fraction: busiest, color: Self.heat(busiest), figure: Format.percent(busiest),
                               detail: "of \(c.cores.count)"))
        }
        let cores = max(c.cores.count, ProcessInfo.processInfo.activeProcessorCount)
        if let one = c.loadAverage.first {
            let rest = c.loadAverage.dropFirst().prefix(2).map { String(format: "%.1f", $0) }
            lines.append(.init(label: "Load", fraction: one / Double(cores), color: Self.heat(one / Double(cores)),
                               figure: String(format: "%.1f", one), detail: "1 min",
                               hover: rest.count == 2 ? "Then \(rest[0]), \(rest[1])" : nil))
        }
        let split = c.performanceCores > 0 ? "\(c.performanceCores) performance, \(c.efficiencyCores) efficiency" : nil
        load.isHidden = false
        load.show(mark: .glyph("gauge.with.dots.needle.33percent", A2.labelTint(.cpu)), title: "Right now",
                  meta: "\(cores) cores", metaHover: split, lines: lines)

        let (dot, word) = c.total >= 0.85 ? (A2.bad, "busy") : c.total >= 0.6 ? (A2Dev.idle, "working") : (A2Dev.live, "calm")
        let average = c.loadAverage.first.map { String(format: "%.1f", $0) }
        head.status = .init(dot: dot, lines: [average.map { "\(Format.percent(c.total)) used · Load \($0) on \(cores) cores" },
                                              "\(Format.percent(c.total)) used · \(word.prefix(1).uppercased() + word.dropFirst())",
                                              "\(Format.percent(c.total)) used"].compactMap { $0 })
        plate.count = "\(cores) cores"
        place()
    }

    override func update(_ table: ProcessTable) {
        let machine = delegate.settings.cpuOfMachine
        showApps(apps, title: "Using the most", table: table, color: A2.cpu, value: { $0.cpu },
                 figure: { Style.appCPU($0.cpu, machine: machine, coreCount: table.coreCount) }, whole: Double(table.coreCount))
        place()
    }

    private func place() {
        guard !history.isHidden else { return }
        plate.footer = apps.isHidden ? "Hover a line for what it means." : "Click an app to see it in Wisp."
        arrange([history, load, apps].filter { !$0.isHidden })
    }

    /// Calm, then amber from 60% and red from 85%, as the limit meters step.
    static func heat(_ fraction: Double) -> NSColor {
        fraction >= 0.85 ? A2.bad : fraction >= 0.6 ? A2.power : A2.cpu
    }
}
