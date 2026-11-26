import Foundation
import Testing
@testable import WispCore

@Suite struct StorageScanTests {
    typealias Scratch = StorageTests.Scratch

    /// Every node with its path, size and file count, for comparing two trees.
    private func shape(_ node: FolderNode) -> [String: String] {
        var result = ["": "\(node.size) \(node.files) \(node.otherSize) \(node.otherCount)"]
        node.walk { child, path in
            result[path] = "\(child.size) \(child.files) \(child.otherSize) \(child.otherCount) \(child.isFile) \(child.locked)"
            return true
        }
        return result
    }

    /// A walk split over threads gives the tree one thread gives, folder for folder.
    @Test func splitWalkMatchesOneThread() {
        let scratch = Scratch()
        for top in 0..<6 {
            for middle in 0..<(top + 2) {
                for leaf in 0..<3 { scratch.file("t\(top)/m\(middle)/l\(leaf)/f.bin", bytes: 4_000 * (top + 1) + leaf) }
                scratch.file("t\(top)/m\(middle)/own.bin", bytes: 30_000)
            }
        }
        scratch.file("deep/a/b/c/d/e/f/g/h/i/j/f.bin", bytes: 90_000)
        var rules = FolderScanner.Rules()
        rules.smallestFolder = 20_000
        rules.keepChildren = 3
        rules.threads = 1
        let one = FolderScanner(rules: rules).scan(scratch.path)
        rules.threads = 4
        for _ in 0..<5 {
            let split = FolderScanner(rules: rules).scan(scratch.path)
            #expect(shape(split) == shape(one))
        }
        #expect(one.files == (2 + 3 + 4 + 5 + 6 + 7) * 4 + 1)
        #expect(FolderScanner(rules: rules).folder(at: scratch.path, threads: 4).size == one.size)
    }

    /// Partial trees arrive while a split walk runs, and never add up to more than the end result.
    @Test func splitWalkSendsPartialTrees() {
        let scratch = Scratch()
        for index in 0..<300 { scratch.file("f\(index % 30)/g\(index)/x.bin", bytes: 1_000) }
        var rules = FolderScanner.Rules()
        rules.threads = 3
        let scanner = FolderScanner(rules: rules)
        let lock = NSLock()
        var sizes: [UInt64] = []
        scanner.progressInterval = 0
        let node = scanner.scan(scratch.path) { partial in lock.withLock { sizes.append(partial.size) } }
        #expect(node.files == 300)
        #expect(lock.withLock { sizes.allSatisfy { $0 <= node.size } })
    }

    /// A stopped walk returns at once with what it read.
    @Test func stoppedWalkReturns() {
        let scratch = Scratch()
        for index in 0..<200 { scratch.file("f\(index)/x.bin", bytes: 1_000) }
        let flag = ScanFlag()
        flag.set()
        var rules = FolderScanner.Rules()
        rules.threads = 4
        let node = FolderScanner(rules: rules, cancel: flag).scan(scratch.path)
        #expect(node.files < 200)
    }

    /// A clone counts once in all, also when one of its folders is read again on its own.
    @Test func clonesCountOnceAcrossRefreshes() throws {
        let scratch = Scratch()
        scratch.file("a/original.bin", bytes: 400_000)
        try FileManager.default.createDirectory(atPath: scratch.path + "/b", withIntermediateDirectories: true)
        try #require(clonefile(scratch.path + "/a/original.bin", scratch.path + "/b/copy.bin", 0) == 0)
        let once = scratch.allocated("a/original.bin")
        var rules = FolderScanner.Rules()
        rules.smallestFolder = 0
        let root = FolderScanner(rules: rules).scan(scratch.path)
        #expect(root.size == once)
        let a = try #require(root.child("a"))
        // b was folded away; a new scanner reads it again next to the a it keeps.
        let old = FolderNode(name: root.name, size: root.size, files: root.files, children: [a])
        let again = FolderScanner(rules: rules).refresh(old, at: scratch.path)
        #expect(again.size == once)
    }

    @Test func cacheKeepsTheEventDatabase() throws {
        let cache = StorageIndex.Cache(eventID: 7, date: Date(), roots: ["/r": FolderNode(name: "r", size: 1)], seconds: [:],
                                       fullDiskAccess: false, eventsUUID: "ABC")
        let data = try #require(StorageCacheFile.encode(cache))
        let back = try #require(StorageCacheFile.decode(data))
        #expect(back.eventsUUID == "ABC" && back.eventID == 7)
    }

    /// A saved place from another FSEvents database is not replayed: the roots are measured again.
    @Test func cacheFromAnotherEventDatabaseIsMeasuredAgain() async throws {
        let scratch = Scratch()
        scratch.file("a/real.bin", bytes: 200_000)
        let cacheURL = URL(fileURLWithPath: scratch.path + "-cache.bin")
        let historyURL = URL(fileURLWithPath: scratch.path + "-sizes.json")
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: historyURL)
        }
        let made = FolderNode(name: "root", size: 12_345, files: 1)
        let cache = StorageIndex.Cache(eventID: FSEventsGetCurrentEventId(), date: Date(), roots: [scratch.path: made], seconds: [:],
                                       fullDiskAccess: StorageAccess.hasFullDiskAccess, eventsUUID: "not-this-database")
        try #require(StorageCacheFile.encode(cache)).write(to: cacheURL)
        let lock = NSLock()
        var latest: StorageState?
        let index = StorageIndex(home: "/nonexistent", roots: [scratch.path], cacheURL: cacheURL, historyURL: historyURL,
                                 callbackQueue: DispatchQueue(label: "test.storage.uuid"))
        index.onChange = { state in lock.withLock { latest = state } }
        index.open()
        func size() -> UInt64? { lock.withLock { latest?.scanning == nil ? latest?.roots[scratch.path]?.size : nil } }
        for _ in 0..<200 where size() == nil || size() == 12_345 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(size() == scratch.allocated("a/real.bin"))
        index.close()
    }

    @Test func startupDiskContainerIsNamed() {
        #expect(StorageVolume.container(of: "/")?.hasPrefix("disk") == true)
        #expect(StorageVolume.container(of: "/System/Volumes/Data") == StorageVolume.container(of: "/"))
    }

    /// An app that is a link (Safari is one, into a cryptex) is measured where the link leads.
    @Test func linkedAppIsMeasured() throws {
        let scratch = Scratch()
        scratch.file("Real/Linked.app/Contents/MacOS/Linked", bytes: 120_000)
        try FileManager.default.createDirectory(atPath: scratch.path + "/Applications", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: scratch.path + "/Applications/Linked.app",
                                                   withDestinationPath: scratch.path + "/Real/Linked.app")
        let storage = AppStorage.measure(bundlePath: scratch.path + "/Applications/Linked.app", home: scratch.path, fullDiskAccess: false)
        #expect(storage.parts.first?.size == scratch.allocated("Real/Linked.app/Contents/MacOS/Linked"))
        #expect(storage.parts.first?.paths == [scratch.path + "/Applications/Linked.app"])
    }
}
