import Foundation

/// Every scanner the Clean Up page, `wisp clean` and the MCP server run.
public enum CleanRegistry {
    public static var scanners: [any CleanScanner] {
        [
            AppCacheScanner(),
            SystemJunkScanner(),
            InstallerScanner(),
            LocalSnapshotScanner(),
            DeveloperCacheScanner(),
            SimulatorScanner(),
            ProjectArtifactScanner(staleAfter: TimeInterval(CleanSettings.load().staleProjectDays) * 86_400),
            WorktreeScanner(),
            LeftoversScanner(),
            LargeFilesScanner(),
        ]
    }

    /// Checks on a whole selection, given the item ids; each returns false when the
    /// selection must not be cleaned together. One line per check.
    public static var selectionChecks: [@Sendable (Set<String>) -> Bool] {
        [
            { LargeFileIndex.shared.keepsACopy($0) },
        ]
    }

    /// Nil when `items` may be cleaned together, otherwise the reason they may not.
    public static func selectionRefusal(_ items: [CleanItem], checks: [@Sendable (Set<String>) -> Bool] = selectionChecks) -> String? {
        let ids = Set(items.map(\.id))
        return checks.allSatisfy { $0(ids) } ? nil : "This would remove every copy of a file. Keep at least one copy ticked off"
    }

    public static func scanners(for tab: CleanTab) -> [any CleanScanner] {
        scanners.filter { $0.tab == tab }
    }

    /// Runs the scanners of `tabs` one after another on the calling thread and returns what
    /// they found, without excluded items or repeats. Batches still stream through `context.found`.
    public static func scan(_ tabs: [CleanTab], context: CleanScanContext, using scanners: [any CleanScanner] = scanners) -> [CleanItem] {
        var seen = Set<String>()
        var items: [CleanItem] = []
        for tab in tabs {
            for scanner in scanners where scanner.tab == tab {
                if context.isCancelled() { return items }
                var forwarding = context
                forwarding.found = { batch in context.found(batch.filter { !$0.paths.contains(where: context.isExcluded) }) }
                for item in scanner.scan(forwarding) where !item.paths.contains(where: context.isExcluded) {
                    if seen.insert(item.id).inserted { items.append(item) }
                }
            }
        }
        return items
    }

    /// The tabs that list things to clean, in page order.
    public static let cleaningTabs: [CleanTab] = [.junk, .developer, .largeFiles, .leftovers, .uninstall]
    /// What a scheduled clean and Clean Safe Items take from.
    public static let safeTabs: [CleanTab] = [.junk, .developer]
}

extension Array where Element == CleanItem {
    public var totalBytes: Int64 { reduce(0) { $0 + $1.bytes } }
}
