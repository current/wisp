import Darwin
import Foundation

/// Reverse-DNS names for remote addresses, looked up in the background.
///
/// `name(for:)` never blocks: it answers from the cache or queues a lookup and
/// returns nil. Lookups are deduplicated, at most `maxInFlight` run at once on a
/// utility queue, and the queue holds at most `maxQueued` addresses; callers ask
/// again on their next tick. Answers stay for `ttl`, misses for `missTTL`.
/// Lookups go to the Mac's own resolver, the same as `host` or `nslookup`.
public final class HostNames: @unchecked Sendable {
    public static let shared = HostNames()

    public let ttl: TimeInterval
    public let missTTL: TimeInterval
    public let maxInFlight: Int
    public let maxQueued: Int
    private let resolve: @Sendable (String) -> String?
    private let lock = NSLock()
    private var cache: [String: (name: String?, until: Date)] = [:]
    private var queued: [String] = []
    private var running = Set<String>()
    private let workers = DispatchQueue(label: "app.wisp.hostnames", qos: .utility, attributes: .concurrent)
    private let maxCached = 4000

    public init(ttl: TimeInterval = 3600, missTTL: TimeInterval = 600, maxInFlight: Int = 3, maxQueued: Int = 48,
                resolve: @escaping @Sendable (String) -> String? = HostNames.reverseLookup) {
        self.ttl = ttl
        self.missTTL = missTTL
        self.maxInFlight = maxInFlight
        self.maxQueued = maxQueued
        self.resolve = resolve
    }

    /// The cached name, or nil while unknown (a lookup is then queued).
    public func name(for address: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[address], hit.until > now { return hit.name }
        guard !running.contains(address), !queued.contains(address), queued.count < maxQueued else { return nil }
        queued.append(address)
        startNext()
        return nil
    }

    /// True once a lookup for the address has finished, with or without a name.
    public func isResolved(_ address: String, now: Date = Date()) -> Bool {
        lock.withLock { (cache[address]?.until ?? .distantPast) > now }
    }

    /// Drops lookups not started yet, for when nothing on screen needs them.
    public func cancelQueued() {
        lock.withLock { queued.removeAll() }
    }

    public var inFlight: Int { lock.withLock { running.count } }

    // Called with the lock held.
    private func startNext() {
        while running.count < maxInFlight, !queued.isEmpty {
            let address = queued.removeFirst()
            running.insert(address)
            workers.async { [self] in
                let name = resolve(address)
                lock.withLock {
                    running.remove(address)
                    if cache.count > maxCached { cache = cache.filter { $0.value.until > Date() } }
                    cache[address] = (name, Date().addingTimeInterval(name == nil ? missTTL : ttl))
                    startNext()
                }
            }
        }
    }

    /// `getnameinfo` with NI_NAMEREQD: a PTR name or nothing.
    public static let reverseLookup: @Sendable (String) -> String? = { address in
        var storage = sockaddr_storage()
        var length: socklen_t = 0
        if address.contains(":") {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, address, &sin6.sin6_addr) == 1 else { return nil }
            withUnsafeBytes(of: sin6) { raw in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) } }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return nil }
            withUnsafeBytes(of: sin) { raw in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) } }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty || name == address ? nil : name
    }
}

/// What to call a remote end: a service everyone knows, its DNS name or its address.
public enum HostLabel {
    /// Name suffixes of the big hosting and service networks.
    static let services: [(suffix: String, name: String)] = [
        ("1e100.net", "Google"), ("google.com", "Google"), ("googleusercontent.com", "Google Cloud"),
        ("googlevideo.com", "YouTube"), ("youtube.com", "YouTube"),
        ("apple.com", "Apple"), ("aaplimg.com", "Apple"), ("icloud.com", "iCloud"), ("mzstatic.com", "Apple"),
        ("amazonaws.com", "Amazon Web Services"), ("cloudfront.net", "Amazon CloudFront"), ("amazon.com", "Amazon"),
        ("akamaitechnologies.com", "Akamai"), ("akamaiedge.net", "Akamai"), ("akamai.net", "Akamai"),
        ("cloudflare.com", "Cloudflare"), ("cloudflare.net", "Cloudflare"),
        ("fastly.net", "Fastly"), ("fbcdn.net", "Meta"), ("facebook.com", "Meta"),
        ("github.com", "GitHub"), ("githubusercontent.com", "GitHub"),
        ("microsoft.com", "Microsoft"), ("msedge.net", "Microsoft"), ("azure.com", "Microsoft Azure"),
        ("cloudapp.net", "Microsoft Azure"), ("1drv.com", "OneDrive"),
        ("spotify.com", "Spotify"), ("slack.com", "Slack"), ("zoom.us", "Zoom"), ("dropbox.com", "Dropbox"),
        ("anthropic.com", "Anthropic"), ("openai.com", "OpenAI"), ("discord.gg", "Discord"), ("discord.com", "Discord"),
        ("netflix.com", "Netflix"), ("nflxvideo.net", "Netflix"), ("twitch.tv", "Twitch"), ("vercel.com", "Vercel"),
    ]

    /// Well-known ports by what they carry.
    static let ports: [UInt16: String] = [
        20: "FTP", 21: "FTP", 22: "SSH", 25: "SMTP", 53: "DNS", 80: "HTTP", 110: "POP3", 123: "NTP", 143: "IMAP",
        443: "HTTPS", 465: "SMTP", 587: "SMTP", 993: "IMAP", 995: "POP3", 853: "DNS over TLS", 1194: "OpenVPN",
        3478: "STUN", 5223: "Apple Push", 5228: "Google Push", 5353: "Bonjour", 51820: "WireGuard",
        3389: "Remote Desktop", 5900: "Screen Sharing", 8080: "HTTP", 8443: "HTTPS",
    ]

    /// Address prefixes of networks that often have no reverse-DNS names.
    static let prefixes: [(prefix: String, name: String)] = [
        ("17.", "Apple"), ("2620:149:", "Apple"), ("2a01:b740:", "Apple"), ("2403:300:", "Apple"),
        ("2606:4700:", "Cloudflare"), ("2a06:98c0:", "Cloudflare"), ("104.16.", "Cloudflare"), ("104.17.", "Cloudflare"),
        ("104.18.", "Cloudflare"), ("104.19.", "Cloudflare"), ("104.20.", "Cloudflare"), ("104.21.", "Cloudflare"),
        ("172.64.", "Cloudflare"), ("172.65.", "Cloudflare"), ("172.66.", "Cloudflare"), ("172.67.", "Cloudflare"),
        ("162.158.", "Cloudflare"), ("162.159.", "Cloudflare"),
        ("2607:f8b0:", "Google"), ("2001:4860:", "Google"), ("2a00:1450:", "Google"), ("2404:6800:", "Google"), ("2800:3f0:", "Google"),
        ("142.250.", "Google"), ("142.251.", "Google"), ("172.217.", "Google"), ("216.58.", "Google"), ("74.125.", "Google"),
        ("151.101.", "Fastly"), ("2a04:4e42:", "Fastly"), ("140.82.", "GitHub"), ("185.199.", "GitHub"),
        ("2a03:2880:", "Meta"), ("157.240.", "Meta"), ("31.13.", "Meta"),
    ]

    public static func service(address: String) -> String? {
        let lower = address.lowercased()
        return prefixes.first { lower.hasPrefix($0.prefix) }?.name
    }

    public static func service(port: UInt16) -> String? { ports[port] }

    /// The service a DNS name belongs to, if it is a well-known one.
    public static func service(host: String) -> String? {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return services.first { lower == $0.suffix || lower.hasSuffix("." + $0.suffix) }?.name
    }

    /// The name to show and group by.
    public static func name(for endpoint: NetworkEndpoint, dns: String?) -> String {
        if endpoint.isLoopback { return "This Mac" }
        if let dns, let known = service(host: dns) { return known }
        if let known = service(address: endpoint.address) { return known }
        if let dns { return dns.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return endpoint.address
    }

    /// Whether a lookup is worth making: loopback and the known ranges are already named.
    public static func wantsLookup(_ endpoint: NetworkEndpoint) -> Bool {
        !endpoint.isLoopback && !endpoint.isUnspecified && service(address: endpoint.address) == nil
    }
}

/// Connections of one remote host, for the lists.
public struct HostGroup: Sendable, Equatable {
    public var name: String
    /// The DNS names or addresses behind the name.
    public var addresses: [String]
    public var connections: [AppConnection]
    public var received: UInt64
    public var sent: UInt64
    public var perSecond: Double
    public var isLocalNetwork: Bool

    public var bytes: UInt64 { received &+ sent }

    /// Groups connections with a far end by `label`, most bytes first. Bytes change
    /// slowly, so the order stays put between ticks; the rate breaks ties.
    public static func group(_ connections: [AppConnection], label: (NetworkEndpoint) -> String,
                             detail: (NetworkEndpoint) -> String = { $0.address }) -> [HostGroup] {
        var groups: [String: HostGroup] = [:]
        var order: [String] = []
        for connection in connections {
            guard let remote = connection.remote, !remote.isUnspecified else { continue }
            let name = label(remote)
            if groups[name] == nil {
                groups[name] = HostGroup(name: name, addresses: [], connections: [], received: 0, sent: 0, perSecond: 0,
                                         isLocalNetwork: remote.isLocalNetwork)
                order.append(name)
            }
            groups[name]!.connections.append(connection)
            groups[name]!.received &+= connection.received
            groups[name]!.sent &+= connection.sent
            groups[name]!.perSecond += connection.perSecond
            let shown = detail(remote)
            if !groups[name]!.addresses.contains(shown) { groups[name]!.addresses.append(shown) }
        }
        return order.compactMap { groups[$0] }.sorted { a, b in
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            if a.perSecond != b.perSecond { return a.perSecond > b.perSecond }
            return a.name < b.name
        }
    }
}
