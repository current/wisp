import Foundation
import Testing
@testable import WispCore

@Test func uptimeLabelsUseTheLargestWholeUnit() {
    #expect(Uptime.label(20) == "up 1 min")
    #expect(Uptime.label(12 * 60) == "up 12 min")
    #expect(Uptime.label(3_600) == "up 1 hour")
    #expect(Uptime.label(5 * 3_600 + 59 * 60) == "up 5 hours")
    #expect(Uptime.label(86_400) == "up 1 day")
    #expect(Uptime.label(4 * 86_400 + 23 * 3_600) == "up 4 days")
}

@Test func bootDateIsInThePast() throws {
    let boot = try #require(Uptime.bootDate())
    #expect(boot < Date())
    #expect(boot > Date(timeIntervalSince1970: 1_600_000_000))
}

@Test func chartCeilingIsRoundAndAboveThePeak() {
    #expect(abs(ChartScale.ceiling(peak: 0.18, minimum: 0.1) - 0.3) < 1e-9)
    #expect(abs(ChartScale.ceiling(peak: 0.3, minimum: 0.1) - 0.5) < 1e-9)
    #expect(abs(ChartScale.ceiling(peak: 0, minimum: 0.1) - 0.1) < 1e-9)
    #expect(abs(ChartScale.ceiling(peak: 9.6, minimum: 1) - 15) < 1e-9)
    #expect(abs(ChartScale.ceiling(peak: 0.9, minimum: 0.1) - 1.5) < 1e-9)
    #expect(ChartScale.ceiling(peak: .nan, minimum: 0.1) == 0.1)
}
