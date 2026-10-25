import Foundation
import IOKit

/// GPU time per process, from the accumulated time the graphics driver keeps for
/// each client. Reading it walks a few dozen registry entries, about a millisecond,
/// so callers ask only while something on screen shows it.
public final class GPUClients: @unchecked Sendable {
    private var last: [Int32: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private let lock = NSLock()

    public init() {}

    /// Share of the GPU each process used since the previous call, 0 to 1.
    /// The first call only takes a baseline and returns nothing.
    public func sample() -> [Int32: Double] {
        lock.lock()
        defer { lock.unlock() }
        var totals: [Int32: UInt64] = [:]
        // Driver clients hang off the accelerator in the registry; they are not
        // services, so walk its children rather than match them.
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let entry = IOIteratorNext(children), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let pid = Self.pid(from: creator),
                      let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                totals[pid, default: 0] += time
            }
        }
        let now = MachTime.now
        defer {
            last = totals
            lastTime = now
        }
        guard lastTime != 0 else { return [:] }
        let elapsed = MachTime.seconds(now &- lastTime) * 1e9
        guard elapsed > 0 else { return [:] }
        var shares: [Int32: Double] = [:]
        for (pid, time) in totals {
            guard let before = last[pid], time > before else { continue }
            shares[pid] = min(1, Double(time - before) / elapsed)
        }
        return shares
    }

    /// "pid 441, WindowServer" → 441.
    static func pid(from creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }
}

/// What the processes inside one app are doing: for a browser its tabs, GPU
/// process, extensions and network service; for anything else the main process
/// and its helpers by name.
public struct AppBreakdown: Sendable, Equatable {
    public struct Part: Sendable, Equatable, Identifiable {
        /// "Tabs", "GPU", "Browser", "Extensions", "Network", "Other processes", or a helper's name.
        public var name: String
        public var kind: Kind
        public var processes: Int
        public var memory: UInt64
        public var cpu: Double
        public var id: String { name }
    }

    public enum Kind: String, Sendable {
        case tabs, gpu, main, extensions, network, media, other
    }

    public var parts: [Part]
    public var isBrowser: Bool

    static let browsers = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser",
                           "com.vivaldi.Vivaldi", "com.operasoftware", "org.chromium.Chromium", "com.apple.Safari",
                           "ai.perplexity.comet", "org.mozilla.firefox"]

    /// Groups the app's processes. `arguments` gives a process's command line when
    /// its name alone does not say what it is (Chromium helpers); it may return nil.
    public static func make(_ app: AppGroup, table: ProcessTable, arguments: (Int32) -> [String]?) -> AppBreakdown {
        let rows = table.processes.filter { $0.groupID == app.id }
        // The main process is the one running the bundle's own executable; failing
        // that, the app's name; failing that, the oldest process with no parent here.
        let executableFolder = app.bundlePath.map { $0 + "/Contents/MacOS/" }
        let mainPID = rows.first { row in executableFolder.map { row.path?.hasPrefix($0) == true } ?? false }?.pid
            ?? rows.first { $0.name == app.name }?.pid
            ?? rows.first { row in !rows.contains { $0.pid == row.ppid } }?.pid
        var browser = false
        let isBrowser = Self.browsers.contains { app.bundleIdentifier?.hasPrefix($0) == true }
        var parts: [String: Part] = [:]

        func add(_ name: String, _ kind: Kind, _ row: ProcessRow) {
            var part = parts[name] ?? Part(name: name, kind: kind, processes: 0, memory: 0, cpu: 0)
            part.processes += 1
            part.memory += row.memory
            part.cpu += row.cpu
            parts[name] = part
        }

        for row in rows {
            let name = row.name
            if row.pid == mainPID {
                add("Main process", .main, row)
                continue
            }
            // Chromium browsers and Electron apps name helpers "<App> Helper (...)";
            // what each one does is in its --type argument.
            if name.contains(" Helper") {
                let args = arguments(row.pid) ?? []
                let type = args.first { $0.hasPrefix("--type=") }.map { String($0.dropFirst(7)) }
                    ?? (name.contains("Renderer") ? "renderer" : name.contains("GPU") ? "gpu-process" : "")
                switch type {
                case "renderer":
                    if args.contains(where: { $0.hasPrefix("--extension-process") }) {
                        add("Extensions", .extensions, row)
                    } else if isBrowser {
                        browser = true
                        add("Tabs", .tabs, row)
                    } else {
                        // An Electron app draws its windows in renderers.
                        add("Windows", .tabs, row)
                    }
                case "gpu-process":
                    add("GPU", .gpu, row)
                case "utility":
                    if args.contains(where: { $0.contains("NetworkService") }) {
                        add("Network", .network, row)
                    } else if args.contains(where: { $0.contains("audio") || $0.contains("Audio") || $0.contains("video") }) {
                        add("Audio and video", .media, row)
                    } else {
                        add("Other processes", .other, row)
                    }
                default:
                    add("Other processes", .other, row)
                }
                continue
            }
            // Safari and other WebKit browsers.
            switch name {
            case let n where n.hasSuffix("WebContent") || n.contains("Web Content"):
                add("Tabs", .tabs, row)
                browser = true
            case let n where n.contains("GPU") || n.contains("Graphics and Media"):
                add("GPU", .gpu, row)
            case let n where n.contains("Networking"):
                add("Network", .network, row)
            case let n where n.contains("Extension"):
                add("Extensions", .extensions, row)
            case let n where n.contains("crashpad") || n.contains("Crash"):
                add("Crash reporter", .other, row)
            default:
                add(name, .other, row)
            }
        }
        if browser, var main = parts.removeValue(forKey: "Main process") {
            main.name = "Browser"
            parts["Browser"] = main
        }
        // Long tails of one-off helpers fold into one line.
        var sorted = parts.values.sorted { $0.memory > $1.memory }
        if sorted.count > 7 {
            let rest = sorted[6...]
            var other = Part(name: "Other processes", kind: .other, processes: 0, memory: 0, cpu: 0)
            for part in rest {
                other.processes += part.processes
                other.memory += part.memory
                other.cpu += part.cpu
            }
            var head = Array(sorted[..<6])
            if let index = head.firstIndex(where: { $0.name == other.name }) {
                head[index].processes += other.processes
                head[index].memory += other.memory
                head[index].cpu += other.cpu
            } else {
                head.append(other)
            }
            sorted = head
        }
        return AppBreakdown(parts: sorted, isBrowser: browser)
    }
}
