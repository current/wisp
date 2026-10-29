import AppKit

/// The mark shown next to a coding agent: the icon of the agent's own Mac app when it
/// is installed (Claude, Codex, Cursor, Gemini), otherwise an SF Symbol.
@MainActor
enum AgentMark {
    private static let apps: [(match: String, bundleID: String)] = [
        ("Claude", "com.anthropic.claudefordesktop"),
        ("Codex", "com.openai.codex"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Gemini", "com.google.GeminiMacOS"),
    ]
    private static var cache: [String: NSImage] = [:]

    static func symbol(_ kind: String) -> (String, NSColor) {
        switch kind {
        case let k where k.contains("Claude"): return ("asterisk", Theme.hex(0xD97757))
        case let k where k.contains("Codex"): return ("circle.hexagongrid.fill", Theme.ink)
        case let k where k.contains("Gemini"): return ("sparkle", Theme.blue)
        case let k where k.contains("Cursor"): return ("cursorarrow.rays", Theme.ink)
        default: return ("terminal.fill", Theme.ink)
        }
    }

    static func image(_ kind: String, size: CGFloat, appearance: NSAppearance) -> NSImage {
        if let bundleID = apps.first(where: { kind.contains($0.match) })?.bundleID {
            let key = "\(bundleID)-\(size)"
            if let cached = cache[key] { return cached }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                // App icons carry a margin around the squircle; draw a little larger so the
                // visible shape matches an 18 pt glyph.
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                    icon.draw(in: rect.insetBy(dx: -size * 0.1, dy: -size * 0.1))
                    return true
                }
                cache[key] = image
                return image
            }
        }
        let (name, tint) = symbol(kind)
        return IconTile.glyph(name, tint: tint, size: size, appearance: appearance)
    }
}
