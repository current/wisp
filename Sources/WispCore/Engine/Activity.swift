import Foundation

/// How much of Wisp is on screen. Sampling follows it: nothing is measured that
/// nothing shows, unless history or an alert rule needs it.
public enum ActivityLevel: Int, Comparable, Codable, Sendable {
    /// Display asleep or nothing visible: only the background pass for history and alerts.
    case hidden
    /// Status items only.
    case menuBar
    /// The dashboard popover is open.
    case popover
    /// The main window is open and visible.
    case window

    public static func < (a: ActivityLevel, b: ActivityLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Readings that something currently wants.
public struct Demand: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let cpu = Demand(rawValue: 1 << 0)
    public static let cpuCores = Demand(rawValue: 1 << 1)
    public static let memory = Demand(rawValue: 1 << 2)
    public static let disk = Demand(rawValue: 1 << 3)
    public static let network = Demand(rawValue: 1 << 4)
    public static let gpu = Demand(rawValue: 1 << 5)
    public static let battery = Demand(rawValue: 1 << 6)
    public static let thermal = Demand(rawValue: 1 << 7)
    public static let power = Demand(rawValue: 1 << 8)
    /// The per-app table, at the visible cadence.
    public static let processes = Demand(rawValue: 1 << 9)
    /// Per-app network through NetworkStatistics.
    public static let appNetwork = Demand(rawValue: 1 << 10)

    public static let system: Demand = [.cpu, .memory, .disk, .network, .gpu, .battery, .thermal, .power]
    public static let everything: Demand = [.system, .cpuCores, .processes, .appNetwork]
}

public struct SamplingPlan: Equatable, Sendable {
    public var demand: Demand
    /// Seconds between system readings while something is on screen.
    public var interval: TimeInterval
    /// Seconds between background process passes for history and alerts; nil turns them off.
    public var backgroundProcessInterval: TimeInterval?
    /// Whether the background pass also tracks per-app network.
    public var backgroundAppNetwork: Bool

    public init(demand: Demand = [.cpu, .memory], interval: TimeInterval = 2,
                backgroundProcessInterval: TimeInterval? = 10, backgroundAppNetwork: Bool = false) {
        self.demand = demand
        self.interval = interval
        self.backgroundProcessInterval = backgroundProcessInterval
        self.backgroundAppNetwork = backgroundAppNetwork
    }
}
