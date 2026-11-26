import CoreServices
import Darwin
import Foundation

/// Folder sizes for the scanners: allocated bytes, hard links and clones counted once,
/// the newest change inside, and how many folders could not be read. Many folders are
/// measured at once on a few threads, a large folder split between them. A folder
/// measured before and unchanged since, as FSEvents tells, is not read again; one
/// changed in a few of its subfolders reads only those again.
final class CleanSizer: @unchecked Sendable {
    struct Size {
        var bytes: Int64
        var modified: Date?
        /// Folders inside that could not be read.
        var locked = 0
        /// What was at the path when it was measured.
        var stamp: CleanStamp?

        /// Said after a row's detail when part of it could not be read, so its size may be short.
        var unreadNote: String {
            locked == 0 ? "" : locked == 1 ? " One folder inside could not be read." : " \(locked) folders inside could not be read."
        }
    }

    private let isCancelled: () -> Bool
    let cache: CleanScanCache?
    /// Absolute paths that are not entered, such as folders guarded by privacy settings.
    var skip: Set<String> = []
    var threads = CleanSizer.threadCount()

    /// Listing threads contend for the volume's locks in the kernel: on this Mac a second
    /// thread halved the time and a fourth cost twice the CPU for a little more speed. Four
    /// only when the Mac has the cores to spare, two when it is busy.
    static func threadCount() -> Int {
        var load = [Double](repeating: 0, count: 1)
        let idle = getloadavg(&load, 1) == 1 ? Double(ProcessInfo.processInfo.activeProcessorCount) - load[0] : 0
        return idle >= 6 ? 4 : idle >= 3 ? 3 : 2
    }

    init(_ context: CleanScanContext, cache: CleanScanCache? = CleanScanCache.shared) {
        isCancelled = context.isCancelled
        self.cache = cache
    }

    init(isCancelled: @escaping () -> Bool = { false }, cache: CleanScanCache? = CleanScanCache.shared) {
        self.isCancelled = isCancelled
        self.cache = cache
    }

    var cancelled: Bool { isCancelled() }

    /// A folder's whole size, or a file's allocated size.
    func size(_ path: String) -> Size {
        sizes([path])[path] ?? Size(bytes: 0, modified: nil)
    }

    /// Sizes of many paths, each one present unless the scan was stopped.
    func sizes(_ paths: [String]) -> [String: Size] {
        var result: [String: Size] = [:]
        var jobs: [SizeWalk.Job] = []
        var stamps: [String: CleanStamp] = [:]
        var catchingUp = false
        for path in Set(paths) {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                result[path] = Size(bytes: 0, modified: nil)
                continue
            }
            let stamp = CleanStamp(info)
            guard info.st_mode & S_IFMT == S_IFDIR else {
                result[path] = Size(bytes: Int64(info.st_blocks) * 512, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
                                    stamp: stamp)
                continue
            }
            if skip.contains(path) {
                result[path] = Size(bytes: 0, modified: nil, locked: 1, stamp: stamp)
                continue
            }
            // Folders left out on purpose would make a record that is short once they may be read.
            let cache = skip.isEmpty ? cache.flatMap { $0.isFollowed(path) ? $0 : nil } : nil
            if let cache, !catchingUp {
                cache.catchUp(within: cache.reuseWindow, isCancelled: isCancelled)
                catchingUp = true
            }
            let known = cache?.folder(path).flatMap { $0.inode == UInt64(info.st_ino) && !$0.stale ? $0 : nil }
            if let known, known.isClean {
                result[path] = Size(bytes: known.bytes, modified: known.newest > 0 ? Date(timeIntervalSince1970: known.newest) : nil,
                                    locked: known.locked, stamp: stamp)
                continue
            }
            // A folder changed only in some subfolders keeps the others' figures.
            var reuse: [String: CleanScanCache.Part] = [:]
            if let known, let children = known.children {
                reuse = children.filter { !known.changedChildren.contains($0.key) }
            }
            jobs.append(SizeWalk.Job(path: path, inode: UInt64(info.st_ino), device: info.st_dev, reuse: reuse, followed: cache != nil))
            stamps[path] = stamp
        }
        guard !jobs.isEmpty else { return result }
        let event = CleanScanCache.currentEvent()
        // Each folder keeps a descriptor open while it is walked, so a long list goes a batch at a time.
        for start in stride(from: 0, to: jobs.count, by: SizeWalk.batch) where !cancelled {
            SizeWalk(jobs: Array(jobs[start..<min(jobs.count, start + SizeWalk.batch)]), skip: skip, isCancelled: isCancelled).run(threads: threads)
        }
        let stopped = cancelled
        for job in jobs {
            let total = job.total
            result[job.path] = Size(bytes: total.bytes, modified: total.newest > 0 ? Date(timeIntervalSince1970: total.newest) : nil,
                                    locked: total.locked, stamp: stamps[job.path])
            // A folder with parts that could not be read is read again next time, in case access was granted.
            guard !stopped, job.opened, job.followed, total.locked == 0, let cache else { continue }
            cache.store(job.path, CleanScanCache.Folder(inode: job.inode, bytes: total.bytes, newest: total.newest, files: total.files,
                                                        locked: total.locked, event: event, own: job.own,
                                                        children: job.children.count <= CleanScanCache.childLimit ? job.children : nil))
        }
        return result
    }

    /// Bytes and newest change over several paths.
    func total(_ paths: [String], sizes: [String: Size]) -> Size {
        var total = Size(bytes: 0, modified: nil)
        for path in paths {
            guard let size = sizes[path] else { continue }
            total.bytes += size.bytes
            total.locked += size.locked
            if let modified = size.modified { total.modified = max(total.modified ?? modified, modified) }
        }
        return total
    }
}

/// One parallel walk over several folders. Each folder's subfolders are tasks of their
/// own while threads are idle, and walked in place otherwise.
final class SizeWalk: @unchecked Sendable {
    final class Job: @unchecked Sendable {
        let path: String
        let inode: UInt64
        let device: dev_t
        let reuse: [String: CleanScanCache.Part]
        let followed: Bool
        var fd: Int32 = -1
        var opened = false
        let lock = NSLock()
        var own = CleanScanCache.Part()
        var children: [String: CleanScanCache.Part] = [:]
        var linked = Set<UInt64>()
        var clones = Set<UInt64>()

        init(path: String, inode: UInt64, device: dev_t, reuse: [String: CleanScanCache.Part], followed: Bool) {
            self.path = path
            self.inode = inode
            self.device = device
            self.reuse = reuse
            self.followed = followed
        }

        var total: CleanScanCache.Part {
            var total = own
            for child in children.values {
                total.bytes += child.bytes
                total.files += child.files
                total.locked += child.locked
                total.newest = max(total.newest, child.newest)
            }
            return total
        }

        /// The first time this file's data is met in this folder.
        func first(link id: UInt64) -> Bool { lock.withLock { linked.insert(id).inserted } }
        func first(clone id: UInt64) -> Bool { lock.withLock { clones.insert(id).inserted } }
    }

    let jobs: [Job]
    let skip: Set<String>
    let isCancelled: () -> Bool
    private let pool = TaskPool()
    private var threads = 4
    private let bufferLock = NSLock()
    private var buffers: [[UInt8]] = []

    init(jobs: [Job], skip: Set<String>, isCancelled: @escaping () -> Bool) {
        self.jobs = jobs
        self.skip = skip
        self.isCancelled = isCancelled
    }

    static let batch = 64

    func run(threads: Int) {
        self.threads = threads
        Self.raiseFileLimit()
        for job in jobs {
            job.fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard job.fd >= 0 else {
                job.own.locked = errno == EACCES || errno == EPERM ? 1 : 0
                continue
            }
            job.opened = true
            pool.add { [self] in listRoot(job) }
        }
        pool.run(threads: threads, qos: .utility)
        for job in jobs where job.fd >= 0 { close(job.fd) }
    }

    /// Deep trees keep a descriptor open per level in each thread.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 4096 else { return }
        limit.rlim_cur = min(4096, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    private func buffer() -> [UInt8] {
        bufferLock.withLock { buffers.popLast() } ?? [UInt8](repeating: 0, count: 256 * 1024)
    }

    private func recycle(_ buffer: [UInt8]) {
        bufferLock.withLock { buffers.append(buffer) }
    }

    /// The folder's own entries; each subfolder not known from before becomes a task.
    private func listRoot(_ job: Job) {
        if isCancelled() { return }
        var buffer = buffer()
        defer { recycle(buffer) }
        var own = CleanScanCache.Part()
        var subfolders: [(name: String, inode: UInt64)] = []
        CleanScanCounters.opened()
        if !Self.list(job.fd, job: job, buffer: &buffer, into: &own, subfolders: &subfolders) { own.locked += 1 }
        var fresh: [String] = []
        job.lock.withLock {
            job.own = own
            for sub in subfolders {
                if let known = job.reuse[sub.name], known.inode == sub.inode {
                    job.children[sub.name] = known
                } else {
                    job.children[sub.name] = CleanScanCache.Part(inode: sub.inode)
                    fresh.append(sub.name)
                }
            }
        }
        for name in fresh {
            pool.add { [self] in walkChild(job, relative: name, bucket: name, depth: 1) }
        }
    }

    /// Folders deeper than this below a root are walked in place: opening a long relative
    /// path costs the kernel a lookup per level, more than an idle thread gains.
    static let splitDepth = 3

    private func walkChild(_ job: Job, relative: String, bucket: String, depth: Int) {
        if isCancelled() { return }
        var part = CleanScanCache.Part()
        if !skip.isEmpty, skip.contains(job.path + "/" + relative) {
            part.locked = 1
        } else {
            let fd = openat(job.fd, relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            if fd < 0 {
                if errno == EACCES || errno == EPERM { part.locked = 1 }
            } else {
                var buffer = buffer()
                walk(fd, job: job, relative: relative, bucket: bucket, depth: depth, buffer: &buffer, into: &part)
                recycle(buffer)
                close(fd)
            }
        }
        job.lock.withLock {
            var child = job.children[bucket] ?? CleanScanCache.Part()
            child.bytes += part.bytes
            child.files += part.files
            child.locked += part.locked
            child.newest = max(child.newest, part.newest)
            job.children[bucket] = child
        }
    }

    private func walk(_ fd: Int32, job: Job, relative: String, bucket: String, depth: Int, buffer: inout [UInt8],
                      into part: inout CleanScanCache.Part) {
        if isCancelled() { return }
        var subfolders: [(name: String, inode: UInt64)] = []
        CleanScanCounters.opened()
        if !Self.list(fd, job: job, buffer: &buffer, into: &part, subfolders: &subfolders) { part.locked += 1 }
        for sub in subfolders {
            let child = relative + "/" + sub.name
            if !skip.isEmpty, skip.contains(job.path + "/" + child) {
                part.locked += 1
                continue
            }
            if depth < Self.splitDepth, pool.waiting < threads {
                pool.add { [self] in walkChild(job, relative: child, bucket: bucket, depth: depth + 1) }
                continue
            }
            let childFD = openat(fd, sub.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if childFD < 0 {
                if errno == EACCES || errno == EPERM { part.locked += 1 }
                continue
            }
            walk(childFD, job: job, relative: child, bucket: bucket, depth: depth + 1, buffer: &buffer, into: &part)
            close(childFD)
        }
    }

    private static let common: attrgroup_t = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)
    private static let fileAttributes: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    /// No private size: it costs the kernel two to three times the rest, and a pure clone's is nothing.
    private static let extended: attrgroup_t = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

    /// Adds a folder's files to `part` and collects its subfolders on the same volume.
    /// False when it cannot be read.
    private static func list(_ fd: Int32, job: Job, buffer: inout [UInt8], into part: inout CleanScanCache.Part,
                             subfolders: inout [(name: String, inode: UInt64)]) -> Bool {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: common, volattr: 0,
                               dirattr: 0, fileattr: fileAttributes, forkattr: extended)
        let options = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_ATTR_CMN_EXTENDED)
        let capacity = buffer.count
        var read = false
        while true {
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &request, $0.baseAddress!, capacity, options) }
            if count < 0 { return read }
            if count == 0 { return true }
            read = true
            CleanScanCounters.listed(Int(count))
            buffer.withUnsafeBytes { raw in
                var entry = raw.baseAddress!
                for _ in 0..<count {
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    defer { entry += length }
                    var p = entry + 4
                    let returned = p.loadUnaligned(as: attribute_set_t.self)
                    p += MemoryLayout<attribute_set_t>.size
                    if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                        let error = p.loadUnaligned(as: UInt32.self)
                        p += 4
                        if error != 0 { continue }
                    }
                    var name: UnsafePointer<CChar>?
                    if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                        let reference = p.loadUnaligned(as: attrreference_t.self)
                        name = (p + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                        p += MemoryLayout<attrreference_t>.size
                    }
                    var device = job.device
                    if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                        device = p.loadUnaligned(as: Int32.self)
                        p += MemoryLayout<dev_t>.size
                    }
                    var type: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                        type = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    var modified = 0.0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                        modified = Double(p.loadUnaligned(as: Int.self))
                        p += MemoryLayout<timespec>.size
                    }
                    var flags: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                        flags = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    var fileID: UInt64 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                        fileID = p.loadUnaligned(as: UInt64.self)
                        p += 8
                    }
                    part.newest = max(part.newest, modified)
                    if type == UInt32(VDIR.rawValue) {
                        // Another volume mounted here, or a folder whose contents live in the cloud.
                        if device != job.device || flags & UInt32(SF_DATALESS) != 0 { continue }
                        if let name { subfolders.append((String(cString: name), fileID)) }
                        continue
                    }
                    guard type == UInt32(VREG.rawValue) || type == UInt32(VLNK.rawValue) else { continue }
                    var links: UInt32 = 1
                    var allocated: UInt64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                        links = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        allocated = UInt64(max(0, p.loadUnaligned(as: Int64.self)))
                        p += 8
                    }
                    var cloneID: UInt64 = 0
                    var extFlags: UInt64 = 0
                    if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                        cloneID = p.loadUnaligned(as: UInt64.self)
                        p += 8
                    }
                    if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                        extFlags = p.loadUnaligned(as: UInt64.self)
                        p += 8
                    }
                    part.files += 1
                    if links > 1, !job.first(link: fileID) { continue }
                    // Files with the same clone id are pure clones holding the same blocks, so a later copy adds nothing.
                    if extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0, cloneID != 0, !job.first(clone: cloneID) { continue }
                    part.bytes += Int64(allocated)
                }
            }
        }
    }
}

extension CleanStamp {
    init(_ info: stat) {
        self.init(device: Int64(info.st_dev), inode: UInt64(info.st_ino), kind: UInt32(info.st_mode & S_IFMT), size: Int64(info.st_size),
                  modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
    }
}

extension CleanItem {
    /// Stamps each path with what the scan saw when it measured it.
    func stamped(_ sizes: [String: CleanSizer.Size]) -> CleanItem {
        var item = self
        for path in paths {
            if let stamp = sizes[path]?.stamp { item.stamps[path] = stamp }
        }
        return item
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
        CleanScanCounters.opened()
        while let entry = readdir(dir) {
            CleanScanCounters.listed(1)
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
        CleanScanCounters.opened()
        while true {
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &request, $0.baseAddress!, capacity, UInt64(FSOPT_NOFOLLOW)) }
            if count <= 0 { return entries }
            CleanScanCounters.listed(Int(count))
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

/// Disk images attached right now, which the Trash cannot take while they are in use.
public enum DiskImages {
    /// Real paths of the image files, from `hdiutil info`. Empty when hdiutil gave no answer.
    public static func attached() -> Set<String> {
        Set((ProcessUse.attachedImages() ?? [:]).keys)
    }

    /// `images` holds real paths; `path` may reach the image through a link.
    static func isAttached(_ path: String, in images: Set<String>) -> Bool {
        !images.isEmpty && (images.contains(path) || images.contains(LargeFilesScanner.realPath(path) ?? path))
    }

    static let extensions: Set<String> = ["dmg", "iso", "img", "cdr", "sparseimage", "sparsebundle", "toast", "dmgpart"]
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
