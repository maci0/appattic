// swift-tools-version: 5.10
import Foundation
import PackageDescription

#if os(Linux)
// Linux UI is ui/linux-qt (C++ Qt 6), not SwiftCrossUI Gtk.
let uiProducts: [Product] = []
let uiTargets: [Target] = []
let uiDeps: [Package.Dependency] = []
#else
// `swift test` builds every target in the package, so CI that verifies only the
// scan library and CLI (the parts the pinned Swift 5.10.1 can build) drops the
// UI here. AppAtticUI needs swift-cross-ui 0.2.1, which needs a Swift 6
// compiler, and Swift 6.1's SIL lifetime pass crashes on swift-mutex 0.0.6
// (fixed only on swift main). Leave the variable unset to build the UI.
let macUI = ProcessInfo.processInfo.environment["APPATTIC_NO_MAC_UI"] != "1"
let uiProducts: [Product] = macUI ? [
    // AppAtticUI, not AppAttic: APFS is case-insensitive, so AppAttic and appattic are the same file.
    .executable(name: "AppAtticUI", targets: ["AppAttic"]),
] : []
let uiTargets: [Target] = macUI ? [
    .executableTarget(
        name: "AppAttic",
        dependencies: [
            "AppAtticScan",
            .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            .product(name: "DefaultBackend", package: "swift-cross-ui"),
        ]
    ),
] : []
let uiDeps: [Package.Dependency] = macUI ? [
    .package(url: "https://github.com/moreSwift/swift-cross-ui", .exact("0.2.1")),
] : []
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
        .target(
            name: "AppAtticScan",
            resources: [.copy("linux-system-names.txt")]
        ),
        .executableTarget(name: "AppAtticCLI", dependencies: ["AppAtticScan"]),
        .executableTarget(
            name: "appattic-bench",
            dependencies: ["AppAtticScan"],
            path: "benchmarks/AppAtticBench"
        ),
        .testTarget(
            name: "AppAtticScanTests",
            dependencies: ["AppAtticScan"],
            path: "tests/AppAtticScanTests"
        ),
    ] + uiTargets
)
