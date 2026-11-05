import AppKit
import WispCore

/// Clean Up's part of the app outside its page: its settings, the opt-in scheduled clean
/// (a date check on the app's existing 15-minute timer) and the opt-in deleted-app watcher.
/// With both off, as they are by default, it does nothing at all.
@MainActor
final class CleanUpCenter {
    private(set) var settings = CleanSettings.load()
    /// Posts a notification: identifier, title, body and what a click should open.
    var notify: ((String, String, String, [String: String]) -> Void)?
    /// Opens the Clean Up page and hands it over.
    var open: ((@escaping (CleanUpPage) -> Void) -> Void)?
    private var watcher: DeletedAppWatcher?
    private var checkingSchedule = false
    private static let queue = DispatchQueue(label: "app.wisp.clean.background", qos: .utility)

    func start() {
        applyWatcher()
        checkSchedule()
    }

    func change(_ body: (inout CleanSettings) -> Void) {
        var copy = settings
        body(&copy)
        guard copy != settings else { return }
        settings = copy
        // Screenshot and benchmark runs keep their changes in memory, as the app's own settings do.
        if ProcessInfo.processInfo.environment["WISP_NO_SAVE"] == nil { settings.save() }
        applyWatcher()
    }

    // MARK: Scheduled clean

    /// Called from the app's existing timer. When a clean is due, scans Junk and Developer
    /// once in the background and says how much safe junk can go; the owner reviews it
    /// before anything moves. The next due date is set either way.
    func checkSchedule(now: Date = Date()) {
        guard settings.isDue(now: now), !checkingSchedule else { return }
        checkingSchedule = true
        let context = CleanScanContext(excluded: settings.exclusions)
        Self.queue.async { [weak self] in
            let safe = CleanRegistry.scan(CleanRegistry.safeTabs, context: context).filter(\.isSafeTrash)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingSchedule = false
                    self.change { $0.scheduleNext(from: Date()) }
                    guard safe.totalBytes > 0 else { return }
                    self.notify?("clean-scheduled", "\(Format.bytes(UInt64(safe.totalBytes))) of junk can go",
                                 "\(safe.count) caches, logs and build files marked safe. Review them before they move to the Trash.",
                                 ["clean": "scheduled"])
                }
            }
        }
    }

    // MARK: Deleted apps

    private func applyWatcher() {
        if settings.watchDeletedApps, watcher == nil {
            let watcher = DeletedAppWatcher()
            watcher.onDeleted = { [weak self] app in self?.deleted(app) }
            watcher.start()
            self.watcher = watcher
        } else if !settings.watchDeletedApps, let watcher {
            watcher.stop()
            self.watcher = nil
        }
    }

    /// An app left the Applications folders. Tell the owner only if it left something behind.
    private func deleted(_ app: DeletedAppWatcher.App) {
        let scanners = CleanRegistry.scanners(for: .leftovers)
        guard !scanners.isEmpty else { return }
        let context = CleanScanContext(excluded: settings.exclusions)
        Self.queue.async { [weak self] in
            let items = CleanRegistry.scan([.leftovers], context: context, using: scanners).filter { $0.ownerBundleID == app.bundleID }
            let files = items.reduce(0) { $0 + $1.paths.count }
            guard files > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.notify?("clean-deleted-\(app.bundleID)", "\(app.name) was deleted",
                                  "It left \(files == 1 ? "1 file" : "\(files) files"), \(Format.bytes(UInt64(items.totalBytes))) in all.",
                                  ["clean": "leftovers", "bundleID": app.bundleID, "name": app.name])
                }
            }
        }
    }

    /// A click on one of Clean Up's notifications.
    func handle(_ info: [String: String]) {
        switch info["clean"] {
        case "scheduled":
            open? { $0.startScheduledClean() }
        case "leftovers":
            guard let id = info["bundleID"] else { return }
            open? { $0.showLeftovers(of: id, name: info["name"] ?? id) }
        default:
            open? { _ in }
        }
    }
}
