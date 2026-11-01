import Foundation
import IOKit

/// NVMe SMART figures for the internal SSD, read through the NVMeSMARTLib plug-in
/// IONVMeFamily ships. Works as a normal user; no root and no entitlements.
public struct DiskHealth: Codable, Sendable, Equatable {
    /// Share of the drive's rated endurance used, as the drive reports it (can pass 100).
    public var percentUsed: Int
    public var availableSpare: Int
    public var celsius: Int?
    public var bytesWritten: Double
    public var bytesRead: Double
    public var powerOnHours: Double
    public var powerCycles: Double
    public var unsafeShutdowns: Double
    /// Non-zero when the drive raises a warning (spare low, temperature, read-only).
    public var criticalWarning: Int

    /// Decodes the 512-byte SMART / Health Information log page (NVMe log 02h).
    public init?(log: [UInt8]) {
        guard log.count >= 512 else { return nil }
        func u128(_ offset: Int) -> Double {
            var value = 0.0
            for index in (0..<16).reversed() { value = value * 256 + Double(log[offset + index]) }
            return value
        }
        criticalWarning = Int(log[0])
        let kelvin = Int(log[1]) | Int(log[2]) << 8
        celsius = kelvin > 0 ? kelvin - 273 : nil
        availableSpare = Int(log[3])
        percentUsed = Int(log[5])
        // Data units are a thousand 512-byte blocks.
        bytesRead = u128(32) * 512_000
        bytesWritten = u128(48) * 512_000
        powerCycles = u128(112)
        powerOnHours = u128(128)
        unsafeShutdowns = u128(144)
    }

    public static func read() -> DiskHealth? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let capable = IORegistryEntryCreateCFProperty(service, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool
            guard capable == true, let log = readLog(service) else { continue }
            return DiskHealth(log: log)
        }
        return nil
    }

    private typealias ReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

    private static func readLog(_ service: io_service_t) -> [UInt8]? {
        // kIONVMeSMARTUserClientTypeID, kIONVMeSMARTInterfaceID and kIOCFPlugInInterfaceID.
        guard let clientType = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
                                                               0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F),
              let interfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
                                                               0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6),
              let pluginType = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                              0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F) else { return nil }
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, clientType, pluginType, &plugin, &score) == KERN_SUCCESS,
              let plugin, let table = plugin.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var interface: UnsafeMutableRawPointer?
        guard table.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), &interface) == S_OK, let interface else { return nil }
        // IONVMeSMARTInterface: the IUnknown header (reserved, QueryInterface, AddRef, Release),
        // version and revision, then SMARTReadData.
        let functions = interface.load(as: UnsafeMutableRawPointer.self)
        let pointer = MemoryLayout<UnsafeRawPointer>.size
        let readData = functions.load(fromByteOffset: pointer * 5, as: ReadData.self)
        let release = functions.load(fromByteOffset: pointer * 3, as: Release.self)
        defer { _ = release(interface) }
        var log = [UInt8](repeating: 0, count: 512)
        let result = log.withUnsafeMutableBytes { readData(interface, $0.baseAddress) }
        return result == KERN_SUCCESS ? log : nil
    }
}
