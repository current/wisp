import Darwin
import Foundation
import Testing
@testable import WispCore

// MARK: Endpoints

@Test func endpointParsesSockaddrs() {
    // sockaddr_in for 93.184.216.34:443
    var v4 = Data([16, UInt8(AF_INET), 0x01, 0xBB, 93, 184, 216, 34])
    v4.append(Data(count: 8))
    #expect(NetworkEndpoint(sockaddr: v4) == NetworkEndpoint(address: "93.184.216.34", port: 443))

    // sockaddr_in6 for [2606:4700::1]:8443
    var v6 = Data([28, UInt8(AF_INET6), 0x20, 0xFB, 0, 0, 0, 0])
    v6.append(Data([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [1]))
    v6.append(Data(count: 4))
    #expect(NetworkEndpoint(sockaddr: v6) == NetworkEndpoint(address: "2606:4700::1", port: 8443))

    // An IPv4 address mapped into IPv6 reads as IPv4.
    var mapped = Data([28, UInt8(AF_INET6), 0, 80, 0, 0, 0, 0])
    mapped.append(Data([UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 10, 0, 0, 7]))
    mapped.append(Data(count: 4))
    #expect(NetworkEndpoint(sockaddr: mapped)?.address == "10.0.0.7")
    #expect(NetworkEndpoint(sockaddr: Data([1, 2])) == nil)
}

@Test func endpointRanges() {
    #expect(NetworkEndpoint(address: "127.0.0.1", port: 1).isLoopback)
    #expect(NetworkEndpoint(address: "::1", port: 1).isLoopback)
    #expect(NetworkEndpoint(address: "192.168.1.4", port: 1).isLocalNetwork)
    #expect(NetworkEndpoint(address: "172.20.0.1", port: 1).isLocalNetwork)
    #expect(!NetworkEndpoint(address: "172.64.0.1", port: 1).isLocalNetwork)
    #expect(NetworkEndpoint(address: "100.100.1.1", port: 1).isLocalNetwork)
    #expect(NetworkEndpoint(address: "::", port: 0).isUnspecified)
}

// MARK: Joining sockets with flows

private func socket(_ pid: Int32, local: UInt16, remote: String?, port: UInt16 = 443, udp: Bool = false,
                    listening: Bool = false) -> AppConnection {
    AppConnection(pid: pid, isUDP: udp, local: NetworkEndpoint(address: "192.168.1.2", port: local),
                  remote: remote.map { NetworkEndpoint(address: $0, port: port) }, state: listening ? "Listening" : (udp ? "" : "Open"),
                  direction: listening ? .listening : .outgoing, received: 0, sent: 0, measured: false)
}

private func flow(_ id: UInt, pid: Int32, owner: Int32? = nil, local: UInt16, remote: String?, port: UInt16 = 443,
                  udp: Bool = false, rx: UInt64, tx: UInt64) -> NetworkFlow {
    NetworkFlow(id: id, pid: pid, owner: owner ?? pid, isUDP: udp, local: NetworkEndpoint(address: "192.168.1.2", port: local),
                remote: remote.map { NetworkEndpoint(address: $0, port: port) }, tcpState: "Established", received: rx, sent: tx)
}

@Test func joinGivesSocketsTheirFlowBytes() {
    let sockets = [socket(10, local: 50000, remote: "1.1.1.1"), socket(10, local: 50001, remote: "8.8.8.8"),
                   socket(10, local: 3000, remote: nil, listening: true), socket(10, local: 3000, remote: "192.168.1.9", port: 61000)]
    let flows = [flow(1, pid: 10, local: 50000, remote: "1.1.1.1", rx: 500, tx: 20),
                 // nsurlsessiond (pid 99) downloading for the app: no socket in the app's processes.
                 flow(2, pid: 99, owner: 10, local: 50100, remote: "17.1.2.3", rx: 9000, tx: 100)]
    let joined = ConnectionSampler.join(sockets: sockets, flows: flows, measured: true)
    #expect(joined.count == 5)
    let first = joined.first { $0.local.port == 50000 }!
    #expect(first.received == 500 && first.sent == 20 && first.measured)
    let unmatched = joined.first { $0.local.port == 50001 }!
    #expect(!unmatched.measured && unmatched.bytes == 0)
    // A connection to the app's own listening port is incoming.
    #expect(joined.first { $0.remote?.port == 61000 }?.direction == .incoming)
    let delegated = joined.first { $0.pid == 99 }!
    #expect(delegated.received == 9000 && delegated.direction == .outgoing)
}

@Test func joinMatchesUnconnectedUDPByLocalPort() {
    let sockets = [socket(10, local: 5353, remote: nil, udp: true, listening: true)]
    let flows = [flow(1, pid: 10, local: 5353, remote: "::", udp: true, rx: 64, tx: 32)]
    let joined = ConnectionSampler.join(sockets: sockets, flows: flows, measured: true)
    #expect(joined.count == 1)
    #expect(joined[0].bytes == 96 && joined[0].direction == .listening)
}

@Test func samplerRatesFromChange() {
    let sampler = ConnectionSampler()
    let start = Date(timeIntervalSince1970: 1_000_000)
    var c = socket(10, local: 50000, remote: "1.1.1.1")
    c.received = 1000
    c.sent = 100
    _ = sampler.rated([c], now: start)
    c.received = 5000
    c.sent = 300
    let rated = sampler.rated([c], now: start.addingTimeInterval(2))
    #expect(rated[0].receivedPerSecond == 2000)
    #expect(rated[0].sentPerSecond == 100)
    sampler.reset()
    #expect(sampler.rated([c], now: start.addingTimeInterval(4))[0].perSecond == 0)
}

@Test func listsOwnSockets() throws {
    // A listening socket of this test process shows up as listening TCP.
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    try #require(bound == 0 && listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    let port = UInt16(bigEndian: address.sin_port)
    let sockets = ConnectionSampler.sockets(pid: getpid())
    let mine = sockets.first { $0.local.port == port }
    #expect(mine?.direction == .listening)
    #expect(mine?.local.isLoopback == true)
    #expect(mine?.isUDP == false)
}

// MARK: Host names

@Test func hostLabels() {
    let google = NetworkEndpoint(address: "142.250.1.1", port: 443)
    #expect(HostLabel.name(for: google, dns: nil) == "Google")
    #expect(!HostLabel.wantsLookup(google))
    let other = NetworkEndpoint(address: "203.0.113.5", port: 443)
    #expect(HostLabel.name(for: other, dns: "lhr25s34-in-f14.1e100.net.") == "Google")
    #expect(HostLabel.name(for: other, dns: "cdn.example.org.") == "cdn.example.org")
    #expect(HostLabel.name(for: other, dns: nil) == "203.0.113.5")
    #expect(HostLabel.name(for: NetworkEndpoint(address: "127.0.0.1", port: 80), dns: nil) == "This Mac")
    #expect(HostLabel.service(host: "notgithub.com") == nil)
    #expect(HostLabel.service(port: 443) == "HTTPS")
}

private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    var concurrent = 0
    var peak = 0
}

@Test func hostNamesAreCachedDedupedAndCapped() async throws {
    let counter = Counter()
    let names = HostNames(ttl: 60, missTTL: 60, maxInFlight: 2, maxQueued: 3) { address in
        counter.lock.withLock {
            counter.calls.append(address)
            counter.concurrent += 1
            counter.peak = max(counter.peak, counter.concurrent)
        }
        Thread.sleep(forTimeInterval: 0.05)
        counter.lock.withLock { counter.concurrent -= 1 }
        return address == "1.1.1.1" ? "one.one.one.one" : nil
    }
    for _ in 0..<5 { #expect(names.name(for: "1.1.1.1") == nil) }
    for address in ["2.2.2.2", "3.3.3.3", "4.4.4.4", "5.5.5.5", "6.6.6.6"] { _ = names.name(for: address) }
    for _ in 0..<100 where names.inFlight > 0 || !names.isResolved("1.1.1.1") { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(150))
    #expect(names.name(for: "1.1.1.1") == "one.one.one.one")
    let calls = counter.lock.withLock { counter.calls }
    #expect(calls.filter { $0 == "1.1.1.1" }.count == 1)
    // Two ran at once at most; the queue held at most three more, the rest were dropped.
    #expect(counter.lock.withLock { counter.peak } <= 2)
    #expect(calls.count <= 5)
    // A miss is cached too.
    #expect(names.isResolved("2.2.2.2"))
    #expect(names.name(for: "2.2.2.2") == nil)
    #expect(counter.lock.withLock { counter.calls }.filter { $0 == "2.2.2.2" }.count == 1)
}

@Test func hostGroupsMergeByLabelAndSortByBytes() {
    var a = socket(1, local: 1, remote: "142.250.1.1"); a.received = 100
    var b = socket(1, local: 2, remote: "142.251.9.9"); b.received = 300
    var c = socket(2, local: 3, remote: "203.0.113.5"); c.received = 200
    let listening = socket(1, local: 80, remote: nil, listening: true)
    let groups = HostGroup.group([a, b, c, listening], label: { HostLabel.name(for: $0, dns: nil) })
    #expect(groups.map(\.name) == ["Google", "203.0.113.5"])
    #expect(groups[0].bytes == 400 && groups[0].connections.count == 2 && groups[0].addresses.count == 2)
}

// MARK: Data used per app

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}

@Test func dataUsageAddsMeasuredPassesPerDay() throws {
    let usage = AppDataUsage(url: nil, calendar: utcCalendar())
    let day1 = Date(timeIntervalSince1970: 1_793_750_400)  // 2026-11-04 00:00 UTC, a Wednesday
    usage.record(date: day1.addingTimeInterval(3600), seconds: 2, apps: ["/A.app": ("A", 1000, 100)])
    usage.record(date: day1.addingTimeInterval(3602), seconds: 2, apps: ["/A.app": ("A", 500, 50), "b": ("b", 10, 0)])
    usage.record(date: day1.addingTimeInterval(86_400 + 60), seconds: 2, apps: ["/A.app": ("A", 1, 1)])
    let now = day1.addingTimeInterval(86_400 + 120)
    let (today, week, month) = usage.usage(of: "/A.app", now: now)
    #expect(today?.bytes == 2)
    #expect(week?.received == 1501 && week?.sent == 151)
    #expect(month?.bytes == 1652)
    #expect(usage.since == day1.addingTimeInterval(3598))
    #expect(usage.measuredSeconds(since: day1) == 6)
    #expect(usage.totals(since: day1)["b"]?.bytes == 10)
}

@Test func dataUsageSkipsUnmeasuredTables() {
    let usage = AppDataUsage(url: nil)
    var table = ProcessTable()
    table.interval = 2
    table.networkMeasured = false
    usage.record(table)
    #expect(usage.since == nil)
}

@Test func dataUsageRecentWindow() {
    let usage = AppDataUsage(url: nil, calendar: utcCalendar())
    let start = Date(timeIntervalSince1970: 1_793_750_400)
    for step in 0..<400 {
        usage.record(date: start.addingTimeInterval(Double(step) * 2), seconds: 2, apps: ["x": ("X", 100, 0)])
    }
    let now = start.addingTimeInterval(798)
    let recent = usage.recentTotals(window: 300, now: now)
    #expect(recent.apps["x"]?.name == "X")
    #expect(abs(recent.seconds - 300) <= 2)
    #expect(abs((recent.apps["x"]?.received ?? 0) - 15_000) <= 100)
}

@Test func dataUsageSavesAndLoads() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-usage-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let usage = AppDataUsage(url: url)
    usage.record(date: Date(), seconds: 2, apps: ["a": ("A", 42, 8)])
    usage.save()
    let loaded = AppDataUsage(url: url)
    #expect(loaded.totals(since: Date().addingTimeInterval(-86_400))["a"]?.bytes == 50)
    #expect(loaded.since != nil)
}

@Test func dataUsageKeepsLimitedDays() {
    let usage = AppDataUsage(url: nil, calendar: utcCalendar())
    let start = Date(timeIntervalSince1970: 1_793_750_400)
    for day in 0..<(AppDataUsage.keepDays + 10) {
        usage.record(date: start.addingTimeInterval(Double(day) * 86_400 + 60), seconds: 2, apps: ["a": ("A", 1, 0)])
    }
    #expect(usage.totals(since: start)["a"]?.received == Double(AppDataUsage.keepDays))
}
