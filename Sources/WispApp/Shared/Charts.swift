import AppKit

/// A small filled line chart. Drawn as two paths in draw(_:), with no layers,
/// so a dashboard full of them costs a few kilobytes.
final class SparklineView: NSView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    /// Fixed top of the scale; nil scales to the largest value.
    var ceiling: Float?
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var secondary: [Float] = [] { didSet { needsDisplay = true } }
    var secondaryColor: NSColor = .systemTeal

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let top = ceiling ?? max(values.filter { !$0.isNaN }.max() ?? 0, secondary.filter { !$0.isNaN }.max() ?? 0, 0.0001)
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        Self.plot(values, in: rect, top: top, color: color)
        if !secondary.isEmpty { Self.plot(secondary, in: rect, top: top, color: secondaryColor) }
    }

    static func plot(_ values: [Float], in rect: NSRect, top: Float, color: NSColor, fill: Bool = true) {
        guard values.count > 1 else { return }
        let step = rect.width / CGFloat(values.count - 1)
        let line = NSBezierPath()
        var area: NSBezierPath?
        var started = false
        func point(_ index: Int, _ value: Float) -> NSPoint {
            NSPoint(x: rect.minX + CGFloat(index) * step,
                    y: rect.minY + CGFloat(min(1, max(0, value / top))) * rect.height)
        }
        for (index, value) in values.enumerated() {
            if value.isNaN {
                if started, let shape = area {
                    shape.line(to: NSPoint(x: shape.currentPoint.x, y: rect.minY))
                    color.withAlphaComponent(0.12).setFill()
                    if fill { shape.fill() }
                }
                started = false
                area = nil
                continue
            }
            let p = point(index, value)
            if !started {
                line.move(to: p)
                area = NSBezierPath()
                area?.move(to: NSPoint(x: p.x, y: rect.minY))
                area?.line(to: p)
                started = true
            } else {
                line.line(to: p)
                area?.line(to: p)
            }
        }
        if let shape = area, started {
            shape.line(to: NSPoint(x: shape.currentPoint.x, y: rect.minY))
            shape.close()
            color.withAlphaComponent(0.12).setFill()
            if fill { shape.fill() }
        }
        color.setStroke()
        line.lineWidth = 1.25
        line.lineJoinStyle = .round
        line.stroke()
    }
}

enum MiniGraph {
    /// Bars for a status item. Template unless `tint` is given, so the menu bar
    /// colours it to match light, dark and tinted wallpapers.
    static func image(_ values: [Float], ceiling: Float, size: NSSize, tint: NSColor?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let color = tint ?? .black
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            let bars = Int(rect.width / 2)
            let shown = values.suffix(bars)
            let start = bars - shown.count
            color.setFill()
            for (offset, value) in shown.enumerated() where !value.isNaN {
                let height = max(1, CGFloat(min(1, value / ceiling)) * (rect.height - 2))
                NSRect(x: CGFloat(start + offset) * 2, y: 1, width: 1.5, height: height).fill()
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    /// Two short right-aligned lines, used where one number is not enough (network up and down).
    static func twoLines(_ top: String, _ bottom: String, width: CGFloat, tint: NSColor?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint ?? NSColor.black, .paragraphStyle: paragraph]
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            (top as NSString).draw(in: NSRect(x: 0, y: 8.5, width: rect.width, height: 10), withAttributes: attributes)
            (bottom as NSString).draw(in: NSRect(x: 0, y: -0.5, width: rect.width, height: 10), withAttributes: attributes)
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}
