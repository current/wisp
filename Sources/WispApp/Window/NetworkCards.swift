import AppKit
import SystemConfiguration
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
    nonisolated static let rows = 6
    /// The cards' height when the window leaves them no more room.
    static let height: CGFloat = 314

    init(page: MachinePage) {
        self.page = page
        dataCard.header.title = "Most data"
        dataCard.header.detail = "this month"
        dataCard.toggle = Segmented(["5 min", "Today", "Month"])
        dataCard.toggle?.select(2, animated: false)
        dataCard.toggle?.onChange = { [weak self] _ in self?.dataAt = .distantPast; self?.refreshData() }
        dataCard.meterColor = A2.down
        dataCard.meterEnd = A2.up
        hostsCard.header.title = "Hosts"
        hostsCard.header.detail = "all apps"
        hostsCard.meterColor = A2.cpu
        hostsCard.footnote.text = Self.footnote("Open connections, counted since each one opened")
        for (index, row) in dataCard.rows.enumerated() {
            row.onClick = { [weak self] in
                guard let self, index < self.appIDs.count else { return }
                self.page?.onSelect(.app(self.appIDs[index]))
            }
        }
    }

    var extras: [(CardView, CGFloat)] { [(dataCard, Self.height), (hostsCard, Self.height)] }

    static func footnote(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(10.5), .foregroundColor: A2.tertiary])
    }

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
        dataCard.header.detail = ["in the last 5 minutes", "today", "this month"][mode]
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
            dataCard.footnote.text = Self.footnote(seconds < 280 ? "Measured for \(max(minutes, seconds > 0 ? 1 : 0)) of the last 5 minutes"
                                                   : "Average rates, for finding what uses a hotspot")
        } else {
            dataCard.footnote.text = Self.footnote(AppNetworkSection.sinceNote(usage.since, background: page.delegate.settings.trackAppNetwork,
                                                                               monthStart: mode == 1 ? Calendar.current.startOfDay(for: now) : usage.startOfMonth(now)))
        }
    }

    // MARK: Hosts

    private func refreshHosts(_ table: ProcessTable) {
        guard let page, !busy, table.networkMeasured else {
            if !table.networkMeasured {
                hostsCard.fill([], empty: "Per-app traffic is off")
                hostsCard.header.items = []
            }
            return
        }
        busy = true
        let monitor = page.delegate.monitor
        var appOf: [Int32: String] = [:]
        for process in table.processes { appOf[process.pid] = table.app(process.groupID)?.name ?? process.name }
        work.async { [weak self] in
            let flows = monitor.networkFlows(pids: nil) ?? []
            let (items, open) = Self.hosts(flows, appOf: appOf)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.hostsCard.fill(items, empty: "No connections")
                self.hostsCard.header.items = open > 0 ? [.init(text: open == 1 ? "1 open connection" : "\(open) open connections")] : []
            }
        }
    }

    /// The busiest hosts, and how many connections leave the Mac.
    nonisolated private static func hosts(_ flows: [NetworkFlow], appOf: [Int32: String]) -> ([NetworkListCard.Item], Int) {
        // Only flows that left the Mac, by the far end's address.
        var byAddress: [String: (endpoint: NetworkEndpoint, bytes: UInt64, received: UInt64, sent: UInt64, apps: [String: UInt64])] = [:]
        var open = 0
        for flow in flows {
            guard let remote = flow.remote, !remote.isUnspecified, !remote.isLoopback else { continue }
            open += 1
            guard flow.received &+ flow.sent > 0 else { continue }
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
        let items = top.map { name, group in
            let apps = group.apps.sorted { $0.value > $1.value }.map(\.key)
            let note = apps.count > 2 ? "\(apps[0]), \(apps[1]) and \(apps.count - 2) more" : apps.joined(separator: ", ")
            return NetworkListCard.Item(icon: nil, name: name, note: note, value: Format.bytes(group.bytes), fraction: Double(group.bytes) / peak)
        }
        return (items, open)
    }
}

/// A list card of the Network page: a header with an optional switch, six rows that
/// share the height (icon, name over a detail, a meter and the amount) and a footnote.
final class NetworkListCard: CardView {
    struct Item: Sendable {
        var icon: NSImage?
        var name: String
        var note: String
        var value: String
        var fraction: Double
    }

    let header = A2Header()
    let footnote = TextLine()
    private let empty = TextLine()
    let rows: [A2Row] = (0..<NetworkCards.rows).map { _ in A2Row() }
    var toggle: Segmented? { didSet { oldValue?.removeFromSuperview(); toggle.map(addSubview) } }
    var meterColor = A2.cpu
    var meterEnd: NSColor?

    override init() {
        super.init()
        for view in [header, footnote, empty] as [NSView] { addSubview(view) }
        empty.alignment = .center
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
            row.lead = item.icon.map { .image($0) } ?? .glyph("globe", nil)
            row.name = item.name
            row.detail = item.note
            row.cells = [.init(kind: .meter(item.fraction, meterColor, meterEnd), width: 96),
                         .init(kind: .text(item.value, A2.primary, A2.valueFont, .right), width: 56)]
            row.showsRule = index > 0
        }
        empty.text = NSAttributedString(string: items.isEmpty ? text : "", attributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        let toggleWidth = toggle?.naturalWidth ?? 0
        header.frame = NSRect(x: A2.padSide, y: A2.padTop + 5, width: inner - (toggle == nil ? 0 : toggleWidth + 12), height: 16)
        if let toggle {
            toggle.frame = NSRect(x: A2.padSide + inner - toggleWidth, y: A2.padTop, width: toggleWidth, height: 26)
        }
        let top = A2.padTop + 26 + 8
        let footY = bounds.height - A2.padTop - 13
        footnote.frame = NSRect(x: A2.padSide, y: footY, width: inner, height: 13)
        let pitch = ((footY - 6 - top) / CGFloat(rows.count)).rounded(.down)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: A2.padSide, y: top + CGFloat(index) * pitch, width: inner, height: pitch)
        }
        empty.frame = NSRect(x: A2.padSide, y: top + (footY - top) / 2 - 8, width: inner, height: 16)
    }
}

/// How the Mac is connected now: the primary interface's kind and its IPv4 address.
/// Read from the system configuration store, only while the Network page is open.
enum NetworkPlace {
    struct Place {
        var kind: String
        var address: String
    }

    static func current() -> Place? {
        guard let store = SCDynamicStoreCreate(nil, "Wisp" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String else { return nil }
        var kind = "Network"
        for item in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] where SCNetworkInterfaceGetBSDName(item) as String? == interface {
            kind = (SCNetworkInterfaceGetLocalizedDisplayName(item) as String?) ?? kind
        }
        let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any]
        let address = (state?["Addresses"] as? [String])?.first ?? interface
        return Place(kind: kind, address: address)
    }
}
