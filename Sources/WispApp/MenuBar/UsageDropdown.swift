import AppKit
import WispCore

/// The AI usage item's dropdown: first the limit closest to running out, with a chart of
/// where it is heading by its reset, then a card per account with its name and plan and a
/// line per limit with a slim bar, a pace mark, the share used and when it resets.
/// Hovering a limit shows how it is going (see `PlanCard.pace`); hovering the update
/// time shows the account.
@MainActor
final class UsageDropdown: SoftDropdown {
    /// Room for three Claude and two Codex accounts with one to spare.
    private static let limit = 6
    private var cards: [SoftCard] = []
    private var allHidden = false
    private let outlook = SoftCard()
    private let pace = PaceChart()

    init(delegate: AppDelegate) {
        super.init(delegate: delegate, title: MenuMetric.usage.title, page: .agents)
        plate.title = "Accounts"
        pace.clip = SoftCard.chartClip
        pace.padX = SoftCard.padX + 4
        pace.captionFont = SoftDropdown.Look.body
        outlook.graphic = pace
        outlook.chartHeight = 112
        outlook.fixed = true
        addSubview(outlook)
        onEmpty = { [weak self] in
            guard let self else { return }
            if self.allHidden { self.showAll() } else { self.delegate.showSettings(section: .assistants) }
        }
        onReorder = { [weak self] ordered in self?.reorder(ordered) }
        delegate.plans.observe { [weak self] plans in self?.show(plans) }
        show(delegate.plans.plans)
    }

    /// A card was dropped in a new place: the cards take that order at once, so none
    /// changes what it shows, and the accounts keep it from now on.
    private func reorder(_ ordered: [SoftCard]) {
        cards = ordered + cards.filter { card in !ordered.contains { $0 === card } }
        let ids = ordered.map(\.dragID)
        delegate.change { settings in
            settings.usageAccountOrder = ids + settings.usageAccountOrder.filter { !ids.contains($0) }
        }
    }

    override func dragEnded() { show(delegate.plans.plans) }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        delegate.plans.refresh(maxAge: 20, liveAge: 180)
        show(delegate.plans.plans)
    }

    /// Once a sample: reset times count down, and old figures are read again.
    override func update(_ s: SystemSnapshot, history: HistoryStore) {
        delegate.plans.refresh()
        show(delegate.plans.plans)
    }

    func show(_ plans: [PlanUsage]) {
        // Cards keep what they show while one is being moved.
        guard !isDragging else { return }
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
            card.dragID = usage.id
            card.show(mark: .agent(usage.provider), title: usage.label ?? usage.provider,
                      meta: updated.isEmpty ? usage.account : updated,
                      metaHover: updated.isEmpty || usage.account.isEmpty ? nil : usage.account,
                      tag: usage.plan, note: usage.problem, lines: usage.windows.map { window in
                          let pace = PlanCard.pace(window, now: now)
                          return SoftCard.Line(label: Self.label(window.name), fraction: window.used,
                                               color: PlanCard.meterColor(window, short: pace.short), figure: Format.percent(window.used),
                                               detail: pace.text, hover: pace.resets, warns: pace.short,
                                               pace: PlanCard.elapsed(window, now: now))
                      })
        }

        let pick = PlanOutlook.closest(shown, now: now)
        showOutlook(pick, now: now)
        head.status = Self.status(shown, pick: pick, total: visible.count, now: now)
        let hiddenCount = plans.filter { hidden.contains($0.id) }.count
        let count = shown.count == 1 ? "1 account" : "\(shown.count) accounts"
        plate.count = shown.isEmpty ? "" : hiddenCount == 0 ? count : "\(count), \(hiddenCount) hidden"
        let paced = shown.contains { $0.windows.contains { $0.resets != nil } }
        plate.footer = shown.count > 1 ? (paced ? "Drag to reorder, hover for pace." : "Drag an account to reorder.")
            : paced ? "Hover a limit to see its pace." : ""
        if shown.isEmpty {
            showEmpty(allHidden ? "Every account is hidden." : "No plan figures yet. Turn on plan limits in Settings.",
                      button: allHidden ? "Show All" : "Open Settings")
        } else {
            showEmpty(nil)
        }
        arrange((outlook.isHidden ? [] : [outlook]) + Array(cards.prefix(shown.count)))
    }

    /// The first card: the limit closest to running out, its share as the tag, and a
    /// chart of where it is heading by its reset.
    private func showOutlook(_ pick: PlanOutlook.Pick?, now: Date) {
        outlook.isHidden = pick == nil
        guard let pick else { return }
        let window = pick.window
        let pace = PlanCard.pace(window, now: now)
        let reset = window.resets.map { "Resets " + PlanCard.resetsAt($0, now: now) }
        outlook.show(mark: .agent(pick.usage.provider), title: pick.usage.label ?? pick.usage.provider,
                     meta: PlanCard.title(window.name), metaHover: reset, tag: Format.percent(window.used), lines: [])
        self.pace.limit = window
        self.pace.now = now
        self.pace.color = PlanCard.meterColor(window, short: pace.short)
        // Ahead of pace or used up, the hover text says when it runs out or comes back.
        var caption = pace.short ? pace.resets ?? pace.text : PlanCard.outlook(window, pace: pace, now: now)
        if caption == "Not started" { caption = "Not started yet. Hover the chart to read it." }
        if caption.isEmpty { caption = window.resets == nil ? "No reset time reported" : "Too early to tell the pace" }
        self.pace.caption = caption
        self.pace.captionWarns = pace.short
    }

    /// The limit's name for the label column: "5-hour", "This week", or an Antigravity
    /// group's first model with its window ("Gemini 5h", "Claude week"). The column is
    /// shared by every account, so a long label would cut their reset times short.
    static func label(_ name: String) -> String {
        if name == "5-hour session" { return "5-hour" }
        if name == "This week" { return "Weekly" }
        if name == "This month" { return "Monthly" }
        let models = { (text: Substring) in String(text.split(separator: " ").first ?? text) }
        if name.hasPrefix("5-hour ") { return models(name.dropFirst(7)) + " 5h" }
        if name.hasSuffix(" this week"), name != "This week" { return models(name.dropLast(10)) + " week" }
        return name
    }

    /// The dot and line under the title: the limit nearest running out, at what share
    /// and where it is heading.
    private static func status(_ plans: [PlanUsage], pick: PlanOutlook.Pick?, total: Int, now: Date) -> Head.Status {
        guard let pick else {
            return .init(dot: A2Dev.quiet, lines: [total == 0 ? "No figures yet" : "Waiting for figures"])
        }
        return .init(dot: PlanOutlook.dot(pick, now: now), lines: PlanOutlook.status(pick, now: now))
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
        let reset = NSMenuItem(title: "Reset Order", action: #selector(resetOrder), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !delegate.settings.usageAccountOrder.isEmpty
        items.append(reset)
        if delegate.plans.plans.contains(where: { $0.provider == "Antigravity" }) {
            items.append(.separator())
            items.append(contentsOf: Self.antigravityItems(delegate: delegate, target: self, action: #selector(toggleLimit(_:))))
        }
        return items
    }

    /// A tick per Antigravity limit; the last one shown cannot be turned off.
    static func antigravityItems(delegate: AppDelegate, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let hidden = delegate.settings.hiddenAntigravityLimits
        let shown = AntigravityLive.limits.filter { !hidden.contains($0.name) }.count
        var items: [NSMenuItem] = [.sectionHeader(title: "Antigravity limits")]
        for limit in AntigravityLive.limits {
            let item = NSMenuItem(title: limit.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = limit.name
            item.state = hidden.contains(limit.name) ? .off : .on
            item.isEnabled = item.state == .off || shown > 1
            items.append(item)
        }
        return items
    }

    @objc private func toggleLimit(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        Self.toggleAntigravity(name, delegate: delegate)
    }

    static func toggleAntigravity(_ name: String, delegate: AppDelegate) {
        delegate.change { settings in
            if let index = settings.hiddenAntigravityLimits.firstIndex(of: name) {
                settings.hiddenAntigravityLimits.remove(at: index)
            } else if AntigravityLive.limits.filter({ !settings.hiddenAntigravityLimits.contains($0.name) }).count > 1 {
                settings.hiddenAntigravityLimits.append(name)
            }
        }
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

    @objc private func resetOrder() {
        delegate.change { $0.usageAccountOrder = [] }
    }

    @objc private func showAll() {
        delegate.change { $0.hiddenUsageAccounts = [] }
        show(delegate.plans.plans)
    }
}
