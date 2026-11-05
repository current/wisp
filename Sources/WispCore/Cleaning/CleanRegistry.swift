import Foundation

/// Every scanner the Clean Up page runs.
public enum CleanRegistry {
    public static var scanners: [any CleanScanner] {
        [
            LargeFilesScanner(),
        ]
    }
}
