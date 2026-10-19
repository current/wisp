import Foundation

/// Number formatting shared by the app, the CLI and alert text.
public enum Format {
    public static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    public static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = value
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) B" }
        return String(format: amount < 10 ? "%.1f %@" : "%.0f %@", amount, units[unit])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// Short form for the menu bar: "1.2M", "340K".
    public static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var amount = bytesPerSecond
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        return String(format: amount < 10 && unit > 0 ? "%.1f%@" : "%.0f%@", amount, units[unit])
    }

    public static func minutes(_ minutes: Double) -> String {
        minutes == 1 ? "a minute" : "\(Int(minutes)) minutes"
    }

    public static func watts(_ watts: Double) -> String {
        watts < 0.1 ? String(format: "%.2f W", watts) : String(format: "%.1f W", watts)
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    public static func celsius(_ value: Double) -> String {
        String(format: "%.0f°", value)
    }
}
