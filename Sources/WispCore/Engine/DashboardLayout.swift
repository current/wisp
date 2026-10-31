import Foundation

/// One block of the menu bar dashboard. The dashboard is an ordered list of these,
/// chosen in Settings > Menu Bar. Each block names the readings it needs, so the
/// dashboard samples only what it shows.
public enum DashboardBlock: String, Codable, CaseIterable, Sendable {
    case cpu, meters, cores, memory, gpu, power, network, disk, sensors, apps, agents

    /// What today's dashboard showed: the CPU, the six meters, the core map and the busiest apps.
    public static let defaultLayout: [DashboardBlock] = [.cpu, .meters, .cores, .apps]

    public var demand: Demand {
        switch self {
        case .cpu: return .cpu
        case .meters: return [.memory, .gpu, .power, .network, .disk, .battery, .thermal]
        case .cores: return [.cpu, .cpuCores]
        case .memory: return .memory
        case .gpu: return .gpu
        case .power: return [.power, .battery]
        case .network: return .network
        case .disk: return .disk
        case .sensors: return .thermal
        case .apps, .agents: return .processes
        }
    }

    /// Readings a layout needs while the dashboard is open.
    public static func demand(of layout: [DashboardBlock]) -> Demand {
        layout.reduce(into: Demand()) { $0.formUnion($1.demand) }
    }

    /// Reads a saved layout: names this build does not know are dropped, and so are
    /// repeats. Missing or unreadable data gives the default layout.
    public static func layout(from names: [String]?) -> [DashboardBlock] {
        guard let names else { return defaultLayout }
        var seen = Set<DashboardBlock>()
        return names.compactMap(DashboardBlock.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    /// Moves `block` to `index` in `layout`, adding it when it is not there yet.
    public static func moving(_ block: DashboardBlock, to index: Int, in layout: [DashboardBlock]) -> [DashboardBlock] {
        var result = layout.filter { $0 != block }
        result.insert(block, at: min(max(0, index), result.count))
        return result
    }
}
