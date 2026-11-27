import Darwin
import Foundation

/// One request and its answer over a Unix socket, each a line of JSON.
public enum UnixSocket {
    /// Nil when nothing listens at `path` or no answer comes within `timeout` seconds.
    public static func exchange(_ path: String, line: Data, timeout: Int = 10) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var line = line
        if line.last != 10 { line.append(10) }
        let sent = line.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == line.count else { return nil }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            reply.append(buffer, count: n)
            if reply.last == 10 { break }
        }
        return reply.isEmpty ? nil : reply
    }
}
