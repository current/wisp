import AppKit
import WispCore

/// Docker containers: memory over the last five minutes, CPU, the one closest to its
/// limit, what Docker keeps on disk, and every container with stop and restart.
/// Readings are taken only while the page is open.
@MainActor
final class ContainersPage: CardPage {
    override var pageTint: NSColor { PageID.docker.tint }
    private let tint = A2Dev.tint(.docker)
    private lazy var titleLines = heading("Containers")
    private let hero = CardView()
    private let heroLabel: A2CardLabel
    private let heroLegend = A2TitleRow()
    private let heroFigure = A2.figure()
    private let heroSub = TextLine()
    private let heroChart = A2ActivityChart()
    private let cpuTile: A2Tile
    private let limitTile: A2Tile
    private let networkTile: A2Tile
    private let portsTile: A2Tile
    private let diskCard = CardView()
    private let diskTitle = A2TitleRow()
    private let diskWaffle = Waffle()
    private let diskKeys = DiskKeys()
    private let tableCard = CardView()
    private let table = A2Table()
    private let onSelect: (Selection?) -> Void
    private let watcher = DockerWatcher()
    private var status = DockerStatus(socket: nil, containers: [])
    /// Five minutes of readings two seconds apart.
    private var memoryRing = RecentRing(capacity: 150)
    private var polledAt = Date.distantPast
    private var diskAt = Date.distantPast
    private var diskBusy = false
    private var polling = false
    private var sortColumn = 4

    /// The mockup's heights at 1240 by 780: chart, tiles, disk use, then the table.
    private static let heroHeight: CGFloat = 250
    private static let tileHeight: CGFloat = 110
    private static let diskHeight: CGFloat = 160

    /// Kept in the machine pages' shape so the window builds it the same way.
    init(title: String, metric: SystemMetric, delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        self.onSelect = onSelect
        heroLabel = A2CardLabel("Memory", symbol: PageID.memory.symbol, tint: tint)
        heroLabel.showsChevron = false
        cpuTile = A2Tile("CPU", symbol: PageID.cpu.symbol, tint: tint)
        limitTile = A2Tile("Closest to its limit", symbol: "arrow.up", tint: tint)
        networkTile = A2Tile("Network", symbol: PageID.network.symbol, tint: tint)
        portsTile = A2Tile("Published ports", symbol: "server.rack", tint: tint)
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        titleLines.1.text = Toolbar.subtitle("Looking for a container engine…")
        for view in [hero, cpuTile, limitTile, networkTile, portsTile, diskCard, tableCard] as [NSView] { canvas.addSubview(view) }
        for view in [heroLegend, heroLabel, heroFigure, heroSub, heroChart] as [NSView] { hero.addSubview(view) }
        heroLegend.items = [.init(text: "Last 5 minutes", faint: true)]
        heroFigure.format = { DashboardView.split(Format.memory($0)) }
        heroFigure.show("–")
        heroChart.firstColor = Theme.dynamic(0x30B0C7, 0x40C8E0)
        heroChart.format = { Format.memory(Double($0)) }
        limitTile.showsMeter = true
        for tile in [cpuTile, limitTile, networkTile, portsTile] { tile.figure.show("–") }

        for view in [diskTitle, diskWaffle, diskKeys] as [NSView] { diskCard.addSubview(view) }
        diskTitle.title = "Disk use"
        diskTitle.items = [.init(text: "Adding it up…")]
        diskWaffle.cell = 8
        diskWaffle.gap = 3
        diskWaffle.onHover = { [weak self] hover in self?.diskKeys.highlighted = hover?.0 }

        tableCard.addSubview(table)
        table.heading = ("Containers", "")
        table.headerHeight = 24
        table.headerRule = false
        table.rowHeight = 44
        table.iconSize = 22
        table.spacing = 10
        table.meterColors = A2Dev.meter(.docker)
        table.columns = [.init(title: "Ports", width: 62, drop: 3), .init(title: "Status", width: 92, kind: .status, drop: 4),
                         .init(title: "CPU", width: 120, kind: .meter(64)), .init(title: "Memory", width: 64, right: true),
                         .init(title: "Network", width: 70, right: true, drop: 2), .init(title: "Disk", width: 62, right: true, drop: 1),
                         .init(title: "", width: 128, kind: .buttons(["Restart", "Stop"]))]
        table.onSort = { [weak self] column in
            guard let self, column >= 3, column <= 6 else { return }
            self.sortColumn = column
            self.received(self.status, sample: false)
        }
        table.onSelect = { [weak self] id in self?.showActions(for: id) }
        table.onButton = { [weak self] id, index in
            guard let container = self?.status.containers.first(where: { $0.id == id }) else { return }
            self?.run(index == 0 ? "restart" : "stop", container)
        }
    }

    // MARK: Layout

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        hero.frame = NSRect(x: margin, y: margin, width: inner, height: Self.heroHeight)
        let heroInner = inner - A2.padSide * 2
        heroLabel.frame = NSRect(x: A2.padSide, y: A2.padTop, width: heroInner * 0.6, height: 15)
        heroLegend.frame = NSRect(x: A2.padSide, y: A2.padTop - 0.5, width: heroInner, height: 16)
        heroFigure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: heroInner)
        heroSub.frame = NSRect(x: A2.padSide, y: A2StatCard.subTop, width: heroInner, height: 14)
        // The mockup's chart is 164 pt of the 250 pt card, flush with the bottom.
        heroChart.frame = NSRect(x: 0, y: Self.heroHeight - 164, width: inner, height: 164)

        var y = grid([cpuTile, limitTile, networkTile, portsTile], top: hero.frame.maxY + gap, width: width, columns: 4,
                     height: Self.tileHeight) + gap

        diskCard.frame = NSRect(x: margin, y: y, width: inner, height: Self.diskHeight)
        diskTitle.frame = NSRect(x: A2.padSide, y: A2.padTop, width: heroInner, height: 16)
        diskWaffle.frame = NSRect(x: A2.padSide, y: A2.padTop + 16 + 12, width: heroInner, height: 5 * 8 + 4 * 3)
        diskKeys.frame = NSRect(x: A2.padSide, y: Self.diskHeight - A2.padTop - DiskKeys.height, width: heroInner, height: DiskKeys.height)
        y = diskCard.frame.maxY + gap

        // The table ends at the window's bottom margin when its rows fit, as in the mockup.
        let natural = table.naturalHeight + A2.padTop * 2
        let room = scroll.contentSize.height - Self.topInset - margin - y
        let height = room >= natural && room <= natural * 1.4 ? room : natural
        tableCard.frame = NSRect(x: margin, y: y, width: inner, height: height)
        table.frame = NSRect(x: A2.padSide, y: A2.padTop, width: heroInner, height: height - A2.padTop * 2)
        return tableCard.frame.maxY + margin
    }

    // MARK: Readings

    override func update(system: SystemSnapshot) {
        // Container stats are an HTTP round trip per container; poll every two seconds at most.
        guard Date().timeIntervalSince(polledAt) >= 1.9, !polling else { return }
        polledAt = Date()
        polling = true
        let watcher = self.watcher
        DispatchQueue.global(qos: .utility).async {
            let status = Docker.status(stats: true, watcher: watcher)
            DispatchQueue.main.async { [weak self] in
                self?.polling = false
                self?.received(status, sample: true)
            }
        }
        if Date().timeIntervalSince(diskAt) > 120, !diskBusy {
            diskBusy = true
            DispatchQueue.global(qos: .utility).async {
                let use = Docker.diskUse()
                DispatchQueue.main.async { [weak self] in
                    self?.diskBusy = false
                    self?.diskAt = Date()
                    self?.show(use)
                }
            }
        }
    }

    private func received(_ status: DockerStatus, sample: Bool) {
        self.status = status
        let running = status.containers
        let memory = running.reduce(0) { $0 + ($1.memory ?? 0) }
        if sample { memoryRing.append(Float(memory)) }
        let samples = memoryRing.values
        // Empty on the left until five minutes have been seen.
        heroChart.first = [Float](repeating: .nan, count: memoryRing.capacity - samples.count) + samples
        let peak = Double(samples.max() ?? 0)
        heroChart.ceiling = Float(ChartScale.ceiling(peak: peak, minimum: 64 * 1_048_576))

        guard let socket = status.socket else {
            titleLines.1.text = Toolbar.subtitle("No container engine running")
            heroFigure.show("None")
            heroSub.text = A2.plain("Wisp looks for Docker Desktop, OrbStack, Colima, Rancher Desktop and Lima")
            table.rows = []
            table.emptyText = "No engine running"
            relayout()
            return
        }
        let place = "\(running.count) container\(running.count == 1 ? "" : "s") in \(Docker.engineName(socket))"
        titleLines.1.text = Toolbar.subtitle(place)
        heroFigure.set(Double(memory))
        let sub = NSMutableAttributedString(attributedString: A2.plain(place + " · "))
        sub.append(A2.facts([.init(label: "Peak", value: Format.memory(UInt64(peak)))]))
        heroSub.text = sub

        let cpu = running.reduce(0) { $0 + ($1.cpu ?? 0) }
        cpuTile.figure.show(String(format: "%.1f", cpu * 100), unit: "%")
        if let busiest = running.max(by: { ($0.cpu ?? 0) < ($1.cpu ?? 0) }) {
            cpuTile.set(facts: [.init(label: "Most in", value: busiest.name)])
        } else {
            cpuTile.set(sub: "")
        }
        let limited = running.compactMap { c -> (Container, Double)? in
            guard let used = c.memory, let limit = c.memoryLimit, limit > 0, limit < 1 << 50 else { return nil }
            return (c, Double(used) / Double(limit))
        }.max { $0.1 < $1.1 }
        limitTile.showsMeter = limited != nil
        if let (container, fraction) = limited {
            limitTile.show(word: container.name)
            limitTile.meter.fraction = fraction
            limitTile.meter.color = fraction > 0.9 ? A2.bad : (fraction > 0.75 ? A2.warn : A2.good)
            limitTile.set(sub: "\(Format.percent(fraction)) of \(Format.memory(container.memoryLimit ?? 0))")
        } else {
            limitTile.figure.show("–")
            limitTile.set(sub: "No container has a memory limit")
        }
        networkTile.show(Format.rate(running.reduce(0) { $0 + ($1.networkRate ?? 0) }))
        networkTile.set(sub: "In and out")
        let ports = Set(running.flatMap { $0.ports.compactMap { $0.split(separator: ":").first.map(String.init) } })
        portsTile.figure.show("\(ports.count)")
        portsTile.set(sub: ports.sorted().prefix(5).joined(separator: " · "))

        let key: (Container) -> Double = { [sortColumn] in
            switch sortColumn {
            case 3: return $0.cpu ?? 0
            case 5: return $0.networkRate ?? 0
            case 6: return $0.diskRate ?? 0
            default: return Double($0.memory ?? 0)
            }
        }
        let sorted = running.sorted { ($0.folder ?? $0.project ?? "", -key($0)) < ($1.folder ?? $1.project ?? "", -key($1)) }
        let peakCPU = max(sorted.compactMap(\.cpu).max() ?? 0, 0.0001)
        let before = table.rows.count
        table.heading = ("Containers", running.isEmpty ? "" : "\(running.count)")
        table.emptyText = "No containers running"
        table.rows = sorted.map { c in
            A2Table.Row(id: c.id, glyph: PageID.docker.symbol, name: c.name, note: c.project ?? "",
                        cells: [c.ports.map { String($0.split(separator: ":").first ?? "") }.joined(separator: ", "),
                                c.status, c.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "–",
                                c.memory.map { Format.memory($0) } ?? "–",
                                c.networkRate.map { Format.rate($0) } ?? "–", c.diskRate.map { Format.rate($0) } ?? "–", ""],
                        fraction: (c.cpu ?? 0) / peakCPU,
                        dot: c.state == "running" ? A2Dev.live : A2Dev.quiet)
        }
        if table.rows.count != before { relayout() }
        hero.needsLayout = true
    }

    private func show(_ use: DockerDiskUse?) {
        guard let use else {
            diskTitle.items = [.init(text: "Not available")]
            return
        }
        diskTitle.items = [.init(text: "\(Format.bytes(use.total)) total · \(Format.bytes(use.reclaimable)) reclaimable")]
        let parts: [(String, DockerDiskUse.Part, NSColor)] = [
            ("Images", use.images, Theme.dynamic(0x30B0C7, 0x40C8E0)), ("Containers", use.containers, A2.cpu),
            ("Volumes", use.volumes, A2.memoryApp), ("Build cache", use.buildCache, A2.power),
        ]
        diskWaffle.parts = parts.map { .init(name: $0.0, value: Double($0.1.size), color: $0.2) }
        diskKeys.keys = parts.map { name, part, color in
            let use = part.inUse == 0 ? "none in use" : "\(part.inUse) of \(part.count) in use"
            return DiskKeys.Key(label: name, value: Format.bytes(part.size), note: use, color: color)
        }
    }

    // MARK: Actions

    private func showActions(for id: String) {
        guard let container = status.containers.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        for port in container.ports.compactMap({ $0.split(separator: ":").first }) {
            menu.addItem(ActionItem("Open http://localhost:\(port)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionItem("Restart \(container.name)") { [weak self] in self?.run("restart", container) })
        menu.addItem(ActionItem("Stop \(container.name)") { [weak self] in self?.run("stop", container) })
        let point = table.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: point, in: table)
    }

    private func run(_ action: String, _ container: Container) {
        DispatchQueue.global(qos: .userInitiated).async {
            let done = Docker.perform(action, container: container.id)
            DispatchQueue.main.async { [weak self] in
                if !done { NSSound.beep() }
                self?.polledAt = .distantPast
            }
        }
    }
}

/// The key under the disk waffle: a colour square and label, then the size in bold
/// and how many are in use, in four equal columns.
final class DiskKeys: BitmapView {
    struct Key: Equatable {
        var label: String
        var value: String
        var note: String
        var color: NSColor
    }

    var keys: [Key] = [] { didSet { if keys != oldValue { needsDisplay = true } } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    static let height: CGFloat = 32

    private static let labelFont = Theme.sans(10.5)
    private static let valueFont = Theme.digits(12.5, .semibold)
    private static let noteFont = Theme.sans(11)

    override func draw(_ dirtyRect: NSRect) {
        guard !keys.isEmpty else { return }
        let column = (bounds.width - 8 * CGFloat(keys.count - 1)) / CGFloat(keys.count)
        for (index, key) in keys.enumerated() {
            let x = CGFloat(index) * (column + 8)
            let faded = highlighted != nil && highlighted != index
            (faded ? key.color.withAlphaComponent(0.3) : key.color).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 4, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
            A2Dev.text(key.label, x: x + 13, mid: 7.5, width: column - 13, font: Self.labelFont, color: A2.secondary)
            let used = A2Dev.text(key.value, x: x + 13, mid: 24, width: column - 13, font: Self.valueFont, color: A2.primary)
            A2Dev.text(key.note, x: x + 13 + used + 6, mid: 24.5, width: column - 19 - used, font: Self.noteFont, color: A2.tertiary)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { keys.map { "\($0.label) \($0.value), \($0.note)" }.joined(separator: "; ") }
}
