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
/// Closing cancels any scan, stops the stream and saves. Nothing runs while closed.
public final class StorageIndex: @unchecked Sendable {
    public struct Cache {
        public static let currentVersion = 2
        public var version = Cache.currentVersion
        public var eventID: UInt64
        public var date: Date
        public var roots: [String: FolderNode]
        public var seconds: [String: Double]
        public var fullDiskAccess: Bool
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
    private var isOpen = false
    private var generation = 0

    // Owned by `work`.
    private var state = StorageState()
    private var cacheEventID: UInt64 = 0
    private var changed = false
    private var snapshots: [LocalSnapshot] = []
    private var fullDiskAccess = false
    private let home: String
    private let rootPaths: [String]

    private let cacheURL: URL
    private let historyURL: URL
    private let realRoots: [(real: String, root: String)]
    private let callbackQueue: DispatchQueue

    public init(home: String = NSHomeDirectory(), roots: [String]? = nil, cacheURL: URL = StorageIndex.cacheURL,
                historyURL: URL = SpaceHistory.url, callbackQueue: DispatchQueue = .main) {
        self.home = home
        rootPaths = roots ?? Self.roots(home: home)
        // FSEvents reports real paths (/private/var for /var); match events against those.
        realRoots = rootPaths.map { root in
            guard let real = realpath(root, nil) else { return (root, root) }
            defer { free(real) }
            return (String(cString: real), root)
        }
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

    public func open() {
        lock.withLock {
            guard !isOpen else { return }
            isOpen = true
            generation += 1
            flag = ScanFlag()
            historyDone = false
        }
        let generation = lock.withLock { self.generation }
        work.async { [self] in
            guard current(generation) else { return }
            fullDiskAccess = StorageAccess.hasFullDiskAccess
            let loadStart = Date()
            if state.roots.isEmpty, let cache = Self.loadCache(from: cacheURL), cache.version == Cache.currentVersion {
                log(String(format: "loaded the cache in %.3f s", Date().timeIntervalSince(loadStart)))
                state.roots = cache.roots
                state.scannedAt = cache.date
                state.scanSeconds = cache.seconds
                cacheEventID = cache.eventID
                // Access changed since the scan: what was locked is readable now, or the other way round.
                if cache.fullDiskAccess != fullDiskAccess { state.roots[home] = nil }
            }
            log(String(format: "opened with %d cached roots", state.roots.count))
            malloc_zone_pressure_relief(nil, 0)
            state.health = DiskHealth.read()
            snapshots = LocalSnapshot.list()
            publish()
            let since = cacheEventID != 0 && !state.roots.isEmpty ? cacheEventID : FSEventsGetCurrentEventId()
            startStream(since: since)
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
            cooldown.removeAll()
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
            let node = FolderScanner(rules: rules).folder(at: path)
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
            let scanner = FolderScanner(rules: rules, cancel: lock.withLock { flag })
            let started = Date()
            state.scanning = path
            publish()
            let order = state.roots[path].map { Dictionary($0.children.map { ($0.name, $0.size) }, uniquingKeysWith: max) } ?? [:]
            let previous = state.roots[path]
            // The work queue waits for the scan, so partial trees go out from the scan's own
            // threads, on a copy of the state. They only fill in a root that has nothing yet.
            let base = state
            let partialLock = NSLock()
            let node = scanner.scan(path, order: order) { [weak self] partial in
                guard let self, previous == nil else { return }
                partialLock.withLock {
                    autoreleasepool {
                        var copy = base
                        copy.roots[path] = partial
                        copy.summary = self.summarize(copy)
                        let callback = self.onChange
                        self.callbackQueue.async { callback?(copy) }
                    }
                }
            }
            guard !scanner.cancelled else {
                if previous == nil { state.roots[path] = nil }
                state.scanning = nil
                return
            }
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
        // The walk made and dropped a node per folder; give the freed pages back.
        malloc_zone_pressure_relief(nil, 0)
        save()
        SpaceHistory.record(SpaceHistory.sizes(of: state.roots), to: historyURL)
        changed = false
        publish()
        refreshNow()
    }

    private func publish() {
        state.summary = autoreleasepool { summarize(state) }
        let copy = state
        let callback = onChange
        callbackQueue.async { callback?(copy) }
    }

    private func summarize(_ state: StorageState) -> StorageSummary {
        let input = StorageAnalysis.Input(volume: .read(), roots: state.roots, home: home, snapshots: snapshots, swap: .read(),
                                          scannedAt: state.scannedAt, fullDiskAccess: fullDiskAccess,
                                          deviceName: Simulators.name(ofDeviceAt:))
        return StorageAnalysis.summarize(input)
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
                          fullDiskAccess: fullDiskAccess)
        if let data = StorageCacheFile.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }

    // MARK: FSEvents

    private func startStream(since: UInt64) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let index = Unmanaged<StorageIndex>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            index.received(list, flags: Array(UnsafeBufferPointer(start: flags, count: count)), ids: Array(UnsafeBufferPointer(start: ids, count: count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
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

    private func received(_ paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        var historyEnded = false
        lock.withLock {
            for (index, raw) in paths.enumerated() {
                let flag = Int(flags[index])
                latestEvent = max(latestEvent, ids[index])
                if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                    historyDone = true
                    historyEnded = true
                    continue
                }
                let path = canonical(Self.normalize(raw))
                if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    mustScan.insert(path)
                } else {
                    dirty.insert(path)
                }
            }
        }
        if historyEnded { work.async { [self] in refreshNow() } } else { scheduleRefresh() }
    }

    /// An event path in terms of the root paths the tree uses.
    private func canonical(_ path: String) -> String {
        for (real, root) in realRoots where real != root {
            if path == real { return root }
            if path.hasPrefix(real + "/") { return root + path.dropFirst(real.count) }
        }
        return path
    }

    /// FSEvents may report the data volume's own path for firmlinked folders.
    static func normalize(_ path: String) -> String {
        var path = path
        if path.hasPrefix("/System/Volumes/Data/") { path.removeFirst("/System/Volumes/Data".count) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
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

        // A must-scan event at or above a root means that root starts over.
        var rescanRoots: [String] = []
        for path in full {
            for root in rootPaths where root == path || root.hasPrefix(path == "/" ? "/" : path + "/") { rescanRoots.append(root) }
        }
        var targets: [(root: String, parts: [String], deep: Bool)] = []
        for (path, deep) in paths.map({ ($0, false) }) + full.map({ ($0, true) }) {
            guard let root = rootPaths.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
                  let tree = state.roots[root], !rescanRoots.contains(root) else { continue }
            let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
            let parts = tree.deepest(relative).path
            // The folder that changed is the one kept, or one the tree folded into it; a full
            // rescan is only needed when FSEvents says so for that very folder.
            let fullHere = deep && parts.count == relative.split(separator: "/").count
            targets.append((root, parts, fullHere))
        }
        // Drop targets inside another target of the same root.
        targets.sort { $0.parts.count < $1.parts.count }
        var chosen: [(root: String, parts: [String], deep: Bool)] = []
        for target in targets where !chosen.contains(where: { $0.root == target.root && target.parts.starts(with: $0.parts) && ($0.deep || $0.parts == target.parts) }) {
            if let same = chosen.firstIndex(where: { $0.root == target.root && $0.parts == target.parts }) {
                chosen[same].deep = chosen[same].deep || target.deep
            } else {
                chosen.append(target)
            }
        }
        var deferred: [String] = []
        let now = Date()
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
            let new = target.deep ? scanner.folder(at: path) : scanner.refresh(old, at: path)
            let cost = Date().timeIntervalSince(targetStart)
            if cost > 0.05 { cooldown[path] = Date().addingTimeInterval(min(1800, cost * backoff)) }
            if Date().timeIntervalSince(targetStart) > 0.1 {
                log(String(format: "  %@ %@ took %.2f s (%llu files)", target.deep ? "rescan" : "refresh", path, Date().timeIntervalSince(targetStart), new.files))
            }
            if scanner.cancelled { return }
            state.roots[target.root] = target.parts.isEmpty ? new : tree.replacing(at: target.parts, with: new)
        }
        for root in Set(rescanRoots) { state.roots[root] = nil }
        // Changes still waiting must be replayed next launch, so the saved place only moves on when none are.
        if deferred.isEmpty { cacheEventID = max(cacheEventID, eventID) }
        if let next = deferred.compactMap({ cooldown[$0] }).min(), !waitingForCooldown {
            waitingForCooldown = true
            work.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow)) { [self] in
                waitingForCooldown = false
                if lock.withLock({ isOpen }) { refreshNow() }
            }
        }
        changed = true
        state.lastRefreshSeconds = Date().timeIntervalSince(started)
        log(String(format: "refreshed %d folders (%d waiting) from %d events in %.3f s", chosen.count - deferred.count, deferred.count,
                   paths.count + full.count, Date().timeIntervalSince(started)))
        if chosen.count > deferred.count || !rescanRoots.isEmpty {
            publish()
            malloc_zone_pressure_relief(nil, 0)
        }
        if !rescanRoots.isEmpty {
            let generation = lock.withLock { self.generation }
            scan(Array(Set(rescanRoots)).sorted(), generation: generation)
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
