import AppKit
import WispCore

/// When a reading counts as strained, which turns its menu bar item red.
enum Strain {
    static func cpu(_ reading: CPUReading?) -> Bool { (reading?.total ?? 0) >= 0.85 }
    static func memory(_ reading: MemoryReading?) -> Bool { (reading?.pressure ?? .normal) != .normal }
    static func gpu(_ reading: GPUReading?) -> Bool { (reading?.utilization ?? 0) >= 0.9 }
    static func temperature(_ reading: ThermalReading?) -> Bool {
        guard let reading else { return false }
        return reading.pressure == .serious || reading.pressure == .critical || (reading.cpuCelsius ?? 0) >= 95
    }
    static func battery(_ reading: BatteryReading?) -> Bool {
        guard let reading, !reading.isPluggedIn else { return false }
        return reading.percent <= 15
    }
    static func disk(_ reading: DiskReading?) -> Bool {
        guard let reading, reading.volumeTotal > 0 else { return false }
        return Double(reading.volumeFree) / Double(reading.volumeTotal) < 0.05
    }

    static func color(_ strained: Bool) -> NSColor { strained ? .systemRed : .labelColor }
}
