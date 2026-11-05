import AppKit

/// Inter, the face the approved mockups are set in, from the variable font in
/// Resources/Fonts. Its optical size follows the point size as a browser sets it,
/// so large figures get the display cut. Falls back to SF Pro if the file is missing.
enum Fonts {
    private static let opticalSize: UInt32 = 0x6F70_737A // 'opsz'
    private static let weightAxis: UInt32 = 0x7767_6874 // 'wght'
    private static var registered = false
    private static var cache: [String: NSFont] = [:]

    /// Registers the bundled fonts for this process. Call once at launch.
    static func register() {
        guard !registered, let folder = folder() else { return }
        registered = true
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// The app bundle's Resources/Fonts, or the repository's when run straight from `swift build`.
    private static func folder() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("Resources/Fonts")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static func inter(_ size: CGFloat, _ weight: NSFont.Weight = .regular, tabular: Bool = false) -> NSFont {
        let key = "\(size)|\(weight.rawValue)|\(tabular)"
        if let font = cache[key] { return font }
        let font = make(size, weight, tabular: tabular)
        cache[key] = font
        return font
    }

    private static func make(_ size: CGFloat, _ weight: NSFont.Weight, tabular: Bool) -> NSFont {
        let system = tabular ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard registered else { return system }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .name: "InterVariable",
            .variation: [NSNumber(value: weightAxis): wght(weight), NSNumber(value: opticalSize): min(32, max(14, size))],
        ]
        if tabular {
            attributes[.featureSettings] = [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                             NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        }
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size) ?? system
    }

    /// NSFont weights on Inter's 100 to 900 axis.
    private static func wght(_ weight: NSFont.Weight) -> CGFloat {
        switch weight {
        case ..<NSFont.Weight.light: return 200
        case ..<NSFont.Weight.regular: return 300
        case ..<NSFont.Weight.medium: return 400
        case ..<NSFont.Weight.semibold: return 500
        case ..<NSFont.Weight.bold: return 600
        case ..<NSFont.Weight.heavy: return 700
        default: return 800
        }
    }
}
