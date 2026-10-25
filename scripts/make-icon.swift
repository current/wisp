// Draws the app icon and writes Resources/Wisp.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: an 824 pt rounded square centred on 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(starting: hex(0xFFFFFF), ending: hex(0xF1F1F4))!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    hex(0xE2E2E7).setStroke()
    shape.lineWidth = max(1, 3 * s)
    shape.stroke()

    // Seven bars on the heat scale, low and pale at the edges, tall and deep in the middle.
    let heights: [CGFloat] = [0.30, 0.52, 0.42, 0.78, 0.64, 0.90, 0.48]
    let low = hex(0xC9CFF7), high = hex(0x2536C4)
    let barWidth = 62 * s, pitch = 92 * s
    let left = tile.midX - (pitch * 6 + barWidth) / 2
    let base = tile.minY + 190 * s, room = 470 * s
    for (index, h) in heights.enumerated() {
        let t = pow(h, 0.75)
        let color = low.blended(withFraction: t, of: high)!
        color.setFill()
        let bar = NSRect(x: left + CGFloat(index) * pitch, y: base, width: barWidth, height: max(barWidth, room * h))
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    // The live dot.
    hex(0xE85A2C).setFill()
    NSBezierPath(ovalIn: NSRect(x: tile.maxX - 190 * s, y: tile.maxY - 190 * s, width: 74 * s, height: 74 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Wisp.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Resources/Wisp.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/Wisp.icns" : "iconutil failed")
