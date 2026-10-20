import AppKit
import WispCore

/// Wires the monitor to the menu bar, the dashboard and the main window, and keeps
/// the sampling plan in step with what is on screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var settings = AppSettings.load()
    let monitor: Monitor
    private var statusBar: StatusBar!
    private var dashboard: DashboardPopover!
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private let notifier = Notifier()
    private var displayAsleep = false
    private var flushTimer: Timer?
    private let launchDate = Date()

    private(set) var system = SystemSnapshot()
    private(set) var table = ProcessTable()
    private var systemObservers: [(SystemSnapshot) -> Void] = []
    private var tableObservers: [(ProcessTable) -> Void] = []

    override init() {
        let archive = AppSettings.load().keepHistory ? HourlyArchive() : nil
        monitor = Monitor(history: HistoryStore(archive: archive))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBar(delegate: self)
        dashboard = DashboardPopover(delegate: self)

        monitor.onSystem = { [weak self] snapshot in self?.received(snapshot) }
        monitor.onProcesses = { [weak self] table in self?.received(table) }
        monitor.onAlert = { [weak self] alert in self?.notifier.post(alert) }
        notifier.onOpen = { [weak self] appID in self?.showWindow(selecting: appID) }
        monitor.update(rules: settings.alerts)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displaysSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysSlept), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysWoke), name: NSWorkspace.didWakeNotification, object: nil)

        statusBar.rebuild(settings.menuItems)
        replan()
        monitor.start()
        IPCServer.shared.assistantsAllowed = settings.allowMCP
        IPCServer.shared.start(monitor: monitor)

        // Finished hours go to disk as they close; this catches the hour in progress
        // every 15 minutes so a crash loses little.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.monitor.history.flushToArchive()
        }
        flushTimer?.tolerance = 120

        switch ProcessInfo.processInfo.environment["WISP_OPEN"] {
        case "window":
            showWindow(selecting: ProcessInfo.processInfo.environment["WISP_SELECT"])
            if let page = ProcessInfo.processInfo.environment["WISP_PAGE"].flatMap(PageID.init(rawValue:)) { mainWindow?.show(page) }
        case "dashboard": DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.statusBar.openDashboard() }
        case "settings": showSettings()
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.history.flushToArchive()
        IPCServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching from a terminal also sends a reopen event; only a later one is the user asking.
        guard Date().timeIntervalSince(launchDate) > 2 else { return false }
        showWindow()
        return false
    }

    // MARK: Data

    private func received(_ snapshot: SystemSnapshot) {
        system = snapshot
        statusBar.update(snapshot, history: monitor.history)
        for observer in systemObservers { observer(snapshot) }
    }

    private func received(_ table: ProcessTable) {
        self.table = table
        for observer in tableObservers { observer(table) }
    }

    func observeSystem(_ body: @escaping (SystemSnapshot) -> Void) { systemObservers.append(body) }
    func observeTable(_ body: @escaping (ProcessTable) -> Void) { tableObservers.append(body) }

    // MARK: What is on screen

    var dashboardOpen = false { didSet { replan() } }
    var windowVisible = false { didSet { replan() } }
    /// Readings the visible window page needs beyond the basics.
    var windowDemand: Demand = [] { didSet { if windowVisible { replan() } } }

    func replan() {
        var demand: Demand = []
        for item in settings.menuItems where item.enabled { demand.insert(item.metric.demand) }

        let activity: ActivityLevel
        if displayAsleep {
            activity = .hidden
        } else if windowVisible {
            activity = .window
            demand.formUnion([.system, .processes])
            demand.formUnion(windowDemand)
        } else if dashboardOpen {
            activity = .popover
            demand.formUnion([.system, .processes])
        } else {
            activity = demand.isEmpty ? .hidden : .menuBar
        }

        let needsBackground = settings.keepHistory || settings.alerts.anyEnabled
        let plan = SamplingPlan(demand: demand,
                                interval: settings.interval,
                                backgroundProcessInterval: needsBackground ? settings.backgroundInterval : nil,
                                backgroundAppNetwork: settings.trackAppNetwork)
        monitor.update(activity: activity, plan: plan)
    }

    @objc private func displaysSlept() {
        displayAsleep = true
        monitor.setPaused(true)
    }

    @objc private func displaysWoke() {
        guard displayAsleep else { return }
        displayAsleep = false
        monitor.setPaused(false)
        replan()
    }

    // MARK: Settings

    func change(_ body: (inout AppSettings) -> Void) {
        var copy = settings
        body(&copy)
        guard copy != settings else { return }
        let menuChanged = copy.menuItems != settings.menuItems || copy.showIcons != settings.showIcons
        settings = copy
        settings.save()
        if menuChanged { statusBar.rebuild(settings.menuItems) }
        monitor.update(rules: settings.alerts)
        IPCServer.shared.assistantsAllowed = settings.allowMCP
        replan()
    }

    // MARK: Windows

    func showWindow(selecting appID: String? = nil) {
        dashboard.close()
        if mainWindow == nil { mainWindow = MainWindowController(delegate: self) }
        NSApp.activate()
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        // An accessory app is not always allowed to activate; make sure the window is seen anyway.
        mainWindow?.window?.orderFrontRegardless()
        if let appID { mainWindow?.reveal(appID: appID) }
    }

    func mainWindowClosed() {
        // Dropping the controller frees the table views and their row caches.
        mainWindow = nil
        windowVisible = false
    }

    func showSettings() {
        dashboard.close()
        if settingsWindow == nil { settingsWindow = SettingsWindowController(delegate: self) }
        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        settingsWindow?.window?.orderFrontRegardless()
    }

    func settingsClosed() { settingsWindow = nil }

    func toggleDashboard(from button: NSStatusBarButton) {
        dashboard.toggle(relativeTo: button)
    }
}
