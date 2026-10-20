import AppKit
import WispCore

/// The right-hand panel: everything known about the selected app or process.
/// Signature checks run off the main thread and only for the process on show.
@MainActor
final class InspectorController: NSViewController {
    private unowned let delegate: AppDelegate
    private var selection: Selection?
    private let stack = Style.stack([], axis: .vertical, spacing: Style.gap, alignment: .leading)
    private let empty = Style.secondary("Select an app or a process", font: Style.body)

    private let icon = NSImageView()
    private let heading = Style.label("", font: NSFont.systemFont(ofSize: 15, weight: .semibold))
    private let subtitle = Style.secondary()
    private let figures = NSGridView()
    private var figureLabels: [String: NSTextField] = [:]
    private let cpuChart = HistoryChart()
    private let memoryChart = HistoryChart()
    private let facts = NSGridView()
    private let commandLine = NSTextField(wrappingLabelWithString: "")
    private let actions = Style.stack([], axis: .horizontal)
    private var detailsToken = 0

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        heading.maximumNumberOfLines = 2
        heading.lineBreakMode = .byWordWrapping
        let titles = Style.stack([heading, subtitle], axis: .vertical, spacing: 2, alignment: .leading)
        let header = Style.stack([icon, titles], axis: .horizontal, spacing: Style.pad)
        header.alignment = .centerY

        figures.translatesAutoresizingMaskIntoConstraints = false
        figures.rowSpacing = Style.gap
        figures.columnSpacing = Style.pad
        for row in [["CPU", "Memory"], ["Power", "Processes"], ["Disk", "Network"]] {
            let cells = row.map { name -> NSView in
                let value = Style.label("–", font: Style.figure)
                figureLabels[name] = value
                return Style.stack([Style.secondary(name), value], axis: .vertical, spacing: 1, alignment: .leading)
            }
            figures.addRow(with: cells)
        }

        for chart in [cpuChart, memoryChart] {
            chart.translatesAutoresizingMaskIntoConstraints = false
            chart.heightAnchor.constraint(equalToConstant: 84).isActive = true
            chart.spanMinutes = 60
        }
        cpuChart.format = { [weak self] value in
            Style.appCPU(Double(value), machine: self?.delegate.settings.cpuOfMachine ?? false, coreCount: self?.delegate.table.coreCount ?? 1)
        }
        memoryChart.format = { Format.memory(Double($0)) }
        memoryChart.color = .systemPurple

        facts.translatesAutoresizingMaskIntoConstraints = false
        facts.rowSpacing = Style.unit + 1
        facts.columnSpacing = Style.gap
        commandLine.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLine.textColor = .secondaryLabelColor
        commandLine.isSelectable = true
        commandLine.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.addSubview(empty)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Style.pad + Style.unit),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -(Style.pad + Style.unit)),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Style.pad),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Style.pad),
            empty.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            empty.topAnchor.constraint(equalTo: document.topAnchor, constant: 120),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
        ])
        view = scroll

        stack.setViews([header, figures, Style.separator(), section("CPU, last hour"), cpuChart,
                        section("Memory, last hour"), memoryChart, Style.separator(), facts, commandLine, actions], in: .top)
        for view in [figures, cpuChart, memoryChart, facts, commandLine] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in stack.arrangedSubviews where view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(Style.pad, after: header)
        show(nil)
    }

    private func section(_ text: String) -> NSTextField {
        Style.label(text, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
    }

    // MARK: Selection

    func show(_ selection: Selection?) {
        guard isViewLoaded else { return }
        let changed = selection != self.selection
        self.selection = selection
        stack.isHidden = selection == nil
        empty.isHidden = selection != nil
        guard selection != nil else { return }
        if changed {
            setFacts([])
            commandLine.stringValue = ""
            commandLine.isHidden = true
            buildActions()
        }
        update(table: delegate.table)
        if changed, case .process(let pid) = selection { loadDetails(pid: pid) }
        if changed, case .app(let id) = selection, let app = delegate.table.app(id) { loadAppFacts(app) }
    }

    func update(system: SystemSnapshot) {}

    func update(table: ProcessTable) {
        guard let selection else { return }
        let machine = delegate.settings.cpuOfMachine
        switch selection {
        case .app(let id):
            let summary = delegate.monitor.history.summaries(minutes: 60).first { $0.id == id }
            guard let app = table.app(id) else {
                heading.stringValue = summary?.name ?? "Not running"
                subtitle.stringValue = "Not running"
                for label in figureLabels.values { label.stringValue = "–" }
                fillCharts(appID: id)
                return
            }
            icon.image = Icons.icon(for: app)
            icon.isHidden = false
            heading.stringValue = app.name
            subtitle.stringValue = app.bundleIdentifier ?? (app.kind == .system ? "Part of macOS" : "Command-line tool")
            figureLabels["CPU"]?.stringValue = Style.appCPU(app.cpu, machine: machine, coreCount: table.coreCount)
            figureLabels["Memory"]?.stringValue = Format.memory(app.memory)
            figureLabels["Power"]?.stringValue = app.watts > 0.005 ? Format.watts(app.watts) : "–"
            figureLabels["Processes"]?.stringValue = "\(app.processCount)" + (app.unreadable > 0 ? " (\(app.unreadable) need admin)" : "")
            figureLabels["Disk"]?.stringValue = app.diskPerSecond > 0 ? Format.rate(app.diskPerSecond) : "–"
            figureLabels["Network"]?.stringValue = table.networkMeasured ? (app.networkPerSecond > 0 ? Format.rate(app.networkPerSecond) : "–") : "Not measured"
            fillCharts(appID: id)
        case .process(let pid):
            guard let row = table.processes.first(where: { $0.pid == pid }) else {
                subtitle.stringValue = "Exited"
                return
            }
            let group = table.app(row.groupID)
            icon.image = group.map { Icons.icon(for: $0) }
            heading.stringValue = row.name
            subtitle.stringValue = "Process \(row.pid)" + (group.map { " in \($0.name)" } ?? "")
            figureLabels["CPU"]?.stringValue = row.readable ? Style.appCPU(row.cpu, machine: machine, coreCount: table.coreCount) : "–"
            figureLabels["Memory"]?.stringValue = row.readable ? Format.memory(row.memory) : "–"
            figureLabels["Power"]?.stringValue = row.watts > 0.005 ? Format.watts(row.watts) : "–"
            figureLabels["Processes"]?.stringValue = "\(table.processes.lazy.filter { $0.ppid == pid }.count) children"
            let disk = row.diskReadPerSecond + row.diskWritePerSecond
            figureLabels["Disk"]?.stringValue = disk > 0 ? Format.rate(disk) : "–"
            let net = row.networkInPerSecond + row.networkOutPerSecond
            figureLabels["Network"]?.stringValue = table.networkMeasured ? (net > 0 ? Format.rate(net) : "–") : "Not measured"
            fillCharts(appID: row.groupID)
        }
    }

    private func fillCharts(appID: String) {
        let history = delegate.monitor.history
        cpuChart.values = history.app(appID, .cpu, minutes: 60)
        memoryChart.values = history.app(appID, .memory, minutes: 60)
    }

    // MARK: Facts

    private func setFacts(_ rows: [(String, String)]) {
        facts.clear()
        for (name, value) in rows {
            let valueLabel = Style.label(value, font: Style.caption)
            valueLabel.isSelectable = true
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.toolTip = value
            facts.addRow(with: [Style.secondary(name), valueLabel])
        }
        facts.isHidden = rows.isEmpty
        if facts.numberOfColumns > 0 { facts.column(at: 0).xPlacement = .trailing }
    }

    private func loadAppFacts(_ app: AppGroup) {
        var rows: [(String, String)] = []
        if let path = app.bundlePath { rows.append(("Location", path)) }
        if let bundleID = app.bundleIdentifier { rows.append(("Bundle ID", bundleID)) }
        setFacts(rows)
        guard let main = app.pids.min() else { return }
        detailsToken += 1
        let token = detailsToken
        DispatchQueue.global(qos: .userInitiated).async {
            let signature = ProcessDetails.signature(pid: main)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detailsToken == token, let signature else { return }
                self.setFacts(rows + Self.signatureRows(signature))
            }
        }
    }

    private func loadDetails(pid: Int32) {
        detailsToken += 1
        let token = detailsToken
        let row = delegate.table.processes.first { $0.pid == pid }
        let parent = row.flatMap { r in delegate.table.processes.first { $0.pid == r.ppid } }
        DispatchQueue.global(qos: .userInitiated).async {
            let details = ProcessDetails.read(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detailsToken == token else { return }
                var rows: [(String, String)] = []
                if let parent { rows.append(("Parent", "\(parent.name) (\(parent.pid))")) }
                if let user = details.user { rows.append(("User", user)) }
                if let start = row?.startDate {
                    rows.append(("Started", start.formatted(date: .abbreviated, time: .shortened)))
                }
                if let row, row.readable { rows.append(("CPU time", Format.duration(row.cpuTime))) }
                if let path = row?.path { rows.append(("Executable", path)) }
                if let cwd = details.workingDirectory { rows.append(("Folder", cwd)) }
                if let signature = details.signature { rows += Self.signatureRows(signature) }
                self.setFacts(rows)
                self.commandLine.stringValue = details.arguments.joined(separator: " ")
                self.commandLine.isHidden = details.arguments.isEmpty
            }
        }
    }

    private static func signatureRows(_ s: ProcessDetails.Signature) -> [(String, String)] {
        var rows = [("Signed by", s.authority + (s.valid ? "" : ", not valid"))]
        if let team = s.teamID { rows.append(("Team ID", team)) }
        rows.append(("Sandbox", s.sandboxed ? "Yes" : "No"))
        rows.append(("Hardened", s.hardenedRuntime ? "Yes" : "No"))
        return rows
    }

    // MARK: Actions

    private func buildActions() {
        actions.setViews([], in: .leading)
        switch selection {
        case .app(let id):
            guard let app = delegate.table.app(id), app.kind == .app else { return }
            actions.addArrangedSubview(button("Quit", #selector(quitApp)))
            if app.bundlePath != nil { actions.addArrangedSubview(button("Show in Finder", #selector(reveal))) }
        case .process:
            actions.addArrangedSubview(button("Quit", #selector(terminateProcess)))
            actions.addArrangedSubview(button("Force Quit", #selector(killProcess)))
            actions.addArrangedSubview(button("Show in Finder", #selector(reveal)))
        case nil: break
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.controlSize = .small
        return button
    }

    @objc private func quitApp() {
        guard case .app(let id) = selection, let app = delegate.table.app(id) else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier ?? "")
        if running.isEmpty {
            for pid in app.pids { kill(pid, SIGTERM) }
        } else {
            running.forEach { $0.terminate() }
        }
    }

    @objc private func terminateProcess() {
        guard case .process(let pid) = selection else { return }
        kill(pid, SIGTERM)
    }

    @objc private func killProcess() {
        guard case .process(let pid) = selection else { return }
        let name = delegate.table.processes.first { $0.pid == pid }?.name ?? "process \(pid)"
        let alert = NSAlert()
        alert.messageText = "Force quit \(name)?"
        alert.informativeText = "It stops at once and loses anything it has not saved."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { kill(pid, SIGKILL) }
        }
    }

    @objc private func reveal() {
        var path: String?
        switch selection {
        case .app(let id): path = delegate.table.app(id)?.bundlePath
        case .process(let pid): path = delegate.table.processes.first { $0.pid == pid }?.path
        case nil: break
        }
        if let path { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    }
}

extension NSGridView {
    /// removeRow(at:) leaves the cell views in the hierarchy, so take them out first.
    func clear() {
        for row in (0..<numberOfRows).reversed() {
            for column in 0..<numberOfColumns { cell(atColumnIndex: column, rowIndex: row).contentView?.removeFromSuperview() }
            removeRow(at: row)
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
