import CoreServices
import Darwin
import Foundation

/// What the Clean Up scanners measured, kept between scans and launches so a second scan
/// reads only what changed. Every record carries the FSEvents id from just before it was
/// measured; before records are used, FSEvents replays every change since the last replay,
/// and a change inside a record's folder marks that record (or the one child folder of it
/// the change is in) to be read again. When the history cannot be replayed (another disk,
/// events lost, a replay that takes too long) everything is read again.
public final class CleanScanCache: @unchecked Sendable {
    /// A measured folder. Sizes are allocated bytes with hard links and clones counted once.
    struct Folder: Codable {
        var inode: UInt64
        var bytes: Int64
        /// Newest modification of anything inside, seconds since 1970.
        var newest: Double
        var files: Int64
        /// Folders inside that could not be read.
        var locked: Int
        /// FSEvents id taken just before the folder was read.
        var event: UInt64
        /// The folder's own files, apart from its subfolders.
        var own: Part
        /// Each subfolder by name, so a change in one of them reads only that one again. Nil for folders with too many.
        var children: [String: Part]?
        /// Changes since `event`: in its own entries, and below these children.
        var ownChanged = false
        var changedChildren: Set<String> = []
        /// Everything in it must be read again.
        var stale = false

        var isClean: Bool { !stale && !ownChanged && changedChildren.isEmpty }
    }

    struct Part: Codable {
        var inode: UInt64 = 0
        var bytes: Int64 = 0
        var newest: Double = 0
        var files: Int64 = 0
        var locked: Int = 0
    }

    /// Results a scanner keeps for a folder it searched, valid while nothing in the folder changes.
    struct Memo: Codable {
        var path: String
        /// Nil: anything below the folder changing makes it stale. A number: only changes this
        /// many levels down or fewer (0 is the folder's own entries), for a memo of one listing.
        var levels: Int?
        var event: UInt64
        var data: Data
        var used: Date
        var stale = false
    }

    private struct Saved: Codable {
        static let currentVersion = 1
        var version = Saved.currentVersion
        var volume: String
        var event: UInt64
        var folders: [String: Folder]
        var memos: [String: Memo]
        var hashes: [String: FileHash]
    }

    /// A file's hashes for the duplicate search, valid while the file's id, size and date stay the same.
    struct FileHash: Codable {
        var fileID: UInt64
        var length: Int64
        var modified: Double
        var edge: String?
        var full: String?
    }

    /// Off under a test runner, so tests never write to the support folder or see each
    /// other's records; WISP_CLEAN_CACHE names another file, or "off".
    public static let shared: CleanScanCache? = {
        let setting = ProcessInfo.processInfo.environment["WISP_CLEAN_CACHE"]
        if setting == "off" { return nil }
        if let setting, !setting.isEmpty { return CleanScanCache(url: URL(fileURLWithPath: setting)) }
        if isTestRunner { return nil }
        return CleanScanCache(url: Wisp.supportDirectory.appendingPathComponent("clean-scan-cache.plist"))
    }()

    static var isTestRunner: Bool {
        Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") } || NSClassFromString("XCTestCase") != nil
    }

    /// A scan waits this long for the saved history to replay, then reads everything again.
    var replayLimit: Double = 10
    /// A replay this recent also covers the next caller; tabs scanning at once share it.
    var reuseWindow: Double = 2
    /// Folders with more subfolders than this keep only their total.
    static let childLimit = 600

    private let lock = NSLock()
    private let url: URL?
    private let roots: [String]
    /// FSEvents names real paths (/private/var for /var); these map them back.
    private let realRoots: [(real: String, given: String)]
    private var folders: [String: Folder] = [:]
    private var memos: [String: Memo] = [:]
    private var hashes: [String: FileHash] = [:]
    /// Lowercased path to the record's key, for matching events whatever the case.
    private var keys: [String: String] = [:]
    private var lastEvent: UInt64 = 0
    private var volume = ""
    /// Recent changes, so a folder measured while they happened is marked when it is stored.
    private var recent: [(path: String, id: UInt64, deep: Bool, date: Date)] = []
    private var changed = false
    private var lastSave = Date.distantPast
    private var saveQueued = false

    private var lostLogged = Set<String>()
    private let replayLock = NSLock()
    private var lastReplayStart = Date.distantPast

    /// `roots` are the folders whose changes are followed; records outside them are never kept.
    init(url: URL?, roots: [String] = [NSHomeDirectory(), "/Applications"]) {
        self.url = url
        self.roots = roots.filter { FileManager.default.fileExists(atPath: $0) }
        realRoots = self.roots.compactMap { root in
            let real = LargeFilesScanner.realPath(root) ?? root
            return real == root ? nil : (real, root)
        }
        load()
    }

    // MARK: Records

    func isFollowed(_ path: String) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The record for `path` as of the last `catchUp`.
    func folder(_ path: String) -> Folder? {
        lock.withLock { folders[path] }
    }

    /// The memo's data while nothing it covers has changed.
    func memo(_ key: String) -> Data? {
        lock.withLock {
            guard var memo = memos[key], !memo.stale else { return nil }
            memo.used = Date()
            memos[key] = memo
            return memo.data
        }
    }

    func hash(_ path: String) -> FileHash? {
        lock.withLock { hashes[path] }
    }

    /// The current FSEvents id, taken before reading a folder so changes during the read are caught next time.
    static func currentEvent() -> UInt64 { FSEventsGetCurrentEventId() }

    func store(_ path: String, _ folder: Folder) {
        guard isFollowed(path) else { return }
        lock.withLock {
            var folder = folder
            let lower = path.lowercased()
            // Changes that happened while it was being read.
            for change in recent[Self.firstAfter(folder.event, in: recent)...] {
                Self.mark(&folder, key: lower, change: change.path, deep: change.deep)
            }
            folders[path] = folder
            keys[lower] = path
            changed = true
        }
        queueSave()
    }

    func storeMemo(_ key: String, path: String, levels: Int? = nil, event: UInt64, data: Data) {
        guard isFollowed(path) else { return }
        lock.withLock {
            var memo = Memo(path: path, levels: levels, event: event, data: data, used: Date())
            let lower = path.lowercased()
            if recent[Self.firstAfter(event, in: recent)...].contains(where: { Self.touches($0.path, lower, levels: levels, deep: $0.deep) }) {
                memo.stale = true
            }
            memos[key] = memo
            memoIndex[lower, default: []].insert(key)
            changed = true
        }
        queueSave()
    }

    func storeHash(_ path: String, _ hash: FileHash) {
        lock.withLock {
            hashes[path] = hash
            changed = true
        }
        queueSave()
    }

    /// Where the changes after `event` start; one stream delivers ids in order.
    static func firstAfter(_ event: UInt64, in recent: [(path: String, id: UInt64, deep: Bool, date: Date)]) -> Int {
        var low = 0
        var high = recent.count
        while low < high {
            let middle = (low + high) / 2
            if recent[middle].id > event { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Memo keys by the lowercased folder they describe.
    private var memoIndex: [String: Set<String>] = [:]

    // MARK: Following changes

    /// Brings every record up to date with the changes so far. The first call opens an
    /// FSEvents stream from the id saved last time, which replays the history since then and
    /// then stays open while scans keep asking, delivering changes as they happen: a later
    /// call only flushes what is pending. Two minutes after the last call the stream closes
    /// and the place is saved, so Wisp follows nothing while Clean Up is not in use; the next
    /// scan replays what changed meanwhile. Replaying a long history on a busy Mac can
    /// take long; past `replayLimit` everything is read again until the replay ends.
    /// A call within `age` seconds of the last one is covered by it. A stopped scan stops waiting.
    func catchUp(within age: Double = 0, isCancelled: () -> Bool = { false }) {
        let asked = Date().addingTimeInterval(-age)
        replayLock.lock()
        defer { replayLock.unlock() }
        if lastReplayStart >= asked { return }
        lastReplayStart = Date()
        let started = Date()
        let now = FSEventsGetCurrentEventId()
        guard var stream = openStream(now: now) else { return }
        if !waitForHistory(isCancelled) {
            if isCancelled() { return }
            // Too much history to go through: forget it all and follow changes from now on.
            Self.log(String(format: "the replay was still going after %.1f s; reading everything again", replayLimit))
            closeStream()
            lock.withLock {
                clearAll()
                lastEvent = now
            }
            guard let fresh = openStream(now: now), waitForHistory(isCancelled) else { return }
            stream = fresh
        }
        FSEventStreamFlushSync(stream)
        lock.withLock {
            if lastEvent < now { lastEvent = now }
            changed = true
        }
        closeWhenIdle()
        Self.log(String(format: "caught up in %.2f s", Date().timeIntervalSince(started)))
    }

    /// The open stream, or a new one from the saved id. Nil when changes cannot be followed.
    private func openStream(now: UInt64) -> FSEventStreamRef? {
        if let stream = lock.withLock({ stream }) { return stream }
        let current = Self.volumeID(roots.first ?? "/")
        var since = lock.withLock { lastEvent }
        let known = lock.withLock { volume == current }
        if since == 0 || !known {
            Self.log(since == 0 ? "nothing saved yet" : "another volume or event database")
            lock.withLock {
                if !folders.isEmpty || !memos.isEmpty { clearAll() }
                volume = current
                lastEvent = now
            }
            since = now
        }
        guard !roots.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let cache = Unmanaged<CleanScanCache>.fromOpaque(info).takeUnretainedValue()
            let list = UnsafeBufferPointer(start: paths.assumingMemoryBound(to: UnsafePointer<CChar>.self), count: count)
            cache.received(list, UnsafeBufferPointer(start: flags, count: count), UnsafeBufferPointer(start: ids, count: count))
        }
        // Changes come in batches every half minute; a scan flushes what is pending when it starts.
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, since, 30,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        lock.withLock { self.stream = stream }
        return stream
    }

    private func waitForHistory(_ isCancelled: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(replayLimit)
        let history = lock.withLock { self.history }
        while Date() < deadline, !isCancelled() {
            if history.wait(until: min(deadline, Date().addingTimeInterval(0.1))) { return true }
        }
        return false
    }

    /// How long the stream stays open after the last scan asked for it.
    var idleClose: Double = 120

    /// Closes the stream once no scan has asked for `idleClose` seconds, flushing and
    /// saving first so the next replay starts where this one ended.
    private func closeWhenIdle() {
        let asked = lastReplayStart
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleClose) { [weak self] in
            guard let self else { return }
            self.replayLock.lock()
            defer { self.replayLock.unlock() }
            guard self.lastReplayStart == asked, let stream = self.lock.withLock({ self.stream }) else { return }
            FSEventStreamFlushSync(stream)
            self.closeStream()
            self.save()
        }
    }

    private func closeStream() {
        guard let stream = lock.withLock({ () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventQueue.sync {}
        lock.withLock { history = HistoryDone() }
    }

    deinit { closeStream() }

    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "app.wisp.clean.events", qos: .utility)
    private var history = HistoryDone()

    /// Set once the stream has replayed the saved history and is delivering changes as they happen.
    private final class HistoryDone: @unchecked Sendable {
        private let condition = NSCondition()
        private var done = false
        func set() { condition.withLock { done = true; condition.broadcast() } }
        func wait(until deadline: Date) -> Bool {
            condition.withLock {
                while !done { if !condition.wait(until: deadline) { return done } }
                return true
            }
        }
    }

    private func received(_ paths: UnsafeBufferPointer<UnsafePointer<CChar>>, _ flags: UnsafeBufferPointer<FSEventStreamEventFlags>,
                          _ ids: UnsafeBufferPointer<FSEventStreamEventId>) {
        let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        var ended = false
        lock.withLock {
            let now = Date()
            recent.removeAll { now.timeIntervalSince($0.date) > 900 }
            for index in 0..<paths.count {
                let flag = Int(flags[index])
                if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                    ended = true
                    continue
                }
                if flag & (kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
                    clearAll()
                    continue
                }
                var path = String(cString: paths[index])
                if path.count > 1, path.hasSuffix("/") { path.removeLast() }
                let lower = given(path).lowercased()
                if flag & lost != 0, !lostLogged.contains(path) {
                    lostLogged.insert(path)
                    Self.log("events were lost below \(path); what is there is read again")
                }
                apply(lower, id: ids[index], deep: flag & lost != 0)
                recent.append((lower, ids[index], flag & lost != 0, now))
                lastEvent = max(lastEvent, ids[index])
            }
            if recent.count > 100_000 { recent.removeFirst(recent.count - 100_000) }
            changed = true
        }
        if ended {
            Self.log("the replay of saved history ended")
            lock.withLock { history }.set()
        }
    }

    private func given(_ real: String) -> String {
        for root in realRoots where real == root.real || real.hasPrefix(root.real + "/") {
            return root.given + real.dropFirst(root.real.count)
        }
        return real
    }

    /// Marks the records a change in `path` (lowercased) affects.
    private func apply(_ path: String, id: UInt64, deep: Bool) {
        // Events lost for a whole followed folder: everything goes at once, without a pass over every record under the lock.
        if deep, roots.contains(where: { $0.lowercased() == path || $0.lowercased().hasPrefix(path + "/") }) {
            folders.removeAll()
            memos.removeAll()
            memoIndex.removeAll()
            keys.removeAll()
            return
        }
        var ancestor = path
        while true {
            if let key = keys[ancestor], var folder = folders[key], folder.event < id {
                Self.mark(&folder, key: ancestor, change: path, deep: deep)
                folders[key] = folder
            }
            for key in memoIndex[ancestor] ?? [] {
                guard let memo = memos[key], memo.event < id, Self.touches(path, ancestor, levels: memo.levels, deep: deep) else { continue }
                memos[key]?.stale = true
            }
            guard let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex else { break }
            ancestor = String(ancestor[..<slash])
        }
        // Lost events: every record below goes too.
        if deep {
            for (lower, key) in keys where lower.hasPrefix(path + "/") {
                folders[key]?.stale = true
            }
            for (lower, list) in memoIndex where lower.hasPrefix(path + "/") {
                for key in list { memos[key]?.stale = true }
            }
        }
    }

    /// A change in `change` touches the folder `folder` when it is in it, no deeper than
    /// `levels` when given, or, for lost events, above it or anywhere in it.
    static func touches(_ change: String, _ folder: String, levels: Int? = nil, deep: Bool) -> Bool {
        if change == folder || (deep && folder.hasPrefix(change + "/")) { return true }
        guard change.hasPrefix(folder + "/") else { return false }
        guard let levels, !deep else { return true }
        return change.dropFirst(folder.count + 1).split(separator: "/").count <= levels
    }

    static func mark(_ folder: inout Folder, key: String, change: String, deep: Bool) {
        if change == key {
            if deep { folder.stale = true } else { folder.ownChanged = true }
        } else if change.hasPrefix(key + "/") {
            let rest = change.dropFirst(key.count + 1)
            let child = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(rest)
            folder.changedChildren.insert(child)
        } else if deep, key.hasPrefix(change + "/") {
            folder.stale = true
        }
    }

    private func clearAll() {
        folders.removeAll()
        memos.removeAll()
        memoIndex.removeAll()
        keys.removeAll()
        recent.removeAll()
        changed = true
    }

    /// A short stable digest of settings a memo depends on, for its key. Hasher is seeded per launch, so FNV-1a.
    static func digest(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{0}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    static func volumeID(_ path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }

    /// WISP_CLEAN_TIMING=1 writes what the cache did to standard error, for measuring.
    private static let timing = ProcessInfo.processInfo.environment["WISP_CLEAN_TIMING"] != nil
    static func log(_ text: String) {
        if timing { FileHandle.standardError.write(Data("clean cache: \(text)\n".utf8)) }
    }

    // MARK: Saving

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode(Saved.self, from: data), saved.version == Saved.currentVersion else { return }
        folders = saved.folders
        memos = saved.memos
        hashes = saved.hashes
        lastEvent = saved.event
        volume = saved.volume
        for key in folders.keys { keys[key.lowercased()] = key }
        for (key, memo) in memos { memoIndex[memo.path.lowercased(), default: []].insert(key) }
    }

    /// Saves come from the scanners at the end of each batch; this keeps them from piling up
    /// when batches finish close together, and saves the rest a moment later.
    private func queueSave() {
        guard url != nil else { return }
        let deferred: Bool = lock.withLock {
            guard !saveQueued else { return false }
            saveQueued = true
            return true
        }
        guard deferred else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.saveQueued = false }
            self.save()
        }
    }

    func save() {
        guard let url else { return }
        let saved: Saved? = lock.withLock {
            guard changed else { return nil }
            changed = false
            lastSave = Date()
            // Hashes of files that are gone are dropped once there are many.
            if hashes.count > 50_000 { hashes = hashes.filter { CleanFiles.exists($0.key) } }
            // Memos nobody asked for in a month belong to folders or settings that are gone.
            let month = Date().addingTimeInterval(-30 * 86_400)
            return Saved(volume: volume, event: lastEvent, folders: folders, memos: memos.filter { !$0.value.stale && $0.value.used > month },
                         hashes: hashes)
        }
        guard let saved else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
