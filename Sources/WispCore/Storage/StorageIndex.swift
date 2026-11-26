import CoreServices
import Foundation

/// What the Storage page shows, handed over on the main queue. Trees are never
/// changed once handed over; a refresh builds new nodes along the changed path.
public struct StorageState: @unchecked Sendable {
    public var roots: [String: FolderNode] = [:]
    public var summary: StorageSummary?
    public var health: DiskHealth?
    /// The root being scanned from scratch, if any.
    public var scanning: String?
    public var scannedAt: Date?
    /// Seconds the last full scan of each root took.
    public var scanSeconds: [String: Double] = [:]
    public var lastRefreshSeconds: Double?

    public init() {}
}

/// Keeps the storage scan. Opening loads the cache from disk and asks FSEvents for
/// every change since the event id saved with it, so only changed folders are read
/// again, even across launches. With no cache it scans, sending partial results.
/// FSEvents hands back a few thousand old events a second, so after a long or busy
/// gap a fresh scan is sooner: the replay gives way to one when it would take longer.
/// Closing stops the stream and saves. A full scan of a root that is under way goes on
/// at background priority and is saved, so it does not start over next time; nothing
/// else runs while closed.
public final class StorageIndex: @unchecked Sendable {
    public struct Cache {
        public static let currentVersion = 2
        public var version = Cache.currentVersion
        public var eventID: UInt64
        public var date: Date
        public var roots: [String: FolderNode]
        public var seconds: [String: Double]
        public var fullDiskAccess: Bool
        /// The FSEvents database the event id belongs to. A new one (after it was reset)
        /// means the saved id says nothing about what changed.
        public var eventsUUID: String? = nil
    }

    public static var cacheURL: URL { Wisp.supportDirectory.appendingPathComponent("storage-scan.bin") }

    public static func roots(home: String = NSHomeDirectory()) -> [String] {
        (["/Applications", home, "/Library", "/opt/homebrew", "/usr/local"] + [temporaryFolder].compactMap { $0 })
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// /private/var/folders/xx/yyyy: this user's caches (C) and temporary files (T).
    static var temporaryFolder: String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size)
        guard let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        let folder = (String(cString: real) as NSString).deletingLastPathComponent
        return folder.hasPrefix("/private/var/folders/") ? folder : nil
    }

    /// Called on the main queue whenever something new is known.
    public var onChange: ((StorageState) -> Void)?

    private let work = DispatchQueue(label: "app.wisp.storage", qos: .utility)
    private let events = DispatchQueue(label: "app.wisp.storage.events", qos: .utility)
    private let lock = NSLock()
    private var flag = ScanFlag()
    private var stream: FSEventStreamRef?
    private var dirty: Set<String> = []
    private var mustScan: Set<String> = []
    private var latestEvent: UInt64 = 0
    private var refreshScheduled = false
    private var historyDone = false
    /// The replay of old events under way: where it started and ends, and how long a
    /// fresh scan of every root took last time, which it must beat.
    private var replay: (from: UInt64, to: UInt64, started: Date, budget: Double)?
    private var lastSave = Date()
    private var isOpen = false
    private var generation = 0

    // Owned by `work`.
    private var state = StorageState()
    private var cacheEventID: UInt64 = 0
    private var changed = false
    private var snapshots: [LocalSnapshot] = []
    private var fullDiskAccess = false
    /// The access the trees were read with, saved with them.
    private var treeAccess = false
    private let home: String
    private let rootPaths: [String]
    /// The full scan under way, under `lock`, so closing can turn it down.
    private var fullScanner: FolderScanner?

    private let cacheURL: URL
    private let historyURL: URL
    /// FSEvents reports real paths (/private/var for /var), as bytes to compare cheaply.
    private let realRoots: [(real: [UInt8], root: String)]
    /// Wisp's own folder: its databases and this cache change all the time and say nothing about disk use.
    private let ignored: [UInt8]
    private let callbackQueue: DispatchQueue

    private let summaryMemo = StorageAnalysis.Memo()
    private let readingsLock = NSLock()
    private var volumeReading: (volume: StorageVolume, date: Date)?
    private var existing: [String: Bool] = [:]

    public init(home: String = NSHomeDirectory(), roots: [String]? = nil, cacheURL: URL = StorageIndex.cacheURL,
                historyURL: URL = SpaceHistory.url, callbackQueue: DispatchQueue = .main) {
        self.home = home
        rootPaths = roots ?? Self.roots(home: home)
        realRoots = rootPaths.compactMap { root in
            let real = Self.realPath(root)
            return real == root ? nil : (Array(real.utf8), root)
        }
        ignored = Array(Self.realPath(Wisp.supportDirectory.path).utf8)
        self.cacheURL = cacheURL
        self.historyURL = historyURL
        self.callbackQueue = callbackQueue
    }

    /// Minimum seconds between refreshes while changes keep coming in.
    public var refreshInterval: Double = 20
    /// Folders whose refresh was expensive wait this many seconds per second it took.
    public var backoff: Double = 600
    private var cooldown: [String: Date] = [:]
    private var waitingForCooldown = false

    private static func realPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    public func open() {
        lock.withLock {
            guard !isOpen else { return }
            isOpen = true
            generation += 1
            flag = ScanFlag()
            historyDone = false
            fullScanner?.quiet = false
        }
        let generation = lock.withLock { self.generation }
        work.async { [self] in
            guard current(generation) else { return }
            fullDiskAccess = StorageAccess.hasFullDiskAccess
            let loadStart = Date()
            let now = FSEventsGetCurrentEventId()
            let uuid = eventsUUID()
            var stale = false
            if state.roots.isEmpty, let cache = Self.loadCache(from: cacheURL), cache.version == Cache.currentVersion {
                log(String(format: "loaded the cache in %.3f s", Date().timeIntervalSince(loadStart)))
                state.roots = cache.roots
                state.scannedAt = cache.date
                state.scanSeconds = cache.seconds
                cacheEventID = cache.eventID
                treeAccess = cache.fullDiskAccess
                // A reset event database or an id from the future cannot say what changed.
                stale = cache.eventID > now || (cache.eventsUUID != nil && uuid != nil && cache.eventsUUID != uuid)
            }
            if state.roots.isEmpty { treeAccess = fullDiskAccess }
            log(String(format: "opened with %d cached roots", state.roots.count))
            malloc_zone_pressure_relief(nil, 0)
            state.health = DiskHealth.read()
            snapshots = LocalSnapshot.list()
            publish()
            let replaying = cacheEventID != 0 && !state.roots.isEmpty && !stale
            if replaying {
                let budget = rootPaths.reduce(0.0) { $0 + (state.scanSeconds[$1] ?? 0) }
                lock.withLock { replay = (cacheEventID, now, Date(), budget) }
            }
            startStream(since: replaying ? cacheEventID : now)
            if stale {
                log("the saved event id is from another event database; measuring again")
                scan(rootPaths, generation: generation)
                return
            }
            if treeAccess != fullDiskAccess {
                followAccess(generation: generation)
                guard current(generation) else { return }
            }
            let missing = rootPaths.filter { state.roots[$0] == nil }
            if !missing.isEmpty { scan(missing, generation: generation) }
        }
    }

    public func close() {
        let wasOpen: Bool = lock.withLock {
            defer { isOpen = false }
            return isOpen
        }
        guard wasOpen else { return }
        flag.set()
        lock.withLock { fullScanner?.quiet = true }
        stopStream()
        work.async { [self] in
            if changed {
                save()
                SpaceHistory.record(SpaceHistory.sizes(of: state.roots), to: historyURL)
                changed = false
            }
            // Closed costs nothing: the tree is on disk and loads again in a moment.
            guard !lock.withLock({ isOpen }) else { return }
            state = StorageState()
            summaryMemo.clear()
            // Reopened, the page measures again what changed while it was shut.
            cooldown.removeAll()
            readingsLock.withLock { existing.removeAll() }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Scans everything again from scratch, as when there is no cache.
    public func rescan() {
        let generation = lock.withLock { self.generation }
        work.async { [self] in
            guard current(generation) else { return }
            scan(rootPaths, generation: generation)
        }
    }

    /// A one-off scan of a folder the tree did not keep, for drilling below it.
    public func scanFolder(_ path: String, done: @escaping (FolderNode) -> Void) {
        let skip = StorageAccess.skipped(home: home)
        DispatchQueue.global(qos: .utility).async {
            var rules = FolderScanner.Rules()
            rules.skip = skip
            let node = FolderScanner(rules: rules).folder(at: path, threads: rules.threads)
            DispatchQueue.main.async { done(node) }
        }
    }

    /// WISP_STORAGE_TIMING=1 writes scan and refresh times to standard error, for measuring.
    private static let timing = ProcessInfo.processInfo.environment["WISP_STORAGE_TIMING"] != nil
    private func log(_ text: String) {
        if Self.timing { FileHandle.standardError.write(Data("storage: \(text)\n".utf8)) }
    }

    private func current(_ generation: Int) -> Bool {
        lock.withLock { isOpen && self.generation == generation }
    }

    // MARK: Scanning

    private func scan(_ paths: [String], generation: Int) {
        var rules = FolderScanner.Rules()
        rules.skip = StorageAccess.skipped(home: home)
        // Changes during the scan are replayed from here once it is done.
        let startEvent = FSEventsGetCurrentEventId()
        for path in paths {
            guard current(generation) else { return }
            // Not cancelled by closing: a root is only worth anything once it is read to the end.
            let scanner = FolderScanner(rules: rules)
            lock.withLock {
                scanner.quiet = !isOpen
                fullScanner = scanner
            }
            let started = Date()
            state.scanning = path
            readingsLock.withLock { existing.removeAll() }
            publish()
            let order = state.roots[path].map { Dictionary($0.children.map { ($0.name, $0.size) }, uniquingKeysWith: max) } ?? [:]
            let previous = state.roots[path]
            // The work queue waits for the scan, so partial trees go out from the scan's own
            // threads, on a copy of the state. They only fill in a root that has nothing yet;
            // a page opened again during the scan gets the state once.
            let base = state
            let partialLock = NSLock()
            var shownTo = generation
            let node = scanner.scan(path, order: order) { [weak self] partial in
                guard let self, let open = lock.withLock({ self.isOpen ? self.generation : nil }) else { return }
                partialLock.withLock {
                    guard previous == nil || open != shownTo else { return }
                    shownTo = open
                    autoreleasepool {
                        var copy = base
                        if previous == nil { copy.roots[path] = partial }
                        copy.summary = self.summarize(copy)
                        let callback = self.onChange
                        self.callbackQueue.async { callback?(copy) }
                    }
                }
            }
            lock.withLock { fullScanner = nil }
            // Changes from here on are replayed next launch even if the other roots are never reached.
            if cacheEventID == 0 { cacheEventID = startEvent }
            state.roots[path] = node
            state.scanSeconds[path] = Date().timeIntervalSince(started)
            log(String(format: "scanned %@ in %.2f s: %llu files, %d folders, %d nodes kept", path, Date().timeIntervalSince(started),
                       node.files, scanner.folders, node.nodeCount))
            state.scanning = nil
            changed = true
            publish()
        }
        state.scannedAt = Date()
        cacheEventID = startEvent
        if Set(paths) == Set(rootPaths) { treeAccess = fullDiskAccess }
        // The walk made and dropped a node per folder; give the freed pages back.
        malloc_zone_pressure_relief(nil, 0)
        save()
        SpaceHistory.record(SpaceHistory.sizes(of: state.roots), to: historyURL)
        changed = false
        publish()
        refreshNow()
    }

    /// Full Disk Access changed since the trees were read: what was locked may be readable
    /// now, or what was read is guarded. Only those folders are read again; if closing
    /// stops this halfway, the saved access stays the old one and the rest waits for next time.
    private func followAccess(generation: Int) {
        let started = Date()
        var rules = FolderScanner.Rules()
        rules.skip = StorageAccess.skipped(home: home)
        let scanner = FolderScanner(rules: rules, cancel: lock.withLock { flag })
        var count = 0
        for (root, tree) in state.roots {
            var targets: [String] = []
            tree.walk { node, relative in
                guard !node.isFile else { return false }
                if node.locked || rules.skip.contains(root + "/" + relative) {
                    targets.append(relative)
                    return false
                }
                return true
            }
            for relative in targets {
                let new = scanner.folder(at: root + "/" + relative, threads: rules.threads)
                guard current(generation), !scanner.cancelled else { return }
                state.roots[root] = state.roots[root]?.replacing(at: relative.split(separator: "/").map(String.init), with: new)
                changed = true
                count += 1
            }
        }
        treeAccess = fullDiskAccess
        log(String(format: "read %d folders again for the change in access in %.2f s", count, Date().timeIntervalSince(started)))
        publish()
    }

    private func publish() {
        guard lock.withLock({ isOpen }) else { return }
        state.summary = autoreleasepool { summarize(state) }
        let copy = state
        let callback = onChange
        callbackQueue.async { callback?(copy) }
    }

    private func summarize(_ state: StorageState) -> StorageSummary {
        let input = StorageAnalysis.Input(volume: volume(), roots: state.roots, home: home, snapshots: snapshots, swap: .read(),
                                          scannedAt: state.scannedAt, fullDiskAccess: fullDiskAccess, exists: { [self] in exists($0) },
                                          deviceName: Simulators.name(ofDeviceAt:))
        return StorageAnalysis.summarize(input, memo: summaryMemo)
    }

    /// The volume's figures take a dozen file system calls; a few seconds old is fine for the page.
    private func volume() -> StorageVolume {
        readingsLock.withLock {
            if let reading = volumeReading, Date().timeIntervalSince(reading.date) < 10 { return reading.volume }
            let volume = StorageVolume.read()
            volumeReading = (volume, Date())
            return volume
        }
    }

    /// Marker files (Cargo.toml and the like) seen since the last change was read.
    private func exists(_ path: String) -> Bool {
        if let known = readingsLock.withLock({ existing[path] }) { return known }
        let found = FileManager.default.fileExists(atPath: path)
        readingsLock.withLock { existing[path] = found }
        return found
    }

    // MARK: Cache

    static func loadCache(from url: URL = cacheURL) -> Cache? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return StorageCacheFile.decode(data)
    }

    /// The last saved scan, for the CLI and the MCP tool, which do not scan themselves.
    public static func cached() -> Cache? { loadCache() }

    private func save() {
        let complete = state.roots.filter { state.scanning != $0.key }
        guard !complete.isEmpty else { return }
        let cache = Cache(eventID: cacheEventID, date: state.scannedAt ?? Date(), roots: complete, seconds: state.scanSeconds,
                          fullDiskAccess: treeAccess, eventsUUID: eventsUUID())
        if let data = StorageCacheFile.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        lastSave = Date()
    }

    // MARK: FSEvents

    /// The FSEvents database of the volume the roots are on.
    private func eventsUUID() -> String? {
        var info = stat()
        guard let root = rootPaths.first(where: { lstat($0, &info) == 0 }), !root.isEmpty,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Whether the replay of old events, at the pace it is going, will take longer than
    /// measuring everything again. Called with `lock` held.
    private func replayTooSlow() -> Bool {
        guard let replay, !historyDone, replay.budget > 0, replay.to > replay.from else { return false }
        let elapsed = Date().timeIntervalSince(replay.started)
        // Events come in bursts, so the pace is only judged once it has run a while.
        guard elapsed > max(5, replay.budget / 10) else { return false }
        let done = Double(min(latestEvent, replay.to) &- min(latestEvent, replay.from)) / Double(replay.to - replay.from)
        return elapsed / max(done, 0.001) > replay.budget
    }

    /// Drops the replay and measures every root again, keeping the saved trees on show.
    private func abandonReplay(generation: Int) {
        guard current(generation), lock.withLock({ !historyDone }) else { return }
        stopStream()
        lock.withLock {
            replay = nil
            dirty.removeAll()
            mustScan.removeAll()
        }
        log("the replay of old events would take longer than measuring again")
        startStream(since: FSEventsGetCurrentEventId())
        scan(rootPaths, generation: generation)
    }

    private func startStream(since: UInt64) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let index = Unmanaged<StorageIndex>.fromOpaque(info).takeUnretainedValue()
            let list = UnsafeBufferPointer(start: paths.assumingMemoryBound(to: UnsafePointer<CChar>.self), count: count)
            index.received(list, flags: UnsafeBufferPointer(start: flags, count: count), ids: UnsafeBufferPointer(start: ids, count: count))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, rootPaths as CFArray, since, 5.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, events)
        FSEventStreamStart(stream)
        lock.withLock { self.stream = stream }
    }

    private func stopStream() {
        let stream: FSEventStreamRef? = lock.withLock {
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func received(_ paths: UnsafeBufferPointer<UnsafePointer<CChar>>, flags: UnsafeBufferPointer<FSEventStreamEventFlags>,
                          ids: UnsafeBufferPointer<FSEventStreamEventId>) {
        let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
        var changes: [(path: String, deep: Bool)] = []
        var historyEnded = false
        let dropped = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        for index in flags.indices where Int(flags[index]) & dropped != 0 {
            log("FSEvents dropped events (\(Int(flags[index]) & kFSEventStreamEventFlagKernelDropped != 0 ? "kernel" : "Wisp too slow")) at \(String(cString: paths[index]))")
        }
        for (index, raw) in paths.enumerated() where Int(flags[index]) & kFSEventStreamEventFlagHistoryDone == 0 {
            let bytes = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
            guard let path = eventPath(UnsafeBufferPointer(start: bytes, count: strlen(raw))) else { continue }
            changes.append((path, Int(flags[index]) & rescan != 0))
        }
        let giveUp: Int? = lock.withLock {
            for index in flags.indices {
                latestEvent = max(latestEvent, ids[index])
                if Int(flags[index]) & kFSEventStreamEventFlagHistoryDone != 0 {
                    historyDone = true
                    historyEnded = true
                    replay = nil
                }
            }
            for change in changes {
                if change.deep { mustScan.insert(change.path) } else { dirty.insert(change.path) }
            }
            guard replayTooSlow() else { return nil }
            replay = nil
            return generation
        }
        if let giveUp {
            work.async { [self] in abandonReplay(generation: giveUp) }
            return
        }
        if historyEnded { work.async { [self] in refreshNow() } } else { scheduleRefresh() }
    }

    private static let dataVolume = Array("/System/Volumes/Data".utf8)
    private static let slash = UInt8(ascii: "/")

    /// An event path in terms of the root paths the tree uses: FSEvents may report the data
    /// volume's own path for firmlinked folders, and real paths for roots behind a link.
    /// Nil for Wisp's own folder. Both sides come from the file system, so bytes compare.
    func eventPath(_ raw: UnsafeBufferPointer<UInt8>) -> String? {
        var path = raw[...]
        if Self.starts(path, with: Self.dataVolume[...]), path.count > Self.dataVolume.count {
            path = path.dropFirst(Self.dataVolume.count)
        }
        while path.count > 1, path.last == Self.slash { path = path.dropLast() }
        if !ignored.isEmpty, Self.starts(path, with: ignored[...]) { return nil }
        for (real, root) in realRoots where Self.starts(path, with: real[...]) {
            return root + String(decoding: path.dropFirst(real.count), as: UTF8.self)
        }
        return String(decoding: path, as: UTF8.self)
    }

    func eventPath(_ path: String) -> String? {
        var path = path
        return path.withUTF8 { eventPath($0) }
    }

    /// Whether `path` is `prefix` or inside it.
    private static func starts<A: Collection<UInt8>, B: BidirectionalCollection<UInt8>>(_ path: A, with prefix: B) -> Bool {
        guard path.starts(with: prefix) else { return false }
        return path.count == prefix.count || prefix.last == slash || path.dropFirst(prefix.count).first == slash
    }

    /// The deepest root at or above `path`.
    private func root(of path: String) -> String? {
        var best: String?
        for root in rootPaths where Self.starts(path.utf8, with: root.utf8) && root.utf8.count > (best?.utf8.count ?? -1) { best = root }
        return best
    }

    private func scheduleRefresh() {
        let go: Bool = lock.withLock {
            guard historyDone, !refreshScheduled, isOpen else { return false }
            refreshScheduled = true
            return true
        }
        guard go else { return }
        work.asyncAfter(deadline: .now() + refreshInterval) { [self] in
            lock.withLock { refreshScheduled = false }
            refreshNow()
        }
    }

    typealias Target = (root: String, parts: [String], deep: Bool)

    /// Folders to read again, without those inside one read again in full, and with
    /// the same folder once, in full if any event asked for that.
    static func merged(_ targets: [Target]) -> [Target] {
        var chosen: [Target] = []
        var chosenAt: [String: Int] = [:]
        for target in targets.sorted(by: { $0.parts.count < $1.parts.count }) {
            var key = target.root
            var covered = false
            for part in target.parts {
                if let index = chosenAt[key], chosen[index].deep {
                    covered = true
                    break
                }
                key += "/" + part
            }
            if covered { continue }
            if let index = chosenAt[key] {
                chosen[index].deep = chosen[index].deep || target.deep
            } else {
                chosenAt[key] = chosen.count
                chosen.append(target)
            }
        }
        return chosen
    }

    /// Reads again the folders FSEvents reported, at the deepest level the tree keeps.
    private func refreshNow() {
        guard state.scanning == nil else { return }
        let (paths, full, eventID): (Set<String>, Set<String>, UInt64) = lock.withLock {
            defer { dirty.removeAll(); mustScan.removeAll() }
            return (dirty, mustScan, latestEvent)
        }
        guard !paths.isEmpty || !full.isEmpty else { return }
        let started = Date()
        var rules = FolderScanner.Rules()
        rules.skip = StorageAccess.skipped(home: home)
        let scanner = FolderScanner(rules: rules, cancel: lock.withLock { flag })
        readingsLock.withLock { existing.removeAll() }

        // A must-scan event at or above a root means that root starts over.
        var rescanRoots: Set<String> = []
        for path in full {
            for root in rootPaths where Self.starts(root.utf8, with: path.utf8) { rescanRoots.insert(root) }
        }
        var targets: [Target] = []
        for (path, deep) in paths.map({ ($0, false) }) + full.map({ ($0, true) }) {
            guard let root = root(of: path), let tree = state.roots[root], !rescanRoots.contains(root) else { continue }
            let relative = path.utf8.count == root.utf8.count ? "" : String(decoding: path.utf8.dropFirst(root.utf8.count + 1), as: UTF8.self)
            let parts = tree.deepest(relative).path
            // The folder that changed is the one kept, or one the tree folded into it; a full
            // rescan is only needed when FSEvents says so for that very folder.
            let fullHere = deep && parts.count == relative.split(separator: "/").count
            targets.append((root, parts, fullHere))
        }
        // Cheap reads first, so most of the page is current while a big folder is read again.
        let chosen = Self.merged(targets).map { target -> (Target, UInt64) in
            let tree = state.roots[target.root]
            return (target, (target.parts.isEmpty ? tree : tree?.descendant(target.parts.joined(separator: "/")))?.files ?? 0)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        if !rescanRoots.isEmpty { log("FSEvents asks for a full read of " + rescanRoots.sorted().joined(separator: ", ")) }
        var deferred: [String] = []
        let now = Date()
        var lastPublish = Date()
        for target in chosen {
            guard !scanner.cancelled, let tree = state.roots[target.root] else { return }
            let path = ([target.root] + target.parts).joined(separator: "/")
            // A folder that is expensive to read and changes all the time (temporary files,
            // caches) is read again only after a pause that grows with what it costs.
            if let until = cooldown[path], until > now {
                deferred.append(path)
                lock.withLock { if target.deep { mustScan.insert(path) } else { dirty.insert(path) } }
                continue
            }
            let old = target.parts.isEmpty ? tree : tree.descendant(target.parts.joined(separator: "/")) ?? tree
            let targetStart = Date()
            let new = target.deep ? scanner.folder(at: path, threads: rules.threads) : scanner.refresh(old, at: path)
            let cost = Date().timeIntervalSince(targetStart)
            if cost > 0.05 { cooldown[path] = Date().addingTimeInterval(min(1800, cost * backoff)) }
            if cost > 0.1 { log(String(format: "  %@ %@ took %.2f s (%llu files)", target.deep ? "rescan" : "refresh", path, cost, new.files)) }
            if scanner.cancelled { return }
            state.roots[target.root] = target.parts.isEmpty ? new : tree.replacing(at: target.parts, with: new)
            if Date().timeIntervalSince(lastPublish) > 2 {
                publish()
                lastPublish = Date()
            }
        }
        // Changes still waiting must be replayed next launch, so the saved place only moves on when none
        // are. A root read again from scratch moves it on itself once it is done.
        if deferred.isEmpty, rescanRoots.isEmpty { cacheEventID = max(cacheEventID, eventID) }
        if let next = deferred.compactMap({ cooldown[$0] }).min(), !waitingForCooldown {
            waitingForCooldown = true
            work.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow)) { [self] in
                waitingForCooldown = false
                if lock.withLock({ isOpen }) { refreshNow() }
            }
        }
        changed = true
        // Saved now and then, so a quit without closing the page leaves little to replay.
        if Date().timeIntervalSince(lastSave) > 600 { save() }
        state.lastRefreshSeconds = Date().timeIntervalSince(started)
        log(String(format: "refreshed %d folders (%d waiting) from %d events in %.3f s", chosen.count - deferred.count, deferred.count,
                   paths.count + full.count, Date().timeIntervalSince(started)))
        if chosen.count > deferred.count || !rescanRoots.isEmpty {
            publish()
            malloc_zone_pressure_relief(nil, 0)
        }
        if !rescanRoots.isEmpty {
            let generation = lock.withLock { self.generation }
            // Quickest first, so most roots are current while the big one is read.
            scan(rescanRoots.sorted { (state.scanSeconds[$0] ?? 0, $0) < (state.scanSeconds[$1] ?? 0, $1) }, generation: generation)
        }
    }
}

/// Simulator devices, read from the files CoreSimulator keeps for each one.
public enum Simulators {
    /// "iPhone 17 Pro (iOS 26.1)" from a device folder's device.plist.
    public static func name(ofDeviceAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/device.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["name"] as? String else { return nil }
        if let runtime = plist["runtime"] as? String,
           let version = runtime.split(separator: ".").last?.replacingOccurrences(of: "-", with: " ").split(separator: " ", maxSplits: 1),
           version.count == 2 {
            return "\(name) (\(version[0]) \(version[1].replacingOccurrences(of: " ", with: ".")))"
        }
        return name
    }
}
