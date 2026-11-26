import Foundation

public enum Wisp {
    public static let version = "0.4.0"
    public static let bundleIdentifier = "app.wisp.Wisp"

    /// WISP_NO_SAVE: a screenshot, audit or benchmark run reads the owner's history and
    /// settings but writes none of them, so it leaves the running copy's data as it was.
    public static let readOnly = ProcessInfo.processInfo.environment["WISP_NO_SAVE"] != nil

    /// ~/Library/Application Support/Wisp, created on first use.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
