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

    func sample() -> BatteryReading? {
        if !looked {
            looked = true
            battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            pack = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let found = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let source = found else { return nil }

        let current = (source[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
        let max = (source[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
        let charging = source[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = (source[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        var minutes: Int?
        let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        if let value = (source[key] as? NSNumber)?.intValue, value > 0 { minutes = value }

        var reading = BatteryReading(percent: max > 0 ? Swift.min(100, current / max * 100) : current,
                                     isCharging: charging, isPluggedIn: plugged, minutesRemaining: minutes)
        if battery != 0 {
            let top = properties(battery)
            let data = top["BatteryData"] as? [String: Any] ?? [:]
            let packData = pack != 0 ? (properties(pack)["BatteryData"] as? [String: Any] ?? [:]) : [:]
            func value(_ key: String) -> NSNumber? {
                (top[key] ?? data[key] ?? packData[key]) as? NSNumber
            }
            reading.cycleCount = value("CycleCount")?.intValue
            if let full = (data["AppleRawMaxCapacity"] ?? top["AppleRawMaxCapacity"]) as? NSNumber,
               let design = value("DesignCapacity")?.doubleValue, design > 0 {
                reading.health = Swift.min(1, full.doubleValue / design)
            }
            if let raw = ((packData["Temperature"] ?? top["Temperature"] ?? data["Temperature"]) as? NSNumber)?.doubleValue, raw > 0 {
                reading.temperature = raw / 100
            }
            if let volts = value("Voltage")?.doubleValue, let amps = value("Amperage")?.int64Value {
                reading.watts = volts / 1000 * Double(Int16(truncatingIfNeeded: amps)) / 1000
            }
            if let adapter = top["AdapterDetails"] as? [String: Any],
               let watts = (adapter["Watts"] as? NSNumber)?.intValue, plugged {
                reading.adapterWatts = watts
            }
        }
        return reading
    }

    private func properties(_ entry: io_service_t) -> [String: Any] {
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let result = dict?.takeRetainedValue() as? [String: Any] else { return [:] }
        return result
    }
}
