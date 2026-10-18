import Darwin

enum MachTime {
    /// Nanoseconds per mach absolute time unit. 1 on Intel, 125/3 on Apple silicon.
    static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * nanosPerTick / 1e9 }

    static var now: UInt64 { mach_continuous_time() }

    static func secondsSince(_ start: UInt64) -> Double { seconds(now &- start) }
}
