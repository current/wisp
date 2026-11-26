import Darwin
import Foundation
import Testing
@testable import WispCore

/// What a clean's checks cost on this Mac, reading only: nothing is removed, git is not run
/// (a plain git status can rewrite an index) and the Trash is never called.
/// `WISP_SAFETY_PROBE=1 swift test --filter CleanSafetyProbe`.
@Suite(.serialized) struct CleanSafetyProbe {
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    static func peak() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    static func time(_ label: String, runs: Int = 5, _ body: () -> String) {
        var walls: [Double] = [], cpus: [Double] = []
        var note = ""
        for _ in 0..<runs {
            let wall = Date(), cpu = cpu()
            note = body()
            walls.append(Date().timeIntervalSince(wall) * 1000)
            cpus.append(Self.cpu() - cpu)
        }
        print(String(format: "NEW  %-28@ wall %8.1f ms  cpu %8.1f ms  peak %6.0f MB  %@", label as NSString, median(walls), median(cpus), peak(), note as NSString))
    }

    static let home = NSHomeDirectory()
    static var paths: [(String, String)] {
        [("pnpm store", home + "/Library/pnpm/store"), ("Homebrew cache", home + "/Library/Caches/Homebrew"),
         ("CocoaPods cache", home + "/Library/Caches/CocoaPods"), ("Google cache", home + "/Library/Caches/Google"),
         ("node_modules", home + "/code/underhand-site/node_modules"), ("Downloads dmg", home + "/Downloads/helium_0.22.2.1_arm64-macos.dmg")]
    }

    static var guards: CleanGuards {
        var guards = CleanGuards.live
        guards.gitState = { _ in .clean }
        guards.gitTracks = { _, _ in false }
        guards.trash = { path in Issue.record("the probe tried to remove \(path)") }
        guards.lockFile = nil
        return guards
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_SAFETY_PROBE"] != nil))
    func checks() {
        Self.time("ProcessUse.snapshot") {
            let use = ProcessUse.snapshot()
            return "running bundles \(use.runningBundlePaths.count), images \(use.diskImages?.count ?? -1), mounts \(use.mountPoints.count)"
        }
        for (label, path) in Self.paths where FileManager.default.fileExists(atPath: path) {
            Self.time("dependents " + label, runs: 3) {
                let context = CleanDependents.Context(home: Self.home)
                let found = CleanDependents.dependent(of: [path], home: Self.home, context: context) ?? "none"
                return found + " (\(context.entriesRead) entries)"
            }
        }
        let cleaner = Cleaner(home: Self.home, guards: Self.guards)
        let items = Self.paths.filter { FileManager.default.fileExists(atPath: $0.1) }.map {
            CleanItem(id: "probe:" + $0.1, tab: .junk, group: "Probe", name: $0.0, detail: "", paths: [$0.1], bytes: 0, safety: .safe).stamped()
        }
        Self.time("skip reasons, \(items.count) items", runs: 3) {
            let session = Cleaner.Session(cleaner: cleaner, items: items)
            let reasons = items.map { cleaner.skipReason($0, session: session) ?? "go" }
            return reasons.joined(separator: " | ") + " (\(session.dependents.entriesRead) entries)"
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_SAFETY_PROBE"] != nil))
    func containerWalk() {
        let containers = Self.home + "/Library/Containers"
        guard let first = (try? FileManager.default.contentsOfDirectory(atPath: containers))?.filter({ !$0.hasPrefix(".") && !$0.hasPrefix("com.apple.") }).sorted().first else { return }
        Self.time("dependents container " + first, runs: 3) {
            let context = CleanDependents.Context(home: Self.home)
            return (CleanDependents.dependent(of: [containers + "/" + first], home: Self.home, context: context) ?? "none") + " (\(context.entriesRead) entries)"
        }
        let prefs = Self.home + "/Library/Preferences"
        if let plist = (try? FileManager.default.contentsOfDirectory(atPath: prefs))?.filter({ $0.hasSuffix(".plist") && !$0.hasPrefix("com.apple.") }).sorted().first {
            Self.time("dependents prefs plist", runs: 3) {
                let context = CleanDependents.Context(home: Self.home)
                return (CleanDependents.dependent(of: [prefs + "/" + plist], home: Self.home, context: context) ?? "none") + " (\(context.entriesRead) entries)"
            }
        }
    }
}

extension CleanSafetyProbe {
    /// Every check for every item Clean Safe Items would take from a real scan of Junk and
    /// Developer. The scan only reads and is not timed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_SAFETY_PROBE"] != nil))
    func safeItemsOfARealScan() {
        let items = CleanRegistry.scan(CleanRegistry.safeTabs, context: CleanScanContext(excluded: CleanSettings.load().exclusions)).filter(\.isSafeTrash)
        let cleaner = Cleaner(home: Self.home, guards: Self.guards)
        Self.time("checks for \(items.count) safe items", runs: 3) {
            let session = Cleaner.Session(cleaner: cleaner, items: items)
            let reasons = items.map { cleaner.skipReason($0, session: session) }
            let kept = reasons.compactMap { $0 }
            return "\(kept.count) stay: " + Set(kept).sorted().joined(separator: " | ") + " (\(session.dependents.entriesRead) entries)"
        }
    }
}

extension CleanSafetyProbe {
    /// Each safe item's decision, for comparing with another build on the same scan.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_SAFETY_DECISIONS"] != nil))
    func decisions() {
        let items = CleanRegistry.scan(CleanRegistry.safeTabs, context: CleanScanContext(excluded: CleanSettings.load().exclusions)).filter(\.isSafeTrash)
        let cleaner = Cleaner(home: Self.home, guards: Self.guards)
        let session = Cleaner.Session(cleaner: cleaner, items: items)
        for item in items.sorted(by: { $0.id < $1.id }) { print("DECISION \(item.id) \(item.bytes) => \(cleaner.skipReason(item, session: session) ?? "go")") }
    }
}
