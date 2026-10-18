import Darwin

final class MemoryCollector {
    private let host = mach_host_self()
    private let total = UInt64(Sysctl.int64("hw.memsize") ?? 0)
    private let pageSize = UInt64(vm_kernel_page_size)

    func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = pageSize
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let free = UInt64(stats.free_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let level = Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1
        return MemoryReading(total: total, app: app, wired: wired, compressed: compressed,
                             cached: cached, free: free,
                             swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
                             pressure: MemoryPressure(rawValue: Int(level)) ?? .normal)
    }
}
