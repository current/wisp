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

    public static let defaultStaleAfter: TimeInterval = 30 * 86_400

    public init(staleAfter: TimeInterval = ProjectArtifactScanner.defaultStaleAfter, minimumBytes: Int64 = 1 << 20, depth: Int = 8,
                roots: [String]? = nil, now: @escaping @Sendable () -> Date = { Date() },
                workingFolders: @escaping @Sendable () -> [String] = { WorkingFolders.current() },
                readsGuardedFolders: @escaping @Sendable () -> Bool = { StorageAccess.hasFullDiskAccess }) {
        self.staleAfter = staleAfter
        self.minimumBytes = minimumBytes
        self.depth = depth
        self.roots = roots
        self.now = now
        self.workingFolders = workingFolders
        self.readsGuardedFolders = readsGuardedFolders
    }

    /// One artifact folder and the folder it sits in.
    struct Found {
        var path: String
        var parent: String
        var artifact: StorageCatalog.Artifact
    }

    /// What one walk of the roots turns up.
    final class Walk {
        var found: [Found] = []
        var gitRoots = Set<String>()
        /// Newest change to anything that is not an artifact, for folders that hold a repository or an artifact.
        var newest: [String: Double] = [:]
        var visited = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        static let folderLimit = 300_000
        static let entryLimit = 10_000
    }

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
        let sizer = CleanSizer(context)
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
                let paths = group.map(\.path).sorted()
                let size = sizer.total(paths, sizes: sizes)
                guard size.bytes >= minimumBytes else { continue }
                let artifact = group[0].artifact
                batch.append(CleanItem(id: "project-\(name):\(project)", tab: .developer, group: Self.group, name: "\(name) in \(projectName)",
                                       detail: artifact.detail + ".", paths: paths, bytes: size.bytes,
                                       modified: Date(timeIntervalSince1970: last), safety: artifact.cleanSafety,
                                       checkedByDefault: artifact.cleanSafety == .safe))
            }
            batch.sort { $0.bytes > $1.bytes }
            if !batch.isEmpty { context.found(batch) }
            items += batch
        }
        return items
    }

    func walk(_ rootPaths: [String], context: CleanScanContext) -> Walk {
        let walk = Walk()
        for root in rootPaths where !context.isExcluded(root) && !context.isCancelled() {
            _ = visit(root, level: 0, walk: walk, context: context)
        }
        return walk
    }

    /// Lists one folder, records the artifacts in it and walks on. Returns the newest change
    /// to a file in it or below that is not part of an artifact.
    private func visit(_ path: String, level: Int, walk: Walk, context: CleanScanContext) -> Double {
        guard walk.visited < Walk.folderLimit, !context.isCancelled() else { return 0 }
        walk.visited += 1
        guard let entries = CleanFiles.entries(path, limit: Walk.entryLimit, buffer: &walk.buffer) else {
            // A folder this full holds data, not code: its own date stands in for its files.
            var info = stat()
            return lstat(path, &info) == 0 ? Double(info.st_mtimespec.tv_sec) : 0
        }
        var newest = 0.0
        let names = Set(entries.map(\.name))
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
            for name in folders {
                let child = path + "/" + name
                if context.isExcluded(child) { continue }
                newest = max(newest, visit(child, level: level + 1, walk: walk, context: context))
            }
        }
        if hasGit || artifactsHere { walk.newest[path] = newest }
        return newest
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
