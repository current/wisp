import AppKit
import ServiceManagement
import WispCore

/// Settings, a page of the main window like the others: the sections are tabs in the
/// toolbar and each section is cards of settings, one per row, two columns wide when
/// the window has the room. Every control writes through AppDelegate.change, which
/// saves and re-plans sampling at once.
@MainActor
final class SettingsPage: NSViewController, Page {
    enum Section: String, CaseIterable {
        /// The outline symbol the sidebar shows, as for pages.
        var sidebarSymbol: String {
            switch self {
            case .general: return "gearshape"
            case .menuBar: return "menubar.rectangle"
            case .display: return "paintbrush"
            case .alerts: return "bell.badge"
            case .assistants: return "sparkles"
            case .cleanUp: return "wand.and.sparkles"
            case .about: return "info.circle"
            }
        }

        case general, menuBar, display, alerts, assistants, cleanUp, about

        var title: String {
            switch self {
            case .general: return "General"
            case .menuBar: return "Menu Bar"
            case .display: return "Display"
            case .alerts: return "Alerts"
            case .assistants: return "Assistants"
            case .cleanUp: return "Clean Up"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .menuBar: return "menubar.rectangle"
            case .display: return "paintbrush.fill"
            case .alerts: return "bell.badge.fill"
            case .assistants: return "sparkles"
            case .cleanUp: return "wand.and.sparkles"
            case .about: return "info"
            }
        }

        var tint: NSColor {
            switch self {
            case .general: return Theme.dynamic(0x007AFF, 0x0A84FF)
            case .menuBar: return Theme.dynamic(0x5856D6, 0x7D7AFF)
            case .display: return Theme.dynamic(0xD9487A, 0xEB6F98)
            case .alerts: return Theme.dynamic(0xE0662A, 0xF0864E)
            case .assistants: return Theme.dynamic(0x6E56E0, 0x9480F0)
            case .cleanUp: return PageID.cleanup.tint
            case .about: return Theme.dynamic(0x1F9D72, 0x4ACB98)
            }
        }
    }

    private unowned let delegate: AppDelegate
    private let scroll = NSScrollView()
    private let page = SettingsPageView()
    private(set) var section: Section = .general
    private let tabs = Segmented(Section.allCases.map(\.title))
    private let titleLine = TextLine(Toolbar.title("Settings"))
    private let caption: TextLine = {
        let line = TextLine()
        line.variants = ["Changes apply as you make them · Wisp \(Wisp.version)", "Wisp \(Wisp.version)"].map(Toolbar.subtitle)
        return line
    }()
    private lazy var builder: DashboardBuilder = {
        let builder = DashboardBuilder(delegate: delegate)
        builder.onHeightChange = { [weak self] in self?.rebuild() }
        builder.onLayoutChange = { [weak self] in self?.updateDemand() }
        return builder
    }()
    /// Wisp's own CPU and memory, on General and About.
    private let ownUse = SettingsFacts()
    private lazy var aboutHero = AboutHero()

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        scroll.documentView = page
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Toolbar.height, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: Toolbar.height - 8, left: 0, bottom: 0, right: 0)
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        view = root
        ownUse.frame.size = NSSize(width: 210, height: 20)
        showOwnUse(delegate.table)
        tabs.onChange = { [weak self] index in self?.show(Section.allCases[index]) }
        tabs.setAccessibilityLabel("Settings sections")
        // Assistants lists each account; it fills in as their answers arrive.
        delegate.plans.observe { [weak self] _ in
            guard let self, self.section == .assistants, self.delegate.settings.planUsage else { return }
            self.rebuild()
        }
        // WISP_TAB=<0-6> opens on a given section, for screenshots.
        let start = ProcessInfo.processInfo.environment["WISP_TAB"].flatMap(Int.init).flatMap { Section.allCases.indices.contains($0) ? Section.allCases[$0] : nil }
        show(start ?? .general, animated: false)
    }

    var toolbarHeading: (NSView, NSView)? { (titleLine, caption) }
    var toolbarItems: [NSView] { [tabs] }
    var pageScroll: NSScrollView? { scroll }

    /// The Menu Bar section's dashboard preview reads what its blocks show.
    var demand: Demand {
        section == .menuBar ? DashboardBlock.demand(of: delegate.settings.dashboard) : []
    }

    private func updateDemand() {
        if view.window != nil { delegate.windowDemand = demand }
    }

    func update(system: SystemSnapshot) {
        if section == .menuBar {
            builder.update(system: system)
            menuPreview.needsDisplay = true
        }
    }

    func update(table: ProcessTable) {
        if section == .menuBar { builder.update(table: table) }
        showOwnUse(table)
    }

    /// Wisp's own process as the table last measured it, the window's drawing included.
    private func showOwnUse(_ table: ProcessTable) {
        guard let own = table.processes.first(where: { $0.pid == getpid() }) else {
            ownUse.facts = [A2.Fact(label: "", value: "Measuring…", color: A2.secondary)]
            return
        }
        ownUse.facts = [A2.Fact(label: "CPU", value: Format.percent(own.cpu, digits: 1)), A2.Fact(label: "Memory", value: Format.memory(own.memory))]
        aboutHero.use = (own.cpu, own.memory)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scroll.frame = view.bounds
        if page.width != scroll.contentSize.width {
            page.width = scroll.contentSize.width
            page.relayout()
        }
    }

    func show(_ section: Section, animated: Bool = true) {
        self.section = section
        if section == .assistants, delegate.settings.planUsage { delegate.plans.refresh(maxAge: 60, live: false) }
        tabs.select(Section.allCases.firstIndex(of: section) ?? 0, animated: animated)
        rebuild()
        updateDemand()
        // WISP_SCROLL=<points> scrolls part of the way, for screenshots.
        let offset = ProcessInfo.processInfo.environment["WISP_SCROLL"].flatMap(Double.init) ?? 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset - Toolbar.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        if animated { Motion.enter(page, from: CGPoint(x: 0, y: 6), duration: 0.2) }
    }

    /// Builds the section again once a switch has finished sliding, so the change shows.
    func rebuildSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.rebuild() }
    }

    /// Builds the current section again, after a change that adds or removes rows.
    func rebuild() {
        page.tint = section.tint
        page.groups = groups(for: section)
        page.width = scroll.contentSize.width
        page.relayout()
    }

    // MARK: Sections

    private func groups(for section: Section) -> [SettingsGroup] {
        switch section {
        case .general: return general()
        case .menuBar: return menuBar()
        case .display: return display()
        case .alerts: return alerts()
        case .assistants: return assistants()
        case .cleanUp:
            return CleanUpSettings.groups(delegate.cleanUp, rebuild: { [unowned self] in rebuild() },
                                          open: { [unowned self] in delegate.showPage(.cleanup) })
        case .about: return about()
        }
    }

    private func general() -> [SettingsGroup] {
        let s = delegate.settings
        let intervals: [Double] = [1, 2, 3, 5]
        let menuIntervals: [Double] = [1, 2, 3, 5, 10]
        let every = { (seconds: Double) in seconds == 1 ? "every second" : "every \(Int(seconds)) seconds" }
        let atLogin = SMAppService.mainApp.status == .enabled
        return [
            SettingsGroup("Sampling", symbol: "timer", summary: "Windows read the Mac \(every(s.interval)), the menu bar \(every(s.menuInterval)).", [
                .control("Update every", "While a Wisp window or the dashboard is open.",
                         SettingsControls.popup(intervals.map { $0 == 1 ? "Second" : "\(Int($0)) seconds" }, intervals.firstIndex(of: s.interval) ?? 1) { [unowned self] i in
                             delegate.change { $0.interval = intervals[i] }
                             rebuild()
                         }),
                .control("Menu bar", "Redrawing the menu bar is most of what Wisp costs with every window closed.",
                         SettingsControls.popup(menuIntervals.map { $0 == 1 ? "Every second" : "Every \(Int($0)) seconds" }, menuIntervals.firstIndex(of: s.menuInterval) ?? 2) { [unowned self] i in
                             delegate.change { $0.menuInterval = menuIntervals[i] }
                             rebuild()
                         }),
                .control("What Wisp uses now", "Its own process, this window included.", ownUse),
            ], footer: "A slower pace costs less. Wisp measures itself the way it measures every other app."),
            SettingsGroup("History", symbol: "clock.arrow.circlepath", summary: s.keepHistory ? "A year of per-app history, on this Mac only." : "Off. Pages show only what Wisp read since it started.",
                          trailing: .pill(s.keepHistory ? "On" : "Off", s.keepHistory ? .good : .neutral), [
                .control("Keep a year of per-app history", "Minute by minute for a day, hourly totals for a year, on this Mac only.",
                         SettingsControls.toggle(s.keepHistory) { [unowned self] on in
                             delegate.change { $0.keepHistory = on }
                             rebuildSoon()
                         }),
                .control("Track network per app in the background", "Off, per-app network is measured only while a window shows it.",
                         SettingsControls.toggle(s.trackAppNetwork) { [unowned self] on in delegate.change { $0.trackAppNetwork = on } }),
            ], footer: "Kept in ~/Library/Application Support/Wisp.", action: ("Show in Finder", { Self.revealSupportFolder() })),
            SettingsGroup("Startup", symbol: "power", summary: atLogin ? "Wisp opens in the menu bar when you log in." : "Wisp opens only when you start it.", [
                .control("Open Wisp at login", "Adds Wisp to the Login Items in System Settings.", SettingsControls.toggle(atLogin) { [unowned self] on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSSound.beep()
                    }
                    rebuildSoon()
                }),
            ], footer: "macOS can also turn it off there.", action: ("Login Items", {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            })),
        ]
    }

    private func menuBar() -> [SettingsGroup] {
        let s = delegate.settings
        let shown = s.menuItems.filter(\.enabled).count
        var rows: [SettingsRow] = []
        for (index, item) in s.menuItems.enumerated() {
            let style = SettingsControls.popup(MenuStyle.allCases.map(\.title), MenuStyle.allCases.firstIndex(of: item.style) ?? 0) { [unowned self] i in
                changeItem(index) { $0.style = MenuStyle.allCases[i] }
            }
            let open = editing == index
            let edit = SettingsControls.pill(open ? "Done" : "Edit") { [unowned self] in
                editing = open ? nil : index
                rebuild()
            }
            let enable = SettingsControls.toggle(item.enabled) { [unowned self] on in
                changeItem(index) { $0.enabled = on }
                rebuildSoon()
            }
            rows.append(.pair(itemTitle(item), .symbol(item.metric.symbol, Self.tint(item.metric)), SettingsControls.row([style, edit]), enable))
            if item.metric == .usage, !s.menuItems[(index + 1)...].contains(where: { $0.metric == .usage }) {
                rows.append(.item(.symbol("plus", section.tint), "Another AI usage item", "Another account or limit next to this one, with its own look.",
                                  SettingsControls.pill("Add") { [unowned self] in addUsageItem(after: index) }, tip: nil))
            }
        }
        let look: SettingsGroup
        if let index = editing, s.menuItems.indices.contains(index) {
            let item = s.menuItems[index]
            look = SettingsGroup("Look of \(itemTitle(item))", symbol: item.metric.symbol, tint: Self.tint(item.metric),
                                 summary: "Its label, size, weight, colour and width.", itemEditor(index, item),
                                 footer: "A reading turns red when the Mac is under strain, unless its colour is Menu bar only. AI usage turns red at 90%.")
        } else {
            look = SettingsGroup("Look", symbol: "textformat.size", summary: "Each item can have its own.", [
                .empty(.symbol("slider.horizontal.3", section.tint), "Pick Edit on an item",
                       "Give it its own label, text size, weight and colour, then use that look for every item if you like it.", nil),
            ])
        }
        builder.needsLayout = true
        return [
            SettingsGroup("Menu bar", symbol: "menubar.rectangle", summary: "\(shown) of \(s.menuItems.count) items shown, drawn from the latest reading.", wide: true, [
                .custom(menuPreview, MenuBarPreview.height),
                .control("Clicking an item opens", "With details, Memory opens memory and the apps using the most of it, Network the apps moving data, and so on.",
                         SettingsControls.popup(["The dashboard", "Details about that item"], s.itemDropdowns ? 1 : 0) { [unowned self] i in
                             delegate.change { $0.itemDropdowns = i == 1 }
                         }),
            ]),
            SettingsGroup("Items", symbol: "list.bullet", summary: "Turn one on, pick how it reads, or edit its look.", trailing: .text("\(shown) shown"), rows),
            look,
            SettingsGroup(nil, wide: true, chrome: false, [.flexible(builder)]),
        ]
    }

    private func display() -> [SettingsGroup] {
        let s = delegate.settings
        let looks = Look.allCases
        let pages = PageID.allCases.filter { $0 != .settings }
        let cores = max(1, delegate.table.coreCount)
        let appCPU = s.cpuOfMachine ? "An app busy on two cores reads \(Int((200 / Double(cores)).rounded()))% of this \(cores)-core Mac."
            : "An app busy on two cores reads 200%."
        return [
            SettingsGroup("Window", symbol: "macwindow", summary: s.look == .automatic ? "Follows macOS, so it changes when the system does." : "Stays \(s.look == .dark ? "dark" : "light") whatever macOS uses.", [
                .flexible(appearancePicker(looks.firstIndex(of: s.look) ?? 0) { [unowned self] i in
                    delegate.change { $0.look = looks[i] }
                    rebuild()
                }),
                .control("Show Wisp in the Dock", "Off, Wisp lives in the menu bar only.", SettingsControls.toggle(s.showInDock) { [unowned self] on in delegate.change { $0.showInDock = on } }),
                .control("Open the window when Wisp starts", "Off, it starts in the menu bar.",
                         SettingsControls.toggle(s.openWindowAtLaunch) { [unowned self] on in delegate.change { $0.openWindowAtLaunch = on } }),
                .control("Start on", "The page a new window opens on.",
                         SettingsControls.popup(pages.map(\.title), pages.firstIndex { $0.rawValue == s.startPage } ?? 0) { [unowned self] i in
                             delegate.change { $0.startPage = pages[i].rawValue }
                         }),
            ]),
            SettingsGroup("Units", symbol: "ruler", summary: "How readings are written everywhere in Wisp.", [
                .control("App CPU", appCPU, SettingsControls.popup(["100% is one core", "100% is the whole Mac"], s.cpuOfMachine ? 1 : 0) { [unowned self] i in
                    delegate.change { $0.cpuOfMachine = i == 1 }
                    rebuild()
                }),
                .control("Temperature", s.fahrenheit ? "A busy CPU reads about 185°F." : "A busy CPU reads about 85°C.",
                         SettingsControls.popup(["Celsius", "Fahrenheit"], s.fahrenheit ? 1 : 0) { [unowned self] i in
                             delegate.change { $0.fahrenheit = i == 1 }
                             rebuild()
                         }),
                .control("Network", s.bits ? "A 100 megabit line reads 100 Mb/s." : "A 100 megabit line reads 12.5 MB/s.",
                         SettingsControls.popup(["Bytes per second", "Bits per second"], s.bits ? 1 : 0) { [unowned self] i in
                             delegate.change { $0.bits = i == 1 }
                             rebuild()
                         }),
            ], footer: "Pages, dropdowns, the menu bar and alerts all follow these."),
        ]
    }

    private func alerts() -> [SettingsGroup] {
        let rules = delegate.settings.alerts
        let ruleCount = [rules.cpuEnabled, rules.memoryEnabled, rules.diskEnabled, rules.networkEnabled, rules.temperatureEnabled].filter { $0 }.count
        let rule = { (kind: AlertKind, title: String, detail: String, on: Bool, apply: @escaping (inout AlertRules, Bool) -> Void) -> SettingsRow in
            let (symbol, tint) = Self.mark(kind)
            return .item(.symbol(symbol, tint), title, detail, SettingsControls.toggle(on) { [unowned self] on in
                delegate.change { apply(&$0.alerts, on) }
                rebuildSoon()
            }, tip: nil)
        }
        var limits: [SettingsRow] = rules.appLimits.enumerated().map { index, limit in
            var parts: [String] = []
            if let bytes = limit.memoryBytes { parts.append("over \(Format.memory(bytes)) of memory") }
            if let cores = limit.cpu { parts.append("over \(Format.percent(cores)) CPU") }
            let remove = SettingsControls.pill("Remove") { [unowned self] in
                delegate.change { $0.alerts.appLimits.remove(at: index) }
                rebuild()
            }
            return .item(appMark(limit.appID, kind: .appLimit), limit.appName, "Tell me when it goes " + parts.joined(separator: " or ") + " for a minute.", remove, tip: nil)
        }
        let addLimit = SettingsControls.pill("Add Limit…") { [unowned self] in addLimit() }
        if limits.isEmpty {
            limits = [.empty(.symbol("gauge.with.dots.needle.67percent", section.tint), "No app limits yet",
                             "Pick an app and a memory or CPU limit. Wisp tells you when it stays over it for a minute.", addLimit)]
        }
        let recent = Array(delegate.monitor.perform { $0.alerts.recent }.suffix(8).reversed())
        let full = DateFormatter()
        full.dateFormat = "EEEE, MMM d 'at' HH:mm"
        var history: [SettingsRow] = recent.map { alert in
            .item(appMark(alert.appID, kind: alert.kind), alert.title, alert.body, SettingsTime(alert.date), tip: full.string(from: alert.date) + "\n" + alert.body)
        }
        if history.isEmpty {
            history = [.empty(.symbol("bell.slash", section.tint), "Nothing yet", "Alerts Wisp raises show up here and survive a restart.", nil)]
        }
        let clear = SettingsControls.pill("Clear") { [unowned self] in
            delegate.monitor.perform { $0.alerts.clear() }
            rebuild()
        }
        return [
            SettingsGroup("Tell me when", symbol: "bell.badge", summary: "Rules every app is checked against, also with every window closed.",
                          trailing: .text("\(ruleCount) of 5 on"), [
                rule(.cpu, "An app keeps a core busy", "For \(Int(rules.cpuMinutes)) minutes.", rules.cpuEnabled) { $0.cpuEnabled = $1 },
                rule(.memoryGrowth, "An app keeps growing in memory", "By \(Format.bytes(rules.memoryGrowthBytes)) in \(rules.memoryWindowMinutes) minutes.", rules.memoryEnabled) { $0.memoryEnabled = $1 },
                rule(.diskWrites, "An app writes a lot to disk", "\(Format.rate(rules.diskBytesPerSecond)) for \(Int(rules.diskMinutes)) minutes.", rules.diskEnabled) { $0.diskEnabled = $1 },
                rule(.network, "An app moves a lot of data", "\(Format.rate(rules.networkBytesPerSecond)) for \(Int(rules.networkMinutes)) minutes.", rules.networkEnabled) { $0.networkEnabled = $1 },
                rule(.temperature, "The CPU runs hot", "Above \(Format.celsius(rules.temperatureCelsius)) for \(Int(rules.temperatureMinutes)) minutes.", rules.temperatureEnabled) { $0.temperatureEnabled = $1 },
            ], footer: "Each app is mentioned at most once every \(Int(rules.cooldownMinutes)) minutes per rule.",
                          action: ("Notifications", { Self.openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension") })),
            SettingsGroup("App limits", symbol: "gauge.with.dots.needle.67percent", summary: "A memory or CPU limit for one app.",
                          trailing: rules.appLimits.isEmpty ? nil : .view(addLimit), limits),
            SettingsGroup("Recent", symbol: "clock", summary: recent.isEmpty ? "What Wisp told you, newest first." : "The last \(recent.count) Wisp raised, newest first.",
                          trailing: recent.isEmpty ? nil : .view(clear), history),
        ]
    }

    private func assistants() -> [SettingsGroup] {
        let s = delegate.settings
        let command = "claude mcp add wisp -- /Applications/Wisp.app/Contents/Helpers/wisp mcp"
        var planRows: [SettingsRow] = [
            .control("Show AI plan limits and tokens used today", PlanLimitsSetup.detail,
                     SettingsControls.toggle(s.planUsage) { [unowned self] on in
                         delegate.change { $0.planUsage = on }
                         PlanLimitsSetup.apply(on: on)
                         rebuildSoon()
                     }),
        ]
        let plans = delegate.plans.plans
        if s.planUsage {
            let ordered = plans.sorted { ($0.windows.map(\.used).max() ?? -1) > ($1.windows.map(\.used).max() ?? -1) }
            for usage in ordered {
                planRows.append(Self.planRow(usage, appearance: view.effectiveAppearance))
            }
            if plans.isEmpty {
                planRows.append(.loading("Reading each account's limits", "They show here once Claude Code, Codex or the Antigravity CLI answer, within a few minutes."))
            }
        }
        var groups = [
            SettingsGroup("MCP server", symbol: "point.3.connected.trianglepath.dotted", summary: "What coding agents may read from Wisp.",
                          trailing: .pill(s.allowMCP ? "On" : "Off", s.allowMCP ? .good : .neutral), [
                .control("Let Claude, Codex and Cursor read Wisp", "They see what the CLI prints. They can ask you to quit an app; nothing quits unless you agree.",
                         SettingsControls.toggle(s.allowMCP) { [unowned self] on in
                             delegate.change { $0.allowMCP = on }
                             rebuildSoon()
                         }),
                .flexible(SettingsCommand(title: "Add it to Claude Code", detail: "Run this once in Terminal.", command: command)),
            ]),
            SettingsGroup("Plan limits", symbol: "gauge.with.needle", summary: !s.planUsage ? "Off. No sign-ins are read." : plans.isEmpty ? "Asking each signed-in account." : "\(plans.count) \(plans.count == 1 ? "account" : "accounts"), closest to its limit first.",
                          trailing: .pill(s.planUsage ? "On" : "Off", s.planUsage ? .good : .neutral), planRows,
                          footer: s.planUsage ? "Each account's limits, resets and pace are on the Coding Agents page." : nil,
                          action: s.planUsage ? ("Coding Agents", { [unowned self] in delegate.showPage(.agents) }) : nil),
        ]
        if s.planUsage, AntigravityLive.seen() {
            let hidden = s.hiddenAntigravityLimits
            let usage = plans.first { $0.provider == "Antigravity" }
            let shown = AntigravityLive.limits.filter { !hidden.contains($0.name) }.count
            groups.insert(SettingsGroup("Antigravity limits", symbol: "sparkle", tint: Theme.blue, summary: "Which of its limits AI usage shows.",
                                        trailing: .text("\(shown) of \(AntigravityLive.limits.count) shown"), AntigravityLive.limits.map { limit in
                let window = usage?.windows.first { $0.name == limit.name }
                let toggle = SettingsControls.toggle(!hidden.contains(limit.name)) { [unowned self] _ in
                    UsageDropdown.toggleAntigravity(limit.name, delegate: delegate)
                    rebuildSoon()
                }
                var control = toggle
                if let window {
                    let meter = SettingsMeter()
                    meter.fraction = window.used
                    meter.frame.size = NSSize(width: 132, height: 20)
                    control = SettingsControls.row([meter, toggle])
                }
                return .item(.symbol(limit.name.hasPrefix("5-hour") ? "clock" : "calendar", Theme.blue), limit.title,
                             window.map { Self.resetDetail($0) } ?? "Not read yet.", control, tip: nil)
            }, footer: "Each model group has a 5-hour and a weekly limit. At least one stays on."), at: 1)
        }
        return groups
    }

    private func about() -> [SettingsGroup] {
        let s = delegate.settings
        let checked = UserDefaults.standard.double(forKey: "WispUpdateCheckedAt")
        aboutHero.release = delegate.availableRelease?.version
        aboutHero.checking = s.checkForUpdates
        var updates: [SettingsRow] = []
        if let release = delegate.availableRelease {
            let how = delegate.installedWithBrew ? "Run brew upgrade --cask wisp in Terminal, or download it." : "Download it from GitHub and replace this copy."
            updates.append(.item(.symbol("arrow.down.circle.fill", A2.warn), "Wisp \(release.version) is out", how, SettingsControls.pill("Show Release") {
                NSWorkspace.shared.open(release.page)
            }, tip: release.page.absoluteString))
        }
        if let notes = WhatsNew.current {
            updates.append(.item(.symbol("sparkles", section.tint), "What's new in Wisp \(UpdateNotes.shortName(notes.version))",
                                 "The changes in this version, as shown after the update.",
                                 SettingsControls.pill("What's New") { [unowned self] in delegate.showWhatsNew() }, tip: nil))
        }
        let last = checked > 0 ? "Last checked " + Date(timeIntervalSince1970: checked).formatted(date: .abbreviated, time: .shortened) + "." : "Not checked yet."
        updates.append(.control("Check for new versions", "Once a day Wisp asks GitHub for the latest version number. Nothing about you or this Mac is sent. " + (s.checkForUpdates ? last : ""),
                                SettingsControls.toggle(s.checkForUpdates) { [unowned self] on in
                                    delegate.change { $0.checkForUpdates = on }
                                    if on { delegate.checkForUpdates(force: true) }
                                    rebuildSoon()
                                }))
        return [
            SettingsGroup(nil, wide: true, [.flexible(aboutHero)]),
            SettingsGroup("Updates", symbol: "arrow.triangle.2.circlepath", summary: delegate.availableRelease == nil ? "This copy is Wisp \(Wisp.version)." : "A newer version is ready.", updates),
            SettingsGroup("Privacy", symbol: "hand.raised.fill", summary: "What Wisp keeps and what it sends.", [
                .item(.symbol("lock.fill", section.tint), "Nothing about you leaves this Mac",
                      "No analytics and no account. The only requests are host name lookups and the daily version check.", nil, tip: nil),
                .item(.symbol("folder.fill", section.tint), "History and settings", "~/Library/Application Support/Wisp",
                      SettingsControls.pill("Show in Finder") { Self.revealSupportFolder() }, tip: nil),
            ]),
        ]
    }

    private func appearancePicker(_ selected: Int, _ pick: @escaping (Int) -> Void) -> AppearancePicker {
        let picker = AppearancePicker(selected: selected)
        picker.onPick = pick
        return picker
    }

    // MARK: Section helpers

    /// The page whose colour a menu bar reading takes.
    static func tint(_ metric: MenuMetric) -> NSColor {
        switch metric {
        case .cpu: return PageID.cpu.tint
        case .memory: return PageID.memory.tint
        case .network: return PageID.network.tint
        case .gpu: return PageID.gpu.tint
        case .temperature: return PageID.sensors.tint
        case .battery, .power: return PageID.energy.tint
        case .disk: return PageID.disk.tint
        case .usage: return PageID.agents.tint
        }
    }

    /// An alert's symbol, in the colour of the page it is about.
    static func mark(_ kind: AlertKind) -> (String, NSColor) {
        switch kind {
        case .cpu: return ("cpu", PageID.cpu.tint)
        case .memoryGrowth: return ("memorychip", PageID.memory.tint)
        case .diskWrites: return ("internaldrive", PageID.disk.tint)
        case .network: return ("arrow.up.arrow.down", PageID.network.tint)
        case .temperature: return ("thermometer.medium", PageID.sensors.tint)
        case .appLimit: return ("gauge.with.dots.needle.67percent", Section.alerts.tint)
        }
    }

    /// The app's icon when it is running now, else the alert's symbol.
    private func appMark(_ appID: String, kind: AlertKind) -> SettingsMark {
        if let path = delegate.table.apps.first(where: { $0.id == appID })?.bundlePath {
            return .image(NSWorkspace.shared.icon(forFile: path))
        }
        let (symbol, tint) = Self.mark(kind)
        return .symbol(symbol, tint)
    }

    /// One account: its mark, its name, the fullest limit and when it resets, and a meter.
    private static func planRow(_ usage: PlanUsage, appearance: NSAppearance) -> SettingsRow {
        let mark = SettingsMark.image(AgentMark.image(usage.provider, size: RowView.markSize, appearance: appearance))
        let name = usage.label ?? usage.provider
        if let problem = usage.problem {
            return .item(mark, name, problem, nil, tip: usage.account)
        }
        guard let fullest = usage.windows.max(by: { $0.used < $1.used }) else {
            return .item(mark, name, "No limits reported yet.", nil, tip: usage.account)
        }
        let meter = SettingsMeter()
        meter.fraction = fullest.used
        meter.frame.size = NSSize(width: 132, height: 20)
        let plan = usage.plan.map { $0 + " · " } ?? ""
        return .item(mark, name, plan + windowDetail(fullest), meter, tip: usage.account)
    }

    /// "Resets in 2h 14m", or "Not started" for a limit with nothing used yet.
    private static func resetDetail(_ window: PlanUsage.Window) -> String {
        guard let resets = window.resets, resets > Date() else { return window.used > 0 ? "Resets when the window ends." : "Not started." }
        return "Resets in " + Format.duration(resets.timeIntervalSinceNow) + "."
    }

    /// "Weekly · resets in 5d 3h".
    private static func windowDetail(_ window: PlanUsage.Window) -> String {
        let title = PlanUsageFeed.limitTitle(window.name)
        guard let resets = window.resets, resets > Date() else { return title + " · " + Format.percent(window.used) + " used" }
        return title + " · resets in " + Format.duration(resets.timeIntervalSinceNow)
    }

    private static func revealSupportFolder() {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Wisp"),
              FileManager.default.fileExists(atPath: folder.path) else { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private static func openSystemSettings(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }


    // MARK: Menu bar items

    private lazy var menuPreview = MenuBarPreview(delegate: delegate)
    /// The menu bar item whose look is open for editing: the first one shown until another
    /// is picked, so the Look card beside the list starts with something in it.
    // WISP_MENU_EDIT=<metric> opens that item's look, for screenshots.
    private lazy var editing: Int? = ProcessInfo.processInfo.environment["WISP_MENU_EDIT"].flatMap(MenuMetric.init(rawValue:))
        .flatMap { metric in delegate.settings.menuItems.firstIndex { $0.metric == metric } }
        ?? delegate.settings.menuItems.firstIndex(where: \.enabled)

    /// "AI usage", or with an account picked, "AI usage, Codex (main)": its name, not its
    /// sign-in, which would wrap the row.
    private func itemTitle(_ item: MenuItemSetting) -> String {
        guard item.metric == .usage, !item.usageAccount.isEmpty,
              let usage = delegate.plans.plans.first(where: { $0.id == item.usageAccount }) else { return item.metric.title }
        return item.metric.title + ", " + (usage.label ?? usage.provider)
    }

    /// A second (or third) AI usage item after the last, on, with the first one's look,
    /// labelled with its account, and open for editing.
    private func addUsageItem(after index: Int) {
        let taken = Set(delegate.settings.menuItems.filter { $0.metric == .usage }.map(\.usageAccount))
        let plans = delegate.plans.plans.filter { $0.problem == nil }
        var item = MenuItemSetting(metric: .usage, enabled: true, style: .number)
        if let first = delegate.settings.menuItems.first(where: { $0.metric == .usage }) { item.adoptLook(of: first) }
        item.usageAccount = plans.first { !taken.contains($0.id) }?.id ?? plans.first?.id ?? ""
        if !item.usageAccount.isEmpty, item.label == .icon { item.label = .before }
        delegate.change { $0.menuItems.insert(item, at: index + 1) }
        editing = index + 1
        menuPreview.needsDisplay = true
        rebuild()
    }

    private func changeItem(_ index: Int, rebuilds: Bool = false, _ body: @escaping (inout MenuItemSetting) -> Void) {
        delegate.change { body(&$0.menuItems[index]) }
        menuPreview.needsDisplay = true
        if rebuilds { rebuild() }
    }

    private func itemEditor(_ index: Int, _ item: MenuItemSetting) -> [SettingsRow] {
        func popup<T: CaseIterable & Equatable>(_ current: T, _ title: @escaping (T) -> String, rebuilds: Bool = false,
                                                _ apply: @escaping (inout MenuItemSetting, T) -> Void) -> NSView {
            let all = Array(T.allCases)
            return SettingsControls.popup(all.map(title), all.firstIndex(of: current) ?? 0) { [unowned self] i in
                changeItem(index, rebuilds: rebuilds) { apply(&$0, all[i]) }
            }
        }
        var rows: [SettingsRow] = []
        if item.metric == .usage {
            // Accounts as they were last read, in the dropdown's order; the item follows the
            // most used until one is picked.
            let plans = delegate.plans.plans.filter { $0.problem == nil }
            let ids = [""] + plans.map(\.id)
            let names = ["Closest to its limit"] + plans.map(PlanUsageFeed.name)
            rows.append(.control("Account", plans.isEmpty ? "Accounts appear once Wisp has read their limits." : nil,
                                SettingsControls.popup(names, ids.firstIndex(of: item.usageAccount) ?? 0) { [unowned self] i in
                                    changeItem(index, rebuilds: true) {
                                        $0.usageAccount = ids[i]
                                        $0.usageLimit = ""
                                    }
                                }))
            // The usual choices, then each of the account's own limits when it has more
            // than a 5-hour and a weekly one (Antigravity has one of each per model group).
            var titles = UsageWindowChoice.allCases.map(\.title)
            var choices: [(inout MenuItemSetting) -> Void] = UsageWindowChoice.allCases.map { choice in
                { $0.usageWindow = choice; $0.usageLimit = "" }
            }
            var selected = item.usageLimit.isEmpty ? UsageWindowChoice.allCases.firstIndex(of: item.usageWindow) ?? 0 : 0
            if let usage = plans.first(where: { $0.id == item.usageAccount }), usage.windows.count > 2 {
                titles = titles.map { "Fullest " + $0.prefix(1).lowercased() + $0.dropFirst() }
                for window in usage.windows {
                    if window.name == item.usageLimit { selected = titles.count }
                    titles.append(PlanUsageFeed.limitTitle(window.name))
                    choices.append { $0.usageLimit = window.name }
                }
            }
            rows.append(.control("Shows", nil, SettingsControls.popup(titles, selected) { [unowned self] i in
                changeItem(index, rebuilds: true) { choices[i](&$0) }
            }))
            if delegate.settings.menuItems.filter({ $0.metric == .usage }).count > 1 {
                rows.append(.control("Remove this item", nil, SettingsControls.pill("Remove") { [unowned self] in
                    delegate.change { $0.menuItems.remove(at: index) }
                    editing = nil
                    menuPreview.needsDisplay = true
                    rebuild()
                }))
            }
        }
        rows.append(.control("Label", nil, popup(item.label, \.title, rebuilds: true) { $0.label = $1 }))
        if item.label == .above || item.label == .before {
            let usage = item.metric == .usage ? delegate.plans.plans.first { $0.id == item.usageAccount } : nil
            let fallback = usage.map(PlanUsageFeed.shortName) ?? item.metric.caption
            let field = SettingsControls.field(item.caption, placeholder: fallback, limit: 6) { [unowned self] text in
                changeItem(index) { $0.caption = text }
            }
            rows.append(.control("Label text", "Up to six characters. Empty shows \(fallback).", field))
            rows.append(.control("Label weight", nil, popup(item.captionWeight, \.title) { $0.captionWeight = $1 }))
        }
        rows += [
            .control("Text size", nil, popup(item.size, \.title) { $0.size = $1 }),
            .control("Number weight", nil, popup(item.weight, \.title) { $0.weight = $1 }),
            .control("Colour", nil, popup(item.color, \.title, rebuilds: true) { $0.color = $1 }),
        ]
        if item.color.isFixed {
            rows.append(.control("Colour applies to", nil, popup(item.colorPart, \.title) { $0.colorPart = $1 }))
        }
        rows += [
            .control("Keep a steady width", "Leaves room for the widest reading, so the items to its left stay put.",
                    SettingsControls.toggle(item.steady) { [unowned self] on in changeItem(index) { $0.steady = on } }),
            .control("Use this look for every item", "Label style, size, weights, colour and width. Label text stays per item.",
                    SettingsControls.pill("Apply to All") { [unowned self] in
                        delegate.change { settings in
                            let look = settings.menuItems[index]
                            for other in settings.menuItems.indices { settings.menuItems[other].adoptLook(of: look) }
                        }
                        menuPreview.needsDisplay = true
                    }),
        ]
        return rows
    }

    private func addLimit() {
        guard let window = view.window else { return }
        let apps = delegate.table.apps.sorted { $0.memory > $1.memory }.prefix(40)
        guard !apps.isEmpty else { return }
        let appMenu = NSPopUpButton()
        appMenu.addItems(withTitles: apps.map(\.name))
        let kindMenu = NSPopUpButton()
        kindMenu.addItems(withTitles: ["Memory over", "CPU over"])
        let amount = NSTextField(string: "4")
        amount.alignment = .right
        amount.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let unit = Style.label("GB")
        kindMenu.target = ActionTarget.shared
        ActionTarget.shared.run = { [weak kindMenu, weak amount, weak unit] in
            let cpu = kindMenu?.indexOfSelectedItem == 1
            unit?.stringValue = cpu ? "% of a core" : "GB"
            amount?.stringValue = cpu ? "150" : "4"
        }
        kindMenu.action = #selector(ActionTarget.fire)
        let line = Style.stack([kindMenu, amount, unit], axis: .horizontal, spacing: 6, alignment: .centerY)
        let accessory = Style.stack([appMenu, line], axis: .vertical, spacing: 8, alignment: .leading)
        accessory.frame.size = accessory.fittingSize
        let alert = NSAlert()
        alert.messageText = "Add an app limit"
        alert.informativeText = "Wisp tells you when the app stays over it for a minute."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [unowned self] response in
            guard response == .alertFirstButtonReturn, let value = Double(amount.stringValue.replacingOccurrences(of: ",", with: ".")), value > 0 else { return }
            let app = apps[apps.startIndex + appMenu.indexOfSelectedItem]
            var limit = AppLimit(appID: app.id, appName: app.name)
            if kindMenu.indexOfSelectedItem == 1 { limit.cpu = value / 100 } else { limit.memoryBytes = value * 1_073_741_824 }
            delegate.change { $0.alerts.appLimits.append(limit) }
            rebuild()
        }
    }
}

// MARK: - Controls that run a closure

final class ActionPopUp: NSPopUpButton {
    private let body: (Int) -> Void
    init(titles: [String], selected: Int, _ body: @escaping (Int) -> Void) {
        self.body = body
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        selectItem(at: selected)
        target = self
        action = #selector(picked)
        frame.size = fittingSize
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func picked() { body(indexOfSelectedItem) }
}

/// Lets a control in a modal sheet call a closure.
@MainActor
final class ActionTarget: NSObject {
    static let shared = ActionTarget()
    var run: (() -> Void)?
    @objc func fire() { run?() }
}
