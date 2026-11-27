import Darwin
import Foundation
import WispCore

enum Local {
    /// Sends one request to the running app. Nil when the app is not running.
    static func ask(_ request: LocalRequest) -> Data? {
        let reply = UnixSocket.exchange(LocalRequest.socketPath, line: Report.json(request, pretty: false))
        // An app from before `why` existed: answer it here instead.
        if request.command == "why", let reply, String(decoding: reply, as: UTF8.self).contains("Unknown command") { return nil }
        return reply
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
