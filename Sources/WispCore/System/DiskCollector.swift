import Foundation
import IOKit

/// Disk throughput from the block storage drivers' cumulative byte counters.
final class DiskCollector {
    private var drivers: [io_object_t] = []
    private var lastMatch: UInt64 = 0
    private var previous: (read: UInt64, write: UInt64, at: UInt64)?

    deinit { release() }

    func reset() {
        release()
        previous = nil
    }

    func sample() -> DiskReading? {
        // New disks are rare; matching costs a registry walk, so do it once a minute.
        if drivers.isEmpty || MachTime.secondsSince(lastMatch) > 60 { match() }

        var read: UInt64 = 0
        var write: UInt64 = 0
        for driver in drivers {
            guard let property = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0),
                  let stats = property.takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        let now = MachTime.now
        var readRate = 0.0
        var writeRate = 0.0
        if let previous, read >= previous.read, write >= previous.write {
            let elapsed = MachTime.seconds(now &- previous.at)
            if elapsed > 0 {
                readRate = Double(read - previous.read) / elapsed
                writeRate = Double(write - previous.write) / elapsed
            }
        }
        previous = (read, write, now)

        var fs = statfs()
        var total: UInt64 = 0
        var free: UInt64 = 0
        if statfs("/System/Volumes/Data", &fs) == 0 || statfs("/", &fs) == 0 {
            total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
            free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        }
        return DiskReading(readBytesPerSecond: readRate, writeBytesPerSecond: writeRate,
                           volumeTotal: total, volumeFree: free)
    }

    private func match() {
        release()
        lastMatch = MachTime.now
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            drivers.append(service)
        }
    }

    private func release() {
        for driver in drivers { IOObjectRelease(driver) }
        drivers = []
    }
}
