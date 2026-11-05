import Foundation

extension InstalledApps {
    /// Whether the Uninstall tab lists the app at `path`: a bundle in /Applications or
    /// ~/Applications, directly or one plain folder down, that is neither Apple's nor Wisp.
    public static func isUninstallable(path: String, bundleID: String?, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasSuffix(".app"), let bundleID, !bundleID.isEmpty, !isApple(bundleID), bundleID != Wisp.bundleIdentifier else { return false }
        for folder in ["/Applications/", home + "/Applications/"] where path.hasPrefix(folder) {
            let rest = path.dropFirst(folder.count).split(separator: "/", omittingEmptySubsequences: false)
            return rest.count == 1 || (rest.count == 2 && !rest[0].isEmpty && (String(rest[0]) as NSString).pathExtension.isEmpty)
        }
        return false
    }

    /// A bundle's size on disk. Stops early, with what it counted, once `cancel` is set.
    public static func bundleBytes(_ path: String, cancel: ScanFlag) -> Int64 {
        var rules = FolderScanner.Rules()
        // Only the total matters, so no node below the bundle is kept.
        rules.keepChildren = 0
        rules.smallestFolder = .max
        rules.smallestFile = .max
        return Int64(clamping: FolderScanner(rules: rules, cancel: cancel).folder(at: path).size)
    }
}
