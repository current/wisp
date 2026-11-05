import Foundation

/// Every scanner the Clean Up page and `wisp clean` run. One line each.
public enum CleanRegistry {
    public static var scanners: [any CleanScanner] {
        [
            AppCacheScanner(),
            SystemJunkScanner(),
            InstallerScanner(),
            LocalSnapshotScanner(),
            DeveloperCacheScanner(),
            SimulatorScanner(),
            ProjectArtifactScanner(),
            WorktreeScanner(),
        ]
    }
}
