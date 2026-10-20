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
    /// Fraction of one core, as `docker stats` shows it.
    public var cpu: Double?
    public var memory: UInt64?
    public var memoryLimit: UInt64?
    public var networkReceived: UInt64?
    public var networkSent: UInt64?
}

public struct DockerStatus: Codable, Sendable, Equatable {
    /// The socket that answered, or nil when no engine is running.
    public var socket: String?
    public var containers: [Container]
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
                         project: labels["com.docker.compose.project"])
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
    }

    /// A bare HTTP/1.1 GET over a Unix socket with a one-second timeout.
    static func request(_ path: String, socket socketPath: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
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

        let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
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

    public init() {}

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
