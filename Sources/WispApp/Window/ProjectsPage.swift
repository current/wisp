import AppKit
import WispCore

/// Port numbers as small capsules. Clicking one offers to open it, copy its
/// address or stop the process behind it.
final class PortChips: DrawnView {
    struct Chip {
        var port: UInt16
        var server: DevServer
    }

    var chips: [Chip] = [] { didSet { needsDisplay = true } }
    var onStop: ((DevServer) -> Void)?
    private static let font = Theme.figure(11, .medium)

    private func frames() -> [NSRect] {
        var x: CGFloat = 0
        return chips.map { chip in
            let width = ceil(("\(chip.port)" as NSString).size(withAttributes: [.font: Self.font]).width) + 18
            defer { x += width + 6 }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    var naturalWidth: CGFloat { (frames().last?.maxX ?? 0) }

    override func draw(_ dirtyRect: NSRect) {
        for (chip, rect) in zip(chips, frames()) where rect.maxX <= bounds.width {
            let idle = chip.server.connections == 0 && (chip.server.idleSeconds ?? 0) >= DevServerScanner.idleAfter
            (idle ? Theme.warnWash : Theme.ground).setFill()
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            shape.fill()
            Theme.cardBorder.setStroke()
            shape.stroke()
            let text = "\(chip.port)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: idle ? Theme.warn : Theme.ink]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = frames().firstIndex(where: { $0.contains(point) }) else { return }
        let chip = chips[index]
        let menu = NSMenu()
        let url = "http://localhost:\(chip.port)"
        menu.addItem(ActionItem("Open \(url)") { NSWorkspace.shared.open(URL(string: url)!) })
        menu.addItem(ActionItem("Copy address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Stop \(chip.server.name) (\(chip.server.pid))…") { [weak self] in self?.onStop?(chip.server) })
        menu.popUp(positioning: nil, at: NSPoint(x: frames()[index].minX, y: bounds.height + 4), in: self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { "Ports " + chips.map { "\($0.port)" }.joined(separator: ", ") }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// One project: name, ports, folder and totals, then its servers.
final class ProjectCard: CardView {
    let name = TextLine()
    let chips = PortChips()
    let badge = Pill()
    let path = TextLine()
    let figures = TextLine()
    let bar = TickMeter()
    var serverRows: [ListRow] = []

    override init() {
        super.init()
        badge.tone = .warn
        bar.tickWidth = 2
        for view in [name, chips, badge, path, figures, bar] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func height(servers: Int) -> CGFloat { 74 + CGFloat(servers) * 30 + (servers > 0 ? 6 : 0) }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        name.frame = NSRect(x: 20, y: 16, width: min(name.naturalWidth + 4, width / 3), height: 20)
        let chipsWidth = min(chips.naturalWidth, width - 380)
        chips.frame = NSRect(x: name.frame.maxX + 10, y: 15, width: max(0, chipsWidth), height: 22)
        badge.frame = NSRect(x: chips.frame.maxX + (chipsWidth > 0 ? 8 : 0), y: 17, width: badge.naturalWidth, height: 18)
        path.frame = NSRect(x: 20, y: 42, width: width - 240, height: 14)
        figures.frame = NSRect(x: 20 + width - 300, y: 18, width: 300, height: 16)
        bar.frame = NSRect(x: 20 + width - 120, y: 44, width: 120, height: 8)
        for (index, row) in serverRows.enumerated() { row.frame = NSRect(x: 20, y: 68 + CGFloat(index) * 30, width: width, height: 30) }
    }
}

/// Projects with something running: dev servers and their ports, everything
/// else started in the folder, and the Docker containers of the same name.
@MainActor
final class ProjectsPage: CardPage {
    private lazy var titleLines = heading("Projects")
    private let memory = Tile("Memory"), cpu = Tile("CPU"), processes = Tile("Processes"), ports = Tile("Open ports")
    private let idleCard = CardView()
    private let idleTitle = TextLine()
    private let idleList = TextLine()
    private lazy var stopAll = ActionButton(title: "Stop All…", target: self, action: #selector(stopIdle))
    private var cards: [ProjectCard] = []
    private let scanner = DevServerScanner()
    private var projects: [DevProject] = []
    private var containers: [Container] = []
    private var scannedAt = Date.distantPast
    var onSelect: ((Selection?) -> Void)?

    override func loadView() {
        super.loadView()
        titleLines.1.text = Theme.caption("Looking for projects…")
        for view in [memory, cpu, processes, ports, idleCard] as [NSView] { canvas.addSubview(view) }
        idleCard.fill = Theme.warnWash
        idleCard.stroke = Theme.warn.withAlphaComponent(0.25)
        for view in [idleTitle, idleList, stopAll] as [NSView] { idleCard.addSubview(view) }
        for tile in [memory, cpu, processes, ports] { tile.tint = PageID.ports.tint }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        let top = place(titleLines.0, titleLines.1, width: width)
        var y = grid([memory, cpu, processes, ports], top: top, width: width, columns: 4, height: 112) + gap
        if idleCard.isHidden == false {
            idleCard.frame = NSRect(x: margin, y: y, width: inner, height: 76)
            idleTitle.frame = NSRect(x: 20, y: 16, width: inner - 180, height: 20)
            idleList.frame = NSRect(x: 20, y: 42, width: inner - 180, height: 14)
            let size = stopAll.intrinsicContentSize
            stopAll.frame = NSRect(x: inner - 20 - size.width, y: (76 - size.height) / 2, width: size.width, height: size.height)
            y = idleCard.frame.maxY + gap
        }
        for (index, card) in cards.enumerated() where index < projects.count {
            let height = ProjectCard.height(servers: projects[index].servers.count)
            card.frame = NSRect(x: margin, y: y, width: inner, height: height)
            y = card.frame.maxY + gap
        }
        return y + margin - gap
    }

    override func update(table: ProcessTable) {
        // Walking every process's sockets and folder costs a few milliseconds; do it every few seconds.
        guard Date().timeIntervalSince(scannedAt) > 4 else { return }
        scannedAt = Date()
        projects = scanner.scan(table).filter { !$0.path.isEmpty }
            .sorted { a, b in
                if a.servers.isEmpty != b.servers.isEmpty { return !a.servers.isEmpty }
                return a.memory > b.memory
            }
        containers = Docker.status(stats: false).containers
        fill(table)
    }

    private func fill(_ table: ProcessTable) {
        let processCount = projects.reduce(0) { $0 + $1.processes.count }
        titleLines.1.text = Theme.caption(projects.isEmpty ? "Nothing running in a project folder"
                                          : "\(projects.count) running · \(processCount) processes")
        let totalMemory = projects.reduce(0) { $0 + $1.memory }
        let (memoryValue, memoryUnit) = DashboardView.split(Format.memory(totalMemory))
        memory.set(text: memoryValue, unit: memoryUnit)
        memory.set(note: projects.max { $0.memory < $1.memory }.map { "Most in \($0.name)" } ?? "")
        let totalCPU = projects.reduce(0) { $0 + $1.cpu }
        cpu.set(text: Style.appCPU(totalCPU, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount))
        cpu.set(note: "Across every project")
        processes.set(text: "\(projects.reduce(0) { $0 + $1.processes.count })")
        processes.set(note: "Servers, watchers, editors")
        let openPorts = Set(projects.flatMap { $0.servers.flatMap { $0.ports.map(\.port) } }).sorted()
        ports.set(text: "\(openPorts.count)")
        ports.set(note: openPorts.prefix(5).map(String.init).joined(separator: " · ") + (openPorts.count > 5 ? " +\(openPorts.count - 5)" : ""))

        let idle = projects.flatMap(\.idleServers)
        idleCard.isHidden = idle.isEmpty
        if !idle.isEmpty {
            let held = idle.reduce(0) { $0 + $1.memory }
            idleTitle.text = NSAttributedString(string: "\(idle.count) dev \(idle.count == 1 ? "server is" : "servers are") running but idle",
                                                attributes: [.font: Theme.sans(14, .medium), .foregroundColor: Theme.ink])
            let names = Dictionary(grouping: projects.filter { !$0.idleServers.isEmpty }, by: \.name)
                .map { $0.value.first!.idleServers.count > 1 ? "\($0.key) ×\($0.value.first!.idleServers.count)" : $0.key }.sorted()
            idleList.text = Theme.caption(names.joined(separator: ", ") + " · holding \(Format.memory(held))", color: Theme.inkSecondary)
        }

        while cards.count < projects.count {
            let card = ProjectCard()
            canvas.addSubview(card)
            cards.append(card)
        }
        for (index, card) in cards.enumerated() {
            guard index < projects.count else { card.isHidden = true; continue }
            card.isHidden = false
            fill(card, projects[index], table: table)
        }
        relayout()
    }

    private func fill(_ card: ProjectCard, _ project: DevProject, table: ProcessTable) {
        card.name.text = NSAttributedString(string: project.name, attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink])
        card.chips.chips = project.servers.flatMap { server in Set(server.ports.map(\.port)).sorted().map { PortChips.Chip(port: $0, server: server) } }
        card.chips.onStop = { [weak self] server in self?.confirmStop([server]) }
        let idle = project.idleServers.count
        card.badge.isHidden = idle == 0
        card.badge.text = "\(idle) idle"
        let home = NSHomeDirectory()
        let mine = containers.filter { container in
            if let folder = container.folder { return folder == project.path || folder.hasPrefix(project.path + "/") }
            return container.project?.lowercased() == project.name.lowercased()
        }
        var where_ = project.path.replacingOccurrences(of: home, with: "~") + " · \(project.processes.count) processes"
        if !mine.isEmpty { where_ += " · \(mine.count) container\(mine.count == 1 ? "" : "s")" }
        card.path.text = Theme.caption(where_, color: Theme.inkTertiary, size: 9.5)
        let figures = NSMutableAttributedString()
        for (label, value) in [("CPU", Style.appCPU(project.cpu, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount)),
                               ("Power", Format.watts(project.watts)), ("Memory", Format.memory(project.memory))] {
            figures.append(NSAttributedString(string: value, attributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink]))
            figures.append(NSAttributedString(string: " " + label.uppercased() + "    ", attributes: [.font: Theme.mono(9), .foregroundColor: Theme.inkTertiary]))
        }
        card.figures.text = figures
        card.figures.alignment = .right
        let peak = max(projects.map(\.memory).max() ?? 1, 1)
        card.bar.fraction = Double(project.memory) / Double(peak)
        card.bar.color = Theme.action

        while card.serverRows.count < project.servers.count {
            let row = ListRow()
            row.showsBar = false
            card.addSubview(row)
            card.serverRows.append(row)
        }
        for (index, row) in card.serverRows.enumerated() {
            guard index < project.servers.count else { row.isHidden = true; continue }
            let server = project.servers[index]
            row.isHidden = false
            row.dot = server.connections > 0 ? Theme.good : (project.idleServers.contains { $0.pid == server.pid } ? Theme.warn : Theme.inkTertiary)
            row.name = "\(server.name)  \(server.pid)"
            row.note = server.ports.map { "\($0.port)" }.joined(separator: ", ")
            row.value = server.connections > 0 ? "\(server.connections) connected"
                : (server.idleSeconds.map { $0 >= 60 ? "Idle " + Format.duration($0) : "Listening" } ?? "")
            row.showsRule = index < project.servers.count - 1
            row.onClick = { [weak self] in self?.onSelect?(.process(server.pid)) }
        }
    }

    @objc private func stopIdle() { confirmStop(projects.flatMap(\.idleServers)) }

    /// Asks first, then sends SIGTERM so the servers can shut down cleanly.
    private func confirmStop(_ servers: [DevServer]) {
        guard !servers.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = servers.count == 1 ? "Stop \(servers[0].name) (\(servers[0].pid))?" : "Stop \(servers.count) idle dev servers?"
        alert.informativeText = servers.map { server in
            "\(server.name) \(server.pid) on " + server.ports.map { "\($0.port)" }.joined(separator: ", ")
        }.joined(separator: "\n") + "\n\nEach gets a normal quit signal and can save its work first."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            for server in servers { kill(server.pid, SIGTERM) }
            self?.scannedAt = .distantPast
        }
    }
}
