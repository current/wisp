import Foundation

public struct CPUReading: Codable, Sendable, Equatable {
    /// Fractions of the whole machine, 0...1.
    public var user: Double
    public var system: Double
    public var total: Double { user + system }
    /// Per logical core, 0...1. Empty when only the totals were sampled.
    public var cores: [Double]
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var loadAverage: [Double]

    public init(user: Double, system: Double, cores: [Double] = [], performanceCores: Int = 0,
                efficiencyCores: Int = 0, loadAverage: [Double] = []) {
        self.user = user
        self.system = system
        self.cores = cores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.loadAverage = loadAverage
    }
}

public enum MemoryPressure: Int, Codable, Sendable { case normal = 1, warning = 2, critical = 4 }

public struct MemoryReading: Codable, Sendable, Equatable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure
    /// The same "Memory Used" Activity Monitor shows: app + wired + compressed.
    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct DiskReading: Codable, Sendable, Equatable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var volumeTotal: UInt64
    public var volumeFree: UInt64
}

public struct NetworkReading: Codable, Sendable, Equatable {
    public var receivedBytesPerSecond: Double
    public var sentBytesPerSecond: Double
    public var totalReceived: UInt64
    public var totalSent: UInt64
}

public struct GPUReading: Codable, Sendable, Equatable {
    public var name: String
    public var utilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    public var memoryUsed: UInt64?
    public var coreCount: Int?
}

public struct BatteryReading: Codable, Sendable, Equatable {
    public var percent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Full charge capacity over design capacity.
    public var health: Double?
    public var temperature: Double?
    /// Positive while charging, negative while draining.
    public var watts: Double?
    public var adapterWatts: Int?
    /// What the whole Mac draws now, from the battery's power telemetry.
    public var systemWatts: Double?
    /// Charge the battery holds when full and held when new, mAh.
    public var fullChargeCapacity: Int?
    public var designCapacity: Int?
    /// The cycle count the battery is rated for.
    public var designCycleCount: Int?
    /// Plugged in, not charging and short of full: macOS is holding the charge.
    public var chargeHeld: Bool?
    public var manufactured: Date?
    public var lowPowerMode: Bool?
}

public struct TemperatureSensor: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var celsius: Double
}

public struct FanReading: Codable, Sendable, Equatable {
    public var index: Int
    public var rpm: Double
    public var minRPM: Double?
    public var maxRPM: Double?
}

public enum ThermalPressure: String, Codable, Sendable { case nominal, fair, serious, critical }

public struct ThermalReading: Codable, Sendable, Equatable {
    public var pressure: ThermalPressure
    public var cpuCelsius: Double?
    public var gpuCelsius: Double?
    public var sensors: [TemperatureSensor]
    public var fans: [FanReading]
}

public struct PowerReading: Codable, Sendable, Equatable {
    /// Watts over the last interval.
    public var cpu: Double?
    public var gpu: Double?
    public var ane: Double?
    /// Whole-machine draw from the battery telemetry or the SMC, when available.
    public var system: Double?
}

public struct SystemSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var disk: DiskReading?
    public var network: NetworkReading?
    public var gpu: GPUReading?
    public var battery: BatteryReading?
    public var thermal: ThermalReading?
    public var power: PowerReading?

    public init(date: Date = Date()) { self.date = date }
}
