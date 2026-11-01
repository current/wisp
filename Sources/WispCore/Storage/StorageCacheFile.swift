import Foundation

/// The scan cache on disk: a short JSON header and the trees in a compact binary
/// form, depth first. Decoding JSON for 50,000 folders would allocate tens of
/// megabytes for a moment; this reads straight into nodes.
enum StorageCacheFile {
    static let magic = Data("WISPSTO2".utf8)

    struct Header: Codable {
        var version: Int
        var eventID: UInt64
        var date: Double
        var seconds: [String: Double]
        var fullDiskAccess: Bool
        var roots: [String]
    }

    static func encode(_ cache: StorageIndex.Cache) -> Data? {
        let order = cache.roots.keys.sorted()
        let header = Header(version: cache.version, eventID: cache.eventID, date: cache.date.timeIntervalSince1970, seconds: cache.seconds,
                            fullDiskAccess: cache.fullDiskAccess, roots: order)
        guard let json = try? JSONEncoder().encode(header) else { return nil }
        var data = Data()
        data.reserveCapacity(4 << 20)
        data.append(magic)
        append(UInt32(json.count), to: &data)
        data.append(json)
        for root in order { if let node = cache.roots[root] { write(node, to: &data) } }
        return data
    }

    static func decode(_ data: Data) -> StorageIndex.Cache? {
        guard data.count > magic.count + 4, data.prefix(magic.count) == magic else { return nil }
        return data.withUnsafeBytes { raw -> StorageIndex.Cache? in
            var reader = Reader(raw: raw, offset: magic.count)
            guard let length = reader.u32(), let json = reader.bytes(Int(length)),
                  let header = try? JSONDecoder().decode(Header.self, from: Data(json)) else { return nil }
            var roots: [String: FolderNode] = [:]
            for root in header.roots {
                guard let node = reader.node(depth: 0) else { return nil }
                roots[root] = node
            }
            return StorageIndex.Cache(version: header.version, eventID: header.eventID, date: Date(timeIntervalSince1970: header.date),
                                      roots: roots, seconds: header.seconds, fullDiskAccess: header.fullDiskAccess)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func write(_ node: FolderNode, to data: inout Data) {
        let name = Array(node.name.utf8.prefix(Int(UInt16.max)))
        append(UInt16(name.count), to: &data)
        data.append(contentsOf: name)
        append(UInt8((node.isFile ? 1 : 0) | (node.locked ? 2 : 0)), to: &data)
        append(node.size, to: &data)
        append(node.files, to: &data)
        append(UInt32(clamping: Int64(node.modified)), to: &data)
        append(UInt32(clamping: Int64(node.ownModified)), to: &data)
        append(node.otherSize, to: &data)
        append(node.otherCount, to: &data)
        append(UInt32(node.children.count), to: &data)
        for child in node.children { write(child, to: &data) }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var offset: Int

        mutating func value<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= raw.count else { return nil }
            defer { offset += size }
            return T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
        }

        mutating func u32() -> UInt32? { value(UInt32.self) }

        mutating func bytes(_ count: Int) -> UnsafeRawBufferPointer? {
            guard count >= 0, offset + count <= raw.count else { return nil }
            defer { offset += count }
            return UnsafeRawBufferPointer(rebasing: raw[offset..<offset + count])
        }

        mutating func node(depth: Int) -> FolderNode? {
            guard depth < 512, let length = value(UInt16.self), let name = bytes(Int(length)), let flags = value(UInt8.self),
                  let size = value(UInt64.self), let files = value(UInt64.self), let modified = value(UInt32.self),
                  let own = value(UInt32.self), let otherSize = value(UInt64.self), let otherCount = value(UInt32.self),
                  let count = value(UInt32.self) else { return nil }
            var children: [FolderNode] = []
            children.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                guard let child = node(depth: depth + 1) else { return nil }
                children.append(child)
            }
            return FolderNode(name: String(decoding: name, as: UTF8.self), size: size, files: files, modified: Double(modified),
                              ownModified: Double(own), isFile: flags & 1 != 0, locked: flags & 2 != 0, children: children,
                              otherSize: otherSize, otherCount: otherCount)
        }
    }
}
