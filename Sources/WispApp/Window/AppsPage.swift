import AppKit
import WispCore

/// Every app as one row, expandable to its processes. Rows are kept as objects
/// keyed by app id and pid so a reload every couple of seconds keeps expansion
/// and selection where the user left them.
@MainActor
final class AppsPage: NSViewController, Page, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
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
    private let outline = NSOutlineView()
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
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autosaveName = "WispApps"
        outline.autosaveTableColumns = true
        outline.autosaveExpandedItems = false
        outline.rowHeight = 24
        outline.sortDescriptors = [NSSortDescriptor(key: Column.cpu.rawValue, ascending: false)]
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = "Filter apps and processes"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.sendsSearchStringImmediately = true

        let bar = Style.stack([search, summary], axis: .horizontal, spacing: Style.pad)
        let root = NSView()
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Style.section),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Style.section),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Style.pad),
            search.widthAnchor.constraint(equalToConstant: 240),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Style.pad),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        result.sort(by: appOrder)
        roots = result
        if nodes.count > live.count + 256 { nodes = nodes.filter { live.contains($0.key) } }

        let selected = outline.item(atRow: outline.selectedRow) as? Node
        outline.reloadData()
        if let selected, outline.row(forItem: selected) >= 0 {
            outline.selectRowIndexes([outline.row(forItem: selected)], byExtendingSelection: false)
        }
        if let pending = pendingSelection, let target = nodes["app:" + pending], outline.row(forItem: target) >= 0 {
            pendingSelection = nil
            let row = outline.row(forItem: target)
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        let processCount = table.processes.count
        summary.stringValue = "\(roots.count) apps, \(processCount) processes"
            + (table.unattributedCPU > 0.05 ? ", \(Style.appCPU(table.unattributedCPU, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount)) CPU in processes Wisp cannot read" : "")
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
        cell.set(text, faint: faint)
        return cell
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

    func controlTextDidChange(_ obj: Notification) { rebuild() }
}

/// Icon, name and a quiet note (a pid, or why figures are missing).
final class NameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = Style.label()
    private let note = Style.label("", font: Style.smallFigure, color: .tertiaryLabelColor)
    private var iconWidth: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(name)
        addSubview(note)
        imageView = icon
        textField = name
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 18)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            note.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(icon image: NSImage?, name text: String, note noteText: String?) {
        icon.image = image
        iconWidth.constant = image == nil ? 0 : 18
        name.stringValue = text
        note.stringValue = noteText ?? ""
    }
}

/// A right-aligned figure in tabular digits.
final class FigureCell: NSTableCellView {
    private let label = Style.label("", font: Style.figure)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = .right
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, faint: Bool) {
        if label.stringValue != text { label.stringValue = text }
        label.textColor = faint ? .tertiaryLabelColor : .labelColor
    }
}
