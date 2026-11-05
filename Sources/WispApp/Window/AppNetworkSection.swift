import AppKit
import WispCore

/// The drawer's network cards: the data the app used today, this week and this
/// month, and its connections grouped by the host at the other end.
///
/// Works only while the drawer feeds it: each `update` lists the sockets of the
/// shown app's processes on a utility queue, joins them with the flows Wisp
/// already counts and asks for host names in the background. With the drawer
/// shut nothing calls it, and queued name lookups are dropped.
@MainActor
final class AppNetworkSection: NSView {
    /// The section living in the drawer's content view, made on first use.
    static func attach(to content: NSView) -> AppNetworkSection {
        if let existing = content.subviews.first(where: { $0 is AppNetworkSection }) as? AppNetworkSection { return existing }
        let section = AppNetworkSection()
        content.addSubview(section)
        return section
    }

    private let usageCard = CardView()
    private let usageTitle = TextLine()
    private let usageNote = TextLine()
    private var usageColumns: [(label: TextLine, figure: BigNumber, note: TextLine)] = []

    private let connectionsCard = CardView()
    private let connectionsTitle = TextLine()
    private let connectionsMeta = TextLine()
    private var rows: [ConnectionRow] = []
    private let listeningLabel = TextLine()
    private let moreLine = TextLine()
    private let emptyLine = TextLine()
    private var shownHosts = 0
    private var shownListening = 0
    private var hasMore = false

    private let work = DispatchQueue(label: "app.wisp.drawer.network", qos: .utility)
    private let sampler = ConnectionSampler()
    private var busy = false
    private var key = ""
    private var usageAt = Date.distantPast
    static let maxHosts = 8
    static let maxListening = 4

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for card in [usageCard, connectionsCard] {
            card.radius = 14
            addSubview(card)
        }
        usageTitle.text = Self.title("Data used")
        for view in [usageTitle, usageNote] as [NSView] { usageCard.addSubview(view) }
        for name in ["Today", "This week", "This month"] {
            let label = TextLine(), figure = BigNumber(), note = TextLine()
            label.text = NSAttributedString(string: name, attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary])
            figure.font = Theme.figure(14)
            figure.unitFont = Theme.sans(12, .medium)
            figure.show("–")
            for view in [label, figure, note] as [NSView] { usageCard.addSubview(view) }
            usageColumns.append((label, figure, note))
        }
        connectionsTitle.text = Self.title("Connections")
        connectionsMeta.alignment = .right
        listeningLabel.text = NSAttributedString(string: "Listening", attributes: [.font: Theme.sans(11, .medium), .foregroundColor: Theme.inkSecondary])
        for view in [connectionsTitle, connectionsMeta, listeningLabel, moreLine, emptyLine] as [NSView] { connectionsCard.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
    }

    // MARK: Layout

    private static let rowHeight: CGFloat = 40

    /// Lays the cards out from `top` in the drawer's content; returns the next free y.
    func arrange(top: CGFloat, width inner: CGFloat) -> CGFloat {
        guard !isHidden else { return top }
        let usageHeight: CGFloat = 112
        let hostRows = CGFloat(shownHosts), listenRows = CGFloat(shownListening)
        var connectionsHeight: CGFloat = 52 + max(1, hostRows) * Self.rowHeight
        if shownListening > 0 { connectionsHeight += 26 + listenRows * Self.rowHeight }
        if hasMore { connectionsHeight += 22 }
        connectionsHeight += 8
        frame = NSRect(x: 16, y: top, width: inner, height: usageHeight + 10 + connectionsHeight)
        usageCard.frame = NSRect(x: 0, y: 0, width: inner, height: usageHeight)
        connectionsCard.frame = NSRect(x: 0, y: usageHeight + 10, width: inner, height: connectionsHeight)

        let width = inner - 36
        usageTitle.frame = NSRect(x: 18, y: 18, width: 120, height: 18)
        usageNote.frame = NSRect(x: 18 + 110, y: 20, width: width - 110, height: 15)
        usageNote.alignment = .right
        let column = width / 3
        for (index, parts) in usageColumns.enumerated() {
            let x = 18 + CGFloat(index) * column
            parts.label.frame = NSRect(x: x, y: 48, width: column - 8, height: 15)
            parts.figure.frame = NSRect(x: x, y: 64, width: column - 8, height: 22)
            parts.note.frame = NSRect(x: x, y: 88, width: column - 8, height: 14)
        }

        connectionsTitle.frame = NSRect(x: 18, y: 18, width: 120, height: 18)
        connectionsMeta.frame = NSRect(x: 18 + 110, y: 20, width: width - 110, height: 15)
        var y: CGFloat = 48
        for (index, row) in rows.enumerated() {
            if index == shownHosts {
                if shownHosts == 0 { y += Self.rowHeight }
                listeningLabel.frame = NSRect(x: 18, y: y + 10, width: width, height: 15)
                y += 26
            }
            guard !row.isHidden else { continue }
            row.frame = NSRect(x: 18, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        listeningLabel.isHidden = shownListening == 0
        moreLine.isHidden = !hasMore
        moreLine.frame = NSRect(x: 18, y: connectionsHeight - 30, width: width, height: 15)
        emptyLine.frame = NSRect(x: 18, y: 48 + (Self.rowHeight - 15) / 2, width: width, height: 15)
        emptyLine.isHidden = shownHosts > 0
        return frame.maxY + 10
    }

    // MARK: Updating

    /// Called by the drawer on every process pass while it is open.
    func update(selection: Selection?, pids: [Int32], table: ProcessTable, delegate: AppDelegate) {
        guard let selection else { return }
        let newKey: String
        switch selection {
        case .app(let id): newKey = id
        case .process(let pid): newKey = "pid:\(pid)"
        }
        let appID: String? = {
            switch selection {
            case .app(let id): return id
            case .process(let pid): return table.processes.first { $0.pid == pid }?.groupID
            }
        }()
        if newKey != key {
            key = newKey
            usageAt = .distantPast
            HostNames.shared.cancelQueued()
            show(groups: [], listening: [], total: 0, measured: table.networkMeasured, names: [:])
            work.async { [sampler] in sampler.reset() }
        }
        if Date().timeIntervalSince(usageAt) > 10, let appID {
            usageAt = Date()
            fillUsage(appID, delegate: delegate)
        }
        guard !busy, !pids.isEmpty else { return }
        busy = true
        let monitor = delegate.monitor
        let names = Dictionary(table.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        let measured = table.networkMeasured
        let token = key
        let sampler = sampler
        work.async { [weak self] in
            let flows = measured ? monitor.networkFlows(pids: Set(pids)) : nil
            let connections = sampler.sample(pids: pids, flows: flows)
            let resolved = Self.lookUpNames(connections)
            let label: (NetworkEndpoint) -> String = { HostLabel.name(for: $0, dns: resolved[$0.address]) }
            let groups = HostGroup.group(connections.filter { $0.direction != .listening }, label: label,
                                         detail: { resolved[$0.address] ?? $0.address })
            let listening = connections.filter { $0.direction == .listening }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard token == self.key, !self.isHidden, self.window != nil else { return }
                self.show(groups: groups, listening: listening, total: connections.count - listening.count,
                          measured: flows != nil, names: names)
            }
        }
    }

    /// Names already known; unknown ones are queued, busiest first, for the next tick.
    nonisolated private static func lookUpNames(_ connections: [AppConnection]) -> [String: String] {
        var bytes: [String: UInt64] = [:]
        var endpoints: [String: NetworkEndpoint] = [:]
        for connection in connections {
            guard let remote = connection.remote, HostLabel.wantsLookup(remote) else { continue }
            bytes[remote.address, default: 0] &+= connection.bytes
            endpoints[remote.address] = remote
        }
        var result: [String: String] = [:]
        for address in bytes.keys.sorted(by: { bytes[$0, default: 0] > bytes[$1, default: 0] }) {
            if let name = HostNames.shared.name(for: address) { result[address] = name }
        }
        return result
    }

    override func viewDidHide() {
        super.viewDidHide()
        // The drawer shut: no lookups for it should still be waiting.
        HostNames.shared.cancelQueued()
    }

    private func fillUsage(_ appID: String, delegate: AppDelegate) {
        let usage = delegate.monitor.dataUsage
        let now = Date()
        let (today, week, month) = usage.usage(of: appID, now: now)
        for (index, entry) in [today, week, month].enumerated() {
            let column = usageColumns[index]
            if let entry, entry.bytes >= 1 {
                let (value, unit) = DashboardView.split(Format.bytes(entry.bytes))
                column.figure.show(value, unit: unit)
                column.note.text = Theme.caption("↓ \(Format.bytes(entry.received)) ↑ \(Format.bytes(entry.sent))", size: 9.5)
            } else {
                column.figure.show(usage.since == nil ? "–" : "0", unit: usage.since == nil ? "" : "KB")
                column.note.text = NSAttributedString()
            }
        }
        usageNote.text = Theme.caption(Self.sinceNote(usage.since, background: delegate.settings.trackAppNetwork,
                                                      monthStart: usage.startOfMonth(now)), size: 9.5)
    }

    /// Says what the totals cover: counting starts when Wisp first measured, and
    /// without background tracking only while a network view is open.
    static func sinceNote(_ since: Date?, background: Bool, monthStart: Date) -> String {
        guard let since else { return "Counted while Wisp measures" }
        let when = since.formatted(.dateTime.day().month(.abbreviated))
        let prefix = since > monthStart ? "Since \(when), " : ""
        return prefix + (background ? "while Wisp runs" : "while a network view is open")
    }

    private func show(groups: [HostGroup], listening: [AppConnection], total: Int, measured: Bool, names: [Int32: String]) {
        let hosts = Array(groups.prefix(Self.maxHosts))
        var ports: [UInt16: [AppConnection]] = [:]
        for socket in listening { ports[socket.local.port, default: []].append(socket) }
        let listen = ports.keys.sorted { a, b in
            let tcpA = ports[a]!.contains { !$0.isUDP }, tcpB = ports[b]!.contains { !$0.isUDP }
            return tcpA != tcpB ? tcpA : a < b
        }.prefix(Self.maxListening)
        let wanted = hosts.count + listen.count
        while rows.count < wanted {
            let row = ConnectionRow()
            connectionsCard.addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= wanted
            if index < hosts.count {
                row.set(host: hosts[index], names: names, measured: measured)
                row.showsRule = index < hosts.count - 1
            } else if index < wanted {
                let port = listen[listen.index(listen.startIndex, offsetBy: index - hosts.count)]
                row.set(port: port, sockets: ports[port] ?? [], names: names)
                row.showsRule = index < wanted - 1
            }
        }
        let more = groups.count - hosts.count
        let moreChanged = hasMore != (more > 0)
        hasMore = more > 0
        moreLine.text = Theme.caption(more == 1 ? "1 more host" : "\(more) more hosts", size: 9.5)
        if hosts.isEmpty, rows.first?.isHidden ?? true {
            connectionsMeta.text = NSAttributedString()
        } else {
            connectionsMeta.text = Theme.caption("\(total) open · \(groups.count) \(groups.count == 1 ? "host" : "hosts")", size: 9.5)
        }
        emptyLine.text = Theme.caption(hosts.isEmpty ? "No connections to other hosts" : "", size: 10)
        let changed = shownHosts != hosts.count || shownListening != listen.count || moreChanged
        shownHosts = hosts.count
        shownListening = listen.count
        if changed || frame.height == 0 { drawer?.needsLayout = true }
        scrollForScreenshot()
    }

    private var scrolledForScreenshot = false

    /// WISP_DRAWER_SCROLL=<points> scrolls the drawer once its cards are in, for screenshots.
    private func scrollForScreenshot() {
        guard !scrolledForScreenshot, let points = ProcessInfo.processInfo.environment["WISP_DRAWER_SCROLL"].flatMap(Double.init),
              let scroll = enclosingScrollView else { return }
        scrolledForScreenshot = true
        DispatchQueue.main.async {
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: points))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private var drawer: NSView? {
        var view = superview
        while let current = view, !(current is AppDrawer) { view = current.superview }
        return view
    }
}

/// One host or listening port: name and rate on top; ports, state, owner and the
/// bytes in and out under it.
final class ConnectionRow: DrawnView, SelfAuditing {
    private var name = "", note = "", rate = "", bytes = ""
    var showsRule = true { didSet { if showsRule != oldValue { needsDisplay = true } } }

    private func set(_ name: String, _ note: String, _ rate: String, _ bytes: String, tip: String) {
        toolTip = tip
        guard (name, note, rate, bytes) != (self.name, self.note, self.rate, self.bytes) else { return }
        (self.name, self.note, self.rate, self.bytes) = (name, note, rate, bytes)
        needsDisplay = true
    }

    func set(host: HostGroup, names: [Int32: String], measured: Bool) {
        var parts: [String] = []
        let incoming = host.connections.contains { $0.direction == .incoming }
        if incoming { parts.append(host.connections.allSatisfy { $0.direction == .incoming } ? "Incoming" : "In and out") }
        parts.append(Self.ports(host.connections.compactMap { c in c.remote.map { ($0.port, c.isUDP) } }))
        let tcp = host.connections.filter { !$0.isUDP }
        let open = tcp.filter { $0.state == "Open" }.count
        let other = tcp.count - open
        if open > 0 { parts.append("\(open) open") }
        if other > 0 { parts.append(tcp.count == other && other == 1 ? (tcp.first?.state.lowercased() ?? "") : "\(other) closing") }
        let udp = host.connections.count - tcp.count
        if udp > 0 { parts.append(udp == 1 ? "1 flow" : "\(udp) flows") }
        parts.append(Self.owners(host.connections.map(\.pid), names: names))
        let measuredAny = measured && host.connections.contains(where: \.measured)
        let rate = measuredAny && host.perSecond >= 1 ? Format.rate(host.perSecond) : "–"
        let bytes = measuredAny ? "↓ \(Format.bytes(host.received)) ↑ \(Format.bytes(host.sent))" : ""
        let tip = ([host.name] + host.addresses.filter { $0 != host.name }.prefix(6)).joined(separator: "\n")
        set(host.name, parts.joined(separator: " · "), rate, bytes, tip: tip)
    }

    func set(port: UInt16, sockets: [AppConnection], names: [Int32: String]) {
        let protocols = Set(sockets.map(\.protocolName)).sorted().joined(separator: " and ")
        let local = sockets.allSatisfy { $0.local.isLoopback }
        var parts = [protocols, local ? "This Mac only" : "All networks"]
        parts.append(Self.owners(sockets.map(\.pid), names: names))
        let service = HostLabel.service(port: port).map { " · \($0)" } ?? ""
        set("Port \(port)", parts.joined(separator: " · "), "", "", tip: "Port \(port)\(service)")
    }

    /// "443 TCP", "443 TCP and UDP", "443, 80 TCP".
    static func ports(_ list: [(UInt16, Bool)]) -> String {
        var byPort: [UInt16: Set<String>] = [:]
        var order: [UInt16] = []
        for (port, udp) in list {
            if byPort[port] == nil { order.append(port) }
            byPort[port, default: []].insert(udp ? "UDP" : "TCP")
        }
        let protocols = Set(byPort.values.flatMap { $0 }).sorted().joined(separator: " and ")
        let shown = order.prefix(2).map(String.init).joined(separator: ", ") + (order.count > 2 ? " and more" : "")
        return "\(shown) \(protocols)"
    }

    static func owners(_ pids: [Int32], names: [Int32: String]) -> String {
        var counts: [String: Int] = [:]
        for pid in pids { counts[names[pid] ?? "Process \(pid)", default: 0] += 1 }
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let first = sorted.first else { return "" }
        return sorted.count == 1 ? first.key : "\(first.key) and \(sorted.count - 1) more"
    }

    private static let nameFont = Theme.sans(13)
    private static let rateAttributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(13, .semibold), .foregroundColor: Theme.ink]
    private static let bytesAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.digits(11, .regular), .foregroundColor: Theme.inkSecondary]

    private var rateWidth: CGFloat { rate.isEmpty ? 0 : ceil((rate as NSString).size(withAttributes: Self.rateAttributes).width) }
    private var bytesWidth: CGFloat { bytes.isEmpty ? 0 : ceil((bytes as NSString).size(withAttributes: Self.bytesAttributes).width) }

    var auditFaults: [String] {
        let room = bounds.width - rateWidth - 12
        return room < 80 ? ["\(name) has \(Int(room)) pt"] : []
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsRule {
            Theme.rule.setFill()
            NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        if !rate.isEmpty {
            let rateColor = rate == "–" ? Theme.inkSecondary : Theme.ink
            var attributes = Self.rateAttributes
            attributes[.foregroundColor] = rateColor
            (rate as NSString).draw(at: NSPoint(x: bounds.width - rateWidth, y: 4), withAttributes: attributes)
        }
        if !bytes.isEmpty {
            (bytes as NSString).draw(at: NSPoint(x: bounds.width - bytesWidth, y: 22), withAttributes: Self.bytesAttributes)
        }
        let nameRoom = bounds.width - rateWidth - 12
        (name as NSString).draw(with: NSRect(x: 0, y: 4, width: nameRoom, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Self.nameFont, .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
        let noteRoom = bounds.width - bytesWidth - 12
        (note as NSString).draw(with: NSRect(x: 0, y: 21, width: noteRoom, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary, .paragraphStyle: paragraph])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { [note, rate, bytes].filter { !$0.isEmpty }.joined(separator: ", ") }
}
