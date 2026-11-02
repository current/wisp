import Darwin
import Foundation
import IOKit.pwr_mgt

/// The few readings a diagnosis needs that the monitor does not keep: swap paging
/// counters, the CPU speed limit and whether a Time Machine backup is mounted.
enum DiagnosisProbe {
    struct Paging {
        var swapIns: UInt64
        var swapOuts: UInt64
        var at: UInt64
    }

    static func paging() -> Paging? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Paging(swapIns: stats.swapins, swapOuts: stats.swapouts, at: MachTime.now)
    }

    /// Bytes per second swapped in and out between two readings.
    static func rates(_ a: Paging, _ b: Paging) -> (swapIn: Double, swapOut: Double)? {
        let seconds = MachTime.seconds(b.at &- a.at)
        guard seconds > 0, b.swapIns >= a.swapIns, b.swapOuts >= a.swapOuts else { return nil }
        let page = Double(vm_kernel_page_size)
        return (Double(b.swapIns - a.swapIns) * page / seconds, Double(b.swapOuts - a.swapOuts) * page / seconds)
    }

    /// The limit macOS put on CPU speed, percent. Most Apple silicon Macs do not report one.
    static func cpuSpeedLimit() -> Int? {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&status) == kIOReturnSuccess,
              let dictionary = status?.takeRetainedValue() as? [String: Any],
              let limit = dictionary[kIOPMCPUPowerLimitProcessorSpeedKey] as? Int else { return nil }
        return limit
    }

    /// A backup mounts its local snapshot or its destination under a Time Machine path.
    static func timeMachineMounted() -> Bool {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return volumes.contains { $0.path.contains("com.apple.TimeMachine") || $0.path.hasPrefix("/Volumes/.timemachine") }
    }
}

extension Monitor {
    /// Looks hard at the machine for `window` seconds (at most 3) and says why it is slow.
    ///
    /// Takes one full reading, waits, takes another, so every rate covers the window,
    /// then stops: nothing keeps running afterwards. Blocks the caller for the window,
    /// so call it from a background queue, never the main thread or the monitor queue.
    public func diagnose(window: TimeInterval = 2.5) -> Diagnosis {
        let window = min(max(window, 0.5), 3)
        let gpu = GPUClients()
        _ = gpu.sample()
        let before = DiagnosisProbe.paging()
        _ = fresh(maxAge: 0)
        let started = Date()
        // Slow, table-free reads go inside the window rather than after it.
        let containers = Docker.status(stats: false).containers.filter { $0.state == "running" }.count
        let timeMachine = DiagnosisProbe.timeMachineMounted()
        let speedLimit = DiagnosisProbe.cpuSpeedLimit()
        Thread.sleep(forTimeInterval: max(0, window - Date().timeIntervalSince(started)))
        let now = fresh(maxAge: 0)
        let after = DiagnosisProbe.paging()
        let shares = gpu.sample()
        let swap = before.flatMap { a in after.flatMap { DiagnosisProbe.rates(a, $0) } }

        // Minutes of CPU for the apps that have been busy lately, from history.
        var recent: [String: [Float]] = [:]
        for summary in history.summaries(minutes: 15) where summary.cpu >= 0.5 {
            recent[summary.id] = history.app(summary.id, .cpu, minutes: 30)
        }
        let agents = AgentFinder().find(now.table)
        let servers = DevServerScanner().scan(now.table).flatMap(\.servers)
        let thermal: ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        default: thermal = .nominal
        }
        let input = DiagnosisInput(system: now.system, table: now.table, swapInPerSecond: swap?.swapIn, swapOutPerSecond: swap?.swapOut,
                                   thermalState: thermal, cpuSpeedLimit: speedLimit, gpuShares: shares,
                                   recentAppCPU: recent, agents: agents, devServers: servers.count,
                                   devServerCPU: servers.reduce(0) { $0 + $1.cpu }, devServerMemory: servers.reduce(0) { $0 + $1.memory }, containers: containers,
                                   timeMachineRunning: timeMachine, sampled: window)
        return Diagnoser.diagnose(input)
    }
}
