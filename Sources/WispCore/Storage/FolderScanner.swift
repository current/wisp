import Darwin
import Foundation
import Synchronization

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
///
/// The kernel's listing is the cost, so the walk keeps a few threads listing at once:
/// a thread reads subfolders itself, depth first, and hands one over only while
/// another thread waits for work, so no thread idles behind one deep folder and few
/// folders wait at a time. More than four threads mostly add kernel lock contention
/// on this Mac's SSD: eight took three times the CPU of four for no gain.
public final class FolderScanner: @unchecked Sendable {
    public struct Rules: Sendable {
        /// Children kept per folder, largest first.
        public var keepChildren = 40
        /// Smallest folder kept as its own node.
        public var smallestFolder: UInt64 = 1 << 20
        /// Smallest file kept as its own node.
        public var smallestFile: UInt64 = 64 << 20
        /// A folder with this many files is kept even past `keepChildren`: a folded folder
        /// is read again whenever its parent changes, and this many files take seconds.
        public var busyFolder: UInt64 = 20_000
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
    /// Clone ids already counted, for volumes that do not say how many files share a
    /// clone's blocks; spread over shards so threads rarely wait for each other.
    private final class Seen {
        let lock = NSLock()
        var ids = Set<UInt64>()
    }
    private let clones = (0..<16).map { _ in Seen() }
    /// A million ids, at most 16 MB.
    private static let seenLimit = 1_000_000 / 16
    private var device: dev_t = 0
    private let folderCount = Atomic<Int>(0)
    /// Folders visited, for progress and timing.
    public var folders: Int { folderCount.load(ordering: .relaxed) }
    private let uncheckedCount = Atomic<Int>(0)
    /// Cloned files counted in full because the set of clone ids already seen was full.
    var unchecked: Int { uncheckedCount.load(ordering: .relaxed) }
    /// Seconds between partial trees sent to `scan`'s progress.
    var progressInterval: Double = 2
    private let quietValue = Atomic<Bool>(false)
    /// Scan threads run at background priority while this is set, and no partial trees are made.
    public var quiet: Bool {
        get { quietValue.load(ordering: .relaxed) }
        set { quietValue.store(newValue, ordering: .relaxed) }
    }

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

    /// Scans `path` and everything under it on this volume, on `rules.threads` threads.
    /// The folders `order` puts first start first; `progress` gets the partial tree
    /// every so often.
    public func scan(_ path: String, order: [String: UInt64] = [:], progress: ((FolderNode) -> Void)? = nil) -> FolderNode {
        var info = stat()
        let name = (path as NSString).lastPathComponent
        guard lstat(path, &info) == 0 else { return FolderNode(name: name, locked: true) }
        device = info.st_dev
        if rules.skip.contains(path) { return FolderNode(name: name, locked: true) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return FolderNode(name: name, locked: true) }
        return run(fd, name: name, path: path, threads: rules.threads, order: order, progress: progress)
    }

    /// One folder and everything below it. One thread by default, for the many small
    /// folders other scanners measure side by side; more for one large folder.
    public func folder(at path: String, threads: Int = 1) -> FolderNode {
        let name = (path as NSString).lastPathComponent
        if device == 0 {
            var info = stat()
            if lstat(path, &info) == 0 { device = info.st_dev }
        }
        if rules.skip.contains(path) { return FolderNode(name: name, locked: true) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return FolderNode(name: name, locked: errno == EACCES || errno == EPERM) }
        return run(fd, name: name, path: path, threads: threads)
    }

    /// Lists `path` again and rescans only the subfolders `old` did not keep; kept
    /// subfolders keep their sizes. Used when FSEvents reports a change in this folder
    /// or somewhere below it that the tree does not hold on its own.
    public func refresh(_ old: FolderNode, at path: String) -> FolderNode {
        var info = stat()
        guard lstat(path, &info) == 0 else { return FolderNode(name: old.name) }
        if device == 0 { device = info.st_dev }
        if rules.skip.contains(path) { return FolderNode(name: old.name, locked: true) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return FolderNode(name: old.name, locked: errno == EACCES || errno == EPERM) }
        let kept = Dictionary(old.children.lazy.filter { !$0.isFile && !$0.locked }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return run(fd, name: old.name, path: path, threads: rules.threads, reuse: kept)
    }

    // MARK: Walking

    /// What a finished folder hands its parent: a node, or, for a folder too small to
    /// keep, only its figures, so nothing is allocated for it.
    private enum Outcome {
        case node(FolderNode)
        case small(Tally)
    }

    /// A folder being read. Its own listing and each subfolder count as one wait; the
    /// last to finish, on whichever thread, completes it and hands it to its parent.
    private final class Pending: @unchecked Sendable {
        struct State {
            var tally = Tally()
            var children: [FolderNode] = []
            var otherSize: UInt64 = 0
            var otherCount: UInt32 = 0
            var waiting = 1
            var locked = false
        }

        let name: String
        let parent: Pending?
        /// The folder the walk started from, kept whatever its size.
        let always: Bool
        let state = Mutex(State())

        init(name: String, parent: Pending?, always: Bool = false) {
            (self.name, self.parent, self.always) = (name, parent, always)
            parent?.state.withLock { $0.waiting += 1 }
        }

        func add(_ outcome: Outcome) {
            state.withLock { state in
                switch outcome {
                case .node(let child):
                    state.tally.size &+= child.size
                    state.tally.files &+= child.files
                    state.tally.modified = max(state.tally.modified, child.modified)
                    state.children.append(child)
                case .small(let small):
                    state.tally.size &+= small.size
                    state.tally.files &+= small.files
                    state.tally.modified = max(state.tally.modified, small.modified)
                    state.tally.ownModified = max(state.tally.ownModified, small.modified)
                    state.otherSize &+= small.size
                    state.otherCount &+= 1
                }
            }
        }

        /// The folder as it stands, for a partial tree while it is still being read.
        func snapshot() -> FolderNode {
            state.withLock { state in
                let node = state.tally.node(name)
                node.children = state.children.sorted(by: FolderScanner.largestFirst)
                node.otherSize = state.otherSize
                node.otherCount = state.otherCount
                return node
            }
        }
    }

    /// One walk's shared work: folders waiting for a thread, newest first, so each
    /// thread stays deep in one part of the tree and the queue stays short.
    private final class Walk: @unchecked Sendable {
        let condition = NSCondition()
        var tasks: [(path: String, item: Pending)] = []
        let queued = Atomic<Int>(0)
        /// Threads waiting for a folder.
        let idle = Atomic<Int>(0)
        let threads: Int
        var result: FolderNode?
        /// The folders right below the root, for partial trees.
        var top: [Pending] = []
        var lastPublish = Date()

        init(threads: Int) { self.threads = threads }

        /// Whether a subfolder should go to another thread instead of being read here:
        /// only while a thread waits for one, since a handover costs a wakeup and an open by path.
        var wantsWork: Bool { threads > 1 && queued.load(ordering: .relaxed) < idle.load(ordering: .relaxed) }

        func push(_ path: String, _ item: Pending) {
            condition.withLock {
                tasks.append((path, item))
                queued.add(1, ordering: .relaxed)
                condition.signal()
            }
        }
    }

    /// What one thread keeps between folders.
    private struct Worker {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var background = false
    }

    /// Reads the folder open on `fd` and everything below it, then closes `fd`. The
    /// root's subfolders are queued first and other threads start only if there are
    /// any, so a folder of files alone costs no thread.
    private func run(_ fd: Int32, name: String, path: String, threads: Int, order: [String: UInt64] = [:],
                     reuse: [String: FolderNode] = [:], progress: ((FolderNode) -> Void)? = nil) -> FolderNode {
        let walk = Walk(threads: max(1, threads))
        let root = Pending(name: name, parent: nil, always: true)
        var worker = Worker()
        read(fd, path: path, into: root, walk: walk, worker: &worker, spread: true, order: order, reuse: reuse)
        close(fd)
        let group = DispatchGroup()
        if walk.queued.load(ordering: .relaxed) > 0 {
            for index in 1..<walk.threads {
                group.enter()
                DispatchQueue.global(qos: .utility).async { [self] in
                    var worker = Worker()
                    work(walk, worker: &worker, progress: progress, root: root, index: index)
                    if worker.background { setpriority(PRIO_DARWIN_THREAD, 0, 0) }
                    group.leave()
                }
            }
        }
        work(walk, worker: &worker, progress: progress, root: root, index: 0)
        if worker.background { setpriority(PRIO_DARWIN_THREAD, 0, 0) }
        group.wait()
        // Stopped early, the root has not completed; what was read so far stands.
        return walk.condition.withLock { walk.result } ?? root.snapshot()
    }

    /// Takes folders from the walk until it is complete or stopped. In the background two
    /// threads go on: each one more adds more kernel lock contention than speed.
    private func work(_ walk: Walk, worker: inout Worker, progress: ((FolderNode) -> Void)?, root: Pending, index: Int) {
        while true {
            if index >= 2, quiet { return }
            let task: (path: String, item: Pending)? = walk.condition.withLock { () -> (path: String, item: Pending)? in
                if walk.tasks.isEmpty {
                    walk.idle.add(1, ordering: .relaxed)
                    while walk.tasks.isEmpty, walk.result == nil, !cancelled {
                        walk.condition.wait(until: Date().addingTimeInterval(0.25))
                    }
                    walk.idle.subtract(1, ordering: .relaxed)
                }
                guard walk.result == nil, !cancelled, let task = walk.tasks.popLast() else { return nil }
                walk.queued.subtract(1, ordering: .relaxed)
                return task
            }
            guard let task else { return }
            autoreleasepool {
                let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 {
                    let locked = errno == EACCES || errno == EPERM
                    task.item.state.withLock { $0.locked = locked }
                    finish(task.item, walk: walk, gone: !locked)
                } else {
                    read(fd, path: task.path, into: task.item, walk: walk, worker: &worker)
                    close(fd)
                }
            }
            if let progress, !worker.background, let partial = partial(walk, root: root) { progress(partial) }
        }
    }

    /// The tree so far, at most every `progressInterval` seconds.
    private func partial(_ walk: Walk, root: Pending) -> FolderNode? {
        let open: [Pending]? = walk.condition.withLock {
            guard walk.result == nil, Date().timeIntervalSince(walk.lastPublish) > progressInterval else { return nil }
            walk.lastPublish = Date()
            return walk.top
        }
        guard let open else { return nil }
        let node = root.snapshot()
        for item in open where item.state.withLock({ $0.waiting > 0 }) {
            let child = item.snapshot()
            node.size &+= child.size
            node.files &+= child.files
            node.modified = max(node.modified, child.modified)
            node.children.append(child)
        }
        node.children.sort(by: Self.largestFirst)
        return node
    }

    /// Reads one folder: its files go into `item`, and each subfolder is read here or,
    /// when a thread is free, queued for it. `spread` queues every subfolder, biggest
    /// in `order` first, for the root of a walk; `reuse` are subfolders already measured.
    private func read(_ fd: Int32, path: String, into item: Pending, walk: Walk, worker: inout Worker, spread: Bool = false,
                      order: [String: UInt64] = [:], reuse: [String: FolderNode] = [:]) {
        if quiet != worker.background {
            worker.background.toggle()
            setpriority(PRIO_DARWIN_THREAD, 0, worker.background ? PRIO_DARWIN_BG : 0)
        }
        folderCount.add(1, ordering: .relaxed)
        var tally = Tally()
        var subfolders: [String] = []
        var files: [FolderNode] = []
        let readable = list(fd, buffer: &worker.buffer, into: &tally, folders: &subfolders, bigFiles: &files)
        item.state.withLock { state in
            state.tally.size &+= tally.size
            state.tally.files &+= tally.files
            state.tally.modified = max(state.tally.modified, tally.modified)
            state.tally.ownModified = max(state.tally.ownModified, tally.ownModified)
            state.children += files
            if !readable { state.locked = true }
        }
        if readable {
            if spread, !order.isEmpty { subfolders.sort { (order[$0] ?? 0, $1) > (order[$1] ?? 0, $0) } }
            var queued: [(String, Pending)] = []
            for sub in subfolders {
                if cancelled { break }
                if let kept = reuse[sub] {
                    item.add(.node(kept))
                    continue
                }
                let subPath = path + "/" + sub
                if rules.skip.contains(subPath) {
                    item.add(.node(FolderNode(name: sub, locked: true)))
                    continue
                }
                if spread && walk.threads > 1 || walk.wantsWork {
                    let child = Pending(name: sub, parent: item)
                    if spread { queued.append((subPath, child)) } else { walk.push(subPath, child) }
                    continue
                }
                let subFD = openat(fd, sub, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if subFD < 0 {
                    if errno == EACCES || errno == EPERM { item.add(.node(FolderNode(name: sub, locked: true))) }
                    continue
                }
                read(subFD, path: subPath, into: Pending(name: sub, parent: item), walk: walk, worker: &worker)
                close(subFD)
            }
            if !queued.isEmpty {
                walk.condition.withLock {
                    // The stack is taken from the end, so the biggest goes last.
                    walk.tasks += queued.reversed()
                    walk.queued.add(queued.count, ordering: .relaxed)
                    walk.top += queued.map(\.1)
                    walk.condition.broadcast()
                }
            }
        }
        finish(item, walk: walk)
    }

    /// Ends one wait on `item`; when it was the last, completes it and its parents in turn.
    /// A folder that is `gone` (deleted while queued) adds nothing.
    private func finish(_ item: Pending, walk: Walk, gone: Bool = false) {
        var item = item
        var gone = gone
        while true {
            let outcome: Outcome? = item.state.withLock { state in
                state.waiting -= 1
                guard state.waiting == 0, !gone else { return nil }
                if state.locked { return .node(FolderNode(name: item.name, locked: true)) }
                guard item.always || state.tally.size >= rules.smallestFolder else { return .small(state.tally) }
                let node = state.tally.node(item.name)
                node.children = state.children.sorted(by: FolderScanner.largestFirst)
                node.otherSize = state.otherSize
                node.otherCount = state.otherCount
                Self.keep(node, rules: rules)
                return .node(node)
            }
            if gone {
                gone = false
                guard let parent = item.parent else { return }
                item = parent
                continue
            }
            guard let outcome else { return }
            guard let parent = item.parent else {
                if case .node(let node) = outcome {
                    walk.condition.withLock {
                        walk.result = node
                        walk.condition.broadcast()
                    }
                }
                return
            }
            parent.add(outcome)
            item = parent
        }
    }

    /// Largest first, and by name between equals, so threads finishing in another order
    /// keep the same children.
    static func largestFirst(_ a: FolderNode, _ b: FolderNode) -> Bool {
        a.size != b.size ? a.size > b.size : a.name < b.name
    }

    /// Keeps the largest children and folds the rest into `otherSize`.
    static func keep(_ node: FolderNode, rules: Rules) {
        var kept: [FolderNode] = []
        for child in node.children {
            let big = child.size >= (child.isFile ? rules.smallestFile : rules.smallestFolder)
            let always = !child.isFile && (alwaysKept.contains(child.name) || child.files >= rules.busyFolder)
            if big && (kept.count < rules.keepChildren || always) || child.locked {
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
        | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)

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
                    // Most entries are small files whose name is never needed; it becomes a String only when kept.
                    var name: UnsafePointer<CChar>?
                    if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                        let reference = p.loadUnaligned(as: attrreference_t.self)
                        name = (p + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
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
                        folders.append(name.map { String(cString: $0) } ?? "")
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
                    var sharers: UInt32?
                    if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0 {
                        sharers = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    let size = counted(allocated: allocated, links: links, privateSize: privateSize, cloneID: cloneID,
                                       sharers: sharers, extFlags: extFlags)
                    node.size &+= size
                    node.files &+= 1
                    if size >= rules.smallestFile {
                        bigFiles.append(FolderNode(name: name.map { String(cString: $0) } ?? "", size: size, files: 1, modified: modified, ownModified: modified, isFile: true))
                    }
                }
            }
        }
    }

    /// The bytes a file adds. Each hard link takes an equal share of the file, and each
    /// clone its own blocks and a share of those it shares, so a file counts once
    /// whichever folder is read first, and reading one folder again later (a refresh)
    /// cannot count shared blocks a second time. Remembering which ids were seen did
    /// both: a refresh of four worktrees came to 9.6 GB where a full read found 6.5 GB.
    private func counted(allocated: UInt64, links: UInt32, privateSize: UInt64?, cloneID: UInt64, sharers: UInt32?,
                         extFlags: UInt64) -> UInt64 {
        var size = allocated
        if extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 {
            let own = min(allocated, privateSize ?? allocated)
            if let sharers {
                size = own + (allocated - own) / UInt64(max(1, sharers))
            } else if cloneID != 0, sighting(cloneID, in: clones) == .again {
                size = own
            }
        }
        return links > 1 ? size / UInt64(links) : size
    }

    private enum Sighting { case first, again, unknown }

    private func sighting(_ id: UInt64, in shards: [Seen]) -> Sighting {
        let shard = shards[Int(truncatingIfNeeded: (id &* 0x9E37_79B9_7F4A_7C15) >> 60)]
        let sighting: Sighting = shard.lock.withLock {
            if shard.ids.count < Self.seenLimit { return shard.ids.insert(id).inserted ? .first : .again }
            return shard.ids.contains(id) ? .again : .unknown
        }
        if sighting == .unknown { uncheckedCount.add(1, ordering: .relaxed) }
        return sighting
    }
}
