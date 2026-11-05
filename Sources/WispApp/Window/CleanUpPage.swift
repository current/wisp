import AppKit
import WispCore

/// Clean Up: what can go from the Mac, by tab, ticked and reviewed before anything moves.
/// Scans run only while the page is on screen, on a utility queue, and stop when it is
/// left. Results stay in memory with their time until the window closes.
@MainActor
final class CleanUpPage: CardPage {
    private struct Found {
        var items: [CleanItem] = []
        var scannedAt: Date?
        /// False when the scan was stopped before it finished; the tab scans again next time.
        var complete = false
    }

    private var found: [CleanTab: Found] = [:]
    private var selected: Set<String> = []
    /// Every id seen, so a rescan keeps the owner's ticks instead of resetting them.
    private var seen: Set<String> = []
    private var tab: CleanTab = .junk
    private var scanning: (flag: ScanFlag, tabs: [CleanTab])?
    private var leftoversOf: (id: String, name: String)?
    private var history: [CleanRecord]?
    private var visible = false
    private var refreshQueued = false
    /// Set by a click on the scheduled-clean notification: review the safe items once the scan is in.
    private var scheduledPending = false
    private var review: CleanReview?

    private let tabs = Segmented(CleanTab.allCases.map(\.title))
    private let headerCard = CardView(), headerTitle = TextLine(), figure = TextLine(), status = TextLine()
    private lazy var scanButton: ActionButton = {
        let button = ActionButton(title: "Scan Again", target: self, action: #selector(scanPressed))
        button.secondary = true
        return button
    }()
    private lazy var showAllButton: ActionButton = {
        let button = ActionButton(title: "Show All", target: self, action: #selector(showAll))
        button.secondary = true
        return button
    }()
    private let listCard = CardView(), list = CleanList(), emptyNote = TextLine()
    private lazy var footer = CleanFooter(target: self, safe: #selector(cleanSafe), clean: #selector(cleanSelected))
    private let root = Root()
    private static let work = DispatchQueue(label: "app.wisp.clean", qos: .utility)

    /// Holds the scrolling cards and the footer over them.
    private final class Root: NSView {
        override var isFlipped: Bool { true }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }
    }

    private var center: CleanUpCenter { delegate.cleanUp }
    private var demo: Bool { ProcessInfo.processInfo.environment["WISP_CLEAN_DEMO"] != nil }
    private var scanners: [any CleanScanner] { demo ? CleanUpDemo.scanners : CleanRegistry.scanners }

    override var pageTint: NSColor { PageID.cleanup.tint }
    override var toolbarItems: [NSView] { [tabs] }

    override func loadView() {
        super.loadView()
        root.addSubview(scroll)
        root.addSubview(footer)
        view = root
        for view in [headerCard, listCard] { canvas.addSubview(view) }
        for view in [headerTitle, figure, status, scanButton, showAllButton] as [NSView] { headerCard.addSubview(view) }
        for view in [list, emptyNote] as [NSView] { listCard.addSubview(view) }
        list.drawsVisibleOnly = true
        list.onToggle = { [weak self] ids, on in self?.toggle(ids, on) }
        list.onExclude = { [weak self] item in self?.exclude(item) }
        tabs.onChange = { [weak self] index in self?.pick(CleanTab.allCases[index]) }
        // WISP_CLEAN_TAB=developer opens on one tab, for screenshots.
        if let name = ProcessInfo.processInfo.environment["WISP_CLEAN_TAB"], let start = CleanTab(rawValue: name) {
            tab = start
            tabs.select(CleanTab.allCases.firstIndex(of: start) ?? 0, animated: false)
        }
        fill()
    }

    override func viewDidLayout() {
        scroll.frame = root.bounds
        let showsFooter = tab != .history
        footer.isHidden = !showsFooter
        footer.frame = NSRect(x: margin, y: root.bounds.height - CleanFooter.height - 16, width: max(0, root.bounds.width - margin * 2),
                              height: CleanFooter.height)
        let bottom = showsFooter ? CleanFooter.height + 24 : 0
        if scroll.contentInsets.bottom != bottom { scroll.contentInsets.bottom = bottom }
        review?.frame = root.bounds
        super.viewDidLayout()
    }

    // MARK: Open and close

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !visible else { return }
        visible = true
        scanIfNeeded()
        // WISP_CLEAN_REVIEW=1 opens the review for the ticked items (=all for every item on the tab), for screenshots.
        if let review = ProcessInfo.processInfo.environment["WISP_CLEAN_REVIEW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if review == "all" { self.presentReview(self.shown, trigger: .manual) } else { self.cleanSelected() }
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard visible else { return }
        visible = false
        stopScan()
    }

    override func update(system: SystemSnapshot) {
        // Keeps "scanned 2 min ago" true; redraws only when the words change.
        if visible, scanning == nil { updateHeader() }
    }

    // MARK: Scanning

    private func scanIfNeeded() {
        guard tab != .history else { return loadHistory() }
        let tabs = (scheduledPending ? CleanRegistry.safeTabs : [tab]).filter { tab in scanners.contains { $0.tab == tab } }
        if tabs.contains(where: { found[$0]?.complete != true }) { scan(tabs) }
    }

    private func scan(_ tabs: [CleanTab]) {
        stopScan()
        let flag = ScanFlag()
        scanning = (flag, tabs)
        for tab in tabs {
            found[tab, default: Found()].complete = false
        }
        let incoming = Incoming()
        let context = CleanScanContext(excluded: center.settings.exclusions, isCancelled: { flag.isSet }, found: { [weak self] batch in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scanning?.flag === flag else { return }
                    for item in batch where incoming.ids.insert(item.id).inserted { self.found[item.tab, default: Found()].items.append(item) }
                    self.queueRefresh()
                }
            }
        })
        for tab in tabs { found[tab]?.items = [] }
        let scanners = self.scanners
        updateHeader()
        Self.work.async { [weak self] in
            let items = CleanRegistry.scan(tabs, context: context, using: scanners)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scanning?.flag === flag else { return }
                    self.scanning = nil
                    let now = Date()
                    for tab in tabs {
                        self.found[tab] = Found(items: items.filter { $0.tab == tab }, scannedAt: now, complete: !flag.isSet)
                    }
                    self.fill()
                    if self.scheduledPending {
                        self.scheduledPending = false
                        self.presentReview(items.filter(\.isSafeTrash), trigger: .scheduled)
                    }
                }
            }
        }
    }

    private func stopScan() {
        guard let scanning else { return }
        scanning.flag.set()
        self.scanning = nil
        // What came in so far stays on screen; the tab scans again the next time it is shown.
        updateHeader()
    }

    /// Ids that came in during one scan, so a batch sent twice shows once.
    private final class Incoming {
        var ids = Set<String>()
    }

    /// Batches can arrive many times a second; the list is rebuilt at most four times a second.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.fill()
        }
    }

    @objc private func scanPressed() {
        if scanning != nil {
            stopScan()
            fill()
        } else {
            scan([tab])
        }
    }

    // MARK: Tabs

    private func pick(_ new: CleanTab) {
        guard review == nil else {
            tabs.select(CleanTab.allCases.firstIndex(of: tab) ?? 0, animated: false)
            return
        }
        tab = new
        if new != .leftovers { leftoversOf = nil }
        if let scanning, !scanning.tabs.contains(new) { stopScan() }
        fill()
        scrollToTop()
        Motion.enter(listCard, from: CGPoint(x: 0, y: 6), duration: 0.2)
        if visible { scanIfNeeded() }
        view.needsLayout = true
    }

    /// The scheduled clean's notification was clicked: scan Junk and Developer, then review their safe items.
    func startScheduledClean() {
        scheduledPending = true
        tabs.select(0, animated: false)
        tab = .junk
        fill()
        if visible { scan(CleanRegistry.safeTabs) }
    }

    /// A deleted app's notification was clicked: Leftovers, only that app's.
    func showLeftovers(of bundleID: String, name: String) {
        leftoversOf = (bundleID, name)
        tabs.select(CleanTab.allCases.firstIndex(of: .leftovers) ?? 0, animated: false)
        tab = .leftovers
        found[.leftovers]?.complete = false
        fill()
        if visible { scan([.leftovers]) }
    }

    @objc private func showAll() {
        leftoversOf = nil
        fill()
    }

    // MARK: Selection

    /// The items on screen: this tab's, narrowed to one app when Leftovers was opened for it.
    private var shown: [CleanItem] {
        let items = found[tab]?.items ?? []
        guard tab == .leftovers, let leftoversOf else { return items }
        return items.filter { $0.ownerBundleID == leftoversOf.id }
    }

    private func toggle(_ ids: [String], _ on: Bool) {
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
        fill()
    }

    private func exclude(_ item: CleanItem) {
        center.change { settings in for path in item.paths { settings.exclude(path) } }
        for tab in found.keys {
            found[tab]?.items.removeAll { $0.paths.contains(where: center.settings.isExcluded) }
        }
        selected.remove(item.id)
        fill()
    }

    // MARK: Filling in

    private func fill() {
        for item in found.values.flatMap(\.items) where seen.insert(item.id).inserted && item.checkedByDefault {
            selected.insert(item.id)
        }
        if tab == .history {
            fillHistory()
        } else {
            fillItems()
        }
        updateHeader()
        updateFooter()
        relayout()
    }

    private func fillItems() {
        var order: [String] = []
        var groups: [String: [CleanItem]] = [:]
        for item in shown {
            if groups[item.group] == nil { order.append(item.group) }
            groups[item.group, default: []].append(item)
        }
        var rows: [CleanList.Row] = []
        for name in order {
            let items = groups[name]!.sorted { $0.bytes > $1.bytes }
            let ids = items.map(\.id)
            let ticked = ids.filter(selected.contains).count
            rows.append(.init(kind: .heading, id: "#" + name, title: name, value: Format.bytes(UInt64(items.totalBytes)),
                              check: ticked == 0 ? .off : ticked == ids.count ? .on : .mixed, ids: ids))
            for item in items {
                rows.append(.init(kind: .item, id: item.id, title: item.name, detail: item.detail, value: Format.bytes(UInt64(item.bytes)),
                                  label: item.safetyLabel, labelWarns: item.removal.isPermanent,
                                  check: selected.contains(item.id) ? .on : .off, item: item))
            }
        }
        list.rows = rows
        let hasScanners = scanners.contains { $0.tab == tab }
        emptyNote.text = Theme.caption(!hasScanners ? "Wisp has nothing to look for on this tab yet"
                                       : scanning != nil ? "Looking…"
                                       : found[tab]?.scannedAt == nil ? "Not scanned yet"
                                       : leftoversOf != nil ? "Nothing left of \(leftoversOf!.name)"
                                       : "Nothing found", size: 12)
        emptyNote.alignment = .center
        emptyNote.isHidden = !rows.isEmpty
    }

    private func loadHistory() {
        Self.work.async { [weak self] in
            let records = CleanHistory.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.history = records
                    if self.tab == .history { self.fill() }
                }
            }
        }
    }

    private func fillHistory() {
        let records = (history ?? []).reversed()
        var rows: [CleanList.Row] = []
        var month = ""
        let monthFormat = DateFormatter()
        monthFormat.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        for record in records {
            let heading = monthFormat.string(from: record.date)
            if heading != month {
                month = heading
                let inMonth = records.filter { monthFormat.string(from: $0.date) == heading }
                rows.append(.init(kind: .heading, id: "#" + heading, title: heading,
                                  value: Format.bytes(UInt64(inMonth.reduce(0) { $0 + $1.bytesFreed }))))
            }
            let removed = record.items.filter(\.outcome.removed)
            let names = removed.prefix(3).map(\.name).joined(separator: ", ") + (removed.count > 3 ? " and \(removed.count - 3) more" : "")
            let stayed = record.items.count - removed.count
            let permanent = removed.contains { $0.removal.isPermanent }
            let title = removed.isEmpty ? "Nothing removed"
                : (permanent ? "Removed " : "Moved ") + (removed.count == 1 ? "1 item" : "\(removed.count) items") + (permanent ? "" : " to the Trash")
            rows.append(.init(kind: .item, id: record.id.uuidString, title: title,
                              detail: [names, stayed > 0 ? "\(stayed) left in place" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                              value: Format.bytes(UInt64(record.bytesFreed)),
                              label: record.date.formatted(date: .abbreviated, time: .shortened) + " · " + record.trigger.historyLabel,
                              symbol: record.trigger == .scheduled ? "calendar" : record.trigger == .cli ? "terminal.fill" : "trash.fill"))
        }
        list.rows = rows
        emptyNote.text = Theme.caption(history == nil ? "Loading…" : "Cleans you make from here or with wisp clean show up here", size: 12)
        emptyNote.alignment = .center
        emptyNote.isHidden = !rows.isEmpty
    }

    private func updateHeader() {
        guard isViewLoaded else { return }
        let figureText: String, unitText: String, statusText: String
        if tab == .history {
            let records = history ?? []
            figureText = records.isEmpty ? "–" : Format.bytes(UInt64(records.reduce(0) { $0 + $1.bytesFreed }))
            unitText = records.isEmpty ? "nothing cleaned yet" : "freed in " + (records.count == 1 ? "1 clean" : "\(records.count) cleans")
            statusText = ""
        } else {
            let items = shown
            let hasScanners = scanners.contains { $0.tab == tab }
            figureText = hasScanners ? Format.bytes(UInt64(items.totalBytes)) : "–"
            unitText = !hasScanners ? "" : "can go" + (items.isEmpty ? "" : " · " + (items.count == 1 ? "1 item" : "\(items.count) items"))
                + (leftoversOf.map { " left by \($0.name)" } ?? "")
            if scanning != nil {
                statusText = "Scanning…" + (items.isEmpty ? "" : " \(items.count) found so far")
            } else if hasScanners, let date = found[tab]?.scannedAt {
                statusText = (found[tab]?.complete == false ? "Stopped " : "Scanned ") + StoragePage.ago(date)
            } else {
                statusText = ""
            }
        }
        headerTitle.text = Theme.header(tab.title, symbol: tab.symbol, tint: pageTint)
        let text = NSMutableAttributedString(string: figureText, attributes: [.font: Theme.figure(28, .regular), .foregroundColor: Theme.ink])
        text.append(NSAttributedString(string: "  " + unitText, attributes: [.font: Theme.sans(15), .foregroundColor: Theme.inkSecondary]))
        figure.text = text
        status.text = Theme.caption(statusText, size: 11)
        status.alignment = .right
        let canScan = tab != .history && scanners.contains { $0.tab == tab }
        scanButton.isHidden = !canScan
        scanButton.title = scanning != nil ? "Stop" : found[tab]?.scannedAt == nil ? "Scan" : "Scan Again"
        scanButton.invalidateIntrinsicContentSize()
        showAllButton.isHidden = !(tab == .leftovers && leftoversOf != nil)
        placeHeader()
    }

    private func updateFooter() {
        let items = shown
        let ticked = items.filter { selected.contains($0.id) }
        footer.selection.text = NSAttributedString(
            string: ticked.isEmpty ? "Nothing selected" : "\(ticked.count) selected · \(Format.bytes(UInt64(ticked.totalBytes)))",
            attributes: [.font: Theme.sans(13, .medium), .foregroundColor: ticked.isEmpty ? Theme.inkSecondary : Theme.ink])
        footer.set(enabled: footer.cleanButton, !ticked.isEmpty && review == nil)
        footer.set(enabled: footer.safeButton, items.contains(where: \.isSafeTrash) && review == nil)
        view.needsLayout = true
    }

    // MARK: Cleaning

    @objc private func cleanSelected() {
        presentReview(shown.filter { selected.contains($0.id) }, trigger: .manual)
    }

    @objc private func cleanSafe() {
        presentReview(shown.filter(\.isSafeTrash), trigger: .manual)
    }

    private func presentReview(_ items: [CleanItem], trigger: CleanRecord.Trigger) {
        guard !items.isEmpty, review == nil else { return }
        let sheet = CleanReview(items: items)
        sheet.frame = root.bounds
        sheet.onCancel = { [weak self] in self?.dismissReview() }
        sheet.onConfirm = { [weak self] in self?.run(items, trigger: trigger) }
        if let refusal = CleanRegistry.selectionRefusal(items) { sheet.block(refusal) }
        root.addSubview(sheet)
        review = sheet
        view.window?.makeFirstResponder(sheet)
        Motion.enter(sheet, from: CGPoint(x: 0, y: 6), duration: 0.18)
        updateFooter()
    }

    private func dismissReview() {
        guard let review else { return }
        self.review = nil
        Motion.leave(review, to: CGPoint(x: 0, y: 4), duration: 0.14) { review.removeFromSuperview() }
        updateFooter()
    }

    private func run(_ items: [CleanItem], trigger: CleanRecord.Trigger) {
        guard let sheet = review else { return }
        sheet.progress(done: 0, of: items.count)
        let cleaner = Cleaner(exclusions: center.settings.exclusions, guards: demo ? CleanUpDemo.guards : .live)
        let demo = self.demo
        let total = items.count
        Self.work.async { [weak self] in
            var done = 0
            let report = cleaner.clean(items, progress: { _ in
                done += 1
                let count = done
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.review?.progress(done: count, of: total) } }
            })
            let record = report.record(trigger: trigger)
            if !demo { CleanHistory.append(record) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let removed = Set(report.removed.map(\.item.id))
                    for tab in self.found.keys { self.found[tab]?.items.removeAll { removed.contains($0.id) } }
                    self.selected.subtract(removed)
                    self.history?.append(record)
                    self.review?.finish(report, permanent: items.contains(where: \.removal.isPermanent))
                    self.fill()
                }
            }
        }
    }

    // MARK: Layout

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = margin
        headerCard.frame = NSRect(x: margin, y: y, width: inner, height: 96)
        y += 96 + gap
        let listHeight = list.rows.isEmpty ? 120 : list.naturalHeight + 32
        listCard.frame = NSRect(x: margin, y: y, width: inner, height: listHeight)
        list.frame = NSRect(x: 20, y: 16, width: inner - 40, height: max(1, list.naturalHeight))
        emptyNote.frame = NSRect(x: 20, y: (listHeight - 18) / 2, width: inner - 40, height: 18)
        placeHeader()
        return y + listHeight + margin
    }

    private func placeHeader() {
        let width = headerCard.bounds.width - 40
        guard width > 0 else { return }
        headerTitle.frame = NSRect(x: 20, y: 16, width: headerTitle.naturalWidth + 4, height: 22)
        var right = 20 + width
        for button in [scanButton, showAllButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: right - size.width, y: 14, width: size.width, height: size.height)
            right -= size.width + 10
        }
        let statusWidth = max(0, min(320, right - headerTitle.frame.maxX - 16))
        status.frame = NSRect(x: right - statusWidth, y: 19, width: statusWidth, height: 16)
        figure.frame = NSRect(x: 20, y: 48, width: width, height: 36)
    }
}

extension CleanRecord.Trigger {
    var historyLabel: String {
        switch self {
        case .manual: return "by you"
        case .scheduled: return "scheduled"
        case .cli: return "wisp clean"
        }
    }
}
