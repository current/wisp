import Foundation

public struct ProcessRow: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String?
    public var responsiblePID: Int32
    public var groupID: String
    /// False for processes owned by other users, whose counters need root.
    public var readable: Bool
    /// Cores in use, so 1.0 is one core fully busy.
    public var cpu: Double
    /// phys_footprint, the figure Activity Monitor calls Memory.
    public var memory: UInt64
    public var watts: Double
    public var diskReadPerSecond: Double
    public var diskWritePerSecond: Double
    public var networkInPerSecond: Double
    public var networkOutPerSecond: Double
    /// Seconds of CPU since launch.
    public var cpuTime: Double
    public var startDate: Date?
    /// Times per second the process woke the CPU from idle (timers and interrupts).
    public var wakeupsPerSecond: Double = 0

    public var id: Int32 { pid }
}

public enum AppKind: String, Codable, Sendable {
    case app
    case system
    case tool
}

public struct AppGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AppKind
    public var bundlePath: String?
    public var bundleIdentifier: String?
    public var pids: [Int32]
    public var cpu: Double
    public var memory: UInt64
    public var watts: Double
    public var diskReadPerSecond: Double
    public var diskWritePerSecond: Double
    public var networkInPerSecond: Double
    public var networkOutPerSecond: Double
    /// Processes in the group whose counters could not be read.
    public var unreadable: Int
    public var wakeupsPerSecond: Double = 0

    public var processCount: Int { pids.count }
    public var diskPerSecond: Double { diskReadPerSecond + diskWritePerSecond }
    public var networkPerSecond: Double { networkInPerSecond + networkOutPerSecond }
}

public struct ProcessTable: Codable, Sendable, Equatable {
    public var date: Date
    /// Seconds covered by the rates in this table.
    public var interval: Double
    public var processes: [ProcessRow]
    public var apps: [AppGroup]
    /// Cores in use machine-wide over the same interval, including processes
    /// this user cannot read.
    public var machineCPU: Double
    public var coreCount: Int
    public var networkMeasured: Bool

    public init(date: Date = Date(), interval: Double = 0, processes: [ProcessRow] = [], apps: [AppGroup] = [],
                machineCPU: Double = 0, coreCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                networkMeasured: Bool = false) {
        self.date = date
        self.interval = interval
        self.processes = processes
        self.apps = apps
        self.machineCPU = machineCPU
        self.coreCount = coreCount
        self.networkMeasured = networkMeasured
    }

    /// CPU used by processes Wisp cannot read: the machine total minus what it can.
    public var unattributedCPU: Double {
        max(0, machineCPU - processes.reduce(0) { $0 + $1.cpu })
    }

    public func app(_ id: String) -> AppGroup? { apps.first { $0.id == id } }
    public func processes(in app: AppGroup) -> [ProcessRow] {
        let set = Set(app.pids)
        return processes.filter { set.contains($0.pid) }
    }
}
