import AppKit
import WispCore

/// Storage: where the space on the startup disk goes, above the live disk activity
/// the Disk page always had. Folder sizes come from `StorageIndex`, which works only
/// while this page is on screen.
@MainActor
final class StoragePage: DiskPage {
    private enum Level: Equatable {
        case mac
        case folder(String)
        case category(StorageCategory)
        case row(String)
    }

    private let index = StorageIndex()
    private var state = StorageState()
    private let home = NSHomeDirectory()
    private lazy var stack: [Level] = [.mac, .folder(home)]
    private var onDemand: [String: FolderNode] = [:]
    private var measuring: Set<String> = []
    private var visible = false
    private var notice: String?
    /// The list under the bar shows this many rows until asked for the rest.
    private static let shortList = 12
    private var expanded = false

    private let barCard = CardView(), barTitle = TextLine(), barFigure = TextLine(), barStatus = TextLine()
    private let bar = DiskBar(), legend = DiskLegend(), tooltip = Tooltip()
    private lazy var rescanButton = SymbolButton(symbol: "arrow.clockwise", label: "Measure again", target: self, action: #selector(rescan))
    private let accessNote = TextLine()
    private lazy var accessButton: ActionButton = {
        let button = ActionButton(title: "Open Privacy Settings", target: self, action: #selector(openAccessSettings))
        button.secondary = true
        return button
    }()

    private let detailCard = CardView(), crumbs = Breadcrumb(), detailNote = TextLine(), list = StorageList()
    private lazy var revealButton: ActionButton = {
        let button = ActionButton(title: "Reveal in Finder", target: self, action: #selector(revealCurrent))
        button.secondary = true
        return button
    }()

    private let reclaimCard = CardView(), reclaimTitle = TextLine(), reclaimNote = TextLine(), reclaimList = StorageList()
    private var reclaimButtons: [ActionButton] = []
    private lazy var cleanUpButton: ActionButton = {
        let button = ActionButton(title: "Clean Up", target: self, action: #selector(openCleanUp))
        button.secondary = true
        return button
    }()
    private var reclaimItems: [ReclaimItem] = []

    private let historyCard = CardView(), historyTitle = TextLine(), chart = SpaceChart(), grewTitle = TextLine(), grewList = StorageList()
    private var history: (values: [Double], marks: [SpaceChart.Mark], grew: [SpaceHistory.Growth], since: Date?)?

    private let healthCard = CardView(), healthTitle = TextLine(), healthNote = TextLine()
    private let wear = FigureTile("Life used", symbol: "gauge.with.dots.needle.33percent", tint: PageID.disk.tint, big: false)
    private let written = FigureTile("Written", symbol: "arrow.up.doc.fill", tint: PageID.disk.tint, big: false)
    private let temperature = FigureTile("Temperature", symbol: "thermometer.medium", tint: PageID.disk.tint, big: false)
    private let spare = FigureTile("Spare blocks", symbol: "square.stack.3d.up.fill", tint: PageID.disk.tint, big: false)
    private let poweredOn = FigureTile("Powered on", symbol: "clock.fill", tint: PageID.disk.tint, big: false)

    private var storageViews: [NSView] { [barCard, detailCard, reclaimCard, historyCard, healthCard] }

    override var pageTint: NSColor { PageID.disk.tint }
    /// The Live / Hour / Day switch stays on its chart, which sits lower on this page.
    override var toolbarItems: [NSView] { [] }

    override func setUp() {
        super.setUp()
        for view in storageViews { canvas.addSubview(view) }
        for view in [barTitle, barFigure, barStatus, rescanButton, bar, legend, accessNote, accessButton] as [NSView] { barCard.addSubview(view) }
        barTitle.text = title("Startup disk", symbol: "internaldrive.fill")
        bar.onPick = { [weak self] category in self?.pick(category) }
        legend.onPick = { [weak self] category in self?.pick(category) }
        bar.onHover = { [weak self] category, rect in self?.hover(category, rect) }
        accessNote.text = Theme.caption("Some folders stay locked until Wisp has Full Disk Access", size: 11)

        for view in [crumbs, detailNote, list, revealButton] as [NSView] { detailCard.addSubview(view) }
        crumbs.onPick = { [weak self] index in self?.goBack(to: index) }
        list.onOpen = { [weak self] row in self?.open(row) }

        for view in [reclaimTitle, reclaimNote, reclaimList, cleanUpButton] as [NSView] { reclaimCard.addSubview(view) }
        reclaimTitle.text = title("Could go to the Trash", symbol: "trash.fill")

        for view in [historyTitle, chart, grewTitle, grewList] as [NSView] { historyCard.addSubview(view) }
        historyTitle.text = title("Where your space went", symbol: "chart.line.downtrend.xyaxis", detail: "Free space, last 30 days")
        chart.tint = PageID.disk.tint

        for view in [healthTitle, healthNote, wear, written, temperature, spare, poweredOn] as [NSView] { healthCard.addSubview(view) }
        healthTitle.text = title("Drive health", symbol: "heart.fill")
        healthCard.isHidden = true

        // Lists can be long; only the part on screen is drawn.
        for list in [list, reclaimList, grewList] { list.drawsVisibleOnly = true }
        index.onChange = { [weak self] state in MainActor.assumeIsolated { self?.received(state) } }
    }

    private func title(_ name: String, symbol: String, detail: String = "") -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: Theme.header(name, symbol: symbol, tint: pageTint))
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: Theme.sans(13), .foregroundColor: Theme.inkTertiary]))
        }
        return text
    }

    // MARK: Open and close

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !visible else { return }
        visible = true
        index.open()
        loadHistory()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard visible else { return }
        visible = false
        index.close()
        onDemand.removeAll()
        // Keep what is on screen, but not the trees behind it.
        state.roots = [:]
    }

    private func received(_ new: StorageState) {
        let hadSummary = state.summary != nil
        let finished = state.scanning != nil && new.scanning == nil
        state = new
        // WISP_STORAGE_PICK=developer opens one slice, for screenshots.
        if !hadSummary, let pick = ProcessInfo.processInfo.environment["WISP_STORAGE_PICK"], let category = StorageCategory(rawValue: pick) {
            self.pick(category)
        }
        refreshStorage()
        if finished || !hadSummary { loadHistory() }
    }

    @objc private func rescan() {
        onDemand.removeAll()
        index.rescan()
    }

    @objc private func openCleanUp() { delegate.showPage(.cleanup) }

    @objc private func openAccessSettings() { NSWorkspace.shared.open(StorageAccess.settingsURL) }

    // MARK: Filling in

    private func refreshStorage() {
        guard let summary = state.summary else { return }
        let volume = summary.volume
        let figure = NSMutableAttributedString(string: Format.bytes(volume.available),
                                               attributes: [.font: Theme.figure(28, .regular), .foregroundColor: Theme.ink])
        figure.append(NSAttributedString(string: "  free of \(Format.bytes(volume.capacity))",
                                         attributes: [.font: Theme.sans(15), .foregroundColor: Theme.inkSecondary]))
        if volume.purgeable > 0 {
            figure.append(NSAttributedString(string: " · \(Format.bytes(volume.availableForImportant)) once macOS clears purgeable space",
                                             attributes: [.font: Theme.sans(13), .foregroundColor: Theme.inkTertiary]))
        }
        barFigure.text = figure
        updateStatus()
        let scanned = !state.roots.isEmpty
        bar.slices = summary.segments.map { DiskBar.Slice(category: $0.category, size: scanned || [.free, .purgeable].contains($0.category) ? $0.size : 0) }
            + (scanned ? [] : [DiskBar.Slice(category: .system, size: volume.used > volume.purgeable ? volume.used - volume.purgeable : 0)])
        legend.items = summary.segments.map { segment in
            let value: String
            switch segment.category {
            case .snapshots: value = summary.snapshots.isEmpty ? "None" : "\(summary.snapshots.count) · size not reported"
            case .free, .purgeable: value = Format.bytes(segment.size)
            case .mail where !summary.fullDiskAccess && segment.size == 0: value = "Locked"
            default: value = scanned ? Format.bytes(segment.size) : "Measuring"
            }
            return DiskLegend.Item(category: segment.category, value: value)
        }
        let locked = !summary.fullDiskAccess
        accessNote.isHidden = !locked
        accessButton.isHidden = !locked

        fillDetail()
        fillReclaim(summary)
        fillHealth()
        if let history { fillHistory(history) }
        relayoutIfNeeded()
    }

    private func updateStatus() {
        var text = ""
        if let scanning = state.scanning {
            text = "Measuring \(displayName(scanning))…"
        } else if let date = state.scannedAt {
            text = "Measured " + Self.ago(date)
        }
        if let notice { text = notice }
        barStatus.text = Theme.caption(text, size: 11)
        rescanButton.isHidden = state.scanning != nil || state.roots.isEmpty
    }

    override func update(system: SystemSnapshot) {
        super.update(system: system)
        if visible, state.summary != nil { updateStatus() }
    }

    private func hover(_ category: StorageCategory?, _ rect: NSRect) {
        guard let category, let summary = state.summary, let segment = summary.segment(category) else { return tooltip.hide() }
        tooltip.title = category.title
        let share = summary.volume.capacity > 0 ? Double(segment.size) / Double(summary.volume.capacity) : 0
        tooltip.detail = category == .snapshots ? "" : Format.percent(share)
        tooltip.lines = [Tooltip.Line(color: nil, name: category == .snapshots ? "\(summary.snapshots.count) local snapshots" : "Size",
                                      value: category == .snapshots ? "Not reported" : Format.bytes(segment.size))]
        tooltip.show(in: barCard, above: bar.convert(rect, to: barCard))
    }

    // MARK: The list under the bar

    private func pick(_ category: StorageCategory?) {
        expanded = false
        bar.selected = category
        legend.selected = category
        stack = category.map { [.mac, .category($0)] } ?? [.mac, .folder(home)]
        fillDetail()
        relayoutIfNeeded()
    }

    private func goBack(to index: Int) {
        expanded = false
        stack = Array(stack.prefix(index + 1))
        if case .mac = stack.last { pick(nil); stack = [.mac] }
        fillDetail()
        relayoutIfNeeded()
    }

    private func open(_ row: StorageList.Row) {
        if row.id == "#more" {
            expanded = true
            fillDetail()
            relayoutIfNeeded()
            return
        }
        expanded = false
        if row.id.hasPrefix("row:") {
            let id = String(row.id.dropFirst(4))
            if let storageRow = state.summary?.row(id), storageRow.paths.count == 1 {
                stack.append(.folder(storageRow.paths[0]))
            } else {
                stack.append(.row(id))
            }
        } else if let path = row.path {
            stack.append(.folder(path))
        }
        fillDetail()
        relayoutIfNeeded()
        scroll.contentView.scrollToVisible(detailCard.frame)
    }

    @objc private func revealCurrent() {
        guard case .folder(let path) = stack.last else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func name(_ level: Level) -> String {
        switch level {
        case .mac: return "This Mac"
        case .folder(let path): return displayName(path)
        case .category(let category): return category.title
        case .row(let id): return state.summary?.row(id)?.name ?? id
        }
    }

    private func displayName(_ path: String) -> String {
        if path == home { return "Home" }
        if path == "/Library" { return "Library (shared)" }
        if path == "/opt/homebrew" { return "Homebrew" }
        if path.hasPrefix("/private/var/folders/"), path.split(separator: "/").count == 5 { return "Temporary files" }
        return (path as NSString).lastPathComponent
    }

    /// The scanned node for a path, from the tree or from a scan made for drilling down.
    private func node(_ path: String) -> FolderNode? {
        if let node = onDemand[path] { return node }
        guard let root = state.roots.keys.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
              let tree = state.roots[root] else { return nil }
        return path == root ? tree : tree.descendant(String(path.dropFirst(root.count + 1)))
    }

    private func fillDetail() {
        crumbs.parts = stack.map(name)
        var rows: [StorageList.Row] = []
        var note = ""
        let tint = pageTint
        revealButton.isHidden = true
        switch stack.last ?? .mac {
        case .mac:
            note = "Folders Wisp measures on the startup disk"
            for (path, node) in state.roots.sorted(by: { $0.value.size > $1.value.size }) {
                rows.append(.init(id: path, name: displayName(path), note: path.replacingOccurrences(of: home, with: "~"),
                                  value: Format.bytes(node.size), fraction: 0, symbol: path == home ? "house.fill" : "folder.fill",
                                  tint: tint, opens: true, path: path))
            }
        case .folder(let path):
            revealButton.isHidden = false
            rows = folderRows(path, note: &note)
        case .category(let category):
            note = explanation(category)
            rows = categoryRows(category)
        case .row(let id):
            guard let row = state.summary?.row(id) else { break }
            note = row.detail
            for path in row.paths {
                let found = node(path)
                let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let isArtifact = ["node_modules", "target", "venv", "build"].contains(id)
                rows.append(.init(id: path, name: isArtifact ? project : displayName(path),
                                  note: path.replacingOccurrences(of: home, with: "~") + (found.map { $0.modified > 0 ? " · changed " + Self.ago(Date(timeIntervalSince1970: $0.modified)) : "" } ?? ""),
                                  value: found.map { Format.bytes($0.size) } ?? "–", fraction: 0, symbol: "folder.fill", tint: row.category.color,
                                  opens: true, path: path))
            }
        }
        let peak = Double(rows.compactMap { node($0.path ?? "")?.size }.max() ?? 0)
        let sizes = rows.map { row -> Double in
            if let path = row.path, let found = node(path) { return Double(found.size) }
            return 0
        }
        let rowPeak = max(peak, sizes.max() ?? 0)
        if rowPeak > 0 {
            for index in rows.indices where rows[index].fraction == 0 && sizes[index] > 0 { rows[index].fraction = sizes[index] / rowPeak }
        }
        if !expanded, rows.count > Self.shortList + 2 {
            let hidden = rows.count - Self.shortList
            rows = Array(rows.prefix(Self.shortList))
            rows.append(.init(id: "#more", name: "Show \(hidden) more", note: "", value: "", fraction: 0, symbol: "ellipsis.circle",
                              tint: Theme.inkSecondary, opens: true, faint: true, bar: false))
        }
        list.rows = rows
        detailNote.text = Theme.caption(note, size: 11)
    }

    private func folderRows(_ path: String, note: inout String) -> [StorageList.Row] {
        guard let folder = node(path) else {
            note = "Measuring…"
            // Only a folder the finished tree folded away gets a scan of its own; a root still
            // waiting for the main scan is left to it.
            let root = state.roots.keys.first { path.hasPrefix($0 + "/") }
            if root != nil, state.scanning == nil { measure(path) }
            return []
        }
        if folder.locked {
            note = state.summary?.fullDiskAccess == false ? "Locked until Wisp has Full Disk Access" : "macOS does not let Wisp read this folder"
            return []
        }
        // A folder whose smaller subfolders were folded together gets a scan of its own, if it is not huge.
        if onDemand[path] == nil, folder.otherCount > 0, folder.files < 200_000, state.scanning == nil { measure(path) }
        note = "\(Format.bytes(folder.size)) · \(Format.count(Int(folder.files))) files"
            + (folder.modified > 0 ? " · changed " + Self.ago(Date(timeIntervalSince1970: folder.modified)) : "")
        let peak = Double(folder.children.first?.size ?? 1)
        var rows = folder.children.prefix(60).map { child -> StorageList.Row in
            let childPath = path + "/" + child.name
            let changed = child.modified > 0 ? "changed " + Self.ago(Date(timeIntervalSince1970: child.modified)) : ""
            if child.locked {
                return .init(id: childPath, name: child.name, note: state.summary?.fullDiskAccess == false ? "Needs Full Disk Access" : "Cannot be read",
                             value: "–", fraction: 0, symbol: "lock.fill", tint: Theme.inkTertiary, opens: false, faint: true, bar: false, path: childPath)
            }
            let opens = !child.isFile && (!child.children.isEmpty || child.otherCount > 0)
            let files = child.isFile ? "" : "\(Format.count(Int(child.files))) files"
            return .init(id: childPath, name: child.name, note: [files, changed].filter { !$0.isEmpty }.joined(separator: " · "),
                         value: Format.bytes(child.size), fraction: Double(child.size) / max(peak, 1),
                         symbol: child.isFile ? "doc.fill" : (child.name.hasSuffix(".app") ? "app.fill" : "folder.fill"), tint: pageTint,
                         opens: opens, path: childPath)
        }
        if folder.otherSize > 0 {
            rows.append(.init(id: path + "/#other", name: "\(folder.otherCount) smaller folders", note: "Each too small to list",
                              value: Format.bytes(folder.otherSize), fraction: 0, symbol: "folder", tint: Theme.inkTertiary, opens: false, faint: true,
                              bar: false))
        }
        let listedFiles = folder.children.filter(\.isFile).reduce(UInt64(0)) { $0 + $1.size }
        let looseFiles = folder.ownFiles > listedFiles ? folder.ownFiles - listedFiles : 0
        if looseFiles > 0 {
            rows.append(.init(id: path + "/#files", name: "Files in this folder", note: "", value: Format.bytes(looseFiles), fraction: 0,
                              symbol: "doc", tint: Theme.inkTertiary, opens: false, faint: true, bar: false))
        }
        return rows
    }

    private func measure(_ path: String) {
        guard !measuring.contains(path) else { return }
        measuring.insert(path)
        index.scanFolder(path) { [weak self] node in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.measuring.remove(path)
                guard self.visible else { return }
                self.onDemand[path] = node
                if case .folder(let shown) = self.stack.last, shown == path {
                    self.fillDetail()
                    self.relayoutIfNeeded()
                }
            }
        }
    }

    private func categoryRows(_ category: StorageCategory) -> [StorageList.Row] {
        guard let summary = state.summary else { return [] }
        switch category {
        case .apps:
            var apps: [(String, FolderNode)] = []
            for root in ["/Applications", home + "/Applications"] {
                guard let tree = node(root) else { continue }
                apps += tree.children.map { (root + "/" + $0.name, $0) }
            }
            let peak = Double(apps.map(\.1.size).max() ?? 1)
            return apps.sorted { $0.1.size > $1.1.size }.prefix(60).map { path, node in
                .init(id: path, name: (node.name as NSString).deletingPathExtension, note: path.hasPrefix(home) ? "~/Applications" : "",
                      value: Format.bytes(node.size), fraction: Double(node.size) / max(peak, 1), symbol: node.isFile ? "doc.fill" : "app.fill",
                      tint: category.color, opens: !node.children.isEmpty, path: path)
            }
        case .snapshots:
            return summary.snapshots.map { snapshot in
                .init(id: snapshot.name, name: snapshot.kind, note: snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.name,
                      value: "–", fraction: 0, symbol: "clock.arrow.circlepath", tint: category.color, opens: false, bar: false)
            }
        case .purgeable:
            return [.init(id: "purgeable", name: "Purgeable", note: "Local snapshots, and files iCloud and apps can fetch again",
                          value: Format.bytes(summary.volume.purgeable), fraction: 0, symbol: category.symbol, tint: category.color, opens: false, bar: false)]
        case .free:
            return [.init(id: "free", name: "Free", note: "Ready for new files", value: Format.bytes(summary.volume.available), fraction: 0,
                          symbol: category.symbol, tint: Theme.inkSecondary, opens: false, bar: false)]
        default:
            var rows = summary.rows(category)
            if category == .developer { rows.sort { ($0.size ?? 0) > ($1.size ?? 0) } }
            rows = rows.filter { ($0.size ?? 0) >= 1 << 20 || $0.locked }
            let peak = Double(rows.compactMap(\.size).max() ?? 1)
            return rows.map { row in
                var note = row.detail
                if row.count > 1, ["node_modules", "target", "venv", "build"].contains(row.id) { note = "In \(row.count) projects · " + note }
                if let last = row.lastUsed, category == .developer { note = "Changed \(Self.ago(last)) · " + note }
                let locked = row.locked && (row.size ?? 0) == 0
                return .init(id: "row:" + row.id, name: row.name, note: locked ? "Needs Full Disk Access" : note,
                             value: locked ? "–" : Format.bytes(row.size ?? 0), fraction: Double(row.size ?? 0) / max(peak, 1),
                             symbol: locked ? "lock.fill" : category.symbol, tint: locked ? Theme.inkTertiary : category.color,
                             opens: !row.paths.isEmpty && !locked, faint: locked || row.id == "unmeasured", path: row.paths.count == 1 ? row.paths[0] : nil)
            }
        }
    }

    private func explanation(_ category: StorageCategory) -> String {
        switch category {
        case .apps: return "Apps in Applications as they sit on disk; their data in Library counts under System Data"
        case .developer: return "Build output, package caches, toolchains and virtual machine disks"
        case .documents: return "Your folders, and iCloud Drive and cloud files kept on this Mac"
        case .mail: return "Mail and Messages with their attachments"
        case .system: return "Everything else: macOS, swap, caches, logs, app data and what Wisp cannot read"
        case .snapshots:
            return "macOS does not report snapshot sizes without administrator rights; the space they hold counts as purgeable"
        case .purgeable: return "Space macOS frees by itself when it runs low"
        case .free: return "Space ready for new files"
        }
    }

    // MARK: Reclaimable

    private func fillReclaim(_ summary: StorageSummary) {
        reclaimItems = summary.reclaimable
        var rows = reclaimItems.map { item in
            StorageList.Row(id: item.id, name: item.name,
                            note: item.detail,
                            value: Format.bytes(item.size), fraction: 0, symbol: "trash", tint: pageTint, opens: false, bar: false)
        }
        let trash = summary.row("trash")
        let trashLocked = !summary.fullDiskAccess
        // A Trash under a megabyte is folded into the home folder's small folders.
        let trashValue = trashLocked ? "–" : trash.map { Format.bytes($0.size ?? 0) } ?? (state.roots.isEmpty ? "–" : "Under 1 MB")
        rows.append(.init(id: "trash", name: "Trash", note: trashLocked ? "Its size needs Full Disk Access" : "Empty it in Finder",
                          value: trashValue, fraction: 0, symbol: "trash.fill", tint: Theme.inkSecondary, opens: false, bar: false))
        reclaimList.rows = rows
        let total = reclaimItems.reduce(UInt64(0)) { $0 + $1.size }
        reclaimNote.text = Theme.caption(state.roots.isEmpty ? "Appears once folders are measured"
                                         : total > 0 ? "\(Format.bytes(total)) in all · each goes to the Trash after you check what it holds"
                                         : "Nothing large found", size: 11)
        while reclaimButtons.count < rows.count {
            let button = ActionButton(title: "Review…", target: self, action: #selector(review(_:)))
            button.secondary = true
            reclaimCard.addSubview(button)
            reclaimButtons.append(button)
        }
        for (index, button) in reclaimButtons.enumerated() {
            button.isHidden = index >= rows.count
            guard index < rows.count else { continue }
            let isTrash = rows[index].id == "trash"
            button.title = isTrash ? "Open Trash" : "Review…"
            button.tag = isTrash ? -1 : index
            button.invalidateIntrinsicContentSize()
        }
    }

    @objc private func review(_ sender: ActionButton) {
        guard sender.tag >= 0 else {
            NSWorkspace.shared.open(URL(fileURLWithPath: home + "/.Trash", isDirectory: true))
            return
        }
        guard reclaimItems.indices.contains(sender.tag), let window = view.window else { return }
        let item = reclaimItems[sender.tag]
        let entries = item.entries.filter { Self.safeToTrash($0.path, home: home) }
        guard !entries.isEmpty else { return }
        let total = entries.reduce(UInt64(0)) { $0 + $1.size }
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Move \(entries[0].name) to the Trash?" : "Move \(entries.count) folders to the Trash?"
        alert.informativeText = "\(Format.bytes(total)). \(item.consequence). You can put them back from the Trash until you empty it."
        let lines = entries.map { "\(Format.bytes($0.size))   \($0.path.replacingOccurrences(of: home, with: "~"))" }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 10))
        text.string = lines.joined(separator: "\n")
        text.font = Theme.sans(11.5)
        text.textColor = Theme.inkSecondary
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        let accessory = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: min(220, CGFloat(lines.count) * 17 + 12)))
        accessory.documentView = text
        accessory.hasVerticalScroller = lines.count > 12
        accessory.drawsBackground = false
        text.frame.size.width = 440
        text.sizeToFit()
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let urls = entries.map { URL(fileURLWithPath: $0.path) }
            NSWorkspace.shared.recycle(urls) { trashed, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let moved = entries.filter { entry in trashed.keys.contains { $0.path == entry.path } }.reduce(UInt64(0)) { $0 + $1.size }
                    self.notice = error == nil ? "Moved \(Format.bytes(moved)) to the Trash" : "Some folders could not be moved"
                    self.updateStatus()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        self?.notice = nil
                        self?.updateStatus()
                    }
                }
            }
        }
    }

    static func safeToTrash(_ path: String, home: String) -> Bool { StorageAccess.safeToTrash(path, home: home) }

    // MARK: History

    private func loadHistory() {
        guard let archive = delegate.monitor.history.archive else { return }
        let capacity = Double(state.summary?.volume.capacity ?? 0)
        let free = Double(state.summary?.volume.available ?? 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = HourlyArchive.currentHour
            let start = now - 30 * 24
            var values = [Double](repeating: .nan, count: 30 * 24 + 1)
            let readings = archive.system(.diskFree, since: start)
            for reading in readings where reading.hour >= start && reading.hour <= now { values[reading.hour - start] = reading.value }
            if free > 0 { values[values.count - 1] = free }
            let snapshots = SpaceHistory.load()
            let points = values.enumerated().compactMap { $0.element.isNaN ? nil : (hour: start + $0.offset, value: $0.element) }
            let jumps = SpaceHistory.jumps(free: points, threshold: max(5e9, capacity * 0.005), snapshots: snapshots)
            let marks = jumps.sorted { $0.drop > $1.drop }.prefix(3).map { jump -> SpaceChart.Mark in
                let what = jump.grew.first.map { "  " + ($0.path as NSString).lastPathComponent } ?? ""
                return SpaceChart.Mark(index: jump.to - start, label: "−" + Format.bytes(jump.drop) + what)
            }
            var grew: [SpaceHistory.Growth] = []
            var since: Date?
            if let first = snapshots.first, let last = snapshots.last, first.date < last.date {
                grew = Array(SpaceHistory.growth(from: first.sizes, to: last.sizes).prefix(4))
                since = first.date
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.visible else { return }
                    self.history = (values, Array(marks), grew, since)
                    self.fillHistory(self.history!)
                    self.relayoutIfNeeded()
                }
            }
        }
    }

    private func fillHistory(_ history: (values: [Double], marks: [SpaceChart.Mark], grew: [SpaceHistory.Growth], since: Date?)) {
        chart.capacity = Double(state.summary?.volume.capacity ?? 1)
        chart.values = history.values
        chart.marks = history.marks
        if let since = history.since, !history.grew.isEmpty {
            grewTitle.text = Theme.caption("Grew most since \(since.formatted(date: .abbreviated, time: .omitted))", size: 11)
        } else {
            grewTitle.text = Theme.caption(state.roots.isEmpty ? "" : "Growth shows here after the next day's scan", size: 11)
        }
        let peak = Double(history.grew.map(\.delta).max() ?? 1)
        grewList.rows = history.grew.map { growth in
            .init(id: growth.path, name: displayName(growth.path), note: growth.path.replacingOccurrences(of: home, with: "~"),
                  value: "+" + Format.bytes(UInt64(max(0, growth.delta))), fraction: Double(growth.delta) / max(peak, 1),
                  symbol: "folder.fill", tint: Theme.warn, opens: node(growth.path) != nil, path: growth.path)
        }
        grewList.onOpen = { [weak self] row in
            guard let self, let path = row.path else { return }
            self.pick(nil)
            self.stack = [.mac, .folder(path)]
            self.fillDetail()
            self.relayoutIfNeeded()
            self.scroll.contentView.scrollToVisible(self.detailCard.frame)
        }
    }

    // MARK: Health

    private func fillHealth() {
        guard let health = state.health else {
            healthCard.isHidden = true
            return
        }
        healthCard.isHidden = false
        wear.figure.show("\(health.percentUsed)", unit: "%")
        let (w, wu) = DashboardView.split(Format.bytes(UInt64(health.bytesWritten)))
        written.figure.show(w, unit: wu)
        if let celsius = health.celsius {
            temperature.figure.show("\(celsius)", unit: "°C")
        } else {
            temperature.figure.show("–")
        }
        spare.figure.show("\(health.availableSpare)", unit: "%")
        poweredOn.figure.show(Format.count(Int(health.powerOnHours)), unit: "h")
        let color = health.criticalWarning != 0 ? Theme.bad : Theme.inkSecondary
        let left = 100 - min(100, health.percentUsed)
        healthNote.variants = health.criticalWarning != 0
            ? [Theme.caption("The drive reports a warning. Back up this Mac", color: color, size: 11),
               Theme.caption("The drive reports a warning", color: color, size: 11)]
            : [Theme.caption("\(left)% of the drive's rated writes left · read from its SMART log", size: 11),
               Theme.caption("\(left)% of rated writes left", size: 11)]
    }

    // MARK: Layout

    private var lastHeights: [CGFloat] = []

    private func relayoutIfNeeded() {
        let heights = storageHeights(width: scroll.contentSize.width - margin * 2)
        if heights != lastHeights { relayout() } else { placeInside() }
    }

    private var twoColumns: Bool { scroll.contentSize.width >= 900 }

    private func storageHeights(width: CGFloat) -> [CGFloat] {
        let legendHeight = legend.naturalHeight(width: width - 40)
        let barHeight = 124 + legendHeight + (accessNote.isHidden ? 8 : 48)
        let detailHeight = 86 + max(StorageList.rowHeight, list.naturalHeight) + 10
        let reclaimHeight = 76 + reclaimList.naturalHeight + 10
        let historyHeight = 56 + 160 + (grewList.rows.isEmpty ? 34 : 34 + grewList.naturalHeight) + 10
        let healthHeight: CGFloat = healthCard.isHidden ? 0 : 128
        return [barHeight, detailHeight, reclaimHeight, historyHeight, healthHeight]
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let heights = storageHeights(width: inner)
        lastHeights = heights
        var y = margin
        barCard.frame = NSRect(x: margin, y: y, width: inner, height: heights[0])
        y += heights[0] + gap
        detailCard.frame = NSRect(x: margin, y: y, width: inner, height: heights[1])
        y += heights[1] + gap
        if width >= 900 {
            let half = (inner - gap) / 2
            let height = max(heights[2], heights[3])
            reclaimCard.frame = NSRect(x: margin, y: y, width: half, height: height)
            historyCard.frame = NSRect(x: margin + half + gap, y: y, width: half, height: height)
            y += height + gap
        } else {
            reclaimCard.frame = NSRect(x: margin, y: y, width: inner, height: heights[2])
            y += heights[2] + gap
            historyCard.frame = NSRect(x: margin, y: y, width: inner, height: heights[3])
            y += heights[3] + gap
        }
        if !healthCard.isHidden {
            healthCard.frame = NSRect(x: margin, y: y, width: inner, height: heights[4])
            y += heights[4] + gap
        }
        placeInside()
        // The Disk page's own cards follow, moved down by what is above them.
        let bottom = super.arrange(width: width)
        let shift = y - margin
        let mine = Set(storageViews.map(ObjectIdentifier.init))
        for view in canvas.subviews where !mine.contains(ObjectIdentifier(view)) { view.frame.origin.y += shift }
        return bottom + shift
    }

    private func placeInside() {
        var width = barCard.bounds.width - 40
        barTitle.frame = NSRect(x: 20, y: 16, width: barTitle.naturalWidth + 4, height: 22)
        rescanButton.frame = NSRect(x: 20 + width - 26, y: 14, width: 26, height: 26)
        let statusWidth = max(0, min(360, width - barTitle.frame.width - 32 - 16))
        barStatus.alignment = .right
        barStatus.frame = NSRect(x: 20 + width - 32 - statusWidth, y: 19, width: statusWidth, height: 16)
        barFigure.frame = NSRect(x: 20, y: 46, width: width, height: 36)
        bar.frame = NSRect(x: 20, y: 92, width: width, height: 20)
        let legendHeight = legend.naturalHeight(width: width)
        legend.frame = NSRect(x: 20, y: 126, width: width, height: legendHeight)
        let accessY = 126 + legendHeight + 6
        let buttonSize = accessButton.intrinsicContentSize
        accessNote.frame = NSRect(x: 20, y: accessY + (buttonSize.height - 16) / 2, width: width - buttonSize.width - 16, height: 16)
        accessButton.frame = NSRect(x: 20 + width - buttonSize.width, y: accessY, width: buttonSize.width, height: buttonSize.height)

        width = detailCard.bounds.width - 40
        let revealSize = revealButton.intrinsicContentSize
        revealButton.frame = NSRect(x: 20 + width - revealSize.width, y: 16, width: revealSize.width, height: revealSize.height)
        crumbs.frame = NSRect(x: 20, y: 16, width: width - (revealButton.isHidden ? 0 : revealSize.width + 16), height: 24)
        detailNote.frame = NSRect(x: 20, y: 44, width: width, height: 16)
        list.frame = NSRect(x: 20, y: 72, width: width, height: max(StorageList.rowHeight, list.naturalHeight))

        width = reclaimCard.bounds.width - 40
        reclaimTitle.frame = NSRect(x: 20, y: 16, width: width, height: 22)
        let cleanUpSize = cleanUpButton.intrinsicContentSize
        cleanUpButton.frame = NSRect(x: 20 + width - cleanUpSize.width, y: 14, width: cleanUpSize.width, height: cleanUpSize.height)
        reclaimNote.frame = NSRect(x: 20, y: 42, width: width, height: 16)
        let buttonWidth: CGFloat = 104
        reclaimList.frame = NSRect(x: 20, y: 66, width: width - buttonWidth - 14, height: reclaimList.naturalHeight)
        for (index, button) in reclaimButtons.enumerated() where !button.isHidden {
            button.frame = NSRect(x: 20 + width - buttonWidth, y: 66 + CGFloat(index) * StorageList.rowHeight + (StorageList.rowHeight - 26) / 2,
                                  width: buttonWidth, height: 26)
        }

        width = historyCard.bounds.width - 40
        historyTitle.frame = NSRect(x: 20, y: 16, width: width, height: 22)
        chart.frame = NSRect(x: 20, y: 52, width: width, height: 160)
        grewTitle.frame = NSRect(x: 20, y: 224, width: width, height: 16)
        grewList.frame = NSRect(x: 20, y: 248, width: width, height: grewList.naturalHeight)

        width = healthCard.bounds.width - 40
        healthTitle.frame = NSRect(x: 20, y: 16, width: 240, height: 22)
        healthNote.alignment = .right
        healthNote.frame = NSRect(x: 260, y: 19, width: width - 240, height: 16)
        let tiles = [wear, written, temperature, spare, poweredOn]
        let column = (width + 20) / CGFloat(tiles.count)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: 10 + CGFloat(index) * column, y: 50, width: column, height: 60).integral
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "yesterday" }
        if days < 60 { return "\(days) days ago" }
        if days < 730 { return "\(days / 30) months ago" }
        return "\(days / 365) years ago"
    }
}
