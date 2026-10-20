import Foundation
import IOKit

/// CPU, GPU and Neural Engine power from IOReport energy counters, without root.
///
/// Up to macOS 26 the "Energy Model" group carries these counters. macOS 27 keeps
/// the group but stops updating it for unprivileged readers; the same totals are
/// still published by the AppleCLPC driver under report IDs that are not listed.
/// Those IDs (table below) were worked out by the macmon project (MIT); see NOTICE.
final class PowerCollector {
    private typealias Subscription = OpaquePointer

    private struct API {
        let copyGroup: @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        let subscribe: @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Subscription?
        let samples: @convention(c) (Subscription, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        let delta: @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        let channelName: @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        let groupName: @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        let unitLabel: @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        let integerValue: @convention(c) (CFDictionary, Int32) -> Int64
    }

    private static let api: API? = {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copyGroup = fn("IOReportCopyChannelsInGroup", (@convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?).self),
              let subscribe = fn("IOReportCreateSubscription", (@convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Subscription?).self),
              let samples = fn("IOReportCreateSamples", (@convention(c) (Subscription, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?).self),
              let delta = fn("IOReportCreateSamplesDelta", (@convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?).self),
              let channelName = fn("IOReportChannelGetChannelName", (@convention(c) (CFDictionary) -> Unmanaged<CFString>?).self),
              let groupName = fn("IOReportChannelGetGroup", (@convention(c) (CFDictionary) -> Unmanaged<CFString>?).self),
              let unitLabel = fn("IOReportChannelGetUnitLabel", (@convention(c) (CFDictionary) -> Unmanaged<CFString>?).self),
              let integerValue = fn("IOReportSimpleGetIntegerValue", (@convention(c) (CFDictionary, Int32) -> Int64).self)
        else { return nil }
        return API(copyGroup: copyGroup, subscribe: subscribe, samples: samples, delta: delta, channelName: channelName,
                   groupName: groupName, unitLabel: unitLabel, integerValue: integerValue)
    }()

    /// AppleCLPC aggregate energy report keys for macOS 27, by driver bundle: CPU, GPU, ANE.
    static let clpcKeys: [String: (UInt32, UInt32, UInt32)] = [
        "com.apple.driver.AppleT6000CLPCv3": (0x4747_9059, 0x4519_BF1E, 0x9AAA_17F8),
        "com.apple.driver.AppleT6002CLPC": (0xB501_816B, 0x9E2C_3E8B, 0x14D5_A574),
        "com.apple.driver.AppleT6020CLPC": (0xE301_CD75, 0x8F34_CC7A, 0x7415_FB0F),
        "com.apple.driver.AppleT6022CLPC": (0x76F5_FD21, 0x9062_4499, 0x3C09_7307),
        "com.apple.driver.AppleT6030CLPC": (0xBE03_A01A, 0x472D_6C9C, 0xB899_0C38),
        "com.apple.driver.AppleT6031CLPC": (0xD81E_0084, 0x1085_F98B, 0x313A_3BE1),
        "com.apple.driver.AppleT6032CLPC": (0xF4A2_1308, 0x85E8_0513, 0x63DC_8E25),
        "com.apple.driver.AppleT6041CLPC": (0x263C_F1F0, 0x22E4_CF59, 0x7849_FB5C),
        "com.apple.driver.AppleT6050CLPC": (0xD3AB_60BB, 0x27CD_4CE5, 0x8C0F_1C59),
        "com.apple.driver.AppleT6050dCLPC": (0x18B3_010E, 0xEDEC_A11A, 0x188B_D883),
        "com.apple.driver.AppleT8103CLPCv3": (0x2CDD_31F2, 0x21BE_CF42, 0x0667_FB81),
        "com.apple.driver.AppleT8112CLPC": (0xB543_5137, 0x638D_9D52, 0xEA08_9C36),
        "com.apple.driver.AppleT8122CLPC": (0x54B5_1C99, 0xCE2D_D9DC, 0x960A_FE2F),
        "com.apple.driver.AppleT8132CLPC": (0x4A85_4D94, 0x3B3E_3B79, 0x1FF4_A9EC),
        "com.apple.driver.AppleT8140CLPC": (0x9BF5_4436, 0xEF70_589C, 0x569D_941B),
        "com.apple.driver.AppleT8142CLPC": (0x4370_8744, 0x6A01_0933, 0xBC5E_FDF0),
        "com.apple.driver.AppleT8152CLPC": (0x485D_4BFC, 0x1178_4654, 0x9380_C6BB),
    ]
    static let clpcIndices: (cpu: UInt64, gpu: UInt64, ane: UInt64) = (16, 25, 24)

    private var subscription: Subscription?
    private var subscribed: CFMutableDictionary?
    private var previous: (CFDictionary, UInt64)?
    private var unavailable = false
    private var usesCLPC = false

    func close() {
        subscription = nil
        subscribed = nil
        previous = nil
    }

    func sample() -> PowerReading? {
        guard !unavailable, let api = Self.api else { return nil }
        if subscription == nil, !open(api) {
            unavailable = true
            return nil
        }
        guard let subscription, let subscribed, let current = api.samples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let now = mach_absolute_time()
        defer { previous = (current, now) }
        guard let (before, then) = previous, let delta = api.delta(before, current, nil)?.takeRetainedValue() else { return nil }
        let seconds = MachTime.seconds(now &- then)
        guard seconds > 0.05, let channels = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }

        var cpu = 0.0, gpu = 0.0, ane = 0.0
        var clpc = (cpu: 0.0, gpu: 0.0, ane: 0.0)
        for item in channels {
            let name = api.channelName(item)?.takeUnretainedValue() as String? ?? ""
            let group = api.groupName(item)?.takeUnretainedValue() as String? ?? ""
            let unit = (api.unitLabel(item)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
            let joules = Self.joules(Double(api.integerValue(item, 0)), unit: unit)
            if group == "CLPC" {
                switch name {
                case "CPU Energy": clpc.cpu += joules
                case "GPU Energy": clpc.gpu += joules
                case "ANE": clpc.ane += joules
                default: break
                }
            } else if name.hasSuffix("CPU Energy") {
                cpu += joules
            } else if name == "GPU Energy" {
                gpu += joules
            } else if name.hasPrefix("ANE") {
                ane += joules
            }
        }
        // Prefer the CLPC totals whenever they move; the legacy group can sit at zero.
        if clpc.cpu + clpc.gpu + clpc.ane > 0 { (cpu, gpu, ane) = clpc }
        return PowerReading(cpu: cpu / seconds, gpu: gpu / seconds, ane: ane / seconds, system: nil)
    }

    static func joules(_ value: Double, unit: String) -> Double {
        switch unit {
        case "mJ": return value / 1e3
        case "uJ", "µJ": return value / 1e6
        case "nJ": return value / 1e9
        default: return 0
        }
    }

    private func open(_ api: API) -> Bool {
        guard let channels = api.copyGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return false }
        let mutable = NSMutableDictionary(dictionary: channels as NSDictionary)
        var list = (mutable["IOReportChannels"] as? [Any]) ?? []
        list += clpcChannels()
        guard !list.isEmpty else { return false }
        mutable["IOReportChannels"] = list
        var out: Unmanaged<CFMutableDictionary>?
        guard let subscription = api.subscribe(nil, mutable as CFMutableDictionary, &out, 0, nil), let out else { return false }
        self.subscription = subscription
        subscribed = out.takeRetainedValue()
        usesCLPC = list.count > ((channels as NSDictionary)["IOReportChannels"] as? [Any])?.count ?? 0
        return true
    }

    /// Hand-built channel descriptions for the unlisted CLPC energy reports.
    private func clpcChannels() -> [NSDictionary] {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [NSDictionary] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var driver: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &driver) == KERN_SUCCESS,
                  let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let keys = Self.clpcKeys[bundle] else { continue }
            let i = Self.clpcIndices
            for (index, key, name) in [(i.cpu, keys.0, "CPU Energy"), (i.gpu, keys.1, "GPU Energy"), (i.ane, keys.2, "ANE")] {
                let id = Int64(bitPattern: (index << 32) | UInt64(key))
                // Simple integer, power category, one element; energy in nanojoules.
                let type = Int64(1) | (2 << 16) | (1 << 32)
                let unit = (Int64(3) << 56) | (118 << 32)
                result.append([
                    "DriverID": NSNumber(value: Int64(bitPattern: driver)),
                    "DriverName": "AppleCLPC",
                    "IOReportGroupName": "CLPC",
                    "IOReportSubGroupName": "Energy Counters",
                    "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
                    "LegendChannel": [NSNumber(value: id), NSNumber(value: type), name],
                ] as NSMutableDictionary)
            }
        }
        return result
    }
}
