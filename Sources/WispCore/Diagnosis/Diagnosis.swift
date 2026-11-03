import Foundation

/// What a diagnosis offers to do about one finding.
public enum DiagnosisAction: Codable, Sendable, Equatable {
    /// Open the app's drawer, where it can be quit.
    case showApp(String)
    /// Ask to quit the app normally, so it can save its work.
    case quitApp(String)
    /// Open one of Wisp's pages, by its raw name ("sensors", "agents", "docker", "gpu").
    case openPage(String)
    /// Open Wisp's Storage page.
    case openStorage

    private enum CodingKeys: String, CodingKey { case type, target }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        switch try c.decode(String.self, forKey: .type) {
        case "showApp": self = .showApp(target)
        case "quitApp": self = .quitApp(target)
        case "openPage": self = .openPage(target)
        default: self = .openStorage
        }
    }

    /// {"type": "showApp", "target": "<app id>"}, so scripts and assistants read it plainly.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .showApp(let id): try c.encode("showApp", forKey: .type); try c.encode(id, forKey: .target)
        case .quitApp(let id): try c.encode("quitApp", forKey: .type); try c.encode(id, forKey: .target)
        case .openPage(let page): try c.encode("openPage", forKey: .type); try c.encode(page, forKey: .target)
        case .openStorage: try c.encode("openStorage", forKey: .type)
        }
    }

    public var title: String {
        switch self {
        case .showApp: return "Show"
        case .quitApp: return "Quit…"
        case .openPage: return "Show"
        case .openStorage: return "Open Storage"
        }
    }
}

/// One reason the Mac is slow: a plain sentence with the number and the culprit,
/// and the one thing to do about it.
public struct DiagnosisFinding: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case cpu, heldCores, memory, thermal, diskSpace, diskActivity, spotlight, timeMachine, mediaAnalysis
        case windowServer, gpu, unmeasured, developer
    }

    public var kind: Kind
    /// The sentence, e.g. "limactl is holding 20 GB and macOS is swapping 300 MB a minute".
    public var title: String
    /// A short second line: what it means or what else is involved.
    public var detail: String
    /// 0 to 1; findings are listed by this, highest first.
    public var severity: Double
    public var appID: String?
    public var appName: String?
    public var action: DiagnosisAction?

    public init(kind: Kind, title: String, detail: String, severity: Double, appID: String? = nil, appName: String? = nil,
                action: DiagnosisAction? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.severity = severity
        self.appID = appID
        self.appName = appName
        self.action = action
    }
}

public struct Diagnosis: Codable, Sendable, Equatable {
    public var date: Date
    /// Seconds the diagnosis sampled for.
    public var sampled: Double
    /// Ranked, most important first. Empty when nothing is wrong.
    public var findings: [DiagnosisFinding]
    /// One line: what is wrong in short, or that nothing is, with the key numbers.
    public var summary: String
    /// The two or three numbers that matter, for the "all fine" case and for scripts.
    public var numbers: [String]

    public var isHealthy: Bool { findings.isEmpty }
}

/// Everything the diagnosis looks at, gathered by `Monitor.diagnose` or built by hand in tests.
public struct DiagnosisInput: Sendable {
    public var system: SystemSnapshot
    /// Rates measured over the diagnosis window.
    public var table: ProcessTable
    /// Bytes per second paged in from and out to swap over the window; nil when not measured.
    public var swapInPerSecond: Double?
    public var swapOutPerSecond: Double?
    public var thermalState: ThermalPressure
    /// The CPU speed limit macOS set, percent, when the OS reports one.
    public var cpuSpeedLimit: Int?
    /// GPU share per process over the window, 0 to 1.
    public var gpuShares: [Int32: Double]
    /// Per-app CPU (cores) for the last minutes, oldest first, for apps that have been busy.
    public var recentAppCPU: [String: [Float]]
    public var agents: [CodingAgent]
    public var devServers: Int
    /// What the dev servers use together: cores and bytes.
    public var devServerCPU: Double
    public var devServerMemory: UInt64
    public var containers: Int
    /// True when a Time Machine backup has its snapshot mounted.
    public var timeMachineRunning: Bool
    public var sampled: Double

    public init(system: SystemSnapshot, table: ProcessTable, swapInPerSecond: Double? = nil, swapOutPerSecond: Double? = nil,
                thermalState: ThermalPressure = .nominal, cpuSpeedLimit: Int? = nil, gpuShares: [Int32: Double] = [:],
                recentAppCPU: [String: [Float]] = [:], agents: [CodingAgent] = [], devServers: Int = 0, devServerCPU: Double = 0,
                devServerMemory: UInt64 = 0, containers: Int = 0,
                timeMachineRunning: Bool = false, sampled: Double = 0) {
        self.system = system
        self.table = table
        self.swapInPerSecond = swapInPerSecond
        self.swapOutPerSecond = swapOutPerSecond
        self.thermalState = thermalState
        self.cpuSpeedLimit = cpuSpeedLimit
        self.gpuShares = gpuShares
        self.recentAppCPU = recentAppCPU
        self.agents = agents
        self.devServers = devServers
        self.devServerCPU = devServerCPU
        self.devServerMemory = devServerMemory
        self.containers = containers
        self.timeMachineRunning = timeMachineRunning
        self.sampled = sampled
    }
}

/// Turns one hard look at the machine into ranked findings. Pure: no sampling here.
public enum Diagnoser {
    static let spotlightNames: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd", "mdbulkimport"]
    static let mediaNames: Set<String> = ["photoanalysisd", "mediaanalysisd", "photolibraryd", "mediaanalysisd-access", "cloudphotod",
                                          "VTDecoderXPCService", "mediastream.mediastreamd"]
    /// Minutes an app must keep a core busy before it counts as holding it.
    static let heldMinutes = 5

    public static func diagnose(_ input: DiagnosisInput) -> Diagnosis {
        var findings: [DiagnosisFinding] = []
        let table = input.table
        let coreCount = Double(max(1, table.coreCount))
        let cpuTotal = input.system.cpu?.total ?? (table.machineCPU / coreCount)
        let byCPU = table.apps.filter { $0.id != AppGrouping.systemID }.sorted { $0.cpu > $1.cpu }

        // CPU saturated, and by whom.
        if cpuTotal >= 0.85 {
            var title = "CPU is at \(Format.percent(cpuTotal))"
            var detail = "Every core is busy, so everything waits its turn"
            var finding = DiagnosisFinding(kind: .cpu, title: title, detail: detail, severity: 0.7 + 0.3 * min(1, (cpuTotal - 0.85) / 0.15))
            if let top = byCPU.first, top.cpu >= 0.5 {
                title += ": \(top.name) is using \(cores(top.cpu))"
                if byCPU.count > 1, byCPU[1].cpu >= 0.5 { detail = "Then \(byCPU[1].name) with \(cores(byCPU[1].cpu))" }
                finding.title = title
                finding.detail = detail
                finding.appID = top.id
                finding.appName = top.name
                finding.action = .showApp(top.id)
            } else {
                finding.title = title
            }
            findings.append(finding)
        }

        // One app taking a big share of the cores right now, while the total is still under the line.
        if cpuTotal < 0.85, let top = byCPU.first, top.cpu >= max(2, coreCount * 0.3) {
            let share = top.cpu / coreCount
            findings.append(DiagnosisFinding(kind: .cpu, title: "\(top.name) is using \(cores(top.cpu)), \(Format.percent(min(1, share))) of the CPU",
                                             detail: "Other apps get what is left", severity: min(0.75, 0.4 + 0.4 * share),
                                             appID: top.id, appName: top.name, action: .showApp(top.id)))
        }

        // One app holding cores for minutes, even when the total looks fine.
        for (id, minutes) in input.recentAppCPU {
            guard let app = table.app(id), id != AppGrouping.systemID, findings.first(where: { $0.appID == id && $0.kind == .cpu }) == nil else { continue }
            guard let held = heldRun(minutes), held.minutes >= heldMinutes, app.cpu >= 0.5 else { continue }
            let severity = min(0.75, 0.35 + Double(held.minutes) / 60 + held.cores / coreCount * 0.5)
            findings.append(DiagnosisFinding(kind: .heldCores, title: "\(app.name) has held \(cores(held.cores)) for \(held.minutes) min",
                                             detail: "It is using \(cores(app.cpu)) right now", severity: severity,
                                             appID: id, appName: app.name, action: .showApp(id)))
        }

        // Memory: pressure, swapping, compression.
        if let m = input.system.memory {
            let swapRate = (input.swapInPerSecond ?? 0) + (input.swapOutPerSecond ?? 0)
            let swapping = swapRate * 60 >= 50_000_000
            let compressedShare = Double(m.compressed) / Double(max(1, m.total))
            let largest = table.apps.filter { $0.id != AppGrouping.systemID }.max { $0.memory < $1.memory }
            if m.pressure != .normal || swapping || compressedShare >= 0.3 {
                var parts: [String] = []
                if let largest, largest.memory >= m.total / 10 { parts.append("\(largest.name) is holding \(Format.memory(largest.memory))") }
                if swapping {
                    parts.append("macOS is swapping \(Format.memory(swapRate * 60)) a minute")
                } else if m.pressure != .normal {
                    parts.append("memory pressure is \(m.pressure == .critical ? "critical" : "high")")
                } else {
                    parts.append("macOS has compressed \(Format.memory(m.compressed)) to make room")
                }
                var title = parts.joined(separator: " and ")
                // App names keep their own case ("limactl"); a sentence that starts with a reading does not.
                if !(largest.map { largest in largest.memory >= m.total / 10 } ?? false), !title.hasPrefix("macOS") {
                    title = title.prefix(1).uppercased() + title.dropFirst()
                }
                var detail = "\(Format.memory(m.used)) of \(Format.memory(m.total)) in use"
                if m.swapUsed > 0 { detail += ", \(Format.memory(m.swapUsed)) in swap" }
                if swapping, m.compressed > 0 { detail += ", \(Format.memory(m.compressed)) compressed" }
                var severity = m.pressure == .critical ? 0.95 : (m.pressure == .warning ? 0.8 : 0.45)
                if swapping { severity = max(severity, 0.6 + 0.3 * min(1, swapRate * 60 / 1_000_000_000)) }
                var finding = DiagnosisFinding(kind: .memory, title: title, detail: detail, severity: severity)
                if let largest, largest.memory >= m.total / 10 {
                    finding.appID = largest.id
                    finding.appName = largest.name
                    finding.action = largest.kind == .app && largest.bundleIdentifier != nil ? .quitApp(largest.id) : .showApp(largest.id)
                }
                findings.append(finding)
            }
        }

        // Thermal throttling.
        switch input.thermalState {
        case .serious, .critical:
            var title = "macOS is slowing the CPU to cool it down"
            if let limit = input.cpuSpeedLimit, limit < 100 { title = "macOS has capped the CPU at \(limit)% speed to cool it down" }
            let hot = input.system.thermal?.cpuCelsius.map { "CPU at \(Format.celsius($0))" }
            findings.append(DiagnosisFinding(kind: .thermal, title: title,
                                             detail: ([hot, "thermal pressure \(input.thermalState.rawValue)"].compactMap { $0 }).joined(separator: ", "),
                                             severity: input.thermalState == .critical ? 0.95 : 0.85, action: .openPage("sensors")))
        case .fair:
            if let limit = input.cpuSpeedLimit, limit < 100 {
                findings.append(DiagnosisFinding(kind: .thermal, title: "macOS has capped the CPU at \(limit)% speed",
                                                 detail: "Thermal pressure is fair", severity: 0.6, action: .openPage("sensors")))
            } else if let celsius = input.system.thermal?.cpuCelsius, celsius >= 95 {
                findings.append(DiagnosisFinding(kind: .thermal, title: "The CPU is at \(Format.celsius(celsius)) and may slow down soon",
                                                 detail: "Thermal pressure is fair", severity: 0.4, action: .openPage("sensors")))
            }
        case .nominal:
            break
        }

        // Disk nearly full.
        if let d = input.system.disk, d.volumeTotal > 0 {
            let share = Double(d.volumeFree) / Double(d.volumeTotal)
            if share < 0.1 || d.volumeFree < 20_000_000_000 {
                let severity = d.volumeFree < 5_000_000_000 ? 0.9 : (d.volumeFree < 10_000_000_000 ? 0.75 : 0.55)
                findings.append(DiagnosisFinding(kind: .diskSpace, title: "Only \(Format.bytes(d.volumeFree)) free on the startup disk",
                                                 detail: "macOS needs free space for swap, caches and updates",
                                                 severity: severity, action: .openStorage))
            }
        }

        // An app reading or writing heavily.
        if let heavy = table.apps.max(by: { $0.diskPerSecond < $1.diskPerSecond }), heavy.diskPerSecond >= 50_000_000 {
            let writing = heavy.diskWritePerSecond >= heavy.diskReadPerSecond
            let verb = writing ? "writing" : "reading"
            let rate = writing ? heavy.diskWritePerSecond : heavy.diskReadPerSecond
            let name = heavy.id == AppGrouping.systemID ? "macOS" : heavy.name
            findings.append(DiagnosisFinding(kind: .diskActivity, title: "\(name) is \(verb) \(Format.rate(rate)) \(writing ? "to" : "from") disk",
                                             detail: "Other apps wait longer to load and save",
                                             severity: min(0.7, 0.35 + heavy.diskPerSecond / 1_000_000_000),
                                             appID: heavy.id, appName: name, action: .showApp(heavy.id)))
        }

        // Spotlight, Photos and media analysis: processes counted by name.
        let processes = table.processes
        let spotlight = processes.filter { spotlightNames.contains($0.name) }
        let spotlightCPU = spotlight.reduce(0) { $0 + $1.cpu }
        let spotlightDisk = spotlight.reduce(0) { $0 + $1.diskReadPerSecond + $1.diskWritePerSecond }
        if spotlightCPU >= 0.5 || spotlightDisk >= 30_000_000 {
            let workers = spotlight.filter { $0.name.hasPrefix("mdworker") }.count
            let who = workers > 1 ? "\(workers) mdworker processes are" : (spotlight.max { $0.cpu < $1.cpu }?.name ?? "mds") + " is"
            findings.append(DiagnosisFinding(kind: .spotlight, title: "Spotlight is indexing: \(who) using \(cores(spotlightCPU))",
                                             detail: "This usually settles once indexing is done",
                                             severity: min(0.65, 0.3 + spotlightCPU / coreCount), appID: AppGrouping.systemID,
                                             appName: "macOS", action: .showApp(AppGrouping.systemID)))
        }
        let media = processes.filter { mediaNames.contains($0.name) }
        let mediaCPU = media.reduce(0) { $0 + $1.cpu }
        if mediaCPU >= 0.5, let top = media.max(by: { $0.cpu < $1.cpu }) {
            findings.append(DiagnosisFinding(kind: .mediaAnalysis, title: "Photos is analysing your library: \(top.name) is using \(cores(mediaCPU))",
                                             detail: "It runs while the Mac is idle or plugged in and stops when done",
                                             severity: min(0.6, 0.3 + mediaCPU / coreCount), appID: top.groupID, appName: "macOS",
                                             action: .showApp(top.groupID)))
        }

        // macOS work Wisp cannot read (root processes such as mds_stores, backupd, WindowServer's CPU).
        let unmeasured = table.unattributedCPU
        if input.timeMachineRunning {
            let busy = unmeasured >= 0.5 || (input.system.disk.map { $0.readBytesPerSecond + $0.writeBytesPerSecond } ?? 0) >= 20_000_000
            findings.append(DiagnosisFinding(kind: .timeMachine, title: "Time Machine is backing up",
                                             detail: busy ? "macOS processes Wisp cannot measure are using \(cores(unmeasured))" : "It reads every changed file once",
                                             severity: busy ? 0.5 : 0.25))
        } else if unmeasured >= 2 {
            findings.append(DiagnosisFinding(kind: .unmeasured, title: "macOS processes Wisp cannot measure are using \(cores(unmeasured))",
                                             detail: "System services run as root; Activity Monitor shows them by name",
                                             severity: min(0.6, 0.3 + unmeasured / coreCount), appID: AppGrouping.systemID, appName: "macOS",
                                             action: .showApp(AppGrouping.systemID)))
        }

        // GPU saturated, and WindowServer's share of it.
        var gpuByApp: [String: Double] = [:]
        var windowServerGPU = 0.0
        if !input.gpuShares.isEmpty {
            let groups = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for (pid, share) in input.gpuShares {
                guard let row = groups[pid] else { continue }
                if row.groupID == "windowserver" || row.name == "WindowServer" { windowServerGPU += share }
                gpuByApp[row.groupID, default: 0] += share
            }
        }
        if let gpu = input.system.gpu?.utilization, gpu >= 0.9 {
            var finding = DiagnosisFinding(kind: .gpu, title: "GPU is at \(Format.percent(gpu))",
                                           detail: "Scrolling, video and animations stutter when it is full", severity: 0.6)
            if let (id, share) = gpuByApp.filter({ $0.key != "windowserver" }).max(by: { $0.value < $1.value }), share >= 0.2,
               let app = table.app(id) {
                finding.title += ": \(app.name) is using \(Format.percent(share)) of it"
                finding.appID = id
                finding.appName = app.name
                finding.action = .showApp(id)
            } else {
                finding.action = .openPage("gpu")
            }
            findings.append(finding)
        }
        if windowServerGPU >= 0.4 {
            findings.append(DiagnosisFinding(kind: .windowServer, title: "WindowServer is using \(Format.percent(windowServerGPU)) of the GPU to draw the screen",
                                             detail: "Many windows, displays or moving effects add to it",
                                             severity: 0.45 + 0.2 * min(1, (windowServerGPU - 0.4) / 0.4), action: .openPage("gpu")))
        }

        // Many coding agents, dev servers or containers.
        let agentCPU = input.agents.reduce(0) { $0 + $1.cpu }
        let agentMemory = input.agents.reduce(UInt64(0)) { $0 + $1.memory }
        // Agents count only when together they are using enough to matter, not for being open.
        if input.agents.count >= 2 && (agentCPU >= 1.5 || agentMemory >= 6 << 30) {
            findings.append(DiagnosisFinding(kind: .developer,
                                             title: "\(input.agents.count) coding agents are running, using \(cores(agentCPU)) and \(Format.memory(agentMemory)) together",
                                             detail: extraDev(servers: input.devServers, containers: input.containers),
                                             severity: min(0.6, 0.25 + agentCPU / coreCount + Double(agentMemory) / Double(input.system.memory?.total ?? (64 << 30))),
                                             action: .openPage("agents")))
        } else if input.containers >= 3 {
            findings.append(DiagnosisFinding(kind: .developer, title: "\(input.containers) containers are running",
                                             detail: extraDev(servers: input.devServers, containers: 0), severity: 0.3, action: .openPage("docker")))
        } else if input.devServers >= 3 && (input.devServerCPU >= 1 || input.devServerMemory >= 4 << 30) {
            findings.append(DiagnosisFinding(kind: .developer,
                                             title: "\(input.devServers) dev servers are using \(cores(input.devServerCPU)) and \(Format.memory(input.devServerMemory)) together",
                                             detail: "Stop the ones you are not working on", severity: 0.3, action: .openPage("ports")))
        }

        findings.sort { $0.severity > $1.severity }
        let ranked = findings.prefix(6).map { finding -> DiagnosisFinding in
            var finding = finding
            finding.severity = (finding.severity * 100).rounded() / 100
            return finding
        }
        let numbers = keyNumbers(input, cpuTotal: cpuTotal)
        let summary = ranked.first.map { $0.title } ?? "Nothing is slowing this Mac down"
        return Diagnosis(date: input.system.date, sampled: input.sampled, findings: ranked, summary: summary, numbers: numbers)
    }

    /// "CPU 14%", "Memory pressure normal", "212 GB free".
    static func keyNumbers(_ input: DiagnosisInput, cpuTotal: Double) -> [String] {
        var numbers = ["CPU \(Format.percent(cpuTotal))"]
        if let m = input.system.memory {
            numbers.append("Memory pressure \(m.pressure == .normal ? "normal" : (m.pressure == .warning ? "high" : "critical"))")
        }
        if let d = input.system.disk, d.volumeTotal > 0 { numbers.append("\(Format.bytes(d.volumeFree)) free") }
        return numbers
    }

    /// The longest run of recent minutes, ending now (one missing minute allowed at the end),
    /// in which the app kept at least 0.9 of a core busy. Nil when it is not holding one now.
    static func heldRun(_ minutes: [Float]) -> (minutes: Int, cores: Double)? {
        var values = minutes
        if let last = values.last, last.isNaN { values.removeLast() }
        var run: [Float] = []
        for value in values.reversed() {
            guard !value.isNaN, value >= 0.9 else { break }
            run.append(value)
        }
        guard !run.isEmpty else { return nil }
        return (run.count, Double(run.reduce(0, +)) / Double(run.count))
    }

    /// "1 core", "3.2 cores".
    static func cores(_ value: Double) -> String {
        if value < 1.05 && value >= 0.95 { return "1 core" }
        if value < 0.95 { return Format.percent(value) + " of a core" }
        return String(format: value < 10 ? "%.1f cores" : "%.0f cores", value)
    }

    private static func extraDev(servers: Int, containers: Int) -> String {
        var parts: [String] = []
        if servers > 0 { parts.append("\(servers) dev server\(servers == 1 ? "" : "s")") }
        if containers > 0 { parts.append("\(containers) container\(containers == 1 ? "" : "s")") }
        return parts.isEmpty ? "Each one runs builds, tests and language servers" : "Also running: " + parts.joined(separator: ", ")
    }
}
