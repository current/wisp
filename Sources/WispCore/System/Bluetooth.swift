import CoreBluetooth
import Foundation
import IOBluetooth

public struct BluetoothDevice: Sendable, Equatable {
    public var name: String
    public var address: String
    public var connected: Bool
    /// Headphones, Keyboard, Mouse, Phone...
    public var kind: String
    public var battery: Int?
}

/// Paired Bluetooth devices from IOBluetooth, with the battery level for the ones
/// that report it through HID. Reading the list asks macOS for Bluetooth access once.
public enum Bluetooth {
    /// True once the person has allowed Bluetooth access. Until then the list stays
    /// empty: reading it would raise the system prompt, which should only follow a click.
    public static var allowed: Bool { CBManager.authorization == .allowedAlways }
    public static var undecided: Bool { CBManager.authorization == .notDetermined }

    public static func devices(asking: Bool = false) -> [BluetoothDevice] {
        guard allowed || (asking && undecided && Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil)
        else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let batteries = Dictionary(Accessories.batteries().map { ($0.name, $0.percent) }, uniquingKeysWith: { first, _ in first })
        return paired.map { device in
            let name = device.name ?? device.addressString ?? "Device"
            return BluetoothDevice(name: name, address: device.addressString ?? "", connected: device.isConnected(),
                                   kind: kind(major: device.deviceClassMajor, minor: device.deviceClassMinor), battery: batteries[name])
        }
        .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    static func kind(major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> String {
        switch Int(major) {
        case kBluetoothDeviceClassMajorAudio: return "Headphones"
        case kBluetoothDeviceClassMajorPhone: return "Phone"
        case kBluetoothDeviceClassMajorComputer: return "Computer"
        case kBluetoothDeviceClassMajorPeripheral:
            switch Int(minor) & 0x30 {
            case 0x10: return "Keyboard"
            case 0x20: return "Mouse"
            case 0x30: return "Keyboard and mouse"
            default: return "Input device"
            }
        case kBluetoothDeviceClassMajorWearable: return "Wearable"
        case kBluetoothDeviceClassMajorImaging: return "Printer or camera"
        default: return "Device"
        }
    }
}
