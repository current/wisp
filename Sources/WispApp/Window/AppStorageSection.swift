import AppKit
import WispCore

/// "Storage" in the app drawer: the app's bundle and every Library folder it keeps,
/// measured once when the drawer opens on it and kept for a while, with a button
/// that moves its caches to the Trash.
@MainActor
final class AppStorageSection: CardView {
    private let title = TextLine()
    private let headline = TextLine()
    private let bar = StackBar()
    private var rows: [PartRow] = []
    private let footnote = TextLine()
    private lazy var clearButton: ActionButton = {
        let button = ActionButton(title: "Clear Cache…", target: self, action: #selector(clearCache))
        button.secondary = true
        return button
    }()

    private var bundlePath: String?
    private var storage: AppStorage?
    private var measuring: String?

    private static var cache: [String: AppStorage] = [:]
    private static let keepFor: TimeInterval = 600
    private static let work = DispatchQueue(label: "app.wisp.appstorage", qos: .utility)

    private static let colors: [String: NSColor] = [
        "App": Theme.blue, "Container": Theme.indigo, "Group containers": Theme.purple, "Application Support": Theme.orange,
        "Caches": Theme.teal, "Logs": Theme.gray, "Website data": Theme.pink, "Preferences": Theme.green, "Saved Application State": Theme.yellow,
    ]
    private static let symbols: [String: String] = [
        "App": "app.fill", "Container": "shippingbox.fill", "Group containers": "square.stack.3d.up.fill",
        "Application Support": "folder.fill", "Caches": "archivebox.fill", "Logs": "doc.text.fill", "Website data": "globe",
        "Preferences": "slider.horizontal.3", "Saved Application State": "macwindow",
    ]

    override init() {
        super.init()
        radius = 14
        for view in [title, headline, bar, footnote, clearButton] as [NSView] { addSubview(view) }
        title.text = NSAttributedString(string: "Storage", attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Places the section in the drawer's content at `y` and returns where the next card goes.
    /// Shown only for apps with a bundle; measuring starts the first time an app is shown.
    func place(in content: NSView, selection: Selection?, at y: CGFloat, width: CGFloat) -> CGFloat {
        if superview !== content { content.addSubview(self) }
        var path: String?
        if case .app(let id) = selection, id.hasSuffix(".app"), FileManager.default.fileExists(atPath: id) { path = id }
        if path != bundlePath { show(path) }
        isHidden = path == nil
        guard !isHidden else { return y }
        frame = NSRect(x: 16, y: y, width: width, height: wantedHeight)
        return frame.maxY + 10
    }

    private var shownRows: Int { storage?.parts.count ?? 0 }
    private var wantedHeight: CGFloat {
        guard storage != nil else { return 76 }
        return 104 + CGFloat(shownRows) * 40 + 30 + ((storage?.cacheSize ?? 0) > 0 ? 44 : 0)
    }

    private func show(_ path: String?) {
        bundlePath = path
        storage = nil
        guard let path else { return }
        if let cached = Self.cache[path], Date().timeIntervalSince(cached.measuredAt) < Self.keepFor {
            storage = cached
            refresh()
            return
        }
        refresh()
        measure(path)
    }

    private func measure(_ path: String) {
        guard measuring != path else { return }
        measuring = path
        Self.work.async { [weak self] in
            let result = AppStorage.measure(bundlePath: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.cache[path] = result
                    if Self.cache.count > 40 { Self.cache = Self.cache.filter { Date().timeIntervalSince($0.value.measuredAt) < Self.keepFor } }
                    guard let self else { return }
                    if self.measuring == path { self.measuring = nil }
                    guard self.bundlePath == path else { return }
                    self.storage = result
                    self.refresh()
                    self.enclosingDrawer?.needsLayout = true
                }
            }
        }
    }

    private var enclosingDrawer: NSView? {
        var view = superview
        while let current = view, !(current is AppDrawer) { view = current.superview }
        return view
    }

    private func refresh() {
        guard let storage else {
            headline.text = NSAttributedString(string: "Measuring…", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.inkSecondary])
            bar.segments = []
            rows.forEach { $0.isHidden = true }
            footnote.isHidden = true
            clearButton.isHidden = true
            needsLayout = true
            return
        }
        let total = storage.total
        let text = NSMutableAttributedString(string: Format.bytes(total), attributes: [.font: Theme.figure(15, .semibold), .foregroundColor: Theme.ink])
        text.append(NSAttributedString(string: " on disk", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink]))
        headline.text = text
        let parts = storage.parts.sorted { $0.size > $1.size }
        bar.segments = parts.map { (Double($0.size) / Double(max(total, 1)), Self.colors[$0.name] ?? Theme.inkTertiary) }
        while rows.count < parts.count {
            let row = PartRow()
            addSubview(row)
            rows.append(row)
        }
        let home = NSHomeDirectory()
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= parts.count
            guard index < parts.count else { continue }
            let part = parts[index]
            let where_ = part.paths.count == 1 ? part.paths[0].replacingOccurrences(of: home, with: "~") : "\(part.paths.count) folders"
            row.set(name: part.name, note: part.locked ? "Needs Full Disk Access" : (part.name == "App" ? part.detail : where_),
                    share: part.locked || total == 0 ? "" : Format.percent(Double(part.size) / Double(total)),
                    value: part.locked ? "–" : Format.bytes(part.size),
                    symbol: Self.symbols[part.name] ?? "folder.fill", tint: Self.colors[part.name] ?? Theme.inkTertiary)
            row.showsRule = index < parts.count - 1
            row.toolTip = part.paths.joined(separator: "\n")
        }
        footnote.isHidden = false
        footnote.text = Theme.caption("Measured " + StoragePage.ago(storage.measuredAt) + " · folders in Library named after the app", size: 9)
        clearButton.isHidden = storage.cacheSize == 0
        clearButton.title = "Clean Up Cache (\(Format.bytes(storage.cacheSize)))…"
        clearButton.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 36
        title.frame = NSRect(x: 18, y: 18, width: width, height: 18)
        headline.frame = NSRect(x: 18, y: 44, width: width, height: 22)
        bar.frame = NSRect(x: 18, y: 76, width: width, height: 10)
        var y: CGFloat = 98
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: 18, y: y, width: width, height: 40)
            y += 40
        }
        footnote.frame = NSRect(x: 18, y: y + 8, width: width, height: 14)
        if !clearButton.isHidden {
            let size = clearButton.intrinsicContentSize
            clearButton.frame = NSRect(x: 18, y: y + 34, width: min(width, size.width), height: size.height)
        }
    }

    /// Removals happen on the Clean Up page, after its review.
    var onClean: (() -> Void)?

    @objc private func clearCache() { onClean?() }
}
