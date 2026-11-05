import AppKit
import WispCore

/// Runs a diagnosis off the main thread and hands the result back on it. The
/// monitor looks hard for about three seconds, then everything stops.
@MainActor
enum DiagnosisRunner {
    static func run(_ delegate: AppDelegate, done: @escaping @MainActor (Diagnosis) -> Void) {
        let monitor = delegate.monitor
        DispatchQueue.global(qos: .utility).async {
            let result = monitor.diagnose()
            DispatchQueue.main.async { done(result) }
        }
    }

    /// The symbol and colour for a finding's row, when it has no app icon.
    static func look(_ kind: DiagnosisFinding.Kind) -> (String, NSColor) {
        switch kind {
        case .cpu, .heldCores: return ("cpu.fill", PageID.cpu.tint)
        case .memory: return ("memorychip.fill", Theme.indigo)
        case .thermal: return ("thermometer.high", Theme.orange)
        case .diskSpace: return ("internaldrive.fill", Theme.red)
        case .diskActivity: return ("internaldrive.fill", Theme.cyan)
        case .spotlight: return ("magnifyingglass", Theme.gray)
        case .timeMachine: return ("clock.arrow.circlepath", Theme.green)
        case .mediaAnalysis: return ("photo.fill", Theme.yellow)
        case .windowServer: return ("macwindow", Theme.blue)
        case .gpu: return ("cube.fill", PageID.gpu.tint)
        case .unmeasured: return ("gearshape.fill", Theme.gray)
        case .developer: return ("sparkles", PageID.agents.tint)
        }
    }

    /// The app's own icon for findings about one app, so the culprit is seen at a glance.
    static func icon(_ finding: DiagnosisFinding, table: ProcessTable) -> NSImage? {
        guard let id = finding.appID, id != AppGrouping.systemID, let app = table.app(id) else { return nil }
        return Icons.icon(for: app)
    }

    /// Does what a finding offers. Quitting asks first and quits normally, as the drawer's Quit does.
    static func perform(_ action: DiagnosisAction, delegate: AppDelegate, window: NSWindow?,
                        open: (PageID) -> Void, select: (String) -> Void) {
        switch action {
        case .showApp(let id): select(id)
        case .openPage(let name): if let page = PageID(rawValue: name) { open(page) }
        case .openStorage: open(.disk)
        case .quitApp(let id):
            guard let app = delegate.table.app(id), let bundleID = app.bundleIdentifier else { return select(id) }
            let alert = NSAlert()
            alert.messageText = "Quit \(app.name)?"
            alert.informativeText = "It is using \(Format.memory(app.memory)) of memory. It quits normally, so it can ask to save your work."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.icon = Icons.icon(for: app)
            let quit = { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() } }
            if let window {
                alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { quit() } }
            } else {
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { quit() }
            }
        }
    }
}

/// The toolbar control that starts a diagnosis: a symbol and a short label on the
/// toolbar's glass capsule.
final class DiagnoseButton: DrawnView {
    var onPress: (() -> Void)?
    var busy = false { didSet { if busy != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { needsDisplay = true } }
    static let label = "Why Is It Slow?"
    private static let font = Theme.sans(12, .semibold)
    private static let iconTint = Theme.dynamic(0xF29A00, 0xFFD60A)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.label)
        toolTip = "Looks at this Mac for about 3 seconds"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var textWidth: CGFloat { ceil((Self.label as NSString).size(withAttributes: [.font: Self.font]).width) }
    /// The capsule adds 6 pt each side: 12 pt before the icon and 14 after the text.
    override var fittingSize: NSSize { NSSize(width: 6 + 14 + 7 + textWidth + 8, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let fade: CGFloat = busy ? 0.4 : (pressed ? 0.6 : 1)
        let glyph = IconTile.glyph("wand.and.stars", tint: Self.iconTint.withAlphaComponent(fade), size: 14, appearance: effectiveAppearance)
        glyph.draw(in: NSRect(x: 6, y: (bounds.height - 14) / 2, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        let size = (Self.label as NSString).size(withAttributes: [.font: Self.font])
        (Self.label as NSString).draw(at: NSPoint(x: 27, y: (bounds.height - size.height) / 2),
                                      withAttributes: [.font: Self.font, .foregroundColor: A2.primary.withAlphaComponent(fade)])
    }

    override func mouseDown(with event: NSEvent) { if !busy { pressed = true } }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard !busy else { return false }
        onPress?()
        return true
    }
}

/// The diagnosis on the Overview: a card at the top of the page with the findings
/// ranked, each with its one action. Hidden until the toolbar button is pressed.
@MainActor
final class DiagnosisCard: CardView {
    let button = DiagnoseButton()
    var onResize: (() -> Void)?
    private unowned let delegate: AppDelegate
    private let open: (PageID) -> Void
    private let select: (Selection?) -> Void
    private let title = TextLine()
    private let meta = TextLine()
    private let again = CapsuleButton()
    private let done = CapsuleButton()
    private let spinner = NSProgressIndicator()
    private let lookingTitle = TextLine()
    private let lookingNote = TextLine()
    private var rows: [NoticeRow] = []
    private var running = false
    private var result: Diagnosis?
    private var items: [(symbol: String, tint: NSColor, image: NSImage?, title: String, detail: String, action: DiagnosisAction?)] = []
    private var fittedWidth: CGFloat = 0

    init(delegate: AppDelegate, open: @escaping (PageID) -> Void, select: @escaping (Selection?) -> Void) {
        self.delegate = delegate
        self.open = open
        self.select = select
        super.init()
        isHidden = true
        title.text = NSAttributedString(string: DiagnoseButton.label, attributes: [.font: Theme.sans(15, .bold), .foregroundColor: Theme.ink])
        again.title = "Check Again"
        done.title = "Done"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        lookingTitle.text = NSAttributedString(string: "Looking at this Mac", attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
        lookingNote.text = NSAttributedString(string: "CPU, memory, disk, GPU and heat for about 3 seconds",
                                              attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary])
        meta.alignment = .right
        for view in [title, meta, again, done, spinner, lookingTitle, lookingNote] as [NSView] { addSubview(view) }
        button.onPress = { [weak self] in self?.start() }
        again.onPress = { [weak self] in self?.start() }
        done.onPress = { [weak self] in self?.dismiss() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Adds the card to the page; WISP_DIAGNOSE=1 runs one at launch, for screenshots.
    func install(in canvas: NSView, relayout: @escaping () -> Void) {
        canvas.addSubview(self)
        onResize = relayout
        if ProcessInfo.processInfo.environment["WISP_DIAGNOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.start() }
        }
    }

    private var rowCount: Int { running ? 1 : max(1, rows.filter { !$0.isHidden }.count) }
    var height: CGFloat { 16 + 22 + 8 + CGFloat(rowCount) * 54 + 12 }

    /// Places the card at the top of the page; returns where the next card starts.
    func place(x: CGFloat, y: CGFloat, width: CGFloat, gap: CGFloat) -> CGFloat {
        guard !isHidden else { return y }
        frame = NSRect(x: x, y: y, width: width, height: height).integral
        return frame.maxY + gap
    }

    private func start() {
        guard !running else { return }
        running = true
        isHidden = false
        button.busy = true
        spinner.startAnimation(nil)
        refresh()
        DiagnosisRunner.run(delegate) { [weak self] diagnosis in
            guard let self else { return }
            self.running = false
            self.button.busy = false
            self.spinner.stopAnimation(nil)
            self.result = diagnosis
            self.refresh()
        }
    }

    private func dismiss() {
        isHidden = true
        result = nil
        onResize?()
    }

    private func refresh() {
        lookingTitle.isHidden = !running
        lookingNote.isHidden = !running
        again.isHidden = running || result == nil
        done.isHidden = running
        items = []
        if !running, let result {
            let time = result.date.formatted(date: .omitted, time: .shortened)
            meta.text = Theme.caption("Checked at \(time)")
            if result.isHealthy {
                items.append(("checkmark.circle.fill", Theme.good, nil, result.summary, result.numbers.joined(separator: " · "), nil))
            }
            for finding in result.findings {
                let (symbol, tint) = DiagnosisRunner.look(finding.kind)
                items.append((symbol, tint, DiagnosisRunner.icon(finding, table: delegate.table), finding.title, finding.detail, finding.action))
            }
        } else {
            meta.text = NSAttributedString()
        }
        while rows.count < items.count {
            let row = NoticeRow()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = running || index >= items.count
            row.showsRule = index < items.count - 1
        }
        fittedWidth = 0
        needsLayout = true
        onResize?()
    }

    /// Fills the rows for the card's width. A sentence too long for its row is split at
    /// " and " or ": ", and the second half takes the detail line.
    private func fill(width: CGFloat) {
        guard width != fittedWidth else { return }
        fittedWidth = width
        let font = Theme.sans(13, .semibold)
        for (index, item) in items.enumerated() where index < rows.count {
            var title = item.title, detail = item.detail
            let buttonWidth = item.action.map { ceil(($0.title as NSString).size(withAttributes: [.font: Theme.sans(12, .medium)]).width) + 24 + 12 } ?? 0
            let room = width - 42 - buttonWidth
            if ceil((title as NSString).size(withAttributes: [.font: font]).width) > room {
                for separator in [" and ", ": "] {
                    guard let range = title.range(of: separator) else { continue }
                    let rest = String(title[range.upperBound...])
                    title = String(title[..<range.lowerBound])
                    detail = rest.hasPrefix("macOS") ? rest : rest.prefix(1).uppercased() + rest.dropFirst()
                    break
                }
            }
            rows[index].set(symbol: item.symbol, tint: item.tint, image: item.image, title: title, detail: detail,
                            button: item.action?.title, action: item.action.map { action in { [weak self] in self?.perform(action) } })
        }
    }

    private func perform(_ action: DiagnosisAction) {
        DiagnosisRunner.perform(action, delegate: delegate, window: window, open: open, select: { [weak self] id in self?.select(.app(id)) })
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 32
        title.frame = NSRect(x: 16, y: 14, width: 200, height: 22)
        var right = 16 + width
        for capsule in [done, again] where !capsule.isHidden {
            let w = capsule.naturalWidth
            capsule.frame = NSRect(x: right - w, y: 13, width: w, height: 24)
            right -= w + 8
        }
        let metaWidth = meta.naturalWidth
        meta.frame = NSRect(x: right - metaWidth - 4, y: 18, width: metaWidth, height: 14)
        spinner.frame = NSRect(x: 16 + 7, y: 46 + (54 - 16) / 2, width: 16, height: 16)
        lookingTitle.frame = NSRect(x: 58, y: 46 + 54 / 2 - 17, width: width - 42, height: 17)
        lookingNote.frame = NSRect(x: 58, y: 46 + 54 / 2 + 1, width: width - 42, height: 16)
        fill(width: width)
        var y: CGFloat = 46
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: 16, y: y, width: width, height: 54)
            y += 54
        }
    }
}
