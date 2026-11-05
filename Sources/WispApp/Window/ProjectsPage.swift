import AppKit
import WispCore

/// Port numbers as small capsules, amber when the server behind it is idle.
/// Clicking one offers to open it, copy its address or stop the process behind it.
final class PortChips: BitmapView {
    struct Chip {
        var port: UInt16
        var server: DevServer
    }

    var chips: [Chip] = [] { didSet { needsDisplay = true } }
    var onStop: ((DevServer) -> Void)?
    private static let font = Theme.digits(11, .medium)

    private func frames() -> [NSRect] {
        var x: CGFloat = 0
        return chips.map { chip in
            let width = A2Dev.width("\(chip.port)", Self.font) + 14
            defer { x += width + 6 }
            return NSRect(x: x, y: (bounds.height - 20) / 2, width: width, height: 20)
        }
    }

    var naturalWidth: CGFloat { (frames().last?.maxX ?? 0) }

    private static func idle(_ server: DevServer) -> Bool {
        server.connections == 0 && (server.idleSeconds ?? 0) >= DevServerScanner.idleAfter
    }

    override func draw(_ dirtyRect: NSRect) {
        for (chip, rect) in zip(chips, frames()) where rect.maxX <= bounds.width {
            let idle = Self.idle(chip.server)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            (idle ? A2Dev.warnWash : A2Dev.chip).setFill()
            shape.fill()
            (idle ? A2Dev.warnLine : A2Dev.chipLine).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            A2Dev.text("\(chip.port)", x: rect.minX + 7, mid: rect.midY, width: rect.width - 10, font: Self.font,
                       color: idle ? A2.warn : A2.primary)
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

/// A project's first lines: folder symbol, name, port chips and idle count, the
/// folder and process count under them, and CPU, power and memory on the right
/// over a memory meter. The chips are a subview so they can take clicks.
final class ProjectHeader: BitmapView {
    let chips = PortChips()
    var name = "" { didSet { if name != oldValue { needsLayout = true; needsDisplay = true } } }
    var idle = 0 { didSet { if idle != oldValue { needsDisplay = true } } }
    var path = "" { didSet { if path != oldValue { needsDisplay = true } } }
    var figures: [(String, String)] = [] { didSet { needsDisplay = true } }
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    private static let nameFont = Theme.sans(14, .semibold)
    private static let figureFont = Theme.digits(13, .semibold)
    private static let figureLabel = Theme.sans(11, .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(chips)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var figuresWidth: CGFloat {
        figures.reduce(0) { $0 + A2Dev.width($1.0, Self.figureFont) + 4 + A2Dev.width($1.1, Self.figureLabel) } + 16 * CGFloat(max(0, figures.count - 1))
    }

    private var textRight: CGFloat { bounds.width - max(120, figuresWidth) - 16 }

    override func layout() {
        super.layout()
        let nameRight = min(44 + A2Dev.width(name, Self.nameFont), textRight - 60)
        let room = max(0, textRight - nameRight - 10 - (idle > 0 ? 60 : 0))
        chips.frame = NSRect(x: nameRight + 10, y: 0, width: min(chips.naturalWidth, room), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint = A2Dev.tint(.ports)
        let fold = NSRect(x: 0, y: (bounds.height - 32) / 2, width: 32, height: 32)
        tint.withAlphaComponent(A2.drawingDark ? 0.16 : 0.1).setFill()
        NSBezierPath(roundedRect: fold, xRadius: 9, yRadius: 9).fill()
        IconTile.glyph(PageID.ports.symbol, tint: tint, size: 16, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 8, y: fold.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: nil)

        let used = A2Dev.text(name, x: 44, mid: 10, width: textRight - 104, font: Self.nameFont, color: A2.primary)
        if idle > 0 {
            let x = chips.naturalWidth > 0 ? chips.frame.maxX + 8 : 44 + used + 10
            A2Dev.drawTag("\(idle) idle", x: x, mid: 10, font: Theme.sans(11, .semibold))
        }
        A2Dev.text(path, x: 44, mid: 30.5, width: textRight - 44, font: A2Dev.detailFont, color: A2.tertiary)

        var x = bounds.width - figuresWidth
        for (value, label) in figures {
            x += A2Dev.text(value, x: x, mid: 10, width: 200, font: Self.figureFont, color: A2.primary) + 4
            x += A2Dev.text(label, x: x, mid: 10.5, width: 200, font: Self.figureLabel, color: A2.tertiary) + 16
        }
        A2Dev.drawMeter(NSRect(x: bounds.width - 120, y: 28, width: 120, height: 5), fraction: fraction, colors: A2Dev.meter(.ports))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { ([path] + figures.map { "\($0.1) \($0.0)" }).joined(separator: ", ") }
}

/// A dev server under its project: a status dot, the name and pid, its port, how it
/// is doing and a Stop button. A hairline above each row.
final class ServerRow: BitmapView {
    let stop = A2PillButton()
    var dot: NSColor = A2Dev.quiet
    var name = ""
    var pid = ""
    var port = ""
    var status = ""
    var statusColor: NSColor = A2.secondary
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stop.title = "Stop"
        addSubview(stop)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = stop.naturalWidth - 2
        stop.frame = NSRect(x: bounds.width - width, y: ((bounds.height - 24) / 2).rounded(), width: width, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        A2.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        let mid = bounds.height / 2
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: mid - 3.5, width: 7, height: 7)).fill()
        let statusRight = stop.frame.minX - 6
        let portX = statusRight - 120 - 10 - 110
        let used = A2Dev.text(name, x: 17, mid: mid, width: portX - 27, font: A2Dev.nameFont, color: A2.primary)
        A2Dev.text(pid, x: 17 + used + 6, mid: mid + 1, width: portX - 33 - used, font: A2Dev.noteFont, color: A2.tertiary)
        A2Dev.text(port, x: portX, mid: mid, width: 110, font: Theme.digits(12, .regular), color: A2.secondary)
        A2Dev.text(status, x: statusRight - 120, mid: mid, width: 120, font: Theme.digits(12, .medium),
                   color: statusColor, right: true)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "\(name) \(pid)" }
    override func accessibilityValue() -> Any? { "\(port), \(status)" }
}

/// One project: its header, then a row per dev server.
final class ProjectCard: CardView {
    let header = ProjectHeader()
    var serverRows: [ServerRow] = []

    override init() {
        super.init()
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The mockup's heights: 76 with no servers, then 78 plus 31 a server.
    static func height(servers: Int) -> CGFloat { servers == 0 ? 76 : 78 + CGFloat(servers) * 31 }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        let shown = serverRows.filter { !$0.isHidden }
        header.frame = NSRect(x: A2.padSide, y: shown.isEmpty ? (bounds.height - 40) / 2 : A2.padTop, width: inner, height: 40)
        for (index, row) in shown.enumerated() {
            row.frame = NSRect(x: A2.padSide + 44, y: A2.padTop + 50 + CGFloat(index) * 31, width: inner - 44, height: 31)
        }
    }
}

/// Projects with something running: dev servers and their ports, everything
/// else started in the folder, and the Docker containers of the same name.
@MainActor
final class ProjectsPage: CardPage {
    override var pageTint: NSColor { PageID.ports.tint }
    private lazy var titleLines = heading("Projects")
    private let memory = A2Tile("Memory", symbol: PageID.memory.symbol, tint: A2Dev.tint(.ports))
    private let cpu = A2Tile("CPU", symbol: PageID.cpu.symbol, tint: A2Dev.tint(.ports))
    private let processes = A2Tile("Processes", symbol: "macwindow", tint: A2Dev.tint(.ports))
    private let ports = A2Tile("Open ports", symbol: "server.rack", tint: A2Dev.tint(.ports))
    private let idleCard = A2NoticeCard()
    private var cards: [ProjectCard] = []
    private let scanner = DevServerScanner()
    private var projects: [DevProject] = []
    private var containers: [Container] = []
    private var scannedAt = Date.distantPast
    private var idleText = ""
    var onSelect: ((Selection?) -> Void)?

    override func loadView() {
        super.loadView()
        titleLines.1.text = Toolbar.subtitle("Looking for projects…")
        for view in [memory, cpu, processes, ports, idleCard] as [NSView] { canvas.addSubview(view) }
        idleCard.warning = true
        idleCard.isHidden = true
        for tile in [memory, cpu, processes, ports] { tile.figure.show("–") }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = grid([memory, cpu, processes, ports], top: margin, width: width, columns: 4, height: 110) + gap
        if !idleCard.isHidden {
            idleCard.frame = NSRect(x: margin, y: y, width: inner, height: A2NoticeCard.height)
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

    private func cpuText(_ cores: Double, _ table: ProcessTable) -> String {
        Style.appCPU(cores, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount)
    }

    private func fill(_ table: ProcessTable) {
        let processCount = projects.reduce(0) { $0 + $1.processes.count }
        titleLines.1.text = Toolbar.subtitle(projects.isEmpty ? "Nothing running in a project folder"
                                             : "\(projects.count) running · \(processCount) processes")
        memory.show(Format.memory(projects.reduce(0) { $0 + $1.memory }))
        if let top = projects.max(by: { $0.memory < $1.memory }) {
            memory.set(facts: [.init(label: "Most in", value: top.name)])
        } else {
            memory.set(sub: "")
        }
        cpu.show(cpuText(projects.reduce(0) { $0 + $1.cpu }, table))
        cpu.set(sub: "Across every project")
        processes.figure.show("\(processCount)")
        processes.set(sub: "Servers, watchers, editors")
        let openPorts = Set(projects.flatMap { $0.servers.flatMap { $0.ports.map(\.port) } }).sorted()
        ports.figure.show("\(openPorts.count)")
        ports.set(sub: openPorts.prefix(4).map(String.init).joined(separator: " · ") + (openPorts.count > 4 ? " +\(openPorts.count - 4)" : ""))

        let idle = projects.flatMap(\.idleServers)
        idleCard.isHidden = idle.isEmpty
        if !idle.isEmpty {
            let held = idle.reduce(0) { $0 + $1.memory }
            let names = projects.filter { !$0.idleServers.isEmpty }
                .map { $0.idleServers.count > 1 ? "\($0.name) ×\($0.idleServers.count)" : $0.name }.sorted()
            let minutes = Int(DevServerScanner.idleAfter / 60)
            let title = "\(idle.count) dev \(idle.count == 1 ? "server is" : "servers are") running but idle"
            let detail = names.joined(separator: ", ") + " · holding \(Format.memory(held)) · no connections for \(minutes) minutes"
            if title + detail != idleText {
                idleText = title + detail
                idleCard.row.set(symbol: "server.rack", tint: A2.warn, title: title, detail: detail, button: "Stop All…") { [weak self] in
                    self?.stopIdle()
                }
            }
        }

        while cards.count < projects.count {
            let card = ProjectCard()
            canvas.addSubview(card)
            cards.append(card)
        }
        let peak = max(projects.map(\.memory).max() ?? 1, 1)
        for (index, card) in cards.enumerated() {
            guard index < projects.count else { card.isHidden = true; continue }
            card.isHidden = false
            fill(card, projects[index], peak: peak, table: table)
        }
        relayout()
    }

    private func fill(_ card: ProjectCard, _ project: DevProject, peak: UInt64, table: ProcessTable) {
        let header = card.header
        header.name = project.name
        header.chips.chips = project.servers.flatMap { server in Set(server.ports.map(\.port)).sorted().map { PortChips.Chip(port: $0, server: server) } }
        header.chips.onStop = { [weak self] server in self?.confirmStop([server]) }
        header.idle = project.idleServers.count
        let mine = containers.filter { container in
            if let folder = container.folder { return folder == project.path || folder.hasPrefix(project.path + "/") }
            return container.project?.lowercased() == project.name.lowercased()
        }
        var place = project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · \(project.processes.count) processes"
        if !mine.isEmpty { place += " · \(mine.count) container\(mine.count == 1 ? "" : "s")" }
        header.path = place
        header.figures = [(cpuText(project.cpu, table), "CPU"), (Format.watts(project.watts), "Power"), (Format.memory(project.memory), "Memory")]
        header.fraction = Double(project.memory) / Double(peak)
        header.needsLayout = true

        while card.serverRows.count < project.servers.count {
            let row = ServerRow()
            card.addSubview(row)
            card.serverRows.append(row)
        }
        for (index, row) in card.serverRows.enumerated() {
            guard index < project.servers.count else { row.isHidden = true; continue }
            let server = project.servers[index]
            let idle = project.idleServers.contains { $0.pid == server.pid }
            row.isHidden = false
            row.dot = server.connections > 0 ? A2Dev.live : (idle ? A2Dev.idle : A2Dev.quiet)
            row.name = server.name
            row.pid = "\(server.pid)"
            let portList = Set(server.ports.map(\.port)).sorted().map(String.init)
            row.port = (portList.count == 1 ? "Port " : "Ports ") + portList.joined(separator: ", ")
            if server.connections > 0 {
                row.status = "\(server.connections) connected"
                row.statusColor = A2.good
            } else if let seconds = server.idleSeconds, seconds >= 60 {
                row.status = "Idle " + Format.duration(seconds)
                row.statusColor = idle ? A2.warn : A2.secondary
            } else {
                row.status = "Listening"
                row.statusColor = A2.secondary
            }
            row.onClick = { [weak self] in self?.onSelect?(.process(server.pid)) }
            row.stop.onPress = { [weak self] in self?.confirmStop([server]) }
            row.needsDisplay = true
        }
        card.needsLayout = true
    }

    private func stopIdle() { confirmStop(projects.flatMap(\.idleServers)) }

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
