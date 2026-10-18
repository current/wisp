// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WispCore", targets: ["WispCore"]),
        .executable(name: "WispApp", targets: ["WispApp"]),
        .executable(name: "wisp", targets: ["WispCLI"]),
    ],
    targets: [
        // The collectors wrap Mach, libproc and IOKit calls that are confined to one
        // serial queue by construction, so they stay in Swift 5 mode rather than
        // pretending those C handles are Sendable.
        .target(
            name: "WispCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "WispApp",
            dependencies: ["WispCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WispCLI",
            dependencies: ["WispCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WispCoreTests",
            dependencies: ["WispCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
