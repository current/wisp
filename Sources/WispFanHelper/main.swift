import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import WispCore

// The fan helper: a root launch daemon that drives the fans through the SMC.
// Socket I/O runs off the engine queue so a slow client can never stall the 2-second
// thermal loop, and a watchdog + sleep handler guarantee Ftst=1 is never left stuck.

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("wisp fan helper: must run as root, from its launch daemon\n".utf8))
    exit(1)
}
let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--user"), flag + 1 < arguments.count, let owner = uid_t(arguments[flag + 1]) else {
    FileHandle.standardError.write(Data("wisp fan helper: --user UID is required\n".utf8))
    exit(2)
}

final class HelperState: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedStatus: FanStatus?
    private var lastTickUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var managing = false
    private var sleeping = false

    func update(status: FanStatus, managing: Bool) {
        lock.lock()
        cachedStatus = status
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        self.managing = managing
        lock.unlock()
    }

    func markRestored(sleeping: Bool = false) {
        lock.lock()
        managing = false
        self.sleeping = sleeping
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func markAwake() {
        lock.lock()
        sleeping = false
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func status() -> FanStatus? {
        lock.lock()
        defer { lock.unlock() }
        return cachedStatus
    }

    func stallAgeIfManaging() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard managing, !sleeping else { return nil }
        return ProcessInfo.processInfo.systemUptime - lastTickUptime
    }
}

let engineQueue = DispatchQueue(label: "app.wisp.fans.engine", qos: .userInteractive)
let acceptQueue = DispatchQueue(label: "app.wisp.fans.accept", qos: .userInteractive)
let clientQueue = DispatchQueue(label: "app.wisp.fans.clients", qos: .userInteractive, attributes: .concurrent)
let watchdogQueue = DispatchQueue(label: "app.wisp.fans.watchdog", qos: .userInteractive)
let powerQueue = DispatchQueue(label: "app.wisp.fans.power", qos: .userInteractive)
let clientSlots = DispatchSemaphore(value: 16)
let state = HelperState()

let hardware = SMCFanHardware(allSensors: true)
let engine = hardware.flatMap { $0.fans.isEmpty ? nil : FanEngine(hardware: $0) }

func loadMode() -> FanMode {
    guard let data = FileManager.default.contents(atPath: FanHelper.modePath),
          let mode = try? JSONDecoder().decode(FanMode.self, from: data) else { return .auto }
    return mode
}

@Sendable func saveMode(_ mode: FanMode) {
    let folder = (FanHelper.modePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(mode) { try? data.write(to: URL(fileURLWithPath: FanHelper.modePath), options: .atomic) }
}

@Sendable func failure(_ message: String) -> Data {
    (try? JSONEncoder().encode(["error": message])) ?? Data()
}

func runTick() -> FanStatus? {
    guard let engine else { return nil }
    let status = engine.tick()
    state.update(status: status, managing: engine.isManaging)
    return status
}

@Sendable func answer(_ line: Data) -> Data {
    guard let engine else { return failure("This Mac has no fans Wisp can control.") }
    guard let request = try? JSONDecoder().decode(FanRequest.self, from: line) else { return failure("Bad request.") }
    if request.command == .set {
        guard let mode = request.mode else { return failure("set needs a mode.") }
        if mode.kind == .curve && (mode.curve?.points.isEmpty ?? true) { return failure("A curve needs at least one point.") }
        let status: FanStatus = engineQueue.sync {
            engine.set(mode)
            saveMode(mode)
            let updated = engine.tick()
            state.update(status: updated, managing: engine.isManaging)
            return updated
        }
        return (try? JSONEncoder().encode(status)) ?? Data()
    }
    if let cached = state.status() {
        return (try? JSONEncoder().encode(cached)) ?? Data()
    }
    let status: FanStatus = engineQueue.sync { engine.status() }
    return (try? JSONEncoder().encode(status)) ?? Data()
}

// Clear any leftover Ftst/manual lock from an unclean prior exit before opening the socket.
engineQueue.sync {
    guard let engine else { return }
    let initialMode = loadMode()
    engine.set(initialMode)
    if initialMode.kind == .auto { engine.restore() }
    _ = runTick()
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
guard listener >= 0, bound == 0, listen(listener, 16) == 0 else {
    FileHandle.standardError.write(Data("wisp fan helper: cannot listen on \(FanHelper.socketPath)\n".utf8))
    exit(1)
}
// Anyone may connect; each connection is checked against the owner below.
chmod(FanHelper.socketPath, 0o666)
_ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

func serve(_ client: Int32) {
    defer { close(client) }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == owner || uid == 0 else { return }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !data.contains(10) && data.count < 65536 {
        let n = recv(client, &buffer, buffer.count, 0)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 { break }
        data.append(buffer, count: n)
    }
    guard !data.isEmpty else { return }
    var reply = answer(data.prefix { $0 != 10 })
    reply.append(10)
    _ = UnixSocket.sendAll(client, reply)
}

let accepting = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
accepting.setEventHandler {
    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        if clientSlots.wait(timeout: .now()) == .success {
            clientQueue.async {
                defer { clientSlots.signal() }
                serve(client)
            }
        } else {
            close(client)
        }
    }
}
accepting.resume()

// The 2-second thermal and fan control loop.
let timer = DispatchSource.makeTimerSource(queue: engineQueue)
timer.schedule(deadline: .now() + FanEngine.interval, repeating: FanEngine.interval, leeway: .milliseconds(200))
timer.setEventHandler { _ = runTick() }
timer.resume()

// Hand fans back to macOS before sleep so Ftst=1 is never held across sleep, and resume cleanly on wake.
var powerNotifyPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
var rootPowerDomain: io_connect_t = 0
let kMsgCanSystemSleep: UInt32 = 0xe0000270
let kMsgSystemWillSleep: UInt32 = 0xe0000280
let kMsgSystemHasPoweredOn: UInt32 = 0xe0000300

let powerCallback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
    let arg = Int(bitPattern: messageArgument)
    switch messageType {
    case kMsgCanSystemSleep:
        IOAllowPowerChange(rootPowerDomain, arg)
    case kMsgSystemWillSleep:
        engineQueue.async {
            engine?.restore()
            hardware?.invalidateUnlock()
            state.markRestored(sleeping: true)
            IOAllowPowerChange(rootPowerDomain, arg)
        }
    case kMsgSystemHasPoweredOn:
        state.markAwake()
        engineQueue.async {
            hardware?.invalidateUnlock()
            _ = runTick()
        }
    default:
        break
    }
}
rootPowerDomain = IORegisterForSystemPower(nil, &powerNotifyPort, powerCallback, &powerNotifier)
if rootPowerDomain != 0, let powerNotifyPort {
    IONotificationPortSetDispatchQueue(powerNotifyPort, powerQueue)
}

// Dead-man watchdog: if the 2-second loop ever stalls for >12s while managing the fans,
// release the SMC from a fresh connection and exit so launchd starts a clean helper.
let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
watchdog.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
watchdog.setEventHandler {
    if let age = state.stallAgeIfManaging(), age > 12 {
        FileHandle.standardError.write(Data("wisp fan helper: thermal loop stalled for \(Int(age))s; restoring automatic fans\n".utf8))
        SMCFanHardware.emergencyRestore()
        unlink(FanHelper.socketPath)
        _exit(1)
    }
}
watchdog.resume()

// Stopping, as launchctl bootout does: the fans go back to macOS first, with a 2-second
// fallback in case the engine queue is wedged when the stop signal arrives.
var stops: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: watchdogQueue)
    source.setEventHandler {
        let done = DispatchSemaphore(value: 0)
        engineQueue.async {
            engine?.restore()
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            SMCFanHardware.emergencyRestore()
        }
        unlink(FanHelper.socketPath)
        _exit(0)
    }
    source.resume()
    stops.append(source)
}

dispatchMain()
