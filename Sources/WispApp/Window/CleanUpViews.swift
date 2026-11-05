import AppKit
import WispCore

extension CleanTab {
    var symbol: String {
        switch self {
        case .junk: return "trash.fill"
        case .developer: return "hammer.fill"
        case .largeFiles: return "doc.fill"
        case .leftovers: return "tray.full.fill"
        case .uninstall: return "xmark.app.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// App and file icons for Clean Up rows, rasterised once at row size.
@MainActor
enum CleanIcons {
    private static var cache: [String: NSImage] = [:]
    static let size: CGFloat = 22

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

/// The rows of a Clean Up tab drawn in one view: group headings, then items with a
/// checkbox, icon, name, what it is, size and safety. Only the part on screen is drawn.
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
    }

    var rows: [Row] = [] {
        didSet {
            offsets = []
            var y: CGFloat = 0
            for (index, row) in rows.enumerated() {
                // A heading after items gets room above it.
                if row.kind == .heading, index > 0 { y += 10 }
                offsets.append(y)
                y += height(row)
            }
            total = y
            needsDisplay = true
        }
    }
    var onToggle: (([String], Bool) -> Void)?
    var onExclude: ((CleanItem) -> Void)?
    /// Set for a list of rows that open something (the Uninstall tab's apps) instead of ticking.
    var onOpen: ((Row) -> Void)? { didSet { needsDisplay = true } }
    private var offsets: [CGFloat] = []
    private var total: CGFloat = 0
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for index in [hovered, oldValue].compactMap({ $0 }) where rows.indices.contains(index) { setNeedsDisplay(frame(index)) }
        }
    }
    private var revealHovered = false

    static let itemHeight: CGFloat = 50
    static let headingHeight: CGFloat = 32
    var naturalHeight: CGFloat { total }

    private func height(_ row: Row) -> CGFloat { row.kind == .heading ? Self.headingHeight : Self.itemHeight }
    private func frame(_ index: Int) -> NSRect { NSRect(x: 0, y: offsets[index], width: bounds.width, height: height(rows[index])) }

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

    private var checkable: Bool { rows.contains { $0.check != nil } }
    private func opens(_ row: Row) -> Bool { onOpen != nil && row.kind == .item && row.check == nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let reveals = rows.contains { $0.item?.paths.isEmpty == false && $0.check != nil }
        let rightEdge = bounds.width - (reveals || rows.contains(where: opens) ? 34 : 0)
        let valueWidth: CGFloat = 132
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
                (row.title as NSString).draw(with: NSRect(x: x, y: frame.midY - 9, width: rightEdge - x - valueWidth, height: 18),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
                let attributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(12.5, .medium), .foregroundColor: Theme.inkSecondary]
                let size = (row.value as NSString).size(withAttributes: attributes)
                (row.value as NSString).draw(at: NSPoint(x: rightEdge - size.width, y: frame.midY - size.height / 2), withAttributes: attributes)
            case .item:
                let icon: NSImage? = row.item.map { CleanIcons.icon(for: $0) }
                    ?? row.symbol.map { IconTile.image($0, tint: PageID.cleanup.tint, size: CleanIcons.size, appearance: effectiveAppearance) }
                if let icon {
                    icon.draw(in: NSRect(x: x, y: frame.midY - CleanIcons.size / 2, width: CleanIcons.size, height: CleanIcons.size),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    x += CleanIcons.size + 12
                }
                let textWidth = max(40, rightEdge - x - valueWidth - 12)
                (row.title as NSString).draw(with: NSRect(x: x, y: frame.minY + 7, width: textWidth, height: 18),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
                (row.detail as NSString).draw(with: NSRect(x: x, y: frame.minY + 26, width: textWidth, height: 16),
                                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                              attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.inkSecondary, .paragraphStyle: paragraph])
                let valueAttributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink]
                let valueSize = (row.value as NSString).size(withAttributes: valueAttributes)
                (row.value as NSString).draw(at: NSPoint(x: rightEdge - valueSize.width, y: frame.minY + 7), withAttributes: valueAttributes)
                let labelAttributes: [NSAttributedString.Key: Any] = [.font: Theme.sans(11.5), .foregroundColor: row.labelWarns ? Theme.warn : Theme.inkSecondary]
                let labelSize = (row.label as NSString).size(withAttributes: labelAttributes)
                (row.label as NSString).draw(at: NSPoint(x: rightEdge - labelSize.width, y: frame.minY + 27), withAttributes: labelAttributes)
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
                    Theme.rule.setFill()
                    NSRect(x: x, y: frame.maxY - 0.5, width: bounds.width - x, height: 0.5).fill()
                }
            }
        }
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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityValue() -> Any? {
        rows.prefix(16).map { "\($0.title) \($0.value)" + ($0.check == .on ? " selected" : "") }.joined(separator: "; ")
    }
}

/// The bar under the list: how much is ticked and the two ways to clean. On the
/// Uninstall tab the safe button gives way to one that asks a running app to quit.
final class CleanFooter: CardView {
    let selection = TextLine()
    let safeButton: ActionButton
    let cleanButton: ActionButton
    let quitButton: ActionButton
    static let height: CGFloat = 56

    init(target: AnyObject, safe: Selector, clean: Selector, quit: Selector) {
        safeButton = ActionButton(title: "Clean Safe Items…", target: target, action: safe)
        safeButton.secondary = true
        cleanButton = ActionButton(title: "Clean Selected…", target: target, action: clean)
        quitButton = ActionButton(title: "Quit", target: target, action: quit)
        quitButton.secondary = true
        quitButton.isHidden = true
        super.init()
        for view in [selection, safeButton, quitButton, cleanButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(enabled button: ActionButton, _ on: Bool) {
        button.isEnabled = on
        button.alphaValue = on ? 1 : 0.4
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 16
        for button in [cleanButton, safeButton, quitButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right -= size.width + 10
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
        running = true
        cancelButton.isHidden = true
        goButton.isHidden = true
        summary.stringValue = "Working through \(done) of \(total)…"
        needsLayout = true
    }

    /// The outcome, with each item that stayed and why.
    func finish(_ report: CleanReport, permanent: Bool) {
        running = false
        let freed = Format.bytes(UInt64(report.bytesFreed))
        let moved = report.removed.count
        setTitle(moved == 0 ? "Nothing was removed" : permanent ? "Freed \(freed)" : "Moved \(freed) to the Trash")
        let left = report.notRemoved
        summary.stringValue = left.isEmpty
            ? "\(moved == 1 ? "1 item" : "\(moved) items") cleaned." + (permanent ? "" : " Empty the Trash in Finder to get the space back.")
            : "\(moved) cleaned, \(left.count) left in place:"
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

    @objc private func cancel() { onCancel?() }
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
        let listHeight = min(list.naturalHeight, max(CleanList.itemHeight, bounds.height - 96 - chrome))
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
