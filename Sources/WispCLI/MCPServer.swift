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
        let request: ([String: Any]) -> LocalRequest
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
                                   "instructions": "This Mac's processes, apps, ports, coding agents and Docker containers, from the Wisp system monitor. Everything is read only, except that you can ask the user to quit an app."])
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
                var request = tool.request(params["arguments"] as? [String: Any] ?? [:])
                request.fromAssistant = true
                let text: String
                if !Self.allowed {
                    text = "{\"error\": \"Assistant access is turned off in Wisp's settings.\"}"
                } else {
                    let data = Local.ask(request) ?? (request.command == "quit"
                        ? Report.json(Responder.Failure(error: "Wisp is not running, so it cannot ask the user."))
                        : Local.sampleAndAnswer(request))
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
