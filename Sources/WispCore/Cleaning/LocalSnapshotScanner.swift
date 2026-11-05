import Foundation

/// Time Machine's local snapshots of the startup disk, all but the newest.
public struct LocalSnapshotScanner: CleanScanner {
    static let group = "Time Machine snapshots"

    public var tab: CleanTab { .junk }
    public var snapshots: @Sendable () -> [LocalSnapshot]

    public init(snapshots: @escaping @Sendable () -> [LocalSnapshot] = { LocalSnapshot.list() }) {
        self.snapshots = snapshots
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        guard !context.isCancelled() else { return [] }
        // Only Time Machine's carry the date tmutil deletes them by; update snapshots belong to macOS.
        let dated = snapshots().compactMap { snapshot -> (stamp: String, date: Date)? in
            guard snapshot.kind == "Time Machine", let date = snapshot.date,
                  let range = snapshot.name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
            return (String(snapshot.name[range]), date)
        }.sorted { $0.date > $1.date }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let items = dated.dropFirst().map { snapshot in
            CleanItem(id: "snapshot:\(snapshot.stamp)", tab: .junk, group: Self.group,
                      name: "Snapshot from \(formatter.string(from: snapshot.date))",
                      detail: "A copy of the disk Time Machine keeps for about a day. macOS does not report its size, and removing it is permanent.",
                      paths: [], bytes: 0, modified: snapshot.date, safety: .checkFirst, removal: .localSnapshot(date: snapshot.stamp))
        }
        if !items.isEmpty { context.found(items) }
        return items
    }
}
