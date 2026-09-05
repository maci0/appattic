// swift-tools-version: 5.10
import PackageDescription

#if os(Linux)
// Linux UI is ui/linux-qt (C++ Qt 6), not SwiftCrossUI Gtk.
let uiProducts: [Product] = []
let uiTargets: [Target] = []
let uiDeps: [Package.Dependency] = []
#else
let uiProducts: [Product] = [
    // AppAtticUI, not AppAttic: APFS is case-insensitive, so AppAttic and appattic are the same file.
    .executable(name: "AppAtticUI", targets: ["AppAttic"]),
]
let uiTargets: [Target] = [
    .executableTarget(
        name: "AppAttic",
        dependencies: [
            "AppAtticScan",
            .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            .product(name: "DefaultBackend", package: "swift-cross-ui"),
        ]
    ),
]
let uiDeps: [Package.Dependency] = [
    .package(url: "https://github.com/moreSwift/swift-cross-ui", .exact("0.2.1")),
]
#endif

let package = Package(
    name: "AppAttic",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "AppAtticScan", targets: ["AppAtticScan"]),
        .executable(name: "appattic", targets: ["AppAtticCLI"]),
    ] + uiProducts,
    dependencies: uiDeps,
    targets: [
        .target(name: "AppAtticScan"),
        .target(name: "AppAtticCLIKit"),
        .executableTarget(name: "AppAtticCLI", dependencies: ["AppAtticScan", "AppAtticCLIKit"]),
        .testTarget(
            name: "AppAtticScanTests",
            dependencies: ["AppAtticScan", "AppAtticCLIKit"],
            path: "tests/AppAtticScanTests"
        ),
    ] + uiTargets
)
