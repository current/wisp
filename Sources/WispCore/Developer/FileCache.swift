import Darwin
import Foundation

/// What was worked out from a file, kept until the file changes. Plan limits are read
/// every minute from files that change far less often (account details, settings, the
/// tails of old session logs), so each is read again only once its size, modification
/// time or inode moves.
enum FileCache {
    struct Stamp: Equatable {
        var seconds: Int
        var nanoseconds: Int
        var size: Int64
        var inode: UInt64

        var modified: Date { Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1e9) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: (stamp: Stamp, value: Any)] = [:]

    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Stamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec, size: info.st_size, inode: info.st_ino)
    }

    static func modified(_ path: String) -> Date? { stamp(path)?.modified }

    /// `make`'s answer for the file as it is now; `kind` keeps different readings of one file apart.
    static func value<T>(_ path: String, kind: String, _ make: () -> T) -> T {
        guard let stamp = stamp(path) else { return make() }
        let key = kind + ":" + path
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached, cached.stamp == stamp, let value = cached.value as? T { return value }
        let value = make()
        lock.lock()
        if entries.count > 1000 { entries.removeAll() }
        entries[key] = (stamp, value)
        lock.unlock()
        return value
    }
}
