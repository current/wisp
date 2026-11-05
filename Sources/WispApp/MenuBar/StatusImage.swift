import AppKit

/// Draws a status item's whole content (symbol, graph or caption, then the reading)
/// into one bitmap. Template when no colour is given, so the menu bar colours it for
/// any wallpaper.
@MainActor
enum StatusImage {
    struct Content {
        var symbol: NSImage?
        var graph: ([Float], Float)?
        var caption: String?
        var captionAbove = false
        var text = ""
        /// Two short lines stacked in place of the text (network up and down).
        var lines: (String, String)?
        /// Text whose width the reading never shrinks below.
        var steadySample: String?
        var size: MenuTextSize = .regular
        var weight: MenuWeight = .regular
    }

    /// Room for the tallest layout, two lines, on every menu bar height macOS uses.
    static var height: CGFloat { min(24, max(18, NSStatusBar.system.thickness)) }

    /// `lead` paints the symbol, graph or caption, `value` the reading. Both nil
    /// makes a template image.
    static func render(_ content: Content, lead: NSColor?, value: NSColor?) -> NSImage {
        let template = lead == nil && value == nil
        let leadColor = lead ?? value ?? .black
        let valueColor = value ?? lead ?? .black
        let height = Self.height
        let fonts = Fonts(content.size, content.weight, above: content.captionAbove)
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: fonts.value, .foregroundColor: valueColor]
        let lineAttributes: [NSAttributedString.Key: Any] = [.font: fonts.line, .foregroundColor: valueColor]
        let captionAttributes: [NSAttributedString.Key: Any] = [.font: fonts.caption, .foregroundColor: leadColor, .kern: content.captionAbove ? 0.3 : 0.1]

        func width(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
            text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: attributes).width)
        }

        // The graph sits under the caption only when it is all there is to show.
        let graphInColumn = content.captionAbove && content.graph != nil && content.text.isEmpty && content.lines == nil
        let caption = content.caption ?? ""
        var valueWidth: CGFloat
        if let lines = content.lines {
            valueWidth = max(width(lines.0, lineAttributes), width(lines.1, lineAttributes))
            if let sample = content.steadySample { valueWidth = max(valueWidth, width(sample, lineAttributes)) }
        } else if graphInColumn {
            valueWidth = 28
        } else {
            valueWidth = width(content.text, valueAttributes)
            if let sample = content.steadySample, valueWidth > 0 { valueWidth = max(valueWidth, width(sample, valueAttributes)) }
        }
        let captionWidth = width(caption, captionAttributes)
        let columnWidth = content.captionAbove ? max(valueWidth, captionWidth) : valueWidth

        var leadWidth: CGFloat = 0
        if let symbol = content.symbol { leadWidth = max(16, ceil(symbol.size.width)) }
        if content.graph != nil, !graphInColumn { leadWidth += (leadWidth > 0 ? 4 : 0) + 28 }
        if !content.captionAbove, captionWidth > 0 { leadWidth += (leadWidth > 0 ? 4 : 0) + captionWidth }
        let gap: CGFloat = leadWidth > 0 && columnWidth > 0 ? (content.captionAbove || content.symbol != nil || content.graph != nil ? 4 : 3) : 0
        let total = max(1, leadWidth + gap + columnWidth)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(total * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = NSSize(width: total, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // One line of text is centred on its line box, as the menu bar centres its own titles.
        let inlineBaseline = ((height - (fonts.value.ascender - fonts.value.descender)) / 2) - fonts.value.descender
        var x: CGFloat = 0
        if let symbol = content.symbol {
            let size = symbol.size
            let rect = NSRect(x: x + (16 - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height)
            NSImage(size: size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                leadColor.set()
                bounds.fill(using: .sourceAtop)
                return true
            }.draw(in: rect)
            x += max(16, ceil(size.width))
        }
        if let graph = content.graph, !graphInColumn {
            if x > 0 { x += 4 }
            drawGraph(graph, in: NSRect(x: x, y: 1, width: 28, height: height - 2), color: leadColor)
            x += 28
        }
        if !content.captionAbove, captionWidth > 0 {
            if x > 0 { x += 4 }
            let baseline = content.lines == nil ? inlineBaseline : (height - fonts.caption.capHeight) / 2
            (caption as NSString).draw(at: NSPoint(x: x, y: baseline + fonts.caption.descender), withAttributes: captionAttributes)
            x += captionWidth
        }
        x += gap

        let right = NSMutableParagraphStyle()
        right.alignment = .right
        if content.captionAbove {
            // Caption and reading as one block, centred on their cap heights, not their line boxes.
            let below: CGFloat = graphInColumn ? 9 : fonts.value.capHeight
            let spacing: CGFloat = graphInColumn ? 2 : 2.5
            let bottom = ((height - below - spacing - fonts.caption.capHeight) / 2).rounded()
            let captionBaseline = bottom + below + spacing
            (caption as NSString).draw(at: NSPoint(x: x, y: captionBaseline + fonts.caption.descender), withAttributes: captionAttributes)
            if let graph = content.graph, graphInColumn {
                drawGraph(graph, in: NSRect(x: x, y: bottom - 1, width: 28, height: below + 1), color: valueColor, framed: false)
            } else if !content.text.isEmpty {
                (content.text as NSString).draw(at: NSPoint(x: x, y: bottom + fonts.value.descender), withAttributes: valueAttributes)
            }
        } else if let lines = content.lines {
            var attributes = lineAttributes
            attributes[.paragraphStyle] = right
            let lineHeight = ceil(fonts.line.ascender - fonts.line.descender)
            let middle = height / 2
            (lines.0 as NSString).draw(in: NSRect(x: x, y: middle - 0.5, width: valueWidth, height: lineHeight), withAttributes: attributes)
            (lines.1 as NSString).draw(in: NSRect(x: x, y: middle - lineHeight + 0.5, width: valueWidth, height: lineHeight), withAttributes: attributes)
        } else if !content.text.isEmpty {
            // A steady item keeps its figure against the right edge, where the digits change least.
            let shown = width(content.text, valueAttributes)
            (content.text as NSString).draw(at: NSPoint(x: x + valueWidth - shown, y: inlineBaseline + fonts.value.descender), withAttributes: valueAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = template
        return image
    }

    private static func drawGraph(_ graph: ([Float], Float), in frame: NSRect, color: NSColor, framed: Bool = true) {
        let (values, ceiling) = graph
        if framed {
            color.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
        }
        color.setFill()
        let inset: CGFloat = framed ? 2 : 0
        let shown = values.suffix(13)
        let start = 13 - shown.count
        for (offset, value) in shown.enumerated() where !value.isNaN {
            let barHeight = max(1, CGFloat(min(1, value / max(ceiling, 0.0001))) * (frame.height - inset * 2))
            NSRect(x: frame.minX + inset + CGFloat(start + offset) * 2, y: frame.minY + inset, width: 1.5, height: barHeight).fill()
        }
    }

    /// Fonts are made once per look; a reading changes far more often than its look.
    private struct Fonts {
        let value: NSFont
        let line: NSFont
        let caption: NSFont

        private static var cache: [String: Fonts] = [:]

        init(_ size: MenuTextSize, _ weight: MenuWeight, above: Bool) {
            let key = "\(size.rawValue).\(weight.rawValue).\(above)"
            if let cached = Self.cache[key] {
                self = cached
                return
            }
            let points: (value: CGFloat, line: CGFloat, caption: CGFloat)
            switch (size, above) {
            case (.small, false): points = (11, 8.5, 9.5)
            case (.regular, false): points = (12, 9, 10.5)
            case (.large, false): points = (13.5, 10, 11.5)
            case (.small, true): points = (11.5, 8.5, 7.5)
            case (.regular, true): points = (12.5, 9, 8)
            case (.large, true): points = (14, 10, 8.5)
            }
            let base: NSFont.Weight
            switch weight {
            case .regular: base = .regular
            case .medium: base = .medium
            case .semibold: base = .semibold
            case .bold: base = .bold
            }
            value = Theme.digits(points.value, base)
            line = Theme.digits(points.line, base == .regular ? .medium : base)
            // Small caps-height text needs more weight than the figure to read at all.
            caption = Theme.sans(points.caption, base == .bold ? .heavy : .semibold)
            Self.cache[key] = self
        }
    }
}

/// The menu bar items as they look now, on a strip of menu bar in the window's
/// appearance, for Settings. Drawn from the latest reading on each new sample.
final class MenuBarPreview: DrawnView {
    static let height: CGFloat = 72
    private unowned let delegate: AppDelegate
    private static let strip = A2.dynamic(NSColor(white: 0.93, alpha: 1), NSColor(white: 0.1, alpha: 1))
    private static let ring = A2.dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.07))
    private static let hint = Theme.sans(12)

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Menu bar preview")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: RowView.inset, y: 16, width: bounds.width - RowView.inset * 2, height: bounds.height - 32)
        let path = NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10)
        Self.strip.setFill()
        path.fill()
        Self.ring.setStroke()
        path.lineWidth = 1
        path.stroke()

        let shown = delegate.settings.menuItems.filter(\.enabled)
        guard !shown.isEmpty else {
            let text = NSAttributedString(string: "Nothing is shown. Wisp keeps one small icon so you can still open it.",
                                          attributes: [.font: Self.hint, .foregroundColor: A2.secondary])
            let size = text.size()
            text.draw(at: NSPoint(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2))
            return
        }
        let snapshot = delegate.system
        let history = delegate.monitor.history
        let images = shown.map { setting -> NSImage in
            let reading = StatusBar.reading(setting.metric, snapshot)
            let graph = setting.style != .number ? Array(history.recent(setting.metric.historyMetric).suffix(14)) : []
            return StatusBar.image(setting, reading: reading, graph: graph, appearance: effectiveAppearance, template: false)
        }
        // About the spacing the menu bar leaves between status items.
        let spacing: CGFloat = 16
        let total = images.map(\.size.width).reduce(0, +) + spacing * CGFloat(images.count - 1)
        var x = max(bar.minX + 12, (bar.midX - total / 2).rounded())
        for image in images {
            let rect = NSRect(x: x, y: (bar.midY - image.size.height / 2).rounded(), width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += image.size.width + spacing
        }
    }
}
