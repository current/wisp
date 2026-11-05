import Foundation

/// Caches and downloads that developer tools keep in the home folder, one row per tool.
public struct DeveloperCacheScanner: CleanScanner {
    struct Tool {
        let id: String
        let group: String
        let name: String
        /// Relative to the home folder. Only the parts a tool fetches or builds again, never its settings.
        let paths: [String]
        let safety: CleanSafety
        let detail: String
        var owner: String? = nil
    }

    static let xcode = "Xcode"
    static let packages = "Package caches"
    static let tools = "Editors and tools"

    /// Name and paths from the Storage catalogue where it has the row; paths narrowed where its row is wider than a cache.
    private static func catalog(_ row: String, group: String, paths: [String]? = nil, safety: CleanSafety, detail: String,
                                owner: String? = nil) -> Tool {
        let location = StorageCatalog.location(row: row)
        return Tool(id: row, group: group, name: location?.name ?? row, paths: paths ?? location?.paths ?? [], safety: safety, detail: detail,
                    owner: owner)
    }

    static let catalogue: [Tool] = [
        catalog("deriveddata", group: xcode, safety: .safe,
                detail: "Build products and indexes. Xcode makes them again, and the next build takes longer.", owner: "com.apple.dt.Xcode"),
        catalog("archives", group: xcode, safety: .checkFirst,
                detail: "Builds you archived. Without their debug symbols, crash reports from those builds cannot be read."),
        catalog("devicesupport", group: xcode, safety: .safe,
                detail: "Symbols copied from devices you connected. Xcode copies them again the next time you connect one."),
        catalog("previews", group: xcode, safety: .safe,
                detail: "Preview builds. Xcode makes them again when you open a preview.", owner: "com.apple.dt.Xcode"),
        catalog("simcaches", group: xcode, safety: .safe, detail: "Caches the simulators make again the next time they start."),
        Tool(id: "xcodecache", group: xcode, name: "Xcode cache", paths: ["Library/Caches/com.apple.dt.Xcode"], safety: .safe,
             detail: "Downloads and caches Xcode makes again as you use it.", owner: "com.apple.dt.Xcode"),

        catalog("homebrew", group: packages, safety: .safe, detail: "Bottles and sources brew downloads again when it needs them."),
        catalog("npm", group: packages, paths: [".npm/_cacache", ".npm/_npx"], safety: .safe,
                detail: "Packages npm and npx download again when needed."),
        catalog("pnpm", group: packages, paths: ["Library/pnpm/store", ".pnpm-store", ".local/share/pnpm/store"], safety: .safe,
                detail: "Packages pnpm shares between projects. pnpm downloads them again when needed."),
        catalog("yarn", group: packages, safety: .safe, detail: "Packages Yarn downloads again when needed."),
        catalog("bun", group: packages, safety: .safe, detail: "Packages Bun downloads again when needed."),
        catalog("cocoapods", group: packages, paths: ["Library/Caches/CocoaPods"], safety: .safe,
                detail: "Pod sources CocoaPods downloads again on the next pod install."),
        catalog("gradle", group: packages, paths: [".gradle/caches", ".gradle/wrapper/dists"], safety: .safe,
                detail: "Dependencies and Gradle versions Gradle downloads again on the next build."),
        catalog("maven", group: packages, safety: .checkFirst,
                detail: "Dependencies Maven downloads again. Anything you put there with mvn install goes too."),
        Tool(id: "pub", group: packages, name: "Dart and Flutter packages", paths: [".pub-cache/hosted", ".pub-cache/git"], safety: .safe,
             detail: "Packages pub downloads again on the next pub get."),
        catalog("cargo", group: packages, safety: .safe, detail: "Crate sources cargo downloads again on the next build."),
        catalog("gobuild", group: packages, safety: .safe, detail: "Compiled packages go builds again."),
        catalog("pip", group: packages, safety: .safe, detail: "Packages pip downloads again when needed."),
        catalog("uv", group: packages, safety: .safe, detail: "Packages and Python builds uv fetches again when needed."),
        catalog("poetry", group: packages, paths: ["Library/Caches/pypoetry/cache", "Library/Caches/pypoetry/artifacts"], safety: .safe,
                detail: "Packages Poetry downloads again. Its environments stay."),
        catalog("swiftpm", group: packages, paths: ["Library/Caches/org.swift.swiftpm"], safety: .safe,
                detail: "Package checkouts Swift downloads again on the next resolve."),

        Tool(id: "vscode", group: tools, name: "VS Code cache",
             paths: ["Library/Application Support/Code/CachedData", "Library/Application Support/Code/CachedExtensionVSIXs"], safety: .safe,
             detail: "Compiled code and extension downloads VS Code makes again.", owner: "com.microsoft.VSCode"),
        Tool(id: "cursor", group: tools, name: "Cursor cache",
             paths: ["Library/Application Support/Cursor/CachedData", "Library/Application Support/Cursor/CachedExtensionVSIXs"], safety: .safe,
             detail: "Compiled code and extension downloads Cursor makes again.", owner: "com.todesktop.230313mzl4w4u92"),
        catalog("jetbrains", group: tools, safety: .safe,
                detail: "Indexes the JetBrains IDEs build again. The next time you open a project it takes longer."),
        Tool(id: "terraform", group: tools, name: "Terraform plugins", paths: [".terraform.d/plugin-cache"], safety: .safe,
             detail: "Providers Terraform downloads again on the next terraform init."),
        Tool(id: "ccache", group: tools, name: "ccache", paths: ["Library/Caches/ccache", ".ccache", ".cache/ccache"], safety: .safe,
             detail: "Compiler output ccache keeps. Builds are slower until it fills again."),
        Tool(id: "sccache", group: tools, name: "sccache", paths: ["Library/Caches/Mozilla.sccache", ".cache/sccache"], safety: .safe,
             detail: "Compiler output sccache keeps. Builds are slower until it fills again."),
        catalog("playwright", group: tools, safety: .checkFirst,
                detail: "Browsers for Playwright and Puppeteer tests. playwright install downloads them again."),
    ]

    /// Folders in ~/Library/Caches that this scanner lists, so the app cache list leaves them out.
    static let cacheFolders: Set<String> = Set(catalogue.flatMap(\.paths).compactMap { path in
        guard path.hasPrefix("Library/Caches/") else { return nil }
        return path.dropFirst("Library/Caches/".count).split(separator: "/").first.map(String.init)
    })

    public var tab: CleanTab { .developer }
    public var minimumBytes: Int64
    /// Where Go keeps module sources, which `go env GOMODCACHE` can move.
    public var goModuleCache: @Sendable (String) -> String?

    public init(minimumBytes: Int64 = 1 << 20, goModuleCache: @escaping @Sendable (String) -> String? = { DeveloperCacheScanner.goModuleCache(home: $0) }) {
        self.minimumBytes = minimumBytes
        self.goModuleCache = goModuleCache
    }

    /// GOMODCACHE from the environment or from `go env` when go is installed, else ~/go/pkg/mod.
    public static func goModuleCache(home: String) -> String? {
        if let value = ProcessInfo.processInfo.environment["GOMODCACHE"], !value.isEmpty { return value }
        for go in ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"] where FileManager.default.isExecutableFile(atPath: go) {
            let path = Run.output(go, ["env", "GOMODCACHE"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if path.hasPrefix("/") { return path }
        }
        return home + "/go/pkg/mod"
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let home = context.homePath
        var tools = Self.catalogue.map { tool in
            Tool(id: tool.id, group: tool.group, name: tool.name, paths: tool.paths.map { home + "/" + $0 }, safety: tool.safety,
                 detail: tool.detail, owner: tool.owner)
        }
        if let modules = goModuleCache(home), modules.hasPrefix(home + "/") {
            let index = tools.firstIndex { $0.id == "gobuild" } ?? tools.count
            tools.insert(Tool(id: "gomod", group: Self.packages, name: StorageCatalog.location(row: "gomod")?.name ?? "Go modules",
                              paths: [modules], safety: .checkFirst,
                              detail: "Module sources go downloads again. Go makes them read-only, so the Trash may ask for your permission."),
                         at: index)
        }

        let sizer = CleanSizer(context)
        var items: [CleanItem] = []
        for group in [Self.xcode, Self.packages, Self.tools] {
            if sizer.cancelled || context.isCancelled() { break }
            let groupTools = tools.filter { $0.group == group }
            let existing = groupTools.flatMap(\.paths).filter { CleanFiles.isDirectory($0) && !context.isBlocked($0) }
            let sizes = sizer.sizes(existing)
            var batch: [CleanItem] = []
            for tool in groupTools {
                let paths = tool.paths.filter { sizes[$0] != nil }
                let size = sizer.total(paths, sizes: sizes)
                guard !paths.isEmpty, size.bytes >= minimumBytes else { continue }
                batch.append(CleanItem(id: "devcache:\(paths[0])", tab: .developer, group: group, name: tool.name, detail: tool.detail,
                                       paths: paths, bytes: size.bytes, modified: size.modified, safety: tool.safety,
                                       ownerBundleID: tool.owner))
            }
            if !batch.isEmpty { context.found(batch) }
            items += batch
        }
        return items
    }
}
