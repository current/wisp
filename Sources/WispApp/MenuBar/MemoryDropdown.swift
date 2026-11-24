import AppKit
import WispCore

/// The Memory item's dropdown: memory used over the last few minutes as the Memory page
/// charts it, where it goes (app memory, wired, compressed, cached files, in the page's
/// colours), and the apps using the most. Clicking an app opens it in Wisp.
@MainActor
final class MemoryDropdown: SoftDropdown {
    private let history = SoftCard()
    private let chart = SoftDropdown.makeChart(A2.memoryApp, format: { Format.memory(Double($0)) })
    private let parts = SoftCard()
    private let apps = SoftCard()
    private var total: UInt64 = 0

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.memory.title, page: .memory)
        plate.title = "This Mac"
        history.chart = chart
        history.chartHeight = 104
        for card in [history, parts, apps] { addSubview(card) }
        update(delegate.system, history: delegate.monitor.history)
        update(delegate.table)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        update(delegate.system, history: delegate.monitor.history)
        update(delegate.table)
    }

    override func update(_ s: SystemSnapshot, history store: HistoryStore) {
        guard let m = s.memory, m.total > 0 else {
            head.status = .init(dot: A2Dev.quiet, lines: ["No reading yet"])
            plate.count = ""
            plate.footer = ""
            for card in [history, parts, apps] { card.isHidden = true }
            showEmpty("Memory has not been read yet.")
            arrange([])
            return
        }
        showEmpty(nil)
        total = m.total
        chart.step = delegate.settings.interval
        chart.primary = store.recent(.memory)
        chart.ceiling = Float(m.total)
        history.isHidden = false
        history.show(mark: .glyph(PageID.memory.symbol, A2.labelTint(.memory)), title: "Memory used",
                     meta: recentSpan, metaHover: "\(Format.memory(m.free + m.cached)) available",
                     tag: Format.percent(m.usedFraction), lines: [])

        let share = { (bytes: UInt64) in Double(bytes) / Double(m.total) }
        let rows: [(String, UInt64, NSColor, String)] = [
            ("App memory", m.app, A2.memoryApp, "Used by apps"),
            ("Wired", m.wired, A2.memoryWired, "Kept by macOS"),
            ("Compressed", m.compressed, A2.memoryCompressed, "Squeezed to fit"),
            ("Cached files", m.cached, A2.teal, "Freed when needed"),
        ]
        parts.isHidden = false
        parts.show(mark: .glyph("square.stack.3d.up", A2.labelTint(.memory)), title: "Where it goes",
                   meta: m.swapUsed > 0 ? "Swap \(Format.memory(m.swapUsed))" : "No swap",
                   lines: rows.map { name, bytes, color, about in
                       SoftCard.Line(label: name, fraction: share(bytes), color: color, figure: Format.memory(bytes),
                                     detail: Format.percent(share(bytes)), hover: about)
                   })

        head.status = Self.status(m)
        plate.count = "\(Format.memory(m.total)) installed"
        place()
    }

    override func update(_ table: ProcessTable) {
        showApps(apps, title: "Using the most", table: table, color: A2.memoryApp, value: { Double($0.memory) },
                 figure: { Format.memory($0.memory) }, whole: total > 0 ? Double(total) : nil)
        place()
    }

    private func place() {
        guard !history.isHidden else { return }
        plate.footer = apps.isHidden ? "Hover a part for what it is." : "Click an app to see it in Wisp."
        arrange([history, parts, apps].filter { !$0.isHidden })
    }

    /// The dot and line under the title: memory used of the total, and the pressure
    /// macOS reports.
    private static func status(_ m: MemoryReading) -> Head.Status {
        let (name, dot): (String, NSColor) = switch m.pressure {
        case .normal: ("normal", A2Dev.live)
        case .warning: ("warning", A2Dev.idle)
        case .critical: ("critical", A2.bad)
        }
        let used = Format.memory(m.used), total = Format.memory(m.total)
        // "31 of 36 GB" when both are in the same unit.
        let (number, unit) = DashboardView.split(used)
        let short = total.hasSuffix(" " + unit) ? "\(number) of \(total)" : "\(used) of \(total)"
        return .init(dot: dot, lines: ["\(used) of \(total) used · Pressure \(name)", "\(short) used · Pressure \(name)",
                                       "\(short) · Pressure \(name)", "\(short) used"])
    }
}
