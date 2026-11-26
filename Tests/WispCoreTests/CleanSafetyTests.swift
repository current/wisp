import Darwin
import Foundation
import Testing
@testable import WispCore

/// Each test builds an unsafe case in its own temporary folder and shows that a clean leaves
/// it. The Trash is the fake from `CleanerTests`, which deletes inside that folder only. Git,
/// where a test needs it, is the real one, run on a repository made there with the owner's
/// git configuration switched off.
@Suite struct CleanSafetyTests {
    typealias Scratch = CleanerTests.Scratch
    typealias Fakes = CleanerTests.Fakes

    /// Stamped as a scan stamps what it finds.
    func item(_ paths: [String], tab: CleanTab = .junk, id: String? = nil, removal: CleanRemoval = .trash,
              safety: CleanSafety = .safe) -> CleanItem {
        CleanItem(id: id ?? "test:" + (paths.first ?? "none"), tab: tab, group: "Test", name: "Test item", detail: "A test.",
                  paths: paths, bytes: 1000, safety: safety, removal: removal).stamped()
    }

    /// Where a path really is, as the kernel names it.
    func real(_ path: String) -> String { CleanPathRules.realPath(path) ?? path }

    func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Git with no global or system configuration, so no signing, hooks or templates of the owner's run.
    @discardableResult
    static func git(_ arguments: [String], in folder: String) -> Int32 {
        guard let git = CleanTools.git else { return 127 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        for name in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { environment[name] = "Test" }
        for name in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { environment[name] = "test@example.com" }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 126 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    // MARK: Mounted disks

    @Test func aMountedDiskImageStaysAndSoDoesAFolderHoldingOne() {
        let scratch = Scratch()
        let image = scratch.make("Downloads/helium.dmg", file: true)
        let cache = scratch.make("Library/Caches/com.example.app")
        let inner = scratch.make("Library/Caches/com.example.app/stage.dmg", file: true)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        // Finder mounts a download through diskimagesiod, a system process: no open file of the owner's shows it.
        fakes.use = ProcessUse(diskImages: [real(image): "/Volumes/Helium", real(inner): ""])
        #expect(cleaner.clean([item([image], tab: .largeFiles)]).results[0].outcome == .skipped("It is mounted as Helium. Eject it first"))
        #expect(cleaner.clean([item([cache])]).results[0].outcome == .skipped("It holds a disk image that is mounted. Eject it first"))
        fakes.use = ProcessUse(diskImages: nil)
        #expect(cleaner.clean([item([image], tab: .largeFiles)]).results[0].outcome == .skipped("Wisp could not check whether it is mounted"))
        #expect(fakes.trashed.isEmpty)
        fakes.use = ProcessUse()
        #expect(cleaner.clean([item([image], tab: .largeFiles)]).results[0].outcome == .removed)
        #expect(fakes.trashed == [image])
    }

    @Test func aDiskMountedInsideAFolderKeepsItThere() {
        let scratch = Scratch()
        let cache = scratch.make("Library/Caches/com.example.app")
        let volume = scratch.make("Library/Caches/com.example.app/volume")
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        // Renaming a folder moves a volume mounted inside it into the Trash, where it can no longer be ejected.
        fakes.use = ProcessUse(mountPoints: ["/", real(volume)])
        #expect(cleaner.clean([item([cache])]).results[0].outcome
            == .skipped("A disk is mounted inside it at ~/Library/Caches/com.example.app/volume. Eject it first"))
        #expect(cleaner.clean([item([volume])]).results[0].outcome == .skipped("It is a disk of its own. Eject it instead"))
        #expect(fakes.trashed.isEmpty)
    }

    @Test func hdiutilsListOfImagesIsRead() {
        let plist = """
            hdiutil: a warning first
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>images</key><array>
            <dict><key>image-path</key><string>/nowhere/helium.dmg</string><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
            <dict><key>dev-entry</key><string>/dev/disk9s1</string><key>mount-point</key><string>/Volumes/Helium</string></dict>
            </array></dict>
            <dict><key>image-path</key><string>/nowhere/attached.dmg</string><key>system-entities</key><array/></dict>
            </array></dict></plist>
            """
        #expect(ProcessUse.parseImages(plist) == ["/nowhere/helium.dmg": "/Volumes/Helium", "/nowhere/attached.dmg": ""])
        #expect(ProcessUse.parseImages("hdiutil: no plist here") == nil)
    }

    // MARK: Changed since the scan

    @Test func whatTookAPathsPlaceSinceTheScanStays() throws {
        let scratch = Scratch()
        let cache = scratch.make("Library/Caches/com.example.app")
        let scanned = item([cache])
        try FileManager.default.removeItem(atPath: cache)
        scratch.make("Library/Caches/com.example.app")
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        let changed = CleanOutcome.skipped("It changed since Wisp scanned it. Scan again to see it as it is now")
        #expect(cleaner.clean([scanned]).results[0].outcome == changed)

        var unscanned = scanned
        unscanned.stamps = [:]
        #expect(cleaner.clean([unscanned]).results[0].outcome == .skipped("Wisp has no record of it from a scan. Scan again"))

        // A large file rewritten in place is held to what the owner saw; a log that grew is still a log.
        let movie = scratch.make("Movies/cut.mov", file: true)
        let log = scratch.make("Library/Logs/app.log", file: true)
        let movieRow = item([movie], tab: .largeFiles, safety: .checkFirst), logRow = item([log])
        Thread.sleep(forTimeInterval: 0.01)
        for path in [movie, log] {
            let handle = try #require(FileHandle(forWritingAtPath: path))
            handle.seekToEndOfFile()
            handle.write(Data("more".utf8))
            try handle.close()
        }
        #expect(cleaner.clean([movieRow]).results[0].outcome == changed)
        #expect(cleaner.clean([logRow]).results[0].outcome == .removed)
        #expect(fakes.trashed == [log])
    }

    @Test func aPathSwappedWhileTheChecksRunStays() {
        let scratch = Scratch()
        let cache = scratch.make("Library/Caches/com.example.app")
        let fakes = Fakes(scratch)
        var guards = fakes.guards
        // The walk for links is the last and slowest check; something replaces the folder meanwhile.
        guards.dependent = { paths, _, _ in
            try? FileManager.default.removeItem(atPath: paths[0])
            try? FileManager.default.createDirectory(atPath: paths[0], withIntermediateDirectories: true)
            return nil
        }
        let report = Cleaner(home: scratch.home, guards: guards).clean([item([cache])])
        #expect(report.results[0].outcome == .skipped("It changed since Wisp scanned it. Scan again to see it as it is now"))
        #expect(fakes.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: cache))
    }

    @Test func aScanStampsAPathTheFirstTimeItSeesIt() {
        struct Replacing: CleanScanner {
            let path: String
            var tab: CleanTab { .junk }
            func scan(_ context: CleanScanContext) -> [CleanItem] {
                let row = CleanItem(id: "row", tab: .junk, group: "G", name: "Row", detail: "", paths: [path], bytes: 1, safety: .safe)
                context.found([row])
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                return [row]
            }
        }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [CleanItem] = []
        }
        let scratch = Scratch()
        let cache = scratch.make("Library/Caches/com.example.app")
        let streamed = Box()
        let context = CleanScanContext(home: URL(fileURLWithPath: scratch.home), found: { batch in streamed.lock.withLock { streamed.items += batch } })
        let first = CleanStamp(path: cache)
        let items = CleanRegistry.scan([.junk], context: context, using: [Replacing(path: cache)])
        #expect(streamed.items.first?.stamps[cache] == first)
        #expect(items.first?.stamps[cache] == first)
        #expect(CleanStamp(path: cache) != first)
        let fakes = Fakes(scratch)
        #expect(Cleaner(home: scratch.home, guards: fakes.guards).clean(items).results[0].outcome
            == .skipped("It changed since Wisp scanned it. Scan again to see it as it is now"))
    }

    // MARK: Links

    @Test func aLinkGoesAndWhatItPointsToStays() throws {
        let scratch = Scratch()
        let target = scratch.make("Documents/important", file: true)
        let link = scratch.home + "/Library/Caches/com.example.link"
        try FileManager.default.createDirectory(atPath: scratch.home + "/Library/Caches", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let fakes = Fakes(scratch)
        #expect(Cleaner(home: scratch.home, guards: fakes.guards).clean([item([link])]).results[0].outcome == .removed)
        #expect(fakes.trashed == [link])
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test func useIsJudgedByWhereAPathReallyIs() throws {
        let scratch = Scratch()
        let modules = scratch.make("code/web/node_modules")
        try FileManager.default.createSymbolicLink(atPath: scratch.home + "/src", withDestinationPath: scratch.home + "/code")
        let fakes = Fakes(scratch)
        // The kernel names an open file by where it really is, not by the link the scan came through.
        fakes.use = ProcessUse(entries: [("node", real(modules) + "/vite/bin/vite.js")])
        let report = Cleaner(home: scratch.home, guards: fakes.guards).clean([item([scratch.home + "/src/web/node_modules"], tab: .developer)])
        #expect(report.results[0].outcome == .skipped("node is using it"))
        #expect(fakes.trashed.isEmpty)
    }

    @Test func anExclusionHoldsThroughALink() throws {
        let scratch = Scratch()
        let modules = scratch.make("code/keep/node_modules")
        try FileManager.default.createSymbolicLink(atPath: scratch.home + "/src", withDestinationPath: scratch.home + "/code")
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, exclusions: [scratch.home + "/src/keep"], guards: fakes.guards)
        #expect(cleaner.clean([item([modules], tab: .developer)]).results[0].outcome == .skipped("You excluded it"))
        #expect(fakes.trashed.isEmpty)
    }

    // MARK: Git

    @Test func whatGitTracksOrKeepsAsItsOwnStays() throws {
        guard CleanTools.git != nil else { return }
        let scratch = Scratch()
        let repo = scratch.make("src/action")
        Self.git(["init", "-q"], in: repo)
        scratch.make("src/action/package.json", file: true)
        scratch.make("src/action/node_modules/pkg/index.js", file: true)
        scratch.make("src/action/target/debug/out", file: true)
        try write("node_modules/\ntarget/\n", to: repo + "/.gitignore")
        // A JavaScript action commits node_modules on purpose.
        Self.git(["add", "-f", "node_modules/pkg/index.js", ".gitignore", "package.json"], in: repo)
        #expect(Self.git(["commit", "-q", "-m", "init"], in: repo) == 0)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        #expect(cleaner.clean([item([repo + "/node_modules"], tab: .developer)]).results[0].outcome
            == .skipped("Git tracks files in it, so it is part of the project, not something a build makes again"))
        #expect(cleaner.clean([item([repo + "/target"], tab: .developer)]).results[0].outcome == .removed)
        // A repository with its own history, and git's own records, always stay, whatever git status says.
        #expect(cleaner.clean([item([repo], tab: .developer)]).results[0].outcome == .skipped("It is a git repository. Remove it yourself if you mean to"))
        #expect(cleaner.clean([item([repo + "/.git/objects"], tab: .developer)]).results[0].outcome
            == .skipped("It is part of a git repository's own records"))
        #expect(fakes.trashed == [repo + "/target"])
    }

    @Test func checkingAWorktreeLeavesItsIndexAlone() throws {
        guard CleanTools.git != nil else { return }
        let scratch = Scratch()
        let repo = scratch.make("src/repo")
        Self.git(["init", "-q"], in: repo)
        let file = scratch.make("src/repo/README", file: true)
        Self.git(["add", "README"], in: repo)
        #expect(Self.git(["commit", "-q", "-m", "init"], in: repo) == 0)
        // Same bytes, new date: the index's record of the file is stale, and a plain git status rewrites the index.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file)
        let index = repo + "/.git/index"
        let before = CleanStamp(path: index)
        #expect(CleanGuards.liveGitState(repo) == .clean)
        #expect(CleanStamp(path: index) == before)
    }

    @Test func onlyTheWorktreeThatWentIsForgotten() throws {
        guard CleanTools.git != nil else { return }
        let scratch = Scratch()
        let repo = scratch.make("src/repo")
        Self.git(["init", "-q"], in: repo)
        #expect(Self.git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo) == 0)
        let a = scratch.home + "/.t3/worktrees/repo/a", b = scratch.home + "/.t3/worktrees/repo/b"
        #expect(Self.git(["worktree", "add", "-q", a, "-b", "a"], in: repo) == 0)
        #expect(Self.git(["worktree", "add", "-q", b, "-b", "b"], in: repo) == 0)
        let fakes = Fakes(scratch)
        var guards = fakes.guards
        guards.runTool = { CleanTools.run($0, $1, timeout: 30) }
        let cleaner = Cleaner(home: scratch.home, guards: guards)

        // b's disk is not plugged in. git worktree prune would make git forget b too, with its index and HEAD.
        let away = scratch.root + "/unplugged-b"
        try FileManager.default.moveItem(atPath: b, toPath: away)
        #expect(cleaner.clean([item([a], tab: .developer)]).results[0].outcome == .removed)
        #expect(FileManager.default.fileExists(atPath: repo + "/.git/worktrees/b/HEAD"))

        // With b back, a is the only one missing, and git forgets it.
        try FileManager.default.moveItem(atPath: away, toPath: b)
        let c = scratch.home + "/.t3/worktrees/repo/c"
        #expect(Self.git(["worktree", "prune"], in: repo) == 0)
        #expect(Self.git(["worktree", "add", "-q", c, "-b", "c"], in: repo) == 0)
        #expect(cleaner.clean([item([c], tab: .developer)]).results[0].outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: repo + "/.git/worktrees/c"))
        #expect(FileManager.default.fileExists(atPath: repo + "/.git/worktrees/b/HEAD"))
    }

    // MARK: Duplicates

    @Test func aDuplicateGoesOnlyWhileAnIdenticalCopyStays() throws {
        let scratch = Scratch()
        let keep = scratch.make("Documents/trip.mov", file: true), copy = scratch.make("Downloads/trip.mov", file: true)
        var bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: URL(fileURLWithPath: keep))
        try bytes.write(to: URL(fileURLWithPath: copy))
        var summary = DuplicateSummary()
        summary.groups = [DuplicateGroup(id: "dup-1", length: Int64(bytes.count), paths: [keep, copy], reclaimable: Int64(bytes.count))]
        let known = summary
        let fakes = Fakes(scratch)
        var guards = fakes.guards
        guards.duplicates = { known }
        let cleaner = Cleaner(home: scratch.home, guards: guards)
        let row = item([copy], tab: .largeFiles, id: LargeFilesScanner.duplicatePrefix + copy, safety: .checkFirst)
        let last = CleanOutcome.skipped("No other copy is left as it was, so this may be the last one")

        // The copy Wisp keeps was edited after the scan: this one holds the only original.
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: keep))
        #expect(cleaner.clean([row]).results[0].outcome == last)
        try FileManager.default.removeItem(atPath: keep)
        #expect(cleaner.clean([row]).results[0].outcome == last)
        // Both copies ticked in one clean: neither stays, so neither goes.
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: keep))
        let keepRow = item([keep], tab: .largeFiles, id: LargeFilesScanner.largePrefix + keep, safety: .checkFirst)
        var both = cleaner
        both.selectionChecks = []
        #expect(both.clean([keepRow, row]).results[1].outcome == last)
        #expect(fakes.trashed == [keep])
        // Back as it was: the copy may go.
        try bytes.write(to: URL(fileURLWithPath: keep))
        #expect(cleaner.clean([row]).results[0].outcome == .removed)

        var forgotten = guards
        forgotten.duplicates = { DuplicateSummary() }
        let other = scratch.make("Downloads/other.mov", file: true)
        #expect(Cleaner(home: scratch.home, guards: forgotten).clean([item([other], tab: .largeFiles, id: LargeFilesScanner.duplicatePrefix + other)])
            .results[0].outcome == .skipped("Wisp no longer has its other copies on record. Scan Large Files again"))
    }

    // MARK: Tools that remove for good

    @Test func aSimulatorOrRuntimeInUseNowStays() {
        let scratch = Scratch()
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        let udid = "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A", image = "1CE31380-2525-4AA2-9878-679933FF43D3"
        // Started after the scan; and a new simulator now runs on the runtime the scan found unused.
        fakes.simulators = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": "\#(udid)", "state": "Booted", "isAvailable": true}]}}"#
        fakes.runtimes = #"{"\#(image)": {"identifier": "\#(image)", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "deletable": true}}"#
        let report = cleaner.clean([
            item([], id: "a", removal: .simulator(udid: udid)),
            item([], id: "b", removal: .simulatorRuntime(identifier: image)),
            // simctl runtime delete all deletes every runtime; simctl takes words as well as UUIDs.
            item([], id: "c", removal: .simulatorRuntime(identifier: "all")),
            item([], id: "d", removal: .simulator(udid: "5D1E2F3A-0000-4000-8000-000000000000")),
        ])
        #expect(report.results.map(\.outcome) == [
            .skipped("It is running. Shut it down and clean again"), .skipped("A simulator uses it now"),
            .skipped("Its name does not look right, so Wisp left it alone"), .skipped("It is already gone"),
        ])
        #expect(!fakes.tools.contains { $0.contains("delete") })
    }

    @Test func theTrashGetsItsShareBeforeAToolDeletesAnything() {
        let scratch = Scratch()
        let support = scratch.make("Library/Application Support/Steam")
        let fakes = Fakes(scratch)
        let udid = "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A"
        fakes.simulators = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": "\#(udid)", "state": "Shutdown"}]}}"#
        let log = Log()
        var guards = fakes.guards
        let trash = guards.trash, tool = guards.runTool
        guards.trash = { log.add("trash"); try trash($0) }
        guards.runTool = { path, arguments in
            if arguments.contains("delete") { log.add("delete") }
            return tool(path, arguments)
        }
        let report = Cleaner(home: scratch.home, guards: guards).clean([item([], id: "tool", removal: .simulator(udid: udid)), item([support], id: "trash")])
        #expect(report.results.map(\.item.id) == ["tool", "trash"])
        #expect(report.results.map(\.outcome) == [.removed, .removed])
        #expect(log.all == ["trash", "delete"])
    }

    @Test func aCasksOwnUninstallStepsAreSaidBeforehand() throws {
        let scratch = Scratch()
        let receipt = scratch.root + "/Caskroom/steam/.metadata/INSTALL_RECEIPT.json"
        try FileManager.default.createDirectory(atPath: (receipt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let artifacts: [[String: Any]] = [
            ["uninstall": [["launchctl": ["com.valvesoftware.steam.ipctool", "com.valvesoftware.steamclean"], "quit": "com.valvesoftware.steam",
                            "delete": "~/Library/Application Support/Steam/Steam.AppBundle"]]],
            ["app": ["Steam.app"]],
        ]
        try JSONSerialization.data(withJSONObject: ["uninstall_artifacts": artifacts]).write(to: URL(fileURLWithPath: receipt))
        let app = InstalledApp(path: scratch.root + "/Applications/Steam.app", name: "Steam", bundleID: "com.valvesoftware.steam", version: "4.0",
                               cask: HomebrewCask(token: "steam", apps: ["Steam.app"]))
        let planner = UninstallPlanner(home: scratch.home, installed: [app], fullDiskAccess: true, measure: false, caskrooms: [scratch.root + "/Caskroom"])
        #expect(planner.items(for: app, appRemoval: .homebrew).first?.detail
            == "Homebrew deletes the app, version 4.0 for good with brew uninstall --cask steam. Its cask also deletes ~/Library/Application Support/Steam/Steam.AppBundle and unloads 2 launch agents.")
        #expect(planner.caskSteps("missing") == nil)
    }

    // MARK: Where things may be

    @Test func applesDataAndTheOwnersKeysAreNeverTouched() {
        let scratch = Scratch()
        for relative in ["Library/Application Support/AddressBook/Sources", "Library/Calendars/Calendar Cache", "Library/Safari/History.db",
                         "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", "Library/Containers/com.apple.mail/Data",
                         "Library/Preferences/com.apple.dock.plist", "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Library",
                         "Library/Application Support/MobileSync/Backup", "Library/Application Support/com.apple.TCC",
                         ".aws/credentials", ".config/gh/hosts.yml", ".kube/config"] {
            #expect(CleanPathRules.refusal(scratch.make(relative), home: scratch.home) != nil, "\(relative)")
        }
        // APFS ignores case, so the rules do too.
        scratch.make("Library/Application Support/AddressBook")
        #expect(CleanPathRules.refusal(scratch.home + "/Library/Application Support/addressbook", home: scratch.home) == "Wisp never touches it")
        // Apple's caches and logs are junk like anyone's.
        for relative in ["Library/Caches/com.apple.Safari", "Library/Logs/com.apple.xpc.launchd", "Library/Application Support/com.example.app",
                         "Library/Group Containers/group.com.example.app", ".config/example"] {
            #expect(CleanPathRules.refusal(scratch.make(relative), home: scratch.home) == nil, "\(relative)")
        }
    }

    @Test func uninstallsAndLeftoversStayInTheirFolders() {
        let scratch = Scratch()
        let notes = scratch.make("Documents/notes")
        let cache = scratch.make("Library/Caches/com.example.app")
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        #expect(cleaner.clean([item([notes], tab: .uninstall)]).results[0].outcome
            == .skipped("An uninstall only removes the app and its files in your Library"))
        #expect(cleaner.clean([item([notes], tab: .leftovers)]).results[0].outcome == .skipped("An app's leftovers are only ever in your Library"))
        #expect(cleaner.clean([item([cache], tab: .uninstall)]).results[0].outcome == .removed)
        #expect(fakes.trashed == [cache])
        #expect(!UninstallPlan.mayRemove("/Applications/Suite.app/Contents/Helper.app", home: scratch.home))
        #expect(UninstallPlan.mayRemove(scratch.home + "/Library/Caches/com.example.app", home: scratch.home))
    }

    // MARK: What links in

    @Test func aPnpmStoreProjectsLinkIntoStays() throws {
        let scratch = Scratch()
        let fm = FileManager.default
        let store = scratch.make("Library/pnpm/store")
        let package = scratch.make("Library/pnpm/store/v11/links/@/left-pad/1.3.0/abc/node_modules/left-pad")
        let project = scratch.make("src/app")
        scratch.make("src/app/node_modules")
        // pnpm's global virtual store: the project's packages are links into the store, and the store lists the project.
        try fm.createSymbolicLink(atPath: project + "/node_modules/left-pad", withDestinationPath: package)
        scratch.make("Library/pnpm/store/v11/projects")
        try fm.createSymbolicLink(atPath: store + "/v11/projects/0123abcd", withDestinationPath: project)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        #expect(cleaner.clean([item([store], tab: .developer)]).results[0].outcome == .skipped("The pnpm project in ~/src/app links into it"))
        // Copied or cloned packages are the project's own; then the store may go.
        try fm.removeItem(atPath: project + "/node_modules/left-pad")
        scratch.make("src/app/node_modules/left-pad/index.js", file: true)
        #expect(cleaner.clean([item([store], tab: .developer)]).results[0].outcome == .removed)
    }

    @Test func aProjectsOwnBuildOutputDoesNotKeepItsPackages() throws {
        let scratch = Scratch()
        let fm = FileManager.default
        let modules = scratch.home + "/src/web/node_modules"
        let package = scratch.make("src/web/node_modules/libsql")
        // Next.js links its dev build into node_modules; the next build makes it again.
        let next = scratch.make("src/web/.next/dev/node_modules")
        try fm.createSymbolicLink(atPath: next + "/libsql-ed63c3166a52376f", withDestinationPath: package)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        #expect(cleaner.clean([item([modules], tab: .developer)]).results[0].outcome == .removed)
        // Anything else beside it that links in still keeps it.
        scratch.make("src/web/node_modules/libsql")
        try fm.createSymbolicLink(atPath: scratch.make("src/web/tools") + "/libsql", withDestinationPath: package)
        #expect(cleaner.clean([item([modules], tab: .developer)]).results[0].outcome == .skipped("~/src/web/tools/libsql links into it"))
        // Unless that goes in the same clean.
        let tools = item([scratch.home + "/src/web/tools"], tab: .developer)
        #expect(cleaner.clean([item([modules], tab: .developer), tools]).results.map(\.outcome) == [.removed, .removed])

        // In a monorepo the build output sits deeper, in each app.
        scratch.make("src/mono/package.json", file: true)
        let shared = scratch.make("src/mono/node_modules/libsql")
        let app = scratch.make("src/mono/apps/web/.next/dev/node_modules")
        try fm.createSymbolicLink(atPath: app + "/libsql-0a1b2c3d", withDestinationPath: shared)
        #expect(cleaner.clean([item([scratch.home + "/src/mono/node_modules"], tab: .developer)]).results[0].outcome == .removed)
    }

    @Test func anUninstallIsNotHeldBackByTheAppsOwnCommand() throws {
        let scratch = Scratch()
        let fm = FileManager.default
        let app = scratch.make("Applications/Code.app")
        let tool = scratch.make("Applications/Code.app/Contents/Resources/app/bin/code", file: true)
        let cache = scratch.make("Library/Caches/com.example.tool")
        let bin = scratch.make(".local/bin")
        try fm.createSymbolicLink(atPath: bin + "/code", withDestinationPath: tool)
        try fm.createSymbolicLink(atPath: bin + "/tool", withDestinationPath: cache)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        // Uninstalling VS Code is meant to break its code command; a cache a command runs from is in use.
        #expect(cleaner.clean([item([app], tab: .uninstall, safety: .checkFirst)]).results[0].outcome == .removed)
        #expect(cleaner.clean([item([cache], tab: .developer)]).results[0].outcome == .skipped("tool in ~/.local/bin runs from it"))
    }

    @Test func otherAppsFoldersAreNotReadForLinks() throws {
        let scratch = Scratch()
        let gone = scratch.make("Library/Containers/com.example.gone")
        let other = scratch.make("Library/Containers/com.example.other/Data")
        try FileManager.default.createSymbolicLink(atPath: other + "/link", withDestinationPath: gone)
        // Walking beside a container reads every app's container, which macOS guards and which can hold millions of files.
        #expect(CleanDependents.dependent(of: [gone], home: scratch.home) == nil)
        let movie = scratch.make("Movies/2024/trip.mov", file: true)
        try FileManager.default.createSymbolicLink(atPath: scratch.home + "/Movies/2024/latest.mov", withDestinationPath: movie)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        #expect(cleaner.clean([item([gone], tab: .leftovers, safety: .checkFirst)]).results[0].outcome == .removed)
        // A large file is the owner's own pick; a link to it elsewhere does not keep it.
        #expect(cleaner.clean([item([movie], tab: .largeFiles, safety: .checkFirst)]).results[0].outcome == .removed)
        #expect(fakes.trashed == [gone, movie])
    }

    // MARK: Partial and concurrent cleans

    @Test func somethingAlreadyMovedIsReportedGoneNotFailed() {
        let scratch = Scratch()
        let cache = scratch.make("Library/Caches/com.example.app")
        let inner = scratch.make("Library/Caches/com.example.app/fonts")
        let fakes = Fakes(scratch)
        // One item can name a folder and something inside it; the second is gone with the first.
        #expect(Cleaner(home: scratch.home, guards: fakes.guards).clean([item([cache, inner])]).results[0].outcome == .removed)
        #expect(fakes.trashed == [cache])
        let again = scratch.make("Library/Caches/com.example.other")
        var guards = fakes.guards
        guards.trash = { _ in throw CocoaError(.fileNoSuchFile) }
        #expect(Cleaner(home: scratch.home, guards: guards).clean([item([again])]).results[0].outcome == .skipped("It is already gone"))
    }

    @Test func twoCleansNeverRunAtOnce() {
        let scratch = Scratch()
        let a = scratch.make("Library/Caches/a"), b = scratch.make("Library/Caches/b")
        let fakes = Fakes(scratch)
        let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        var slow = fakes.guards
        slow.lockFile = scratch.root + "/clean.lock"
        let trash = slow.trash
        slow.trash = { path in
            entered.signal()
            go.wait()
            try trash(path)
        }
        var quick = fakes.guards
        quick.lockFile = slow.lockFile
        var second = Cleaner(home: scratch.home, guards: quick)
        second.lockWait = 0.3
        let first = Cleaner(home: scratch.home, guards: slow)
        let items = [item([a]), item([b])]
        DispatchQueue.global(qos: .utility).async {
            _ = first.clean(items)
            done.signal()
        }
        entered.wait()
        let busy = CleanOutcome.skipped("Another clean is running. Clean again when it is done")
        #expect(second.clean(items).results.map(\.outcome) == [busy, busy])
        #expect(fakes.trashed.isEmpty)
        go.signal()
        go.signal()
        done.wait()
        #expect(fakes.trashed == [a, b])
        // Once the first is done, the second goes ahead and finds nothing left to move.
        #expect(second.clean(items).results.map(\.outcome) == [.skipped("It is already gone"), .skipped("It is already gone")])
    }

    // MARK: History

    @Test func historyKeepsRecordsThisBuildCannotRead() throws {
        let scratch = Scratch()
        let url = URL(fileURLWithPath: scratch.root + "/clean-history.json")
        let known = CleanRecord(date: Date(timeIntervalSince1970: 1_800_000_000), trigger: .manual, items: [
            .init(name: "Cache", tab: .junk, paths: ["/Users/me/Library/Caches/x"], bytes: 5, removal: .trash, outcome: .removed),
        ], bytesFreed: 5)
        CleanHistory.append(known, to: url)
        // A newer build's record, with a kind of removal this one has never heard of.
        var list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
        list.append(["id": UUID().uuidString, "date": "2027-01-01T00:00:00Z", "trigger": "manual", "bytesFreed": 9,
                     "items": [["name": "x", "tab": "junk", "paths": [String](), "bytes": 9, "removal": ["dockerVolume": ["name": "v"]],
                                "outcome": ["removed": [String: String]()]]]])
        try JSONSerialization.data(withJSONObject: list).write(to: url)
        #expect(CleanHistory.load(from: url) == [known])
        let next = CleanRecord(date: Date(timeIntervalSince1970: 1_800_000_100), trigger: .cli, items: [], bytesFreed: 7)
        CleanHistory.append(next, to: url)
        #expect(CleanHistory.load(from: url) == [known, next])
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
        #expect(raw.count == 3)

        // A file that is not a list at all is kept aside, not written over.
        try write("not json", to: url.path)
        CleanHistory.append(next, to: url)
        #expect(CleanHistory.load(from: url) == [next])
        let aside = try FileManager.default.contentsOfDirectory(atPath: scratch.root).filter { $0.hasPrefix("clean-history.unreadable-") }
        #expect(aside.count == 1)
    }

    // MARK: Small parts

    @Test func helpersAndExtensionsCountAsRunningApps() {
        #expect(ProcessUse.bundlePaths(in: "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")
            == ["/Applications/Foo.app", "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app"])
        #expect(ProcessUse.bundlePaths(in: "/Applications/Foo.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share")
            == ["/Applications/Foo.app", "/Applications/Foo.app/Contents/PlugIns/Share.appex"])
        #expect(ProcessUse.bundlePaths(in: "/opt/homebrew/bin/node").isEmpty)
    }

    @Test func prunableWorktreesAreReadFromGitsPorcelain() {
        let output = "worktree /r\0HEAD abc\0branch refs/heads/main\0\0worktree /w/a\0HEAD abc\0branch refs/heads/a\0prunable gitdir file points to non-existent location\0\0worktree /w/b\0HEAD abc\0locked\0\0"
        #expect(Cleaner.prunableWorktrees(output) == ["/w/a"])
        #expect(Cleaner.prunableWorktrees("").isEmpty)
    }

    @Test func stampsTellTheSameThingFromAChangedOne() throws {
        let scratch = Scratch()
        let file = scratch.make("Movies/a.mov", file: true)
        let before = try #require(CleanStamp(path: file))
        var grown = before
        grown.size += 1
        #expect(before.same(as: grown, content: false))
        #expect(!before.same(as: grown, content: true))
        var other = before
        other.inode += 1
        #expect(!before.same(as: other, content: false))
        #expect(CleanStamp(path: scratch.root + "/missing") == nil)
    }

    // MARK: Live

    /// The real snapshot of this Mac's processes, reading only, and a disk image attached inside
    /// the scratch folder: `WISP_SAFETY_LIVE=1 swift test --filter CleanSafetyTests/live`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_SAFETY_LIVE"] == "1"))
    func liveSnapshotSeesWhatAProcessHoldsOrMaps() throws {
        let scratch = Scratch()
        // A home outside /Users: the snapshot used to keep only /Users and /Applications paths.
        let held = scratch.make("Library/Caches/com.example.held/log.txt", file: true)
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", held]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate() }
        // Mapped, then closed: only the mapped-files pass sees it.
        let mapped = scratch.make("Library/Caches/com.example.mapped/blob.bin", file: true)
        let fd = open(mapped, O_RDONLY)
        let map = mmap(nil, 1, PROT_READ, MAP_PRIVATE, fd, 0)
        close(fd)
        defer { munmap(map, 1) }
        Thread.sleep(forTimeInterval: 0.3)
        let start = Date()
        let use = ProcessUse.snapshot(excluding: 0, home: scratch.home)
        print("live snapshot \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(use.runningBundleIDs.count) running bundle ids, \(use.mountPoints.count) mounts")
        #expect(use.user(of: real(held)) == "tail")
        #expect(use.user(of: real(mapped)) != nil)
        #expect(use.diskImages != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_SAFETY_LIVE"] == "1"))
    func liveDiskImageInsideAFolderKeepsIt() throws {
        let scratch = Scratch()
        func hdiutil(_ arguments: [String]) -> Int32 { CleanTools.run(CleanTools.hdiutil, arguments, timeout: 60).status }
        let image = scratch.home + "/Downloads/lab.dmg"
        try FileManager.default.createDirectory(atPath: scratch.home + "/Downloads", withIntermediateDirectories: true)
        #expect(hdiutil(["create", "-size", "4m", "-fs", "APFS", "-volname", "WispSafety", "-quiet", image]) == 0)
        let folder = scratch.make("Library/Caches/com.example.disk")
        let mountPoint = scratch.make("Library/Caches/com.example.disk/volume")
        #expect(hdiutil(["attach", image, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]) == 0)
        defer { _ = hdiutil(["detach", mountPoint, "-force", "-quiet"]) }
        let use = ProcessUse.snapshot(home: scratch.home)
        #expect(use.mount(inside: real(folder)) == real(mountPoint))
        #expect(use.diskImage(inside: real(image))?.mount == real(mountPoint))
        let fakes = Fakes(scratch)
        var guards = fakes.guards
        guards.processUse = { use }
        let cleaner = Cleaner(home: scratch.home, guards: guards)
        #expect(cleaner.clean([item([folder])]).results[0].outcome
            == .skipped("A disk is mounted inside it at ~/Library/Caches/com.example.disk/volume. Eject it first"))
        #expect(cleaner.clean([item([image], tab: .largeFiles)]).results[0].outcome == .skipped("It is mounted as volume. Eject it first"))
        #expect(fakes.trashed.isEmpty)
    }
}
