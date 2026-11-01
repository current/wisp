import AppKit

/// The Tahoe toolbar over the page: the page's title and a subtitle on the left,
/// its controls on the right, each on a glass capsule. It has no background: the
/// page scrolls under it, as in a Tahoe window.
@MainActor
final class Toolbar: NSView {
    static let height: CGFloat = 60
    private let defaultTitle = TextLine()
    private let defaultSubtitle = TextLine()
    private var heading: (NSView, NSView)?
    private var capsules: [GlassCapsule] = []
    /// The page's name on a small glass capsule, shown once the heading has scrolled away.
    private let compactTitle = TextLine()
    private lazy var compact = GlassCapsule(content: compactTitle)
    private var scrolled: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Shows a page: its own heading views if it has them, else its name and the machine.
    func show(title: String, subtitle: String, heading custom: (NSView, NSView)?, items: [NSView]) {
        heading.map { [$0.0, $0.1].forEach { $0.removeFromSuperview() } }
        defaultTitle.removeFromSuperview()
        defaultSubtitle.removeFromSuperview()
        if let custom {
            heading = custom
        } else {
            defaultTitle.text = Self.title(title)
            // Narrow toolbars drop the model name, then the line.
            let short = subtitle.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            defaultSubtitle.variants = [subtitle, short, ""].map(Self.subtitle)
            heading = (defaultTitle, defaultSubtitle)
        }
        if let heading { addSubview(heading.0); addSubview(heading.1) }
        let name = (heading?.0 as? TextLine)?.text.string ?? (heading?.0 as? NSTextField)?.stringValue ?? title
        compactTitle.text = NSAttributedString(string: name, attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
        if compact.superview == nil { addSubview(compact) }
        scrolled = 0
        compact.alphaValue = 0
        compact.isHidden = true
        capsules.forEach { $0.removeFromSuperview() }
        capsules = items.map { GlassCapsule(content: $0) }
        capsules.forEach(addSubview)
        needsLayout = true
    }

    static func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(15, .bold), .foregroundColor: Theme.ink, .kern: -0.15])
    }

    static func subtitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary])
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 16
        for capsule in capsules.reversed() {
            let width = capsule.naturalWidth
            capsule.frame = NSRect(x: right - width, y: 13, width: width, height: 34)
            right -= width + 10
        }
        if let (title, subtitle) = heading {
            let width = max(80, right - 24 - 12)
            title.frame = NSRect(x: 24, y: 13 - scrolled, width: width, height: 19)
            subtitle.frame = NSRect(x: 24, y: 32 - scrolled, width: width, height: 14)
            // The heading belongs to the page: it scrolls away with it and fades as it goes.
            let fade = max(0, min(1, 1 - scrolled / 28))
            title.alphaValue = fade
            subtitle.alphaValue = fade
        }
        compact.frame = NSRect(x: 16, y: 13, width: min(compact.naturalWidth, max(80, right - 26)), height: 34)
    }

    /// The page scrolled to `offset` points from its top. The heading moves with the
    /// content, so nothing ever runs under it, and the compact title takes its place.
    func follow(scrolled offset: CGFloat) {
        let offset = max(0, offset)
        guard offset != scrolled else { return }
        let wasCompact = scrolled > 40
        scrolled = offset
        needsLayout = true
        let isCompact = offset > 40
        guard isCompact != wasCompact else { return }
        compact.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.2
            compact.animator().alphaValue = isCompact ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scrolled <= 40 else { return }
                self.compact.isHidden = true
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A control on a Liquid Glass capsule, as Tahoe toolbars place them.
final class GlassCapsule: NSView {
    let content: NSView
    private let surface: NSView
    private let holder = Holder()

    private final class Holder: NSView {
        override var isFlipped: Bool { true }
    }

    init(content: NSView) {
        self.content = content
        if #available(macOS 26.0, *), !Theme.solidPanels {
            let glass = NSGlassEffectView()
            glass.style = .regular
            surface = glass
        } else {
            let card = CardView()
            card.fill = Theme.card
            surface = card
        }
        super.init(frame: .zero)
        addSubview(surface)
        holder.addSubview(content)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = holder
        } else {
            surface.addSubview(holder)
        }
        (content as? Segmented)?.onGlass = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var naturalWidth: CGFloat {
        if let segmented = content as? Segmented { return segmented.naturalWidth + 2 }
        if let search = content as? NSSearchField {
            // Room for the whole placeholder: text, the magnifier and the clear button.
            let text = (search.placeholderString ?? "") as NSString
            return max(180, ceil(text.size(withAttributes: [.font: search.font ?? Theme.sans(13)]).width) + 100)
        }
        if let line = content as? TextLine { return line.naturalWidth + 30 }
        return max(34, content.fittingSize.width + 12)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        } else if let card = surface as? CardView {
            card.radius = bounds.height / 2
        }
        holder.frame = surface.bounds
        if content is Segmented {
            content.frame = bounds.insetBy(dx: 1, dy: 0)
        } else if content is TextLine {
            content.frame = NSRect(x: 15, y: (bounds.height - 17) / 2, width: bounds.width - 30, height: 17)
        } else if content is NSSearchField {
            content.frame = NSRect(x: 8, y: (bounds.height - 22) / 2, width: bounds.width - 16, height: 22)
        } else {
            content.frame = bounds.insetBy(dx: 6, dy: 3)
        }
    }
}
