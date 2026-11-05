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
            case .general: return "ri:settings-3-line"
            case .menuBar: return "ri:layout-top-line"
            case .display: return "ri:palette-line"
            case .alerts: return "ri:notification-3-line"
            case .assistants: return "ri:sparkling-line"
            case .cleanUp: return "ri:magic-line"
            case .about: return "ri:information-line"
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
        if section == .menuBar { builder.update(system: system) }
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
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -Toolbar.height))
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
                             popup(intervals.map { $0 == 1 ? "Second" : "\(Int($0)) seconds" }, intervals.firstIndex(of: s.interval) ?? 1) { [unowned self] i in
                                 delegate.change { $0.interval = intervals[i] }
                             }),
                    .control("Menu bar", "Redrawing the menu bar is most of what Wisp costs with every window closed.",
                             popup(menuIntervals.map { $0 == 1 ? "Every second" : "Every \(Int($0)) seconds" }, menuIntervals.firstIndex(of: s.menuInterval) ?? 2) { [unowned self] i in
                                 delegate.change { $0.menuInterval = menuIntervals[i] }
                             }),
                ]),
                SettingsGroup("History", [
                    .control("Keep a year of per-app history", "Minute by minute for a day, hourly totals for a year, on this Mac only.",
                             toggle(s.keepHistory) { [unowned self] on in delegate.change { $0.keepHistory = on } }),
                    .control("Track network per app in the background", "Off, per-app network is measured only while a window shows it.",
                             toggle(s.trackAppNetwork) { [unowned self] on in delegate.change { $0.trackAppNetwork = on } }),
                ]),
                SettingsGroup("Startup", [
                    .control("Open Wisp at login", nil, toggle(SMAppService.mainApp.status == .enabled) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSSound.beep()
                        }
                    }),
                ]),
            ]
        case .menuBar:
            var rows: [SettingsRow] = s.menuItems.enumerated().map { index, item in
                let style = popup(MenuStyle.allCases.map(\.title), MenuStyle.allCases.firstIndex(of: item.style) ?? 0) { [unowned self] i in
                    delegate.change { $0.menuItems[index].style = MenuStyle.allCases[i] }
                }
                let enable = toggle(item.enabled) { [unowned self] on in delegate.change { $0.menuItems[index].enabled = on } }
                return .pair(item.metric.title, item.metric.symbol, style, enable)
            }
            rows.append(.control("Show icons next to numbers", "A reading turns red when the Mac is under strain.",
                                 toggle(s.showIcons) { [unowned self] on in delegate.change { $0.showIcons = on } }))
            builder.needsLayout = true
            return [
                SettingsGroup("Dashboard", [
                    .custom(builder, builder.preferredHeight),
                    .control("Reset the dashboard", "Back to the CPU, meters, cores and apps.", pill("Reset to Default") { [unowned self] in builder.reset() }),
                ], footer: "The dashboard opens from the menu bar. It reads only what its blocks show, and nothing while it is closed."),
                SettingsGroup("Shown in the menu bar", rows),
            ]
        case .display:
            let looks = Look.allCases
            let pages = PageID.allCases.filter { $0 != .settings }
            return [
                SettingsGroup("Window", [
                    .control("Appearance", nil, popup(["Light", "Dark", "Match the system"], looks.firstIndex(of: s.look) ?? 0) { [unowned self] i in
                        delegate.change { $0.look = looks[i] }
                    }),
                    .control("Show Wisp in the Dock", nil, toggle(s.showInDock) { [unowned self] on in delegate.change { $0.showInDock = on } }),
                    .control("Open the window when Wisp starts", nil,
                             toggle(s.openWindowAtLaunch) { [unowned self] on in delegate.change { $0.openWindowAtLaunch = on } }),
                    .control("Start on", "The page a new window opens on.",
                             popup(pages.map(\.title), pages.firstIndex { $0.rawValue == s.startPage } ?? 0) { [unowned self] i in
                                 delegate.change { $0.startPage = pages[i].rawValue }
                             }),
                ]),
                SettingsGroup("Units", [
                    .control("App CPU", "How a busy app's CPU reads.", popup(["100% is one core", "100% is the whole Mac"], s.cpuOfMachine ? 1 : 0) { [unowned self] i in
                        delegate.change { $0.cpuOfMachine = i == 1 }
                    }),
                    .control("Temperature", nil, popup(["Celsius", "Fahrenheit"], s.fahrenheit ? 1 : 0) { [unowned self] i in
                        delegate.change { $0.fahrenheit = i == 1 }
                    }),
                    .control("Network", nil, popup(["Bytes per second", "Bits per second"], s.bits ? 1 : 0) { [unowned self] i in
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
                let remove = pill("Remove") { [unowned self] in
                    delegate.change { $0.alerts.appLimits.remove(at: index) }
                    rebuild()
                }
                return .control(limit.appName, "Tell me when it goes " + parts.joined(separator: " or ") + " for a minute.", remove)
            }
            limits.append(.control(rules.appLimits.isEmpty ? "No app limits yet" : "Add another", "A memory or CPU limit for one app.",
                                   pill("Add Limit…") { [unowned self] in addLimit() }))
            let recent = delegate.monitor.perform { $0.alerts.recent }.suffix(8).reversed()
            let time = DateFormatter()
            time.dateFormat = "MMM d, HH:mm"
            var history: [SettingsRow] = recent.map { .control($0.title, time.string(from: $0.date) + " · " + $0.body, nil) }
            if history.isEmpty {
                history = [.control("Nothing yet", "Alerts Wisp raises show up here and survive a restart.", nil)]
            } else {
                history.append(.control("", nil, pill("Clear History") { [unowned self] in
                    delegate.monitor.perform { $0.alerts.clear() }
                    rebuild()
                }))
            }
            return [
                SettingsGroup("Tell me when", [
                    .control("An app keeps a core busy", "For \(Int(rules.cpuMinutes)) minutes.",
                             toggle(rules.cpuEnabled) { [unowned self] on in delegate.change { $0.alerts.cpuEnabled = on } }),
                    .control("An app keeps growing in memory", "By \(Format.bytes(rules.memoryGrowthBytes)) in \(rules.memoryWindowMinutes) minutes.",
                             toggle(rules.memoryEnabled) { [unowned self] on in delegate.change { $0.alerts.memoryEnabled = on } }),
                    .control("An app writes a lot to disk", "\(Format.rate(rules.diskBytesPerSecond)) for \(Int(rules.diskMinutes)) minutes.",
                             toggle(rules.diskEnabled) { [unowned self] on in delegate.change { $0.alerts.diskEnabled = on } }),
                    .control("An app moves a lot of data", "\(Format.rate(rules.networkBytesPerSecond)) for \(Int(rules.networkMinutes)) minutes.",
                             toggle(rules.networkEnabled) { [unowned self] on in delegate.change { $0.alerts.networkEnabled = on } }),
                    .control("The CPU runs hot", "Above \(Format.celsius(rules.temperatureCelsius)) for \(Int(rules.temperatureMinutes)) minutes.",
                             toggle(rules.temperatureEnabled) { [unowned self] on in delegate.change { $0.alerts.temperatureEnabled = on } }),
                ], footer: "Each app is mentioned at most once every \(Int(rules.cooldownMinutes)) minutes per rule, also with every window closed."),
                SettingsGroup("App limits", limits),
                SettingsGroup("Recent", history),
            ]
        case .assistants:
            let command = "claude mcp add wisp -- /Applications/Wisp.app/Contents/Helpers/wisp mcp"
            return [
                SettingsGroup("MCP server", [
                    .control("Let Claude, Codex and Cursor read Wisp", "They see what the CLI prints. They can ask you to quit an app; nothing quits unless you agree.",
                             toggle(s.allowMCP) { [unowned self] on in delegate.change { $0.allowMCP = on } }),
                    .control("Add it to Claude Code", command, pill("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }),
                ]),
                SettingsGroup("Plan limits", [
                    .control("Show AI plan limits and tokens used today", "Adds Wisp to Claude Code's status line (yours keeps working) and reads Codex's session logs. No sign-ins are read and nothing is sent.",
                             toggle(s.planUsage) { [unowned self] on in
                                 delegate.change { $0.planUsage = on }
                                 PlanLimitsSetup.apply(on: on)
                             }),
                ]),
            ]
        case .cleanUp:
            return CleanUpSettings.groups(delegate.cleanUp, rebuild: { [unowned self] in rebuild() })
        case .about:
            return [
                SettingsGroup(nil, [.custom(AboutCard(), 168)]),
                SettingsGroup("Privacy", [
                    .control("Nothing leaves this Mac", "No analytics, no updater, no network requests beyond looking up host names. History lives in ~/Library/Application Support/Wisp.", nil),
                ]),
            ]
        }
    }

    // MARK: Controls

    private func toggle(_ on: Bool, _ body: @escaping (Bool) -> Void) -> NSView {
        ActionSwitch(on: on, body)
    }

    private func popup(_ titles: [String], _ selected: Int, _ body: @escaping (Int) -> Void) -> NSView {
        let button = MenuButton()
        button.titles = titles
        button.selected = selected
        button.onPick = body
        // As wide as the longest choice, so picking one does not move the button.
        let longest = titles.max { $0.count < $1.count } ?? ""
        let probe = MenuButton()
        probe.titles = [longest]
        button.frame.size = NSSize(width: probe.naturalWidth, height: 26)
        return button
    }

    private func pill(_ title: String, _ body: @escaping () -> Void) -> NSView {
        let pill = GlassPill(title)
        pill.onPress = body
        let width = ceil((title as NSString).size(withAttributes: [.font: Theme.sans(13, .semibold)]).width) + 32
        pill.frame.size = NSSize(width: width, height: 30)
        return pill
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

/// The scrolling column of a settings section: its title and its grouped cards.
@MainActor
final class SettingsPageView: NSView {
    var groups: [SettingsGroup] = []
    var width: CGFloat = 560
    private var built: [NSView] = []

    override var isFlipped: Bool { true }

    func relayout() {
        built.forEach { $0.removeFromSuperview() }
        built = []
        let inner = min(620, width - 48)
        let left = (width - inner) / 2
        var y: CGFloat = 8
        for group in groups {
            if let groupTitle = group.title {
                let caption = TextLine(Theme.caption(groupTitle))
                caption.frame = NSRect(x: left + 6, y: y, width: inner, height: 14)
                add(caption)
                y += 22
            }
            let card = CardView()
            card.radius = 14
            var rowY: CGFloat = 0
            for (index, row) in group.rows.enumerated() {
                let view = RowView(row, width: inner)
                view.frame.origin = NSPoint(x: 0, y: rowY)
                card.addSubview(view)
                rowY += view.frame.height
                if index < group.rows.count - 1 {
                    let rule = CardView()
                    rule.fill = Theme.rule
                    rule.stroke = .clear
                    rule.radius = 0
                    rule.frame = NSRect(x: 18, y: rowY, width: inner - 36, height: 1)
                    card.addSubview(rule)
                }
            }
            card.frame = NSRect(x: left, y: y, width: inner, height: rowY)
            add(card)
            y += rowY + 8
            if let footer = group.footer {
                let note = NSTextField(wrappingLabelWithString: footer)
                note.font = Theme.sans(11.5)
                note.textColor = Theme.inkTertiary
                note.preferredMaxLayoutWidth = inner - 12
                let size = note.sizeThatFits(NSSize(width: inner - 12, height: 200))
                note.frame = NSRect(x: left + 6, y: y, width: inner - 12, height: ceil(size.height))
                add(note)
                y += ceil(size.height) + 4
            }
            y += 18
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(y + 20, superview?.bounds.height ?? 0))
    }

    private func add(_ view: NSView) {
        addSubview(view)
        built.append(view)
    }
}

/// One row: title and explanation on the left, the control on the right.
@MainActor
final class RowView: NSView {
    override var isFlipped: Bool { true }

    init(_ row: SettingsRow, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        switch row {
        case .control(let title, let detail, let control):
            var controlWidth: CGFloat = 0
            if let control {
                let size = control.frame.size.width > 0 ? control.frame.size : control.fittingSize
                controlWidth = size.width
                addSubview(control)
                control.frame.size = size
            }
            let textWidth = width - 36 - (controlWidth > 0 ? controlWidth + 20 : 0)
            let titleField = Self.label(title, font: Theme.sans(13, .medium), color: Theme.ink, width: textWidth)
            var height: CGFloat = 16 + titleField.frame.height
            titleField.frame.origin = NSPoint(x: 18, y: 14)
            if !title.isEmpty { addSubview(titleField) } else { height = 14 }
            if let detail, !detail.isEmpty {
                let detailField = Self.label(detail, font: Theme.sans(11.5), color: Theme.inkSecondary, width: textWidth)
                detailField.frame.origin = NSPoint(x: 18, y: height)
                addSubview(detailField)
                height += detailField.frame.height + 2
            }
            height = max(48, height + 12)
            frame.size.height = height
            if let control {
                control.frame.origin = NSPoint(x: width - 18 - control.frame.width, y: (height - control.frame.height) / 2)
            }
        case .pair(let title, let symbol, let first, let second):
            let icon = NSImageView(image: IconTile.image(symbol, tint: Theme.accent, size: 24, appearance: NSApp.effectiveAppearance))
            icon.frame = NSRect(x: 18, y: 14, width: 24, height: 24)
            addSubview(icon)
            let titleField = Self.label(title, font: Theme.sans(13, .medium), color: Theme.ink, width: 200)
            titleField.frame.origin = NSPoint(x: 54, y: (52 - titleField.frame.height) / 2)
            addSubview(titleField)
            let secondSize = second.fittingSize
            second.frame = NSRect(x: width - 18 - secondSize.width, y: (52 - secondSize.height) / 2, width: secondSize.width, height: secondSize.height)
            let firstSize = NSSize(width: 170, height: first.fittingSize.height)
            first.frame = NSRect(x: second.frame.minX - 16 - firstSize.width, y: (52 - firstSize.height) / 2, width: firstSize.width, height: firstSize.height)
            addSubview(first)
            addSubview(second)
        case .custom(let view, let height):
            frame.size.height = height
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        let size = field.sizeThatFits(NSSize(width: width, height: 400))
        field.frame.size = NSSize(width: width, height: ceil(size.height))
        return field
    }
}

/// The app icon, name, version and what it costs to run.
final class AboutCard: DrawnView {
    override func draw(_ dirtyRect: NSRect) {
        if let icon = NSApp.applicationIconImage {
            icon.draw(in: NSRect(x: 18, y: 24, width: 96, height: 96), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSAttributedString(string: "Wisp", attributes: [.font: Theme.sans(24, .semibold), .foregroundColor: Theme.ink])
            .draw(at: NSPoint(x: 134, y: 30))
        Theme.caption("Version \(Wisp.version)", size: 10).draw(at: NSPoint(x: 136, y: 66))
        let text = "A system monitor that stays out of the way: about 0.2% of one core and 18 MB with only the menu bar showing."
        (text as NSString).draw(with: NSRect(x: 136, y: 88, width: bounds.width - 160, height: 60), options: [.usesLineFragmentOrigin],
                                attributes: [.font: Theme.sans(12.5), .foregroundColor: Theme.inkSecondary])
    }
}

// MARK: - Controls that run a closure

final class ActionSwitch: NSSwitch {
    private let body: (Bool) -> Void
    init(on: Bool, _ body: @escaping (Bool) -> Void) {
        self.body = body
        super.init(frame: .zero)
        state = on ? .on : .off
        target = self
        action = #selector(toggled)
        frame.size = fittingSize
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func toggled() { body(state == .on) }
}

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
