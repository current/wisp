import AppKit
import WispCore

/// The app's side of fan control: whether the helper is there, what it reports, the owner's
/// curves, and changing the mode. The helper does the work; this only asks it. Views call
/// `watch` while they are on screen, and the helper is asked every two seconds until none watches.
@MainActor
final class FanService {
    static let shared = FanService()

    enum Availability: Equatable {
        /// Not installed yet: the Sensors page offers to set it up.
        case notInstalled
        /// Installed but not answering, or from an older Wisp.
        case needsRepair(String)
        case ready
    }

    private(set) var availability: Availability = FanHelper.isInstalled ? .needsRepair("Starting") : .notInstalled
    /// The helper's last report, or the fans as macOS runs them when there is no helper.
    private(set) var status: FanStatus?
    /// The owner's own curves; the built-in ones are `FanCurve.presets`.
    private(set) var curves: [FanCurve] = FanCurveStore.load()
    /// Shown under the controls after something failed, until the next change works.
    private(set) var problem: String?
    private(set) var busy = false
    /// The helper has been asked at least once, so `availability` is an answer and not the guess made at launch.
    private(set) var checked = false

    private var observers: [UUID: () -> Void] = [:]
    private var watchers = 0
    private var timer: Timer?
    private var refreshing = false
    private var unreachableStreak = 0
    /// Incremented on every user action so an older in-flight poll cannot overwrite a newer `set` or `install`.
    private var generation = 0
    private let statusQueue = DispatchQueue(label: "app.wisp.fans.status", qos: .userInitiated)
    private let actionQueue = DispatchQueue(label: "app.wisp.fans.action", qos: .userInitiated)
    /// Owned solely by `statusQueue` so read-only fallback never crosses actor boundaries.
    private final class FallbackHardware: @unchecked Sendable {
        lazy var hardware = SMCFanHardware(allSensors: false)
        func status() -> FanStatus? {
            guard let hardware, !hardware.fans.isEmpty else { return nil }
            return FanEngine(hardware: hardware).status()
        }
    }
    private let fallback = FallbackHardware()

    var modes: [FanMode] { FanMode.builtIn + curves.map(FanMode.curve) }

    /// Calls `change` on the main thread whenever anything here changes. Keep the token to stop.
    func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    /// While at least one watcher is on, the helper is asked every two seconds.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if watchers > 0, timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: FanEngine.interval, repeats: true) { _ in
                MainActor.assumeIsolated { FanService.shared.refresh() }
            }
        } else if watchers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        // Never queue overlapping polls: if one is in flight, let it finish.
        guard !refreshing, !busy else { return }
        refreshing = true
        let token = generation
        let fallback = self.fallback
        statusQueue.async {
            let answer = FanHelper.status()
            let local: FanStatus? = {
                guard case .failure = answer else { return nil }
                return fallback.status()
            }()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    guard self.generation == token else { return }
                    self.take(answer, fallback: local, fromAction: false)
                }
            }
        }
    }

    private func take(_ answer: Result<FanStatus, FanHelper.Failure>, fallback: FanStatus?, fromAction: Bool) {
        let wasReady = availability == .ready
        checked = true
        switch answer {
        case .success(let status) where status.version != FanHelper.protocolVersion:
            unreachableStreak = 0
            self.status = status
            availability = .needsRepair("The fan helper is from another version of Wisp")
        case .success(let status):
            unreachableStreak = 0
            self.status = status
            self.problem = nil
            availability = .ready
        case .failure(.unreachable):
            unreachableStreak += 1
            // A single transient timeout while already healthy shouldn't flash the Repair screen;
            // explicit user actions and launch checks report immediately.
            if wasReady, !fromAction, unreachableStreak < 2 {
                return
            }
            if let fallback { status = fallback }
            availability = FanHelper.isInstalled ? .needsRepair("The fan helper is not answering") : .notInstalled
        case .failure(.refused(let message)):
            unreachableStreak = 0
            if let fallback { status = fallback }
            availability = .needsRepair(message)
        }
        changed()
    }

    func set(_ mode: FanMode) {
        guard availability == .ready else { return }
        generation += 1
        let token = generation
        busy = true
        changed()
        actionQueue.async {
            let answer = FanHelper.set(mode)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == token else { return }
                    self.busy = false
                    switch answer {
                    case .failure(.unreachable): self.problem = "The fan helper is not answering"
                    case .failure(.refused(let message)): self.problem = message
                    case .success: self.problem = nil
                    }
                    self.take(answer, fallback: nil, fromAction: true)
                }
            }
        }
    }

    /// Asks for the password, then installs or repairs the helper.
    func install() {
        generation += 1
        let token = generation
        busy = true
        changed()
        actionQueue.async {
            let error = FanHelper.install(from: Bundle.main.bundleURL)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == token else { return }
                    self.busy = false
                    self.problem = error == "cancelled" ? nil : error
                    self.unreachableStreak = 0
                    self.refresh()
                }
            }
        }
    }

    func uninstall() {
        generation += 1
        let token = generation
        busy = true
        changed()
        actionQueue.async {
            let error = FanHelper.uninstall()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == token else { return }
                    self.busy = false
                    self.problem = error == "cancelled" ? nil : error
                    self.unreachableStreak = 0
                    self.refresh()
                }
            }
        }
    }

    /// Adds or replaces the curve with `curve`'s name, renamed from `oldName` when given. A
    /// curve the fans are following now is sent to the helper again.
    func save(_ curve: FanCurve, replacing oldName: String? = nil) {
        let name = oldName ?? curve.name
        if let index = curves.firstIndex(where: { $0.name == name }) { curves[index] = curve } else { curves.append(curve) }
        FanCurveStore.save(curves)
        if status?.mode.kind == .curve, status?.mode.curve?.name == name { set(.curve(curve)) }
        changed()
    }

    func delete(_ name: String) {
        curves.removeAll { $0.name == name }
        FanCurveStore.save(curves)
        if status?.mode.kind == .curve, status?.mode.curve?.name == name { set(.auto) }
        changed()
    }

    private func changed() {
        for observer in observers.values { observer() }
    }
}
