import AppKit
import WispCore

/// The Network page's two extra cards: the apps that used the most data (last
/// five minutes, today or this month) and the hosts all apps send the most to.
///
/// Both update from the page's own process passes, so they cost nothing while
/// the page is closed. The hosts come from the flows Wisp already counts for the
/// per-app figures, without walking any process's sockets.
@MainActor
final class NetworkCards {
    let dataCard = NetworkListCard()
    let hostsCard = NetworkListCard()
    private weak var page: MachinePage?
    private var appIDs: [String] = []
    private var dataAt = Date.distantPast
    private var lastTable: ProcessTable?
    private let work = DispatchQueue(label: "app.wisp.network.hosts", qos: .utility)
    private var busy = false
    static let rows = 6
    static let height: CGFloat = 46 + CGFloat(rows) * 34 + 40

    init(page: MachinePage) {
        self.page = page
        dataCard.title.text = page.cardTitle("Most data", "this month")
        dataCard.toggle = Segmented(["5 min", "Today", "Month"])
        dataCard.toggle?.select(2, animated: false)
        dataCard.toggle?.onChange = { [weak self] _ in self?.dataAt = .distantPast; self?.refreshData() }
        hostsCard.title.text = page.cardTitle("Hosts", "all apps")
        hostsCard.footnote.text = Theme.caption("Open connections, counted since each one opened", size: 9.5)
        for (index, row) in dataCard.rows.enumerated() {
            row.onClick = { [weak self] in
                guard let self, index < self.appIDs.count else { return }
                self.page?.onSelect(.app(self.appIDs[index]))
            }
        }
    }

    var extras: [(CardView, CGFloat)] { [(dataCard, Self.height), (hostsCard, Self.height)] }

    func update(table: ProcessTable) {
        lastTable = table
        if Date().timeIntervalSince(dataAt) > (dataCard.toggle?.selected == 0 ? 2 : 10) { refreshData() }
        refreshHosts(table)
    }

    // MARK: Most data

    private func refreshData() {
        guard let page, let table = lastTable else { return }
        dataAt = Date()
        let usage = page.delegate.monitor.dataUsage
        let mode = dataCard.toggle?.selected ?? 2
        let now = Date()
        let totals: [String: AppDataUsage.Entry]
        var seconds: Double = 0
        switch mode {
        case 0: (totals, seconds) = usage.recentTotals(window: 5 * 60, now: now)
        case 1: totals = usage.totals(since: Calendar.current.startOfDay(for: now))
        default: totals = usage.totals(since: usage.startOfMonth(now))
        }
        dataCard.title.text = page.cardTitle("Most data", ["in the last 5 minutes", "today", "this month"][mode])
        let top = totals.sorted { $0.value.bytes > $1.value.bytes }.filter { $0.value.bytes >= 1 }.prefix(Self.rows)
        appIDs = top.map(\.key)
        let peak = max(top.first?.value.bytes ?? 1, 1)
        let window = max(seconds, 1)
        dataCard.fill(top.map { id, entry in
            let app = table.app(id)
            let icon = app.map { Icons.icon(for: $0) }
                ?? Icons.icon(id: id, kind: id.hasSuffix(".app") ? .app : .tool, bundlePath: id.hasSuffix(".app") ? id : nil)
            let note = mode == 0 ? "\(Format.rate(entry.bytes / window)) on average"
                : "↓ \(Format.bytes(entry.received)) ↑ \(Format.bytes(entry.sent))"
            return NetworkListCard.Item(icon: icon, name: app?.name ?? entry.name, note: note, value: Format.bytes(entry.bytes),
                                 fraction: entry.bytes / peak)
        }, empty: usage.since == nil || !table.networkMeasured && totals.isEmpty ? "Nothing counted yet" : "No data used")
        if mode == 0 {
            let minutes = Int((seconds / 60).rounded())
            dataCard.footnote.text = Theme.caption(seconds < 280 ? "Measured for \(max(minutes, seconds > 0 ? 1 : 0)) of the last 5 minutes"
                                                   : "Average rates, for finding what uses a hotspot", size: 9.5)
        } else {
            dataCard.footnote.text = Theme.caption(AppNetworkSection.sinceNote(usage.since, background: page.delegate.settings.trackAppNetwork,
                                                                               monthStart: mode == 1 ? Calendar.current.startOfDay(for: now) : usage.startOfMonth(now)),
                                                   size: 9.5)
        }
    }

    // MARK: Hosts

    private func refreshHosts(_ table: ProcessTable) {
        guard let page, !busy, table.networkMeasured else {
            if !table.networkMeasured { hostsCard.fill([], empty: "Per-app traffic is off") }
            return
        }
        busy = true
        let monitor = page.delegate.monitor
        var appOf: [Int32: String] = [:]
        for process in table.processes { appOf[process.pid] = table.app(process.groupID)?.name ?? process.name }
        work.async { [weak self] in
            let flows = monitor.networkFlows(pids: nil) ?? []
            let items = Self.hosts(flows, appOf: appOf)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.hostsCard.fill(items, empty: "No connections")
            }
        }
    }

    nonisolated private static func hosts(_ flows: [NetworkFlow], appOf: [Int32: String]) -> [NetworkListCard.Item] {
        // Only flows that left the Mac, by the far end's address.
        var byAddress: [String: (endpoint: NetworkEndpoint, bytes: UInt64, received: UInt64, sent: UInt64, apps: [String: UInt64])] = [:]
        for flow in flows {
            guard let remote = flow.remote, !remote.isUnspecified, !remote.isLoopback, flow.received &+ flow.sent > 0 else { continue }
            var entry = byAddress[remote.address] ?? (remote, 0, 0, 0, [:])
            entry.bytes &+= flow.received &+ flow.sent
            entry.received &+= flow.received
            entry.sent &+= flow.sent
            entry.apps[appOf[flow.owner] ?? appOf[flow.pid] ?? "Process \(flow.owner)", default: 0] &+= flow.received &+ flow.sent
            byAddress[remote.address] = entry
        }
        // Names for the busiest addresses only; the rest group by address.
        let ranked = byAddress.values.sorted { $0.bytes > $1.bytes }
        var names: [String: String] = [:]
        for entry in ranked.prefix(16) where HostLabel.wantsLookup(entry.endpoint) {
            if let name = HostNames.shared.name(for: entry.endpoint.address) { names[entry.endpoint.address] = name }
        }
        var groups: [String: (bytes: UInt64, received: UInt64, sent: UInt64, apps: [String: UInt64])] = [:]
        for entry in ranked {
            let name = HostLabel.name(for: entry.endpoint, dns: names[entry.endpoint.address])
            var group = groups[name] ?? (0, 0, 0, [:])
            group.bytes &+= entry.bytes
            group.received &+= entry.received
            group.sent &+= entry.sent
            for (app, bytes) in entry.apps { group.apps[app, default: 0] &+= bytes }
            groups[name] = group
        }
        let top = groups.sorted { $0.value.bytes > $1.value.bytes }.prefix(rows)
        let peak = Double(max(top.first?.value.bytes ?? 1, 1))
        return top.map { name, group in
            let apps = group.apps.sorted { $0.value > $1.value }.map(\.key)
            let note = apps.count > 2 ? "\(apps[0]), \(apps[1]) and \(apps.count - 2) more" : apps.joined(separator: ", ")
            return NetworkListCard.Item(icon: nil, name: name, note: note, value: Format.bytes(group.bytes), fraction: Double(group.bytes) / peak)
        }
    }
}

/// `ListCard` with a switch in the title row and a footnote, same row metrics.
final class NetworkListCard: CardView {
    struct Item: Sendable {
        var icon: NSImage?
        var name: String
        var note: String
        var value: String
        var fraction: Double
    }

    let title = TextLine()
    let footnote = TextLine()
    private let empty = TextLine()
    let rows: [ListRow] = (0..<NetworkCards.rows).map { _ in ListRow() }
    var toggle: Segmented? { didSet { oldValue?.removeFromSuperview(); toggle.map(addSubview) } }

    override init() {
        super.init()
        for view in [title, footnote, empty] as [NSView] { addSubview(view) }
        for row in rows {
            row.isHidden = true
            addSubview(row)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fill(_ items: [Item], empty text: String) {
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= items.count
            guard index < items.count else { continue }
            let item = items[index]
            row.icon = item.icon
            row.name = item.name
            row.note = item.note
            row.value = item.value
            row.fraction = item.fraction
            row.showsRule = index < items.count - 1
        }
        empty.text = Theme.caption(items.isEmpty ? text : "", size: 10)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 40
        title.frame = NSRect(x: 20, y: 16, width: inner - (toggle?.naturalWidth ?? 0) - 12, height: 20)
        if let toggle {
            let width = toggle.naturalWidth
            toggle.frame = NSRect(x: 20 + inner - width, y: 12, width: width, height: 26)
        }
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 20, y: 46 + CGFloat(index) * 34, width: inner, height: 34) }
        empty.frame = NSRect(x: 20, y: 54, width: inner, height: 14)
        footnote.frame = NSRect(x: 20, y: bounds.height - 30, width: inner, height: 15)
    }
}
