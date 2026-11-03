import Darwin
import Foundation

/// A cancel flag shared between the page and a scan running on another queue.
public final class ScanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}

/// Walks folders with `getattrlistbulk`, one call per few hundred entries, and adds up
/// allocated sizes. Hard links and APFS clones count once. Nothing per file is kept:
/// each folder keeps its largest children and folds the rest into one figure.
public final class FolderScanner: @unchecked Sendable {
    public struct Rules: Sendable {
        /// Children kept per folder, largest first.
        public var keepChildren = 40
        /// Smallest folder kept as its own node.
        public var smallestFolder: UInt64 = 1 << 20
        /// Smallest file kept as its own node.
        public var smallestFile: UInt64 = 64 << 20
        /// Absolute paths that are not entered; they come back locked.
        public var skip: Set<String> = []
        /// Folders scanned at the same time below the root.
        public var threads = 4
        public init() {}
    }

    /// Folder names worth keeping even when they are not among the largest, because
    /// the developer list looks for them.
    static let alwaysKept: Set<String> = ["node_modules", "target", ".venv", "venv", "build", ".build", "DerivedData", ".gradle", "Pods"]

    private let rules: Rules
    private let flag: ScanFlag
    private let lock = NSLock()
    private var hardLinks = Set<UInt64>()
    private var clones = Set<UInt64>()
    private static let seenLimit = 400_000
    private var device: dev_t = 0
    /// Folders visited, for progress and timing.
    public private(set) var folders = 0

    public init(rules: Rules = Rules(), cancel: ScanFlag = ScanFlag()) {
        self.rules = rules
        self.flag = cancel
        Self.raiseFileLimit()
    }

    public var cancelled: Bool { flag.isSet }

    /// Deep trees keep one descriptor open per level in each thread.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 4096 else { return }
        limit.rlim_cur = min(4096, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// Scans `path` and everything under it on this volume. Work is shared out two
    /// levels down, so one large folder (Library) does not leave the other threads
    /// idle. The folders `order` puts first start first; `progress` gets the partial
    /// tree every so often.
    public func scan(_ path: String, order: [String: UInt64] = [:], progress: ((FolderNode) -> Void)? = nil) -> FolderNode {
        var info = stat()
        let name = (path as NSString).lastPathComponent
        guard lstat(path, &info) == 0 else { return FolderNode(name: name, locked: true) }
        device = info.st_dev
        if rules.skip.contains(path) { return FolderNode(name: name, locked: true) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return FolderNode(name: name, locked: true) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var rootTally = Tally(modified: Double(info.st_mtimespec.tv_sec), ownModified: Double(info.st_mtimespec.tv_sec))
        var subfolders: [String] = []
        var bigFiles: [FolderNode] = []
        let readable = list(fd, buffer: &buffer, into: &rootTally, folders: &subfolders, bigFiles: &bigFiles)
        close(fd)
        let root = rootTally.node(name)
        guard readable else {
            root.locked = true
            return root
        }
        subfolders.sort { (order[$0] ?? 0, $1) > (order[$1] ?? 0, $0) }

        // A first-level folder waits for its own subfolders, which are separate tasks.
        final class Pending {
            let node: FolderNode
            var waiting: Int
            var children: [FolderNode]
            init(node: FolderNode, waiting: Int, children: [FolderNode]) { (self.node, self.waiting, self.children) = (node, waiting, children) }
        }
        var tasks: [(first: String, second: String?)] = subfolders.map { ($0, nil) }
        var next = 0
        var pending: [String: Pending] = [:]
        var done: [FolderNode] = []
        var lastPublish = Date()
        let finish: (Pending) -> Void = { [rules] item in
            item.node.children = item.children.sorted { $0.size > $1.size }
            Self.keep(item.node, rules: rules)
            done.append(item.node)
        }
        let group = DispatchGroup()
        for _ in 0..<max(1, rules.threads) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                var buffer = [UInt8](repeating: 0, count: 128 * 1024)
                while !cancelled {
                    let task: (first: String, second: String?)? = lock.withLock {
                        // Others may still add second-level tasks; wait for them while any first-level one is open.
                        guard next < tasks.count else { return nil }
                        defer { next += 1 }
                        return tasks[next]
                    }
                    guard let task else {
                        let open = lock.withLock { pending.values.contains { $0.waiting > 0 } || next < tasks.count }
                        if open { usleep(2000); continue }
                        break
                    }
                    let firstPath = path + "/" + task.first
                    autoreleasepool {
                        if let second = task.second {
                            let child = folder(at: firstPath + "/" + second, name: second, buffer: &buffer)
                            lock.withLock {
                                guard let item = pending[task.first] else { return }
                                item.children.append(child)
                                item.node.size &+= child.size
                                item.node.files &+= child.files
                                item.node.modified = max(item.node.modified, child.modified)
                                item.waiting -= 1
                                if item.waiting == 0 { finish(item) }
                            }
                        } else if rules.skip.contains(firstPath) {
                            lock.withLock { done.append(FolderNode(name: task.first, locked: true)) }
                        } else {
                            let fd = open(firstPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            var tally = Tally()
                            var subs: [String] = []
                            var files: [FolderNode] = []
                            var locked = false
                            if fd < 0 {
                                locked = errno == EACCES || errno == EPERM
                            } else {
                                if !list(fd, buffer: &buffer, into: &tally, folders: &subs, bigFiles: &files) { locked = true }
                                close(fd)
                            }
                            let node = tally.node(task.first)
                            node.locked = locked
                            lock.withLock {
                                folders += 1
                                let item = Pending(node: node, waiting: subs.count, children: files)
                                if subs.isEmpty {
                                    finish(item)
                                } else {
                                    pending[task.first] = item
                                    tasks.append(contentsOf: subs.map { (task.first, $0) })
                                }
                            }
                        }
                    }
                    var partial: FolderNode?
                    if progress != nil {
                        lock.withLock {
                            guard Date().timeIntervalSince(lastPublish) > 0.5 else { return }
                            lastPublish = Date()
                            let open = pending.values.filter { $0.waiting > 0 }.map { item in
                                FolderNode(name: item.node.name, size: item.node.size, files: item.node.files, modified: item.node.modified,
                                           ownModified: item.node.ownModified, children: item.children.sorted { $0.size > $1.size })
                            }
                            partial = Self.assemble(root, children: done + open + bigFiles, rules: rules, prune: false)
                        }
                    }
                    if let partial { progress?(partial) }
                }
                group.leave()
            }
        }
        group.wait()
        return Self.assemble(root, children: done + bigFiles, rules: rules, prune: true)
    }

    private static func assemble(_ own: FolderNode, children: [FolderNode], rules: Rules, prune: Bool) -> FolderNode {
        let node = FolderNode(name: own.name, size: own.size, files: own.files, modified: own.modified, ownModified: own.ownModified)
        for child in children where !child.isFile {
            node.size &+= child.size
            node.files &+= child.files
            node.modified = max(node.modified, child.modified)
        }
        node.children = children.sorted { $0.size > $1.size }
        if prune { keep(node, rules: rules) }
        return node
    }

    /// One folder and everything below it, by path. For rescanning part of a tree.
    public func folder(at path: String, name: String? = nil, buffer: inout [UInt8]) -> FolderNode {
        let name = name ?? (path as NSString).lastPathComponent
        if device == 0 {
            var info = stat()
            if lstat(path, &info) == 0 { device = info.st_dev }
        }
        if rules.skip.contains(path) { return FolderNode(name: name, locked: true) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return FolderNode(name: name, locked: errno == EACCES || errno == EPERM) }
        defer { close(fd) }
        return folder(fd: fd, name: name, path: path, buffer: &buffer)
    }

    /// Lists `path` again and rescans only the subfolders `old` did not keep; kept
    /// subfolders keep their sizes. Used when FSEvents reports a change in this folder
    /// or somewhere below it that the tree does not hold on its own.
    public func refresh(_ old: FolderNode, at path: String) -> FolderNode {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var info = stat()
        guard lstat(path, &info) == 0 else { return FolderNode(name: old.name) }
        if device == 0 { device = info.st_dev }
        if rules.skip.contains(path) { return FolderNode(name: old.name, locked: true) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return FolderNode(name: old.name, locked: errno == EACCES || errno == EPERM) }
        defer { close(fd) }
        var tally = Tally()
        var subfolders: [String] = []
        var children: [FolderNode] = []
        guard list(fd, buffer: &buffer, into: &tally, folders: &subfolders, bigFiles: &children) else {
            return FolderNode(name: old.name, locked: true)
        }
        var otherSize: UInt64 = 0
        var otherCount: UInt32 = 0
        for sub in subfolders {
            if cancelled { break }
            var small = Tally()
            let child: FolderNode?
            if let kept = old.child(sub), !kept.isFile, !kept.locked {
                child = kept
            } else {
                child = walk(fd, sub, path: path + "/" + sub, buffer: &buffer, total: &small)
            }
            if let child {
                tally.size &+= child.size
                tally.files &+= child.files
                tally.modified = max(tally.modified, child.modified)
                children.append(child)
            } else {
                tally.size &+= small.size
                tally.files &+= small.files
                tally.modified = max(tally.modified, small.modified)
                tally.ownModified = max(tally.ownModified, small.modified)
                otherSize &+= small.size
                otherCount &+= 1
            }
        }
        let node = tally.node(old.name)
        node.children = children.sorted { $0.size > $1.size }
        node.otherSize = otherSize
        node.otherCount = otherCount
        Self.keep(node, rules: rules)
        return node
    }

    /// Convenience for a one-off scan of one folder.
    public func folder(at path: String) -> FolderNode {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        return folder(at: path, buffer: &buffer)
    }

    /// One folder and everything below it, opened relative to its parent. Nil for a
    /// folder too small to keep: its figures go into `total` and nothing is allocated.
    private func walk(_ parent: Int32, _ name: String, path: String, buffer: inout [UInt8], total: inout Tally) -> FolderNode? {
        if rules.skip.contains(path) { return FolderNode(name: name, locked: true) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == EACCES || errno == EPERM ? FolderNode(name: name, locked: true) : nil }
        defer { close(fd) }
        return walk(fd: fd, name: name, path: path, buffer: &buffer, total: &total, always: false)
    }

    private func folder(fd: Int32, name: String, path: String, buffer: inout [UInt8]) -> FolderNode {
        var total = Tally()
        return walk(fd: fd, name: name, path: path, buffer: &buffer, total: &total, always: true) ?? total.node(name)
    }

    private func walk(fd: Int32, name: String, path: String, buffer: inout [UInt8], total: inout Tally, always: Bool) -> FolderNode? {
        var tally = Tally()
        var subfolders: [String] = []
        var children: [FolderNode] = []
        lock.withLock { folders += 1 }
        guard list(fd, buffer: &buffer, into: &tally, folders: &subfolders, bigFiles: &children) else {
            return FolderNode(name: name, locked: true)
        }
        var otherSize: UInt64 = 0
        var otherCount: UInt32 = 0
        for sub in subfolders {
            if cancelled { break }
            var small = Tally()
            if let child = walk(fd, sub, path: path + "/" + sub, buffer: &buffer, total: &small) {
                tally.size &+= child.size
                tally.files &+= child.files
                tally.modified = max(tally.modified, child.modified)
                children.append(child)
            } else {
                tally.size &+= small.size
                tally.files &+= small.files
                tally.modified = max(tally.modified, small.modified)
                tally.ownModified = max(tally.ownModified, small.modified)
                otherSize &+= small.size
                otherCount &+= 1
            }
        }
        total = tally
        guard always || tally.size >= rules.smallestFolder else { return nil }
        let node = tally.node(name)
        node.children = children.sorted { $0.size > $1.size }
        node.otherSize = otherSize
        node.otherCount = otherCount
        Self.keep(node, rules: rules)
        return node
    }

    /// Keeps the largest children and folds the rest into `otherSize`.
    static func keep(_ node: FolderNode, rules: Rules) {
        var kept: [FolderNode] = []
        for child in node.children {
            let big = child.size >= (child.isFile ? rules.smallestFile : rules.smallestFolder)
            if big && (kept.count < rules.keepChildren || (!child.isFile && alwaysKept.contains(child.name))) || child.locked {
                kept.append(child)
            } else if !child.isFile {
                // A dropped file is still in the folder's own files; a dropped folder goes to "other".
                node.otherSize &+= child.size
                node.otherCount &+= 1
                node.ownModified = max(node.ownModified, child.modified)
            }
        }
        node.children = kept
    }

    // MARK: Listing one folder

    /// What one folder adds up to while it is being read, before it is known whether
    /// it is big enough to become a node.
    struct Tally {
        var size: UInt64 = 0
        var files: UInt64 = 0
        var modified: Double = 0
        var ownModified: Double = 0

        func node(_ name: String) -> FolderNode {
            FolderNode(name: name, size: size, files: files, modified: modified, ownModified: ownModified)
        }
    }

    private static let common: attrgroup_t = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)
    private static let fileAttributes: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    private static let extended: attrgroup_t = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

    /// Reads one folder's entries: adds its files to `node`, collects its subfolders'
    /// names and its files large enough to list. False when the folder cannot be read.
    private func list(_ fd: Int32, buffer: inout [UInt8], into node: inout Tally, folders: inout [String], bigFiles: inout [FolderNode]) -> Bool {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: Self.common, volattr: 0,
                               dirattr: 0, fileattr: Self.fileAttributes, forkattr: Self.extended)
        let options = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_ATTR_CMN_EXTENDED)
        let capacity = buffer.count
        while true {
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &request, $0.baseAddress!, capacity, options) }
            if count < 0 { return node.files > 0 || !folders.isEmpty }
            if count == 0 { return true }
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
                    var name = ""
                    if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                        let reference = p.loadUnaligned(as: attrreference_t.self)
                        name = String(cString: (p + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                        p += MemoryLayout<attrreference_t>.size
                    }
                    var dev: Int32 = device
                    if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                        dev = p.loadUnaligned(as: Int32.self)
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
                    node.ownModified = max(node.ownModified, modified)
                    node.modified = max(node.modified, modified)
                    if type == UInt32(VDIR.rawValue) {
                        // Another volume mounted here, or a folder whose contents live in the cloud.
                        if dev != device || flags & UInt32(SF_DATALESS) != 0 { continue }
                        folders.append(name)
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
                    var privateSize: UInt64?
                    var cloneID: UInt64 = 0
                    var extFlags: UInt64 = 0
                    if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                        privateSize = UInt64(max(0, p.loadUnaligned(as: Int64.self)))
                        p += 8
                    }
                    if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                        cloneID = p.loadUnaligned(as: UInt64.self)
                        p += 8
                    }
                    if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                        extFlags = p.loadUnaligned(as: UInt64.self)
                        p += 8
                    }
                    let size = counted(allocated: allocated, links: links, fileID: fileID, privateSize: privateSize,
                                       cloneID: cloneID, extFlags: extFlags)
                    node.size &+= size
                    node.files &+= 1
                    if size >= rules.smallestFile {
                        bigFiles.append(FolderNode(name: name, size: size, files: 1, modified: modified, ownModified: modified, isFile: true))
                    }
                }
            }
        }
    }

    /// The bytes a file adds: a second hard link adds nothing, and a clone adds only
    /// the blocks it does not share once its family has been counted.
    private func counted(allocated: UInt64, links: UInt32, fileID: UInt64, privateSize: UInt64?, cloneID: UInt64, extFlags: UInt64) -> UInt64 {
        if links > 1 {
            let first = lock.withLock { hardLinks.count < Self.seenLimit ? hardLinks.insert(fileID).inserted : true }
            if !first { return 0 }
        }
        if extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0, cloneID != 0 {
            let first = lock.withLock { clones.count < Self.seenLimit ? clones.insert(cloneID).inserted : true }
            if !first { return min(allocated, privateSize ?? allocated) }
        }
        return allocated
    }
}
