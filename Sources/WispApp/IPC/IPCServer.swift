import Foundation
import WispCore

final class IPCServer: @unchecked Sendable {
    static let shared = IPCServer()
    func start(monitor: Monitor) {}
    func stop() {}
}
