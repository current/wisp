import CryptoKit
import Darwin
import Foundation

/// A file the duplicate search may compare.
struct DuplicateCandidate: Sendable {
    var path: String
    var length: Int64
    var allocated: Int64
    var device: Int32
    var fileID: UInt64
    var cloneID: UInt64
    var created: Double
    var modified: Double
    var accessed: Double
    /// Lower is a better place to keep a copy: Documents and Pictures before Downloads and Desktop.
    var placeRank: Int
    var isICloud: Bool
}

/// Finds identical files: same size, then the same first and last 64 KB, then the same
/// SHA-256 of the whole file. Hashing reads at most `limit` bytes per run.
struct DuplicateFinder {
    var limit: Int64
    var isCancelled: () -> Bool

    static let edge = 64 * 1024
    private static let chunk = 1 << 20

    func groups(_ candidates: [DuplicateCandidate]) -> DuplicateSummary {
        var summary = DuplicateSummary()
        var budget = limit

        // One entry per data stream: hard links share an inode and pure clones share a clone id,
        // so removing one of them frees nothing.
        struct Key: Hashable { var device: Int32; var id: UInt64 }
        var inodes = Set<Key>()
        var clones = Set<Key>()
        var bySize: [Int64: [DuplicateCandidate]] = [:]
        for file in candidates {
            guard inodes.insert(Key(device: file.device, id: file.fileID)).inserted else { continue }
            if file.cloneID != 0, !clones.insert(Key(device: file.device, id: file.cloneID)).inserted { continue }
            bySize[file.length, default: []].append(file)
        }

        // Largest first, so the byte limit spends itself where the most space is.
        let sizes = bySize.filter { $0.value.count > 1 }.sorted { $0.key > $1.key }
        for (length, files) in sizes {
            if isCancelled() { break }
            let edgeCost = Int64(files.count) * min(length, Int64(2 * Self.edge))
            guard edgeCost <= budget else { summary.stoppedAtLimit = true; break }
            budget -= edgeCost
            summary.hashedBytes += edgeCost
            let edges = hash(files, using: edgeHash)
            for sameEdges in Dictionary(grouping: edges, by: \.digest).values where sameEdges.count > 1 {
                if isCancelled() { break }
                let wholeCost = length <= Int64(2 * Self.edge) ? 0 : Int64(sameEdges.count) * length
                guard wholeCost <= budget else { summary.stoppedAtLimit = true; break }
                budget -= wholeCost
                summary.hashedBytes += wholeCost
                let whole = wholeCost == 0 ? sameEdges : hash(sameEdges.map(\.file), using: fullHash)
                for same in Dictionary(grouping: whole, by: \.digest).values where same.count > 1 {
                    summary.groups.append(Self.group(same.map(\.file), digest: same[0].digest))
                }
            }
            if summary.stoppedAtLimit { break }
        }
        summary.groups.sort { $0.reclaimable > $1.reclaimable }
        return summary
    }

    /// The keeper goes first: the best place, then the oldest copy, then the shortest path.
    static func group(_ files: [DuplicateCandidate], digest: String) -> DuplicateGroup {
        let ordered = files.sorted {
            ($0.placeRank, $0.created, $0.path.count, $0.path) < ($1.placeRank, $1.created, $1.path.count, $1.path)
        }
        return DuplicateGroup(id: "dup-" + digest.prefix(16), length: ordered[0].length, paths: ordered.map(\.path),
                              reclaimable: ordered.dropFirst().reduce(0) { $0 + $1.allocated })
    }

    private struct Hashed { var file: DuplicateCandidate; var digest: String }

    /// Hashes a few files at once; files that cannot be read drop out.
    private func hash(_ files: [DuplicateCandidate], using digest: (DuplicateCandidate) -> String?) -> [Hashed] {
        var results = [Hashed?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            guard !isCancelled(), let value = digest(files[index]) else { return }
            lock.withLock { results[index] = Hashed(file: files[index], digest: value) }
        }
        return results.compactMap { $0 }
    }

    private func open(_ file: DuplicateCandidate) -> Int32? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        // The file changed since the walk, or it is not a plain local file any more.
        guard fstat(fd, &info) == 0, Int64(info.st_size) == file.length, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            close(fd)
            return nil
        }
        // Reads for hashing should not push the owner's working set out of the cache.
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    private func edgeHash(_ file: DuplicateCandidate) -> String? {
        guard let fd = open(file) else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        // A file of 128 KB or less is read whole, so its edge hash is already the full hash.
        let small = file.length <= Int64(2 * Self.edge)
        for offset in small ? [0] : [0, file.length - Int64(Self.edge)] {
            let wanted = small ? Int(file.length) : Self.edge
            var data = [UInt8](repeating: 0, count: wanted)
            var done = 0
            while done < wanted {
                let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, wanted - done, offset + Int64(done)) }
                guard count > 0 else { return nil }
                done += count
            }
            hasher.update(data: data)
        }
        return Self.hex(hasher.finalize())
    }

    private func fullHash(_ file: DuplicateCandidate) -> String? {
        guard let fd = open(file) else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        var total: Int64 = 0
        while true {
            if isCancelled() { return nil }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, Self.chunk) }
            if count < 0 { return nil }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            total += Int64(count)
        }
        return total == file.length ? Self.hex(hasher.finalize()) : nil
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
