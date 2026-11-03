import Foundation

/// The storage summary for `wisp storage` and the MCP tool. Built from the scan the
/// app last saved; nothing is scanned here, so it answers at once.
public struct StorageReport: Codable, Sendable {
    public struct Slice: Codable, Sendable {
        public var name: String
        public var bytes: UInt64?
        public var note: String?
    }

    public struct Line: Codable, Sendable {
        public var name: String
        public var bytes: UInt64?
        public var detail: String
        public var lastChanged: Date?
        public var paths: [String]?
    }

    public struct Reclaim: Codable, Sendable {
        public var name: String
        public var bytes: UInt64
        public var detail: String
        public var paths: [String]
    }

    public struct Health: Codable, Sendable {
        public var percentUsed: Int
        public var availableSparePercent: Int
        public var temperatureCelsius: Int?
        public var bytesWritten: Double
        public var bytesRead: Double
        public var powerOnHours: Double
    }

    public var capacityBytes: UInt64
    public var freeBytes: UInt64
    public var purgeableBytes: UInt64
    public var slices: [Slice]
    public var systemData: [Line]
    public var developer: [Line]
    public var reclaimable: [Reclaim]
    public var localSnapshots: Int
    public var swapUsedBytes: UInt64?
    public var health: Health?
    /// When the folder sizes were measured; nil when the app has not scanned yet.
    public var scannedAt: Date?
    public var fullDiskAccess: Bool
    public var note: String?

    public static func current(home: String = NSHomeDirectory()) -> StorageReport {
        let cache = StorageIndex.cached()
        let roots = cache?.roots ?? [:]
        let summary = StorageAnalysis.summarize(.init(volume: .read(), roots: roots, home: home, snapshots: LocalSnapshot.list(), swap: .read(),
                                                      scannedAt: cache?.date, fullDiskAccess: StorageAccess.hasFullDiskAccess,
                                                      deviceName: Simulators.name(ofDeviceAt:)))
        return make(summary, health: DiskHealth.read(), scanned: !roots.isEmpty)
    }

    public static func make(_ summary: StorageSummary, health: DiskHealth?, scanned: Bool) -> StorageReport {
        let slices = summary.segments.map { segment -> Slice in
            switch segment.category {
            case .snapshots:
                return Slice(name: segment.category.title, bytes: nil,
                             note: "\(summary.snapshots.count) local snapshots; macOS does not report their size without administrator rights, and the space they hold is part of purgeable")
            case .system:
                return Slice(name: segment.category.title, bytes: scanned ? segment.size : nil,
                             note: scanned ? "What is left once the other slices, purgeable and free space are counted" : "Open Storage in Wisp to measure folders")
            default:
                return Slice(name: segment.category.title, bytes: scanned || [.purgeable, .free].contains(segment.category) ? segment.size : nil, note: nil)
            }
        }
        func line(_ row: StorageRow) -> Line {
            Line(name: row.name, bytes: row.locked && (row.size ?? 0) == 0 ? nil : row.size, detail: row.detail, lastChanged: row.lastUsed,
                 paths: row.paths.isEmpty ? nil : Array(row.paths.prefix(5)))
        }
        return StorageReport(capacityBytes: summary.volume.capacity, freeBytes: summary.volume.available, purgeableBytes: summary.volume.purgeable,
                             slices: slices, systemData: summary.rows(.system).map(line),
                             developer: summary.rows(.developer).sorted { ($0.size ?? 0) > ($1.size ?? 0) }.map(line),
                             reclaimable: summary.reclaimable.map { Reclaim(name: $0.name, bytes: $0.size, detail: $0.detail, paths: $0.entries.map(\.path)) },
                             localSnapshots: summary.snapshots.count, swapUsedBytes: summary.swap?.used,
                             health: health.map { Health(percentUsed: $0.percentUsed, availableSparePercent: $0.availableSpare, temperatureCelsius: $0.celsius,
                                                         bytesWritten: $0.bytesWritten, bytesRead: $0.bytesRead, powerOnHours: $0.powerOnHours) },
                             scannedAt: summary.scannedAt, fullDiskAccess: summary.fullDiskAccess,
                             note: scanned ? nil : "Folder sizes appear after the Storage page in Wisp has scanned once")
    }
}
