import Darwin

/// Machine-wide network throughput from the 64-bit interface counters.
///
/// NET_RT_IFLIST2 returns every interface's if_data64 in one sysctl. The buffer is
/// kept between samples and only grows.
final class NetworkCollector {
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var previous: (received: UInt64, sent: UInt64, at: UInt64)?
    private var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    /// Interface index to whether it is summed; names only change when interfaces come and go.
    private var counted: [UInt16: Bool] = [:]

    func reset() {
        previous = nil
        counted = [:]
    }

    /// Tunnels, AirDrop and bridges carry traffic that is already counted on the
    /// physical interface underneath, so only these prefixes are summed.
    static func countsInterface(_ name: UnsafePointer<CChar>) -> Bool {
        if strncmp(name, "lo", 2) == 0 { return false }
        for prefix in ["utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "ipsec", "vmenet"] where strncmp(name, prefix, strlen(prefix)) == 0 {
            return false
        }
        return true
    }

    func sample() -> NetworkReading? {
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        if size > buffer.count { buffer = [UInt8](repeating: 0, count: size + 4096) }
        size = buffer.count
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var counted = self.counted
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = base.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = base.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                    let index = message.ifm_index
                    let include: Bool
                    if let known = counted[index] {
                        include = known
                    } else {
                        include = if_indextoname(UInt32(index), &nameBuffer) != nil && Self.countsInterface(nameBuffer)
                        counted[index] = include
                    }
                    if include {
                        received &+= message.ifm_data.ifi_ibytes
                        sent &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }

        self.counted = counted
        let now = MachTime.now
        var inRate = 0.0
        var outRate = 0.0
        if let previous, received >= previous.received, sent >= previous.sent {
            let elapsed = MachTime.seconds(now &- previous.at)
            if elapsed > 0 {
                inRate = Double(received - previous.received) / elapsed
                outRate = Double(sent - previous.sent) / elapsed
            }
        }
        previous = (received, sent, now)
        return NetworkReading(receivedBytesPerSecond: inRate, sentBytesPerSecond: outRate,
                              totalReceived: received, totalSent: sent)
    }
}
