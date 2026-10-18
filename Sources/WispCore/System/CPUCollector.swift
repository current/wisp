import Darwin

/// Machine-wide CPU from the host's tick counters.
///
/// The totals come from HOST_CPU_LOAD_INFO, which fills a fixed struct and allocates
/// nothing. Per-core figures need host_processor_info, which vm_allocates a fresh
/// array on every call, so they are only read when something on screen shows cores.
final class CPUCollector {
    private var previousTotal: host_cpu_load_info?
    private var previousCores: [UInt32] = []
    private let host = mach_host_self()
    let performanceCores = Int(Sysctl.int32("hw.perflevel0.logicalcpu") ?? 0)
    let efficiencyCores = Int(Sysctl.int32("hw.perflevel1.logicalcpu") ?? 0)

    func reset() {
        previousTotal = nil
        previousCores = []
    }

    func sample(perCore: Bool) -> CPUReading? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previousTotal = info }
        let cores = perCore ? coreUsage() : []
        if !perCore { previousCores = [] }
        guard let previous = previousTotal else { return nil }

        let user = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0) + Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let system = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let all = user + system + idle
        guard all > 0 else { return nil }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return CPUReading(user: user / all, system: system / all,
                          cores: cores,
                          performanceCores: performanceCores, efficiencyCores: efficiencyCores,
                          loadAverage: load)
    }

    private func coreUsage() -> [Double] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let infoArray else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: infoArray)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let n = Int(cpuCount)
        let current = (0..<(n * states)).map { UInt32(bitPattern: infoArray[$0]) }
        defer { previousCores = current }
        guard previousCores.count == current.count else { return [] }

        var result = [Double](repeating: 0, count: n)
        for core in 0..<n {
            let base = core * states
            let user = Double(current[base + Int(CPU_STATE_USER)] &- previousCores[base + Int(CPU_STATE_USER)])
            let nice = Double(current[base + Int(CPU_STATE_NICE)] &- previousCores[base + Int(CPU_STATE_NICE)])
            let system = Double(current[base + Int(CPU_STATE_SYSTEM)] &- previousCores[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(current[base + Int(CPU_STATE_IDLE)] &- previousCores[base + Int(CPU_STATE_IDLE)])
            let busy = user + nice + system
            result[core] = busy + idle > 0 ? busy / (busy + idle) : 0
        }
        return result
    }
}
