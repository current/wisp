import Foundation
import Testing
@testable import WispCore

@Test func planDatesWithMicroseconds() {
    let date = PlanUsageReader.date("2026-11-03T23:10:00.130194+00:00")
    #expect(date == Date(timeIntervalSince1970: 1_793_747_400))
    #expect(PlanUsageReader.date("2026-11-10T20:00:00+00:00") != nil)
    #expect(PlanUsageReader.date(nil) == nil)
}

@Test func keychainServiceFollowsClaudeCode() {
    let home = NSHomeDirectory()
    #expect(PlanUsageReader.keychainService(for: home + "/.claude") == "Claude Code-credentials")
    let other = PlanUsageReader.keychainService(for: home + "/.claude-x")
    #expect(other.hasPrefix("Claude Code-credentials-") && other.count == "Claude Code-credentials-".count + 8)
}

@Test func emailFromIdToken() {
    // Header and signature do not matter; only the payload is read.
    let payload = Data(#"{"email":"someone@example.com"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    #expect(PlanUsageReader.jwtEmail("x." + payload + ".y") == "someone@example.com")
    #expect(PlanUsageReader.jwtEmail("nodots") == nil)
}

@Test func shortCounts() {
    #expect(Format.count(950) == "950")
    #expect(Format.count(1_240) == "1.2K")
    #expect(Format.count(48_000) == "48K")
    #expect(Format.count(611_000_000) == "611M")
    #expect(Format.count(2_400_000_000) == "2.4B")
}
