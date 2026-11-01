import Foundation
import Testing
@testable import WispCore

@Suite struct StorageTests {
    /// A scratch folder that goes away with the test.
    final class Scratch {
        let path: String
        init() {
            path = (FileManager.default.temporaryDirectory.appendingPathComponent("wisp-storage-\(UUID().uuidString)").path as NSString)
                .resolvingSymlinksInPath
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func file(_ relative: String, bytes: Int) {
            let url = URL(fileURLWithPath: path + "/" + relative)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Random bytes so APFS cannot store them compressed or sparse.
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try? data.write(to: url)
        }

        func allocated(_ relative: String) -> UInt64 {
            UInt64((try? URL(fileURLWithPath: path + "/" + relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
    }

    // MARK: Scanner

    @Test func scannerAddsAllocatedSizesAndCountsHardLinksOnce() throws {
        let scratch = Scratch()
        scratch.file("a/one.bin", bytes: 300_000)
        scratch.file("a/b/two.bin", bytes: 200_000)
        scratch.file("c/three.bin", bytes: 100_000)
        try FileManager.default.linkItem(atPath: scratch.path + "/a/one.bin", toPath: scratch.path + "/c/link.bin")
        let expected = scratch.allocated("a/one.bin") + scratch.allocated("a/b/two.bin") + scratch.allocated("c/three.bin")

        var rules = FolderScanner.Rules()
        rules.smallestFolder = 0
        let root = FolderScanner(rules: rules).scan(scratch.path)
        #expect(root.size == expected)
        #expect(root.files == 4)
        let a = try #require(root.child("a"))
        #expect(a.size == scratch.allocated("a/one.bin") + scratch.allocated("a/b/two.bin"))
        #expect(root.descendant("a/b")?.files == 1)
        // Largest first.
        #expect(root.children.map(\.size) == root.children.map(\.size).sorted(by: >))
    }

    @Test func scannerFoldsSmallFoldersAndKeepsTheTotal() {
        let scratch = Scratch()
        for index in 0..<6 { scratch.file("small\(index)/f.bin", bytes: 10_000) }
        scratch.file("big/f.bin", bytes: 400_000)
        var rules = FolderScanner.Rules()
        rules.smallestFolder = 200_000
        let root = FolderScanner(rules: rules).scan(scratch.path)
        #expect(root.children.map(\.name) == ["big"])
        #expect(root.otherCount == 6)
        #expect(root.children[0].size + root.otherSize + root.ownFiles == root.size)
    }

    @Test func scannerLeavesSkippedFoldersLocked() {
        let scratch = Scratch()
        scratch.file("private/secret.bin", bytes: 50_000)
        scratch.file("open/f.bin", bytes: 50_000)
        var rules = FolderScanner.Rules()
        rules.smallestFolder = 0
        rules.skip = [scratch.path + "/private"]
        let root = FolderScanner(rules: rules).scan(scratch.path)
        #expect(root.child("private")?.locked == true)
        #expect(root.child("private")?.size == 0)
        #expect(root.child("open")?.locked == false)
    }

    @Test func refreshReadsOnlyWhatChangedAndKeepsKeptFolders() {
        let scratch = Scratch()
        scratch.file("kept/f.bin", bytes: 300_000)
        scratch.file("folded/f.bin", bytes: 1_000)
        var rules = FolderScanner.Rules()
        rules.smallestFolder = 100_000
        let scanner = FolderScanner(rules: rules)
        let before = scanner.scan(scratch.path)
        #expect(before.children.map(\.name) == ["kept"])
        scratch.file("folded/g.bin", bytes: 500_000)
        let after = scanner.refresh(before, at: scratch.path)
        // The folded folder was read again and is big enough to list now; the kept one was reused.
        #expect(after.child("folded") != nil)
        #expect(after.child("kept") === before.child("kept"))
        #expect(after.size == before.size + scratch.allocated("folded/g.bin"))
    }

    @Test func replacingCopiesThePathAndLeavesTheOldTreeAlone() {
        let leaf = FolderNode(name: "c", size: 10, files: 1)
        let middle = FolderNode(name: "b", size: 30, files: 3, children: [leaf])
        let root = FolderNode(name: "a", size: 100, files: 10, children: [middle])
        let new = root.replacing(at: ["b", "c"], with: FolderNode(name: "ignored", size: 50, files: 4, modified: 99))
        #expect(new.size == 140 && new.files == 13 && new.modified == 99)
        #expect(new.descendant("b")?.size == 70)
        #expect(new.descendant("b/c")?.name == "c")
        #expect(root.size == 100 && middle.size == 30 && leaf.size == 10)
        #expect(root.replacing(at: ["missing"], with: leaf) === root)
    }

    @Test func cacheRoundTripsTheTree() throws {
        let node = FolderNode(name: "root", size: 5, files: 2, modified: 1000, children: [FolderNode(name: "f", size: 5, isFile: true)],
                              otherSize: 0, otherCount: 0)
        let data = try JSONEncoder().encode(node)
        let back = try JSONDecoder().decode(FolderNode.self, from: data)
        // The JSON form is what SpaceHistory and tools use; the cache itself is binary.
        #expect(back.name == "root" && back.size == 5 && back.children.first?.isFile == true)
    }

    /// The whole loop: a cold scan, a change FSEvents reports, a refresh of only that
    /// folder, and a cache on disk with the event id to resume from.
    @Test func indexFollowsChangesAndSavesItsPlace() async throws {
        let scratch = Scratch()
        scratch.file("watched/a.bin", bytes: 200_000)
        scratch.file("other/b.bin", bytes: 200_000)
        let cacheURL = URL(fileURLWithPath: scratch.path + "-cache.json")
        let historyURL = URL(fileURLWithPath: scratch.path + "-sizes.json")
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: historyURL)
        }
        let queue = DispatchQueue(label: "test.storage.callbacks")
        let lock = NSLock()
        var latest: StorageState?
        let index = StorageIndex(home: "/nonexistent", roots: [scratch.path], cacheURL: cacheURL, historyURL: historyURL, callbackQueue: queue)
        index.refreshInterval = 0.2
        index.onChange = { state in lock.withLock { latest = state } }
        func root() -> FolderNode? { lock.withLock { latest?.scanning == nil ? latest?.roots[scratch.path] : nil } }
        func wait(until done: () -> Bool) async {
            for _ in 0..<200 where !done() { try? await Task.sleep(nanoseconds: 50_000_000) }
        }

        index.open()
        await wait { root() != nil }
        let first = try #require(root())
        // FSEvents only reports what happens after the stream starts.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        scratch.file("watched/c.bin", bytes: 300_000)
        let grown = first.size + scratch.allocated("watched/c.bin")
        await wait { (root()?.size ?? 0) == grown }
        let second = try #require(root())
        #expect(second.size == grown)
        // Only the changed folder was read again; the other is the same node.
        #expect(second.child("other") === first.child("other"))
        index.close()
        await wait { FileManager.default.fileExists(atPath: cacheURL.path) && StorageIndex.loadCache(from: cacheURL)?.roots[scratch.path]?.size == grown }
        let cache = try #require(StorageIndex.loadCache(from: cacheURL))
        #expect(cache.roots[scratch.path]?.size == grown)
        #expect(cache.eventID > 0)

        // Opening again starts from the cache, without a scan.
        lock.withLock { latest = nil }
        index.open()
        await wait { root() != nil }
        #expect(root()?.size == grown)
        index.close()
    }

    @Test func binaryCacheRoundTrips() throws {
        let deep = FolderNode(name: "naïve folder", size: 7, files: 2, modified: 1_700_000_000, ownModified: 1_600_000_000, locked: true)
        let file = FolderNode(name: "big.bin", size: 3, files: 1, isFile: true)
        let root = FolderNode(name: "root", size: 10, files: 3, modified: 1_700_000_000, children: [deep, file], otherSize: 4, otherCount: 2)
        let cache = StorageIndex.Cache(eventID: 42, date: Date(timeIntervalSince1970: 1_700_000_123), roots: ["/r": root],
                                       seconds: ["/r": 1.5], fullDiskAccess: true)
        let data = try #require(StorageCacheFile.encode(cache))
        let back = try #require(StorageCacheFile.decode(data))
        #expect(back.eventID == 42 && back.fullDiskAccess && back.seconds["/r"] == 1.5)
        let node = try #require(back.roots["/r"])
        #expect(node.size == 10 && node.otherSize == 4 && node.otherCount == 2 && node.modified == 1_700_000_000)
        #expect(node.children.map(\.name) == ["naïve folder", "big.bin"])
        #expect(node.children[0].locked && node.children[1].isFile && node.children[0].ownModified == 1_600_000_000)
        // A cut-off file reads as no cache rather than a wrong one.
        #expect(StorageCacheFile.decode(data.prefix(data.count - 3)) == nil)
    }

    // MARK: Analysis

    private func tree(_ name: String, _ size: UInt64, modified: Double = 0, _ children: [FolderNode] = []) -> FolderNode {
        FolderNode(name: name, size: size, files: 1, modified: modified, ownModified: modified, children: children)
    }

    @Test func summaryPartitionsTheDiskAndNamesWhatItCannotMeasure() {
        let gb: UInt64 = 1 << 30
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.timeIntervalSince1970 - 200 * 86_400
        let home = tree("me", 100 * gb, [
            tree("Library", 30 * gb, [
                tree("Caches", 6 * gb, [tree("Homebrew", 4 * gb), tree("com.example.app", 2 * gb)]),
                tree("Mail", 3 * gb),
                tree("Developer", 10 * gb, [tree("Xcode", 10 * gb, [tree("DerivedData", 10 * gb)])]),
            ]),
            tree("Documents", 20 * gb),
            tree("src", 30 * gb, modified: old, [
                tree("app", 30 * gb, modified: old, [tree("node_modules", 8 * gb, modified: now.timeIntervalSince1970), tree("Sources", 1 * gb, modified: old)]),
            ]),
            tree(".colima", 15 * gb),
        ])
        let apps = tree("Applications", 40 * gb)
        let volume = StorageVolume(capacity: 1000 * gb, available: 400 * gb, availableForImportant: 410 * gb, systemVolume: 15 * gb, vm: 5 * gb)
        let summary = StorageAnalysis.summarize(.init(volume: volume, roots: ["/Users/me": home, "/Applications": apps], home: "/Users/me",
                                                      now: now, exists: { _ in false }))
        let size = { (category: StorageCategory) in summary.segment(category)?.size ?? 0 }
        #expect(size(.apps) == 40 * gb)
        // DerivedData, Homebrew, node_modules and Colima.
        #expect(size(.developer) == (10 + 4 + 8 + 15) * gb)
        #expect(size(.mail) == 3 * gb)
        #expect(size(.purgeable) == 10 * gb)
        #expect(size(.free) == 400 * gb)
        // Every slice together is the whole disk.
        #expect(summary.segments.reduce(0) { $0 + $1.size } == volume.capacity)
        #expect(summary.row("caches")?.size == 2 * gb)
        #expect(summary.row("macos")?.size == 15 * gb)
        #expect(summary.row("unmeasured") != nil)
        // The project's own files have not changed in 200 days, so its node_modules could go.
        let modules = summary.reclaimable.first { $0.id == "node_modules" }
        #expect(modules?.entries.map(\.path) == ["/Users/me/src/app/node_modules"])
        #expect(summary.reclaimable.first { $0.id == "deriveddata" }?.size == 10 * gb)
        #expect(summary.reclaimable.first { $0.id == "caches" }?.entries.map(\.name) == ["com.example.app"])
    }

    @Test func buildFoldersNeedTheirProjectFile() {
        let gb: UInt64 = 1 << 30
        let home = tree("me", 4 * gb, [tree("rust", 2 * gb, [tree("target", 2 * gb)]), tree("notes", 2 * gb, [tree("target", 2 * gb)])])
        let volume = StorageVolume(capacity: 100 * gb, available: 50 * gb, availableForImportant: 50 * gb)
        let summary = StorageAnalysis.summarize(.init(volume: volume, roots: ["/Users/me": home], home: "/Users/me",
                                                      exists: { $0 == "/Users/me/rust/Cargo.toml" }))
        #expect(summary.row("target")?.paths == ["/Users/me/rust/target"])
        #expect(summary.segment(.developer)?.size == 2 * gb)
    }

    @Test func trashOnlyTakesFoldersInsideHome() {
        let scratch = Scratch()
        scratch.file("Library/Caches/app/f.bin", bytes: 10)
        #expect(StorageAccess.safeToTrash(scratch.path + "/Library/Caches/app", home: scratch.path))
        #expect(StorageAccess.safeToTrash(scratch.path + "/Library/Caches", home: scratch.path))
        #expect(!StorageAccess.safeToTrash(scratch.path + "/Library", home: scratch.path))
        #expect(!StorageAccess.safeToTrash(scratch.path, home: scratch.path))
        #expect(!StorageAccess.safeToTrash(scratch.path + "/Library/../Library/Caches", home: scratch.path))
        #expect(!StorageAccess.safeToTrash("/Applications/Safari.app", home: scratch.path))
        #expect(!StorageAccess.safeToTrash(scratch.path + "/Library/Caches/missing", home: scratch.path))
        try? FileManager.default.createSymbolicLink(atPath: scratch.path + "/Library/Caches/escape", withDestinationPath: "/Applications")
        #expect(!StorageAccess.safeToTrash(scratch.path + "/Library/Caches/escape", home: scratch.path))
    }

    // MARK: History

    @Test func growthNamesTheDeepestFolderThatExplainsIt() {
        let gb: UInt64 = 1 << 30
        let old: [String: UInt64] = ["/u": 100 * gb, "/u/Library": 40 * gb, "/u/Library/Docker": 20 * gb, "/u/Movies": 10 * gb]
        let new: [String: UInt64] = ["/u": 130 * gb, "/u/Library": 65 * gb, "/u/Library/Docker": 44 * gb, "/u/Movies": 15 * gb]
        let growth = SpaceHistory.growth(from: old, to: new, minimum: 2 * gb)
        #expect(growth.map(\.path) == ["/u/Library/Docker", "/u/Movies"])
        #expect(growth.first?.delta == Int64(24 * gb))
    }

    @Test func jumpsAreLabelledFromTheScansAroundThem() {
        let gb = Double(1 << 30)
        let hour = 480_000
        let free: [(hour: Int, value: Double)] = (0..<10).map { (hour + $0, $0 < 5 ? 100 * gb : 80 * gb) }
        let before = SpaceHistory.Snapshot(date: Date(timeIntervalSince1970: Double(hour) * 3600), sizes: ["/u/vm": 1 << 30])
        let after = SpaceHistory.Snapshot(date: Date(timeIntervalSince1970: Double(hour + 8) * 3600), sizes: ["/u/vm": 21 << 30])
        let jumps = SpaceHistory.jumps(free: free, threshold: 5 * gb, snapshots: [before, after])
        #expect(jumps.count == 1)
        #expect(jumps[0].from == hour + 4 && jumps[0].to == hour + 5)
        #expect(jumps[0].drop == 20 << 30)
        #expect(jumps[0].grew.first?.path == "/u/vm")
        // Without scans on both sides nothing is named.
        #expect(SpaceHistory.jumps(free: free, threshold: 5 * gb, snapshots: [after]).first?.grew.isEmpty == true)
    }

    @Test func snapshotsKeepOnePerDayAndForgetOldDays() {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var list: [SpaceHistory.Snapshot] = []
        for offset in [60, 3, 2] { list.append(.init(date: now.addingTimeInterval(-Double(offset) * day), sizes: [:])) }
        let merged = SpaceHistory.merge(list, .init(date: now, sizes: ["/x": 1]), now: now)
        #expect(merged.count == 3)
        #expect(merged.last?.sizes["/x"] == 1)
    }

    // MARK: System figures

    @Test func smartLogDecodes() throws {
        var log = [UInt8](repeating: 0, count: 512)
        log[1] = 0x38; log[2] = 0x01   // 312 K
        log[3] = 100
        log[5] = 2
        log[48] = 0x10; log[49] = 0x27  // 10,000 data units written
        log[128] = 0xC8                 // 200 hours
        let health = try #require(DiskHealth(log: log))
        #expect(health.celsius == 39)
        #expect(health.percentUsed == 2)
        #expect(health.bytesWritten == 10_000 * 512_000)
        #expect(health.powerOnHours == 200)
        #expect(DiskHealth(log: [1, 2, 3]) == nil)
    }

    @Test func snapshotListParses() {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-11-04-101010.local
        com.apple.os.update-ABCDEF
        """
        let snapshots = LocalSnapshot.parse(output)
        #expect(snapshots.map(\.kind) == ["Time Machine", "macOS update"])
        #expect(snapshots[0].date != nil && snapshots[1].date == nil)
    }

    @Test func eventPathsLoseTheDataVolumePrefix() {
        #expect(StorageIndex.normalize("/System/Volumes/Data/Users/me/x/") == "/Users/me/x")
        #expect(StorageIndex.normalize("/Applications") == "/Applications")
    }

    @Test func volumeFiguresAreConsistent() {
        let volume = StorageVolume.read()
        #expect(volume.capacity > 0)
        #expect(volume.available <= volume.capacity)
        #expect(volume.availableForImportant >= volume.available)
        #expect(StorageVolume.spaceUsed("/System/Volumes/Data/Users") == nil)
    }
}
