import AppKit
import WispCore

/// The AI usage item's dropdown: a card per account with its name and plan, then a line
/// per limit with a slim bar, the share used and when it resets. Hovering a limit shows
/// how it is going (see `PlanCard.pace`); hovering the update time shows the account.
@MainActor
final class UsageDropdown: SoftDropdown {
    /// Room for three Claude and two Codex accounts with one to spare.
    private static let limit = 6
    private var cards: [SoftCard] = []
    private var allHidden = false

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.usage.title, page: .agents)
        plate.title = "Accounts"
        onEmpty = { [weak self] in
            guard let self else { return }
            if self.allHidden { self.showAll() } else { self.delegate.showSettings(section: .assistants) }
        }
        delegate.plans.observe { [weak self] plans in self?.show(plans) }
        show(delegate.plans.plans)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        delegate.plans.refresh(maxAge: 20, liveAge: 60)
        show(delegate.plans.plans)
    }

    /// Once a sample: reset times count down, and old figures are read again.
    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        delegate.plans.refresh()
        show(delegate.plans.plans)
    }

    func show(_ plans: [PlanUsage]) {
        let now = Date()
        let hidden = Set(delegate.settings.hiddenUsageAccounts)
        allHidden = !plans.isEmpty && plans.allSatisfy { hidden.contains($0.id) }
        let visible = plans.filter { !hidden.contains($0.id) }
        // Folders still waiting for their first figures only show when nothing has any;
        // they would otherwise push real accounts past the limit.
        let withFigures = visible.filter { $0.problem == nil }
        let shown = Array((withFigures.isEmpty ? visible : withFigures).prefix(Self.limit))

        while cards.count < shown.count {
            let card = SoftCard()
            addSubview(card)
            cards.append(card)
        }
        for (index, card) in cards.enumerated() {
            card.isHidden = index >= shown.count
            guard index < shown.count else { continue }
            let usage = shown[index]
            let updated = PlanCard.updated(usage, now: now)
            card.show(mark: .agent(usage.provider), title: usage.label ?? usage.provider,
                      meta: updated.isEmpty ? usage.account : updated,
                      metaHover: updated.isEmpty || usage.account.isEmpty ? nil : usage.account,
                      tag: usage.plan, note: usage.problem, lines: usage.windows.map { window in
                          let pace = PlanCard.pace(window, now: now)
                          return SoftCard.Line(label: Self.label(window.name), fraction: window.used,
                                               color: PlanCard.meterColor(window, short: pace.short), figure: Format.percent(window.used),
                                               detail: pace.text, hover: pace.resets, warns: pace.short)
                      })
        }

        head.status = Self.status(shown, total: visible.count)
        let hiddenCount = plans.filter { hidden.contains($0.id) }.count
        let count = shown.count == 1 ? "1 account" : "\(shown.count) accounts"
        plate.count = shown.isEmpty ? "" : hiddenCount == 0 ? count : "\(count), \(hiddenCount) hidden"
        plate.footer = shown.contains { $0.windows.contains { $0.resets != nil } } ? "Hover a limit to see its pace." : ""
        if shown.isEmpty {
            showEmpty(allHidden ? "Every account is hidden." : "No plan figures yet. Turn on plan limits in Settings.",
                      button: allHidden ? "Show All" : "Open Settings")
        } else {
            showEmpty(nil)
        }
        arrange(Array(cards.prefix(shown.count)))
    }

    /// The limit's name for the label column: "5-hour", "This week", or the models an
    /// Antigravity pool covers ("Gemini", "Claude, GPT", "Gemini, week").
    static func label(_ name: String) -> String {
        if name == "5-hour session" { return "5-hour" }
        let models = { (text: Substring) in text.replacingOccurrences(of: " and ", with: ", ").replacingOccurrences(of: "-OSS", with: "") }
        if name.hasPrefix("5-hour ") { return models(name.dropFirst(7)) }
        if name.hasSuffix(" this week"), name != "This week" { return models(name.dropLast(10)) + ", week" }
        return name
    }

    /// The dot and line under the title: how many accounts, and the one nearest a limit.
    private static func status(_ plans: [PlanUsage], total: Int) -> Head.Status {
        let counted = plans.filter { $0.problem == nil && !$0.windows.isEmpty }
        guard let (usage, window) = counted.flatMap({ plan in plan.windows.map { (plan, $0) } }).max(by: { $0.1.used < $1.1.used }) else {
            return .init(dot: A2Dev.quiet, lines: [total == 0 ? "No figures yet" : "Waiting for figures"])
        }
        let accounts = counted.count == 1 ? "1 account" : "\(counted.count) accounts"
        guard window.used >= 0.6 else {
            return .init(dot: A2Dev.live, lines: [counted.count == 1 ? "1 account, under 60%" : "All \(counted.count) accounts under 60%", "All under 60%"])
        }
        let name = usage.label ?? usage.provider
        let percent = Format.percent(window.used)
        let lower = window.name.lowercased()
        let when = lower.contains("week") ? " this week" : lower.hasPrefix("5-hour") ? " this session" : ""
        let dot = window.used >= 0.9 ? A2.bad : A2Dev.idle
        return .init(dot: dot, lines: ["\(accounts) · \(name) at \(percent)\(when)", "\(name) at \(percent)\(when)", "\(name) at \(percent)"])
    }

    // MARK: Choosing accounts

    override func menuItems() -> [NSMenuItem] {
        guard !delegate.plans.plans.isEmpty else { return [] }
        let hidden = Set(delegate.settings.hiddenUsageAccounts)
        var items: [NSMenuItem] = [.sectionHeader(title: "Accounts")]
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
        return items
    }

    @objc override func openSettings() { delegate.showSettings(section: .assistants) }

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
