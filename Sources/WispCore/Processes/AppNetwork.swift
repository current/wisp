import Darwin
import Foundation

/// Per-process network rates from the private NetworkStatistics framework, the
/// same source nettop reads, without nettop's process and its busy loop.
///
/// The kernel reports every TCP and UDP flow as a source with cumulative byte
/// counts. Wisp keeps the last counts per flow and turns the difference into a
/// rate per process when asked. Loopback traffic is left out by summing only the
/// Wi-Fi, wired and cellular counters.
final class AppNetwork: AppNetworkSource {
    private typealias Manager = UnsafeMutableRawPointer
    private typealias Source = UnsafeMutableRawPointer
    private typealias AddedBlock = @convention(block) (Source, UnsafeMutableRawPointer?) -> Void
    private typealias DictionaryBlock = @convention(block) (CFDictionary) -> Void
    private typealias VoidBlock = @convention(block) () -> Void

    private struct API {
        let create: @convention(c) (CFAllocator?, DispatchQueue, @escaping AddedBlock) -> Manager?
        let addTCP: @convention(c) (Manager, Int32, Int32) -> Void
        let addUDP: @convention(c) (Manager, Int32, Int32) -> Void
        let queryAll: @convention(c) (Manager, @escaping VoidBlock) -> Void
        let destroy: @convention(c) (Manager) -> Void
        let setDescription: @convention(c) (Source, @escaping DictionaryBlock) -> Void
        let setCounts: @convention(c) (Source, @escaping DictionaryBlock) -> Void
        let setRemoved: @convention(c) (Source, @escaping VoidBlock) -> Void
        let queryDescription: @convention(c) (Source) -> Void
        let keys: Keys
    }

    private struct Keys {
        let pid: String
        let epid: String
        let counts: [(rx: String, tx: String)]
        let local: String?
        let remote: String?
        let provider: String?
        let tcpState: String?
        let rxAll: String?
        let txAll: String?
    }

    private static let api: API? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY) else { return nil }
        func fn<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        func key(_ name: String) -> String? {
            dlsym(handle, name).map { $0.assumingMemoryBound(to: CFString.self).pointee as String }
        }
        guard let create = fn("NStatManagerCreate", (@convention(c) (CFAllocator?, DispatchQueue, @escaping AddedBlock) -> Manager?).self),
              let addTCP = fn("NStatManagerAddAllTCPWithFilter", (@convention(c) (Manager, Int32, Int32) -> Void).self),
              let addUDP = fn("NStatManagerAddAllUDPWithFilter", (@convention(c) (Manager, Int32, Int32) -> Void).self),
              let queryAll = fn("NStatManagerQueryAllSources", (@convention(c) (Manager, @escaping VoidBlock) -> Void).self),
              let destroy = fn("NStatManagerDestroy", (@convention(c) (Manager) -> Void).self),
              let setDescription = fn("NStatSourceSetDescriptionBlock", (@convention(c) (Source, @escaping DictionaryBlock) -> Void).self),
              let setCounts = fn("NStatSourceSetCountsBlock", (@convention(c) (Source, @escaping DictionaryBlock) -> Void).self),
              let setRemoved = fn("NStatSourceSetRemovedBlock", (@convention(c) (Source, @escaping VoidBlock) -> Void).self),
              let queryDescription = fn("NStatSourceQueryDescription", (@convention(c) (Source) -> Void).self),
              let pid = key("kNStatSrcKeyPID"), let epid = key("kNStatSrcKeyEPID"),
              let rxWiFi = key("kNStatSrcKeyRxWiFiBytes"), let txWiFi = key("kNStatSrcKeyTxWiFiBytes"),
              let rxWired = key("kNStatSrcKeyRxWiredBytes"), let txWired = key("kNStatSrcKeyTxWiredBytes"),
              let rxCell = key("kNStatSrcKeyRxCellularBytes"), let txCell = key("kNStatSrcKeyTxCellularBytes")
        else { return nil }
        return API(create: create, addTCP: addTCP, addUDP: addUDP, queryAll: queryAll, destroy: destroy,
                   setDescription: setDescription, setCounts: setCounts, setRemoved: setRemoved,
                   queryDescription: queryDescription,
                   keys: Keys(pid: pid, epid: epid, counts: [(rxWiFi, txWiFi), (rxWired, txWired), (rxCell, txCell)],
                              local: key("kNStatSrcKeyLocal"), remote: key("kNStatSrcKeyRemote"),
                              provider: key("kNStatSrcKeyProvider"), tcpState: key("kNStatSrcKeyTCPState"),
                              rxAll: key("kNStatSrcKeyRxBytes"), txAll: key("kNStatSrcKeyTxBytes")))
    }()

    private final class Flow {
        var pid: Int32 = 0
        /// The process holding the socket; `pid` is the app it works for.
        var process: Int32 = 0
        var isUDP = false
        var local: NetworkEndpoint?
        var remote: NetworkEndpoint?
        var tcpState = ""
        /// All interfaces, loopback included; only the connection list reads these.
        var receivedAll: UInt64 = 0
        var sentAll: UInt64 = 0
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var reportedReceived: UInt64 = 0
        var reportedSent: UInt64 = 0
    }

    private let api: API
    private let queue = DispatchQueue(label: "app.wisp.network", qos: .utility)
    private var manager: Manager?
    // Touched only on `queue`.
    private var flows: [UnsafeMutableRawPointer: Flow] = [:]
    /// Bytes from flows that closed since the last read, so short connections still count.
    private var closed: [Int32: (UInt64, UInt64)] = [:]
    private var lastRead: UInt64 = 0

    init?() {
        guard let api = Self.api else { return nil }
        self.api = api
        let keys = api.keys
        let added: AddedBlock = { [weak self] source, _ in
            guard let self else { return }
            let flow = Flow()
            self.flows[source] = flow
            api.setDescription(source) { dictionary in
                let d = dictionary as NSDictionary
                let epid = (d[keys.epid] as? NSNumber)?.int32Value ?? 0
                let pid = (d[keys.pid] as? NSNumber)?.int32Value ?? 0
                // A daemon working for an app (nsurlsessiond downloading for it) reports the app as EPID.
                flow.pid = epid > 0 ? epid : pid
                flow.process = pid
                if let key = keys.provider { flow.isUDP = (d[key] as? String) == "UDP" }
                if let key = keys.tcpState { flow.tcpState = (d[key] as? String) ?? "" }
                if let key = keys.local, let data = d[key] as? Data { flow.local = NetworkEndpoint(sockaddr: data) }
                if let key = keys.remote, let data = d[key] as? Data { flow.remote = NetworkEndpoint(sockaddr: data) }
            }
            api.setCounts(source) { dictionary in
                let d = dictionary as NSDictionary
                var rx: UInt64 = 0
                var tx: UInt64 = 0
                for pair in keys.counts {
                    rx &+= (d[pair.rx] as? NSNumber)?.uint64Value ?? 0
                    tx &+= (d[pair.tx] as? NSNumber)?.uint64Value ?? 0
                }
                flow.received = rx
                flow.sent = tx
                if let key = keys.rxAll { flow.receivedAll = (d[key] as? NSNumber)?.uint64Value ?? rx }
                if let key = keys.txAll { flow.sentAll = (d[key] as? NSNumber)?.uint64Value ?? tx }
            }
            api.setRemoved(source) { [weak self] in
                guard let self, let flow = self.flows.removeValue(forKey: source) else { return }
                let rx = flow.received &- flow.reportedReceived
                let tx = flow.sent &- flow.reportedSent
                if flow.pid > 0, rx > 0 || tx > 0 {
                    let old = self.closed[flow.pid] ?? (0, 0)
                    self.closed[flow.pid] = (old.0 &+ rx, old.1 &+ tx)
                }
            }
            api.queryDescription(source)
        }
        guard let manager = api.create(kCFAllocatorDefault, queue, added) else { return nil }
        self.manager = manager
        api.addTCP(manager, 0, 0)
        api.addUDP(manager, 0, 0)
    }

    deinit { stop() }

    func stop() {
        guard let manager else { return }
        self.manager = nil
        api.destroy(manager)
    }

    /// Every open flow of the given apps (by the pid each flow is counted under), or
    /// of all processes when `owners` is nil, with its counts as of the last `rates()`.
    func flows(owners: Set<Int32>?) -> [NetworkFlow] {
        guard manager != nil else { return [] }
        return queue.sync {
            var result: [NetworkFlow] = []
            for (source, flow) in flows where flow.pid > 0 {
                if let owners, !owners.contains(flow.pid), !owners.contains(flow.process) { continue }
                result.append(NetworkFlow(id: UInt(bitPattern: source), pid: flow.process, owner: flow.pid,
                                          isUDP: flow.isUDP, local: flow.local, remote: flow.remote, tcpState: flow.tcpState,
                                          received: max(flow.receivedAll, flow.received), sent: max(flow.sentAll, flow.sent)))
            }
            return result
        }
    }

    /// Bytes per second per process since the previous call. The first call only
    /// sets the baseline. Waits at most a quarter second for the kernel's answer.
    func rates() -> [Int32: (received: Double, sent: Double)] {
        guard let manager else { return [:] }
        let done = DispatchSemaphore(value: 0)
        api.queryAll(manager) { done.signal() }
        _ = done.wait(timeout: .now() + .milliseconds(250))

        return queue.sync {
            let now = mach_absolute_time()
            let first = lastRead == 0
            let seconds = first ? 0 : MachTime.seconds(now &- lastRead)
            lastRead = now
            var totals: [Int32: (UInt64, UInt64)] = closed
            closed.removeAll(keepingCapacity: true)
            for flow in flows.values {
                let rx = flow.received &- flow.reportedReceived
                let tx = flow.sent &- flow.reportedSent
                flow.reportedReceived = flow.received
                flow.reportedSent = flow.sent
                guard flow.pid > 0, rx > 0 || tx > 0 else { continue }
                let old = totals[flow.pid] ?? (0, 0)
                totals[flow.pid] = (old.0 &+ rx, old.1 &+ tx)
            }
            guard !first, seconds > 0 else { return [:] }
            return totals.mapValues { (Double($0.0) / seconds, Double($0.1) / seconds) }
        }
    }
}
