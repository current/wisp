import Foundation

/// The slices of the whole-disk bar.
public enum StorageCategory: String, Codable, CaseIterable, Sendable {
    case apps, developer, documents, mail, system, snapshots, purgeable, free

    public var title: String {
        switch self {
        case .apps: return "Apps"
        case .developer: return "Developer"
        case .documents: return "Documents & Media"
        case .mail: return "Mail & Messages"
        case .system: return "macOS & System Data"
        case .snapshots: return "Snapshots"
        case .purgeable: return "Purgeable"
        case .free: return "Free"
        }
    }
}

/// A known place on disk: which slice it belongs to, the row it adds up into and
/// one line on what it is or what deleting it does.
struct StorageLocation {
    let row: String
    let category: StorageCategory
    /// Relative to the home folder, or absolute when it starts with "/".
    let paths: [String]
    let name: String
    let detail: String
}

enum StorageCatalog {
    static let developer: [StorageLocation] = [
        .init(row: "deriveddata", category: .developer, paths: ["Library/Developer/Xcode/DerivedData"], name: "Xcode DerivedData",
              detail: "Build products and indexes. Xcode makes them again; the next build takes longer"),
        .init(row: "archives", category: .developer, paths: ["Library/Developer/Xcode/Archives"], name: "Xcode archives",
              detail: "Builds you archived, with their debug symbols for reading crash reports"),
        .init(row: "devicesupport", category: .developer,
              paths: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
                      "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport"],
              name: "Device support", detail: "Symbols copied from devices you connected. Xcode copies them again next time"),
        .init(row: "simulators", category: .developer, paths: ["Library/Developer/CoreSimulator/Devices"], name: "Simulators",
              detail: "Simulated devices with their apps and data. Deleting one removes everything in it"),
        .init(row: "simcaches", category: .developer, paths: ["Library/Developer/CoreSimulator/Caches"], name: "Simulator caches",
              detail: "Made again the next time a simulator starts"),
        .init(row: "previews", category: .developer, paths: ["Library/Developer/Xcode/UserData/Previews"], name: "SwiftUI previews",
              detail: "Preview builds. Made again when you open a preview"),
        .init(row: "xcodeother", category: .developer, paths: ["Library/Developer"], name: "Other Xcode data",
              detail: "Settings, logs and products Xcode keeps"),
        .init(row: "docker", category: .developer, paths: ["Library/Containers/com.docker.docker/Data/vms"], name: "Docker Desktop",
              detail: "The Linux disk with every image, container and volume. Prune from Docker instead of deleting it"),
        .init(row: "orbstack", category: .developer, paths: ["Library/Group Containers/HUC964yHBR.dev.orbstack", ".orbstack"], name: "OrbStack",
              detail: "Disk of OrbStack's Linux machine with images and containers. Clean up from OrbStack"),
        .init(row: "colima", category: .developer, paths: [".colima"], name: "Colima",
              detail: "Virtual machine disks. colima delete removes a machine and its images"),
        .init(row: "lima", category: .developer, paths: [".lima"], name: "Lima", detail: "Virtual machine disks. limactl delete removes one"),
        .init(row: "podman", category: .developer, paths: [".local/share/containers"], name: "Podman",
              detail: "Machine disks and images. podman machine rm removes a machine"),
        .init(row: "homebrew", category: .developer, paths: ["Library/Caches/Homebrew"], name: "Homebrew downloads",
              detail: "Bottles and sources brew can download again"),
        .init(row: "npm", category: .developer, paths: [".npm"], name: "npm cache", detail: "Packages npm downloads again when needed"),
        .init(row: "pnpm", category: .developer, paths: ["Library/pnpm", ".pnpm-store", ".local/share/pnpm"], name: "pnpm store",
              detail: "Shared packages for your projects. pnpm downloads them again"),
        .init(row: "yarn", category: .developer, paths: ["Library/Caches/Yarn", ".yarn/berry/cache"], name: "Yarn cache",
              detail: "Packages yarn downloads again when needed"),
        .init(row: "bun", category: .developer, paths: [".bun/install/cache"], name: "Bun cache", detail: "Packages bun downloads again"),
        .init(row: "pip", category: .developer, paths: ["Library/Caches/pip"], name: "pip cache", detail: "Wheels pip downloads again"),
        .init(row: "uv", category: .developer, paths: [".cache/uv", "Library/Caches/uv"], name: "uv cache",
              detail: "Packages and Python builds uv fetches again"),
        .init(row: "poetry", category: .developer, paths: ["Library/Caches/pypoetry"], name: "Poetry cache", detail: "Packages Poetry downloads again"),
        .init(row: "cargo", category: .developer, paths: [".cargo/registry", ".cargo/git"], name: "Cargo registry",
              detail: "Crate sources cargo downloads again"),
        .init(row: "rustup", category: .developer, paths: [".rustup"], name: "Rust toolchains", detail: "Toolchains rustup installed"),
        .init(row: "gomod", category: .developer, paths: ["go/pkg/mod"], name: "Go modules", detail: "Module sources go downloads again"),
        .init(row: "gobuild", category: .developer, paths: ["Library/Caches/go-build"], name: "Go build cache", detail: "Compiled packages go builds again"),
        .init(row: "gradle", category: .developer, paths: [".gradle"], name: "Gradle", detail: "Dependencies and build caches Gradle fetches again"),
        .init(row: "maven", category: .developer, paths: [".m2/repository"], name: "Maven repository", detail: "Dependencies Maven downloads again"),
        .init(row: "cocoapods", category: .developer, paths: ["Library/Caches/CocoaPods", ".cocoapods"], name: "CocoaPods",
              detail: "Pod sources and specs CocoaPods downloads again"),
        .init(row: "swiftpm", category: .developer, paths: ["Library/Caches/org.swift.swiftpm", "Library/org.swift.swiftpm"], name: "Swift packages",
              detail: "Package checkouts Swift downloads again"),
        .init(row: "playwright", category: .developer, paths: ["Library/Caches/ms-playwright", ".cache/puppeteer"], name: "Test browsers",
              detail: "Browsers Playwright and Puppeteer download again"),
        .init(row: "jetbrains", category: .developer, paths: ["Library/Caches/JetBrains"], name: "JetBrains caches",
              detail: "Indexes the IDE builds again"),
        .init(row: "ollama", category: .developer, paths: [".ollama/models"], name: "Ollama models",
              detail: "Models you pulled. ollama pull downloads them again"),
        .init(row: "huggingface", category: .developer, paths: [".cache/huggingface"], name: "Hugging Face",
              detail: "Models and datasets. They download again on next use"),
        .init(row: "lmstudio", category: .developer, paths: [".lmstudio/models", ".cache/lm-studio/models"], name: "LM Studio models",
              detail: "Models you downloaded in LM Studio"),
        .init(row: "nodeversions", category: .developer, paths: [".nvm", ".volta", ".local/share/fnm"], name: "Node versions",
              detail: "Node installs from nvm, Volta or fnm"),
        .init(row: "conda", category: .developer, paths: ["miniconda3", "anaconda3", "miniforge3", ".conda"], name: "Conda",
              detail: "Python environments and packages"),
        .init(row: "pyenv", category: .developer, paths: [".pyenv"], name: "pyenv", detail: "Python versions pyenv built"),
        .init(row: "homebrewcellar", category: .developer, paths: ["/opt/homebrew"], name: "Homebrew packages",
              detail: "Everything brew installed. brew uninstall removes a package"),
        .init(row: "usrlocal", category: .developer, paths: ["/usr/local"], name: "Tools in /usr/local", detail: "Command-line tools installed there"),
        .init(row: "librarydeveloper", category: .developer, paths: ["/Library/Developer"], name: "Command Line Tools and runtimes",
              detail: "Xcode's command-line tools and simulator runtimes. Remove runtimes in Xcode settings"),
    ]

    /// Folders inside projects that the next build or install makes again.
    struct Artifact {
        let name: String
        let row: String
        let title: String
        let detail: String
        /// A file next to (parent) or inside (self) the folder that shows it is what it looks like.
        let markers: [String]
        let markerInside: Bool
        /// How Clean Up labels it. Environments and general build folders can hold
        /// more than the next build makes again, so they are check first.
        var cleanSafety: CleanSafety = .safe
    }

    static let artifacts: [Artifact] = [
        .init(name: "node_modules", row: "node_modules", title: "node_modules",
              detail: "Packages for JavaScript projects. npm install brings them back", markers: [], markerInside: false),
        .init(name: "target", row: "target", title: "Rust target folders", detail: "Build output. cargo build makes it again",
              markers: ["Cargo.toml"], markerInside: false),
        .init(name: ".venv", row: "venv", title: "Python environments", detail: "Packages for one project. uv sync or pip install rebuilds it",
              markers: ["pyvenv.cfg"], markerInside: true, cleanSafety: .checkFirst),
        .init(name: "venv", row: "venv", title: "Python environments", detail: "Packages for one project. uv sync or pip install rebuilds it",
              markers: ["pyvenv.cfg"], markerInside: true, cleanSafety: .checkFirst),
        .init(name: "build", row: "build", title: "Build folders", detail: "Build output. The next build makes it again",
              markers: ["build.gradle", "build.gradle.kts", "CMakeLists.txt", "package.json", "setup.py", "pyproject.toml", "meson.build", "Makefile",
                        "pubspec.yaml"],
              markerInside: false, cleanSafety: .checkFirst),
        .init(name: ".build", row: "build", title: "Build folders", detail: "Build output. The next build makes it again",
              markers: ["Package.swift"], markerInside: false),
        .init(name: "Pods", row: "build", title: "Build folders", detail: "Pods CocoaPods installed. pod install brings them back",
              markers: ["Podfile"], markerInside: false, cleanSafety: .checkFirst),
        .init(name: ".next", row: "build", title: "Build folders", detail: "Next.js build output. The next build makes it again",
              markers: ["package.json"], markerInside: false),
        .init(name: ".turbo", row: "build", title: "Build folders", detail: "Turborepo's cache. The next build makes it again",
              markers: ["package.json", "turbo.json"], markerInside: false),
        .init(name: ".parcel-cache", row: "build", title: "Build folders", detail: "Parcel's cache. The next build makes it again",
              markers: ["package.json"], markerInside: false),
        .init(name: ".gradle", row: "build", title: "Build folders", detail: "Gradle's cache for one project. The next build makes it again",
              markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"], markerInside: false),
        // A "*" marker matches by extension; Storage only checks exact names, so it counts these as code.
        .init(name: "DerivedData", row: "build", title: "Build folders", detail: "Xcode build products and indexes. Xcode makes them again",
              markers: ["*.xcodeproj", "*.xcworkspace", "Package.swift"], markerInside: false),
    ]

    static let artifactNames = Set(artifacts.map(\.name))

    /// Everything that is not developer data, by home-relative path.
    static let places: [StorageLocation] = [
        .init(row: "apps", category: .apps, paths: ["Applications", "/Applications"], name: "Apps", detail: ""),
        .init(row: "mail", category: .mail, paths: ["Library/Mail", "Library/Containers/com.apple.mail", "Library/Group Containers/group.com.apple.mail"],
              name: "Mail", detail: "Messages and attachments Mail downloaded"),
        .init(row: "messages", category: .mail, paths: ["Library/Messages", "Library/Containers/com.apple.MobileSMS"], name: "Messages",
              detail: "Conversations and attachments"),
        .init(row: "desktop", category: .documents, paths: ["Desktop"], name: "Desktop", detail: ""),
        .init(row: "documents", category: .documents, paths: ["Documents"], name: "Documents", detail: ""),
        .init(row: "downloads", category: .documents, paths: ["Downloads"], name: "Downloads", detail: ""),
        .init(row: "pictures", category: .documents, paths: ["Pictures"], name: "Pictures", detail: ""),
        .init(row: "movies", category: .documents, paths: ["Movies"], name: "Movies", detail: ""),
        .init(row: "music", category: .documents, paths: ["Music"], name: "Music", detail: ""),
        .init(row: "icloud", category: .documents, paths: ["Library/Mobile Documents"], name: "iCloud Drive", detail: "Files kept on this Mac"),
        .init(row: "cloud", category: .documents, paths: ["Library/CloudStorage"], name: "Cloud storage",
              detail: "Dropbox, Google Drive, OneDrive and others, kept on this Mac"),
        .init(row: "backups", category: .system, paths: ["Library/Application Support/MobileSync/Backup"], name: "iPhone and iPad backups",
              detail: "Finder backups of your devices"),
        .init(row: "caches", category: .system, paths: ["Library/Caches", "/Library/Caches"], name: "Caches",
              detail: "Apps make these again as needed"),
        .init(row: "logs", category: .system, paths: ["Library/Logs", "/Library/Logs"], name: "Logs", detail: "Records apps and macOS keep for problems"),
        .init(row: "appdata", category: .system,
              paths: ["Library/Application Support", "Library/Containers", "Library/Group Containers"], name: "App data",
              detail: "Settings, databases and downloads apps keep"),
        .init(row: "trash", category: .system, paths: [".Trash"], name: "Trash", detail: "Files you deleted. Empty the Trash in Finder"),
        .init(row: "library", category: .system, paths: ["Library"], name: "Other Library folders", detail: "Fonts, keychains, mailboxes and settings"),
        .init(row: "systemlibrary", category: .system, paths: ["/Library"], name: "Shared library",
              detail: "Fonts, drivers and app support for every user"),
    ]

    /// This user's folder under /private/var/folders: temporary files and caches macOS keeps per user.
    static let temporary = StorageLocation(row: "temporary", category: .system, paths: [], name: "Temporary files",
                                           detail: "Per-user caches and temporary files. macOS clears them at restart or when space runs low")

    /// Folders in the home folder that usually hold code.
    static let codeFolders = ["src", "Developer", "Projects", "projects", "code", "Code", "dev", "repos", "git", "GitHub", "workspace", "Sites"]

    /// Rule for a node: the most specific location whose path is exactly this one.
    static let rules: [String: StorageLocation] = {
        var table: [String: StorageLocation] = [:]
        for location in places + developer { for path in location.paths where table[path] == nil { table[path] = location } }
        return table
    }()

    static func location(row: String) -> StorageLocation? {
        (developer + places + [temporary]).first { $0.row == row }
    }
}
