import AppKit
import WispCore

/// AI plan limits: each account with its windows as tick meters, how much is used and
/// when each resets. The same rows as the Coding Agents page, at the dashboard's width.
final class UsageBlock: DashboardBlockView {
    private final class Account {
        let header = PlanCard.Header()
        let note = TextLine()
        var rows: [PlanCard.WindowRow] = []
        let rule = CardView()
    }

    private var accounts: [Account] = []
    private var shownPlans: [PlanUsage] = []
    /// Every account with figures is hidden by choice, so the empty state offers Show All.
    private var allHidden = false
    private let empty = TextLine()
    private let settingsButton = CapsuleButton()
    private lazy var accountsButton = SymbolButton(symbol: "line.3.horizontal.decrease", label: "Choose Accounts",
                                                   target: self, action: #selector(chooseAccounts(_:)))
    private static let headerHeight: CGFloat = PlanCard.Header.height + 10
    private static let rowHeight: CGFloat = 29
    private static let rowGap: CGFloat = 8
    private static let noteHeight: CGFloat = 16
    private static let accountGap: CGFloat = 16
    /// Room for three Claude and two Codex accounts with one to spare.
    private static let limit = 6

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        empty.alignment = .center
        settingsButton.onPress = { [weak self] in
            guard let self else { return }
            if self.allHidden { self.showAll() } else { self.delegate.showSettings(section: .assistants) }
        }
        addSubview(empty)
        addSubview(settingsButton)
        addSubview(accountsButton)
        delegate.plans.observe { [weak self] plans in self?.show(plans) }
        show(delegate.plans.plans)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat {
        guard !shownPlans.isEmpty else { return 44 + 70 }
        var total: CGFloat = 44
        for plan in shownPlans {
            total += Self.headerHeight + CGFloat(plan.windows.count) * (Self.rowHeight + Self.rowGap) + Self.accountGap
            if plan.problem != nil { total += Self.noteHeight + Self.rowGap }
        }
        return total - Self.accountGap + 12
    }

    override func layout() {
        super.layout()
        placeRight(accountsButton, width: 26, height: 26)
        empty.frame = NSRect(x: 16, y: 54, width: content, height: 16)
        let buttonWidth = settingsButton.naturalWidth
        settingsButton.frame = NSRect(x: (bounds.width - buttonWidth) / 2, y: 78, width: buttonWidth, height: 26)
        var y: CGFloat = 44
        for (index, account) in accounts.enumerated() where index < shownPlans.count {
            account.header.frame = NSRect(x: 16, y: y, width: content, height: PlanCard.Header.height)
            y += Self.headerHeight
            if !account.note.isHidden {
                account.note.frame = NSRect(x: 16, y: y, width: content, height: Self.noteHeight)
                y += Self.noteHeight + Self.rowGap
            }
            for row in account.rows where !row.isHidden {
                row.frame = NSRect(x: 16, y: y, width: content, height: Self.rowHeight)
                y += Self.rowHeight + Self.rowGap
            }
            account.rule.isHidden = index == shownPlans.count - 1
            account.rule.frame = NSRect(x: 16, y: y + Self.accountGap / 2 - 4, width: content, height: 0.5)
            y += Self.accountGap
        }
    }

    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        // Reset times count down between reads, and figures older than a minute are read again.
        delegate.plans.refresh()
        show(delegate.plans.plans)
    }

    private func show(_ plans: [PlanUsage]) {
        let now = Date()
        let hidden = Set(delegate.settings.hiddenUsageAccounts)
        allHidden = !plans.isEmpty && plans.allSatisfy { hidden.contains($0.id) }
        let plans = plans.filter { !hidden.contains($0.id) }
        // Folders still waiting for their first figures only show when nothing has any;
        // they would otherwise push real accounts past the limit.
        let withFigures = plans.filter { $0.problem == nil }
        let shown = Array((withFigures.isEmpty ? plans : withFigures).prefix(Self.limit))
        let resized = shown.map { $0.windows.count * 2 + ($0.problem == nil ? 0 : 1) } != shownPlans.map { $0.windows.count * 2 + ($0.problem == nil ? 0 : 1) }
        shownPlans = shown
        while accounts.count < shown.count {
            let account = Account()
            account.rule.fill = Theme.cardBorder
            account.rule.stroke = .clear
            account.rule.radius = 0
            for view in [account.header, account.note, account.rule] as [NSView] { addSubview(view) }
            accounts.append(account)
        }
        for (index, account) in accounts.enumerated() {
            let visible = index < shown.count
            account.header.isHidden = !visible
            if !visible { account.note.isHidden = true }
            account.rule.isHidden = !visible
            account.rows.forEach { $0.isHidden = !visible }
            guard visible else { continue }
            let usage = shown[index]
            account.header.provider = usage.provider
            account.header.title = usage.label
            account.header.updated = PlanCard.updated(usage, now: now)
            account.header.account = usage.account
            account.header.plan = usage.plan
            account.note.text = PlanCard.problemText(usage.problem ?? "")
            account.note.isHidden = usage.problem == nil
            account.header.needsDisplay = true
            while account.rows.count < usage.windows.count {
                let row = PlanCard.WindowRow()
                addSubview(row)
                account.rows.append(row)
            }
            for (rowIndex, row) in account.rows.enumerated() {
                row.isHidden = rowIndex >= usage.windows.count
                guard rowIndex < usage.windows.count else { continue }
                let window = usage.windows[rowIndex]
                let pace = PlanCard.pace(window, now: now)
                row.name = window.name
                row.used = window.used
                row.detail = pace.text
                row.short = pace.short
                row.resets = pace.resets
                row.meter.fraction = window.used
                row.meter.color = PlanCard.meterColor(window, short: pace.short)
                row.needsDisplay = true
            }
        }
        empty.text = NSAttributedString(string: allHidden ? "Every account is hidden."
                                            : "No plan figures yet. Turn on plan limits in Settings to read Claude Code's.",
                                        attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary])
        settingsButton.title = allHidden ? "Show All" : "Open Settings"
        empty.isHidden = !shown.isEmpty
        settingsButton.isHidden = !shown.isEmpty
        accountsButton.isHidden = delegate.plans.plans.isEmpty
        needsLayout = true
        if resized { onResize?() }
    }

    // MARK: Choosing accounts

    @objc private func chooseAccounts(_ sender: NSButton) {
        let menu = NSMenu()
        let hidden = Set(delegate.settings.hiddenUsageAccounts)
        for usage in delegate.plans.plans {
            let item = NSMenuItem(title: PlanUsageFeed.name(usage), action: #selector(toggleAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = usage.id
            item.state = hidden.contains(usage.id) ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = menu.addItem(withTitle: "Show All", action: #selector(showAll), keyEquivalent: "")
        all.target = self
        all.isEnabled = !hidden.isEmpty
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleAccount(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        delegate.change { settings in
            if let index = settings.hiddenUsageAccounts.firstIndex(of: id) {
                settings.hiddenUsageAccounts.remove(at: index)
            } else {
                settings.hiddenUsageAccounts.append(id)
            }
        }
        show(delegate.plans.plans)
    }

    @objc private func showAll() {
        delegate.change { $0.hiddenUsageAccounts = [] }
        show(delegate.plans.plans)
    }
}
