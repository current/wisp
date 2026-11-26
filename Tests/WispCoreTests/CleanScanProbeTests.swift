import Darwin
import Foundation
import Testing
@testable import WispCore

/// Times one Clean Up scanner on the real home folder, read-only:
/// `WISP_PROBE=1 WISP_CLEAN_PROBE=large swift test -c release -Xswiftc -enable-testing --filter probeCleanScanner`.
/// Prints one line of figures and, with WISP_CLEAN_PROBE_OUT, writes the items as JSON for comparing two builds.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil && ProcessInfo.processInfo.environment["WISP_CLEAN_PROBE"] != nil))
func probeCleanScanner() throws {
    let environment = ProcessInfo.processInfo.environment
    let name = environment["WISP_CLEAN_PROBE"] ?? ""
    let days = TimeInterval(CleanSettings.load().staleProjectDays) * 86_400
    let scanners: [String: [any CleanScanner]] = [
        "appcache": [AppCacheScanner()], "systemjunk": [SystemJunkScanner()], "installer": [InstallerScanner()],
        "snapshot": [LocalSnapshotScanner()], "devcache": [DeveloperCacheScanner()], "simulator": [SimulatorScanner()],
        "projects": [ProjectArtifactScanner(staleAfter: days)], "worktrees": [WorktreeScanner(staleAfter: days)],
        "leftovers": [LeftoversScanner()], "large": [LargeFilesScanner()], "largenodup": [LargeFilesScanner(findDuplicates: false)],
        "junk": CleanRegistry.scanners(for: .junk), "developer": CleanRegistry.scanners(for: .developer),
    ]
    func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
    func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    let before = footprint()
    let cpuStart = cpu()
    let start = Date()
    var firstBatch: Double?
    let lock = NSLock()
    let context = CleanScanContext(excluded: CleanSettings.load().exclusions, found: { batch in
        lock.withLock { if firstBatch == nil, !batch.isEmpty { firstBatch = Date().timeIntervalSince(start) } }
    })
    var items: [CleanItem] = []
    // As the page runs them: every tab at once, at utility priority, each tab's time on its own.
    if name == "page" {
        let group = DispatchGroup()
        let results = NSLock()
        var times: [String: Double] = [:]
        for tab in CleanListing.defaultTabs {
            DispatchQueue.global(qos: .utility).async(group: group) {
                let found = CleanRegistry.scan([tab], context: context)
                results.withLock {
                    items += found
                    times[tab.rawValue] = Date().timeIntervalSince(start)
                }
            }
        }
        group.wait()
        print("PAGE " + times.sorted { $0.key < $1.key }.map { String(format: "%@ %.2f s", $0.key, $0.value) }.joined(separator: ", "))
    } else if environment["WISP_CLEAN_PROBE_QOS"] == "utility", name != "uninstall" {
        let list = try #require(scanners[name], "unknown scanner \(name)")
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            items = CleanRegistry.scan(Array(Set(list.map(\.tab))), context: context, using: list)
        }
        group.wait()
    } else if name == "uninstall" {
        let busy = InstalledApps.runningBundlePaths()
        var apps = InstalledApps.scan(measure: false, isRunning: { busy.contains($1) })
        let flag = ScanFlag()
        for index in apps.indices { apps[index].bundleBytes = InstalledApps.bundleBytes(apps[index].path, cancel: flag) }
        items = apps.map { CleanItem(id: "app:" + $0.path, tab: .uninstall, group: "Apps", name: $0.name, detail: $0.bundleID,
                                     paths: [$0.path], bytes: $0.bundleBytes, safety: .checkFirst) }
    } else {
        let list = try #require(scanners[name], "unknown scanner \(name)")
        items = CleanRegistry.scan(Array(Set(list.map(\.tab))), context: context, using: list)
    }
    let wall = Date().timeIntervalSince(start)
    let used = cpu() - cpuStart
    let after = footprint()
    let peak = Double(after.peak > before.now ? after.peak - before.now : 0) / 1e6
    let entries = CleanScanCounters.entries.load(ordering: .relaxed)
    let folders = CleanScanCounters.folders.load(ordering: .relaxed)
    print(String(format: "PROBE %@ wall %.2f s cpu %.2f s peak +%.0f MB entries %d folders %d items %d bytes %lld first %.2f s",
                 name, wall, used, peak, entries, folders, items.count, items.totalBytes, firstBatch ?? -1))
    if let out = environment["WISP_CLEAN_PROBE_OUT"] {
        let rows = items.sorted { $0.id < $1.id }.map { ["id": $0.id, "bytes": String($0.bytes), "paths": $0.paths.joined(separator: "|"),
                                                         "safety": $0.safety == .safe ? "safe" : "check", "checked": String($0.checkedByDefault)] }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
    }
}

/// Old against new folder sizing on the same paths, in turn:
/// `WISP_PROBE=1 WISP_SIZER_PATHS=~/.cache:~/.npm swift test -c release -Xswiftc -enable-testing --filter probeSizer`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil && ProcessInfo.processInfo.environment["WISP_SIZER_PATHS"] != nil))
func probeSizer() {
    let environment = ProcessInfo.processInfo.environment
    let paths = (environment["WISP_SIZER_PATHS"] ?? "").split(separator: ":").map { ($0 as NSString).expandingTildeInPath }
    let rounds = Int(environment["WISP_SIZER_ROUNDS"] ?? "3") ?? 3
    func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    func time(_ label: String, _ body: () -> Int64) {
        let start = Date()
        let cpuStart = cpu()
        let bytes = body()
        print(String(format: "SIZER %@ wall %.2f s cpu %.2f s bytes %lld", label, Date().timeIntervalSince(start), cpu() - cpuStart, bytes))
    }
    for _ in 0..<rounds {
        time("old") {
            var rules = FolderScanner.Rules()
            rules.keepChildren = 0
            rules.smallestFolder = .max
            rules.smallestFile = .max
            let lock = NSLock()
            var total: Int64 = 0
            var next = 0
            DispatchQueue.concurrentPerform(iterations: min(4, paths.count)) { _ in
                while true {
                    let index: Int? = lock.withLock { defer { next += 1 }; return next < paths.count ? next : nil }
                    guard let index else { return }
                    let size = Int64(FolderScanner(rules: rules).folder(at: paths[index]).size)
                    lock.withLock { total += size }
                }
            }
            return total
        }
        for threads in [Int(environment["WISP_SIZER_THREADS"] ?? "4") ?? 4] {
            time("new\(threads)") {
                let sizer = CleanSizer(cache: nil)
                sizer.threads = threads
                return sizer.sizes(paths).values.reduce(0) { $0 + $1.bytes }
            }
        }
    }
}
