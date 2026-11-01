import Darwin
import Foundation

/// Per-app network byte rates, keyed by pid. Supplied by NetworkStatistics.
protocol AppNetworkSource: AnyObject {
    func rates() -> [Int32: (received: Double, sent: Double)]
    func flows(owners: Set<Int32>?) -> [NetworkFlow]
    func stop()
}

extension AppNetworkSource {
    func flows(owners: Set<Int32>?) -> [NetworkFlow] { [] }
}

/// Walks every process once per pass and turns the kernel's cumulative counters
/// into rates.
///
/// One pass costs proc_listpids plus one proc_pid_rusage per process. Everything
/// that does not change while a process lives (its name, path, responsible
/// process and app row) is resolved the first time a pid+start time is seen and
/// kept until the process exits.
final class ProcessScanner {
    private final class Entry {
        var start: UInt64
        var name: String
        var path: String?
        var ppid: Int32
        var uid: UInt32
        var responsible: Int32
        var groupID: String
        var readable: Bool
        var cpuTicks: UInt64 = 0
        var energy: UInt64 = 0
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var wakeups: UInt64 = 0
        var sampledAt: UInt64 = 0
        var seen = 0
        var checkedAt = 0

        init(start: UInt64, name: String, path: String?, ppid: Int32, uid: UInt32, responsible: Int32, groupID: String, readable: Bool) {
            self.start = start
            self.name = name
            self.path = path
            self.ppid = ppid
            self.uid = uid
            self.responsible = responsible
            self.groupID = groupID
            self.readable = readable
        }
    }

    private struct GroupInfo {
        let name: String
        let kind: AppKind
        let bundlePath: String?
        let bundleIdentifier: String?
    }

    private var pids = [Int32](repeating: 0, count: 2048)
    private var entries: [Int32: Entry] = [:]
    private var groupInfo: [String: GroupInfo] = [:]
    private var generation = 0
    private var lastScan: UInt64 = 0
    private var host = (ticks: host_cpu_load_info(), valid: false)
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount
    private let wallStart = Date().timeIntervalSince1970 - MachTime.seconds(mach_absolute_time())
    private var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    var network: AppNetworkSource?
    var makeNetworkSource: (() -> AppNetworkSource?)? = { AppNetwork() }

    private static let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    func scan(network wantsNetwork: Bool) -> ProcessTable {
        generation += 1
        let now = mach_absolute_time()
        let previousScan = lastScan
        let elapsed = previousScan == 0 ? 0 : MachTime.seconds(now &- previousScan)
        lastScan = now

        if wantsNetwork, network == nil { network = makeNetworkSource?() }
        if !wantsNetwork, let source = network {
            source.stop()
            network = nil
        }
        let netRates = network?.rates() ?? [:]

        let count = listPIDs()
        var rows: [ProcessRow] = []
        rows.reserveCapacity(count)
        var usage = rusage_info_v6()

        for index in 0..<count {
            let pid = pids[index]
            if pid == 0 && index > 0 { continue }
            let readable = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                }
            }

            var entry = entries[pid]
            if let existing = entry {
                let reused = readable ? existing.start != usage.ri_proc_start_abstime
                    : (generation - existing.checkedAt > 15 && identityChanged(existing, pid: pid))
                if reused { entry = nil }
            }
            if entry == nil {
                guard let fresh = resolve(pid: pid, start: readable ? usage.ri_proc_start_abstime : 0, readable: readable) else { continue }
                entries[pid] = fresh
                entry = fresh
            }
            guard let entry else { continue }
            entry.seen = generation

            var row = ProcessRow(pid: pid, ppid: entry.ppid, uid: entry.uid, name: entry.name, path: entry.path,
                                 responsiblePID: entry.responsible, groupID: entry.groupID, readable: readable,
                                 cpu: 0, memory: 0, watts: 0, diskReadPerSecond: 0, diskWritePerSecond: 0,
                                 networkInPerSecond: 0, networkOutPerSecond: 0, cpuTime: 0, startDate: nil)
            if readable {
                let ticks = usage.ri_user_time &+ usage.ri_system_time
                row.memory = usage.ri_phys_footprint
                row.cpuTime = MachTime.seconds(ticks)
                row.startDate = Date(timeIntervalSince1970: wallStart + MachTime.seconds(usage.ri_proc_start_abstime))
                // A process first seen this pass is measured from its own start, so
                // short-lived work still shows; older ones need one pass as a baseline.
                let base = entry.sampledAt != 0
                let bornSinceLastPass = previousScan != 0 && usage.ri_proc_start_abstime > previousScan
                let since = base ? entry.sampledAt : (bornSinceLastPass ? usage.ri_proc_start_abstime : 0)
                if since != 0, now > since {
                    let span = MachTime.seconds(now &- since)
                    row.cpu = Double(ticks &- (base ? entry.cpuTicks : 0)) * MachTime.nanosPerTick / 1e9 / span
                    row.watts = Double(usage.ri_energy_nj &- (base ? entry.energy : 0)) / 1e9 / span
                    row.diskReadPerSecond = Double(usage.ri_diskio_bytesread &- (base ? entry.bytesRead : 0)) / span
                    row.diskWritePerSecond = Double(usage.ri_diskio_byteswritten &- (base ? entry.bytesWritten : 0)) / span
                    let wakeups = usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups
                    row.wakeupsPerSecond = Double(wakeups &- (base ? entry.wakeups : 0)) / span
                }
                entry.wakeups = usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups
                entry.cpuTicks = ticks
                entry.energy = usage.ri_energy_nj
                entry.bytesRead = usage.ri_diskio_bytesread
                entry.bytesWritten = usage.ri_diskio_byteswritten
                entry.sampledAt = now
            }
            if let rate = netRates[pid] {
                row.networkInPerSecond = rate.received
                row.networkOutPerSecond = rate.sent
            }
            rows.append(row)
        }

        if generation % 8 == 0 || entries.count > count + 64 {
            entries = entries.filter { $0.value.seen == generation }
        }

        let apps = AppGrouping.group(rows) { id in
            let info = groupInfo[id] ?? GroupInfo(name: id, kind: .tool, bundlePath: nil, bundleIdentifier: nil)
            return (info.name, info.kind, info.bundlePath, info.bundleIdentifier)
        }
        return ProcessTable(date: Date(), interval: elapsed, processes: rows, apps: apps,
                            machineCPU: machineCPU(), coreCount: coreCount, networkMeasured: network != nil)
    }

    private func listPIDs() -> Int {
        while true {
            let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
            let count = Int(bytes) / MemoryLayout<Int32>.stride
            if count < pids.count - 16 { return max(0, count) }
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
    }

    private func machineCPU() -> Double {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size) == KERN_SUCCESS
            }
        }
        guard ok else { return 0 }
        defer { host = (info, true) }
        guard host.valid else { return 0 }
        let old = host.ticks.cpu_ticks
        let new = info.cpu_ticks
        let busy = Double((new.0 &- old.0) &+ (new.1 &- old.1) &+ (new.3 &- old.3))
        let all = busy + Double(new.2 &- old.2)
        return all > 0 ? busy / all * Double(coreCount) : 0
    }

    private func shortInfo(_ pid: Int32) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private func identityChanged(_ entry: Entry, pid: Int32) -> Bool {
        entry.checkedAt = generation
        guard let info = shortInfo(pid) else { return true }
        return Int32(info.pbsi_ppid) != entry.ppid || Self.comm(info) != String(entry.name.prefix(Int(MAXCOMLEN)))
    }

    private static func comm(_ info: proc_bsdshortinfo) -> String {
        withUnsafeBytes(of: info.pbsi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func path(of pid: Int32) -> String? {
        let length = pathBuffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return pathBuffer.withUnsafeBytes { String(decoding: $0.prefix(Int(length)), as: UTF8.self) }
    }

    private func resolve(pid: Int32, start: UInt64, readable: Bool) -> Entry? {
        guard let info = shortInfo(pid) else {
            // pid 0 has no short info but is the kernel, which belongs in the macOS row.
            guard pid == 0 else { return nil }
            groupInfo[AppGrouping.systemID] = groupInfo[AppGrouping.systemID] ?? GroupInfo(name: "macOS", kind: .system, bundlePath: nil, bundleIdentifier: nil)
            return Entry(start: start, name: "kernel_task", path: nil, ppid: 0, uid: 0, responsible: 0,
                         groupID: AppGrouping.systemID, readable: readable)
        }
        let executable = path(of: pid)
        var name = Self.comm(info)
        if let executable, let last = executable.split(separator: "/").last, last.hasPrefix(name) {
            name = String(last)
        }

        var responsible = pid
        if let lookup = Self.responsibleFor {
            let value = lookup(pid)
            if value > 0 { responsible = value }
        }
        let responsiblePath: String?
        if responsible == pid {
            responsiblePath = executable
        } else if let known = entries[responsible], known.path != nil {
            responsiblePath = known.path
        } else {
            responsiblePath = path(of: responsible) ?? executable
        }

        let identity = AppGrouping.identity(path: responsiblePath, name: name)
        if groupInfo[identity.id] == nil {
            var displayName = identity.name
            var bundleID: String?
            if let bundle = identity.bundlePath, let plist = Self.infoPlist(bundle) {
                displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? displayName
                bundleID = plist["CFBundleIdentifier"] as? String
                if displayName.isEmpty { displayName = identity.name }
            }
            groupInfo[identity.id] = GroupInfo(name: displayName, kind: identity.kind, bundlePath: identity.bundlePath, bundleIdentifier: bundleID)
        }

        let entry = Entry(start: start, name: name, path: executable, ppid: Int32(info.pbsi_ppid), uid: info.pbsi_uid,
                          responsible: responsible, groupID: identity.id, readable: readable)
        entry.checkedAt = generation
        return entry
    }

    private static func infoPlist(_ bundle: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
