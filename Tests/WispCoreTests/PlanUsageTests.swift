import Foundation
import Testing
@testable import WispCore

/// A throwaway home folder with Claude Code and Codex folders in it.
private func scratchHome() -> String {
    let path = NSTemporaryDirectory() + "wisp-plan-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: path + "/.claude", withIntermediateDirectories: true)
    return path
}

private func write(_ text: String, to path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func settings(_ path: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: path)!) as! [String: Any]
}

@Test func statusLineCommandRoundTrips() {
    let original = #"jq -r '"[\(.model.display_name)]"' | sed "s/x/y/""#
    let command = ClaudeStatusLine.command(helper: "/Applications/Wisp.app/Contents/Helpers/wisp", folder: "/Users/a b/.claude", original: original)
    #expect(ClaudeStatusLine.parse(command) == .init(helper: "/Applications/Wisp.app/Contents/Helpers/wisp", original: original))
    let bare = ClaudeStatusLine.command(helper: "/x/wisp", folder: "/h/.claude", original: nil)
    #expect(ClaudeStatusLine.parse(bare) == .init(helper: "/x/wisp", original: nil))
    #expect(ClaudeStatusLine.parse("~/.claude/statusline.sh") == nil)
}

@Test func statusLineCommandRunsInAShell() throws {
    // The wrapped command must still run, with the same input, when the helper is gone.
    let original = #"read line; echo "got '$line'""#
    let command = ClaudeStatusLine.command(helper: "/nonexistent/wisp", folder: "/h/.claude", original: original)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", command]
    let input = Pipe(), output = Pipe()
    task.standardInput = input
    task.standardOutput = output
    try task.run()
    input.fileHandleForWriting.write(Data("hello\n".utf8))
    try input.fileHandleForWriting.close()
    task.waitUntilExit()
    #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "got 'hello'\n")
}

@Test func connectKeepsTheOldStatusLineAndDisconnectPutsItBack() {
    let home = scratchHome()
    let folder = home + "/.claude"
    write(#"{"model":"opus","statusLine":{"type":"command","command":"~/bin/line --x 'a b'","padding":2}}"#, to: folder + "/settings.json")
    let backups = URL(fileURLWithPath: home + "/backups")
    #expect(ClaudeStatusLine.state(folder: folder) == .notConnected)
    #expect(ClaudeStatusLine.connect(folder: folder, helper: "/A/wisp", backups: backups))
    #expect(ClaudeStatusLine.state(folder: folder, helper: "/A/wisp") == .connected)
    #expect(ClaudeStatusLine.state(folder: folder, helper: "/B/wisp") == .notConnected)
    var saved = settings(folder + "/settings.json")
    #expect(saved["model"] as? String == "opus")
    let line = saved["statusLine"] as! [String: Any]
    #expect(line["padding"] as? Int == 2)
    #expect(ClaudeStatusLine.parse(line["command"] as! String)?.original == "~/bin/line --x 'a b'")
    #expect(FileManager.default.fileExists(atPath: home + "/backups/claude.json"))
    // Moving the app re-points the helper without wrapping Wisp in itself.
    ClaudeStatusLine.connect(folder: folder, helper: "/B/wisp", backups: backups)
    let moved = ClaudeStatusLine.parse((settings(folder + "/settings.json")["statusLine"] as! [String: Any])["command"] as! String)
    #expect(moved == .init(helper: "/B/wisp", original: "~/bin/line --x 'a b'"))
    ClaudeStatusLine.disconnect(folder: folder)
    saved = settings(folder + "/settings.json")
    #expect((saved["statusLine"] as? [String: Any])?["command"] as? String == "~/bin/line --x 'a b'")
    #expect((saved["statusLine"] as? [String: Any])?["padding"] as? Int == 2)
}

@Test func connectWithoutAStatusLineAddsOneAndDisconnectRemovesIt() {
    let home = scratchHome()
    let folder = home + "/.claude"
    #expect(ClaudeStatusLine.connect(folder: folder, helper: "/A/wisp", backups: URL(fileURLWithPath: home + "/b")))
    #expect(ClaudeStatusLine.state(folder: folder) == .connected)
    ClaudeStatusLine.disconnect(folder: folder)
    #expect(settings(folder + "/settings.json")["statusLine"] == nil)
    // A settings file that is not JSON is left alone.
    write("{ not json", to: folder + "/settings.json")
    #expect(!ClaudeStatusLine.connect(folder: folder, helper: "/A/wisp", backups: URL(fileURLWithPath: home + "/b")))
    #expect(ClaudeStatusLine.state(folder: folder) == .unreadable)
}

@Test func statusLineInputBecomesPlanLimits() {
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    write(#"{"oauthAccount":{"emailAddress":"me@example.com","planDisplayName":"Max"}}"#, to: home + "/.claude.json")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let input = #"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800003600},"seven_day":{"used_percentage":41,"resets_at":1799990000}}}"#
    ClaudeStatusLine.record(input: Data(input.utf8), folder: home + "/.claude", store: store, now: now)
    let usage = PlanUsageReader.readAll(home: home, store: store, now: now)
    #expect(usage.count == 1)
    #expect(usage.first?.account == "me@example.com" && usage.first?.plan == "Max")
    #expect(usage.first?.windows.first == .init(name: "5-hour session", used: 0.235, resets: Date(timeIntervalSince1970: 1_800_003_600)))
    // The weekly window already reset: nothing used since.
    #expect(usage.first?.windows.last == .init(name: "This week", used: 0, resets: nil))
    // Input without limits (API key, or before the first reply) leaves the saved figures.
    ClaudeStatusLine.record(input: Data(#"{"model":{"id":"x"}}"#.utf8), folder: home + "/.claude", store: store, now: now)
    #expect(ClaudeStatusLine.read(folder: home + "/.claude", store: store)?.windows.count == 2)
}

@Test func codexLimitsFromItsSessionLog() {
    let home = scratchHome()
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    let empty = #"{"timestamp":"2026-11-04T20:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":null,"secondary":null}}}"#
    let full = #"{"timestamp":"2026-11-04T20:11:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":16.0,"window_minutes":300,"resets_at":1793841114},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1794427928},"plan_type":"plus"}}}"#
    write(full + "\n" + empty + "\n", to: home + "/.codex/sessions/2026/11/04/rollout-a.jsonl")
    write(#"{"type":"session_meta"}"# + "\n", to: home + "/.codex/sessions/2026/11/03/rollout-b.jsonl")
    let usage = PlanUsageReader.readAll(home: home, store: URL(fileURLWithPath: home + "/store"), now: now)
    #expect(usage.count == 1)
    let codex = usage.first
    #expect(codex?.provider == "Codex" && codex?.plan == "Plus" && codex?.account.hasSuffix("/.codex") == true)
    #expect(codex?.windows == [.init(name: "5-hour session", used: 0.16, resets: Date(timeIntervalSince1970: 1_793_841_114)),
                               .init(name: "This week", used: 0.03, resets: Date(timeIntervalSince1970: 1_794_427_928))])
}

@Test func shortCounts() {
    #expect(Format.count(950) == "950")
    #expect(Format.count(1_240) == "1.2K")
    #expect(Format.count(48_000) == "48K")
    #expect(Format.count(611_000_000) == "611M")
    #expect(Format.count(2_400_000_000) == "2.4B")
}
