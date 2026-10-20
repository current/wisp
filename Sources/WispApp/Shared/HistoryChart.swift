import AppKit

/// A larger chart for the window: filled line, faint gridlines, a label for the top
/// of the scale and the time span, and a hover readout. Drawn in draw(_:) with no
/// layers or Metal, so it costs memory only for its values.
final class HistoryChart: NSView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var secondary: [Float] = [] { didSet { needsDisplay = true } }
    var ceiling: Float? { didSet { needsDisplay = true } }
    var color: NSColor = .controlAccentColor
    var secondaryColor: NSColor = .systemTeal
    /// Formats a value for the scale label and the hover readout.
    var format: (Float) -> String = { String(format: "%.0f", $0) }
    /// Minutes the values span; each value is one equal step.
    var spanMinutes = 60 { didSet { needsDisplay = true } }

    private var hoverIndex: Int?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        guard values.count > 1, plot.contains(NSPoint(x: point.x, y: plot.midY)) else { return }
        let index = Int(((point.x - plot.minX) / plot.width * CGFloat(values.count - 1)).rounded())
        if index != hoverIndex {
            hoverIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    private var plotRect: NSRect { NSRect(x: 0, y: 18, width: bounds.width, height: bounds.height - 30) }

    private var top: Float {
        if let ceiling { return ceiling }
        let peak = max(values.lazy.filter { !$0.isNaN }.max() ?? 0, secondary.lazy.filter { !$0.isNaN }.max() ?? 0)
        return peak > 0 ? peak * 1.15 : 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect
        let top = self.top
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let isEmpty = values.allSatisfy({ $0.isNaN }) && secondary.allSatisfy({ $0.isNaN })
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        for step in 0...2 where !(isEmpty && step == 1) {
            let y = plot.minY + plot.height * CGFloat(step) / 2
            NSRect(x: plot.minX, y: y.rounded() - 0.5, width: plot.width, height: 0.5).fill()
        }
        if hoverIndex == nil, !isEmpty {
            (format(top) as NSString).draw(at: NSPoint(x: plot.minX, y: plot.maxY + 1), withAttributes: attributes)
        }
        let span = spanMinutes >= 120 ? "\(spanMinutes / 60) hours ago" : "\(spanMinutes) minutes ago"
        (span as NSString).draw(at: NSPoint(x: plot.minX, y: 2), withAttributes: attributes)
        let now = "now" as NSString
        now.draw(at: NSPoint(x: plot.maxX - now.size(withAttributes: attributes).width, y: 2), withAttributes: attributes)

        if isEmpty {
            let empty = "Collecting history" as NSString
            let size = empty.size(withAttributes: attributes)
            empty.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
            return
        }
        SparklineView.plot(values, in: plot, top: top, color: color)
        if !secondary.isEmpty { SparklineView.plot(secondary, in: plot, top: top, color: secondaryColor) }

        if let index = hoverIndex, index >= 0, index < values.count, values.count > 1 {
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1)
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: x.rounded() - 0.5, y: plot.minY, width: 1, height: plot.height).fill()
            let minutesAgo = Int(Double(values.count - 1 - index) * Double(spanMinutes) / Double(max(values.count - 1, 1)))
            var text = values[index].isNaN ? "no data" : format(values[index])
            if index < secondary.count, !secondary[index].isNaN { text += " / " + format(secondary[index]) }
            text += minutesAgo == 0 ? ", now" : ", \(minutesAgo) min ago"
            let label = text as NSString
            let bold: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = label.size(withAttributes: bold)
            let left = min(max(plot.minX, x - size.width / 2), plot.maxX - size.width)
            label.draw(at: NSPoint(x: left, y: plot.maxY + 1), withAttributes: bold)
        }
    }
}
