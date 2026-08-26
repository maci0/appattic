# Swift Scan Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python scanner with a Foundation `AppAtticScan` library, a Gtk-free `appattic` CLI, and an in-process UI scan, then delete the Python package.

**Architecture:** One library owns discover → usage → brew → outdated → leftovers → recommend. The CLI links only that library. The existing SwiftCrossUI app calls `runFullScan` on a background queue. Mac/Linux splits use `#if os`, never AppKit in the library.

**Tech Stack:** Swift 5.10, SwiftPM, Foundation, XCTest, SwiftCrossUI DefaultBackend (UI only).

**Spec:** `docs/superpowers/specs/2026-08-17-swift-scan-port-design.md`

## Global Constraints

- No `import AppKit` / `NSImage` / SF Symbols / materials / AppKit `List` in `AppAtticScan` or `AppAtticCLI`.
- Linux UI is Qt (`ui/linux-qt`); macOS UI APIs stay behind `#if os(macOS)`.
- Outdated is report-only. Never run upgrades.
- Missing `brew`/`mas`/`apt`/`flatpak`/`snap` yields `[]`, scan continues.
- No em dashes in user-visible copy.
- Do not commit unless the user asks.
- `swift test` and `swift build` need unrestricted permissions in this environment.
- Python stays until Task 11 wires the UI; deleted in Task 12.

## File map

- Create: `Sources/AppAtticScan/*.swift`
- Create: `Sources/AppAtticCLI/main.swift`
- Create: `Tests/AppAtticScanTests/*.swift`
- Modify: `Package.swift`, `Sources/AppAttic/Scanner.swift`, `Sources/AppAttic/Models.swift`, `run.sh`, `build.sh`, `README.md`
- Delete (Task 12): Python package modules, `tests/*.py`, `Resources/appattic`

---

### Task 1: Package + Util

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AppAtticScan/Util.swift`
- Create: `Tests/AppAtticScanTests/UtilTests.swift`

**Produces:** `public func norm(_:)`, `humanSize`, `humanDays`, `daysSince`, `parseMdlsDate`, `runCommand`, `fileSize`, `duSize`

- [ ] **Step 1:** Update `Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppAttic",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "AppAtticScan", targets: ["AppAtticScan"]),
        .executable(name: "appattic", targets: ["AppAtticCLI"]),
        .executable(name: "AppAttic", targets: ["AppAttic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(name: "AppAtticScan"),
        .executableTarget(name: "AppAtticCLI", dependencies: ["AppAtticScan"]),
        .executableTarget(
            name: "AppAttic",
            dependencies: [
                "AppAtticScan",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ]
        ),
        .testTarget(name: "AppAtticScanTests", dependencies: ["AppAtticScan"]),
    ]
)
```

Add stub `Sources/AppAtticCLI/main.swift` that prints `appattic 1.0.0` so the target links.

- [ ] **Step 2:** Write `UtilTests.swift` covering `norm("Google Chrome") == "googlechrome"`, `humanSize(0) == "0 B"`, `humanSize(1024) == "1.0 KB"`, `humanDays(0.5)` contains `h`, `parseMdlsDate("(null)") == nil`, `daysSince` nil in → nil out.

- [ ] **Step 3:** Implement `Util.swift` by translating `util.py` (`norm`, `human_size`, `human_days`, `run`, `file_size`, `du_size`, `parse_mdls_date`, `days_since`). `runCommand` never throws; return `(Int32, String, String)`.

- [ ] **Step 4:** `swift test --filter UtilTests` with unrestricted permissions. Expected: PASS.

---

### Task 2: Public scan models

**Files:**
- Create: `Sources/AppAtticScan/Models.swift`
- Modify: `Sources/AppAttic/Models.swift` (keep `formatDate` only; types come from the library)
- Modify: UI files that reference those types (they compile via `import AppAtticScan`)

**Produces:** public `ScanTotals`, `LeftoverItem`, `SoftwareItem`, `OutdatedEntry`, `ScanData` with the same Codable keys as today.

- [ ] **Step 1:** Test round-trip JSON for a leftover with `reason` and `summary`.
- [ ] **Step 2:** Move structs into the library as `public`. UI `import AppAtticScan`. Keep `humanSize` in the library (Task 1) and `formatDate` in the UI file.
- [ ] **Step 3:** `swift build -c debug` still builds `AppAttic`.

---

### Task 3: Discover (pure functions first)

**Files:**
- Create: `Sources/AppAtticScan/Discover.swift`
- Create: `Tests/AppAtticScanTests/DiscoverTests.swift`

**Produces:** `AppRecord`, `isRealAppPath`, `parseDesktopFile`, `plistDescription`, `categoryLabel`, `linuxDesktopDirs`

Port `tests/test_linux.py` desktop parse + hidden skip, and `is_real_app_path` fake markers (`/Library/Caches/Foo.app` is false). Port `plist_description` junk skip (version/copyright) from `discover.py`.

`findApps` can be a later step in this task: Mac walks `/Applications`; Linux walks desktop dirs. Wrapper `.app` inner Info.plist: port `_make_app` iOS wrapper tests from `test_linux.py`.

---

### Task 4: Leftovers classify

**Files:**
- Create: `Sources/AppAtticScan/Leftovers.swift`
- Create: `Tests/AppAtticScanTests/ClassifyTests.swift`

**Produces:** `DataItem`, `Identity`, `includeScanEntry`, `classifyLinuxSystemName`, `leftoverSummary`, `orphanReason`

Port `tests/test_classify.py` (generic `com.` prefix does not own unrelated bundle; vendor dir owned; python exec does not own interpreter cache). Port Linux system names from `test_linux.py`. `includeScanEntry` skips `.DS_Store` / `.localized`.

Do not implement the full disk walk until classify tests pass. Then add `scanLeftovers` over injected roots (temp dirs in tests).

---

### Task 5: Usage

**Files:**
- Create: `Sources/AppAtticScan/Usage.swift`
- Create: `Tests/AppAtticScanTests/UsageTests.swift`

**Produces:** `effectiveLastUsed`, `processBasenames`, `appMatchesRunning`, `parseRecentlyUsedXbel`

Port `tests/test_usage.py` and prefs fallback from `tests/test_prefs.py` (`applyPrefsFallback`). Spotlight `mdls` behind `runCommand` so tests do not need mdls.

---

### Task 6: BrewInfo

**Files:**
- Create: `Sources/AppAtticScan/BrewInfo.swift`
- Create: `Tests/AppAtticScanTests/BrewInfoTests.swift`

**Produces:** `Formula`, `Cask`, `BrewSnapshot`, `refusedCaskToken`, `fetchInfoJSON` using `--formula/--cask --installed`, `infoJSONForNames` dropping refused casks, join desc by path / artifact / title.

Tests: refused cask regex; parse canned `brew info --json=v2` with a formula `desc`; skip empty JSON on rc=1.

Live `brew` only in `collect(progress:)` which tests stub via injected runner.

---

### Task 7: Outdated parsers

**Files:**
- Create: `Sources/AppAtticScan/Outdated.swift`
- Create: `Tests/AppAtticScanTests/OutdatedTests.swift`

**Produces:** `OutdatedPkg`, `parseBrewOutdatedJSON`, `parseAptUpgradable`, `parseMasOutdated`, `parseFlatpakUpdates`, `versionNewer`, `outdatedReason` (no upgrades).

Port `tests/test_outdated.py`. `collectLinux` / `queryAppStore` call `runCommand`; missing binary → `[]`.

---

### Task 8: Recommend

**Files:**
- Create: `Sources/AppAtticScan/Recommend.swift`
- Create: `Tests/AppAtticScanTests/RecommendTests.swift`

**Produces:** `Software`, `Verdict`, `evaluate`, `evaluateAll`, `softwareDisplaySummary`, `buildSoftware`

Port `tests/test_recommend.py`. Thresholds: `ACTIVE_DAYS = 30`, `STALE_DAYS = 180`, `DATA_KEEP_THRESHOLD = 50 * 1024 * 1024`. System source → `system`. Running service → `keep`.

---

### Task 9: Scan orchestration + cleanup script

**Files:**
- Create: `Sources/AppAtticScan/Scan.swift`
- Create: `Sources/AppAtticScan/Cleanup.swift`
- Create: `Tests/AppAtticScanTests/ScanTests.swift`

**Produces:** `runFullScan(includeSystem:progress:) -> ScanData`, `cleanupScript(_ result: ScanData) -> String`

`ScanData.totals` computed like Python `to_dict`. Cleanup contains `rm -rf` for orphans, `brew uninstall` for remove-tier formulas, commented outdated lines, never `brew upgrade`.

Test with a temp tree: one orphan dir, no live brew required (inject empty brew).

---

### Task 10: CLI

**Files:**
- Modify: `Sources/AppAtticCLI/main.swift`
- Create: `Tests/AppAtticScanTests/CLIFlagTests.swift` only if parsing is extracted; otherwise manual `swift run appattic --version`

**Produces:** commands `report|leftovers|stale|outdated`, flags `--json --include-system --dry-run --top --category --leftovers-only --stale-only --version`. Default command `report`. No Gtk link.

---

### Task 11: Wire UI

**Files:**
- Modify: `Sources/AppAttic/Scanner.swift` (replace `executePythonScan` with `runFullScan`)
- Modify: `Sources/AppAttic/App.swift` if needed

Call `AppAtticScan.runFullScan` on `DispatchQueue.global`. Map progress strings onto `ScanProgress.message`. `swift build -c debug` then `./build.sh debug`. Mac UI scans without `python3`.

---

### Task 12: Delete Python, scripts, README

**Files:**
- Delete package `.py` modules listed in the spec (keep `generate_icon.py`)
- Delete `tests/*.py`
- Modify: `run.sh`, `build.sh`, `README.md`
- Stop copying `Resources/appattic`

Linux `build.sh`: build CLI always; Qt UI via `scripts/linux-qt-link.sh` only if `pkg-config Qt6Widgets`.

---

## Execution

User said go: implement inline in this session, no per-task commit.
