import Foundation

/// Plan limits from T3 Code on other machines. A thread that runs in a linked environment
/// (a devbox, another Mac) logs its `rate_limit_event`s on that machine, and the T3 Code on
/// this Mac never sees them. For each SSH host the owner names, Wisp runs `ssh <host>` with
/// a short script that prints the newest limit lines from the T3 Code logs there, and reads
/// them like the local ones. Only hosts the owner adds are contacted; ssh runs in batch mode,
/// so it never asks for a password, and nothing else is sent.
public enum T3RemoteLimits {
    /// What one host reported, kept in the plan-limits folder between checks.
    struct Saved: Codable, Equatable {
        var host: String
        /// The last check that reached the host.
        var checked: Date?
        /// The last check, whether it reached the host or not.
        var tried: Date
        /// Why the last check failed, in words a person can act on.
        var problem: String?
        var hits: [String: T3CodeLimits.Hit] = [:]
    }

    /// Host names as typed: split on commas and spaces, empty ones dropped, each once.
    public static func hosts(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { seen.insert($0).inserted }
    }

    static func fileName(host: String) -> String {
        "remote-" + String(host.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }) + ".json"
    }

    static func saved(host: String, store: URL) -> Saved? {
        guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(fileName(host: host)).path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, store: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? data.write(to: store.appendingPathComponent(fileName(host: saved.host)), options: .atomic)
    }

    /// One line per host for the settings page: when it was last read, or why it could not be.
    public static func status(hosts: [String], store: URL = ClaudeStatusLine.store, now: Date = Date()) -> [String] {
        hosts.map { host in
            guard let saved = saved(host: host, store: store) else { return "\(host): not checked yet" }
            if let problem = saved.problem { return "\(host): \(problem)" }
            let minutes = Int(now.timeIntervalSince(saved.checked ?? saved.tried) / 60)
            return "\(host): read " + (minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago")
        }
    }

    // MARK: Checking

    private static let lock = NSLock()
    nonisolated(unsafe) private static var checking = Set<String>()

    /// Checks each host whose last check is older than `maxAge`. A host already being
    /// checked (the menu bar and the Agents page both refresh) is left to that check.
    public static func refresh(hosts: [String], store: URL = ClaudeStatusLine.store, maxAge: TimeInterval, now: Date = Date(),
                               run: (String, String) -> (output: Data, status: Int32)? = runSSH) {
        for host in hosts {
            let previous = saved(host: host, store: store)
            if let previous, now.timeIntervalSince(previous.tried) < maxAge { continue }
            lock.lock()
            let mine = checking.insert(host).inserted
            lock.unlock()
            guard mine else { continue }
            defer { lock.lock(); checking.remove(host); lock.unlock() }
            // Only logs changed since the last check that reached the host, with a few minutes to spare.
            let since = previous?.checked.map { now.timeIntervalSince($0) + 300 } ?? T3CodeLimits.maxAge
            var next = Saved(host: host, checked: previous?.checked, tried: now, problem: nil, hits: previous?.hits ?? [:])
            if let (output, status) = run(host, script(minutes: Int((since / 60).rounded(.up)))) {
                if status == 0 {
                    next.checked = now
                    if output.starts(with: Data(noT3.utf8)) {
                        next.problem = "T3 Code has no logs there"
                    } else {
                        for (instance, hit) in hits(output) where (next.hits[instance]?.updated ?? .distantPast) < hit.updated {
                            next.hits[instance] = hit
                        }
                    }
                } else {
                    next.problem = status == 255 ? "could not connect with ssh" : "the check failed there"
                }
            } else {
                next.problem = "ssh did not answer in time"
            }
            // Figures older than T3 Code's own logs are kept no longer than the local ones.
            next.hits = next.hits.filter { now.timeIntervalSince($0.value.updated) < T3CodeLimits.maxAge }
            save(next, store: store)
        }
    }

    static let noT3 = "WISP-NO-T3"

    /// Runs under `sh` on the host: the last few limit lines of each T3 Code log changed in
    /// the last `minutes`, read from the end of the file only.
    static func script(minutes: Int) -> String {
        """
        cd "$HOME/.t3/userdata/logs/provider" 2>/dev/null || { echo \(noT3); exit 0; }
        find . -maxdepth 1 -type f -name 'events.*' -mmin -\(max(1, minutes)) | while read -r f; do
          tail -c \(T3CodeLimits.tailBytes) "$f" | grep -F '"payload":{"type":"rate_limit_event"' | tail -n 5
        done
        exit 0
        """
    }

    /// The newest hit per instance in what the script printed.
    static func hits(_ output: Data) -> [String: T3CodeLimits.Hit] {
        var found: [String: T3CodeLimits.Hit] = [:]
        for line in output.split(separator: 10) {
            guard let (instance, hit) = T3CodeLimits.parse(line: line) else { continue }
            if (found[instance]?.updated ?? .distantPast) < hit.updated { found[instance] = hit }
        }
        return found
    }

    /// `ssh -o BatchMode=yes <host> sh -s` with the script on stdin, stopped after 20 seconds.
    public static func runSSH(host: String, script: String) -> (output: Data, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                             "--", host, "sh", "-s"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationReason == .uncaughtSignal { return nil }
        return (data, process.terminationStatus)
    }

    // MARK: Reading

    /// The newest figures each host reported, as accounts of this Mac: a remote instance
    /// counts as the account the same T3 Code instance id uses here ("claudeAgent" is
    /// ~/.claude, "claude-alt" the folder T3 Code's settings give it).
    public static func accounts(hosts: [String], home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store) -> [T3CodeLimits.Account] {
        let instances = T3CodeLimits.claudeInstances(settings: home + "/.t3/userdata/settings.json", home: home)
        var best: [String: T3CodeLimits.Hit] = [:]
        for host in hosts {
            for (instance, hit) in saved(host: host, store: store)?.hits ?? [:] where (best[instance]?.updated ?? .distantPast) < hit.updated {
                best[instance] = hit
            }
        }
        return best.compactMap { instance, hit in
            guard let (folder, label) = instances[instance] else { return nil }
            return T3CodeLimits.Account(label: label, record: .init(folder: folder, updated: hit.updated, windows: hit.windows))
        }
    }
}
