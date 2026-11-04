import AppKit
import WispCore

/// One account's plan limits: each window as a tick meter with when it resets
/// and whether the current pace runs it out first.
@MainActor
final class PlanCard: CardView {
    final class WindowRow: DrawnView {
        var name = ""
        var used: Double = 0
        var detail = ""
        var tone: NSColor = Theme.accent
        let meter = TickMeter()

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(meter)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            meter.frame = NSRect(x: 0, y: 20, width: bounds.width - 52, height: 8)
        }

        override func draw(_ dirtyRect: NSRect) {
            Theme.caption(name, color: Theme.inkSecondary).draw(at: NSPoint(x: 0, y: 0))
            let detailText = Theme.caption(detail, size: 9.5)
            detailText.draw(at: NSPoint(x: bounds.width - 52 - detailText.size().width, y: 0.5))
            let percent = NSAttributedString(string: Format.percent(used), attributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink])
            percent.draw(at: NSPoint(x: bounds.width - percent.size().width, y: 14))
        }
    }

    static let rowHeight: CGFloat = 42
    let name = TextLine()
    let account = TextLine()
    let plan = Pill()
    let problem = TextLine()
    private(set) var rows: [WindowRow] = []

    override init() {
        super.init()
        plan.tone = .neutral
        for view in [name, account, plan, problem] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func height(windows: Int, problem: Bool) -> CGFloat {
        66 + CGFloat(windows) * rowHeight + (problem ? 22 : 0)
    }

    func show(_ usage: PlanUsage, now: Date) {
        let mark = NSTextAttachment()
        mark.image = AgentMark.image(usage.provider, size: 16, appearance: NSApp.effectiveAppearance)
        mark.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let title = NSMutableAttributedString(attachment: mark)
        title.append(NSAttributedString(string: "  " + usage.provider, attributes: [.font: Theme.sans(14, .medium), .foregroundColor: Theme.ink]))
        name.text = title
        account.text = Theme.caption(usage.account + Self.age(usage.updated, now: now), size: 9.5)
        plan.text = usage.plan ?? ""
        plan.isHidden = usage.plan == nil
        problem.text = Theme.caption(usage.problem ?? "", color: Theme.warn, size: 9.5)
        problem.isHidden = usage.problem == nil
        while rows.count < usage.windows.count {
            let row = WindowRow()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= usage.windows.count
            guard index < usage.windows.count else { continue }
            let window = usage.windows[index]
            row.name = window.name
            row.used = window.used
            let pace = Self.pace(window, now: now)
            row.detail = pace.text
            row.meter.fraction = window.used
            row.meter.color = window.used >= 0.9 ? Theme.bad : (pace.short ? Theme.warn : Theme.accent)
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
        let width = bounds.width - 40
        let planWidth = plan.isHidden ? 0 : plan.naturalWidth
        name.frame = NSRect(x: 20, y: 16, width: width - planWidth - 8, height: 20)
        plan.frame = NSRect(x: 20 + width - planWidth, y: 17, width: planWidth, height: 18)
        account.frame = NSRect(x: 20, y: 38, width: width, height: 14)
        var y: CGFloat = 62
        if !problem.isHidden {
            problem.frame = NSRect(x: 20, y: y, width: width, height: 14)
            y += 22
        }
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: 20, y: y, width: width, height: 30)
            y += Self.rowHeight
        }
    }
}

/// Coding agents: what is running and what it costs the Mac, plus, when the
/// owner turns it on, each AI plan's limits and the tokens used today.
@MainActor
final class AgentsPage: CardPage {
    override var pageTint: NSColor { PageID.agents.tint }
    private let (titleLine, caption): (TextLine, TextLine)
    private let running = Tile("Agents running"), cpu = Tile("CPU"), memory = Tile("Memory"), tokens = Tile("Tokens today")
    private let planOff = CardView()
    private let planOffTitle = TextLine()
    private let planOffDetail = TextLine()
    private lazy var planButton = ActionButton(title: "Show Limits", target: self, action: #selector(turnOnPlans))
    /// Claude folders whose status line does not send limits to Wisp yet; checked with the limits.
    private var unconnected: [String] = []
    private let plansTitle = TextLine()
    private var planCards: [PlanCard] = []
    private var plans: [PlanUsage] = []
    private var plansAt = Date.distantPast
    private var plansBusy = false
    private let list = ListCard()
    private let finder = AgentFinder()
    private let counter = TokenCounter()
    private var tokensAt = Date.distantPast
    private var tokensBusy = false
    private var findBusy = false
    private var agents: [CodingAgent] = []
    private let onSelect: (Selection?) -> Void

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        let title = TextLine(Toolbar.title("Coding Agents"))
        (titleLine, caption) = (title, TextLine())
        self.onSelect = onSelect
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var plansOn: Bool { delegate.settings.planUsage }
    override var toolbarHeading: (NSView, NSView)? { (titleLine, caption) }

    override func loadView() {
        super.loadView()
        for view in [running, cpu, memory, tokens, planOff, plansTitle, list] as [NSView] { canvas.addSubview(view) }
        for view in [planOffTitle, planOffDetail, planButton] as [NSView] { planOff.addSubview(view) }
        planOffTitle.text = NSAttributedString(string: "Plan limits", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink])
        planOffDetail.text = Theme.caption(PlanLimitsSetup.offDetail, color: Theme.inkSecondary)
        plansTitle.text = cardTitle("Plan limits", "")
        list.title.text = cardTitle("Running", "")
        list.empty.text = Theme.caption("No coding agents running. Wisp knows Claude Code, Codex, Cursor Agent, Gemini CLI, Aider, OpenCode and more")
        caption.text = Theme.caption("Looking for agents…")
        running.figure.format = { (String(format: "%.0f", $0), "") }
        tokens.set(text: "–")
        for tile in [running, cpu, memory, tokens] { tile.tint = PageID.agents.tint }
        showPlanState()
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = grid([running, cpu, memory, tokens], top: margin, width: width, columns: 4, height: 104) + gap
        let offered = !plansOn || !unconnected.isEmpty
        if offered {
            planOff.isHidden = false
            planOff.frame = NSRect(x: margin, y: y, width: inner, height: 76)
            planOffTitle.frame = NSRect(x: 20, y: 16, width: inner - 180, height: 22)
            planOffDetail.frame = NSRect(x: 20, y: 42, width: inner - 180, height: 14)
            let size = planButton.intrinsicContentSize
            planButton.frame = NSRect(x: inner - 20 - size.width, y: (76 - size.height) / 2, width: size.width, height: size.height)
            y = planOff.frame.maxY + gap
        } else {
            planOff.isHidden = true
        }
        if plansOn {
            plansTitle.isHidden = planCards.isEmpty
            if !planCards.isEmpty {
                plansTitle.frame = NSRect(x: margin + 2, y: y + 6, width: inner, height: 20)
                y += 34
                let visible = planCards.prefix(plans.count)
                let height = visible.indices.map { PlanCard.height(windows: plans[$0].windows.count, problem: plans[$0].problem != nil) }.max() ?? 0
                y = grid(Array(visible), top: y, width: width, columns: 2, height: height) + gap
            }
        } else {
            plansTitle.isHidden = true
        }
        list.frame = NSRect(x: margin, y: y, width: inner, height: list.wantedHeight)
        return list.frame.maxY + margin
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
                    self?.tokens.set(text: Format.count(total))
                    self?.tokens.set(note: "Claude Code, every account")
                }
            }
        }
    }

    private func show(_ found: [CodingAgent], table: ProcessTable) {
        agents = found
        let machine = delegate.settings.cpuOfMachine
        let processes = found.reduce(0) { $0 + $1.processes.count }
        running.figure.set(Double(found.count))
        let kinds = Dictionary(grouping: found, by: \.kind).sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
            .map { "\($0.value.count) \($0.key)" }
        running.set(note: kinds.prefix(2).joined(separator: " · "))
        let totalCPU = found.reduce(0) { $0 + $1.cpu }
        cpu.set(text: Style.appCPU(totalCPU, machine: machine, coreCount: table.coreCount))
        cpu.set(note: found.max { $0.cpu < $1.cpu }.map { "Most in \(Self.folderName($0))" } ?? "")
        let (value, unit) = DashboardView.split(Format.memory(found.reduce(0) { $0 + $1.memory }))
        memory.set(text: value, unit: unit)
        memory.set(note: "\(processes) processes between them")
        caption.text = Theme.caption(found.isEmpty ? "Nothing running" : "\(found.count) running · \(processes) processes")
        list.title.text = cardTitle("Running", found.isEmpty ? "" : "\(found.count)")
        let home = NSHomeDirectory()
        let now = Date()
        let peak = max(found.map(\.cpu).max() ?? 0, 0.0001)
        let sorted = found.sorted { $0.cpu > $1.cpu }
        list.set(count: sorted.count) { [weak self] row, index in
            let agent = sorted[index]
            row.icon = AgentMark.image(agent.kind, size: 18, appearance: NSApp.effectiveAppearance)
            row.name = agent.kind + (agent.host.map { $0 != agent.kind ? " in \($0)" : "" } ?? "") + "  \(agent.pid)"
            var note = agent.folder.flatMap { $0 == home ? nil : $0.replacingOccurrences(of: home, with: "~") } ?? ""
            if let start = agent.startDate { note += (note.isEmpty ? "" : " · ") + Format.duration(now.timeIntervalSince(start)) }
            note += " · \(agent.processes.count) proc"
            row.note = note
            row.value = Style.appCPU(agent.cpu, machine: machine, coreCount: table.coreCount) + "  " + Format.memory(agent.memory)
            row.fraction = agent.cpu / peak
            row.onClick = { self?.onSelect(.process(agent.pid)) }
        }
        relayout()
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
        plansTitle.text = cardTitle("Plan limits", result.isEmpty ? "" : "\(result.count)")
        if result.isEmpty, unconnected.isEmpty { caption.text = Theme.caption("No Claude Code or Codex limits on this Mac yet") }
        showPlanState()
        relayout()
    }

    private func showPlanState() {
        if !plansOn {
            tokens.set(text: "Off")
            tokens.set(note: "Turn on with plan limits")
            planOffTitle.text = NSAttributedString(string: "Plan limits", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink])
            planOffDetail.text = Theme.caption(PlanLimitsSetup.offDetail, color: Theme.inkSecondary)
            planButton.title = "Show Limits"
        } else if !unconnected.isEmpty {
            let count = unconnected.count
            planOffTitle.text = NSAttributedString(string: "Claude Code limits", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink])
            planOffDetail.text = Theme.caption(count == 1 ? "One Claude Code setup does not send its limits to Wisp yet"
                                                          : "\(count) Claude Code setups do not send their limits to Wisp yet", color: Theme.inkSecondary)
            planButton.title = "Connect"
        }
    }

    private static func folderName(_ agent: CodingAgent) -> String {
        guard let folder = agent.folder, folder != NSHomeDirectory() else { return agent.kind }
        return (folder as NSString).lastPathComponent
    }

    @objc private func turnOnPlans() {
        delegate.change { $0.planUsage = true }
        PlanLimitsSetup.apply(on: true)
        unconnected = []
        showPlanState()
        plansAt = .distantPast
        tokensAt = .distantPast
        tokens.set(text: "…")
        tokens.set(note: "Counting")
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
