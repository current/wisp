import Darwin
import Foundation

/// Finds what outside a folder still points into it. A cache is listed because its tool
/// fetches it again, but some tools also run from their cache: pnpm 10 and later link
/// global installs, pnpm itself among them, into its store. A folder something still
/// points into is not a cache any more, so a clean leaves it, whatever the scanner said.
///
/// Two places are read: the folders commands are installed in (links and the scripts
/// that start a tool), and the rest of the folder the item sits in, which is where a
/// tool keeps whatever links into its own cache. A walk that runs past its limit counts
/// as a dependent, so a check that could not finish never lets a folder go.
public enum CleanDependents {
    /// Where installers put commands, relative to the home folder.
    static let homeCommandFolders = [".local/bin", "bin", ".bun/bin", ".cargo/bin", ".deno/bin", ".volta/bin", "go/bin",
                                     ".npm-global/bin", "Library/pnpm", "Library/pnpm/bin", ".local/share/pnpm", ".yarn/bin",
                                     ".pyenv/shims", ".rbenv/shims", ".asdf/shims", ".local/share/mise/shims"]
    static let systemCommandFolders = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
    /// Folders many unrelated tools share, relative to the home folder. An item directly
    /// inside one of these is not walked beside; its neighbours belong to other tools.
    static let sharedFolders: Set<String> = ["Library", "Library/Caches", "Library/Application Support", "Library/Developer",
                                             "Library/Developer/Xcode", "Library/Developer/CoreSimulator", ".cache", ".local",
                                             ".local/share", ".config", "Documents", "Desktop", "Downloads"]
    static let walkLimit = 200_000
    static let walkDepth = 10
    static let scriptLimit = 64 * 1024

    /// A sentence naming what still uses one of `paths`, or nil when nothing Wisp can find does.
    public static func dependent(of paths: [String], home: String) -> String? {
        let targets = paths.compactMap(CleanPathRules.realPath)
        guard !targets.isEmpty else { return nil }
        func isTarget(_ path: String) -> Bool { targets.contains { path == $0 || path.hasPrefix($0 + "/") } }

        var commandFolders = homeCommandFolders.map { home + "/" + $0 } + systemCommandFolders
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        where entry.hasPrefix("/") && !commandFolders.contains(entry) {
            commandFolders.append(entry)
        }
        for folder in commandFolders {
            guard let real = CleanPathRules.realPath(folder), !isTarget(real) else { continue }
            for name in CleanFiles.names(real) {
                if usesTarget(real + "/" + name, readScript: true, home: home, isTarget: isTarget) {
                    return "\(name) in \(display(folder, home: home)) runs from it"
                }
            }
        }

        let homeReal = CleanPathRules.realPath(home) ?? home
        var walked = Set<String>()
        for target in targets {
            let parent = (target as NSString).deletingLastPathComponent
            guard parent.hasPrefix(homeReal + "/"), !sharedFolders.contains(String(parent.dropFirst(homeReal.count + 1))),
                  walked.insert(parent).inserted else { continue }
            var budget = walkLimit
            switch walk(parent, depth: 0, budget: &budget, home: home, isTarget: isTarget) {
            case .clear: continue
            case .found(let path): return "\(display(path, home: home)) links into it"
            case .tooBig: return "Wisp could not check everything in \(display(parent, home: home)) that might use it"
            }
        }
        return nil
    }

    enum Walk { case clear, found(String), tooBig }

    /// Links anywhere under `folder`, and the scripts in its bin folders, that lead into a target.
    private static func walk(_ folder: String, depth: Int, budget: inout Int, home: String, isTarget: (String) -> Bool) -> Walk {
        guard let dir = opendir(folder) else { return .clear }
        defer { closedir(dir) }
        let name = (folder as NSString).lastPathComponent
        let readScripts = name == "bin" || name == ".bin"
        while let entry = readdir(dir) {
            let child = CleanFiles.entryName(entry)
            if child == "." || child == ".." { continue }
            budget -= 1
            if budget < 0 { return .tooBig }
            let path = folder + "/" + child
            switch Int32(entry.pointee.d_type) {
            case DT_DIR:
                // .git holds no links a tool runs from, and is most of a big project's files.
                if child == ".git" || isTarget(path) || depth >= walkDepth { continue }
                let result = walk(path, depth: depth + 1, budget: &budget, home: home, isTarget: isTarget)
                if case .clear = result { continue }
                return result
            case DT_LNK, DT_REG:
                if usesTarget(path, readScript: readScripts, home: home, isTarget: isTarget) { return .found(path) }
            default: continue
            }
        }
        return .clear
    }

    /// Whether `path` is a link that ends in a target, or a script that names a file in one.
    static func usesTarget(_ path: String, readScript: Bool, home: String, isTarget: (String) -> Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            return CleanPathRules.realPath(path).map(isTarget) ?? false
        case S_IFREG where readScript && info.st_size < scriptLimit && info.st_mode & 0o111 != 0:
            return scriptReferences(path, home: home).contains { CleanPathRules.realPath($0).map(isTarget) ?? false }
        default:
            return false
        }
    }

    /// Paths a launcher script names. Installers write these (npm's and pnpm's shims start
    /// a tool with `exec "$basedir/../global/.../pnpm"`), so a variable before the first
    /// slash is read as the script's own folder.
    static func scriptReferences(_ path: String, home: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path), data.starts(with: Array("#!".utf8)) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let folder = (path as NSString).deletingLastPathComponent
        let pattern = #"(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|~|)/[A-Za-z0-9_.@+/-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var paths: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            let slash = token.firstIndex(of: "/")!
            let head = token[..<slash], tail = token[slash...]
            let resolved: String
            if head.isEmpty { resolved = token } else if head == "~" { resolved = home + tail } else { resolved = folder + tail }
            paths.append((resolved as NSString).standardizingPath)
        }
        return paths
    }

    private static func display(_ path: String, home: String) -> String {
        let homeReal = CleanPathRules.realPath(home) ?? home
        for prefix in [home, homeReal] where path.hasPrefix(prefix + "/") { return "~" + path.dropFirst(prefix.count) }
        return path
    }
}
