import Darwin
import Foundation
import Testing
@testable import WispCore

// Measurements for the Storage index and its readers. They only read, and only write
// inside a temporary folder. Skipped unless WISP_PROBE is set; each run measures one
// method, chosen with WISP_PROBE_METHOD, so peak memory belongs to that method alone.
//
//   WISP_PROBE=1 WISP_PROBE_METHOD=scanner WISP_PROBE_PATH=~/Library swift test --filter probeStorageWalk

private let environment = ProcessInfo.processInfo.environment
private let probing = environment["WISP_PROBE"] != nil

private struct Meter {
    let wall = Date()
    let cpu = Meter.cpuSeconds()
    let base = Meter.footprint().current

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    var seconds: Double { Date().timeIntervalSince(wall) }

    func line(_ label: String, entries: UInt64 = 0, folders: Int = 0, bytes: UInt64 = 0, extra: String = "") -> String {
        let peak = Meter.footprint().peak
        return String(format: "PROBE %@ wall=%.3f cpu=%.3f peakMB=%.1f entries=%llu folders=%d bytes=%llu %@", label, seconds,
                      Meter.cpuSeconds() - cpu, Double(peak > base ? peak - base : 0) / 1e6, entries, folders, bytes, extra)
    }
}

private func probePath() -> String {
    let raw = environment["WISP_PROBE_PATH"] ?? "~/Library"
    return (raw as NSString).expandingTildeInPath
}

private func int(_ key: String, _ fallback: Int) -> Int { environment[key].flatMap(Int.init) ?? fallback }

/// The smallest walk that still gives allocated bytes: getattrlistbulk on a pool of
/// threads, every folder its own task, opened by path. No hard-link or clone handling
/// unless the attribute set asks for it; it is a floor to hold the scanner against.
private final class FloorWalker: @unchecked Sendable {
    let common: attrgroup_t
    let file: attrgroup_t
    let fork: attrgroup_t
    let bufferSize: Int
    let threads: Int
    let skip: Set<String>
    let condition = NSCondition()
    var stack: [String] = []
    var busy = 0
    var entries: UInt64 = 0
    var folders = 0
    var bytes: UInt64 = 0
    var device: Int32 = 0

    init(attributes: String, bufferSize: Int, threads: Int, skip: Set<String>) {
        let base = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS)
        let all = base | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        switch attributes {
        case "min":
            (common, file, fork) = (base, attrgroup_t(ATTR_FILE_ALLOCSIZE), 0)
        case "nofork":
            (common, file, fork) = (all, attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE), 0)
        case "noprivate":
            (common, file, fork) = (all, attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE),
                                    attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS))
        default:
            (common, file, fork) = (all, attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE),
                                    attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS))
        }
        self.bufferSize = bufferSize
        self.threads = threads
        self.skip = skip
    }

    func run(_ root: String) {
        var info = stat()
        lstat(root, &info)
        device = info.st_dev
        stack = [root]
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var local: (entries: UInt64, folders: Int, bytes: UInt64) = (0, 0, 0)
                var found: [String] = []
                while true {
                    let path: String? = condition.withLock {
                        while stack.isEmpty {
                            if busy == 0 { return nil }
                            condition.wait()
                        }
                        busy += 1
                        return stack.removeLast()
                    }
                    guard let path else { break }
                    found.removeAll(keepingCapacity: true)
                    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if fd >= 0 {
                        local.folders += 1
                        list(fd, path: path, buffer: &buffer, local: &local, found: &found)
                        close(fd)
                    }
                    condition.withLock {
                        stack.append(contentsOf: found)
                        busy -= 1
                        condition.broadcast()
                    }
                }
                condition.withLock {
                    entries += local.entries
                    folders += local.folders
                    bytes += local.bytes
                }
                group.leave()
            }
        }
        group.wait()
    }

    private func list(_ fd: Int32, path: String, buffer: inout [UInt8], local: inout (entries: UInt64, folders: Int, bytes: UInt64),
                      found: inout [String]) {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: common, volattr: 0, dirattr: 0,
                               fileattr: file, forkattr: fork)
        let options = UInt64(FSOPT_NOFOLLOW) | (fork != 0 ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0)
        let capacity = buffer.count
        while true {
            let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &request, $0.baseAddress!, capacity, options) }
            if count <= 0 { return }
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
                    var dev = device
                    if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                        dev = p.loadUnaligned(as: Int32.self)
                        p += 4
                    }
                    var type: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                        type = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 { p += MemoryLayout<timespec>.size }
                    var flags: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                        flags = p.loadUnaligned(as: UInt32.self)
                        p += 4
                    }
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { p += 8 }
                    local.entries += 1
                    if type == UInt32(VDIR.rawValue) {
                        if dev != device || flags & UInt32(SF_DATALESS) != 0 { continue }
                        let child = path + "/" + (name.map { String(cString: $0) } ?? "")
                        if !skip.contains(child) { found.append(child) }
                        continue
                    }
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { p += 4 }
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        local.bytes &+= UInt64(max(0, p.loadUnaligned(as: Int64.self)))
                    }
                }
            }
        }
    }
}

/// fts with lstat of every entry, the way du does it.
private func ftsWalk(_ root: String, skip: Set<String>) -> (entries: UInt64, folders: Int, bytes: UInt64) {
    var result: (entries: UInt64, folders: Int, bytes: UInt64) = (0, 0, 0)
    var seen = Set<UInt64>()
    root.withCString { pointer in
        var paths: [UnsafeMutablePointer<CChar>?] = [strdup(pointer), nil]
        defer { free(paths[0]) }
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_D {
                let path = String(cString: entry.pointee.fts_path)
                if skip.contains(path) || (entry.pointee.fts_statp.pointee.st_flags & UInt32(SF_DATALESS)) != 0 {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                result.folders += 1
                result.entries += 1
                continue
            }
            if info == FTS_DP { continue }
            result.entries += 1
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            if stat.st_nlink > 1, !seen.insert(stat.st_ino).inserted { continue }
            result.bytes &+= UInt64(stat.st_blocks) * 512
        }
    }
    return result
}

/// searchfs over the whole volume for every file, with its allocated size, until the time limit.
private func searchfsWalk(_ volume: String, limit: Double) -> (entries: UInt64, bytes: UInt64, error: Int32, finished: Bool) {
    var returnAttributes = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_PARENTID),
                                    volattr: 0, dirattr: 0, fileattr: attrgroup_t(ATTR_FILE_ALLOCSIZE), forkattr: 0)
    struct Bound { var length: UInt32; var value: Int64 }
    var lower = Bound(length: UInt32(MemoryLayout<Bound>.size), value: 0)
    var upper = Bound(length: UInt32(MemoryLayout<Bound>.size), value: Int64.max)
    let bufferSize = 1 << 20
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    defer { buffer.deallocate() }
    var state = searchstate()
    var entries: UInt64 = 0
    var bytes: UInt64 = 0
    var options = UInt32(SRCHFS_START | SRCHFS_MATCHFILES)
    let started = Date()
    var finished = false
    var lastError: Int32 = 0
    withUnsafeMutablePointer(to: &returnAttributes) { returnPointer in
        withUnsafeMutablePointer(to: &lower) { lowerPointer in
            withUnsafeMutablePointer(to: &upper) { upperPointer in
                var block = fssearchblock()
                block.returnattrs = returnPointer
                block.returnbuffer = buffer
                block.returnbuffersize = bufferSize
                block.maxmatches = 10_000
                block.timelimit = timeval(tv_sec: 1, tv_usec: 0)
                block.searchparams1 = UnsafeMutableRawPointer(lowerPointer)
                block.sizeofsearchparams1 = MemoryLayout<Bound>.size
                block.searchparams2 = UnsafeMutableRawPointer(upperPointer)
                block.sizeofsearchparams2 = MemoryLayout<Bound>.size
                block.searchattrs = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0, dirattr: 0,
                                             fileattr: attrgroup_t(ATTR_FILE_DATAALLOCSIZE), forkattr: 0)
                while Date().timeIntervalSince(started) < limit {
                    var matches: UInt = 0
                    let result = searchfs(volume, &block, &matches, 0, options, &state)
                    let error = result == 0 ? 0 : errno
                    options &= ~UInt32(SRCHFS_START)
                    var entry = buffer
                    for _ in 0..<matches {
                        let length = Int(entry.loadUnaligned(as: UInt32.self))
                        bytes &+= UInt64(max(0, (entry + 4 + 8).loadUnaligned(as: Int64.self)))
                        entries += 1
                        entry += length
                    }
                    if error == EAGAIN { continue }
                    lastError = error
                    finished = error == 0
                    break
                }
            }
        }
    }
    return (entries, bytes, lastError, finished)
}

@Test(.enabled(if: probing))
func probeStorageWalk() {
    let path = probePath()
    let method = environment["WISP_PROBE_METHOD"] ?? "scanner"
    let threads = int("WISP_PROBE_THREADS", 4)
    let buffer = int("WISP_PROBE_BUFFER_KB", 128) * 1024
    let skip = StorageAccess.skipped()
    let meter = Meter()
    switch method {
    case "scanner":
        var rules = FolderScanner.Rules()
        rules.skip = skip
        rules.threads = threads
        let scanner = FolderScanner(rules: rules)
        let node = scanner.scan(path)
        let top = node.children.prefix(6).map { "\($0.name)=\($0.size)" }.joined(separator: ",")
        print(meter.line("scanner t=\(threads)", entries: node.files, folders: scanner.folders, bytes: node.size,
                         extra: "nodes=\(node.nodeCount) unchecked=\(scanner.unchecked) fda=\(StorageAccess.hasFullDiskAccess) top=\(top)"))
    case "refresh":
        // A refresh of a folder where nothing changed: what is read again is what the tree folded.
        var rules = FolderScanner.Rules()
        rules.skip = skip
        rules.threads = threads
        rules.busyFolder = UInt64(int("WISP_PROBE_BUSY", 20_000))
        rules.keepChildren = int("WISP_PROBE_KEEP", 40)
        let node = FolderScanner(rules: rules).scan(path)
        let refreshMeter = Meter()
        let scanner = FolderScanner(rules: rules)
        let again = scanner.refresh(node, at: path)
        print(refreshMeter.line("refresh busy=\(rules.busyFolder)", entries: again.files, folders: scanner.folders, bytes: again.size,
                                extra: "nodes=\(node.nodeCount) scanFiles=\(node.files) scanBytes=\(node.size)"))
    case "bulk":
        let attributes = environment["WISP_PROBE_ATTRS"] ?? "full"
        let walker = FloorWalker(attributes: attributes, bufferSize: buffer, threads: threads, skip: skip)
        walker.run(path)
        print(meter.line("bulk attrs=\(attributes) t=\(threads) buf=\(buffer / 1024)K", entries: walker.entries, folders: walker.folders,
                         bytes: walker.bytes))
    case "fts":
        let result = ftsWalk(path, skip: skip)
        print(meter.line("fts", entries: result.entries, folders: result.folders, bytes: result.bytes))
    case "searchfs":
        let result = searchfsWalk("/System/Volumes/Data", limit: Double(int("WISP_PROBE_LIMIT", 30)))
        print(meter.line("searchfs", entries: result.entries, bytes: result.bytes,
                         extra: "errno=\(result.error) finished=\(result.finished) rate=\(Int(Double(result.entries) / max(0.001, meter.seconds)))/s"))
    default:
        Issue.record("unknown method \(method)")
    }
}

/// Opens the Storage index on a copy of the saved scan, the way the page opens after
/// a quit, and times the first result and the replay of FSEvents since the saved id.
/// The copy lives in a temporary folder; the real cache is only read.
@Test(.enabled(if: probing && environment["WISP_PROBE_METHOD"] == "reopen"))
func probeStorageReopen() async throws {
    let source = environment["WISP_PROBE_CACHE"].map { URL(fileURLWithPath: $0) } ?? StorageIndex.cacheURL
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-reopen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheURL = folder.appendingPathComponent("storage-scan.bin")
    try FileManager.default.copyItem(at: source, to: cacheURL)
    // WISP_PROBE_AGE moves the saved place to that many seconds ago, as if Wisp had quit then.
    if let age = environment["WISP_PROBE_AGE"].flatMap(Double.init), var cache = StorageIndex.loadCache(from: cacheURL) {
        let now = FSEventsGetCurrentEventId()
        let rate = Double(now - cache.eventID) / max(1, -cache.date.timeIntervalSinceNow)
        cache.eventID = now - UInt64(rate * age)
        try #require(StorageCacheFile.encode(cache)).write(to: cacheURL)
    }
    let saved = try #require(StorageIndex.loadCache(from: cacheURL))
    print("PROBE cache eventID=\(saved.eventID) now=\(FSEventsGetCurrentEventId()) age=\(Int(-saved.date.timeIntervalSinceNow)) s fda=\(saved.fullDiskAccess) here=\(StorageAccess.hasFullDiskAccess) seconds=\(saved.seconds.mapValues { Int($0) })")

    let lock = NSLock()
    var states: [(Double, StorageState)] = []
    let meter = Meter()
    let index = StorageIndex(cacheURL: cacheURL, historyURL: folder.appendingPathComponent("sizes.json"),
                             callbackQueue: DispatchQueue(label: "probe.reopen"))
    index.onChange = { state in lock.withLock { states.append((meter.seconds, state)) } }
    index.open()
    let limit = Double(int("WISP_PROBE_LIMIT", 180))
    var first: Double?
    while meter.seconds < limit {
        try await Task.sleep(nanoseconds: 50_000_000)
        let (count, latest) = lock.withLock { (states.count, states.last) }
        if first == nil, let latest, !latest.1.roots.isEmpty { first = latest.0 }
        if let latest, latest.1.lastRefreshSeconds != nil, latest.1.scanning == nil, count > 1 { break }
    }
    let last = try #require(lock.withLock { states.last })
    let total = last.1.roots.values.reduce(UInt64(0)) { $0 + $1.size }
    print(meter.line("reopen", bytes: total, extra: String(format: "first=%.3f replayed=%.3f refresh=%.3f publishes=%d scanning=%@", first ?? -1,
                                                           last.0, last.1.lastRefreshSeconds ?? -1, states.count, last.1.scanning ?? "none")))
    for (root, node) in last.1.roots.sorted(by: { $0.key < $1.key }) {
        print("PROBE root \(root) size=\(node.size) files=\(node.files) saved=\(saved.roots[root]?.size ?? 0)")
    }
    let before = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date) ?? nil
    index.close()
    // WISP_PROBE_CACHE_OUT keeps the brought-up-to-date cache, to reopen from after a real gap.
    if let out = environment["WISP_PROBE_CACHE_OUT"] {
        for _ in 0..<200 {
            let now = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date) ?? nil
            if now != before { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try? FileManager.default.removeItem(atPath: out)
        try FileManager.default.copyItem(at: cacheURL, to: URL(fileURLWithPath: out))
        print("PROBE kept the cache at \(out)")
    }
}

@Test(.enabled(if: probing && environment["WISP_PROBE_METHOD"] == "readers"))
func probeStorageReaders() {
    var meter = Meter()
    var volume = StorageVolume.read()
    print(meter.line("volume.read", extra: "capacity=\(volume.capacity) available=\(volume.available) important=\(volume.availableForImportant)"))
    meter = Meter()
    for _ in 0..<5 { volume = StorageVolume.read() }
    print(meter.line("volume.read x5 warm"))
    meter = Meter()
    let free = StorageVolume.freeBytes()
    print(meter.line("freeBytes", extra: "free=\(free ?? 0)"))
    meter = Meter()
    _ = DiskHealth.read()
    print(meter.line("DiskHealth.read"))
    meter = Meter()
    let snapshots = LocalSnapshot.list()
    print(meter.line("LocalSnapshot.list", extra: "count=\(snapshots.count)"))
    for app in (environment["WISP_PROBE_APPS"] ?? "/Applications/Safari.app").split(separator: ",") {
        meter = Meter()
        let storage = AppStorage.measure(bundlePath: String(app))
        let parts = storage.parts.map { "\($0.name)=\($0.size)" }.joined(separator: ",")
        print(meter.line("AppStorage \((app as NSString).lastPathComponent)", bytes: storage.total, extra: "caches=\(storage.cacheSize) \(parts)"))
    }
}

/// Replays FSEvents history since an event id over the index's roots and times it,
/// without reading any folder: what a reopen costs before the first folder is refreshed.
@Test(.enabled(if: probing && environment["WISP_PROBE_METHOD"] == "history"))
func probeFSEventsHistory() async throws {
    // Event ids by time come back 0 here, so the age is turned into an id with the rate since the saved scan.
    let byAge = environment["WISP_PROBE_AGE"].flatMap(Double.init).flatMap { age -> UInt64? in
        guard let cache = StorageIndex.loadCache() else { return nil }
        let now = FSEventsGetCurrentEventId()
        let rate = Double(now - cache.eventID) / max(1, -cache.date.timeIntervalSinceNow)
        return now - UInt64(rate * age)
    }
    let since = environment["WISP_PROBE_SINCE"].flatMap(UInt64.init) ?? byAge
        ?? StorageIndex.loadCache(from: environment["WISP_PROBE_CACHE"].map { URL(fileURLWithPath: $0) } ?? StorageIndex.cacheURL)?.eventID ?? 0
    let latency = Double(environment["WISP_PROBE_LATENCY"] ?? "5") ?? 5
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var events = 0
        var deep = 0
        var paths = Set<String>()
        var prefixes: [String: Int] = [:]
        var deepPaths: [String: Int] = [:]
        var done: Double?
        var callbacks = 0
    }
    let counter = Counter()
    let meter = Meter()
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(counter).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        let counter = Unmanaged<Counter>.fromOpaque(info!).takeUnretainedValue()
        let list = UnsafeBufferPointer(start: paths.assumingMemoryBound(to: UnsafePointer<CChar>.self), count: count)
        counter.lock.withLock {
            counter.callbacks += 1
            for index in 0..<count {
                if Int(flags[index]) & kFSEventStreamEventFlagHistoryDone != 0 {
                    counter.done = counter.done ?? Date().timeIntervalSince1970
                    continue
                }
                counter.events += 1
                if Int(flags[index]) & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                    counter.deep += 1
                    let why = [(kFSEventStreamEventFlagUserDropped, "user"), (kFSEventStreamEventFlagKernelDropped, "kernel")]
                        .filter { Int(flags[index]) & $0.0 != 0 }.map(\.1).joined(separator: "+")
                    counter.deepPaths[String(cString: list[index]) + " " + why, default: 0] += 1
                }
                let path = String(cString: list[index])
                counter.paths.insert(path)
                counter.prefixes[path.split(separator: "/").prefix(int("WISP_PROBE_DEPTH", 5)).joined(separator: "/"), default: 0] += 1
            }
        }
    }
    let roots = environment["WISP_PROBE_ROOTS"].map { $0.split(separator: ",").map { ($0 as NSString).expandingTildeInPath } } ?? StorageIndex.roots()
    let flags = environment["WISP_PROBE_NODEFER"] != nil ? kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer : kFSEventStreamCreateFlagWatchRoot
    let stream = try #require(FSEventStreamCreate(nil, callback, &context, roots as CFArray, since, latency,
                                                  FSEventStreamCreateFlags(flags)))
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "probe.history"))
    let started = Date().timeIntervalSince1970
    FSEventStreamStart(stream)
    let limit = Double(int("WISP_PROBE_LIMIT", 300))
    while meter.seconds < limit, counter.lock.withLock({ counter.done == nil }) { try await Task.sleep(nanoseconds: 50_000_000) }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    let (events, deep, paths, done, callbacks) = counter.lock.withLock { (counter.events, counter.deep, counter.paths.count, counter.done, counter.callbacks) }
    let shown = counter.lock.withLock { counter.paths.sorted().prefix(int("WISP_PROBE_SHOW", 0)) }
    print(meter.line("history", entries: UInt64(events), extra: String(format: "since=%llu now=%llu historyDone=%.3f latency=%.1f roots=%d callbacks=%d distinctPaths=%d mustScan=%d",
                                                                         since, FSEventsGetCurrentEventId(), done.map { $0 - started } ?? -1, latency, roots.count,
                                                                         callbacks, paths, deep)))
    for path in shown { print("PROBE path \(path)") }
    let top = counter.lock.withLock { counter.prefixes.sorted { $0.value > $1.value }.prefix(int("WISP_PROBE_TOP", 0)) }
    for (prefix, count) in top { print("PROBE prefix \(count) \(prefix)") }
    let deepTop = counter.lock.withLock { counter.deepPaths.sorted { $0.value > $1.value }.prefix(int("WISP_PROBE_TOP", 0)) }
    for (path, count) in deepTop { print("PROBE mustScan \(count) \(path)") }
}
