import Foundation

/// Git worktrees that coding tools left behind after their repository forgot them.
public struct WorktreeScanner: CleanScanner {
    static let group = "Worktrees"

    /// Where Claude Code, Codex, Cursor, T3 Code and Conductor keep worktrees, relative to the home folder.
    static let toolFolders = [".claude/worktrees", ".codex/worktrees", ".cursor/worktrees", ".t3/worktrees", "conductor/workspaces"]

    public var tab: CleanTab { .developer }
    /// Absolute folders holding repositories; nil for the usual code folders in the home folder.
    public var roots: [String]?
    public var workingFolders: @Sendable () -> [String]
    public var readsGuardedFolders: @Sendable () -> Bool

    public init(roots: [String]? = nil, workingFolders: @escaping @Sendable () -> [String] = { WorkingFolders.current() },
                readsGuardedFolders: @escaping @Sendable () -> Bool = { StorageAccess.hasFullDiskAccess }) {
        self.roots = roots
        self.workingFolders = workingFolders
        self.readsGuardedFolders = readsGuardedFolders
    }

    struct Orphan {
        var path: String
        var repository: String
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let home = context.homePath
        let readsGuarded = readsGuardedFolders()
        var containers = Self.toolFolders.map { home + "/" + $0 }
        // Next to repositories: <repo>/.claude/worktrees and <name>-worktrees folders, one or two levels into each root.
        let rootPaths = roots ?? CleanFiles.projectRoots(home: home, readsGuarded: readsGuarded)
        for root in rootPaths {
            for name in CleanFiles.names(root) where !name.hasPrefix(".") {
                let child = root + "/" + name
                containers.append(child + "/.claude/worktrees")
                if name.hasSuffix("-worktrees") { containers.append(child); continue }
                guard !CleanFiles.exists(child + "/.git"), CleanFiles.isDirectory(child) else { continue }
                for inner in CleanFiles.names(child) where !inner.hasPrefix(".") {
                    containers.append(child + "/" + inner + "/.claude/worktrees")
                    if inner.hasSuffix("-worktrees") { containers.append(child + "/" + inner) }
                }
            }
        }

        var orphans: [Orphan] = []
        var seen = Set<String>()
        for container in containers where CleanFiles.isDirectory(container) && seen.insert(container).inserted {
            if context.isCancelled() { return [] }
            find(container, level: 0, home: home, readsGuarded: readsGuarded, context: context, into: &orphans)
        }

        let busy = workingFolders()
        orphans = orphans.filter { !WorkingFolders.contains(busy, inside: $0.path) && !context.isBlocked($0.path) }
        let sizer = CleanSizer(context)
        let sizes = sizer.sizes(orphans.map(\.path))
        if sizer.cancelled { return [] }
        let items = orphans.map { orphan in
            let size = sizes[orphan.path] ?? .init(bytes: 0, modified: nil)
            return CleanItem(id: "worktree:\(orphan.path)", tab: .developer, group: Self.group,
                             name: "\((orphan.path as NSString).lastPathComponent) (\(orphan.repository))",
                             detail: "A git worktree its repository no longer tracks. Changes in it that were never pushed go with it.",
                             paths: [orphan.path], bytes: size.bytes, modified: size.modified, safety: .checkFirst, checkedByDefault: false)
        }.sorted { $0.bytes > $1.bytes }
        if !items.isEmpty { context.found(items) }
        return items
    }

    /// Worktrees sit a level or two down (tool/repo/name); a folder with a .git file is one, and is not walked into.
    private func find(_ folder: String, level: Int, home: String, readsGuarded: Bool, context: CleanScanContext, into orphans: inout [Orphan]) {
        for name in CleanFiles.names(folder) where !name.hasPrefix(".") {
            let path = folder + "/" + name
            guard CleanFiles.isDirectory(path), !context.isExcluded(path) else { continue }
            let gitFile = path + "/.git"
            if CleanFiles.isDirectory(gitFile) { continue }
            if CleanFiles.exists(gitFile) {
                if let orphan = Self.orphan(path, home: home, readsGuarded: readsGuarded) { orphans.append(orphan) }
            } else if level < 2 {
                find(path, level: level + 1, home: home, readsGuarded: readsGuarded, context: context, into: &orphans)
            }
        }
    }

    /// A worktree whose `.git` file points at a gitdir that no longer exists. Nil when it
    /// is fine or when that cannot be told: the repository is on a disk that is not
    /// connected, or in a folder Wisp may not read.
    static func orphan(_ worktree: String, home: String, readsGuarded: Bool) -> Orphan? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = ((worktree as NSString).appendingPathComponent(gitdir) as NSString).standardizingPath }
        guard gitdir.contains("/.git/worktrees/") else { return nil }
        if gitdir.hasPrefix("/Volumes/") {
            let volume = gitdir.split(separator: "/").prefix(2).joined(separator: "/")
            if !CleanFiles.isDirectory("/" + volume) { return nil }
        }
        if !readsGuarded && CleanFiles.isGuarded(gitdir, home: home) { return nil }
        if CleanFiles.exists(gitdir) { return nil }
        let repository = gitdir.components(separatedBy: "/.git/worktrees/")[0]
        return Orphan(path: worktree, repository: (repository as NSString).lastPathComponent)
    }
}
