import AppKit
import WispCore

/// Every app as one row, expandable to its processes. Rows are kept as objects
/// keyed by app id and pid so a reload every couple of seconds keeps expansion
/// and selection where the user left them.
@MainActor
final class AppsPage: NSViewController, Page, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    /// The Network column needs per-app traffic, about 2 ms a tick while the page shows.
    var demand: Demand { [.appNetwork] }

    final class Node {
        let key: String
        var app: AppGroup?
        var process: ProcessRow?
        var children: [Node] = []
        init(key: String) { self.key = key }
    }

    enum Column: String, CaseIterable {
        case name, cpu, memory, energy, disk, network

        var title: String {
            switch self {
            case .name: return "Name"
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .energy: return "Power"
            case .disk: return "Disk"
            case .network: return "Network"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 170
            default: return 74
            }
        }
    }

    private unowned let delegate: AppDelegate
    private let onSelect: (Selection?) -> Void
    let outline = NSOutlineView()
    private let search = NSSearchField()
    private let summary = Style.secondary()
    private var nodes: [String: Node] = [:]
    private var roots: [Node] = []
    private var sortColumn: Column = .cpu
    private var ascending = false
    private var table = ProcessTable()
    private var pendingSelection: String?

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        self.delegate = delegate
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 140 : 56
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .name)
            if column != .name { tableColumn.headerCell.alignment = .right }
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 12, height: 0)
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autosaveName = "WispApps"
        outline.autosaveTableColumns = true
        outline.autosaveExpandedItems = false
        outline.rowHeight = 30
        outline.sortDescriptors = [NSSortDescriptor(key: Column.cpu.rawValue, ascending: false)]
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)

        let scroll = NSScrollView()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer?.masksToBounds = true
        card.addSubview(scroll)

        search.placeholderString = "Filter apps and processes"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.sendsSearchStringImmediately = true

        summary.font = Theme.mono(10)
        summary.textColor = Theme.inkTertiary
        let title = Style.label("Apps", font: Theme.sans(20, .medium), color: Theme.ink)
        let bar = Style.stack([title, summary], axis: .horizontal, spacing: Style.pad)
        bar.alignment = .firstBaseline
        let root = GroundView()
        root.addSubview(bar)
        root.addSubview(search)
        root.addSubview(card)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            search.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            search.widthAnchor.constraint(equalToConstant: 240),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: search.leadingAnchor, constant: -Style.pad),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
        ])
        view = root
    }

    // MARK: Data

    func update(table: ProcessTable) {
        self.table = table
        rebuild()
    }

    private func node(_ key: String) -> Node {
        if let existing = nodes[key] { return existing }
        let fresh = Node(key: key)
        nodes[key] = fresh
        return fresh
    }

    private func rebuild() {
        let filter = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var byPID: [Int32: ProcessRow] = [:]
        byPID.reserveCapacity(table.processes.count)
        for row in table.processes { byPID[row.pid] = row }

        var live = Set<String>()
        var result: [Node] = []
        for app in table.apps {
            var processes = app.pids.compactMap { byPID[$0] }
            if !filter.isEmpty, !app.name.lowercased().contains(filter) {
                processes = processes.filter { $0.name.lowercased().contains(filter) || String($0.pid) == filter }
                if processes.isEmpty { continue }
            }
            let appNode = node("app:" + app.id)
            appNode.app = app
            live.insert(appNode.key)
            appNode.children = processes.map { row in
                let child = node("pid:\(row.pid)")
                child.process = row
                live.insert(child.key)
                return child
            }
            appNode.children.sort(by: processOrder)
            result.append(appNode)
        }
        // Re-rank at most every few seconds. Between re-ranks rows keep their places and
        // only their figures change, which is easier to read and far cheaper to draw.
        let now = Date()
        let sameApps = Set(result.map(\.key)) == Set(roots.map(\.key))
        if sameApps, !forceSort, now.timeIntervalSince(lastSort) < 6 {
            let position = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1.key, $0) })
            result.sort { (position[$0.key] ?? 0) < (position[$1.key] ?? 0) }
        } else {
            result.sort(by: appOrder)
            lastSort = now
            forceSort = false
        }
        roots = result
        if nodes.count > live.count + 256 { nodes = nodes.filter { live.contains($0.key) } }

        // Same rows in the same order: refresh only what is on screen. Anything else
        // (a new app, a change in ranking) needs a full reload.
        let order = flatOrder()
        if order == lastOrder {
            refreshVisible()
        } else {
            let selected = outline.item(atRow: outline.selectedRow) as? Node
            outline.reloadData()
            if let selected, outline.row(forItem: selected) >= 0 {
                outline.selectRowIndexes([outline.row(forItem: selected)], byExtendingSelection: false)
            }
            lastOrder = flatOrder()
        }
        if let pending = pendingSelection, let target = nodes["app:" + pending], outline.row(forItem: target) >= 0 {
            pendingSelection = nil
            let row = outline.row(forItem: target)
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        // Counts move rarely; a label that changes every tick re-lays out the whole window.
        let text = "\(roots.count) apps, \(table.processes.count / 10 * 10)+ processes"
        if summary.stringValue != text { summary.stringValue = text }
    }

    private var lastOrder: [String] = []

    /// Writes new figures into the cells already on screen. Only labels whose text
    /// changed redraw; nothing is re-created or laid out again.
    private func refreshVisible() {
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        let columns = outline.tableColumns.compactMap { Column(rawValue: $0.identifier.rawValue) }
        for row in visible.location..<(visible.location + visible.length) {
            guard let node = outline.item(atRow: row) as? Node else { continue }
            for (index, column) in columns.enumerated() where column != .name {
                guard let cell = outline.view(atColumn: index, row: row, makeIfNecessary: false) as? FigureCell else { continue }
                let (text, faint) = figure(node, column)
                cell.set(text, faint: faint)
            }
        }
    }
    private var lastSort = Date.distantPast
    private var forceSort = false

    /// Keys of the rows as the outline would show them, expanded children included.
    private func flatOrder() -> [String] {
        var keys: [String] = []
        keys.reserveCapacity(roots.count + 32)
        for root in roots {
            keys.append(root.key)
            if outline.isItemExpanded(root) { keys.append(contentsOf: root.children.map(\.key)) }
        }
        return keys
    }

    func select(appID: String) {
        pendingSelection = appID
        if !table.apps.isEmpty { rebuild() }
    }

    private func value(_ column: Column, app: AppGroup) -> Double {
        switch column {
        case .name: return 0
        case .cpu: return app.cpu
        case .memory: return Double(app.memory)
        case .energy: return app.watts
        case .disk: return app.diskPerSecond
        case .network: return app.networkPerSecond
        }
    }

    private func value(_ column: Column, process row: ProcessRow) -> Double {
        switch column {
        case .name: return 0
        case .cpu: return row.cpu
        case .memory: return Double(row.memory)
        case .energy: return row.watts
        case .disk: return row.diskReadPerSecond + row.diskWritePerSecond
        case .network: return row.networkInPerSecond + row.networkOutPerSecond
        }
    }

    private func appOrder(_ a: Node, _ b: Node) -> Bool {
        guard let x = a.app, let y = b.app else { return false }
        if sortColumn == .name {
            let order = x.name.localizedStandardCompare(y.name)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        let (u, v) = (value(sortColumn, app: x), value(sortColumn, app: y))
        if u == v { return x.name < y.name }
        return ascending ? u < v : u > v
    }

    private func processOrder(_ a: Node, _ b: Node) -> Bool {
        guard let x = a.process, let y = b.process else { return false }
        if sortColumn == .name {
            return x.name.localizedStandardCompare(y.name) == .orderedAscending
        }
        let (u, v) = (value(sortColumn, process: x), value(sortColumn, process: y))
        if u == v { return x.pid < y.pid }
        return ascending ? u < v : u > v
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.app != nil && node.children.count > 1
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = outlineView.sortDescriptors.first, let column = Column(rawValue: first.key ?? "") else { return }
        sortColumn = column
        ascending = first.ascending
        forceSort = true
        rebuild()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let machine = delegate.settings.cpuOfMachine
        let cores = table.coreCount

        if column == .name {
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NameCell) ?? NameCell(identifier: id)
            if let app = node.app {
                let note = app.unreadable == app.processCount ? "needs admin" : (app.processCount > 1 ? "\(app.processCount)" : nil)
                cell.set(icon: Icons.icon(for: app), name: app.name, note: note)
            } else if let row = node.process {
                cell.set(icon: nil, name: row.name, note: "\(row.pid)")
            }
            return cell
        }

        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? FigureCell) ?? FigureCell(identifier: id)
        let (text, faint) = figure(node, column)
        cell.set(text, faint: faint)
        return cell
    }

    private func figure(_ node: Node, _ column: Column) -> (String, Bool) {
        let machine = delegate.settings.cpuOfMachine
        let cores = table.coreCount
        var text = ""
        var faint = false
        if let app = node.app {
            switch column {
            case .cpu: text = Style.appCPU(app.cpu, machine: machine, coreCount: cores)
            case .memory: text = Format.memory(app.memory)
            case .energy: text = app.watts > 0.005 ? Format.watts(app.watts) : "–"
            case .disk: text = app.diskPerSecond > 0 ? Format.rate(app.diskPerSecond) : "–"
            case .network: text = table.networkMeasured ? (app.networkPerSecond > 0 ? Format.rate(app.networkPerSecond) : "–") : ""
            case .name: break
            }
            faint = app.unreadable == app.processCount
        } else if let row = node.process {
            faint = !row.readable
            switch column {
            case .cpu: text = row.readable ? Style.appCPU(row.cpu, machine: machine, coreCount: cores) : "–"
            case .memory: text = row.readable ? Format.memory(row.memory) : "–"
            case .energy: text = row.watts > 0.005 ? Format.watts(row.watts) : "–"
            case .disk:
                let disk = row.diskReadPerSecond + row.diskWritePerSecond
                text = disk > 0 ? Format.rate(disk) : "–"
            case .network:
                let net = row.networkInPerSecond + row.networkOutPerSecond
                text = table.networkMeasured ? (net > 0 ? Format.rate(net) : "–") : ""
            case .name: break
            }
        }
        return (text, faint)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else {
            onSelect(nil)
            return
        }
        if let app = node.app { onSelect(.app(app.id)) } else if let row = node.process { onSelect(.process(row.pid)) }
    }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node, node.app != nil else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    func controlTextDidChange(_ obj: Notification) {
        forceSort = true
        rebuild()
    }
}

/// Icon, name and a quiet note (a pid, or why figures are missing). Laid out by
/// hand: a table full of constraint-based cells re-solves them all on every reload.
final class NameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = Style.label()
    private let note = Style.label("", font: Style.smallFigure, color: .tertiaryLabelColor)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for view in [icon, name, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        // Not assigned to textField: the table would then restyle the label after
        // layout and the measured width would no longer fit the text. The labels
        // stay accessible on their own.
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            name.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            note.textColor = emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var font: NSFont {
        get { name.font ?? Style.body }
        set { if name.font != newValue { name.font = newValue; needsLayout = true } }
    }

    func set(icon image: NSImage?, name text: String, note noteText: String?) {
        if icon.image !== image { icon.image = image }
        icon.isHidden = image == nil
        if name.stringValue != text { name.stringValue = text }
        let noteValue = noteText ?? ""
        if note.stringValue != noteValue { note.stringValue = noteValue }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 2
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (height - 18) / 2, width: 18, height: 18)
            x += 24
        }
        let noteWidth = note.stringValue.isEmpty ? 0 : ceil(note.cell?.cellSize.width ?? 0)
        let nameHeight = ceil(name.cell?.cellSize.height ?? 16)
        let nameWidth = min(ceil(name.cell?.cellSize.width ?? 0), max(0, bounds.width - x - 4 - (noteWidth > 0 ? noteWidth + 6 : 0)))
        name.frame = NSRect(x: x, y: (height - nameHeight) / 2, width: nameWidth, height: nameHeight)
        if noteWidth > 0 {
            let noteHeight = ceil(note.cell?.cellSize.height ?? 14)
            let baseline = name.frame.minY + name.baselineOffsetFromBottom - note.baselineOffsetFromBottom
            note.frame = NSRect(x: name.frame.maxX + 6, y: baseline, width: min(noteWidth, max(0, bounds.width - name.frame.maxX - 10)), height: noteHeight)
        } else {
            note.frame = .zero
        }
    }
}

/// The grey ground behind pages that are not card canvases.
final class GroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.ground.cgColor }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A figure in tabular digits that draws itself. Setting new text only marks the
/// cell for redraw; a text field would invalidate its size and re-lay out the window.
final class FigureCell: NSTableCellView {
    private static let font = Style.figure
    private var text = ""
    private var faint = false
    var alignment: NSTextAlignment = .right { didSet { needsDisplay = true } }
    var color: NSColor? { didSet { needsDisplay = true } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ newText: String, faint newFaint: Bool) {
        guard newText != text || newFaint != faint else { return }
        text = newText
        faint = newFaint
        setAccessibilityValue(newText)
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let emphasized = backgroundStyle == .emphasized
        let textColor = emphasized ? NSColor.alternateSelectedControlTextColor
            : (color ?? (faint ? .tertiaryLabelColor : .labelColor))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor, .paragraphStyle: paragraph]
        let height = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        (text as NSString).draw(in: NSRect(x: 2, y: (bounds.height - height) / 2, width: max(0, bounds.width - 6), height: height),
                                withAttributes: attributes)
    }
}
