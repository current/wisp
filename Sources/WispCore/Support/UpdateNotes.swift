import Foundation

/// Whether a launch follows an update, and which versions' notes it should show.
/// Kept apart from the window so the rules can be tested without AppKit.
public enum UpdateNotes {
    /// Wisp started remembering the version that ran in 0.5.0. Settings or history left
    /// without that record come from this version or one before it.
    public static let lastUnrecorded = "0.4.0"

    public enum Decision: Equatable, Sendable {
        /// Nothing says Wisp ran here before: remember this version and show nothing.
        case firstInstall
        /// The same version, a downgrade, or an update without notes.
        case nothingNew
        /// Updated from `from`; `versions` have notes, newest first.
        case show(from: String, versions: [String])
    }

    /// `stored` is the newest version that ran before this launch, nil when none was
    /// recorded. `earlierTraces` says an older Wisp left settings or history behind.
    /// `notes` are the versions that have notes, in any order.
    public static func decide(stored: String?, earlierTraces: Bool, running: String, notes: [String]) -> Decision {
        guard let previous = stored ?? (earlierTraces ? lastUnrecorded : nil) else { return .firstInstall }
        guard Release.isNewer(running, than: previous) else { return .nothingNew }
        let versions = between(previous, running, notes)
        return versions.isEmpty ? .nothingNew : .show(from: previous, versions: versions)
    }

    /// The versions in `notes` after `previous` and up to `running`, newest first.
    public static func between(_ previous: String, _ running: String, _ notes: [String]) -> [String] {
        notes.filter { Release.isNewer($0, than: previous) && !Release.isNewer($0, than: running) }
            .sorted { Release.isNewer($0, than: $1) }
    }

    /// What to store after this launch: the newer of the two, so going back to an older
    /// copy and forward again does not show the same notes twice.
    public static func remembered(stored: String?, running: String) -> String {
        guard let stored, Release.isNewer(stored, than: running) else { return running }
        return stored
    }

    /// "0.5" for 0.5.0, as people say it; "0.5.1" stays as it is.
    public static func shortName(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 2, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }
}
