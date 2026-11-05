import AppKit

/// Remix Icon glyphs (https://remixicon.com, version 4.8.0), drawn from their SVG path data
/// on a 24 point grid. See NOTICE for the licence.
enum RemixIcon {
    /// Symbol names with this prefix are Remix icons; everything else is an SF Symbol.
    static let prefix = "ri:"

    static func isRemix(_ symbol: String) -> Bool { symbol.hasPrefix(prefix) }

    private static var cache: [String: CGPath] = [:]

    /// The glyph's outline in a 24 by 24 box, y pointing down as in SVG.
    static func path(_ symbol: String) -> CGPath? {
        let name = String(symbol.dropFirst(prefix.count))
        if let path = cache[name] { return path }
        guard let data = pathData[name] else { return nil }
        let path = SVGPath.parse(data)
        cache[name] = path
        return path
    }

    /// Fills the glyph into `rect` in the current graphics context, which is not flipped.
    static func draw(_ symbol: String, in rect: NSRect, color: NSColor) {
        guard let path = path(symbol), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / 24, y: -rect.height / 24)
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static let pathData: [String: String] = [
        "layout-grid-line": "M21 3a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 13H4v6h7zm9 0h-7v6h7zm-9-8H4v6h7zm9 0h-7v6h7z",
        "apps-line": "M6.75 2.5A4.25 4.25 0 0 1 11 6.75V11H6.75a4.25 4.25 0 0 1 0-8.5M9 9V6.75A2.25 2.25 0 1 0 6.75 9zm-2.25 4H11v4.25A4.25 4.25 0 1 1 6.75 13m0 2A2.25 2.25 0 1 0 9 17.25V15zm10.5-12.5a4.25 4.25 0 0 1 0 8.5H13V6.75a4.25 4.25 0 0 1 4.25-4.25m0 6.5A2.25 2.25 0 1 0 15 6.75V9zM13 13h4.25A4.25 4.25 0 1 1 13 17.25zm2 2v2.25A2.25 2.25 0 1 0 17.25 15z",
        "cpu-line": "M6 18h12V6H6zm8 2h-4v2H8v-2H5a1 1 0 0 1-1-1v-3H2v-2h2v-4H2V8h2V5a1 1 0 0 1 1-1h3V2h2v2h4V2h2v2h3a1 1 0 0 1 1 1v3h2v2h-2v4h2v2h-2v3a1 1 0 0 1-1 1h-3v2h-2zM8 8h8v8H8z",
        "ram-2-line": "M2 5a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1v2a1 1 0 0 0 1 1h7.414l1-1h1.172l1 1H21a1 1 0 0 0 1-1v-2a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1zm18 11v1h-5.586l-1-1zm-9.414 0l-1 1H4v-1zM3 14V7h18v7zm2-5h2v3H5zm6 0H9v3h2zm2 0h2v3h-2zm6 0h-2v3h2z",
        "box-3-line": "m12 1l9.5 5.5v11L12 23l-9.5-5.5v-11zM5.494 7.078L12 10.844l6.506-3.766L12 3.31zM4.5 8.813v7.534L11 20.11v-7.533zM13 20.11l6.5-3.763V8.813L13 12.576z",
        "brain-line": "M9 4a2 2 0 0 1 2 2v6.827c-.894-.69-2.034-1.097-3.336-1.313l-.328 1.972c1.38.23 2.261.667 2.804 1.255c.53.574.86 1.426.86 2.759a2.5 2.5 0 0 1-5 0v-.35c.43.143.876.26 1.336.336l.328-1.972c-.743-.124-1.489-.4-2.235-.754A2.5 2.5 0 0 1 4 12.5c0-.835.208-1.492.559-1.974c.345-.476.883-.856 1.684-1.056L7 9.28V6a2 2 0 0 1 2-2m3-.646A4 4 0 0 0 5 6v1.774c-.851.342-1.549.874-2.059 1.575C2.292 10.242 2 11.335 2 12.5a4.49 4.49 0 0 0 2 3.742V17.5a4.5 4.5 0 0 0 8 2.829a4.5 4.5 0 0 0 8-2.829v-1.258a4.49 4.49 0 0 0 2-3.742c0-1.165-.292-2.258-.941-3.15c-.51-.702-1.208-1.234-2.059-1.576V6a4 4 0 0 0-7-2.646m6 13.795v.351a2.5 2.5 0 0 1-5 0c0-1.333.33-2.185.86-2.76c.543-.587 1.424-1.024 2.804-1.254l-.328-1.972c-1.302.216-2.442.623-3.336 1.313V6a2 2 0 1 1 4 0v3.28l.758.19c.8.2 1.338.58 1.683 1.056c.351.482.559 1.14.559 1.974c0 .999-.582 1.857-1.43 2.26c-.745.354-1.492.63-2.234.754l.328 1.972A9 9 0 0 0 18 17.149",
        "battery-2-line": "M11 6H7v14h10V6h-4V4h-2zM9 4V3a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v1h3a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z",
        "plug-line": "M13 18v2h6v2h-6a2 2 0 0 1-2-2v-2H8a4 4 0 0 1-4-4V7a1 1 0 0 1 1-1h3V2h2v4h4V2h2v4h3a1 1 0 0 1 1 1v7a4 4 0 0 1-4 4zm-5-2h8a2 2 0 0 0 2-2v-3H6v3a2 2 0 0 0 2 2m10-8H6v1h12zm-6 6.5a1 1 0 1 1 0-2a1 1 0 0 1 0 2",
        "hard-drive-3-line": "M4.508 2.876A1 1 0 0 1 5.5 2h13a1 1 0 0 1 .992.876l1.5 12Q21 14.938 21 15v6a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-6a1 1 0 0 1 .008-.124zM6.383 4l-1.25 10h13.734l-1.25-10zM19 16H5v4h14zm-4 1h2v2h-2zm-2 0h-2v2h2z",
        "magic-line": "M15.199 9.944a2.6 2.6 0 0 1-.79-1.55l-.403-3.083l-2.731 1.486a2.6 2.6 0 0 1-1.719.272L6.5 6.5l.57 3.056a2.6 2.6 0 0 1-.273 1.72l-1.486 2.73l3.083.403a2.6 2.6 0 0 1 1.55.79l2.138 2.257l1.336-2.807a2.6 2.6 0 0 1 1.23-1.231l2.808-1.336zm.025 5.564l-2.213 4.65a.6.6 0 0 1-.977.155l-3.542-3.739a.6.6 0 0 0-.358-.182l-5.106-.668a.6.6 0 0 1-.45-.881l2.462-4.524a.6.6 0 0 0 .063-.396L4.16 4.86a.6.6 0 0 1 .7-.7l5.062.943a.6.6 0 0 0 .397-.063l4.523-2.46a.6.6 0 0 1 .882.448l.668 5.107a.6.6 0 0 0 .182.357l3.739 3.542a.6.6 0 0 1-.155.977l-4.65 2.213a.6.6 0 0 0-.284.284m.797 1.927l1.414-1.414l4.243 4.242l-1.415 1.415z",
        "global-line": "M12 22C6.477 22 2 17.523 2 12S6.477 2 12 2s10 4.477 10 10s-4.477 10-10 10m-2.29-2.333A17.9 17.9 0 0 1 8.027 13H4.062a8.01 8.01 0 0 0 5.648 6.667M10.03 13c.151 2.439.848 4.73 1.97 6.752A15.9 15.9 0 0 0 13.97 13zm9.908 0h-3.965a17.9 17.9 0 0 1-1.683 6.667A8.01 8.01 0 0 0 19.938 13M4.062 11h3.965A17.9 17.9 0 0 1 9.71 4.333A8.01 8.01 0 0 0 4.062 11m5.969 0h3.938A15.9 15.9 0 0 0 12 4.248A15.9 15.9 0 0 0 10.03 11m4.259-6.667A17.9 17.9 0 0 1 15.973 11h3.965a8.01 8.01 0 0 0-5.648-6.667",
        "volume-up-line": "M6.603 10L10 7.22v9.56L6.603 14H3v-4zM2 16h3.889l5.294 4.332a.5.5 0 0 0 .817-.387V4.055a.5.5 0 0 0-.817-.387L5.89 8H2a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1m21-4c0 3.292-1.446 6.246-3.738 8.262l-1.418-1.418A8.98 8.98 0 0 0 21 12a8.98 8.98 0 0 0-3.155-6.844l1.417-1.418A10.97 10.97 0 0 1 23 12m-5 0a5.99 5.99 0 0 0-2.287-4.713l-1.429 1.429A4 4 0 0 1 16 12c0 1.36-.679 2.561-1.716 3.284l1.43 1.43A5.99 5.99 0 0 0 18 12",
        "bluetooth-line": "m14.312 12l4.343 4.343L12.998 22h-2v-6.686l-4.364 4.364l-1.414-1.415l5.778-5.778v-.97L5.22 5.737l1.414-1.415l4.364 4.364V2h2l5.657 5.657zm-1.314 1.515v5.657l2.828-2.829zm0-3.03l2.828-2.828l-2.828-2.829z",
        "temp-hot-line": "M8 5a4 4 0 1 1 8 0v5.255a7 7 0 1 1-8 0zm1.144 6.895a5 5 0 1 0 5.712 0L14 11.298V5a2 2 0 1 0-4 0v6.298zm1.856.231V5h2v7.126A4.002 4.002 0 0 1 12 20a4 4 0 0 1-1-7.874M12 18a2 2 0 1 0 0-4a2 2 0 0 0 0 4",
        "shut-down-line": "m6.265 3.807l1.147 1.639a8 8 0 1 0 9.176 0l1.147-1.639A9.99 9.99 0 0 1 22 12c0 5.523-4.477 10-10 10S2 17.523 2 12a9.99 9.99 0 0 1 4.265-8.193M11 12V2h2v10z",
        "folder-line": "M4 5v14h16V7h-8.414l-2-2zm8.414 0H21a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h7.414z",
        "ship-line": "M4 10.4V4a1 1 0 0 1 1-1h5V1h4v2h5a1 1 0 0 1 1 1v6.4l1.086.326a1 1 0 0 1 .683 1.2l-1.517 6.068a5 5 0 0 1-1.902-.273l1.25-5.351L12 10l-7.6 2.37l1.25 5.351a5 5 0 0 1-1.902.273l-1.516-6.068a1 1 0 0 1 .682-1.2zm2-.6L12 8l6 1.8V5H6zM4 20a5.98 5.98 0 0 0 4-1.528A5.98 5.98 0 0 0 12 20a5.98 5.98 0 0 0 4-1.528A5.98 5.98 0 0 0 20 20h2v2h-2a7.96 7.96 0 0 1-4-1.07A7.96 7.96 0 0 1 12 22a7.96 7.96 0 0 1-4-1.07A7.96 7.96 0 0 1 4 22H2v-2z",
        "sparkling-line": "M14 4.438A2.437 2.437 0 0 0 16.438 2h1.125A2.437 2.437 0 0 0 20 4.438v1.125A2.437 2.437 0 0 0 17.563 8h-1.125A2.437 2.437 0 0 0 14 5.563zM1 11a6 6 0 0 0 6-6h2a6 6 0 0 0 6 6v2a6 6 0 0 0-6 6H7a6 6 0 0 0-6-6zm3.876 1A8.04 8.04 0 0 1 8 15.124A8.04 8.04 0 0 1 11.124 12A8.04 8.04 0 0 1 8 8.876A8.04 8.04 0 0 1 4.876 12m12.374 2A3.25 3.25 0 0 1 14 17.25v1.5A3.25 3.25 0 0 1 17.25 22h1.5A3.25 3.25 0 0 1 22 18.75v-1.5A3.25 3.25 0 0 1 18.75 14z",
        "settings-3-line": "M3.34 17a10 10 0 0 1-.979-2.326a3 3 0 0 0 .003-5.347a10 10 0 0 1 2.5-4.337a3 3 0 0 0 4.632-2.674a10 10 0 0 1 5.007.003a3 3 0 0 0 4.632 2.671a10.06 10.06 0 0 1 2.503 4.336a3 3 0 0 0-.002 5.347a10 10 0 0 1-2.501 4.337a3 3 0 0 0-4.632 2.674a10 10 0 0 1-5.007-.002a3 3 0 0 0-4.631-2.672A10 10 0 0 1 3.339 17m5.66.196a5 5 0 0 1 2.25 2.77q.75.07 1.499.002a5 5 0 0 1 2.25-2.772a5 5 0 0 1 3.526-.564q.435-.614.748-1.298A5 5 0 0 1 18 12c0-1.26.47-2.437 1.273-3.334a8 8 0 0 0-.75-1.298A5 5 0 0 1 15 6.804a5 5 0 0 1-2.25-2.77q-.75-.071-1.5-.001A5 5 0 0 1 9 6.804a5 5 0 0 1-3.526.564q-.436.614-.747 1.298A5 5 0 0 1 6 12c0 1.26-.471 2.437-1.273 3.334a8 8 0 0 0 .75 1.298A5 5 0 0 1 9 17.196M12 15a3 3 0 1 1 0-6a3 3 0 0 1 0 6m0-2a1 1 0 1 0 0-2a1 1 0 0 0 0 2",
        "layout-top-line": "M21 3a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM4 10v9h16v-9zm0-2h16V5H4z",
        "palette-line": "M12 2c5.522 0 10 3.978 10 8.889a5.56 5.56 0 0 1-5.556 5.555h-1.966c-.922 0-1.667.745-1.667 1.667c0 .422.167.811.422 1.1c.267.3.434.689.434 1.122C13.667 21.256 12.9 22 12 22C6.478 22 2 17.522 2 12S6.478 2 12 2m-1.189 16.111a3.664 3.664 0 0 1 3.667-3.667h1.966A3.56 3.56 0 0 0 20 10.89C20 7.139 16.468 4 12 4a8 8 0 0 0-.676 15.972a3.65 3.65 0 0 1-.513-1.86M7.5 12a1.5 1.5 0 1 1 0-3a1.5 1.5 0 0 1 0 3m9 0a1.5 1.5 0 1 1 0-3a1.5 1.5 0 0 1 0 3M12 9a1.5 1.5 0 1 1 0-3a1.5 1.5 0 0 1 0 3",
        "notification-3-line": "M20 17h2v2H2v-2h2v-7a8 8 0 1 1 16 0zm-2 0v-7a6 6 0 0 0-12 0v7zm-9 4h6v2H9z",
        "information-line": "M12 22C6.477 22 2 17.523 2 12S6.477 2 12 2s10 4.477 10 10s-4.477 10-10 10m0-2a8 8 0 1 0 0-16a8 8 0 0 0 0 16M11 7h2v2h-2zm0 4h2v6h-2z",
        "arrow-down-s-line": "m12 13.171l4.95-4.95l1.414 1.415L12 16L5.636 9.636L7.05 8.222z",
        "arrow-left-s-line": "m10.828 12l4.95 4.95l-1.414 1.415L8 12l6.364-6.364l1.414 1.414z",
    ]
}

/// The subset of SVG path syntax the icons use: M L H V C S Q T A Z, absolute and relative.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(Array(data.utf8))
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        while let command = scanner.command(after: lastCommand) {
            let relative = command >= 97
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p
                // Further pairs after a move are lines.
                lastCommand = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastControl = nil
                continue
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p); current = p; lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return path }
                let c1 = reflect(lastControl, about: current, if: "cs", lastCommand)
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case UInt8(ascii: "t"):
                guard let p = point() else { return path }
                let c = reflect(lastControl, about: current, if: "qt", lastCommand)
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                arc(path, from: current, to: p, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep)
                current = p; lastControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, about point: CGPoint, if kinds: String, _ last: UInt8) -> CGPoint {
        guard let control, kinds.utf8.contains(last | 0x20) else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// An elliptical arc as cubic curves (SVG 1.1, appendix F.6).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                            angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { return path.addLine(to: p1) }
        let phi = angle * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, numerator / denominator))
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angleOf(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat { atan2(uy, ux) }
        let theta1 = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleOf((-x1 - cx1) / rx, (-y1 - cy1) / ry) - theta1
        if sweep, delta < 0 { delta += 2 * .pi } else if !sweep, delta > 0 { delta -= 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func onEllipse(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = theta1
        for index in 0..<segments {
            let next = t + step
            let a = onEllipse(t), b = index == segments - 1 ? p1 : onEllipse(next)
            let da = derivative(t), db = derivative(next)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t = next
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private mutating func skipSeparators() {
            while index < bytes.count, [32, 44, 9, 10, 13].contains(bytes[index]) { index += 1 }
        }

        /// The next command letter, or the previous command again when numbers follow it.
        mutating func command(after last: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (65...90).contains(byte) || (97...122).contains(byte), byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") {
                index += 1
                return byte
            }
            return last == 0 ? nil : last
        }

        /// Arc flags may be written without separators ("01").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
            defer { index += 1 }
            return bytes[index] == 49
        }

        /// SVG numbers run together: "1.5.5" is 1.5 and .5, "3-2" is 3 and -2.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            var seenDot = false, seenDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) { seenDigit = true; index += 1 }
                else if byte == 46, !seenDot { seenDot = true; index += 1 }
                else if (byte == 101 || byte == 69), seenDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                }
                else { break }
            }
            guard seenDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
