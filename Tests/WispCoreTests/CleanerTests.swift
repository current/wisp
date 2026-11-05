import Foundation
import Testing
@testable import WispCore

/// Every test works in its own temporary folder, with a fake home inside it. The Trash,
/// git and the tools are fakes; nothing here touches real files.
@Suite struct CleanerTests {
    final class Scratch {
        let root: String
        var home: String { root + "/home" }
        var outside: String { root + "/outside" }

        init() {
            root = (FileManager.default.temporaryDirectory.appendingPathComponent("wisp-clean-\(UUID().uuidString)").path as NSString)
                .resolvingSymlinksInPath
            for folder in [home, outside] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        @discardableResult
        func make(_ relative: String, in base: String? = nil, file: Bool = false) -> String {
            let path = (base ?? home) + "/" + relative
            if file {
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            } else {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            return path
        }
    }

    /// Records what the cleaner asked for; "trash" deletes inside the scratch folder only.
    final class Fakes: @unchecked Sendable {
        let lock = NSLock()
        var trashed: [String] = []
        var tools: [[String]] = []
        var use = ProcessUse()
        var git: CleanGuards.GitState = .clean
        var toolStatus: Int32 = 0
        var snapshotList = ""
        let scratchRoot: String

        init(_ scratch: Scratch) { scratchRoot = scratch.root }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var ids: [String] = []
            func add(_ new: [String]) { lock.withLock { ids += new } }
        }

        var guards: CleanGuards {
            CleanGuards(processUse: { self.use },
                        gitState: { _ in self.git },
                        runTool: { path, arguments in
                            self.lock.withLock { self.tools.append([path] + arguments) }
                            if arguments.first == "listlocalsnapshotdates" { return (0, self.snapshotList) }
                            return (self.toolStatus, self.toolStatus == 0 ? "" : "Error: it went wrong\n")
                        },
                        trash: { path in
                            precondition(path.hasPrefix(self.scratchRoot + "/"), "a test tried to remove \(path)")
                            try FileManager.default.removeItem(atPath: path)
                            self.lock.withLock { self.trashed.append(path) }
                        },
                        developerTools: { true },
                        now: { Date() })
        }
    }

    func item(_ paths: [String], bytes: Int64 = 1000, removal: CleanRemoval = .trash, owner: String? = nil,
              safety: CleanSafety = .safe) -> CleanItem {
        CleanItem(id: "test:" + (paths.first ?? "none"), tab: .junk, group: "Test", name: "Test item", detail: "A test.",
                  paths: paths, bytes: bytes, safety: safety, removal: removal, ownerBundleID: owner)
    }

    // MARK: Path rules

    @Test func pathRulesKeepHomeAndItsTopFolders() {
        let scratch = Scratch()
        let documents = scratch.make("Documents")
        let library = scratch.make("Library/Caches")
        let cache = scratch.make("Library/Caches/com.example.app")
        let project = scratch.make("src/wisp/node_modules")
        #expect(CleanPathRules.refusal(scratch.home, home: scratch.home) == "It is your home folder")
        #expect(CleanPathRules.refusal(documents, home: scratch.home) == "It is a top-level folder of your home folder")
        #expect(CleanPathRules.refusal(scratch.home + "/Library", home: scratch.home) == "It is a top-level folder of your home folder")
        #expect(CleanPathRules.refusal(library, home: scratch.home) == "It is a top-level folder of your Library")
        #expect(CleanPathRules.refusal(cache, home: scratch.home) == nil)
        #expect(CleanPathRules.refusal(project, home: scratch.home) == nil)
        #expect(CleanPathRules.refusal(scratch.make("Library/Keychains/login"), home: scratch.home) == "Wisp never touches it")
        #expect(CleanPathRules.refusal(scratch.make(".ssh/keys"), home: scratch.home) == "Wisp never touches it")
        for folder in ["Mobile Documents", "CloudStorage", "Mail", "Messages", "Accounts"] {
            #expect(CleanPathRules.refusal(scratch.make("Library/\(folder)/inside"), home: scratch.home) == "Wisp never touches it")
        }
    }

    @Test func pathRulesRefuseOddPathsSystemFoldersAndLinksOut() throws {
        let scratch = Scratch()
        scratch.make("src/a")
        #expect(CleanPathRules.refusal(scratch.home + "/src/../src/a", home: scratch.home) == "Not a plain absolute path")
        #expect(CleanPathRules.refusal(scratch.home + "/src/a/", home: scratch.home) == "Not a plain absolute path")
        #expect(CleanPathRules.refusal("src/a", home: scratch.home) == "Not a plain absolute path")
        #expect(CleanPathRules.refusal("/System/Library", home: scratch.home) == "It belongs to macOS")
        #expect(CleanPathRules.refusal("/usr/bin", home: scratch.home) == "It belongs to macOS")
        #expect(CleanPathRules.refusal(scratch.outside, home: scratch.home) != nil)

        // A link in home that points outside it.
        let target = scratch.make("precious", in: scratch.outside)
        try FileManager.default.createSymbolicLink(atPath: scratch.home + "/src/link", withDestinationPath: target)
        #expect(CleanPathRules.refusal(scratch.home + "/src/link", home: scratch.home) == "It is a link to somewhere Wisp does not clean")
        // A folder reached through a linked parent is judged by where it really is.
        try FileManager.default.createSymbolicLink(atPath: scratch.home + "/src/out", withDestinationPath: scratch.outside)
        #expect(CleanPathRules.refusal(scratch.home + "/src/out/precious", home: scratch.home) != nil)
        // A link that stays inside home is fine.
        let inside = scratch.make("src/b")
        try FileManager.default.createSymbolicLink(atPath: scratch.home + "/src/c", withDestinationPath: inside)
        #expect(CleanPathRules.refusal(scratch.home + "/src/c", home: scratch.home) == nil)
    }

    // MARK: Skips

    @Test func excludedItemsAndParentsOfExclusionsStay() {
        let scratch = Scratch()
        let cache = scratch.make("Library/Caches/com.example.app")
        let keep = scratch.make("Library/Caches/com.example.app/keep")
        let fakes = Fakes(scratch)
        var cleaner = Cleaner(home: scratch.home, exclusions: [cache], guards: fakes.guards)
        #expect(cleaner.clean([item([keep])]).results[0].outcome == .skipped("You excluded it"))
        cleaner.exclusions = [keep]
        #expect(cleaner.clean([item([cache])]).results[0].outcome == .skipped("It holds something you excluded"))
        #expect(fakes.trashed.isEmpty)
    }

    @Test func goneBusyRunningAndUncommittedItemsAreSkipped() {
        let scratch = Scratch()
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)

        #expect(cleaner.clean([item([scratch.home + "/Library/Caches/nothing"])]).results[0].outcome == .skipped("It is already gone"))

        let build = scratch.make("src/app/build")
        fakes.use = ProcessUse(entries: [("node", build + "/out/server.js")])
        #expect(cleaner.clean([item([build])]).results[0].outcome == .skipped("node is using it"))
        fakes.use = ProcessUse(entries: [("zsh", build)])
        #expect(cleaner.clean([item([build])]).results[0].outcome == .skipped("zsh is using it"))
        // A neighbour whose name starts the same is not a match.
        fakes.use = ProcessUse(entries: [("zsh", build + "-old")])
        #expect(cleaner.clean([item([build])]).results[0].outcome == .removed)

        let cache = scratch.make("Library/Caches/com.example.app")
        fakes.use = ProcessUse(runningBundleIDs: ["com.example.app"])
        #expect(cleaner.clean([item([cache], owner: "com.example.app")]).results[0].outcome == .skipped("Its app is open. Quit it and clean again"))

        let project = scratch.make("src/old-project")
        scratch.make("src/old-project/.git")
        fakes.use = ProcessUse()
        fakes.git = .uncommitted
        #expect(cleaner.clean([item([project])]).results[0].outcome == .skipped("It has changes that are not committed"))
        fakes.git = .unknown
        #expect(cleaner.clean([item([project])]).results[0].outcome == .skipped("Wisp could not check it for uncommitted changes"))
        fakes.git = .clean
        #expect(cleaner.clean([item([project])]).results[0].outcome == .removed)
        #expect(fakes.trashed == [build, project])
    }

    @Test func freshLockfileMeansTheProjectIsBusy() {
        let scratch = Scratch()
        let modules = scratch.make("src/web/node_modules")
        scratch.make("src/web/package-lock.json", file: true)
        let fakes = Fakes(scratch)
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        #expect(cleaner.clean([item([modules])]).results[0].outcome == .skipped("Its project is installing packages right now"))
        var later = fakes.guards
        later.now = { Date().addingTimeInterval(600) }
        #expect(Cleaner(home: scratch.home, guards: later).clean([item([modules])]).results[0].outcome == .removed)
    }

    @Test func removesEveryPathAndAddsUpWhatWasFreed() {
        let scratch = Scratch()
        let a = scratch.make("Library/Caches/a")
        let b = scratch.make("Library/Logs/b")
        let c = scratch.make("Library/Caches/c")
        let fakes = Fakes(scratch)
        let report = Cleaner(home: scratch.home, guards: fakes.guards)
            .clean([item([a, b], bytes: 300), item([c], bytes: 200), item([scratch.home], bytes: 5000)])
        #expect(report.results.map(\.outcome) == [.removed, .removed, .skipped("It is your home folder")])
        #expect(report.bytesFreed == 500)
        #expect(fakes.trashed == [a, b, c])
        #expect(FileManager.default.fileExists(atPath: scratch.home))

        let record = report.record(trigger: .manual)
        #expect(record.bytesFreed == 500)
        #expect(record.removedCount == 2)
    }

    @Test func aPathNamedTwiceIsRemovedOnce() {
        let scratch = Scratch()
        let movie = scratch.make("Movies/big.mov", file: true)
        let other = scratch.make("Movies/other.mov", file: true)
        let fakes = Fakes(scratch)
        var asDuplicate = item([movie, movie], bytes: 900)
        asDuplicate.id = "duplicate:" + movie
        let report = Cleaner(home: scratch.home, guards: fakes.guards).clean([item([movie], bytes: 900), asDuplicate, item([other], bytes: 100)])
        #expect(report.results.map(\.outcome) == [.removed, .removed, .removed])
        #expect(report.bytesFreed == 1000)
        #expect(fakes.trashed == [movie, other])
        #expect(report.results[1].item.paths == [movie, movie])
    }

    @Test func aSelectionCheckCanRefuseTheWholeClean() {
        let scratch = Scratch()
        let a = scratch.make("Movies/a.mov", file: true)
        let fakes = Fakes(scratch)
        var cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        cleaner.selectionChecks = [{ ids in !ids.contains("test:" + a) }]
        let report = cleaner.clean([item([a])])
        #expect(report.results[0].outcome == .skipped("This would remove every copy of a file. Keep at least one copy ticked off"))
        #expect(fakes.trashed.isEmpty)
        #expect(CleanRegistry.selectionRefusal([item([a])], checks: [{ _ in true }]) == nil)
    }

    @Test func cancellingSkipsWhatIsLeft() {
        let scratch = Scratch()
        let a = scratch.make("Library/Caches/a"), b = scratch.make("Library/Caches/b")
        let fakes = Fakes(scratch)
        var calls = 0
        let report = Cleaner(home: scratch.home, guards: fakes.guards).clean([item([a]), item([b])], isCancelled: {
            calls += 1
            return calls > 1
        })
        #expect(report.results.map(\.outcome) == [.removed, .skipped("Cleaning stopped before it got here")])
    }

    // MARK: Permanent removals

    @Test func permanentRemovalsGoThroughTheirToolAndKeepTheNewestSnapshot() {
        let scratch = Scratch()
        let fakes = Fakes(scratch)
        fakes.snapshotList = "Snapshot dates for all disks:\n2026-11-01-090000\n2026-11-04-101500\n"
        let cleaner = Cleaner(home: scratch.home, guards: fakes.guards)
        let udid = "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A"
        let report = cleaner.clean([
            item([], removal: .simulator(udid: udid)),
            item([], removal: .simulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0")),
            item([], removal: .localSnapshot(date: "2026-11-01-090000")),
            item([], removal: .localSnapshot(date: "2026-11-04-101500")),
            item([], removal: .simulator(udid: "--all")),
            item([], removal: .localSnapshot(date: "/ ; rm")),
        ])
        #expect(report.results.map(\.outcome) == [
            .removed, .removed, .removed, .skipped("Wisp keeps the newest snapshot"),
            .skipped("Its name does not look right, so Wisp left it alone"),
            .skipped("Its name does not look right, so Wisp left it alone"),
        ])
        #expect(fakes.tools.contains(["/usr/bin/xcrun", "simctl", "delete", udid]))
        #expect(fakes.tools.contains(["/usr/bin/xcrun", "simctl", "runtime", "delete", "com.apple.CoreSimulator.SimRuntime.iOS-18-0"]))
        #expect(fakes.tools.contains(["/usr/bin/tmutil", "deletelocalsnapshots", "2026-11-01-090000"]))
        #expect(!fakes.tools.contains(["/usr/bin/tmutil", "deletelocalsnapshots", "2026-11-04-101500"]))
        #expect(fakes.tools.filter { $0.contains("listlocalsnapshotdates") }.count == 1)
    }

    @Test func aFailingToolIsReportedWithItsMessage() {
        let scratch = Scratch()
        let fakes = Fakes(scratch)
        fakes.toolStatus = 1
        let report = Cleaner(home: scratch.home, guards: fakes.guards)
            .clean([item([], removal: .simulator(udid: "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A"))])
        #expect(report.results[0].outcome == .failed("Error: it went wrong"))
        #expect(report.bytesFreed == 0)
    }

    @Test func caskTokensAreChecked() {
        #expect(Cleaner.badIdentifier(.brewCask(token: "google-chrome")) == nil)
        #expect(Cleaner.badIdentifier(.brewCask(token: "font-sf-mono@beta")) == nil)
        #expect(Cleaner.badIdentifier(.brewCask(token: "--force")) != nil)
        #expect(Cleaner.badIdentifier(.brewCask(token: "Google Chrome")) != nil)
    }

    @Test func safeTrashIsOnlySafeItemsThatGoToTheTrash() {
        #expect(item(["/x"]).isSafeTrash)
        #expect(!item(["/x"], safety: .checkFirst).isSafeTrash)
        #expect(!item([], removal: .simulator(udid: "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A")).isSafeTrash)
    }

    @Test func processUseFindsPathsAndEverythingUnderThem() {
        let use = ProcessUse(entries: [("a", "/Users/me/x/y"), ("b", "/Users/me/xy/z"), ("c", "/Users/me/q")])
        #expect(use.user(of: "/Users/me/x") == "a")
        #expect(use.user(of: "/Users/me/x/y") == "a")
        #expect(use.user(of: "/Users/me/q") == "c")
        #expect(use.user(of: "/Users/me/x/y/z") == nil)
        #expect(use.user(of: "/Users/me/w") == nil)
    }

    // MARK: History

    @Test func historyRoundTripsAndKeepsTheLast200() throws {
        let scratch = Scratch()
        let url = URL(fileURLWithPath: scratch.root + "/clean-history.json")
        let first = CleanRecord(date: Date(timeIntervalSince1970: 1_800_000_000), trigger: .cli, items: [
            .init(name: "Xcode build files", tab: .developer, paths: ["/Users/me/Library/Developer/Xcode/DerivedData"], bytes: 4_000_000_000,
                  removal: .trash, outcome: .removed),
            .init(name: "iPhone 15", tab: .developer, paths: [], bytes: 2_000_000, removal: .simulator(udid: "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A"),
                  outcome: .skipped("Xcode is not installed")),
        ], bytesFreed: 4_000_000_000)
        CleanHistory.append(first, to: url)
        let loaded = CleanHistory.load(from: url)
        #expect(loaded == [first])

        for index in 0..<205 {
            CleanHistory.append(CleanRecord(date: Date(timeIntervalSince1970: Double(index)), trigger: .manual, items: [], bytesFreed: Int64(index)), to: url)
        }
        let trimmed = CleanHistory.load(from: url)
        #expect(trimmed.count == 200)
        #expect(trimmed.first?.bytesFreed == 5)
        #expect(trimmed.last?.bytesFreed == 204)
        #expect(CleanHistory.load(from: URL(fileURLWithPath: scratch.root + "/missing.json")).isEmpty)
    }

    // MARK: Settings

    @Test func settingsRoundTripAndFillInMissingFields() throws {
        let scratch = Scratch()
        let url = URL(fileURLWithPath: scratch.root + "/clean-settings.json")
        var settings = CleanSettings()
        settings.staleProjectDays = 60
        settings.watchDeletedApps = true
        settings.setSchedule(.monthly, now: Date(timeIntervalSince1970: 1_800_000_000))
        settings.save(to: url)
        #expect(CleanSettings.load(from: url) == settings)

        try Data(#"{"staleProjectDays": 90, "schedule": "fortnightly"}"#.utf8).write(to: url)
        let partial = CleanSettings.load(from: url)
        #expect(partial.staleProjectDays == 90)
        #expect(partial.schedule == .off)
        #expect(partial.exclusions.isEmpty)
        #expect(!partial.watchDeletedApps)
    }

    @Test func exclusionsCoverWhatIsUnderThem() {
        var settings = CleanSettings()
        settings.exclude("/Users/me/src/keep/node_modules")
        settings.exclude("/Users/me/src/keep")
        settings.exclude("/Users/me/src/keep/build")
        #expect(settings.exclusions == ["/Users/me/src/keep"])
        #expect(settings.isExcluded("/Users/me/src/keep/anything"))
        #expect(settings.isExcluded("/Users/me/src/keep"))
        #expect(!settings.isExcluded("/Users/me/src/keeper"))
    }

    @Test func scheduleDueDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9)))
        func day(_ date: Date?) -> String {
            guard let date else { return "none" }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
        }
        var settings = CleanSettings()
        #expect(settings.nextDate(after: start, calendar: calendar) == nil)
        #expect(!settings.isDue(now: start))

        settings.setSchedule(.weekly, now: start, calendar: calendar)
        #expect(day(settings.nextDue) == "2027-2-7")
        #expect(!settings.isDue(now: start))
        #expect(settings.isDue(now: start.addingTimeInterval(7 * 86_400)))

        settings.setSchedule(.monthly, now: start, calendar: calendar)
        #expect(day(settings.nextDue) == "2027-2-28")
        settings.setSchedule(.quarterly, now: start, calendar: calendar)
        #expect(day(settings.nextDue) == "2027-4-30")
        settings.setSchedule(.custom, customDays: 10, now: start, calendar: calendar)
        #expect(day(settings.nextDue) == "2027-2-10")
        settings.setSchedule(.custom, customDays: 0, now: start, calendar: calendar)
        #expect(settings.customDays == 1)

        settings.setSchedule(.weekly, now: start, calendar: calendar)
        let ran = start.addingTimeInterval(9 * 86_400)
        settings.scheduleNext(from: ran, calendar: calendar)
        #expect(day(settings.nextDue) == "2027-2-16")

        settings.setSchedule(.off, now: start, calendar: calendar)
        #expect(settings.nextDue == nil)
        #expect(!settings.isDue(now: ran))
    }

    @Test func registryDropsExcludedItems() {
        struct Fixed: CleanScanner {
            var tab: CleanTab { .junk }
            func scan(_ context: CleanScanContext) -> [CleanItem] {
                [CleanItem(id: "a", tab: .junk, group: "G", name: "A", detail: "", paths: ["/Users/me/a"], bytes: 1, safety: .safe),
                 CleanItem(id: "b", tab: .junk, group: "G", name: "B", detail: "", paths: ["/Users/me/b/c"], bytes: 1, safety: .safe)]
            }
        }
        let streamed = Fakes.Box()
        let context = CleanScanContext(home: URL(fileURLWithPath: "/Users/me"), excluded: ["/Users/me/b"],
                                       found: { batch in streamed.add(batch.map(\.id)) })
        let items = CleanRegistry.scan([.junk, .developer], context: context, using: [Fixed(), Fixed()])
        #expect(items.map(\.id) == ["a"])
        #expect(CleanRegistry.scan([.developer], context: context, using: [Fixed()]).isEmpty)
    }
}
