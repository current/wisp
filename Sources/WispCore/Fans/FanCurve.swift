import Foundation

/// Which temperature a curve follows.
public enum FanSensor: String, Codable, Sendable, CaseIterable {
    /// The hottest CPU or GPU sensor.
    case hottest
    case cpu
    case gpu

    public var title: String {
        switch self {
        case .hottest: return "Hottest"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }
}

/// Fan speed by temperature. Speeds are percent of each fan's own range, from its minimum
/// (0) to its maximum (100), so one curve fits fans with different limits. Where the curve
/// says 0 the fans go back to macOS, which on most Macs stops them when the chip is cool.
public struct FanCurve: Codable, Sendable, Equatable, Hashable {
    public struct Point: Codable, Sendable, Equatable, Hashable {
        public var celsius: Double
        public var percent: Double

        public init(_ celsius: Double, _ percent: Double) {
            self.celsius = celsius
            self.percent = percent
        }
    }

    public var name: String
    public var sensor: FanSensor
    /// Kept sorted by temperature.
    public private(set) var points: [Point]

    public static let celsiusRange: ClosedRange<Double> = 30...100

    public init(name: String, sensor: FanSensor = .hottest, points: [Point]) {
        self.name = name
        self.sensor = sensor
        self.points = Self.tidy(points)
    }

    public mutating func setPoints(_ points: [Point]) { self.points = Self.tidy(points) }

    /// Clamped to the ranges and sorted, with at most one point per degree.
    static func tidy(_ points: [Point]) -> [Point] {
        var seen = Set<Int>()
        return points.map { Point(min(max($0.celsius, celsiusRange.lowerBound), celsiusRange.upperBound), min(max($0.percent, 0), 100)) }
            .sorted { $0.celsius < $1.celsius }
            .filter { seen.insert(Int($0.celsius.rounded())).inserted }
    }

    /// The percent at `celsius`, straight between points and flat beyond the first and last.
    public func percent(at celsius: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if celsius <= first.celsius { return first.percent }
        if celsius >= last.celsius { return last.percent }
        for (low, high) in zip(points, points.dropFirst()) where celsius <= high.celsius {
            let t = (celsius - low.celsius) / (high.celsius - low.celsius)
            return low.percent + t * (high.percent - low.percent)
        }
        return last.percent
    }

    // From quietest to coolest; at every temperature each one runs at least as fast as the one
    // before. All leave the fans to macOS while the chip is cool, so none costs anything at idle.

    /// Steps in only when macOS would let the chip run hot for long.
    public static let silent = FanCurve(name: "Silent", points: [.init(72, 0), .init(82, 15), .init(90, 45), .init(95, 100)])
    public static let quiet = FanCurve(name: "Quiet", points: [.init(60, 0), .init(72, 15), .init(85, 50), .init(95, 100)])
    /// Audible under sustained load, and keeps the chip in the low 80s.
    public static let balanced = FanCurve(name: "Balanced", points: [.init(55, 0), .init(65, 20), .init(75, 45), .init(85, 75), .init(92, 100)])
    /// Holds the chip as cool as the fans allow, for long renders or builds while plugged in.
    public static let cool = FanCurve(name: "Cool", points: [.init(50, 0), .init(58, 25), .init(68, 50), .init(78, 80), .init(85, 100)])

    public static let presets: [FanCurve] = [.silent, .quiet, .balanced, .cool]
}

/// What the fans do: macOS decides, one fixed speed, or a curve.
public struct FanMode: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case auto, fixed, curve }

    public var kind: Kind
    /// For `fixed`: percent of each fan's range.
    public var percent: Double?
    public var curve: FanCurve?

    public static let auto = FanMode(kind: .auto)
    public static let max = FanMode.fixed(100)
    public static let quiet = FanMode.curve(.quiet)
    public static let balanced = FanMode.curve(.balanced)
    /// Automatic, the curve presets, then Max.
    public static let builtIn: [FanMode] = [.auto] + FanCurve.presets.map(FanMode.curve) + [.max]

    public static func fixed(_ percent: Double) -> FanMode { FanMode(kind: .fixed, percent: Swift.min(Swift.max(percent, 0), 100)) }
    public static func curve(_ curve: FanCurve) -> FanMode { FanMode(kind: .curve, curve: curve) }

    public init(kind: Kind, percent: Double? = nil, curve: FanCurve? = nil) {
        self.kind = kind
        self.percent = percent
        self.curve = curve
    }

    /// "Automatic", "Max", "60%", or the curve's name.
    public var title: String {
        switch kind {
        case .auto: return "Automatic"
        case .fixed: return (percent ?? 0) >= 100 ? "Max" : "\(Int((percent ?? 0).rounded()))%"
        case .curve: return curve?.name ?? "Curve"
        }
    }

    /// The speed the mode asks for at these temperatures, before smoothing. Nil for automatic.
    public func percent(_ temperatures: FanTemperatures) -> Double? {
        switch kind {
        case .auto: return nil
        case .fixed: return percent ?? 0
        case .curve:
            guard let curve else { return nil }
            guard let celsius = temperatures.value(curve.sensor) else { return 100 }
            return curve.percent(at: celsius)
        }
    }

    /// `auto`, `max`, a preset's name, `60%`, or the name of a saved curve.
    public static func parse(_ text: String, curves: [FanCurve]) -> FanMode? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch word {
        case "auto", "automatic", "system": return .auto
        case "max", "full": return .max
        default: break
        }
        if let preset = FanCurve.presets.first(where: { $0.name.lowercased() == word }) { return .curve(preset) }
        if word.hasSuffix("%"), let value = Double(word.dropLast()), (0...100).contains(value) { return .fixed(value) }
        return curves.first { $0.name.lowercased() == word }.map(FanMode.curve)
    }
}

public struct FanTemperatures: Codable, Sendable, Equatable {
    public var cpu: Double?
    public var gpu: Double?
    public var hottest: Double?

    public init(cpu: Double? = nil, gpu: Double? = nil, hottest: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.hottest = hottest
    }

    func value(_ sensor: FanSensor) -> Double? {
        switch sensor {
        case .hottest: return hottest
        case .cpu: return cpu ?? hottest
        case .gpu: return gpu ?? hottest
        }
    }
}

/// The owner's own curves, shared by the app and `wisp fans`.
public enum FanCurveStore {
    static var url: URL { Wisp.supportDirectory.appendingPathComponent("fan-curves.json") }

    public static func load() -> [FanCurve] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FanCurve].self, from: data)) ?? []
    }

    public static func save(_ curves: [FanCurve]) {
        guard !Wisp.readOnly, let data = try? JSONEncoder().encode(curves) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
