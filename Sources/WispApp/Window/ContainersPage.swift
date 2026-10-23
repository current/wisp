import AppKit
import WispCore

/// Docker containers: memory over time, CPU, the one closest to its limit,
/// what Docker keeps on disk, and every container with stop and restart.
@MainActor
final class ContainersPage: MachinePage {
    private let cpuTile = Tile("CPU"), limitTile = Tile("Closest to its limit"), networkTile = Tile("Network"), portsTile = Tile("Published ports")
    private let diskCard = CardView()
    private let diskTitle = TextLine()
    private let diskTotal = TextLine()
    private let diskWaffle = Waffle()
    private let diskLegend = LegendStrip()
    private let watcher = DockerWatcher()
    private var status = DockerStatus(socket: nil, containers: [])
    private var memoryRing = RecentRing(capacity: HistoryStore.recentSamples)
    private var cpuRing = RecentRing(capacity: HistoryStore.recentSamples)
    private var polledAt = Date.distantPast
    private var diskAt = Date.distantPast
    private var diskBusy = false
    private var polling = false

    override func setUp() {
        hero.range.items = ["Live"]
        hero.chart.format = { Format.memory(Double($0)) }
        hero.chart.names = ("Memory", "")
        hero.figure.format = { DashboardView.split(Format.memory($0)) }
        limitTile.showsMeter = true
        tiles = [cpuTile, limitTile, networkTile, portsTile]
        for view in [diskTitle, diskTotal, diskWaffle, diskLegend] as [NSView] { diskCard.addSubview(view) }
        diskTitle.text = DashboardView.titleText("Disk use", "")
        diskTotal.text = Theme.caption("Adding it up…")
        diskWaffle.cell = 8
        diskWaffle.gap = 3
        diskWaffle.onHover = { [weak self] hover in self?.diskLegend.highlighted = hover?.0 }
        diskLegend.onHover = { [weak self] index in self?.diskWaffle.highlighted = index }
        extras = [(diskCard, 176)]
        table.columns = [.init(title: "Container", width: 0), .init(title: "Ports", width: 110, right: false),
                         .init(title: "Status", width: 150, right: false), .init(title: "CPU", width: 120, bar: true),
                         .init(title: "Memory", width: 80), .init(title: "Network", width: 80), .init(title: "Disk", width: 80)]
        table.sortColumn = 4
        table.onSelect = { [weak self] id in self?.showActions(for: id) }
        tableTitle.text = DashboardView.titleText("Containers", "")
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let bottom = super.arrange(width: width)
        let inner = diskCard.bounds.width - 40
        diskTitle.frame = NSRect(x: 20, y: 16, width: 160, height: 20)
        diskTotal.frame = NSRect(x: 20 + inner - 320, y: 18, width: 320, height: 14)
        diskTotal.alignment = .right
        diskWaffle.frame = NSRect(x: 20, y: 48, width: inner, height: 5 * 11 - 3)
        diskLegend.frame = NSRect(x: 20, y: 122, width: inner, height: 36)
        return bottom
    }

    // The machine chart and app table are replaced by container data.
    override func refreshChart(force: Bool) {
        hero.chart.step = 2
        hero.chart.primary = memoryRing.values
    }

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
                self?.received(status)
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

    override func update(table: ProcessTable) {}

    private func received(_ status: DockerStatus) {
        self.status = status
        let running = status.containers
        let memory = running.reduce(0) { $0 + ($1.memory ?? 0) }
        let cpu = running.reduce(0) { $0 + ($1.cpu ?? 0) }
        memoryRing.append(Float(memory))
        cpuRing.append(Float(cpu))
        refreshChart(force: false)

        guard let socket = status.socket else {
            hero.figure.show("No engine")
            hero.meta.text = Theme.caption("Wisp looks for Docker Desktop, OrbStack, Colima, Rancher Desktop and Lima")
            table.rows = []
            relayout()
            return
        }
        hero.figure.set(Double(memory))
        hero.meta.text = Theme.caption("\(running.count) container\(running.count == 1 ? "" : "s") in \(Docker.engineName(socket))")
        hero.needsLayout = true

        cpuTile.set(text: String(format: "%.1f", cpu * 100), unit: "%")
        cpuTile.set(note: running.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) }.map { "Most in \($0.name)" } ?? "")
        let limited = running.compactMap { c -> (Container, Double)? in
            guard let used = c.memory, let limit = c.memoryLimit, limit > 0, limit < 1 << 50 else { return nil }
            return (c, Double(used) / Double(limit))
        }.max { $0.1 < $1.1 }
        if let (container, fraction) = limited {
            limitTile.set(text: container.name)
            limitTile.meter.fraction = fraction
            limitTile.meter.color = fraction > 0.9 ? Theme.bad : (fraction > 0.75 ? Theme.warn : Theme.good)
            limitTile.set(note: "\(Format.percent(fraction)) of \(Format.memory(container.memoryLimit ?? 0))")
        }
        let network = running.reduce(0) { $0 + ($1.networkRate ?? 0) }
        let (value, unit) = DashboardView.split(Format.rate(network))
        networkTile.set(text: value, unit: unit)
        networkTile.set(note: "In and out")
        let ports = Set(running.flatMap { $0.ports.compactMap { $0.split(separator: ":").first.map(String.init) } })
        portsTile.set(text: "\(ports.count)")
        portsTile.set(note: ports.sorted().prefix(5).joined(separator: " · "))

        let column = table.sortColumn
        let key: (Container) -> Double = {
            switch column {
            case 4: return Double($0.memory ?? 0)
            case 5: return $0.networkRate ?? 0
            case 6: return $0.diskRate ?? 0
            default: return $0.cpu ?? 0
            }
        }
        let sorted = running.sorted { ($0.folder ?? $0.project ?? "", -key($0)) < ($1.folder ?? $1.project ?? "", -key($1)) }
        let peak = max(sorted.compactMap(\.cpu).max() ?? 0, 0.0001)
        let icon = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
        table.rows = sorted.map { c in
            ColumnTable.Row(id: c.id, icon: icon,
                            cells: [(c.project.map { $0 + " / " } ?? "") + c.name,
                                    c.ports.map { String($0.split(separator: ":").first ?? "") }.joined(separator: ", "),
                                    c.status, c.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "–",
                                    c.memory.map { Format.memory($0) } ?? "–",
                                    c.networkRate.map { Format.rate($0) } ?? "–", c.diskRate.map { Format.rate($0) } ?? "–"],
                            fraction: (c.cpu ?? 0) / peak)
        }
        relayout()
    }

    private func show(_ use: DockerDiskUse?) {
        guard let use else {
            diskTotal.text = Theme.caption("Not available")
            return
        }
        diskTotal.text = Theme.caption("\(Format.bytes(use.total)) total · \(Format.bytes(use.reclaimable)) reclaimable")
        let parts: [(String, DockerDiskUse.Part, NSColor)] = [("Images", use.images, Theme.series[2]), ("Containers", use.containers, Theme.series[1]),
                                                             ("Volumes", use.volumes, Theme.series[4]), ("Build cache", use.buildCache, Theme.series[5])]
        diskWaffle.parts = parts.map { .init(name: $0.0, value: Double($0.1.size), color: $0.2) }
        diskLegend.items = parts.map {
            .init(name: $0.0, value: Format.bytes($0.1.size), share: "\($0.1.inUse)/\($0.1.count)", color: $0.2)
        }
    }

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
