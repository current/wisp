import Darwin
import Foundation

/// What became of one item in a clean.
public struct CleanResult: Sendable {
    public var item: CleanItem
    public var outcome: CleanOutcome
    public var bytesFreed: Int64

    public init(item: CleanItem, outcome: CleanOutcome, bytesFreed: Int64 = 0) {
        self.item = item
        self.outcome = outcome
        self.bytesFreed = bytesFreed
    }
}

public struct CleanReport: Sendable {
    public var results: [CleanResult] = []
    public var bytesFreed: Int64 { results.reduce(0) { $0 + $1.bytesFreed } }
    public var removed: [CleanResult] { results.filter(\.outcome.removed) }
    public var notRemoved: [CleanResult] { results.filter { !$0.outcome.removed } }

    public init(results: [CleanResult] = []) { self.results = results }

    public func record(trigger: CleanRecord.Trigger, date: Date = Date()) -> CleanRecord {
        CleanRecord(date: date, trigger: trigger, items: results.map {
            CleanRecord.Item(name: $0.item.name, tab: $0.item.tab, paths: $0.item.paths, bytes: $0.item.bytes,
                             removal: $0.item.removal, outcome: $0.outcome)
        }, bytesFreed: bytesFreed)
    }
}

extension CleanItem {
    /// Cleaned by Clean Safe Items and by a scheduled clean: safe, and only ever to the Trash.
    public var isSafeTrash: Bool { safety == .safe && removal == .trash }
}

/// Who is using what right now: the working folder, program, open files and mapped files of
/// every process Wisp can read, the apps that are running, and the volumes and disk images
/// that are mounted. Taken when a clean starts and again while a long one runs.
public struct ProcessUse: Sendable {
    /// Sorted by path, so finding a path and everything under it is a binary search.
    private var paths: [String] = []
    private var names: [String] = []
    public var runningBundleIDs: Set<String> = []
    public var runningBundlePaths: Set<String> = []
    /// Where volumes are mounted.
    public var mountPoints: [String] = []
    /// Attached disk images by the real path of the image, with where each is mounted. Nil when
    /// hdiutil could not say: a disk image file is then left alone.
    public var diskImages: [String: String]?

    public init(entries: [(name: String, path: String)] = [], runningBundleIDs: Set<String> = [], runningBundlePaths: Set<String> = [],
                mountPoints: [String] = [], diskImages: [String: String]? = [:]) {
        let sorted = entries.sorted { $0.path < $1.path }
        paths = sorted.map(\.path)
        names = sorted.map(\.name)
        self.runningBundleIDs = runningBundleIDs
        self.runningBundlePaths = runningBundlePaths
        self.mountPoints = mountPoints
        self.diskImages = diskImages
    }

    /// The name of a process working in `path` or holding a file at or under it.
    public func user(of path: String) -> String? {
        if let index = lowerBound(path), index < paths.count, paths[index] == path { return names[index] }
        let folder = path.hasSuffix("/") ? path : path + "/"
        if let index = lowerBound(folder), index < paths.count, paths[index].hasPrefix(folder) { return names[index] }
        return nil
    }

    /// A volume mounted at `path` or somewhere inside it.
    public func mount(inside path: String) -> String? {
        mountPoints.first { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// An attached disk image at `path` or inside it, and where it is mounted.
    public func diskImage(inside path: String) -> (image: String, mount: String)? {
        guard let image = diskImages?.keys.sorted().first(where: { $0 == path || $0.hasPrefix(path + "/") }) else { return nil }
        return (image, diskImages?[image] ?? "")
    }

    private func lowerBound(_ key: String) -> Int? {
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// `PROC_PIDREGIONPATHINFO2`: only the regions a file backs. The header defines it as a
    /// plain number Swift does not import.
    static let regionPathInfo: Int32 = 22
    /// A process with more mapped regions than this is read only this far.
    static let regionLimit = 50_000

    /// Reads every process once: `proc_listpids`, then per process its name, working folder,
    /// program, open files and mapped files. Processes of other users fail quietly and are left
    /// out, which is why mounted disk images are asked of hdiutil: their files are held open by
    /// a system process. Only paths in the folders a clean can touch are kept.
    public static func snapshot(excluding own: Int32 = getpid(), home: String = NSHomeDirectory()) -> ProcessUse {
        var roots = ["/Users/", "/Applications/", "/Volumes/"]
        for base in [home, CleanPathRules.realPath(home) ?? home] where !roots.contains(where: { (base + "/").hasPrefix($0) }) {
            roots.append(base + "/")
        }
        var pids = [Int32](repeating: 0, count: 4096)
        var count = 0
        while true {
            let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
            count = Int(bytes) / MemoryLayout<Int32>.stride
            if count < pids.count - 16 { break }
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
        let wanted = pids.prefix(count).filter { $0 > 0 && $0 != own }

        // Walking mapped files is most of the time, and each process's map has its own lock,
        // so a few threads share the processes.
        final class Gathered: @unchecked Sendable {
            let lock = NSLock()
            var next = 0
            var entries: [(name: String, path: String)] = []
            var bundles: Set<String> = []
        }
        let gathered = Gathered()
        let threads = min(6, max(1, wanted.count / 64))
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var reader = ProcessReader(roots: roots)
            var entries: [(name: String, path: String)] = []
            var bundles: Set<String> = []
            while true {
                let index: Int? = gathered.lock.withLock {
                    guard gathered.next < wanted.count else { return nil }
                    defer { gathered.next += 1 }
                    return gathered.next
                }
                guard let index else { break }
                reader.read(wanted[index], into: &entries, bundles: &bundles)
            }
            gathered.lock.withLock {
                gathered.entries += entries
                gathered.bundles.formUnion(bundles)
            }
        }
        var ids: Set<String> = []
        for bundle in gathered.bundles {
            if let id = CleanPathRules.bundleID(at: bundle) ?? (NSDictionary(contentsOfFile: bundle + "/Info.plist")?["CFBundleIdentifier"] as? String) {
                ids.insert(id)
            }
        }
        return ProcessUse(entries: gathered.entries, runningBundleIDs: ids, runningBundlePaths: gathered.bundles, mountPoints: mountPoints(),
                          diskImages: attachedImages())
    }

    /// One thread's buffers for reading processes.
    struct ProcessReader {
        let roots: [String]
        private var nameBuffer = [CChar](repeating: 0, count: 256)
        private var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        private var fdInfo = vnode_fdinfowithpath()
        private var region = proc_regionwithpathinfo()

        init(roots: [String]) { self.roots = roots }

        func kept(_ path: String) -> Bool { roots.contains { path.hasPrefix($0) } }

        mutating func read(_ pid: Int32, into entries: inout [(name: String, path: String)], bundles: inout Set<String>) {
            let name: String = nameBuffer.withUnsafeMutableBufferPointer { buffer in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count)) > 0 ? String(cString: buffer.baseAddress!) : "pid \(pid)"
            }
            if let cwd = ProcessDetails.workingDirectory(pid: pid), cwd != "/" { entries.append((name, cwd)) }
            let executable: String? = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)) > 0 ? String(cString: buffer.baseAddress!) : nil
            }
            if let executable {
                bundles.formUnion(ProcessUse.bundlePaths(in: executable))
                // A program running from a folder holds no open file there, only its mapped executable.
                if kept(executable) { entries.append((name, executable)) }
            }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if size > 0 {
                let fdInfoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
                let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
                for fd in fds.prefix(max(0, Int(filled)) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &fdInfo, fdInfoSize) == fdInfoSize else { continue }
                    let path = withUnsafeBytes(of: fdInfo.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if kept(path) { entries.append((name, path)) }
                }
            }
            // Libraries, plug-ins and native modules stay mapped after their file is closed.
            let regionSize = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            var mapped = Set<String>()
            var address: UInt64 = 0
            for _ in 0..<ProcessUse.regionLimit {
                guard proc_pidinfo(pid, ProcessUse.regionPathInfo, address, &region, regionSize) > 0 else { break }
                let path = withUnsafeBytes(of: region.prp_vip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if !path.isEmpty, kept(path) { mapped.insert(path) }
                let next = region.prp_prinfo.pri_address &+ region.prp_prinfo.pri_size
                guard next > address else { break }
                address = next
            }
            for path in mapped { entries.append((name, path)) }
        }
    }

    /// Every app, extension and XPC service bundle a program runs inside, outermost first:
    /// a helper's own id names its caches and containers, the outer app's names the app.
    static func bundlePaths(in executable: String) -> [String] {
        var bundles: [String] = []
        var prefix = ""
        for part in executable.split(separator: "/") {
            prefix += "/" + part
            if ["app", "appex", "xpc"].contains((String(part) as NSString).pathExtension.lowercased()) { bundles.append(prefix) }
        }
        return bundles
    }

    /// Mount points as the kernel lists them, with the Data volume's firmlinked view added
    /// so they compare with the paths a scan reports.
    static func mountPoints() -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        let data = "/System/Volumes/Data"
        var points: [String] = []
        for index in 0..<Int(count) {
            let point = withUnsafeBytes(of: buffer[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            points.append(point)
            if point.hasPrefix(data + "/") { points.append(String(point.dropFirst(data.count))) }
        }
        return points
    }

    /// Image files hdiutil has attached, with where each is mounted. Nil when hdiutil gave no answer.
    static func attachedImages() -> [String: String]? {
        let result = CleanTools.run(CleanTools.hdiutil, ["info", "-plist"], timeout: 10)
        guard result.status == 0 else { return nil }
        return parseImages(result.output)
    }

    static func parseImages(_ output: String) -> [String: String]? {
        guard let start = output.range(of: "<?xml"), let end = output.range(of: "</plist>", range: start.upperBound..<output.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: Data(output[start.lowerBound..<end.upperBound].utf8), format: nil)
                  as? [String: Any] else { return nil }
        var found: [String: String] = [:]
        for image in plist["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String else { continue }
            let mount = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }.first ?? ""
            found[CleanPathRules.realPath(path) ?? path] = mount
        }
        return found
    }
}

/// The checks a clean makes before it touches anything, and the calls it makes to remove
/// things. The live ones read the real Mac; tests put fakes in their place.
public struct CleanGuards: Sendable {
    public enum GitState: Sendable { case clean, uncommitted, unknown }

    public var processUse: @Sendable () -> ProcessUse
    /// Asked only for worktrees: folders whose `.git` is a file.
    public var gitState: @Sendable (String) -> GitState
    /// Whether git tracks a file at or under the path in the work tree that holds it; nil when git cannot say.
    public var gitTracks: @Sendable (_ repository: String, _ path: String) -> Bool?
    /// Runs a tool and returns its exit status and what it printed.
    public var runTool: @Sendable (_ path: String, _ arguments: [String]) -> (status: Int32, output: String)
    public var trash: @Sendable (String) throws -> Void
    /// Whether xcrun has developer tools behind it. Without them it offers to install them,
    /// which puts a window on screen, so simctl is not run.
    public var developerTools: @Sendable () -> Bool
    public var now: @Sendable () -> Date
    /// What still links into or runs from an item's paths, given the paths, the home folder and the clean's shared context.
    public var dependent: @Sendable ([String], String, CleanDependents.Context) -> String?
    /// The duplicate groups of the last Large Files scan, to make sure a copy stays.
    public var duplicates: @Sendable () -> DuplicateSummary
    /// Locked for the length of a clean by the app and by wisp alike, so two cleans never run at once. Nil cleans without it.
    public var lockFile: String?

    public init(processUse: @escaping @Sendable () -> ProcessUse, gitState: @escaping @Sendable (String) -> GitState,
                runTool: @escaping @Sendable (String, [String]) -> (status: Int32, output: String),
                trash: @escaping @Sendable (String) throws -> Void, developerTools: @escaping @Sendable () -> Bool = { CleanGuards.developerToolsInstalled() },
                now: @escaping @Sendable () -> Date = { Date() },
                dependent: @escaping @Sendable ([String], String, CleanDependents.Context) -> String? = { CleanDependents.dependent(of: $0, home: $1, context: $2) },
                gitTracks: @escaping @Sendable (String, String) -> Bool? = { CleanGuards.liveGitTracks(repository: $0, path: $1) },
                duplicates: @escaping @Sendable () -> DuplicateSummary = { LargeFileIndex.shared.duplicates },
                lockFile: String? = nil) {
        self.processUse = processUse
        self.gitState = gitState
        self.runTool = runTool
        self.trash = trash
        self.developerTools = developerTools
        self.now = now
        self.dependent = dependent
        self.gitTracks = gitTracks
        self.duplicates = duplicates
        self.lockFile = lockFile
    }

    public static func developerToolsInstalled() -> Bool { CleanTools.hasDeveloperTools }

    /// `git ls-files` for the path, literally: a name with * or ? in it is not a pattern.
    /// Optional locks are off, so the check never rewrites the repository's index.
    public static func liveGitTracks(repository: String, path: String) -> Bool? {
        guard let git = CleanTools.git else { return nil }
        let real = CleanPathRules.realPath(path) ?? path
        let root = CleanPathRules.realPath(repository) ?? repository
        guard real.hasPrefix(root + "/") else { return nil }
        let result = CleanTools.run(git, ["--no-optional-locks", "-C", root, "ls-files", "--cached", "-z", "--",
                                          ":(literal)" + real.dropFirst(root.count + 1)], timeout: 20)
        guard result.status == 0 else { return nil }
        return !result.output.isEmpty
    }

    /// `git status` without optional locks, so checking a worktree never rewrites its index.
    /// /usr/bin/git is a shim that offers to install the developer tools when they are
    /// missing, which would put a window on screen; only a real git is run.
    public static func liveGitState(_ path: String) -> GitState {
        guard let git = CleanTools.git else { return .unknown }
        let result = CleanTools.run(git, ["--no-optional-locks", "-C", path, "status", "--porcelain"], timeout: 20)
        guard result.status == 0 else { return .unknown }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clean : .uncommitted
    }

    /// In the support folder the app and wisp share. Named without creating the folder: when
    /// it is missing the lock cannot be opened and the clean relies on its other checks.
    static var sharedLockFile: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path + "/Wisp/clean.lock"
    }

    public static let live = CleanGuards(
        processUse: { ProcessUse.snapshot() },
        gitState: { liveGitState($0) },
        runTool: { CleanTools.run($0, $1, timeout: 300) },
        trash: { path in try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) },
        lockFile: sharedLockFile
    )
}

/// Where the tools a clean may call live. Nothing is found through PATH.
enum CleanTools {
    static let xcrun = "/usr/bin/xcrun"
    static let tmutil = "/usr/bin/tmutil"
    static let hdiutil = "/usr/bin/hdiutil"

    static var git: String? {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether xcrun has developer tools to run, so it will not offer to install them.
    static var hasDeveloperTools: Bool {
        let result = run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return (127, "\((path as NSString).lastPathComponent) is not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Homebrew would otherwise update itself over the network first.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (126, error.localizedDescription) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Which paths Wisp may move to the Trash.
public enum CleanPathRules {
    /// Inside home, these are never touched, whatever a scanner says: the owner's keys and
    /// accounts, what syncs, and Apple's stores of contacts, calendars, browsing and backups.
    static let protectedInHome = ["Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
                                  "Library/Messages", "Library/Accounts", ".ssh", ".gnupg", ".Trash",
                                  "Library/Calendars", "Library/Safari", "Library/Photos", "Library/Passes", "Library/IdentityServices",
                                  "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
                                  "Library/Application Support/CallHistoryTransactions", "Library/Application Support/MobileSync",
                                  "Library/Application Support/Knowledge", "Library/Application Support/FileProvider",
                                  "Library/Application Support/CloudDocs",
                                  ".aws", ".azure", ".kube", ".password-store", ".config/gcloud", ".config/gh"].map { $0.lowercased() }

    /// Library folders where an entry named for Apple (com.apple.Notes, group.com.apple.notes,
    /// 243LU875E5.groups.com.apple.podcasts) holds macOS's own data. Caches and Logs are not
    /// among them: Apple's caches and logs are junk like anyone's.
    static let appleDataFolders: Set<String> = ["library/application support", "library/containers", "library/group containers",
                                                "library/preferences", "library/preferences/byhost", "library/httpstorages",
                                                "library/webkit", "library/saved application state", "library/cookies",
                                                "library/application scripts", "library/launchagents"]

    /// Nil when Wisp may move `path` to the Trash, otherwise the plain reason it may not.
    /// Allowed: below a top-level folder of the home folder (two levels down inside
    /// ~/Library), app bundles in /Applications or one plain folder down (as
    /// `InstalledApps` lists them), and nothing that a link carries
    /// somewhere else. The path must exist.
    public static func refusal(_ path: String, home: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/"),
              !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return "Not a plain absolute path" }
        guard let homeReal = realPath(home) else { return "Your home folder cannot be read" }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let parentReal = realPath(parent), let itemReal = realPath(path) else { return "It cannot be read" }
        let placed = parentReal == "/" ? "/" + name : parentReal + "/" + name
        if let reason = refusal(resolved: placed, homeReal: homeReal) { return reason }
        if itemReal != placed, refusal(resolved: itemReal, homeReal: homeReal) != nil {
            return "It is a link to somewhere Wisp does not clean"
        }
        return nil
    }

    static func refusal(resolved path: String, homeReal: String) -> String? {
        if path == homeReal { return "It is your home folder" }
        if path.hasPrefix(homeReal + "/") {
            let relative = String(path.dropFirst(homeReal.count + 1))
            let parts = relative.split(separator: "/")
            if parts.count < 2 { return "It is a top-level folder of your home folder" }
            if parts[0] == "Library", parts.count < 3 { return "It is a top-level folder of your Library" }
            // APFS ignores case, so ~/library/keychains is the keychains folder too.
            let lower = relative.lowercased()
            if protectedInHome.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) { return "Wisp never touches it" }
            if isAppleData(lower) { return "It holds data macOS keeps for its own apps" }
            return nil
        }
        let parts = path.split(separator: "/")
        let inApplications = parts.count == 2 || (parts.count == 3 && (String(parts[1]) as NSString).pathExtension.isEmpty)
        if inApplications, parts[0] == "Applications", parts[parts.count - 1].hasSuffix(".app") {
            if let id = bundleID(at: path), id.hasPrefix("com.apple."),
               !id.hasPrefix("com.apple.InstallAssistant"), !id.hasPrefix("com.apple.dt.") {
                return "It comes with macOS"
            }
            return nil
        }
        if ["System", "Library", "usr", "bin", "sbin", "private", "etc", "var", "cores", "dev", "Volumes"].contains(parts.first ?? "") {
            return "It belongs to macOS"
        }
        return "It is outside the folders Wisp cleans"
    }

    /// `relative` (lowercased, below home) is or sits in an Apple-named entry of a folder in `appleDataFolders`.
    static func isAppleData(_ relative: String) -> Bool {
        for folder in appleDataFolders where relative.hasPrefix(folder + "/") {
            let entry = relative.dropFirst(folder.count + 1).prefix { $0 != "/" }
            if entry.hasPrefix("com.apple.") || entry.hasPrefix("group.com.apple.") || entry.contains(".com.apple.") { return true }
        }
        return false
    }

    /// An app bundle's identifier from its Info.plist. Read directly: `Bundle(path:)` keeps
    /// every bundle it opens for the life of the process.
    public static func bundleID(at path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
    }

    static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}

/// Removes items: each one is checked again first, then goes to the Trash, or through its
/// own tool for the few kinds only that tool can remove. Never asks for administrator rights.
public struct Cleaner: Sendable {
    public var home: String
    public var exclusions: [String]
    public var guards: CleanGuards
    /// Checks on the selection as a whole (see `CleanRegistry.selectionChecks`).
    public var selectionChecks: [@Sendable (Set<String>) -> Bool] = CleanRegistry.selectionChecks
    /// How long a clean waits for one already running in the app or in wisp.
    public var lockWait: TimeInterval = 30

    /// Package managers write these while they install; a project with one this fresh is busy.
    static let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "Cargo.lock",
                            "Podfile.lock", "Package.resolved", "poetry.lock", "uv.lock", "Gemfile.lock", "composer.lock"]
    static let busyWindow: TimeInterval = 120
    /// A clean that runs longer than this looks again at what is running before it goes on.
    static let useLifetime: TimeInterval = 5
    static let diskImageExtensions: Set<String> = ["dmg", "sparseimage", "sparsebundle", "iso", "img", "cdr", "toast", "dmgpart", "udif"]

    public init(home: String = NSHomeDirectory(), exclusions: [String] = [], guards: CleanGuards = .live) {
        self.home = home
        self.exclusions = exclusions
        self.guards = guards
    }

    public func clean(_ items: [CleanItem], isCancelled: () -> Bool = { false },
                      progress: (CleanResult) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        guard !items.isEmpty else { return report }
        func skipAll(_ reason: String) -> CleanReport {
            report.results = items.map { CleanResult(item: $0, outcome: .skipped(reason)) }
            report.results.forEach(progress)
            return report
        }
        if let refusal = CleanRegistry.selectionRefusal(items, checks: selectionChecks) { return skipAll(refusal) }
        var lock: CleanLock?
        if let path = guards.lockFile {
            switch CleanLock.take(path, wait: lockWait, isCancelled: isCancelled) {
            case .held(let held): lock = held
            case .busy: return skipAll(isCancelled() ? "Cleaning stopped before it got here" : "Another clean is running. Clean again when it is done")
            case .unavailable: break
            }
        }
        defer { lock?.release() }

        let session = Session(cleaner: self, items: items)
        // What goes to the Trash goes first: a cask's own uninstall steps may delete files the
        // owner chose to send to the Trash, and this way the Trash has them already.
        let order = items.indices.sorted { (items[$0].removal.isPermanent ? 1 : 0, $0) < (items[$1].removal.isPermanent ? 1 : 0, $1) }
        var results = [CleanResult?](repeating: nil, count: items.count)
        for index in order {
            let item = items[index]
            let result: CleanResult
            if isCancelled() {
                result = CleanResult(item: item, outcome: .skipped("Cleaning stopped before it got here"))
            } else if item.removal == .trash, !item.paths.isEmpty, item.paths.allSatisfy(session.alreadyRemoved) {
                // Two rows can name the same file (a large file that is also a duplicate copy); the second frees nothing more.
                result = CleanResult(item: item, outcome: .removed)
            } else if let reason = skipReason(item, session: session, isCancelled: isCancelled) {
                result = CleanResult(item: item, outcome: .skipped(reason))
            } else {
                var pending = item
                var listed = Set<String>()
                pending.paths = item.paths.filter { !session.alreadyRemoved($0) && listed.insert($0).inserted }
                var removed = remove(pending, session: session)
                if removed.outcome.removed, item.removal == .trash { session.removed.formUnion(pending.paths) }
                removed.item = item
                result = removed
            }
            results[index] = result
            progress(result)
        }
        report.results = results.compactMap { $0 }
        return report
    }

    /// What one clean learns once and uses for every item.
    final class Session {
        let cleaner: Cleaner
        let dependents: CleanDependents.Context
        /// Every path the clean sends to the Trash.
        let removing: Set<String>
        var removed = Set<String>()
        private let exclusionsReal: [String]
        private var use: ProcessUse?
        private var useTaken = Date.distantPast
        private var summary: DuplicateSummary?
        private var developerTools: Bool?
        var newestSnapshot: String??
        private var devices: SimulatorList??
        private var runtimes: [String: SimulatorRuntime]??

        init(cleaner: Cleaner, items: [CleanItem]) {
            self.cleaner = cleaner
            let going = items.filter { $0.removal == .trash }.flatMap(\.paths)
            removing = Set(going)
            dependents = CleanDependents.Context(home: cleaner.home, going: going)
            exclusionsReal = cleaner.exclusions.compactMap(CleanPathRules.realPath)
        }

        func alreadyRemoved(_ path: String) -> Bool {
            removed.contains(path) || removed.contains { path.hasPrefix($0 + "/") }
        }

        /// What is running, looked at again once the last look is a few seconds old.
        var processes: ProcessUse {
            let now = cleaner.guards.now()
            if let use, now.timeIntervalSince(useTaken) < Cleaner.useLifetime { return use }
            let fresh = cleaner.guards.processUse()
            use = fresh
            useTaken = now
            return fresh
        }

        /// Excluded by the path as saved or by where it really is, so a link or a change of case does not get past it.
        func isExcluded(_ path: String) -> Bool {
            if CleanScanContext(excluded: cleaner.exclusions).isExcluded(path) { return true }
            guard let real = CleanPathRules.realPath(path) else { return false }
            return exclusionsReal.contains { real == $0 || real.hasPrefix($0 + "/") }
        }

        func holdsExclusion(_ path: String) -> Bool {
            if cleaner.exclusions.contains(where: { $0.hasPrefix(path + "/") }) { return true }
            guard let real = CleanPathRules.realPath(path) else { return false }
            return exclusionsReal.contains { $0.hasPrefix(real + "/") }
        }

        var duplicates: DuplicateSummary {
            if let summary { return summary }
            let fresh = cleaner.guards.duplicates()
            summary = fresh
            return fresh
        }

        var hasDeveloperTools: Bool {
            if let developerTools { return developerTools }
            let fresh = cleaner.guards.developerTools()
            developerTools = fresh
            return fresh
        }

        var simulators: SimulatorList? {
            if let devices { return devices }
            let result = cleaner.guards.runTool(CleanTools.xcrun, ["simctl", "list", "devices", "-j"])
            let list = result.status == 0 ? SimulatorList(json: result.output) : nil
            devices = .some(list)
            return list
        }

        var simulatorRuntimes: [String: SimulatorRuntime]? {
            if let runtimes { return runtimes }
            let result = cleaner.guards.runTool(CleanTools.xcrun, ["simctl", "runtime", "list", "-j"])
            let list = result.status == 0 ? SimulatorRuntime.parse(result.output) : nil
            runtimes = .some(list)
            return list
        }
    }

    /// Why an item must stay, or nil when it may go. Cheap checks come first; git, the
    /// duplicate's other copy and the walk for links come last, and the path is looked at
    /// once more right before it moves.
    func skipReason(_ item: CleanItem, session: Session, isCancelled: () -> Bool = { false }) -> String? {
        if item.paths.contains(where: session.isExcluded) { return "You excluded it" }
        if item.paths.contains(where: session.holdsExclusion) { return "It holds something you excluded" }
        if let owner = item.ownerBundleID, session.processes.runningBundleIDs.contains(owner) { return "Its app is open. Quit it and clean again" }

        guard item.removal == .trash else {
            return Self.badIdentifier(item.removal) ?? permanentReason(item, session: session)
        }
        let use = session.processes
        let existing = item.paths.filter(Self.exists)
        if existing.isEmpty { return "It is already gone" }
        for path in existing {
            if let reason = placeReason(path, tab: item.tab) { return reason }
        }
        for path in existing {
            if let reason = Self.changeReason(path, in: item) { return reason }
        }
        for path in existing {
            let real = CleanPathRules.realPath(path) ?? path
            if let reason = mountReason(path, real: real, use: use) { return reason }
            if path.hasSuffix(".app"), use.runningBundlePaths.contains(path) || use.runningBundlePaths.contains(real) {
                return "The app is open. Quit it and clean again"
            }
            if path.hasSuffix(".app"), let id = CleanPathRules.bundleID(at: path), use.runningBundleIDs.contains(id) {
                return "The app is open. Quit it and clean again"
            }
            if let user = use.user(of: real) ?? use.user(of: path) { return "\(user) is using it" }
        }
        let now = guards.now()
        for path in existing {
            let parent = (path as NSString).deletingLastPathComponent
            for folder in [path, parent] where Self.isDirectory(folder) {
                for name in Self.lockfiles {
                    guard let modified = Self.modified(folder + "/" + name) else { continue }
                    if now.timeIntervalSince(modified) < Self.busyWindow { return "Its project is installing packages right now" }
                }
            }
        }
        for path in existing {
            if let reason = gitReason(path, tab: item.tab) { return reason }
        }
        if item.tab == .largeFiles, item.id.hasPrefix(LargeFilesScanner.duplicatePrefix), let path = existing.first,
           let reason = keeperReason(path, session: session, isCancelled: isCancelled) {
            return reason
        }
        // A cache or a vanished app's files that something still runs from are in use. A large
        // file is the owner's own pick, and an uninstall is meant to break what links into the app
        // (VS Code's code command): neither is held back by a link to it.
        if item.tab != .largeFiles, item.tab != .uninstall, let reason = guards.dependent(existing, home, session.dependents) { return reason }
        return nil
    }

    /// Where the path sits: inside the folders Wisp cleans, outside git's own records, and for
    /// an uninstall or leftovers inside the places those can leave files.
    func placeReason(_ path: String, tab: CleanTab) -> String? {
        if let reason = CleanPathRules.refusal(path, home: home) { return reason }
        if path.split(separator: "/").contains(".git") { return "It is part of a git repository's own records" }
        switch tab {
        case .uninstall:
            if !UninstallPlan.mayRemove(path, home: home) { return "An uninstall only removes the app and its files in your Library" }
        case .leftovers:
            if !path.hasPrefix(home + "/Library/") || !UninstallPlan.mayRemove(path, home: home) {
                return "An app's leftovers are only ever in your Library"
            }
        default: break
        }
        return nil
    }

    /// Nil while the path holds what the scan saw. Large files are also held to the size and
    /// date they had: the owner picked them for what was in them.
    static func changeReason(_ path: String, in item: CleanItem) -> String? {
        guard let seen = item.stamps[path] else { return "Wisp has no record of it from a scan. Scan again" }
        guard let now = CleanStamp(path: path), now.same(as: seen, content: item.tab == .largeFiles) else {
            return "It changed since Wisp scanned it. Scan again to see it as it is now"
        }
        return nil
    }

    /// A volume mounted at or inside the path moves with its folder and can no longer be
    /// ejected, and emptying the Trash would erase what is on it.
    func mountReason(_ path: String, real: String, use: ProcessUse) -> String? {
        if let mount = use.mount(inside: real) ?? use.mount(inside: path) {
            return mount == real || mount == path ? "It is a disk of its own. Eject it instead"
                : "A disk is mounted inside it at \(Self.display(mount, home: home)). Eject it first"
        }
        if let image = use.diskImage(inside: real) {
            let name = image.mount.isEmpty ? "" : " as \((image.mount as NSString).lastPathComponent)"
            return image.image == real ? "It is mounted\(name). Eject it first"
                : "It holds a disk image that is mounted\(name). Eject it first"
        }
        if use.diskImages == nil, Self.diskImageExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return "Wisp could not check whether it is mounted"
        }
        return nil
    }

    /// A repository's own history is never Wisp's to remove; a worktree goes only without
    /// uncommitted changes; and a cache or build folder that git tracks files in is part of the project.
    func gitReason(_ path: String, tab: CleanTab) -> String? {
        let git = path + "/.git"
        if Self.isDirectory(git) { return "It is a git repository. Remove it yourself if you mean to" }
        if Self.exists(git) {
            switch guards.gitState(path) {
            case .clean: return nil
            case .uncommitted: return "It has changes that are not committed"
            case .unknown: return "Wisp could not check it for uncommitted changes"
            }
        }
        guard tab == .junk || tab == .developer, let repository = Self.repository(holding: path, home: home) else { return nil }
        switch guards.gitTracks(repository, path) {
        case .some(false): return nil
        case .some(true): return "Git tracks files in it, so it is part of the project, not something a build makes again"
        case nil: return "Wisp could not check it with git"
        }
    }

    /// For a duplicate copy: another copy that stays must still be there and still be the same,
    /// compared byte for byte now, or this copy may be the last one.
    func keeperReason(_ path: String, session: Session, isCancelled: () -> Bool) -> String? {
        guard let group = session.duplicates.groups.first(where: { $0.paths.contains(path) }) else {
            return "Wisp no longer has its other copies on record. Scan Large Files again"
        }
        for other in group.paths where other != path && !session.removing.contains(other) {
            if Self.sameContent(path, other, isCancelled: isCancelled) { return nil }
        }
        return isCancelled() ? "Cleaning stopped before it got here" : "No other copy is left as it was, so this may be the last one"
    }

    /// Checks a tool's removal against what the tool says now: a simulator that has started
    /// since the scan, or a runtime a new simulator uses, stays. Only that tool can remove
    /// these, and it removes them for good.
    func permanentReason(_ item: CleanItem, session: Session) -> String? {
        switch item.removal {
        case .trash, .localSnapshot:
            return nil
        case .simulator(let udid):
            guard session.hasDeveloperTools else { return "Xcode is not installed" }
            guard let list = session.simulators else { return "simctl did not say whether it is in use" }
            guard let device = list.devices[udid.uppercased()] else { return "It is already gone" }
            if device.isAvailable, device.state != "Shutdown" { return "It is running. Shut it down and clean again" }
            return nil
        case .simulatorRuntime(let identifier):
            guard session.hasDeveloperTools else { return "Xcode is not installed" }
            guard let runtimes = session.simulatorRuntimes, let list = session.simulators else { return "simctl did not say whether it is in use" }
            guard let runtime = runtimes[identifier.uppercased()] else { return "It is already gone" }
            if runtime.deletable == false { return "macOS keeps it" }
            if let id = runtime.runtimeIdentifier, list.usedRuntimes.contains(id) { return "A simulator uses it now" }
            return nil
        case .brewCask:
            for path in item.paths where Self.exists(path) {
                if let reason = placeReason(path, tab: .uninstall) ?? Self.changeReason(path, in: item) { return reason }
                if session.processes.runningBundlePaths.contains(path) { return "The app is open. Quit it and clean again" }
            }
            return nil
        }
    }

    private func remove(_ item: CleanItem, session: Session) -> CleanResult {
        switch item.removal {
        case .trash:
            var moved = 0
            for path in item.paths where Self.exists(path) {
                // The checks above can take a while; what moves is what was checked.
                if let reason = Self.changeReason(path, in: item) {
                    let outcome: CleanOutcome = moved == 0 ? .skipped(reason) : .failed("Moved \(moved) of \(item.paths.count) to the Trash. " + reason)
                    return CleanResult(item: item, outcome: outcome)
                }
                let repository = Self.worktreeRepository(path)
                let recorded = repository == nil ? nil : Self.worktreeRecord(path)
                do {
                    try guards.trash(path)
                    moved += 1
                    if let repository { forget(worktree: path, recorded: recorded, in: repository) }
                } catch {
                    // Gone already, by another clean or the app that owns it: nothing of it is left to move.
                    if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileNoSuchFileError { continue }
                    let reason = moved == 0 ? "It could not be moved to the Trash" : "Moved \(moved) of \(item.paths.count) to the Trash, then one failed"
                    return CleanResult(item: item, outcome: .failed(reason))
                }
            }
            if moved == 0 { return CleanResult(item: item, outcome: .skipped("It is already gone")) }
            return CleanResult(item: item, outcome: .removed, bytesFreed: item.bytes)
        case .simulator(let udid):
            return runTool(item, CleanTools.xcrun, ["simctl", "delete", udid])
        case .simulatorRuntime(let identifier):
            return runTool(item, CleanTools.xcrun, ["simctl", "runtime", "delete", identifier])
        case .localSnapshot(let date):
            if session.newestSnapshot == nil { session.newestSnapshot = .some(newestSnapshot()) }
            guard let newest = session.newestSnapshot ?? nil else { return CleanResult(item: item, outcome: .failed("Time Machine did not list its snapshots")) }
            if date == newest { return CleanResult(item: item, outcome: .skipped("Wisp keeps the newest snapshot")) }
            return runTool(item, CleanTools.tmutil, ["deletelocalsnapshots", date])
        case .brewCask(let token):
            guard let brew = CleanTools.brew else { return CleanResult(item: item, outcome: .skipped("Homebrew is not installed")) }
            return runTool(item, brew, ["uninstall", "--cask", token])
        }
    }

    /// Until git forgets a worktree, its branch counts as checked out and cannot be checked
    /// out elsewhere. `git worktree prune` forgets every worktree whose folder is missing,
    /// including one on a disk that is not plugged in, which loses its index and HEAD; so it
    /// runs only when this worktree is the one missing.
    private func forget(worktree: String, recorded: String?, in repository: String) {
        guard let git = CleanTools.git else { return }
        let list = guards.runTool(git, ["-C", repository, "worktree", "list", "--porcelain", "-z"])
        guard list.status == 0 else { return }
        let ours = Set([worktree, recorded].compactMap { $0 })
        let prunable = Self.prunableWorktrees(list.output)
        guard !prunable.isEmpty, prunable.allSatisfy(ours.contains) else { return }
        _ = guards.runTool(git, ["-C", repository, "worktree", "prune"])
    }

    private func runTool(_ item: CleanItem, _ tool: String, _ arguments: [String]) -> CleanResult {
        let result = guards.runTool(tool, arguments)
        guard result.status == 0 else {
            let last = result.output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let name = (tool as NSString).lastPathComponent
            return CleanResult(item: item, outcome: .failed(last.isEmpty ? "\(name) stopped with status \(result.status)" : String(last.prefix(160))))
        }
        return CleanResult(item: item, outcome: .removed, bytesFreed: item.bytes)
    }

    /// The newest local snapshot's date as tmutil names it ("2026-11-04-101500"), which Wisp never deletes.
    private func newestSnapshot() -> String? {
        let result = guards.runTool(CleanTools.tmutil, ["listlocalsnapshotdates", "/"])
        guard result.status == 0 else { return nil }
        let dates = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isSnapshotDate)
        return dates.max() ?? ""
    }

    /// Identifiers go to a tool as one argument each; anything that does not look like one is
    /// refused. simctl reads words too ("all", "unavailable", a device's name), so simulators
    /// and runtimes are taken only by their UUID.
    static func badIdentifier(_ removal: CleanRemoval) -> String? {
        let ok: Bool
        switch removal {
        case .trash: return nil
        case .simulator(let udid): ok = UUID(uuidString: udid) != nil
        case .simulatorRuntime(let identifier): ok = UUID(uuidString: identifier) != nil
        case .localSnapshot(let date): ok = isSnapshotDate(date)
        case .brewCask(let token):
            ok = !token.isEmpty && !token.hasPrefix("-") && token.allSatisfy { ($0.isLowercase || $0.isNumber || "@._+-".contains($0)) && $0.isASCII }
        }
        return ok ? nil : "Its name does not look right, so Wisp left it alone"
    }

    /// The repository a linked worktree belongs to, read from its `.git` file; nil for anything else.
    static func worktreeRepository(_ path: String) -> String? {
        guard !isDirectory(path + "/.git"), let gitdir = WorktreeScanner.gitdir(path) else { return nil }
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }

    /// Where the worktree's repository thinks it is, from the repository's own record of it.
    static func worktreeRecord(_ path: String) -> String? {
        guard let gitdir = WorktreeScanner.gitdir(path),
              let text = try? String(contentsOfFile: gitdir + "/gitdir", encoding: .utf8) else { return nil }
        let file = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return file.hasSuffix("/.git") ? String(file.dropLast(5)) : nil
    }

    /// Paths of the worktrees `git worktree list --porcelain -z` marks prunable.
    static func prunableWorktrees(_ output: String) -> [String] {
        var prunable: [String] = []
        var current: String?
        var marked = false
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let current, marked { prunable.append(current) }
                current = nil
                marked = false
            } else if field.hasPrefix("worktree ") {
                current = String(field.dropFirst("worktree ".count))
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                marked = true
            }
        }
        if let current, marked { prunable.append(current) }
        return prunable
    }

    /// The nearest folder above `path`, the home folder included, that holds a `.git`.
    static func repository(holding path: String, home: String) -> String? {
        let real = CleanPathRules.realPath(path) ?? path
        let top = CleanPathRules.realPath(home) ?? home
        var folder = (real as NSString).deletingLastPathComponent
        while folder.hasPrefix(top + "/") || folder == top {
            if exists(folder + "/.git") { return folder }
            if folder == top { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Two regular files with the same bytes, read without filling the cache and without
    /// downloading one whose contents are only in iCloud. A hard link to the same file counts.
    static func sameContent(_ first: String, _ second: String, isCancelled: () -> Bool) -> Bool {
        var a = stat(), b = stat()
        guard lstat(first, &a) == 0, lstat(second, &b) == 0, a.st_mode & S_IFMT == S_IFREG, b.st_mode & S_IFMT == S_IFREG,
              a.st_size == b.st_size, a.st_flags & UInt32(SF_DATALESS) == 0, b.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
        if a.st_dev == b.st_dev, a.st_ino == b.st_ino { return true }
        let left = open(first, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), right = open(second, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer {
            if left >= 0 { close(left) }
            if right >= 0 { close(right) }
        }
        guard left >= 0, right >= 0 else { return false }
        _ = fcntl(left, F_NOCACHE, 1)
        _ = fcntl(right, F_NOCACHE, 1)
        let chunk = 1 << 20
        var one = [UInt8](repeating: 0, count: chunk), two = [UInt8](repeating: 0, count: chunk)
        while true {
            if isCancelled() { return false }
            let count = one.withUnsafeMutableBytes { read(left, $0.baseAddress!, chunk) }
            guard count >= 0 else { return false }
            // Both end together, or one changed while it was read.
            if count == 0 { return two.withUnsafeMutableBytes { read(right, $0.baseAddress!, 1) } == 0 }
            var filled = 0
            while filled < count {
                let more = two.withUnsafeMutableBytes { read(right, $0.baseAddress! + filled, count - filled) }
                guard more > 0 else { return false }
                filled += more
            }
            if memcmp(one, two, count) != 0 { return false }
        }
    }

    /// "~/Library/Caches/foo", from the path as given or as the kernel names it.
    private static func display(_ path: String, home: String) -> String {
        for prefix in [home, CleanPathRules.realPath(home) ?? home] where path.hasPrefix(prefix + "/") { return "~" + path.dropFirst(prefix.count) }
        return path
    }

    static func isSnapshotDate(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}

/// The simulators simctl lists, for checking one again right before it is deleted.
struct SimulatorList {
    struct Device {
        var state: String
        var isAvailable: Bool
    }

    /// By UDID, uppercased.
    var devices: [String: Device] = [:]
    /// Runtime identifiers at least one simulator is made with.
    var usedRuntimes: Set<String> = []

    init?(json: String) {
        struct List: Decodable {
            struct Entry: Decodable {
                var udid: String
                var state: String?
                var isAvailable: Bool?
            }
            var devices: [String: [Entry]]
        }
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"),
              let list = try? JSONDecoder().decode(List.self, from: Data(json[start...end].utf8)) else { return nil }
        for (runtime, entries) in list.devices where !entries.isEmpty {
            usedRuntimes.insert(runtime)
            for entry in entries {
                devices[entry.udid.uppercased()] = Device(state: entry.state ?? "", isAvailable: entry.isAvailable ?? true)
            }
        }
    }
}

/// One runtime image simctl lists.
struct SimulatorRuntime: Decodable {
    var identifier: String?
    var runtimeIdentifier: String?
    var deletable: Bool?

    /// By image identifier, uppercased.
    static func parse(_ json: String) -> [String: SimulatorRuntime]? {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"),
              let list = try? JSONDecoder().decode([String: SimulatorRuntime].self, from: Data(json[start...end].utf8)) else { return nil }
        var byID: [String: SimulatorRuntime] = [:]
        for (key, runtime) in list {
            byID[key.uppercased()] = runtime
            if let identifier = runtime.identifier { byID[identifier.uppercased()] = runtime }
        }
        return byID
    }
}

/// An exclusive lock on a file, held while one clean runs. The kernel lets go if the process ends.
final class CleanLock {
    enum Taken { case held(CleanLock), busy, unavailable }

    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Waits up to `wait` for a clean already running to finish. A lock file that cannot be
    /// opened leaves the clean to its other checks.
    static func take(_ path: String, wait: TimeInterval, isCancelled: () -> Bool) -> Taken {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if isCancelled() || Date() >= deadline {
                close(fd)
                return .busy
            }
            usleep(100_000)
        }
        return .held(CleanLock(fd: fd))
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
