import Foundation
import WispCore

/// `wisp storage`: answered here from the app's saved scan, without asking the app.
enum StorageCommand {
    static func run(json: Bool) {
        let report = StorageReport.current()
        if json {
            FileHandle.standardOutput.write(Report.json(report))
            print()
            return
        }
        print("Startup disk  \(Format.bytes(report.freeBytes)) free of \(Format.bytes(report.capacityBytes))"
            + (report.purgeableBytes > 0 ? ", \(Format.bytes(report.purgeableBytes)) purgeable" : ""))
        if let scanned = report.scannedAt {
            print("Folders measured \(scanned.formatted(date: .abbreviated, time: .shortened))")
        } else if let note = report.note {
            print(note)
        }
        print()
        Table.print(["KIND", "SIZE"], report.slices.map { [$0.name, $0.bytes.map { Format.bytes($0) } ?? "–"] }, right: [1])
        if report.scannedAt != nil {
            print()
            Table.print(["SYSTEM DATA", "SIZE"], report.systemData.map { [$0.name, $0.bytes.map { Format.bytes($0) } ?? "locked"] }, right: [1])
            let developer = report.developer.filter { ($0.bytes ?? 0) >= 1 << 20 }
            if !developer.isEmpty {
                print()
                Table.print(["DEVELOPER", "SIZE", "CHANGED"], developer.map {
                    [$0.name, $0.bytes.map { Format.bytes($0) } ?? "locked", $0.lastChanged.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""]
                }, right: [1])
            }
            if !report.reclaimable.isEmpty {
                print()
                Table.print(["COULD GO TO THE TRASH", "SIZE", "FOLDERS"], report.reclaimable.map { [$0.name, Format.bytes($0.bytes), "\($0.paths.count)"] }, right: [1, 2])
            }
        }
        print()
        print("Local snapshots  \(report.localSnapshots)")
        if let health = report.health {
            print("SSD  \(health.percentUsed)% of rated life used, \(Format.bytes(UInt64(health.bytesWritten))) written"
                + (health.temperatureCelsius.map { ", \($0) °C" } ?? ""))
        }
        if !report.fullDiskAccess { print("Some folders are locked until Wisp has Full Disk Access.") }
    }
}
