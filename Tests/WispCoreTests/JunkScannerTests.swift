import Foundation
import Testing
@testable import WispCore

/// A fake home folder in the temporary folder, gone with the test.
final class FakeHome {
    let path: String
    init() {
        path = (FileManager.default.temporaryDirectory.appendingPathComponent("wisp-clean-\(UUID().uuidString)").path as NSString)
            .resolvingSymlinksInPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    var url: URL { URL(fileURLWithPath: path) }

    func file(_ relative: String, bytes: Int = 1_000, text: String? = nil) {
        let url = URL(fileURLWithPath: path + "/" + relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text {
            try? text.write(to: url, atomically: false, encoding: .utf8)
            return
        }
        // Random bytes so APFS cannot store them compressed or sparse.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try? data.write(to: url)
    }

    func folder(_ relative: String) {
        try? FileManager.default.createDirectory(atPath: path + "/" + relative, withIntermediateDirectories: true)
    }

    /// Sets every file and folder at and below `relative` to `days` ago.
    func age(_ relative: String, days: Double) {
        let date = Date().addingTimeInterval(-days * 86_400)
        let root = path + "/" + relative
        var all = [root]
        if let more = FileManager.default.subpaths(atPath: root) { all += more.map { root + "/" + $0 } }
        for item in all { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item) }
    }

    func context(excluded: [String] = []) -> CleanScanContext {
        CleanScanContext(home: url, excluded: excluded.map { path + "/" + $0 })
    }
}

@Suite struct JunkScannerTests {
    static let mb = 1 << 20

    private func appCaches(_ home: FakeHome, excluded: [String] = []) -> [CleanItem] {
        let names = ["com.example.editor": "Example Editor", "com.spotify.client": "Spotify"]
        let scanner = AppCacheScanner(appName: { names[$0] }, readsContainers: { true })
        return scanner.scan(home.context(excluded: excluded))
    }

    @Test func appCachesMergeOneRowPerApp() throws {
        let home = FakeHome()
        home.file("Library/Caches/com.example.editor/a.bin", bytes: 2 * Self.mb)
        home.file("Library/Caches/com.example.editor.ShipIt/update.zip", bytes: Self.mb / 2)
        home.file("Library/Containers/com.example.editor/Data/Library/Caches/b.bin", bytes: Self.mb)
        home.file("Library/Containers/com.example.editor.share-extension/Data/Library/Caches/c.bin", bytes: Self.mb / 2)
        home.file("Library/Caches/SomeTool/cache.bin", bytes: 2 * Self.mb)
        home.file("Library/Caches/com.spotify.client/Data/song.bin", bytes: 2 * Self.mb)

        let items = appCaches(home)
        let editor = try #require(items.first { $0.name == "Example Editor cache" })
        #expect(editor.paths.count == 4)
        #expect(editor.bytes >= Int64(4 * Self.mb))
        #expect(editor.ownerBundleID == "com.example.editor")
        #expect(editor.safety == .safe)
        #expect(editor.tab == .junk && editor.group == "App caches")
        // A folder LaunchServices does not know keeps its own name.
        #expect(items.contains { $0.name == "SomeTool cache" && $0.ownerBundleID == nil })
        #expect(items.first { $0.name == "Spotify cache" }?.safety == .checkFirst)
        #expect(items.count == 3)
    }

    @Test func appCachesLeaveOutAppleWispDeveloperAndTinyFolders() {
        let home = FakeHome()
        home.file("Library/Caches/CloudKit/state.db", bytes: 2 * Self.mb)
        home.file("Library/Caches/com.apple.bird/state.db", bytes: 2 * Self.mb)
        home.file("Library/Caches/geod/tiles.bin", bytes: 2 * Self.mb)
        home.file("Library/Caches/app.wisp.Wisp/cache.bin", bytes: 2 * Self.mb)
        home.file("Library/Caches/Homebrew/bottle.tar.gz", bytes: 2 * Self.mb)
        home.file("Library/Caches/com.example.editor/small.bin", bytes: 100_000)
        home.file("Library/Containers/com.apple.Notes/Data/Library/Caches/x.bin", bytes: 2 * Self.mb)
        #expect(appCaches(home).isEmpty)

        // Known Apple caches are listed.
        home.file("Library/Caches/com.apple.python/cache.bin", bytes: 2 * Self.mb)
        #expect(appCaches(home).map(\.name) == ["Python bytecode cache"])
    }

    @Test func appCachesHonourExclusions() {
        let home = FakeHome()
        home.file("Library/Caches/com.example.editor/a.bin", bytes: 2 * Self.mb)
        home.file("Library/Containers/com.example.editor/Data/Library/Caches/b.bin", bytes: 2 * Self.mb)
        home.file("Library/Caches/SomeTool/keep/c.bin", bytes: 2 * Self.mb)

        let items = appCaches(home, excluded: ["Library/Caches/com.example.editor", "Library/Caches/SomeTool/keep"])
        #expect(items.count == 1)
        #expect(items.first?.paths == [home.path + "/Library/Containers/com.example.editor/Data/Library/Caches"])
    }

    @Test func containersNeedFullDiskAccess() {
        let home = FakeHome()
        home.file("Library/Containers/com.example.editor/Data/Library/Caches/b.bin", bytes: 2 * Self.mb)
        let scanner = AppCacheScanner(appName: { _ in "Example Editor" }, readsContainers: { false })
        #expect(scanner.scan(home.context()).isEmpty)
    }

    @Test func appCachesStreamWhatTheyReturn() {
        let home = FakeHome()
        home.file("Library/Caches/com.example.editor/a.bin", bytes: 2 * Self.mb)
        let streamed = Locked<[CleanItem]>([])
        var context = home.context()
        context.found = { batch in streamed.mutate { $0 += batch } }
        let items = AppCacheScanner(appName: { _ in nil }, readsContainers: { true }).scan(context)
        #expect(streamed.value == items)
        #expect(!items.isEmpty)
    }

    @Test func systemJunkListsLogsAndCrashReportsSeparately() throws {
        let home = FakeHome()
        home.file("Library/Logs/SomeApp/run.log", bytes: Self.mb)
        home.file("Library/Logs/other.log", bytes: Self.mb)
        home.file("Library/Logs/DiagnosticReports/App-2026-11-01.ips", bytes: 2 * Self.mb)
        home.file("Library/iTunes/iPhone Software Updates/iPhone_27.0_Restore.ipsw", bytes: 2 * Self.mb)

        let items = SystemJunkScanner().scan(home.context(excluded: ["Library/Logs/other.log"]))
        let logs = try #require(items.first { $0.name == "App logs" })
        #expect(logs.paths == [home.path + "/Library/Logs/SomeApp"])
        let crashes = try #require(items.first { $0.name == "Crash reports" })
        #expect(crashes.paths == [home.path + "/Library/Logs/DiagnosticReports/App-2026-11-01.ips"])
        #expect(items.contains { $0.name == "iPhone and iPad software updates" && $0.paths.count == 1 })
        #expect(items.allSatisfy { $0.safety == .safe && $0.group == "System junk" })
    }

    @Test func installersInDownloadsDesktopDocumentsAndApplications() throws {
        let home = FakeHome()
        home.file("Downloads/Tool.dmg", bytes: 2 * Self.mb)
        home.file("Downloads/old/Driver.pkg", bytes: 2 * Self.mb)
        home.file("Desktop/UniversalMac_27.0_Restore.ipsw", bytes: 2 * Self.mb)
        home.file("Documents/Xcode_27.xip", bytes: 2 * Self.mb)
        home.file("Documents/notes.txt", bytes: 2 * Self.mb)
        home.file("Downloads/Some.app/Contents/Resources/inner.dmg", bytes: 2 * Self.mb)
        home.file("Downloads/tiny.dmg", bytes: 10_000)
        home.file("Applications/Install macOS Tahoe.app/Contents/SharedSupport/SharedSupport.dmg", bytes: 2 * Self.mb)
        home.file("Applications/Safari.app/Contents/Info.plist", bytes: 2 * Self.mb)

        let scanner = InstallerScanner(applications: home.path + "/Applications", readsGuardedFolders: { true })
        let items = scanner.scan(home.context(excluded: ["Documents/Xcode_27.xip"]))
        #expect(Set(items.map(\.name)) == ["Install macOS Tahoe", "Tool.dmg", "Driver.pkg", "UniversalMac_27.0_Restore.ipsw"])
        #expect(items.allSatisfy { $0.safety == .checkFirst && $0.tab == .junk && !$0.checkedByDefault })
        let ipsw = try #require(items.first { $0.name.hasSuffix(".ipsw") })
        #expect(ipsw.detail == "A system image. Only needed to set up a Mac, a device or a virtual machine.")

        let withoutAccess = InstallerScanner(applications: home.path + "/Applications", readsGuardedFolders: { false })
        #expect(withoutAccess.scan(home.context()).map(\.name) == ["Install macOS Tahoe"])
    }

    @Test func installersInsideProjectsAreLeftOut() {
        let home = FakeHome()
        home.file("Documents/crosswire/.git/HEAD")
        home.file("Documents/crosswire/build/virtual-hid/Driver.pkg", bytes: 2 * Self.mb)
        home.file("Documents/crosswire/dist/App.dmg", bytes: 2 * Self.mb)
        home.file("Documents/worktree/.git", text: "gitdir: /elsewhere")
        home.file("Documents/worktree/Release.dmg", bytes: 2 * Self.mb)
        home.file("Desktop/export/build/Tool.pkg", bytes: 2 * Self.mb)
        home.file("Downloads/Setup.dmg", bytes: 2 * Self.mb)
        home.file("Downloads/drivers/Driver.pkg", bytes: 2 * Self.mb)

        let scanner = InstallerScanner(applications: home.path + "/Applications", readsGuardedFolders: { true })
        #expect(Set(scanner.scan(home.context()).map(\.paths[0])) == [home.path + "/Downloads/Setup.dmg", home.path + "/Downloads/drivers/Driver.pkg"])
    }

    @Test func snapshotsKeepTheNewest() {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-11-03-101010.local
        com.apple.TimeMachine.2026-11-04-090000.local
        com.apple.TimeMachine.2026-11-02-080000.local
        com.apple.os.update-810C7D51A2A937EEA6F4A05056790B457C70B7E66998ACC90A8D43A9B034564D
        """
        let snapshots = LocalSnapshot.parse(output)
        let items = LocalSnapshotScanner(snapshots: { snapshots }).scan(CleanScanContext())
        #expect(items.map(\.removal) == [.localSnapshot(date: "2026-11-03-101010"), .localSnapshot(date: "2026-11-02-080000")])
        #expect(items.allSatisfy { $0.bytes == 0 && $0.safety == .checkFirst && $0.removal.isPermanent && $0.paths.isEmpty })
        #expect(LocalSnapshotScanner(snapshots: { [] }).scan(CleanScanContext()).isEmpty)
    }

    @Test func registryHasEveryScanner() {
        let scanners = CleanRegistry.scanners
        #expect(scanners.filter { $0.tab == .junk }.count == 4)
        #expect(scanners.filter { $0.tab == .developer }.count == 4)
        #expect(scanners.filter { $0.tab == .leftovers }.count == 1)
        #expect(scanners.filter { $0.tab == .largeFiles }.count == 1)
    }
}

/// A value shared with a closure that may run on another thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
