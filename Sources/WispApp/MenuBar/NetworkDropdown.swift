import AppKit
import WispCore

/// The Network item's dropdown: download and upload over the last few minutes, the rates
/// right now with what has moved since the Mac started, and the apps moving the most.
@MainActor
final class NetworkDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart = SoftDropdown.makeChart(A2.down, A2.up, names: ("Down", "Up"), format: { Format.rate(Double($0)) })
    private let now = SoftCard()
    private let apps = SoftCard()

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.network.title, page: .network)
        plate.title = "This Mac"
        history.chart = chart
        history.chartHeight = 104
        for card in [history, now, apps] { addSubview(card) }
        prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        update(delegate.system, history: delegate.monitor.history)
        update(delegate.table)
    }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        guard let n = s.network else {
            head.status = .init(dot: A2Dev.quiet, lines: ["No reading yet"])
            for card in [history, now, apps] { card.isHidden = true }
            showEmpty("The network has not been read yet.")
            arrange([])
            return
        }
        showEmpty(nil)
        chart.step = delegate.settings.interval
        chart.primary = store.recent(.networkIn)
        chart.secondary = store.recent(.networkOut)
        history.isHidden = false
        history.show(mark: .glyph(PageID.network.symbol, A2.labelTint(.network)), title: "Traffic", meta: recentSpan,
                     tag: Format.rate(n.receivedBytesPerSecond + n.sentBytesPerSecond), lines: [])

        // Bars against the busiest moment shown in the chart, so they read on the same scale.
        let peak = max(1, (chart.primary + chart.secondary).filter { !$0.isNaN }.map(Double.init).max() ?? 1,
                       n.receivedBytesPerSecond, n.sentBytesPerSecond)
        now.isHidden = false
        now.show(mark: .glyph("arrow.up.arrow.down", A2.labelTint(.network)), title: "Right now", meta: "Since the Mac started",
                 lines: [
                     .init(label: "Download", fraction: n.receivedBytesPerSecond / peak, color: A2.down,
                           figure: Format.rate(n.receivedBytesPerSecond), detail: Format.bytes(n.totalReceived),
                           hover: "\(Format.bytes(n.totalReceived)) received"),
                     .init(label: "Upload", fraction: n.sentBytesPerSecond / peak, color: A2.up,
                           figure: Format.rate(n.sentBytesPerSecond), detail: Format.bytes(n.totalSent),
                           hover: "\(Format.bytes(n.totalSent)) sent"),
                 ])

        let moving = n.receivedBytesPerSecond + n.sentBytesPerSecond > 1024
        head.status = .init(dot: moving ? A2Dev.live : A2Dev.quiet, lines: [
            "Down \(Format.rate(n.receivedBytesPerSecond)) · Up \(Format.rate(n.sentBytesPerSecond))",
            "↓ \(Format.compactRate(n.receivedBytesPerSecond)) ↑ \(Format.compactRate(n.sentBytesPerSecond))",
        ])
        plate.count = ""
        place()
    }

    override func update(_ table: ProcessTable) {
        showApps(apps, title: "Moving the most", table: table, color: A2.down, value: { $0.networkPerSecond },
                 figure: { Format.rate($0.networkPerSecond) })
        place()
    }

    private func place() {
        guard !history.isHidden else { return }
        plate.footer = !apps.isHidden ? "Click an app to see it in Wisp."
            : delegate.settings.trackAppNetwork ? "No app is moving data right now." : "Per-app network use is off in Settings."
        arrange([history, now, apps].filter { !$0.isHidden })
    }
}
