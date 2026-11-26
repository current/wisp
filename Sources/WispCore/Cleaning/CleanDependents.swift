import Darwin
import Foundation

/// Finds what outside a folder still points into it. A cache is listed because its tool
/// fetches it again, but some tools also run from their cache: pnpm 10 and later link
/// global installs, pnpm itself among them, into its store. A folder something still
/// points into is not a cache any more, so a clean leaves it, whatever the scanner said.
///
/// Three places are read: the folders commands are installed in (links and the scripts
/// that start a tool), the rest of the folder the item sits in, which is where a tool
/// keeps whatever links into its own cache, and a pnpm store's list of the projects that
/// use it. A walk that runs past its limit counts as a dependent, so a check that could
/// not finish never lets a folder go.
public enum CleanDependents {
    /// Where installers put commands, relative to the home folder.
    static let homeCommandFolders = [".local/bin", "bin", ".bun/bin", ".cargo/bin", ".deno/bin", ".volta/bin", "go/bin",
                                     ".npm-global/bin", "Library/pnpm", "Library/pnpm/bin", ".local/share/pnpm", ".yarn/bin",
                                     ".pyenv/shims", ".rbenv/shims", ".asdf/shims", ".local/share/mise/shims"]
    static let systemCommandFolders = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
    /// Folders many unrelated tools or apps share, relative to the home folder. An item
    /// directly inside one of these is not walked beside; its neighbours belong to others,
    /// and in Containers and Group Containers reading them would open every app's data.
    static let sharedFolders: Set<String> = {
        var folders: Set<String> = ["Library", "Library/Caches", "Library/Application Support", "Library/Developer",
                                    "Library/Developer/Xcode", "Library/Developer/CoreSimulator", "Library/Group Containers",
                                    "Library/LaunchAgents", "Library/Logs/DiagnosticReports", "Library/iTunes", ".cache", ".local",
                                    ".local/share", ".config", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public"]
        for area in LibraryArea.all { folders.insert("Library/" + area.folder) }
        return folders
    }()
    static let walkLimit = 200_000
    static let walkDepth = 10
    static let scriptLimit = 64 * 1024
    /// Entries read across a pnpm store's projects before the check gives up and keeps the store.
    static let projectLimit = 100_000

    /// What one clean shares between its items: the commands in the usual folders, read once
    /// however many items there are, and the paths the clean removes, whose links go with them.
    public final class Context: @unchecked Sendable {
        let home: String
        let homeReal: String
        /// Real paths of everything the clean removes.
        let going: [String]
        private let lock = NSLock()
        private var commands: [Command]?
        /// Entries read so far, for probes.
        private(set) var entriesRead = 0

        public init(home: String, going: [String] = []) {
            self.home = home
            homeReal = CleanPathRules.realPath(home) ?? home
            self.going = going.compactMap(CleanPathRules.realPath)
        }

        func isGoing(_ path: String) -> Bool { going.contains { path == $0 || path.hasPrefix($0 + "/") } }

        func read(_ count: Int) { lock.withLock { entriesRead += count } }

        /// Every command and the real paths it leads to. Built on first use.
        var commandIndex: [Command] {
            if let commands = lock.withLock({ commands }) { return commands }
            let built = CleanDependents.commands(home: home, context: self)
            lock.withLock { commands = built }
            return built
        }
    }

    /// One command: a link or a launcher script, and where it leads.
    struct Command {
        var name: String
        /// As the owner knows it, for the message.
        var folder: String
        var path: String
        var targets: [String]
    }

    /// A sentence naming what still uses one of `paths`, or nil when nothing Wisp can find does.
    public static func dependent(of paths: [String], home: String, context: Context? = nil) -> String? {
        let context = context ?? Context(home: home)
        let targets = paths.compactMap(CleanPathRules.realPath)
        guard !targets.isEmpty else { return nil }
        func isTarget(_ path: String) -> Bool { targets.contains { path == $0 || path.hasPrefix($0 + "/") } }

        for command in context.commandIndex where !isTarget(command.path) && !context.isGoing(command.path) {
            if command.targets.contains(where: isTarget) { return "\(command.name) in \(display(command.folder, context: context)) runs from it" }
        }

        if let found = pnpmProjects(targets, context: context, isTarget: isTarget) { return found }

        let homeReal = context.homeReal
        var walked = Set<String>()
        for target in targets {
            let parent = (target as NSString).deletingLastPathComponent
            guard parent.hasPrefix(homeReal + "/"), !sharedFolders.contains(String(parent.dropFirst(homeReal.count + 1))),
                  walked.insert(parent).inserted else { continue }
            var budget = walkLimit
            defer { context.read(walkLimit - max(0, budget)) }
            let project = projectMarkers.contains { CleanFiles.exists(parent + "/" + $0) }
            switch walk(parent, depth: 0, budget: &budget, project: project, context: context, isTarget: isTarget) {
            case .clear: continue
            case .found(let path): return "\(display(path, context: context)) links into it"
            case .tooBig: return "Wisp could not check everything in \(display(parent, context: context)) that might use it"
            }
        }
        return nil
    }

    enum Walk { case clear, found(String), tooBig }

    /// The commands in the usual folders and the PATH, each with where its link or script leads.
    static func commands(home: String, context: Context) -> [Command] {
        var folders = homeCommandFolders.map { home + "/" + $0 } + systemCommandFolders
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        where entry.hasPrefix("/") && !folders.contains(entry) {
            folders.append(entry)
        }
        var commands: [Command] = []
        var seen = Set<String>()
        for folder in folders {
            guard let real = CleanPathRules.realPath(folder), seen.insert(real).inserted else { continue }
            let names = CleanFiles.names(real)
            context.read(names.count)
            for name in names {
                let targets = leadsTo(real + "/" + name, readScript: true, home: home)
                if !targets.isEmpty { commands.append(Command(name: name, folder: folder, path: real + "/" + name, targets: targets)) }
            }
        }
        return commands
    }

    /// Files that make a folder a project, so the build folders anywhere in it are its own output.
    static let projectMarkers = ["package.json", "Cargo.toml", "pyproject.toml", "setup.py", "Package.swift", "Podfile", "build.gradle",
                                 "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "CMakeLists.txt", "meson.build",
                                 "pubspec.yaml", "go.mod", "pom.xml", "Gemfile", "composer.json", "turbo.json"]

    /// Links anywhere under `folder`, and the scripts in its bin folders, that lead into a target.
    /// Build output beside the item (a project's .next linking into its node_modules) is made
    /// again by the next build, so its links do not count, and neither do links in what goes too.
    /// In a project that holds for its build folders at any depth (apps/web/.next in a
    /// monorepo); elsewhere only right beside the item, since pnpm's own global packages sit in
    /// a node_modules folder deep inside ~/Library/pnpm.
    private static func walk(_ folder: String, depth: Int, budget: inout Int, project: Bool, context: Context,
                             isTarget: (String) -> Bool) -> Walk {
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
            if context.isGoing(path) { continue }
            switch Int32(entry.pointee.d_type) {
            case DT_DIR:
                // .git holds no links a tool runs from, and is most of a big project's files.
                if child == ".git" || isTarget(path) || depth >= walkDepth { continue }
                if depth == 0 || project, StorageCatalog.artifactNames.contains(child) { continue }
                let result = walk(path, depth: depth + 1, budget: &budget, project: project, context: context, isTarget: isTarget)
                if case .clear = result { continue }
                return result
            case DT_LNK, DT_REG:
                if leadsTo(path, readScript: readScripts, home: context.home).contains(where: isTarget) { return .found(path) }
            default: continue
            }
        }
        return .clear
    }

    /// pnpm 10 and later keep a link to every project that installed from a store in
    /// `<store>/v<N>/projects`. With its global virtual store on, a project's node_modules
    /// links straight into the store, and removing the store breaks every such project.
    static func pnpmProjects(_ targets: [String], context: Context, isTarget: (String) -> Bool) -> String? {
        var budget = projectLimit
        defer { context.read(projectLimit - max(0, budget)) }
        var linked: [String] = []
        for target in targets {
            for version in CleanFiles.names(target) where version.hasPrefix("v") {
                let registry = target + "/" + version + "/projects"
                guard CleanFiles.isDirectory(registry) else { continue }
                for entry in CleanFiles.names(registry) {
                    budget -= 1
                    guard let project = CleanPathRules.realPath(registry + "/" + entry), !isTarget(project), !context.isGoing(project),
                          CleanFiles.isDirectory(project + "/node_modules") else { continue }
                    switch linksInto(project + "/node_modules", budget: &budget, isTarget: isTarget) {
                    case .clear: continue
                    case .found: linked.append(project)
                    case .tooBig: return "Wisp could not check every pnpm project that might use it"
                    }
                }
            }
        }
        guard let first = linked.sorted().first else { return nil }
        let place = display(first, context: context)
        return linked.count == 1 ? "The pnpm project in \(place) links into it" : "\(linked.count) pnpm projects link into it, such as \(place)"
    }

    /// The packages at the top of a node_modules folder, scoped ones included, that are links into a target.
    private static func linksInto(_ modules: String, budget: inout Int, isTarget: (String) -> Bool) -> Walk {
        for name in CleanFiles.names(modules) where name != ".bin" {
            budget -= 1
            if budget < 0 { return .tooBig }
            let path = modules + "/" + name
            if name.hasPrefix("@"), CleanFiles.isDirectory(path) {
                for inner in CleanFiles.names(path) {
                    budget -= 1
                    if budget < 0 { return .tooBig }
                    if leadsTo(path + "/" + inner, readScript: false, home: "").contains(where: isTarget) { return .found(path + "/" + inner) }
                }
            } else if name == ".pnpm" {
                continue
            } else if leadsTo(path, readScript: false, home: "").contains(where: isTarget) {
                return .found(path)
            }
        }
        return .clear
    }

    /// Where `path` leads: the end of a link, or the files a launcher script names. Empty for anything else.
    static func leadsTo(_ path: String, readScript: Bool, home: String) -> [String] {
        var info = stat()
        guard lstat(path, &info) == 0 else { return [] }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            return CleanPathRules.realPath(path).map { [$0] } ?? []
        case S_IFREG where readScript && info.st_size < scriptLimit && info.st_mode & 0o111 != 0:
            return scriptReferences(path, home: home).compactMap(CleanPathRules.realPath)
        default:
            return []
        }
    }

    /// Whether `path` is a link that ends in a target, or a script that names a file in one.
    static func usesTarget(_ path: String, readScript: Bool, home: String, isTarget: (String) -> Bool) -> Bool {
        leadsTo(path, readScript: readScript, home: home).contains(where: isTarget)
    }

    /// Paths a launcher script names. Installers write these (npm's and pnpm's shims start
    /// a tool with `exec "$basedir/../global/.../pnpm"`), so a variable before the first
    /// slash is read as the script's own folder.
    static func scriptReferences(_ path: String, home: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path), data.starts(with: Array("#!".utf8)) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let folder = (path as NSString).deletingLastPathComponent
        guard let regex = scriptPath else { return [] }
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

    private static let scriptPath = try? NSRegularExpression(pattern: #"(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|~|)/[A-Za-z0-9_.@+/-]+"#)

    private static func display(_ path: String, context: Context) -> String {
        for prefix in [context.home, context.homeReal] where path.hasPrefix(prefix + "/") { return "~" + path.dropFirst(prefix.count) }
        return path
    }
}
