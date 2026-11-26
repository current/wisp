import Darwin
import Foundation

/// Build output and installed packages inside projects nobody has touched for a while:
/// node_modules, Rust target, Python environments, Swift .build and the like.
public struct ProjectArtifactScanner: CleanScanner {
    static let group = "Projects"

    public var tab: CleanTab { .developer }
    /// A project counts as stale once nothing in it has changed for this long.
    public var staleAfter: TimeInterval
    public var minimumBytes: Int64
    /// Folder levels walked below each project root.
    public var depth: Int
    /// Absolute folders to walk; nil for the usual code folders in the home folder.
    public var roots: [String]?
    public var now: @Sendable () -> Date
    public var workingFolders: @Sendable () -> [String]
    /// Documents and Desktop need Full Disk Access; without it macOS asks the owner.
    public var readsGuardedFolders: @Sendable () -> Bool
    /// Whether git tracks files in a folder of a repository; nil when git cannot say.
    public var gitTracks: @Sendable (_ repository: String, _ path: String) -> Bool?
    /// Remembers each project's walk and the artifacts' sizes; nil reads everything every time.
    var cache: CleanScanCache? = CleanScanCache.shared

    public static let defaultStaleAfter: TimeInterval = 30 * 86_400

    public init(staleAfter: TimeInterval = ProjectArtifactScanner.defaultStaleAfter, minimumBytes: Int64 = 1 << 20, depth: Int = 8,
                roots: [String]? = nil, now: @escaping @Sendable () -> Date = { Date() },
                workingFolders: @escaping @Sendable () -> [String] = { WorkingFolders.current() },
                readsGuardedFolders: @escaping @Sendable () -> Bool = { StorageAccess.hasFullDiskAccess },
                gitTracks: @escaping @Sendable (String, String) -> Bool? = { CleanGuards.liveGitTracks(repository: $0, path: $1) }) {
        self.staleAfter = staleAfter
        self.minimumBytes = minimumBytes
        self.depth = depth
        self.roots = roots
        self.now = now
        self.workingFolders = workingFolders
        self.readsGuardedFolders = readsGuardedFolders
        self.gitTracks = gitTracks
    }

    /// One artifact folder and the folder it sits in.
    struct Found {
        var path: String
        var parent: String
        var artifact: StorageCatalog.Artifact
    }

    /// What one walk of the roots, or of one folder in them, turns up.
    final class Walk {
        var found: [Found] = []
        var gitRoots = Set<String>()
        /// Newest change to anything that is not an artifact, for folders that hold a repository or an artifact.
        var newest: [String: Double] = [:]
        /// Folders listed, shared by every part of one walk.
        let visited: Counter
        /// The folder limit cut this part short, so it is not remembered.
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        static let folderLimit = 300_000
        static let entryLimit = 10_000

        init(visited: Counter = Counter()) {
            self.visited = visited
        }

        func merge(_ other: Walk) {
            found += other.found
            gitRoots.formUnion(other.gitRoots)
            newest.merge(other.newest) { max($0, $1) }
            truncated = truncated || other.truncated
        }

        func merge(_ memo: Memo) {
            for item in memo.found {
                guard let artifact = StorageCatalog.artifacts.first(where: { $0.name == item.artifact }) else { continue }
                found.append(Found(path: item.path, parent: item.parent, artifact: artifact))
            }
            gitRoots.formUnion(memo.gitRoots)
            newest.merge(memo.newest) { max($0, $1) }
        }

        func memo(newest result: Double) -> Memo {
            Memo(found: found.map { Memo.Item(path: $0.path, parent: $0.parent, artifact: $0.artifact.name) }, gitRoots: gitRoots.sorted(),
                 newest: newest, result: result)
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        /// False once the limit is reached.
        func next() -> Bool { lock.withLock { value += 1; return value <= Walk.folderLimit } }
    }

    /// A folder's part of a walk, kept while nothing below it changes.
    struct Memo: Codable {
        struct Item: Codable { var path: String; var parent: String; var artifact: String }
        var found: [Item]
        var gitRoots: [String]
        var newest: [String: Double]
        var result: Double
    }

    /// Folders this many levels below a root are remembered on their own, so a change in
    /// one project reads only that project again.
    static let memoLevels = 1...2

    /// Artifact names with a stricter marker than the Storage page uses.
    static let extraMarkers: [String: [String]] = ["node_modules": ["package.json"]]

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let rootPaths = roots ?? CleanFiles.projectRoots(home: context.homePath, readsGuarded: readsGuardedFolders())
        let walk = walk(rootPaths, context: context)
        if context.isCancelled() { return [] }

        // Each artifact belongs to the nearest enclosing repository, or to the folder it sits in.
        var projects: [String: [Found]] = [:]
        var order: [String] = []
        for found in walk.found {
            var project = found.parent
            var candidate = found.parent
            while true {
                if walk.gitRoots.contains(candidate) { project = candidate; break }
                guard rootPaths.contains(where: { candidate.hasPrefix($0 + "/") }) else { break }
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            if projects[project] == nil { order.append(project) }
            projects[project, default: []].append(found)
        }

        let busy = workingFolders()
        let cutoff = now().timeIntervalSince1970 - staleAfter
        let sizer = CleanSizer(context, cache: cache)
        var items: [CleanItem] = []
        for project in order {
            if sizer.cancelled { break }
            guard let artifacts = projects[project], let last = walk.newest[project], last > 0, last < cutoff,
                  !WorkingFolders.contains(busy, inside: project) else { continue }
            let projectName = (project as NSString).lastPathComponent
            let sizes = sizer.sizes(artifacts.map(\.path))
            var byName: [String: [Found]] = [:]
            for found in artifacts { byName[found.artifact.name, default: []].append(found) }
            var batch: [CleanItem] = []
            for (name, group) in byName.sorted(by: { $0.key < $1.key }) {
                var paths = group.map(\.path).sorted()
                guard sizer.total(paths, sizes: sizes).bytes >= minimumBytes else { continue }
                // Folders the repository commits (node_modules in a GitHub Action, checked-in Pods) are the project's own files.
                if walk.gitRoots.contains(project) { paths = paths.filter { gitTracks(project, $0) != true } }
                let size = sizer.total(paths, sizes: sizes)
                guard !paths.isEmpty, size.bytes >= minimumBytes else { continue }
                let artifact = group[0].artifact
                batch.append(CleanItem(id: "project-\(name):\(project)", tab: .developer, group: Self.group, name: "\(name) in \(projectName)",
                                       detail: artifact.detail + "." + size.unreadNote, paths: paths, bytes: size.bytes,
                                       modified: Date(timeIntervalSince1970: last), safety: artifact.cleanSafety,
                                       checkedByDefault: artifact.cleanSafety == .safe).stamped(sizes))
            }
            batch.sort { $0.bytes > $1.bytes }
            if !batch.isEmpty { context.found(batch) }
            items += batch
        }
        // A process that ends right after its scan, like the CLI, keeps what it measured.
        sizer.cache?.save()
        return items
    }

    func walk(_ rootPaths: [String], context: CleanScanContext) -> Walk {
        let walk = Walk()
        let cache = cache.flatMap { cache in rootPaths.allSatisfy(cache.isFollowed) ? cache : nil }
        cache?.catchUp(within: cache?.reuseWindow ?? 0, isCancelled: context.isCancelled)
        let salt = CleanScanCache.digest(["\(depth)"] + context.excluded.sorted())
        for root in rootPaths where !context.isExcluded(root) && !context.isCancelled() {
            _ = visit(root, level: 0, walk: walk, context: context, cache: cache, salt: salt)
        }
        return walk
    }

    /// A remembered folder comes back from its memo; others are listed.
    private func visit(_ path: String, level: Int, walk: Walk, context: CleanScanContext, cache: CleanScanCache?, salt: String) -> Double {
        guard let cache, Self.memoLevels.contains(level) else {
            return list(path, level: level, walk: walk, context: context, cache: cache, salt: salt)
        }
        let key = "projects:\(level):\(salt):" + path
        if let data = cache.memo(key), let memo = try? PropertyListDecoder().decode(Memo.self, from: data) {
            walk.merge(memo)
            return memo.result
        }
        let event = CleanScanCache.currentEvent()
        let part = Walk(visited: walk.visited)
        let result = list(path, level: level, walk: part, context: context, cache: cache, salt: salt)
        if !part.truncated, !context.isCancelled(), let data = try? PropertyListEncoder().encode(part.memo(newest: result)) {
            cache.storeMemo(key, path: path, event: event, data: data)
        }
        walk.merge(part)
        return result
    }

    /// Lists one folder, records the artifacts in it and walks on. Returns the newest change
    /// to a file in it or below that is not part of an artifact.
    private func list(_ path: String, level: Int, walk: Walk, context: CleanScanContext, cache: CleanScanCache?, salt: String) -> Double {
        guard !context.isCancelled() else { return 0 }
        guard walk.visited.next() else {
            walk.truncated = true
            return 0
        }
        guard let entries = CleanFiles.entries(path, limit: Walk.entryLimit, buffer: &walk.buffer) else {
            // A folder this full holds data, not code: its own date stands in for its files.
            var info = stat()
            return lstat(path, &info) == 0 ? Double(info.st_mtimespec.tv_sec) : 0
        }
        var newest = 0.0
        var folders: [String] = []
        var candidates: [String] = []
        var hasGit = false
        for entry in entries {
            let name = entry.name
            if name == ".git" { hasGit = true; continue }
            if entry.isFolder {
                if StorageCatalog.artifactNames.contains(name) {
                    candidates.append(name)
                } else if !name.hasPrefix("."), !InstallerScanner.packages.contains((name as NSString).pathExtension.lowercased()) {
                    folders.append(name)
                }
            } else if entry.isFile {
                // Files only: a folder's own date also moves when a build adds or replaces an artifact in it.
                newest = max(newest, entry.modified)
            }
        }
        var artifactsHere = false
        let names = candidates.isEmpty ? [] : Set(entries.map(\.name))
        for name in candidates {
            let child = path + "/" + name
            if let artifact = artifact(name, in: path, names: names) {
                guard !context.isBlocked(child) else { continue }
                walk.found.append(Found(path: child, parent: path, artifact: artifact))
                artifactsHere = true
            } else if !name.hasPrefix(".") {
                folders.append(name)
            }
        }
        if hasGit {
            walk.gitRoots.insert(path)
            for file in [".git", ".git/HEAD", ".git/index", ".git/logs/HEAD"] {
                var info = stat()
                if lstat(path + "/" + file, &info) == 0, info.st_mode & S_IFMT != S_IFDIR {
                    newest = max(newest, Double(info.st_mtimespec.tv_sec))
                }
            }
        }
        if level < depth {
            let children = folders.map { path + "/" + $0 }.filter { !context.isExcluded($0) }
            if level == 0, children.count > 1 {
                // Each project of a root on a thread of its own; parts merge in listing order, as one thread would make them.
                let parts = children.map { _ in Walk(visited: walk.visited) }
                let results = Results(count: children.count)
                let pool = TaskPool()
                for (index, child) in children.enumerated() {
                    pool.add { results.set(index, visit(child, level: 1, walk: parts[index], context: context, cache: cache, salt: salt)) }
                }
                pool.run(threads: CleanSizer.threadCount(), qos: .utility)
                for (index, part) in parts.enumerated() {
                    walk.merge(part)
                    newest = max(newest, results.get(index))
                }
            } else {
                for child in children {
                    newest = max(newest, visit(child, level: level + 1, walk: walk, context: context, cache: cache, salt: salt))
                }
            }
        }
        if hasGit || artifactsHere { walk.newest[path] = newest }
        return newest
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        init(count: Int) { values = [Double](repeating: 0, count: count) }
        func set(_ index: Int, _ value: Double) { lock.withLock { values[index] = value } }
        func get(_ index: Int) -> Double { lock.withLock { values[index] } }
    }

    /// The catalogue entry `name` matches in this folder, checked by its marker file.
    private func artifact(_ name: String, in folder: String, names: Set<String>) -> StorageCatalog.Artifact? {
        for artifact in StorageCatalog.artifacts where artifact.name == name {
            let markers = Self.extraMarkers[name] ?? artifact.markers
            if markers.isEmpty { return artifact }
            if artifact.markerInside {
                if markers.contains(where: { CleanFiles.exists(folder + "/" + name + "/" + $0) }) { return artifact }
            } else if markers.contains(where: { marker in
                marker.hasPrefix("*") ? names.contains { $0.hasSuffix(marker.dropFirst()) } : names.contains(marker)
            }) {
                return artifact
            }
        }
        return nil
    }
}
