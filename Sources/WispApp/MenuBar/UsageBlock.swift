import AppKit
import WispCore

/// AI plan limits as the AI usage dropdown shows them: a card per account with its mark,
/// name and plan, then a line per limit with a slim bar and pace mark, the share used and
/// when it resets (hovering shows how it is going). Accounts are chosen in the
/// dashboard's ⋯ menu.
final class UsageBlock: DashboardBlockView {
    private var accounts: [SoftCard] = []
    private var shownCount = 0
    /// Every account with figures is hidden by choice, so the empty state offers Show All.
    private var allHidden = false
    /// Room for three Claude and two Codex accounts with one to spare.
    private static let limit = 6

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        delegate.plans.observe { [weak self] plans in self?.show(plans) }
        show(delegate.plans.plans)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var cards: [SoftCard] { shownCount == 0 ? [card] : Array(accounts.prefix(shownCount)) }

    override var height: CGFloat {
        guard shownCount > 0 else { return super.height }
        return accounts.prefix(shownCount).map(\.height).reduce(0, +) + CGFloat(shownCount - 1) * SoftDropdown.cardGap
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for card in accounts.prefix(shownCount) {
            card.frame = NSRect(x: 0, y: y, width: bounds.width, height: card.height)
            y += card.height + SoftDropdown.cardGap
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
        let visible = plans.filter { !hidden.contains($0.id) }
        // Folders still waiting for their first figures only show when nothing has any;
        // they would otherwise push real accounts past the limit.
        let withFigures = visible.filter { $0.problem == nil }
        let shown = Array((withFigures.isEmpty ? visible : withFigures).prefix(Self.limit))
        while accounts.count < shown.count {
            let card = SoftCard()
            card.isHidden = true
            addSubview(card)
            accounts.append(card)
        }
        for (index, card) in accounts.enumerated() {
            card.isHidden = index >= shown.count
            guard index < shown.count else { continue }
            let usage = shown[index]
            let updated = PlanCard.updated(usage, now: now)
            card.show(mark: .agent(usage.provider), title: usage.label ?? usage.provider,
                      meta: updated.isEmpty ? usage.account : updated,
                      metaHover: updated.isEmpty || usage.account.isEmpty ? nil : usage.account,
                      tag: usage.plan, note: usage.problem, lines: usage.windows.map { window in
                          let pace = PlanCard.pace(window, now: now)
                          return SoftCard.Line(label: UsageDropdown.label(window.name), fraction: window.used,
                                               color: PlanCard.meterColor(window, short: pace.short), figure: Format.percent(window.used),
                                               detail: PlanCard.shortDetail(pace.text), hover: pace.resets ?? pace.text, warns: pace.short,
                                               pace: PlanCard.elapsed(window, now: now))
                      })
        }
        shownCount = shown.count
        card.isHidden = !shown.isEmpty
        if shown.isEmpty {
            card.show(mark: .glyph("sparkles", A2.labelTint(.agents)), title: "Plan limits", meta: allHidden ? "All hidden" : "", lines: [])
            showMessage(allHidden ? "Every account is hidden." : "No plan figures yet. Turn on plan limits in Settings.",
                        button: allHidden ? "Show All" : "Open Settings") { [weak self] in
                guard let self else { return }
                if self.allHidden { self.showAll() } else { self.delegate.showSettings(section: .assistants) }
            }
        } else {
            showMessage(nil)
        }
        needsLayout = true
        refit()
    }

    // MARK: Choosing accounts

    /// The ⋯ menu's items for this block: each account, Show All, and Antigravity's limits.
    func menuItems() -> [NSMenuItem] {
        guard !delegate.plans.plans.isEmpty else { return [] }
        let hidden = Set(delegate.settings.hiddenUsageAccounts)
        var items: [NSMenuItem] = [.sectionHeader(title: "Plan limits")]
        for usage in delegate.plans.plans {
            let item = NSMenuItem(title: PlanUsageFeed.name(usage), action: #selector(toggleAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = usage.id
            item.state = hidden.contains(usage.id) ? .off : .on
            items.append(item)
        }
        let all = NSMenuItem(title: "Show All", action: #selector(showAll), keyEquivalent: "")
        all.target = self
        all.isEnabled = !hidden.isEmpty
        items.append(all)
        if delegate.plans.plans.contains(where: { $0.provider == "Antigravity" }) {
            items.append(.separator())
            items += UsageDropdown.antigravityItems(delegate: delegate, target: self, action: #selector(toggleLimit(_:)))
        }
        return items
    }

    @objc private func toggleLimit(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        UsageDropdown.toggleAntigravity(name, delegate: delegate)
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
