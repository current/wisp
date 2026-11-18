import AppKit
import WispCore

/// AI plan limits: each account with its windows as tick meters, how much is used and
/// when each resets. The same rows as the Coding Agents page, at the dashboard's width.
final class UsageBlock: DashboardBlockView {
    private final class Account {
        let header = PlanCard.Header()
        var rows: [PlanCard.WindowRow] = []
        let rule = CardView()
    }

    private var accounts: [Account] = []
    private var shownPlans: [PlanUsage] = []
    private let empty = TextLine()
    private let settingsButton = CapsuleButton()
    private static let headerHeight: CGFloat = 46
    private static let rowHeight: CGFloat = 29
    private static let rowGap: CGFloat = 8
    private static let accountGap: CGFloat = 16
    private static let limit = 4

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        empty.alignment = .center
        empty.text = NSAttributedString(string: "No plan figures yet. Turn on plan limits in Settings to read Claude Code's.",
                                        attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary])
        settingsButton.title = "Open Settings"
        settingsButton.onPress = { [weak self] in self?.delegate.showSettings(section: .assistants) }
        addSubview(empty)
        addSubview(settingsButton)
        delegate.plans.observe { [weak self] plans in self?.show(plans) }
        show(delegate.plans.plans)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var height: CGFloat {
        guard !shownPlans.isEmpty else { return 44 + 70 }
        var total: CGFloat = 44
        for plan in shownPlans {
            total += Self.headerHeight + CGFloat(plan.windows.count) * (Self.rowHeight + Self.rowGap) + Self.accountGap
        }
        return total - Self.accountGap + 12
    }

    override func layout() {
        super.layout()
        empty.frame = NSRect(x: 16, y: 54, width: content, height: 16)
        let buttonWidth = settingsButton.naturalWidth
        settingsButton.frame = NSRect(x: (bounds.width - buttonWidth) / 2, y: 78, width: buttonWidth, height: 26)
        var y: CGFloat = 44
        for (index, account) in accounts.enumerated() where index < shownPlans.count {
            account.header.frame = NSRect(x: 16, y: y, width: content, height: 40)
            y += Self.headerHeight
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
        let shown = Array(plans.prefix(Self.limit))
        let resized = shown.map(\.windows.count) != shownPlans.map(\.windows.count)
        shownPlans = shown
        while accounts.count < shown.count {
            let account = Account()
            account.rule.fill = Theme.cardBorder
            account.rule.stroke = .clear
            account.rule.radius = 0
            for view in [account.header, account.rule] as [NSView] { addSubview(view) }
            accounts.append(account)
        }
        for (index, account) in accounts.enumerated() {
            let visible = index < shown.count
            account.header.isHidden = !visible
            account.rule.isHidden = !visible
            account.rows.forEach { $0.isHidden = !visible }
            guard visible else { continue }
            let usage = shown[index]
            account.header.provider = usage.provider
            account.header.title = usage.label
            account.header.account = usage.account + PlanCard.age(usage.updated, now: now)
            account.header.plan = usage.plan
            account.header.problem = usage.problem
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
                row.meter.fraction = window.used
                row.meter.color = window.used >= 0.9 ? A2.bad : (pace.short ? A2.power : A2.cpu)
                row.needsDisplay = true
            }
        }
        empty.isHidden = !shown.isEmpty
        settingsButton.isHidden = !shown.isEmpty
        needsLayout = true
        if resized { onResize?() }
    }
}
