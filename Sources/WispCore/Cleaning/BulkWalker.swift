import Darwin
import Foundation

/// One entry of a folder as `getattrlistbulk` returns it.
struct BulkEntry {
    enum Kind { case file, folder, symlink, other }

    var name: String
    var kind: Kind
    var device: Int32
    var fileID: UInt64
    var links: UInt32
    var allocated: UInt64
    var length: UInt64
    var created: Double
    var modified: Double
    var accessed: Double
    var flags: UInt32
    /// Pure APFS clones share it; 0 when the volume does not report one.
    var cloneID: UInt64

    /// Its contents live in the cloud. Reading it would start a download.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }
    var pathExtension: String { (name as NSString).pathExtension.lowercased() }
}

/// Walks folders with `getattrlistbulk`, a few hundred entries per call, never following
/// a symlink. The visitor decides which folders to enter.
final class BulkWalker {
    enum Visit { case descend, skip }

    private let isCancelled: () -> Bool
    private var buffers: [[UInt8]] = []
    /// Folder depth below the start; deeper folders are not entered (one descriptor per level is open).
    var maxDepth = 48

    init(isCancelled: @escaping () -> Bool) {
        self.isCancelled = isCancelled
    }

    /// Calls `visit(parent, entry, depth)` for every entry under `path`, depth 0 being the
    /// entries of `path` itself. `display` is the path reported as the parent, so a walk
    /// that started through a symlink reports paths through the link.
    func walk(_ path: String, display: String? = nil, visit: (_ parent: String, _ entry: BulkEntry, _ depth: Int) -> Visit) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        var info = stat()
        fstat(fd, &info)
        walk(fd: fd, path: display ?? path, device: info.st_dev, depth: 0, visit: visit)
        close(fd)
    }

    private func walk(fd: Int32, path: String, device: Int32, depth: Int, visit: (String, BulkEntry, Int) -> Visit) {
        if isCancelled() { return }
        var subfolders: [String] = []
        list(fd) { entry in
            if visit(path, entry, depth) == .descend, entry.kind == .folder, entry.device == device, depth < maxDepth {
                subfolders.append(entry.name)
            }
        }
        for name in subfolders {
            if isCancelled() { return }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            walk(fd: child, path: path + "/" + name, device: device, depth: depth + 1, visit: visit)
            close(child)
        }
    }

    /// Allocated bytes of the regular files under `path` (hard links once), and the newest modification time.
    func folderSize(_ path: String) -> (bytes: UInt64, newest: Double) {
        var bytes: UInt64 = 0
        var newest = 0.0
        var linked = Set<UInt64>()
        walk(path) { _, entry, _ in
            newest = max(newest, entry.modified)
            guard entry.kind == .file else { return .descend }
            if entry.links > 1, !linked.insert(entry.fileID).inserted { return .skip }
            bytes &+= entry.allocated
            return .skip
        }
        return (bytes, newest)
    }

    // MARK: Listing one folder

    private static let common: attrgroup_t = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_ACCTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
    private static let fileAttributes: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        | attrgroup_t(ATTR_FILE_DATALENGTH)
    private static let extended: attrgroup_t = attrgroup_t(ATTR_CMNEXT_CLONEID)

    /// Entries come back in bit order of the attributes, `ATTR_CMN_ERROR` right after the returned set.
    private func list(_ fd: Int32, each: (BulkEntry) -> Void) {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: Self.common, volattr: 0,
                               dirattr: 0, fileattr: Self.fileAttributes, forkattr: Self.extended)
        let options = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_ATTR_CMN_EXTENDED)
        var buffer = buffers.popLast() ?? [UInt8](repeating: 0, count: 64 * 1024)
        defer { buffers.append(buffer) }
        let capacity = buffer.count
        while true {
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &request, $0.baseAddress!, capacity, options) }
            if count <= 0 { return }
            buffer.withUnsafeBytes { raw in
                var start = raw.baseAddress!
                for _ in 0..<count {
                    let length = Int(start.loadUnaligned(as: UInt32.self))
                    defer { start += length }
                    if let entry = Self.entry(at: start) { each(entry) }
                }
            }
        }
    }

    private static func entry(at start: UnsafeRawPointer) -> BulkEntry? {
        var p = start + 4
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        func has(_ bit: Int32) -> Bool { returned.commonattr & attrgroup_t(bit) != 0 }
        func time() -> Double {
            let value = Double(p.loadUnaligned(as: Int.self))
            p += MemoryLayout<timespec>.size
            return value
        }
        if has(ATTR_CMN_ERROR) {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 { return nil }
        }
        var entry = BulkEntry(name: "", kind: .other, device: 0, fileID: 0, links: 1, allocated: 0, length: 0,
                              created: 0, modified: 0, accessed: 0, flags: 0, cloneID: 0)
        if has(ATTR_CMN_NAME) {
            let reference = p.loadUnaligned(as: attrreference_t.self)
            entry.name = String(cString: (p + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            p += MemoryLayout<attrreference_t>.size
        }
        if has(ATTR_CMN_DEVID) {
            entry.device = p.loadUnaligned(as: Int32.self)
            p += MemoryLayout<dev_t>.size
        }
        if has(ATTR_CMN_OBJTYPE) {
            switch p.loadUnaligned(as: UInt32.self) {
            case UInt32(VREG.rawValue): entry.kind = .file
            case UInt32(VDIR.rawValue): entry.kind = .folder
            case UInt32(VLNK.rawValue): entry.kind = .symlink
            default: entry.kind = .other
            }
            p += 4
        }
        if has(ATTR_CMN_CRTIME) { entry.created = time() }
        if has(ATTR_CMN_MODTIME) { entry.modified = time() }
        if has(ATTR_CMN_ACCTIME) { entry.accessed = time() }
        if has(ATTR_CMN_FLAGS) {
            entry.flags = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if has(ATTR_CMN_FILEID) {
            entry.fileID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            entry.links = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocated = UInt64(max(0, p.loadUnaligned(as: Int64.self)))
            p += 8
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            entry.length = UInt64(max(0, p.loadUnaligned(as: Int64.self)))
            p += 8
        }
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
            entry.cloneID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        return entry
    }
}

/// A few threads that work through tasks, where a task may add more. The calling thread
/// works too, so the pool finishes even when no other thread is free to join it.
final class TaskPool: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [() -> Void] = []
    private var running = 0
    /// Helpers that joined and have not left yet.
    private var helpers = 0
    private var closed = false
    private let helpersLeft = DispatchSemaphore(value: 0)

    func add(_ task: @escaping () -> Void) {
        lock.withLock { tasks.append(task) }
    }

    /// Returns when every task, including those added along the way, is done.
    func run(threads: Int, qos: DispatchQoS.QoSClass) {
        for _ in 1..<max(1, threads) {
            DispatchQueue.global(qos: qos).async { [self] in
                let joined = lock.withLock {
                    if closed { return false }
                    helpers += 1
                    return true
                }
                guard joined else { return }
                work()
                let last = lock.withLock {
                    helpers -= 1
                    return closed && helpers == 0
                }
                if last { helpersLeft.signal() }
            }
        }
        work()
        let wait = lock.withLock {
            closed = true
            return helpers > 0
        }
        if wait { helpersLeft.wait() }
    }

    private func work() {
        while true {
            let next: (() -> Void)?? = lock.withLock {
                if let task = tasks.popLast() {
                    running += 1
                    return .some(task)
                }
                return running == 0 ? nil : .some(nil)
            }
            guard let next else { return }
            guard let task = next else {
                usleep(2000)
                continue
            }
            autoreleasepool { task() }
            lock.withLock { running -= 1 }
        }
    }
}
