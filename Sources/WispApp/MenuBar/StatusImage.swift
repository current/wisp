import AppKit

/// Draws a status item's whole content (symbol or graph, then the figure) into one
/// bitmap. Template unless tinted, so the menu bar colours it for any wallpaper.
enum StatusImage {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let height: CGFloat = 18

    static func render(symbol: NSImage?, graph: ([Float], Float)?, text: String, lines: (String, String)?, tint: NSColor?) -> NSImage {
        let color = tint ?? .black
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let smallAttributes: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: color]
        let textWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: attributes).width)
        let linesWidth = lines.map { ceil(max(($0.0 as NSString).size(withAttributes: smallAttributes).width,
                                               ($0.1 as NSString).size(withAttributes: smallAttributes).width)) } ?? 0
        let lead: CGFloat = symbol != nil ? 16 : (graph != nil ? 28 : 0)
        let gap: CGFloat = lead > 0 && (textWidth > 0 || linesWidth > 0) ? 4 : 0
        let width = max(1, lead + gap + textWidth + linesWidth)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        if let symbol {
            let size = symbol.size
            let rect = NSRect(x: (16 - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                color.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        } else if let (values, ceiling) = graph {
            let frame = NSRect(x: 0, y: 1, width: 28, height: height - 2)
            color.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            color.setFill()
            let shown = values.suffix(13)
            let start = 13 - shown.count
            for (offset, value) in shown.enumerated() where !value.isNaN {
                let barHeight = max(1, CGFloat(min(1, value / max(ceiling, 0.0001))) * (frame.height - 4))
                NSRect(x: frame.minX + 2 + CGFloat(start + offset) * 2, y: frame.minY + 2, width: 1.5, height: barHeight).fill()
            }
        }
        if textWidth > 0 {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: lead + gap, y: (height - size.height) / 2), withAttributes: attributes)
        }
        if let lines {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            var right = smallAttributes
            right[.paragraphStyle] = paragraph
            (lines.0 as NSString).draw(in: NSRect(x: lead + gap, y: 8.5, width: linesWidth, height: 10), withAttributes: right)
            (lines.1 as NSString).draw(in: NSRect(x: lead + gap, y: -0.5, width: linesWidth, height: 10), withAttributes: right)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = tint == nil
        return image
    }
}
