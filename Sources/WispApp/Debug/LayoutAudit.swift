import AppKit

/// Walks a window's views and reports layout faults a person would notice:
/// text cut short or clipped, figures squeezed, views spilling out of their card,
/// and labels lying on top of each other. Run with WISP_AUDIT=<folder>; see
/// scripts/ui-audit.sh, which runs it at several window sizes in light and dark.
/// A view that draws its own text says here what did not fit.
@MainActor
protocol SelfAuditing {
    var auditFaults: [String] { get }
}

@MainActor
enum LayoutAudit {
    struct Issue: CustomStringConvertible {
        var kind: String
        var path: String
        var frame: NSRect
        var detail: String
        var description: String {
            "\(kind)\t\(path)\t\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\t\(detail)"
        }
    }

    static func audit(_ root: NSView) -> [Issue] {
        var issues: [Issue] = []
        walk(root, path: [], into: &issues)
        return issues
    }

    private static func name(_ view: NSView) -> String {
        if let line = view as? TextLine, !line.text.string.isEmpty { return "TextLine(\(line.text.string.prefix(28)))" }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { return "\(type(of: field))(\(field.stringValue.prefix(28)))" }
        return String(describing: type(of: view))
    }

    /// Visible on screen: not hidden itself or through an ancestor, and inside the window's content.
    private static func shown(_ view: NSView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0.01 && view.bounds.width > 0 && view.bounds.height > 0
    }

    private static func walk(_ view: NSView, path: [String], into issues: inout [Issue]) {
        guard shown(view) else { return }
        let here = path + [name(view)]
        let pathText = here.suffix(4).joined(separator: " > ")
        let frame = view.convert(view.bounds, to: nil)

        if let line = view as? TextLine, !line.text.string.isEmpty {
            if line.naturalWidth > line.bounds.width + 1 {
                issues.append(Issue(kind: "truncated", path: pathText, frame: frame,
                                    detail: "needs \(Int(line.naturalWidth)) pt, has \(Int(line.bounds.width))"))
            }
            if line.naturalHeight > line.bounds.height + 1.5 {
                issues.append(Issue(kind: "clipped", path: pathText, frame: frame,
                                    detail: "needs \(Int(line.naturalHeight)) pt tall, has \(Int(line.bounds.height))"))
            }
        }
        if let field = view as? NSSearchField, let placeholder = field.placeholderString, field.stringValue.isEmpty {
            let width = (placeholder as NSString).size(withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: 13)]).width
            let room = (field.cell as? NSSearchFieldCell)?.searchTextRect(forBounds: field.bounds).width ?? field.bounds.width - 50
            if width > room + 1 {
                issues.append(Issue(kind: "truncated", path: pathText, frame: frame, detail: "placeholder needs \(Int(width)) pt, has \(Int(room))"))
            }
        } else if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty, let cell = field.cell {
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: field.bounds.height))
            if field.maximumNumberOfLines == 1 || cell.lineBreakMode == .byTruncatingTail,
               needed.width > field.bounds.width + 1 {
                issues.append(Issue(kind: "truncated", path: pathText, frame: frame,
                                    detail: "needs \(Int(needed.width)) pt, has \(Int(field.bounds.width))"))
            }
        }
        if let drawn = view as? SelfAuditing {
            for fault in drawn.auditFaults { issues.append(Issue(kind: "truncated", path: pathText, frame: frame, detail: fault)) }
        }
        if let number = view as? BigNumber, number.naturalWidth > number.bounds.width + 1 {
            issues.append(Issue(kind: "squeezed", path: pathText, frame: frame,
                                detail: "figure needs \(Int(number.naturalWidth)) pt, has \(Int(number.bounds.width))"))
        }

        // Children of a card must stay inside it.
        if view is CardView || view is GlassCapsule {
            for child in view.subviews where shown(child) {
                let outside = child.frame.insetBy(dx: 1, dy: 1)
                if !view.bounds.contains(outside), !(child is NSScrollView) {
                    issues.append(Issue(kind: "spills", path: pathText + " > " + name(child), frame: child.convert(child.bounds, to: nil),
                                        detail: "outside its card by \(spill(child.frame, view.bounds))"))
                }
            }
        }

        // Text-bearing siblings must not overlap.
        let texts = view.subviews.filter { shown($0) && ($0 is TextLine || $0 is BigNumber || $0 is Pill || $0 is NSTextField || $0 is Facts) }
        // A figure's frame is wider than what it draws; compare what is drawn.
        func inked(_ view: NSView) -> NSRect {
            guard let number = view as? BigNumber else { return view.frame }
            return NSRect(x: view.frame.minX, y: view.frame.minY, width: min(view.frame.width, number.naturalWidth), height: view.frame.height)
        }
        for (index, a) in texts.enumerated() {
            for b in texts[(index + 1)...] {
                let overlap = inked(a).intersection(inked(b))
                if !overlap.isNull, overlap.width > 2, overlap.height > 2, !isEmptyText(a), !isEmptyText(b) {
                    issues.append(Issue(kind: "overlap", path: pathText + " > " + name(a) + " & " + name(b),
                                        frame: a.convert(overlap.offsetBy(dx: -a.frame.minX, dy: -a.frame.minY), to: nil),
                                        detail: "\(Int(overlap.width))x\(Int(overlap.height)) pt"))
                }
            }
        }
        for child in view.subviews { walk(child, path: here, into: &issues) }
    }

    private static func isEmptyText(_ view: NSView) -> Bool {
        if let line = view as? TextLine { return line.text.string.isEmpty }
        if let field = view as? NSTextField { return field.stringValue.isEmpty }
        if let pill = view as? Pill { return pill.text.isEmpty }
        return false
    }

    private static func spill(_ frame: NSRect, _ bounds: NSRect) -> String {
        let values = [bounds.minX - frame.minX, frame.maxX - bounds.maxX, bounds.minY - frame.minY, frame.maxY - bounds.maxY]
        return "\(Int(values.max() ?? 0)) pt"
    }
}
