import AppKit
import WispCore

// Pieces the AI usage dropdown and the dashboard share: which plan limit is closest to
// running out, a chart of where it is heading, an account's limits in the plan cards'
// line grammar, and the ghost rows a list shows before its first reading.

/// Where plan limits are going, worked out from the figures the accounts report.
@MainActor
enum PlanOutlook {
    struct Pick {
        let usage: PlanUsage
        let window: PlanUsage.Window
    }

    /// How long a limit's window runs, as `PlanCard.elapsed` measures it.
    static func length(_ window: PlanUsage.Window) -> TimeInterval {
        window.name.hasPrefix("5-hour") ? 5 * 3600 : window.name.hasSuffix("month") ? 30 * 86_400 : 7 * 86_400
    }

    /// Where the limit lands by its reset at the rate so far, once a tenth of the window
    /// has passed; earlier than that a few minutes of work would read as a flood.
    static func projected(_ window: PlanUsage.Window, now: Date) -> Double? {
        guard window.used > 0, let elapsed = PlanCard.elapsed(window, now: now), elapsed >= 0.1 else { return nil }
        return window.used / elapsed
    }

    /// The limit closest to running out across `plans`: one used up, then one the pace
    /// would use up before it resets (the soonest), then the highest of used and heading for.
    static func closest(_ plans: [PlanUsage], now: Date) -> Pick? {
        let counted = plans.filter { $0.problem == nil && !$0.windows.isEmpty }
        func score(_ window: PlanUsage.Window) -> Double {
            if window.used >= 1 { return 4 }
            let pace = PlanCard.pace(window, now: now)
            if pace.short, let elapsed = PlanCard.elapsed(window, now: now), elapsed > 0, window.used > 0 {
                let runsOut = (1 - window.used) * elapsed * length(window) / window.used
                return 2 + 1 / (1 + runsOut / 3600)
            }
            return max(window.used, min(1.5, projected(window, now: now) ?? 0))
        }
        var best: (Pick, Double)?
        for usage in counted {
            for window in usage.windows {
                let value = score(window)
                if best == nil || value > best!.1 { best = (Pick(usage: usage, window: window), value) }
            }
        }
        guard let best else { return nil }
        // Nothing used anywhere: the first account's week says more than an idle session.
        if best.1 == 0, let usage = counted.first, let window = PlanCard.headline(usage.windows) {
            return Pick(usage: usage, window: window)
        }
        return best.0
    }

    /// "this week", "this session", "this month": the window in a sentence.
    static func span(_ window: PlanUsage.Window) -> String {
        let lower = window.name.lowercased()
        if lower.contains("week") { return "this week" }
        if lower.hasPrefix("5-hour") { return "this session" }
        if lower.contains("month") { return "this month" }
        return ""
    }

    /// The status dot for a pick: red near or at the limit, amber at 60% or ahead of pace.
    static func dot(_ pick: Pick, now: Date) -> NSColor {
        let used = pick.window.used
        if used >= 0.9 { return A2.bad }
        if used >= 0.6 || PlanCard.pace(pick.window, now: now).short || (projected(pick.window, now: now) ?? 0) >= 1 { return A2Dev.idle }
        return A2Dev.live
    }

    /// The status line under a dropdown's title, longest first, so the widest that fits shows.
    static func status(_ pick: Pick, now: Date) -> [String] {
        let name = pick.usage.label ?? pick.usage.provider
        let percent = Format.percent(pick.window.used)
        let span = Self.span(pick.window)
        let at = "\(name) at \(percent)" + (span.isEmpty ? "" : " " + span)
        let pace = PlanCard.pace(pick.window, now: now)
        var going: String?
        if pick.window.used >= 1 {
            going = "Used up"
        } else if pace.short, pace.text.hasPrefix("Runs out") {
            going = PlanCard.shortDetail(pace.text)
        } else if let projected = projected(pick.window, now: now) {
            going = "Heading for \(Format.percent(min(1, projected)))"
        }
        let lower = going.map { $0.prefix(1).lowercased() + $0.dropFirst() }
        return [going.map { at + " · " + $0 }, lower.map { "\(name) \(percent) · " + $0 }, at, "\(name) at \(percent)"].compactMap { $0 }
    }
}

// MARK: - Pace chart

/// Where one limit is going across its window: the time from its start on the left to
/// its reset on the right, the share used so far as a filled area at the rate so far,
/// a dashed line on to the reset at that rate, and even use as a dotted diagonal.
/// Hovering reads off a time and the share at this rate.
@MainActor
final class PaceChart: BitmapView {
    var limit: PlanUsage.Window? { didSet { if limit != oldValue { needsDisplay = true } } }
    var now = Date() { didSet { needsDisplay = true } }
    var color: NSColor = A2.cpu { didSet { needsDisplay = true } }
    /// The line above the plot: where the limit is heading.
    var caption = "" { didSet { if caption != oldValue { needsDisplay = true } } }
    var captionWarns = false
    /// The shape the plot is cut to, such as the card's rounded bottom.
    var clip: ((CGRect) -> CGPath)?
    /// Room at the sides for the caption and the labels.
    var padX: CGFloat = 12
    var captionFont = Theme.sans(12)
    private var hoverX: CGFloat? {
        didSet { if hoverX != oldValue { needsDisplay = true } }
    }

    static let top: CGFloat = 34

    private var plot: NSRect { NSRect(x: 0, y: Self.top, width: bounds.width, height: max(1, bounds.height - 1 - Self.top)) }

    /// The limit's start and length, when its reset is known.
    private var span: (start: Date, length: TimeInterval)? {
        guard let limit, let resets = limit.resets, resets > now else { return nil }
        let length = PlanOutlook.length(limit)
        return (resets.addingTimeInterval(-length), length)
    }

    private var elapsed: Double? { limit.flatMap { PlanCard.elapsed($0, now: now) } }

    /// The share used at `fraction` of the limit: the rate so far up to now, on at
    /// that rate after it, capped at the whole limit.
    private func value(at fraction: Double) -> Double? {
        guard let limit, let elapsed, elapsed > 0 else { return nil }
        return min(1, limit.used * fraction / elapsed)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = plot
        func y(_ value: Double) -> CGFloat { rect.maxY - CGFloat(min(1, max(0, value))) * rect.height }
        func x(_ fraction: Double) -> CGFloat { rect.minX + CGFloat(min(1, max(0, fraction))) * rect.width }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = A2.drawingDark

        context.saveGState()
        context.addPath(clip?(bounds) ?? A2.bottomRounded(bounds))
        context.clip()
        // Dotted lines at half and the whole limit, as the other charts draw them.
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 4])
        for fraction: CGFloat in [0.5, 1] {
            let lineY = floor(rect.maxY - fraction * rect.height) + 0.5
            context.move(to: CGPoint(x: 0, y: lineY))
            context.addLine(to: CGPoint(x: bounds.width, y: lineY))
            context.strokePath()
        }

        let resolved = (color.usingColorSpace(.sRGB) ?? color).cgColor
        var end: CGPoint?
        var nowPoint: CGPoint?
        if let limit, let elapsed, span != nil {
            // Even use: none at the start, the whole limit at the reset.
            context.setStrokeColor((A2.gridLabel.usingColorSpace(.sRGB) ?? A2.gridLabel).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [1.5, 3])
            context.move(to: CGPoint(x: x(0), y: y(0)))
            context.addLine(to: CGPoint(x: x(1), y: y(1)))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])

            let here = CGPoint(x: x(elapsed), y: y(limit.used))
            nowPoint = here
            // Now, as a hairline across the plot, so the left of it reads as gone and the right as ahead.
            context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: here.x.rounded() + 0.5, y: rect.minY))
            context.addLine(to: CGPoint(x: here.x.rounded() + 0.5, y: bounds.height))
            context.strokePath()
            let used = CGMutablePath()
            used.move(to: CGPoint(x: x(0), y: bounds.height))
            used.addLine(to: CGPoint(x: x(0), y: y(0)))
            used.addLine(to: here)
            used.addLine(to: CGPoint(x: here.x, y: bounds.height))
            used.closeSubpath()
            A2.fade(used, color: color, alpha: dark ? 0.42 : 0.3, from: rect.minY, to: bounds.height, in: context)

            // On at the same rate until the reset, or until it reaches the whole limit.
            if limit.used > 0, limit.used < 1 {
                let reach = elapsed / limit.used
                let stop = min(1, reach)
                let point = CGPoint(x: x(stop), y: y(min(1, limit.used * stop / elapsed)))
                end = point
                let ahead = CGMutablePath()
                ahead.move(to: CGPoint(x: here.x, y: bounds.height))
                ahead.addLine(to: here)
                ahead.addLine(to: point)
                ahead.addLine(to: CGPoint(x: point.x, y: bounds.height))
                ahead.closeSubpath()
                A2.fade(ahead, color: color, alpha: dark ? 0.14 : 0.1, from: rect.minY, to: bounds.height, in: context)
                context.setStrokeColor(resolved)
                context.setLineWidth(1.6)
                context.setLineCap(.round)
                context.setLineDash(phase: 0, lengths: [4, 4])
                context.move(to: here)
                context.addLine(to: point)
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            context.setStrokeColor(resolved)
            context.setLineWidth(1.8)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: x(0), y: y(0)))
            context.addLine(to: here)
            context.strokePath()
        } else if let limit {
            // No reset reported: the share used, level across.
            let level = y(limit.used)
            let area = CGMutablePath(rect: CGRect(x: 0, y: level, width: bounds.width, height: bounds.height - level), transform: nil)
            A2.fade(area, color: color, alpha: dark ? 0.3 : 0.2, from: rect.minY, to: bounds.height, in: context)
            context.setStrokeColor(resolved)
            context.setLineWidth(1.8)
            context.move(to: CGPoint(x: 0, y: level))
            context.addLine(to: CGPoint(x: bounds.width, y: level))
            context.strokePath()
        }
        context.restoreGState()

        // The point it would run out at, and now.
        if let end, let limit, limit.used < 1, end.y <= y(1) + 0.5 {
            let runsOut = A2.bad
            runsOut.setFill()
            NSBezierPath(ovalIn: NSRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)).fill()
        }
        if let nowPoint, hoverX == nil {
            let font = Theme.sans(10, .medium)
            let width = A2Dev.width("Now", font)
            // To the right of the hairline, unless the edge or a run-out dot is in the way.
            let crowded = end.map { $0.x > nowPoint.x && $0.x - nowPoint.x < width + 14 && $0.y < rect.minY + 16 } ?? false
            let left = nowPoint.x + 5 + width > bounds.width - padX || crowded ? nowPoint.x - 5 - width : nowPoint.x + 5
            A2Dev.text("Now", x: left, mid: rect.minY + 8, width: width + 1, font: font, color: A2.gridLabel)
        }
        if let nowPoint {
            SoftDropdown.Look.card.setFill()
            NSBezierPath(ovalIn: NSRect(x: nowPoint.x - 5, y: nowPoint.y - 5, width: 10, height: 10)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: nowPoint.x - 3.5, y: nowPoint.y - 3.5, width: 7, height: 7)).fill()
        }

        // The whole limit's label on the right, and where the line ends just under it.
        let labelFont = Theme.digits(10)
        let label = "100%"
        let labelWidth = A2Dev.width(label, labelFont)
        let labelMid = floor(rect.minY) - 5 - labelFont.ascender / 2 + 1
        var labelShown = true
        // Where it lands by the reset; a run-out point has its dot and the caption instead.
        if let end, let limit, let elapsed, limit.used < elapsed {
            let landing = limit.used / elapsed
            let text = Format.percent(landing)
            let font = Theme.digits(11, .semibold)
            let width = A2Dev.width(text, font)
            let right = min(end.x - 8, bounds.width - padX)
            var mid = end.y - 10
            if end.x > bounds.width - padX - 2 { mid = end.y - 11 }
            mid = max(rect.minY + 8, mid)
            if abs(mid - labelMid) < 14, right > bounds.width - padX - labelWidth - width - 6 { labelShown = false }
            A2Dev.text(text, x: right - width, mid: mid, width: width + 1, font: font, color: SoftDropdown.Look.heading)
        }
        if labelShown {
            A2Dev.text(label, x: bounds.width - padX - labelWidth, mid: labelMid, width: labelWidth + 1, font: labelFont, color: A2.gridLabel)
        }

        if let hoverX, let span, let limit, let elapsed, elapsed > 0 {
            drawReadout(hoverX, rect: rect, span: span, limit: limit, elapsed: elapsed, y: y, x: x)
        } else {
            let room = bounds.width - padX * 2 - (labelShown ? labelWidth + 12 : 0)
            let text = PlanCard.fitted(caption, room: room, font: captionFont)
            A2Dev.text(text, x: padX, mid: Self.top / 2 - 1, width: room, font: captionFont,
                       color: captionWarns ? A2.warn : SoftDropdown.Look.secondary)
        }
    }

    /// A hairline at the pointer, a dot on the line, and the time and share above the plot.
    private func drawReadout(_ pointer: CGFloat, rect: NSRect, span: (start: Date, length: TimeInterval), limit: PlanUsage.Window,
                             elapsed: Double, y: (Double) -> CGFloat, x: (Double) -> CGFloat) {
        let fraction = Double(min(1, max(0, (pointer - rect.minX) / rect.width)))
        guard let value = value(at: fraction) else { return }
        let lineX = x(fraction).rounded() + 0.5
        A2.tertiary.setFill()
        NSRect(x: lineX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: lineX - 3, y: y(value) - 3, width: 6, height: 6)).fill()
        let date = span.start.addingTimeInterval(span.length * fraction)
        let when = limit.name.hasPrefix("5-hour") ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let past = fraction <= elapsed
        let even = "even use \(Format.percent(fraction))"
        let text = past ? "\(when) · about \(Format.percent(value)) · \(even)" : "\(when) · \(Format.percent(value)) at this rate · \(even)"
        let room = bounds.width - padX * 2
        A2Dev.text(PlanCard.fitted(text, room: room, font: captionFont), x: padX, mid: Self.top / 2 - 1, width: room,
                   font: captionFont, color: SoftDropdown.Look.heading)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverX = span == nil || point.y < Self.top - 6 ? nil : point.x
    }

    override func mouseExited(with event: NSEvent) { hoverX = nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverX = nil }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Pace" }
    // The plot and its hover readout say how use compares with even use and where this
    // rate ends up; VoiceOver gets the same figures as words.
    override func accessibilityValue() -> Any? {
        var parts = [captionWarns && !caption.isEmpty ? "Warning: " + caption : caption]
        if let limit, let elapsed {
            parts.append("\(Format.percent(limit.used)) used, even use would be \(Format.percent(elapsed)) by now")
            if let atReset = value(at: 1) { parts.append("about \(Format.percent(atReset)) by reset at this rate") }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "; ")
    }
}
