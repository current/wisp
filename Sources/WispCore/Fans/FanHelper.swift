import CryptoKit
import Foundation

/// A request to the fan helper, the small root daemon that drives the fans.
public struct FanRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { case status, set }

    public var command: Command
    public var mode: FanMode?

    public init(command: Command, mode: FanMode? = nil) {
        self.command = command
        self.mode = mode
    }
}

/// Where the fan helper lives, how to reach it, and how to install and remove it. Writing
/// to the SMC needs root, so the helper runs as a launch daemon; it takes only fan modes,
/// from the user who installed it, over a socket in /var/run.
public enum FanHelper {
    public static let label = "app.wisp.fans"
    /// Raised whenever the request, status format, or daemon setup changes, so the app offers to update an older helper.
    public static let protocolVersion = 2
    public static let installedPath = "/Library/PrivilegedHelperTools/app.wisp.fans"
    public static let plistPath = "/Library/LaunchDaemons/app.wisp.fans.plist"
    public static let socketPath = "/var/run/app.wisp.fans.sock"
    /// The mode in force, kept by the helper so it survives a restart without the app.
    public static let modePath = "/Library/Application Support/Wisp/fan-mode.json"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath) && FileManager.default.fileExists(atPath: plistPath)
    }

    public enum Failure: Error, Equatable {
        /// Nothing answers: the helper is not installed or not running.
        case unreachable
        case refused(String)
    }

    public static func send(_ request: FanRequest) -> Result<FanStatus, Failure> {
        guard let data = try? JSONEncoder().encode(request), let reply = UnixSocket.exchange(socketPath, line: data, timeout: 5) else {
            return .failure(.unreachable)
        }
        if let status = try? JSONDecoder().decode(FanStatus.self, from: reply) { return .success(status) }
        let error = (try? JSONDecoder().decode([String: String].self, from: reply))?["error"]
        return .failure(.refused(error ?? "The fan helper gave an answer Wisp does not understand."))
    }

    public static func status() -> Result<FanStatus, Failure> { send(FanRequest(command: .status)) }
    public static func set(_ mode: FanMode) -> Result<FanStatus, Failure> { send(FanRequest(command: .set, mode: mode)) }

    // MARK: Installing

    /// Copies `helper` (the one inside Wisp.app) to a folder only root can write, checks that
    /// the copy is the file that was hashed, and starts it as a launch daemon for `uid`.
    /// Running the copy, never the original, keeps any process of the user from swapping in
    /// a program root would then run.
    public static func installScript(helper: String, sha256: String, uid: uid_t) -> String {
        """
        set -e
        launchctl bootout system/\(label) 2>/dev/null || true
        mkdir -p /Library/PrivilegedHelperTools
        cp \(quote(helper)) \(quote(installedPath + ".new"))
        chown root:wheel \(quote(installedPath + ".new"))
        chmod 755 \(quote(installedPath + ".new"))
        if [ "$(shasum -a 256 \(quote(installedPath + ".new")) | cut -d ' ' -f 1)" != \(quote(sha256)) ]; then
            rm -f \(quote(installedPath + ".new"))
            echo "The helper changed while it was being installed." >&2
            exit 1
        fi
        mv -f \(quote(installedPath + ".new")) \(quote(installedPath))
        cat > \(quote(plistPath)) <<'PLIST'
        \(plist(uid: uid))
        PLIST
        chown root:wheel \(quote(plistPath))
        chmod 644 \(quote(plistPath))
        launchctl bootstrap system \(quote(plistPath))
        """
    }

    /// Stopping the helper hands the fans back to macOS before it exits.
    public static let uninstallScript = """
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f \(quote(installedPath)) \(quote(plistPath)) \(quote(socketPath)) \(quote(modePath))
        """

    static func plist(uid: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedPath)</string>
                <string>--user</string>
                <string>\(uid)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>Nice</key>
            <integer>-10</integer>
        </dict>
        </plist>
        """
    }

    /// Runs `script` as root after macOS asks for an administrator's password. Nil when it
    /// worked, otherwise what went wrong; "cancelled" when the owner closed the prompt.
    public static func runAsAdministrator(_ script: String, prompt: String) -> String? {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let promptText = prompt.replacingOccurrences(of: "\"", with: "'")
        let source = "do shell script \"\(escaped)\" with prompt \"\(promptText)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        // osascript reports a closed password prompt as error -128.
        if message.contains("-128") { return "cancelled" }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Installs the helper inside Wisp.app, given the app or the `wisp` command beside the helper,
    /// after the password prompt. Nil when it worked; "cancelled" when the owner closed the prompt.
    public static func install(from executable: URL) -> String? {
        let path = executable.pathExtension == "app"
            ? executable.appendingPathComponent("Contents/Helpers/wisp-fan-helper").path
            : executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("wisp-fan-helper").path
        guard let hash = sha256(of: path) else { return "The fan helper is missing from Wisp.app at \(path)." }
        let result = runAsAdministrator(installScript(helper: path, sha256: hash, uid: getuid()),
                                        prompt: "Wisp needs your password once to install its fan helper, which changes fan speeds.")
        guard result == nil else { return result }
        // launchd starts it at once; wait until it answers on its socket, not just until the file appears.
        for _ in 0..<30 {
            if case .success = status() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    public static func uninstall() -> String? {
        runAsAdministrator(uninstallScript, prompt: "Wisp needs your password to remove its fan helper. The fans go back to macOS.")
    }

    public static func sha256(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
