import Foundation
import WispCore

enum MenuMetric: String, Codable, CaseIterable {
    case cpu, memory, network, gpu, temperature, battery, disk, power, usage

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .temperature: return "Temperature"
        case .battery: return "Battery"
        case .disk: return "Disk"
        case .power: return "Power"
        case .usage: return "AI usage"
        }
    }

    /// The default caption when an item is labelled with text.
    var caption: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .network: return "NET"
        case .gpu: return "GPU"
        case .temperature: return "TEMP"
        case .battery: return "BAT"
        case .disk: return "DISK"
        case .power: return "PWR"
        case .usage: return "AI"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .gpu: return "cube.transparent"
        case .temperature: return "thermometer.medium"
        case .battery: return "battery.75percent"
        case .disk: return "internaldrive"
        case .power: return "bolt"
        case .usage: return "sparkles"
        }
    }

    var demand: Demand {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .network: return .network
        case .gpu: return .gpu
        case .temperature: return .thermal
        case .battery: return .battery
        case .disk: return .disk
        case .power: return .power
        // Plan limits come from files read once a minute, not from sampling.
        case .usage: return []
        }
    }
}

/// Which plan limit the AI usage item shows.
enum UsageWindowChoice: String, Codable, CaseIterable {
    case session, week, both, sideBySide

    var title: String {
        switch self {
        case .session: return "5-hour"
        case .week: return "Weekly"
        case .both: return "5-hour over weekly"
        case .sideBySide: return "5-hour and weekly in a row"
        }
    }
}

/// What the temperature item reads.
enum TemperatureChoice: String, Codable, CaseIterable {
    case cpuAverage, cpuHottest

    var title: String {
        switch self {
        case .cpuAverage: return "CPU average"
        case .cpuHottest: return "Hottest CPU sensor"
        }
    }
}

enum MenuStyle: String, Codable, CaseIterable {
    case number, graph, both

    var title: String {
        switch self {
        case .number: return "Number"
        case .graph: return "Graph"
        case .both: return "Number and graph"
        }
    }
}

/// What sits in front of a reading: its symbol, a short caption over or before the
/// figure (the caption over it is the compact two-line look), or nothing.
enum MenuLabel: String, Codable, CaseIterable {
    case icon, above, before, none

    var title: String {
        switch self {
        case .icon: return "Icon"
        case .above: return "Text above"
        case .before: return "Text before"
        case .none: return "None"
        }
    }
}

enum MenuTextSize: String, Codable, CaseIterable {
    case small, regular, large

    var title: String { rawValue.capitalized }
}

enum MenuWeight: String, Codable, CaseIterable {
    case light, regular, medium, semibold, bold

    var title: String { rawValue.capitalized }
}

/// The two plain choices follow the menu bar's own colour; the rest are fixed hues.
/// Every choice but `.plain` turns red while the Mac is under strain.
enum MenuColor: String, Codable, CaseIterable {
    case standard, plain, blue, teal, green, yellow, orange, pink, purple

    var title: String {
        switch self {
        case .standard: return "Menu bar, red under strain"
        case .plain: return "Menu bar only"
        default: return rawValue.capitalized
        }
    }

    var isFixed: Bool { self != .standard && self != .plain }
}

/// Which part of an item a fixed colour paints.
enum MenuColorPart: String, Codable, CaseIterable {
    case all, label, value

    var title: String {
        switch self {
        case .all: return "Everything"
        case .label: return "Icon or text label"
        case .value: return "Reading"
        }
    }
}

struct MenuItemSetting: Codable, Equatable {
    var metric: MenuMetric
    var enabled: Bool
    var style: MenuStyle
    var label: MenuLabel = .icon
    /// Shown when `label` is text; empty means the metric's short name.
    var caption = ""
    var size: MenuTextSize = .regular
    var weight: MenuWeight = .regular
    /// The text label's own weight; small text usually wants more than the figure.
    var captionWeight: MenuWeight = .semibold
    var color: MenuColor = .standard
    var colorPart: MenuColorPart = .all
    /// Reserve room for the widest reading, so the items to the left do not shift.
    var steady = false
    /// AI usage only: the limit shown, and the account (a PlanUsage id; empty for the most used).
    var usageWindow: UsageWindowChoice = .session
    var usageAccount = ""
    /// AI usage only: one exact limit of the account (a window name, such as "Gemini this
    /// week"), in place of `usageWindow`. Empty for none.
    var usageLimit = ""
    var temperature: TemperatureChoice = .cpuAverage

    init(metric: MenuMetric, enabled: Bool, style: MenuStyle) {
        self.metric = metric
        self.enabled = enabled
        self.style = style
    }

    var shownCaption: String { caption.isEmpty ? metric.caption : caption }

    /// Copies everything about how an item looks, not what it shows.
    mutating func adoptLook(of other: MenuItemSetting) {
        label = other.label
        size = other.size
        weight = other.weight
        captionWeight = other.captionWeight
        color = other.color
        colorPart = other.colorPart
        steady = other.steady
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = try c.decode(MenuMetric.self, forKey: .metric)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        style = (try? c.decode(MenuStyle.self, forKey: .style)) ?? .number
        label = (try? c.decode(MenuLabel.self, forKey: .label)) ?? .icon
        caption = (try? c.decode(String.self, forKey: .caption)) ?? ""
        size = (try? c.decode(MenuTextSize.self, forKey: .size)) ?? .regular
        weight = (try? c.decode(MenuWeight.self, forKey: .weight)) ?? .regular
        captionWeight = (try? c.decode(MenuWeight.self, forKey: .captionWeight)) ?? .semibold
        color = (try? c.decode(MenuColor.self, forKey: .color)) ?? .standard
        colorPart = (try? c.decode(MenuColorPart.self, forKey: .colorPart)) ?? .all
        steady = (try? c.decode(Bool.self, forKey: .steady)) ?? false
        usageWindow = (try? c.decode(UsageWindowChoice.self, forKey: .usageWindow)) ?? .session
        usageAccount = (try? c.decode(String.self, forKey: .usageAccount)) ?? ""
        usageLimit = (try? c.decode(String.self, forKey: .usageLimit)) ?? ""
        temperature = (try? c.decode(TemperatureChoice.self, forKey: .temperature)) ?? .cpuAverage
    }
}

enum Look: String, Codable, CaseIterable {
    case light, dark, automatic
}

struct AppSettings: Codable, Equatable {
    var menuItems: [MenuItemSetting] = [
        MenuItemSetting(metric: .cpu, enabled: true, style: .number),
        MenuItemSetting(metric: .memory, enabled: true, style: .number),
        MenuItemSetting(metric: .network, enabled: false, style: .number),
        MenuItemSetting(metric: .gpu, enabled: false, style: .number),
        MenuItemSetting(metric: .temperature, enabled: false, style: .number),
        MenuItemSetting(metric: .battery, enabled: false, style: .number),
        MenuItemSetting(metric: .disk, enabled: false, style: .number),
        MenuItemSetting(metric: .power, enabled: false, style: .number),
    ]
    /// Seconds between readings while something is on screen.
    var interval: Double = 2
    /// Seconds between menu bar updates while no window or popover is open. Each
    /// update costs the menu bar a redraw, which is most of what an idle Wisp spends.
    var menuInterval: Double = 3
    /// Seconds between the quiet process passes that feed history and alerts.
    var backgroundInterval: Double = 10
    var keepHistory = true
    /// Per-app network in the background, for history and the network alert.
    var trackAppNetwork = false
    /// Show app CPU as a share of the whole machine instead of one core.
    var cpuOfMachine = false
    var alerts = AlertRules()
    var allowMCP = true
    /// Read each AI plan's limits with the sign-in its own tool keeps. Off until asked for.
    var planUsage = false
    /// Accounts (PlanUsage ids) the AI usage block leaves out.
    var hiddenUsageAccounts: [String] = []
    /// Antigravity limits (window names in `AntigravityLive.limits`) AI usage leaves out.
    var hiddenAntigravityLimits: [String] = []
    /// Accounts (PlanUsage ids) in the order the user dragged them into; others follow.
    var usageAccountOrder: [String] = []
    var look = Look.automatic
    var fahrenheit = false
    var bits = false
    var showInDock = false
    var openWindowAtLaunch = false
    /// The page a newly opened window starts on.
    var startPage = "overview"
    /// The blocks of the menu bar dashboard, top to bottom.
    var dashboard = DashboardBlock.defaultLayout
    /// A click on a menu bar item opens a dropdown about that reading instead of the dashboard.
    var itemDropdowns = true
    /// Once a day, ask GitHub for the latest release's number.
    var checkForUpdates = true
    /// The newest Wisp version that has run here, for showing What's New once after an
    /// update. Empty in settings saved before 0.5.0, which did not record it.
    var lastVersion = ""

    static let key = "settings"

    private enum LegacyKeys: String, CodingKey { case showIcons }
    private struct LegacyLabel: Decodable { var label: MenuLabel? }

    init() {}

    init(from decoder: Decoder) throws {
        // Every field falls back to its default, so settings saved by an older build still load.
        let fallback = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuItems = (try? c.decode([MenuItemSetting].self, forKey: .menuItems)) ?? fallback.menuItems
        // Before each item had its own label, one switch turned every icon off.
        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           (try? legacy.decode(Bool.self, forKey: .showIcons)) == false,
           let labels = try? c.decode([LegacyLabel].self, forKey: .menuItems) {
            for (index, item) in labels.enumerated() where item.label == nil && menuItems.indices.contains(index) {
                menuItems[index].label = .none
            }
        }
        interval = (try? c.decode(Double.self, forKey: .interval)) ?? fallback.interval
        backgroundInterval = (try? c.decode(Double.self, forKey: .backgroundInterval)) ?? fallback.backgroundInterval
        menuInterval = (try? c.decode(Double.self, forKey: .menuInterval)) ?? fallback.menuInterval
        keepHistory = (try? c.decode(Bool.self, forKey: .keepHistory)) ?? fallback.keepHistory
        trackAppNetwork = (try? c.decode(Bool.self, forKey: .trackAppNetwork)) ?? fallback.trackAppNetwork
        cpuOfMachine = (try? c.decode(Bool.self, forKey: .cpuOfMachine)) ?? fallback.cpuOfMachine
        alerts = (try? c.decode(AlertRules.self, forKey: .alerts)) ?? fallback.alerts
        allowMCP = (try? c.decode(Bool.self, forKey: .allowMCP)) ?? fallback.allowMCP
        planUsage = (try? c.decode(Bool.self, forKey: .planUsage)) ?? fallback.planUsage
        hiddenUsageAccounts = (try? c.decode([String].self, forKey: .hiddenUsageAccounts)) ?? fallback.hiddenUsageAccounts
        hiddenAntigravityLimits = (try? c.decode([String].self, forKey: .hiddenAntigravityLimits)) ?? fallback.hiddenAntigravityLimits
        usageAccountOrder = (try? c.decode([String].self, forKey: .usageAccountOrder)) ?? fallback.usageAccountOrder
        look = (try? c.decode(Look.self, forKey: .look)) ?? fallback.look
        fahrenheit = (try? c.decode(Bool.self, forKey: .fahrenheit)) ?? fallback.fahrenheit
        bits = (try? c.decode(Bool.self, forKey: .bits)) ?? fallback.bits
        showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? fallback.showInDock
        openWindowAtLaunch = (try? c.decode(Bool.self, forKey: .openWindowAtLaunch)) ?? fallback.openWindowAtLaunch
        startPage = (try? c.decode(String.self, forKey: .startPage)) ?? fallback.startPage
        // Read as names so a block this build does not know drops out instead of losing the whole layout.
        dashboard = DashboardBlock.layout(from: try? c.decode([String].self, forKey: .dashboard))
        itemDropdowns = (try? c.decode(Bool.self, forKey: .itemDropdowns)) ?? fallback.itemDropdowns
        checkForUpdates = (try? c.decode(Bool.self, forKey: .checkForUpdates)) ?? fallback.checkForUpdates
        lastVersion = (try? c.decode(String.self, forKey: .lastVersion)) ?? fallback.lastVersion
    }

    static func load() -> AppSettings {
        var settings = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        // Metrics added in later versions show up disabled at the end.
        for metric in MenuMetric.allCases where !settings.menuItems.contains(where: { $0.metric == metric }) {
            settings.menuItems.append(MenuItemSetting(metric: metric, enabled: false, style: .number))
        }
        // WISP_MENU=cpu.above.large.label-light,memory.icon.blue,... shows given menu bar items, for screenshots.
        if let list = ProcessInfo.processInfo.environment["WISP_MENU"] {
            let wanted = list.split(separator: ",").map { $0.split(separator: ".").map(String.init) }
            settings.menuItems = settings.menuItems.map { item in
                var item = item
                item.enabled = false
                return item
            }
            for words in wanted.reversed() {
                guard let metric = words.first.flatMap(MenuMetric.init(rawValue:)),
                      let index = settings.menuItems.firstIndex(where: { $0.metric == metric }) else { continue }
                var item = MenuItemSetting(metric: metric, enabled: true, style: .number)
                for word in words.dropFirst() {
                    if let style = MenuStyle(rawValue: word) { item.style = style }
                    if let label = MenuLabel(rawValue: word) { item.label = label }
                    if let size = MenuTextSize(rawValue: word) { item.size = size }
                    if let weight = MenuWeight(rawValue: word) { item.weight = weight }
                    if let color = MenuColor(rawValue: word) { item.color = color }
                    if let part = MenuColorPart(rawValue: word) { item.colorPart = part }
                    if word == "steady" { item.steady = true }
                    if let window = UsageWindowChoice(rawValue: word) { item.usageWindow = window }
                    if word.hasPrefix("label-"), let weight = MenuWeight(rawValue: String(word.dropFirst(6))) { item.captionWeight = weight }
                }
                settings.menuItems.remove(at: index)
                settings.menuItems.insert(item, at: 0)
            }
        }
        if ProcessInfo.processInfo.environment["WISP_DROPDOWNS"] != nil { settings.itemDropdowns = true }
        // WISP_DASHBOARD=cpu,gpu,... shows a given layout, for screenshots.
        if let names = ProcessInfo.processInfo.environment["WISP_DASHBOARD"] {
            settings.dashboard = DashboardBlock.layout(from: names.split(separator: ",").map(String.init))
        }
        return settings
    }

    func save() {
        // Screenshot and demo runs share the real app's defaults; they keep changes in memory.
        let env = ProcessInfo.processInfo.environment
        guard env["WISP_NO_SAVE"] == nil, env["WISP_BUILDER_DEMO"] == nil else { return }
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension AlertRules {
    var anyEnabled: Bool { cpuEnabled || memoryEnabled || diskEnabled || networkEnabled }
}
