import Darwin
import Foundation

public struct ListeningPort: Codable, Sendable, Equatable, Hashable {
    public var port: UInt16
    /// "127.0.0.1", "::", "0.0.0.0"...
    public var address: String
    /// True when the port accepts connections from other machines too.
    public var exposed: Bool { address != "127.0.0.1" && address != "::1" && address != "localhost" }
}

public struct DevServer: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var command: String
    public var ports: [ListeningPort]
    public var folder: String?
    public var cpu: Double
    public var memory: UInt64
    public var startDate: Date?
    /// Connections open on its ports right now.
    public var connections: Int
    /// Seconds since a connection was last seen, counted from when Wisp started watching.
    public var idleSeconds: Double?
    public var isRuntime: Bool

    public var id: Int32 { pid }
}

public struct DevProject: Codable, Sendable, Equatable, Identifiable {
    /// Project root folder, or "" for listeners that belong to no project.
    public var path: String
    public var name: String
    public var servers: [DevServer]
    public var id: String { path }
}

/// Finds processes of this user that listen on TCP ports and sorts them by the
/// project folder they run in. Walks the file descriptors of this user's processes
/// only, and only when asked: about 2 ms for every process on the machine.
public final class DevServerScanner: @unchecked Sendable {
    /// Executables that are almost always somebody's dev server when they listen.
    static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "php", "java", "go", "air",
                                        "uvicorn", "gunicorn", "rails", "puma", "next-server", "vite", "esbuild", "hugo",
                                        "jekyll", "dotnet", "beam.smp", "postgres", "redis-server", "mysqld", "mongod"]
    static let projectMarkers = [".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile", "composer.json",
                                 "deno.json", "mix.exs", "pom.xml", "build.gradle", "Package.swift"]
    /// Idle means nothing connected for this long.
    public static let idleAfter: Double = 30 * 60

    private var lastActive: [String: Date] = [:]
    private let watchStart = Date()
    private var folders: [String: String?] = [:]
    private let uid = getuid()
    private let lock = NSLock()

    public init() {}

    public func scan(_ table: ProcessTable) -> [DevProject] {
        lock.lock()
        defer { lock.unlock() }
        var servers: [DevServer] = []
        let now = Date()
        for row in table.processes where row.uid == uid && row.readable {
            let sockets = Self.sockets(pid: row.pid)
            let ports = sockets.listening
            guard !ports.isEmpty else { continue }
            let key = "\(row.pid):\(row.startDate?.timeIntervalSince1970 ?? 0)"
            let portSet = Set(ports.map(\.port))
            let connections = sockets.established.filter { portSet.contains($0) }.count
            if connections > 0 || lastActive[key] == nil { lastActive[key] = connections > 0 ? now : nil }
            let since = lastActive[key] ?? max(watchStart, row.startDate ?? watchStart)
            let base = (row.name as NSString).lastPathComponent.lowercased()
            let runtime = Self.runtimes.contains(base) || base.hasPrefix("python")
            let cwd = ProcessDetails.workingDirectory(pid: row.pid)
            let folder = cwd.flatMap { projectRoot(of: $0) }
            let args = (runtime ? ProcessDetails.arguments(pid: row.pid) : nil) ?? [row.name]
            servers.append(DevServer(pid: row.pid, name: row.name, command: args.joined(separator: " "),
                                     ports: ports.sorted { $0.port < $1.port }, folder: folder, cpu: row.cpu, memory: row.memory,
                                     startDate: row.startDate, connections: connections,
                                     idleSeconds: connections > 0 ? 0 : now.timeIntervalSince(since), isRuntime: runtime))
        }
        let live = Set(servers.map { "\($0.pid):\($0.startDate?.timeIntervalSince1970 ?? 0)" })
        lastActive = lastActive.filter { live.contains($0.key) }

        var projects: [String: DevProject] = [:]
        for server in servers {
            let path = server.folder ?? ""
            let name = path.isEmpty ? "Other listeners" : (path as NSString).lastPathComponent
            projects[path, default: DevProject(path: path, name: name, servers: [])].servers.append(server)
        }
        return projects.values.sorted { a, b in
            if a.path.isEmpty != b.path.isEmpty { return b.path.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The nearest folder at or above `path` that looks like a project. Home and / never count.
    func projectRoot(of path: String) -> String? {
        if let cached = folders[path] { return cached }
        let home = NSHomeDirectory()
        var current = path
        var found: String?
        let fm = FileManager.default
        while current != "/" && current != home && current.count > 1 {
            if Self.projectMarkers.contains(where: { fm.fileExists(atPath: current + "/" + $0) }) {
                found = current
                if fm.fileExists(atPath: current + "/.git") { break }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        if folders.count > 2000 { folders.removeAll() }
        folders[path] = found
        return found
    }

    struct Sockets {
        var listening: [ListeningPort] = []
        /// Local ports of established TCP connections.
        var established: [UInt16] = []
    }

    static func sockets(pid: Int32) -> Sockets {
        var result = Sockets()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return result }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return result }
        var info = socket_fdinfo()
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        var seen = Set<ListeningPort>()
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            switch tcp.tcpsi_state {
            case TSI_S_LISTEN:
                let port = ListeningPort(port: local, address: address(tcp.tcpsi_ini))
                if seen.insert(port).inserted { result.listening.append(port) }
            case TSI_S_ESTABLISHED:
                result.established.append(local)
            default: break
            }
        }
        return result
    }

    private static func address(_ ini: in_sockinfo) -> String {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
            return String(cString: buffer)
        }
        var addr = ini.insi_laddr.ina_6
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }
}
