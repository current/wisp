import AppKit
import WispCore

/// "Why is it slow?" in the menu bar dashboard: a Check button that runs the
/// three-second diagnosis and lists the top findings. Reads nothing until pressed.
final class WhyBlock: DashboardBlockView {
    private let check = CapsuleButton()
    private let spinner = NSProgressIndicator()
    private var lines: [FindingLine] = []
    private var running = false
    private var result: Diagnosis?
    private static let shown = 3

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        check.title = "Check"
        check.onPress = { [weak self] in self?.start() }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(check)
        addSubview(spinner)
        // WISP_DIAGNOSE=1 runs one at launch, for screenshots of the dashboard.
        if ProcessInfo.processInfo.environment["WISP_DIAGNOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var visibleLines: Int { lines.filter { !$0.isHidden }.count }
    override var height: CGFloat { visibleLines == 0 ? 46 : 46 + CGFloat(visibleLines) * FindingLine.height + 8 }

    override func layout() {
        super.layout()
        let width = check.naturalWidth
        placeRight(check, width: width, height: 24)
        spinner.frame = NSRect(x: bounds.width - 16 - 16, y: 15, width: 16, height: 16)
        var y: CGFloat = 44
        for line in lines where !line.isHidden {
            line.frame = NSRect(x: 16, y: y, width: content, height: FindingLine.height)
            y += FindingLine.height
        }
    }

    private func start() {
        guard !running else { return }
        running = true
        check.isHidden = true
        spinner.startAnimation(nil)
        DiagnosisRunner.run(delegate) { [weak self] diagnosis in
            guard let self else { return }
            self.running = false
            self.spinner.stopAnimation(nil)
            self.check.title = "Check Again"
            self.check.isHidden = false
            self.show(diagnosis)
        }
    }

    private func show(_ diagnosis: Diagnosis) {
        var items: [(NSImage, String, String, DiagnosisAction?)] = []
        if diagnosis.isHealthy {
            items.append((IconTile.image("checkmark.circle.fill", tint: Theme.good, size: 24, solid: true, appearance: effectiveAppearance),
                          diagnosis.summary, diagnosis.numbers.joined(separator: " · "), nil))
        }
        for finding in diagnosis.findings.prefix(Self.shown) {
            let (symbol, tint) = DiagnosisRunner.look(finding.kind)
            let image = DiagnosisRunner.icon(finding, table: delegate.table)
                ?? IconTile.image(symbol, tint: tint, size: 24, solid: true, appearance: effectiveAppearance)
            items.append((image, finding.title, finding.detail, finding.action))
        }
        while lines.count < items.count {
            let line = FindingLine()
            addSubview(line)
            lines.append(line)
        }
        for (index, line) in lines.enumerated() {
            line.isHidden = index >= items.count
            guard index < items.count else { continue }
            let (image, title, detail, action) = items[index]
            line.set(image: image, title: title, detail: detail)
            line.showsRule = index < items.count - 1
            line.onPress = action.map { action in { [weak self] in self?.perform(action) } }
        }
        needsLayout = true
        onResize?()
    }

    private func perform(_ action: DiagnosisAction) {
        let delegate = self.delegate
        DiagnosisRunner.perform(action, delegate: delegate, window: nil,
                                open: { delegate.showPage($0) }, select: { delegate.showWindow(selecting: $0) })
    }
}

/// One finding in the dashboard: icon, a sentence that may take two lines, and its detail.
/// The whole line is the button when the finding has an action.
final class FindingLine: DrawnView {
    static let height: CGFloat = 58
    var showsRule = true { didSet { needsDisplay = true } }
    var onPress: (() -> Void)? { didSet { setAccessibilityRole(onPress == nil ? .staticText : .button) } }
    private var image: NSImage?
    private var title = ""
    private var detail = ""
    private var pressed = false { didSet { needsDisplay = true } }

    func set(image: NSImage, title: String, detail: String) {
        self.image = image
        self.title = title
        self.detail = detail
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if pressed {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -6, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        image?.draw(in: NSRect(x: 0, y: 10, width: 24, height: 24), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: Theme.sans(12.5, .semibold), .foregroundColor: Theme.ink, .paragraphStyle: paragraph]
        let width = bounds.width - 34
        let titleRect = (title as NSString).boundingRect(with: NSSize(width: width, height: 34), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                         attributes: titleAttributes)
        let titleHeight = min(32, ceil(titleRect.height))
        let detailHeight: CGFloat = detail.isEmpty ? 0 : 15
        var y = (bounds.height - titleHeight - detailHeight) / 2
        (title as NSString).draw(with: NSRect(x: 34, y: y, width: width, height: titleHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes)
        y += titleHeight
        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.lineBreakMode = .byTruncatingTail
        (detail as NSString).draw(with: NSRect(x: 34, y: y, width: width, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary, .paragraphStyle: detailParagraph])
        if showsRule {
            Theme.rule.setFill()
            NSRect(x: 34, y: bounds.height - 0.5, width: bounds.width - 34, height: 0.5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { if onPress != nil { pressed = true } }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
