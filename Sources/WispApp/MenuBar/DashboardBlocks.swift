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
        case .usage: return "Plan limits"
        case .why: return "Why is it slow?"
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
        case .usage: return "Claude and Codex limits, and when they reset"
        case .why: return "A three-second check when the Mac drags"
        }
    }

    var symbol: String {
        switch self {
        case .meters: return "square.grid.3x2.fill"
        case .sensors: return "thermometer.medium"
        case .agents, .usage: return "sparkles"
        case .why: return "stethoscope"
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
        case .agents, .usage: return PageID.agents.tint
        case .why: return Theme.gray
        }
    }

    /// The page a click on the block opens.
    var page: PageID {
        switch self {
        case .cpu, .cores: return .cpu
        case .meters, .why: return .overview
        case .memory: return .memory
        case .gpu: return .gpu
        case .power: return .energy
        case .network: return .network
        case .disk: return .disk
        case .sensors: return .sensors
        case .apps: return .apps
        case .agents, .usage: return .agents
        }
    }
}

/// One block of the dashboard: a soft card (or, for plan limits, a card per account) laid
/// out in the dropdowns' 400-point space. Each kind fills its card from the readings and
/// says how tall it is; the dashboard stacks them in the saved order. A click on the card
/// outside its lines opens the block's page.
@MainActor
class DashboardBlockView: DrawnView {
    let block: DashboardBlock
    unowned let delegate: AppDelegate
    let card = SoftCard()
    /// Set by the dashboard: the block's height changed with its data.
    var onResize: (() -> Void)?
    /// A line and a button under the card's title when it has nothing to list.
    let message = CardMessage()
    /// The card's title row, where extra content starts.
    static let titleRow: CGFloat = 44
    static let width: CGFloat = DashboardView.width - DashboardView.outer * 2

    init(_ block: DashboardBlock, delegate: AppDelegate) {
        self.block = block
        self.delegate = delegate
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 46))
        wantsLayer = true
        addSubview(card)
        message.isHidden = true
        addSubview(message)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(block.title)
        setAccessibilityHelp("Opens " + block.page.title + " in Wisp")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The cards whose columns line up with the rest of the dashboard's.
    var cards: [SoftCard] { card.isHidden ? [] : [card] }

    var height: CGFloat { message.isHidden ? card.height : Self.titleRow + message.height + 8 }

    override func layout() {
        super.layout()
        card.frame = bounds
        message.frame = NSRect(x: 0, y: Self.titleRow, width: bounds.width, height: message.height)
    }

    func update(_ s: SystemSnapshot, history: HistoryStore) {}
    func update(_ table: ProcessTable) {}

    /// Shows a message under the title in place of lines, or hides it.
    func showMessage(_ text: String?, button: String = "", action: (() -> Void)? = nil) {
        message.isHidden = text == nil
        message.show(text ?? "", button: button)
        message.onPress = action
        needsLayout = true
    }

    /// Asks the dashboard to lay out again once the block's height no longer fits its frame.
    func refit() {
        if abs(frame.height - height) > 0.5 { onResize?() }
    }

    /// "Last 4 minutes": what the recent history covers at the sampling interval.
    var recentSpan: String {
        "Last \(Int((Double(HistoryStore.recentSamples) * max(delegate.settings.interval, 1) / 60).rounded())) minutes"
    }

    static func makeView(_ block: DashboardBlock, delegate: AppDelegate) -> DashboardBlockView {
        switch block {
        case .cpu: return CPUBlock(block, delegate: delegate)
        case .meters: return MetersBlock(block, delegate: delegate)
        case .cores: return CoresBlock(block, delegate: delegate)
        case .memory: return MemoryBlock(block, delegate: delegate)
        case .gpu: return GPUBlock(block, delegate: delegate)
        case .power: return PowerBlock(block, delegate: delegate)
        case .network: return NetworkBlock(block, delegate: delegate)
        case .disk: return DiskBlock(block, delegate: delegate)
        case .sensors: return SensorsBlock(block, delegate: delegate)
        case .apps: return AppsBlock(block, delegate: delegate)
        case .agents: return AgentsBlock(block, delegate: delegate)
        case .usage: return UsageBlock(block, delegate: delegate)
        case .why: return WhyBlock(block, delegate: delegate)
        }
    }

    // MARK: Click

    private var pressed = false

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { delegate.showPage(block.page) }
    }

    override func accessibilityPerformPress() -> Bool {
        delegate.showPage(block.page)
        return true
    }
}

// MARK: - CPU

/// The CPU as the CPU dropdown shows it: apps and macOS, the busiest core and the load,
/// then total and system time over the last few minutes.
final class CPUBlock: DashboardBlockView {
    private let chart = SoftDropdown.makeChart(A2.cpu, A2.cpuLight, names: ("Total", "System"), format: { Format.percent(Double($0)) })

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        chart.ceiling = 1
        card.chart = chart
        card.chartHeight = 88
        card.show(mark: .glyph(PageID.cpu.symbol, A2.labelTint(.cpu)), title: "CPU", meta: "Waiting for the first reading",
                  lines: [.waiting("Apps"), .waiting("macOS"), .waiting("Load")])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let c = s.cpu else { return }
        chart.step = delegate.settings.interval
        chart.primary = history.recent(.cpu)
        chart.secondary = history.recent(.cpuSystem)
        var lines = [
            SoftCard.Line(label: "Apps", fraction: c.user, color: A2.cpu, figure: Format.percent(c.user), detail: "User", hover: "Running apps"),
            SoftCard.Line(label: "macOS", fraction: c.system, color: A2.cpuLight, figure: Format.percent(c.system), detail: "System",
                          hover: "macOS itself"),
        ]
        if let busiest = c.cores.max() {
            lines.append(.init(label: "Busiest core", fraction: busiest, color: CPUDropdown.heat(busiest), figure: Format.percent(busiest),
                               detail: "of \(c.cores.count)"))
        }
        let cores = max(c.cores.count, ProcessInfo.processInfo.activeProcessorCount)
        if let one = c.loadAverage.first {
            let rest = c.loadAverage.dropFirst().prefix(2).map { String(format: "%.1f", $0) }
            lines.append(.init(label: "Load", fraction: one / Double(cores), color: CPUDropdown.heat(one / Double(cores)),
                               figure: String(format: "%.1f", one), detail: "1 min", hover: rest.count == 2 ? "Then \(rest[0]), \(rest[1])" : nil))
        }
        let split = c.performanceCores > 0 ? "\(c.performanceCores) performance, \(c.efficiencyCores) efficiency cores" : "\(cores) cores"
        card.show(mark: .glyph(PageID.cpu.symbol, A2.labelTint(.cpu)), title: "CPU", meta: recentSpan, metaHover: split,
                  tag: Format.percent(c.total), lines: lines)
        refit()
    }
}

// MARK: - Meters

/// Six readings in the row grammar: memory, GPU, power, network, disk and the battery
/// (or the temperature on a Mac without one).
final class MetersBlock: DashboardBlockView {
    /// Samples seen. Rates need two, so a dash shows only once a reading stays missing.
    private var samples = 0
    private static let names = ["Memory", "GPU", "Power", "Network", "Disk", MachinePower.hasBattery ? "Battery" : "Temperature"]

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.show(mark: .glyph("square.grid.2x2", A2.labelTint(.overview)), title: "Meters", meta: "Waiting for the first reading",
                  lines: Self.names.map { .waiting($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        samples += 1
        // Still waiting for the first reading, or none to be had.
        func missing(_ name: String) -> SoftCard.Line {
            samples < 4 ? .waiting(name) : SoftCard.Line(label: name, fraction: 0, color: A2.secondary, figure: "–", detail: "None")
        }
        var lines: [SoftCard.Line] = []
        if let m = s.memory, m.total > 0 {
            lines.append(.init(label: "Memory", fraction: m.usedFraction, color: Strain.memory(m) ? A2.bad : A2.memoryApp,
                               figure: Format.memory(m.used), detail: "of " + Format.memory(m.total),
                               hover: m.pressure == .normal ? "Pressure normal" : m.pressure == .warning ? "Pressure warning" : "Pressure critical",
                               warns: m.pressure != .normal))
        } else {
            lines.append(missing("Memory"))
        }
        if let g = s.gpu?.utilization {
            lines.append(.init(label: "GPU", fraction: g, color: A2.gpu, figure: Format.percent(g), detail: "Busy"))
        } else {
            lines.append(missing("GPU"))
        }
        if let p = s.power, let cpuWatts = p.cpu {
            let total = cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0)
            let peak = Double(history.recent(.power).filter { !$0.isNaN }.max() ?? 0)
            lines.append(.init(label: "Power", fraction: total / max(peak * 1.2, 20), color: A2.power, figure: Format.watts(total), detail: "Chip",
                               hover: "CPU \(Format.watts(cpuWatts)), GPU \(Format.watts(p.gpu ?? 0))"))
        } else {
            lines.append(missing("Power"))
        }
        if let n = s.network {
            let rate = n.receivedBytesPerSecond + n.sentBytesPerSecond
            let peak = Double(zip(history.recent(.networkIn), history.recent(.networkOut)).map { $0 + $1 }.filter { !$0.isNaN }.max() ?? 0)
            lines.append(.init(label: "Network", fraction: rate / max(peak, 1), color: A2.down, figure: Format.rate(rate), detail: "In and out",
                               hover: "↓ \(Format.compactRate(n.receivedBytesPerSecond)) ↑ \(Format.compactRate(n.sentBytesPerSecond))"))
        } else {
            lines.append(missing("Network"))
        }
        if let d = s.disk, d.volumeTotal > 0 {
            let rate = d.readBytesPerSecond + d.writeBytesPerSecond
            let peak = Double(zip(history.recent(.diskRead), history.recent(.diskWrite)).map { $0 + $1 }.filter { !$0.isNaN }.max() ?? 0)
            let low = Strain.disk(d)
            lines.append(.init(label: "Disk", fraction: rate / max(peak, 1), color: low ? A2.bad : A2.diskApps, figure: Format.rate(rate),
                               detail: low ? "Low space" : "\(Format.bytes(d.volumeFree)) free",
                               hover: "\(Format.bytes(d.volumeFree)) free of \(Format.bytes(d.volumeTotal))", warns: low))
        } else {
            lines.append(missing("Disk"))
        }
        if let b = s.battery {
            let state = b.isCharging ? "Charging" : b.isPluggedIn ? "Plugged in" : "On battery"
            let left = b.minutesRemaining.flatMap { $0 > 0 ? Format.duration(Double($0) * 60) : nil }
            lines.append(.init(label: "Battery", fraction: b.percent / 100, color: Strain.battery(b) ? A2.bad : A2.charge,
                               figure: Format.percent(b.percent / 100), detail: state,
                               hover: left.map { b.isCharging ? "Full in \($0)" : "\($0) left" }))
        } else if let t = s.thermal?.cpuCelsius {
            lines.append(.init(label: "Temperature", fraction: t / 105, color: Strain.temperature(s.thermal) ? A2.bad : A2.cpu,
                               figure: Format.celsius(t), detail: "CPU"))
        } else {
            lines.append(missing(Self.names[5]))
        }
        let waiting = lines.allSatisfy(\.ghost)
        card.show(mark: .glyph("square.grid.2x2", A2.labelTint(.overview)), title: "Meters",
                  meta: waiting ? "Waiting for the first reading" : "Right now", lines: lines)
        refit()
    }
}

// MARK: - Cores

/// Every core over the last minute, performance cores on top. Hovering a cell reads it
/// off in the card's quiet spot.
final class CoresBlock: DashboardBlockView {
    private let map = CoreMapGraphic()
    private var rowCount = ProcessInfo.processInfo.activeProcessorCount
    private var summary = "Waiting for the first reading"
    var heatmap: Heatmap { map.heatmap }

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.graphic = map
        card.chartHeight = map.height(rows: rowCount)
        map.heatmap.onHover = { [weak self] hover in self?.hover(hover) }
        showSummary(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showSummary(_ hovered: String?) {
        card.show(mark: .glyph("square.grid.3x3", A2.labelTint(.cpu)), title: "Cores", meta: hovered ?? summary, lines: [])
    }

    private func hover(_ hover: (Int, Int, NSRect)?) {
        guard let (row, column, _) = hover, heatmap.rows.indices.contains(row) else { return showSummary(nil) }
        let values = heatmap.rows[row].values
        let index = values.count - 1 - column
        guard index >= 0, !values[index].isNaN else { return showSummary(nil) }
        let seconds = Double(column) * max(delegate.settings.interval, 1)
        let when = column == 0 ? "now" : Format.duration(seconds) + " ago"
        showSummary("\(heatmap.rows[row].label) \(String(format: "%.0f%%", values[index] * 100)) \(when)")
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let c = s.cpu else { return }
        let busy = c.cores.filter { $0 >= 0.8 }.count
        summary = (c.performanceCores > 0 ? "\(c.performanceCores)P + \(c.efficiencyCores)E" : "\(c.cores.count) cores") + " · \(busy) busy"
        showSummary(nil)
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
            card.chartHeight = map.height(rows: rowCount)
        }
        refit()
    }
}

// MARK: - Memory

/// Memory as the Memory dropdown splits it: app memory, wired, compressed and cached
/// files, with the share used as the tag and a warning while the pressure is up.
final class MemoryBlock: DashboardBlockView {
    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.show(mark: .glyph(PageID.memory.symbol, A2.labelTint(.memory)), title: "Memory", meta: "Waiting for the first reading",
                  lines: ["App memory", "Wired", "Compressed", "Cached files"].map { .waiting($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let m = s.memory, m.total > 0 else { return }
        let share = { (bytes: UInt64) in Double(bytes) / Double(m.total) }
        let rows: [(String, UInt64, NSColor, String)] = [
            ("App memory", m.app, A2.memoryApp, "Used by apps"),
            ("Wired", m.wired, A2.memoryWired, "Kept by macOS"),
            ("Compressed", m.compressed, A2.memoryCompressed, "Squeezed to fit"),
            ("Cached files", m.cached, A2.teal, "Freed when needed"),
        ]
        let (number, unit) = DashboardView.split(Format.memory(m.used))
        let total = Format.memory(m.total)
        let used = total.hasSuffix(" " + unit) ? "\(number) of \(total) used" : "\(Format.memory(m.used)) of \(total) used"
        let note: String? = switch m.pressure {
        case .normal: nil
        case .warning: "Memory pressure is up. Quitting an app frees some."
        case .critical: "Memory is under heavy pressure. Quit an app you are done with."
        }
        card.show(mark: .glyph(PageID.memory.symbol, A2.labelTint(.memory)), title: "Memory", meta: used,
                  metaHover: m.swapUsed > 0 ? "Swap \(Format.memory(m.swapUsed))" : "No swap",
                  tag: Format.percent(m.usedFraction), note: note,
                  lines: rows.map { name, bytes, color, about in
                      SoftCard.Line(label: name, fraction: share(bytes), color: color, figure: Format.memory(bytes),
                                    detail: Format.percent(share(bytes)), hover: about)
                  })
        refit()
    }
}

// MARK: - GPU

/// The GPU as its dropdown shows it: rendering, tiling and the memory it holds, then how
/// busy it has been over the last few minutes.
final class GPUBlock: DashboardBlockView {
    private let chart = SoftDropdown.makeChart(A2.gpu, format: { Format.percent(Double($0)) })

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        chart.ceiling = 1
        card.chart = chart
        card.chartHeight = 88
        card.show(mark: .glyph(PageID.gpu.symbol, A2.labelTint(.gpu)), title: "GPU", meta: "Waiting for the first reading",
                  lines: [.waiting("Rendering"), .waiting("Tiling")])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let g = s.gpu, let busy = g.utilization else { return }
        chart.step = delegate.settings.interval
        chart.primary = history.recent(.gpu)
        var lines: [SoftCard.Line] = []
        if let renderer = g.rendererUtilization {
            lines.append(.init(label: "Rendering", fraction: renderer, color: A2.gpu, figure: Format.percent(renderer), detail: "Drawing",
                               hover: "Drawing what is on screen"))
        }
        if let tiler = g.tilerUtilization {
            lines.append(.init(label: "Tiling", fraction: tiler, color: A2.gpu, figure: Format.percent(tiler), detail: "Sorting",
                               hover: "Sorting shapes before drawing"))
        }
        let installed = ProcessInfo.processInfo.physicalMemory
        if let used = g.memoryUsed, installed > 0 {
            lines.append(.init(label: "Memory", fraction: Double(used) / Double(installed), color: A2.memoryApp, figure: Format.memory(used),
                               detail: Format.percent(Double(used) / Double(installed)), hover: "Shared with the Mac"))
        }
        card.show(mark: .glyph(PageID.gpu.symbol, A2.labelTint(.gpu)), title: "GPU", meta: recentSpan,
                  metaHover: g.coreCount.map { "\($0)-core GPU" }, tag: Format.percent(busy), lines: lines)
        refit()
    }
}

// MARK: - Power

/// Where the chip's power goes, as the Power dropdown splits it, and the battery's charge.
final class PowerBlock: DashboardBlockView {
    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.show(mark: .glyph("bolt", A2.labelTint(.energy)), title: "Power", meta: "Waiting for the first reading",
                  lines: (MachinePower.hasBattery ? ["Battery"] : []).map { .waiting($0) } + ["CPU", "GPU", "Neural Engine"].map { .waiting($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard s.power?.cpu != nil || s.battery != nil else { return }
        var lines: [SoftCard.Line] = []
        if let b = s.battery {
            let low = Strain.battery(b)
            let state = b.isCharging ? "Charging" : b.chargeHeld == true ? "Held" : b.isPluggedIn ? "Plugged in" : "On battery"
            let left = b.minutesRemaining.flatMap { $0 > 0 ? Format.duration(Double($0) * 60) : nil }
            lines.append(.init(label: "Battery", fraction: b.percent / 100, color: low ? A2.bad : A2.charge, figure: Format.percent(b.percent / 100),
                               detail: state, hover: left.map { b.isCharging ? "Full in \($0)" : b.isPluggedIn ? state : "\($0) left" }, warns: low))
        }
        var chip: Double?
        if let p = s.power, let cpu = p.cpu {
            let parts: [(String, Double?, NSColor, String)] = [
                ("CPU", cpu, A2.cpu, "The processor cores"),
                ("GPU", p.gpu, A2.gpu, "Graphics"),
                ("Neural Engine", p.ane, A2.memoryApp, "Machine learning"),
            ]
            let total = parts.compactMap(\.1).reduce(0, +)
            chip = total
            lines += parts.compactMap { name, watts, color, about in
                watts.map { SoftCard.Line(label: name, fraction: total > 0 ? $0 / total : 0, color: color, figure: Format.watts($0),
                                          detail: total > 0 ? Format.percent($0 / total) : "", hover: about) }
            }
        }
        let whole = s.battery?.systemWatts ?? s.power?.system
        card.show(mark: .glyph("bolt", A2.labelTint(.energy)), title: "Power",
                  meta: whole.map { "\(Format.watts($0)) whole Mac" } ?? (chip == nil ? "" : "Chip right now"),
                  metaHover: s.battery?.adapterWatts.map { "\($0) W adapter" }, tag: chip.map { Format.watts($0) }, lines: lines)
        refit()
    }
}

// MARK: - Network

/// Download and upload right now with what has moved since the Mac started, then both
/// over the last few minutes.
final class NetworkBlock: DashboardBlockView {
    private let chart = SoftDropdown.makeChart(A2.down, A2.up, names: ("Down", "Up"), format: { Format.rate(Double($0)) })

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.chart = chart
        card.chartHeight = 88
        card.show(mark: .glyph(PageID.network.symbol, A2.labelTint(.network)), title: "Network", meta: "Waiting for the first reading",
                  lines: [.waiting("Download"), .waiting("Upload")])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let n = s.network else { return }
        chart.step = delegate.settings.interval
        chart.primary = history.recent(.networkIn)
        chart.secondary = history.recent(.networkOut)
        // Bars against the busiest moment in the chart, so they read on the same scale.
        let peak = max(1, (chart.primary + chart.secondary).filter { !$0.isNaN }.map(Double.init).max() ?? 1,
                       n.receivedBytesPerSecond, n.sentBytesPerSecond)
        card.show(mark: .glyph(PageID.network.symbol, A2.labelTint(.network)), title: "Network", meta: recentSpan,
                  metaHover: "Totals since the Mac started", tag: Format.rate(n.receivedBytesPerSecond + n.sentBytesPerSecond), lines: [
                      .init(label: "Download", fraction: n.receivedBytesPerSecond / peak, color: A2.down,
                            figure: Format.rate(n.receivedBytesPerSecond), detail: Format.bytes(n.totalReceived),
                            hover: "\(Format.bytes(n.totalReceived)) in"),
                      .init(label: "Upload", fraction: n.sentBytesPerSecond / peak, color: A2.up,
                            figure: Format.rate(n.sentBytesPerSecond), detail: Format.bytes(n.totalSent),
                            hover: "\(Format.bytes(n.totalSent)) out"),
                  ])
        refit()
    }
}

// MARK: - Disk

/// The startup disk's space and activity, as the Disk dropdown's Space card shows them.
final class DiskBlock: DashboardBlockView {
    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.show(mark: .glyph(PageID.disk.symbol, A2.labelTint(.disk)), title: "Disk", meta: "Waiting for the first reading",
                  lines: ["Used", "Free", "Reading", "Writing"].map { .waiting($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let d = s.disk, d.volumeTotal > 0 else { return }
        let total = Double(d.volumeTotal), used = d.volumeTotal - d.volumeFree
        let low = Strain.disk(d)
        let peak = max(1, (history.recent(.diskRead) + history.recent(.diskWrite)).filter { !$0.isNaN }.map(Double.init).max() ?? 1,
                       d.readBytesPerSecond, d.writeBytesPerSecond)
        card.show(mark: .glyph(PageID.disk.symbol, A2.labelTint(.disk)), title: "Disk", meta: "\(Format.bytes(d.volumeTotal)) startup disk",
                  tag: low ? "Low" : nil, note: low ? "Space is running low. Clean Up can free some." : nil, lines: [
                      .init(label: "Used", fraction: Double(used) / total, color: low ? A2.bad : A2.diskApps, figure: Format.bytes(used),
                            detail: Format.percent(Double(used) / total)),
                      .init(label: "Free", fraction: Double(d.volumeFree) / total, color: low ? A2.bad : A2.charge,
                            figure: Format.bytes(d.volumeFree), detail: Format.percent(Double(d.volumeFree) / total)),
                      .init(label: "Reading", fraction: d.readBytesPerSecond / peak, color: A2.diskApps,
                            figure: Format.rate(d.readBytesPerSecond), detail: "Now"),
                      .init(label: "Writing", fraction: d.writeBytesPerSecond / peak, color: A2.diskDocuments,
                            figure: Format.rate(d.writeBytesPerSecond), detail: "Now"),
                  ])
        refit()
    }
}

// MARK: - Temperature

/// The sensors by group (the hottest reading of each; hovering lists them) and the fans,
/// as the Temperature dropdown shows them, with the CPU's reading as the tag.
final class SensorsBlock: DashboardBlockView {
    private static let groupLimit = 4

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.show(mark: .glyph(PageID.sensors.symbol, A2.labelTint(.sensors)), title: "Temperature", meta: "Waiting for the first reading",
                  lines: ["CPU", "GPU"].map { .waiting($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func heat(_ celsius: Double) -> NSColor { celsius >= 90 ? A2.bad : celsius >= 75 ? A2.power : A2.cpu }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        guard let t = s.thermal, !t.sensors.isEmpty || t.cpuCelsius != nil else { return }
        var lines: [SoftCard.Line]
        let groups = SensorsCardPage.groups(t.sensors)
        if groups.isEmpty {
            lines = [("CPU", t.cpuCelsius), ("GPU", t.gpuCelsius)].compactMap { name, value in
                value.map { SoftCard.Line(label: name, fraction: $0 / 105, color: Self.heat($0), figure: Format.celsius($0), detail: "") }
            }
        } else {
            lines = groups.prefix(Self.groupLimit).map { group in
                let top = group.values.max() ?? 0
                let readings = group.values.sorted(by: >).map { Format.celsius($0) }
                return SoftCard.Line(label: group.name, fraction: top / 105, color: Self.heat(top), figure: Format.celsius(top),
                                     detail: group.values.count == 1 ? "1 sensor" : "Hottest of \(group.values.count)",
                                     hover: readings.count > 1 ? readings.joined(separator: " ") : nil)
            }
        }
        for fan in t.fans.prefix(2) {
            let top = fan.maxRPM ?? 6000
            let fraction = fan.rpm > 1 ? min(1, fan.rpm / max(top, 1)) : 0
            lines.append(.init(label: t.fans.count == 1 ? "Fan" : "Fan \(fan.index + 1)", fraction: fraction,
                               color: fraction >= 0.8 ? A2.power : A2.cpu, figure: Format.percent(fraction),
                               detail: fan.rpm > 1 ? "\(Int(fan.rpm.rounded()).formatted(.number.grouping(.automatic))) rpm" : "Off"))
        }
        let state: String = switch t.pressure {
        case .nominal: "Thermal state normal"
        case .fair: "Thermal state fair"
        case .serious: "Thermal state serious"
        case .critical: "Thermal state critical"
        }
        let hottest = t.sensors.max { $0.celsius < $1.celsius }
        card.show(mark: .glyph(PageID.sensors.symbol, A2.labelTint(.sensors)), title: "Temperature", meta: state,
                  metaHover: hottest.map { "Hottest: \($0.name), \(Format.celsius($0.celsius))" },
                  tag: t.cpuCelsius.map { "CPU " + Format.celsius($0) },
                  note: t.pressure == .serious || t.pressure == .critical ? "macOS is slowing the chip to cool it." : nil, lines: lines)
        refit()
    }
}

// MARK: - Apps

/// The busiest apps by CPU, memory, power or network, with their icons; a click opens
/// one in Wisp, and hovering shows how many processes it runs.
final class AppsBlock: DashboardBlockView {
    let tabs = SoftTabs(["CPU", "Memory", "Power", "Net"])
    private var last: ProcessTable?
    private static let shown = 5
    var interactive = true

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        addSubview(tabs)
        tabs.onChange = { [weak self] _ in
            guard let self, let table = self.last else { return }
            self.update(table)
        }
        // WISP_TABS=<n> (or the older "map,apps" pair) opens on an apps tab, for screenshots.
        if let tab = ProcessInfo.processInfo.environment["WISP_TABS"]?.split(separator: ",").last.flatMap({ Int($0) }) {
            tabs.select(tab, animated: false)
        }
        card.onClick = { [weak self] index in
            guard let self, self.interactive, self.card.ids.indices.contains(index) else { return }
            self.delegate.showWindow(selecting: self.card.ids[index])
        }
        showLines([], meta: "", waiting: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = tabs.naturalWidth
        tabs.frame = NSRect(x: bounds.width - SoftCard.padX - width, y: 10, width: width, height: 26)
    }

    private func showLines(_ lines: [SoftCard.Line], meta: String, waiting: Bool = false) {
        card.show(mark: .glyph(PageID.apps.symbol, A2.labelTint(.apps)), title: "Apps", meta: meta,
                  lines: waiting ? (0..<Self.shown).map { _ in .waiting() } : lines)
    }

    override func update(_ table: ProcessTable) {
        // The first table has no apps until the processes have been read once.
        guard !(table.apps.isEmpty && table.processes.isEmpty) else { return }
        last = table
        let tab = tabs.selected
        if tab == 3, !table.networkMeasured {
            card.ids = []
            showLines([], meta: "")
            showMessage("Measured only while a Wisp window shows it.", button: "Also measure in the background") { [weak self] in
                self?.delegate.change { $0.trackAppNetwork = true }
            }
            return refit()
        }
        showMessage(nil)
        let value: (AppGroup) -> Double = {
            switch tab {
            case 1: return Double($0.memory)
            case 2: return $0.watts
            case 3: return $0.networkPerSecond
            default: return $0.cpu
            }
        }
        let color = [A2.cpu, A2.memoryApp, A2.power, A2.down][tab]
        let top = Array(table.apps.filter { value($0) > 0 }.sorted { value($0) > value($1) }.prefix(Self.shown))
        let peak = max(top.first.map(value) ?? 1, .leastNonzeroMagnitude)
        let whole = tab == 0 ? Double(max(table.coreCount, 1)) : tab == 1 ? Double(ProcessInfo.processInfo.physicalMemory)
            : table.apps.map(value).reduce(0, +)
        let machine = delegate.settings.cpuOfMachine
        card.ids = top.map(\.id)
        let lines = top.map { app in
            let figure: String = switch tab {
            case 1: Format.memory(app.memory)
            case 2: Format.watts(app.watts)
            case 3: Format.rate(app.networkPerSecond)
            default: Style.appCPU(app.cpu, machine: machine, coreCount: table.coreCount)
            }
            return SoftCard.Line(label: app.name, fraction: value(app) / peak, color: color, figure: figure,
                                 detail: whole > 0 ? Format.percent(value(app) / whole) : "",
                                 hover: app.processCount == 1 ? "1 process" : "\(app.processCount) processes", icon: Icons.icon(for: app))
        }
        if lines.isEmpty {
            showLines([], meta: "")
            showMessage(tab == 2 ? "No app is drawing measurable power." : "No app is busy with this right now.")
        } else {
            showLines(lines, meta: "")
        }
        refit()
    }
}

// MARK: - Coding agents

/// Coding agents running now, one line per kind: its mark, the CPU its processes use,
/// and how many are running. Hovering shows their memory.
final class AgentsBlock: DashboardBlockView {
    private let finder = AgentFinder()
    private var checkedAt = Date.distantPast
    /// How many were found at the last look, for the dashboard's status line.
    private(set) var running: Int?

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        card.show(mark: .glyph("sparkles", A2.labelTint(.agents)), title: "Coding agents", meta: "Looking for agents",
                  lines: [.waiting(), .waiting()])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ table: ProcessTable) {
        // Finding agents walks the process table; every few seconds is plenty. Before the
        // first table there is nothing to look through yet.
        guard !table.processes.isEmpty, Date().timeIntervalSince(checkedAt) > 5 else { return }
        checkedAt = Date()
        let found = finder.find(table)
        running = found.count
        let groups = Dictionary(grouping: found, by: \.kind)
            .map { (kind: $0.key, count: $0.value.count, cpu: $0.value.map(\.cpu).reduce(0, +), memory: $0.value.map(\.memory).reduce(0, +)) }
            .sorted { ($0.count, $1.kind) > ($1.count, $0.kind) }.prefix(4)
        let peak = max(groups.map(\.cpu).max() ?? 1, 0.01)
        let machine = delegate.settings.cpuOfMachine
        let lines = groups.map { group in
            SoftCard.Line(label: group.kind, fraction: group.cpu / peak, color: A2.cpu,
                          figure: Style.appCPU(group.cpu, machine: machine, coreCount: table.coreCount),
                          detail: group.count == 1 ? "1 running" : "\(group.count) running",
                          hover: "\(Format.memory(group.memory)) memory",
                          icon: AgentMark.image(group.kind, size: 16, appearance: effectiveAppearance))
        }
        card.show(mark: .glyph("sparkles", A2.labelTint(.agents)), title: "Coding agents",
                  meta: found.isEmpty ? "None running" : "\(found.count) running", lines: lines)
        showMessage(found.isEmpty ? "Agents show here while they work." : nil)
        refit()
    }
}
