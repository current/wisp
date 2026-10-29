// Prints the window number of the named app's largest on-screen window, for screencapture -l.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Wisp"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int ?? 0) <= 3 }
let largest = windows.max { a, b in
    let area = { (w: [String: Any]) -> Double in
        let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    return area(a) < area(b)
}
if let number = largest?[kCGWindowNumber as String] as? Int { print(number) } else { exit(1) }
