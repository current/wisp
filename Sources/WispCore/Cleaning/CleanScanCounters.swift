import Synchronization

/// Entries and folders the Clean Up scanners listed, for the probe that times them.
enum CleanScanCounters {
    static let entries = Atomic<Int>(0)
    static let folders = Atomic<Int>(0)

    static func listed(_ count: Int) {
        entries.add(count, ordering: .relaxed)
    }

    static func opened() {
        folders.add(1, ordering: .relaxed)
    }
}
