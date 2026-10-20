import Darwin
import Foundation

public struct CodingAgent: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int32
    /// "Claude Code", "Codex"...
    public var kind: String
    public var folder: String?
    public var startDate: Date?
    /// The agent process and everything it started, still running.
    public var processes: [ProcessRow]
    public var cpu: Double
    public var memory: UInt64
    /// The app it runs inside, when it was started by one (a terminal, an editor).
    public var host: String?

    public var id: Int32 { pid }
}

/// Spots coding agents in the process table and collects the process tree under each.
/// Most agents are recognised by executable name; the ones that run as plain `node`
/// or `python` scripts need their arguments, which are read only for those
/// interpreters and cached per process.
public final class AgentFinder: @unchecked Sendable {
    static let byExecutable: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "cursor-agent": "Cursor Agent", "gemini": "Gemini CLI",
        "aider": "Aider", "opencode": "OpenCode", "opencode.exe": "OpenCode", "goose": "Goose", "amp": "Amp",
        "qwen": "Qwen Code", "crush": "Crush", "droid": "Factory Droid", "kiro-cli": "Kiro", "copilot": "GitHub Copilot CLI",
    ]
    /// Script names that identify an agent run through an interpreter.
    static let byScript: [String: String] = [
        "@anthropic-ai/claude-code": "Claude Code", "claude": "Claude Code", "@openai/codex": "Codex", "codex": "Codex",
        "@google/gemini-cli": "Gemini CLI", "gemini": "Gemini CLI", "aider": "Aider", "opencode": "OpenCode",
        "@qwen-code/qwen-code": "Qwen Code", "@githubnext/github-copilot-cli": "GitHub Copilot CLI", "amp": "Amp",
    ]
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    private var scriptCache: [String: String?] = [:]
    private let lock = NSLock()
    private let uid = getuid()

    public init() {}

    public func find(_ table: ProcessTable) -> [CodingAgent] {
        lock.lock()
        defer { lock.unlock() }
        var children: [Int32: [ProcessRow]] = [:]
        var byPID: [Int32: ProcessRow] = [:]
        for row in table.processes {
            children[row.ppid, default: []].append(row)
            byPID[row.pid] = row
        }

        var agents: [Int32: String] = [:]
        var live = Set<String>()
        for row in table.processes where row.uid == uid {
            let path = row.path ?? row.name
            var base = (path as NSString).lastPathComponent.lowercased()
            if base.hasSuffix(".exe") { base.removeLast(4) }
            if let kind = Self.byExecutable[base] ?? Self.packageKind(path) {
                agents[row.pid] = kind
            } else if Self.interpreters.contains(base) || base.hasPrefix("python3") {
                let key = "\(row.pid):\(row.startDate?.timeIntervalSince1970 ?? 0)"
                live.insert(key)
                if scriptCache[key] == nil { scriptCache[key] = Self.scriptKind(pid: row.pid) }
                if let kind = scriptCache[key] ?? nil { agents[row.pid] = kind }
            }
        }
        scriptCache = scriptCache.filter { live.contains($0.key) }

        // An agent started by another agent (a subagent) is shown under its parent.
        let roots = agents.keys.filter { pid in
            var parent = byPID[pid]?.ppid ?? 0
            var hops = 0
            while parent > 1, hops < 64 {
                if agents[parent] != nil { return false }
                parent = byPID[parent]?.ppid ?? 0
                hops += 1
            }
            return true
        }

        return roots.compactMap { pid -> CodingAgent? in
            guard let row = byPID[pid] else { return nil }
            var tree: [ProcessRow] = []
            var queue = [row]
            while let next = queue.popLast(), tree.count < 500 {
                tree.append(next)
                queue.append(contentsOf: children[next.pid] ?? [])
            }
            // Only a real app counts as the host; a command-line agent is its own group.
            let hostApp = table.app(byPID[row.responsiblePID]?.groupID ?? row.groupID)
            let host = hostApp?.kind == .app ? hostApp?.name : nil
            return CodingAgent(pid: pid, kind: agents[pid] ?? "Agent", folder: ProcessDetails.workingDirectory(pid: pid),
                               startDate: row.startDate, processes: tree,
                               cpu: tree.reduce(0) { $0 + $1.cpu }, memory: tree.reduce(0) { $0 + $1.memory },
                               host: host)
        }
        .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }

    /// Native agent binaries installed by npm live inside their package folder.
    static func packageKind(_ path: String) -> String? {
        guard path.contains("/node_modules/") else { return nil }
        for (marker, kind) in byScript where marker.hasPrefix("@") && path.contains("/node_modules/\(marker)/") {
            return kind
        }
        return nil
    }

    static func scriptKind(pid: Int32) -> String? {
        guard let args = ProcessDetails.arguments(pid: pid), args.count > 1 else { return nil }
        for arg in args.dropFirst().prefix(3) where !arg.hasPrefix("-") {
            for (marker, kind) in byScript {
                if arg.contains("/node_modules/\(marker)/") || arg.hasSuffix("/bin/\(marker)") || arg == marker {
                    return kind
                }
            }
        }
        return nil
    }
}
