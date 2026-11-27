import Foundation
import WispCore

/// `wisp fans`: what the fans are doing, and changing their mode through the fan helper.
enum FanCommand {
    static func run(_ arguments: [String], json: Bool) -> Int32 {
        switch arguments.first {
        case nil, "status":
            return show(status(), json: json)
        case "set":
            guard arguments.count == 2 else { return fail("set takes one mode: auto, silent, quiet, balanced, cool, max, a percent like 60%, or a saved curve's name") }
            guard let mode = FanMode.parse(arguments[1], curves: FanCurveStore.load()) else {
                return fail("unknown mode \(arguments[1]). Saved curves: " + (FanCurveStore.load().map(\.name).joined(separator: ", ").nilIfEmpty ?? "none"))
            }
            switch FanHelper.set(mode) {
            case .success(let status): return show(.success(status), json: json)
            case .failure(.unreachable): return fail(notInstalled)
            case .failure(.refused(let message)): return fail(message)
            }
        case "curves":
            let curves = FanCurve.presets + FanCurveStore.load()
            if json {
                FileHandle.standardOutput.write(Report.json(curves))
                print()
                return 0
            }
            for curve in curves {
                print("\(curve.name) (\(curve.sensor.title)): " + curve.points.map { "\(Int($0.celsius))°C \(Int($0.percent))%" }.joined(separator: ", "))
            }
            return 0
        case "install":
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            if let error = FanHelper.install(from: executable) { return fail(error == "cancelled" ? "cancelled" : error) }
            print("The fan helper is installed. wisp fans set silent, quiet, balanced, cool, max, or a percent changes the fans.")
            return 0
        case "uninstall":
            if let error = FanHelper.uninstall() { return fail(error) }
            print("The fan helper is removed and macOS controls the fans again.")
            return 0
        default:
            return fail("unknown fans command \(arguments[0])")
        }
    }

    struct Summary: Encodable {
        var helperInstalled: Bool
        var status: FanStatus
        var modes: [String]
    }

    /// The JSON the MCP tool `fan_status` returns.
    static func statusJSON() -> Data {
        switch status() {
        case .success(let status):
            let modes = FanMode.builtIn.map { $0.title.lowercased() } + FanCurveStore.load().map(\.name)
            return Report.json(Summary(helperInstalled: FanHelper.isInstalled, status: status, modes: modes))
        case .failure(.unreachable):
            return Report.json(Responder.Failure(error: "This Mac has no fans Wisp can read."))
        case .failure(.refused(let message)):
            return Report.json(Responder.Failure(error: message))
        }
    }

    static let notInstalled = "fan control is not set up. Run wisp fans install, or turn it on in Wisp's Sensors page."

    /// The helper's status, or without it the fans as they are, under macOS.
    static func status() -> Result<FanStatus, FanHelper.Failure> {
        let answer = FanHelper.status()
        guard case .failure(.unreachable) = answer, let hardware = SMCFanHardware(allSensors: false), !hardware.fans.isEmpty else { return answer }
        return .success(FanEngine(hardware: hardware).status())
    }

    static func show(_ result: Result<FanStatus, FanHelper.Failure>, json: Bool) -> Int32 {
        let status: FanStatus
        switch result {
        case .success(let value): status = value
        case .failure(.unreachable): return fail("this Mac has no fans Wisp can read")
        case .failure(.refused(let message)): return fail(message)
        }
        if json {
            FileHandle.standardOutput.write(Report.json(status))
            print()
            return 0
        }
        let helper = FanHelper.isInstalled ? "" : " (fan helper not installed)"
        print("Mode: \(status.mode.title)\(helper)" + (status.overheated ? ", running full speed until the chip cools" : ""))
        let t = status.temperatures
        print("Temperature: " + [("CPU", t.cpu), ("GPU", t.gpu)].compactMap { name, value in value.map { "\(name) \(Int($0.rounded()))°C" } }
            .joined(separator: ", "))
        for fan in status.fans {
            let now = fan.rpm.map { "\(Int($0.rounded())) rpm" } ?? "–"
            let target = fan.targetRPM.map { ", target \(Int($0.rounded()))" } ?? ""
            print("Fan \(fan.index + 1): \(now)\(target) (\(Int(fan.minRPM))–\(Int(fan.maxRPM)))")
        }
        if let error = status.error { print("Problem: \(error)") }
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("wisp fans: \(message)\n".utf8))
        return message == "cancelled" ? 1 : 2
    }
}
