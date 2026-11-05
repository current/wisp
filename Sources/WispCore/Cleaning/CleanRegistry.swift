import Foundation

/// Every scanner the Clean Up page runs. Add one line per scanner.
public enum CleanRegistry {
    public static var scanners: [any CleanScanner] {
        [
            LeftoversScanner(),
        ]
    }
}
