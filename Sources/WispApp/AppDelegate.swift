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
        MainMenu.install(delegate: self)
        statusBar = StatusBar(delegate: self)
        dashboard = DashboardPopover(delegate: self)

        monitor.onSystem = { [weak self] snapshot in self?.received(snapshot) }
        monitor.onProcesses = { [weak self] table in self?.received(table) }
        monitor.onAlert = { [weak self] alert in self?.notifier.post(alert) }
        // Insights outlive a restart; they are small and change only when one fires or is cleared.
        let insights = Wisp.supportDirectory.appendingPathComponent("insights.json")
        monitor.perform { monitor in
            if let data = try? Data(contentsOf: insights), let saved = try? JSONDecoder().decode([Alert].self, from: data) {
                monitor.alerts.restore(saved)
            }
            monitor.alerts.onChange = { recent in try? JSONEncoder().encode(recent).write(to: insights, options: .atomic) }
        }
        notifier.onOpen = { [weak self] appID in self?.showWindow(selecting: appID) }
        monitor.update(rules: settings.alerts)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displaysSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysSlept), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysWoke), name: NSWorkspace.didWakeNotification, object: nil)

        applyLooks()
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
        case "menu":
            if let seconds = ProcessInfo.processInfo.environment["WISP_MENU_INTERVAL"].flatMap(Double.init) {
                change { $0.menuInterval = seconds }
            }
        default:
            if settings.openWindowAtLaunch { showWindow() }
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
                                interval: activity == .menuBar ? max(settings.interval, settings.menuInterval) : settings.interval,
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
        applyLooks()
        replan()
    }

    /// Appearance, units and the Dock icon, from settings.
    private func applyLooks() {
        // WISP_APPEARANCE=dark or light overrides the setting, for screenshots and the layout audit.
        switch ProcessInfo.processInfo.environment["WISP_APPEARANCE"].flatMap(Look.init(rawValue:)) ?? settings.look {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .automatic: NSApp.appearance = nil
        }
        Format.fahrenheit = settings.fahrenheit
        Format.bits = settings.bits
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // MARK: Windows

    func showWindow(selecting appID: String? = nil) {
        dashboard.close()
        if mainWindow == nil {
            mainWindow = MainWindowController(delegate: self)
            if appID == nil, let page = PageID(rawValue: settings.startPage) { mainWindow?.show(page) }
        }
        if MainWindowController.background {
            // Shown without taking focus or coming forward.
            mainWindow?.window?.orderBack(nil)
            if let appID { mainWindow?.reveal(appID: appID) }
            return
        }
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

    func showPage(_ page: PageID) {
        showWindow()
        mainWindow?.show(page)
    }

    /// Settings live in the main window, as its last page.
    func showSettings() {
        showWindow()
        mainWindow?.show(.settings)
    }

    func closeDashboard() { dashboard.close() }

    func toggleDashboard(from button: NSStatusBarButton) {
        dashboard.toggle(relativeTo: button)
    }
}
