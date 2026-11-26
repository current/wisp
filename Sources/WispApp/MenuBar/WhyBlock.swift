import AppKit
import WispCore

/// "Why is it slow?" in the menu bar dashboard: a Check button that runs the
/// three-second diagnosis and lists the top findings. Reads nothing until pressed.
final class WhyBlock: DashboardBlockView {
    /// Over the card's tag, which reads Check: the tag is the button.
    private let check = TagButton()
    private var lines: [FindingLine] = []
    private var running = false
    private var checkedAt: Date?
    private static let shown = 3

    override init(_ block: DashboardBlock, delegate: AppDelegate) {
        super.init(block, delegate: delegate)
        check.onPress = { [weak self] in self?.start() }
        addSubview(check)
        showHeader()
        showMessage("Press Check when the Mac feels slow.")
        // WISP_DIAGNOSE=1 runs one at launch, for screenshots of the dashboard.
        if ProcessInfo.processInfo.environment["WISP_DIAGNOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showHeader() {
        let meta = running ? "" : checkedAt.map { "At " + $0.formatted(date: .omitted, time: .shortened) } ?? "Three seconds"
        let tag = running ? "Checking" : checkedAt == nil ? "Check" : "Check Again"
        check.title = tag
        check.isEnabled = !running
        card.show(mark: .glyph("stethoscope", A2.labelTint(.overview)), title: "Why is it slow?", meta: meta, tag: tag, lines: [])
        needsLayout = true
    }

    private var visibleLines: Int { lines.filter { !$0.isHidden }.count }

    override var height: CGFloat {
        visibleLines == 0 ? super.height : Self.titleRow + CGFloat(visibleLines) * FindingLine.height + 6
    }

    override func layout() {
        super.layout()
        check.frame = SoftCard.tagRect(check.title, in: bounds)
        var y = Self.titleRow - 2
        for line in lines where !line.isHidden {
            line.frame = NSRect(x: 0, y: y, width: bounds.width, height: FindingLine.height)
            y += FindingLine.height
        }
    }

    private func start() {
        guard !running else { return }
        running = true
        showHeader()
        DiagnosisRunner.run(delegate) { [weak self] diagnosis in
            guard let self else { return }
            self.running = false
            self.checkedAt = Date()
            self.showHeader()
            self.show(diagnosis)
        }
    }

    private func show(_ diagnosis: Diagnosis) {
        var items: [(FindingLine.Mark, String, String, DiagnosisAction?)] = []
        if diagnosis.isHealthy {
            items.append((.glyph("checkmark", A2.good), diagnosis.summary, diagnosis.numbers.joined(separator: " · "), nil))
        }
        for finding in diagnosis.findings.prefix(Self.shown) {
            let (symbol, tint) = DiagnosisRunner.look(finding.kind)
            let mark: FindingLine.Mark = DiagnosisRunner.icon(finding, table: delegate.table).map { .icon($0) } ?? .glyph(symbol, tint)
            items.append((mark, finding.title, finding.detail, finding.action))
        }
        while lines.count < items.count {
            let line = FindingLine()
            addSubview(line)
            lines.append(line)
        }
        for (index, line) in lines.enumerated() {
            line.isHidden = index >= items.count
            guard index < items.count else { continue }
            let (mark, title, detail, action) = items[index]
            line.set(mark: mark, title: title, detail: detail)
            line.onPress = action.map { action in { [weak self] in self?.perform(action) } }
        }
        showMessage(items.isEmpty ? "Nothing stands out right now." : nil)
        needsLayout = true
        refit()
    }

    private func perform(_ action: DiagnosisAction) {
        let delegate = self.delegate
        DiagnosisRunner.perform(action, delegate: delegate, window: nil,
                                open: { delegate.showPage($0) }, select: { delegate.showWindow(selecting: $0) })
    }
}
