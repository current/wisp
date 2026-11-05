import Foundation

public enum Uptime {
    /// When the Mac last started, from `kern.boottime`.
    public static func bootDate() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    /// "up 4 days", "up 5 hours", "up 12 min": the largest whole unit.
    public static func label(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return "up \(max(1, minutes)) min" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "up 1 hour" : "up \(hours) hours" }
        let days = hours / 24
        return days == 1 ? "up 1 day" : "up \(days) days"
    }
}
