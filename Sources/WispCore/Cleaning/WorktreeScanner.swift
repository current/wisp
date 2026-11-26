import Foundation

/// Git worktrees: every one a coding agent made, so their space shows even while they are
/// in use, and in hand-made `*-worktrees` folders the ones nobody has touched for a while.
/// None is ticked or cleaned without a review. A worktree its repository forgot is not
/// offered: git cannot say what in it was never committed, so the cleaner leaves it.
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

    struct Worktree {
        var path: String
        var repository: String
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

        var worktrees: [Worktree] = []
        var seen = Set<String>()
        for (container, agent) in containers where CleanFiles.isDirectory(container) && seen.insert(container).inserted {
            if context.isCancelled() { return [] }
            find(container, level: 0, listsEvery: agent, home: home, readsGuarded: readsGuarded, context: context, into: &worktrees)
        }

        let busy = workingFolders()
        worktrees = worktrees.filter { !WorkingFolders.contains(busy, inside: $0.path) && !context.isBlocked($0.path) }
        let sizer = CleanSizer(context)
        var items: [CleanItem] = []
        // A few at a time, so the first rows show while the rest are measured.
        for start in stride(from: 0, to: worktrees.count, by: 4) {
            let batch = Array(worktrees[start..<min(worktrees.count, start + 4)])
            let sizes = sizer.sizes(batch.map(\.path))
            if sizer.cancelled { return [] }
            let found = batch.map { worktree in
                let size = sizes[worktree.path] ?? .init(bytes: 0, modified: nil)
                return CleanItem(id: "worktree:\(worktree.path)", tab: .developer, group: Self.group,
                                 name: "\((worktree.path as NSString).lastPathComponent) (\(worktree.repository))",
                                 detail: "A git worktree, last used \(Self.ago(worktree.lastUsed ?? Date())). Its commits and branch stay in \(worktree.repository); files git ignores, like build output and .env files, go with it. Wisp leaves it if anything in it is not committed." + size.unreadNote,
                                 paths: [worktree.path], bytes: size.bytes, modified: size.modified, safety: .checkFirst, checkedByDefault: false)
                    .stamped(sizes)
            }
            context.found(found)
            items += found
        }
        items.sort { $0.bytes > $1.bytes }
        // A process that ends right after its scan, like the CLI, keeps what it measured.
        sizer.cache?.save()
        return items
    }

    /// Worktrees sit a level or two down (tool/repo/name); a folder with a .git file is one, and is not walked into.
    private func find(_ folder: String, level: Int, listsEvery: Bool, home: String, readsGuarded: Bool, context: CleanScanContext,
                      into worktrees: inout [Worktree]) {
        for name in CleanFiles.names(folder) where !name.hasPrefix(".") {
            let path = folder + "/" + name
            guard CleanFiles.isDirectory(path), !context.isExcluded(path) else { continue }
            let gitFile = path + "/.git"
            if CleanFiles.isDirectory(gitFile) { continue }
            if CleanFiles.exists(gitFile) {
                if let tracked = Self.tracked(path, home: home, readsGuarded: readsGuarded),
                   listsEvery || tracked.lastUsed!.timeIntervalSinceNow < -staleAfter {
                    worktrees.append(tracked)
                }
            } else if level < 2 {
                find(path, level: level + 1, listsEvery: listsEvery, home: home, readsGuarded: readsGuarded, context: context, into: &worktrees)
            }
        }
    }

    /// A worktree its repository still tracks, last used when the folder itself or git's record
    /// of it (HEAD, index, reflog) last changed. Locked worktrees are left out:
    /// `git worktree lock` is how a tool says to keep one.
    static func tracked(_ worktree: String, home: String, readsGuarded: Bool) -> Worktree? {
        guard let gitdir = gitdir(worktree), gitdir.contains("/.git/worktrees/"), CleanFiles.isDirectory(gitdir),
              !CleanFiles.exists(gitdir + "/locked") else { return nil }
        if !readsGuarded && CleanFiles.isGuarded(gitdir, home: home) { return nil }
        var newest: Double = 0
        for path in [worktree, gitdir + "/HEAD", gitdir + "/index", gitdir + "/logs/HEAD"] {
            var info = stat()
            if lstat(path, &info) == 0 { newest = max(newest, Double(info.st_mtimespec.tv_sec)) }
        }
        let repository = gitdir.components(separatedBy: "/.git/worktrees/")[0]
        return Worktree(path: worktree, repository: (repository as NSString).lastPathComponent, lastUsed: Date(timeIntervalSince1970: newest))
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
}
