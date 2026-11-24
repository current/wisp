import AppKit
import WispCore

/// The Disk item's dropdown: reads and writes over the last few minutes, the startup
/// disk's space and activity right now, and the apps reading and writing the most.
@MainActor
final class DiskDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart = SoftDropdown.makeChart(A2.diskApps, A2.diskDocuments, names: ("Read", "Write"), format: { Format.rate(Double($0)) })
    private let space = SoftCard()
    private let apps = SoftCard()

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.disk.title, page: .disk)
        plate.title = "Startup disk"
        history.chart = chart
        history.chartHeight = 104
        for card in [history, space, apps] { addSubview(card) }
        prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        update(delegate.system, history: delegate.monitor.history)
        update(delegate.table)
    }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        guard let d = s.disk, d.volumeTotal > 0 else {
            head.status = .init(dot: A2Dev.quiet, lines: ["No reading yet"])
            for card in [history, space, apps] { card.isHidden = true }
            showEmpty("The disk has not been read yet.")
            arrange([])
            return
        }
        showEmpty(nil)
        chart.step = delegate.settings.interval
        chart.primary = store.recent(.diskRead)
        chart.secondary = store.recent(.diskWrite)
        history.isHidden = false
        history.show(mark: .glyph(PageID.disk.symbol, A2.labelTint(.disk)), title: "Activity", meta: recentSpan,
                     tag: Format.rate(d.readBytesPerSecond + d.writeBytesPerSecond), lines: [])

        let total = Double(d.volumeTotal), used = d.volumeTotal - d.volumeFree
        let low = Strain.disk(d)
        let peak = max(1, (chart.primary + chart.secondary).filter { !$0.isNaN }.map(Double.init).max() ?? 1,
                       d.readBytesPerSecond, d.writeBytesPerSecond)
        space.isHidden = false
        space.show(mark: .glyph("internaldrive", A2.labelTint(.disk)), title: "Space", meta: "\(Format.bytes(d.volumeTotal)) disk",
                   tag: low ? "Low" : nil, lines: [
                       .init(label: "Used", fraction: Double(used) / total, color: low ? A2.bad : A2.diskApps, figure: Format.bytes(used),
                             detail: Format.percent(Double(used) / total)),
                       .init(label: "Free", fraction: Double(d.volumeFree) / total, color: low ? A2.bad : A2.charge,
                             figure: Format.bytes(d.volumeFree), detail: Format.percent(Double(d.volumeFree) / total)),
                       .init(label: "Reading", fraction: d.readBytesPerSecond / peak, color: A2.diskApps,
                             figure: Format.rate(d.readBytesPerSecond), detail: ""),
                       .init(label: "Writing", fraction: d.writeBytesPerSecond / peak, color: A2.diskDocuments,
                             figure: Format.rate(d.writeBytesPerSecond), detail: ""),
                   ])

        let free = Format.bytes(d.volumeFree), size = Format.bytes(d.volumeTotal)
        head.status = .init(dot: low ? A2.bad : A2Dev.live, lines: ["\(free) free of \(size)" + (low ? " · Running low" : ""), "\(free) free"])
        plate.count = ""
        place()
    }

    override func update(_ table: ProcessTable) {
        showApps(apps, title: "Reading and writing", table: table, color: A2.diskApps, value: { $0.diskPerSecond },
                 figure: { Format.rate($0.diskPerSecond) })
        place()
    }

    private func place() {
        guard !history.isHidden else { return }
        plate.footer = apps.isHidden ? "Clean Up can free space on this disk." : "Click an app to see it in Wisp."
        arrange([history, space, apps].filter { !$0.isHidden })
    }
}
