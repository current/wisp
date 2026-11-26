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

@Test func codexFoldersOnOneAccountAreOneRow() {
    let home = scratchHome()
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    write(#"{"providerInstances":{"codex":{"driver":"codex","displayName":"Codex (main)","config":{"homePath":"\#(home)/.codex-t3"}},"codex-alt":{"driver":"codex","displayName":"Codex (alt)","config":{"homePath":"\#(home)/.codex-alt"}}}}"#,
          to: home + "/.t3/userdata/settings.json")
    func session(account: String, stamp: String, five: Double) -> String {
        #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"account_scoped":true,"creator_account_id":"\#(account)"}}"# + "\n" +
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(five),"window_minutes":300,"resets_at":1793841114},"plan_type":"plus"}}}"# + "\n"
    }
    // The Codex CLI and T3 Code's main instance share a sign-in; the CLI ran last.
    write(session(account: "acct-main", stamp: "2026-11-04T20:11:00.000Z", five: 35), to: home + "/.codex/sessions/2026/11/04/rollout-a.jsonl")
    write(session(account: "acct-main", stamp: "2026-11-04T18:00:00.000Z", five: 99), to: home + "/.codex-t3/sessions/2026/11/04/rollout-b.jsonl")
    write(session(account: "acct-alt", stamp: "2026-11-04T19:00:00.000Z", five: 50), to: home + "/.codex-alt/sessions/2026/11/04/rollout-c.jsonl")
    let usage = PlanUsageReader.readAll(home: home, store: URL(fileURLWithPath: home + "/store"), now: now)
    #expect(usage.map(\.label) == ["Codex (alt)", "Codex (main)"])
    let main = usage.last
    #expect(main?.account == "~/.codex-t3" && main?.windows.first?.used == 0.35)
    #expect(usage.first?.windows.first?.used == 0.5)
}

@Test func codexLiveAnswerBeatsAnOlderLog() {
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    write(#"{"providerInstances":{"codex-alt":{"driver":"codex","displayName":"Codex (alt)","config":{"homePath":"\#(home)/.codex-alt"}}}}"#,
          to: home + "/.t3/userdata/settings.json")
    write(#"{"timestamp":"2026-11-03T20:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1793841114},"plan_type":"plus"}}}"# + "\n",
          to: home + "/.codex-alt/sessions/2026/11/03/rollout-a.jsonl")
    let answer: [String: Any] = ["accountId": "acct-alt", "rateLimits": [
        "primary": ["usedPercent": 47, "windowDurationMins": 300, "resetsAt": 1_793_810_000],
        "secondary": ["usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1_794_300_000],
        "planType": "plus"]]
    CodexLive.save(CodexLive.record(answer, folder: home + "/.codex-alt", now: now.addingTimeInterval(-30)), store: store)
    let usage = PlanUsageReader.readAll(home: home, store: store, now: now)
    #expect(usage.count == 1 && usage.first?.label == "Codex (alt)" && usage.first?.plan == "Plus")
    #expect(usage.first?.windows == [.init(name: "5-hour session", used: 0.47, resets: Date(timeIntervalSince1970: 1_793_810_000)),
                                     .init(name: "This week", used: 0.10, resets: Date(timeIntervalSince1970: 1_794_300_000))])
    #expect(usage.first?.updated == now.addingTimeInterval(-30))
}

@Test func antigravityQuotaPoolsBecomeWindows() {
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let status: [String: Any] = ["userStatus": [
        "email": "me@example.com",
        "userTier": ["name": "Google AI Ultra"],
        "planStatus": ["planInfo": ["planName": "Pro"]],
        "cascadeModelConfigData": ["clientModelConfigs": [
            ["label": "Gemini 4 Neon (High)", "modelId": "gemini-4-neon-high",
             "quotaInfo": ["remainingFraction": 0.75, "resetTime": "2026-11-18T14:00:00Z"]],
            ["label": "Orchestrator (Neon)", "modelId": "gemini-pro-orchestrator-neon",
             "quotaInfo": ["remainingFraction": 0.75, "resetTime": "2026-11-18T14:00:00Z"]],
            ["label": "Claude Opus 4.6 (Thinking)", "modelId": "claude-opus-4-6-thinking",
             "quotaInfo": ["resetTime": "2026-11-18T15:00:00Z"]],
            ["label": "GPT-OSS 120B (Medium)", "modelId": "gpt-oss-120b-medium",
             "quotaInfo": ["resetTime": "2026-11-18T15:00:00Z"]],
            ["label": "No quota", "modelId": "x"],
        ]],
    ]]
    AntigravityLive.save(AntigravityLive.record(status, now: now)!, store: store)
    let usage = PlanUsageReader.readAll(home: home, store: store, now: now)
    #expect(usage.count == 1)
    #expect(usage.first?.provider == "Antigravity" && usage.first?.account == "me@example.com" && usage.first?.plan == "Ultra")
    #expect(usage.first?.windows.map(\.name) == ["5-hour Gemini", "5-hour Claude and GPT-OSS"])
    #expect(usage.first?.windows.map(\.used) == [0.25, 1])
}

@Test func antigravityQuotaSummaryHasFourLimits() {
    let bucket = { (id: String, window: String, remaining: Double, resets: String) -> [String: Any] in
        ["bucketId": id, "window": window, "remainingFraction": remaining, "resetTime": resets]
    }
    // As the server sends it: each group's weekly bucket first.
    let summary: [String: Any] = ["response": ["groups": [
        ["displayName": "Gemini Models", "buckets": [
            bucket("gemini-weekly", "weekly", 0.99, "2026-11-30T20:09:34Z"),
            bucket("gemini-5h", "5h", 0.75, "2026-11-24T01:09:34Z"),
        ]],
        ["displayName": "Claude and GPT models", "buckets": [
            bucket("3p-weekly", "weekly", 1, "2026-11-30T20:47:32Z"),
            bucket("3p-5h", "5h", 0.5, "2026-11-24T01:47:32Z"),
        ]],
    ]]]
    let windows = AntigravityLive.windows(summary)
    #expect(windows?.map(\.name) == AntigravityLive.limits.map(\.name))
    #expect(windows?.map(\.used) == [0.25, 1 - 0.99, 0.5, 0])
    #expect(windows?.first?.resets == ISO8601DateFormatter().date(from: "2026-11-24T01:09:34Z"))
    #expect(AntigravityLive.windows(["response": [:]]) == nil)
}

@Test func shortCounts() {
    #expect(Format.count(950) == "950")
    #expect(Format.count(1_240) == "1.2K")
    #expect(Format.count(48_000) == "48K")
    #expect(Format.count(611_000_000) == "611M")
    #expect(Format.count(2_400_000_000) == "2.4B")
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

// MARK: Claude Code's own answer

private func iso(_ text: String) -> Date { LiveCheck.date(text)! }

@Test func claudeUsageAnswerBecomesWindows() {
    let usage: [String: Any] = [
        "subscription_type": "max", "rate_limits_available": true,
        "rate_limits": ["five_hour": NSNull(), "limits": [
            ["kind": "weekly_all", "percent": 19, "resets_at": "2026-12-01T19:59:59.778268+00:00", "is_active": true],
            ["kind": "session", "percent": 42.5, "resets_at": "2026-11-26T20:00:00Z", "is_active": true],
            ["kind": "weekly_scoped", "percent": 3, "resets_at": "2026-12-01T20:00:00+00:00", "is_active": false,
             "scope": ["model": ["display_name": "Fable"]]],
            ["kind": "weekly_scoped", "percent": 0, "resets_at": "2026-12-01T20:00:00+00:00", "is_active": false,
             "scope": ["model": ["display_name": "Sonnet"]]],
            ["kind": "something_new", "percent": 50],
        ]],
    ]
    let answer = ClaudeLive.answer(usage)!
    #expect(answer.plan == "Max" && answer.available)
    #expect(answer.windows == [
        .init(name: "5-hour session", used: 0.425, resets: iso("2026-11-26T20:00:00Z")),
        .init(name: "This week", used: 0.19, resets: iso("2026-12-01T19:59:59Z")),
        .init(name: "Fable this week", used: 0.03, resets: iso("2026-12-01T20:00:00Z")),
    ])
}

@Test func claudeUsageFromTheFixedFieldsAndBeforeASession() {
    let usage: [String: Any] = ["subscription_type": "pro", "rate_limits_available": true, "rate_limits": [
        "five_hour": NSNull(),
        "seven_day": ["utilization": 8, "resets_at": "2026-12-01T01:00:00.221712+00:00"],
        "seven_day_sonnet": ["utilization": 0, "resets_at": "2026-12-01T01:00:00Z"],
    ]]
    let answer = ClaudeLive.answer(usage)!
    #expect(answer.plan == "Pro")
    // No 5-hour figure before the first reply of a session: none of it is used yet.
    #expect(answer.windows == [.init(name: "5-hour session", used: 0, resets: nil),
                               .init(name: "This week", used: 0.08, resets: iso("2026-12-01T01:00:00Z"))])
}

@Test func claudeWithoutPlanLimitsIsUnavailable() {
    let answer = ClaudeLive.answer(["subscription_type": NSNull(), "rate_limits_available": false, "rate_limits": NSNull()])
    #expect(answer?.available == false && answer?.windows.isEmpty == true)
    // Limits that claude.ai did not send this time are a failed check, not a signed-out account.
    #expect(ClaudeLive.answer(["subscription_type": "max", "rate_limits_available": true, "rate_limits": NSNull()]) == nil)
    #expect(ClaudeLive.answer(["subscription_type": "max", "rate_limits_available": true, "rate_limits": ["five_hour": NSNull()]]) == nil)
}

@Test func claudeUsageTextIsReadWhenTheRequestIsUnknown() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 15))!
    let text = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 12% used · resets 1:59pm (America/Chicago)
    Current week (all models): 8% used · resets Nov 30 at 7pm (America/Chicago)
    Current week (Sonnet only): 0% used · resets Nov 30 at 7pm (America/Chicago)
    Current week (Fable): 4% used · resets Dec 1 at 7:30pm (America/Chicago)

    What's contributing to your usage?
    """
    let windows = ClaudeLive.windows(text: text, now: now)
    #expect(windows.map(\.name) == ["5-hour session", "This week", "Fable this week"])
    #expect(windows.map(\.used) == [0.12, 0.08, 0.04])
    #expect(windows[0].resets == calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 13, minute: 59)))
    #expect(windows[1].resets == calendar.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 19)))
    #expect(windows[2].resets == calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 19, minute: 30)))
    // A time earlier than now is tomorrow's; a date already past is next year's.
    #expect(ClaudeLive.resetDate("8am (America/Chicago)", now: now) == calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 8)))
    #expect(ClaudeLive.resetDate("Jan 2 at 9am (America/Chicago)", now: now) == calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9)))
    #expect(ClaudeLive.windows(text: "Nothing here", now: now).isEmpty)
}

@Test func claudeAnswerJoinsTheStatusLineAndNamesFromT3Code() {
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    write(#"{"oauthAccount":{"emailAddress":"me@example.com"}}"#, to: home + "/.claude.json")
    write(#"{"oauthAccount":{"emailAddress":"alt@example.com"}}"#, to: home + "/.claude-alt/.claude.json")
    write(#"{"oauthAccount":{"emailAddress":"gone@example.com"}}"#, to: home + "/.claude-gone/.claude.json")
    write(#"{"providerInstances":{"claude-alt":{"driver":"claudeAgent","displayName":"Claude (alt)","config":{"homePath":"\#(home)/.claude-alt"}}}}"#,
          to: home + "/.t3/userdata/settings.json")
    // ~/.claude: the status line ran after Claude Code last answered, so its figures win,
    // and the model's weekly limit only the answer has stays beside them.
    ClaudeLive.save(.init(folder: home + "/.claude", updated: now.addingTimeInterval(-120), plan: "Max",
                          windows: [.init(name: "5-hour session", used: 0.1, resets: nil), .init(name: "This week", used: 0.2, resets: nil),
                                    .init(name: "Fable this week", used: 0.05, resets: nil)], available: true), store: store)
    ClaudeStatusLine.record(input: Data(#"{"rate_limits":{"five_hour":{"used_percentage":30},"seven_day":{"used_percentage":21}}}"#.utf8),
                            folder: home + "/.claude", store: store, now: now.addingTimeInterval(-60))
    ClaudeLive.save(.init(folder: home + "/.claude-alt", updated: now, plan: "Pro",
                          windows: [.init(name: "This week", used: 0.5, resets: nil)], available: true), store: store)
    // Signed out since its status line last ran: not shown.
    ClaudeStatusLine.record(input: Data(#"{"rate_limits":{"five_hour":{"used_percentage":30}}}"#.utf8),
                            folder: home + "/.claude-gone", store: store, now: now.addingTimeInterval(-600))
    ClaudeLive.save(.init(folder: home + "/.claude-gone", updated: now, plan: nil, windows: [], available: false), store: store)

    let usage = PlanUsageReader.readAll(home: home, store: store, now: now)
    #expect(usage.map(\.account) == ["alt@example.com", "me@example.com"])
    #expect(usage[0].label == "Claude (alt)" && usage[0].plan == "Pro" && usage[0].windows.map(\.used) == [0.5])
    #expect(usage[1].plan == "Max" && usage[1].updated == now.addingTimeInterval(-60))
    #expect(usage[1].windows.map(\.name) == ["5-hour session", "This week", "Fable this week"])
    #expect(usage[1].windows.map(\.used) == [0.3, 0.21, 0.05])
}

@Test func claudeChecksAskSignedInFoldersAndSpaceThemOut() {
    LiveCheck.forgetFailures()
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    write(#"{"oauthAccount":{"emailAddress":"me@example.com"}}"#, to: home + "/.claude.json")
    write(#"{"oauthAccount":{"emailAddress":"alt@example.com"}}"#, to: home + "/.claude-alt/.claude.json")
    write(#"{"projects":{}}"#, to: home + "/.claude-api/.claude.json")
    var asked: [String] = []
    let week = ClaudeLive.Answer(plan: "Max", windows: [.init(name: "This week", used: 0.2, resets: nil)], available: true)
    func check(_ now: Date, paced: Bool = false, answer: ClaudeLive.Answer? = nil) {
        ClaudeLive.check(home: home, store: store, maxAge: 300, paced: paced, now: now) { _, folder in
            asked.append((folder as NSString).lastPathComponent)
            return answer ?? week
        }
    }
    let start = Date(timeIntervalSince1970: 1_795_000_000)
    check(start)
    #expect(asked.sorted() == [".claude", ".claude-alt"])
    asked = []
    check(start.addingTimeInterval(60))
    #expect(asked.isEmpty)
    // Unchanged: the timer's next check waits 10 minutes, a look only 5.
    check(start.addingTimeInterval(301))
    #expect(asked.count == 2 && ClaudeLive.saved(folder: home + "/.claude", store: store)?.unchanged == 1)
    asked = []
    check(start.addingTimeInterval(301 + 400), paced: true)
    #expect(asked.isEmpty)
    check(start.addingTimeInterval(301 + 400))
    #expect(asked.count == 2)
    // A question with no answer waits ten minutes, and keeps the last figures.
    asked = []
    ClaudeLive.check(home: home, store: store, maxAge: 0, paced: false, now: start.addingTimeInterval(2000)) { _, folder in
        asked.append(folder)
        return nil
    }
    #expect(asked.count == 2)
    check(start.addingTimeInterval(2100))
    #expect(asked.count == 2)
    #expect(ClaudeLive.saved(folder: home + "/.claude", store: store)?.windows.first?.used == 0.2)
    LiveCheck.forgetFailures()
}

// MARK: Antigravity's CLI

private let agyAnswer = #"""
{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t99%\t2026-12-03T07:25:57Z\nGemini Models\tFive Hour Limit Remaining\t98%\t2026-11-26T18:25:41Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t1970-01-01T00:00:00Z\nClaude and GPT models\tFive Hour Limit Remaining\t50%\t2026-11-26T19:00:00Z\n","usage":{"total_tokens":0},"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.99,"reset_time":"2026-12-03T07:25:57Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.98,"reset_time":"2026-11-26T18:25:41Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},{"id":"3p-5h","window":"5h","remaining_fraction":0.5,"reset_time":"2026-11-26T19:00:00Z"}]}]}}}
"""#

@Test func antigravityCLIAnswerHasFourLimits() throws {
    let json = try JSONSerialization.jsonObject(with: Data(agyAnswer.utf8)) as! [String: Any]
    let windows = AntigravityLive.cliWindows(json)
    #expect(windows?.map(\.name) == AntigravityLive.limits.map(\.name))
    #expect(windows?.map { ($0.used * 100).rounded() } == [2, 1, 50, 0])
    // A limit not started yet comes with the Unix epoch as its reset.
    #expect(windows?.last?.resets == nil && windows?.first?.resets == iso("2026-11-26T18:25:41Z"))
    // Without the structured part, the tab-separated lines say the same.
    var text = json
    text["command"] = nil
    #expect(AntigravityLive.cliWindows(text) == windows)
}

@Test func antigravityRefreshAsksTheCLIAndNamesTheAccount() {
    LiveCheck.forgetFailures()
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    write(#"{"active":"me@example.com","old":[]}"#, to: home + "/.gemini/google_accounts.json")
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let windows: [ClaudeStatusLine.Record.Window] = [.init(name: "5-hour Gemini", used: 0.25, resets: nil)]
    var asked = 0
    AntigravityLive.refresh(home: home, store: store, maxAge: 300, now: now) { _ in asked += 1; return windows }
    AntigravityLive.refresh(home: home, store: store, maxAge: 300, now: now.addingTimeInterval(60)) { _ in asked += 1; return windows }
    #expect(asked == 1)
    let usage = PlanUsageReader.readAll(home: home, store: store, now: now)
    #expect(usage.count == 1 && usage.first?.provider == "Antigravity" && usage.first?.account == "me@example.com")
    #expect(usage.first?.windows.map(\.used) == [0.25])
    LiveCheck.forgetFailures()
}

// MARK: Shared

@Test func checksWaitLongerWhileFiguresStayTheSame() {
    #expect(LiveCheck.interval(maxAge: 300, unchanged: 0, paced: true) == 300)
    #expect(LiveCheck.interval(maxAge: 300, unchanged: 1, paced: true) == 600)
    #expect(LiveCheck.interval(maxAge: 300, unchanged: 2, paced: true) == 1200)
    #expect(LiveCheck.interval(maxAge: 300, unchanged: 9, paced: true) == 1800)
    #expect(LiveCheck.interval(maxAge: 300, unchanged: 9, paced: false) == 300)
    #expect(LiveCheck.interval(maxAge: .infinity, unchanged: 0, paced: true) == .infinity)
    let a: [ClaudeStatusLine.Record.Window] = [.init(name: "This week", used: 0.2, resets: Date(timeIntervalSince1970: 1000))]
    let b: [ClaudeStatusLine.Record.Window] = [.init(name: "This week", used: 0.202, resets: Date(timeIntervalSince1970: 1001))]
    #expect(LiveCheck.unchanged(previous: a, count: 2, next: b) == 3)
    #expect(LiveCheck.unchanged(previous: a, count: 2, next: [.init(name: "This week", used: 0.3, resets: nil)]) == 0)
    #expect(LiveCheck.unchanged(previous: nil, count: nil, next: a) == 0)
}

@Test func checksRunWithoutAnotherAccountsSettings() {
    setenv("CLAUDE_CONFIG_DIR", "/elsewhere", 1)
    setenv("ANTHROPIC_API_KEY", "x", 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR"); unsetenv("ANTHROPIC_API_KEY") }
    let plain = LiveCheck.environment(home: "/Users/me")
    #expect(plain["CLAUDE_CONFIG_DIR"] == nil && plain["ANTHROPIC_API_KEY"] == nil && plain["HOME"] == "/Users/me")
    #expect(plain["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    #expect(LiveCheck.environment(setting: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-alt"], home: "/Users/me")["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-alt")
}

@Test func programsAreReadLineByLineAndStoppedInTime() {
    let found: String? = LiveCheck.run("/bin/sh", ["-c", "echo one; echo '{\"a\":2}'; sleep 30"], environment: LiveCheck.environment(), timeout: 10) { line in
        LiveCheck.json(line).map { "\($0["a"] ?? "")" }
    }
    #expect(found == "2")
    let start = Date()
    let none: String? = LiveCheck.run("/bin/sh", ["-c", "sleep 30"], environment: LiveCheck.environment(), timeout: 1) { _ in "x" }
    #expect(none == nil && Date().timeIntervalSince(start) < 5)
    // The last line counts without its newline.
    let last: String? = LiveCheck.run("/usr/bin/printf", ["tail"], environment: LiveCheck.environment(), timeout: 5) { String(data: $0, encoding: .utf8) }
    #expect(last == "tail")
}

@Test func oldT3AndSSHFilesAreRemoved() {
    let home = scratchHome()
    let store = URL(fileURLWithPath: home + "/store")
    for name in ["t3-logs.json", "remote-devbox.json", "live-codex.json", "claude.json"] { write("{}", to: store.path + "/" + name) }
    PlanUsageReader.removeRetiredFiles(store: store)
    #expect(Set((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []) == ["live-codex.json", "claude.json"])
}

private func usageLine(_ date: Date, id: String, input: Int, output: Int = 0) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return #"{"type":"assistant","timestamp":"\#(iso.string(from: date))","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
}

private func append(_ text: String, to path: String) throws {
    let handle = try #require(FileHandle(forWritingAtPath: path))
    handle.seekToEndOfFile()
    handle.write(Data(text.utf8))
    try handle.close()
}

@Test func tokenCounterReadsOnlyWhatALogGained() throws {
    let root = scratchHome() + "/.claude/projects"
    let path = root + "/project/session.jsonl"
    let now = Date()
    let yesterday = now.addingTimeInterval(-2 * 86_400)
    write(usageLine(yesterday, id: "old", input: 1000) + "\n" + usageLine(now, id: "a", input: 10, output: 5) + "\n", to: path)
    let counter = TokenCounter(roots: [root])
    #expect(counter.today(now: now) == 15)
    // A reply repeated on a second line counts once; a line still being written waits.
    try append(usageLine(now, id: "a", input: 10, output: 5) + "\n" + usageLine(now, id: "b", input: 7), to: path)
    #expect(counter.today(now: now) == 15)
    try append("\n", to: path)
    #expect(counter.today(now: now) == 22)
    // Replaced by a shorter file: read again from the top.
    write(usageLine(now, id: "c", input: 3) + "\n", to: path)
    #expect(counter.today(now: now) == 25)
}

@Test func tokenCounterFindsNewLogsOnItsNextWalk() {
    let root = scratchHome() + "/.claude/projects"
    let now = Date()
    write(usageLine(now, id: "a", input: 4) + "\n", to: root + "/one/a.jsonl")
    let counter = TokenCounter(roots: [root], walkEvery: 300)
    #expect(counter.today(now: now) == 4)
    write(usageLine(now, id: "b", input: 6) + "\n", to: root + "/two/b.jsonl")
    #expect(counter.today(now: now.addingTimeInterval(60)) == 4)
    #expect(counter.today(now: now.addingTimeInterval(301)) == 10)
}

@Test func tokenCounterStartsAgainAtMidnight() throws {
    let root = scratchHome() + "/.claude/projects"
    let path = root + "/project/session.jsonl"
    let now = Date()
    write(usageLine(now, id: "a", input: 9) + "\n", to: path)
    let counter = TokenCounter(roots: [root])
    #expect(counter.today(now: now) == 9)
    let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 3600)
    #expect(counter.today(now: tomorrow) == 0)
    try append(usageLine(tomorrow, id: "b", input: 2) + "\n", to: path)
    #expect(counter.today(now: tomorrow) == 2)
}

@Test func fileCacheReadsAgainOnlyWhenTheFileChanges() {
    let path = scratchHome() + "/settings.json"
    write("one", to: path)
    var reads = 0
    func read() -> String { FileCache.value(path, kind: "test") { reads += 1; return String(decoding: FileManager.default.contents(atPath: path)!, as: UTF8.self) } }
    #expect(read() == "one")
    #expect(read() == "one")
    #expect(reads == 1)
    write("three", to: path)
    #expect(read() == "three")
    #expect(reads == 2)
}

@Test func codexFreePlansThirtyDayLimitIsMonthly() {
    #expect(PlanUsageReader.windowName(minutes: 300) == "5-hour session")
    #expect(PlanUsageReader.windowName(minutes: 10_080) == "This week")
    #expect(PlanUsageReader.windowName(minutes: 43_200) == "This month")
    #expect(PlanUsageReader.windowName(minutes: 1_440) == nil)
    let answer: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 17, "windowDurationMins": 43_200, "resetsAt": 1_797_000_000],
                                                "planType": "free"]]
    let record = CodexLive.record(answer, folder: "/h/.codex-alt", now: Date(timeIntervalSince1970: 1_795_000_000))
    #expect(record.windows.map(\.name) == ["This month"] && record.plan == "Free")
}
