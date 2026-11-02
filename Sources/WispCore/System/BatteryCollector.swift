import Foundation
import IOKit
import IOKit.ps

final class BatteryCollector {
    private var battery: io_service_t = 0
    /// macOS 27 moved the pack temperature onto this child node.
    private var pack: io_service_t = 0
    private var looked = false

    deinit {
        if battery != 0 { IOObjectRelease(battery) }
        if pack != 0 { IOObjectRelease(pack) }
    }

    /// The internal battery's power source entry, or nil on a Mac without one.
    static func internalSource() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return list.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    /// Level and power state only, from the power source list: no registry reads.
    /// Used for the minute-by-minute charge log.
    static func quick() -> (percent: Double, charging: Bool, plugged: Bool)? {
        guard let source = internalSource() else { return nil }
        let current = (source[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
        let max = (source[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
        return (max > 0 ? Swift.min(100, current / max * 100) : current,
                source[kIOPSIsChargingKey] as? Bool ?? false,
                (source[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
    }

    func sample() -> BatteryReading? {
        if !looked {
            looked = true
            battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            pack = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        }
        guard let source = Self.internalSource() else { return nil }

        let current = (source[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
        let max = (source[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
        let charging = source[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = (source[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        var minutes: Int?
        let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        if let value = (source[key] as? NSNumber)?.intValue, value > 0 { minutes = value }

        var reading = BatteryReading(percent: max > 0 ? Swift.min(100, current / max * 100) : current,
                                     isCharging: charging, isPluggedIn: plugged, minutesRemaining: minutes)
        reading.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if battery != 0 {
            // Only the keys used, not the whole node: it carries large port controller blobs.
            func top(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let data = top("BatteryData") as? [String: Any] ?? [:]
            let packData = pack != 0
                ? (IORegistryEntryCreateCFProperty(pack, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] ?? [:])
                : [:]
            func value(_ key: String) -> NSNumber? {
                (top(key) ?? data[key] ?? packData[key]) as? NSNumber
            }
            reading.cycleCount = value("CycleCount")?.intValue
            reading.designCycleCount = (top("DesignCycleCount9C") as? NSNumber)?.intValue
                ?? (source["DesignCycleCount"] as? NSNumber)?.intValue
            let design = (data["DesignCapacity"] ?? packData["DesignCapacity"] ?? top("DesignCapacity")) as? NSNumber
            // Nominal charge capacity is the figure closest to what System Settings shows;
            // the raw maximum is the gauge's own, more conservative estimate.
            let full = (data["NominalChargeCapacity"] ?? packData["NominalChargeCapacity"]
                ?? data["AppleRawMaxCapacity"] ?? top("AppleRawMaxCapacity")) as? NSNumber
            if let full, let design, design.doubleValue > 0 {
                reading.fullChargeCapacity = full.intValue
                reading.designCapacity = design.intValue
                reading.health = Swift.min(1, full.doubleValue / design.doubleValue)
            }
            if let raw = ((packData["Temperature"] ?? top("Temperature") ?? data["Temperature"]) as? NSNumber)?.doubleValue, raw > 0 {
                reading.temperature = raw / 100
            }
            if let volts = value("Voltage")?.doubleValue, let amps = value("Amperage")?.int64Value {
                reading.watts = volts / 1000 * Double(Int16(truncatingIfNeeded: amps)) / 1000
            }
            if plugged, let adapter = top("AdapterDetails") as? [String: Any],
               let watts = (adapter["Watts"] as? NSNumber)?.intValue, watts > 0 {
                reading.adapterWatts = watts
            }
            if let telemetry = top("PowerTelemetryData") as? [String: Any],
               let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0, load < 1_000_000 {
                reading.systemWatts = load / 1000
            }
            let fullyCharged = (top("FullyCharged") as? Bool) ?? false
            reading.chargeHeld = plugged && !charging && !fullyCharged && reading.percent < 99
            if let raw = ((data["ManufactureDate"] ?? packData["ManufactureDate"] ?? top("ManufactureDate")) as? NSNumber)?.intValue {
                reading.manufactured = Self.manufactureDate(raw)
            }
        }
        return reading
    }

    /// Smart Battery format: (year - 1980) << 9 | month << 5 | day. Newer packs store
    /// a vendor code instead, which is not a date; those return nil.
    static func manufactureDate(_ raw: Int) -> Date? {
        guard raw > 0, raw < 0x10000 else { return nil }
        let day = raw & 0x1F, month = (raw >> 5) & 0x0F, year = 1980 + (raw >> 9)
        guard (1...31).contains(day), (1...12).contains(month), year >= 2006, year <= 2100 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }
}
