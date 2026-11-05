import Foundation

/// The headings of the Large Files tab. The raw value is the `CleanItem.group` of a large
/// file row, so `LargeFileCategory(rawValue: item.group)` gives it back.
public enum LargeFileCategory: String, Codable, CaseIterable, Sendable {
    case videos = "Videos"
    case audio = "Audio"
    case images = "Images"
    case pdfs = "PDFs"
    case archives = "Archives"
    case documents = "Documents"
    case aiModels = "AI models"
    case virtualMachines = "Virtual machines"
    case restoreImages = "Restore images"
    case unfinishedDownloads = "Unfinished downloads"
    case other = "Other"
}

/// The `CleanItem.group` of duplicate rows. Their category is in `LargeFileInfo`.
public let duplicatesGroup = "Duplicates"

/// What the Large Files tab filters on, beyond what `CleanItem` carries. Keyed by item id
/// in `LargeFileIndex`.
public struct LargeFileInfo: Codable, Sendable, Hashable {
    public var category: LargeFileCategory
    /// When the file was last opened, from Spotlight or the access time. Nil when unknown.
    public var lastUsed: Date?
    public var modified: Date?
    /// In iCloud Drive (its own folder, or Desktop and Documents when they sync). Removing it removes it everywhere.
    public var isICloud: Bool
    /// Rows with the same id hold identical files.
    public var duplicateGroup: String?
    /// The copy Wisp suggests keeping. It arrives unticked.
    public var isSuggestedKeeper: Bool

    public init(category: LargeFileCategory, lastUsed: Date? = nil, modified: Date? = nil, isICloud: Bool = false,
                duplicateGroup: String? = nil, isSuggestedKeeper: Bool = false) {
        self.category = category
        self.lastUsed = lastUsed
        self.modified = modified
        self.isICloud = isICloud
        self.duplicateGroup = duplicateGroup
        self.isSuggestedKeeper = isSuggestedKeeper
    }
}

/// Identical files: every path holds the same bytes, confirmed with a full SHA-256.
public struct DuplicateGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Size of one copy.
    public var length: Int64
    /// Every copy, the suggested keeper first.
    public var paths: [String]
    public var keeper: String { paths[0] }
    /// What removing every copy but one frees.
    public var reclaimable: Int64
}

public struct DuplicateSummary: Codable, Sendable, Hashable {
    public var groups: [DuplicateGroup] = []
    public var hashedBytes: Int64 = 0
    /// Hashing stopped at the byte limit; larger sets of same-size files were not compared.
    public var stoppedAtLimit = false
    /// Duplicate hashing was turned off for this scan.
    public var skipped = false
    public var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    /// The sentence the tab shows under the duplicates, or nil when there is nothing to say.
    public var note: String? {
        if skipped { return "Duplicates were not checked in this scan." }
        if stoppedAtLimit { return "Stopped comparing files after \(Format.bytes(UInt64(hashedBytes))). Some duplicates may be missing." }
        return nil
    }

    public init() {}
}

/// Everything one Large Files scan found.
public struct LargeFilesReport: Sendable {
    public var items: [CleanItem] = []
    public var info: [String: LargeFileInfo] = [:]
    public var duplicates = DuplicateSummary()
    public var seconds: Double = 0
}

/// The last Large Files scan's extra fields, for the page. The scanner writes it as it
/// streams items; the page reads it by item id.
public final class LargeFileIndex: @unchecked Sendable {
    public static let shared = LargeFileIndex()

    private let lock = NSLock()
    private var infoByID: [String: LargeFileInfo] = [:]
    private var summary = DuplicateSummary()

    public init() {}

    public func info(for id: String) -> LargeFileInfo? { lock.withLock { infoByID[id] } }
    public var duplicates: DuplicateSummary { lock.withLock { summary } }

    func reset() { lock.withLock { infoByID = [:]; summary = DuplicateSummary() } }
    func add(_ info: [String: LargeFileInfo]) { lock.withLock { infoByID.merge(info) { $1 } } }
    func setDuplicates(_ duplicates: DuplicateSummary) { lock.withLock { summary = duplicates } }

    /// False when `selected` (item ids) would remove every copy in some duplicate group,
    /// counting large-file rows for the same paths too.
    public func keepsACopy(_ selected: Set<String>) -> Bool {
        let summary = duplicates
        let paths = Set(selected.compactMap(LargeFilesScanner.path(fromID:)))
        return summary.groups.allSatisfy { group in group.paths.contains { !paths.contains($0) } }
    }
}

/// File extensions and folder names the scanner recognises.
enum LargeFileKinds {
    static let vmBundles: [String: String] = [
        "pvm": "Parallels virtual machine", "utm": "UTM virtual machine", "vmwarevm": "VMware Fusion virtual machine",
    ]

    /// Libraries an app manages. Removing a file inside one breaks the library, so they are not entered.
    static let managedLibraries: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "fcpproject", "lrlibrary", "lrdata", "lrcat-data", "cocatalog", "photoboothlibrary",
    ]
    static let managedFiles: Set<String> = ["lrcat", "lrcat-wal", "lrcat-shm", "lrcat-lock", "itl", "musicdb"]
    /// Folders an app manages, by their path below the home folder.
    static let managedFolders: Set<String> = [
        "Music/iTunes", "Music/Music", "Music/Media.localized", "Movies/TV", "Pictures/Photo Booth Library",
    ]

    static let dependencyFolders: Set<String> = [
        "node_modules", "Pods", "DerivedData", ".build", "target", ".venv", "venv", ".git", "__pycache__", ".gradle",
        // What xcodebuild -derivedDataPath leaves in a project's build folder.
        "SourcePackages", "SDKExplicitPrecompiledModules", "ModuleCache.noindex", "Intermediates.noindex", "XCBuildData",
    ]

    /// Folder packages listed as one row, with their category and what they are.
    static let packageRows: [String: (LargeFileCategory, String)] = [
        "sparsebundle": (.archives, "Disk image"), "sparseimage": (.archives, "Disk image"),
        "mlpackage": (.aiModels, "Core ML model"), "app": (.other, "App"), "xcarchive": (.other, "Xcode archive"),
        "logicx": (.audio, "Logic Pro project"), "band": (.audio, "GarageBand project"),
        "key": (.documents, "Keynote presentation"), "pages": (.documents, "Pages document"),
        "numbers": (.documents, "Numbers spreadsheet"), "rtfd": (.documents, "Rich text document"),
        "pvm": (.virtualMachines, "Parallels virtual machine"), "utm": (.virtualMachines, "UTM virtual machine"),
        "vmwarevm": (.virtualMachines, "VMware Fusion virtual machine"),
    ]

    static let files: [String: (LargeFileCategory, String?)] = {
        var map: [String: (LargeFileCategory, String?)] = [:]
        func add(_ category: LargeFileCategory, _ kinds: [String: String?]) {
            for (ext, what) in kinds { map[ext] = (category, what) }
        }
        add(.videos, ["mov": "QuickTime movie", "mp4": "Video", "m4v": "Video", "mkv": "Matroska video", "avi": "AVI video",
                      "wmv": "Windows Media video", "flv": "Flash video", "webm": "WebM video", "mpg": "MPEG video",
                      "mpeg": "MPEG video", "mts": "Camcorder video", "m2ts": "Camcorder video", "3gp": "Video",
                      "hevc": "Video", "braw": "Blackmagic RAW video", "r3d": "RED video", "insv": "360 video",
                      "lrv": "Low resolution video copy", "screenflow": "ScreenFlow recording"])
        add(.audio, ["mp3": "MP3 audio", "m4a": "Audio", "aac": "Audio", "wav": "WAV audio", "aif": "AIFF audio",
                     "aiff": "AIFF audio", "flac": "FLAC audio", "alac": "Audio", "ogg": "Ogg audio", "opus": "Opus audio",
                     "caf": "Core Audio file", "m4b": "Audiobook", "m4p": "Audio", "wma": "Windows Media audio",
                     "m4r": "Ringtone"])
        add(.images, ["jpg": "Photo", "jpeg": "Photo", "png": "Image", "heic": "Photo", "heif": "Photo", "tif": "TIFF image",
                      "tiff": "TIFF image", "gif": "GIF", "bmp": "Image", "webp": "Image", "avif": "Image", "exr": "EXR image",
                      "dng": "RAW photo", "cr2": "RAW photo", "cr3": "RAW photo", "nef": "RAW photo", "arw": "RAW photo",
                      "orf": "RAW photo", "rw2": "RAW photo", "raf": "RAW photo", "raw": "RAW photo",
                      "psd": "Photoshop document", "psb": "Photoshop document", "afphoto": "Affinity Photo document",
                      "pxd": "Pixelmator document", "pxm": "Pixelmator document", "svg": "Image"])
        add(.pdfs, ["pdf": "PDF"])
        add(.archives, ["zip": "ZIP archive", "rar": "RAR archive", "7z": "7-Zip archive", "tar": "Tar archive",
                        "gz": "Compressed archive", "tgz": "Compressed archive", "bz2": "Compressed archive",
                        "xz": "Compressed archive", "zst": "Compressed archive", "lz4": "Compressed archive",
                        "xip": "Xcode archive download", "cpgz": "Compressed archive", "dmg": "Disk image",
                        "iso": "Disk image", "img": "Disk image", "sparseimage": "Disk image", "pkg": "Installer package",
                        "mpkg": "Installer package", "apk": "Android app", "aab": "Android app bundle", "ipa": "iPhone app"])
        add(.documents, ["doc": "Word document", "docx": "Word document", "xls": "Excel spreadsheet", "xlsx": "Excel spreadsheet",
                         "ppt": "PowerPoint presentation", "pptx": "PowerPoint presentation", "key": "Keynote presentation",
                         "pages": "Pages document", "numbers": "Numbers spreadsheet", "txt": "Text file", "rtf": "Rich text document",
                         "csv": "CSV file", "tsv": "Table", "json": "JSON file", "epub": "Book", "md": "Text file",
                         "odt": "Document", "ods": "Spreadsheet", "odp": "Presentation", "sqlite": "Database",
                         "db": "Database", "parquet": "Data file", "log": "Log file", "sketch": "Sketch file", "fig": "Figma file",
                         "ai": "Illustrator file", "indd": "InDesign document"])
        add(.aiModels, ["gguf": "GGUF model weights", "safetensors": "Model weights", "ckpt": "Model checkpoint",
                        "pt": "PyTorch model", "pth": "PyTorch model", "onnx": "ONNX model", "mlmodel": "Core ML model",
                        "tflite": "TensorFlow Lite model"])
        add(.virtualMachines, ["vmdk": "Virtual disk", "vdi": "VirtualBox disk", "qcow2": "Virtual disk", "vhd": "Virtual disk",
                               "vhdx": "Virtual disk", "hdd": "Virtual disk", "ova": "Virtual machine export",
                               "ovf": "Virtual machine export"])
        add(.restoreImages, ["ipsw": "Restore image"])
        add(.unfinishedDownloads, ["crdownload": "Unfinished Chrome download", "part": "Unfinished download",
                                   "download": "Unfinished Safari download", "partial": "Unfinished download",
                                   "opdownload": "Unfinished Opera download"])
        return map
    }()

    /// Weight files the model search looks for outside known stores.
    static let weightExtensions: Set<String> = ["gguf", "safetensors", "bin", "pt", "pth", "ckpt", "mlmodel", "mlpackage"]
}
