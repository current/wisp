import CoreServices
import Darwin
import Foundation

/// Folder sizes for the scanners. FolderScanner does the walking; a light timer
/// passes the scan's cancel state on to it, so a long walk stops soon after the page closes.
final class CleanSizer: @unchecked Sendable {
    struct Size {
        var bytes: Int64
        var modified: Date?
    }

    private let flag = ScanFlag()
    private let watch: DispatchSourceTimer
    private let rules: FolderScanner.Rules = {
        var rules = FolderScanner.Rules()
        // Only the totals matter here, so no node below the root is kept.
        rules.keepChildren = 0
        rules.smallestFolder = .max
        rules.smallestFile = .max
        return rules
    }()

    init(_ context: CleanScanContext) {
        watch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watch.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(100))
        let flag = flag
        let isCancelled = context.isCancelled
        watch.setEventHandler { if isCancelled() { flag.set() } }
        watch.resume()
    }

    deinit { watch.cancel() }

    var cancelled: Bool { flag.isSet }

    /// A folder's whole size, or a file's allocated size.
    func size(_ path: String) -> Size {
        var info = stat()
        guard lstat(path, &info) == 0 else { return Size(bytes: 0, modified: nil) }
        if info.st_mode & S_IFMT == S_IFDIR {
            let node = FolderScanner(rules: rules, cancel: flag).folder(at: path)
            return Size(bytes: Int64(clamping: node.size), modified: node.modified > 0 ? Date(timeIntervalSince1970: node.modified) : nil)
        }
        return Size(bytes: Int64(info.st_blocks) * 512, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
    }

    /// Sizes of many paths, four at a time.
    func sizes(_ paths: [String]) -> [String: Size] {
        let lock = NSLock()
        var next = 0
        var sizes: [String: Size] = [:]
        DispatchQueue.concurrentPerform(iterations: min(4, max(1, paths.count))) { _ in
            while !cancelled {
                let index: Int? = lock.withLock {
                    guard next < paths.count else { return nil }
                    defer { next += 1 }
                    return next
                }
                guard let index else { return }
                let measured = self.size(paths[index])
                lock.withLock { sizes[paths[index]] = measured }
            }
        }
        return sizes
    }

    /// Bytes and newest change over several paths.
    func total(_ paths: [String], sizes: [String: Size]) -> Size {
        var total = Size(bytes: 0, modified: nil)
        for path in paths {
            guard let size = sizes[path] else { continue }
            total.bytes += size.bytes
            if let modified = size.modified { total.modified = max(total.modified ?? modified, modified) }
        }
        return total
    }
}

extension CleanScanContext {
    /// Excluded itself, or holding something the owner excluded: removing it would take that too.
    func isBlocked(_ path: String) -> Bool {
        isExcluded(path) || excluded.contains { $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
    }

    var homePath: String { home.path }
}

enum CleanFiles {
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Names in a folder, without "." and "..". Empty when it cannot be read.
    static func names(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    struct Entry {
        var name: String
        var isFolder: Bool
        var isFile: Bool
        /// Seconds since 1970.
        var modified: Double
    }

    /// A folder's entries with their type and modification time, a few hundred per
    /// system call. Nil when the folder cannot be opened or holds more than `limit` entries.
    static func entries(_ path: String, limit: Int = .max, dates: Bool = true, buffer: inout [UInt8]) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                               commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
                                   | attrgroup_t(ATTR_CMN_OBJTYPE) | (dates ? attrgroup_t(ATTR_CMN_MODTIME) : 0),
                               volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        let capacity = buffer.count
        var entries: [Entry] = []
        while true {
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &request, $0.baseAddress!, capacity, UInt64(FSOPT_NOFOLLOW)) }
            if count <= 0 { return entries }
            if entries.count > limit { return nil }
            buffer.withUnsafeBytes { raw in
                var entry = raw.baseAddress!
                for _ in 0..<count {
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    defer { entry += length }
                    // Attributes come in the order of their bits, with the error right after the returned set.
                    var p = entry + 4
                    let returned = p.loadUnaligned(as: attribute_set_t.self)
                    p += MemoryLayout<attribute_set_t>.size
                    if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                        let error = p.loadUnaligned(as: UInt32.self)
                        p += 4
                        if error != 0 { continue }
                    }
                    guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                    let reference = p.loadUnaligned(as: attrreference_t.self)
                    let name = String(cString: (p + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    p += MemoryLayout<attrreference_t>.size
                    var type: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                        type = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    var modified = 0.0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                        modified = Double(p.loadUnaligned(as: Int.self))
                    }
                    entries.append(Entry(name: name, isFolder: type == UInt32(VDIR.rawValue),
                                         isFile: type == UInt32(VREG.rawValue) || type == UInt32(VLNK.rawValue), modified: modified))
                }
            }
        }
    }

    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }
    }

    /// Whether a folder in the home folder is one macOS guards behind a privacy prompt.
    static func isGuarded(_ path: String, home: String) -> Bool {
        StorageAccess.guarded.contains { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }
    }

    /// Folders in the home folder that hold code, each once even where names differ only in case.
    static func projectRoots(home: String, readsGuarded: Bool) -> [String] {
        var seen = Set<[UInt64]>()
        var roots: [String] = []
        for name in StorageCatalog.codeFolders + ["Documents", "Desktop"] {
            let path = home + "/" + name
            if !readsGuarded && isGuarded(path, home: home) { continue }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard seen.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted else { continue }
            roots.append(path)
        }
        return roots
    }
}

/// Where this user's running processes are working, so scanners can leave those folders alone.
public enum WorkingFolders {
    public static func current() -> [String] {
        var pids = [Int32](repeating: 0, count: 4096)
        while true {
            let count = Int(pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) })
            if count < pids.count - 16 {
                var folders = Set<String>()
                for pid in pids.prefix(max(0, count)) where pid > 0 {
                    if let folder = ProcessDetails.workingDirectory(pid: pid), folder != "/" { folders.insert(folder) }
                }
                return Array(folders)
            }
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
    }

    /// Whether any of `folders` is `path` or inside it.
    public static func contains(_ folders: [String], inside path: String) -> Bool {
        folders.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
}

/// App names by bundle identifier, from LaunchServices.
public enum AppNames {
    /// The name Finder shows for the app, or nil when no app with that identifier is installed.
    public static func name(bundleID: String) -> String? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL],
              let url = urls.first else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}
