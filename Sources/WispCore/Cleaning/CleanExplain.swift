import CoreServices
import Foundation

/// The Clean Up page's last scan of each tab and what the owner ticked, saved by the app so
/// `wisp clean` and the MCP server answer about the rows on screen instead of scanning again.
public struct CleanSnapshot: Codable, Sendable {
    public struct Tab: Codable, Sendable {
        public var scannedAt: Date
        public var items: [CleanItem]

        public init(scannedAt: Date, items: [CleanItem]) {
            self.scannedAt = scannedAt
            self.items = items
        }
    }

    /// By `CleanTab` raw value. Only scans that finished are saved.
    public var tabs: [String: Tab]
    /// Ids of the ticked rows.
    public var selected: [String]

    /// A scan older than this is not used; whatever asks scans again.
    public static let maximumAge: TimeInterval = 86_400

    public init(tabs: [String: Tab], selected: [String]) {
        self.tabs = tabs
        self.selected = selected
    }

    static var url: URL { Wisp.supportDirectory.appendingPathComponent("clean-scan.json") }

    public static func load() -> CleanSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CleanSnapshot.self, from: data)
    }

    public func save() {
        guard !Wisp.readOnly else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// The saved scan of `tab` if it is recent, without rows whose files are gone since.
    public func recent(_ tab: CleanTab, now: Date = Date()) -> Tab? {
        guard var saved = tabs[tab.rawValue], now.timeIntervalSince(saved.scannedAt) < Self.maximumAge else { return nil }
        saved.items.removeAll { !$0.paths.isEmpty && !$0.paths.contains { FileManager.default.fileExists(atPath: $0) } }
        return saved
    }
}

/// Everything Wisp can tell about one row of Clean Up: the row itself, where it came from,
/// and what is true of it right now. The answer to `wisp clean --explain` and the MCP tool
/// `explain_cleanable`.
public struct CleanExplanation: Codable, Sendable {
    public struct Git: Codable, Sendable {
        /// The repository the item belongs to; for a worktree, the main repository.
        public var repository: String
        public var branch: String?
        public var remote: String?
        /// Files changed or not tracked, as `git status` lists them. These go with a worktree.
        public var uncommittedFiles: Int?
        /// Commits no remote branch holds. A worktree's commits stay in its repository either way.
        public var unpushedCommits: Int?
        public var lastCommit: String?
        public var lastCommitDate: Date?
    }

    public var item: CleanItem
    public var safety: String
    /// Ticked on the Clean Up page. Nil when the answer comes from a fresh scan.
    public var selected: Bool?
    /// Every path the row lists still exists.
    public var stillThere: Bool
    public var git: Git?
    /// Where a downloaded file came from, from the address the browser recorded on it.
    public var downloadedFrom: [String]?
    /// The installed app the item belongs to.
    public var ownerApp: String?
    public var ownerRunning: Bool?
    /// A process working in the item or holding a file in it now.
    public var inUseBy: String?
}

public enum CleanExplainer {
    /// Rows matching `query`: an item id, a path at or inside an item, or words from the row's name. Largest first, at most `limit`.
    public static func matches(_ query: String, in items: [CleanItem], limit: Int = 10) -> [CleanItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if let exact = items.first(where: { $0.id == query }) { return [exact] }
        let path = (query as NSString).expandingTildeInPath
        let byPath = items.filter { $0.paths.contains { path == $0 || path.hasPrefix($0 + "/") } }
        if !byPath.isEmpty { return Array(byPath.sorted { $0.bytes > $1.bytes }.prefix(limit)) }
        let words = query.lowercased().split(separator: " ").map(String.init)
        let byName = items.filter { item in
            let text = ([item.name, item.group] + item.paths.map { ($0 as NSString).lastPathComponent }).joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
        return Array(byName.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    public static func explain(_ item: CleanItem, selected: Bool?, processUse: ProcessUse? = nil) -> CleanExplanation {
        let use = processUse ?? ProcessUse.snapshot()
        let fileManager = FileManager.default
        var explanation = CleanExplanation(item: item, safety: item.safetyLabel, selected: selected,
                                           stillThere: item.paths.allSatisfy { fileManager.fileExists(atPath: $0) })
        if let folder = gitFolder(item) { explanation.git = git(folder, repository: item.origin?.project ?? folder) }
        if item.paths.count == 1 {
            explanation.downloadedFrom = item.origin?.downloadedFrom ?? CleanOrigin.downloadedFrom(item.paths[0])
        }
        if let bundleID = item.ownerBundleID {
            explanation.ownerApp = installedApp(bundleID)
            explanation.ownerRunning = use.runningBundleIDs.contains(bundleID)
        }
        explanation.inUseBy = item.paths.lazy.compactMap(use.user(of:)).first
        return explanation
    }

    /// The folder git is asked about: a worktree itself, or the project an artifact sits in.
    static func gitFolder(_ item: CleanItem) -> String? {
        if item.id.hasPrefix("worktree:") { return item.paths.first }
        guard let project = item.origin?.project, FileManager.default.fileExists(atPath: project + "/.git") else { return nil }
        return project
    }

    static func git(_ folder: String, repository: String) -> CleanExplanation.Git {
        var facts = CleanExplanation.Git(repository: repository)
        guard let git = CleanTools.git else { return facts }
        func run(_ arguments: [String]) -> String? {
            let result = CleanTools.run(git, ["--no-optional-locks", "-C", folder] + arguments, timeout: 10)
            guard result.status == 0 else { return nil }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        }
        facts.branch = run(["symbolic-ref", "--short", "-q", "HEAD"])
        let remotes = run(["remote"])?.split(separator: "\n").map(String.init) ?? []
        if let name = remotes.contains("origin") ? "origin" : remotes.first { facts.remote = run(["remote", "get-url", name]) }
        let status = CleanTools.run(git, ["--no-optional-locks", "-C", folder, "status", "--porcelain"], timeout: 20)
        if status.status == 0 { facts.uncommittedFiles = status.output.split(separator: "\n").count }
        // Without a remote every commit would count, which says nothing.
        if !remotes.isEmpty { facts.unpushedCommits = run(["rev-list", "--count", "HEAD", "--not", "--remotes"]).flatMap { Int($0) } }
        if let last = run(["log", "-1", "--format=%h %s%n%cI"])?.split(separator: "\n", maxSplits: 1) {
            facts.lastCommit = String(last[0])
            if last.count > 1 { facts.lastCommitDate = ISO8601DateFormatter().date(from: String(last[1])) }
        }
        return facts
    }

    static func installedApp(_ bundleID: String) -> String? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else { return nil }
        return urls.first?.path
    }
}
