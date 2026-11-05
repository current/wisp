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
    private let tint = A2Dev.tint(.startup)
    private let countTile: A2Tile
    private let runningTile: A2Tile
    private let cpuTile: A2Tile
    private let memoryTile: A2Tile
    private let tipsCard = CardView()
    private let tipsTitle = A2TitleRow()
    private var tipRows: [A2TipRow] = []
    private let tipRules = A2Rules()
    private let tableCard = CardView()
    private let tableTitle = A2TitleRow()
    private let table: A2Table = { let table = A2Table(); table.drawsVisibleOnly = true; return table }()
    private var sortColumn = 5
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
    private static let flaggedLimit = 3
    private static let refreshEvery: TimeInterval = 60
    /// A suggestion row's height in the mockup.
    private static let tipHeight: CGFloat = 50
    private static let sortNames = ["name", "developer", "kind", "schedule", "status", "CPU", "memory", "last day"]

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        self.onSelect = onSelect
        countTile = A2Tile("Start with this Mac", symbol: PageID.startup.symbol, tint: tint)
        runningTile = A2Tile("Running now", symbol: "play", tint: tint)
        cpuTile = A2Tile("CPU", symbol: PageID.cpu.symbol, tint: tint)
        memoryTile = A2Tile("Memory", symbol: PageID.memory.symbol, tint: tint)
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var toolbarItems: [NSView] { [scope] }

    override func loadView() {
        super.loadView()
        _ = titleLines
        for view in [countTile, runningTile, cpuTile, memoryTile, tipsCard, tableCard] as [NSView] { canvas.addSubview(view) }
        for tile in [countTile, runningTile, cpuTile, memoryTile] { tile.figure.show("–") }
        tipsCard.addSubview(tipsTitle)
        tipsCard.addSubview(tipRules)
        tipsTitle.title = "Worth a look"
        tipsCard.isHidden = true
        tableCard.addSubview(tableTitle)
        tableCard.addSubview(table)
        tableTitle.title = "Items"
        caption.text = Toolbar.subtitle("Reading launch items…")
        table.nameTitle = "Item"
        // Narrow windows let the schedule, the developer, the day's average and the kind go, in that order.
        table.columns = [.init(title: "Developer", width: 142, drop: 2), .init(title: "Kind", width: 66, drop: 4),
                         .init(title: "Runs", width: 146, drop: 1), .init(title: "Status", width: 80, kind: .status),
                         .init(title: "CPU", width: 100, kind: .meter(52), right: true), .init(title: "Memory", width: 58, right: true),
                         .init(title: "Last day", width: 54, right: true, drop: 3)]
        table.onSort = { [weak self] column in
            self?.sortColumn = column
            self?.fillTable()
        }
        table.onSelect = { [weak self] id in self?.showActions(for: id) }
        scope.onChange = { [weak self] _ in self?.refresh(force: true) }
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
        let tiles = [countTile, runningTile, cpuTile, memoryTile]
        var y: CGFloat
        if (inner - gap * 3) / 4 >= 180 {
            // The first tile is a little wider for its three counts, as in the mockup.
            let unit = (inner - gap * 3) / 4.25
            var x = margin
            for (index, tile) in tiles.enumerated() {
                let tileWidth = index == 0 ? unit * 1.25 : unit
                tile.frame = NSRect(x: x.rounded(), y: margin, width: (x + tileWidth).rounded() - x.rounded(), height: 110)
                x += tileWidth + gap
            }
            y = margin + 110 + gap
        } else {
            y = grid(tiles, top: margin, width: width, columns: 4, height: 110) + gap
        }
        let cardInner = inner - A2.padSide * 2
        if !tipsCard.isHidden {
            let shown = tipRows.filter { !$0.isHidden }
            let listTop = A2.padTop + 16 + 6
            tipsCard.frame = NSRect(x: margin, y: y, width: inner, height: listTop + CGFloat(shown.count) * Self.tipHeight + A2.padTop)
            tipsTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: cardInner, height: 16)
            tipRules.frame = NSRect(x: A2.padSide, y: listTop, width: cardInner, height: CGFloat(shown.count) * Self.tipHeight)
            for (index, row) in shown.enumerated() {
                row.frame = NSRect(x: A2.padSide, y: listTop + CGFloat(index) * Self.tipHeight, width: cardInner, height: Self.tipHeight)
            }
            y = tipsCard.frame.maxY + gap
        }
        // The table runs to the window's bottom margin when its rows fit, as in the mockup.
        let tableTop = A2.padTop + 16 + 8
        let natural = tableTop + table.naturalHeight + A2.padTop
        let room = scroll.contentSize.height - Self.topInset - margin - y
        let height = room >= natural && room <= natural * 1.4 ? room : natural
        tableCard.frame = NSRect(x: margin, y: y, width: inner, height: height)
        tableTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: cardInner, height: 16)
        table.frame = NSRect(x: A2.padSide, y: tableTop, width: cardInner, height: height - tableTop - A2.padTop)
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

    private func cpuText(_ cores: Double) -> String {
        Style.appCPU(cores, machine: delegate.settings.cpuOfMachine, coreCount: lastTable.coreCount)
    }

    private func show() {
        current = lines()
        let byKind = Dictionary(grouping: items, by: \.kind)
        countTile.figure.show("\(items.count)")
        countTile.set(sub: [(LaunchItem.Kind.agent, "agents"), (.daemon, "daemons"), (.loginItem, "login items")]
            .compactMap { kind, word in byKind[kind].map { "\($0.count) \($0.count == 1 ? String(word.dropLast()) : word)" } }
            .joined(separator: " · "))
        let running = current.filter { $0.status == .running }
        runningTile.figure.show("\(running.count)")
        let waiting = current.filter { $0.status == .loaded }.count
        runningTile.set(sub: waiting > 0 ? "\(waiting) loaded and waiting" : "")
        cpuTile.show(cpuText(running.reduce(0) { $0 + $1.cpu }))
        if let busiest = running.max(by: { $0.cpu < $1.cpu }), busiest.cpu > 0.001 {
            cpuTile.set(facts: [.init(label: "Most in", value: busiest.item.name)])
        } else {
            cpuTile.set(sub: running.isEmpty ? "" : "Idle")
        }
        memoryTile.show(Format.memory(running.reduce(0) { $0 + ($1.cost?.memory ?? 0) }))
        let watts = running.reduce(0) { $0 + ($1.cost?.watts ?? 0) }
        let between = NSMutableAttributedString(attributedString: A2.facts([.init(label: "", value: Format.watts(watts))]))
        between.append(A2.plain(" between them"))
        memoryTile.sub.text = between

        let leftovers = current.filter { $0.item.isLeftover }.count
        var parts = ["\(items.count) items", "\(running.count) running"]
        if leftovers > 0 { parts.append("\(leftovers) left over") }
        if dormant > 0, scope.selected == 0 { parts.append("\(dormant) more in apps, not turned on") }
        caption.text = Toolbar.subtitle(parts.joined(separator: " · "))

        let shape = (tipsCard.isHidden, tipRows.filter { !$0.isHidden }.count, table.rows.count)
        showTips()
        fillTable()
        if shape != (tipsCard.isHidden, tipRows.filter { !$0.isHidden }.count, table.rows.count) || !laidOut {
            laidOut = true
            relayout()
        }
    }

    private var laidOut = false

    private func reason(_ line: Line) -> String? {
        let item = line.item
        if item.isLeftover {
            if item.appMissing { return "Its app is no longer installed" }
            return item.script != nil && !item.scriptExists ? "Its script is gone" : "Its program is gone"
        }
        if item.keepAlive, line.cpu > 0.05 || (line.day ?? 0) > 0.02 {
            let usage = line.cpu > 0.05 ? line.cpu : line.day ?? 0
            return "Kept running, \(cpuText(usage)) CPU" + (line.cpu > 0.05 ? " now" : " over the day")
        }
        if let signer = line.signer, signer.unknown { return "Not signed by a known developer" }
        return nil
    }

    /// "Agent in ~/Library/LaunchAgents", or the app and who made it for a busy item.
    private func whereabouts(_ line: Line) -> String {
        let item = line.item
        if !item.isLeftover, item.keepAlive, let signer = line.signer, !signer.unknown {
            if let app = item.appPath {
                return ((app as NSString).lastPathComponent as NSString).deletingPathExtension + " by " + signer.title
            }
            return signer.title
        }
        let folder = ((item.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return "\(item.kind.title) in \(folder)"
    }

    private func showTips() {
        let rank: (Line) -> Int = { $0.item.isLeftover ? 0 : ($0.item.keepAlive && $0.cpu > 0.05 ? 1 : 2) }
        let found = current.compactMap { line in reason(line).map { (line, $0) } }
            .sorted { (rank($0.0), $0.0.item.name.lowercased()) < (rank($1.0), $1.0.item.name.lowercased()) }
        tipsCard.isHidden = found.isEmpty
        let shown = Array(found.prefix(Self.flaggedLimit))
        let more = found.count - shown.count
        let count = found.count == 1 ? "1 item" : "\(found.count) items"
        tipsTitle.items = [.init(text: more > 0 ? "\(count), first \(shown.count) shown" : count)]
        while tipRows.count < shown.count {
            let row = A2TipRow()
            tipsCard.addSubview(row)
            tipRows.append(row)
        }
        for (index, row) in tipRows.enumerated() {
            if row.isHidden != (index >= shown.count) { row.isHidden = index >= shown.count }
            guard index < shown.count else { continue }
            let (line, why) = shown[index]
            let item = line.item
            let symbol: String, tint: NSColor
            if item.isLeftover {
                (symbol, tint) = ("trash", A2.power)
            } else if line.signer?.unknown == true, !(item.keepAlive && line.cpu > 0.05) {
                (symbol, tint) = ("exclamationmark.shield", A2.warn)
            } else {
                (symbol, tint) = ("flame", Theme.dynamic(0xE6A700, 0xFFD60A))
            }
            let (button, action) = primaryAction(line)
            let detail = why + " · " + whereabouts(line)
            // Rows are redrawn only when what they say changes, not on every update.
            let key = [symbol, item.id, detail, button].joined(separator: "|")
            if index >= tipKeys.count { tipKeys.append("") }
            if tipKeys[index] != key {
                tipKeys[index] = key
                row.set(symbol: symbol, tint: tint, title: item.name, detail: detail, button: button, action: action)
            }
        }
        // The rules between rows are drawn by the card's own bitmap: a row with `showsRule`
        // on gets an asynchronously drawn layer from AppKit (WISP_LAYER_REPORT).
        tipRules.lines = (1..<max(1, shown.count)).map { CGFloat($0) * Self.tipHeight }
    }

    private var tipKeys: [String] = []

    /// The one action a suggestion offers: trash a leftover the user owns, show what is
    /// running, or reveal the file.
    private func primaryAction(_ line: Line) -> (String, () -> Void) {
        let item = line.item
        if item.canTrash, line.status != .running, item.path.hasPrefix(NSHomeDirectory() + "/") {
            return ("Move to Trash…", { [weak self] in self?.confirmTrash(item) })
        }
        if !item.isLeftover, let app = item.appPath, FileManager.default.fileExists(atPath: app) {
            return ("Show", { [weak self] in self?.onSelect(.app(app)) })
        }
        if !item.isLeftover, let pid = line.cost?.pids.first {
            return ("Show", { [weak self] in self?.onSelect(.process(pid)) })
        }
        return ("Reveal in Finder", { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) })
    }

    private func fillTable() {
        let column = sortColumn
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
            let (icon, glyph) = look(for: line.item)
            return A2Table.Row(id: line.item.id, icon: icon, glyph: glyph, name: line.item.name,
                               cells: [developer(line), line.item.kind.title, line.item.schedule, status,
                                       line.cost.map { cpuText($0.cpu) } ?? "–",
                                       line.cost.flatMap { $0.memory > 0 ? Format.memory($0.memory) : nil } ?? "–",
                                       line.day.map { cpuText($0) } ?? "–"],
                               fraction: line.cpu / peak, dot: line.status == .running ? A2Dev.live : A2Dev.quiet,
                               tag: line.item.isLeftover ? "Left over" : nil, faint: line.status != .running)
        }
        tableTitle.items = items.isEmpty ? [] : [.init(text: "\(items.count)"), .init(text: "Sorted by " + Self.sortNames[min(column, 7)])]
    }

    private func developer(_ line: Line) -> String {
        if let signer = line.signer { return signer.title }
        return line.item.isLeftover ? "–" : "Unknown developer"
    }

    /// The app's icon when the item belongs to an installed app, otherwise a terminal glyph.
    private func look(for item: LaunchItem) -> (NSImage?, String?) {
        if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
            return (Icons.icon(id: app, kind: .app, bundlePath: app), nil)
        }
        return (nil, "apple.terminal")
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
