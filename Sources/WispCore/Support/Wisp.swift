import Foundation

public enum Wisp {
    public static let version = "0.1.0"
    public static let bundleIdentifier = "app.wisp.Wisp"

    /// ~/Library/Application Support/Wisp, created on first use.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
