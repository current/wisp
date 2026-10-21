import AppKit
import WispCore

/// Shared shape of the developer pages: a title, a one-line summary, an outline,
/// and work that runs off the main thread at most every few seconds while shown.
@MainActor
class DeveloperPage: NSViewController, Page, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item {
        let key: String
        var columns: [String]
        var faint = false
        var accent = false
        var icon: NSImage?
        var children: [Item] = []
        var selection: Selection?
        init(key: String, columns: [String]) {
            self.key = key
            self.columns = columns
        }
    }

    unowned let delegate: AppDelegate
    let outline = NSOutlineView()
    let summary = Style.secondary("", font: Style.body)
    let empty = Style.secondary("", font: Style.body)
    var items: [Item] = []
    private var expanded = Set<String>()
    private var expandedOnce = false
    private var lastRun = Date.distantPast
    private var running = false
    let queue = DispatchQueue(label: "app.wisp.developer", qos: .utility)
    var onSelect: ((Selection?) -> Void)?

    var titleText: String { "" }
    var columns: [(String, CGFloat, Bool)] { [] }
    var refreshInterval: TimeInterval { 5 }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (index, (title, width, right)) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init("\(index)"))
            column.title = title
            column.width = width
            if right { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if index == 0 { outline.outlineTableColumn = column }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.style = .inset
        outline.rowHeight = 24
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autosaveExpandedItems = false
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let title = Style.label(titleText, font: NSFont.systemFont(ofSize: 15, weight: .semibold))
        let header = Style.stack([title, summary], axis: .vertical, spacing: 2, alignment: .leading)
        let root = NSView()
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(empty)
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.lineBreakMode = .byWordWrapping
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Style.section),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Style.section),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Style.pad),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Style.pad),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        view = root
    }

    func update(table: ProcessTable) {
        guard !running, Date().timeIntervalSince(lastRun) >= refreshInterval * 0.9 else { return }
        running = true
        lastRun = Date()
        let work = makeWork(table)
        queue.async {
            let result = work()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                self.apply(result)
            }
        }
    }

    /// Runs on a background queue; returns whatever `apply` needs.
    func makeWork(_ table: ProcessTable) -> () -> Any { { () } }
    func apply(_ result: Any) {}

    func show(_ newItems: [Item], emptyText: String) {
        let selectedKey = (outline.item(atRow: outline.selectedRow) as? Item)?.key
        items = newItems
        outline.reloadData()
        let expandAll = !expandedOnce && !items.isEmpty
        if expandAll { expandedOnce = true }
        for item in items where !item.children.isEmpty && (expanded.contains(item.key) || (expandAll && items.count <= 12)) {
            outline.expandItem(item)
            expanded.insert(item.key)
        }
        if let selectedKey {
            for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? Item)?.key == selectedKey {
                outline.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        empty.stringValue = emptyText
        empty.isHidden = !items.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item { expanded.insert(item.key) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item { expanded.remove(item.key) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item, let id = tableColumn?.identifier, let index = Int(id.rawValue) else { return nil }
        let text = index < item.columns.count ? item.columns[index] : ""
        if index == 0 {
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NameCell) ?? NameCell(identifier: id)
            cell.set(icon: item.icon, name: text, note: nil)
            cell.textField?.font = item.children.isEmpty ? Style.body : NSFont.systemFont(ofSize: 12, weight: .semibold)
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? FigureCell) ?? FigureCell(identifier: id)
        cell.alignment = columns[index].2 ? .right : .left
        cell.color = item.accent && index == columns.count - 1 ? .systemOrange : nil
        cell.set(text, faint: item.faint)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let item = outline.item(atRow: outline.selectedRow) as? Item
        onSelect?(item?.selection)
    }
}

// MARK: Dev servers

@MainActor
final class PortsPage: DeveloperPage {
    private let scanner = DevServerScanner()
    override var titleText: String { "Dev Servers" }
    override var columns: [(String, CGFloat, Bool)] {
        [("Project and process", 240, false), ("Ports", 120, false), ("CPU", 64, true), ("Memory", 72, true), ("Activity", 120, false)]
    }

    override func makeWork(_ table: ProcessTable) -> () -> Any {
        let scanner = self.scanner
        return { scanner.scan(table) }
    }

    override func apply(_ result: Any) {
        guard let projects = result as? [DevProject] else { return }
        let machine = delegate.settings.cpuOfMachine
        let cores = delegate.table.coreCount
        var idleCount = 0
        let items = projects.map { project -> Item in
            let group = Item(key: "p:" + project.path, columns: [project.name, "", "", "", ""])
            group.icon = NSImage(systemSymbolName: project.path.isEmpty ? "questionmark.folder" : "folder", accessibilityDescription: nil)
            group.children = project.servers.map { server in
                let ports = Array(Set(server.ports.map(\.port))).sorted().map(String.init).joined(separator: ", ")
                var activity = server.connections > 0 ? "\(server.connections) connected" : "No connections"
                var accent = false
                if let idle = server.idleSeconds, server.connections == 0, idle >= DevServerScanner.idleAfter, project.path.isEmpty == false {
                    activity = "Idle " + Format.duration(idle)
                    accent = true
                    idleCount += 1
                }
                let item = Item(key: "s:\(server.pid)", columns: [server.name + "  " + String(server.pid), ports,
                                                                  Style.appCPU(server.cpu, machine: machine, coreCount: cores),
                                                                  Format.memory(server.memory), activity])
                item.accent = accent
                item.selection = .process(server.pid)
                return item
            }
            return group
        }
        let servers = projects.reduce(0) { $0 + $1.servers.count }
        summary.stringValue = servers == 0 ? "" : "\(servers) processes listening in \(projects.filter { !$0.path.isEmpty }.count) projects"
            + (idleCount > 0 ? ". \(idleCount) idle for over 30 minutes." : ".")
        show(items, emptyText: "Nothing of yours is listening on a port.")
    }
}

// MARK: Docker

@MainActor
final class DockerPage: DeveloperPage {
    private let watcher = DockerWatcher()
    override var titleText: String { "Docker" }
    override var columns: [(String, CGFloat, Bool)] {
        [("Container", 220, false), ("Image", 160, false), ("Ports", 120, false), ("CPU", 60, true), ("Memory", 80, true), ("Status", 140, false)]
    }

    override func makeWork(_ table: ProcessTable) -> () -> Any {
        let watcher = self.watcher
        return { Docker.status(stats: true, watcher: watcher) }
    }

    override func apply(_ result: Any) {
        guard let status = result as? DockerStatus else { return }
        var groups: [String: [Container]] = [:]
        for container in status.containers { groups[container.project ?? "", default: []].append(container) }
        func row(_ c: Container) -> Item {
            let memory = c.memory.map { Format.memory($0) } ?? "–"
            let item = Item(key: "c:" + c.id, columns: [c.name, c.image, c.ports.joined(separator: ", "),
                                                         c.cpu.map { Format.percent($0, digits: 1) } ?? "–", memory, c.status])
            item.icon = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            return item
        }
        var items: [Item] = []
        for (project, containers) in groups.sorted(by: { $0.key < $1.key }) {
            if project.isEmpty {
                items += containers.map(row)
            } else {
                let group = Item(key: "g:" + project, columns: [project, "Compose project", "", "", "", ""])
                group.icon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
                group.children = containers.map(row)
                items.append(group)
            }
        }
        if let socket = status.socket {
            let short = socket.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            summary.stringValue = "\(status.containers.count) running, engine at \(short)"
        } else {
            summary.stringValue = ""
        }
        show(items, emptyText: status.socket == nil ? "No Docker engine is running. Wisp looks for Docker Desktop, OrbStack, Colima, Rancher Desktop and Lima."
                                                    : "No containers are running.")
    }
}

// MARK: Coding agents

@MainActor
final class AgentsPage: DeveloperPage {
    private let finder = AgentFinder()
    override var titleText: String { "Coding Agents" }
    override var refreshInterval: TimeInterval { 2 }
    override var columns: [(String, CGFloat, Bool)] {
        [("Agent and processes", 260, false), ("Folder", 200, false), ("CPU", 64, true), ("Memory", 72, true), ("Running for", 100, false)]
    }

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        super.init(delegate: delegate)
        self.onSelect = onSelect
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeWork(_ table: ProcessTable) -> () -> Any {
        let finder = self.finder
        return { finder.find(table) }
    }

    override func apply(_ result: Any) {
        guard let agents = result as? [CodingAgent] else { return }
        let machine = delegate.settings.cpuOfMachine
        let cores = delegate.table.coreCount
        let home = NSHomeDirectory()
        let now = Date()
        let items = agents.map { agent -> Item in
            let folder = agent.folder.map { $0.replacingOccurrences(of: home, with: "~") } ?? ""
            let age = agent.startDate.map { Format.duration(now.timeIntervalSince($0)) } ?? ""
            let title = agent.kind + (agent.host.map { $0 != agent.kind ? " in \($0)" : "" } ?? "")
            let item = Item(key: "a:\(agent.pid)", columns: [title, folder, Style.appCPU(agent.cpu, machine: machine, coreCount: cores),
                                                              Format.memory(agent.memory), age])
            item.icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            item.selection = .process(agent.pid)
            item.children = agent.processes.dropFirst().map { row in
                let child = Item(key: "p:\(row.pid)", columns: ["\(row.name)  \(row.pid)", "",
                                                                 Style.appCPU(row.cpu, machine: machine, coreCount: cores),
                                                                 Format.memory(row.memory),
                                                                 row.startDate.map { Format.duration(now.timeIntervalSince($0)) } ?? ""])
                child.selection = .process(row.pid)
                return child
            }
            return item
        }
        let processes = agents.reduce(0) { $0 + $1.processes.count }
        summary.stringValue = agents.isEmpty ? "" : "\(agents.count) agents running \(processes) processes between them"
        show(items, emptyText: "No coding agents are running. Wisp recognises Claude Code, Codex, Cursor Agent, Gemini CLI, Aider, OpenCode and others.")
    }
}
