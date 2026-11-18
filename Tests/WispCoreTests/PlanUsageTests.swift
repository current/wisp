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

private func t3Line(_ stamp: String, instance: String, five: Double, week: Double) -> String {
    #"[\#(stamp)] NTIVE: {"provider":"claudeAgent","protocol":"claude-agent-sdk.query","kind":"protocol","providerSessionId":"provider-session:provider-instance:\#(instance):thread:t1:abc","event":{"direction":"incoming","stage":"decoded","payload":{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795031400,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":\#(five),"resetsAt":1795031400,"status":"allowed"},"seven_day":{"utilization":\#(week),"resetsAt":1795550400,"status":"allowed"}}},"session_id":"s"}}}"#
}

private func touch(_ path: String, _ date: Date) {
    try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

@Test func t3CodeLimitsPerInstance() {
    let home = scratchHome()
    let logs = home + "/.t3/userdata/logs/provider"
    let now = T3CodeLimits.date("2026-11-18T15:20:00.000Z")!
    write(#"{"providerInstances":{"claude-alt":{"driver":"claudeAgent","displayName":"Claude (alt)","config":{"homePath":"\#(home)/.claude-alt/"}},"codex":{"driver":"codex","config":{"homePath":"\#(home)/.codex-t3"}}}}"#,
          to: home + "/.t3/userdata/settings.json")
    // A tool result that quotes the event name, escaped inside a JSON string, is not an event.
    let quoted = #"[2026-11-18T15:30:00.000Z] NTIVE: {"provider":"claudeAgent","providerSessionId":"provider-session:provider-instance:claudeAgent:thread:x","event":{"payload":{"type":"user","content":"\"payload\":{\"type\":\"rate_limit_event\""}}}"#
    write([t3Line("2026-11-18T15:00:00.000Z", instance: "claudeAgent", five: 0.04, week: 0.01),
           t3Line("2026-11-18T15:10:00.000Z", instance: "claude-alt", five: 0.5, week: 0.2),
           quoted, "{partial"].joined(separator: "\n"), to: logs + "/events.a.log")
    touch(logs + "/events.a.log", now)
    // An older rotation: an older line for the main instance, and one for an instance T3 Code does not list.
    write([t3Line("2026-11-18T14:00:00.000Z", instance: "claudeAgent", five: 0.9, week: 0.9),
           t3Line("2026-11-18T14:05:00.000Z", instance: "claude-gone", five: 0.9, week: 0.9)].joined(separator: "\n"),
          to: logs + "/events.a.log.1")
    touch(logs + "/events.a.log.1", now.addingTimeInterval(-3600))
    write(t3Line("2026-11-01T00:00:00.000Z", instance: "claude-alt", five: 1, week: 1), to: logs + "/events.old.log")
    touch(logs + "/events.old.log", now.addingTimeInterval(-9 * 86_400))

    let accounts = T3CodeLimits.read(home: home, now: now)
    #expect(accounts.map(\.record.folder) == [home + "/.claude", home + "/.claude-alt"])
    #expect(accounts.first?.label == nil && accounts.last?.label == "Claude (alt)")
    let alt = accounts.last?.record
    #expect(alt?.updated == T3CodeLimits.date("2026-11-18T15:10:00.000Z"))
    #expect(alt?.windows == [.init(name: "5-hour session", used: 0.5, resets: Date(timeIntervalSince1970: 1_795_031_400)),
                             .init(name: "This week", used: 0.2, resets: Date(timeIntervalSince1970: 1_795_550_400))])
    #expect(accounts.first?.record.windows.first?.used == 0.04)
}

@Test func t3CodeLimitsJoinStatusLineFigures() {
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    let logs = home + "/.t3/userdata/logs/provider"
    let now = T3CodeLimits.date("2026-11-18T15:20:00.000Z")!
    write(#"{"oauthAccount":{"emailAddress":"me@example.com","planDisplayName":"Max"}}"#, to: home + "/.claude.json")
    write(#"{"oauthAccount":{"emailAddress":"alt@example.com"}}"#, to: home + "/.claude-alt/.claude.json")
    write(#"{"providerInstances":{"claude-alt":{"driver":"claudeAgent","displayName":"Claude (alt)","config":{"homePath":"\#(home)/.claude-alt"}}}}"#,
          to: home + "/.t3/userdata/settings.json")
    write([t3Line("2026-11-18T15:00:00.000Z", instance: "claudeAgent", five: 0.04, week: 0.01),
           t3Line("2026-11-18T15:10:00.000Z", instance: "claude-alt", five: 0.5, week: 0.2)].joined(separator: "\n"),
          to: logs + "/events.a.log")
    touch(logs + "/events.a.log", now)
    // The status line reported ~/.claude after T3 Code did, so its figures win there.
    let input = #"{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1795031400}}}"#
    ClaudeStatusLine.record(input: Data(input.utf8), folder: home + "/.claude", store: store, now: now)

    let usage = PlanUsageReader.readAll(home: home, store: store, now: now)
    #expect(usage.map(\.account) == ["alt@example.com", "me@example.com"])
    let alt = usage.first
    #expect(alt?.label == "Claude (alt)" && alt?.problem == nil)
    #expect(alt?.windows.map(\.used) == [0.5, 0.2])
    let main = usage.last
    #expect(main?.updated == now && main?.windows.map(\.used) == [0.3])
}

@Test func planUsageDecodesWithoutALabel() throws {
    let usage = try JSONDecoder().decode(PlanUsage.self, from: Data(#"{"provider":"Claude","account":"a","windows":[]}"#.utf8))
    #expect(usage.label == nil && usage.account == "a")
}

@Test func planNameFromOrganizationType() {
    #expect(PlanUsageReader.planName(organizationType: "claude_pro") == "Pro")
    #expect(PlanUsageReader.planName(organizationType: "claude_max") == "Max")
    #expect(PlanUsageReader.planName(organizationType: "team") == nil)
    #expect(PlanUsageReader.planName(organizationType: nil) == nil)
}

@Test func t3HitSurvivesTheLogGrowingPastIt() throws {
    let home = scratchHome()
    let path = home + "/events.grow.log"
    write(t3Line("2026-11-18T15:00:00.000Z", instance: "claudeAgent", five: 0.4, week: 0.1) + "\n", to: path)
    func log() -> T3CodeLimits.Log {
        let attributes = try! FileManager.default.attributesOfItem(atPath: path)
        return .init(path: path, modified: attributes[.modificationDate] as! Date, size: (attributes[.size] as! NSNumber).uint64Value)
    }
    #expect(T3CodeLimits.hits(in: log())["claudeAgent"] != nil)
    // Grow the file by more than a first read takes from its end.
    let filler = String(repeating: "[2026-11-18T15:01:00.000Z] NTIVE: {\"provider\":\"claudeAgent\",\"note\":\"filler\"}\n", count: 40_000)
    let handle = try #require(FileHandle(forWritingAtPath: path))
    handle.seekToEndOfFile()
    handle.write(Data(filler.utf8))
    try handle.close()
    #expect(log().size > T3CodeLimits.tailBytes)
    #expect(T3CodeLimits.hits(in: log())["claudeAgent"]?.windows.first?.used == 0.4)
}
