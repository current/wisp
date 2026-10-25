import Foundation
import WispCore

enum MenuMetric: String, Codable, CaseIterable {
    case cpu, memory, network, gpu, temperature, battery, disk, power

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

struct MenuItemSetting: Codable, Equatable {
    var metric: MenuMetric
    var enabled: Bool
    var style: MenuStyle
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
    var showIcons = true
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
    var look = Look.light
    var fahrenheit = false
    var bits = false
    var showInDock = false
    var openWindowAtLaunch = false
    /// The page a newly opened window starts on.
    var startPage = "overview"

    static let key = "settings"

    init() {}

    init(from decoder: Decoder) throws {
        // Every field falls back to its default, so settings saved by an older build still load.
        let fallback = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuItems = (try? c.decode([MenuItemSetting].self, forKey: .menuItems)) ?? fallback.menuItems
        showIcons = (try? c.decode(Bool.self, forKey: .showIcons)) ?? fallback.showIcons
        interval = (try? c.decode(Double.self, forKey: .interval)) ?? fallback.interval
        backgroundInterval = (try? c.decode(Double.self, forKey: .backgroundInterval)) ?? fallback.backgroundInterval
        menuInterval = (try? c.decode(Double.self, forKey: .menuInterval)) ?? fallback.menuInterval
        keepHistory = (try? c.decode(Bool.self, forKey: .keepHistory)) ?? fallback.keepHistory
        trackAppNetwork = (try? c.decode(Bool.self, forKey: .trackAppNetwork)) ?? fallback.trackAppNetwork
        cpuOfMachine = (try? c.decode(Bool.self, forKey: .cpuOfMachine)) ?? fallback.cpuOfMachine
        alerts = (try? c.decode(AlertRules.self, forKey: .alerts)) ?? fallback.alerts
        allowMCP = (try? c.decode(Bool.self, forKey: .allowMCP)) ?? fallback.allowMCP
        planUsage = (try? c.decode(Bool.self, forKey: .planUsage)) ?? fallback.planUsage
        look = (try? c.decode(Look.self, forKey: .look)) ?? fallback.look
        fahrenheit = (try? c.decode(Bool.self, forKey: .fahrenheit)) ?? fallback.fahrenheit
        bits = (try? c.decode(Bool.self, forKey: .bits)) ?? fallback.bits
        showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? fallback.showInDock
        openWindowAtLaunch = (try? c.decode(Bool.self, forKey: .openWindowAtLaunch)) ?? fallback.openWindowAtLaunch
        startPage = (try? c.decode(String.self, forKey: .startPage)) ?? fallback.startPage
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        // Metrics added in later versions show up disabled at the end.
        for metric in MenuMetric.allCases where !settings.menuItems.contains(where: { $0.metric == metric }) {
            settings.menuItems.append(MenuItemSetting(metric: metric, enabled: false, style: .number))
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension AlertRules {
    var anyEnabled: Bool { cpuEnabled || memoryEnabled || diskEnabled || networkEnabled }
}
