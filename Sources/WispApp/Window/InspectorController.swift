import AppKit
import WispCore

/// The right-hand panel: everything known about the selected app or process, as
/// cards on the grey ground. Signature checks run off the main thread and only for
/// the selection on show.
@MainActor
final class InspectorController: NSViewController {
    private unowned let delegate: AppDelegate
    private var selection: Selection?
    private let scroll = NSScrollView()
    private let canvas = CardPage.Canvas()
    private let empty = TextLine()

    private let header = CardView()
    private let icon = NSImageView()
    private let name = TextLine()
    private let subtitle = TextLine()
    private var buttons: [ActionButton] = []

    private let figuresCard = CardView()
    private let stats = (0..<6).map { _ in Stat() }

    private let cpuCard = CardView(), memoryCard = CardView()
    private let cpuTitle = TextLine(), memoryTitle = TextLine()
    private let cpuChart = TimeChart(), memoryChart = TimeChart()

    private let factsCard = CardView()
    private var factRows: [FactRow] = []
    private let commandCard = CardView()
    private let commandTitle = TextLine()
    private let commandLine = NSTextField(wrappingLabelWithString: "")
    private var detailsToken = 0

    private let margin: CGFloat = 14
    private let gap: CGFloat = 10

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        canvas.wantsLayer = true
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.ground
        view = scroll

        for card in [header, figuresCard, cpuCard, memoryCard, factsCard, commandCard] { canvas.addSubview(card) }
        canvas.addSubview(empty)
        empty.text = Theme.caption("Select an app or a process")
        empty.alignment = .center

        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, name, subtitle] as [NSView] { header.addSubview(view) }
        for stat in stats { figuresCard.addSubview(stat) }

        cpuTitle.text = Theme.caption("CPU · last hour")
        memoryTitle.text = Theme.caption("Memory · last hour")
        for (card, title, chart) in [(cpuCard, cpuTitle, cpuChart), (memoryCard, memoryTitle, memoryChart)] {
            card.addSubview(title)
            card.addSubview(chart)
            chart.step = 60
        }
        cpuChart.format = { [weak self] value in
            Style.appCPU(Double(value), machine: self?.delegate.settings.cpuOfMachine ?? false, coreCount: self?.delegate.table.coreCount ?? 1)
        }
        cpuChart.names = ("CPU", "")
        memoryChart.format = { Format.memory(Double($0)) }
        memoryChart.names = ("Memory", "")
        memoryChart.primaryColor = Theme.series[2]

        commandTitle.text = Theme.caption("Command")
        commandLine.font = Theme.mono(10.5, .regular)
        commandLine.textColor = Theme.inkSecondary
        commandLine.isSelectable = true
        commandCard.addSubview(commandTitle)
        commandCard.addSubview(commandLine)
        show(nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        arrange()
    }

    /// Places the cards by frame, top to bottom.
    private func arrange() {
        let width = scroll.contentSize.width
        let inner = width - margin * 2
        guard inner > 40 else { return }
        empty.frame = NSRect(x: margin, y: 140, width: inner, height: 16)
        var y = margin

        let buttonRow = buttons.isEmpty ? 0 : 36
        header.frame = NSRect(x: margin, y: y, width: inner, height: 76 + CGFloat(buttonRow))
        icon.frame = NSRect(x: 16, y: 18, width: 40, height: 40)
        name.frame = NSRect(x: 66, y: 18, width: inner - 82, height: 20)
        subtitle.frame = NSRect(x: 66, y: 42, width: inner - 82, height: 14)
        var x: CGFloat = 16
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: 76, width: size.width, height: size.height)
            x += size.width + 8
        }
        y = header.frame.maxY + gap

        let cell = (inner - 32 - 12) / 2
        figuresCard.frame = NSRect(x: margin, y: y, width: inner, height: 3 * 40 + 22)
        for (index, stat) in stats.enumerated() {
            stat.frame = NSRect(x: 16 + CGFloat(index % 2) * (cell + 12), y: 14 + CGFloat(index / 2) * 40, width: cell, height: 34)
        }
        y = figuresCard.frame.maxY + gap

        for (card, title, chart) in [(cpuCard, cpuTitle, cpuChart), (memoryCard, memoryTitle, memoryChart)] {
            card.frame = NSRect(x: margin, y: y, width: inner, height: 132)
            title.frame = NSRect(x: 16, y: 14, width: inner - 32, height: 14)
            chart.frame = NSRect(x: 16, y: 36, width: inner - 32, height: 84)
            y = card.frame.maxY + gap
        }

        let shownFacts = factRows.filter { !$0.isHidden }
        factsCard.isHidden = shownFacts.isEmpty || selection == nil
        if !factsCard.isHidden {
            factsCard.frame = NSRect(x: margin, y: y, width: inner, height: CGFloat(shownFacts.count) * 22 + 20)
            for (index, row) in shownFacts.enumerated() {
                row.frame = NSRect(x: 16, y: 10 + CGFloat(index) * 22, width: inner - 32, height: 22)
            }
            y = factsCard.frame.maxY + gap
        }

        commandCard.isHidden = commandLine.stringValue.isEmpty || selection == nil
        if !commandCard.isHidden {
            commandLine.preferredMaxLayoutWidth = inner - 32
            let height = min(160, ceil(commandLine.sizeThatFits(NSSize(width: inner - 32, height: 1000)).height))
            commandCard.frame = NSRect(x: margin, y: y, width: inner, height: height + 48)
            commandTitle.frame = NSRect(x: 16, y: 14, width: inner - 32, height: 14)
            commandLine.frame = NSRect(x: 16, y: 34, width: inner - 32, height: height)
            y = commandCard.frame.maxY + gap
        }

        let height = max(y + margin - gap, scroll.contentSize.height)
        if canvas.frame.size != NSSize(width: width, height: height) {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    // MARK: Selection

    func show(_ selection: Selection?) {
        guard isViewLoaded else { return }
        let changed = selection != self.selection
        self.selection = selection
        for card in [header, figuresCard, cpuCard, memoryCard, factsCard, commandCard] { card.isHidden = selection == nil }
        empty.isHidden = selection != nil
        guard selection != nil else { return arrange() }
        if changed {
            setFacts([])
            commandLine.stringValue = ""
            buildActions()
        }
        update(table: delegate.table)
        if changed, case .process(let pid) = selection { loadDetails(pid: pid) }
        if changed, case .app(let id) = selection, let app = delegate.table.app(id) { loadAppFacts(app) }
        arrange()
    }

    func update(system: SystemSnapshot) {}

    func update(table: ProcessTable) {
        guard let selection else { return }
        let machine = delegate.settings.cpuOfMachine
        let values: [(String, String)]
        switch selection {
        case .app(let id):
            guard let app = table.app(id) else {
                let summary = delegate.monitor.history.summaries(minutes: 60).first { $0.id == id }
                setTitle(summary?.name ?? "Not running", "Not running")
                for stat in stats { stat.set(("", "")) }
                fillCharts(appID: id)
                return
            }
            icon.image = Icons.icon(for: app)
            setTitle(app.name, app.bundleIdentifier ?? (app.kind == .system ? "Part of macOS" : "Command-line tool"))
            values = [("CPU", Style.appCPU(app.cpu, machine: machine, coreCount: table.coreCount)),
                      ("Memory", Format.memory(app.memory)),
                      ("Power", app.watts > 0.005 ? Format.watts(app.watts) : "–"),
                      ("Processes", "\(app.processCount)" + (app.unreadable > 0 ? ", \(app.unreadable) need admin" : "")),
                      ("Disk", app.diskPerSecond > 0 ? Format.rate(app.diskPerSecond) : "–"),
                      ("Network", table.networkMeasured ? (app.networkPerSecond > 0 ? Format.rate(app.networkPerSecond) : "–") : "Not measured")]
            fillCharts(appID: id)
        case .process(let pid):
            guard let row = table.processes.first(where: { $0.pid == pid }) else {
                setTitle(name.text.string, "Exited")
                return
            }
            let group = table.app(row.groupID)
            icon.image = group.map { Icons.icon(for: $0) }
            setTitle(row.name, "Process \(row.pid)" + (group.map { " in \($0.name)" } ?? ""))
            let disk = row.diskReadPerSecond + row.diskWritePerSecond
            let net = row.networkInPerSecond + row.networkOutPerSecond
            values = [("CPU", row.readable ? Style.appCPU(row.cpu, machine: machine, coreCount: table.coreCount) : "–"),
                      ("Memory", row.readable ? Format.memory(row.memory) : "–"),
                      ("Power", row.watts > 0.005 ? Format.watts(row.watts) : "–"),
                      ("Children", "\(table.processes.lazy.filter { $0.ppid == pid }.count)"),
                      ("Disk", disk > 0 ? Format.rate(disk) : "–"),
                      ("Network", table.networkMeasured ? (net > 0 ? Format.rate(net) : "–") : "Not measured")]
            fillCharts(appID: row.groupID)
        }
        for (stat, value) in zip(stats, values) { stat.set(value) }
    }

    private func setTitle(_ title: String, _ detail: String) {
        name.text = NSAttributedString(string: title, attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink])
        subtitle.text = Theme.caption(detail, size: 9.5)
    }

    private func fillCharts(appID: String) {
        let history = delegate.monitor.history
        cpuChart.primary = history.app(appID, .cpu, minutes: 60)
        memoryChart.primary = history.app(appID, .memory, minutes: 60)
    }

    // MARK: Facts

    private func setFacts(_ rows: [(String, String)]) {
        while factRows.count < rows.count {
            let row = FactRow()
            factsCard.addSubview(row)
            factRows.append(row)
        }
        for (index, row) in factRows.enumerated() {
            row.isHidden = index >= rows.count
            if index < rows.count { row.set(rows[index]) }
        }
        arrange()
    }

    private func loadAppFacts(_ app: AppGroup) {
        var rows: [(String, String)] = []
        if let path = app.bundlePath { rows.append(("Location", path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
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
                if let path = row?.path { rows.append(("Executable", path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
                if let cwd = details.workingDirectory { rows.append(("Folder", cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
                if let signature = details.signature { rows += Self.signatureRows(signature) }
                self.commandLine.stringValue = details.arguments.joined(separator: " ")
                self.setFacts(rows)
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
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        switch selection {
        case .app(let id):
            guard let app = delegate.table.app(id), app.kind == .app else { break }
            buttons.append(button("Quit", #selector(quitApp)))
            if app.bundlePath != nil { buttons.append(button("Show in Finder", #selector(reveal))) }
        case .process:
            buttons = [button("Quit", #selector(terminateProcess)), button("Force Quit", #selector(killProcess)),
                       button("Show in Finder", #selector(reveal))]
        case nil: break
        }
        buttons.forEach(header.addSubview)
    }

    private func button(_ title: String, _ action: Selector) -> ActionButton {
        let button = ActionButton(title: title, target: self, action: action)
        button.secondary = true
        button.font = Theme.sans(12, .medium)
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

/// A name on the left and its value on the right, shortened in the middle so the
/// end of a path stays readable. The full value is in the tooltip.
final class FactRow: DrawnView {
    private var pair = ("", "")

    func set(_ pair: (String, String)) {
        guard pair != self.pair else { return }
        self.pair = pair
        toolTip = pair.1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let key = Theme.caption(pair.0, size: 9.5)
        key.draw(at: NSPoint(x: 0, y: (bounds.height - key.size().height) / 2))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingMiddle
        let left: CGFloat = 92
        (pair.1 as NSString).draw(with: NSRect(x: left, y: (bounds.height - 15) / 2, width: bounds.width - left, height: 16),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { pair.0 + " " + pair.1 }
}
