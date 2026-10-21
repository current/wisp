import AppKit
import WispCore

/// One status item per enabled reading. An item is redrawn only when the text it
/// shows, its strain colour or its graph actually changes.
@MainActor
final class StatusBar {
    private final class Item {
        let setting: MenuItemSetting
        let statusItem: NSStatusItem
        var lastText = ""
        var lastStrained = false
        var lastGraph: [Float] = []

        init(setting: MenuItemSetting, statusItem: NSStatusItem) {
            self.setting = setting
            self.statusItem = statusItem
        }
    }

    private unowned let delegate: AppDelegate
    private var items: [Item] = []
    private static let symbols: [MenuMetric: NSImage] = {
        var result: [MenuMetric: NSImage] = [:]
        for metric in MenuMetric.allCases {
            result[metric] = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: metric.title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        }
        return result
    }()
    /// Shown when every reading is turned off, so the app can still be reached.
    private var fallback: NSStatusItem?

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func rebuild(_ settings: [MenuItemSetting]) {
        for item in items { NSStatusBar.system.removeStatusItem(item.statusItem) }
        items.removeAll()
        if let fallback { NSStatusBar.system.removeStatusItem(fallback) }
        fallback = nil

        // Status items are laid out right to left in creation order, so create the
        // last one first to keep the order the user picked.
        for setting in settings.reversed() where setting.enabled {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = "wisp." + setting.metric.rawValue
            configure(statusItem.button)
            items.insert(Item(setting: setting, statusItem: statusItem), at: 0)
        }
        if items.isEmpty {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Wisp")
            configure(statusItem.button)
            fallback = statusItem
        }
        update(delegate.system, history: delegate.monitor.history)
    }

    private func configure(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(sender)
        } else {
            delegate.toggleDashboard(from: sender)
        }
    }

    func openDashboard() {
        if let button = items.first?.statusItem.button ?? fallback?.button {
            delegate.toggleDashboard(from: button)
        }
    }

    private func showMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Wisp", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let item = items.first(where: { $0.statusItem.button === button })?.statusItem ?? fallback {
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
        }
    }

    @objc private func openWindow() { delegate.showWindow() }
    @objc private func openSettings() { delegate.showSettings() }

    // MARK: Drawing

    func update(_ snapshot: SystemSnapshot, history: HistoryStore) {
        let icons = delegate.settings.showIcons
        for item in items {
            guard let button = item.statusItem.button else { continue }
            let metric = item.setting.metric
            let reading = Self.reading(metric, snapshot)
            let wantsGraph = item.setting.style != .number
            let wantsText = item.setting.style != .graph
            let graph = wantsGraph ? Array(history.recent(metric.historyMetric).suffix(14)) : []

            let text = wantsText ? reading.text : ""
            guard text != item.lastText || reading.strained != item.lastStrained || graph != item.lastGraph else { continue }
            item.lastText = text
            item.lastStrained = reading.strained
            item.lastGraph = graph

            let tint: NSColor? = reading.strained ? .systemRed : nil
            let ceiling = reading.ceiling > 0 ? reading.ceiling : max(graph.filter { !$0.isNaN }.max() ?? 1, 1)
            let symbol = icons && !wantsGraph && metric != .network ? Self.symbols[metric] : nil
            let lines = metric == .network && wantsText && !wantsGraph ? reading.lines : nil
            // One bitmap per change: the menu bar re-snapshots a button whenever any part
            // of it changes, so a symbol plus an attributed title costs two passes.
            button.image = StatusImage.render(symbol: symbol, graph: wantsGraph ? (graph, ceiling) : nil,
                                              text: lines == nil ? text : "", lines: lines, tint: tint)
            let tip = metric.title + (reading.text.isEmpty ? "" : ": " + reading.text)
            if button.toolTip != tip { button.toolTip = tip }
        }
    }

    struct Reading {
        var text: String
        var strained: Bool
        var ceiling: Float
        var lines: (String, String)?
    }

    static func reading(_ metric: MenuMetric, _ s: SystemSnapshot) -> Reading {
        switch metric {
        case .cpu:
            return Reading(text: s.cpu.map { Format.percent($0.total) } ?? "–", strained: Strain.cpu(s.cpu), ceiling: 1)
        case .memory:
            return Reading(text: s.memory.map { Format.percent($0.usedFraction) } ?? "–", strained: Strain.memory(s.memory),
                           ceiling: Float(s.memory?.total ?? 1))
        case .network:
            guard let net = s.network else { return Reading(text: "–", strained: false, ceiling: 1) }
            let down = "↓" + Format.compactRate(net.receivedBytesPerSecond)
            let up = "↑" + Format.compactRate(net.sentBytesPerSecond)
            return Reading(text: down + " " + up, strained: false, ceiling: 0, lines: (up, down))
        case .gpu:
            return Reading(text: s.gpu?.utilization.map { Format.percent($0) } ?? "–", strained: Strain.gpu(s.gpu), ceiling: 1)
        case .temperature:
            return Reading(text: s.thermal?.cpuCelsius.map(Format.celsius) ?? "–", strained: Strain.temperature(s.thermal), ceiling: 110)
        case .battery:
            return Reading(text: s.battery.map { Format.percent($0.percent / 100) } ?? "–", strained: Strain.battery(s.battery), ceiling: 100)
        case .disk:
            guard let disk = s.disk else { return Reading(text: "–", strained: false, ceiling: 1) }
            return Reading(text: Format.compactRate(disk.readBytesPerSecond + disk.writeBytesPerSecond), strained: Strain.disk(s.disk), ceiling: 0)
        case .power:
            let watts = s.power.flatMap { p in p.system ?? p.cpu.map { $0 + (p.gpu ?? 0) + (p.ane ?? 0) } }
            return Reading(text: watts.map { String(format: "%.1fW", $0) } ?? "–", strained: false, ceiling: 0)
        }
    }
}

extension MenuMetric {
    var historyMetric: SystemMetric {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .network: return .networkIn
        case .gpu: return .gpu
        case .temperature: return .cpuTemperature
        case .battery: return .battery
        case .disk: return .diskWrite
        case .power: return .power
        }
    }
}
