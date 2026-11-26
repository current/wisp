import AppKit
import WispCore

/// Shows What's New once after an update, and again whenever it is asked for.
@MainActor
final class WhatsNewPresenter {
    private unowned let delegate: AppDelegate
    private var controller: WhatsNewController?
    /// Waiting for a full screen app to leave the front before showing on its own.
    private var waiting: [NSObjectProtocol] = []
    private var pending: (() -> Void)?

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    /// At launch. `earlierTraces` is read before this launch wrote anything.
    func launched(earlierTraces: Bool) {
        let environment = ProcessInfo.processInfo.environment
        // WISP_WHATS_NEW=<from> opens the window as if updating from that version, for
        // screenshots. <from>..<to> also pretends to run <to>. Nothing is remembered.
        if let hook = environment["WISP_WHATS_NEW"] {
            let parts = hook.components(separatedBy: "..")
            let running = parts.count > 1 ? parts[1] : Wisp.version
            let versions = UpdateNotes.between(parts[0], running, WhatsNew.versions)
            return show(versions.isEmpty ? [WhatsNew.current?.version].compactMap { $0 } : versions, from: parts[0], automatic: false)
        }
        // Screenshot, audit and benchmark copies share the owner's settings: they neither show it nor use it up.
        guard !Wisp.readOnly, !MainWindowController.background else { return }
        let stored = delegate.settings.lastVersion.isEmpty ? nil : delegate.settings.lastVersion
        let remember = UpdateNotes.remembered(stored: stored, running: Wisp.version)
        switch UpdateNotes.decide(stored: stored, earlierTraces: earlierTraces, running: Wisp.version, notes: WhatsNew.versions) {
        case .firstInstall, .nothingNew:
            delegate.change { $0.lastVersion = remember }
        case .show(let from, let versions):
            // Remembered as it shows, so a launch that quits first still shows it next time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.whenNoFullScreenAppIsInFront {
                    guard let self else { return }
                    self.delegate.change { $0.lastVersion = remember }
                    self.show(versions, from: from, automatic: true)
                }
            }
        }
    }

    /// From the menus and Settings: this version's notes.
    func showCurrent() {
        guard let current = WhatsNew.current else { return }
        show([current.version], from: nil, automatic: false)
    }

    private func show(_ versions: [String], from: String?, automatic: Bool) {
        let notes = versions.compactMap(WhatsNew.notes)
        guard !notes.isEmpty else { return }
        controller?.close()
        let controller = WhatsNewController(notes: notes, from: from, delegate: delegate)
        controller.onClose = { [weak self, weak controller] in
            if self?.controller === controller { self?.controller = nil }
        }
        self.controller = controller
        controller.present()
    }

    // MARK: Full screen

    /// Showing a window on its own while a full screen app is in front would take the
    /// person out of that app's space, so it waits until they leave it.
    private func whenNoFullScreenAppIsInFront(_ body: @escaping () -> Void) {
        guard Self.fullScreenAppIsInFront() else { return body() }
        pending = body
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            waiting.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The space finishes sliding before the new front app's windows report their place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.retry() }
            })
        }
    }

    private func retry() {
        guard let body = pending, !Self.fullScreenAppIsInFront() else { return }
        pending = nil
        waiting.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        waiting = []
        body()
    }

    /// The front app has a window covering a whole display, menu bar included, which is
    /// what a full screen app's space looks like. Window bounds need no permission.
    static func fullScreenAppIsInFront() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let displays = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
            .map(CGDisplayBounds)
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            return displays.contains(bounds)
        }
    }
}

/// A plain window that closes with Escape and Command-W, and in background runs lives
/// off every screen like the main window does.
final class WhatsNewWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        MainWindowController.background ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        // Escape, should no view in the window turn it into cancelOperation first.
        if event.keyCode == 53 { return close() }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window has no close button to press, so Command-W closes it here rather than through the menu.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class WhatsNewController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let content: WhatsNewView

    static let width: CGFloat = 800
    /// macOS 26 rounds a window without a toolbar this much.
    static let cornerRadius: CGFloat = 16

    init(notes: [WhatsNew.Notes], from: String?, delegate: AppDelegate) {
        content = WhatsNewView(notes: notes, from: from, delegate: delegate)
        let window = WhatsNewWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "What's New in Wisp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Wisp's icon sits where the window buttons would; Done, Escape and Command-W close it.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = SoftDropdown.Look.panel
        // Opens on the space in use, over a full screen app when asked for there, instead of switching spaces.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        content.onDone = { [weak self] in self?.close() }
        window.initialFirstResponder = content.doneButton
        fit()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// As tall as the notes, up to most of the screen; longer notes scroll.
    private func fit() {
        guard let window else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        var height = min(content.idealHeight(width: Self.width), max(420, min(820, screen - 100)))
        // WISP_SIZE=640x1300 sets the height in background runs, so a picture can show every version.
        if MainWindowController.background,
           let size = ProcessInfo.processInfo.environment["WISP_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            height = size[1]
        }
        window.setContentSize(NSSize(width: Self.width, height: height.rounded()))
    }

    func present() {
        guard let window else { return }
        if MainWindowController.background {
            let screens = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: screens.maxX + 4000, y: screens.minY))
            window.orderBack(nil)
        } else {
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // An accessory app is not always allowed to activate; make sure the window is seen anyway.
            window.orderFrontRegardless()
        }
        snapshotIfAsked()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: Snapshots

    /// WISP_SNAPSHOT=<file.png> with WISP_WHATS_NEW and no main window: a picture of this
    /// window after WISP_SNAPSHOT_DELAY seconds, then Wisp quits.
    private func snapshotIfAsked() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WISP_WHATS_NEW"] != nil, environment["WISP_OPEN"] != "window", let path = environment["WISP_SNAPSHOT"] else { return }
        let delay = environment["WISP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.writeSnapshot(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Drawn from the window's layers as `MainWindowController.writeSnapshot` does, so a
    /// window kept off the screen can be looked at.
    private func writeSnapshot(to url: URL) {
        guard let window, let frameView = window.contentView?.superview, let layer = frameView.layer else { return }
        frameView.layoutSubtreeIfNeeded()
        let scale = max(2, window.backingScaleFactor)
        let size = frameView.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        let outline = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        context.addPath(outline)
        context.clip()
        frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(SoftDropdown.Look.panel.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            layer.render(in: context)
        }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25),
                               cornerWidth: Self.cornerRadius - 0.25, cornerHeight: Self.cornerRadius - 0.25, transform: nil))
        context.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.2 : 0.14))
        context.setLineWidth(0.5)
        context.strokePath()
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The window's content, in the dropdowns' design: Wisp's icon with the title and what
/// the version is about, one plate per version (the measured gains large, then a card
/// per change), and a footer with a hint, the release notes and Done.
@MainActor
final class WhatsNewView: DrawnView {
    typealias Look = SoftDropdown.Look

    var onDone: (() -> Void)?
    let doneButton: ActionButton
    private let notes: [WhatsNew.Notes]
    private let head = SoftDropdown.Head()
    private let scroll = NSScrollView()
    private let document = DrawnView()
    private var sections: [WhatsNewSection] = []
    private let hint = TextLine()
    private lazy var link = SoftDropdown.LinkButton(title: "Full release notes", target: self, action: #selector(openReleaseNotes))

    static let headHeight: CGFloat = 76
    static let footerHeight: CGFloat = 58
    static let sectionGap: CGFloat = 12

    init(notes: [WhatsNew.Notes], from: String?, delegate: AppDelegate) {
        self.notes = notes
        doneButton = ActionButton(title: "Done", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: WhatsNewController.width, height: 600))
        head.title = "What's new in Wisp \(UpdateNotes.shortName(notes[0].version))"
        head.status = Self.status(notes: notes, from: from)
        link.toolTip = WhatsNew.releasePage(notes[0].version).absoluteString
        link.setAccessibilityHelp("Opens the release on GitHub.")
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.font = Look.strong
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityLabel("Done")
        // The figures need their caveat more than the window needs a way back to itself.
        let note = notes.first { $0.measured != nil }?.measured ?? "Find this again in Settings, About."
        hint.text = NSAttributedString(string: note, attributes: [.font: Look.body, .foregroundColor: Look.secondary])
        hint.setAccessibilityElement(true)
        hint.setAccessibilityRole(.staticText)
        hint.setAccessibilityValue(note)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        sections = notes.map { WhatsNewSection(notes: $0, delegate: delegate) }
        sections.forEach(document.addSubview)
        for view in [scroll, head, hint, link, doneButton] as [NSView] { addSubview(view) }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func status(notes: [WhatsNew.Notes], from: String?) -> SoftDropdown.Head.Status {
        let summary = notes[0].summary
        guard let from, notes.count > 1 else { return .init(dot: Theme.accent, lines: [summary]) }
        // Skipped versions: say the older ones are here too, without a paragraph.
        let older = notes.dropFirst().map { UpdateNotes.shortName($0.version) }.reversed().joined(separator: ", ")
        return .init(dot: Theme.accent, lines: ["\(summary) · \(older) below, since you had \(UpdateNotes.shortName(from))",
                                                "\(summary) · \(older) below", summary])
    }

    @objc private func scrolled() { needsDisplay = true }

    /// A hairline where cards pass under the head or the footer, so notes longer than
    /// the window read as more to scroll rather than as the end.
    override func draw(_ dirtyRect: NSRect) {
        let visible = scroll.contentView.bounds
        A2.hairline.setFill()
        if visible.minY > 1 { NSRect(x: 0, y: scroll.frame.minY - 0.5, width: bounds.width, height: 0.5).fill() }
        if visible.maxY < document.frame.height - 1 { NSRect(x: 0, y: scroll.frame.maxY, width: bounds.width, height: 0.5).fill() }
    }

    func idealHeight(width: CGFloat) -> CGFloat {
        Self.headHeight + documentHeight(width: width) + Self.footerHeight
    }

    private func documentHeight(width: CGFloat) -> CGFloat {
        sections.map { $0.height(width: width) }.reduce(0, +) + CGFloat(max(0, sections.count - 1)) * Self.sectionGap
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        head.frame = NSRect(x: 0, y: 0, width: width, height: Self.headHeight)
        head.textRight = width - 20
        let body = NSRect(x: 0, y: Self.headHeight, width: width, height: max(0, bounds.height - Self.headHeight - Self.footerHeight))
        scroll.frame = body
        var y: CGFloat = 0
        for section in sections {
            let height = section.height(width: width)
            section.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + Self.sectionGap
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(body.height, documentHeight(width: width)))
        needsDisplay = true

        let mid = body.maxY + Self.footerHeight / 2 - SoftDropdown.footerLift
        let done = doneButton.intrinsicContentSize
        let doneWidth = max(76, done.width)
        doneButton.frame = NSRect(x: width - 20 - doneWidth, y: (mid - done.height / 2).rounded(), width: doneWidth, height: done.height)
        let linkSize = link.intrinsicContentSize
        link.frame = NSRect(x: doneButton.frame.minX - 18 - linkSize.width, y: (mid - linkSize.height / 2).rounded(),
                            width: linkSize.width, height: linkSize.height)
        let left = SoftDropdown.sectionX + 8
        hint.frame = NSRect(x: left, y: (mid - 9).rounded(), width: max(0, link.frame.minX - 12 - left), height: 18)
    }

    @objc private func done() { onDone?() }

    @objc private func openReleaseNotes() {
        NSWorkspace.shared.open(WhatsNew.releasePage(notes[0].version))
    }
}

/// One version's plate: its name and how many changes, the measured gains two by two,
/// then a compact card per change in two columns.
@MainActor
final class WhatsNewSection: DrawnView {
    private let plate = SoftDropdown.Plate()
    private let headlines: [WhatsNewHeadlineCard]
    private let cards: [WhatsNewCard]

    static let columnGap: CGFloat = SoftDropdown.cardGap

    init(notes: WhatsNew.Notes, delegate: AppDelegate) {
        let labels = (old: UpdateNotes.shortName(notes.baseline), new: UpdateNotes.shortName(notes.version))
        headlines = notes.headlines.map { WhatsNewHeadlineCard(headline: $0, labels: labels) }
        // One figure column for every gain, so the bars end together across the cards.
        let column = headlines.map(\.figureNeed).max() ?? 0
        headlines.forEach { $0.figureColumn = column }
        cards = notes.entries.map { entry in
            WhatsNewCard(entry: entry) { [unowned delegate] page in delegate.showPage(page) }
        }
        super.init(frame: .zero)
        plate.title = "Wisp " + UpdateNotes.shortName(notes.version)
        plate.count = notes.entries.count == 1 ? "1 change" : "\(notes.entries.count) changes"
        addSubview(plate)
        headlines.forEach(addSubview)
        cards.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(plate.title), \(plate.count)")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func inner(_ width: CGFloat) -> CGFloat { width - SoftDropdown.sectionX * 2 - SoftDropdown.inset * 2 }

    /// Each card's frame, from the top of the first; the last of an odd count spans both columns.
    private func frames(_ count: Int, height: CGFloat, width: CGFloat, top: CGFloat) -> [NSRect] {
        let x = SoftDropdown.sectionX + SoftDropdown.inset
        let half = ((width - Self.columnGap) / 2).rounded(.down)
        return (0..<count).map { index in
            let row = CGFloat(index / 2), right = index % 2 == 1
            let spans = index == count - 1 && count % 2 == 1
            return NSRect(x: right ? x + width - half : x, y: top + row * (height + SoftDropdown.cardGap),
                          width: spans ? width : half, height: height)
        }
    }

    private func blockHeight(_ count: Int, _ height: CGFloat) -> CGFloat {
        let rows = CGFloat((count + 1) / 2)
        return rows == 0 ? 0 : rows * height + (rows - 1) * SoftDropdown.cardGap
    }

    func height(width: CGFloat) -> CGFloat {
        let heroes = blockHeight(headlines.count, WhatsNewHeadlineCard.height)
        let gap = headlines.isEmpty || cards.isEmpty ? 0 : SoftDropdown.cardGap
        return SoftDropdown.sectionTitle + heroes + gap + blockHeight(cards.count, WhatsNewCard.height) + SoftDropdown.bottomInset
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        plate.frame = bounds
        plate.section = NSRect(x: SoftDropdown.sectionX, y: 0, width: width - SoftDropdown.sectionX * 2, height: height(width: width))
        var top = SoftDropdown.sectionTitle
        for (card, frame) in zip(headlines, frames(headlines.count, height: WhatsNewHeadlineCard.height, width: inner(width), top: top)) {
            card.frame = frame
        }
        if !headlines.isEmpty { top += blockHeight(headlines.count, WhatsNewHeadlineCard.height) + SoftDropdown.cardGap }
        for (card, frame) in zip(cards, frames(cards.count, height: WhatsNewCard.height, width: inner(width), top: top)) {
            card.frame = frame
        }
    }
}

/// A soft dropdown card's plate and shadow, for the window's own cards.
@MainActor
class WhatsNewCardBase: BitmapView {
    typealias Look = SoftDropdown.Look

    var fill: NSColor { Look.card }

    override func layout() {
        super.layout()
        applyShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShadow()
    }

    /// On the layer, outside the bitmap, as a soft dropdown's cards have it.
    private func applyShadow() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.shadowColor = Look.cardShadow.cgColor
        }
        layer.shadowOpacity = 1
        layer.shadowRadius = 1.8
        layer.shadowOffset = CGSize(width: 0, height: 1.4)
        layer.shadowPath = CGPath.continuous(bounds, radius: SoftDropdown.cardRadius)
    }

    func drawPlate() {
        Look.thin()
        let radius = SoftDropdown.cardRadius
        fill.setFill()
        Look.rounded(bounds, radius: radius).fill()
        Look.cardLine.setStroke()
        Look.rounded(bounds.insetBy(dx: 0.25, dy: 0.25), radius: radius - 0.25).stroke(width: 0.5)
    }
}

/// One measured gain: a tile and a title with where it was measured, the gain as the
/// card's big figure, then the old and the new reading as bars on one scale, the old
/// long and quiet, the new in the card's tint.
@MainActor
final class WhatsNewHeadlineCard: WhatsNewCardBase {
    private let headline: WhatsNew.Headline
    /// The two rows' labels: the version measured against and this one.
    private let labels: (old: String, new: String)
    /// Set by the section to the widest figure of all its gains.
    var figureColumn: CGFloat = 0 { didSet { if figureColumn != oldValue { needsDisplay = true } } }
    var figureNeed: CGFloat {
        ceil(max(Look.width(headline.beforeText, Self.figureFont), Look.width(headline.afterText, Self.figureFont)))
    }

    static let height: CGFloat = 146
    static let padX: CGFloat = 16
    static let titleMid: CGFloat = 25
    static let gainBaseline: CGFloat = 80
    static let firstBar: CGFloat = 104
    static let pitch: CGFloat = 22
    static let barHeight: CGFloat = 12
    static let figureFont = Theme.figure(15, .semibold)
    /// The neutral fill of the old reading's bar, a step stronger than an empty track.
    static let oldFill = A2.dynamic(NSColor(white: 0, alpha: 0.16), NSColor(white: 1, alpha: 0.2))

    init(headline: WhatsNew.Headline, labels: (old: String, new: String)) {
        self.headline = headline
        self.labels = labels
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(headline.title)
        setAccessibilityValue("\(headline.gain). \(headline.afterText) in Wisp \(labels.new), \(headline.beforeText) in \(labels.old). \(headline.detail).")
        toolTip = "\(headline.title), \(headline.detail): \(headline.afterText) in Wisp \(labels.new), \(headline.beforeText) in \(labels.old)."
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        drawPlate()
        let pad = Self.padX, right = bounds.width - pad
        A2Dev.drawGlyphTile(headline.symbol, tint: headline.tint, in: NSRect(x: pad, y: Self.titleMid - 10, width: 20, height: 20),
                            appearance: effectiveAppearance)
        let titleLeft = pad + 29
        let titleWidth = min(ceil(Look.width(headline.title, Look.title)), right - titleLeft)
        Look.text(headline.title, x: titleLeft, mid: Self.titleMid, width: titleWidth + 1, font: Look.title, color: Look.primary)
        let detailLeft = titleLeft + titleWidth + 12
        Look.text(headline.detail, x: detailLeft, mid: Self.titleMid, width: max(0, right - detailLeft), font: Look.body,
                  color: Look.secondary, right: true)

        let gain = NSAttributedString(string: headline.gain, attributes: [.font: A2.figureFont, .foregroundColor: Look.primary, .kern: -1.36])
        gain.draw(at: NSPoint(x: pad - 1, y: Self.gainBaseline - A2.figureFont.ascender))

        // Label, bar, figure: the version in a quiet column, both bars on the old reading's scale.
        let labelWidth = ceil(max(Look.width(labels.old, Look.body), Look.width(labels.new, Look.body))) + 10
        let figureWidth = max(figureNeed, figureColumn)
        let barLeft = pad + labelWidth
        let barWidth = right - figureWidth - 12 - barLeft
        let peak = max(headline.before, headline.after, .leastNonzeroMagnitude)
        let rows: [(String, Double, NSColor, String, NSColor)] = [
            (labels.old, headline.before, Self.oldFill, headline.beforeText, Look.secondary),
            (labels.new, headline.after, headline.tint, headline.afterText, Look.primary),
        ]
        for (index, (label, value, color, figure, ink)) in rows.enumerated() {
            let mid = Self.firstBar + CGFloat(index) * Self.pitch
            Look.text(label, x: pad, mid: mid, width: labelWidth, font: Look.body, color: Look.secondary)
            let track = NSRect(x: barLeft, y: (mid - Self.barHeight / 2).rounded(), width: barWidth, height: Self.barHeight)
            let radius = Self.barHeight / 2
            Look.track.setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            // A tiny new reading still shows as a sliver.
            let length = max(1.5, track.width * CGFloat(value / peak))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: length, height: track.height),
                         xRadius: min(radius, length / 2), yRadius: radius).fill()
            Look.text(figure, x: right - figureWidth - 1, mid: mid, width: figureWidth + 2, font: Self.figureFont, color: ink, right: true)
        }
    }
}

/// One change, compact: a tinted glyph tile, a short bold title and one line. The
/// whole text shows on hover, and a change that lives on a page opens it when clicked.
@MainActor
final class WhatsNewCard: WhatsNewCardBase {
    private let entry: WhatsNew.Entry
    private let open: (PageID) -> Void
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    static let height: CGFloat = 60
    static let padX: CGFloat = 12
    static let tile: CGFloat = 28
    static let titleMid: CGFloat = 21
    static let lineMid: CGFloat = 40
    private static var textLeft: CGFloat { padX + tile + 11 }

    override var fill: NSColor { hovering ? Look.buttonHover : Look.card }

    init(entry: WhatsNew.Entry, open: @escaping (PageID) -> Void) {
        self.entry = entry
        self.open = open
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(entry.page == nil ? .staticText : .button)
        setAccessibilityLabel(entry.title)
        setAccessibilityValue(entry.text)
        if let page = entry.page { setAccessibilityHelp("Opens \(page.title).") }
        toolTip = entry.text
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Hover and click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard entry.page != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) {
        entry.page == nil ? super.cursorUpdate(with: event) : NSCursor.pointingHand.set()
    }

    override var mouseDownCanMoveWindow: Bool { entry.page == nil }

    override func mouseUp(with event: NSEvent) {
        guard let page = entry.page, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open(page)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let page = entry.page else { return false }
        open(page)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawPlate()
        A2Dev.drawGlyphTile(entry.symbol, tint: entry.tint,
                            in: NSRect(x: Self.padX, y: ((Self.height - Self.tile) / 2).rounded(), width: Self.tile, height: Self.tile),
                            appearance: effectiveAppearance)
        let right = bounds.width - Self.padX
        var titleRoom = right - Self.textLeft
        if hovering, let page = entry.page {
            let label = "Open \(page.title)"
            let width = ceil(Look.width(label, Look.body))
            let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            let arrowWidth = arrow?.size.width ?? 0
            let left = right - arrowWidth - 6 - width
            Look.text(label, x: left, mid: Self.titleMid, width: width + 1, font: Look.body, color: Look.secondary)
            if let arrow {
                let tinted = NSImage(size: arrow.size, flipped: false) { rect in
                    arrow.draw(in: rect)
                    Look.secondary.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: right - arrowWidth, y: (Self.titleMid - arrow.size.height / 2).rounded(),
                                       width: arrowWidth, height: arrow.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            titleRoom = left - 12 - Self.textLeft
        }
        Look.text(entry.title, x: Self.textLeft, mid: Self.titleMid, width: titleRoom, font: Look.title, color: Look.primary)
        Look.text(entry.line, x: Self.textLeft, mid: Self.lineMid, width: right - Self.textLeft, font: Look.body, color: Look.secondary)
    }
}
