import Darwin
import Foundation

/// The startup disk as macOS reports it: capacity, what is free, what macOS could
/// free (purgeable), and the space each system volume in the container uses.
public struct StorageVolume: Codable, Sendable, Equatable {
    public var capacity: UInt64
    /// Free right now, as Finder's Get Info and statfs report it.
    public var available: UInt64
    /// Free once macOS clears purgeable files and snapshots, the figure System Settings shows.
    public var availableForImportant: UInt64
    /// Space used by the sealed macOS volume, Preboot, VM (swap and sleep image), Update and the rest.
    public var systemVolume: UInt64?
    public var dataVolume: UInt64?
    public var preboot: UInt64?
    public var vm: UInt64?
    public var update: UInt64?
    public var otherSystemVolumes: UInt64

    public var used: UInt64 { capacity > available ? capacity - available : 0 }
    /// Space macOS counts as used but frees on demand: purgeable files and local snapshots.
    public var purgeable: UInt64 { availableForImportant > available ? availableForImportant - available : 0 }

    public init(capacity: UInt64, available: UInt64, availableForImportant: UInt64, systemVolume: UInt64? = nil, dataVolume: UInt64? = nil,
                preboot: UInt64? = nil, vm: UInt64? = nil, update: UInt64? = nil, otherSystemVolumes: UInt64 = 0) {
        self.capacity = capacity
        self.available = available
        self.availableForImportant = availableForImportant
        self.systemVolume = systemVolume
        self.dataVolume = dataVolume
        self.preboot = preboot
        self.vm = vm
        self.update = update
        self.otherSystemVolumes = otherSystemVolumes
    }

    public static func read() -> StorageVolume {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        let capacity = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? Int64(available)))
        var volume = StorageVolume(capacity: capacity, available: available, availableForImportant: max(important, available),
                                   systemVolume: spaceUsed("/"), dataVolume: spaceUsed("/System/Volumes/Data"),
                                   preboot: spaceUsed("/System/Volumes/Preboot"), vm: spaceUsed("/System/Volumes/VM"),
                                   update: spaceUsed("/System/Volumes/Update"))
        for name in ["xarts", "iSCPreboot", "Hardware"] { volume.otherSystemVolumes += spaceUsed("/System/Volumes/" + name) ?? 0 }
        return volume
    }

    /// Free bytes on the startup disk from one statfs call, cheap enough for the hourly archive.
    public static func freeBytes() -> UInt64? {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 || statfs("/", &fs) == 0 else { return nil }
        return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    }

    /// Bytes one APFS volume uses, from `ATTR_VOL_SPACEUSED`. Nil when the volume is not mounted.
    public static func spaceUsed(_ mountPoint: String) -> UInt64? {
        var fs = statfs()
        // Only a mount point answers for its own volume; a plain folder would answer for its parent's.
        guard statfs(mountPoint, &fs) == 0 else { return nil }
        let mounted = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard mounted == mountPoint else { return nil }
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0,
                               volattr: attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED), dirattr: 0, fileattr: 0, forkattr: 0)
        var buffer = [UInt8](repeating: 0, count: 32)
        let result = buffer.withUnsafeMutableBytes { getattrlist(mountPoint, &request, $0.baseAddress, 32, 0) }
        guard result == 0 else { return nil }
        let used = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return used > 0 ? UInt64(used) : nil
    }
}

/// APFS local snapshots of the startup disk, from `tmutil listlocalsnapshots /`.
/// macOS does not report their size without administrator rights.
public struct LocalSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var date: Date?
    /// "Time Machine", "macOS update" or the app that made it.
    public var kind: String

    public static func list() -> [LocalSnapshot] {
        guard let output = Run.output("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else { return [] }
        return parse(output)
    }

    static func parse(_ output: String) -> [LocalSnapshot] {
        output.split(separator: "\n").compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("com.") || name.contains(".local") else { return nil }
            var kind = "Snapshot"
            if name.hasPrefix("com.apple.TimeMachine.") { kind = "Time Machine" } else if name.hasPrefix("com.apple.os.update") { kind = "macOS update" }
            return LocalSnapshot(name: name, date: date(in: name), kind: kind)
        }
    }

    /// Time Machine names carry their time: com.apple.TimeMachine.2026-11-04-101010.local.
    static func date(in name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(name[range]))
    }
}

/// Swap in use and allocated, from `vm.swapusage`.
public struct SwapUsage: Codable, Sendable, Equatable {
    public var total: UInt64
    public var used: UInt64

    public static func read() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(total: usage.xsu_total, used: usage.xsu_used)
    }
}

public enum StorageAccess {
    /// Whether Wisp can read what only Full Disk Access opens. Reading the system
    /// privacy database never shows a prompt; it simply fails without access.
    public static var hasFullDiskAccess: Bool {
        if ProcessInfo.processInfo.environment["WISP_STORAGE_NO_FDA"] != nil { return false }
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// Folders in the home folder that macOS guards: without Full Disk Access, reading
    /// them either fails or asks the user, so Wisp leaves them alone and shows them locked.
    public static let guarded = [
        "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage", "Library/Containers",
        "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Application Support/MobileSync",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB", "Library/Application Support/com.apple.TCC",
        "Library/Calendars", "Library/Reminders", "Library/Suggestions", "Library/HomeKit", "Library/IdentityServices",
        "Library/Metadata/CoreSpotlight", "Library/Cookies", "Library/Biome", "Library/Accounts", "Library/Sharing",
        "Library/Autosave Information", "Library/Daemon Containers", "Library/Weather", "Library/Trial", "Pictures/Photos Library.photoslibrary",
        "Library/Photos", "Library/Assistant", "Library/Shortcuts", "Library/Finance", "Library/DoNotDisturb", "Library/Passes",
        ".Trash",
    ]

    /// Absolute paths to leave alone in this run.
    public static func skipped(home: String = NSHomeDirectory()) -> Set<String> {
        hasFullDiskAccess ? [] : Set(guarded.map { home + "/" + $0 })
    }

    /// Whether Wisp may move `path` to the Trash: only below a folder inside the home
    /// folder (never home itself or Desktop, Library and the like), and never through
    /// a link that leads somewhere else.
    public static func safeToTrash(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standard = (path as NSString).standardizingPath
        guard standard == path, !path.contains("/../"), let real = realpath(path, nil) else { return false }
        defer { free(real) }
        let resolved = String(cString: real)
        guard let homeReal = realpath(home, nil) else { return false }
        defer { free(homeReal) }
        let homeResolved = String(cString: homeReal)
        guard resolved.hasPrefix(homeResolved + "/") else { return false }
        return resolved.dropFirst(homeResolved.count + 1).split(separator: "/").count >= 2
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
}

/// Runs a system tool and returns what it printed. Only for read-only tools with fixed paths.
enum Run {
    static func output(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
