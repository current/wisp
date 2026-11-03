import Darwin
import Foundation

/// An IP address and port.
public struct NetworkEndpoint: Hashable, Sendable, Codable {
    public var address: String
    public var port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// From a `sockaddr_in` or `sockaddr_in6` as NetworkStatistics hands it over.
    init?(sockaddr data: Data) {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        let family = Int32(bytes[1])
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if family == AF_INET {
            guard let text = Self.text(AF_INET, Array(bytes[4..<8])) else { return nil }
            self.init(address: text, port: port)
        } else if family == AF_INET6, bytes.count >= 24 {
            guard let text = Self.text(AF_INET6, Array(bytes[8..<24])) else { return nil }
            self.init(address: Self.unmapped(text), port: port)
        } else {
            return nil
        }
    }

    /// No address at all: an unconnected socket's far end.
    public var isUnspecified: Bool { address == "0.0.0.0" || address == "::" || address.isEmpty }
    public var isLoopback: Bool { address.hasPrefix("127.") || address == "::1" }

    /// Private, link-local and carrier-grade NAT ranges: this network, not the internet.
    public var isLocalNetwork: Bool {
        let a = address
        if a.hasPrefix("10.") || a.hasPrefix("192.168.") || a.hasPrefix("169.254.") || a.lowercased().hasPrefix("fe80:") { return true }
        if a.lowercased().hasPrefix("fd") || a.lowercased().hasPrefix("fc") { return a.contains(":") }
        let parts = a.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 100, (64...127).contains(parts[1]) { return true }
        return false
    }

    static func text(_ family: Int32, _ raw: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = raw.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) != nil }
        return ok ? String(cString: buffer) : nil
    }

    /// "::ffff:1.2.3.4" reads as "1.2.3.4".
    static func unmapped(_ text: String) -> String {
        text.hasPrefix("::ffff:") && text.contains(".") ? String(text.dropFirst(7)) : text
    }
}

/// One TCP or UDP flow as NetworkStatistics counts it.
public struct NetworkFlow: Sendable, Equatable {
    public var id: UInt
    /// The process holding the socket.
    public var pid: Int32
    /// The app it is counted under: itself, or the app a daemon works for.
    public var owner: Int32
    public var isUDP: Bool
    public var local: NetworkEndpoint?
    public var remote: NetworkEndpoint?
    public var tcpState: String
    /// Bytes since the flow opened, every interface.
    public var received: UInt64
    public var sent: UInt64

    public init(id: UInt, pid: Int32, owner: Int32, isUDP: Bool, local: NetworkEndpoint?, remote: NetworkEndpoint?,
                tcpState: String, received: UInt64, sent: UInt64) {
        (self.id, self.pid, self.owner, self.isUDP, self.local, self.remote) = (id, pid, owner, isUDP, local, remote)
        (self.tcpState, self.received, self.sent) = (tcpState, received, sent)
    }
}

/// A socket of an app, with the flow's byte counts when NetworkStatistics has them.
public struct AppConnection: Sendable, Equatable {
    public enum Direction: String, Sendable { case listening, outgoing, incoming }

    public var pid: Int32
    public var isUDP: Bool
    public var local: NetworkEndpoint
    public var remote: NetworkEndpoint?
    /// "Open", "Connecting", "Closing", "Listening" or "" for UDP.
    public var state: String
    public var direction: Direction
    public var received: UInt64
    public var sent: UInt64
    public var receivedPerSecond: Double = 0
    public var sentPerSecond: Double = 0
    /// False when no flow was found for the socket, so the byte counts are unknown.
    public var measured: Bool

    public var protocolName: String { isUDP ? "UDP" : "TCP" }
    public var bytes: UInt64 { received &+ sent }
    public var perSecond: Double { receivedPerSecond + sentPerSecond }

    public init(pid: Int32, isUDP: Bool, local: NetworkEndpoint, remote: NetworkEndpoint?, state: String,
                direction: Direction, received: UInt64, sent: UInt64, measured: Bool) {
        (self.pid, self.isUDP, self.local, self.remote, self.state) = (pid, isUDP, local, remote, state)
        (self.direction, self.received, self.sent, self.measured) = (direction, received, sent, measured)
    }
}

/// Lists the sockets of a few processes and joins them with the flows
/// NetworkStatistics counts, so each connection gets its bytes and rate.
///
/// Meant for one app at a time: one `PROC_PIDLISTFDS` per process plus one
/// `PROC_PIDFDSOCKETINFO` per socket, no root. Not thread-safe; use it from one queue.
public final class ConnectionSampler {
    private struct Key: Hashable {
        var pid: Int32
        var isUDP: Bool
        var local: UInt16
        var remote: NetworkEndpoint?
    }

    private var previous: [Key: (received: UInt64, sent: UInt64)] = [:]
    private var previousAt: Date?

    public init() {}

    public func reset() {
        previous = [:]
        previousAt = nil
    }

    /// The connections of `pids`. `flows` are the app's flows (nil when per-app
    /// network is off); flows that daemons hold for the app are listed under the daemon's pid.
    public func sample(pids: [Int32], flows: [NetworkFlow]?, now: Date = Date()) -> [AppConnection] {
        var sockets: [AppConnection] = []
        for pid in pids { sockets += Self.sockets(pid: pid) }
        let joined = Self.join(sockets: sockets, flows: flows ?? [], measured: flows != nil)
        return rated(joined, now: now)
    }

    /// Rates from the change since the previous sample of the same connection.
    func rated(_ connections: [AppConnection], now: Date) -> [AppConnection] {
        let seconds = previousAt.map { now.timeIntervalSince($0) } ?? 0
        var next: [Key: (UInt64, UInt64)] = [:]
        var result = connections
        for index in result.indices {
            let c = result[index]
            let key = Key(pid: c.pid, isUDP: c.isUDP, local: c.local.port, remote: c.remote)
            next[key] = (c.received, c.sent)
            if seconds > 0.2, let old = previous[key] {
                result[index].receivedPerSecond = Double(c.received &- min(old.received, c.received)) / seconds
                result[index].sentPerSecond = Double(c.sent &- min(old.sent, c.sent)) / seconds
            }
        }
        previous = next
        previousAt = now
        return result
    }

    /// Gives each socket the counts of its flow, then adds flows with no socket
    /// in these processes: daemons working for the app, sockets just closed.
    static func join(sockets: [AppConnection], flows: [NetworkFlow], measured: Bool) -> [AppConnection] {
        struct FlowKey: Hashable { var isUDP: Bool; var local: UInt16; var remote: NetworkEndpoint? }
        var byKey: [FlowKey: [Int]] = [:]
        for (index, flow) in flows.enumerated() {
            guard let local = flow.local else { continue }
            let remote = flow.remote.flatMap { $0.isUnspecified ? nil : $0 }
            byKey[FlowKey(isUDP: flow.isUDP, local: local.port, remote: remote), default: []].append(index)
        }
        var used = Set<Int>()
        var result: [AppConnection] = []
        let listening = Set(sockets.filter { $0.direction == .listening && !$0.isUDP }.map(\.local.port))
        for var socket in sockets {
            let key = FlowKey(isUDP: socket.isUDP, local: socket.local.port, remote: socket.remote)
            if let match = byKey[key]?.first(where: { !used.contains($0) && flows[$0].pid == socket.pid })
                ?? byKey[key]?.first(where: { !used.contains($0) }) {
                used.insert(match)
                socket.received = flows[match].received
                socket.sent = flows[match].sent
                socket.measured = true
            } else {
                socket.measured = measured && socket.direction == .listening
            }
            if socket.direction == .outgoing, !socket.isUDP, listening.contains(socket.local.port) { socket.direction = .incoming }
            result.append(socket)
        }
        for (index, flow) in flows.enumerated() where !used.contains(index) {
            guard let local = flow.local, let remote = flow.remote, !remote.isUnspecified else { continue }
            let state = flow.isUDP ? "" : stateName(flow.tcpState)
            guard flow.isUDP || state != "Closed" else { continue }
            let direction: AppConnection.Direction = !flow.isUDP && listening.contains(local.port) ? .incoming : .outgoing
            result.append(AppConnection(pid: flow.pid, isUDP: flow.isUDP, local: local, remote: remote, state: state,
                                        direction: direction, received: flow.received, sent: flow.sent, measured: true))
        }
        return result
    }

    static func stateName(_ nstat: String) -> String {
        switch nstat {
        case "Established": return "Open"
        case "Listen": return "Listening"
        case "SynSent", "SynReceived": return "Connecting"
        case "Closed": return "Closed"
        case "": return ""
        default: return "Closing"
        }
    }

    static func stateName(_ tsi: Int32) -> String {
        switch tsi {
        case TSI_S_LISTEN: return "Listening"
        case TSI_S_ESTABLISHED: return "Open"
        case TSI_S_SYN_SENT, TSI_S_SYN_RECEIVED: return "Connecting"
        case TSI_S_CLOSED: return "Closed"
        default: return "Closing"
        }
    }

    /// The TCP and UDP sockets of one process, read the way the dev server scan reads listeners.
    static func sockets(pid: Int32) -> [AppConnection] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var info = socket_fdinfo()
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        var result: [AppConnection] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            let family = info.psi.soi_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            switch Int(info.psi.soi_kind) {
            case SOCKINFO_TCP:
                let tcp = info.psi.soi_proto.pri_tcp
                let ini = tcp.tcpsi_ini
                let state = stateName(tcp.tcpsi_state)
                guard state != "Closed" else { continue }
                let local = endpoint(ini, local: true)
                if tcp.tcpsi_state == TSI_S_LISTEN {
                    result.append(AppConnection(pid: pid, isUDP: false, local: local, remote: nil, state: state,
                                                direction: .listening, received: 0, sent: 0, measured: false))
                } else {
                    result.append(AppConnection(pid: pid, isUDP: false, local: local, remote: endpoint(ini, local: false),
                                                state: state, direction: .outgoing, received: 0, sent: 0, measured: false))
                }
            case SOCKINFO_IN:
                let ini = info.psi.soi_proto.pri_in
                let local = endpoint(ini, local: true)
                guard local.port != 0 else { continue }
                let remote = endpoint(ini, local: false)
                let connected = !remote.isUnspecified && remote.port != 0
                result.append(AppConnection(pid: pid, isUDP: true, local: local, remote: connected ? remote : nil, state: "",
                                            direction: connected ? .outgoing : .listening, received: 0, sent: 0, measured: false))
            default:
                continue
            }
        }
        return result
    }

    private static func endpoint(_ ini: in_sockinfo, local: Bool) -> NetworkEndpoint {
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: local ? ini.insi_lport : ini.insi_fport))
        var address: String?
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = local ? ini.insi_laddr.ina_46.i46a_addr4 : ini.insi_faddr.ina_46.i46a_addr4
            address = withUnsafeBytes(of: &addr) { NetworkEndpoint.text(AF_INET, Array($0)) }
        } else {
            var addr = local ? ini.insi_laddr.ina_6 : ini.insi_faddr.ina_6
            address = withUnsafeBytes(of: &addr) { NetworkEndpoint.text(AF_INET6, Array($0)) }.map(NetworkEndpoint.unmapped)
        }
        return NetworkEndpoint(address: address ?? "", port: port)
    }
}
