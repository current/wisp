import Foundation

/// The tabs of the Clean Up page.
public enum CleanTab: String, Codable, CaseIterable, Sendable {
    case junk, developer, largeFiles, leftovers, uninstall, history

    public var title: String {
        switch self {
        case .junk: return "Junk"
        case .developer: return "Developer"
        case .largeFiles: return "Large Files"
        case .leftovers: return "Leftovers"
        case .uninstall: return "Uninstall"
        case .history: return "History"
        }
    }
}

/// Safe: a cache or build output the owner gets back by using the app. Check first:
/// probably fine, but it can cost something (a re-download, a sign-in, lost history).
public enum CleanSafety: String, Codable, Sendable {
    case safe, checkFirst
}

/// How an item goes away. Everything goes to the Trash except what only the owning
/// tool can remove; those are permanent, shown with a warning, and never part of
/// Clean Safe Items.
public enum CleanRemoval: Codable, Sendable, Hashable {
    case trash
    /// `xcrun simctl delete <udid>`
    case simulator(udid: String)
    /// `xcrun simctl runtime delete <identifier>`
    case simulatorRuntime(identifier: String)
    /// `tmutil deletelocalsnapshots <date>`
    case localSnapshot(date: String)
    /// `brew uninstall --cask <token>`
    case brewCask(token: String)

    public var isPermanent: Bool { self != .trash }
}

/// What was at a path when a scan saw it, so a clean can tell that the same thing is
/// still there and not something that took its name since.
public struct CleanStamp: Codable, Sendable, Hashable {
    public var device: Int64
    public var inode: UInt64
    /// `st_mode & S_IFMT`: a folder stays a folder, a link stays a link.
    public var kind: UInt32
    public var size: Int64
    /// Nanoseconds since 1970.
    public var modified: Int64

    public init(device: Int64, inode: UInt64, kind: UInt32, size: Int64, modified: Int64) {
        self.device = device
        self.inode = inode
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    /// The path itself, not what a link at it points to. Nil when nothing is there.
    public init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.init(device: Int64(info.st_dev), inode: UInt64(info.st_ino), kind: UInt32(info.st_mode & S_IFMT), size: Int64(info.st_size),
                  modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
    }

    public var isRegularFile: Bool { kind == UInt32(S_IFREG) }

    /// The same object. With `content`, a regular file must also have kept its size and date:
    /// the owner chose it for what was in it.
    public func same(as other: CleanStamp, content: Bool) -> Bool {
        guard device == other.device, inode == other.inode, kind == other.kind else { return false }
        return !content || !isRegularFile || (size == other.size && modified == other.modified)
    }
}

/// One row on the Clean Up page: something that can go, what it is and what removing it costs.
public struct CleanItem: Codable, Sendable, Identifiable, Hashable {
    /// Stable across scans: the scanner's kind plus the first path, so selections and exclusions survive a rescan.
    public var id: String
    public var tab: CleanTab
    /// The heading the row sits under: "App caches", "System junk", "Xcode", "Projects", "Videos"...
    public var group: String
    /// What a person calls it: "Google Chrome cache", "node_modules in wisp".
    public var name: String
    /// One plain sentence on what it is and what removing it does.
    public var detail: String
    /// Absolute paths. Every one of them goes when the item is removed.
    public var paths: [String]
    public var bytes: Int64
    public var modified: Date?
    public var safety: CleanSafety
    public var removal: CleanRemoval
    /// The app the item belongs to, for its icon and to check that it is not running.
    public var ownerBundleID: String?
    /// Strict matches arrive ticked; loose ones (a name match) arrive unticked for the owner to confirm.
    public var checkedByDefault: Bool
    /// What each path was when the scan saw it. A clean leaves a path whose stamp is missing
    /// or no longer matches. Kept out of JSON: it means nothing outside this Mac and this run.
    public var stamps: [String: CleanStamp] = [:]

    private enum CodingKeys: String, CodingKey {
        case id, tab, group, name, detail, paths, bytes, modified, safety, removal, ownerBundleID, checkedByDefault
    }

    public init(id: String, tab: CleanTab, group: String, name: String, detail: String, paths: [String], bytes: Int64,
                modified: Date? = nil, safety: CleanSafety, removal: CleanRemoval = .trash, ownerBundleID: String? = nil,
                checkedByDefault: Bool = true) {
        self.id = id
        self.tab = tab
        self.group = group
        self.name = name
        self.detail = detail
        self.paths = paths
        self.bytes = bytes
        self.modified = modified
        self.safety = safety
        self.removal = removal
        self.ownerBundleID = ownerBundleID
        self.checkedByDefault = checkedByDefault
    }

    /// Records what is at each path not stamped yet. Scanners call it where they measure a
    /// path; the registry and the uninstall planner call it for whatever a scanner left.
    public mutating func stamp() {
        for path in paths where stamps[path] == nil {
            if let stamp = CleanStamp(path: path) { stamps[path] = stamp }
        }
    }

    public func stamped() -> CleanItem {
        var copy = self
        copy.stamp()
        return copy
    }
}

/// What a scanner gets: where to look, what to leave alone, and how to report as it goes.
public struct CleanScanContext: Sendable {
    public var home: URL
    /// Absolute paths the owner excluded. Skip anything at or under them.
    public var excluded: [String]
    /// Checked often during long walks; return what you have when it turns true.
    public var isCancelled: @Sendable () -> Bool
    /// Called with batches of items as they are found, so the page fills in while the scan runs.
    public var found: @Sendable ([CleanItem]) -> Void

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), excluded: [String] = [],
                isCancelled: @escaping @Sendable () -> Bool = { false }, found: @escaping @Sendable ([CleanItem]) -> Void = { _ in }) {
        self.home = home
        self.excluded = excluded
        self.isCancelled = isCancelled
        self.found = found
    }

    public func isExcluded(_ path: String) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

/// Finds items for one tab. Scanners run on a background queue, only while the Clean Up page
/// (or a `wisp clean` command) asks, and never change anything on disk.
public protocol CleanScanner: Sendable {
    var tab: CleanTab { get }
    func scan(_ context: CleanScanContext) -> [CleanItem]
}
