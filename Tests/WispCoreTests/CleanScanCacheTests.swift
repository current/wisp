import Foundation
import Testing
@testable import WispCore

@Suite struct CleanScanCacheTests {
    static let mb = 1 << 20

    private func cache(_ home: FakeHome) -> CleanScanCache {
        let cache = CleanScanCache(url: URL(fileURLWithPath: home.path + "/cache.plist"), roots: [home.path])
        cache.reuseWindow = 0
        return cache
    }

    /// Waits for FSEvents to pass a change on, which can take a moment on a busy Mac.
    /// File system events can arrive many seconds late on a busy Mac, so this waits up to 30.
    private func eventually(_ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return check()
    }

    @Test func testsNeverShareTheSavedCache() {
        #expect(CleanScanCache.shared == nil)
    }

    @Test func sizesMatchTheWalkAndCountHardLinksOnce() throws {
        let home = FakeHome()
        home.file("caches/a/one.bin", bytes: 2 * Self.mb)
        home.file("caches/b/deep/two.bin", bytes: Self.mb)
        try FileManager.default.linkItem(atPath: home.path + "/caches/a/one.bin", toPath: home.path + "/caches/b/link.bin")
        let size = CleanSizer(cache: nil).size(home.path + "/caches")
        let walked = BulkWalker(isCancelled: { false }).folderSize(home.path + "/caches")
        #expect(size.bytes == Int64(walked.bytes))
        #expect(size.bytes >= Int64(3 * Self.mb) && size.bytes < Int64(4 * Self.mb))
        #expect(size.stamp?.inode != nil && size.locked == 0)
    }

    @Test func anUnchangedFolderIsNotReadAgainAndAChangedOneIs() throws {
        let home = FakeHome()
        home.file("caches/a/one.bin", bytes: Self.mb)
        home.file("caches/b/two.bin", bytes: Self.mb)
        let path = home.path + "/caches"
        let cache = cache(home)
        let first = CleanSizer(cache: cache).size(path)
        var record = try #require(cache.folder(path))
        #expect(record.bytes == first.bytes && record.children?.count == 2)

        // A record that says something else is believed while nothing changes. The events of
        // making the files can come in after the first read, so it is stored again until they have.
        #expect(eventually {
            record.bytes = 12_345
            record.event = CleanScanCache.currentEvent()
            cache.store(path, record)
            return CleanSizer(cache: cache).size(path).bytes == 12_345
        })

        // A change inside reads only the child it is in again; the other keeps its figure.
        record.children?["a"]?.bytes = 1_000
        cache.store(path, record)
        home.file("caches/b/three.bin", bytes: Self.mb)
        let b = BulkWalker(isCancelled: { false }).folderSize(path + "/b").bytes
        let own = record.own.bytes
        #expect(eventually { CleanSizer(cache: cache).size(path).bytes == 1_000 + Int64(b) + own })
    }

    @Test func aFolderMadeAgainUnderTheSameNameIsReadAgain() throws {
        let home = FakeHome()
        home.file("caches/a/one.bin", bytes: Self.mb)
        let path = home.path + "/caches/a"
        let cache = cache(home)
        _ = CleanSizer(cache: cache).size(path)
        var record = try #require(cache.folder(path))
        record.bytes = 12_345
        record.inode = 1
        record.event = CleanScanCache.currentEvent()
        cache.store(path, record)
        #expect(CleanSizer(cache: cache).size(path).bytes != 12_345)
    }

    @Test func recordsSurviveAReloadAndChangesSinceAreReplayed() throws {
        let home = FakeHome()
        home.file("caches/a/one.bin", bytes: Self.mb)
        let path = home.path + "/caches/a"
        let url = URL(fileURLWithPath: home.path + "/cache.plist")
        do {
            let cache = CleanScanCache(url: url, roots: [home.path])
            _ = CleanSizer(cache: cache).size(path)
            var record = try #require(cache.folder(path))
            Thread.sleep(forTimeInterval: 1)
            cache.catchUp()
            record.bytes = 12_345
            record.event = CleanScanCache.currentEvent()
            cache.store(path, record)
            cache.save()
        }
        let reloaded = CleanScanCache(url: url, roots: [home.path])
        reloaded.reuseWindow = 0
        #expect(CleanSizer(cache: reloaded).size(path).bytes == 12_345)
        home.file("caches/a/two.bin", bytes: Self.mb)
        #expect(eventually { CleanSizer(cache: reloaded).size(path).bytes > Int64(Self.mb) })
    }

    @Test func memosGoStaleWhenTheirFolderChanges() throws {
        let home = FakeHome()
        home.folder("src/project")
        let cache = cache(home)
        cache.catchUp()
        let key = "test:" + home.path + "/src/project"
        // Making the folder can be reported after the memo is stored, so it is stored again until it holds.
        #expect(eventually {
            cache.storeMemo(key, path: home.path + "/src/project", event: CleanScanCache.currentEvent(), data: Data([1]))
            cache.catchUp()
            return cache.memo(key) == Data([1])
        })
        home.file("src/project/new.txt", text: "x")
        #expect(eventually {
            cache.catchUp()
            return cache.memo(key) == nil
        })
    }

    // MARK: What the scanners leave out

    @Test func attachedDiskImagesAreNotOffered() {
        let home = FakeHome()
        home.file("Downloads/Mounted.dmg", bytes: 2 * Self.mb)
        home.file("Downloads/Loose.dmg", bytes: 2 * Self.mb)
        let mounted: Set<String> = [home.path + "/Downloads/Mounted.dmg"]
        let installers = InstallerScanner(applications: home.path + "/Applications", readsGuardedFolders: { true }, attachedImages: { mounted })
            .scan(home.context())
        #expect(installers.map(\.name) == ["Loose.dmg"])
        #expect(installers.allSatisfy { !$0.stamps.isEmpty })

        var limits = LargeFilesScanner.Limits()
        limits.largeFile = Int64(Self.mb)
        let large = LargeFilesScanner(findDuplicates: false, limits: limits, environment: [:], index: LargeFileIndex(), attachedImages: { mounted })
            .report(home.context())
        #expect(large.items.map(\.name) == ["Loose.dmg"])
        #expect(large.items.allSatisfy { $0.stamps[$0.paths[0]]?.inode != nil })
    }

    @Test func artifactsGitTracksAreNotOffered() {
        let home = FakeHome()
        for name in ["action", "app"] {
            home.file("src/\(name)/package.json", text: "{}")
            home.file("src/\(name)/.git/HEAD", text: "ref: refs/heads/main")
            home.file("src/\(name)/node_modules/dep/index.js", bytes: 2 * Self.mb)
            home.age("src/\(name)", days: 90)
        }
        let tracked = home.path + "/src/action/node_modules"
        let scanner = ProjectArtifactScanner(roots: [home.path + "/src"], workingFolders: { [] }, readsGuardedFolders: { true },
                                             gitTracks: { _, path in path == tracked })
        let items = scanner.scan(home.context())
        #expect(items.map(\.name) == ["node_modules in app"])
        #expect(items.allSatisfy { !$0.stamps.isEmpty })
    }

    @Test func sharedPackageStoresAreCheckFirst() {
        let home = FakeHome()
        home.file("Library/pnpm/store/v10/files/00/blob", bytes: 2 * Self.mb)
        home.file(".yarn/berry/cache/dep.zip", bytes: 2 * Self.mb)
        let items = DeveloperCacheScanner(goModuleCache: { _ in nil }).scan(home.context())
        let pnpm = items.first { $0.paths.contains(home.path + "/Library/pnpm/store") }
        let yarn = items.first { $0.paths.contains(home.path + "/.yarn/berry/cache") }
        #expect(pnpm?.safety == .checkFirst && yarn?.safety == .checkFirst)
    }

    @Test func appsOnAMissingDiskStillCount() {
        #expect(LeftoversScanner.onMissingVolume("/Volumes/Unplugged-\(UUID().uuidString)/Apps/Thing.app"))
        #expect(!LeftoversScanner.onMissingVolume("/Applications/Thing.app"))
    }
}
