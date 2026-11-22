import Foundation

/// Git worktrees: every one a coding agent made, so their space shows even while they are
/// in use, and in hand-made `*-worktrees` folders the ones the repository forgot or that
/// nobody has touched for a while. None is ticked or cleaned without a review.
public struct WorktreeScanner: CleanScanner {
    static let group = "Worktrees"

    /// Where Claude Code, Codex, Cursor, T3 Code and Conductor keep worktrees, relative to the home folder.
    static let toolFolders = [".claude/worktrees", ".codex/worktrees", ".cursor/worktrees", ".t3/worktrees", "conductor/workspaces"]

    public var tab: CleanTab { .developer }
    /// Absolute folders holding repositories; nil for the usual code folders in the home folder.
    public var roots: [String]?
    /// A tracked worktree outside an agent's folder is listed once neither it nor its git state changed for this long.
    public var staleAfter: TimeInterval
    public var workingFolders: @Sendable () -> [String]
    public var readsGuardedFolders: @Sendable () -> Bool

    public init(roots: [String]? = nil, staleAfter: TimeInterval = 30 * 86_400, workingFolders: @escaping @Sendable () -> [String] = { WorkingFolders.current() },
                readsGuardedFolders: @escaping @Sendable () -> Bool = { StorageAccess.hasFullDiskAccess }) {
        self.roots = roots
        self.staleAfter = staleAfter
        self.workingFolders = workingFolders
        self.readsGuardedFolders = readsGuardedFolders
    }

    struct Orphan {
        var path: String
        var repository: String
        /// Still tracked by its repository; nil when the repository forgot it.
        var lastUsed: Date?
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let home = context.homePath
        let readsGuarded = readsGuardedFolders()
        // An agent's folders list every worktree in them; `*-worktrees` folders only forgotten or stale ones.
        var containers = Self.toolFolders.map { (home + "/" + $0, agent: true) }
        // Next to repositories: <repo>/.claude/worktrees and <name>-worktrees folders, one or two levels into each root.
        let rootPaths = roots ?? CleanFiles.projectRoots(home: home, readsGuarded: readsGuarded)
        for root in rootPaths {
            for name in CleanFiles.names(root) where !name.hasPrefix(".") {
                let child = root + "/" + name
                containers.append((child + "/.claude/worktrees", true))
                if name.hasSuffix("-worktrees") { containers.append((child, false)); continue }
                guard !CleanFiles.exists(child + "/.git"), CleanFiles.isDirectory(child) else { continue }
                for inner in CleanFiles.names(child) where !inner.hasPrefix(".") {
                    containers.append((child + "/" + inner + "/.claude/worktrees", true))
                    if inner.hasSuffix("-worktrees") { containers.append((child + "/" + inner, false)) }
                }
            }
        }

        var orphans: [Orphan] = []
        var seen = Set<String>()
        for (container, agent) in containers where CleanFiles.isDirectory(container) && seen.insert(container).inserted {
            if context.isCancelled() { return [] }
            find(container, level: 0, listsEvery: agent, home: home, readsGuarded: readsGuarded, context: context, into: &orphans)
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
                             detail: orphan.lastUsed.map {
                                     "A git worktree, last used \(Self.ago($0)). Its commits and branch stay in \(orphan.repository); files git ignores, like build output and .env files, go with it. Wisp leaves it if anything in it is not committed."
                                 } ?? "A git worktree its repository no longer tracks. Changes in it that were never pushed go with it.",
                             paths: [orphan.path], bytes: size.bytes, modified: size.modified, safety: .checkFirst, checkedByDefault: false)
        }.sorted { $0.bytes > $1.bytes }
        if !items.isEmpty { context.found(items) }
        return items
    }

    /// Worktrees sit a level or two down (tool/repo/name); a folder with a .git file is one, and is not walked into.
    private func find(_ folder: String, level: Int, listsEvery: Bool, home: String, readsGuarded: Bool, context: CleanScanContext,
                      into orphans: inout [Orphan]) {
        for name in CleanFiles.names(folder) where !name.hasPrefix(".") {
            let path = folder + "/" + name
            guard CleanFiles.isDirectory(path), !context.isExcluded(path) else { continue }
            let gitFile = path + "/.git"
            if CleanFiles.isDirectory(gitFile) { continue }
            if CleanFiles.exists(gitFile) {
                if let orphan = Self.orphan(path, home: home, readsGuarded: readsGuarded) {
                    orphans.append(orphan)
                } else if let tracked = Self.tracked(path, home: home, readsGuarded: readsGuarded),
                          listsEvery || tracked.lastUsed!.timeIntervalSinceNow < -staleAfter {
                    orphans.append(tracked)
                }
            } else if level < 2 {
                find(path, level: level + 1, listsEvery: listsEvery, home: home, readsGuarded: readsGuarded, context: context, into: &orphans)
            }
        }
    }

    /// A worktree its repository still tracks, last used when the folder itself or git's record
    /// of it (HEAD, index, reflog) last changed. Locked worktrees are left out:
    /// `git worktree lock` is how a tool says to keep one.
    static func tracked(_ worktree: String, home: String, readsGuarded: Bool) -> Orphan? {
        guard let gitdir = gitdir(worktree), gitdir.contains("/.git/worktrees/"), CleanFiles.isDirectory(gitdir),
              !CleanFiles.exists(gitdir + "/locked") else { return nil }
        if !readsGuarded && CleanFiles.isGuarded(gitdir, home: home) { return nil }
        var newest: Double = 0
        for path in [worktree, gitdir + "/HEAD", gitdir + "/index", gitdir + "/logs/HEAD"] {
            var info = stat()
            if lstat(path, &info) == 0 { newest = max(newest, Double(info.st_mtimespec.tv_sec)) }
        }
        let repository = gitdir.components(separatedBy: "/.git/worktrees/")[0]
        return Orphan(path: worktree, repository: (repository as NSString).lastPathComponent, lastUsed: Date(timeIntervalSince1970: newest))
    }

    /// "today", "yesterday" or "12 days ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// Where a worktree's `.git` file points, made absolute.
    static func gitdir(_ worktree: String) -> String? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return gitdir.hasPrefix("/") ? gitdir : ((worktree as NSString).appendingPathComponent(gitdir) as NSString).standardizingPath
    }

    /// A worktree whose `.git` file points at a gitdir that no longer exists. Nil when it
    /// is fine or when that cannot be told: the repository is on a disk that is not
    /// connected, or in a folder Wisp may not read.
    static func orphan(_ worktree: String, home: String, readsGuarded: Bool) -> Orphan? {
        guard let gitdir = gitdir(worktree), gitdir.contains("/.git/worktrees/") else { return nil }
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
