import Darwin
import Foundation
import WispCore

// The fan helper: a launch daemon that runs as root, because only root may write to the SMC.
// It runs the chosen fan mode every two seconds whether or not Wisp is open, takes requests
// only from the user who installed it, and hands the fans back to macOS when it stops.

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("wisp fan helper: must run as root, from its launch daemon\n".utf8))
    exit(1)
}
let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--user"), flag + 1 < arguments.count, let owner = uid_t(arguments[flag + 1]) else {
    FileHandle.standardError.write(Data("wisp fan helper: --user UID is required\n".utf8))
    exit(2)
}

let queue = DispatchQueue(label: "app.wisp.fans")
let hardware = SMCFanHardware()
let engine = hardware.flatMap { $0.fans.isEmpty ? nil : FanEngine(hardware: $0) }

func loadMode() -> FanMode {
    guard let data = FileManager.default.contents(atPath: FanHelper.modePath),
          let mode = try? JSONDecoder().decode(FanMode.self, from: data) else { return .auto }
    return mode
}

func saveMode(_ mode: FanMode) {
    let folder = (FanHelper.modePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(mode) { try? data.write(to: URL(fileURLWithPath: FanHelper.modePath), options: .atomic) }
}

func failure(_ message: String) -> Data {
    (try? JSONEncoder().encode(["error": message])) ?? Data()
}

func answer(_ line: Data) -> Data {
    guard let engine else { return failure("This Mac has no fans Wisp can control.") }
    guard let request = try? JSONDecoder().decode(FanRequest.self, from: line) else { return failure("Bad request.") }
    if request.command == .set {
        guard let mode = request.mode else { return failure("set needs a mode.") }
        if mode.kind == .curve && (mode.curve?.points.isEmpty ?? true) { return failure("A curve needs at least one point.") }
        engine.set(mode)
        saveMode(mode)
        return (try? JSONEncoder().encode(engine.tick())) ?? Data()
    }
    return (try? JSONEncoder().encode(engine.status())) ?? Data()
}

// The socket.
unlink(FanHelper.socketPath)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    let bytes = Array(FanHelper.socketPath.utf8)
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
}
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard listener >= 0, bound == 0, listen(listener, 8) == 0 else {
    FileHandle.standardError.write(Data("wisp fan helper: cannot listen on \(FanHelper.socketPath)\n".utf8))
    exit(1)
}
// Anyone may connect; each connection is checked against the owner below.
chmod(FanHelper.socketPath, 0o666)
_ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

func serve(_ client: Int32) {
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == owner || uid == 0 else { return }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !data.contains(10) && data.count < 65536 {
        let n = recv(client, &buffer, buffer.count, 0)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    var reply = answer(data.prefix { $0 != 10 })
    reply.append(10)
    _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
}

let accepting = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
accepting.setEventHandler {
    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        serve(client)
        close(client)
    }
}
accepting.resume()

// The loop.
let timer = DispatchSource.makeTimerSource(queue: queue)
queue.sync { engine?.set(loadMode()) }
timer.schedule(deadline: .now(), repeating: FanEngine.interval, leeway: .milliseconds(200))
timer.setEventHandler { engine?.tick() }
timer.resume()

// Stopping, as launchctl bootout does: the fans go back to macOS first.
var stops: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
    source.setEventHandler {
        engine?.restore()
        unlink(FanHelper.socketPath)
        exit(0)
    }
    source.resume()
    stops.append(source)
}

dispatchMain()
