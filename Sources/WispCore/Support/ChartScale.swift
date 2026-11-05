import Foundation

public enum ChartScale {
    /// The top of a chart's scale: a round number about 1.4 times the peak, so the
    /// highest point sits near two thirds of the height, never below `minimum`.
    public static func ceiling(peak: Double, minimum: Double) -> Double {
        guard peak.isFinite else { return minimum }
        let target = max(peak * 1.4, minimum)
        guard target > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(target)))
        for step in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where target <= step * magnitude * (1 + 1e-9) {
            return step * magnitude
        }
        return 10 * magnitude
    }
}
