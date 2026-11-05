import AppKit
import WispCore

/// Storage: where the space on the startup disk goes, above the live disk activity
/// the Disk page always had. Folder sizes come from `StorageIndex`, which works only
/// while this page is on screen.
///
/// At 1240 by 780 the startup disk card spans the top; under it the list for the
/// picked kind or folder sits beside what could go to the Trash and free space over
/// the last 30 days. What grew, drive health and disk activity follow below.
@MainActor
final class StoragePage: DiskPage {
    private enum Level: Equatable {
        case mac
        case folder(String)
        case category(StorageCategory)
        case row(String)
    }

    private let index = StorageIndex()
    /// The last breakdown this page received, for the Overview, which never scans.
    private(set) static var latestSummary: StorageSummary?
    private var state = StorageState()
    private let home = NSHomeDirectory()
    private lazy var stack: [Level] = [.mac, .folder(home)]
    private var onDemand: [String: FolderNode] = [:]
    private var measuring: Set<String> = []
    private var visible = false
    /// The list under the bar shows this many rows, then one for the rest, until asked for them.
    private static let shortList = 9
    private var expanded = false

    private let barCard = CardView(), barStatus = TextLine(), barFigure = TextLine()
    private let barLabel = A2CardLabel("Startup disk", symbol: PageID.disk.symbol, tint: A2.labelTint(.disk))
    private let bar = DiskBar(), legend = DiskLegend(), tooltip = Tooltip()
    private var canMeasure = false
    private let measureButton = A2ToolbarButton("Measure Again", symbol: "arrow.clockwise", tint: A2.secondary)
    private let accessNote = TextLine(), accessButton = A2PillButton()

    private let detailCard = CardView(), crumbs = Breadcrumb(), detailSize = TextLine(), detailNote = TextLine(), list = A2List()
    private let revealButton = A2PillButton()
    /// Bytes behind each row in the list, for the total on the row that shows the rest.
    private var rowBytes: [String: UInt64] = [:]

    private let reclaimCard = CardView(), reclaimTitle = TextLine(), reclaimNote = TextLine(), reclaimList = A2List()
    private let cleanUpButton = A2PillButton()

    private let historyCard = CardView(), historyTitle = A2TitleRow(), chart = SpaceChart()
    private let grewCard = CardView(), grewTitle = A2TitleRow(), grewList = A2List()
    private var history: (values: [Double], marks: [SpaceChart.Mark], grew: [SpaceHistory.Growth], since: Date?)?

    private let healthCard = CardView(), healthTitle = A2TitleRow(), healthKeys = A2Keys()

    private var storageViews: [NSView] { [barCard, detailCard, reclaimCard, historyCard, grewCard, healthCard] }

    override var pageTint: NSColor { PageID.disk.tint }
    /// The toolbar holds the page's one action; the Live / Hour / Day switch stays on the
    /// disk activity chart lower down.
    override var toolbarItems: [NSView] { [measureButton] }

    override func setUp() {
        super.setUp()
        _ = heading("Storage")
        for view in storageViews { canvas.addSubview(view) }
        for view in [barLabel, barStatus, barFigure, bar, legend, accessNote, accessButton] as [NSView] { barCard.addSubview(view) }
        barLabel.showsChevron = false
        barStatus.alignment = .right
        measureButton.onPress = { [weak self] in if self?.canMeasure == true { self?.rescan() } }
        bar.onPick = { [weak self] category in self?.pick(category) }
        legend.onPick = { [weak self] category in self?.pick(category) }
        bar.onHover = { [weak self] category, rect in self?.hover(category, rect) }
        accessNote.text = A2.plain("Some folders stay locked until Wisp has Full Disk Access")
        accessButton.title = "Open Privacy Settings"
        accessButton.onPress = { NSWorkspace.shared.open(StorageAccess.settingsURL) }

        for view in [crumbs, detailSize, revealButton, detailNote, list] as [NSView] { detailCard.addSubview(view) }
        detailSize.alignment = .right
        revealButton.title = "Reveal in Finder"
        revealButton.onPress = { [weak self] in self?.revealCurrent() }
        crumbs.onPick = { [weak self] index in self?.goBack(to: index) }
        list.onOpen = { [weak self] row in self?.open(row) }
        list.drawsVisibleOnly = true

        for view in [reclaimTitle, reclaimNote, reclaimList, cleanUpButton] as [NSView] { reclaimCard.addSubview(view) }
        reclaimTitle.text = NSAttributedString(string: "Could go to the Trash", attributes: [.font: A2.titleFont, .foregroundColor: A2.primary])
        cleanUpButton.title = "Clean Up"
        cleanUpButton.onPress = { [weak self] in self?.delegate.showPage(.cleanup) }
        reclaimList.rowHeight = Self.reclaimRow
        reclaimList.onOpen = { [weak self] row in self?.review(row.id) }

        for view in [chart, historyTitle] as [NSView] { historyCard.addSubview(view) }
        historyTitle.title = "Where your space went"

        for view in [grewTitle, grewList] as [NSView] { grewCard.addSubview(view) }
        grewList.meterColors = (A2.power, nil)
        grewList.onOpen = { [weak self] row in self?.showGrown(row) }
        grewCard.isHidden = true

        for view in [healthTitle, healthKeys] as [NSView] { healthCard.addSubview(view) }
        healthTitle.title = "Drive health"
        healthKeys.arrangement = .columns(5)
        healthCard.isHidden = true

        index.onChange = { [weak self] state in MainActor.assumeIsolated { self?.received(state) } }
    }

    /// "Macintosh HD · APFS · 995 GB", read from the startup volume.
    private func showSubtitle(capacity: UInt64) {
        guard let (_, subtitle) = headingLines else { return }
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        var info = statfs()
        let kind = statfs("/", &info) == 0
            ? withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.uppercased() : ""
        let parts = [name, kind.isEmpty ? nil : kind, Format.bytes(capacity)].compactMap { $0 }
        subtitle.variants = [parts.joined(separator: " · "), parts.dropFirst().joined(separator: " · ")].map(Toolbar.subtitle)
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
        if let summary = new.summary {
            Self.latestSummary = summary
            if !hadSummary { showSubtitle(capacity: summary.volume.capacity) }
        }
        // WISP_STORAGE_PICK=developer opens one slice, for screenshots.
        if !hadSummary, let pick = ProcessInfo.processInfo.environment["WISP_STORAGE_PICK"], let category = StorageCategory(rawValue: pick) {
            self.pick(category)
        }
        refreshStorage()
        if finished || !hadSummary { loadHistory() }
    }

    private func rescan() {
        onDemand.removeAll()
        index.rescan()
    }

    // MARK: Filling in

    private func refreshStorage() {
        guard let summary = state.summary else { return }
        let volume = summary.volume
        let (number, unit) = DashboardView.split(Format.bytes(volume.available))
        let figure = NSMutableAttributedString(string: number, attributes: [.font: Theme.figure(30, .semibold), .foregroundColor: A2.primary, .kern: -1.2])
        figure.append(NSAttributedString(string: " " + unit, attributes: [.font: A2.unitFont, .foregroundColor: A2.secondary]))
        figure.append(NSAttributedString(string: "  free of \(Format.bytes(volume.capacity))", attributes: [.font: A2.unitFont, .foregroundColor: A2.secondary]))
        if volume.purgeable > 0 {
            figure.append(NSAttributedString(string: "  · \(Format.bytes(volume.availableForImportant)) once macOS clears purgeable space",
                                             attributes: [.font: Theme.sans(12), .foregroundColor: A2.tertiary]))
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
        barStatus.text = NSAttributedString(string: text, attributes: [.font: A2.legendFont, .foregroundColor: A2.tertiary])
        canMeasure = state.scanning == nil && !state.roots.isEmpty
        measureButton.alphaValue = canMeasure ? 1 : 0.4
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

    private func open(_ row: A2List.Row) {
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

    private func revealCurrent() {
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

    /// A row of the list. `bytes` sizes its meter and the "Show more" total; nil draws no meter.
    private func row(_ id: String, _ name: String, note: String = "", bytes: UInt64?, value: String? = nil, symbol: String, tint: NSColor,
                     opens: Bool, faint: Bool = false, meter: Bool = true, path: String? = nil) -> A2List.Row {
        if let bytes { rowBytes[id] = bytes }
        return A2List.Row(id: id, name: name, note: note, value: value ?? bytes.map { Format.bytes($0) } ?? "–",
                          fraction: meter && bytes != nil ? 0 : nil, symbol: symbol, tint: tint, opens: opens, faint: faint, path: path)
    }

    private func fillDetail() {
        crumbs.parts = stack.map(name)
        rowBytes = [:]
        var rows: [A2List.Row] = []
        var note = ""
        var size: UInt64?
        let tint = A2.labelTint(.disk)
        revealButton.isHidden = true
        switch stack.last ?? .mac {
        case .mac:
            note = "Folders Wisp measures on the startup disk"
            for (path, node) in state.roots.sorted(by: { $0.value.size > $1.value.size }) {
                rows.append(row(path, displayName(path), note: path.replacingOccurrences(of: home, with: "~"), bytes: node.size,
                                symbol: path == home ? "house" : "folder", tint: tint, opens: true, path: path))
            }
        case .folder(let path):
            revealButton.isHidden = false
            rows = folderRows(path, note: &note)
        case .category(let category):
            note = explanation(category)
            rows = categoryRows(category)
            size = state.summary?.segment(category)?.size
        case .row(let id):
            guard let storageRow = state.summary?.row(id) else { break }
            note = storageRow.detail
            size = storageRow.size
            let isArtifact = ["node_modules", "target", "venv", "build"].contains(id)
            for path in storageRow.paths {
                let found = node(path)
                let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let changed = found.map { $0.modified > 0 ? " · changed " + Self.ago(Date(timeIntervalSince1970: $0.modified)) : "" } ?? ""
                rows.append(row(path, isArtifact ? project : displayName(path), note: path.replacingOccurrences(of: home, with: "~") + changed,
                                bytes: found?.size, symbol: "folder", tint: storageRow.category.color, opens: true, path: path))
            }
        }
        let peak = Double(rows.compactMap { rowBytes[$0.id] }.max() ?? 0)
        if peak > 0 {
            for index in rows.indices where rows[index].fraction != nil {
                rows[index].fraction = Double(rowBytes[rows[index].id] ?? 0) / peak
            }
        }
        if !expanded, rows.count > Self.shortList + 1 {
            let hidden = rows.dropFirst(Self.shortList)
            let total = hidden.reduce(UInt64(0)) { $0 + (rowBytes[$1.id] ?? 0) }
            rows = Array(rows.prefix(Self.shortList))
            rows.append(A2List.Row(id: "#more", name: "Show \(hidden.count) more", value: total > 0 ? Format.bytes(total) : "",
                                   symbol: "chevron.down", opens: true, faint: true))
        }
        // Meters take the kind's colour, as the bar does; folders the page's.
        switch stack.last ?? .mac {
        case .category(let category): list.meterColors = (category.color, nil)
        case .row(let id): list.meterColors = (state.summary?.row(id)?.category.color ?? A2.up, nil)
        default: list.meterColors = (A2.up, nil)
        }
        list.rows = rows
        detailNote.text = A2.plain(note)
        detailSize.text = NSAttributedString(string: size.map { Format.bytes($0) } ?? "", attributes: [.font: Theme.digits(12), .foregroundColor: A2.tertiary])
    }

    private func folderRows(_ path: String, note: inout String) -> [A2List.Row] {
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
        let tint = A2.labelTint(.disk)
        var rows = folder.children.prefix(60).map { child -> A2List.Row in
            let childPath = path + "/" + child.name
            let changed = child.modified > 0 ? "changed " + Self.ago(Date(timeIntervalSince1970: child.modified)) : ""
            if child.locked {
                return row(childPath, child.name, note: state.summary?.fullDiskAccess == false ? "Needs Full Disk Access" : "Cannot be read",
                           bytes: nil, symbol: "lock", tint: A2.tertiary, opens: false, faint: true, path: childPath)
            }
            let opens = !child.isFile && (!child.children.isEmpty || child.otherCount > 0)
            let files = child.isFile ? "" : "\(Format.count(Int(child.files))) files"
            return row(childPath, child.name, note: [files, changed].filter { !$0.isEmpty }.joined(separator: " · "), bytes: child.size,
                       symbol: child.isFile ? "doc" : (child.name.hasSuffix(".app") ? "app" : "folder"), tint: tint, opens: opens, path: childPath)
        }
        if folder.otherSize > 0 {
            rows.append(row(path + "/#other", "\(folder.otherCount) smaller folders", note: "Each too small to list", bytes: folder.otherSize,
                            symbol: "folder", tint: A2.tertiary, opens: false, faint: true, meter: false))
        }
        let listedFiles = folder.children.filter(\.isFile).reduce(UInt64(0)) { $0 + $1.size }
        let looseFiles = folder.ownFiles > listedFiles ? folder.ownFiles - listedFiles : 0
        if looseFiles > 0 {
            rows.append(row(path + "/#files", "Files in this folder", bytes: looseFiles, symbol: "doc", tint: A2.tertiary, opens: false,
                            faint: true, meter: false))
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

    private func categoryRows(_ category: StorageCategory) -> [A2List.Row] {
        guard let summary = state.summary else { return [] }
        switch category {
        case .apps:
            var apps: [(String, FolderNode)] = []
            for root in ["/Applications", home + "/Applications"] {
                guard let tree = node(root) else { continue }
                apps += tree.children.map { (root + "/" + $0.name, $0) }
            }
            return apps.sorted { $0.1.size > $1.1.size }.prefix(60).map { path, node in
                row(path, (node.name as NSString).deletingPathExtension, note: path.hasPrefix(home) ? "~/Applications" : "", bytes: node.size,
                    symbol: node.isFile ? "doc" : "app", tint: category.color, opens: !node.children.isEmpty, path: path)
            }
        case .snapshots:
            return summary.snapshots.map { snapshot in
                row(snapshot.name, snapshot.kind, note: snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.name,
                    bytes: nil, symbol: category.symbol, tint: category.color, opens: false)
            }
        case .purgeable:
            return [row("purgeable", "Purgeable", note: "Local snapshots, and files iCloud and apps can fetch again", bytes: summary.volume.purgeable,
                        symbol: category.symbol, tint: category.color, opens: false, meter: false)]
        case .free:
            return [row("free", "Free", note: "Ready for new files", bytes: summary.volume.available, symbol: category.symbol, tint: A2.secondary,
                        opens: false, meter: false)]
        default:
            var rows = summary.rows(category)
            if category == .developer { rows.sort { ($0.size ?? 0) > ($1.size ?? 0) } }
            rows = rows.filter { ($0.size ?? 0) >= 1 << 20 || $0.locked }
            return rows.map { storageRow in
                var note = storageRow.detail
                if storageRow.count > 1, ["node_modules", "target", "venv", "build"].contains(storageRow.id) { note = "In \(storageRow.count) projects · " + note }
                if let last = storageRow.lastUsed, category == .developer { note = "Changed \(Self.ago(last)) · " + note }
                let locked = storageRow.locked && (storageRow.size ?? 0) == 0
                return row("row:" + storageRow.id, storageRow.name, note: locked ? "Needs Full Disk Access" : note, bytes: locked ? nil : storageRow.size ?? 0,
                           symbol: locked ? "lock" : category.symbol, tint: locked ? A2.tertiary : category.color,
                           opens: !storageRow.paths.isEmpty && !locked, faint: locked || storageRow.id == "unmeasured",
                           path: storageRow.paths.count == 1 ? storageRow.paths[0] : nil)
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
        let items = summary.reclaimable
        let tint = A2.labelTint(.disk)
        var rows = items.map { item in
            A2List.Row(id: item.id, name: item.name, note: item.detail, value: Format.bytes(item.size), symbol: "trash", tint: tint, opens: true)
        }
        let trashLocked = !summary.fullDiskAccess
        // A Trash under a megabyte is folded into the home folder's small folders.
        let trashValue = trashLocked ? "–" : summary.row("trash").map { Format.bytes($0.size ?? 0) } ?? (state.roots.isEmpty ? "–" : "Under 1 MB")
        rows.append(A2List.Row(id: "#trash", name: "Trash", note: trashLocked ? "Its size needs Full Disk Access" : "Empty it in Finder",
                               value: trashValue, symbol: "trash", opens: true, faint: true))
        reclaimList.rows = rows
        let total = items.reduce(UInt64(0)) { $0 + $1.size }
        reclaimNote.text = A2.plain(state.roots.isEmpty ? "Appears once folders are measured"
                                    : total > 0 ? "\(Format.bytes(total)) in all · check each one before it goes to the Trash"
                                    : "Nothing large found")
    }

    private func review(_ id: String) {
        guard id != "#trash" else {
            NSWorkspace.shared.open(URL(fileURLWithPath: home + "/.Trash", isDirectory: true))
            return
        }
        delegate.openCleanUp { $0.show(.developer) }
    }

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
        // A shorter record runs from its first reading, so the line spans the card.
        let first = min(history.values.firstIndex { !$0.isNaN } ?? 0, max(0, history.values.count - 25))
        chart.values = Array(history.values.dropFirst(first))
        chart.marks = history.marks.map { .init(index: $0.index - first, label: $0.label) }.filter { $0.index >= 0 }
        let hours = chart.values.count - 1
        let span = hours >= 29 * 24 ? "last 30 days" : hours >= 48 ? "last \(hours / 24) days" : "last \(hours) hours"
        historyTitle.items = [.init(text: "Free space, " + span)]
        grewCard.isHidden = history.grew.isEmpty
        grewTitle.title = "Grew most"
        grewTitle.items = history.since.map { [.init(text: "Since \($0.formatted(date: .abbreviated, time: .omitted))")] } ?? []
        let peak = Double(history.grew.map(\.delta).max() ?? 1)
        grewList.rows = history.grew.map { growth in
            A2List.Row(id: growth.path, name: displayName(growth.path), note: growth.path.replacingOccurrences(of: home, with: "~"),
                       value: "+" + Format.bytes(UInt64(max(0, growth.delta))), fraction: Double(growth.delta) / max(peak, 1),
                       symbol: "folder", tint: A2.power, opens: node(growth.path) != nil, path: growth.path)
        }
    }

    private func showGrown(_ row: A2List.Row) {
        guard let path = row.path else { return }
        pick(nil)
        stack = [.mac, .folder(path)]
        fillDetail()
        relayoutIfNeeded()
        scroll.contentView.scrollToVisible(detailCard.frame)
    }

    // MARK: Health

    private func fillHealth() {
        guard let health = state.health else {
            healthCard.isHidden = true
            return
        }
        healthCard.isHidden = false
        let celsius = health.celsius.map { "\($0) °C" } ?? "–"
        healthKeys.keys = [.init(label: "Life used", value: "\(health.percentUsed)%", color: nil),
                           .init(label: "Written", value: Format.bytes(UInt64(health.bytesWritten)), color: nil),
                           .init(label: "Temperature", value: celsius, color: nil),
                           .init(label: "Spare blocks", value: "\(health.availableSpare)%", color: nil),
                           .init(label: "Powered on", value: Format.count(Int(health.powerOnHours)) + " h", color: nil)]
        let left = 100 - min(100, health.percentUsed)
        healthTitle.items = health.criticalWarning != 0
            ? [.init(text: "The drive reports a warning. Back up this Mac")]
            : [.init(text: "\(left)% of rated writes left · from its SMART log", faint: true)]
    }

    // MARK: Layout

    private static let reclaimRow: CGFloat = 35
    private static let historyMinimum: CGFloat = 168
    private var lastHeights: [CGFloat] = []

    private func relayoutIfNeeded() {
        let heights = naturalHeights(inner: scroll.contentSize.width - margin * 2)
        if heights != lastHeights { relayout() } else { placeInside() }
    }

    /// The bar card, the detail list at its natural row height, and the reclaim list.
    private func naturalHeights(inner: CGFloat) -> [CGFloat] {
        let legendHeight = legend.naturalHeight(width: inner - A2.padSide * 2)
        let bar = 111 + legendHeight + (accessNote.isHidden ? 11 : 46)
        let detail = Self.listTop + CGFloat(max(1, list.rows.count)) * 40 + A2.padTop
        let reclaim = 78 + CGFloat(reclaimList.rows.count) * Self.reclaimRow
        return [bar, detail, reclaim, grewCard.isHidden ? 0 : 1, healthCard.isHidden ? 0 : 1]
    }

    /// Where the detail list starts in its card: crumbs, the note, then 7 pt.
    private static let listTop: CGFloat = 57

    /// The list's row fills the window's height, so a taller window lays it out again.
    private var arrangedHeight: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        if scroll.contentSize.height != arrangedHeight { relayout() }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        arrangedHeight = scroll.contentSize.height
        let inner = width - margin * 2
        let heights = naturalHeights(inner: inner)
        lastHeights = heights
        var y = margin
        barCard.frame = NSRect(x: margin, y: y, width: inner, height: heights[0])
        y += heights[0] + gap
        if inner >= 760 {
            // The list and the right column share a row that fills the window, as in the mockup.
            let room = scroll.contentSize.height - Self.topInset - y - margin
            let right = heights[2] + gap + Self.historyMinimum
            let height = max(room, heights[1], right).rounded()
            let left = ((inner - gap) * 1.45 / 2.45).rounded()
            detailCard.frame = NSRect(x: margin, y: y, width: left, height: max(heights[1], height))
            reclaimCard.frame = NSRect(x: margin + left + gap, y: y, width: inner - left - gap, height: heights[2])
            let history = min(max(Self.historyMinimum, height - heights[2] - gap), 260)
            historyCard.frame = NSRect(x: reclaimCard.frame.minX, y: reclaimCard.frame.maxY + gap, width: reclaimCard.frame.width, height: history)
            y = max(detailCard.frame.maxY, historyCard.frame.maxY) + gap
        } else {
            for (card, height) in [(detailCard, heights[1]), (reclaimCard, heights[2]), (historyCard, Self.historyMinimum)] {
                card.frame = NSRect(x: margin, y: y, width: inner, height: height)
                y += height + gap
            }
        }
        let lower = [grewCard, healthCard].filter { !$0.isHidden }
        let grewHeight = 14 + 16 + 6 + CGFloat(grewList.rows.count) * 44 + A2.padTop
        let healthHeight = 14 + 16 + 14 + A2Keys.keyHeight + A2.padTop + 4
        // Side by side only when neither card would be left with an empty band.
        if lower.count == 2, inner >= 760, max(grewHeight, healthHeight) <= min(grewHeight, healthHeight) * 1.4 {
            let half = ((inner - gap) / 2).rounded()
            let height = max(grewHeight, healthHeight)
            grewCard.frame = NSRect(x: margin, y: y, width: half, height: height)
            healthCard.frame = NSRect(x: margin + half + gap, y: y, width: inner - half - gap, height: height)
            y += height + gap
        } else {
            for card in lower {
                let height = card === grewCard ? grewHeight : healthHeight
                card.frame = NSRect(x: margin, y: y, width: inner, height: height)
                y += height + gap
            }
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
        var inner = barCard.bounds.width - A2.padSide * 2
        barLabel.frame = NSRect(x: A2.padSide, y: A2.padTop, width: 140, height: 15)
        barStatus.frame = NSRect(x: A2.padSide + 150, y: A2.padTop, width: max(0, inner - 150), height: 15)
        barFigure.frame = NSRect(x: A2.padSide, y: 38, width: inner, height: 36)
        bar.frame = NSRect(x: A2.padSide, y: 85, width: inner, height: 14)
        let legendHeight = legend.naturalHeight(width: inner)
        legend.frame = NSRect(x: A2.padSide - DiskLegend.inset, y: 111, width: inner + DiskLegend.inset * 2, height: legendHeight)
        let accessY = 111 + legendHeight + 8
        let buttonWidth = accessButton.naturalWidth
        accessButton.frame = NSRect(x: A2.padSide + inner - buttonWidth, y: accessY, width: buttonWidth, height: 26)
        accessNote.frame = NSRect(x: A2.padSide, y: accessY + 5, width: max(0, inner - buttonWidth - 16), height: 16)

        inner = detailCard.bounds.width - A2.padSide * 2
        let revealWidth = revealButton.naturalWidth
        revealButton.frame = NSRect(x: A2.padSide + inner - revealWidth, y: A2.padTop - 4, width: revealWidth, height: 26)
        let sizeWidth: CGFloat = 90
        detailSize.frame = NSRect(x: A2.padSide + inner - sizeWidth, y: A2.padTop, width: sizeWidth, height: 18)
        let crumbsRight = revealButton.isHidden ? sizeWidth + 12 : revealWidth + 12
        crumbs.frame = NSRect(x: A2.padSide, y: A2.padTop, width: max(0, inner - crumbsRight), height: 18)
        detailNote.frame = NSRect(x: A2.padSide, y: 36, width: inner, height: 15)
        let listRoom = detailCard.bounds.height - Self.listTop - A2.padTop
        // Rows share the card's height; a short list keeps rows no taller than 48 pt.
        list.rowHeight = min(48, max(40, (listRoom / CGFloat(max(1, list.rows.count))).rounded(.down)))
        list.frame = NSRect(x: A2.padSide, y: Self.listTop, width: inner, height: max(1, listRoom))

        inner = reclaimCard.bounds.width - A2.padSide * 2
        let cleanUpWidth = cleanUpButton.naturalWidth
        cleanUpButton.frame = NSRect(x: A2.padSide + inner - cleanUpWidth, y: A2.padTop, width: cleanUpWidth, height: 26)
        reclaimTitle.frame = NSRect(x: A2.padSide, y: A2.padTop + 4, width: max(0, inner - cleanUpWidth - 12), height: 18)
        reclaimNote.frame = NSRect(x: A2.padSide, y: A2.padTop + 30, width: inner, height: 15)
        reclaimList.frame = NSRect(x: A2.padSide, y: 64, width: inner, height: reclaimList.naturalHeight)

        inner = historyCard.bounds.width - A2.padSide * 2
        historyTitle.frame = NSRect(x: A2.padSide, y: A2.padTop + 4, width: inner, height: 16)
        // The mockup's chart is the bottom 112 pt of a 168 pt card.
        let chartTop = min(56, historyCard.bounds.height - 60)
        chart.frame = NSRect(x: 0, y: chartTop, width: historyCard.bounds.width, height: historyCard.bounds.height - chartTop)

        inner = grewCard.bounds.width - A2.padSide * 2
        grewTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        grewList.rowHeight = 44
        grewList.frame = NSRect(x: A2.padSide, y: A2.padTop + 22, width: inner, height: grewList.naturalHeight)

        inner = healthCard.bounds.width - A2.padSide * 2
        healthTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 16)
        healthKeys.frame = NSRect(x: A2.padSide, y: A2.padTop + 30, width: inner, height: A2Keys.keyHeight)
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
