import AppKit
import WispCore

/// One reading for the whole machine: its figure now, its history over the last
/// hour or day, and the apps behind it, now and over the same span.
@MainActor
final class MetricPage: NSViewController, Page, NSTableViewDataSource, NSTableViewDelegate {
    private struct Line {
        var id: String
        var name: String
        var kind: AppKind
        var bundlePath: String?
        var now: Double
        var span: Double
    }

    private let id: PageID
    private unowned let delegate: AppDelegate
    private let onSelect: (Selection?) -> Void
    private let figure = Style.label("–", font: Style.bigFigure)
    private let detail = Style.secondary("", font: Style.body)
    private let range = NSSegmentedControl(labels: ["Hour", "Day"], trackingMode: .selectOne, target: nil, action: nil)
    private let chart = HistoryChart()
    private let table = NSTableView()
    private let note = Style.secondary()
    private var lines: [Line] = []
    private var spanMinutes = 60

    var demand: Demand {
        switch id {
        case .network: return [.appNetwork]
        case .energy: return [.power]
        case .cpu: return [.cpuCores]
        default: return []
        }
    }

    init(_ id: PageID, delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        self.id = id
        self.delegate = delegate
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = Style.label(id.title, font: NSFont.systemFont(ofSize: 15, weight: .semibold))
        range.selectedSegment = 0
        range.target = self
        range.action = #selector(rangeChanged)
        range.segmentStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = Style.stack([title, spacer, range], axis: .horizontal)
        let figures = Style.stack([figure, detail], axis: .horizontal, spacing: Style.pad)
        figures.alignment = .firstBaseline

        chart.translatesAutoresizingMaskIntoConstraints = false
        configureChart()

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "App"
        nameColumn.width = 260
        let nowColumn = NSTableColumn(identifier: .init("now"))
        nowColumn.title = "Now"
        nowColumn.width = 96
        nowColumn.headerCell.alignment = .right
        let spanColumn = NSTableColumn(identifier: .init("span"))
        spanColumn.width = 120
        spanColumn.headerCell.alignment = .right
        for column in [nameColumn, nowColumn, spanColumn] { table.addTableColumn(column) }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        let top = Style.stack([header, figures, chart, note], axis: .vertical, spacing: Style.gap, alignment: .leading)
        top.setCustomSpacing(Style.pad, after: figures)
        for view in [header, chart] { view.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }
        root.addSubview(top)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Style.section),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Style.section),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: Style.pad),
            chart.heightAnchor.constraint(equalToConstant: 170),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Style.pad),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateSpanTitle()
    }

    private func configureChart() {
        switch id {
        case .cpu, .gpu:
            chart.ceiling = 1
            chart.format = { Format.percent(Double($0)) }
        case .memory:
            chart.ceiling = Float(delegate.system.memory?.total ?? 0)
            chart.format = { Format.memory(Double($0)) }
        case .energy:
            chart.format = { Format.watts(Double($0)) }
        case .disk, .network:
            chart.format = { Format.rate(Double($0)) }
        default: break
        }
    }

    @objc private func rangeChanged() {
        spanMinutes = range.selectedSegment == 0 ? 60 : 1440
        updateSpanTitle()
        refreshChart()
        update(table: delegate.table)
    }

    private func updateSpanTitle() {
        let span = spanMinutes == 60 ? "Hour" : "Day"
        let title: String
        switch id {
        case .cpu: title = span + " average"
        case .memory: title = span + " peak"
        default: title = span + " total"
        }
        table.tableColumns.last?.title = title
    }

    private func refreshChart() {
        let history = delegate.monitor.history
        chart.spanMinutes = spanMinutes
        switch id {
        case .cpu: chart.values = history.day(.cpu, minutes: spanMinutes)
        case .memory: chart.values = history.day(.memory, minutes: spanMinutes)
        case .energy: chart.values = history.day(.power, minutes: spanMinutes)
        case .gpu: chart.values = history.day(.gpu, minutes: spanMinutes)
        case .disk:
            chart.values = history.day(.diskRead, minutes: spanMinutes)
            chart.secondary = history.day(.diskWrite, minutes: spanMinutes)
        case .network:
            chart.values = history.day(.networkIn, minutes: spanMinutes)
            chart.secondary = history.day(.networkOut, minutes: spanMinutes)
        default: break
        }
    }

    private var lastChartMinute = 0

    func update(system s: SystemSnapshot) {
        switch id {
        case .cpu:
            if let c = s.cpu {
                figure.stringValue = Format.percent(c.total)
                var text = "User \(Format.percent(c.user)), system \(Format.percent(c.system))"
                if let load = c.loadAverage.first { text += String(format: ", load %.2f", load) }
                detail.stringValue = text
            }
        case .memory:
            if let m = s.memory {
                figure.stringValue = Format.memory(m.used)
                let pressure = m.pressure == .normal ? "normal" : (m.pressure == .warning ? "elevated" : "critical")
                detail.stringValue = "of \(Format.memory(m.total)). App \(Format.memory(m.app)), wired \(Format.memory(m.wired)), compressed \(Format.memory(m.compressed)), swap \(Format.memory(m.swapUsed)). Pressure \(pressure)."
                figure.textColor = m.pressure == .normal ? .labelColor : .systemRed
                chart.ceiling = Float(m.total)
            }
        case .energy:
            if let p = s.power, let cpu = p.cpu {
                let total = cpu + (p.gpu ?? 0) + (p.ane ?? 0)
                figure.stringValue = Format.watts(total)
                detail.stringValue = "CPU \(Format.watts(cpu)), GPU \(Format.watts(p.gpu ?? 0)), Neural Engine \(Format.watts(p.ane ?? 0))"
            } else if let b = s.battery, let watts = b.watts {
                figure.stringValue = Format.watts(abs(watts))
                detail.stringValue = watts < 0 ? "Drawn from the battery" : "Going into the battery"
            } else {
                figure.stringValue = "–"
                detail.stringValue = "Chip power is not readable on this Mac"
            }
        case .disk:
            if let d = s.disk {
                figure.stringValue = Format.rate(d.readBytesPerSecond + d.writeBytesPerSecond)
                detail.stringValue = "Read \(Format.rate(d.readBytesPerSecond)), write \(Format.rate(d.writeBytesPerSecond)). \(Format.bytes(d.volumeFree)) free of \(Format.bytes(d.volumeTotal))."
            }
        case .network:
            if let n = s.network {
                figure.stringValue = Format.rate(n.receivedBytesPerSecond)
                detail.stringValue = "down, \(Format.rate(n.sentBytesPerSecond)) up"
            }
        case .gpu:
            if let g = s.gpu {
                figure.stringValue = g.utilization.map { Format.percent($0) } ?? "–"
                var parts = [g.name]
                if let cores = g.coreCount { parts.append("\(cores) cores") }
                if let mem = g.memoryUsed { parts.append("\(Format.memory(mem)) in use") }
                detail.stringValue = parts.joined(separator: ", ")
            }
        default: break
        }
        let minute = Int(Date().timeIntervalSince1970 / 60)
        if minute != lastChartMinute || chart.values.isEmpty {
            lastChartMinute = minute
            refreshChart()
        }
    }

    func update(table processTable: ProcessTable) {
        guard id != .gpu else {
            note.stringValue = "Wisp does not measure GPU time per app yet, so this page shows the GPU as a whole."
            lines = []
            table.reloadData()
            return
        }
        if id == .network, !processTable.networkMeasured {
            note.stringValue = "Per-app traffic is not available on this Mac."
        } else {
            note.stringValue = ""
        }
        note.isHidden = note.stringValue.isEmpty

        let summaries = delegate.monitor.history.summaries(minutes: spanMinutes)
        var byID: [String: Line] = [:]
        for app in processTable.apps {
            byID[app.id] = Line(id: app.id, name: app.name, kind: app.kind, bundlePath: app.bundlePath, now: nowValue(app), span: 0)
        }
        for summary in summaries {
            let value = spanValue(summary)
            if var line = byID[summary.id] {
                line.span = value
                byID[summary.id] = line
            } else if value > 0 {
                byID[summary.id] = Line(id: summary.id, name: summary.name, kind: summary.kind, bundlePath: summary.bundlePath, now: 0, span: value)
            }
        }
        let selected = table.selectedRow >= 0 && table.selectedRow < lines.count ? lines[table.selectedRow].id : nil
        lines = byID.values.filter { $0.now > 0 || $0.span > 0 }
            .sorted { ($0.now, $0.span, $1.name) > ($1.now, $1.span, $0.name) }
        if lines.count > 200 { lines.removeLast(lines.count - 200) }
        table.reloadData()
        if let selected, let index = lines.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    private func nowValue(_ app: AppGroup) -> Double {
        switch id {
        case .cpu: return app.cpu
        case .memory: return Double(app.memory)
        case .energy: return app.watts
        case .disk: return app.diskPerSecond
        case .network: return app.networkPerSecond
        default: return 0
        }
    }

    private func spanValue(_ summary: HistoryStore.AppSummary) -> Double {
        switch id {
        case .cpu: return summary.cpu
        case .memory: return summary.memoryPeak
        case .energy: return summary.energyWh
        case .disk: return summary.diskBytes
        case .network: return summary.networkBytes
        default: return 0
        }
    }

    private func text(now value: Double) -> String {
        guard value > 0 else { return "–" }
        switch id {
        case .cpu: return Style.appCPU(value, machine: delegate.settings.cpuOfMachine, coreCount: delegate.table.coreCount)
        case .memory: return Format.memory(value)
        case .energy: return Format.watts(value)
        case .disk, .network: return Format.rate(value)
        default: return ""
        }
    }

    private func text(span value: Double) -> String {
        guard value > 0 else { return "–" }
        switch id {
        case .cpu: return Style.appCPU(value, machine: delegate.settings.cpuOfMachine, coreCount: delegate.table.coreCount)
        case .memory: return Format.memory(value)
        case .energy: return value < 1 ? String(format: "%.0f mWh", value * 1000) : String(format: "%.1f Wh", value)
        case .disk, .network: return Format.bytes(value)
        default: return ""
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let line = lines[row]
        if id.rawValue == "name" {
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NameCell) ?? NameCell(identifier: id)
            cell.set(icon: Icons.icon(id: line.id, kind: line.kind, bundlePath: line.bundlePath), name: line.name,
                     note: line.now == 0 ? "not running" : nil)
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FigureCell) ?? FigureCell(identifier: id)
        cell.set(id.rawValue == "now" ? text(now: line.now) : text(span: line.span), faint: line.now == 0)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < lines.count else { return onSelect(nil) }
        onSelect(.app(lines[table.selectedRow].id))
    }
}
