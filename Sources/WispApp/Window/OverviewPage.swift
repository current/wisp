import AppKit
import WispCore

/// Recent samples as thin bars, newest on the right.
final class BarHistory: DrawnView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var ceiling: Float?
    var color: NSColor = Theme.accent
    var pitch: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        let count = Int(bounds.width / pitch)
        let shown = values.suffix(count)
        let top = ceiling ?? max(shown.filter { !$0.isNaN }.max() ?? 0, 0.0001)
        for slot in 0..<count {
            let x = bounds.width - CGFloat(count - slot) * pitch
            let index = shown.count - (count - slot)
            let value: Float? = index >= 0 ? shown[shown.startIndex + index] : nil
            let rect: NSRect
            if let value, !value.isNaN {
                let height = max(3, bounds.height * CGFloat(min(1, value / top)))
                rect = NSRect(x: x, y: bounds.height - height, width: pitch - 2, height: height)
                color.setFill()
            } else {
                rect = NSRect(x: x, y: bounds.height - 3, width: pitch - 2, height: 3)
                Theme.track.setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// A caption over a figure.
final class Stat: DrawnView {
    private var caption = ""
    private var value = ""

    func set(_ pair: (String, String)) {
        guard pair != (caption, value) else { return }
        (caption, value) = pair
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.caption(caption, size: 9.5).draw(at: .zero)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(with: NSRect(x: 0, y: 15, width: bounds.width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { caption + " " + value }
}

/// One subsystem at a glance: name, the main figure, three small figures and its recent history.
final class SummaryCard: CardView {
    let caption = TextLine()
    let state = Pill()
    let figure = BigNumber()
    let stats = (0..<3).map { _ in Stat() }
    let bars = BarHistory()
    private let arrow = TextLine(NSAttributedString(string: "›", attributes: [.font: Theme.sans(16), .foregroundColor: Theme.inkTertiary]))
    var onClick: (() -> Void)?
    private var statValues: [(String, String)] = []

    init(_ name: String, color: NSColor) {
        super.init()
        let text = NSMutableAttributedString(string: "● ", attributes: [.font: Theme.mono(10), .foregroundColor: color])
        text.append(Theme.caption(name, color: Theme.inkSecondary))
        caption.text = text
        figure.font = Theme.figure(34)
        figure.unitFont = Theme.sans(15)
        bars.color = color
        state.isHidden = true
        for view in [caption, state, figure, bars, arrow] as [NSView] { addSubview(view) }
        stats.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(stats values: [(String, String)]) {
        for (index, stat) in stats.enumerated() {
            stat.set(index < values.count ? values[index] : ("", ""))
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        caption.frame = NSRect(x: 20, y: 18, width: caption.naturalWidth + 4, height: 14)
        state.frame = NSRect(x: caption.frame.maxX + 6, y: 16, width: state.naturalWidth, height: 18)
        arrow.frame = NSRect(x: bounds.width - 30, y: 14, width: 12, height: 20)
        figure.frame = NSRect(x: 20, y: 40, width: width, height: 44)
        let column = width / 3
        for (index, line) in stats.enumerated() { line.frame = NSRect(x: 20 + CGFloat(index) * column, y: 92, width: column - 8, height: 34) }
        bars.frame = NSRect(x: 20, y: bounds.height - 44, width: width, height: 26)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The landing page: every subsystem as a card, plus what Wisp noticed recently.
@MainActor
final class OverviewPage: CardPage {
    private let cpu = SummaryCard("CPU", color: Theme.series[0])
    private let memory = SummaryCard("Memory", color: Theme.series[2])
    private let gpu = SummaryCard("GPU", color: Theme.series[5])
    private let disk = SummaryCard("Disk", color: Theme.series[1])
    private let network = SummaryCard("Network", color: Theme.series[3])
    private let power = SummaryCard("Power", color: Theme.series[4])
    private let developer = SummaryCard("Developer", color: Theme.inkSecondary)
    private let thermal = SummaryCard("Temperature", color: Theme.bad)
    private let notices = CardView()
    private let noticesTitle = TextLine()
    private let noticesEmpty = TextLine(Theme.caption("Nothing worth a look since Wisp started"))
    private var noticeRows: [ListRow] = []
    private let open: (PageID) -> Void
    private let devServers = DevServerScanner()
    private let agents = AgentFinder()
    private var slowAt = Date.distantPast

    init(delegate: AppDelegate, open: @escaping (PageID) -> Void) {
        self.open = open
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        let cards: [(SummaryCard, PageID)] = [(cpu, .cpu), (memory, .memory), (gpu, .gpu), (disk, .disk), (network, .network),
                                              (power, .energy), (thermal, .sensors), (developer, .ports)]
        for (card, page) in cards {
            canvas.addSubview(card)
            card.onClick = { [weak self] in self?.open(page) }
        }
        cpu.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        cpu.bars.ceiling = 1
        gpu.figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        gpu.bars.ceiling = 1
        memory.figure.format = { DashboardView.split(Format.memory($0)) }
        disk.figure.format = { DashboardView.split(Format.bytes(UInt64(max(0, $0)))) }
        network.figure.format = { DashboardView.split(Format.rate($0)) }
        power.figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
        developer.figure.format = { (String(format: "%.0f", $0), "servers") }
        developer.bars.isHidden = true
        thermal.figure.format = { (String(format: "%.0f", $0), "°C") }
        canvas.addSubview(notices)
        notices.addSubview(noticesTitle)
        notices.addSubview(noticesEmpty)
        noticesTitle.text = DashboardView.titleText("Worth a look", "")
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let columns = width > 1000 ? 3 : 2
        let cards = [cpu, memory, gpu, disk, network, power, thermal, developer]
        let bottom = grid(cards, top: margin, width: width, columns: columns, height: 196)
        let inner = width - margin * 2
        let height = max(110, 60 + CGFloat(noticeRows.filter { !$0.isHidden }.count) * 34)
        notices.frame = NSRect(x: margin, y: bottom + gap, width: inner, height: height)
        noticesTitle.frame = NSRect(x: 20, y: 16, width: inner - 40, height: 20)
        noticesEmpty.frame = NSRect(x: 20, y: 54, width: inner - 40, height: 14)
        for (index, row) in noticeRows.enumerated() { row.frame = NSRect(x: 20, y: 46 + CGFloat(index) * 34, width: inner - 40, height: 34) }
        return notices.frame.maxY + margin
    }

    override func update(system s: SystemSnapshot) {
        let history = delegate.monitor.history
        if let c = s.cpu {
            cpu.figure.set(c.total)
            cpu.state.isHidden = c.total < 0.6
            cpu.state.text = c.total >= 0.85 ? "Strained" : "Busy"
            cpu.state.tone = c.total >= 0.85 ? .bad : .warn
            cpu.set(stats: [("User", Format.percent(c.user)), ("System", Format.percent(c.system)),
                            ("Load", String(format: "%.1f", c.loadAverage.first ?? 0))])
            cpu.needsLayout = true
        }
        cpu.bars.values = history.recent(.cpu)

        if let m = s.memory {
            memory.figure.set(Double(m.used))
            memory.state.isHidden = m.pressure == .normal
            memory.state.text = m.pressure == .warning ? "Pressure" : "Critical"
            memory.state.tone = m.pressure == .warning ? .warn : .bad
            memory.set(stats: [("App", Format.memory(m.app)), ("Wired", Format.memory(m.wired)), ("Compressed", Format.memory(m.compressed))])
            memory.bars.ceiling = Float(m.total)
            memory.needsLayout = true
        }
        memory.bars.values = history.recent(.memory)

        if let g = s.gpu {
            gpu.figure.set(g.utilization)
            let recent = history.recent(.gpu).filter { !$0.isNaN }
            let mean = recent.isEmpty ? 0 : Double(recent.reduce(0, +)) / Double(recent.count)
            gpu.set(stats: [("Memory", g.memoryUsed.map { Format.memory($0) } ?? "–"), ("Average", Format.percent(mean)),
                            ("Peak", Format.percent(Double(recent.max() ?? 0)))])
        }
        gpu.bars.values = history.recent(.gpu)

        if let d = s.disk {
            disk.figure.set(Double(d.volumeFree))
            disk.state.isHidden = !Strain.disk(d)
            disk.state.text = "Low space"
            disk.state.tone = .bad
            disk.needsLayout = true
            disk.set(stats: [("Reading", Format.rate(d.readBytesPerSecond)), ("Writing", Format.rate(d.writeBytesPerSecond)),
                             ("Free of", Format.bytes(d.volumeTotal))])
        }
        disk.bars.values = zip(history.recent(.diskRead), history.recent(.diskWrite)).map { $0 + $1 }

        if let n = s.network {
            network.figure.set(n.receivedBytesPerSecond)
            network.set(stats: [("Upload", Format.rate(n.sentBytesPerSecond)), ("Today", networkToday),
                                ("Last 7 days", networkWeek)])
        }
        network.bars.values = zip(history.recent(.networkIn), history.recent(.networkOut)).map { $0 + $1 }

        if let p = s.power, let cpuWatts = p.cpu {
            power.figure.set(cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0))
            var stats: [(String, String)] = [("CPU", Format.watts(cpuWatts)), ("GPU", Format.watts(p.gpu ?? 0))]
            if let b = s.battery {
                stats.append((b.isCharging ? "Charging" : "Battery", String(format: "%.0f%%", b.percent)))
            } else {
                stats.append(("Neural Engine", Format.watts(p.ane ?? 0)))
            }
            power.set(stats: stats)
        }
        power.bars.values = history.recent(.power)

        if let t = s.thermal {
            thermal.figure.set(t.cpuCelsius)
            thermal.state.isHidden = t.pressure == .nominal
            thermal.state.text = t.pressure.rawValue
            thermal.state.tone = t.pressure == .fair ? .warn : .bad
            thermal.needsLayout = true
            thermal.set(stats: [("GPU", t.gpuCelsius.map(Format.celsius) ?? "–"),
                                ("Fans", t.fans.isEmpty ? "None" : t.fans.map { "\(Int($0.rpm))" }.joined(separator: ", ")),
                                ("Hottest", t.sensors.max { $0.celsius < $1.celsius }.map { Format.celsius($0.celsius) } ?? "–")])
        }
        thermal.bars.values = history.recent(.cpuTemperature)
        thermal.bars.ceiling = 110

        if Date().timeIntervalSince(slowAt) > 10 { refreshSlow() }
    }

    private var networkToday = "–"
    private var networkWeek = "–"

    /// Readings that change slowly or cost more: totals, dev servers, agents, alerts.
    private func refreshSlow() {
        slowAt = Date()
        let history = delegate.monitor.history
        let midnight = Calendar.current.startOfDay(for: Date())
        networkToday = Format.bytes(UInt64(history.total(.networkIn, since: midnight) + history.total(.networkOut, since: midnight)))
        let week = Date().addingTimeInterval(-7 * 86_400)
        networkWeek = Format.bytes(UInt64(history.total(.networkIn, since: week) + history.total(.networkOut, since: week)))

        let table = delegate.table
        let projects = devServers.scan(table)
        let servers = projects.reduce(0) { $0 + $1.servers.count }
        let idle = projects.reduce(0) { $0 + $1.servers.filter { $0.connections == 0 && ($0.idleSeconds ?? 0) >= DevServerScanner.idleAfter }.count }
        let agentCount = agents.find(table).count
        developer.figure.set(Double(servers))
        developer.state.isHidden = idle == 0
        developer.state.text = "\(idle) idle"
        developer.state.tone = .warn
        developer.needsLayout = true
        developer.set(stats: [("Projects", "\(projects.count)"), ("Coding agents", "\(agentCount)"), ("Idle servers", "\(idle)")])

        let alerts = delegate.monitor.perform { $0.alerts.recent }.suffix(6).reversed()
        while noticeRows.count < alerts.count {
            let row = ListRow()
            notices.addSubview(row)
            noticeRows.append(row)
        }
        noticesEmpty.isHidden = !alerts.isEmpty
        for (index, row) in noticeRows.enumerated() {
            guard index < alerts.count else { row.isHidden = true; continue }
            let alert = alerts[alerts.index(alerts.startIndex, offsetBy: index)]
            row.isHidden = false
            row.dot = Theme.warn
            row.name = alert.title
            row.note = alert.body
            row.value = alert.date.formatted(date: .omitted, time: .shortened)
            row.showsBar = false
            row.showsRule = index < alerts.count - 1
        }
        relayout()
    }
}
