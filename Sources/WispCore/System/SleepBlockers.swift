import Foundation
import IOKit.pwr_mgt

/// An app holding a power assertion that keeps the display or the Mac awake.
public struct SleepBlocker: Codable, Sendable, Equatable {
    public var pid: Int32
    public var process: String
    /// The reason the app gave, such as "Playing video".
    public var reason: String
    /// True when the display is kept on, not just the system.
    public var keepsDisplayOn: Bool
    public var since: Date?
}

/// Reads power assertions with IOPMCopyAssertionsByProcess: one call, no polling.
public enum SleepBlockers {
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    static let systemTypes: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"]

    public static func list() -> [SleepBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [SleepBlocker] = []
        for (pid, assertions) in byProcess {
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String,
                      displayTypes.contains(type) || systemTypes.contains(type) else { continue }
                // Level 0 means the assertion exists but is switched off.
                if let level = assertion["AssertLevel"] as? Int, level == 0 { continue }
                let name = assertion["Process Name"] as? String ?? ""
                // powerd holds its own assertion while the display is on; it is not an app keeping the Mac up.
                if name == "powerd" { continue }
                result.append(SleepBlocker(pid: pid.int32Value, process: name,
                                           reason: assertion["AssertName"] as? String ?? "",
                                           keepsDisplayOn: displayTypes.contains(type),
                                           since: assertion["AssertStartWhen"] as? Date))
            }
        }
        // One line per process: the display wins over the system, the oldest start wins.
        var merged: [Int32: SleepBlocker] = [:]
        for blocker in result {
            if var existing = merged[blocker.pid] {
                existing.keepsDisplayOn = existing.keepsDisplayOn || blocker.keepsDisplayOn
                if let since = blocker.since, since < (existing.since ?? .distantFuture) { existing.since = since }
                merged[blocker.pid] = existing
            } else {
                merged[blocker.pid] = blocker
            }
        }
        return merged.values.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }
}
