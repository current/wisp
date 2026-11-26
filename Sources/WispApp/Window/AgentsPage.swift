import AppKit
import WispCore

/// An agent's mark: the icon of its own Mac app when one is installed, otherwise its
/// glyph and colour, which the A2 views draw on a quiet square.
@MainActor
enum AgentLook {
    static func mark(_ kind: String, size: CGFloat, appearance: NSAppearance) -> (icon: NSImage?, glyph: String, tint: NSColor) {
        let (symbol, tint) = AgentMark.symbol(kind)
        let image = AgentMark.image(kind, size: size, appearance: appearance)
        // AgentMark hands back IconTile's cached glyph when there is no app to take the icon from.
        let isGlyph = image === IconTile.glyph(symbol, tint: tint, size: size, appearance: appearance)
        return (isGlyph ? nil : image, symbol, tint)
    }
}

/// One account's plan limits: a header with the agent's mark, account and plan, then
/// each window as a tick meter with when it resets and whether the current pace
/// runs it out first. The windows share the card's height.
@MainActor
final class PlanCard: CardView {
    final class WindowRow: BitmapView {
        var name = ""
        var used: Double = 0
        var detail = ""
        var short = false
        /// Shown in place of `detail` while hovered: how the window is going, "Runs out
        /// in…" when the pace would use it up, otherwise the reset's clock time.
        var resets: String?
        private var hovering = false {
            didSet {
                guard hovering != oldValue else { return }
                crossfade()
                needsDisplay = true
            }
        }
        let meter = TickMeter()

        /// The name line, then the bar with the percentage beside it.
        static let height: CGFloat = 32
        private static let figureWidth: CGFloat = 56

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(meter)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            meter.frame = NSRect(x: 0, y: bounds.height - 9, width: bounds.width - Self.figureWidth, height: 6)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = resets != nil }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { hovering = false }
        }

        override func draw(_ dirtyRect: NSRect) {
            let right = bounds.width - Self.figureWidth
            let used = A2Dev.measuredText(PlanCard.title(name), x: 0, mid: 8, width: right, font: Theme.sans(12, .medium), color: A2.secondary)
            let showReset = hovering && resets != nil
            let room = right - used - 12
            A2Dev.text(PlanCard.fitted(showReset ? resets ?? "" : detail, room: room, font: Theme.sans(11)), x: used + 12, mid: 8,
                       width: room, font: Theme.sans(11), color: short && showReset ? A2.warn : A2.tertiary, right: true)
            let font = Theme.digits(15, .semibold)
            A2Dev.text(Format.percent(self.used), x: right, mid: bounds.height - 6, width: Self.figureWidth, font: font, color: A2.primary, right: true)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityValue() -> Any? {
            "\(PlanCard.title(name)) \(Format.percent(used)), \(detail)" + (resets.map { $0 == detail ? "" : ", " + $0 } ?? "")
        }
    }

    /// One line: the provider's mark and name, then the account and the plan on the
    /// right. A long account ends in "…" and scrolls through while hovered.
    final class Header: BitmapView {
        var provider = ""
        /// Shown in place of the provider's name, as T3 Code labels its accounts.
        var title: String? { didSet { showDetail() } }
        /// When the figures were reported ("4m ago"); hovering it shows `account` instead.
        var updated = "" { didSet { showDetail() } }
        var account = "" { didSet { showDetail() } }
        var plan: String? { didSet { needsLayout = true } }
        private let detail = MarqueeLabel()
        static let height: CGFloat = 24
        private static let titleFont = Theme.sans(14, .semibold)
        private static let planFont = Theme.sans(11, .semibold)

        override init(frame: NSRect) {
            super.init(frame: frame)
            detail.font = A2Dev.detailFont
            addSubview(detail)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The figures' age once they are old enough to matter, otherwise the account
        /// when the title does not already name it. Hovering shows the account.
        private func showDetail() {
            detail.text = !updated.isEmpty ? updated : title == nil ? account : ""
            detail.hoverText = account.isEmpty || detail.text == account ? nil : account
        }

        private var planWidth: CGFloat { plan.map { A2Dev.width($0, Self.planFont) + 16 } ?? 0 }
        private var titleWidth: CGFloat { A2Dev.width(title ?? provider, Self.titleFont) }

        override func layout() {
            super.layout()
            // The name keeps its room; the account takes what is left before the plan.
            let left = 30 + min(titleWidth, bounds.width * 0.55) + 12
            let right = bounds.width - (plan == nil ? 0 : planWidth + 8)
            detail.frame = NSRect(x: left, y: 0, width: max(0, right - left), height: Self.height)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let mid = Self.height / 2
            let markRect = NSRect(x: 0, y: mid - 11, width: 22, height: 22)
            let look = AgentLook.mark(provider, size: 22, appearance: effectiveAppearance)
            if let icon = look.icon {
                icon.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                A2Dev.drawGlyphTile(look.glyph, tint: look.tint, in: markRect, appearance: effectiveAppearance)
            }
            if let plan {
                let width = planWidth
                let pill = NSRect(x: bounds.width - width, y: mid - 9.5, width: width, height: 19)
                A2Dev.tile.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9.5, yRadius: 9.5).fill()
                A2Dev.text(plan, x: pill.minX + 8, mid: pill.midY, width: width, font: Self.planFont, color: A2.secondary)
            }
            A2Dev.text(title ?? provider, x: 30, mid: mid, width: min(titleWidth, bounds.width * 0.55) + 1, font: Self.titleFont, color: A2.primary)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityValue() -> Any? { [title ?? provider, plan ?? "", account].joined(separator: ", ") }
    }

    /// The window page's card: the account, its fullest limit as the figure, then every
    /// limit as a line (name, bar with a pace mark, percentage, when it resets), laid out
    /// like the dropdowns' cards. The dashboard's AI usage block keeps `Header` and
    /// `WindowRow`.
    private let face = Face()
    private let figure = A2.figure()
    private let state = Pill()
    private let meta = MarqueeLabel()

    static let figureBaseline: CGFloat = 76
    static let captionMid: CGFloat = 97
    static let firstLine: CGFloat = 132
    static let pitch: CGFloat = 26
    static let bottom: CGFloat = 20

    /// A card's height for `windows` limits, or for its one-line note when it has none.
    static func height(windows: Int) -> CGFloat {
        firstLine + CGFloat(max(windows, 1) - 1) * pitch + bottom
    }

    /// A limit's name, scope first: "Gemini · 5-hour", "Fable · Weekly", or just
    /// "5-hour" and "Weekly" for an account's own limits.
    static func title(_ name: String) -> String {
        if name == "5-hour session" { return "5-hour" }
        if name == "This week" { return "Weekly" }
        if name == "This month" { return "Monthly" }
        if name.hasPrefix("5-hour ") { return String(name.dropFirst(7)) + " · 5-hour" }
        if name.hasSuffix(" this week") { return String(name.dropLast(10)) + " · Weekly" }
        return name
    }

    override init() {
        super.init()
        for view in [face, figure, state, meta] as [NSView] { addSubview(view) }
        figure.color = A2.primary
        meta.font = A2Dev.detailFont
        meta.color = A2.tertiary
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    static func problemText(_ problem: String) -> NSAttributedString {
        NSAttributedString(string: problem, attributes: [.font: A2Dev.detailFont, .foregroundColor: A2.warn])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The limit the figure shows: the fullest, or the week while nothing is used.
    static func headline(_ windows: [PlanUsage.Window]) -> PlanUsage.Window? {
        let fullest = windows.max { $0.used < $1.used }
        if let fullest, fullest.used > 0 { return fullest }
        return windows.first { !$0.name.hasPrefix("5-hour") } ?? windows.first
    }

    /// How far through its window a limit is: where even use would have the bar now.
    static func elapsed(_ window: PlanUsage.Window, now: Date) -> Double? {
        guard let resets = window.resets, resets > now else { return nil }
        let length: Double = window.name.hasPrefix("5-hour") ? 5 * 3600 : window.name.hasSuffix("month") ? 30 * 86_400 : 7 * 86_400
        return min(1, max(0, 1 - resets.timeIntervalSince(now) / length))
    }

    func show(_ usage: PlanUsage, now: Date) {
        face.provider = usage.provider
        face.name = usage.label ?? usage.provider
        face.plan = usage.plan
        let age = Self.updated(usage, now: now)
        meta.text = !age.isEmpty ? age : usage.label == nil ? usage.account : ""
        meta.hoverText = usage.account.isEmpty || meta.text == usage.account ? nil : usage.account

        var lines: [Face.Line] = []
        var anyShort = false
        for window in usage.windows {
            let pace = Self.pace(window, now: now)
            anyShort = anyShort || (pace.short && window.used < 1)
            lines.append(.init(label: Self.title(window.name), fraction: window.used, pace: Self.elapsed(window, now: now),
                               color: Self.meterColor(window, short: pace.short), figure: Format.percent(window.used),
                               detail: Self.shortDetail(pace.text), hover: pace.resets, warns: pace.short))
        }
        face.lines = lines
        face.note = usage.problem

        if let headline = Self.headline(usage.windows) {
            let (number, unit) = A2Dev.parts(Format.percent(headline.used))
            figure.show(number, unit: unit)
            let pace = Self.pace(headline, now: now)
            face.caption = (Self.title(headline.name), Self.outlook(headline, pace: pace, now: now))
            face.captionWarns = pace.short
        } else {
            figure.show("–", unit: "")
            face.caption = nil
        }
        let used = usage.windows.map(\.used).max() ?? 0
        if used >= 1 {
            (state.text, state.tone) = ("Used up", .bad)
        } else if used >= 0.9 {
            (state.text, state.tone) = ("Near limit", .bad)
        } else if anyShort {
            (state.text, state.tone) = ("Ahead of pace", .warn)
        } else {
            state.text = ""
        }
        state.isHidden = state.text.isEmpty
        setAccessibilityLabel((usage.label ?? usage.provider) + (usage.plan.map { ", " + $0 } ?? ""))
        // The face draws its lines and their pace marks in one pass, so the card says
        // what they show, including what the hover and the mark would add.
        let outlook = face.caption.map { $0.detail.isEmpty ? "" : $0.title + " " + $0.detail } ?? ""
        let spoken = lines.map { line -> String in
            var text = "\(line.label) \(line.figure), \(line.detail)"
            if let pace = line.pace, pace > 0.01, pace < 0.99 { text += ", even pace would be \(Format.percent(pace))" }
            if let hover = line.hover, hover != line.detail { text += ", " + hover }
            return text
        }
        setAccessibilityValue(([state.text, outlook, usage.problem ?? ""] + spoken).filter { !$0.isEmpty }.joined(separator: "; "))
        face.needsDisplay = true
        needsLayout = true
    }

    /// Where the headline limit is going: "Heading for 31% by reset · 5d 3h" once a tenth
    /// of its window has passed, "Runs out in 2h at this rate" when it would run out first.
    static func outlook(_ window: PlanUsage.Window, pace: (text: String, short: Bool, resets: String?), now: Date) -> String {
        guard !pace.short, window.used > 0, window.used < 1, let elapsed = elapsed(window, now: now), elapsed >= 0.1,
              let resets = window.resets else { return pace.text }
        let projected = Format.percent(min(1, window.used / elapsed))
        return "Heading for \(projected) by reset · " + Format.duration(resets.timeIntervalSince(now))
    }

    /// A line's detail, short enough for its column: "5d 4h" for "Resets in 5d 4h".
    static func shortDetail(_ text: String) -> String {
        if text.hasPrefix("Resets in ") { return String(text.dropFirst("Resets in ".count)) }
        if text.hasPrefix("Runs out in ") { return "Out in " + text.dropFirst("Runs out in ".count).replacingOccurrences(of: " at this rate", with: "") }
        return text.replacingOccurrences(of: "Used up · Resets in ", with: "Back in ")
    }

    /// Everything but the figure, the state and the meta line, drawn in one pass.
    final class Face: BitmapView {
        struct Line: Equatable {
            var label: String
            var fraction: Double
            /// Where even use would have the bar now, 0 to 1.
            var pace: Double?
            var color: NSColor
            var figure: String
            var detail: String
            /// Shown in place of `detail` while hovered: the reset's clock time, or when
            /// the pace would use the limit up.
            var hover: String?
            var warns: Bool
        }

        var provider = ""
        var name = ""
        var plan: String?
        var caption: (title: String, detail: String)?
        var captionWarns = false
        var note: String?
        var lines: [Line] = []
        private var hovered: Int? {
            didSet {
                guard hovered != oldValue else { return }
                crossfade()
                needsDisplay = true
            }
        }

        static let titleFont = Theme.sans(13, .semibold)
        static let planFont = Theme.sans(11, .semibold)
        static let body = Theme.sans(12)
        static let strong = Theme.sans(12, .semibold)
        static let figureFont = Theme.digits(12.5, .semibold)
        static let markSize: CGFloat = 20
        static let titleMid: CGFloat = 24
        private static let barHeight: CGFloat = 6

        /// Where the title, plan and meta end, for the card to place its meta after.
        var titleEnd: CGFloat {
            let title = A2.padSide + Self.markSize + 9 + ceil(A2Dev.width(name, Self.titleFont))
            return title + (plan.map { 8 + ceil(A2Dev.width($0, Self.planFont)) + 14 } ?? 0)
        }

        private var columns: (label: CGFloat, figure: CGFloat, detail: CGFloat) {
            let label = ceil(lines.map { A2Dev.width($0.label, Self.body) }.max() ?? 0)
            let figure = ceil(max(A2Dev.width("100%", Self.figureFont), lines.map { A2Dev.width($0.figure, Self.figureFont) }.max() ?? 0))
            let detail = ceil(min(96, max(46, lines.map { A2Dev.width($0.detail, Self.body) }.max() ?? 0)))
            return (min(label + 18, bounds.width * 0.42), figure, detail)
        }

        override func draw(_ dirtyRect: NSRect) {
            let left = A2.padSide, right = bounds.width - A2.padSide
            let mid = Self.titleMid
            let markRect = NSRect(x: left, y: mid - Self.markSize / 2, width: Self.markSize, height: Self.markSize)
            let look = AgentLook.mark(provider, size: Self.markSize, appearance: effectiveAppearance)
            if let icon = look.icon {
                icon.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                A2Dev.drawGlyphTile(look.glyph, tint: look.tint, in: markRect, appearance: effectiveAppearance)
            }
            let titleLeft = markRect.maxX + 9
            let titleWidth = min(ceil(A2Dev.width(name, Self.titleFont)), right - titleLeft - 60)
            A2Dev.text(name, x: titleLeft, mid: mid, width: titleWidth + 1, font: Self.titleFont, color: A2.primary)
            if let plan {
                let width = ceil(A2Dev.width(plan, Self.planFont)) + 14
                let pill = NSRect(x: titleLeft + titleWidth + 8, y: mid - 9, width: width, height: 18)
                A2Dev.tile.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
                A2Dev.text(plan, x: pill.minX + 7, mid: pill.midY, width: width, font: Self.planFont, color: A2.secondary)
            }

            if let caption {
                let titleWidth = ceil(A2Dev.width(caption.title, Self.strong))
                A2Dev.text(caption.title, x: left, mid: PlanCard.captionMid, width: titleWidth + 1, font: Self.strong, color: A2.secondary)
                if !caption.detail.isEmpty {
                    let x = left + titleWidth + 6
                    A2Dev.text("· " + caption.detail, x: x, mid: PlanCard.captionMid, width: right - x, font: Self.body,
                               color: captionWarns ? A2.warn : A2.tertiary)
                }
            }

            var y = PlanCard.firstLine
            if let note {
                A2Dev.text(note, x: left, mid: y, width: right - left, font: Self.body, color: A2.warn)
                y += PlanCard.pitch
            }
            let (labelColumn, figureColumn, detailColumn) = columns
            let barLeft = left + labelColumn
            let detailLeft = right - detailColumn
            let figureRight = detailLeft - 14
            let barRight = figureRight - figureColumn - 12
            for (index, line) in lines.enumerated() {
                A2Dev.text(line.label, x: left, mid: y, width: labelColumn - 10, font: Self.body, color: A2.secondary)
                let bar = NSRect(x: barLeft, y: (y - Self.barHeight / 2).rounded(), width: max(40, barRight - barLeft), height: Self.barHeight)
                let radius = Self.barHeight / 2
                A2.track.setFill()
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
                if line.fraction > 0 {
                    line.color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(Self.barHeight, bar.width * CGFloat(min(1, line.fraction))),
                                                     height: bar.height), xRadius: radius, yRadius: radius).fill()
                }
                // Where even use would be by now: past it, the limit runs out early.
                if let pace = line.pace, pace > 0.01, pace < 0.99 {
                    let x = (bar.minX + bar.width * CGFloat(pace)).rounded()
                    A2.tertiary.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: bar.midY - 5, width: 1.5, height: 10), xRadius: 0.75, yRadius: 0.75).fill()
                }
                A2Dev.text(line.figure, x: figureRight - figureColumn, mid: y, width: figureColumn, font: Self.figureFont, color: A2.primary, right: true)
                let hover = hovered == index ? line.hover : nil
                let detail = PlanCard.fitted(hover ?? line.detail, room: right - detailLeft + 30, font: Self.body)
                A2Dev.text(detail, x: detailLeft - (hover == nil ? 0 : 30), mid: y, width: right - detailLeft + (hover == nil ? 0 : 30),
                           font: Self.body, color: hover != nil && line.warns ? A2.warn : A2.tertiary, right: true)
                y += PlanCard.pitch
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let first = PlanCard.firstLine + (note == nil ? 0 : PlanCard.pitch)
            let index = Int(((point.y - first + PlanCard.pitch / 2) / PlanCard.pitch).rounded(.down))
            hovered = lines.indices.contains(index) && lines[index].hover != nil ? index : nil
        }

        override func mouseExited(with event: NSEvent) { hovered = nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { hovered = nil }
        }
    }

    /// The account, after how old the figures are once they are a while old, so the
    /// age stays in view when a long account is cut short.
    /// "Updated 4m ago": when the tool last reported the figures.
    static func updated(_ usage: PlanUsage, now: Date) -> String {
        guard let updated = usage.updated else { return "" }
        let minutes = max(0, Int(now.timeIntervalSince(updated) / 60))
        // Fresh figures say nothing; Wisp checks every few minutes.
        if minutes < 10 { return "" }
        return "Updated " + (minutes < 60 ? "\(minutes)m" : (minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d")) + " ago"
    }

    /// A limit's meter colour. It steps from calm to amber to red as the window fills
    /// (amber early when the pace would use it up). The 5-hour session takes the light
    /// shade of each step and the week the deep one, so the two read apart by colour alone.
    static func meterColor(_ window: PlanUsage.Window, short: Bool) -> NSColor {
        let session = window.name.hasPrefix("5-hour")
        if window.used >= 0.9 { return session ? Self.sessionFull : A2.bad }
        if window.used >= 0.6 || short { return session ? Self.sessionHigh : A2.power }
        return session ? Self.sessionCalm : A2.cpu
    }

    private static let sessionCalm = Theme.dynamic(0x32ADE6, 0x64D2FF)
    private static let sessionHigh = Theme.dynamic(0xE0A800, 0xFFD60A)
    private static let sessionFull = Theme.dynamic(0xFF6B6B, 0xFF8A80)

    /// A window's detail in `room`: the first wording that fits, from the whole one down
    /// to the fewest words that still say it ("Runs out in 3h", "Tomorrow 9:40 AM").
    static func fitted(_ text: String, room: CGFloat, font: NSFont, kern: CGFloat = 0) -> String {
        var candidates = [text]
        func add(_ next: String) { if next != candidates.last { candidates.append(next) } }
        add(text.replacingOccurrences(of: "Not used since it reset", with: "Not used").replacingOccurrences(of: " at this rate", with: ""))
        // A reset's time alone, once "Resets" or "Used up" does not fit beside it.
        for prefix in ["Used up, resets ", "Resets "] where text.hasPrefix(prefix) && !text.hasPrefix("Resets in") {
            let time = String(text.dropFirst(prefix.count))
            add(time.prefix(1).uppercased() + time.dropFirst())
            add((time.prefix(1).uppercased() + time.dropFirst()).replacingOccurrences(of: " at ", with: " "))
        }
        return candidates.first { A2Dev.width($0, font, kern: kern) <= room } ?? candidates.last ?? text
    }

    /// What a limit's line says, and what it says while hovered. The line shows when
    /// the window resets; hovering shows how it is going: when the current pace would
    /// use it up first ("Runs out in 2h at this rate", `short`), or else the reset's
    /// clock time.
    static func pace(_ window: PlanUsage.Window, now: Date) -> (text: String, short: Bool, resets: String?) {
        let (text, short) = paceText(window, now: now)
        guard let resets = window.resets, resets > now else { return (text, short, nil) }
        let resetText = "Resets in " + Format.duration(resets.timeIntervalSince(now))
        let at = resetsAt(resets, now: now)
        if window.used >= 1 { return (resetText, true, "Used up, resets " + at) }
        if short { return (resetText, true, text) }
        return (text, false, "Resets " + at)
    }

    /// "at 3:40 PM" today, "tomorrow at 3:40 PM", or "Wed at 3:40 PM" later in the week.
    static func resetsAt(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = "at " + date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow " + time }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }

    private static func paceText(_ window: PlanUsage.Window, now: Date) -> (String, Bool) {
        guard let resets = window.resets else { return (window.used == 0 ? "Not started" : "", false) }
        let left = resets.timeIntervalSince(now)
        guard left > 0 else { return ("Resetting", false) }
        let length: Double = window.name.hasPrefix("5-hour") ? 5 * 3600 : window.name.hasSuffix("month") ? 30 * 86_400 : 7 * 86_400
        let elapsed = max(60, length - left)
        if window.used == 0, left > length - 120 { return ("Not started", false) }
        let resetText = "Resets in " + Format.duration(left)
        guard window.used > 0.02, window.used < 1 else { return (window.used >= 1 ? "Used up · " + resetText : resetText, window.used >= 1) }
        let runsOut = (1 - window.used) * elapsed / window.used
        if runsOut < left { return ("Runs out in \(Format.duration(runsOut)) at this rate", true) }
        return (resetText, false)
    }

    override func layout() {
        super.layout()
        face.frame = bounds
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: Self.figureBaseline, width: bounds.width / 2)
        let width = state.naturalWidth
        state.frame = NSRect(x: bounds.width - A2.padSide - width, y: Self.figureBaseline - 26, width: width, height: 22)
        let left = face.titleEnd + 12
        let right = bounds.width - A2.padSide
        meta.frame = NSRect(x: left, y: Face.titleMid - 12, width: max(0, right - left), height: 24)
    }
}

/// Coding agents: what is running and what it costs the Mac, plus, when the
/// owner turns it on, each AI plan's limits and the tokens used today.
@MainActor
final class AgentsPage: CardPage {
    override var pageTint: NSColor { PageID.agents.tint }
    private let (titleLine, caption): (TextLine, TextLine)
    private let tint = A2Dev.tint(.agents)
    private let running: A2Tile
    private let cpu: A2Tile
    private let memory: A2Tile
    private let tokens: A2Tile
    private let planOff = A2NoticeCard()
    private var planCards: [PlanCard] = []
    private var plans: [PlanUsage] = []
    private var plansAt = Date.distantPast
    private let listCard = CardView()
    private let list = A2Table()
    private let finder = AgentFinder()
    private var tokensAt = Date.distantPast
    private var tokensBusy = false
    private var findBusy = false
    private let onSelect: (Selection?) -> Void

    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) {
        let title = TextLine(Toolbar.title("Coding Agents"))
        (titleLine, caption) = (title, TextLine())
        self.onSelect = onSelect
        running = A2Tile("Agents running", symbol: "apple.terminal", tint: tint)
        cpu = A2Tile("CPU", symbol: PageID.cpu.symbol, tint: tint)
        memory = A2Tile("Memory", symbol: PageID.memory.symbol, tint: tint)
        tokens = A2Tile("Tokens today", symbol: "wand.and.stars", tint: tint)
        super.init(delegate: delegate)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var plansOn: Bool { delegate.settings.planUsage }
    override var toolbarHeading: (NSView, NSView)? { (titleLine, caption) }

    override func loadView() {
        super.loadView()
        for view in [running, cpu, memory, tokens, planOff, listCard] as [NSView] { canvas.addSubview(view) }
        listCard.addSubview(list)
        list.heading = ("Running", "")
        list.headerHeight = 22
        list.headerRule = false
        list.rowHeight = 56
        list.iconSize = 28
        list.meterColors = A2Dev.meter(.agents)
        list.columns = [.init(title: "", width: 96, kind: .bar), .init(title: "CPU", width: 54, right: true, bold: true),
                        .init(title: "Memory", width: 62, right: true)]
        list.emptyText = "No coding agents running. Wisp knows Claude Code, Codex, Cursor Agent, Gemini CLI, Aider, OpenCode and more"
        list.onSelect = { [weak self] id in if let pid = Int32(id) { self?.onSelect(.process(pid)) } }
        caption.text = Toolbar.subtitle("Looking for agents…")
        for tile in [running, cpu, memory, tokens] { tile.figure.show("–") }
        showPlanState()
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = grid([running, cpu, memory, tokens], top: margin, width: width, columns: 4, height: 110) + gap
        let offered = !plansOn
        planOff.isHidden = !offered
        if offered {
            planOff.frame = NSRect(x: margin, y: y, width: inner, height: A2NoticeCard.height)
            y = planOff.frame.maxY + gap
        }
        let visible = plansOn ? Array(planCards.prefix(plans.count)) : []
        if !visible.isEmpty {
            // Two to a row where they fit; each row is as tall as its taller card.
            let columns = inner >= 2 * 300 + gap ? 2 : 1
            for start in stride(from: 0, to: visible.count, by: columns) {
                let cards = Array(visible[start..<min(start + columns, visible.count)])
                let height = (start..<start + cards.count).map { PlanCard.height(windows: plans[$0].windows.count) }.max() ?? 0
                let cell = (inner - gap * CGFloat(cards.count - 1)) / CGFloat(cards.count)
                for (index, card) in cards.enumerated() {
                    card.frame = NSRect(x: margin + CGFloat(index) * (cell + gap), y: y, width: cell, height: height).integral
                }
                y += height + gap
            }
        }
        // The list runs to the window's bottom margin when its rows fit, as in the mockup.
        let natural = list.naturalHeight + A2.padTop * 2
        let room = scroll.contentSize.height - Self.topInset - margin - y
        let height = room >= natural && room <= natural * 1.4 ? room : natural
        listCard.frame = NSRect(x: margin, y: y, width: inner, height: height)
        list.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner - A2.padSide * 2, height: height - A2.padTop * 2)
        return listCard.frame.maxY + margin
    }

    override func update(table: ProcessTable) {
        if !findBusy {
            findBusy = true
            let finder = self.finder
            DispatchQueue.global(qos: .utility).async {
                let found = finder.find(table)
                DispatchQueue.main.async { [weak self] in
                    self?.findBusy = false
                    self?.show(found, table: table)
                }
            }
        }
        guard plansOn else { return }
        // The menu bar's feed reads the limits, at most once a minute; the page shows what
        // it has, and again each minute so the figures' ages move on.
        let feed = delegate.plans
        feed.refresh(maxAge: plansAt == .distantPast ? 0 : 60)
        if feed.plans != plans || Date().timeIntervalSince(plansAt) > 60 {
            plansAt = Date()
            show(feed.plans)
        }
        // The token count reads only what the session logs gained since last time.
        if Date().timeIntervalSince(tokensAt) > 30, !tokensBusy {
            tokensBusy = true
            DispatchQueue.global(qos: .utility).async {
                let total = TokenCounter.shared.today()
                DispatchQueue.main.async { [weak self] in
                    self?.tokensBusy = false
                    self?.tokensAt = Date()
                    self?.tokens.show(Self.tokenText(total))
                    self?.tokens.set(sub: "Claude Code, every account")
                }
            }
        }
    }

    /// "4.2M" as 4.2 with a quieter M.
    private static func tokenText(_ count: Int) -> String {
        let text = Format.count(count)
        guard let last = text.last, last.isLetter else { return text }
        return String(text.dropLast()) + " " + String(last)
    }

    private func show(_ found: [CodingAgent], table: ProcessTable) {
        let machine = delegate.settings.cpuOfMachine
        let processes = found.reduce(0) { $0 + $1.processes.count }
        running.figure.show("\(found.count)")
        let kinds = Dictionary(grouping: found, by: \.kind).sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
            .map { "\($0.value.count) \($0.key)" }
        running.set(sub: kinds.prefix(2).joined(separator: " · "))
        cpu.show(Style.appCPU(found.reduce(0) { $0 + $1.cpu }, machine: machine, coreCount: table.coreCount))
        if let busiest = found.max(by: { $0.cpu < $1.cpu }) {
            cpu.set(facts: [.init(label: "Most in", value: Self.folderName(busiest))])
        } else {
            cpu.set(sub: "")
        }
        memory.show(Format.memory(found.reduce(0) { $0 + $1.memory }))
        memory.set(sub: "\(processes) processes between them")
        caption.text = Toolbar.subtitle(found.isEmpty ? "Nothing running" : "\(found.count) running · \(processes) processes")
        list.heading = ("Running", found.isEmpty ? "" : "\(found.count)")
        let home = NSHomeDirectory()
        let now = Date()
        let peak = max(found.map(\.cpu).max() ?? 0, 0.0001)
        let appearance = view.effectiveAppearance
        let before = list.rows.count
        list.rows = found.sorted { $0.cpu > $1.cpu }.map { agent in
            var detail = agent.folder.flatMap { $0 == home ? nil : $0.replacingOccurrences(of: home, with: "~") } ?? ""
            if let start = agent.startDate { detail += (detail.isEmpty ? "" : " · ") + Format.duration(now.timeIntervalSince(start)) }
            detail += (detail.isEmpty ? "" : " · ") + "\(agent.processes.count) proc"
            let look = AgentLook.mark(agent.kind, size: 28, appearance: appearance)
            return A2Table.Row(id: "\(agent.pid)", icon: look.icon, glyph: look.glyph, glyphTint: look.tint,
                               name: agent.kind + (agent.host.map { $0 != agent.kind ? " in \($0)" : "" } ?? ""),
                               note: "\(agent.pid)", detail: detail,
                               cells: ["", Style.appCPU(agent.cpu, machine: machine, coreCount: table.coreCount), Format.memory(agent.memory)],
                               fraction: agent.cpu / peak)
        }
        if list.rows.count != before { relayout() }
    }

    private func show(_ result: [PlanUsage]) {
        plans = result
        while planCards.count < result.count {
            let card = PlanCard()
            canvas.addSubview(card)
            planCards.append(card)
        }
        let now = Date()
        for (index, card) in planCards.enumerated() {
            card.isHidden = index >= result.count
            if index < result.count { card.show(result[index], now: now) }
        }
        if result.isEmpty { caption.text = Toolbar.subtitle("No signed-in Claude Code, Codex or Antigravity account on this Mac") }
        showPlanState()
        relayout()
    }

    private func showPlanState() {
        if !plansOn {
            tokens.figure.show("Off")
            tokens.set(sub: "Turn on with plan limits")
            planOff.row.set(symbol: "gauge.with.needle", tint: tint, title: "Plan limits", detail: PlanLimitsSetup.offDetail,
                            button: "Show Limits") { [weak self] in self?.turnOnPlans() }
        }
    }

    private static func folderName(_ agent: CodingAgent) -> String {
        guard let folder = agent.folder, folder != NSHomeDirectory() else { return agent.kind }
        return (folder as NSString).lastPathComponent
    }

    private func turnOnPlans() {
        delegate.change { $0.planUsage = true }
        PlanLimitsSetup.apply(on: true)
        showPlanState()
        plansAt = .distantPast
        tokensAt = .distantPast
        tokens.figure.show("…")
        tokens.set(sub: "Counting")
        relayout()
    }
}

/// Plan limits need no setup: each agent's own program is asked. Turning them off puts
/// back any Claude Code status line that earlier versions of Wisp added themselves to.
@MainActor
enum PlanLimitsSetup {
    static let offDetail = "Asks Claude Code, Codex and Antigravity for each signed-in account's limits. No sign-ins read"
    static let detail = "Every few minutes Wisp asks Claude Code, Codex and the Antigravity CLI for each signed-in account's limits. They answer with their own sign-in, use no tokens and keep no conversation. Wisp reads no sign-in and sends nothing itself."

    static func apply(on: Bool) {
        if !on { DispatchQueue.global(qos: .utility).async { ClaudeStatusLine.disconnectAll() } }
    }
}
