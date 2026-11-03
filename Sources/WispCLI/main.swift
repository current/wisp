import Darwin
import Foundation
import WispCore

let usage = """
usage: wisp <command> [options]

  status              the machine right now and the five busiest apps
  apps                apps grouped the way Wisp shows them
      --sort cpu|memory|energy|disk|network   (default cpu)
      --limit N                               (default 20)
  app NAME            one app: its processes and the last hour
  ports               dev servers and listening ports by project
  agents              coding agents and the processes they started
  docker              running containers
  alerts              recent alerts (needs the app running)
  storage             disk space by kind, what can go, drive health
  mcp                 run as a read-only MCP server on stdin/stdout

  --json              print JSON instead of a table

Figures come from the running Wisp app when it is open; otherwise wisp takes
its own one-second sample.

"""

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

let sort = option("--sort")
let limit = option("--limit").flatMap(Int.init)
guard let command = args.first else {
    print(usage, terminator: "")
    exit(0)
}

if command == "mcp" {
    MCPServer().run()
    exit(0)
}
if command == "help" || command == "--help" || command == "-h" {
    print(usage, terminator: "")
    exit(0)
}
if command == "version" || command == "--version" {
    print("wisp \(Wisp.version)")
    exit(0)
}

if command == "storage" {
    StorageCommand.run(json: json)
    exit(0)
}

let known = ["status", "apps", "app", "ports", "servers", "agents", "docker", "alerts"]
guard known.contains(command) else {
    FileHandle.standardError.write("wisp: unknown command \(command)\n\n\(usage)".data(using: .utf8)!)
    exit(2)
}

let request = LocalRequest(command: command, argument: args.dropFirst().joined(separator: " ").nilIfEmpty, limit: limit, sort: sort)
let data = Local.ask(request) ?? Local.sampleAndAnswer(request)

if json {
    FileHandle.standardOutput.write(data)
    if data.last != 10 { print() }
    exit(0)
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
if let failure = try? decoder.decode(Responder.Failure.self, from: data) {
    FileHandle.standardError.write("wisp: \(failure.error)\n".data(using: .utf8)!)
    exit(1)
}

switch command {
case "status":
    guard let s = try? decoder.decode(Report.Status.self, from: data) else { exit(1) }
    var lines: [(String, String)] = []
    if let cpu = s.cpuPercent { lines.append(("CPU", String(format: "%.0f%%", cpu))) }
    if let used = s.memoryUsedBytes, let total = s.memoryTotalBytes {
        lines.append(("Memory", "\(Format.memory(used)) of \(Format.memory(total)), pressure \(s.memoryPressure ?? "?")"
            + ((s.swapUsedBytes ?? 0) > 0 ? ", \(Format.memory(s.swapUsedBytes ?? 0)) swap" : "")))
    }
    if let down = s.networkInBytesPerSecond, let up = s.networkOutBytesPerSecond {
        lines.append(("Network", "\(Format.rate(down)) down, \(Format.rate(up)) up"))
    }
    if let read = s.diskReadBytesPerSecond, let write = s.diskWriteBytesPerSecond {
        lines.append(("Disk", "\(Format.rate(read)) read, \(Format.rate(write)) write" + (s.diskFreeBytes.map { ", \(Format.bytes($0)) free" } ?? "")))
    }
    if let gpu = s.gpuPercent { lines.append(("GPU", String(format: "%.0f%%", gpu))) }
    if let watts = s.cpuWatts { lines.append(("Power", "CPU \(Format.watts(watts)), GPU \(Format.watts(s.gpuWatts ?? 0))")) }
    if let temp = s.cpuTemperature {
        let fans = (s.fansRPM ?? []).map { "\(Int($0)) rpm" }.joined(separator: ", ")
        lines.append(("Temperature", Format.celsius(temp) + (fans.isEmpty ? "" : ", fans \(fans)")))
    }
    if let battery = s.batteryPercent { lines.append(("Battery", String(format: "%.0f%%", battery) + (s.charging == true ? ", charging" : ""))) }
    let width = lines.map(\.0.count).max() ?? 0
    for (name, value) in lines { print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value) }
    print()
    Table.apps(s.topApps)

case "apps":
    guard let apps = try? decoder.decode([Report.App].self, from: data) else { exit(1) }
    Table.apps(apps)

case "app":
    guard let detail = try? decoder.decode(Report.AppDetail.self, from: data) else { exit(1) }
    let a = detail.app
    print("\(a.name)" + (a.bundleID.map { "  (\($0))" } ?? ""))
    if let path = detail.bundlePath { print(path) }
    print(String(format: "CPU %.1f%%   memory %@   power %@   %d processes", a.cpuPercent, Format.memory(a.memoryBytes), Format.watts(a.watts), a.processes))
    let cpu = detail.cpuPercentLastHour.compactMap { $0 }
    if !cpu.isEmpty {
        print(String(format: "Last hour: CPU average %.1f%%, peak %.1f%%", cpu.reduce(0, +) / Double(cpu.count), cpu.max() ?? 0))
    }
    print()
    Table.print(["PID", "PROCESS", "CPU", "MEMORY"], detail.processes.map {
        ["\($0.pid)", $0.name, $0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–", $0.memoryBytes.map { Format.memory($0) } ?? "–"]
    }, right: [0, 2, 3])

case "ports", "servers":
    guard let projects = try? decoder.decode([DevProject].self, from: data) else { exit(1) }
    if projects.isEmpty { print("Nothing of yours is listening on a port.") }
    var rows: [[String]] = []
    for project in projects {
        for server in project.servers {
            let ports = Array(Set(server.ports.map(\.port))).sorted().map(String.init).joined(separator: ",")
            let idle = server.connections > 0 ? "\(server.connections) connected"
                : ((server.idleSeconds ?? 0) >= DevServerScanner.idleAfter ? "idle \(Format.duration(server.idleSeconds ?? 0))" : "")
            rows.append([project.name, "\(server.pid)", server.name, ports, Format.memory(server.memory), idle])
        }
    }
    if !rows.isEmpty { Table.print(["PROJECT", "PID", "PROCESS", "PORTS", "MEMORY", ""], rows, right: [1, 4]) }

case "agents":
    guard let agents = try? decoder.decode([AgentSummary].self, from: data) else { exit(1) }
    if agents.isEmpty { print("No coding agents are running.") }
    let home = NSHomeDirectory()
    Table.print(["PID", "AGENT", "FOLDER", "PROCESSES", "CPU", "MEMORY"], agents.map {
        ["\($0.pid)", $0.kind + ($0.host.map { " (\($0))" } ?? ""), ($0.folder ?? "").replacingOccurrences(of: home, with: "~"),
         "\($0.processes.count)", String(format: "%.1f%%", $0.cpuPercent), Format.memory($0.memoryBytes)]
    }, right: [0, 3, 4, 5])

case "docker":
    guard let status = try? decoder.decode(DockerStatus.self, from: data) else { exit(1) }
    guard status.socket != nil else {
        print("No Docker engine is running.")
        break
    }
    if status.containers.isEmpty { print("No containers are running.") }
    Table.print(["CONTAINER", "IMAGE", "PORTS", "CPU", "MEMORY", "STATUS"], status.containers.map {
        [$0.name, $0.image, $0.ports.joined(separator: ","), $0.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "–",
         $0.memory.map { Format.memory($0) } ?? "–", $0.status]
    }, right: [3, 4])

case "alerts":
    guard let alerts = try? decoder.decode([Alert].self, from: data) else { exit(1) }
    if alerts.isEmpty { print("No alerts since Wisp started.") }
    for alert in alerts.reversed() {
        print("\(alert.date.formatted(date: .omitted, time: .shortened))  \(alert.title). \(alert.body)")
    }

default:
    break
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum Table {
    static func apps(_ apps: [Report.App]) {
        let network = apps.contains { $0.networkBytesPerSecond != nil }
        var header = ["APP", "CPU", "MEMORY", "POWER", "DISK"]
        if network { header.append("NETWORK") }
        header.append("PROCS")
        Table.print(header, apps.map { a in
            var row = [a.name, String(format: "%.1f%%", a.cpuPercent), Format.memory(a.memoryBytes),
                       a.watts > 0.005 ? Format.watts(a.watts) : "–", a.diskBytesPerSecond > 0 ? Format.rate(a.diskBytesPerSecond) : "–"]
            if network { row.append(a.networkBytesPerSecond.map { $0 > 0 ? Format.rate($0) : "–" } ?? "–") }
            row.append("\(a.processes)")
            return row
        }, right: Set(1..<header.count))
    }

    static func print(_ header: [String], _ rows: [[String]], right: Set<Int> = []) {
        let maxWidth = 44
        let all = [header] + rows.map { $0.map { $0.count > maxWidth ? String($0.prefix(maxWidth - 1)) + "…" : $0 } }
        var widths = [Int](repeating: 0, count: header.count)
        for row in all { for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) } }
        for row in all {
            let cells = row.enumerated().map { i, cell -> String in
                let pad = String(repeating: " ", count: max(0, widths[i] - cell.count))
                return right.contains(i) ? pad + cell : cell + pad
            }
            var line = cells.joined(separator: "  ")
            while line.last == " " { line.removeLast() }
            Swift.print(line)
        }
    }
}
