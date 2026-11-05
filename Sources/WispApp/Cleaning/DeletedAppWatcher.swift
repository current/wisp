import CoreServices
import Foundation
import WispCore

/// One FSEvents stream on /Applications and ~/Applications, coalesced over 5 seconds.
/// It knows which app sits at which path, so when a bundle disappears it can say which
/// app went. Costs nothing between events: the stream wakes Wisp only when those folders change.
final class DeletedAppWatcher: @unchecked Sendable {
    struct App: Equatable, Sendable {
        var path: String
        var bundleID: String
        var name: String
    }

    var onDeleted: (@MainActor (App) -> Void)?
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.wisp.clean.watcher", qos: .utility)
    /// Path to app, as of the last look. Touched only on `queue`.
    private var known: [String: App] = [:]
    private var pending = false
    static let folders = ["/Applications", NSHomeDirectory() + "/Applications"]

    func start() {
        queue.async { self.known = Self.apps() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DeletedAppWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        let folders = Self.folders.filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    /// On `queue`. An app that is replaced by an update vanishes for a moment, so a missing
    /// one is looked for again 10 seconds later before it counts as deleted.
    private func changed() {
        guard !pending else { return }
        let now = Self.apps()
        let present = Set(now.values.map(\.bundleID))
        let gone = known.values.filter { !present.contains($0.bundleID) }
        known.merge(now) { _, new in new }
        guard !gone.isEmpty else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.pending = false
            let later = Self.apps()
            let still = Set(later.values.map(\.bundleID))
            let deleted = self.known.values.filter { !still.contains($0.bundleID) }
            self.known = later
            var reported = Set<String>()
            for app in deleted where reported.insert(app.bundleID).inserted {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onDeleted?(app) } }
            }
        }
    }

    /// Every app bundle directly in the two folders, read from its Info.plist.
    static func apps() -> [String: App] {
        var apps: [String: App] = [:]
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let path = folder + "/" + name
                guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
                      let id = info["CFBundleIdentifier"] as? String else { continue }
                let title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? (name as NSString).deletingPathExtension
                apps[path] = App(path: path, bundleID: id, name: title)
            }
        }
        return apps
    }
}
