import Foundation

/// The newest Wisp release on GitHub, for the notice that a new version is out.
public struct Release: Equatable, Sendable {
    public var version: String
    public var page: URL

    public init(version: String, page: URL) {
        self.version = version
        self.page = page
    }

    public static let latestURL = URL(string: "https://api.github.com/repos/current/wisp/releases/latest")!

    /// Reads GitHub's answer for the latest release: its tag ("v0.3.0") and page.
    public static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    /// True when `version` is later than `current`, comparing dotted numbers ("0.10.0" > "0.9.1").
    public static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// One request, with no cookies or identifying headers beyond the app's name.
    public static func fetchLatest() async -> Release? {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wisp", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
