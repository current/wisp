import AppKit
import WispCore

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
        let font = Theme.digits(9, .medium)
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

/// Labelled spikes on a history chart: a small ring on the line at each peak and a
/// short label in a band above the plot, joined by a hairline. Hovering a label
/// shades the spell and shows the detail; the chart forwards clicks to `hit`.
/// It draws inside the chart's own bitmap, so it adds no layers and costs nothing
/// between redraws.
@MainActor
final class SpikeMarks {
    var spikes: [ChartSpike] = [] { didSet { if spikes != oldValue { hovered = nil; rects = [] } } }
    var color: NSColor = Theme.accent
    /// The height the label band takes from the top of the plot when there are spikes.
    static let band: CGFloat = 22
    var inset: CGFloat { spikes.isEmpty ? 0 : Self.band }
    private(set) var hovered: Int?
    /// Label and marker areas from the last draw, for hover and clicks.
    private var rects: [(label: NSRect, marker: NSRect)] = []
    private static let font = Theme.sans(11)
    private static let strong = Theme.sans(11, .medium)

    /// The full label, or without its time when room is short (the time is in the hover detail).
    private func text(_ spike: ChartSpike, short: Bool = false) -> NSAttributedString {
        let parts = spike.label.components(separatedBy: " · ")
        if short, parts.count > 1 {
            return NSAttributedString(string: parts.dropFirst().joined(separator: " · "), attributes: [.font: Self.strong, .foregroundColor: Theme.ink])
        }
        let text = NSMutableAttributedString(string: parts[0], attributes: [.font: Self.font, .foregroundColor: Theme.inkSecondary])
        if parts.count > 1 {
            text.append(NSAttributedString(string: "  " + parts.dropFirst().joined(separator: " · "),
                                           attributes: [.font: Self.strong, .foregroundColor: Theme.ink]))
        }
        return text
    }

    /// - Parameters:
    ///   - plot: the plot area, already lowered by `inset`.
    ///   - x: the x of a series index.
    ///   - top: the y of the highest line at a series index.
    func draw(in plot: NSRect, x: (Int) -> CGFloat, top: (Int) -> CGFloat?) {
        rects = []
        guard !spikes.isEmpty else { return }
        let bandY = plot.minY - Self.band
        var lastRight = -CGFloat.infinity
        for (index, spike) in spikes.enumerated() {
            let px = x(spike.peak)
            guard let py = top(spike.peak) else { rects.append((.zero, .zero)); continue }
            if hovered == index {
                color.withAlphaComponent(0.08).setFill()
                let from = x(spike.start), to = x(spike.end)
                NSRect(x: from - 2, y: plot.minY, width: max(4, to - from + 4), height: plot.height).fill()
            }
            // The label, centred over the peak and kept inside the plot; skipped when it would
            // run into the one before (the ring stays, and hovering it shows the detail).
            var label = text(spike)
            var box = NSRect.zero
            var fits = false
            for short in [false, true] {
                label = text(spike, short: short)
                let width = ceil(label.size().width)
                box = NSRect(x: px - width / 2, y: bandY + 2, width: width, height: 15)
                box.origin.x = min(max(plot.minX, box.minX, lastRight + 12), plot.maxX - box.width)
                // Slid along to clear the one before, it must still sit over (or right by) its peak.
                fits = box.minX >= lastRight + 12 && px >= box.minX - 24 && px <= box.maxX + 24
                if fits { break }
            }
            if fits {
                label.draw(at: NSPoint(x: box.minX, y: box.minY))
                lastRight = box.maxX
                let leader = NSBezierPath()
                leader.move(to: NSPoint(x: px + 0.5, y: box.maxY + 3))
                leader.line(to: NSPoint(x: px + 0.5, y: py - 5))
                leader.setLineDash([2, 2], count: 2, phase: 0)
                leader.lineWidth = 1
                Theme.inkTertiary.withAlphaComponent(0.7).setStroke()
                if py - 5 > box.maxY + 3 { leader.stroke() }
            }
            let ring = NSRect(x: px - 3.5, y: py - 3.5, width: 7, height: 7)
            Theme.card.setFill()
            NSBezierPath(ovalIn: ring).fill()
            color.setStroke()
            let outline = NSBezierPath(ovalIn: ring)
            outline.lineWidth = 1.5
            outline.stroke()
            rects.append((fits ? box.insetBy(dx: -4, dy: -3) : .zero, ring.insetBy(dx: -6, dy: -6)))
        }
        if let index = hovered, index < spikes.count, index < rects.count {
            drawDetail(spikes[index].detail, near: rects[index].marker, in: plot)
        }
    }

    private func drawDetail(_ detail: String, near anchor: NSRect, in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(11, .medium), .foregroundColor: NSColor.white]
        let size = (detail as NSString).size(withAttributes: attributes)
        var box = NSRect(x: anchor.midX - (size.width + 16) / 2, y: anchor.maxY + 4, width: size.width + 16, height: 22)
        if box.maxY > plot.maxY { box.origin.y = anchor.minY - 4 - box.height }
        box.origin.x = min(max(plot.minX, box.minX), plot.maxX - box.width)
        Theme.tooltip.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (detail as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + (22 - size.height) / 2), withAttributes: attributes)
    }

    private func index(at point: NSPoint) -> Int? {
        rects.firstIndex { $0.label.contains(point) || $0.marker.contains(point) }
    }

    /// Updates the hovered spike; true when the chart must redraw.
    func hover(at point: NSPoint?) -> Bool {
        let now = point.flatMap(index(at:))
        guard now != hovered else { return false }
        hovered = now
        return true
    }

    func hit(_ point: NSPoint) -> ChartSpike? {
        index(at: point).map { spikes[$0] }
    }
}
