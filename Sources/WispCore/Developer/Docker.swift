import Darwin
import Foundation

public struct Container: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    /// "host:container/proto" for each published port.
    public var ports: [String]
    public var project: String?
    /// The folder `docker compose` ran in, when it started the container.
    public var folder: String? = nil
    /// Fraction of one core, as `docker stats` shows it.
    public var cpu: Double?
    public var memory: UInt64?
    public var memoryLimit: UInt64?
    public var networkReceived: UInt64?
    public var networkSent: UInt64?
    /// Bytes per second over the last two readings.
    public var networkRate: Double? = nil
    public var diskRate: Double? = nil
    public var diskBytes: UInt64? = nil
}

/// What Docker keeps on disk, and how much of it nothing uses.
public struct DockerDiskUse: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public var count: Int
        public var inUse: Int
        public var size: UInt64
        public var reclaimable: UInt64
    }
    public var images: Part
    public var containers: Part
    public var volumes: Part
    public var buildCache: Part
    public var total: UInt64 { images.size + containers.size + volumes.size + buildCache.size }
    public var reclaimable: UInt64 { images.reclaimable + containers.reclaimable + volumes.reclaimable + buildCache.reclaimable }
}

public struct DockerStatus: Codable, Sendable, Equatable {
    /// The socket that answered, or nil when no engine is running.
    public var socket: String?
    public var containers: [Container]

    public init(socket: String?, containers: [Container]) {
        self.socket = socket
        self.containers = containers
    }
}

/// Talks to the Docker Engine API over its Unix socket. No `docker` CLI process,
/// no polling while nothing asks: each call is a handful of HTTP requests.
public enum Docker {
    static func candidateSockets() -> [String] {
        let home = NSHomeDirectory()
        var paths: [String] = []
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            paths.append(String(host.dropFirst(7)))
        }
        paths += [home + "/.docker/run/docker.sock", home + "/.orbstack/run/docker.sock", home + "/.colima/default/docker.sock",
                  home + "/.rd/docker.sock", "/var/run/docker.sock"]
        if let limas = try? FileManager.default.contentsOfDirectory(atPath: home + "/.lima") {
            paths += limas.map { home + "/.lima/\($0)/sock/docker.sock" }
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Running containers with live CPU and memory when `stats` is true. CPU needs
    /// two readings, so pass the same `watcher` each time; the first call has none.
    public static func status(stats: Bool = true, watcher: DockerWatcher? = nil) -> DockerStatus {
        for socket in candidateSockets() {
            guard let data = request("/containers/json", socket: socket),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            var containers = list.map(container)
            if stats {
                let group = DispatchGroup()
                let lock = NSLock()
                for index in containers.indices {
                    let id = containers[index].id
                    DispatchQueue.global(qos: .utility).async(group: group) {
                        guard let data = request("/containers/\(id)/stats?stream=false&one-shot=true", socket: socket),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                        lock.withLock {
                            apply(json, to: &containers[index])
                            watcher?.cpu(json, for: &containers[index])
                            watcher?.rates(for: &containers[index])
                        }
                    }
                }
                _ = group.wait(timeout: .now() + 3)
            }
            return DockerStatus(socket: socket, containers: containers.sorted { $0.name < $1.name })
        }
        return DockerStatus(socket: nil, containers: [])
    }

    private static func container(_ json: [String: Any]) -> Container {
        let names = (json["Names"] as? [String])?.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? []
        let ports = (json["Ports"] as? [[String: Any]] ?? []).compactMap { port -> String? in
            guard let privatePort = port["PrivatePort"] as? Int else { return nil }
            let type = port["Type"] as? String ?? "tcp"
            if let publicPort = port["PublicPort"] as? Int { return "\(publicPort):\(privatePort)/\(type)" }
            return nil
        }
        let labels = json["Labels"] as? [String: String] ?? [:]
        return Container(id: String((json["Id"] as? String ?? "").prefix(12)), name: names.first ?? "?",
                         image: json["Image"] as? String ?? "", state: json["State"] as? String ?? "",
                         status: json["Status"] as? String ?? "", ports: Array(Set(ports)).sorted(),
                         project: labels["com.docker.compose.project"], folder: labels["com.docker.compose.project.working_dir"])
    }

    private static func apply(_ json: [String: Any], to container: inout Container) {
        if container.cpu == nil, let cpu = json["cpu_stats"] as? [String: Any], let pre = json["precpu_stats"] as? [String: Any],
           let total = (cpu["cpu_usage"] as? [String: Any])?["total_usage"] as? Double,
           let preTotal = (pre["cpu_usage"] as? [String: Any])?["total_usage"] as? Double,
           let system = cpu["system_cpu_usage"] as? Double, let preSystem = pre["system_cpu_usage"] as? Double,
           preSystem > 0, system > preSystem {
            let cpus = cpu["online_cpus"] as? Double ?? 1
            container.cpu = (total - preTotal) / (system - preSystem) * cpus
        }
        if let memory = json["memory_stats"] as? [String: Any], let usage = memory["usage"] as? Double {
            let cache = (memory["stats"] as? [String: Any])?["inactive_file"] as? Double ?? 0
            container.memory = UInt64(max(0, usage - cache))
            container.memoryLimit = (memory["limit"] as? Double).map { UInt64($0) }
        }
        if let networks = json["networks"] as? [String: [String: Any]] {
            container.networkReceived = UInt64(networks.values.reduce(0) { $0 + ($1["rx_bytes"] as? Double ?? 0) })
            container.networkSent = UInt64(networks.values.reduce(0) { $0 + ($1["tx_bytes"] as? Double ?? 0) })
        }
        if let io = (json["blkio_stats"] as? [String: Any])?["io_service_bytes_recursive"] as? [[String: Any]] {
            container.diskBytes = UInt64(io.reduce(0) { $0 + ($1["value"] as? Double ?? 0) })
        }
    }

    /// A bare HTTP/1.1 GET over a Unix socket with a one-second timeout.
    static func request(_ path: String, socket socketPath: String, method: String = "GET", timeout seconds: Int = 1) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }

        let request = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        guard request.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            response.append(buffer, count: n)
            if response.count > 8_000_000 { return nil }
        }
        return body(of: response)
    }

    /// Stops or restarts a container. Returns false when the engine refused or is not running.
    public static func perform(_ action: String, container id: String) -> Bool {
        guard ["stop", "restart", "start"].contains(action) else { return false }
        for socket in candidateSockets() {
            if request("/containers/\(id)/\(action)", socket: socket, method: "POST", timeout: 15) != nil { return true }
        }
        return false
    }

    /// Disk use by images, containers, volumes and build cache. The engine adds
    /// it up on request, which can take a few seconds; call it rarely.
    public static func diskUse() -> DockerDiskUse? {
        for socket in candidateSockets() {
            guard let data = request("/system/df", socket: socket, timeout: 20),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            func number(_ value: Any?) -> UInt64 { UInt64(max(0, (value as? Double) ?? Double((value as? Int) ?? 0))) }
            let images = json["Images"] as? [[String: Any]] ?? []
            let imagesInUse = images.filter { (($0["Containers"] as? Int) ?? 0) > 0 }
            let containers = json["Containers"] as? [[String: Any]] ?? []
            let running = containers.filter { ($0["State"] as? String) == "running" }
            let volumes = json["Volumes"] as? [[String: Any]] ?? []
            let volumeSize: ([String: Any]) -> UInt64 = { number(($0["UsageData"] as? [String: Any])?["Size"]) }
            let volumesInUse = volumes.filter { ((($0["UsageData"] as? [String: Any])?["RefCount"] as? Int) ?? 0) > 0 }
            let cache = json["BuildCache"] as? [[String: Any]] ?? []
            let cacheInUse = cache.filter { ($0["InUse"] as? Bool) == true }
            let imageTotal = images.reduce(0) { $0 + number($1["Size"]) }
            return DockerDiskUse(
                images: .init(count: images.count, inUse: imagesInUse.count, size: imageTotal,
                              reclaimable: imageTotal - min(imageTotal, imagesInUse.reduce(0) { $0 + number($1["Size"]) })),
                containers: .init(count: containers.count, inUse: running.count, size: containers.reduce(0) { $0 + number($1["SizeRw"]) },
                                  reclaimable: containers.filter { ($0["State"] as? String) != "running" }.reduce(0) { $0 + number($1["SizeRw"]) }),
                volumes: .init(count: volumes.count, inUse: volumesInUse.count, size: volumes.reduce(0) { $0 + volumeSize($1) },
                               reclaimable: volumes.filter { ((($0["UsageData"] as? [String: Any])?["RefCount"] as? Int) ?? 0) == 0 }
                                   .reduce(0) { $0 + volumeSize($1) }),
                buildCache: .init(count: cache.count, inUse: cacheInUse.count, size: cache.reduce(0) { $0 + number($1["Size"]) },
                                  reclaimable: cache.filter { ($0["InUse"] as? Bool) != true }.reduce(0) { $0 + number($1["Size"]) }))
        }
        return nil
    }

    /// The engine's name for the socket that answered: Docker Desktop, OrbStack, Colima...
    public static func engineName(_ socket: String) -> String {
        if socket.contains("/.orbstack/") { return "OrbStack" }
        if socket.contains("/.colima/") { return "Colima" }
        if socket.contains("/.rd/") { return "Rancher Desktop" }
        if socket.contains("/.lima/") { return "Lima" }
        return "Docker"
    }

    static func body(of response: Data) -> Data? {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: response[..<split.lowerBound], as: UTF8.self).lowercased()
        guard header.hasPrefix("http/1.1 2") || header.hasPrefix("http/1.0 2") else { return nil }
        let body = response[split.upperBound...]
        guard header.contains("transfer-encoding: chunked") else { return Data(body) }
        var result = Data()
        var index = body.startIndex
        while index < body.endIndex {
            guard let lineEnd = body[index...].range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: body[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = body.index(start, offsetBy: size, limitedBy: body.endIndex) else { break }
            result.append(body[start..<end])
            index = min(body.endIndex, body.index(end, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex)
        }
        return result
    }
}

/// Remembers each container's last CPU counters so a one-shot stats call can be
/// turned into a rate, instead of asking the engine to sample for a second.
public final class DockerWatcher: @unchecked Sendable {
    private var last: [String: (total: Double, system: Double)] = [:]
    private var lastBytes: [String: (network: UInt64, disk: UInt64, at: Date)] = [:]

    public init() {}

    func rates(for container: inout Container, now: Date = Date()) {
        let network = (container.networkReceived ?? 0) + (container.networkSent ?? 0)
        let disk = container.diskBytes ?? 0
        defer { lastBytes[container.id] = (network, disk, now) }
        guard let previous = lastBytes[container.id] else { return }
        let span = now.timeIntervalSince(previous.at)
        guard span > 0.2 else { return }
        container.networkRate = network >= previous.network ? Double(network - previous.network) / span : nil
        container.diskRate = disk >= previous.disk ? Double(disk - previous.disk) / span : nil
    }

    func cpu(_ json: [String: Any], for container: inout Container) {
        guard let cpu = json["cpu_stats"] as? [String: Any],
              let total = (cpu["cpu_usage"] as? [String: Any])?["total_usage"] as? Double,
              let system = cpu["system_cpu_usage"] as? Double else { return }
        defer { last[container.id] = (total, system) }
        guard let previous = last[container.id], system > previous.system else { return }
        let cpus = cpu["online_cpus"] as? Double ?? 1
        container.cpu = (total - previous.total) / (system - previous.system) * cpus
    }
}
