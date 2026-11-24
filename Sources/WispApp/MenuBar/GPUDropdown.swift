import AppKit
import WispCore

/// The GPU item's dropdown: how busy it has been over the last few minutes, and what it
/// is doing right now (rendering and tiling, the memory it holds, its power and heat).
@MainActor
final class GPUDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart = SoftDropdown.makeChart(A2.gpu, format: { Format.percent(Double($0)) })
    private let now = SoftCard()

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.gpu.title, page: .gpu)
        plate.title = "This Mac"
        chart.ceiling = 1
        history.chart = chart
        history.chartHeight = 104
        for card in [history, now] { addSubview(card) }
        prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() { update(delegate.system, history: delegate.monitor.history) }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        guard let g = s.gpu, let busy = g.utilization else {
            head.status = .init(dot: A2Dev.quiet, lines: ["No reading yet"])
            for card in [history, now] { card.isHidden = true }
            showEmpty("The GPU has not been read yet.")
            arrange([])
            return
        }
        showEmpty(nil)
        chart.step = delegate.settings.interval
        chart.primary = store.recent(.gpu)
        history.isHidden = false
        history.show(mark: .glyph(PageID.gpu.symbol, A2.labelTint(.gpu)), title: "GPU", meta: recentSpan,
                     tag: Format.percent(busy), lines: [])

        var lines: [SoftCard.Line] = []
        if let renderer = g.rendererUtilization {
            lines.append(.init(label: "Rendering", fraction: renderer, color: A2.gpu, figure: Format.percent(renderer), detail: "",
                               hover: "Drawing what is on screen"))
        }
        if let tiler = g.tilerUtilization {
            lines.append(.init(label: "Tiling", fraction: tiler, color: A2.gpu, figure: Format.percent(tiler), detail: "",
                               hover: "Sorting shapes before drawing"))
        }
        if let used = g.memoryUsed, let total = s.memory?.total, total > 0 {
            lines.append(.init(label: "Memory", fraction: Double(used) / Double(total), color: A2.memoryApp, figure: Format.memory(used),
                               detail: Format.percent(Double(used) / Double(total)), hover: "Shared with the Mac"))
        }
        if let watts = s.power?.gpu {
            let total = (s.power?.cpu ?? 0) + watts + (s.power?.ane ?? 0)
            lines.append(.init(label: "Power", fraction: total > 0 ? watts / total : 0, color: A2.power, figure: Format.watts(watts),
                               detail: total > 0 ? Format.percent(watts / total) : "", hover: "Of the chip's power"))
        }
        if let celsius = s.thermal?.gpuCelsius {
            lines.append(.init(label: "Temperature", fraction: celsius / 105, color: celsius >= 90 ? A2.bad : celsius >= 75 ? A2.power : A2.cpu,
                               figure: Format.celsius(celsius), detail: ""))
        }
        now.isHidden = lines.isEmpty
        now.show(mark: .glyph("gauge.with.dots.needle.33percent", A2.labelTint(.gpu)), title: "Right now",
                 meta: g.coreCount.map { "\($0) cores" } ?? "", lines: lines)

        let dot = busy >= 0.85 ? A2.bad : busy >= 0.6 ? A2Dev.idle : A2Dev.live
        let size = g.coreCount.map { "\($0)-core GPU" }
        head.status = .init(dot: dot, lines: [size.map { "\(Format.percent(busy)) busy · \($0)" }, "\(Format.percent(busy)) busy"].compactMap { $0 })
        plate.count = g.name.replacingOccurrences(of: "Apple ", with: "")
        plate.footer = "Hover the chart for earlier readings."
        arrange([history, now].filter { !$0.isHidden })
    }
}
