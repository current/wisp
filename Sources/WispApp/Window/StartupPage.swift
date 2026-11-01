import AppKit
import WispCore

/// What launchd starts with this Mac and the user's session: agents, daemons and
/// login items, who made them, whether they run now and what they cost.
///
/// The plists and signatures are read when the page opens and once a minute while
/// it stays open, on a utility queue. Each update in between only joins the cached
/// items with the process table.
@MainActor
final class StartupPage: CardPage {
    override var pageTint: NSColor { PageID.startup.tint }
    private lazy var titleLines = heading("Login & Background")
    private var caption: TextLine { titleLines.1 }
    private let scope = Segmented(["Third Party", "Everything"])
    private let countTile = Tile("Start with this Mac"), runningTile = Tile("Running now"), cpuTile = Tile("CPU"), memoryTile = Tile("Memory")
    private let flagged = ListCard()
    private let tableCard = CardView()
    private let tableTitle = TextLine()
    private let table: ColumnTable = { let table = ColumnTable(); table.drawsVisibleOnly = true; return table }()
    private let onSelect: (Selection?) -> Void

    private let job = StartupJob()
    private var items: [LaunchItem] = []
    private var signers: [String: Signer] = [:]
    private var state = LaunchdState()
    private var dormant = 0
    private var scannedAt = Date.distantPast
    private var scanning = false
    private var scanned = false
    private var dayCPU: [String: Double] = [:]
    private var dayMinute = 0
    private var lastTable = ProcessTable()
    private static let flaggedLimit = 8
    private static let refreshEvery: TimeInterval = 60

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        self.onSelect = onSelect
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var toolbarItems: [NSView] { [scope] }

    override func loadView() {
        super.loadView()
        _ = titleLines
        for view in [countTile, runningTile, cpuTile, memoryTile, flagged, tableCard] as [NSView] { canvas.addSubview(view) }
        tableCard.addSubview(tableTitle)
        tableCard.addSubview(table)
        let symbols = [(countTile, "power"), (runningTile, "play.fill"), (cpuTile, "cpu"), (memoryTile, "memorychip")]
        for (tile, symbol) in symbols {
            tile.tint = pageTint
            tile.caption.text = Theme.header(tile.name, symbol: symbol, tint: pageTint)
            tile.set(text: "–")
        }
        flagged.title.text = title("Worth a look", symbol: "lightbulb.fill", detail: "")
        flagged.isHidden = true
        tableTitle.text = title("Items", symbol: "list.bullet", detail: "")
        caption.text = Theme.caption("Reading launch items…")
        table.columns = [.init(title: "Item", width: 0), .init(title: "Developer", width: 130, right: false),
                         .init(title: "Kind", width: 64, right: false), .init(title: "Runs", width: 170, right: false),
                         .init(title: "Status", width: 74, right: false), .init(title: "CPU", width: 90, bar: true),
                         .init(title: "Memory", width: 64), .init(title: "Last day", width: 60)]
        table.sortColumn = 5
        table.onSort = { [weak self] _ in self?.fillTable() }
        table.onSelect = { [weak self] id in self?.showActions(for: id) }
        scope.onChange = { [weak self] _ in self?.refresh(force: true) }
    }

    private func title(_ name: String, symbol: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: Theme.header(name, symbol: symbol, tint: pageTint, size: 14, tile: 20,
                                                                            color: Theme.ink, weight: .semibold))
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: Theme.sans(13), .foregroundColor: Theme.inkTertiary]))
        }
        return text
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        job.open = true
        refresh(force: false)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // A scan in flight stops at its next file and its result is dropped.
        job.open = false
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = grid([countTile, runningTile, cpuTile, memoryTile], top: margin, width: width, columns: 4, height: 104) + gap
        if !flagged.isHidden {
            flagged.frame = NSRect(x: margin, y: y, width: inner, height: flagged.wantedHeight)
            y = flagged.frame.maxY + gap
        }
        tableTitle.frame = NSRect(x: 20, y: 16, width: inner - 40, height: 20)
        let tableHeight = max(table.naturalHeight, table.headerHeight + table.rowHeight)
        table.frame = NSRect(x: 12, y: 44, width: inner - 24, height: tableHeight)
        tableCard.frame = NSRect(x: margin, y: y, width: inner, height: tableHeight + 56)
        return tableCard.frame.maxY + margin
    }

    // MARK: Reading

    /// Reads launchd's state, the plists and new signatures off the main thread.
    private func refresh(force: Bool) {
        guard !scanning, force || Date().timeIntervalSince(scannedAt) > Self.refreshEvery else { return }
        scanning = true
        let includeApple = scope.selected == 1
        let known = signers
        let job = self.job
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = LaunchdState.read()
            let result = LaunchItemScanner().scan(includeApple: includeApple, state: state, appForBundleID: { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
            }, cancelled: { !job.open })
            var signers = known
            for item in result.items {
                guard job.open else { break }
                guard let path = item.signedPath, signers[path] == nil else { continue }
                if item.isApple, path.hasPrefix("/System/") || path.hasPrefix("/usr/") {
                    signers[path] = Signer(apple: true)
                } else {
                    signers[path] = Signer.read(path: path) ?? Signer()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                guard job.open, includeApple == (self.scope.selected == 1) else {
                    // Closed meanwhile, or the switch moved: read again next time.
                    if job.open { self.refresh(force: true) }
                    return
                }
                self.scannedAt = Date()
                self.scanned = true
                self.items = result.items
                self.dormant = result.dormant
                self.state = state
                self.signers = signers
                self.dayMinute = 0
                self.show()
            }
        }
    }

    override func update(table: ProcessTable) {
        lastTable = table
        job.open = true
        refresh(force: false)
        guard scanned else { return }
        show()
    }

    // MARK: Showing

    private struct Line {
        let item: LaunchItem
        let status: LaunchdState.Status
        let cost: LaunchItemCost?
        let day: Double?
        let signer: Signer?
        var cpu: Double { cost?.cpu ?? 0 }
    }

    private func lines() -> [Line] {
        let costs = LaunchItemCost.join(items, state: state, table: lastTable)
        updateDayCPU()
        return items.map { item in
            var status = state.status(of: item)
            if costs[item.id] != nil, status != .running { status = .running }
            return Line(item: item, status: status, cost: costs[item.id], day: dayCPU[item.id],
                        signer: item.signedPath.flatMap { signers[$0] })
        }
    }

    /// The average CPU over the last day, for items that run as their own program
    /// (Wisp's history keeps apps as a whole, so helpers inside an app are left out).
    private func updateDayCPU() {
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard minute != dayMinute else { return }
        dayMinute = minute
        let history = delegate.monitor.history
        var values: [String: Double] = [:]
        for item in items {
            guard let program = item.program, item.script == nil else { continue }
            let identity = AppGrouping.identity(path: program, name: item.name)
            guard identity.kind == .tool else { continue }
            let samples = history.app(identity.id, .cpu).filter { !$0.isNaN }
            guard !samples.isEmpty else { continue }
            // Minutes it did not run count as zero.
            values[item.id] = Double(samples.reduce(0, +)) / Double(HistoryStore.minutes)
        }
        dayCPU = values
    }

    private var current: [Line] = []

    private func show() {
        current = lines()
        let machine = delegate.settings.cpuOfMachine
        let cores = lastTable.coreCount
        let byKind = Dictionary(grouping: items, by: \.kind)
        countTile.set(text: "\(items.count)")
        countTile.set(note: [(LaunchItem.Kind.agent, "agents"), (.daemon, "daemons"), (.loginItem, "login items")]
            .compactMap { kind, word in byKind[kind].map { "\($0.count) \($0.count == 1 ? String(word.dropLast()) : word)" } }
            .joined(separator: " · "))
        let running = current.filter { $0.status == .running }
        runningTile.set(text: "\(running.count)")
        let waiting = current.filter { $0.status == .loaded }.count
        runningTile.set(note: waiting > 0 ? "\(waiting) loaded and waiting" : "")
        let cpu = running.reduce(0) { $0 + $1.cpu }
        cpuTile.set(text: Style.appCPU(cpu, machine: machine, coreCount: cores))
        cpuTile.set(note: running.max { $0.cpu < $1.cpu }.map { $0.cpu > 0.001 ? "Most in \($0.item.name)" : "Idle" } ?? "")
        let (value, unit) = DashboardView.split(Format.memory(running.reduce(0) { $0 + ($1.cost?.memory ?? 0) }))
        memoryTile.set(text: value, unit: unit)
        let watts = running.reduce(0) { $0 + ($1.cost?.watts ?? 0) }
        memoryTile.set(note: "\(Format.watts(watts)) between them")

        let leftovers = current.filter { $0.item.isLeftover }.count
        var parts = ["\(items.count) items", "\(running.count) running"]
        if leftovers > 0 { parts.append("\(leftovers) left over") }
        if dormant > 0, scope.selected == 0 { parts.append("\(dormant) more in apps, not turned on") }
        caption.text = Theme.caption(parts.joined(separator: " · "))

        let shape = (flagged.isHidden, flagged.rows.filter { !$0.isHidden }.count, table.rows.count)
        showFlagged(machine: machine, cores: cores)
        fillTable()
        if shape != (flagged.isHidden, flagged.rows.filter { !$0.isHidden }.count, table.rows.count) || !laidOut {
            laidOut = true
            relayout()
        }
    }

    private var laidOut = false

    private func reason(_ line: Line, machine: Bool, cores: Int) -> String? {
        let item = line.item
        if item.isLeftover {
            if item.appMissing { return "Its app is no longer installed" }
            return item.script != nil && !item.scriptExists ? "Its script is gone" : "Its program is gone"
        }
        if item.keepAlive, line.cpu > 0.05 || (line.day ?? 0) > 0.02 {
            let usage = line.cpu > 0.05 ? line.cpu : line.day ?? 0
            return "Kept running, \(Style.appCPU(usage, machine: machine, coreCount: cores)) CPU" + (line.cpu > 0.05 ? " now" : " over the day")
        }
        if let signer = line.signer, signer.unknown { return "Not signed by a known developer" }
        return nil
    }

    private func showFlagged(machine: Bool, cores: Int) {
        let rank: (Line) -> Int = { $0.item.isLeftover ? 0 : ($0.item.keepAlive && $0.cpu > 0.05 ? 1 : 2) }
        let found = current.compactMap { line in reason(line, machine: machine, cores: cores).map { (line, $0) } }
            .sorted { (rank($0.0), $0.0.item.name.lowercased()) < (rank($1.0), $1.0.item.name.lowercased()) }
        flagged.isHidden = found.isEmpty
        let shown = Array(found.prefix(Self.flaggedLimit))
        let more = found.count - shown.count
        flagged.title.text = title("Worth a look", symbol: "lightbulb.fill",
                                   detail: more > 0 ? "\(found.count), first \(shown.count) shown" : "\(found.count)")
        flagged.set(count: shown.count) { [weak self] row, index in
            let (line, why) = shown[index]
            row.icon = self?.icon(for: line.item)
            row.name = line.item.name
            row.note = why
            row.showsBar = false
            row.value = ""
            row.onClick = { self?.showActions(for: line.item.id) }
        }
    }

    private func fillTable() {
        let machine = delegate.settings.cpuOfMachine
        let cores = lastTable.coreCount
        let column = table.sortColumn
        let sorted = current.sorted { a, b in
            func key(_ line: Line) -> Double {
                switch column {
                case 6: return Double(line.cost?.memory ?? 0)
                case 7: return line.day ?? -1
                case 4: return line.status == .running ? 3 : line.status == .loaded ? 2 : line.status == .off ? 1 : 0
                default: return line.cpu + (line.status == .running ? 1e-6 : 0)
                }
            }
            if column >= 1 && column <= 3 {
                let pick: (Line) -> String = { [unowned self] line in
                    column == 1 ? self.developer(line) : column == 2 ? line.item.kind.title : line.item.schedule
                }
                return (pick(a), a.item.name.lowercased()) < (pick(b), b.item.name.lowercased())
            }
            if column == 0 { return a.item.name.lowercased() < b.item.name.lowercased() }
            let (ka, kb) = (key(a), key(b))
            return ka != kb ? ka > kb : a.item.name.lowercased() < b.item.name.lowercased()
        }
        let peak = max(sorted.map(\.cpu).max() ?? 0, 0.0001)
        table.rows = sorted.map { line in
            let status: String
            switch line.status {
            case .running: status = "Running"
            case .loaded: status = "Waiting"
            case .off: status = "Turned off"
            case .notLoaded: status = "Not loaded"
            }
            return ColumnTable.Row(id: line.item.id, icon: icon(for: line.item),
                                   cells: [line.item.name, Self.fit(developer(line), 130), line.item.kind.title, Self.fit(line.item.schedule, 170), status,
                                           line.cost.map { Style.appCPU($0.cpu, machine: machine, coreCount: cores) } ?? "–",
                                           line.cost.flatMap { $0.memory > 0 ? Format.memory($0.memory) : nil } ?? "–",
                                           line.day.map { Style.appCPU($0, machine: machine, coreCount: cores) } ?? "–"],
                                   fraction: line.cpu / peak, faint: line.status != .running)
        }
        tableTitle.text = title("Items", symbol: "list.bullet", detail: items.isEmpty ? "" : "\(items.count)")
    }

    /// Cuts text to a column's width with an ellipsis; the table draws other columns without truncating.
    private static func fit(_ text: String, _ width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(12.5)]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
        var cut = text
        while !cut.isEmpty, ((cut + "…") as NSString).size(withAttributes: attributes).width > width { cut.removeLast() }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private func developer(_ line: Line) -> String {
        if let signer = line.signer { return signer.title }
        return line.item.isLeftover ? "–" : "Unknown developer"
    }

    private func icon(for item: LaunchItem) -> NSImage {
        if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
            return Icons.icon(id: app, kind: .app, bundlePath: app)
        }
        return Icons.icon(id: "tool:" + (item.program ?? item.label), kind: .tool, bundlePath: nil)
    }

    // MARK: Actions

    private func showActions(for id: String) {
        guard let line = current.first(where: { $0.item.id == id }) else { return }
        let item = line.item
        let menu = NSMenu()
        menu.addItem(ActionItem("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        })
        if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            menu.addItem(ActionItem("Show \(name)") { [weak self] in self?.onSelect(.app(app)) })
        } else if let pid = line.cost?.pids.first {
            menu.addItem(ActionItem("Show Process") { [weak self] in self?.onSelect(.process(pid)) })
        }
        menu.addItem(ActionItem("Open Login Items Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
        })
        if item.canTrash, line.status != .running {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Move to Trash…") { [weak self] in self?.confirmTrash(item) })
        }
        let point = view.window?.mouseLocationOutsideOfEventStream ?? .zero
        menu.popUp(positioning: nil, at: canvas.convert(point, from: nil), in: canvas)
    }

    private func confirmTrash(_ item: LaunchItem) {
        let home = NSHomeDirectory() + "/"
        guard item.canTrash, item.path.hasPrefix(home), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(item.name) to the Trash?"
        alert.informativeText = "\((item.path as NSString).abbreviatingWithTildeInPath) points to a program that is no longer on this Mac. "
            + "Once it is in the Trash it stops loading at login."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)]) { _, error in
                DispatchQueue.main.async {
                    if error != nil { NSSound.beep() }
                    self?.refresh(force: true)
                }
            }
        }
    }
}

/// Lets a background scan see that the page closed.
final class StartupJob: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var open: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
