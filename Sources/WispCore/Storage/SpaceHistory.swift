import Foundation

/// Where space went: a few hundred folder sizes from each day's scan, compared
/// with each other and with the hourly free-space figures in the archive.
public enum SpaceHistory {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var date: Date
        /// Absolute folder path to allocated bytes, for folders of at least `minimum`.
        public var sizes: [String: UInt64]
    }

    public struct Growth: Codable, Sendable, Equatable {
        public var path: String
        public var delta: Int64
    }

    public struct Jump: Codable, Sendable, Equatable {
        /// Hours since 1970: the last reading before the drop and the first after it.
        public var from: Int
        public var to: Int
        public var drop: UInt64
        /// What grew between the scans on either side, largest first. Empty when no scans bracket it.
        public var grew: [Growth]
    }

    public static let minimum: UInt64 = 256 << 20
    public static let depth = 5
    public static let keepDays = 45

    public static var url: URL { Wisp.supportDirectory.appendingPathComponent("storage-sizes.json") }

    /// Folder sizes worth comparing later: everything at least `minimum`, a few levels deep.
    public static func sizes(of roots: [String: FolderNode], minimum: UInt64 = minimum, depth: Int = depth) -> [String: UInt64] {
        var sizes: [String: UInt64] = [:]
        func visit(_ node: FolderNode, _ path: String, _ level: Int) {
            guard !node.isFile, node.size >= minimum else { return }
            sizes[path] = node.size
            guard level < depth else { return }
            for child in node.children { visit(child, path + "/" + child.name, level + 1) }
        }
        for (path, node) in roots { visit(node, path, 0) }
        return sizes
    }

    public static func load(from url: URL = url) -> [Snapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([Snapshot].self, from: data)) ?? []
    }

    /// Adds today's sizes, replacing an earlier scan from the same day, and drops old days.
    @discardableResult
    public static func record(_ sizes: [String: UInt64], now: Date = Date(), to url: URL = url) -> [Snapshot] {
        var snapshots = load(from: url)
        snapshots = merge(snapshots, Snapshot(date: now, sizes: sizes), now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(snapshots) { try? data.write(to: url, options: .atomic) }
        return snapshots
    }

    static func merge(_ snapshots: [Snapshot], _ new: Snapshot, now: Date) -> [Snapshot] {
        let calendar = Calendar.current
        var result = snapshots.filter { !calendar.isDate($0.date, inSameDayAs: new.date) }
        // Keep the day's first scan too, so a jump within today still has something before it.
        if let first = snapshots.first(where: { calendar.isDate($0.date, inSameDayAs: new.date) }), first.date < new.date.addingTimeInterval(-3600) {
            result.append(first)
        }
        result.append(new)
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return result.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    /// Folders that grew by at least `minimum`, each named at the deepest level that
    /// explains most of the growth, without listing a folder and one inside it.
    public static func growth(from old: [String: UInt64], to new: [String: UInt64], minimum: UInt64 = 1 << 30) -> [Growth] {
        var deltas: [String: Int64] = [:]
        for (path, size) in new {
            let before = old[path] ?? 0
            // A folder too small to be recorded before counts as empty, which is off by under `SpaceHistory.minimum`.
            deltas[path] = Int64(size) - Int64(before)
        }
        let grown = deltas.filter { $0.value >= Int64(minimum) }
        let explained = grown.filter { path, delta in
            !grown.contains { other, otherDelta in other.hasPrefix(path + "/") && Double(otherDelta) >= Double(delta) * 0.6 }
        }
        var picked: [Growth] = []
        for (path, delta) in explained.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            if picked.contains(where: { $0.path.hasPrefix(path + "/") || path.hasPrefix($0.path + "/") }) { continue }
            picked.append(Growth(path: path, delta: delta))
        }
        return picked
    }

    /// Hours where free space fell by at least `threshold`, each with what grew between
    /// the scans before and after it.
    public static func jumps(free: [(hour: Int, value: Double)], threshold: Double, snapshots: [Snapshot]) -> [Jump] {
        var jumps: [Jump] = []
        var index = 1
        while index < free.count {
            let drop = free[index - 1].value - free[index].value
            guard drop >= threshold else { index += 1; continue }
            // Consecutive falling hours make one jump.
            var end = index
            while end + 1 < free.count, free[end].value - free[end + 1].value >= threshold / 4 { end += 1 }
            let total = free[index - 1].value - free[end].value
            let start = Date(timeIntervalSince1970: Double(free[index - 1].hour) * 3600)
            let finish = Date(timeIntervalSince1970: Double(free[end].hour + 1) * 3600)
            var grew: [Growth] = []
            if let before = snapshots.last(where: { $0.date <= start }), let after = snapshots.first(where: { $0.date >= finish }) {
                grew = growth(from: before.sizes, to: after.sizes, minimum: UInt64(max(threshold / 2, Double(minimum))))
            }
            jumps.append(Jump(from: free[index - 1].hour, to: free[end].hour, drop: UInt64(max(0, total)), grew: grew))
            index = end + 1
        }
        return jumps
    }
}
