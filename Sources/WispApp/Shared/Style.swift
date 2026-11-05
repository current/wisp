import AppKit
import WispCore

/// The handful of sizes and fonts every view uses, so spacing stays on one grid.
enum Style {
    static let unit: CGFloat = 4
    static let gap: CGFloat = 8
    static let pad: CGFloat = 12
    static let section: CGFloat = 20
    static let corner: CGFloat = 8

    static let title = Theme.sans(13, .semibold)
    static let body = Theme.sans(12)
    static let caption = Theme.sans(11)
    static let figure = Theme.digits(12, .regular)
    static let bigFigure = Theme.digits(20, .medium)
    static let smallFigure = Theme.digits(11, .regular)

    static func label(_ text: String = "", font: NSFont = Style.body, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func secondary(_ text: String = "", font: NSFont = Style.caption) -> NSTextField {
        label(text, font: font, color: .secondaryLabelColor)
    }

    static func stack(_ views: [NSView], axis: NSUserInterfaceLayoutOrientation, spacing: CGFloat = Style.gap,
                      alignment: NSLayoutConstraint.Attribute? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = axis
        stack.spacing = spacing
        if let alignment { stack.alignment = alignment }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// App CPU as Activity Monitor shows it (100% is one core), or as a share of the machine.
    static func appCPU(_ cores: Double, machine: Bool, coreCount: Int) -> String {
        if machine { return Format.percent(cores / Double(max(coreCount, 1)), digits: 1) }
        return cores >= 10 ? Format.percent(cores) : Format.percent(cores, digits: 1)
    }
}

/// App icons, looked up once per bundle and kept small.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    private static let tool: NSImage = {
        let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        return image
    }()
    private static let system: NSImage = {
        NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) ?? NSImage()
    }()

    static func icon(for app: AppGroup) -> NSImage {
        icon(id: app.id, kind: app.kind, bundlePath: app.bundlePath)
    }

    static func icon(id: String, kind: AppKind, bundlePath: String?) -> NSImage {
        if let cached = cache[id] { return cached }
        let image: NSImage
        if let bundlePath {
            let full = NSWorkspace.shared.icon(forFile: bundlePath)
            // Draw into a 32 pt bitmap once; the full icon family can be several megabytes.
            image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                full.draw(in: rect)
                return true
            }
        } else {
            image = kind == .system ? system : tool
        }
        if cache.count > 400 { cache.removeAll() }
        cache[id] = image
        return image
    }
}
