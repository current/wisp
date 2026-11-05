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
    private let scanButton = A2PillButton(), showAllButton = A2PillButton(), backButton = A2PillButton()
    private let listCard = CardView(), list = CleanList(), emptyNote = TextLine()
    private let footer = CleanFooter()
    private let uninstall = UninstallBrowser()
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

    /// The tab's name and symbol in the header: the A2 cyan, as in the mockup.
    private static let labelTint = A2.labelTint(.disk)

    override func loadView() {
        super.loadView()
        let (_, subtitle) = heading(PageID.cleanup.title)
        subtitle.variants = ["Nothing moves until you review it", ""].map(Toolbar.subtitle)
        scanButton.title = "Scan Again"
        scanButton.onPress = { [weak self] in self?.scanPressed() }
        showAllButton.title = "Show All"
        showAllButton.onPress = { [weak self] in self?.showAll() }
        backButton.title = "All Apps"
        backButton.onPress = { [weak self] in self?.backToApps() }
        footer.safeButton.onPress = { [weak self] in self?.cleanSafe() }
        footer.cleanButton.onPress = { [weak self] in self?.cleanSelected() }
        footer.quitButton.onPress = { [weak self] in self?.quitApp() }
        root.addSubview(scroll)
        root.addSubview(footer)
        view = root
        for view in [headerCard, listCard] { canvas.addSubview(view) }
        for view in [headerTitle, figure, status, scanButton, showAllButton, backButton, uninstall.search, uninstall.removalLabel,
                     uninstall.removalToggle] as [NSView] { headerCard.addSubview(view) }
        for view in [list, emptyNote] as [NSView] { listCard.addSubview(view) }
        list.drawsVisibleOnly = true
        list.onToggle = { [weak self] ids, on in self?.toggle(ids, on) }
        uninstall.onChange = { [weak self] in self?.fill() }
        uninstall.onProgress = { [weak self] in self?.queueRefresh() }
        tabs.onChange = { [weak self] index in self?.pick(CleanTab.allCases[index]) }
        // WISP_CLEAN_TAB=developer opens on one tab, for screenshots.
        if let name = ProcessInfo.processInfo.environment["WISP_CLEAN_TAB"], let start = CleanTab(rawValue: name) {
            tab = start
            tabs.select(CleanTab.allCases.firstIndex(of: start) ?? 0, animated: false)
        }
        // WISP_CLEAN_APP=<name or bundle path> opens that app's plan on the Uninstall tab, for screenshots.
        if let app = ProcessInfo.processInfo.environment["WISP_CLEAN_APP"] { uninstall.open(app) }
        fill()
    }

    override func viewDidLayout() {
        scroll.frame = root.bounds
        let showsFooter = footerShown
        footer.isHidden = !showsFooter
        footer.frame = NSRect(x: margin, y: root.bounds.height - CleanFooter.height - margin, width: max(0, root.bounds.width - margin * 2),
                              height: CleanFooter.height)
        let bottom = showsFooter ? CleanFooter.height + gap : 0
        if scroll.contentInsets.bottom != bottom { scroll.contentInsets.bottom = bottom }
        review?.frame = root.bounds
        super.viewDidLayout()
        if root.bounds.height != arrangedHeight { relayout() }
    }

    /// The list card reaches the footer, so a taller window lays the page out again.
    private var arrangedHeight: CGFloat = 0

    private var footerShown: Bool { tab != .history && !(tab == .uninstall && uninstall.chosen == nil) }

    // MARK: Open and close

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !visible else { return }
        visible = true
        scanIfNeeded()
        // WISP_CLEAN_REVIEW=1 opens the review for the ticked items (=all for every item on the tab), for screenshots.
        if let review = ProcessInfo.processInfo.environment["WISP_CLEAN_REVIEW"] { openReviewWhenFound(all: review == "all", tries: 10) }
    }

    /// Waits for the tab's items (an uninstall plan can take a few seconds), then opens the review.
    private func openReviewWhenFound(all: Bool, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if self.shown.isEmpty, tries > 0 { return self.openReviewWhenFound(all: all, tries: tries - 1) }
            if all { self.presentReview(self.shown, trigger: .manual) } else { self.cleanSelected() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard visible else { return }
        visible = false
        stopScan()
        uninstall.disappear()
    }

    override func update(system: SystemSnapshot) {
        // Keeps "scanned 2 min ago" true; redraws only when the words change.
        if visible, scanning == nil, !uninstall.isScanning { updateHeader() }
    }

    // MARK: Scanning

    private func scanIfNeeded() {
        guard tab != .history else { return loadHistory() }
        guard tab != .uninstall else { return uninstall.appear() }
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

    private func scanPressed() {
        if tab == .uninstall {
            if uninstall.isScanning { uninstall.stopScan() } else { uninstall.scan(again: uninstall.complete) }
        } else if scanning != nil {
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
        if tab == .uninstall, new != .uninstall { uninstall.disappear() }
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

    func show(_ shown: CleanTab) {
        tabs.select(CleanTab.allCases.firstIndex(of: shown) ?? 0, animated: false)
        tab = shown
        fill()
        if visible, found[shown]?.complete != true { scan([shown]) }
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

    private func showAll() {
        leftoversOf = nil
        fill()
    }

    /// The app drawer's Uninstall button: this tab, with that app's plan open.
    func showUninstall(of path: String) {
        guard review == nil else { return }
        uninstall.open(path)
        tabs.select(CleanTab.allCases.firstIndex(of: .uninstall) ?? 0, animated: false)
        if tab != .uninstall { pick(.uninstall) } else { fill() }
    }

    private func backToApps() {
        uninstall.back()
        scrollToTop()
    }

    private func quitApp() {
        uninstall.quitChosen()
    }

    // MARK: Selection

    /// The items on screen: this tab's, narrowed to one app when Leftovers was opened for it.
    private var shown: [CleanItem] {
        if tab == .uninstall { return uninstall.chosen == nil ? [] : uninstall.plan ?? [] }
        var items = found[tab]?.items ?? []
        if tab == .largeFiles {
            // A duplicate is listed once, under Duplicates, after hashing finds it.
            let duplicated = Set(items.filter { $0.group == duplicatesGroup }.flatMap(\.paths))
            if !duplicated.isEmpty { items.removeAll { $0.group != duplicatesGroup && $0.paths.allSatisfy(duplicated.contains) } }
        }
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
        for item in found.values.flatMap(\.items) + (uninstall.plan ?? []) where seen.insert(item.id).inserted && item.checkedByDefault {
            selected.insert(item.id)
        }
        let listsApps = tab == .uninstall && uninstall.chosen == nil
        list.onOpen = listsApps ? { [weak self] row in self?.openApp(row.id) } : nil
        list.onExclude = tab == .uninstall ? nil : { [weak self] item in self?.exclude(item) }
        if tab == .history {
            fillHistory()
        } else if listsApps {
            fillApps()
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
            // An uninstall plan leads with the app itself, then what it keeps, largest first.
            let leads = { (item: CleanItem) in self.tab == .uninstall && item.paths.first?.hasSuffix(".app") == true ? 1 : 0 }
            let items = groups[name]!.sorted { (leads($0), $0.bytes) > (leads($1), $1.bytes) }
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
        emptyNote.text = Theme.caption(tab == .uninstall ? "Finding what \(uninstall.chosen?.name ?? "the app") keeps on this Mac…"
                                       : !hasScanners ? "Wisp has nothing to look for on this tab yet"
                                       : scanning != nil ? "Looking…"
                                       : found[tab]?.scannedAt == nil ? "Not scanned yet"
                                       : leftoversOf != nil ? "Nothing left of \(leftoversOf!.name)"
                                       : "Nothing found", size: 12)
        emptyNote.alignment = .center
        emptyNote.isHidden = !rows.isEmpty
    }

    private func fillApps() {
        list.rows = uninstall.rows
        let filter = uninstall.filter
        emptyNote.text = Theme.caption(!filter.isEmpty && !uninstall.isScanning ? "No app matches \u{201C}\(filter)\u{201D}"
                                       : uninstall.isScanning ? "Looking…"
                                       : uninstall.listedAt == nil ? "Not scanned yet"
                                       : "No apps besides Apple's", size: 12)
        emptyNote.alignment = .center
        emptyNote.isHidden = !list.rows.isEmpty
    }

    private func openApp(_ path: String) {
        uninstall.open(path)
        scrollToTop()
        Motion.enter(listCard, from: CGPoint(x: 0, y: 6), duration: 0.2)
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
        let title = headerTitleText()
        if tab == .uninstall, let app = uninstall.chosen {
            let items = shown
            figureText = uninstall.plan == nil ? "–" : Format.bytes(UInt64(items.totalBytes))
            unitText = uninstall.plan == nil ? "" : "can go · " + (items.count == 1 ? "1 item" : "\(items.count) items")
            statusText = [app.version.map { "Version \($0)" }, uninstall.isRunning(app) ? "Running" : nil].compactMap { $0 }.joined(separator: " · ")
        } else if tab == .uninstall {
            let apps = uninstall.listedApps
            let measured = uninstall.measuredCount
            figureText = measured == 0 ? "–" : Format.bytes(UInt64(apps.reduce(0) { $0 + (uninstall.size(of: $1) ?? 0) }))
            unitText = measured == 0 ? "" : "in " + (apps.count == 1 ? "1 app" : "\(apps.count) apps")
            if uninstall.isScanning {
                statusText = uninstall.apps.isEmpty ? "Finding apps…" : "Measuring \(measured) of \(uninstall.apps.count) apps…"
            } else if !uninstall.complete, measured > 0 {
                statusText = "Stopped at \(measured) of \(uninstall.apps.count) apps"
            } else if let date = uninstall.listedAt {
                statusText = "Scanned " + StoragePage.ago(date)
            } else {
                statusText = ""
            }
        } else if tab == .history {
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
                let locked = tab == .largeFiles && !StorageAccess.hasFullDiskAccess
                statusText = (found[tab]?.complete == false ? "Stopped " : "Scanned ") + StoragePage.ago(date)
                    + (locked ? " · Some folders need Full Disk Access" : "")
            } else {
                statusText = ""
            }
        }
        headerTitle.text = title
        let text = NSMutableAttributedString(string: figureText, attributes: [.font: Theme.digits(28), .foregroundColor: A2.primary, .kern: -0.84])
        text.append(NSAttributedString(string: "  " + unitText, attributes: [.font: Theme.sans(15), .foregroundColor: A2.secondary]))
        figure.text = text
        status.text = NSAttributedString(string: statusText, attributes: [.font: Theme.digits(11.5), .foregroundColor: A2.secondary])
        if status.alignment != .right { status.alignment = .right }
        let choosing = tab == .uninstall && uninstall.chosen == nil
        let planning = tab == .uninstall && uninstall.chosen != nil
        // Set only on a change: a new title redraws the button, and this runs every update.
        let scanTitle: String
        if tab == .uninstall {
            scanButton.isHidden = planning
            scanTitle = uninstall.isScanning ? "Stop" : uninstall.complete ? "Scan Again" : "Scan"
        } else {
            scanButton.isHidden = !(tab != .history && scanners.contains { $0.tab == tab })
            scanTitle = scanning != nil ? "Stop" : found[tab]?.scannedAt == nil ? "Scan" : "Scan Again"
        }
        scanButton.title = scanTitle
        showAllButton.isHidden = !(tab == .leftovers && leftoversOf != nil)
        backButton.isHidden = !planning
        uninstall.search.isHidden = !choosing
        let homebrew = planning && uninstall.chosen?.brewToken != nil
        uninstall.removalToggle.isHidden = !homebrew
        uninstall.removalLabel.isHidden = !homebrew
        placeHeader()
    }

    private var titleCache: (key: String, title: NSAttributedString)?

    /// The tab's symbol and name, or on the Uninstall tab the chosen app's icon and name.
    /// Kept until either changes: an icon attachment never equals a new one, so a fresh
    /// title on every update would redraw the header each time.
    private func headerTitleText() -> NSAttributedString {
        let app = tab == .uninstall ? uninstall.chosen : nil
        let key = (app?.path ?? tab.rawValue) + "|" + NSApp.effectiveAppearance.name.rawValue
        if let titleCache, titleCache.key == key { return titleCache.title }
        let title = app.map(Self.appTitle) ?? Theme.header(tab.title, symbol: tab.symbol, tint: Self.labelTint)
        titleCache = (key, title)
        return title
    }

    private static func appTitle(_ app: InstalledApp) -> NSAttributedString {
        let font = Theme.sans(13, .semibold)
        let size: CGFloat = 18
        let attachment = NSTextAttachment()
        attachment.image = CleanIcons.file(app.path)
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + app.name, attributes: [.font: font, .foregroundColor: A2.primary]))
        return text
    }

    private func updateFooter() {
        let items = shown
        let ticked = items.filter { selected.contains($0.id) }
        let app = tab == .uninstall ? uninstall.chosen : nil
        let running = app.map(uninstall.isRunning) ?? false
        var line = ticked.isEmpty ? "Nothing selected" : "\(ticked.count) selected · \(Format.bytes(UInt64(ticked.totalBytes)))"
        if let app, running { line = "Quit \(app.name) to uninstall it" }
        footer.selection.text = NSAttributedString(
            string: line, attributes: [.font: Theme.digits(13, .medium), .foregroundColor: ticked.isEmpty && !running ? A2.secondary : A2.primary])
        footer.cleanButton.isEnabled = !ticked.isEmpty && review == nil && !running
        footer.safeButton.isEnabled = items.contains(where: \.isSafeTrash) && review == nil
        footer.safeButton.isHidden = tab == .uninstall
        footer.quitButton.isHidden = !running
        footer.quitButton.isEnabled = review == nil
        footer.cleanButton.title = tab == .uninstall ? "Uninstall…" : "Clean Selected…"
        footer.quitButton.title = "Quit " + (app?.name ?? "")
        footer.needsLayout = true
        view.needsLayout = true
    }

    // MARK: Cleaning

    private func cleanSelected() {
        presentReview(shown.filter { selected.contains($0.id) }, trigger: .manual)
    }

    private func cleanSafe() {
        presentReview(shown.filter(\.isSafeTrash), trigger: .manual)
    }

    private func presentReview(_ items: [CleanItem], trigger: CleanRecord.Trigger) {
        guard !items.isEmpty, review == nil else { return }
        let sheet = CleanReview(items: items)
        sheet.frame = root.bounds
        sheet.onCancel = { [weak self] in self?.dismissReview() }
        sheet.onConfirm = { [weak self] in self?.run(items, trigger: trigger) }
        if let refusal = CleanRegistry.selectionRefusal(items) { sheet.block(refusal) }
        if tab == .uninstall, let app = uninstall.chosen, uninstall.isRunning(app) { sheet.block("\(app.name) is open. Quit it, then uninstall") }
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
        uninstall.reviewClosed()
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
                    let removedPaths = Set(report.removed.flatMap(\.item.paths))
                    for tab in self.found.keys {
                        self.found[tab]?.items.removeAll { removed.contains($0.id) || $0.paths.contains(where: removedPaths.contains) }
                    }
                    self.uninstall.cleaned(removed)
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
        arrangedHeight = root.bounds.height
        headerCard.frame = NSRect(x: margin, y: y, width: inner, height: 96)
        y += 96 + gap
        // The list card reaches down to the footer, as in the mockup; a short list spreads its
        // items up to 64 pt to fill it, then leaves the rest of the card empty.
        let footerRoom = footerShown ? CleanFooter.height + gap : 0
        let room = max(120, root.bounds.height - Self.topInset - y - footerRoom - margin)
        let items = CGFloat(list.itemCount)
        let spread = items > 0 ? ((room - 32 - list.baseHeight) / items).rounded(.down) : 0
        list.itemHeight = min(64, max(CleanList.baseItemHeight, CleanList.baseItemHeight + spread))
        let listHeight = max(room, list.rows.isEmpty ? 120 : list.naturalHeight + 32)
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
        for button in [scanButton, showAllButton, backButton] where !button.isHidden {
            let width = button.naturalWidth
            button.frame = NSRect(x: right - width, y: 15, width: width, height: 26)
            right -= width + 10
        }
        let statusWidth = max(0, min(320, right - headerTitle.frame.maxX - 16))
        status.frame = NSRect(x: right - statusWidth, y: 19, width: statusWidth, height: 16)
        // The Uninstall tab keeps its filter, or the choice of Trash or Homebrew, at the end of the figure's line.
        var figureRight = 20 + width
        if !uninstall.search.isHidden {
            let fieldWidth = min(240, width / 2)
            uninstall.search.frame = NSRect(x: figureRight - fieldWidth, y: 53, width: fieldWidth, height: 26)
            figureRight -= fieldWidth + 16
        }
        if !uninstall.removalToggle.isHidden {
            let toggleWidth = uninstall.removalToggle.naturalWidth
            uninstall.removalToggle.frame = NSRect(x: figureRight - toggleWidth, y: 52, width: toggleWidth, height: 28)
            let labelWidth = uninstall.removalLabel.naturalWidth + 4
            uninstall.removalLabel.frame = NSRect(x: uninstall.removalToggle.frame.minX - 10 - labelWidth, y: 57, width: labelWidth, height: 18)
            figureRight = uninstall.removalLabel.frame.minX - 16
        }
        figure.frame = NSRect(x: 20, y: 48, width: max(0, figureRight - 20), height: 36)
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
