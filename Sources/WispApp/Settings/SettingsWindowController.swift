import AppKit
import ServiceManagement
import WispCore

/// One window, three tabs. Every control writes through AppDelegate.change, which
/// saves and re-plans sampling straight away.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let delegate: AppDelegate
    private let tabs = NSTabViewController()

    init(delegate: AppDelegate) {
        self.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item("Menu Bar", "menubar.rectangle", MenuBarPane(delegate: delegate)))
        tabs.addTabViewItem(item("General", "gearshape", GeneralPane(delegate: delegate)))
        tabs.addTabViewItem(item("Display", "paintbrush", DisplayPane(delegate: delegate)))
        tabs.addTabViewItem(item("Alerts", "bell", AlertsPane(delegate: delegate)))
        // WISP_TAB=1 opens on a given tab, for screenshots.
        if let index = ProcessInfo.processInfo.environment["WISP_TAB"].flatMap(Int.init) { tabs.selectedTabViewItemIndex = index }
        window.contentViewController = tabs
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func item(_ label: String, _ symbol: String, _ controller: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    func windowWillClose(_ notification: Notification) { delegate.settingsClosed() }
}

/// Shared form layout: right-aligned labels, controls on the left edge of a second column.
@MainActor
class Pane: NSViewController {
    unowned let delegate: AppDelegate
    let grid = NSGridView()

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Style.gap + 2
        grid.columnSpacing = Style.gap
        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Style.section),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Style.section),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Style.section),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        view = root
        build()
        if grid.numberOfColumns > 1 {
            grid.column(at: 0).xPlacement = .trailing
        }
    }

    func build() {}

    /// Builds the rows again after a change that adds or removes some.
    func rebuild() {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        build()
        if grid.numberOfColumns > 1 { grid.column(at: 0).xPlacement = .trailing }
        let size = view.fittingSize
        preferredContentSize = size
        if let window = view.window {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: true)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The tab controller resizes the window to each pane's preferred size.
        preferredContentSize = view.fittingSize
    }

    func row(_ label: String, _ control: NSView) {
        grid.addRow(with: [Style.label(label), control])
    }

    func note(_ text: String) {
        let label = Style.secondary(text)
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 300
        label.maximumNumberOfLines = 0
        grid.addRow(with: [NSGridCell.emptyContentView, label])
    }

    func gap() {
        grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        grid.row(at: grid.numberOfRows - 1).height = 6
    }

    func checkbox(_ title: String, _ on: Bool, _ body: @escaping (Bool) -> Void) -> NSButton {
        let box = ActionCheckbox(title: title, on: on, body)
        return box
    }

    func popup(_ titles: [String], selected: Int, _ body: @escaping (Int) -> Void) -> NSPopUpButton {
        ActionPopUp(titles: titles, selected: selected, body)
    }
}

final class ActionCheckbox: NSButton {
    private let body: (Bool) -> Void
    init(title: String, on: Bool, _ body: @escaping (Bool) -> Void) {
        self.body = body
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = on ? .on : .off
        target = self
        action = #selector(toggled)
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
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func picked() { body(indexOfSelectedItem) }
}

final class MenuBarPane: Pane {
    override func build() {
        for (index, item) in delegate.settings.menuItems.enumerated() {
            let enable = checkbox(item.metric.title, item.enabled) { [unowned self] on in
                delegate.change { $0.menuItems[index].enabled = on }
            }
            let style = popup(MenuStyle.allCases.map(\.title), selected: MenuStyle.allCases.firstIndex(of: item.style) ?? 0) { [unowned self] i in
                delegate.change { $0.menuItems[index].style = MenuStyle.allCases[i] }
            }
            style.controlSize = .small
            grid.addRow(with: [enable, style])
        }
        gap()
        grid.addRow(with: [NSGridCell.emptyContentView, checkbox("Show icons next to numbers", delegate.settings.showIcons) { [unowned self] on in
            delegate.change { $0.showIcons = on }
        }])
        note("A reading turns red when the Mac is under strain.")
    }

    override func loadView() {
        super.loadView()
        grid.column(at: 0).xPlacement = .leading
    }
}

final class GeneralPane: Pane {
    private static let intervals: [Double] = [1, 2, 3, 5]

    override func build() {
        let s = delegate.settings
        let intervals = Self.intervals
        row("Update every:", popup(intervals.map { $0 == 1 ? "second" : "\(Int($0)) seconds" },
                                   selected: intervals.firstIndex(of: s.interval) ?? 1) { [unowned self] i in
            delegate.change { $0.interval = intervals[i] }
        })
        note("While a Wisp window or the dashboard is open.")
        let menuIntervals: [Double] = [1, 2, 3, 5, 10]
        row("Menu bar:", popup(menuIntervals.map { $0 == 1 ? "every second" : "every \(Int($0)) seconds" },
                                selected: menuIntervals.firstIndex(of: s.menuInterval) ?? 2) { [unowned self] i in
            delegate.change { $0.menuInterval = menuIntervals[i] }
        })
        note("Redrawing the menu bar is most of what Wisp costs when no window is open. With every window closed it also checks apps every \(Int(s.backgroundInterval)) seconds for history and alerts.")
        gap()
        row("History:", checkbox("Keep a year of per-app history", s.keepHistory) { [unowned self] on in
            delegate.change { $0.keepHistory = on }
        })
        row("", checkbox("Track network use per app in the background", s.trackAppNetwork) { [unowned self] on in
            delegate.change { $0.trackAppNetwork = on }
        })
        gap()
        row("Assistants:", checkbox("Let Claude, Codex and Cursor read Wisp", s.allowMCP) { [unowned self] on in
            delegate.change { $0.allowMCP = on }
        })
        note("Read only. Add it with: claude mcp add wisp -- /Applications/Wisp.app/Contents/Helpers/wisp mcp")
        row("", checkbox("Show AI plan limits and tokens used today", s.planUsage) { [unowned self] on in
            delegate.change { $0.planUsage = on }
        })
        note("Uses each tool's own sign-in, sent only to the company that issued it")
        gap()
        row("Startup:", checkbox("Open Wisp at login", SMAppService.mainApp.status == .enabled) { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        })
    }
}

final class AlertsPane: Pane {
    override func build() {
        let rules = delegate.settings.alerts
        row("CPU:", checkbox("An app keeps a core busy for \(Int(rules.cpuMinutes)) minutes", rules.cpuEnabled) { [unowned self] on in
            delegate.change { $0.alerts.cpuEnabled = on }
        })
        row("Memory:", checkbox("An app grows by \(Format.bytes(rules.memoryGrowthBytes)) in \(rules.memoryWindowMinutes) minutes", rules.memoryEnabled) { [unowned self] on in
            delegate.change { $0.alerts.memoryEnabled = on }
        })
        row("Disk:", checkbox("An app writes \(Format.rate(rules.diskBytesPerSecond)) for \(Int(rules.diskMinutes)) minutes", rules.diskEnabled) { [unowned self] on in
            delegate.change { $0.alerts.diskEnabled = on }
        })
        row("Network:", checkbox("An app moves \(Format.rate(rules.networkBytesPerSecond)) for \(Int(rules.networkMinutes)) minutes", rules.networkEnabled) { [unowned self] on in
            delegate.change { $0.alerts.networkEnabled = on }
        })
        row("Temperature:", checkbox("The CPU stays above \(Format.celsius(rules.temperatureCelsius)) for \(Int(rules.temperatureMinutes)) minutes", rules.temperatureEnabled) { [unowned self] on in
            delegate.change { $0.alerts.temperatureEnabled = on }
        })
        gap()
        for (index, limit) in rules.appLimits.enumerated() {
            row(index == 0 ? "App limits:" : "", limitRow(limit, index: index))
        }
        let add = NSButton(title: "Add Limit…", target: self, action: #selector(addLimit))
        add.bezelStyle = .push
        row(rules.appLimits.isEmpty ? "App limits:" : "", add)
        note("Tell me when one app goes over a memory or CPU limit for a minute.")
        gap()
        let recent = delegate.monitor.perform { $0.alerts.recent }.suffix(6).reversed()
        let time = DateFormatter()
        time.dateFormat = Calendar.current.isDateInToday(recent.first?.date ?? Date()) ? "HH:mm" : "MMM d HH:mm"
        let list = Style.secondary(recent.isEmpty ? "Nothing yet." : recent.map { time.string(from: $0.date) + "  " + $0.title }.joined(separator: "\n"))
        list.maximumNumberOfLines = 0
        list.preferredMaxLayoutWidth = 300
        row("Recent:", list)
        if !recent.isEmpty {
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearHistory))
            clear.bezelStyle = .push
            row("", clear)
        }
        gap()
        note("Each app is mentioned at most once every \(Int(rules.cooldownMinutes)) minutes per rule. Alerts are checked in the background even with every window closed.")
    }

    private func limitRow(_ limit: AppLimit, index: Int) -> NSView {
        var parts: [String] = []
        if let bytes = limit.memoryBytes { parts.append("over \(Format.memory(bytes)) of memory") }
        if let cores = limit.cpu { parts.append("over \(Format.percent(cores)) CPU") }
        let label = Style.label(limit.appName + ", " + parts.joined(separator: " or "))
        let remove = ActionItemButton(symbol: "minus.circle", label: "Remove limit for \(limit.appName)") { [unowned self] in
            delegate.change { $0.alerts.appLimits.remove(at: index) }
            rebuild()
        }
        return Style.stack([label, remove], axis: .horizontal, spacing: 6, alignment: .centerY)
    }

    @objc private func addLimit() {
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

    @objc private func clearHistory() {
        delegate.monitor.perform { $0.alerts.clear() }
        rebuild()
    }
}

/// A small borderless symbol button that runs a closure.
final class ActionItemButton: NSButton {
    private let body: () -> Void
    init(symbol: String, label: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        isBordered = false
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { body() }
}

/// Lets a control in a modal sheet call a closure.
@MainActor
final class ActionTarget: NSObject {
    static let shared = ActionTarget()
    var run: (() -> Void)?
    @objc func fire() { run?() }
}

/// How Wisp looks and where it shows up.
final class DisplayPane: Pane {
    override func build() {
        let s = delegate.settings
        let looks = Look.allCases
        row("Appearance:", popup(["Light", "Dark", "Match the system"], selected: looks.firstIndex(of: s.look) ?? 0) { [unowned self] i in
            delegate.change { $0.look = looks[i] }
        })
        row("", checkbox("Show Wisp in the Dock", s.showInDock) { [unowned self] on in
            delegate.change { $0.showInDock = on }
        })
        row("", checkbox("Open the window when Wisp starts", s.openWindowAtLaunch) { [unowned self] on in
            delegate.change { $0.openWindowAtLaunch = on }
        })
        let pages = PageID.allCases
        row("Start on:", popup(pages.map(\.title), selected: pages.firstIndex { $0.rawValue == s.startPage } ?? 0) { [unowned self] i in
            delegate.change { $0.startPage = pages[i].rawValue }
        })
        gap()
        row("App CPU:", popup(["100% is one core", "100% is the whole Mac"], selected: s.cpuOfMachine ? 1 : 0) { [unowned self] i in
            delegate.change { $0.cpuOfMachine = i == 1 }
        })
        row("Temperature:", popup(["Celsius", "Fahrenheit"], selected: s.fahrenheit ? 1 : 0) { [unowned self] i in
            delegate.change { $0.fahrenheit = i == 1 }
        })
        row("Network:", popup(["Bytes per second", "Bits per second"], selected: s.bits ? 1 : 0) { [unowned self] i in
            delegate.change { $0.bits = i == 1 }
        })
    }
}
