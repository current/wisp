import Foundation
import WispCore

/// Plan limits for the menu bar item and the usage dropdown. The figures are small
/// local files that change after each reply, so they are read off the main thread at
/// most once a minute, and only while something shows them.
@MainActor
final class PlanUsageFeed {
    private(set) var plans: [PlanUsage] = []
    private var readAt = Date.distantPast
    private var busy = false
    private var timer: Timer?
    private var observers: [([PlanUsage]) -> Void] = []

    func observe(_ body: @escaping ([PlanUsage]) -> Void) { observers.append(body) }

    /// Reads again when the figures are older than `maxAge` seconds.
    func refresh(maxAge: TimeInterval = 60) {
        guard !busy, Date().timeIntervalSince(readAt) >= maxAge else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let result = PlanUsageReader.readAll()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    self.readAt = Date()
                    self.plans = result
                    for observer in self.observers { observer(result) }
                }
            }
        }
    }

    /// On while the menu bar shows an AI usage item.
    var running = false {
        didSet {
            guard running != oldValue else { return }
            timer?.invalidate()
            timer = nil
            guard running else { return }
            refresh(maxAge: 0)
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(maxAge: 50) }
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
        case .both: return max(session(usage)?.used ?? 0, week(usage)?.used ?? 0)
        }
    }

    static func session(_ usage: PlanUsage) -> PlanUsage.Window? { usage.windows.first { $0.name.hasPrefix("5-hour") } ?? usage.windows.first }
    static func week(_ usage: PlanUsage) -> PlanUsage.Window? { usage.windows.first { $0.name == "This week" } ?? usage.windows.last }

    /// "Claude (alt)" or "Claude · name@example.com", for menus.
    static func name(_ usage: PlanUsage) -> String {
        usage.label ?? (usage.provider + " · " + usage.account)
    }
}
