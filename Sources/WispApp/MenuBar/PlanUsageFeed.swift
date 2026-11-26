import Foundation
import WispCore

/// Plan limits for the menu bar item and the usage dropdown. Each agent's own program is
/// asked for its accounts' figures (see `ClaudeLive`, `CodexLive`, `AntigravityLive`),
/// off the main thread and only while something shows them: every 5 minutes, less often
/// while an account's figures stay the same, and when a dropdown or the window opens.
@MainActor
final class PlanUsageFeed {
    /// The figures as read, and as shown: without the Antigravity limits turned off.
    private var read: [PlanUsage] = []
    private(set) var plans: [PlanUsage] = []
    private var readAt = Date.distantPast
    private var busy = false
    private var timer: Timer?
    private var startedOnce = false
    private var observers: [([PlanUsage]) -> Void] = []
    /// Settings, Assistants, "Show AI plan limits". Off, no agent's program is started:
    /// only what is already saved shows.
    var allowed = false
    /// Antigravity limits left out, from the settings.
    var hiddenAntigravity: [String] = [] {
        didSet { if hiddenAntigravity != oldValue { publish() } }
    }
    /// The accounts' order, from the settings.
    var order: [String] = [] {
        didSet { if order != oldValue { publish() } }
    }

    func observe(_ body: @escaping ([PlanUsage]) -> Void) { observers.append(body) }

    /// Reads again when the figures are older than `maxAge` seconds, and asks each
    /// account whose last answer is older than `liveAge`; `paced` (the menu bar's own
    /// timer) waits longer for accounts whose figures have not moved. What is saved shows
    /// first; the questions run side by side, each can take a few seconds, and their
    /// answers show once all are in. `live: false` asks only the accounts with no answer
    /// yet, and leaves the figures due.
    func refresh(maxAge: TimeInterval = 60, liveAge: TimeInterval = 300, live: Bool = true, paced: Bool = false) {
        guard !busy, Date().timeIntervalSince(readAt) >= maxAge else { return }
        busy = true
        let liveAge = live ? liveAge : .infinity
        let ask = allowed
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if !Self.retired {
                Self.retired = true
                PlanUsageReader.removeRetiredFiles()
            }
            let local = PlanUsageReader.readAll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, local != self.read else { return }
                    self.read = local
                    self.publish()
                }
            }
            if ask {
                let group = DispatchGroup()
                DispatchQueue.global(qos: .utility).async(group: group) { ClaudeLive.refresh(maxAge: liveAge, paced: paced) }
                DispatchQueue.global(qos: .utility).async(group: group) { CodexLive.refresh(maxAge: liveAge, paced: paced) }
                DispatchQueue.global(qos: .utility).async(group: group) { AntigravityLive.refresh(maxAge: liveAge, paced: paced) }
                group.wait()
            }
            let result = PlanUsageReader.readAll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    if live { self.readAt = Date() }
                    self.read = result
                    self.publish()
                }
            }
        }
    }

    nonisolated(unsafe) private static var retired = false

    private func publish() {
        plans = Self.shown(read, hidden: hiddenAntigravity, order: order)
        for observer in observers { observer(plans) }
    }

    /// The plans in the user's order, without the Antigravity limits turned off. An
    /// account keeps at least one limit; accounts not in the order follow as read.
    static func shown(_ plans: [PlanUsage], hidden: [String], order: [String]) -> [PlanUsage] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let plans = order.isEmpty ? plans : plans.enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
        guard !hidden.isEmpty else { return plans }
        return plans.map { usage in
            guard usage.provider == "Antigravity" else { return usage }
            var usage = usage
            let kept = usage.windows.filter { !hidden.contains($0.name) }
            if !kept.isEmpty { usage.windows = kept }
            return usage
        }
    }

    /// On while the menu bar shows an AI usage item and the displays are awake.
    var running = false {
        didSet {
            guard running != oldValue else { return }
            timer?.invalidate()
            timer = nil
            guard running else { return }
            // At launch the saved figures show at once, and the checks (a program per
            // account) wait half a minute for Wisp to settle.
            let launching = !startedOnce
            startedOnce = true
            refresh(maxAge: 0, live: !launching)
            let timer = Timer(fire: Date().addingTimeInterval(launching ? 30 : 60), interval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(maxAge: 50, paced: true) }
            }
            timer.tolerance = 15
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// The figure an item shows: the chosen account, or the one closest to its limit.
    static func pick(_ plans: [PlanUsage], account: String, window: UsageWindowChoice) -> PlanUsage? {
        let usable = plans.filter { $0.problem == nil && !$0.windows.isEmpty }
        if !account.isEmpty, let chosen = usable.first(where: { $0.id == account }) { return chosen }
        return usable.max { level($0, window) < level($1, window) }
    }

    static func level(_ usage: PlanUsage, _ choice: UsageWindowChoice) -> Double {
        switch choice {
        case .session: return session(usage)?.used ?? 0
        case .week: return week(usage)?.used ?? 0
        case .both, .sideBySide: return max(session(usage)?.used ?? 0, week(usage)?.used ?? 0)
        }
    }

    /// The 5-hour limit, or with several (Antigravity has one per model group) the fullest.
    static func session(_ usage: PlanUsage) -> PlanUsage.Window? {
        usage.windows.filter { $0.name.hasPrefix("5-hour") }.max { $0.used < $1.used } ?? usage.windows.first
    }

    static func week(_ usage: PlanUsage) -> PlanUsage.Window? {
        usage.windows.filter { $0.name == "This week" || $0.name.hasSuffix(" this week") }.max { $0.used < $1.used } ?? usage.windows.last
    }

    /// A label short enough for the menu bar (six characters): "Claude", "Codex", "Agy".
    static func shortName(_ usage: PlanUsage) -> String {
        usage.provider == "Antigravity" ? "Agy" : String(usage.provider.prefix(6))
    }

    /// "Gemini, weekly" for an Antigravity limit, otherwise the limit's own name.
    static func limitTitle(_ name: String) -> String {
        AntigravityLive.limits.first { $0.name == name }?.title ?? name
    }

    /// "Claude (alt)" or "Claude · name@example.com", for menus.
    static func name(_ usage: PlanUsage) -> String {
        usage.label ?? (usage.provider + " · " + usage.account)
    }
}
