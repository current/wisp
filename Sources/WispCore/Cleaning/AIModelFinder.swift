import Darwin
import Foundation

/// Local AI models: the stores of the apps that download them, then loose weight files
/// in caches and app data that no known store claims.
struct AIModelFinder {
    let home: String
    let environment: [String: String]
    let limits: LargeFilesScanner.Limits
    let context: CleanScanContext

    /// How a store keeps its models on disk.
    enum Layout {
        /// One row per folder this many levels down: LM Studio's publisher/model.
        case folders(depth: Int, skip: Set<String>)
        /// One row per file at any depth, of these extensions when given.
        case files(Set<String>?)
        /// One row per folder that directly holds a weight file over the row threshold.
        case weightFolders
        case ollama
        case huggingFace
    }

    struct Store {
        var app: String
        var root: String
        var layout: Layout
        /// A download cache: whatever needs the model fetches it again, there is no list of installed models.
        var isCache = false
    }

    private var cacheHome: String { environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.cache" }
    private var support: String { home + "/Library/Application Support" }

    /// Every store that may exist. Only folders that are there produce rows.
    var stores: [Store] {
        var hub: [String] = []
        if let cache = environment["HF_HUB_CACHE"] ?? environment["HUGGINGFACE_HUB_CACHE"], !cache.isEmpty { hub.append(cache) }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty { hub.append(hfHome + "/hub") }
        hub.append(cacheHome + "/huggingface/hub")
        hub.append(home + "/.cache/huggingface/hub")
        let torch = (environment["TORCH_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? cacheHome + "/torch") + "/hub"

        var list: [Store] = [Store(app: "Ollama", root: environment["OLLAMA_MODELS"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.ollama/models",
                                   layout: .ollama)]
        list += hub.map { Store(app: "Hugging Face", root: $0, layout: .huggingFace, isCache: true) }
        list += [
            Store(app: "LM Studio", root: home + "/.lmstudio/models", layout: .folders(depth: 2, skip: [])),
            Store(app: "LM Studio", root: home + "/.cache/lm-studio/models", layout: .folders(depth: 2, skip: [])),
            Store(app: "PyTorch Hub", root: torch + "/checkpoints", layout: .files(nil), isCache: true),
            Store(app: "PyTorch Hub", root: torch, layout: .folders(depth: 1, skip: ["checkpoints"]), isCache: true),
            Store(app: "Whisper", root: cacheHome + "/whisper", layout: .files(["pt"]), isCache: true),
            Store(app: "GPT4All", root: support + "/nomic.ai/GPT4All", layout: .files(["gguf", "bin"])),
            Store(app: "GPT4All", root: home + "/.cache/gpt4all", layout: .files(["gguf", "bin"])),
            Store(app: "Jan", root: home + "/jan/models", layout: .weightFolders),
            Store(app: "Jan", root: support + "/Jan/data", layout: .weightFolders),
            Store(app: "DiffusionBee", root: home + "/.diffusionbee",
                  layout: .files(["tdict", "ckpt", "safetensors", "bin", "pt", "pth"])),
        ]
        // Reading another app's container can ask the owner for permission, so only when the app is installed.
        if ["/Applications", home + "/Applications"].contains(where: { FileManager.default.fileExists(atPath: $0 + "/Draw Things.app") }) {
            list.append(Store(app: "Draw Things", root: home + "/Library/Containers/com.liuliu.draw-things/Data/Documents/Models",
                              layout: .files(nil)))
        }
        return list
    }

    /// Queues the work on `pool`; rows arrive through `emit` as each part finishes.
    func find(pool: TaskPool, emit: @escaping ([Row]) -> Void) {
        var claimed = Set<String>()
        var known: [Store] = []
        for store in stores {
            guard let real = LargeFilesScanner.realPath(store.root), !claimed.contains(real) else { continue }
            claimed.formUnion([real, store.root])
            if !context.isExcluded(store.root) { known.append(store) }
        }
        pool.add {
            for store in known where !context.isCancelled() { emit(rows(store)) }
        }
        var bases: [String] = []
        for base in [home + "/Library/Caches", support, cacheHome, home + "/.cache"] {
            guard let real = LargeFilesScanner.realPath(base), !bases.contains(real) else { continue }
            bases.append(real)
            pool.add { emit(unknownWeights(base: base, claimed: claimed, pool: pool, emit: emit)) }
        }
    }

    // MARK: Known stores

    private func rows(_ store: Store) -> [Row] {
        switch store.layout {
        case .ollama: return ollama(store)
        case .huggingFace: return huggingFace(store)
        case let .folders(depth, skip): return folders(store, depth: depth, skip: skip)
        case let .files(extensions): return files(store, extensions: extensions)
        case .weightFolders: return weightFolders(store)
        }
    }

    private func detail(_ store: Store, _ folder: String) -> String {
        let place = LargeFilesScanner.place(folder, home: home)
        if store.isCache { return "Downloaded by \(store.app) into \(place). Whatever uses it downloads it again." }
        return "Kept by \(store.app) in \(place). \(store.app) may still list it as installed."
    }

    private func row(_ store: Store, name: String, paths: [String], bytes: UInt64, modified: Double, detail: String? = nil) -> Row? {
        guard Int64(bytes) >= limits.knownModel, !paths.isEmpty else { return nil }
        let date = modified > 0 ? Date(timeIntervalSince1970: modified) : nil
        let folder = (paths[0] as NSString).deletingLastPathComponent
        let item = CleanItem(id: "ai:" + paths[0], tab: .largeFiles, group: LargeFileCategory.aiModels.rawValue, name: name,
                             detail: detail ?? self.detail(store, folder), paths: paths, bytes: Int64(bytes), modified: date,
                             safety: .checkFirst, checkedByDefault: false)
        return Row(item: item, info: LargeFileInfo(category: .aiModels, lastUsed: nil, modified: date))
    }

    private func walker() -> BulkWalker { BulkWalker(isCancelled: context.isCancelled) }

    /// The entries of one folder, without following links.
    private func entries(_ path: String) -> [BulkEntry] {
        var list: [BulkEntry] = []
        walker().walk(path) { _, entry, _ in
            list.append(entry)
            return .skip
        }
        return list.filter { !$0.isDataless && !context.isExcluded(path + "/" + $0.name) }
    }

    private func folders(_ store: Store, depth: Int, skip: Set<String>) -> [Row] {
        var rows: [Row] = []
        func visit(_ path: String, _ relative: [String]) {
            for entry in entries(path) where entry.kind == .folder && !entry.name.hasPrefix(".") && !skip.contains(entry.name) {
                let child = path + "/" + entry.name
                if relative.count + 1 < depth {
                    visit(child, relative + [entry.name])
                } else {
                    let size = walker().folderSize(child)
                    if let row = row(store, name: (relative + [entry.name]).joined(separator: "/"), paths: [child],
                                     bytes: size.bytes, modified: size.newest) { rows.append(row) }
                }
            }
        }
        visit(store.root, [])
        return rows
    }

    private func files(_ store: Store, extensions: Set<String>?) -> [Row] {
        var rows: [Row] = []
        walker().walk(store.root) { parent, entry, _ in
            let path = parent + "/" + entry.name
            if entry.isDataless || context.isExcluded(path) { return .skip }
            if entry.kind == .folder {
                guard entry.pathExtension == "mlpackage" else { return .descend }
                let size = walker().folderSize(path)
                if let row = row(store, name: entry.name, paths: [path], bytes: size.bytes, modified: size.newest) { rows.append(row) }
                return .skip
            }
            guard entry.kind == .file, !entry.name.hasPrefix("."), extensions?.contains(entry.pathExtension) ?? true else { return .skip }
            let name = Self.modelName(entry.name, app: store.app)
            if let row = row(store, name: name, paths: [path], bytes: entry.allocated, modified: entry.modified) { rows.append(row) }
            return .skip
        }
        return rows
    }

    private func weightFolders(_ store: Store) -> [Row] {
        var byFolder: [String: (bytes: UInt64, modified: Double, big: Bool)] = [:]
        walker().walk(store.root) { parent, entry, _ in
            let path = parent + "/" + entry.name
            if entry.isDataless || context.isExcluded(path) { return .skip }
            if entry.kind == .folder { return .descend }
            guard entry.kind == .file else { return .skip }
            let weight = LargeFileKinds.weightExtensions.contains(entry.pathExtension)
            var folder = byFolder[parent] ?? (0, 0, false)
            folder.bytes &+= entry.allocated
            folder.modified = max(folder.modified, entry.modified)
            folder.big = folder.big || (weight && Int64(entry.allocated) >= limits.knownModel)
            byFolder[parent] = folder
            return .skip
        }
        return byFolder.filter(\.value.big).sorted { $0.key < $1.key }.compactMap { folder, contents in
            row(store, name: (folder as NSString).lastPathComponent, paths: [folder], bytes: contents.bytes, modified: contents.modified)
        }
    }

    /// "large-v3.pt" in Whisper's cache becomes "Whisper large-v3".
    static func modelName(_ file: String, app: String) -> String {
        guard app == "Whisper" else { return file }
        return "Whisper " + (file as NSString).deletingPathExtension
    }

    // MARK: Ollama

    private struct OllamaManifest: Decodable {
        struct Layer: Decodable { let digest: String }
        let config: Layer?
        let layers: [Layer]?
        var digests: Set<String> { Set((layers ?? []).map(\.digest) + (config.map { [$0.digest] } ?? [])) }
    }

    /// "registry.ollama.ai/library/llama3.1/8b" is "llama3.1:8b"; other namespaces and hosts keep their prefix.
    static func ollamaName(_ components: [String]) -> String {
        guard components.count >= 4 else { return components.joined(separator: "/") }
        let host = components[0]
        let model = components[components.count - 2]
        let tag = components[components.count - 1]
        let namespace = components[1..<(components.count - 2)].joined(separator: "/")
        if host == "registry.ollama.ai" { return namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)" }
        return "\(host)/\(namespace)/\(model):\(tag)"
    }

    /// One row per model as `ollama list` names it. Tags that point at the same files are one row,
    /// and a row counts only the blobs no other model uses.
    private func ollama(_ store: Store) -> [Row] {
        let manifests = store.root + "/manifests"
        var found: [(name: String, path: String, digests: Set<String>, modified: Double)] = []
        walker().walk(manifests) { parent, entry, _ in
            if entry.kind == .folder { return .descend }
            guard entry.kind == .file, !entry.name.hasPrefix(".") else { return .skip }
            let path = parent + "/" + entry.name
            guard let data = FileManager.default.contents(atPath: path),
                  let manifest = try? JSONDecoder().decode(OllamaManifest.self, from: data) else { return .skip }
            let components = String(path.dropFirst(manifests.count + 1)).split(separator: "/").map(String.init)
            found.append((Self.ollamaName(components), path, manifest.digests, entry.modified))
            return .skip
        }
        let models = Dictionary(grouping: found, by: \.digests).map { digests, tags in
            (names: tags.map(\.name).sorted(), paths: tags.map(\.path).sorted(), digests: digests, modified: tags.map(\.modified).max() ?? 0)
        }
        var users: [String: Int] = [:]
        for model in models { for digest in model.digests { users[digest, default: 0] += 1 } }

        func blob(_ digest: String) -> (path: String, bytes: UInt64)? {
            let path = store.root + "/blobs/" + digest.replacingOccurrences(of: ":", with: "-")
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return (path, UInt64(info.st_blocks) * 512)
        }
        return models.sorted { $0.names[0] < $1.names[0] }.compactMap { model in
            var paths = model.paths
            var own: UInt64 = 0
            var shared: UInt64 = 0
            for digest in model.digests.sorted() {
                guard let file = blob(digest) else { continue }
                if users[digest] == 1 {
                    paths.append(file.path)
                    own &+= file.bytes
                } else {
                    shared &+= file.bytes
                }
            }
            var detail = "Kept by Ollama. Ollama may still list it as installed until it restarts."
            if shared > 0 { detail += " The \(Format.bytes(shared)) it shares with other models stays." }
            return row(store, name: model.names.joined(separator: ", "), paths: paths, bytes: own, modified: model.modified, detail: detail)
        }
    }

    // MARK: Hugging Face

    /// "models--meta-llama--Llama-3.1-8B" is "meta-llama/Llama-3.1-8B".
    static func huggingFaceName(_ folder: String) -> String? {
        guard folder.hasPrefix("models--") else { return nil }
        return folder.dropFirst("models--".count).components(separatedBy: "--").joined(separator: "/")
    }

    /// Snapshots are symlinks into blobs, so counting regular files counts each blob once.
    private func huggingFace(_ store: Store) -> [Row] {
        entries(store.root).compactMap { entry in
            guard entry.kind == .folder, let name = Self.huggingFaceName(entry.name) else { return nil }
            let path = store.root + "/" + entry.name
            let size = walker().folderSize(path)
            return row(store, name: name, paths: [path], bytes: size.bytes, modified: size.newest)
        }
    }

    // MARK: Weights no store claims

    /// Folders that hold no models and are slow or private to walk.
    static let unknownSkip: Set<String> = ["MobileSync", "Steam", "CloudDocs", "FileProvider", "Knowledge",
                                           "AddressBook", "CallHistoryDB", "CallHistoryTransactions"]
    private static let modelHints = ["model", "weight", "llm", "whisper", "checkpoint", "ggml", "gguf", "diffusion", "embedding"]

    /// Weight files under `base`. The base and the folders right inside it list only their own
    /// entries and queue each subfolder as a task. A folder's files all land in one task, so each
    /// task groups them by folder on its own.
    private func unknownWeights(base: String, folder: String? = nil, depth: Int = 0, claimed: Set<String>, pool: TaskPool,
                                emit: @escaping ([Row]) -> Void) -> [Row] {
        var byFolder: [String: (paths: [String], bytes: UInt64, modified: Double)] = [:]
        var subfolders: [String] = []
        func add(_ folder: String, _ path: String, _ bytes: UInt64, _ modified: Double) {
            var group = byFolder[folder] ?? ([], 0, 0)
            group.paths.append(path)
            group.bytes &+= bytes
            group.modified = max(group.modified, modified)
            byFolder[folder] = group
        }
        walker().walk(folder ?? base) { parent, entry, level in
            let path = parent + "/" + entry.name
            if entry.isDataless || context.isExcluded(path) { return .skip }
            if entry.kind == .folder {
                // A known store is reached through its own folder, so matching that folder is enough.
                if entry.name == "node_modules" || claimed.contains(path) { return .skip }
                // Apple's own assets are managed by the system, which downloads them again.
                if depth + level == 0, entry.name.hasPrefix("com.apple.") || Self.unknownSkip.contains(entry.name) { return .skip }
                if entry.pathExtension == "mlpackage" {
                    let size = walker().folderSize(path)
                    if Int64(size.bytes) >= limits.unknownModel { add(parent, path, size.bytes, size.newest) }
                    return .skip
                }
                if depth < 2 {
                    subfolders.append(path)
                    return .skip
                }
                return .descend
            }
            guard entry.kind == .file, Int64(entry.allocated) >= limits.unknownModel,
                  LargeFileKinds.weightExtensions.contains(entry.pathExtension) else { return .skip }
            if entry.pathExtension == "bin", !Self.looksLikeModel(parent) { return .skip }
            add(parent, path, entry.allocated, entry.modified)
            return .skip
        }
        for sub in subfolders {
            pool.add { emit(unknownWeights(base: base, folder: sub, depth: depth + 1, claimed: claimed, pool: pool, emit: emit)) }
        }
        return byFolder.sorted { $0.key < $1.key }.compactMap { folder, group in
            guard Int64(group.bytes) >= limits.unknownModel else { return nil }
            let app = Self.appName(folder: folder, base: base)
            let store = Store(app: app, root: folder, layout: .files(nil))
            let place = LargeFilesScanner.place(folder, home: home)
            let detail = "Model weights kept by \(app) in \(place). \(app) may still list the model as installed."
            return row(store, name: Self.folderName(folder, base: base), paths: group.paths.sorted(), bytes: group.bytes,
                       modified: group.modified, detail: detail)
        }
    }

    /// A .bin file is only taken for weights when its folder says so: a model-ish name or a config.json beside it.
    static func looksLikeModel(_ folder: String) -> Bool {
        let lower = folder.lowercased()
        return modelHints.contains { lower.contains($0) } || FileManager.default.fileExists(atPath: folder + "/config.json")
    }

    private static let vendors: Set<String> = ["Google", "Microsoft", "Adobe", "JetBrains", "BraveSoftware", "nomic.ai"]

    /// The first folder below the base, plus the next for a vendor folder: "Google/Chrome" is "Google Chrome".
    static func appName(folder: String, base: String) -> String {
        let parts = folder.dropFirst(base.count).split(separator: "/").map(String.init)
        guard let first = parts.first else { return (base as NSString).lastPathComponent }
        if vendors.contains(first), parts.count > 1 { return first + " " + parts[1] }
        return first
    }

    /// The folder's own name, or its parent's when the name says nothing ("models", a version, a hash).
    static func folderName(_ folder: String, base: String) -> String {
        let generic: Set<String> = ["models", "model", "weights", "checkpoints", "cache", "snapshots", "blobs", "data", "files"]
        var parts = folder.dropFirst(base.count).split(separator: "/").map(String.init)
        let containers: Set<String> = ["mlmodelc", "mlpackage"]
        while parts.count > 1, let last = parts.last,
              generic.contains(last.lowercased()) || last.first?.isNumber == true || (last.count >= 32 && last.allSatisfy(\.isHexDigit))
                || containers.contains((last as NSString).pathExtension) {
            parts.removeLast()
        }
        return parts.last ?? (folder as NSString).lastPathComponent
    }
}
