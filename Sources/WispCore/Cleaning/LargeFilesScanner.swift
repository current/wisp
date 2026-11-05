import CoreServices
import Darwin
import Foundation

/// The Large Files tab: big files in the owner's folders, virtual machines, duplicates and
/// local AI models. Everything here is the owner's own, so every row is check-first and
/// arrives unticked, except duplicate copies other than the one Wisp suggests keeping.
public struct LargeFilesScanner: CleanScanner {
    public struct Limits: Sendable {
        public var largeFile: Int64 = 10_000_000
        /// Smallest file compared for duplicates.
        public var duplicate: Int64 = 1_000_000
        /// Smallest row from a known model store.
        public var knownModel: Int64 = 10_000_000
        /// Smallest weight file listed outside the known stores.
        public var unknownModel: Int64 = 100_000_000
        /// Most bytes read for duplicate hashing in one scan.
        public var hashedBytes: Int64 = 20_000_000_000
        public init() {}
    }

    public var tab: CleanTab { .largeFiles }
    /// Off skips the hashing, which is most of the scan's disk reads.
    public var findDuplicates: Bool
    public var limits: Limits
    /// For HF_HOME, HF_HUB_CACHE, OLLAMA_MODELS and the like.
    public var environment: [String: String]
    public var index: LargeFileIndex

    public init(findDuplicates: Bool = true, limits: Limits = Limits(),
                environment: [String: String] = ProcessInfo.processInfo.environment, index: LargeFileIndex = .shared) {
        self.findDuplicates = findDuplicates
        self.limits = limits
        self.environment = environment
        self.index = index
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        report(context).items
    }

    static let largePrefix = "large:"
    static let duplicatePrefix = "duplicate:"

    /// The file a large-file or duplicate row stands for.
    public static func path(fromID id: String) -> String? {
        for prefix in [largePrefix, duplicatePrefix] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return nil
    }

    /// The whole scan, with the fields the page filters on. Also publishes them to `index`.
    public func report(_ context: CleanScanContext) -> LargeFilesReport {
        let started = Date()
        index.reset()
        let state = ScanState(context: context, index: index)
        let home = context.home.path
        // Without Full Disk Access, opening Desktop, Documents or Downloads makes macOS ask the user.
        let locked = StorageAccess.skipped(home: home)
        let roots = Self.roots(home: home).filter { root in
            !locked.contains { root.display == $0 || root.display.hasPrefix($0 + "/") }
        }
        state.roots = roots

        // Each root lists its own entries, then hands each subfolder to the pool as its own task.
        let pool = TaskPool()
        for root in roots {
            pool.add { RootWalk(root: root, state: state, limits: limits, home: home, pool: pool).start() }
        }
        AIModelFinder(home: home, environment: environment, limits: limits, context: context).find(pool: pool, emit: state.emit)
        pool.run(threads: 4, qos: .utility)

        var duplicates = DuplicateSummary()
        if !findDuplicates {
            duplicates.skipped = true
        } else if !context.isCancelled() {
            // Background QoS: hashing is the slow, disk-heavy part and nobody waits on it.
            let finder = DuplicateFinder(limit: limits.hashedBytes, isCancelled: context.isCancelled)
            let candidates = state.candidates
            let group = DispatchGroup()
            DispatchQueue.global(qos: .background).async(group: group) { duplicates = finder.groups(candidates) }
            group.wait()
            state.emit(Self.rows(for: duplicates, candidates: candidates, state: state, home: home))
        }
        index.setDuplicates(duplicates)
        var report = state.report
        report.duplicates = duplicates
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    // MARK: Roots

    struct Root {
        enum Kind { case user, virtualMachines }
        /// The path walked, symlinks resolved.
        var real: String
        /// The path rows report, as the owner sees it.
        var display: String
        var kind: Kind
        var isICloud: Bool
        var placeRank: Int
    }

    static func iCloudDrive(home: String) -> String { home + "/Library/Mobile Documents/com~apple~CloudDocs" }

    static func roots(home: String) -> [Root] {
        let user: [(String, Int)] = [("Documents", 0), ("Pictures", 0), ("Movies", 1), ("Music", 1), ("Desktop", 2), ("Downloads", 2)]
        var candidates = user.map { (home + "/" + $0.0, Root.Kind.user, $0.1) }
        candidates += [(home + "/Parallels", .virtualMachines, 1), (home + "/Virtual Machines.localized", .virtualMachines, 1)]
        candidates.append((iCloudDrive(home: home), .user, 1))
        let cloud = realPath(iCloudDrive(home: home))
        var roots: [Root] = []
        for (path, kind, rank) in candidates {
            guard let real = followable(path, home: home) else { continue }
            if roots.contains(where: { real == $0.real || real.hasPrefix($0.real + "/") || $0.real.hasPrefix(real + "/") }) { continue }
            let insideCloud = cloud.map { real == $0 || real.hasPrefix($0 + "/") } ?? false
            let isICloud = insideCloud
                || (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            roots.append(Root(real: real, display: path, kind: kind, isICloud: isICloud, placeRank: rank))
        }
        return roots
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The real folder behind `path` when it may be walked: a plain folder, or a symlink to a
    /// folder inside the home folder or on a local drive under /Volumes.
    static func followable(_ path: String, home: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard let real = realPath(path) else { return nil }
        var target = stat()
        guard stat(real, &target) == 0, target.st_mode & S_IFMT == S_IFDIR else { return nil }
        if info.st_mode & S_IFMT != S_IFLNK { return real }
        let realHome = realPath(home) ?? home
        if real.hasPrefix(realHome + "/") { return real }
        if real.hasPrefix("/Volumes/"),
           (try? URL(fileURLWithPath: real).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true {
            return real
        }
        return nil
    }

    // MARK: Rows

    /// "~/Downloads/Installers" or "iCloud Drive/Trips".
    static func place(_ folder: String, home: String) -> String {
        let cloud = iCloudDrive(home: home)
        if folder == cloud { return "iCloud Drive" }
        if folder.hasPrefix(cloud + "/") { return "iCloud Drive" + folder.dropFirst(cloud.count) }
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// From Spotlight when it knows, else the file's access time.
    static func lastOpened(_ path: String, accessed: Double) -> Date? {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return date
        }
        return accessed > 0 ? Date(timeIntervalSince1970: accessed) : nil
    }

    static func rows(for duplicates: DuplicateSummary, candidates: [DuplicateCandidate], state: ScanState, home: String) -> [Row] {
        let files = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let lastUsed = state.lastUsedByPath
        var rows: [Row] = []
        for group in duplicates.groups {
            let keeperPlace = place((group.keeper as NSString).deletingLastPathComponent, home: home)
            let others = group.paths.count - 1
            for (offset, path) in group.paths.enumerated() {
                guard let file = files[path] else { continue }
                let here = place((path as NSString).deletingLastPathComponent, home: home)
                let detail = offset > 0 ? "Identical copy in \(here). The copy in \(keeperPlace) stays."
                    : "The copy to keep, in \(here). \(others == 1 ? "One identical copy is" : "\(others) identical copies are") elsewhere."
                let opened = lastUsed[path] ?? lastOpened(path, accessed: file.accessed)
                let modified = Date(timeIntervalSince1970: file.modified)
                let item = CleanItem(id: duplicatePrefix + path, tab: .largeFiles, group: duplicatesGroup,
                                     name: (path as NSString).lastPathComponent, detail: detail, paths: [path], bytes: file.allocated,
                                     modified: opened ?? modified, safety: .checkFirst, checkedByDefault: offset > 0)
                let category = LargeFileKinds.files[(path as NSString).pathExtension.lowercased()]?.0 ?? .other
                let info = LargeFileInfo(category: category, lastUsed: opened, modified: modified, isICloud: file.isICloud,
                                         duplicateGroup: group.id, isSuggestedKeeper: offset == 0)
                rows.append(Row(item: item, info: info))
            }
        }
        return rows
    }
}

struct Row {
    var item: CleanItem
    var info: LargeFileInfo
}

/// What the parallel walks share. Every access goes through `lock`.
final class ScanState: @unchecked Sendable {
    struct FileKey: Hashable { var device: Int32; var id: UInt64 }

    let context: CleanScanContext
    let index: LargeFileIndex
    var roots: [LargeFilesScanner.Root] = []
    private let lock = NSLock()
    private var _report = LargeFilesReport()
    private var _candidates: [DuplicateCandidate] = []
    private var _lastUsed: [String: Date] = [:]
    private var seen = Set<FileKey>()

    init(context: CleanScanContext, index: LargeFileIndex) {
        self.context = context
        self.index = index
    }

    var report: LargeFilesReport { lock.withLock { _report } }
    var candidates: [DuplicateCandidate] { lock.withLock { _candidates } }
    /// Spotlight dates already looked up for large-file rows, so duplicate rows reuse them.
    var lastUsedByPath: [String: Date] { lock.withLock { _lastUsed } }

    /// False when the same file was already met through another path (a hard link, or a folder linked twice).
    func firstSighting(device: Int32, id: UInt64) -> Bool {
        lock.withLock { seen.insert(FileKey(device: device, id: id)).inserted }
    }

    func addCandidates(_ files: [DuplicateCandidate]) {
        lock.withLock { _candidates += files }
    }

    func emit(_ rows: [Row]) {
        guard !rows.isEmpty else { return }
        let items = rows.map(\.item)
        var info: [String: LargeFileInfo] = [:]
        for row in rows { info[row.item.id] = row.info }
        lock.withLock {
            _report.items += items
            _report.info.merge(info) { $1 }
            for row in rows where row.item.group != duplicatesGroup {
                if let date = row.info.lastUsed { _lastUsed[row.item.paths[0]] = date }
            }
        }
        index.add(info)
        context.found(items)
    }
}

/// One root folder: its own entries first, then each subfolder as a task of its own.
private struct RootWalk {
    let root: LargeFilesScanner.Root
    let state: ScanState
    let limits: LargeFilesScanner.Limits
    let home: String
    let pool: TaskPool

    /// Folders this shallow are listed on their own and their subfolders become tasks, so one
    /// deep project folder does not leave the other threads idle.
    static let splitDepth = 2

    func start() {
        walk(real: root.real, display: root.display, depth: 0, inRepo: false)
    }

    /// Walks a folder whose entries sit at `depth` below the root.
    private func walk(real: String, display: String, depth: Int, inRepo: Bool) {
        if state.context.isCancelled() { return }
        let walker = BulkWalker(isCancelled: state.context.isCancelled)
        let collector = Collector(walk: self, walker: walker, inRepo: inRepo)
        if depth >= Self.splitDepth {
            walker.walk(real, display: display) { parent, entry, level in collector.visit(parent, entry, depth + level) }
            collector.flush()
            return
        }
        var info = stat()
        guard stat(real, &info) == 0 else { return }
        var subfolders: [String] = []
        walker.walk(real, display: display) { parent, entry, _ in
            if collector.visit(parent, entry, depth) == .descend, entry.kind == .folder, entry.device == info.st_dev {
                subfolders.append(entry.name)
            }
            return .skip
        }
        collector.flush()
        for name in subfolders {
            let child = display + "/" + name
            pool.add { walk(real: real + "/" + name, display: child, depth: depth + 1, inRepo: collector.insideRepo(child)) }
        }
        for link in collector.links {
            pool.add {
                var info = stat()
                guard stat(link.real, &info) == 0, state.firstSighting(device: info.st_dev, id: info.st_ino) else { return }
                walk(real: link.real, display: link.display, depth: 1, inRepo: false)
            }
        }
    }

    /// What one task finds, flushed to the shared state in batches.
    final class Collector {
        /// A row waiting for its Spotlight date.
        struct Pending {
            var path: String
            var bytes: UInt64
            var modified: Double
            var accessed: Double
            var category: LargeFileCategory
            var what: String?
            var suffix: String?
        }

        let walk: RootWalk
        let walker: BulkWalker
        var pending: [Pending] = []
        var candidates: [DuplicateCandidate] = []
        var links: [(real: String, display: String)] = []
        /// Under a git working tree. Copies there are usually build output or vendored files the
        /// project expects, so they are not offered as duplicates.
        let inRepo: Bool
        private var repos: [String] = []
        private var root: LargeFilesScanner.Root { walk.root }
        private var limits: LargeFilesScanner.Limits { walk.limits }
        private var state: ScanState { walk.state }

        init(walk: RootWalk, walker: BulkWalker, inRepo: Bool) {
            self.walk = walk
            self.walker = walker
            self.inRepo = inRepo
        }

        func insideRepo(_ folder: String) -> Bool {
            inRepo || repos.contains { folder == $0 || folder.hasPrefix($0 + "/") }
        }

        func visit(_ parent: String, _ entry: BulkEntry, _ depth: Int) -> BulkWalker.Visit {
            let path = parent + "/" + entry.name
            if entry.isHidden || entry.isDataless || state.context.isExcluded(path) { return .skip }
            let home = walk.home
            switch entry.kind {
            case .folder:
                let ext = entry.pathExtension
                if LargeFileKinds.dependencyFolders.contains(entry.name) || LargeFileKinds.managedLibraries.contains(ext) { return .skip }
                if path.hasPrefix(home + "/"), LargeFileKinds.managedFolders.contains(String(path.dropFirst(home.count + 1))) { return .skip }
                if root.kind == .virtualMachines {
                    guard let what = LargeFileKinds.vmBundles[ext] else { return .descend }
                    bundle(path, entry, .virtualMachines, what)
                    return .skip
                }
                if ext == "download", parent == home + "/Downloads" {
                    bundle(path, entry, .unfinishedDownloads, "Unfinished Safari download")
                    return .skip
                }
                if let (category, what) = LargeFileKinds.packageRows[ext] {
                    bundle(path, entry, category, what)
                    return .skip
                }
                if !ext.isEmpty, (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                    bundle(path, entry, LargeFileKinds.files[ext]?.0 ?? .other, nil)
                    return .skip
                }
                if !inRepo, access(path + "/.git", F_OK) == 0 { repos.append(path) }
                return .descend
            case .file:
                let allocated = Int64(entry.allocated)
                if allocated < limits.largeFile && Int64(entry.length) < limits.duplicate { return .skip }
                let ext = entry.pathExtension
                guard root.kind == .user, !LargeFileKinds.managedFiles.contains(ext),
                      state.firstSighting(device: entry.device, id: entry.fileID) else { return .skip }
                if allocated >= limits.largeFile {
                    let kind = LargeFileKinds.files[ext]
                    add(Pending(path: path, bytes: entry.allocated, modified: entry.modified, accessed: entry.accessed,
                                category: kind?.0 ?? .other, what: kind?.1))
                }
                if Int64(entry.length) >= limits.duplicate, !insideRepo(parent) {
                    candidates.append(DuplicateCandidate(path: path, length: Int64(entry.length), allocated: allocated,
                                                         device: entry.device, fileID: entry.fileID, cloneID: entry.cloneID,
                                                         created: entry.created, modified: entry.modified, accessed: entry.accessed,
                                                         placeRank: root.placeRank, isICloud: root.isICloud))
                }
                return .skip
            case .symlink:
                // Only a link right inside a root is followed, and only to somewhere safe to walk.
                if depth == 0, root.kind == .user, let real = LargeFilesScanner.followable(path, home: home),
                   !state.roots.contains(where: { real == $0.real || real.hasPrefix($0.real + "/") }) {
                    links.append((real, path))
                }
                return .skip
            case .other:
                return .skip
            }
        }

        private func bundle(_ path: String, _ entry: BulkEntry, _ category: LargeFileCategory, _ what: String?) {
            guard state.firstSighting(device: entry.device, id: entry.fileID) else { return }
            let size = walker.folderSize(path)
            guard Int64(size.bytes) >= limits.largeFile else { return }
            let suffix = category == .virtualMachines ? "Everything inside the virtual machine goes with it." : nil
            add(Pending(path: path, bytes: size.bytes, modified: max(size.newest, entry.modified), accessed: entry.accessed,
                        category: category, what: what, suffix: suffix))
        }

        private func add(_ file: Pending) {
            pending.append(file)
            if pending.count >= 64 { flush() }
        }

        func flush() {
            let home = walk.home
            let rows = pending.map { file -> Row in
                let folder = (file.path as NSString).deletingLastPathComponent
                let place = LargeFilesScanner.place(folder, home: home)
                var detail = file.what.map { "\($0) in \(place)." } ?? "In \(place)."
                if let suffix = file.suffix { detail += " " + suffix }
                if root.isICloud { detail += " Removing it also removes it from your other devices." }
                let lastUsed = LargeFilesScanner.lastOpened(file.path, accessed: file.accessed)
                let modified = Date(timeIntervalSince1970: file.modified)
                let item = CleanItem(id: LargeFilesScanner.largePrefix + file.path, tab: .largeFiles, group: file.category.rawValue,
                                     name: (file.path as NSString).lastPathComponent, detail: detail, paths: [file.path],
                                     bytes: Int64(file.bytes), modified: lastUsed ?? modified, safety: .checkFirst, checkedByDefault: false)
                return Row(item: item, info: LargeFileInfo(category: file.category, lastUsed: lastUsed, modified: modified, isICloud: root.isICloud))
            }
            pending.removeAll()
            state.emit(rows)
            state.addCandidates(candidates)
            candidates.removeAll()
        }
    }
}
