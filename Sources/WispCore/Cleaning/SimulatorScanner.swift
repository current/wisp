import Foundation

/// Simulators that are not running and runtimes no simulator uses, from `simctl`.
/// Removing them goes through simctl and is permanent.
public struct SimulatorScanner: CleanScanner {
    static let group = "Simulators"

    public var tab: CleanTab { .developer }
    /// Runs simctl with these arguments and returns what it printed; nil when Xcode is not installed.
    public var simctl: @Sendable ([String]) -> String?

    public init(simctl: @escaping @Sendable ([String]) -> String? = { SimulatorScanner.runSimctl($0) }) {
        self.simctl = simctl
    }

    /// simctl from the selected Xcode, called directly: `xcrun` without Xcode would offer to install the Command Line Tools.
    public static func runSimctl(_ arguments: [String]) -> String? {
        guard let developer = Run.output("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              developer.hasPrefix("/") else { return nil }
        let simctl = developer + "/usr/bin/simctl"
        guard FileManager.default.isExecutableFile(atPath: simctl) else { return nil }
        return Run.output(simctl, arguments, timeout: 20)
    }

    struct Device: Decodable {
        var udid: String
        var name: String
        var state: String
        var isAvailable: Bool?
        var dataPath: String?
        var dataPathSize: Int64?
        var logPathSize: Int64?
    }

    struct DeviceList: Decodable {
        var devices: [String: [Device]]
    }

    struct Runtime: Decodable {
        var identifier: String
        var version: String?
        var build: String?
        var runtimeIdentifier: String?
        var sizeBytes: Int64?
        var deletable: Bool?
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" as "iOS 27.0".
    static func osName(_ runtime: String) -> String {
        let tail = runtime.components(separatedBy: "SimRuntime.").last ?? runtime
        var parts = tail.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return runtime }
        var platform = parts.removeFirst()
        if platform == "xrOS" { platform = "visionOS" }
        return parts.isEmpty ? platform : platform + " " + parts.joined(separator: ".")
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        guard let devicesJSON = simctl(["list", "devices", "-j"]),
              let list = try? JSONDecoder().decode(DeviceList.self, from: Data(devicesJSON.utf8)) else { return [] }
        if context.isCancelled() { return [] }
        let runtimes = simctl(["runtime", "list", "-j"]).flatMap { try? JSONDecoder().decode([String: Runtime].self, from: Data($0.utf8)) } ?? [:]

        let home = context.homePath
        var unavailable: [CleanItem] = []
        var stopped: [CleanItem] = []
        for (runtime, devices) in list.devices {
            let os = Self.osName(runtime)
            for device in devices {
                let isAvailable = device.isAvailable ?? true
                guard !isAvailable || device.state == "Shutdown" else { continue }
                let folder = device.dataPath.map { ($0 as NSString).deletingLastPathComponent }
                let paths = folder.map { $0.hasPrefix(home + "/") ? [$0] : [] } ?? []
                if paths.contains(where: context.isBlocked) { continue }
                let item = CleanItem(
                    id: "simulator:\(device.udid)", tab: .developer, group: Self.group, name: "\(device.name), \(os)",
                    detail: isAvailable
                        ? "A simulator that is not running. Removing it deletes the apps and data in it."
                        : "A simulator whose system is no longer installed, so it cannot start. Removing it deletes the apps and data in it.",
                    paths: paths, bytes: (device.dataPathSize ?? 0) + (device.logPathSize ?? 0), safety: .checkFirst,
                    removal: .simulator(udid: device.udid), checkedByDefault: !isAvailable)
                if isAvailable { stopped.append(item) } else { unavailable.append(item) }
            }
        }

        let used = Set(list.devices.filter { !$0.value.isEmpty }.keys)
        let unused = runtimes.values.filter { runtime in
            guard let id = runtime.runtimeIdentifier, runtime.deletable != false else { return false }
            return !used.contains(id)
        }.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        let runtimeItems = unused.map { runtime in
            let os = runtime.runtimeIdentifier.map(Self.osName) ?? runtime.version ?? runtime.identifier
            return CleanItem(id: "simruntime:\(runtime.identifier)", tab: .developer, group: Self.group,
                             name: "\(os) runtime" + (runtime.build.map { " (\($0))" } ?? ""),
                             detail: "A simulator system no simulator uses. Xcode downloads it again from Settings, Components.",
                             paths: [], bytes: runtime.sizeBytes ?? 0, safety: .checkFirst,
                             removal: .simulatorRuntime(identifier: runtime.identifier))
        }

        let items = unavailable.sorted { $0.bytes > $1.bytes } + runtimeItems + stopped.sorted { $0.bytes > $1.bytes }
        if !items.isEmpty { context.found(items) }
        return items
    }
}
