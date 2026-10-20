import AppKit

@MainActor
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case page(PageID)
    }

    private let table = NSTableView()
    private var rows: [Row] = []
    var onSelect: ((PageID) -> Void)?
    private var wanted: PageID = .apps

    override func loadView() {
        for (title, pages) in PageID.sections {
            if let title { rows.append(.header(title)) }
            rows.append(contentsOf: pages.map { .page($0) })
        }
        table.style = .sourceList
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .default
        table.floatsGroupRows = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        table.reloadData()
        select(wanted)
    }

    func select(_ id: PageID) {
        wanted = id
        guard isViewLoaded, let index = rows.firstIndex(where: { if case .page(id) = $0 { return true } else { return false } }),
              table.selectedRow != index else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .page = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = NSTableCellView()
            let label = Style.label(title, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .page(let id):
            let cell = NSTableCellView()
            let image = NSImageView(image: NSImage(systemSymbolName: id.symbol, accessibilityDescription: nil) ?? NSImage())
            image.translatesAutoresizingMaskIntoConstraints = false
            image.contentTintColor = .controlAccentColor
            let label = Style.label(id.title)
            cell.addSubview(image)
            cell.addSubview(label)
            cell.imageView = image
            cell.textField = label
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, case .page(let id) = rows[table.selectedRow] else { return }
        onSelect?(id)
    }
}
