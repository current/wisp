import AppKit
import WispCore

/// The Uninstall tab's state: every installed app with its size, and for the app picked,
/// what uninstalling it removes. Apps are read and measured on a utility queue only while
/// the tab is shown, one at a time so rows come in as each is measured. Sizes stay in
/// memory until the window closes. The plan is `UninstallPlanner`'s, unchanged.
@MainActor
final class UninstallBrowser: NSObject {
    private(set) var apps: [InstalledApp] = []
    /// Bundle sizes by path, kept across visits to the tab.
    private var sizes: [String: Int64] = [:]
    /// Bundles with a process running from them.
    private(set) var running: Set<String> = []
    private(set) var listedAt: Date?
    /// False until a scan has read and measured every app.
    private(set) var complete = false
    private var scanFlag: ScanFlag?
    private(set) var chosen: InstalledApp?
    /// The chosen app's bundle went in a clean; the tab goes back to the list once the review closes.
    private var chosenGone = false
    private(set) var removal: UninstallPlan.AppRemoval = .trash
    /// Nil while the plan is being worked out.
    private(set) var plan: [CleanItem]?
    private var planToken = 0
    /// An app asked for (from the app drawer) before the list was in.
    private var wanted: String?
    private var observers: [NSObjectProtocol] = []
    private var runningCheckQueued = false

    /// Something on screen changed: an app was picked, a plan or the list came in.
    var onChange: (() -> Void)?
    /// A size came in. Called often while measuring; the page redraws at its own pace.
    var onProgress: (() -> Void)?

    let search: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Filter apps"
        field.font = Theme.sans(13)
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        return field
    }()
    let removalLabel = TextLine()
    let removalToggle = Segmented(["Trash", "Homebrew"])

    private static let listQueue = DispatchQueue(label: "app.wisp.clean.apps", qos: .utility)
    private static let planQueue = DispatchQueue(label: "app.wisp.clean.plan", qos: .utility)

    override init() {
        super.init()
        search.target = self
        search.action = #selector(searched)
        removalLabel.text = NSAttributedString(string: "Remove with", attributes: [.font: Theme.sans(12.5), .foregroundColor: Theme.inkSecondary])
        removalToggle.onChange = { [weak self] index in self?.setRemoval(index == 1 ? .homebrew : .trash) }
    }

    var isScanning: Bool { scanFlag != nil }
    var measuredCount: Int { apps.filter { sizes[$0.path] != nil }.count }
    var filter: String { search.stringValue.trimmingCharacters(in: .whitespaces) }

    func isRunning(_ app: InstalledApp) -> Bool { running.contains(app.path) }
    func size(of app: InstalledApp) -> Int64? { sizes[app.path] }

    // MARK: Showing the tab

    func appear() {
        observeWorkspace()
        if !complete, scanFlag == nil {
            scan(again: false)
        } else {
            checkRunning()
        }
    }

    func disappear() {
        stopScan()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    // MARK: Listing and measuring

    /// Reads the apps, then measures each one not measured yet (every one when `again`).
    func scan(again: Bool) {
        stopScan()
        if again { sizes = [:] }
        let flag = ScanFlag()
        scanFlag = flag
        complete = false
        let known = sizes
        Self.listQueue.async { [weak self] in
            let busy = InstalledApps.runningBundlePaths()
            let found = InstalledApps.scan(measure: false, isRunning: { busy.contains($1) }, cancelled: { flag.isSet })
            Self.onMain { self?.listed(found, running: busy, flag: flag) }
            for app in found where known[app.path] == nil {
                if flag.isSet { break }
                let bytes = InstalledApps.bundleBytes(app.path, cancel: flag)
                // A walk cut short gives a partial size; it is measured again next time.
                if flag.isSet { break }
                Self.onMain { self?.measured(app.path, bytes, flag: flag) }
            }
            Self.onMain { self?.finished(flag) }
        }
        onChange?()
    }

    func stopScan() {
        guard let scanFlag else { return }
        scanFlag.set()
        self.scanFlag = nil
        onChange?()
    }

    private func listed(_ found: [InstalledApp], running busy: Set<String>, flag: ScanFlag) {
        guard scanFlag === flag else { return }
        apps = found
        running = busy
        if let chosen, let fresh = found.first(where: { $0.path == chosen.path }) { self.chosen = fresh }
        if let wanted { open(wanted) }
        onChange?()
    }

    private func measured(_ path: String, _ bytes: Int64, flag: ScanFlag) {
        guard scanFlag === flag else { return }
        sizes[path] = bytes
        onProgress?()
    }

    private func finished(_ flag: ScanFlag) {
        guard scanFlag === flag else { return }
        scanFlag = nil
        complete = !flag.isSet
        listedAt = Date()
        onChange?()
    }

    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    /// The apps shown in the list: measured ones that match the filter, largest first.
    var listedApps: [InstalledApp] {
        let filter = filter
        return apps.filter { app in
            sizes[app.path] != nil && (filter.isEmpty || app.name.localizedCaseInsensitiveContains(filter)
                                       || app.bundleID.localizedCaseInsensitiveContains(filter))
        }.sorted { (sizes[$0.path] ?? 0, $1.name) > (sizes[$1.path] ?? 0, $0.name) }
    }

    var rows: [CleanList.Row] {
        listedApps.map { app in
            let bytes = sizes[app.path] ?? 0
            let detail = [app.version.map { "Version \($0)" }, app.cask.map { "Homebrew cask \($0.token)" }].compactMap { $0 }
            // The item gives the row its icon and the Reveal in Finder menu; it is never cleaned.
            let item = CleanItem(id: "app:" + app.path, tab: .uninstall, group: "Apps", name: app.name, detail: "", paths: [app.path],
                                 bytes: bytes, safety: .checkFirst)
            return CleanList.Row(kind: .item, id: app.path, title: app.name,
                                 detail: detail.isEmpty ? app.bundleID : detail.joined(separator: " · "),
                                 value: Format.bytes(UInt64(max(0, bytes))), label: isRunning(app) ? "Running" : "", item: item)
        }
    }

    @objc private func searched() { onChange?() }

    // MARK: One app

    /// Opens the plan for the app at `query`, a bundle path or a name. Waits for the list when it is not in yet.
    func open(_ query: String) {
        guard let app = apps.first(where: { $0.path == query }) ?? InstalledApps.find(query, in: apps) else {
            // Not listed: either the list is still coming, or the app is not one Wisp uninstalls.
            wanted = apps.isEmpty || isScanning ? query : nil
            return
        }
        wanted = nil
        choose(app)
    }

    private func choose(_ app: InstalledApp) {
        chosen = app
        chosenGone = false
        removal = .trash
        removalToggle.select(0, animated: false)
        plan = nil
        makePlan()
        onChange?()
    }

    func back() {
        chosen = nil
        chosenGone = false
        plan = nil
        planToken += 1
        onChange?()
    }

    private func setRemoval(_ new: UninstallPlan.AppRemoval) {
        guard new != removal else { return }
        removal = new
        // The old plan stays on screen until the new one is in; only the app's own row changes.
        makePlan()
    }

    private func makePlan() {
        guard var app = chosen else { return }
        planToken += 1
        let token = planToken
        if let bytes = sizes[app.path] { app.bundleBytes = bytes }
        let installed = apps.isEmpty ? [app] : apps
        let removal = app.brewToken == nil ? .trash : removal
        Self.planQueue.async { [weak self] in
            let items = UninstallPlanner(installed: installed).items(for: app, appRemoval: removal)
            Self.onMain {
                guard let self, self.planToken == token else { return }
                self.plan = items
                self.onChange?()
            }
        }
    }

    /// Asks the chosen app to quit, the way the Dock's Quit does. It may ask to save first, or refuse.
    func quitChosen() {
        guard let app = chosen else { return }
        for instance in NSWorkspace.shared.runningApplications
        where instance.bundleIdentifier == app.bundleID || instance.bundleURL?.path == app.path {
            instance.terminate()
        }
    }

    /// After a clean: what went leaves the plan, and an app whose bundle went leaves the list.
    func cleaned(_ removed: Set<String>) {
        plan?.removeAll { removed.contains($0.id) }
        guard let app = chosen, removed.contains("uninstall:" + app.path) else { return }
        apps.removeAll { $0.path == app.path }
        sizes[app.path] = nil
        chosenGone = true
    }

    func reviewClosed() {
        if chosenGone { back() }
    }

    // MARK: Running apps

    /// Launches and quits change which apps can be removed. Watched only while the tab shows.
    private func observeWorkspace() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.checkRunning()
                    // Helpers inside a bundle often outlive the app by a moment.
                    if note.name == NSWorkspace.didTerminateApplicationNotification {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.checkRunning() } }
                    }
                }
            })
        }
    }

    private func checkRunning() {
        guard !runningCheckQueued else { return }
        runningCheckQueued = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let busy = InstalledApps.runningBundlePaths()
            Self.onMain {
                guard let self else { return }
                self.runningCheckQueued = false
                guard busy != self.running else { return }
                self.running = busy
                self.onChange?()
            }
        }
    }
}
