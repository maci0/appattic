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
//
// The spellings that mean on are the ones `configBoolSwitch` in
// Sources/AppAtticScan/Settings.swift accepts, and the ones
// `core/host/hostexec.c` applies to the two host-exec switches: `1`, `true`,
// `yes`, `on`, case-insensitive, surrounding blanks ignored, and nothing else.
// The blanks are U+0020 and U+0009 and no others, because that is the pair
// `env_flag` skips; `.whitespaces` and `.whitespacesAndNewlines` also strip
// newlines and Unicode spaces, so a value carrying one would be on here and off
// in the host. `scripts/lint.sh` compares both the spellings and the trim set
// across all three trees so neither can drift. A manifest cannot import the
// scan library, so the rule is restated here.
private func envSwitchIsOn(_ name: String) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[name] else { return false }
    let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased()
    return value == "1" || value == "true" || value == "yes" || value == "on"
}

let macUI = !envSwitchIsOn("APPATTIC_NO_MAC_UI")
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
