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
        showMenu(index)
    }

    fileprivate func showMenu(_ index: Int) {
        guard chips.indices.contains(index) else { return }
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

    // Each chip is its own button so VoiceOver can open its menu, and says in words
    // what the amber colour shows.
    private final class ChipElement: NSAccessibilityElement {
        weak var owner: PortChips?
        var index = 0
        override func accessibilityPerformPress() -> Bool {
            owner?.showMenu(index)
            return owner != nil
        }
        override func accessibilityFrameInParentSpace() -> NSRect {
            guard let owner, owner.chips.indices.contains(index) else { return .zero }
            let rect = owner.frames()[index]
            return NSRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    override func isAccessibilityElement() -> Bool { !chips.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Ports" }
    private var elementCache: [ChipElement] = []

    override func accessibilityChildren() -> [Any]? {
        let shown = zip(chips, frames()).enumerated().filter { $0.element.1.maxX <= bounds.width }
        // Kept between calls so VoiceOver keeps its place while the chips redraw.
        while elementCache.count < shown.count {
            let element = ChipElement()
            element.owner = self
            elementCache.append(element)
        }
        return shown.map { index, pair in
            let element = elementCache[index]
            element.index = index
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Port \(pair.0.port)")
            element.setAccessibilityValue(Self.idle(pair.0.server) ? "Idle, nothing connected" : nil)
            element.setAccessibilityHelp("Open, copy the address or stop \(pair.0.server.name)")
            element.setAccessibilityParent(self)
            return element
        }
    }
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

/// Where the figures sit in a server row of the given width, measured from the right
/// edge. The project's header sits 44 pt further left and adds that to each, so a
/// project's totals line up with its servers' figures and with the cards around it.
enum ProjectColumns {
    static let stop: CGFloat = 58
    static let figure: CGFloat = 62
    static let cpu: CGFloat = 60
    static let status: CGFloat = 108
    static let ports: CGFloat = 120

    /// A narrow window gets a shorter bar, then lets the ports go (the chips in the
    /// project's header still list them).
    static func bar(_ width: CGFloat) -> CGFloat { width < 760 ? 56 : 96 }
    static func showsPorts(_ width: CGFloat) -> Bool { statusX(width) - 14 - ports >= 190 }

    /// The memory figure's right edge.
    static func memoryRight(_ width: CGFloat) -> CGFloat { width - stop - 16 }
    static func barX(_ width: CGFloat) -> CGFloat { memoryRight(width) - figure - 10 - bar(width) }
    static func cpuX(_ width: CGFloat) -> CGFloat { barX(width) - 20 - cpu }
    static func statusX(_ width: CGFloat) -> CGFloat { cpuX(width) - 18 - status }
    static func portsX(_ width: CGFloat) -> CGFloat { showsPorts(width) ? statusX(width) - 14 - ports : statusX(width) }
}

/// A project's first lines: a folder in the project's colour from the split above, the
/// name, port chips and idle count, the folder and process count under them, and its
/// CPU and memory in the same columns as its servers' rows. The chips are a subview so
/// they can take clicks.
final class ProjectHeader: BitmapView {
    let chips = PortChips()
    var name = "" { didSet { if name != oldValue { needsLayout = true; needsDisplay = true } } }
    var idle = 0 { didSet { if idle != oldValue { needsDisplay = true } } }
    var path = "" { didSet { if path != oldValue { needsDisplay = true; toolTip = path } } }
    var cpu = "" { didSet { if cpu != oldValue { needsDisplay = true } } }
    var memory = "" { didSet { if memory != oldValue { needsDisplay = true } } }
    var share = "" { didSet { if share != oldValue { needsDisplay = true } } }
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = A2.cpu { didSet { needsDisplay = true } }

    private static let nameFont = Theme.sans(14, .semibold)
    private static let figureFont = Theme.digits(13, .semibold)
    private static let labelFont = Theme.sans(11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(chips)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The width of the server rows under this header, whose columns it shares.
    private var rowWidth: CGFloat { bounds.width - 44 }
    private var textRight: CGFloat { 44 + ProjectColumns.statusX(rowWidth) + ProjectColumns.status - 20 }

    override func layout() {
        super.layout()
        let nameRight = min(44 + A2Dev.width(name, Self.nameFont), textRight - 60)
        let room = max(0, textRight - nameRight - 10 - (idle > 0 ? 60 : 0))
        chips.frame = NSRect(x: nameRight + 10, y: 0, width: min(chips.naturalWidth, room), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fold = NSRect(x: 0, y: (bounds.height - 32) / 2, width: 32, height: 32)
        color.withAlphaComponent(A2.drawingDark ? 0.2 : 0.13).setFill()
        NSBezierPath(roundedRect: fold, xRadius: 9, yRadius: 9).fill()
        IconTile.glyph("folder.fill", tint: color, size: 16, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 8, y: fold.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: nil)

        let used = A2Dev.measuredText(name, x: 44, mid: 10, width: textRight - 104, font: Self.nameFont, color: A2.primary)
        if idle > 0 {
            let x = chips.naturalWidth > 0 ? chips.frame.maxX + 8 : 44 + used + 10
            _ = A2Dev.drawTag("\(idle) idle", x: x, mid: 10, font: Theme.sans(11, .semibold))
        }
        A2Dev.text(path, x: 44, mid: 30.5, width: textRight - 44, font: A2Dev.detailFont, color: A2.tertiary)

        let width = rowWidth
        let cpuX = 44 + ProjectColumns.cpuX(width), barX = 44 + ProjectColumns.barX(width), right = 44 + ProjectColumns.memoryRight(width)
        A2Dev.text(cpu, x: cpuX, mid: 10, width: ProjectColumns.cpu, font: Self.figureFont, color: A2.primary, right: true)
        A2Dev.text("CPU", x: cpuX, mid: 30.5, width: ProjectColumns.cpu, font: Self.labelFont, color: A2.tertiary, right: true)
        A2Dev.drawMeter(NSRect(x: barX, y: 7.5, width: ProjectColumns.bar(width), height: 5), fraction: fraction, colors: (color, color))
        A2Dev.text(memory, x: right - ProjectColumns.figure, mid: 10, width: ProjectColumns.figure, font: Self.figureFont,
                   color: A2.primary, right: true)
        A2Dev.text(share, x: barX, mid: 30.5, width: right - barX, font: Self.labelFont, color: A2.tertiary, right: true)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? {
        [idle > 0 ? "\(idle) idle" : "", path, "CPU \(cpu)", "Memory \(memory)", share].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A dev server under its project: a status dot, the name and pid, its ports, how it is
/// doing, its CPU, a bar for its share of the project's memory with the figure, and a
/// Stop button. A hairline above each row; the whole command on hover.
final class ServerRow: BitmapView {
    let stop = A2PillButton()
    var dot: NSColor = A2Dev.quiet
    var name = ""
    var pid = ""
    var port = ""
    var status = ""
    var statusColor: NSColor = A2.secondary
    var cpu = ""
    var memory = ""
    var fraction: Double = 0
    var color: NSColor = A2.cpu
    var onClick: (() -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

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
        let width = bounds.width
        if hovering {
            A2.rowHover.setFill()
            NSBezierPath(roundedRect: NSRect(x: -8, y: 1, width: ProjectColumns.memoryRight(width) + 14, height: bounds.height - 2),
                         xRadius: 7, yRadius: 7).fill()
        } else {
            A2.hairline.setFill()
            NSRect(x: 0, y: 0, width: width, height: 0.5).fill()
        }
        let mid = bounds.height / 2
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: mid - 3.5, width: 7, height: 7)).fill()
        let portX = ProjectColumns.portsX(width)
        let used = A2Dev.measuredText(name, x: 17, mid: mid, width: portX - 27, font: A2Dev.nameFont, color: A2.primary)
        A2Dev.text(pid, x: 17 + used + 6, mid: mid + 1, width: portX - 33 - used, font: A2Dev.noteFont, color: A2.tertiary)
        if ProjectColumns.showsPorts(width) {
            A2Dev.text(port, x: portX, mid: mid, width: ProjectColumns.ports, font: Theme.digits(12, .regular), color: A2.secondary)
        }
        A2Dev.text(status, x: ProjectColumns.statusX(width), mid: mid, width: ProjectColumns.status, font: Theme.digits(12, .medium),
                   color: statusColor)
        A2Dev.text(cpu, x: ProjectColumns.cpuX(width), mid: mid, width: ProjectColumns.cpu, font: A2Dev.cellFont, color: A2.secondary,
                   right: true)
        A2Dev.drawMeter(NSRect(x: ProjectColumns.barX(width), y: mid - 2.5, width: ProjectColumns.bar(width), height: 5), fraction: fraction,
                        colors: (color.withAlphaComponent(0.75), color.withAlphaComponent(0.75)))
        let right = ProjectColumns.memoryRight(width)
        A2Dev.text(memory, x: right - ProjectColumns.figure, mid: mid, width: ProjectColumns.figure, font: A2Dev.cellBold,
                   color: A2.primary, right: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "\(name) \(pid)" }
    override func accessibilityValue() -> Any? { "\(port), \(status), CPU \(cpu), memory \(memory)" }
}

/// One project: its header, then a row per dev server.
final class ProjectCard: CardView {
    let header = ProjectHeader()
    var serverRows: [ServerRow] = []
    static let pitch: CGFloat = 32

    override init() {
        super.init()
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func height(servers: Int) -> CGFloat { servers == 0 ? 72 : A2.padTop + 50 + CGFloat(servers) * pitch + 10 }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        let shown = serverRows.filter { !$0.isHidden }
        header.frame = NSRect(x: A2.padSide, y: shown.isEmpty ? (bounds.height - 40) / 2 : A2.padTop, width: inner, height: 40)
        for (index, row) in shown.enumerated() {
            row.frame = NSRect(x: A2.padSide + 44, y: A2.padTop + 50 + CGFloat(index) * Self.pitch, width: inner - 44, height: Self.pitch)
        }
    }
}

/// A project card's shape in grey, while the first look at the project folders runs.
final class GhostProjectCard: CardView {
    let rows = ProjectGhostRows()

    override init() {
        super.init()
        rows.iconSize = 32
        rows.rowHeight = 40
        rows.count = 3
        addSubview(rows)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        rows.frame = NSRect(x: A2.padSide, y: A2.padTop - 2, width: bounds.width - A2.padSide * 2, height: bounds.height - A2.padTop)
    }
}

/// Projects with something running: dev servers and their ports, everything
/// else started in the folder, and the Docker containers of the same name.
@MainActor
final class ProjectsPage: CardPage {
    override var pageTint: NSColor { PageID.ports.tint }
    private lazy var titleLines = heading("Projects")
    private let hero = SplitHero("Memory", symbol: PageID.memory.symbol, page: .ports)
    private let cpu = A2Tile("CPU", symbol: PageID.cpu.symbol, tint: A2Dev.tint(.ports))
    private let power = A2Tile("Power", symbol: "bolt", tint: A2Dev.tint(.ports))
    private let ports = A2Tile("Open ports", symbol: "server.rack", tint: A2Dev.tint(.ports))
    private let connections = A2Tile("Connections", symbol: "point.3.connected.trianglepath.dotted", tint: A2Dev.tint(.ports))
    private let idleCard = A2NoticeCard()
    private let ghosts = [GhostProjectCard(), GhostProjectCard()]
    private var cards: [ProjectCard] = []
    private var projects: [DevProject] = []
    private var containers: [Container] = []
    private var scannedAt = Date.distantPast
    private var scanning = false
    private var scanned = false
    private var idleText = ""
    var onSelect: ((Selection?) -> Void)?

    private var tiles: [A2Tile] { [cpu, power, ports, connections] }

    override func loadView() {
        super.loadView()
        titleLines.1.text = Toolbar.subtitle("Looking for projects…")
        for view in [hero, cpu, power, ports, connections, idleCard] + ghosts as [NSView] { canvas.addSubview(view) }
        idleCard.warning = true
        idleCard.isHidden = true
        hero.measure = "Memory"
        hero.legend.items = [.init(text: "By project", faint: true)]
        hero.showGhost("Looking at what runs in your project folders…")
        for tile in tiles {
            tile.figure.show("–")
            tile.set(sub: "Reading…")
        }
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: hero.height(width: inner))
        var y = grid(tiles, top: hero.frame.maxY + gap, width: width, columns: 4, height: 110) + gap
        if !idleCard.isHidden {
            idleCard.frame = NSRect(x: margin, y: y, width: inner, height: A2NoticeCard.height)
            y = idleCard.frame.maxY + gap
        }
        for ghost in ghosts where !ghost.isHidden {
            ghost.frame = NSRect(x: margin, y: y, width: inner, height: 140)
            y = ghost.frame.maxY + gap
        }
        for (index, card) in cards.enumerated() where index < projects.count {
            let height = ProjectCard.height(servers: projects[index].servers.count)
            card.frame = NSRect(x: margin, y: y, width: inner, height: height)
            y = card.frame.maxY + gap
        }
        return y + margin - gap
    }

    override func update(table: ProcessTable) {
        // Walking every process's sockets and folder costs a few milliseconds, and Docker
        // can take a second to answer: every few seconds, off the main thread.
        // The first table can arrive before any process is listed; it would read as no projects.
        guard !table.processes.isEmpty, Date().timeIntervalSince(scannedAt) > 4, !scanning else { return }
        scannedAt = Date()
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let projects = DevServerScanner.shared.scan(table).filter { !$0.path.isEmpty }
                .sorted { a, b in
                    if a.servers.isEmpty != b.servers.isEmpty { return !a.servers.isEmpty }
                    return a.memory > b.memory
                }
            let containers = Docker.status(stats: false).containers
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                self.scanned = true
                self.projects = projects
                self.containers = containers
                self.fill(table)
            }
        }
    }

    private func cpuText(_ cores: Double, _ table: ProcessTable) -> String {
        Style.appCPU(cores, machine: delegate.settings.cpuOfMachine, coreCount: table.coreCount)
    }

    /// Each project's colour in the split, by its rank in memory; past the fifth they share the grey.
    private var colors: [String: NSColor] = [:]

    private func fill(_ table: ProcessTable) {
        let processCount = projects.reduce(0) { $0 + $1.processes.count }
        titleLines.1.text = Toolbar.subtitle(projects.isEmpty ? "Nothing running in a project folder"
                                             : "\(projects.count) running · \(processCount) processes")
        for ghost in ghosts { ghost.isHidden = true }
        let total = projects.reduce(0) { $0 + $1.memory }
        let idle = projects.flatMap(\.idleServers)
        let connected = projects.reduce(0) { $0 + $1.servers.reduce(0) { $0 + $1.connections } }
        fillHero(table, total: total, idle: idle.count, connected: connected)

        let busiest = projects.max(by: { $0.cpu < $1.cpu })
        cpu.show(cpuText(projects.reduce(0) { $0 + $1.cpu }, table))
        if let busiest, busiest.cpu > 0.001 {
            cpu.set(facts: [.init(label: "Most in", value: busiest.name)])
            cpu.toolTip = "Most in \(busiest.name), \(cpuText(busiest.cpu, table))"
        } else {
            cpu.set(sub: projects.isEmpty ? "No projects running" : "Idle")
            cpu.toolTip = nil
        }
        power.show(Format.watts(projects.reduce(0) { $0 + $1.watts }))
        power.set(sub: "Between them")
        let openPorts = Set(projects.flatMap { $0.servers.flatMap { $0.ports.map(\.port) } }).sorted()
        ports.figure.show("\(openPorts.count)")
        ports.set(sub: openPorts.isEmpty ? "None listening"
                  : openPorts.prefix(4).map(String.init).joined(separator: " · ") + (openPorts.count > 4 ? " +\(openPorts.count - 4)" : ""))
        ports.toolTip = openPorts.isEmpty ? nil : openPorts.map(String.init).joined(separator: ", ")
        let servers = projects.reduce(0) { $0 + $1.servers.count }
        connections.figure.show("\(connected)")
        let serving = projects.flatMap(\.servers).filter { $0.connections > 0 }.count
        connections.set(sub: servers == 0 ? "No dev servers" : "To \(serving) of \(servers) servers")

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
        for (index, card) in cards.enumerated() {
            guard index < projects.count else { card.isHidden = true; continue }
            card.isHidden = false
            fill(card, projects[index], total: total, table: table)
        }
        relayout()
    }

    private func fillHero(_ table: ProcessTable, total: UInt64, idle: Int, connected: Int) {
        guard !projects.isEmpty else {
            colors = [:]
            hero.figure.show("None")
            hero.caption.text = A2.plain("Nothing is running in a project folder")
            hero.showEmpty("Start a dev server, a watcher or an editor in a folder under your home and it shows here, with its ports.")
            hero.setPill(nil)
            return
        }
        let (number, unit) = DashboardView.split(Format.memory(total))
        hero.figure.show(number, unit: unit)
        let processCount = projects.reduce(0) { $0 + $1.processes.count }
        hero.caption.text = A2.plain("Held by \(projects.count) project\(projects.count == 1 ? "" : "s") and their \(processCount) processes")
        if idle > 0 {
            hero.setPill("\(idle) idle", tone: .warn)
        } else if connected > 0 {
            hero.setPill("Serving", tone: .good)
        } else {
            hero.setPill(nil)
        }
        let ranked = projects.sorted { $0.memory > $1.memory }
        let home = NSHomeDirectory()
        hero.show(ranked.map { project in
            SplitHero.Slice(label: project.name, value: Double(project.memory), shown: Format.memory(project.memory),
                            note: cpuText(project.cpu, table) + " CPU",
                            detail: project.path.replacingOccurrences(of: home, with: "~"))
        }) { value, folded in
            SplitHero.Slice(label: "\(folded.count) more", value: value, shown: Format.memory(UInt64(value)),
                            note: folded.prefix(2).map(\.label).joined(separator: ", ") + (folded.count > 2 ? "…" : ""),
                            detail: folded.map(\.label).joined(separator: ", "))
        }
        colors = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.path, hero.color($0.offset, of: ranked.count)) })
    }

    private func fill(_ card: ProjectCard, _ project: DevProject, total: UInt64, table: ProcessTable) {
        let header = card.header
        let color = colors[project.path] ?? DevParts.rest
        header.name = project.name
        header.color = color
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
        header.cpu = cpuText(project.cpu, table)
        header.memory = Format.memory(project.memory)
        let fraction = total > 0 ? Double(project.memory) / Double(total) : 0
        header.fraction = fraction
        header.share = "Memory · \(Format.percent(fraction)) of all"
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
            row.cpu = cpuText(server.cpu, table)
            row.memory = Format.memory(server.memory)
            row.fraction = project.memory > 0 ? Double(server.memory) / Double(project.memory) : 0
            row.color = color
            var tip = server.command.isEmpty ? server.name : server.command
            tip += "\nPid \(server.pid) · " + row.port
            if let started = server.startDate { tip += " · started " + Format.duration(Date().timeIntervalSince(started)) + " ago" }
            row.toolTip = tip
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
