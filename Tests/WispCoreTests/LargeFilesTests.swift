import Foundation
import Testing
@testable import WispCore

/// Serialized: each scan blocks its thread while it waits for the hashing queue, and many at
/// once can starve the test runner's threads.
@Suite(.serialized) struct LargeFilesTests {
    /// A fake home folder that goes away with the test.
    final class Home {
        let path: String
        init() {
            path = (FileManager.default.temporaryDirectory.appendingPathComponent("wisp-large-\(UUID().uuidString)").path as NSString)
                .resolvingSymlinksInPath
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        @discardableResult
        func file(_ relative: String, bytes: Int) -> Data {
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            write(relative, data)
            return data
        }

        func write(_ relative: String, _ data: Data) {
            let url = URL(fileURLWithPath: path + "/" + relative)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }

        func folder(_ relative: String) {
            try? FileManager.default.createDirectory(atPath: path + "/" + relative, withIntermediateDirectories: true)
        }

        func allocated(_ relative: String) -> Int64 {
            Int64((try? URL(fileURLWithPath: path + "/" + relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }

        var context: CleanScanContext { CleanScanContext(home: URL(fileURLWithPath: path)) }
    }

    static var limits: LargeFilesScanner.Limits {
        var limits = LargeFilesScanner.Limits()
        limits.largeFile = 100_000
        limits.duplicate = 50_000
        limits.knownModel = 50_000
        limits.unknownModel = 100_000
        return limits
    }

    func scan(_ home: Home, duplicates: Bool = false, environment: [String: String] = [:]) -> LargeFilesReport {
        LargeFilesScanner(findDuplicates: duplicates, limits: Self.limits, environment: environment, index: LargeFileIndex())
            .report(home.context)
    }

    func groups(_ report: LargeFilesReport) -> [String: String] {
        Dictionary(report.items.map { ($0.name, $0.group) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Large files

    @Test func filesLandInTheirCategories() {
        let home = Home()
        home.file("Downloads/trip.mov", bytes: 150_000)
        home.file("Music/song.mp3", bytes: 150_000)
        home.file("Pictures/photo.heic", bytes: 150_000)
        home.file("Documents/tax.pdf", bytes: 150_000)
        home.file("Documents/old/backup.zip", bytes: 150_000)
        home.file("Documents/report.docx", bytes: 150_000)
        home.file("Desktop/weights.gguf", bytes: 150_000)
        home.file("Downloads/iPhone.ipsw", bytes: 150_000)
        home.file("Downloads/setup.dmg.crdownload", bytes: 150_000)
        home.file("Downloads/movie.mkv.part", bytes: 150_000)
        home.file("Downloads/Xcode.xip.download/Xcode.xip", bytes: 150_000)
        home.file("Desktop/mystery.xyz", bytes: 150_000)
        home.file("Documents/small.mov", bytes: 20_000)
        home.file("Library/Mobile Documents/com~apple~CloudDocs/Trips/clip.mp4", bytes: 150_000)

        let report = scan(home)
        let byName = groups(report)
        #expect(byName["trip.mov"] == "Videos")
        #expect(byName["song.mp3"] == "Audio")
        #expect(byName["photo.heic"] == "Images")
        #expect(byName["tax.pdf"] == "PDFs")
        #expect(byName["backup.zip"] == "Archives")
        #expect(byName["report.docx"] == "Documents")
        #expect(byName["weights.gguf"] == "AI models")
        #expect(byName["iPhone.ipsw"] == "Restore images")
        #expect(byName["setup.dmg.crdownload"] == "Unfinished downloads")
        #expect(byName["movie.mkv.part"] == "Unfinished downloads")
        #expect(byName["Xcode.xip.download"] == "Unfinished downloads")
        #expect(byName["Xcode.xip"] == nil)
        #expect(byName["mystery.xyz"] == "Other")
        #expect(byName["small.mov"] == nil)

        let zip = report.items.first { $0.name == "backup.zip" }!
        #expect(zip.detail == "ZIP archive in ~/Documents/old.")
        #expect(zip.safety == .checkFirst && zip.removal == .trash && !zip.checkedByDefault)
        #expect(zip.paths == [home.path + "/Documents/old/backup.zip"])
        #expect(zip.bytes == home.allocated("Documents/old/backup.zip"))
        #expect(LargeFilesScanner.path(fromID: zip.id) == zip.paths[0])
        #expect(report.info[zip.id]?.category == .archives)
        #expect(report.info[zip.id]?.isICloud == false)
        #expect(report.items.allSatisfy { $0.tab == .largeFiles })

        let clip = report.items.first { $0.name == "clip.mp4" }!
        #expect(report.info[clip.id]?.isICloud == true)
        #expect(clip.detail.hasPrefix("Video in iCloud Drive/Trips."))
    }

    @Test func virtualMachineIsOneRowAndOnlyBundlesCountInVMFolders() {
        let home = Home()
        home.file("Parallels/Windows 11.pvm/harddisk.hdd/disk.hds", bytes: 120_000)
        home.file("Parallels/Windows 11.pvm/config.pvs", bytes: 60_000)
        home.file("Parallels/loose.iso", bytes: 150_000)
        home.file("Virtual Machines.localized/Ubuntu.vmwarevm/disk.vmdk", bytes: 150_000)
        home.file("Documents/VMs/Linux.utm/Data/disk.qcow2", bytes: 150_000)

        let report = scan(home)
        let vms = report.items.filter { $0.group == "Virtual machines" }
        #expect(Set(vms.map(\.name)) == ["Windows 11.pvm", "Ubuntu.vmwarevm", "Linux.utm"])
        let windows = vms.first { $0.name == "Windows 11.pvm" }!
        #expect(windows.paths == [home.path + "/Parallels/Windows 11.pvm"])
        #expect(windows.bytes == home.allocated("Parallels/Windows 11.pvm/harddisk.hdd/disk.hds")
            + home.allocated("Parallels/Windows 11.pvm/config.pvs"))
        #expect(windows.detail == "Parallels virtual machine in ~/Parallels. Everything inside the virtual machine goes with it.")
        #expect(!report.items.contains { $0.name == "loose.iso" || $0.name == "disk.hds" || $0.name == "disk.qcow2" })
    }

    @Test func managedLibrariesHiddenAndBuildFoldersAreSkipped() {
        let home = Home()
        home.file("Pictures/Photos Library.photoslibrary/originals/A/big.heic", bytes: 150_000)
        home.file("Movies/iMovie Library.imovielibrary/clip.mov", bytes: 150_000)
        home.file("Movies/Project.fcpbundle/render.mov", bytes: 150_000)
        home.file("Movies/TV/Media/show.m4v", bytes: 150_000)
        home.file("Music/Music/Media.localized/song.m4a", bytes: 150_000)
        home.file("Music/iTunes/iTunes Media/song2.m4a", bytes: 150_000)
        home.file("Pictures/Lightroom/Catalog.lrcat", bytes: 150_000)
        home.file("Pictures/Lightroom/Catalog Previews.lrdata/p.jpg", bytes: 150_000)
        home.file("Documents/app/node_modules/pkg/blob.zip", bytes: 150_000)
        home.file("Documents/app/.git/objects/pack.pack", bytes: 150_000)
        home.file("Documents/rust/target/debug/app", bytes: 150_000)
        home.file("Documents/.secret/video.mov", bytes: 150_000)
        home.file("Documents/.hidden.mov", bytes: 150_000)
        home.file("Documents/keep.mov", bytes: 150_000)

        let report = scan(home)
        #expect(report.items.map(\.name) == ["keep.mov"])
    }

    @Test func excludedPathsAreLeftAlone() {
        let home = Home()
        home.file("Documents/private/video.mov", bytes: 150_000)
        home.file("Documents/video.mov", bytes: 150_000)
        let context = CleanScanContext(home: URL(fileURLWithPath: home.path), excluded: [home.path + "/Documents/private"])
        let report = LargeFilesScanner(findDuplicates: false, limits: Self.limits, environment: [:], index: LargeFileIndex()).report(context)
        #expect(report.items.map(\.paths) == [[home.path + "/Documents/video.mov"]])
    }

    @Test func topLevelLinksIntoHomeAreFollowedAndDeeperLinksAreNot() throws {
        let home = Home()
        home.file("Storage/Footage/raw.mov", bytes: 150_000)
        home.file("Storage/Elsewhere/other.mov", bytes: 150_000)
        home.folder("Movies")
        home.folder("Documents/sub")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Movies/Footage", withDestinationPath: home.path + "/Storage/Footage")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Documents/sub/link", withDestinationPath: home.path + "/Storage/Elsewhere")
        let outside = Home()
        outside.file("far.mov", bytes: 150_000)
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Documents/outside", withDestinationPath: outside.path)

        let report = scan(home)
        #expect(report.items.map(\.paths) == [[home.path + "/Movies/Footage/raw.mov"]])
    }

    @Test func streamsBatchesThroughFound() {
        let home = Home()
        for index in 0..<5 { home.file("Downloads/file\(index).zip", bytes: 120_000) }
        final class Streamed: @unchecked Sendable {
            let lock = NSLock()
            var items: [CleanItem] = []
        }
        let streamed = Streamed()
        let context = CleanScanContext(home: URL(fileURLWithPath: home.path), found: { batch in streamed.lock.withLock { streamed.items += batch } })
        let index = LargeFileIndex()
        let items = LargeFilesScanner(findDuplicates: false, limits: Self.limits, environment: [:], index: index).scan(context)
        #expect(Set(streamed.items.map(\.id)) == Set(items.map(\.id)))
        #expect(items.count == 5)
        #expect(index.info(for: items[0].id)?.category == .archives)
        #expect(index.duplicates.skipped)
    }

    // MARK: Duplicates

    @Test func duplicatesNeedTheSameBytesAndHardLinksDoNotCount() throws {
        let home = Home()
        let original = home.file("Documents/Taxes/return.pdf", bytes: 300_000)
        home.write("Downloads/return copy.pdf", original)
        home.write("Desktop/return again.pdf", original)
        // Same size, same first and last 64 KB, one byte apart in the middle.
        var nearly = original
        nearly[150_000] ^= 0xFF
        home.write("Downloads/nearly.pdf", nearly)
        // Same size, different everywhere.
        home.file("Downloads/other.pdf", bytes: 300_000)
        // Two names for one file.
        home.file("Pictures/album.jpg", bytes: 200_000)
        try FileManager.default.linkItem(atPath: home.path + "/Pictures/album.jpg", toPath: home.path + "/Documents/album link.jpg")
        // Copies inside a git working tree are the project's business.
        let vendored = home.file("Desktop/app/vendor/lib.dylib", bytes: 200_000)
        home.write("Desktop/app/build/deep/lib.dylib", vendored)
        home.folder("Desktop/app/.git")

        let report = scan(home, duplicates: true)
        let groups = report.duplicates.groups
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.keeper == home.path + "/Documents/Taxes/return.pdf")
        #expect(Set(group.paths) == Set(["Documents/Taxes/return.pdf", "Downloads/return copy.pdf", "Desktop/return again.pdf"]
            .map { home.path + "/" + $0 }))
        #expect(group.reclaimable == home.allocated("Downloads/return copy.pdf") + home.allocated("Desktop/return again.pdf"))
        #expect(!report.duplicates.stoppedAtLimit)

        let rows = report.items.filter { $0.group == duplicatesGroup }
        #expect(rows.count == 3)
        let keeperRow = try #require(rows.first { $0.paths == [group.keeper] })
        #expect(!keeperRow.checkedByDefault)
        #expect(report.info[keeperRow.id]?.isSuggestedKeeper == true)
        #expect(rows.filter(\.checkedByDefault).count == 2)
        #expect(rows.allSatisfy { report.info[$0.id]?.duplicateGroup == group.id && report.info[$0.id]?.category == .pdfs })
        #expect(rows.first { $0.name == "return copy.pdf" }?.detail
            == "Identical copy in ~/Downloads. The copy in ~/Documents/Taxes stays.")
    }

    @Test func removalMustKeepOneCopy() {
        let home = Home()
        let data = home.file("Documents/a.bin", bytes: 200_000)
        home.write("Downloads/a.bin", data)
        let index = LargeFileIndex()
        let items = LargeFilesScanner(findDuplicates: true, limits: Self.limits, environment: [:], index: index).scan(home.context)
        let copies = items.filter { $0.group == duplicatesGroup }
        #expect(copies.count == 2)
        let large = items.filter { $0.group != duplicatesGroup }.map(\.id)
        #expect(index.keepsACopy(Set(copies.filter(\.checkedByDefault).map(\.id))))
        #expect(!index.keepsACopy(Set(copies.map(\.id))))
        // A large-file row for the keeper's path counts as removing that copy too.
        #expect(!index.keepsACopy(Set(copies.filter(\.checkedByDefault).map(\.id) + large)))
    }

    @Test func hashingStopsAtTheByteLimitAndCanBeSkipped() {
        let home = Home()
        let data = home.file("Documents/a.bin", bytes: 400_000)
        home.write("Downloads/a.bin", data)
        var limits = Self.limits
        limits.hashedBytes = 200_000
        let limited = LargeFilesScanner(findDuplicates: true, limits: limits, environment: [:], index: LargeFileIndex()).report(home.context)
        #expect(limited.duplicates.stoppedAtLimit)
        #expect(limited.duplicates.groups.isEmpty)
        #expect(limited.duplicates.note != nil)

        let skipped = scan(home, duplicates: false)
        #expect(skipped.duplicates.skipped)
        #expect(!skipped.items.contains { $0.group == duplicatesGroup })
    }

    @Test func keeperPrefersDocumentsThenTheOldestCopy() {
        func candidate(_ path: String, rank: Int, created: Double) -> DuplicateCandidate {
            DuplicateCandidate(path: path, length: 10, allocated: 16, device: 1, fileID: UInt64(path.count), cloneID: 0,
                               created: created, modified: created, accessed: created, placeRank: rank, isICloud: false)
        }
        let group = DuplicateFinder.group([candidate("/h/Downloads/x", rank: 2, created: 1), candidate("/h/Documents/x", rank: 0, created: 5),
                                           candidate("/h/Pictures/older/x", rank: 0, created: 2)], digest: "ab")
        #expect(group.paths == ["/h/Pictures/older/x", "/h/Documents/x", "/h/Downloads/x"])
        #expect(group.reclaimable == 32)
    }

    // MARK: AI models

    func manifest(_ digests: [String]) -> Data {
        let layers = digests.dropFirst().map { "{\"mediaType\":\"application/vnd.ollama.image.model\",\"digest\":\"\($0)\",\"size\":1}" }
        let json = "{\"schemaVersion\":2,\"config\":{\"digest\":\"\(digests[0])\",\"size\":1},\"layers\":[\(layers.joined(separator: ","))]}"
        return Data(json.utf8)
    }

    @Test func ollamaCountsOnlyBlobsNoOtherModelShares() throws {
        let home = Home()
        let models = ".ollama/models"
        home.file("\(models)/blobs/sha256-shared", bytes: 200_000)
        home.file("\(models)/blobs/sha256-llama", bytes: 300_000)
        home.file("\(models)/blobs/sha256-mistral", bytes: 100_000)
        home.file("\(models)/blobs/sha256-cfg1", bytes: 1_000)
        home.file("\(models)/blobs/sha256-cfg2", bytes: 1_000)
        let library = "\(models)/manifests/registry.ollama.ai/library"
        home.write("\(library)/llama3.1/8b", manifest(["sha256:cfg1", "sha256:shared", "sha256:llama"]))
        home.write("\(library)/llama3.1/latest", manifest(["sha256:cfg1", "sha256:shared", "sha256:llama"]))
        home.write("\(library)/mistral/7b", manifest(["sha256:cfg2", "sha256:shared", "sha256:mistral"]))

        let rows = scan(home).items.filter { $0.group == "AI models" }
        #expect(rows.count == 2)
        let llama = try #require(rows.first { $0.name == "llama3.1:8b, llama3.1:latest" })
        #expect(llama.bytes == home.allocated("\(models)/blobs/sha256-llama") + home.allocated("\(models)/blobs/sha256-cfg1"))
        #expect(llama.paths.contains(home.path + "/\(models)/blobs/sha256-llama"))
        #expect(llama.paths.contains(home.path + "/\(library)/llama3.1/latest"))
        #expect(!llama.paths.contains(home.path + "/\(models)/blobs/sha256-shared"))
        #expect(llama.detail.contains("shares with other models stays"))
        #expect(llama.safety == .checkFirst && !llama.checkedByDefault && llama.removal == .trash)
        let mistral = try #require(rows.first { $0.name == "mistral:7b" })
        #expect(mistral.bytes == home.allocated("\(models)/blobs/sha256-mistral") + home.allocated("\(models)/blobs/sha256-cfg2"))

        #expect(AIModelFinder.ollamaName(["registry.ollama.ai", "jmorgan", "phi", "q4"]) == "jmorgan/phi:q4")
        #expect(AIModelFinder.ollamaName(["hf.co", "bartowski", "Qwen-GGUF", "Q4_K_M"]) == "hf.co/bartowski/Qwen-GGUF:Q4_K_M")
    }

    @Test func huggingFaceRowsAreNamedAfterTheRepoAndCountBlobsOnce() throws {
        let home = Home()
        let repo = ".cache/huggingface/hub/models--meta-llama--Llama-3.1-8B"
        home.file("\(repo)/blobs/abc123", bytes: 200_000)
        home.folder("\(repo)/snapshots/rev1")
        home.folder("\(repo)/snapshots/rev2")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/\(repo)/snapshots/rev1/model.safetensors",
                                                   withDestinationPath: "../../blobs/abc123")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/\(repo)/snapshots/rev2/model.safetensors",
                                                   withDestinationPath: "../../blobs/abc123")
        home.file("elsewhere/hub/models--openai--whisper-large-v3/blobs/def", bytes: 150_000)

        let rows = scan(home, environment: ["HF_HUB_CACHE": home.path + "/elsewhere/hub"]).items.filter { $0.group == "AI models" }
        let llama = try #require(rows.first { $0.name == "meta-llama/Llama-3.1-8B" })
        #expect(llama.bytes == home.allocated("\(repo)/blobs/abc123"))
        #expect(llama.paths == [home.path + "/" + repo])
        #expect(rows.contains { $0.name == "openai/whisper-large-v3" })
        #expect(rows.count == 2)
        #expect(AIModelFinder.huggingFaceName("models--gpt2") == "gpt2")
        #expect(AIModelFinder.huggingFaceName("datasets--squad") == nil)
    }

    @Test func otherStoresAndLooseWeights() throws {
        let home = Home()
        home.file(".lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf", bytes: 120_000)
        home.file(".cache/whisper/large-v3.pt", bytes: 120_000)
        home.file("Library/Application Support/Painter/models/sdxl/1.0/unet.safetensors", bytes: 150_000)
        home.file("Library/Application Support/Painter/models/sdxl/1.0/vae.safetensors", bytes: 150_000)
        home.file("Library/Application Support/SomeGame/data/level.bin", bytes: 150_000)
        home.file("Library/Caches/Helper/model-cache/encoder.bin", bytes: 150_000)
        home.file("Library/Application Support/com.apple.siri.inference/model.bin", bytes: 150_000)

        let rows = scan(home).items.filter { $0.group == "AI models" }
        let names = Set(rows.map(\.name))
        #expect(names == ["lmstudio-community/Qwen3-8B-GGUF", "Whisper large-v3", "sdxl", "model-cache"])
        let sdxl = try #require(rows.first { $0.name == "sdxl" })
        #expect(sdxl.paths.count == 2)
        #expect(sdxl.detail == "Model weights kept by Painter in ~/Library/Application Support/Painter/models/sdxl/1.0. "
            + "Painter may still list the model as installed.")
        let studio = try #require(rows.first { $0.name.hasPrefix("lmstudio") })
        #expect(studio.detail.contains("LM Studio may still list it as installed"))
    }

    @Test func cancelledScanStopsEarly() {
        let home = Home()
        home.file("Documents/a.mov", bytes: 150_000)
        let context = CleanScanContext(home: URL(fileURLWithPath: home.path), isCancelled: { true })
        let report = LargeFilesScanner(limits: Self.limits, environment: [:], index: LargeFileIndex()).report(context)
        #expect(report.items.isEmpty)
    }

    /// The real home folder, read-only: `WISP_LARGE_FILES_LIVE=1 swift test --filter LargeFilesTests/liveScan`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_LARGE_FILES_LIVE"] == "1"))
    func liveScan() {
        for duplicates in [false, true] {
            let report = LargeFilesScanner(findDuplicates: duplicates, index: LargeFileIndex()).report(CleanScanContext())
            print("duplicates \(duplicates): \(report.items.count) rows in \(String(format: "%.1f", report.seconds)) s")
            for (group, items) in Dictionary(grouping: report.items, by: \.group).sorted(by: { $0.key < $1.key }) {
                print("  \(group): \(items.count), \(Format.bytes(UInt64(items.reduce(0) { $0 + $1.bytes })))")
            }
            let summary = report.duplicates
            print("  duplicate groups \(summary.groups.count), reclaimable \(Format.bytes(UInt64(summary.reclaimable))), "
                + "hashed \(Format.bytes(UInt64(summary.hashedBytes))), stopped at limit \(summary.stoppedAtLimit)")
        }
    }
}
