import Foundation

/// Number formatting shared by the app, the CLI and alert text.
public enum Format {
    /// Owner choices the app sets at launch and on change; the CLI keeps the defaults.
    nonisolated(unsafe) public static var fahrenheit = false
    nonisolated(unsafe) public static var bits = false

    /// A large count in short form: 950, 12.4K, 3.1M, 1.2B.
    public static func count(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: v < 10_000 ? "%.1fK" : "%.0fK", v / 1_000)
        case ..<1_000_000_000: return String(format: v < 10_000_000 ? "%.1fM" : "%.0fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

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

    /// Memory in binary units, the way Activity Monitor counts it (16 GB of RAM is 16 GB here).
    public static func memory(_ value: UInt64) -> String {
        memory(Double(value))
    }

    public static func memory(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = value
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) B" }
        return String(format: amount < 10 ? "%.1f %@" : "%.0f %@", amount, units[unit])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bits else { return bytes(bytesPerSecond) + "/s" }
        let units = ["b", "Kb", "Mb", "Gb", "Tb"]
        var amount = bytesPerSecond * 8
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) b/s" }
        return String(format: amount < 10 ? "%.1f %@/s" : "%.0f %@/s", amount, units[unit])
    }

    /// Short form for the menu bar: "1.2M", "340K".
    public static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var amount = bits ? bytesPerSecond * 8 : bytesPerSecond
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        if bits { return String(format: amount < 10 && unit > 0 ? "%.1f%@b" : "%.0f%@b", amount, unit == 0 ? "" : units[unit]) }
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
        String(format: "%.0f°", fahrenheit ? value * 9 / 5 + 32 : value)
    }

    /// A temperature split into figure and unit, in the scale the owner chose.
    public static func temperature(_ celsius: Double) -> (String, String) {
        fahrenheit ? (String(format: "%.0f", celsius * 9 / 5 + 32), "°F") : (String(format: "%.0f", celsius), "°C")
    }
}
