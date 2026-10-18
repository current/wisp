import Foundation
import IOKit

/// A connection to the AppleSMC user client.
///
/// Only public IOKit calls are used. The 80-byte request layout is not documented,
/// so it is written as raw offsets rather than a Swift struct whose layout the
/// compiler is free to choose.
final class SMC {
    private var connection: io_connect_t = 0
    private let input = UnsafeMutableRawPointer.allocate(byteCount: 80, alignment: 16)
    private let output = UnsafeMutableRawPointer.allocate(byteCount: 80, alignment: 16)

    struct KeyInfo {
        let size: UInt32
        let type: UInt32
    }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
        input.deallocate()
        output.deallocate()
    }

    private func call(key: UInt32, command: UInt8, size: UInt32 = 0, type: UInt32 = 0, index: UInt32 = 0) -> Bool {
        memset(input, 0, 80)
        input.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
        input.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
        input.storeBytes(of: type, toByteOffset: 32, as: UInt32.self)
        input.storeBytes(of: command, toByteOffset: 42, as: UInt8.self)
        input.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        var outSize = 80
        guard IOConnectCallStructMethod(connection, 2, input, 80, output, &outSize) == kIOReturnSuccess else { return false }
        return output.load(fromByteOffset: 40, as: UInt8.self) == 0
    }

    func info(_ key: UInt32) -> KeyInfo? {
        guard call(key: key, command: 9) else { return nil }
        let size = output.load(fromByteOffset: 28, as: UInt32.self)
        let type = output.load(fromByteOffset: 32, as: UInt32.self)
        guard size > 0, size <= 32 else { return nil }
        return KeyInfo(size: size, type: type)
    }

    var keyCount: UInt32? {
        guard let info = info(Self.code("#KEY")), call(key: Self.code("#KEY"), command: 5, size: info.size, type: info.type) else { return nil }
        return UInt32(bigEndian: output.loadUnaligned(fromByteOffset: 48, as: UInt32.self))
    }

    func key(at index: UInt32) -> UInt32? {
        guard call(key: 0, command: 8, index: index) else { return nil }
        return output.load(fromByteOffset: 0, as: UInt32.self)
    }

    func read(_ key: UInt32, _ info: KeyInfo) -> Double? {
        guard call(key: key, command: 5, size: info.size, type: info.type) else { return nil }
        let data = output.advanced(by: 48)
        switch info.type {
        case Self.code("flt ") where info.size == 4:
            let value = Double(data.loadUnaligned(as: Float32.self))
            return value.isFinite ? value : nil
        case Self.code("ui8 ") where info.size == 1:
            return Double(data.load(as: UInt8.self))
        case Self.code("ui16") where info.size == 2:
            return Double(UInt16(bigEndian: data.loadUnaligned(as: UInt16.self)))
        case Self.code("ui32") where info.size == 4:
            return Double(UInt32(bigEndian: data.loadUnaligned(as: UInt32.self)))
        case Self.code("sp78") where info.size == 2:
            return Double(Int16(bigEndian: data.loadUnaligned(as: Int16.self))) / 256
        case Self.code("fpe2") where info.size == 2:
            return Double(UInt16(bigEndian: data.loadUnaligned(as: UInt16.self))) / 4
        default:
            return nil
        }
    }

    static func code(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
