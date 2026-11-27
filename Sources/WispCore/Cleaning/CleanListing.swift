import Foundation

/// What can go, by tab: the answer to `wisp clean --json` and the MCP tool `list_cleanable`.
public struct CleanListing: Codable, Sendable {
    public struct Tab: Codable, Sendable {
        public var tab: CleanTab
        public var title: String
        public var bytes: Int64
        /// When the Clean Up page scanned this tab; nil when it was scanned for this answer.
        public var scannedAt: Date?
        public var items: [CleanItem]
    }

    public var date: Date
    public var tabs: [Tab]
    public var totalBytes: Int64
    /// What Clean Safe Items and `wisp clean --apply` would move to the Trash.
    public var safeTrashBytes: Int64
    /// Ids ticked on the Clean Up page, when a tab comes from its saved scan.
    public var selected: [String]?

    public init(items: [CleanItem], tabs: [CleanTab], date: Date = Date()) {
        self.init(tabs: tabs.map { tab in (tab, items.filter { $0.tab == tab }, nil) }, selected: nil, date: date)
    }

    public init(tabs: [(tab: CleanTab, items: [CleanItem], scannedAt: Date?)], selected: [String]?, date: Date = Date()) {
        self.date = date
        self.tabs = tabs.map { tab, items, scannedAt in
            let found = items.sorted { $0.bytes > $1.bytes }
            return Tab(tab: tab, title: tab.title, bytes: found.totalBytes, scannedAt: scannedAt, items: found)
        }
        let all = tabs.flatMap(\.items)
        totalBytes = all.totalBytes
        safeTrashBytes = all.filter(\.isSafeTrash).totalBytes
        self.selected = selected
    }

    /// Each tab from the Clean Up page's recent saved scan when there is one, unless `rescan`;
    /// the rest scanned now with `scanners`.
    public static func current(_ tabs: [CleanTab], rescan: Bool, settings: CleanSettings = .load(),
                               scanners: [any CleanScanner] = CleanRegistry.scanners) -> CleanListing {
        let snapshot = rescan ? nil : CleanSnapshot.load()
        var saved: [CleanTab: CleanSnapshot.Tab] = [:]
        for tab in tabs { saved[tab] = snapshot?.recent(tab) }
        let missing = tabs.filter { saved[$0] == nil }
        let scanned = missing.isEmpty ? [] : CleanRegistry.scan(missing, context: CleanScanContext(excluded: settings.exclusions), using: scanners)
        let parts = tabs.map { tab in
            saved[tab].map { (tab, $0.items, Optional($0.scannedAt)) } ?? (tab, scanned.filter { $0.tab == tab }, nil)
        }
        return CleanListing(tabs: parts, selected: saved.isEmpty ? nil : snapshot?.selected)
    }

    /// Scans `tabs` now, on the calling thread, with the owner's exclusions.
    public static func scan(_ tabs: [CleanTab], settings: CleanSettings = .load()) -> CleanListing {
        let items = CleanRegistry.scan(tabs, context: CleanScanContext(excluded: settings.exclusions))
        return CleanListing(items: items, tabs: tabs)
    }

    /// "junk", "developer", "large", "leftovers", "uninstall", or the raw tab names.
    public static func tab(named name: String) -> CleanTab? {
        switch name.lowercased() {
        case "large", "large-files", "largefiles": return .largeFiles
        case "history": return nil
        default: return CleanTab(rawValue: name.lowercased())
        }
    }

    /// The tabs `wisp clean` lists when none is named. Uninstall lists every app, so it is asked for by name.
    public static let defaultTabs: [CleanTab] = [.junk, .developer, .largeFiles, .leftovers]
}

extension CleanItem {
    /// "Safe to clean", "Check first" or "Removed for good", as the page and the CLI label it.
    public var safetyLabel: String {
        if removal.isPermanent { return "Removed for good" }
        return safety == .safe ? "Safe to clean" : "Check first"
    }
}
