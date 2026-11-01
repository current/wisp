import Foundation

/// The answers the CLI, the MCP server and the app's local socket share. Every
/// figure is in plain units (percent of one core, bytes, watts) so scripts and
/// assistants do not have to guess.
public enum Report {
    public struct App: Codable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var bundleID: String?
        public var cpuPercent: Double
        public var memoryBytes: UInt64
        public var watts: Double
        public var diskBytesPerSecond: Double
        public var networkBytesPerSecond: Double?
        public var processes: Int
    }

    public struct Process: Codable, Sendable {
        public var pid: Int32
        public var parent: Int32
        public var name: String
        public var path: String?
        public var cpuPercent: Double?
        public var memoryBytes: UInt64?
        public var started: Date?
    }

    public struct Status: Codable, Sendable {
        public var date: Date
        public var cpuPercent: Double?
        public var memoryUsedBytes: UInt64?
        public var memoryTotalBytes: UInt64?
        public var memoryPressure: String?
        public var swapUsedBytes: UInt64?
        public var diskReadBytesPerSecond: Double?
        public var diskWriteBytesPerSecond: Double?
        public var diskFreeBytes: UInt64?
        public var networkInBytesPerSecond: Double?
        public var networkOutBytesPerSecond: Double?
        public var gpuPercent: Double?
        public var cpuTemperature: Double?
        public var fansRPM: [Double]?
        public var thermalPressure: String?
        public var batteryPercent: Double?
        public var charging: Bool?
        public var cpuWatts: Double?
        public var gpuWatts: Double?
        public var topApps: [App]
    }

    public struct AppDetail: Codable, Sendable {
        public var app: App
        public var bundlePath: String?
        public var processes: [Process]
        /// One value per minute, oldest first; null where Wisp has no data.
        public var cpuPercentLastHour: [Double?]
        public var memoryBytesLastHour: [Double?]
    }

    public static func app(_ app: AppGroup, measuredNetwork: Bool) -> App {
        App(id: app.id, name: app.name, kind: app.kind.rawValue, bundleID: app.bundleIdentifier,
            cpuPercent: round1(app.cpu * 100), memoryBytes: app.memory, watts: round2(app.watts),
            diskBytesPerSecond: app.diskPerSecond.rounded(),
            networkBytesPerSecond: measuredNetwork ? app.networkPerSecond.rounded() : nil, processes: app.processCount)
    }

    public static func apps(_ table: ProcessTable, sort: String = "cpu", limit: Int = 20) -> [App] {
        let sorted: [AppGroup]
        switch sort {
        case "memory": sorted = table.apps.sorted { $0.memory > $1.memory }
        case "energy", "power": sorted = table.apps.sorted { $0.watts > $1.watts }
        case "disk": sorted = table.apps.sorted { $0.diskPerSecond > $1.diskPerSecond }
        case "network": sorted = table.apps.sorted { $0.networkPerSecond > $1.networkPerSecond }
        default: sorted = table.apps.sorted { $0.cpu > $1.cpu }
        }
        return sorted.prefix(max(1, limit)).map { app($0, measuredNetwork: table.networkMeasured) }
    }

    public static func status(_ s: SystemSnapshot, table: ProcessTable) -> Status {
        Status(date: s.date, cpuPercent: s.cpu.map { round1($0.total * 100) }, memoryUsedBytes: s.memory?.used,
               memoryTotalBytes: s.memory?.total,
               memoryPressure: s.memory.map { $0.pressure == .normal ? "normal" : ($0.pressure == .warning ? "warning" : "critical") },
               swapUsedBytes: s.memory?.swapUsed, diskReadBytesPerSecond: s.disk?.readBytesPerSecond.rounded(),
               diskWriteBytesPerSecond: s.disk?.writeBytesPerSecond.rounded(), diskFreeBytes: s.disk?.volumeFree,
               networkInBytesPerSecond: s.network?.receivedBytesPerSecond.rounded(),
               networkOutBytesPerSecond: s.network?.sentBytesPerSecond.rounded(),
               gpuPercent: s.gpu?.utilization.map { round1($0 * 100) }, cpuTemperature: s.thermal?.cpuCelsius.map(round1),
               fansRPM: s.thermal.map { $0.fans.map { $0.rpm.rounded() } }, thermalPressure: s.thermal?.pressure.rawValue,
               batteryPercent: s.battery?.percent, charging: s.battery?.isCharging,
               cpuWatts: s.power?.cpu.map(round2), gpuWatts: s.power?.gpu.map(round2),
               topApps: apps(table, limit: 5))
    }

    /// Finds an app by id, exact name or a case-insensitive part of its name or bundle id.
    public static func find(_ query: String, in table: ProcessTable) -> AppGroup? {
        let q = query.lowercased()
        return table.apps.first { $0.id == query }
            ?? table.apps.first { $0.name.lowercased() == q }
            ?? table.apps.first { $0.bundleIdentifier?.lowercased() == q }
            ?? table.apps.first { $0.name.lowercased().contains(q) || ($0.bundleIdentifier?.lowercased().contains(q) ?? false) }
    }

    public static func detail(_ app: AppGroup, table: ProcessTable, history: HistoryStore?) -> AppDetail {
        let processes = table.processes(in: app).sorted { $0.cpu > $1.cpu }.map {
            Process(pid: $0.pid, parent: $0.ppid, name: $0.name, path: $0.path,
                    cpuPercent: $0.readable ? round1($0.cpu * 100) : nil, memoryBytes: $0.readable ? $0.memory : nil, started: $0.startDate)
        }
        func series(_ metric: AppMetric, scale: Double) -> [Double?] {
            (history?.app(app.id, metric, minutes: 60) ?? []).map { $0.isNaN ? nil : (Double($0) * scale).rounded() }
        }
        return AppDetail(app: self.app(app, measuredNetwork: table.networkMeasured), bundlePath: app.bundlePath, processes: processes,
                         cpuPercentLastHour: series(.cpu, scale: 100), memoryBytesLastHour: series(.memory, scale: 1))
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    public static func json<T: Encodable>(_ value: T, pretty: Bool = true) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data("null".utf8)
    }
}

/// A request over the app's local socket: one JSON line in, one JSON line out.
public struct LocalRequest: Codable, Sendable {
    public var command: String
    public var argument: String?
    public var limit: Int?
    public var sort: String?
    public var fromAssistant: Bool?
    /// Why an assistant wants something done, shown to the owner when Wisp asks.
    public var reason: String?

    public init(command: String, argument: String? = nil, limit: Int? = nil, sort: String? = nil, fromAssistant: Bool? = nil,
                reason: String? = nil) {
        self.command = command
        self.reason = reason
        self.argument = argument
        self.limit = limit
        self.sort = sort
        self.fromAssistant = fromAssistant
    }

    public static var socketPath: String { Wisp.supportDirectory.appendingPathComponent("wisp.sock").path }
}

/// Answers a request from a table and snapshot, whether they came from the running
/// app or from a quick sample the CLI took itself.
public struct Responder {
    public var system: SystemSnapshot
    public var table: ProcessTable
    public var history: HistoryStore?
    public var alerts: [Alert]
    public var devServers: DevServerScanner
    public var agents: AgentFinder
    public var docker: DockerWatcher

    public init(system: SystemSnapshot, table: ProcessTable, history: HistoryStore?, alerts: [Alert],
                devServers: DevServerScanner = DevServerScanner(), agents: AgentFinder = AgentFinder(), docker: DockerWatcher = DockerWatcher()) {
        self.system = system
        self.table = table
        self.history = history
        self.alerts = alerts
        self.devServers = devServers
        self.agents = agents
        self.docker = docker
    }

    public struct Failure: Codable {
        public var error: String
        public init(error: String) { self.error = error }
    }

    public func respond(_ request: LocalRequest) -> Data {
        switch request.command {
        case "status":
            return Report.json(Report.status(system, table: table))
        case "apps":
            return Report.json(Report.apps(table, sort: request.sort ?? "cpu", limit: request.limit ?? 20))
        case "app":
            guard let query = request.argument, let app = Report.find(query, in: table) else {
                return Report.json(Failure(error: "No running app matches \"\(request.argument ?? "")\"."))
            }
            return Report.json(Report.detail(app, table: table, history: history))
        case "ports", "servers":
            return Report.json(devServers.scan(table))
        case "agents":
            return Report.json(agents.find(table).map(AgentSummary.init))
        case "docker":
            var status = Docker.status(stats: true, watcher: docker)
            // CPU needs two readings; take the second one now rather than print blanks.
            if status.containers.contains(where: { $0.cpu == nil }) {
                Thread.sleep(forTimeInterval: 1)
                status = Docker.status(stats: true, watcher: docker)
            }
            return Report.json(status)
        case "alerts":
            return Report.json(alerts)
        case "storage":
            return Report.json(StorageReport.current())
        default:
            return Report.json(Failure(error: "Unknown command \(request.command)."))
        }
    }
}

/// An agent without its full process rows, which are too long for a terminal or a prompt.
public struct AgentSummary: Codable, Sendable {
    public var pid: Int32
    public var kind: String
    public var folder: String?
    public var host: String?
    public var started: Date?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var processes: [Report.Process]

    public init(_ agent: CodingAgent) {
        pid = agent.pid
        kind = agent.kind
        folder = agent.folder
        host = agent.host
        started = agent.startDate
        cpuPercent = Report.round1(agent.cpu * 100)
        memoryBytes = agent.memory
        processes = agent.processes.map {
            Report.Process(pid: $0.pid, parent: $0.ppid, name: $0.name, path: $0.path,
                           cpuPercent: $0.readable ? Report.round1($0.cpu * 100) : nil,
                           memoryBytes: $0.readable ? $0.memory : nil, started: $0.startDate)
        }
    }
}
