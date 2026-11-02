import Darwin
import Foundation
import WispCore

enum Local {
    /// Sends one request to the running app. Nil when the app is not running.
    static func ask(_ request: LocalRequest) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(LocalRequest.socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var line = Report.json(request, pretty: false)
        line.append(10)
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
        // An app from before `why` existed: answer it here instead.
        if request.command == "why", String(decoding: reply, as: UTF8.self).contains("Unknown command") { return nil }
        return reply.isEmpty ? nil : reply
    }

    private static var sampled: Responder?

    /// Without the app: two samples a second apart so rates mean something.
    static func sampleAndAnswer(_ request: LocalRequest) -> Data {
        if request.command == "why" { return Report.json(Monitor().diagnose()) }
        if sampled == nil {
            let monitor = Monitor()
            _ = monitor.fresh(maxAge: 0)
            Thread.sleep(forTimeInterval: 1)
            let now = monitor.fresh(maxAge: 0)
            sampled = Responder(system: now.system, table: now.table, history: nil, alerts: [])
        }
        if request.command == "alerts" {
            return Report.json(Responder.Failure(error: "Alerts are kept by the Wisp app, which is not running."))
        }
        return sampled!.respond(request)
    }
}
