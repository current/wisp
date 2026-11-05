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

/// Who is using what right now: the working folder and open files of every process Wisp
/// can read, and the apps that are running. Taken once at the start of a clean.
public struct ProcessUse: Sendable {
    /// Sorted by path, so finding a path and everything under it is a binary search.
    private var paths: [String] = []
    private var names: [String] = []
    public var runningBundleIDs: Set<String> = []
    public var runningBundlePaths: Set<String> = []

    public init(entries: [(name: String, path: String)] = [], runningBundleIDs: Set<String> = [], runningBundlePaths: Set<String> = []) {
        let sorted = entries.sorted { $0.path < $1.path }
        paths = sorted.map(\.path)
        names = sorted.map(\.name)
        self.runningBundleIDs = runningBundleIDs
        self.runningBundlePaths = runningBundlePaths
    }

    /// The name of a process working in `path` or holding a file at or under it.
    public func user(of path: String) -> String? {
        if let index = lowerBound(path), index < paths.count, paths[index] == path { return names[index] }
        let folder = path.hasSuffix("/") ? path : path + "/"
        if let index = lowerBound(folder), index < paths.count, paths[index].hasPrefix(folder) { return names[index] }
        return nil
    }

    private func lowerBound(_ key: String) -> Int? {
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Reads every process once: `proc_listpids`, then per process its name, working folder,
    /// open vnodes and executable. Processes of other users fail quietly and are left out.
    public static func snapshot(excluding own: Int32 = getpid()) -> ProcessUse {
        var pids = [Int32](repeating: 0, count: 4096)
        var count = 0
        while true {
            let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
            count = Int(bytes) / MemoryLayout<Int32>.stride
            if count < pids.count - 16 { break }
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
        var entries: [(name: String, path: String)] = []
        var bundles: Set<String> = []
        var nameBuffer = [CChar](repeating: 0, count: 256)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var fdInfo = vnode_fdinfowithpath()
        let fdInfoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for pid in pids.prefix(count) where pid > 0 && pid != own {
            let name: String = nameBuffer.withUnsafeMutableBufferPointer { buffer in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count)) > 0 ? String(cString: buffer.baseAddress!) : "pid \(pid)"
            }
            if let cwd = ProcessDetails.workingDirectory(pid: pid), cwd != "/" { entries.append((name, cwd)) }
            let executable: String? = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)) > 0 ? String(cString: buffer.baseAddress!) : nil
            }
            if let executable, let range = executable.range(of: ".app/") {
                bundles.insert(String(executable[..<range.lowerBound]) + ".app")
            }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
            let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard filled > 0 else { continue }
            for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &fdInfo, fdInfoSize) == fdInfoSize else { continue }
                let path = withUnsafeBytes(of: fdInfo.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if path.hasPrefix("/Users/") || path.hasPrefix("/Applications/") { entries.append((name, path)) }
            }
        }
        var ids: Set<String> = []
        for bundle in bundles {
            if let id = CleanPathRules.bundleID(at: bundle) { ids.insert(id) }
        }
        return ProcessUse(entries: entries, runningBundleIDs: ids, runningBundlePaths: bundles)
    }
}

/// The checks a clean makes before it touches anything, and the calls it makes to remove
/// things. The live ones read the real Mac; tests put fakes in their place.
public struct CleanGuards: Sendable {
    public enum GitState: Sendable { case clean, uncommitted, unknown }

    public var processUse: @Sendable () -> ProcessUse
    /// Asked only for folders that hold a `.git`.
    public var gitState: @Sendable (String) -> GitState
    /// Runs a tool and returns its exit status and what it printed.
    public var runTool: @Sendable (_ path: String, _ arguments: [String]) -> (status: Int32, output: String)
    public var trash: @Sendable (String) throws -> Void
    /// Whether xcrun has developer tools behind it. Without them it offers to install them,
    /// which puts a window on screen, so simctl is not run.
    public var developerTools: @Sendable () -> Bool
    public var now: @Sendable () -> Date

    public init(processUse: @escaping @Sendable () -> ProcessUse, gitState: @escaping @Sendable (String) -> GitState,
                runTool: @escaping @Sendable (String, [String]) -> (status: Int32, output: String),
                trash: @escaping @Sendable (String) throws -> Void, developerTools: @escaping @Sendable () -> Bool = { CleanGuards.developerToolsInstalled() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.processUse = processUse
        self.gitState = gitState
        self.runTool = runTool
        self.trash = trash
        self.developerTools = developerTools
        self.now = now
    }

    public static func developerToolsInstalled() -> Bool { CleanTools.hasDeveloperTools }

    public static let live = CleanGuards(
        processUse: { ProcessUse.snapshot() },
        gitState: { path in
            // /usr/bin/git is a shim that offers to install the developer tools when they are
            // missing, which would put a window on screen. Only a real git is run.
            guard let git = CleanTools.git else { return .unknown }
            let result = CleanTools.run(git, ["-C", path, "status", "--porcelain"], timeout: 20)
            guard result.status == 0 else { return .unknown }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clean : .uncommitted
        },
        runTool: { CleanTools.run($0, $1, timeout: 300) },
        trash: { path in try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
    )
}

/// Where the tools a clean may call live. Nothing is found through PATH.
enum CleanTools {
    static let xcrun = "/usr/bin/xcrun"
    static let tmutil = "/usr/bin/tmutil"

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
    /// Inside home, these are never touched, whatever a scanner says.
    static let protectedInHome = ["Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
                                  "Library/Messages", "Library/Accounts", ".ssh", ".gnupg", ".Trash"]

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
            if protectedInHome.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return "Wisp never touches it" }
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

    /// Package managers write these while they install; a project with one this fresh is busy.
    static let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "Cargo.lock",
                            "Podfile.lock", "Package.resolved", "poetry.lock", "uv.lock", "Gemfile.lock", "composer.lock"]
    static let busyWindow: TimeInterval = 120

    public init(home: String = NSHomeDirectory(), exclusions: [String] = [], guards: CleanGuards = .live) {
        self.home = home
        self.exclusions = exclusions
        self.guards = guards
    }

    public func clean(_ items: [CleanItem], isCancelled: () -> Bool = { false },
                      progress: (CleanResult) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        guard !items.isEmpty else { return report }
        if let refusal = CleanRegistry.selectionRefusal(items, checks: selectionChecks) {
            report.results = items.map { CleanResult(item: $0, outcome: .skipped(refusal)) }
            report.results.forEach(progress)
            return report
        }
        let use = guards.processUse()
        // Two rows can name the same file (a large file that is also a duplicate copy).
        // Each path goes once; a row whose paths all went with an earlier one counts as removed, with nothing more freed.
        var removedPaths = Set<String>()
        func alreadyRemoved(_ path: String) -> Bool {
            removedPaths.contains(path) || removedPaths.contains { path.hasPrefix($0 + "/") }
        }
        var newestSnapshot: String??
        for item in items {
            let result: CleanResult
            if isCancelled() {
                result = CleanResult(item: item, outcome: .skipped("Cleaning stopped before it got here"))
            } else if item.removal == .trash, !item.paths.isEmpty, item.paths.allSatisfy(alreadyRemoved) {
                result = CleanResult(item: item, outcome: .removed)
            } else if let reason = skipReason(item, use: use) {
                result = CleanResult(item: item, outcome: .skipped(reason))
            } else {
                if case .localSnapshot = item.removal, newestSnapshot == nil { newestSnapshot = .some(self.newestSnapshot()) }
                var pending = item
                var listed = Set<String>()
                pending.paths = item.paths.filter { !alreadyRemoved($0) && listed.insert($0).inserted }
                var removed = remove(pending, newestSnapshot: newestSnapshot ?? nil)
                if removed.outcome.removed, item.removal == .trash { removedPaths.formUnion(pending.paths) }
                removed.item = item
                result = removed
            }
            report.results.append(result)
            progress(result)
        }
        return report
    }

    /// Why an item must stay, or nil when it may go.
    func skipReason(_ item: CleanItem, use: ProcessUse) -> String? {
        let context = CleanScanContext(excluded: exclusions)
        if item.paths.contains(where: context.isExcluded) { return "You excluded it" }
        if item.paths.contains(where: { path in exclusions.contains { $0.hasPrefix(path + "/") } }) { return "It holds something you excluded" }
        if let owner = item.ownerBundleID, use.runningBundleIDs.contains(owner) { return "Its app is open. Quit it and clean again" }

        guard item.removal == .trash else {
            return Self.badIdentifier(item.removal)
        }
        let existing = item.paths.filter(Self.exists)
        if existing.isEmpty { return "It is already gone" }
        for path in existing {
            if let reason = CleanPathRules.refusal(path, home: home) { return reason }
        }
        for path in existing {
            if path.hasSuffix(".app"), use.runningBundlePaths.contains(path) { return "The app is open. Quit it and clean again" }
            if path.hasSuffix(".app"), let id = CleanPathRules.bundleID(at: path), use.runningBundleIDs.contains(id) {
                return "The app is open. Quit it and clean again"
            }
            if let user = use.user(of: path) { return "\(user) is using it" }
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
        for path in existing where Self.exists(path + "/.git") {
            switch guards.gitState(path) {
            case .clean: continue
            case .uncommitted: return "It has changes that are not committed"
            case .unknown: return "Wisp could not check it for uncommitted changes"
            }
        }
        return nil
    }

    private func remove(_ item: CleanItem, newestSnapshot: String?) -> CleanResult {
        switch item.removal {
        case .trash:
            let existing = item.paths.filter(Self.exists)
            var moved = 0
            for path in existing {
                do {
                    try guards.trash(path)
                    moved += 1
                } catch {
                    let reason = moved == 0 ? "It could not be moved to the Trash" : "Moved \(moved) of \(existing.count) to the Trash, then one failed"
                    return CleanResult(item: item, outcome: .failed(reason))
                }
            }
            return CleanResult(item: item, outcome: .removed, bytesFreed: item.bytes)
        case .simulator(let udid):
            guard guards.developerTools() else { return CleanResult(item: item, outcome: .skipped("Xcode is not installed")) }
            return runTool(item, CleanTools.xcrun, ["simctl", "delete", udid])
        case .simulatorRuntime(let identifier):
            guard guards.developerTools() else { return CleanResult(item: item, outcome: .skipped("Xcode is not installed")) }
            return runTool(item, CleanTools.xcrun, ["simctl", "runtime", "delete", identifier])
        case .localSnapshot(let date):
            guard let newestSnapshot else { return CleanResult(item: item, outcome: .failed("Time Machine did not list its snapshots")) }
            if date == newestSnapshot { return CleanResult(item: item, outcome: .skipped("Wisp keeps the newest snapshot")) }
            return runTool(item, CleanTools.tmutil, ["deletelocalsnapshots", date])
        case .brewCask(let token):
            guard let brew = CleanTools.brew else { return CleanResult(item: item, outcome: .skipped("Homebrew is not installed")) }
            return runTool(item, brew, ["uninstall", "--cask", token])
        }
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

    /// Identifiers go to a tool as one argument each; anything that does not look like one is refused.
    static func badIdentifier(_ removal: CleanRemoval) -> String? {
        let ok: Bool
        switch removal {
        case .trash: return nil
        case .simulator(let udid): ok = UUID(uuidString: udid) != nil
        case .simulatorRuntime(let identifier):
            ok = !identifier.isEmpty && !identifier.hasPrefix("-") && identifier.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
        case .localSnapshot(let date): ok = isSnapshotDate(date)
        case .brewCask(let token):
            ok = !token.isEmpty && !token.hasPrefix("-") && token.allSatisfy { ($0.isLowercase || $0.isNumber || "@._+-".contains($0)) && $0.isASCII }
        }
        return ok ? nil : "Its name does not look right, so Wisp left it alone"
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
