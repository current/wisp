import AppKit
import ServiceManagement
import WispCore

/// Settings, as a page of the main window: the sections are a segmented control in
/// the toolbar and each section is grouped cards with one setting per row. Every
/// control writes through AppDelegate.change, which saves and re-plans sampling at once.
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
            case .general: return Theme.dynamic(0x6B7280, 0x9AA3B2)
            case .menuBar: return Theme.dynamic(0x2F6BF0, 0x5C8DF6)
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
    private let headingTitle = TextLine()
    private let headingSubtitle = TextLine(Toolbar.subtitle("Settings"))
    private lazy var builder: DashboardBuilder = {
        let builder = DashboardBuilder(delegate: delegate)
        builder.onHeightChange = { [weak self] in self?.rebuild() }
        builder.onLayoutChange = { [weak self] in self?.updateDemand() }
        return builder
    }()

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
        // WISP_TAB=<0-6> opens on a given section, for screenshots.
        let start = ProcessInfo.processInfo.environment["WISP_TAB"].flatMap(Int.init).flatMap { Section.allCases.indices.contains($0) ? Section.allCases[$0] : nil }
        show(start ?? .general, animated: false)
    }

    /// The sections are listed in the sidebar; the toolbar names the one shown.
    var toolbarHeading: (NSView, NSView)? { (headingTitle, headingSubtitle) }
    var pageScroll: NSScrollView? { scroll }

    /// The builder's live preview needs what its blocks show; the core map is the one
    /// reading a window does not take anyway.
    var demand: Demand {
        section == .menuBar ? DashboardBlock.demand(of: delegate.settings.dashboard).intersection(.cpuCores) : []
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
        headingTitle.text = Toolbar.title(section.title)
        rebuild()
        updateDemand()
        // WISP_SCROLL=<points> scrolls part of the way, for screenshots.
        let offset = ProcessInfo.processInfo.environment["WISP_SCROLL"].flatMap(Double.init) ?? 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset - Toolbar.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        if animated { Motion.enter(page, from: CGPoint(x: 0, y: 6), duration: 0.2) }
    }

    /// Builds the current section again, after a change that adds or removes rows.
    func rebuild() {
        page.groups = groups(for: section)
        page.width = scroll.contentSize.width
        page.relayout()
    }

    // MARK: Sections

    private func groups(for section: Section) -> [SettingsGroup] {
        let s = delegate.settings
        switch section {
        case .general:
            let intervals: [Double] = [1, 2, 3, 5]
            let menuIntervals: [Double] = [1, 2, 3, 5, 10]
            return [
                SettingsGroup(nil, [
                    .control("Update every", "While a Wisp window or the dashboard is open.",
                             SettingsControls.popup(intervals.map { $0 == 1 ? "Second" : "\(Int($0)) seconds" }, intervals.firstIndex(of: s.interval) ?? 1) { [unowned self] i in
                                 delegate.change { $0.interval = intervals[i] }
                             }),
                    .control("Menu bar", "Redrawing the menu bar is most of what Wisp costs with every window closed.",
                             SettingsControls.popup(menuIntervals.map { $0 == 1 ? "Every second" : "Every \(Int($0)) seconds" }, menuIntervals.firstIndex(of: s.menuInterval) ?? 2) { [unowned self] i in
                                 delegate.change { $0.menuInterval = menuIntervals[i] }
                             }),
                ]),
                SettingsGroup("History", [
                    .control("Keep a year of per-app history", "Minute by minute for a day, hourly totals for a year, on this Mac only.",
                             SettingsControls.toggle(s.keepHistory) { [unowned self] on in delegate.change { $0.keepHistory = on } }),
                    .control("Track network per app in the background", "Off, per-app network is measured only while a window shows it.",
                             SettingsControls.toggle(s.trackAppNetwork) { [unowned self] on in delegate.change { $0.trackAppNetwork = on } }),
                ]),
                SettingsGroup("Startup", [
                    .control("Open Wisp at login", nil, SettingsControls.toggle(SMAppService.mainApp.status == .enabled) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSSound.beep()
                        }
                    }),
                ]),
            ]
        case .menuBar:
            var rows: [SettingsRow] = [.custom(menuPreview, MenuBarPreview.height)]
            for (index, item) in s.menuItems.enumerated() {
                let style = SettingsControls.popup(MenuStyle.allCases.map(\.title), MenuStyle.allCases.firstIndex(of: item.style) ?? 0) { [unowned self] i in
                    changeItem(index) { $0.style = MenuStyle.allCases[i] }
                }
                let open = editing == item.metric
                let edit = SettingsControls.pill(open ? "Done" : "Edit") { [unowned self] in
                    editing = open ? nil : item.metric
                    rebuild()
                }
                let enable = SettingsControls.toggle(item.enabled) { [unowned self] on in changeItem(index) { $0.enabled = on } }
                rows.append(.pair(item.metric.title, item.metric.symbol, SettingsControls.row([style, edit]), enable))
                if open { rows += itemEditor(index, item) }
            }
            builder.needsLayout = true
            return [
                SettingsGroup("Dashboard", [
                    .custom(builder, builder.preferredHeight),
                    .control("Reset the dashboard", "Back to the CPU, meters, cores and apps.", SettingsControls.pill("Reset to Default") { [unowned self] in builder.reset() }),
                ], footer: "The dashboard opens from the menu bar. It reads only what its blocks show, and nothing while it is closed."),
                SettingsGroup("Shown in the menu bar", rows,
                              footer: "Edit gives an item its own label, size, weight and colour. A reading turns red when the Mac is under strain, unless its colour is Menu bar only."),
            ]
        case .display:
            let looks = Look.allCases
            let pages = PageID.allCases.filter { $0 != .settings }
            return [
                SettingsGroup("Window", [
                    .control("Appearance", nil, SettingsControls.popup(["Light", "Dark", "Match the system"], looks.firstIndex(of: s.look) ?? 0) { [unowned self] i in
                        delegate.change { $0.look = looks[i] }
                    }),
                    .control("Show Wisp in the Dock", nil, SettingsControls.toggle(s.showInDock) { [unowned self] on in delegate.change { $0.showInDock = on } }),
                    .control("Open the window when Wisp starts", nil,
                             SettingsControls.toggle(s.openWindowAtLaunch) { [unowned self] on in delegate.change { $0.openWindowAtLaunch = on } }),
                    .control("Start on", "The page a new window opens on.",
                             SettingsControls.popup(pages.map(\.title), pages.firstIndex { $0.rawValue == s.startPage } ?? 0) { [unowned self] i in
                                 delegate.change { $0.startPage = pages[i].rawValue }
                             }),
                ]),
                SettingsGroup("Units", [
                    .control("App CPU", "How a busy app's CPU reads.", SettingsControls.popup(["100% is one core", "100% is the whole Mac"], s.cpuOfMachine ? 1 : 0) { [unowned self] i in
                        delegate.change { $0.cpuOfMachine = i == 1 }
                    }),
                    .control("Temperature", nil, SettingsControls.popup(["Celsius", "Fahrenheit"], s.fahrenheit ? 1 : 0) { [unowned self] i in
                        delegate.change { $0.fahrenheit = i == 1 }
                    }),
                    .control("Network", nil, SettingsControls.popup(["Bytes per second", "Bits per second"], s.bits ? 1 : 0) { [unowned self] i in
                        delegate.change { $0.bits = i == 1 }
                    }),
                ]),
            ]
        case .alerts:
            let rules = s.alerts
            var limits: [SettingsRow] = rules.appLimits.enumerated().map { index, limit in
                var parts: [String] = []
                if let bytes = limit.memoryBytes { parts.append("over \(Format.memory(bytes)) of memory") }
                if let cores = limit.cpu { parts.append("over \(Format.percent(cores)) CPU") }
                let remove = SettingsControls.pill("Remove") { [unowned self] in
                    delegate.change { $0.alerts.appLimits.remove(at: index) }
                    rebuild()
                }
                return .control(limit.appName, "Tell me when it goes " + parts.joined(separator: " or ") + " for a minute.", remove)
            }
            limits.append(.control(rules.appLimits.isEmpty ? "No app limits yet" : "Add another", "A memory or CPU limit for one app.",
                                   SettingsControls.pill("Add Limit…") { [unowned self] in addLimit() }))
            let recent = delegate.monitor.perform { $0.alerts.recent }.suffix(8).reversed()
            let time = DateFormatter()
            time.dateFormat = "MMM d, HH:mm"
            var history: [SettingsRow] = recent.map { .control($0.title, time.string(from: $0.date) + " · " + $0.body, nil) }
            if history.isEmpty {
                history = [.control("Nothing yet", "Alerts Wisp raises show up here and survive a restart.", nil)]
            } else {
                history.append(.control("", nil, SettingsControls.pill("Clear History") { [unowned self] in
                    delegate.monitor.perform { $0.alerts.clear() }
                    rebuild()
                }))
            }
            return [
                SettingsGroup("Tell me when", [
                    .control("An app keeps a core busy", "For \(Int(rules.cpuMinutes)) minutes.",
                             SettingsControls.toggle(rules.cpuEnabled) { [unowned self] on in delegate.change { $0.alerts.cpuEnabled = on } }),
                    .control("An app keeps growing in memory", "By \(Format.bytes(rules.memoryGrowthBytes)) in \(rules.memoryWindowMinutes) minutes.",
                             SettingsControls.toggle(rules.memoryEnabled) { [unowned self] on in delegate.change { $0.alerts.memoryEnabled = on } }),
                    .control("An app writes a lot to disk", "\(Format.rate(rules.diskBytesPerSecond)) for \(Int(rules.diskMinutes)) minutes.",
                             SettingsControls.toggle(rules.diskEnabled) { [unowned self] on in delegate.change { $0.alerts.diskEnabled = on } }),
                    .control("An app moves a lot of data", "\(Format.rate(rules.networkBytesPerSecond)) for \(Int(rules.networkMinutes)) minutes.",
                             SettingsControls.toggle(rules.networkEnabled) { [unowned self] on in delegate.change { $0.alerts.networkEnabled = on } }),
                    .control("The CPU runs hot", "Above \(Format.celsius(rules.temperatureCelsius)) for \(Int(rules.temperatureMinutes)) minutes.",
                             SettingsControls.toggle(rules.temperatureEnabled) { [unowned self] on in delegate.change { $0.alerts.temperatureEnabled = on } }),
                ], footer: "Each app is mentioned at most once every \(Int(rules.cooldownMinutes)) minutes per rule, also with every window closed."),
                SettingsGroup("App limits", limits),
                SettingsGroup("Recent", history),
            ]
        case .assistants:
            let command = "claude mcp add wisp -- /Applications/Wisp.app/Contents/Helpers/wisp mcp"
            return [
                SettingsGroup("MCP server", [
                    .control("Let Claude, Codex and Cursor read Wisp", "They see what the CLI prints. They can ask you to quit an app; nothing quits unless you agree.",
                             SettingsControls.toggle(s.allowMCP) { [unowned self] on in delegate.change { $0.allowMCP = on } }),
                    .control("Add it to Claude Code", command, SettingsControls.pill("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }),
                ]),
                SettingsGroup("Plan limits", [
                    .control("Show AI plan limits and tokens used today", "Adds Wisp to Claude Code's status line (yours keeps working) and reads Codex's session logs. No sign-ins are read and nothing is sent.",
                             SettingsControls.toggle(s.planUsage) { [unowned self] on in
                                 delegate.change { $0.planUsage = on }
                                 PlanLimitsSetup.apply(on: on)
                             }),
                ]),
            ]
        case .cleanUp:
            return CleanUpSettings.groups(delegate.cleanUp, rebuild: { [unowned self] in rebuild() })
        case .about:
            return [
                SettingsGroup(nil, [.custom(AboutCard(), AboutCard.height)]),
                SettingsGroup("Privacy", [
                    .control("Nothing leaves this Mac", "No analytics, no updater, no network requests beyond looking up host names. History lives in ~/Library/Application Support/Wisp.", nil),
                ]),
            ]
        }
    }


    // MARK: Menu bar items

    private lazy var menuPreview = MenuBarPreview(delegate: delegate)
    /// The menu bar item whose look is open for editing.
    // WISP_MENU_EDIT=<metric> opens that item's look, for screenshots.
    private var editing = ProcessInfo.processInfo.environment["WISP_MENU_EDIT"].flatMap(MenuMetric.init(rawValue:))

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
        var rows: [SettingsRow] = [
            .nested("Label", nil, popup(item.label, \.title, rebuilds: true) { $0.label = $1 }),
        ]
        if item.label == .above || item.label == .before {
            let field = SettingsControls.field(item.caption, placeholder: item.metric.caption, limit: 6) { [unowned self] text in
                changeItem(index) { $0.caption = text }
            }
            rows.append(.nested("Label text", "Up to six characters. Empty shows \(item.metric.caption).", field))
        }
        rows += [
            .nested("Text size", nil, popup(item.size, \.title) { $0.size = $1 }),
            .nested("Weight", nil, popup(item.weight, \.title) { $0.weight = $1 }),
            .nested("Colour", nil, popup(item.color, \.title, rebuilds: true) { $0.color = $1 }),
        ]
        if item.color.isFixed {
            rows.append(.nested("Colour applies to", nil, popup(item.colorPart, \.title) { $0.colorPart = $1 }))
        }
        rows += [
            .nested("Keep a steady width", "Leaves room for the widest reading, so the items to its left stay put.",
                    SettingsControls.toggle(item.steady) { [unowned self] on in changeItem(index) { $0.steady = on } }),
            .nested("Use this look for every item", "Label style, size, weight, colour and width. Label text stays per item.",
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

// MARK: - Building blocks

enum SettingsRow {
    /// A title, an optional line under it, and an optional control on the right.
    case control(String, String?, NSView?)
    /// A title with its symbol, a control, and a switch at the end (menu bar items).
    case pair(String, String, NSView, NSView)
    /// Any view, at a fixed height.
    case custom(NSView, CGFloat)
    /// A `.control` row that belongs to the row above it, its title in line with that row's.
    case nested(String, String?, NSView?)
}

struct SettingsGroup {
    var title: String?
    var rows: [SettingsRow]
    var footer: String?

    init(_ title: String?, _ rows: [SettingsRow], footer: String? = nil) {
        self.title = title
        self.rows = rows
        self.footer = footer
    }
}

/// The scrolling column of a settings section: grouped cards, each under a caption,
/// in a 620 pt column centred on the page, as in the A2 Settings mockup.
@MainActor
final class SettingsPageView: NSView {
    var groups: [SettingsGroup] = []
    var width: CGFloat = 560
    private var built: [NSView] = []

    /// The mockup's spacing: 26 pt under a card, 8 between a caption and its card.
    private static let groupGap: CGFloat = 26
    private static let captionFont = Theme.sans(12, .semibold)
    private static let footerFont = Theme.sans(11.5)

    override var isFlipped: Bool { true }

    func relayout() {
        built.forEach { $0.removeFromSuperview() }
        built = []
        let inner = min(620, width - 44)
        let left = ((width - inner) / 2).rounded()
        var y: CGFloat = 8
        for group in groups {
            if let groupTitle = group.title {
                let caption = TextLine(NSAttributedString(string: groupTitle, attributes: [.font: Self.captionFont, .foregroundColor: A2.secondary]))
                caption.frame = NSRect(x: left + 6, y: y, width: inner - 12, height: 15)
                add(caption)
                y += 23
            }
            let card = CardView()
            card.radius = A2.radius
            var rowY: CGFloat = 0
            for (index, row) in group.rows.enumerated() {
                let view = RowView(row, width: inner)
                view.frame.origin = NSPoint(x: 0, y: rowY)
                card.addSubview(view)
                rowY += view.frame.height
                if index < group.rows.count - 1 {
                    let rule = CardView()
                    rule.fill = A2.hairline
                    rule.stroke = .clear
                    rule.radius = 0
                    rule.frame = NSRect(x: RowView.inset, y: rowY - 0.5, width: inner - RowView.inset * 2, height: 0.5)
                    card.addSubview(rule)
                }
            }
            card.frame = NSRect(x: left, y: y, width: inner, height: rowY)
            add(card)
            y += rowY
            if let footer = group.footer {
                let note = NSTextField(wrappingLabelWithString: footer)
                note.font = Self.footerFont
                note.textColor = A2.secondary
                note.isSelectable = false
                note.preferredMaxLayoutWidth = inner - 12
                let size = note.sizeThatFits(NSSize(width: inner - 12, height: 200))
                note.frame = NSRect(x: left + 6, y: y + 8, width: inner - 12, height: ceil(size.height))
                add(note)
                y += 8 + ceil(size.height) - 4
            }
            y += Self.groupGap
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(y - Self.groupGap + 22, superview?.bounds.height ?? 0))
    }

    private func add(_ view: NSView) {
        addSubview(view)
        built.append(view)
    }
}

/// One row: title and explanation on the left, the control on the right. 16 pt in
/// from the card's edges, 11 above and below the text, at least 48 tall.
@MainActor
final class RowView: NSView {
    static let inset: CGFloat = 16
    private static let gap: CGFloat = 16
    private static let minHeight: CGFloat = 48
    private static let titleFont = Theme.sans(13, .medium)
    private static let detailFont = Theme.sans(11.5)

    override var isFlipped: Bool { true }

    init(_ row: SettingsRow, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.minHeight))
        let inset = Self.inset
        switch row {
        case .control(let title, let detail, let control):
            layoutControl(title, detail, control, width: width, textInset: inset)
        case .nested(let title, let detail, let control):
            layoutControl(title, detail, control, width: width, textInset: inset + 24 + 12)
        case .pair(let title, let symbol, let first, let second):
            let height = Self.minHeight
            let icon = SymbolTile(symbol)
            icon.frame = NSRect(x: inset, y: (height - 24) / 2, width: 24, height: 24)
            addSubview(icon)
            let secondSize = second.frame.size.width > 0 ? second.frame.size : second.fittingSize
            second.frame = NSRect(x: width - inset - secondSize.width, y: ((height - secondSize.height) / 2).rounded(),
                                  width: secondSize.width, height: secondSize.height)
            let firstSize = first.frame.size
            first.frame = NSRect(x: second.frame.minX - Self.gap - firstSize.width, y: ((height - firstSize.height) / 2).rounded(),
                                 width: firstSize.width, height: firstSize.height)
            let titleX = inset + 24 + 12
            let titleField = Self.label(title, font: Self.titleFont, color: A2.primary, width: max(40, first.frame.minX - Self.gap - titleX))
            titleField.frame.origin = NSPoint(x: titleX, y: ((height - titleField.frame.height) / 2).rounded())
            addSubview(titleField)
            addSubview(first)
            addSubview(second)
        case .custom(let view, let height):
            frame.size.height = height
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            addSubview(view)
        }
    }

    private func layoutControl(_ title: String, _ detail: String?, _ control: NSView?, width: CGFloat, textInset: CGFloat) {
        let inset = Self.inset
        var controlWidth: CGFloat = 0
        if let control {
            let size = control.frame.size.width > 0 ? control.frame.size : control.fittingSize
            controlWidth = size.width
            addSubview(control)
            control.frame.size = size
        }
        let textWidth = width - textInset - inset - (controlWidth > 0 ? controlWidth + Self.gap : 0)
        var fields: [NSTextField] = []
        if !title.isEmpty { fields.append(Self.label(title, font: Self.titleFont, color: A2.primary, width: textWidth)) }
        if let detail, !detail.isEmpty { fields.append(Self.label(detail, font: Self.detailFont, color: A2.secondary, width: textWidth)) }
        let textHeight = fields.map(\.frame.height).reduce(0, +) + (fields.count > 1 ? 3 : 0)
        let height = max(Self.minHeight, textHeight + 22)
        frame.size.height = height
        var y = ((height - textHeight) / 2).rounded()
        for field in fields {
            field.frame.origin = NSPoint(x: textInset, y: y)
            addSubview(field)
            y += field.frame.height + 3
        }
        if let control {
            control.frame.origin = NSPoint(x: width - inset - control.frame.width, y: ((height - control.frame.height) / 2).rounded())
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Tracked in by 0.006 em, as the mockup's text is.
    private static func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: -0.006 * font.pointSize])
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        let size = field.sizeThatFits(NSSize(width: width, height: 400))
        field.frame.size = NSSize(width: width, height: ceil(size.height))
        return field
    }
}

/// A metric's symbol on a tinted tile, drawn for the current appearance so it follows
/// a switch between light and dark.
final class SymbolTile: DrawnView {
    private let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        IconTile.image(symbol, tint: Theme.accent, size: bounds.width, appearance: effectiveAppearance)
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The app icon, then the name, version and what it costs to run, centred beside it.
final class AboutCard: DrawnView {
    static let height: CGFloat = 128
    private static let blurb = "A system monitor that stays out of the way: about 0.2% of one core and 18 MB with only the menu bar showing."
    private static let nameFont = Theme.sans(22, .semibold)
    private static let versionFont = Theme.sans(11.5)
    private static let blurbFont = Theme.sans(13)

    override func draw(_ dirtyRect: NSRect) {
        let iconSize: CGFloat = 80
        if let icon = NSApp.applicationIconImage {
            icon.draw(in: NSRect(x: RowView.inset, y: ((bounds.height - iconSize) / 2).rounded(), width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let x = RowView.inset + iconSize + 16
        let room = bounds.width - x - RowView.inset
        let name = NSAttributedString(string: "Wisp", attributes: [.font: Self.nameFont, .foregroundColor: A2.primary])
        let version = NSAttributedString(string: "Version \(Wisp.version)", attributes: [.font: Self.versionFont, .foregroundColor: A2.secondary])
        let blurb = NSAttributedString(string: Self.blurb, attributes: [.font: Self.blurbFont, .foregroundColor: A2.secondary])
        let nameHeight = ceil(Self.nameFont.ascender - Self.nameFont.descender)
        let versionHeight = ceil(Self.versionFont.ascender - Self.versionFont.descender)
        let blurbHeight = ceil(blurb.boundingRect(with: NSSize(width: room, height: 80), options: [.usesLineFragmentOrigin]).height)
        var y = ((bounds.height - nameHeight - 2 - versionHeight - 8 - blurbHeight) / 2).rounded()
        name.draw(at: NSPoint(x: x, y: y))
        y += nameHeight + 2
        version.draw(at: NSPoint(x: x, y: y))
        y += versionHeight + 8
        blurb.draw(with: NSRect(x: x, y: y, width: room, height: blurbHeight), options: [.usesLineFragmentOrigin])
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
