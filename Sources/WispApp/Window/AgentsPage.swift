import AppKit
import WispCore

/// An agent's mark: the icon of its own Mac app when one is installed, otherwise its
/// glyph and colour, which the A2 views draw on a quiet square.
@MainActor
enum AgentLook {
    static func mark(_ kind: String, size: CGFloat, appearance: NSAppearance) -> (icon: NSImage?, glyph: String, tint: NSColor) {
        let (symbol, tint) = AgentMark.symbol(kind)
        let image = AgentMark.image(kind, size: size, appearance: appearance)
        // AgentMark hands back IconTile's cached glyph when there is no app to take the icon from.
        let isGlyph = image === IconTile.glyph(symbol, tint: tint, size: size, appearance: appearance)
        return (isGlyph ? nil : image, symbol, tint)
    }
}

/// One account's plan limits: a header with the agent's mark, account and plan, then
/// each window as a tick meter with when it resets and whether the current pace
/// runs it out first. The windows share the card's height.
@MainActor
final class PlanCard: CardView {
    final class WindowRow: BitmapView {
        var name = ""
        var used: Double = 0
        var detail = ""
        var short = false
        let meter = TickMeter()

        override init(frame: NSRect) {
            super.init(frame: frame)
            meter.ticks = true
            meter.tickWidth = 3
            meter.pitch = 5
            addSubview(meter)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            meter.frame = NSRect(x: 0, y: bounds.height - 8, width: bounds.width - 64, height: 8)
        }

        override func draw(_ dirtyRect: NSRect) {
            let right = bounds.width - 64
            let used = A2Dev.text(name, x: 0, mid: 7, width: right, font: Theme.sans(12), color: A2.secondary)
            A2Dev.text(detail, x: used + 12, mid: 7, width: right - used - 12, font: Theme.sans(11),
                       color: short ? A2.warn : A2.tertiary, right: true)
            let font = Theme.digits(15, .semibold)
            A2Dev.text(Format.percent(self.used), x: right, mid: bounds.height - 6, width: 64, font: font, color: A2.primary, right: true)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityValue() -> Any? { "\(name) \(Format.percent(used)), \(detail)" }
    }

    /// The provider with its mark, the plan on the right and the account under them.
    final class Header: BitmapView {
        var provider = ""
        var account = ""
        var plan: String?
        var problem: String?

        override func draw(_ dirtyRect: NSRect) {
            let markRect = NSRect(x: 0, y: -1, width: 22, height: 22)
            let look = AgentLook.mark(provider, size: 22, appearance: effectiveAppearance)
            if let icon = look.icon {
                icon.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                A2Dev.drawGlyphTile(look.glyph, tint: look.tint, in: markRect, appearance: effectiveAppearance)
            }
            var right = bounds.width
            if let plan {
                let font = Theme.sans(11, .semibold)
                let width = A2Dev.width(plan, font) + 16
                let pill = NSRect(x: right - width, y: 0.5, width: width, height: 19)
                A2Dev.tile.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9.5, yRadius: 9.5).fill()
                A2Dev.text(plan, x: pill.minX + 8, mid: pill.midY, width: width, font: font, color: A2.secondary)
                right = pill.minX - 8
            }
            A2Dev.text(provider, x: 30, mid: 10, width: right - 30, font: Theme.sans(14, .semibold), color: A2.primary)
            A2Dev.text(problem ?? account, x: 30, mid: 31, width: bounds.width - 30, font: A2Dev.detailFont,
                       color: problem == nil ? A2.tertiary : A2.warn)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityValue() -> Any? { [provider, plan ?? "", problem ?? account].joined(separator: ", ") }
    }

    let header = Header()
    private(set) var rows: [WindowRow] = []
    /// The mockup's card, with two windows.
    static let height: CGFloat = 170

    override init() {
        super.init()
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ usage: PlanUsage, now: Date) {
        header.provider = usage.provider
        header.account = usage.account + Self.age(usage.updated, now: now)
        header.plan = usage.plan
        header.problem = usage.problem
        header.needsDisplay = true
        while rows.count < usage.windows.count {
            let row = WindowRow()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= usage.windows.count
            guard index < usage.windows.count else { continue }
            let window = usage.windows[index]
            let pace = Self.pace(window, now: now)
            row.name = window.name
            row.used = window.used
            row.detail = pace.text
            row.short = pace.short
            row.meter.fraction = window.used
            row.meter.color = window.used >= 0.9 ? A2.bad : (pace.short ? A2.power : A2.cpu)
            row.needsDisplay = true
        }
        needsLayout = true
    }

    /// Figures are as fresh as the tool's last reply; say so once they are a while old.
    static func age(_ updated: Date?, now: Date) -> String {
        guard let updated, now.timeIntervalSince(updated) > 900 else { return "" }
        let minutes = Int(now.timeIntervalSince(updated) / 60)
        let text = minutes < 60 ? "\(minutes)m" : (minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d")
        return " · as of " + text + " ago"
    }

    /// When the window resets and, if the current pace would use it up first, when that happens.
    static func pace(_ window: PlanUsage.Window, now: Date) -> (text: String, short: Bool) {
        guard let resets = window.resets else { return (window.used == 0 ? "Not used since it reset" : "", false) }
        let left = resets.timeIntervalSince(now)
        guard left > 0 else { return ("Resetting", false) }
        let length: Double = window.name.hasPrefix("5-hour") ? 5 * 3600 : 7 * 86_400
        let elapsed = max(60, length - left)
        if window.used == 0, left > length - 120 { return ("Not started", false) }
        let resetText = "Resets in " + Format.duration(left)
        guard window.used > 0.02, window.used < 1 else { return (window.used >= 1 ? "Used up · " + resetText : resetText, window.used >= 1) }
        let runsOut = (1 - window.used) * elapsed / window.used
        if runsOut < left { return ("Runs out in \(Format.duration(runsOut)) at this rate", true) }
        return (resetText, false)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 40)
        let shown = rows.filter { !$0.isHidden }
        // Spread evenly over what is left, as the mockup's windows are.
        let top = A2.padTop + 46, bottom = bounds.height - A2.padTop - 4
        let rowHeight: CGFloat = 29
        let space = (bottom - top - rowHeight * CGFloat(shown.count)) / CGFloat(shown.count + 1)
        for (index, row) in shown.enumerated() {
            row.frame = NSRect(x: A2.padSide, y: (top + space + CGFloat(index) * (rowHeight + space)).rounded(), width: inner, height: rowHeight)
        }
    }
}

/// Coding agents: what is running and what it costs the Mac, plus, when the
/// owner turns it on, each AI plan's limits and the tokens used today.
@MainActor
final class AgentsPage: CardPage {
    override var pageTint: NSColor { PageID.agents.tint }
    private let (titleLine, caption): (TextLine, TextLine)
    private let tint = A2Dev.tint(.agents)
    private let running: A2Tile
    private let cpu: A2Tile
    private let memory: A2Tile
    private let tokens: A2Tile
    private let planOff = A2NoticeCard()
    /// Claude folders whose status line does not send limits to Wisp yet; checked with the limits.
    private var unconnected: [String] = []
    private var planCards: [PlanCard] = []
    private var plans: [PlanUsage] = []
    private var plansAt = Date.distantPast
    private var plansBusy = false
    private let listCard = CardView()
    private let list = A2Table()
    private let finder = AgentFinder()
    private let counter = TokenCounter()
    private var tokensAt = Date.distantPast
    private var tokensBusy = false
    private var findBusy = false
    private let onSelect: (Selection?) -> Void

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        let title = TextLine(Toolbar.title("Coding Agents"))
        (titleLine, caption) = (title, TextLine())
        self.onSelect = onSelect
        running = A2Tile("Agents running", symbol: "apple.terminal", tint: tint)
        cpu = A2Tile("CPU", symbol: PageID.cpu.symbol, tint: tint)
        memory = A2Tile("Memory", symbol: PageID.memory.symbol, tint: tint)
        tokens = A2Tile("Tokens today", symbol: "wand.and.stars", tint: tint)
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var plansOn: Bool { delegate.settings.planUsage }
    override var toolbarHeading: (NSView, NSView)? { (titleLine, caption) }

    override func loadView() {
        super.loadView()
        for view in [running, cpu, memory, tokens, planOff, listCard] as [NSView] { canvas.addSubview(view) }
        listCard.addSubview(list)
        list.heading = ("Running", "")
        list.headerHeight = 22
        list.headerRule = false
        list.rowHeight = 56
        list.iconSize = 28
        list.meterColors = A2Dev.meter(.agents)
        list.columns = [.init(title: "", width: 96, kind: .bar), .init(title: "CPU", width: 54, right: true, bold: true),
                        .init(title: "Memory", width: 62, right: true)]
        list.emptyText = "No coding agents running. Wisp knows Claude Code, Codex, Cursor Agent, Gemini CLI, Aider, OpenCode and more"
        list.onSelect = { [weak self] id in if let pid = Int32(id) { self?.onSelect(.process(pid)) } }
        caption.text = Toolbar.subtitle("Looking for agents…")
        for tile in [running, cpu, memory, tokens] { tile.figure.show("–") }
        showPlanState()
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = grid([running, cpu, memory, tokens], top: margin, width: width, columns: 4, height: 110) + gap
        let offered = !plansOn || !unconnected.isEmpty
        planOff.isHidden = !offered
        if offered {
            planOff.frame = NSRect(x: margin, y: y, width: inner, height: A2NoticeCard.height)
            y = planOff.frame.maxY + gap
        }
        let visible = plansOn ? Array(planCards.prefix(plans.count)) : []
        if !visible.isEmpty {
            let windows = plans.prefix(visible.count).map(\.windows.count).max() ?? 2
            y = grid(visible, top: y, width: width, columns: 2, height: PlanCard.height + CGFloat(max(0, windows - 2)) * 40) + gap
        }
        // The list runs to the window's bottom margin when its rows fit, as in the mockup.
        let natural = list.naturalHeight + A2.padTop * 2
        let room = scroll.contentSize.height - Self.topInset - margin - y
        let height = room >= natural && room <= natural * 1.4 ? room : natural
        listCard.frame = NSRect(x: margin, y: y, width: inner, height: height)
        list.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner - A2.padSide * 2, height: height - A2.padTop * 2)
        return listCard.frame.maxY + margin
    }

    override func update(table: ProcessTable) {
        if !findBusy {
            findBusy = true
            let finder = self.finder
            DispatchQueue.global(qos: .utility).async {
                let found = finder.find(table)
                DispatchQueue.main.async { [weak self] in
                    self?.findBusy = false
                    self?.show(found, table: table)
                }
            }
        }
        guard plansOn else { return }
        // Limits are small local files that change after each reply: once a minute.
        if Date().timeIntervalSince(plansAt) > 60, !plansBusy {
            plansBusy = true
            let helper = PlanLimitsSetup.helper
            DispatchQueue.global(qos: .utility).async {
                let result = PlanUsageReader.readAll()
                let unconnected = helper.map { ClaudeStatusLine.unconnected(helper: $0) } ?? []
                DispatchQueue.main.async { [weak self] in
                    self?.plansBusy = false
                    self?.plansAt = Date()
                    self?.unconnected = unconnected
                    self?.show(result)
                }
            }
        }
        // The token count reads only what the session logs gained since last time.
        if Date().timeIntervalSince(tokensAt) > 30, !tokensBusy {
            tokensBusy = true
            let counter = self.counter
            DispatchQueue.global(qos: .utility).async {
                let total = counter.today()
                DispatchQueue.main.async { [weak self] in
                    self?.tokensBusy = false
                    self?.tokensAt = Date()
                    self?.tokens.show(Self.tokenText(total))
                    self?.tokens.set(sub: "Claude Code, every account")
                }
            }
        }
    }

    /// "4.2M" as 4.2 with a quieter M.
    private static func tokenText(_ count: Int) -> String {
        let text = Format.count(count)
        guard let last = text.last, last.isLetter else { return text }
        return String(text.dropLast()) + " " + String(last)
    }

    private func show(_ found: [CodingAgent], table: ProcessTable) {
        let machine = delegate.settings.cpuOfMachine
        let processes = found.reduce(0) { $0 + $1.processes.count }
        running.figure.show("\(found.count)")
        let kinds = Dictionary(grouping: found, by: \.kind).sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
            .map { "\($0.value.count) \($0.key)" }
        running.set(sub: kinds.prefix(2).joined(separator: " · "))
        cpu.show(Style.appCPU(found.reduce(0) { $0 + $1.cpu }, machine: machine, coreCount: table.coreCount))
        if let busiest = found.max(by: { $0.cpu < $1.cpu }) {
            cpu.set(facts: [.init(label: "Most in", value: Self.folderName(busiest))])
        } else {
            cpu.set(sub: "")
        }
        memory.show(Format.memory(found.reduce(0) { $0 + $1.memory }))
        memory.set(sub: "\(processes) processes between them")
        caption.text = Toolbar.subtitle(found.isEmpty ? "Nothing running" : "\(found.count) running · \(processes) processes")
        list.heading = ("Running", found.isEmpty ? "" : "\(found.count)")
        let home = NSHomeDirectory()
        let now = Date()
        let peak = max(found.map(\.cpu).max() ?? 0, 0.0001)
        let appearance = view.effectiveAppearance
        let before = list.rows.count
        list.rows = found.sorted { $0.cpu > $1.cpu }.map { agent in
            var detail = agent.folder.flatMap { $0 == home ? nil : $0.replacingOccurrences(of: home, with: "~") } ?? ""
            if let start = agent.startDate { detail += (detail.isEmpty ? "" : " · ") + Format.duration(now.timeIntervalSince(start)) }
            detail += (detail.isEmpty ? "" : " · ") + "\(agent.processes.count) proc"
            let look = AgentLook.mark(agent.kind, size: 28, appearance: appearance)
            return A2Table.Row(id: "\(agent.pid)", icon: look.icon, glyph: look.glyph, glyphTint: look.tint,
                               name: agent.kind + (agent.host.map { $0 != agent.kind ? " in \($0)" : "" } ?? ""),
                               note: "\(agent.pid)", detail: detail,
                               cells: ["", Style.appCPU(agent.cpu, machine: machine, coreCount: table.coreCount), Format.memory(agent.memory)],
                               fraction: agent.cpu / peak)
        }
        if list.rows.count != before { relayout() }
    }

    private func show(_ result: [PlanUsage]) {
        plans = result
        while planCards.count < result.count {
            let card = PlanCard()
            canvas.addSubview(card)
            planCards.append(card)
        }
        let now = Date()
        for (index, card) in planCards.enumerated() {
            card.isHidden = index >= result.count
            if index < result.count { card.show(result[index], now: now) }
        }
        if result.isEmpty, unconnected.isEmpty { caption.text = Toolbar.subtitle("No Claude Code or Codex limits on this Mac yet") }
        showPlanState()
        relayout()
    }

    private func showPlanState() {
        if !plansOn {
            tokens.figure.show("Off")
            tokens.set(sub: "Turn on with plan limits")
            planOff.row.set(symbol: "gauge.with.needle", tint: tint, title: "Plan limits", detail: PlanLimitsSetup.offDetail,
                            button: "Show Limits") { [weak self] in self?.turnOnPlans() }
        } else if !unconnected.isEmpty {
            let count = unconnected.count
            planOff.row.set(symbol: "gauge.with.needle", tint: tint, title: "Claude Code limits",
                            detail: count == 1 ? "One Claude Code setup does not send its limits to Wisp yet"
                                : "\(count) Claude Code setups do not send their limits to Wisp yet",
                            button: "Connect") { [weak self] in self?.turnOnPlans() }
        }
    }

    private static func folderName(_ agent: CodingAgent) -> String {
        guard let folder = agent.folder, folder != NSHomeDirectory() else { return agent.kind }
        return (folder as NSString).lastPathComponent
    }

    private func turnOnPlans() {
        delegate.change { $0.planUsage = true }
        PlanLimitsSetup.apply(on: true)
        unconnected = []
        showPlanState()
        plansAt = .distantPast
        tokensAt = .distantPast
        tokens.figure.show("…")
        tokens.set(sub: "Counting")
        relayout()
    }
}

/// Turning plan limits on adds Wisp to each Claude Code status line; turning them off
/// puts the old status lines back. Codex needs nothing: it writes its limits to its logs.
@MainActor
enum PlanLimitsSetup {
    static let offDetail = "Adds Wisp to Claude Code's status line and reads Codex's logs. No sign-ins, nothing sent"

    /// The `wisp` helper inside this copy of the app; nil when running outside a bundle.
    static var helper: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wisp").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func apply(on: Bool) {
        if on {
            guard let helper else { return }
            ClaudeStatusLine.connectAll(helper: helper)
        } else {
            ClaudeStatusLine.disconnectAll()
        }
    }
}
