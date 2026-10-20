import Darwin
import Foundation
import WispCore

/// Answers the `wisp` CLI and the MCP server on a Unix socket in Application Support.
/// It costs nothing until a connection arrives: one listening descriptor and a
/// dispatch source, no timer.
final class IPCServer: @unchecked Sendable {
    static let shared = IPCServer()

    private let queue = DispatchQueue(label: "app.wisp.ipc", qos: .userInitiated)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private weak var monitor: Monitor?
    private let devServers = DevServerScanner()
    private let agents = AgentFinder()
    private let docker = DockerWatcher()
    /// Read on the IPC queue; set from the main thread when settings change.
    var assistantsAllowed = true

    func start(monitor: Monitor) {
        self.monitor = monitor
        let path = LocalRequest.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(LocalRequest.socketPath)
    }

    private func accept() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit O_NONBLOCK from the listener; reads here should wait.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(10) && data.count < 65536 {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        let line = data.prefix { $0 != 10 }
        var reply: Data
        if let request = try? JSONDecoder().decode(LocalRequest.self, from: line), let monitor {
            if request.fromAssistant == true && !assistantsAllowed {
                reply = Report.json(Responder.Failure(error: "Assistant access is turned off in Wisp's settings."), pretty: false)
            } else {
                let now = monitor.fresh()
                let responder = Responder(system: now.system, table: now.table, history: monitor.history, alerts: now.alerts,
                                          devServers: devServers, agents: agents, docker: docker)
                reply = responder.respond(request)
            }
        } else {
            reply = Report.json(Responder.Failure(error: "Bad request."), pretty: false)
        }
        reply.append(10)
        reply.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(client, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
