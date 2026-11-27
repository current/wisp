import Foundation
import WispCore

/// A Model Context Protocol server over stdin and stdout, one JSON-RPC message per
/// line. Every tool reads, except one that asks the owner to quit an app; Wisp
/// shows the question and nothing quits unless they agree.
final class MCPServer {
    private struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        var readOnly = true
        var request: (([String: Any]) -> LocalRequest)?
        /// Answered in this process from files on disk, without the app.
        var local: (([String: Any]) -> Data)?
    }

    private let tools: [Tool] = [
        Tool(name: "system_status",
             description: "CPU, memory, disk, network, GPU, power, temperature and battery right now, plus the five busiest apps.",
             properties: [:], required: []) { _ in LocalRequest(command: "status") },
        Tool(name: "top_apps",
             description: "Apps with their helper processes grouped together, ranked by CPU, memory, energy, disk or network. CPU is percent of one core.",
             properties: ["sort": ["type": "string", "enum": ["cpu", "memory", "energy", "disk", "network"]],
                          "limit": ["type": "integer", "minimum": 1, "maximum": 100]],
             required: []) { LocalRequest(command: "apps", limit: $0["limit"] as? Int, sort: $0["sort"] as? String) },
        Tool(name: "app_details",
             description: "One app by name or bundle id: every process in it and its CPU and memory for the last hour, one value per minute.",
             properties: ["name": ["type": "string", "description": "App name or bundle id, e.g. \"Google Chrome\" or \"com.google.Chrome\""]],
             required: ["name"]) { LocalRequest(command: "app", argument: $0["name"] as? String) },
        Tool(name: "dev_servers",
             description: "The user's processes listening on TCP ports, grouped by project folder, with connection counts and how long each has been idle.",
             properties: [:], required: []) { _ in LocalRequest(command: "ports") },
        Tool(name: "coding_agents",
             description: "Running coding agents (Claude Code, Codex, Cursor Agent, Gemini CLI, Aider, OpenCode...) and every process each one started.",
             properties: [:], required: []) { _ in LocalRequest(command: "agents") },
        Tool(name: "docker_containers",
             description: "Running Docker containers with image, published ports, CPU and memory.",
             properties: [:], required: []) { _ in LocalRequest(command: "docker") },
        Tool(name: "recent_alerts",
             description: "Alerts Wisp raised recently: apps that pinned the CPU, kept growing in memory, or wrote or downloaded heavily.",
             properties: [:], required: []) { _ in LocalRequest(command: "alerts") },
        Tool(name: "storage_summary",
             description: "Startup disk space by kind (apps, developer, documents, mail, system data, purgeable, free), what System Data holds, developer caches and build folders with sizes, what could go to the Trash, local snapshots and SSD health. Folder sizes come from the last scan the Wisp app saved.",
             properties: [:], required: [], local: { _ in Report.json(StorageReport.current()) }),
        Tool(name: "list_cleanable",
             description: "The rows of Wisp's Clean Up page: caches, logs, build output, git worktrees, large files and leftovers of deleted apps, by tab, each with its id, paths, size, safety label (safe, or check first) and origin (what made it, the project or repository it belongs to, a worktree's branch). When the Clean Up page scanned in the last day, these are the rows the user sees, with scannedAt on each tab and the ids they ticked in selected. Lists only; nothing is removed. To answer where one row comes from, call explain_cleanable.",
             properties: ["tab": ["type": "string", "enum": ["junk", "developer", "large", "leftovers", "uninstall"]],
                          "rescan": ["type": "boolean", "description": "Scan now instead of using the Clean Up page's last scan. Slower."]],
             required: [], local: { CleanCommand.listingJSON(tab: $0["tab"] as? String, rescan: $0["rescan"] as? Bool ?? false) }),
        Tool(name: "explain_cleanable",
             description: "Where a Clean Up row comes from and what removing it would lose, for when the user cannot tell from its name (\"what is agent-ae2e7c6 (t3code)?\", \"who made these worktrees?\", \"where did this .dmg come from?\"). Matches the row by id, by a path at or inside it, or by words from its name, and returns up to ten: what made it, the repository with its branch, remote, uncommitted files, unpushed commits and last commit, the address a download came from, the owning app and whether it runs, any process using it now, and whether the user ticked it. Reads only.",
             properties: ["query": ["type": "string", "description": "The row's id, a path, or words from its name as the user sees it, e.g. \"agent-ae2e7c6afaf6e46fd\" or \"node_modules wisp\""],
                          "tab": ["type": "string", "enum": ["junk", "developer", "large", "leftovers"]],
                          "rescan": ["type": "boolean", "description": "Scan now instead of using the Clean Up page's last scan. Slower."]],
             required: ["query"], local: { CleanCommand.explainJSON($0["query"] as? String ?? "", tab: $0["tab"] as? String, rescan: $0["rescan"] as? Bool ?? false) }),
        Tool(name: "uninstall_plan",
             description: "What uninstalling an app would remove, without removing anything: the app bundle and its files in ~/Library (Application Support, Caches, Preferences, Containers, Group Containers, launch agents...) with paths and sizes. Ticked items match the app's bundle id or app groups exactly; unticked ones are looser matches to confirm.",
             properties: ["name": ["type": "string", "description": "App name or bundle id, e.g. \"Slack\" or \"com.tinyspeck.slackmacgap\""]],
             required: ["name"], local: { UninstallCommand.planJSON($0["name"] as? String ?? "") }),
        Tool(name: "why_slow",
             description: "Why this Mac is slow right now: Wisp looks hard for about three seconds, then returns findings ranked by how much each one slows the Mac (CPU, memory pressure and swapping, thermal throttling, disk space and activity, Spotlight, Time Machine, Photos analysis, WindowServer, GPU, coding agents and containers). Each finding is one sentence with the number and the app responsible. An empty list means nothing is wrong.",
             properties: [:], required: []) { _ in LocalRequest(command: "why") },
        Tool(name: "fan_status",
             description: "Fan speeds now and each fan's range, the CPU and GPU temperature, and the fan mode: Automatic (macOS decides), a fixed percent, or a curve of speed by temperature such as Quiet or Balanced. Also whether Wisp's fan helper is installed and the modes ask_to_change_fans takes.",
             properties: [:], required: [], local: { _ in FanCommand.statusJSON() }),
        Tool(name: "ask_to_change_fans",
             description: "Ask the user to change the fan mode, for example to Max while a long build runs hot, or back to Automatic. Wisp shows them the mode and your reason, and changes it only if they agree. Needs Wisp running with fan control set up. Returns at once; check fan_status later.",
             properties: ["mode": ["type": "string", "description": "auto, silent, quiet, balanced, cool, max, a percent like \"60%\", or the name of a saved curve from fan_status"],
                          "reason": ["type": "string", "description": "One sentence the user will read, e.g. \"The CPU is at 98 °C during the build.\""]],
             required: ["mode", "reason"], readOnly: false) { LocalRequest(command: "fanmode", argument: $0["mode"] as? String, reason: $0["reason"] as? String) },
        Tool(name: "ask_to_quit_app",
             description: "Ask the user to quit an app, for example one using far too much memory. Wisp shows them the app, what it is using and your reason, and quits it normally only if they agree. Returns at once; check app_details later to see whether it quit.",
             properties: ["name": ["type": "string", "description": "App name or bundle id"],
                          "reason": ["type": "string", "description": "One sentence the user will read, e.g. \"Chrome holds 14 GB and the Mac is swapping.\""]],
             required: ["name", "reason"], readOnly: false) { LocalRequest(command: "quit", argument: $0["name"] as? String, reason: $0["reason"] as? String) },
    ]

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            guard id != nil else { continue }  // notifications need no answer
            switch method {
            case "initialize":
                let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
                reply(id, result: ["protocolVersion": requested ?? "2025-06-18",
                                   "capabilities": ["tools": [:] as [String: Any]],
                                   "serverInfo": ["name": "wisp", "version": Wisp.version],
                                   "instructions": "This Mac's processes, apps, ports, coding agents, Docker containers, storage, fans and Clean Up rows, from the Wisp system monitor. When the user asks what a Clean Up row is or where it came from, call explain_cleanable. Everything is read only, except that you can ask the user to quit an app or change the fan mode."])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools.map { tool in
                    ["name": tool.name, "description": tool.description,
                     "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required],
                     "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": !tool.readOnly, "openWorldHint": false]] as [String: Any]
                }])
            case "tools/call":
                let params = message["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                guard let tool = tools.first(where: { $0.name == name }) else {
                    reply(id, error: (-32602, "Unknown tool \(name)"))
                    continue
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let text: String
                if !Self.allowed {
                    text = "{\"error\": \"Assistant access is turned off in Wisp's settings.\"}"
                } else {
                    let data: Data
                    if let local = tool.local {
                        data = local(arguments)
                    } else {
                        var request = tool.request!(arguments)
                        request.fromAssistant = true
                        data = Local.ask(request) ?? (request.command == "quit" || request.command == "fanmode"
                            ? Report.json(Responder.Failure(error: "Wisp is not running, so it cannot ask the user."))
                            : Local.sampleAndAnswer(request))
                    }
                    text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": text.hasPrefix("{\"error\"")])
            default:
                reply(id, error: (-32601, "Method not found"))
            }
        }
    }

    /// Honours the app's setting even when the app is not running.
    static var allowed: Bool {
        guard let data = UserDefaults(suiteName: Wisp.bundleIdentifier)?.data(forKey: "settings"),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return settings["allowMCP"] as? Bool ?? true
    }

    private func reply(_ id: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func reply(_ id: Any?, error: (Int, String)) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": error.0, "message": error.1]])
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
