import Foundation
import IOKit

/// GPU utilisation from the accelerator's PerformanceStatistics dictionary.
///
/// The dictionary's keys belong to the driver, not the OS, so each figure is looked
/// up under every spelling seen on Apple silicon, AMD and Intel. Reading the
/// dictionary also resets the driver's averaging window, which is why the first
/// read after opening the device is thrown away.
final class GPUCollector {
    private var service: io_service_t = 0
    private var name = "GPU"
    private var coreCount: Int?
    private var primed = false

    deinit { close() }

    func close() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
        primed = false
    }

    private func open() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if service == 0, Self.statistics(candidate) != nil {
                service = candidate
            } else {
                IOObjectRelease(candidate)
            }
        }
        guard service != 0 else { return }
        coreCount = Self.property(service, "gpu-core-count") as? Int
        if let model = Self.property(service, "model") as? String {
            name = model
        } else if let data = Self.property(service, "model") as? Data {
            name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        } else {
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                if let data = Self.property(parent, "model") as? Data {
                    name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                }
                IOObjectRelease(parent)
            }
        }
        if name == "GPU", let chip = Sysctl.string("machdep.cpu.brand_string") {
            name = "\(chip) GPU"
        }
    }

    func sample() -> GPUReading? {
        if service == 0 { open() }
        guard service != 0, let stats = Self.statistics(service) else {
            close()
            return nil
        }
        defer { primed = true }
        let memory = Self.number(stats, ["In use system memory", "vramUsedBytes", "gartUsedBytes"]).map { UInt64(max(0, $0)) }
        guard primed else {
            return GPUReading(name: name, utilization: nil, memoryUsed: memory, coreCount: coreCount)
        }
        return GPUReading(name: name,
                          utilization: Self.fraction(stats, ["Device Utilization %", "GPU Activity(%)", "Device Utilization"]),
                          rendererUtilization: Self.fraction(stats, ["Renderer Utilization %"]),
                          tilerUtilization: Self.fraction(stats, ["Tiler Utilization %"]),
                          memoryUsed: memory,
                          coreCount: coreCount)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func statistics(_ entry: io_registry_entry_t) -> [String: Any]? {
        property(entry, "PerformanceStatistics") as? [String: Any]
    }

    private static func number(_ stats: [String: Any], _ keys: [String]) -> Double? {
        for key in keys { if let value = stats[key] as? NSNumber { return value.doubleValue } }
        return nil
    }

    private static func fraction(_ stats: [String: Any], _ keys: [String]) -> Double? {
        number(stats, keys).map { min(1, max(0, $0 / 100)) }
    }
}
