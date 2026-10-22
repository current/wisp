import Foundation

public struct Volume: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var total: UInt64
    public var free: UInt64
    public var isInternal: Bool

    public var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
}

/// Mounted volumes a person would recognise: the startup disk and anything
/// browsable in Finder. Disk images and system volumes are left out.
public enum Volumes {
    public static func list() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable ?? true,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            // The plain available figure, as Finder's Get Info and statfs report it.
            let free = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            return Volume(name: values.volumeName ?? url.lastPathComponent, path: url.path, total: UInt64(total), free: free,
                          isInternal: values.volumeIsInternal ?? false)
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}
