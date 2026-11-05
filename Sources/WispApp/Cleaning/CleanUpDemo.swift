import Foundation
import WispCore

/// WISP_CLEAN_DEMO=1 fills Clean Up with made-up findings, for screenshots and layout
/// work before the real scanners land. Its cleaner removes nothing: the Trash and the
/// tools are stand-ins that only report success.
enum CleanUpDemo {
    struct Scanner: CleanScanner {
        let tab: CleanTab
        func scan(_ context: CleanScanContext) -> [CleanItem] {
            let items = CleanUpDemo.items(home: context.home.path).filter { $0.tab == tab && !$0.paths.contains(where: context.isExcluded) }
            // In two batches, as a real scan streams them.
            let half = items.count / 2
            context.found(Array(items.prefix(half)))
            Thread.sleep(forTimeInterval: 0.3)
            context.found(Array(items.dropFirst(half)))
            return items
        }
    }

    /// Uninstall lists the real apps (reading them changes nothing); its removals still go through `guards`.
    static var scanners: [any CleanScanner] { CleanTab.allCases.filter { $0 != .history && $0 != .uninstall }.map { Scanner(tab: $0) } }

    static let guards = CleanGuards(processUse: { ProcessUse() }, gitState: { _ in .clean }, runTool: { _, _ in (0, "") },
                                    trash: { _ in }, developerTools: { true })

    static func items(home: String) -> [CleanItem] {
        let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000
        func item(_ tab: CleanTab, _ group: String, _ name: String, _ detail: String, _ path: String, _ bytes: Int64,
                  safety: CleanSafety = .safe, removal: CleanRemoval = .trash, owner: String? = nil, ticked: Bool = true) -> CleanItem {
            let paths = path.isEmpty ? [] : [path.replacingOccurrences(of: "~", with: home)]
            return CleanItem(id: "demo:\(tab.rawValue):\(name)", tab: tab, group: group, name: name, detail: detail, paths: paths, bytes: bytes,
                             safety: safety, removal: removal, ownerBundleID: owner, checkedByDefault: ticked)
        }
        return [
            item(.junk, "App caches", "Google Chrome cache", "Pages and images Chrome keeps to load sites faster. It fills again as you browse.",
                 "~/Library/Caches/Google/Chrome", 2_340 * mb, owner: "com.google.Chrome"),
            item(.junk, "App caches", "Spotify cache", "Songs Spotify kept for playback. They download again when played.",
                 "~/Library/Caches/com.spotify.client", 1_120 * mb, owner: "com.spotify.client"),
            item(.junk, "App caches", "Slack cache", "Images and files from your workspaces. Slack fetches them again.",
                 "~/Library/Caches/com.tinyspeck.slackmacgap", 486 * mb, owner: "com.tinyspeck.slackmacgap"),
            item(.junk, "Logs", "App logs", "Logs apps write as they run. Nothing reads them once they are a week old.",
                 "~/Library/Logs", 212 * mb),
            item(.junk, "Logs", "Crash reports", "Reports from apps that quit unexpectedly. Already sent if you share them with Apple.",
                 "~/Library/Logs/DiagnosticReports", 38 * mb),
            item(.junk, "Downloads", "Installers in Downloads", "Disk images and installers you already opened. Download them again if needed.",
                 "~/Downloads", 3_400 * mb, safety: .checkFirst, ticked: false),
            item(.developer, "Xcode", "Build files", "Build products and indexes. Xcode makes them again, and the next build takes longer.",
                 "~/Library/Developer/Xcode/DerivedData", 18 * gb),
            item(.developer, "Xcode", "iOS 17.5 simulator runtime", "Not used by any simulator. Xcode can download it again.",
                 "", 7_800 * mb, safety: .checkFirst, removal: .simulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5"), ticked: false),
            item(.developer, "Xcode", "iPhone 15 Pro simulator", "Not opened since March. Its apps and data go with it.",
                 "~/Library/Developer/CoreSimulator/Devices/6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A", 2_100 * mb, safety: .checkFirst,
                 removal: .simulator(udid: "6F3D1C0E-6B8A-4C3E-9D3B-2A1F0E9C8B7A"), ticked: false),
            item(.developer, "Package caches", "npm cache", "Packages npm downloaded. The next install fetches what it needs.",
                 "~/.npm/_cacache", 4_600 * mb),
            item(.developer, "Package caches", "Homebrew downloads", "Bottles Homebrew already installed.",
                 "~/Library/Caches/Homebrew", 1_900 * mb),
            item(.developer, "Projects", "node_modules in old-site", "Not touched in 94 days. npm install puts it back.",
                 "~/src/old-site/node_modules", 640 * mb, safety: .checkFirst, ticked: false),
            item(.largeFiles, "Videos", "Screen Recording 2026-10-02.mov", "Opened 33 days ago.",
                 "~/Desktop/Screen Recording 2026-10-02.mov", 6_200 * mb, safety: .checkFirst, ticked: false),
            item(.largeFiles, "Disk images", "Xcode_26.dmg", "Xcode is installed; this is the installer.",
                 "~/Downloads/Xcode_26.dmg", 11 * gb, safety: .checkFirst, ticked: false),
            item(.leftovers, "Discord", "Discord settings and cache", "The app is gone. These stay until removed.",
                 "~/Library/Application Support/discord", 820 * mb, safety: .checkFirst, owner: "com.hnc.Discord"),
            item(.leftovers, "Discord", "Discord preferences", "The app is gone.",
                 "~/Library/Preferences/com.hnc.Discord.plist", 12_000, safety: .checkFirst, owner: "com.hnc.Discord"),
        ]
    }
}
