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
    private let heroPill = Pill()
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
    private let diskKeys = SplitKeys()
    private let diskHint = TextLine()
    private let tips = TableTips()
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
        for view in [heroLegend, heroLabel, heroPill, heroFigure, heroSub, heroChart] as [NSView] { hero.addSubview(view) }
        heroPill.isHidden = true
        heroLegend.items = [.init(text: "Since this page opened", faint: true)]
        heroFigure.format = { DashboardView.split(Format.memory($0)) }
        heroFigure.show("–")
        heroChart.firstColor = Theme.dynamic(0x30B0C7, 0x40C8E0)
        heroChart.format = { Format.memory(Double($0)) }
        heroChart.title = "Container memory"
        diskWaffle.title = "Disk use"
        limitTile.showsMeter = true
        for tile in [cpuTile, limitTile, networkTile, portsTile] {
            tile.figure.show("–")
            tile.set(sub: "Reading…")
        }

        for view in [diskTitle, diskWaffle, diskKeys, diskHint] as [NSView] { diskCard.addSubview(view) }
        diskTitle.title = "Disk use"
        diskTitle.items = [.init(text: "Docker is adding it up, which can take a minute", faint: true)]
        diskWaffle.cell = 8
        diskWaffle.gap = 3
        diskWaffle.alphaValue = 0.6
        diskWaffle.onHover = { [weak self] hover in self?.diskKeys.highlighted = hover?.0 }
        diskKeys.ghost = 4
        diskKeys.onHover = { [weak self] index in self?.diskWaffle.highlighted = index }
        diskHint.isHidden = true

        tableCard.addSubview(table)
        table.heading = ("Containers", "")
        table.headerHeight = 24
        table.headerRule = false
        table.rowHeight = 44
        table.iconSize = 22
        table.spacing = 10
        table.meterColors = A2Dev.meter(.docker)
        // Memory carries the bar: it is what the hero charts and what a limit stops.
        table.columns = [.init(title: "Ports", width: 62, drop: 3), .init(title: "Status", width: 104, kind: .status, drop: 4),
                         .init(title: "CPU", width: 54, right: true), .init(title: "Memory", width: 136, kind: .meter(64), right: true),
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
        let labelWidth = 20 + A2Dev.width("Memory", A2.labelFont)
        heroLabel.frame = NSRect(x: A2.padSide, y: A2.padTop, width: labelWidth + 4, height: 15)
        heroPill.frame = NSRect(x: A2.padSide + labelWidth + 10, y: 12.5, width: heroPill.naturalWidth, height: 18)
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
        diskKeys.maxColumns = 4
        let keysHeight = diskKeys.naturalHeight(width: heroInner)
        diskCard.frame.size.height = A2.padTop + 16 + 12 + diskWaffle.frame.height + 16 + max(keysHeight, SplitKeys.keyHeight) + 16
        diskKeys.frame = NSRect(x: A2.padSide, y: diskWaffle.frame.maxY + 16, width: heroInner, height: keysHeight)
        diskHint.frame = NSRect(x: A2.padSide, y: diskWaffle.frame.maxY + 16, width: heroInner, height: 32)
        y = diskCard.frame.maxY + gap

        // The table ends at the window's bottom margin when its rows fit, as in the mockup.
        let natural = table.naturalHeight + A2.padTop * 2
        let room = scroll.contentSize.height - Self.topInset - margin - y
        let height = room >= natural && room <= natural * 1.4 ? room : natural
        tableCard.frame = NSRect(x: margin, y: y, width: inner, height: height)
        table.frame = NSRect(x: A2.padSide, y: A2.padTop, width: heroInner, height: height - A2.padTop * 2)
        installTips()
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
        // The engine adds up its disk use on request, which can take seconds of its CPU.
        if Date().timeIntervalSince(diskAt) > 600, !diskBusy {
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
        // A reading with no engine behind it is not a measurement of zero; kept, it would
        // draw a climb from nothing at the chart's left edge.
        if sample, status.socket != nil { memoryRing.append(Float(memory)) }
        let samples = memoryRing.values
        // The readings so far span the whole chart, so it has a shape from the first seconds
        // rather than a sliver at the right edge; the legend says how far back it reaches.
        heroChart.first = samples.count == 1 ? [samples[0], samples[0]] : samples
        let seconds = Double(max(0, samples.count - 1)) * 2
        heroLegend.items = [.init(text: seconds >= 290 ? "Last 5 minutes"
                                  : seconds < 60 ? "Last \(Int(seconds)) seconds, since this page opened"
                                  : "Last \(Int(seconds / 60)) min, since this page opened", faint: true)]
        let peak = Double(samples.max() ?? 0)
        heroChart.ceiling = Float(ChartScale.ceiling(peak: peak, minimum: 64 * 1_048_576))

        guard let socket = status.socket else {
            titleLines.1.text = Toolbar.subtitle("No container engine running")
            heroFigure.show("None")
            heroSub.text = A2.plain("Wisp looks for Docker Desktop, OrbStack, Colima, Rancher Desktop and Lima")
            heroPill.isHidden = true
            for tile in [cpuTile, limitTile, networkTile, portsTile] {
                tile.figure.show("–")
                tile.set(sub: "No engine running")
                tile.showsMeter = false
            }
            table.rows = []
            table.emptyText = "Start Docker Desktop, OrbStack or Colima and its containers show here"
            showDiskHint("No container engine is running", "When one starts, Wisp adds up what it keeps on disk.")
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
            cpuTile.set(facts: [.init(label: "Most in", value: Self.shortName(busiest))])
            cpuTile.toolTip = "Most in \(busiest.name)"
        } else {
            cpuTile.set(sub: "")
        }
        let limited = running.compactMap { c -> (Container, Double)? in
            guard let used = c.memory, let limit = c.memoryLimit, limit > 0, limit < 1 << 50 else { return nil }
            return (c, Double(used) / Double(limit))
        }.max { $0.1 < $1.1 }
        // The share is the figure and the name goes under it, where a long compose name
        // can end in an ellipsis without hiding the number; the whole of it is on hover.
        limitTile.showsMeter = limited != nil
        if let (container, fraction) = limited {
            limitTile.figure.show(String(format: fraction < 0.1 ? "%.1f" : "%.0f", fraction * 100),
                                  unit: "% of \(Format.memory(container.memoryLimit ?? 0))")
            limitTile.meter.fraction = fraction
            limitTile.meter.color = fraction > 0.9 ? A2.bad : (fraction > 0.75 ? A2.warn : A2.good)
            limitTile.meter.state = fraction > 0.9 ? "Near its limit" : (fraction > 0.75 ? "Getting close" : "")
            limitTile.set(facts: [.init(label: "", value: Self.shortName(container))])
            limitTile.toolTip = "\(container.name): \(Format.memory(container.memory ?? 0)) of its \(Format.memory(container.memoryLimit ?? 0)) limit"
        } else {
            limitTile.figure.show("–")
            limitTile.set(sub: "No container has a memory limit")
            limitTile.toolTip = nil
        }
        let unhealthy = running.filter { Self.health($0.status) == .unhealthy }.count
        if unhealthy > 0 {
            setPill("\(unhealthy) unhealthy", tone: .bad)
        } else if let (_, fraction) = limited, fraction > 0.9 {
            setPill("Near a limit", tone: .warn)
        } else if !running.isEmpty {
            setPill(running.allSatisfy { $0.state == "running" } ? "All running" : nil, tone: .good)
        } else {
            setPill(nil, tone: .good)
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
        let peakMemory = Double(max(sorted.compactMap(\.memory).max() ?? 0, 1))
        let before = table.rows.count
        table.heading = ("Containers", running.isEmpty ? "" : "\(running.count)")
        table.emptyText = "No containers running. Start one with docker compose up and it shows here."
        table.rows = sorted.map { c in
            let health = Self.health(c.status)
            let dot: NSColor = c.state != "running" ? A2Dev.quiet : health == .starting ? A2Dev.idle : A2Dev.live
            return A2Table.Row(id: c.id, glyph: PageID.docker.symbol, name: c.name, note: c.project ?? "",
                               cells: [c.ports.map { String($0.split(separator: ":").first ?? "") }.joined(separator: ", "),
                                       Self.shortStatus(c.status), c.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "–",
                                       c.memory.map { Format.memory($0) } ?? "–",
                                       c.networkRate.map { Format.rate($0) } ?? "–", c.diskRate.map { Format.rate($0) } ?? "–", ""],
                               fraction: Double(c.memory ?? 0) / peakMemory, dot: dot,
                               tag: health == .unhealthy ? "Unhealthy" : nil)
        }
        tipTexts = sorted.map { c in
            var lines = [c.name + (c.project.map { " · \($0)" } ?? ""), c.status, c.image]
            if let limit = c.memoryLimit, limit > 0, limit < 1 << 50, let used = c.memory {
                lines.append("\(Format.memory(used)) of its \(Format.memory(limit)) memory limit")
            }
            if !c.ports.isEmpty { lines.append("Ports " + c.ports.joined(separator: ", ")) }
            return lines.joined(separator: "\n")
        }
        installTips()
        if table.rows.count != before { relayout() }
        hero.needsLayout = true
    }

    private var tipTexts: [String] = []

    private func installTips() {
        tips.install(on: table, texts: table.rows.isEmpty ? [] : tipTexts)
    }

    private func setPill(_ text: String?, tone: Pill.Tone) {
        heroPill.isHidden = text == nil
        guard let text, text != heroPill.text || tone != heroPill.tone else { return }
        heroPill.text = text
        heroPill.tone = tone
        hero.needsLayout = true
    }

    /// "supabase_analytics_cusplight" as "supabase_analytics": compose repeats the project
    /// in every name, and the tiles have room for the part that tells them apart.
    static func shortName(_ container: Container) -> String {
        guard let project = container.project, !project.isEmpty else { return container.name }
        for joint in ["_", "-"] where container.name.hasSuffix(joint + project) {
            return String(container.name.dropLast(project.count + 1))
        }
        return container.name
    }

    enum Health { case none, healthy, starting, unhealthy }

    /// Docker writes the health check into the status: "Up 2 days (healthy)".
    static func health(_ status: String) -> Health {
        if status.contains("(unhealthy)") { return .unhealthy }
        if status.contains("(health: starting)") { return .starting }
        if status.contains("(healthy)") { return .healthy }
        return .none
    }

    /// "Up 2 days (healthy)" as "Up 2 days": the health is in the dot or the tag, and the
    /// whole status is on hover.
    static func shortStatus(_ status: String) -> String {
        guard let open = status.firstIndex(of: "("), let close = status[open...].firstIndex(of: ")") else { return status }
        let rest = (status[..<open] + status[status.index(after: close)...]).split(separator: " ")
        return rest.joined(separator: " ")
    }

    private func showDiskHint(_ title: String, _ detail: String) {
        diskTitle.items = [.init(text: title, faint: true)]
        diskWaffle.parts = []
        diskKeys.keys = []
        diskKeys.ghost = 0
        diskKeys.isHidden = true
        diskHint.isHidden = false
        diskHint.text = A2.plain(detail)
        relayout()
    }

    private func show(_ use: DockerDiskUse?) {
        guard let use else {
            showDiskHint("Docker did not say", "Wisp asks again in 10 minutes, or when the page opens next.")
            return
        }
        diskWaffle.alphaValue = 1
        diskKeys.isHidden = false
        diskHint.isHidden = true
        diskTitle.items = [.init(text: "\(Format.bytes(use.total)) total"), .init(text: "\(Format.bytes(use.reclaimable)) reclaimable", faint: true)]
        let parts: [(String, DockerDiskUse.Part, NSColor)] = [
            ("Images", use.images, Theme.dynamic(0x30B0C7, 0x40C8E0)), ("Containers", use.containers, A2.cpu),
            ("Volumes", use.volumes, A2.memoryApp), ("Build cache", use.buildCache, A2.cpuLight),
        ]
        diskWaffle.parts = parts.map { .init(name: $0.0, value: Double($0.1.size), color: $0.2) }
        diskKeys.keys = parts.map { name, part, color in
            let use = part.inUse == 0 ? "none in use" : "\(part.inUse) of \(part.count) in use"
            return SplitKeys.Key(label: name, value: Format.bytes(part.size), note: use, color: color)
        }
        // The key's height was set while it held placeholders or a hint; place it again for the real one.
        relayout()
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
