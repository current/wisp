import AppKit
import WispCore

extension CleanTab {
    var symbol: String {
        switch self {
        case .junk: return "trash"
        case .developer: return "hammer"
        case .largeFiles: return "doc"
        case .leftovers: return "tray.full"
        case .uninstall: return "xmark.app"
        case .history: return "clock.arrow.circlepath"
        }
    }
    /// Where a tab's scan looks, for the lines shown while it runs and when it finds nothing.
    var looksIn: String {
        switch self {
        case .junk: return "app caches, system junk, old installers and local snapshots"
        case .developer: return "build output, package caches, simulators and old worktrees"
        case .largeFiles: return "large and duplicate files in your folders"
        case .leftovers: return "what deleted apps left behind"
        case .uninstall: return "the apps on this Mac"
        case .history: return "past cleans"
        }
    }
}

/// App and file icons for Clean Up rows, rasterised once at row size.
@MainActor
enum CleanIcons {
    private static var cache: [String: NSImage] = [:]
    private static var folders: [String: Bool] = [:]
    static let size: CGFloat = 22

    /// A symbol on a tinted tile for what has no icon of its own: simulators, snapshots and
    /// plain folders. Nil for apps and files, which show their Finder icon.
    static func tile(for item: CleanItem) -> (symbol: String, tint: NSColor)? {
        switch item.removal {
        case .simulator, .simulatorRuntime: return ("iphone", A2.labelTint(.disk))
        case .localSnapshot: return ("clock.arrow.circlepath", A2.labelTint(.disk))
        case .brewCask, .trash: break
        }
        if let id = item.ownerBundleID, cache["app:" + id] != nil || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return nil }
        guard let path = item.paths.first else { return (item.tab.symbol, A2.cpu) }
        if folders[path] == nil {
            var isDirectory: ObjCBool = false
            if folders.count > 2000 { folders.removeAll() }
            folders[path] = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !NSWorkspace.shared.isFilePackage(atPath: path)
        }
        return folders[path] == true ? ("folder", A2.cpu) : nil
    }

    static func icon(for item: CleanItem) -> NSImage {
        switch item.removal {
        case .simulator, .simulatorRuntime: return symbol("iphone")
        case .localSnapshot: return symbol("clock.arrow.circlepath")
        case .brewCask, .trash: break
        }
        if let id = item.ownerBundleID {
            if let cached = cache["app:" + id] { return cached }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return store("app:" + id, NSWorkspace.shared.icon(forFile: url.path))
            }
        }
        guard let path = item.paths.first else { return symbol(item.tab.symbol) }
        if let cached = cache[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return symbol(item.tab.symbol) }
        return file(path)
    }

    /// The Finder icon of a file or app bundle.
    static func file(_ path: String) -> NSImage {
        cache[path] ?? store(path, NSWorkspace.shared.icon(forFile: path))
    }

    private static func symbol(_ name: String) -> NSImage {
        IconTile.image(name, tint: PageID.cleanup.tint, size: size, appearance: NSApp.effectiveAppearance)
    }

    /// One bitmap at row size: a full icon family can hold several megabytes of images.
    private static func store(_ key: String, _ full: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [2, 1] as [CGFloat] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * scale), pixelsHigh: Int(size * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            full.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        if cache.count > 600 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The rows of a Clean Up tab drawn in one view: group headings with their colour from
/// the bar above, then items with a checkbox, icon, name, what it is, a size bar, the size
/// and how safe it is. While a scan runs, placeholder rows follow what has come in. Only
/// the part on screen is drawn.
final class CleanList: BitmapView {
    enum Check { case off, on, mixed }

    struct Row {
        enum Kind { case heading, item }
        var kind: Kind
        var id: String
        var title: String
        var detail = ""
        var value = ""
        var label = ""
        var labelWarns = false
        /// Nil for rows without a checkbox (history, the review list).
        var check: Check?
        var item: CleanItem?
        var symbol: String?
        /// The items a heading's checkbox ticks.
        var ids: [String] = []
        /// The size bar's length against the largest row, and its colour; a heading's dot.
        var fraction: Double?
        var color: NSColor?
        /// A heading's quiet count after its name ("12 items").
        var count = ""
        /// The whole text when the row's lines are cut short, or more about it.
        var tip = ""
    }

    var rows: [Row] = [] { didSet { reflow() } }
    /// Placeholder rows after the real ones while more are on the way, under a quiet heading.
    var pending: (title: String, rows: Int)? {
        didSet { if pending?.title != oldValue?.title || pending?.rows != oldValue?.rows { reflow() } }
    }
    /// Items are 50 pt; a short list on a tall card spreads them a little, as in the mockup.
    var itemHeight: CGFloat = CleanList.baseItemHeight { didSet { if itemHeight != oldValue { reflow() } } }
    var onToggle: (([String], Bool) -> Void)?
    var onExclude: ((CleanItem) -> Void)?
    /// Set for a list of rows that open something (the Uninstall tab's apps) instead of ticking.
    var onOpen: ((Row) -> Void)? { didSet { needsDisplay = true } }
    fileprivate var offsets: [CGFloat] = []
    private var total: CGFloat = 0
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for index in [hovered, oldValue].compactMap({ $0 }) where rows.indices.contains(index) { setNeedsDisplay(frame(index)) }
        }
    }
    private var revealHovered = false

    static let baseItemHeight: CGFloat = 50
    static let headingHeight: CGFloat = 32
    private static let headingGap: CGFloat = 10
    private static let meterWidth: CGFloat = 112
    private static let labelFont = Theme.sans(11.5)
    var naturalHeight: CGFloat { total + pendingHeight }
    private var pendingHeight: CGFloat {
        guard let pending, pending.rows > 0 else { return 0 }
        return (rows.isEmpty ? 0 : Self.headingGap) + Self.headingHeight + CGFloat(pending.rows) * itemHeight
    }
    /// The size column: as wide as the widest safety line or date, so the bars line up.
    private var valueWidth: CGFloat = 96

    /// The height with 50 pt items, and how many items share any room beyond it.
    var baseHeight: CGFloat { total - CGFloat(itemCount) * (itemHeight - Self.baseItemHeight) }
    var itemCount: Int { rows.filter { $0.kind == .item }.count }

    private func reflow() {
        valueWidth = max(96, rows.map { A2.width($0.label, Self.labelFont) }.max() ?? 0)
        offsets = []
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            // A heading after items gets room above it.
            if row.kind == .heading, index > 0 { y += Self.headingGap }
            offsets.append(y)
            y += height(row)
        }
        total = y
        needsDisplay = true
    }

    private func height(_ row: Row) -> CGFloat { row.kind == .heading ? Self.headingHeight : itemHeight }
    fileprivate func frame(_ index: Int) -> NSRect { NSRect(x: 0, y: offsets[index], width: bounds.width, height: height(rows[index])) }

    private func index(at point: NSPoint) -> Int? {
        var low = 0, high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] <= point.y { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard rows.indices.contains(index), frame(index).contains(point) else { return nil }
        return index
    }

    private func revealRect(_ index: Int) -> NSRect {
        let frame = frame(index)
        return NSRect(x: frame.maxX - 26, y: frame.midY - 13, width: 26, height: 26)
    }

    /// Where a heading's row starts, for scrolling to it.
    func offset(of id: String) -> CGFloat? { rows.firstIndex { $0.id == id }.map { offsets[$0] } }

    private var checkable: Bool { rows.contains { $0.check != nil } || (rows.isEmpty && pending != nil) }
    fileprivate func opens(_ row: Row) -> Bool { onOpen != nil && row.kind == .item && row.check == nil }

    /// Where the size bars start, or nil when no row has one or the list is too narrow for them.
    private func meterX(rightEdge: CGFloat) -> CGFloat? {
        guard rows.contains(where: { $0.fraction != nil }) || pending != nil, bounds.width >= 520 else { return nil }
        return rightEdge - valueWidth - 20 - Self.meterWidth
    }

    private var rightEdge: CGFloat {
        let reveals = rows.contains { $0.item?.paths.isEmpty == false && $0.check != nil } || (rows.isEmpty && pending != nil)
        return bounds.width - (reveals || rows.contains(where: opens) ? 34 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPending(dirtyRect)
        guard !rows.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let reveals = rows.contains { $0.item?.paths.isEmpty == false && $0.check != nil }
        let rightEdge = rightEdge
        let valueWidth = valueWidth
        let meterX = meterX(rightEdge: rightEdge)
        let textRight = (meterX ?? rightEdge - valueWidth) - 16
        for index in rows.indices {
            let frame = frame(index)
            guard frame.maxY >= dirtyRect.minY else { continue }
            if frame.minY > dirtyRect.maxY { break }
            let row = rows[index]
            var x: CGFloat = 0
            if index == hovered, row.check != nil || opens(row) {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: -8, dy: row.kind == .heading ? 2 : 1), xRadius: 8, yRadius: 8).fill()
            }
            if let check = row.check {
                drawCheck(check, at: NSPoint(x: 0, y: frame.midY - 8))
                x = 28
            } else if checkable {
                x = 28
            }
            switch row.kind {
            case .heading:
                if let color = row.color {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x + 7, y: frame.midY - 4, width: 8, height: 8)).fill()
                    x += 22 + 12 - 7
                }
                let titleFont = Theme.sans(13, .semibold)
                let titleWidth = min(A2.width(row.title, titleFont), max(0, textRight - x))
                A2.drawTruncated(row.title, in: NSRect(x: x, y: frame.minY, width: titleWidth, height: frame.height), font: titleFont, color: A2.primary)
                if !row.count.isEmpty, x + titleWidth + 8 < textRight {
                    A2.drawTruncated(row.count, in: NSRect(x: x + titleWidth + 8, y: frame.minY, width: textRight - x - titleWidth - 8, height: frame.height),
                                     font: Theme.sans(12), color: A2.tertiary)
                }
                let attributes: [NSAttributedString.Key: Any] = [.font: Theme.digits(12.5, .semibold), .foregroundColor: A2.secondary]
                let size = (row.value as NSString).size(withAttributes: attributes)
                (row.value as NSString).draw(at: NSPoint(x: rightEdge - size.width, y: frame.midY - size.height / 2), withAttributes: attributes)
            case .item:
                let iconRect = NSRect(x: x, y: frame.midY - CleanIcons.size / 2, width: CleanIcons.size, height: CleanIcons.size)
                if let item = row.item, let tile = CleanIcons.tile(for: item) {
                    drawTile(tile.symbol, tint: tile.tint, in: iconRect)
                    x += CleanIcons.size + 12
                } else if let icon = row.item.map({ CleanIcons.icon(for: $0) }) {
                    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    x += CleanIcons.size + 12
                } else if let symbol = row.symbol {
                    drawTile(symbol, tint: A2.labelTint(.disk), in: iconRect)
                    x += CleanIcons.size + 12
                }
                // Two lines centred in the row: the name over what it is, the size over how safe it is.
                let titleFont = Theme.sans(13), detailFont = Theme.sans(11.5)
                let titleLine = titleFont.ascender - titleFont.descender, detailLine = detailFont.ascender - detailFont.descender
                let top = (frame.midY - (titleLine + 3 + detailLine) / 2).rounded()
                let detailTop = top + titleLine + 3
                let textWidth = max(40, textRight - x)
                (row.title as NSString).draw(with: NSRect(x: x, y: top, width: textWidth, height: ceil(titleLine)),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: [.font: titleFont, .foregroundColor: A2.primary, .paragraphStyle: paragraph])
                (row.detail as NSString).draw(with: NSRect(x: x, y: detailTop, width: textWidth, height: ceil(detailLine)),
                                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                              attributes: [.font: detailFont, .foregroundColor: A2.secondary, .paragraphStyle: paragraph])
                if let meterX, let fraction = row.fraction {
                    A2.meter(NSRect(x: meterX, y: frame.midY - 2.5, width: Self.meterWidth, height: 5), fraction: max(0.02, fraction),
                             color: row.color ?? A2.labelTint(.disk))
                }
                let valueFont = Theme.digits(13, .semibold)
                let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: A2.primary]
                let valueSize = (row.value as NSString).size(withAttributes: valueAttributes)
                (row.value as NSString).draw(at: NSPoint(x: rightEdge - valueSize.width, y: top + titleFont.ascender - valueFont.ascender),
                                             withAttributes: valueAttributes)
                let labelAttributes: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: row.labelWarns ? A2.warn : A2.secondary]
                let labelSize = (row.label as NSString).size(withAttributes: labelAttributes)
                (row.label as NSString).draw(at: NSPoint(x: rightEdge - labelSize.width, y: detailTop), withAttributes: labelAttributes)
                if opens(row) {
                    let rect = revealRect(index)
                    IconTile.glyph("chevron.right", tint: index == hovered ? Theme.inkSecondary : Theme.inkTertiary, size: 12, appearance: effectiveAppearance)
                        .draw(in: NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
                } else if reveals, row.item?.paths.isEmpty == false, row.check != nil {
                    let rect = revealRect(index)
                    if index == hovered, revealHovered {
                        Theme.ink.withAlphaComponent(0.07).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                    }
                    IconTile.glyph("magnifyingglass", tint: index == hovered ? Theme.inkSecondary : Theme.inkTertiary, size: 13, appearance: effectiveAppearance)
                        .draw(in: NSRect(x: rect.midX - 6.5, y: rect.midY - 6.5, width: 13, height: 13), from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
                }
                if index + 1 < rows.count, rows[index + 1].kind == .item {
                    A2.hairline.setFill()
                    NSRect(x: x, y: frame.maxY - 0.5, width: bounds.width - x, height: 0.5).fill()
                }
            }
        }
    }

    /// Grey rows in the item grammar, after the real ones, under a quiet heading that says what is still coming.
    private func drawPending(_ dirtyRect: NSRect) {
        guard let pending, pending.rows > 0 else { return }
        var y = total + (rows.isEmpty ? 0 : Self.headingGap)
        guard y + pendingHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { return }
        let rightEdge = rightEdge
        let meterX = meterX(rightEdge: rightEdge)
        let checks = checkable
        let x: CGFloat = checks ? 28 : 0
        A2.drawTruncated(pending.title, in: NSRect(x: x, y: y, width: max(0, rightEdge - x), height: Self.headingHeight),
                         font: Theme.sans(12.5, .medium), color: A2.secondary)
        y += Self.headingHeight
        for index in 0..<pending.rows {
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: itemHeight)
            y += itemHeight
            // Fainter as they go down, so the list reads as still filling in.
            let alpha = max(0.35, 1 - CGFloat(index) * 0.12)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            if checks {
                Ghost.fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: frame.midY - 8, width: 16, height: 16), xRadius: 4.5, yRadius: 4.5).fill()
            }
            Ghost.tile(NSRect(x: x, y: frame.midY - CleanIcons.size / 2, width: CleanIcons.size, height: CleanIcons.size))
            let textX = x + CleanIcons.size + 12
            Ghost.bar(NSRect(x: textX, y: frame.midY - 12, width: Ghost.width(index, base: 110, spread: 120), height: 10))
            Ghost.bar(NSRect(x: textX, y: frame.midY + 4, width: Ghost.width(index + 2, base: 180, spread: 160), height: 8))
            if let meterX { Ghost.bar(NSRect(x: meterX, y: frame.midY - 2.5, width: Self.meterWidth, height: 5)) }
            Ghost.bar(NSRect(x: rightEdge - 46, y: frame.midY - 12, width: 46, height: 10))
            Ghost.bar(NSRect(x: rightEdge - 64, y: frame.midY + 4, width: 64, height: 8))
            if index + 1 < pending.rows {
                A2.hairline.setFill()
                NSRect(x: x, y: frame.maxY - 0.5, width: bounds.width - x, height: 0.5).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A 22 pt tile in a wash of its colour with the symbol on it.
    private func drawTile(_ symbol: String, tint: NSColor, in rect: NSRect) {
        tint.withAlphaComponent(A2.drawingDark ? 0.2 : 0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        IconTile.glyph(symbol, tint: tint, size: 13, appearance: effectiveAppearance)
            .draw(in: NSRect(x: rect.midX - 6.5, y: rect.midY - 6.5, width: 13, height: 13), from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: nil)
    }

    private func drawCheck(_ check: Check, at origin: NSPoint) {
        let box = NSRect(x: origin.x, y: origin.y, width: 16, height: 16)
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        if check == .off {
            Theme.card.setFill()
            shape.fill()
            Theme.cardBorderHover.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return
        }
        Theme.accent.setFill()
        shape.fill()
        IconTile.glyph(check == .on ? "checkmark" : "minus", tint: .white, size: 12, appearance: effectiveAppearance)
            .draw(in: box.insetBy(dx: 2, dy: 2), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = index(at: point)
        let overReveal = index.map { revealRect($0).contains(point) } ?? false
        if overReveal != revealHovered, let index {
            revealHovered = overReveal
            setNeedsDisplay(frame(index))
        }
        if index != hovered { toolTip = index.map { tip(rows[$0]) } ?? nil }
        hovered = index
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        let row = rows[index]
        if opens(row) {
            onOpen?(row)
            return
        }
        guard let check = row.check else { return }
        if row.kind == .item, let item = row.item, !item.paths.isEmpty, revealRect(index).contains(point) {
            return reveal(item)
        }
        onToggle?(row.kind == .heading ? row.ids : [row.id], check != .on)
    }

    /// The row's whole text, and where it is on disk.
    private func tip(_ row: Row) -> String? {
        guard row.kind == .item else { return nil }
        if !row.tip.isEmpty { return row.tip }
        let paths = row.item?.paths ?? []
        let place = paths.isEmpty ? "" : "\n" + paths.prefix(3).map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n")
            + (paths.count > 3 ? "\nand \(paths.count - 3) more" : "")
        return [row.title, row.detail].filter { !$0.isEmpty }.joined(separator: "\n") + place
    }

    private func reveal(_ item: CleanItem) {
        let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }.prefix(20).map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), let item = rows[index].item, !item.paths.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionItem("Reveal in Finder") { [weak self] in self?.reveal(item) })
        menu.addItem(ActionItem(item.paths.count == 1 ? "Copy Path" : "Copy Paths") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.paths.joined(separator: "\n"), forType: .string)
        })
        if rows[index].check != nil, onExclude != nil {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Exclude from Scans") { [weak self] in self?.onExclude?(item) })
        }
        return menu
    }

    // MARK: Accessibility

    // The rows are drawn in one view; each is an element here so VoiceOver can tick it,
    // open it and reach what the context menu and the hover offer.
    private final class Element: NSAccessibilityElement {
        weak var owner: CleanList?
        var index = 0
        override func accessibilityPerformPress() -> Bool {
            guard let owner, owner.rows.indices.contains(index) else { return false }
            let row = owner.rows[index]
            if owner.opens(row) {
                owner.onOpen?(row)
                return true
            }
            guard let check = row.check, let onToggle = owner.onToggle else { return false }
            onToggle(row.kind == .heading ? row.ids : [row.id], check != .on)
            return true
        }
        override func accessibilityFrameInParentSpace() -> NSRect {
            guard let owner, owner.rows.indices.contains(index), owner.offsets.indices.contains(index) else { return .zero }
            let rect = owner.frame(index)
            return NSRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }
    private var elementCache: [String: Element] = [:]

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityValue() -> Any? {
        if rows.isEmpty { return pending.map { $0.title } }
        return rows.count == 1 ? "1 row" : "\(rows.count) rows"
    }
    override func accessibilityChildren() -> [Any]? {
        var used: [String: Element] = [:]
        let elements = rows.enumerated().map { index, row -> Element in
            let key = (row.kind == .heading ? "heading " : "item ") + row.id
            let element = elementCache[key] ?? {
                let element = Element()
                element.owner = self
                element.setAccessibilityParent(self)
                return element
            }()
            used[key] = element
            element.index = index
            if let check = row.check {
                element.setAccessibilityRole(.checkBox)
                element.setAccessibilityValue(NSNumber(value: check == .on ? 1 : check == .mixed ? 2 : 0))
            } else {
                element.setAccessibilityRole(opens(row) ? .button : .staticText)
                element.setAccessibilityValue(nil)
            }
            let words = [row.count, row.detail, row.value, row.label].filter { !$0.isEmpty }
            element.setAccessibilityLabel(([row.title] + words).joined(separator: ", "))
            element.setAccessibilityHelp(tip(row))
            var actions: [NSAccessibilityCustomAction] = []
            if let item = row.item, !item.paths.isEmpty {
                actions.append(NSAccessibilityCustomAction(name: "Reveal in Finder") { [weak self] in self?.reveal(item); return true })
                if row.check != nil, let onExclude {
                    actions.append(NSAccessibilityCustomAction(name: "Exclude from Scans") { onExclude(item); return true })
                }
            }
            element.setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
            return element
        }
        elementCache = used
        return elements
    }
}

/// The bar under the list: how much is ticked and the two ways to clean. On the
/// Uninstall tab the safe button gives way to one that asks a running app to quit.
final class CleanFooter: CardView {
    let selection = TextLine()
    let safeButton = A2Button("Clean Safe Items…")
    let cleanButton = A2Button("Clean Selected…", primary: true)
    let quitButton = A2Button("Quit")
    static let height: CGFloat = 56

    override init() {
        super.init()
        quitButton.isHidden = true
        for view in [selection, safeButton, quitButton, cleanButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var right = bounds.width - 13
        for button in [cleanButton, safeButton, quitButton] where !button.isHidden {
            let width = button.naturalWidth
            button.frame = NSRect(x: right - width, y: ((bounds.height - 30) / 2).rounded(), width: width, height: 30)
            right -= width + 10
        }
        selection.frame = NSRect(x: 20, y: (bounds.height - 18) / 2, width: max(0, right - 26), height: 18)
    }
}

/// The review before a clean: a card over the page listing what will go, the permanent
/// ones apart and in warning colour. It stays up while the clean runs and shows the result.
@MainActor
final class CleanReview: NSView {
    private let dim = NSView()
    private let card = CardView()
    private let title = TextLine(), summary = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let list = CleanList()
    private let cancelButton: ActionButton
    private let goButton: ActionButton
    private var running = false
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    /// Stop while a clean runs: what is already gone stays gone, nothing further goes.
    var onStop: (() -> Void)?
    private var stopping = false

    init(items: [CleanItem]) {
        cancelButton = ActionButton(title: "Cancel", target: nil, action: nil)
        goButton = ActionButton(title: "Move to Trash", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        dim.wantsLayer = true
        addSubview(dim)
        addSubview(card)
        cancelButton.secondary = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        goButton.target = self
        goButton.action = #selector(confirm)
        summary.font = Theme.sans(12.5)
        summary.textColor = Theme.inkSecondary
        summary.isSelectable = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        list.drawsVisibleOnly = true
        for view in [title, summary, scroll, cancelButton, goButton] as [NSView] { card.addSubview(view) }
        show(items)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func show(_ items: [CleanItem]) {
        let trash = items.filter { !$0.removal.isPermanent }
        let permanent = items.filter(\.removal.isPermanent)
        let bytes = Format.bytes(UInt64(items.totalBytes))
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        if permanent.isEmpty {
            setTitle("Move \(count) to the Trash?")
            summary.stringValue = items.count == 1
                ? "\(bytes). You can put it back from the Trash until you empty it. Wisp checks it again first and leaves it alone if it is in use."
                : "\(bytes). You can put them back from the Trash until you empty it. Wisp checks each one again first and leaves alone anything in use."
            goButton.title = "Move to Trash"
        } else {
            setTitle(trash.isEmpty ? "Remove \(count) for good?" : "Clean \(count)?")
            summary.stringValue = "\(bytes). " + (trash.isEmpty ? "" : "\(trash.count) go to the Trash. ")
                + (permanent.count == 1 ? "1 is removed for good by its own tool and cannot be put back."
                                        : "\(permanent.count) are removed for good by their own tools and cannot be put back.")
            goButton.title = trash.isEmpty ? "Remove" : "Clean"
        }
        var rows: [CleanList.Row] = []
        if !trash.isEmpty {
            if !permanent.isEmpty { rows.append(.init(kind: .heading, id: "#trash", title: "To the Trash", value: Format.bytes(UInt64(trash.totalBytes)))) }
            rows += trash.map(Self.row)
        }
        if !permanent.isEmpty {
            rows.append(.init(kind: .heading, id: "#permanent", title: "Removed for good", value: Format.bytes(UInt64(permanent.totalBytes))))
            rows += permanent.map(Self.row)
        }
        list.rows = rows
        needsLayout = true
    }

    private static func row(_ item: CleanItem) -> CleanList.Row {
        CleanList.Row(kind: .item, id: item.id, title: item.name, detail: item.detail, value: Format.bytes(UInt64(item.bytes)),
                      label: item.safetyLabel, labelWarns: item.removal.isPermanent, item: item)
    }

    private func setTitle(_ text: String) {
        title.text = NSAttributedString(string: text, attributes: [.font: Theme.sans(15, .semibold), .foregroundColor: Theme.ink])
    }

    /// The selection cannot be cleaned as it is (every copy of a file is ticked): say why, offer only a way back.
    func block(_ reason: String) {
        setTitle("Nothing can go as ticked")
        summary.stringValue = reason + "."
        goButton.isHidden = true
        cancelButton.title = "Back"
        cancelButton.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// While the clean runs: the buttons go and a line says how far it is.
    func progress(done: Int, of total: Int) {
        let first = !running
        running = true
        goButton.isHidden = true
        cancelButton.isHidden = false
        cancelButton.isEnabled = !stopping
        if first || stopping {
            cancelButton.title = stopping ? "Stopping…" : "Stop"
            cancelButton.invalidateIntrinsicContentSize()
        }
        summary.stringValue = stopping ? "Stopping after the item in hand…" : "Working through \(done) of \(total)…"
        needsLayout = true
    }

    /// The outcome, with each item that stayed and why.
    func finish(_ report: CleanReport) {
        running = false
        stopping = false
        cancelButton.isEnabled = true
        let freed = Format.bytes(UInt64(report.bytesFreed))
        let moved = report.removed.count
        // A clean can mix both: some items gone for good, some only in the Trash until it is emptied.
        let trashed = report.removed.contains { !$0.item.removal.isPermanent }
        let gone = report.removed.contains { $0.item.removal.isPermanent }
        setTitle(moved == 0 ? "Nothing was removed" : trashed && !gone ? "Moved \(freed) to the Trash" : "Freed \(freed)")
        let trashNote = trashed ? " Empty the Trash in Finder to get the space back." : ""
        let left = report.notRemoved
        summary.stringValue = left.isEmpty
            ? "\(moved == 1 ? "1 item" : "\(moved) items") cleaned." + trashNote
            : "\(moved) cleaned, \(left.count) left in place." + trashNote
        list.rows = left.map { result in
            CleanList.Row(kind: .item, id: result.item.id, title: result.item.name, detail: result.outcome.summary,
                          value: Format.bytes(UInt64(result.item.bytes)), item: result.item)
        }
        cancelButton.isHidden = true
        goButton.isHidden = false
        goButton.title = "Done"
        goButton.invalidateIntrinsicContentSize()
        goButton.action = #selector(cancel)
        needsLayout = true
    }

    @objc private func cancel() {
        guard running else {
            onCancel?()
            return
        }
        guard !stopping else { return }
        stopping = true
        onStop?()
        cancelButton.title = "Stopping…"
        cancelButton.isEnabled = false
        cancelButton.invalidateIntrinsicContentSize()
        summary.stringValue = "Stopping after the item in hand…"
        needsLayout = true
    }
    @objc private func confirm() { onConfirm?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: if !running { onCancel?() }
        case 36, 76: if !goButton.isHidden { goButton.performClick(nil) }
        default: super.keyDown(with: event)
        }
    }

    // The page underneath takes no clicks while this is up.
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.16).cgColor
        }
        let width = min(560, bounds.width - 48)
        let inner = width - 48
        summary.preferredMaxLayoutWidth = inner
        let summaryHeight = ceil(summary.sizeThatFits(NSSize(width: inner, height: 200)).height)
        let chrome: CGFloat = 24 + 22 + 8 + summaryHeight + 16 + 16 + 30 + 24
        let listHeight = min(list.naturalHeight, max(CleanList.baseItemHeight, bounds.height - 96 - chrome))
        let height = chrome + listHeight
        card.frame = NSRect(x: (bounds.width - width) / 2, y: max(24, (bounds.height - height) / 2), width: width, height: height).integral
        title.frame = NSRect(x: 24, y: 24, width: inner, height: 22)
        summary.frame = NSRect(x: 22, y: 54, width: inner, height: summaryHeight)
        scroll.frame = NSRect(x: 24, y: 54 + summaryHeight + 16, width: inner, height: listHeight)
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(list.naturalHeight, 1))
        let go = goButton.intrinsicContentSize, cancel = cancelButton.intrinsicContentSize
        goButton.frame = NSRect(x: width - 24 - go.width, y: height - 24 - go.height, width: go.width, height: go.height)
        cancelButton.frame = NSRect(x: goButton.frame.minX - 10 - cancel.width, y: goButton.frame.midY - cancel.height / 2,
                                    width: cancel.width, height: cancel.height)
    }
}
