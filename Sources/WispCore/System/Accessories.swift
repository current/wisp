import Foundation
import IOKit

public struct AccessoryBattery: Codable, Sendable, Equatable {
    public var name: String
    public var percent: Int
}

/// Battery levels of Bluetooth keyboards, mice and trackpads, as the HID driver
/// publishes them. One registry walk; call it at most every minute or so.
public enum Accessories {
    public static func batteries() -> [AccessoryBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [AccessoryBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = property(service, "BatteryPercent") as? Int, percent > 0 else { continue }
            let name = property(service, "Product") as? String ?? "Accessory"
            if !result.contains(where: { $0.name == name }) { result.append(AccessoryBattery(name: name, percent: percent)) }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
