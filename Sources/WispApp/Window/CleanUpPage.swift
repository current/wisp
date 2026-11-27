import AppKit
import WispCore

/// Clean Up: what can go from the Mac, by tab, ticked and reviewed before anything moves.
/// Opening the page scans every tab at once, each on its own utility thread, so a tab is
/// ready by the time it is picked. Scans stop when the page is left. Results stay in
/// memory with their time until the window closes.
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
    /// The scans running now, one per tab.
    private var scanning: [CleanTab: ScanFlag] = [:]
    /// When each item was cleaned, so a scan that started before the clean does not bring it back.
    private var cleanedAt: [String: Date] = [:]
    private var leftoversOf: (id: String, name: String)?
    /// What the app named in `leftoversOf` left, found as the notification found it: a full
    /// scan leaves out folders used in the last week, which a just-deleted app's always were.
    private var leftoversOfItem: CleanItem?
    private var history: [CleanRecord]?
    private var visible = false
    private var refreshQueued = false
    private var snapshotQueued = false
    /// Set by a click on the scheduled-clean notification: review the safe items once the scan is in.
    private var scheduledPending = false
    private var review: CleanReview?

    private let tabs = Segmented(CleanTab.allCases.map(\.title))
    private let headerCard = CardView(), headerTitle = TextLine(), statePill = Pill(), status = TextLine()
    private let figure = A2.figure(), caption = TextLine()
    /// What can go split by kind, or on History what past cleans freed.
    private let bar = PartsBar(), legend = PartsLegend(), timeline = CleanTimeline(), tooltip = Tooltip()
    private var parts: [CleanPart] = []
    private let scanButton = A2PillButton(), showAllButton = A2PillButton(), backButton = A2PillButton()
    private let listCard = CardView(), list = CleanList(), note = CleanNote()
    private let footer = CleanFooter(), shelf = FooterShelf()
    private let uninstall = UninstallBrowser()
    private let root = Root()
    private static let work = DispatchQueue(label: "app.wisp.clean", qos: .utility)
    /// Tabs scan side by side.
    private static let scanWork = DispatchQueue(label: "app.wisp.clean.scan", qos: .utility, attributes: .concurrent)
    private static let snapshotWork = DispatchQueue(label: "app.wisp.clean.snapshot", qos: .utility)

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
        root.addSubview(shelf)
        root.addSubview(footer)
        view = root
        for view in [headerCard, listCard] { canvas.addSubview(view) }
        for view in [headerTitle, statePill, figure, caption, bar, legend, timeline, status, scanButton, showAllButton, backButton,
                     uninstall.search, uninstall.removalLabel, uninstall.removalToggle] as [NSView] { headerCard.addSubview(view) }
        for view in [list, note] as [NSView] { listCard.addSubview(view) }
        status.alignment = .right
        bar.onHover = { [weak self] part, rect in self?.hover(part, rect) }
        bar.onPick = { [weak self] part in self?.go(to: part) }
        legend.onPick = { [weak self] part in self?.go(to: part) }
        list.drawsVisibleOnly = true
        list.onToggle = { [weak self] ids, on in self?.toggle(ids, on) }
        uninstall.onChange = { [weak self] in self?.fill() }
        uninstall.onProgress = { [weak self] in self?.queueRefresh() }
        tabs.onChange = { [weak self] index in self?.pick(CleanTab.allCases[index]) }
        tabs.setAccessibilityLabel("Clean Up sections")
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
        shelf.isHidden = !showsFooter
        shelf.frame = NSRect(x: 0, y: footer.frame.minY - FooterShelf.fade, width: root.bounds.width, height: root.bounds.height - footer.frame.minY + FooterShelf.fade)
        let bottom = showsFooter ? CleanFooter.height + gap : 0
        if scroll.contentInsets.bottom != bottom { scroll.contentInsets.bottom = bottom }
        review?.frame = root.bounds
        super.viewDidLayout()
        if root.bounds.height != arrangedHeight { relayout() }
    }

    /// The window's height when the page was last laid out; the footer's place follows it.
    private var arrangedHeight: CGFloat = 0

    private var footerShown: Bool { tab != .history && !(tab == .uninstall && uninstall.chosen == nil) }

    // MARK: Open and close

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !visible else { return }
        visible = true
        scanAll()
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
        stopAllScans()
        uninstall.disappear()
    }

    override func update(system: SystemSnapshot) {
        // Keeps "scanned 2 min ago" true; redraws only when the words change.
        if visible, scanning[tab] == nil, !uninstall.isScanning { updateHeader() }
    }

    // MARK: Scanning

    /// The page opened: start every tab that has not finished a scan, the shown one first,
    /// and the Uninstall tab's list of apps.
    private func scanAll() {
        loadHistory()
        uninstall.appear()
        let order = [tab] + CleanRegistry.cleaningTabs.filter { $0 != tab }
        for tab in order where tab != .uninstall && found[tab]?.complete != true { scan(tab) }
        reviewScheduledIfReady()
    }

    /// A tab was picked: scan it again if its last scan was stopped.
    private func scanIfNeeded() {
        guard tab != .history else { return loadHistory() }
        guard tab != .uninstall else { return uninstall.appear() }
        if found[tab]?.complete != true { scan(tab) }
    }

    private func scan(_ tab: CleanTab) {
        guard scanners.contains(where: { $0.tab == tab }) else { return }
        stopScan(tab)
        let flag = ScanFlag()
        let started = Date()
        scanning[tab] = flag
        found[tab, default: Found()].complete = false
        found[tab]?.items = []
        let incoming = Incoming()
        let context = CleanScanContext(excluded: center.settings.exclusions, isCancelled: { flag.isSet }, found: { [weak self] batch in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scanning[tab] === flag else { return }
                    for item in batch where incoming.ids.insert(item.id).inserted && !self.cleaned(item, since: started) {
                        self.found[item.tab, default: Found()].items.append(item)
                    }
                    self.queueRefresh()
                }
            }
        })
        let scanners = self.scanners
        if tab == self.tab { fill() } else { updateHeader() }
        Self.scanWork.async { [weak self] in
            let items = CleanRegistry.scan([tab], context: context, using: scanners)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scanning[tab] === flag else { return }
                    self.scanning[tab] = nil
                    self.found[tab] = Found(items: items.filter { $0.tab == tab && !self.cleaned($0, since: started) }, scannedAt: Date(),
                                            complete: !flag.isSet)
                    self.fill()
                    self.reviewScheduledIfReady()
                }
            }
        }
    }

    /// True when `item` was cleaned after a scan that started at `start`, which may still have listed it.
    private func cleaned(_ item: CleanItem, since start: Date) -> Bool {
        cleanedAt[item.id].map { $0 >= start } ?? false
    }

    /// Opens the review of the safe items once a scheduled clean's tabs are all scanned.
    private func reviewScheduledIfReady() {
        guard scheduledPending, visible,
              CleanRegistry.safeTabs.allSatisfy({ scanning[$0] == nil && found[$0]?.complete == true }) else { return }
        scheduledPending = false
        presentReview(CleanRegistry.safeTabs.flatMap { found[$0]?.items ?? [] }.filter(\.isSafeTrash), trigger: .scheduled)
    }

    private func stopScan(_ tab: CleanTab) {
        guard let flag = scanning.removeValue(forKey: tab) else { return }
        flag.set()
        // What came in so far stays on screen; the tab scans again the next time it is shown.
        updateHeader()
    }

    private func stopAllScans() {
        for tab in Array(scanning.keys) { stopScan(tab) }
    }

    /// Ids that came in during one scan, so a batch sent twice shows once.
    private final class Incoming {
        var ids = Set<String>()
    }

    /// Saves the finished scans and the ticks for `wisp clean --explain` and the MCP server, at most
    /// once every two seconds. Tabs not scanned in this window keep what an earlier one saved.
    private func queueSnapshot() {
        guard !demo, !snapshotQueued else { return }
        snapshotQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.snapshotQueued = false
            var tabs: [String: CleanSnapshot.Tab] = [:]
            for (tab, found) in self.found where found.complete {
                if let date = found.scannedAt { tabs[tab.rawValue] = CleanSnapshot.Tab(scannedAt: date, items: found.items) }
            }
            let selected = Array(self.selected)
            Self.snapshotWork.async {
                var snapshot = CleanSnapshot.load() ?? CleanSnapshot(tabs: [:], selected: [])
                snapshot.tabs.merge(tabs) { $1 }
                snapshot.selected = selected
                snapshot.save()
            }
        }
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
        } else if scanning[tab] != nil {
            stopScan(tab)
            fill()
        } else {
            scan(tab)
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
        // Fresh scans of the safe tabs; the page's opening scan covers them when it is not on screen yet.
        if visible { CleanRegistry.safeTabs.forEach(scan) }
    }

    func show(_ shown: CleanTab) {
        tabs.select(CleanTab.allCases.firstIndex(of: shown) ?? 0, animated: false)
        tab = shown
        fill()
        if visible, found[shown]?.complete != true, scanning[shown] == nil { scan(shown) }
    }

    /// A deleted app's notification was clicked: Leftovers, only that app's.
    func showLeftovers(of bundleID: String, name: String) {
        leftoversOf = (bundleID, name)
        leftoversOfItem = nil
        let context = CleanScanContext(excluded: center.settings.exclusions)
        Self.work.async { [weak self] in
            // Stamped here, as the registry stamps a scan's items, so the cleaner can check
            // each path is still the one found.
            var item = LeftoversScanner().leftovers(forBundleID: bundleID, context: context)
            item?.stamp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.leftoversOf?.id == bundleID else { return }
                    self.leftoversOfItem = item
                    self.fill()
                }
            }
        }
        tabs.select(CleanTab.allCases.firstIndex(of: .leftovers) ?? 0, animated: false)
        tab = .leftovers
        found[.leftovers]?.complete = false
        fill()
        if visible { scan(.leftovers) }
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
        let own = items.filter { $0.ownerBundleID == leftoversOf.id }
        if own.isEmpty, let leftoversOfItem, leftoversOfItem.ownerBundleID == leftoversOf.id { return [leftoversOfItem] }
        return own
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
        queueSnapshot()
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
        parts = CleanPalette.parts(order.map { name in
            let items = groups[name]!
            return (name, name, items.totalBytes, items.filter { selected.contains($0.id) }.totalBytes, items.count, items.map(\.bytes))
        })
        let largest = Double(max(1, shown.map(\.bytes).max() ?? 1))
        var rows: [CleanList.Row] = []
        // Groups in the bar's order, largest first, so the colours run down the list as they run along the bar.
        for name in order.sorted(by: { (groups[$0]!.totalBytes, $1) > (groups[$1]!.totalBytes, $0) }) {
            // An uninstall plan leads with the app itself, then what it keeps, largest first.
            let leads = { (item: CleanItem) in self.tab == .uninstall && item.paths.first?.hasSuffix(".app") == true ? 1 : 0 }
            let items = groups[name]!.sorted { (leads($0), $0.bytes) > (leads($1), $1.bytes) }
            let ids = items.map(\.id)
            let ticked = ids.filter(selected.contains).count
            let color = CleanPalette.color(of: name, in: parts)
            rows.append(.init(kind: .heading, id: "#" + name, title: name, value: Format.bytes(UInt64(items.totalBytes)),
                              check: ticked == 0 ? .off : ticked == ids.count ? .on : .mixed, ids: ids, color: color,
                              count: items.count == 1 ? "1 item" : "\(items.count) items"))
            for item in items {
                rows.append(.init(kind: .item, id: item.id, title: item.name, detail: item.detail, value: Format.bytes(UInt64(item.bytes)),
                                  label: item.safetyLabel, labelWarns: item.removal.isPermanent,
                                  check: selected.contains(item.id) ? .on : .off, item: item,
                                  fraction: Double(item.bytes) / largest, color: color))
            }
        }
        list.rows = rows
        let hasScanners = scanners.contains { $0.tab == tab }
        if tab == .uninstall {
            list.pending = uninstall.plan == nil ? ("Finding what \(uninstall.chosen?.name ?? "the app") keeps on this Mac…", 5) : nil
        } else if scanning[tab] != nil {
            list.pending = (rows.isEmpty ? "Items appear here as Wisp finds them" : "Still looking…", rows.isEmpty ? 6 : 2)
        } else {
            list.pending = nil
        }
        if !hasScanners {
            setNote("questionmark", A2.secondary, "Nothing to look for here yet", "This version of Wisp has nothing to scan on this tab.")
        } else if tab == .uninstall {
            let name = uninstall.chosen?.name ?? "the app"
            setNote("checkmark", A2.good, "Nothing found for \(name)", "Wisp found nothing \(name) keeps on this Mac.")
        } else if found[tab]?.scannedAt == nil {
            setNote(tab.symbol, Self.labelTint, "Not scanned yet", "Scan to look through \(tab.looksIn).")
        } else if let leftoversOf {
            setNote("checkmark", A2.good, "Nothing left of \(leftoversOf.name)", "Wisp found no files \(leftoversOf.name) left behind.")
        } else if found[tab]?.complete == false {
            setNote(tab.symbol, Self.labelTint, "The scan stopped before it found anything", "Scan again to look through \(tab.looksIn).")
        } else {
            setNote("checkmark", A2.good, "Nothing to clean", "Wisp looked through \(tab.looksIn) and found nothing worth removing.")
        }
        note.isHidden = !(rows.isEmpty && list.pending == nil)
    }

    private func setNote(_ symbol: String, _ tint: NSColor, _ title: String, _ detail: String) {
        note.symbol = symbol
        note.tint = tint
        note.title = title
        note.detail = detail
    }

    private func fillApps() {
        let apps = uninstall.listedApps
        parts = CleanPalette.parts(apps.map { ($0.path, $0.name, uninstall.size(of: $0) ?? 0, nil, 1, []) }, restName: "Other apps")
        let largest = Double(max(1, apps.compactMap(uninstall.size).max() ?? 1))
        list.rows = uninstall.rows.map { row in
            var row = row
            row.fraction = Double(row.item?.bytes ?? 0) / largest
            row.color = CleanPalette.color(of: row.id, in: parts)
            return row
        }
        let filter = uninstall.filter
        let left = uninstall.apps.count - uninstall.measuredCount
        if uninstall.isScanning, filter.isEmpty {
            list.pending = uninstall.apps.isEmpty ? ("Finding apps…", 6)
                : (left == 1 ? "Measuring 1 more app…" : "Measuring \(left) more apps…", min(4, max(1, left)))
        } else {
            list.pending = nil
        }
        if !filter.isEmpty {
            setNote("magnifyingglass", A2.secondary, "No app matches \u{201C}\(filter)\u{201D}", "Try part of its name or bundle identifier.")
        } else if uninstall.listedAt == nil {
            setNote(CleanTab.uninstall.symbol, Self.labelTint, "Not scanned yet", "Scan to measure the apps on this Mac.")
        } else {
            setNote("checkmark", A2.good, "No apps besides Apple's", "Apps that come with macOS stay; there is nothing here to uninstall.")
        }
        note.isHidden = !(list.rows.isEmpty && list.pending == nil)
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
        let largest = Double(max(1, records.map(\.bytesFreed).max() ?? 1))
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
                                  value: Format.bytes(UInt64(inMonth.reduce(0) { $0 + $1.bytesFreed })),
                                  count: inMonth.count == 1 ? "1 clean" : "\(inMonth.count) cleans"))
            }
            let removed = record.items.filter(\.outcome.removed)
            let names = removed.prefix(3).map(\.name).joined(separator: ", ") + (removed.count > 3 ? " and \(removed.count - 3) more" : "")
            let stayed = record.items.count - removed.count
            let permanent = removed.contains { $0.removal.isPermanent }
            let title = removed.isEmpty ? "Nothing removed"
                : (permanent ? "Removed " : "Moved ") + (removed.count == 1 ? "1 item" : "\(removed.count) items") + (permanent ? "" : " to the Trash")
            let detail = [names, stayed > 0 ? "\(stayed) left in place" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            rows.append(.init(kind: .item, id: record.id.uuidString, title: title, detail: detail,
                              value: Format.bytes(UInt64(record.bytesFreed)),
                              label: record.date.formatted(date: .abbreviated, time: .shortened) + " · " + record.trigger.historyLabel,
                              symbol: record.trigger == .scheduled ? "calendar" : record.trigger == .cli ? "terminal.fill" : "trash.fill",
                              fraction: Double(record.bytesFreed) / largest, color: A2.up,
                              tip: ([title] + removed.prefix(12).map { "\($0.name)  \(Format.bytes(UInt64(max(0, $0.bytes))))" }
                                    + (removed.count > 12 ? ["and \(removed.count - 12) more"] : [])).joined(separator: "\n")))
        }
        parts = []
        list.rows = rows
        list.pending = history == nil ? ("Reading past cleans…", 4) : nil
        timeline.cleans = (history ?? []).sorted { $0.date < $1.date }.map { record in
            CleanTimeline.Clean(date: record.date, bytes: record.bytesFreed,
                                summary: record.items.filter(\.outcome.removed).prefix(6).map(\.name).joined(separator: ", "))
        }
        setNote(CleanTab.history.symbol, Self.labelTint, "No cleans yet",
                "What you clean here, or with wisp clean in Terminal, is listed with the space it freed.")
        note.isHidden = !(rows.isEmpty && list.pending == nil)
    }

    /// The hero's state: the figure and what it means, a pill when the state matters, and the graphic under them.
    private struct Hero {
        var figure = "–"
        var unit = ""
        var caption = NSAttributedString()
        var pill: (text: String, tone: Pill.Tone)?
        var status = ""
        var graphic = Graphic.none
        enum Graphic { case none, bar(looking: Bool), timeline }
    }

    private func updateHeader() {
        guard isViewLoaded else { return }
        var hero = Hero()
        let title = headerTitleText()
        func bytes(_ value: Int64) {
            (hero.figure, hero.unit) = DashboardView.split(Format.bytes(UInt64(max(0, value))))
        }
        func count(_ number: Int, _ one: String, _ many: String) -> String { number == 1 ? "1 \(one)" : "\(number) \(many)" }
        if tab == .uninstall, let app = uninstall.chosen {
            let items = shown
            let running = uninstall.isRunning(app)
            if uninstall.plan == nil {
                hero.caption = A2.plain("Finding what \(app.name) keeps on this Mac…")
                hero.graphic = .bar(looking: true)
            } else {
                bytes(items.totalBytes)
                hero.caption = A2.facts([.init(label: "Can go with", value: count(items.count, "item", "items"))]
                                        + (app.version.map { [.init(label: "Version", value: $0)] } ?? [])
                                        + (running ? [.init(label: "", value: "Quit it first", color: A2.warn)] : []))
                hero.graphic = parts.isEmpty ? .none : .bar(looking: false)
            }
            hero.pill = running ? ("Running", .warn) : nil
        } else if tab == .uninstall {
            let apps = uninstall.listedApps
            let measured = uninstall.measuredCount
            if measured > 0 { bytes(apps.reduce(0) { $0 + (uninstall.size(of: $1) ?? 0) }) }
            let largest = apps.first.map { [A2.Fact(label: "Largest", value: $0.name)] } ?? []
            if uninstall.isScanning {
                hero.caption = measured == 0 ? A2.plain("Finding the apps on this Mac and measuring each one…")
                    : A2.facts([.init(label: "Taken by", value: count(apps.count, "app", "apps")), .init(label: "Measured", value: "\(measured) of \(uninstall.apps.count)")])
                hero.pill = ("Measuring", .neutral)
            } else {
                if !uninstall.complete, measured > 0 {
                    hero.status = "Stopped at \(measured) of \(uninstall.apps.count) apps"
                } else if let date = uninstall.listedAt {
                    hero.status = "Scanned " + StoragePage.ago(date)
                }
                hero.caption = measured == 0 ? A2.plain("Scan to measure the apps on this Mac")
                    : A2.facts([.init(label: "Taken by", value: count(apps.count, "app", "apps"))] + largest)
            }
            hero.graphic = parts.isEmpty && !uninstall.isScanning ? .none : .bar(looking: uninstall.isScanning)
        } else if tab == .history {
            let records = history ?? []
            if !records.isEmpty { bytes(records.reduce(0) { $0 + $1.bytesFreed }) }
            if let first = records.map(\.date).min(), let last = records.map(\.date).max() {
                hero.caption = A2.facts([.init(label: "Freed in", value: count(records.count, "clean", "cleans")),
                                         .init(label: "Since", value: first.formatted(date: .abbreviated, time: .omitted)),
                                         .init(label: "Last", value: StoragePage.ago(last))])
                hero.graphic = .timeline
            } else {
                hero.caption = A2.plain(history == nil ? "Reading past cleans…" : "Nothing cleaned yet")
            }
        } else {
            let items = shown
            let hasScanners = scanners.contains { $0.tab == tab }
            let looking = scanning[tab] != nil
            if hasScanners { bytes(items.totalBytes) }
            let safe = items.filter(\.isSafeTrash).totalBytes
            let unsure = items.filter { !$0.isSafeTrash }.count
            let owner = leftoversOf.map { [A2.Fact(label: "Left by", value: $0.name)] } ?? []
            if looking {
                hero.pill = ("Scanning", .neutral)
                hero.caption = items.isEmpty ? A2.plain("Looking through \(tab.looksIn)…")
                    : A2.facts(owner + [.init(label: "Found so far in", value: count(items.count, "item", "items"))])
            } else if hasScanners, let date = found[tab]?.scannedAt {
                let locked = tab == .largeFiles && !StorageAccess.hasFullDiskAccess
                let stopped = found[tab]?.complete == false
                hero.status = (stopped ? "Stopped " : "Scanned ") + StoragePage.ago(date) + (locked ? " · Some folders need Full Disk Access" : "")
                if items.isEmpty {
                    hero.caption = A2.plain(stopped ? "The scan stopped early" : "Nothing found in \(tab.looksIn)")
                    hero.pill = stopped ? ("Stopped", .neutral) : ("All clean", .good)
                } else {
                    let largest = items.max { $0.bytes < $1.bytes }
                    let safeFact = safe > 0 ? [A2.Fact(label: "Safe to clean", value: Format.bytes(UInt64(safe)))] : []
                    hero.caption = A2.facts(owner + [.init(label: "Can go from", value: count(items.count, "item", "items"))] + safeFact
                                            + (largest.map { [.init(label: "Largest", value: $0.name)] } ?? []))
                    hero.pill = stopped ? ("Stopped", .neutral) : unsure == 0 ? ("Safe to clean", .good)
                        : unsure == items.count ? ("Check each first", .neutral) : ("\(unsure) to check first", .neutral)
                }
            } else {
                hero.caption = A2.plain(hasScanners ? "Scan to look through \(tab.looksIn)" : "Nothing to look for on this tab yet")
            }
            hero.graphic = parts.isEmpty && !looking ? .none : .bar(looking: looking)
        }
        headerTitle.text = title
        figure.show(hero.figure, unit: hero.unit)
        caption.text = hero.caption
        status.text = NSAttributedString(string: hero.status, attributes: [.font: A2.legendFont, .foregroundColor: A2.tertiary])
        statePill.isHidden = hero.pill == nil
        if let pill = hero.pill {
            statePill.text = pill.text
            statePill.tone = pill.tone
        }
        switch hero.graphic {
        case .none:
            graphic = .none
        case .bar(let looking):
            graphic = .bar
            bar.parts = parts
            bar.looking = looking
            legend.parts = parts
            legend.ghosts = parts.isEmpty ? 4 : 0
            legend.noun = tab == .uninstall && uninstall.chosen == nil ? ("app", "apps") : ("item", "items")
        case .timeline:
            graphic = .timeline
        }
        bar.isHidden = graphic != .bar
        legend.isHidden = graphic != .bar
        timeline.isHidden = graphic != .timeline
        if graphic != .bar { tooltip.hide() }
        let choosing = tab == .uninstall && uninstall.chosen == nil
        let planning = tab == .uninstall && uninstall.chosen != nil
        // Set only on a change: a new title redraws the button, and this runs every update.
        let scanTitle: String
        if tab == .uninstall {
            scanButton.isHidden = planning
            scanTitle = uninstall.isScanning ? "Stop" : uninstall.complete ? "Scan Again" : "Scan"
        } else {
            scanButton.isHidden = !(tab != .history && scanners.contains { $0.tab == tab })
            scanTitle = scanning[tab] != nil ? "Stop" : found[tab]?.scannedAt == nil ? "Scan" : "Scan Again"
        }
        scanButton.title = scanTitle
        showAllButton.isHidden = !(tab == .leftovers && leftoversOf != nil)
        backButton.isHidden = !planning
        uninstall.search.isHidden = !choosing
        let homebrew = planning && uninstall.chosen?.brewToken != nil
        uninstall.removalToggle.isHidden = !homebrew
        uninstall.removalLabel.isHidden = !homebrew
        if headerCard.frame.width > 0, heroHeight(width: headerCard.frame.width) != headerCard.frame.height {
            relayout()
        } else {
            placeHeader()
        }
    }

    private enum HeroGraphic { case none, bar, timeline }
    private var graphic = HeroGraphic.none

    private func hover(_ part: CleanPart?, _ rect: NSRect) {
        guard let part else { return tooltip.hide() }
        let total = parts.reduce(Int64(0)) { $0 + $1.bytes }
        tooltip.title = part.name
        tooltip.detail = total > 0 ? Format.percent(Double(part.bytes) / Double(total)) : ""
        let apps = tab == .uninstall && uninstall.chosen == nil
        tooltip.lines = [Tooltip.Line(color: part.color, name: "Size", value: Format.bytes(UInt64(max(0, part.bytes)))),
                         Tooltip.Line(color: nil, name: apps ? "Apps" : "Items", value: "\(part.count)")]
            + (part.ticked.map { [Tooltip.Line(color: nil, name: "Ticked", value: Format.bytes(UInt64(max(0, $0))))] } ?? [])
        tooltip.show(in: headerCard, above: bar.convert(rect, to: headerCard))
    }

    /// A slice or key was clicked: its group's rows, or on the Uninstall tab that app's plan.
    private func go(to part: CleanPart) {
        guard part.id != "#rest" else { return }
        if tab == .uninstall, uninstall.chosen == nil { return openApp(part.id) }
        guard let offset = list.offset(of: "#" + part.id) else { return }
        let target = listCard.frame.minY + list.frame.minY + offset - 12 - Self.topInset
        let limit = canvas.frame.height - scroll.contentView.bounds.height
        scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(-Self.topInset, target), max(-Self.topInset, limit))))
        scroll.reflectScrolledClipView(scroll.contentView)
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
        let stop = ScanFlag()
        sheet.onStop = { stop.set() }
        Self.work.async { [weak self] in
            var done = 0
            let report = cleaner.clean(items, isCancelled: { stop.isSet }, progress: { _ in
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
                    let now = Date()
                    for id in removed { self.cleanedAt[id] = now }
                    let removedPaths = Set(report.removed.flatMap(\.item.paths))
                    for tab in self.found.keys {
                        self.found[tab]?.items.removeAll { removed.contains($0.id) || $0.paths.contains(where: removedPaths.contains) }
                    }
                    self.uninstall.cleaned(removed)
                    self.selected.subtract(removed)
                    self.history?.append(record)
                    self.review?.finish(report)
                    self.fill()
                }
            }
        }
    }

    // MARK: Layout

    /// The hero's height: the figure and caption, then the bar and its key, or the chart of past cleans.
    private func heroHeight(width: CGFloat) -> CGFloat {
        switch graphic {
        case .none: return Self.graphicTop
        case .bar: return Self.legendTop + legend.naturalHeight(width: width - A2.padSide * 2) + 12
        case .timeline: return Self.graphicTop + 132
        }
    }

    /// Where the hero's graphic starts, under the caption, and where the bar's key starts.
    private static let graphicTop: CGFloat = 110
    private static let legendTop: CGFloat = 136

    override func arrange(width: CGFloat) -> CGFloat {
        let inner = width - margin * 2
        var y = margin
        arrangedHeight = root.bounds.height
        let heroHeight = heroHeight(width: inner)
        headerCard.frame = NSRect(x: margin, y: y, width: inner, height: heroHeight)
        y += heroHeight + gap
        // The list card fits its rows; with none, it holds the note saying why.
        let showsNote = !note.isHidden
        let listHeight = showsNote ? CleanNote.height + 24 : list.naturalHeight + 32
        listCard.frame = NSRect(x: margin, y: y, width: inner, height: listHeight)
        list.frame = NSRect(x: 20, y: 16, width: inner - 40, height: max(1, list.naturalHeight))
        note.frame = NSRect(x: 0, y: 12, width: inner, height: CleanNote.height)
        placeHeader()
        return y + listHeight + margin
    }

    private func placeHeader() {
        let width = headerCard.bounds.width - A2.padSide * 2
        guard width > 0 else { return }
        headerTitle.frame = NSRect(x: A2.padSide, y: 13, width: headerTitle.naturalWidth + 4, height: 20)
        statePill.frame = NSRect(x: headerTitle.frame.maxX + 8, y: 14, width: statePill.naturalWidth, height: 18)
        var right = A2.padSide + width
        for button in [scanButton, showAllButton, backButton] where !button.isHidden {
            let width = button.naturalWidth
            button.frame = NSRect(x: right - width, y: 10, width: width, height: 26)
            right -= width + 10
        }
        let left = statePill.isHidden ? headerTitle.frame.maxX : statePill.frame.maxX
        let statusWidth = max(0, min(340, right - left - 16))
        status.frame = NSRect(x: right - statusWidth, y: 15, width: statusWidth, height: 16)
        // The Uninstall tab keeps its filter, or the choice of Trash or Homebrew, at the end of the figure's line.
        var figureRight = A2.padSide + width
        if !uninstall.search.isHidden {
            let fieldWidth = min(240, width / 2)
            uninstall.search.frame = NSRect(x: figureRight - fieldWidth, y: 50, width: fieldWidth, height: 26)
            figureRight -= fieldWidth + 16
        }
        if !uninstall.removalToggle.isHidden {
            let toggleWidth = uninstall.removalToggle.naturalWidth
            uninstall.removalToggle.frame = NSRect(x: figureRight - toggleWidth, y: 49, width: toggleWidth, height: 28)
            let labelWidth = uninstall.removalLabel.naturalWidth + 4
            uninstall.removalLabel.frame = NSRect(x: uninstall.removalToggle.frame.minX - 10 - labelWidth, y: 54, width: labelWidth, height: 18)
            figureRight = uninstall.removalLabel.frame.minX - 16
        }
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 71, width: max(0, figureRight - A2.padSide))
        caption.frame = NSRect(x: A2.padSide, y: 82, width: max(0, figureRight - A2.padSide), height: 16)
        bar.frame = NSRect(x: A2.padSide, y: Self.graphicTop, width: width, height: 14)
        legend.frame = NSRect(x: A2.padSide - PartsLegend.inset, y: Self.legendTop, width: width + PartsLegend.inset * 2,
                              height: legend.naturalHeight(width: width))
        timeline.frame = NSRect(x: 0, y: Self.graphicTop, width: headerCard.bounds.width, height: max(40, headerCard.bounds.height - Self.graphicTop))
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
