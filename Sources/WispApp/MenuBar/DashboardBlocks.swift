import AppKit
import WispCore

extension DashboardBlock {
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .meters: return "Meters"
        case .cores: return "Cores"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .power: return "Power"
        case .network: return "Network"
        case .disk: return "Disk"
        case .sensors: return "Temperature"
        case .apps: return "Apps"
        case .agents: return "Coding agents"
        }
    }

    /// One line for the builder's palette.
    var detail: String {
        switch self {
        case .cpu: return "Usage and the last few minutes"
        case .meters: return "Six small readings in a grid"
        case .cores: return "Each core over time"
        case .memory: return "Used, pressure and by kind"
        case .gpu: return "Usage and its line"
        case .power: return "Watts and the battery"
        case .network: return "Down and up"
        case .disk: return "Free space and activity"
        case .sensors: return "Hottest sensor and fans"
        case .apps: return "The busiest apps, by tab"
        case .agents: return "Coding agents running now"
        }
    }

    var symbol: String {
        switch self {
        case .meters: return "square.grid.3x2.fill"
        case .sensors: return "thermometer.medium"
        case .agents: return "sparkles"
        default: return Theme.symbol(for: title)
        }
    }

    var tint: NSColor {
        switch self {
        case .cpu, .cores: return PageID.cpu.tint
        case .meters: return Theme.blue
        case .memory: return PageID.memory.tint
        case .gpu: return PageID.gpu.tint
        case .power: return PageID.energy.tint
        case .network: return PageID.network.tint
        case .disk: return PageID.disk.tint
        case .sensors: return PageID.sensors.tint
        case .apps: return Theme.gray
        case .agents: return PageID.agents.tint
        }
    }
}

/// One card of the dashboard. Each kind lays itself out at the dashboard's width
/// and says how tall it is; the dashboard stacks them in the saved order.
@MainActor
class DashboardBlockView: CardView {
    let block: DashboardBlock
    unowned let delegate: AppDelegate
    let header = TextLine()
    /// Set by the dashboard when its height changes with the data (cores, agents).
    var onResize: (() -> Void)?

    init(_ block: DashboardBlock, delegate: AppDelegate) {
        self.block = block
        self.delegate = delegate
        super.init()
        header.text = Theme.header(block.title, symbol: block.symbol, tint: block.tint)
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(block.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { 106 }
    var content: CGFloat { bounds.width - 32 }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 16, y: 13, width: max(0, header.naturalWidth + 4), height: 20)
    }

    func update(_ s: SystemSnapshot, history: HistoryStore) {}
    func update(_ table: ProcessTable) {}

    static func makeView(_ block: DashboardBlock, delegate: AppDelegate) -> DashboardBlockView {
        switch block {
        case .cpu: return CPUBlock(block, delegate: delegate)
        case .meters: return MetersBlock(block, delegate: delegate)
        case .cores: return CoresBlock(block, delegate: delegate)
        case .memory: return MemoryBlock(block, delegate: delegate)
        case .apps: return AppsBlock(block, delegate: delegate)
        case .agents: return AgentsBlock(block, delegate: delegate)
        case .gpu, .power, .network, .disk, .sensors: return CompactBlock(block, delegate: delegate)
        }
    }

    /// The state pill at the right end of the header.
    func placeRight(_ view: NSView, width: CGFloat, height: CGFloat = 20) {
        view.frame = NSRect(x: bounds.width - 16 - width, y: 13 + (20 - height) / 2, width: width, height: height)
    }
}

// MARK: - CPU

/// The CPU: its figure and state, user and system, and the recent samples as bars.
final class CPUBlock: DashboardBlockView {
    private let state = Pill()
    private let figure = BigNumber()
    private let facts = Facts()
    private let context = TextLine()
    private let chart = BarHistory()

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        for view in [state, figure, facts, context, chart] as [NSView] { addSubview(view) }
        figure.font = Theme.figure(30)
        figure.unitFont = Theme.sans(15, .medium)
        figure.format = { (String(format: "%.0f", $0 * 100), "%") }
        chart.ceiling = 1
        chart.color = block.tint
        chart.pitch = 4
        facts.alignRight = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat { 162 }

    override func layout() {
        super.layout()
        placeRight(state, width: state.naturalWidth)
        figure.frame = NSRect(x: 16, y: 36, width: 150, height: 38)
        facts.frame = NSRect(x: bounds.width - 16 - 180, y: 44, width: 180, height: 32)
        context.frame = NSRect(x: 16, y: 78, width: content, height: 14)
        chart.frame = NSRect(x: 16, y: 102, width: content, height: 44)
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let c = s.cpu else { return }
        figure.set(c.total)
        state.text = c.total >= 0.85 ? "Strained" : (c.total >= 0.6 ? "Busy" : "Normal")
        state.tone = c.total >= 0.85 ? .bad : (c.total >= 0.6 ? .warn : .good)
        facts.items = [.init(label: "User", value: Format.percent(c.user), dot: nil),
                       .init(label: "System", value: Format.percent(c.system), dot: nil),
                       .init(label: "Load", value: String(format: "%.1f", c.loadAverage.first ?? 0), dot: nil)]
        let minutes = Int((Double(HistoryStore.recentSamples) * max(delegate.settings.interval, 1) / 60).rounded())
        context.text = Theme.caption(c.performanceCores > 0
            ? "\(c.cores.count) cores (\(c.performanceCores)P + \(c.efficiencyCores)E) · last \(minutes) min"
            : "\(c.cores.count) cores · last \(minutes) min")
        chart.values = history.recent(.cpu)
        needsLayout = true
    }
}

// MARK: - Meters

/// Six small readings in a grid: memory, GPU, power, network, disk and the battery
/// (or the temperature on a Mac without one).
final class MetersBlock: DashboardBlockView {
    private let meters = (0..<6).map { _ in Meter() }

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        header.isHidden = true
        meters.forEach(addSubview)
        for (meter, caption) in zip(meters, ["Memory", "GPU", "Power", "Network", "Disk", "Battery"]) { meter.caption = caption }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat { 128 }

    override func layout() {
        super.layout()
        let column = (content - 32) / 3
        for (index, meter) in meters.enumerated() {
            meter.frame = NSRect(x: 16 + CGFloat(index % 3) * (column + 16), y: 16 + CGFloat(index / 3) * 54, width: column, height: 44)
        }
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        if let m = s.memory {
            meters[0].set(value: Format.memory(m.used).split(separator: " ").first.map(String.init) ?? "",
                          unit: "/ " + Format.memory(m.total), fraction: m.usedFraction,
                          color: Strain.memory(m) ? Theme.bad : PageID.memory.tint)
        }
        if let g = s.gpu?.utilization {
            meters[1].set(value: String(format: "%.0f", g * 100), unit: "%", fraction: g, color: PageID.gpu.tint)
        } else {
            meters[1].set(value: "–", unit: "", fraction: 0, color: PageID.gpu.tint)
        }
        if let p = s.power, let cpuWatts = p.cpu {
            let total = cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0)
            let peak = Double(history.recent(.power).filter { !$0.isNaN }.max() ?? 0)
            meters[2].set(value: String(format: total >= 10 ? "%.0f" : "%.1f", total), unit: "W",
                          fraction: total / max(peak * 1.2, 20), color: PageID.energy.tint)
        } else {
            meters[2].set(value: "–", unit: "", fraction: 0, color: PageID.energy.tint)
        }
        if let n = s.network {
            let rate = n.receivedBytesPerSecond + n.sentBytesPerSecond
            let peak = Double(zip(history.recent(.networkIn), history.recent(.networkOut)).map { $0 + $1 }.filter { !$0.isNaN }.max() ?? 0)
            let (value, unit) = DashboardView.split(Format.rate(rate))
            meters[3].set(value: value, unit: unit, fraction: rate / max(peak, 1), color: PageID.network.tint)
        }
        if let d = s.disk {
            let rate = d.readBytesPerSecond + d.writeBytesPerSecond
            let peak = Double(zip(history.recent(.diskRead), history.recent(.diskWrite)).map { $0 + $1 }.filter { !$0.isNaN }.max() ?? 0)
            let (value, unit) = DashboardView.split(Format.rate(rate))
            meters[4].caption = Strain.disk(d) ? "Disk · low space" : "Disk"
            meters[4].set(value: value, unit: unit, fraction: rate / max(peak, 1), color: Strain.disk(d) ? Theme.bad : PageID.disk.tint)
        }
        if let b = s.battery {
            meters[5].caption = b.isCharging ? "Charging" : (b.isPluggedIn ? "Battery" : "On battery")
            meters[5].set(value: String(format: "%.0f", b.percent), unit: "%", fraction: b.percent / 100,
                          color: Strain.battery(b) ? Theme.bad : Theme.green)
        } else if let t = s.thermal?.cpuCelsius {
            meters[5].caption = "Temperature"
            meters[5].set(value: Format.temperature(t).0, unit: Format.temperature(t).1, fraction: t / 110,
                          color: Strain.temperature(s.thermal) ? Theme.bad : PageID.sensors.tint)
        }
    }
}

// MARK: - Cores

/// Every core over the last minute, performance cores on top.
final class CoresBlock: DashboardBlockView {
    private let meta = TextLine()
    let heatmap = Heatmap()
    private let hint = TextLine(Theme.caption("Hover a core", size: 9.5))
    private let key = HeatKey()
    private var rowCount = 0
    var onHover: (((Int, Int, NSRect)?) -> Void)?

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        for view in [meta, heatmap, hint, key] as [NSView] { addSubview(view) }
        meta.alignment = .right
        heatmap.rowPitch = 11
        heatmap.labelWidth = 30
        heatmap.valueWidth = 34
        heatmap.columns = HistoryStore.recentCoreSamples
        heatmap.onHover = { [weak self] hover in self?.onHover?(hover) }
        rowCount = ProcessInfo.processInfo.activeProcessorCount
    }

    required init?(coder: NSCoder) { fatalError() }

    private var mapHeight: CGFloat { CGFloat(max(rowCount, 1)) * heatmap.rowPitch - heatmap.cellGap }
    override var height: CGFloat { 44 + mapHeight + 12 + 14 + 14 }

    override func layout() {
        super.layout()
        meta.frame = NSRect(x: bounds.width - 16 - 220, y: 16, width: 220, height: 14)
        heatmap.frame = NSRect(x: 16, y: 44, width: content, height: mapHeight)
        hint.frame = NSRect(x: 16, y: heatmap.frame.maxY + 12, width: 120, height: 14)
        key.frame = NSRect(x: bounds.width - 16 - 150, y: heatmap.frame.maxY + 12, width: 150, height: 14)
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let c = s.cpu else { return }
        let busy = c.cores.filter { $0 >= 0.8 }.count
        meta.text = Theme.caption(c.performanceCores > 0
            ? "\(c.performanceCores)P + \(c.efficiencyCores)E · \(busy) busy" : "\(c.cores.count) cores · \(busy) busy")
        let cores = history.cores()
        guard !cores.isEmpty else { return }
        // The kernel lists efficiency cores first; show performance cores on top.
        let efficiency = min(c.efficiencyCores, cores.count)
        var rows: [Heatmap.Row] = []
        for (number, index) in (efficiency..<cores.count).enumerated() {
            rows.append(Heatmap.Row(label: "P\(number + 1)", tag: "", values: cores[index]))
        }
        for index in 0..<efficiency {
            rows.append(Heatmap.Row(label: "E\(index + 1)", tag: "", values: cores[index]))
        }
        heatmap.rows = rows
        if rows.count != rowCount {
            rowCount = rows.count
            onResize?()
        }
    }
}

// MARK: - Memory

/// Memory in use, its pressure and what holds it.
final class MemoryBlock: DashboardBlockView {
    private let state = Pill()
    private let figure = BigNumber()
    private let context = TextLine()
    private let bar = SplitBar()
    private let legend = LegendRows()

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        for view in [state, figure, context, bar, legend] as [NSView] { addSubview(view) }
        figure.font = Theme.figure(30)
        figure.unitFont = Theme.sans(15, .medium)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat { 194 }

    override func layout() {
        super.layout()
        placeRight(state, width: state.naturalWidth)
        figure.frame = NSRect(x: 16, y: 36, width: content, height: 38)
        context.frame = NSRect(x: 16, y: 78, width: content, height: 14)
        bar.frame = NSRect(x: 16, y: 102, width: content, height: 8)
        legend.frame = NSRect(x: 16, y: 120, width: content, height: 60)
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let m = s.memory else { return }
        figure.format = { value in
            let (number, unit) = DashboardView.split(Format.memory(value))
            return (number, unit + " of " + Format.memory(m.total).replacingOccurrences(of: " GB", with: ""))
        }
        figure.set(Double(m.used))
        state.text = m.pressure == .normal ? "Normal" : (m.pressure == .warning ? "Pressure: Warning" : "Pressure: Critical")
        state.tone = m.pressure == .normal ? .good : (m.pressure == .warning ? .warn : .bad)
        context.text = Theme.caption("Swap \(Format.memory(m.swapUsed)) · \(Format.memory(m.free + m.cached)) available")
        let total = Double(max(m.total, 1))
        let compressed = Theme.indigo.withAlphaComponent(0.45)
        bar.parts = [(Double(m.app) / total, Theme.indigo), (Double(m.wired) / total, Theme.orange), (Double(m.compressed) / total, compressed)]
        legend.rows = [(Theme.indigo, "App", Format.memory(m.app)), (Theme.orange, "Wired", Format.memory(m.wired)),
                       (compressed, "Compressed", Format.memory(m.compressed))]
        needsLayout = true
    }
}

// MARK: - Small parts

/// GPU, power, network, disk and temperature share one shape: the header, a
/// figure with a line under it, and a chart or a few facts on the right.
final class CompactBlock: DashboardBlockView {
    private let state = Pill()
    private let figure = BigNumber()
    private let context = TextLine()
    private let line = LiveLine()
    private let facts = Facts()
    private let bar = SplitBar()

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        for view in [state, figure, context, line, facts, bar] as [NSView] { addSubview(view) }
        figure.font = Theme.figure(26)
        figure.unitFont = Theme.sans(14, .medium)
        line.color = block.tint
        line.capacity = HistoryStore.recentSamples
        facts.alignRight = true
        state.isHidden = true
        switch block {
        case .gpu:
            figure.format = { (String(format: "%.0f", $0 * 100), "%") }
            line.ceiling = 1
            facts.isHidden = true
            bar.isHidden = true
        case .network:
            figure.format = { DashboardView.split(Format.rate($0)) }
            facts.isHidden = true
            bar.isHidden = true
        case .power:
            figure.format = { (String(format: $0 >= 10 ? "%.0f" : "%.1f", $0), "W") }
            line.isHidden = true
            bar.isHidden = true
        case .disk:
            figure.format = { value in
                let (number, unit) = DashboardView.split(Format.bytes(UInt64(max(0, value))))
                return (number, unit + " free")
            }
            line.isHidden = true
        default:
            figure.format = { Format.temperature($0) }
            line.isHidden = true
            bar.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat { block == .disk ? 122 : 106 }

    override func layout() {
        super.layout()
        placeRight(state, width: state.naturalWidth)
        let left = line.isHidden ? content * 0.5 : content * 0.48
        figure.frame = NSRect(x: 16, y: 36, width: left, height: 34)
        context.frame = NSRect(x: 16, y: 74, width: line.isHidden ? content * 0.5 : left, height: 14)
        line.frame = NSRect(x: 16 + content * 0.5, y: 32, width: content * 0.5 + 4, height: 62)
        facts.frame = NSRect(x: 16 + content * 0.4, y: 42, width: content * 0.6, height: 32)
        bar.frame = NSRect(x: 16, y: 98, width: content, height: 8)
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        switch block {
        case .gpu:
            guard let g = s.gpu else { return }
            figure.set(g.utilization)
            context.text = Theme.caption([g.coreCount.map { "\($0)-core GPU" }, g.memoryUsed.map { Format.memory($0) }]
                .compactMap { $0 }.joined(separator: " · "))
            line.values = history.recent(.gpu)
        case .network:
            guard let n = s.network else { return }
            figure.set(n.receivedBytesPerSecond)
            context.text = Theme.caption("Down · \(Format.rate(n.sentBytesPerSecond)) up")
            line.values = zip(history.recent(.networkIn), history.recent(.networkOut)).map { $0 + $1 }
        case .power:
            if let p = s.power, let cpuWatts = p.cpu {
                figure.set(cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0))
                context.text = Theme.caption("CPU \(Format.watts(cpuWatts)) · GPU \(Format.watts(p.gpu ?? 0))")
            }
            var items: [Facts.Item] = []
            if let b = s.battery {
                items.append(.init(label: b.isCharging ? "Charging" : (b.isPluggedIn ? "Battery" : "On battery"),
                                   value: String(format: "%.0f%%", b.percent), dot: Strain.battery(b) ? Theme.bad : nil))
                if let minutes = b.minutesRemaining, minutes > 0, !b.isPluggedIn {
                    items.append(.init(label: "Left", value: Format.duration(Double(minutes) * 60), dot: nil))
                }
                if let health = b.health { items.append(.init(label: "Health", value: String(format: "%.0f%%", health * 100), dot: nil)) }
            } else if let ane = s.power?.ane {
                items.append(.init(label: "Neural Engine", value: Format.watts(ane), dot: nil))
            }
            facts.items = items
        case .disk:
            guard let d = s.disk else { return }
            figure.set(Double(d.volumeFree))
            state.isHidden = !Strain.disk(d)
            state.text = "Low space"
            state.tone = .bad
            context.text = Theme.caption("\(Format.bytes(d.volumeTotal - d.volumeFree)) of \(Format.bytes(d.volumeTotal)) used")
            facts.items = [.init(label: "Reading", value: Format.rate(d.readBytesPerSecond), dot: nil),
                           .init(label: "Writing", value: Format.rate(d.writeBytesPerSecond), dot: nil)]
            bar.parts = [(1 - Double(d.volumeFree) / Double(max(d.volumeTotal, 1)), Strain.disk(d) ? Theme.red : block.tint)]
        default:
            guard let t = s.thermal else { return }
            figure.set(t.cpuCelsius)
            state.isHidden = t.pressure == .nominal
            state.text = t.pressure.rawValue.prefix(1).uppercased() + t.pressure.rawValue.dropFirst()
            state.tone = t.pressure == .fair ? .warn : .bad
            context.text = Theme.caption("Hottest CPU sensor")
            var items: [Facts.Item] = t.fans.prefix(2).enumerated().map {
                .init(label: t.fans.count > 1 ? "Fan \($0.offset + 1)" : "Fan", value: "\(Int($0.element.rpm)) rpm", dot: nil)
            }
            if let gpu = t.gpuCelsius { items.insert(.init(label: "GPU", value: Format.temperature(gpu).0 + Format.temperature(gpu).1, dot: nil), at: 0) }
            facts.items = items
        }
        needsLayout = true
    }
}

// MARK: - Apps

/// The busiest apps by CPU, memory, power or network.
final class AppsBlock: DashboardBlockView {
    let tabs = Segmented(["CPU", "Memory", "Power", "Net"])
    private let meta = TextLine()
    private let rows = (0..<5).map { _ in ListRow() }
    private let note = TextLine()
    private let noteButton = CapsuleButton()
    private var last: ProcessTable?
    var interactive = true

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        for view in [tabs, meta, note, noteButton] as [NSView] { addSubview(view) }
        rows.forEach(addSubview)
        rows.last?.showsRule = false
        note.alignment = .center
        note.text = NSAttributedString(string: "Per-app network is measured while a Wisp window shows it.",
                                       attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary])
        noteButton.title = "Also measure in the background"
        noteButton.onPress = { [weak self] in self?.delegate.change { $0.trackAppNetwork = true } }
        noteButton.setAccessibilityHelp("Turns on Settings, General, Track network per app in the background")
        tabs.onChange = { [weak self] _ in
            guard let self, let table = self.last else { return }
            self.update(table)
        }
        // WISP_TABS=<n> (or the older "map,apps" pair) opens on an apps tab, for screenshots.
        if let tab = ProcessInfo.processInfo.environment["WISP_TABS"]?.split(separator: ",").last.flatMap({ Int($0) }) {
            tabs.select(tab, animated: false)
        }
        showNote(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat { 60 + 30 * CGFloat(rows.count) + 8 }

    override func layout() {
        super.layout()
        let tabsWidth = tabs.naturalWidth
        tabs.frame = NSRect(x: bounds.width - 16 - tabsWidth, y: 10, width: tabsWidth, height: 26)
        meta.frame = NSRect(x: 16, y: 38, width: content, height: 14)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 16, y: 58 + CGFloat(index) * 30, width: content, height: 30)
        }
        let middle: CGFloat = 58 + 75
        note.frame = NSRect(x: 16, y: middle - 24, width: content, height: 16)
        let buttonWidth = noteButton.naturalWidth
        noteButton.frame = NSRect(x: (bounds.width - buttonWidth) / 2, y: middle + 2, width: buttonWidth, height: 26)
    }

    private func showNote(_ on: Bool) {
        note.isHidden = !on
        noteButton.isHidden = !on
        if on { rows.forEach { $0.isHidden = true } }
    }

    override func update(_ table: ProcessTable) {
        last = table
        let tab = tabs.selected
        meta.text = Theme.caption("\(table.apps.count) apps · \(table.processes.count) processes")
        if tab == 3, !table.networkMeasured {
            showNote(true)
            return
        }
        showNote(false)
        let key: (AppGroup) -> Double = {
            switch tab {
            case 1: return Double($0.memory)
            case 2: return $0.watts
            case 3: return $0.networkPerSecond
            default: return $0.cpu
            }
        }
        let top = table.apps.sorted { key($0) > key($1) }.prefix(rows.count)
        let peak = max(top.first.map(key) ?? 0, 0.000_001)
        let settings = delegate.settings
        for (index, row) in rows.enumerated() {
            guard index < top.count else {
                row.isHidden = true
                continue
            }
            let app = top[top.startIndex + index]
            row.isHidden = false
            row.icon = Icons.icon(for: app)
            row.name = app.name
            row.note = app.processCount > 1 ? "\(app.processCount) procs" : ""
            row.fraction = key(app) / peak
            row.barColor = [PageID.cpu.tint, PageID.memory.tint, PageID.energy.tint, PageID.network.tint][tab]
            switch tab {
            case 1: row.value = Format.memory(app.memory)
            case 2: row.value = app.watts > 0.005 ? Format.watts(app.watts) : "–"
            case 3: row.value = app.networkPerSecond > 0 ? Format.rate(app.networkPerSecond) : "–"
            default: row.value = Style.appCPU(app.cpu, machine: settings.cpuOfMachine, coreCount: table.coreCount)
            }
            let id = app.id
            row.onClick = interactive ? { [weak self] in self?.delegate.showWindow(selecting: id) } : nil
        }
    }
}

// MARK: - Coding agents

/// Coding agents running now, one line per kind.
final class AgentsBlock: DashboardBlockView {
    private let count = TextLine()
    private let empty = TextLine(Theme.caption("None running"))
    private var lines: [AgentLine] = []
    private let finder = AgentFinder()
    private var checkedAt = Date.distantPast
    private var shown = 0

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        count.alignment = .right
        addSubview(count)
        addSubview(empty)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat { 44 + CGFloat(max(1, shown)) * 36 + 6 }

    override func layout() {
        super.layout()
        count.frame = NSRect(x: bounds.width - 16 - 120, y: 16, width: 120, height: 14)
        empty.frame = NSRect(x: 16, y: 54, width: content, height: 16)
        for (index, line) in lines.enumerated() {
            line.frame = NSRect(x: 16, y: 44 + CGFloat(index) * 36, width: content, height: 36)
        }
    }

    override func update(_ table: ProcessTable) {
        // Finding agents walks the process table; every few seconds is plenty.
        guard Date().timeIntervalSince(checkedAt) > 5 else { return }
        checkedAt = Date()
        let found = finder.find(table)
        let grouped = Dictionary(grouping: found, by: \.kind).map { ($0.key, $0.value.count) }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(4)
        while lines.count < grouped.count {
            let line = AgentLine()
            addSubview(line)
            lines.append(line)
        }
        for (index, line) in lines.enumerated() {
            line.isHidden = index >= grouped.count
            guard index < grouped.count else { continue }
            let (name, number) = grouped[grouped.startIndex + index]
            line.name = name
            line.count = number
            line.showsRule = index < grouped.count - 1
        }
        empty.isHidden = !grouped.isEmpty
        count.text = Theme.caption(found.isEmpty ? "" : "\(found.count) running")
        if grouped.count != shown {
            shown = grouped.count
            onResize?()
        }
        needsLayout = true
    }
}
