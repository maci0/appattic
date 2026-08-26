import Foundation
import SwiftCrossUI
import AppAtticScan

@ObservableObject
final class ScannerViewModel {
    var scanData: ScanData?
    var isScanning = false
    var errorMessage: String?
    var selectedLeftovers: Set<String> = []
    var selectedApps: Set<String> = []
    var selectedOutdated: Set<String> = []
    var selectedPackages: Set<String> = []
    var selectedMarkManual: Set<String> = []
    var searchText = ""
    var statusText = ""
    var ignoredLeftovers: Set<String> = []
    var progressMessage = "Starting scan…"

    var includeSystem = false
    var selectableAppTiers: Set<String> { selectableCleanupTiers }

    @ObservationIgnored private var rowCacheKey = ""
    @ObservationIgnored private var cachedLeftovers: [LeftoverItem] = []
    @ObservationIgnored private var cachedStale: [SoftwareItem] = []
    @ObservationIgnored private var cachedOutdated: [OutdatedEntry] = []
    @ObservationIgnored private var cachedPackages: [PackageEntry] = []

    var leftoverRows: [LeftoverItem] {
        refreshRowCacheIfNeeded()
        return cachedLeftovers
    }

    var staleRows: [SoftwareItem] {
        refreshRowCacheIfNeeded()
        return cachedStale
    }

    var outdatedRows: [OutdatedEntry] {
        refreshRowCacheIfNeeded()
        return cachedOutdated
    }

    var allPackages: [PackageEntry] {
        scanData?.packages ?? []
    }

    func packageRows(filter: PackageListFilter) -> [PackageEntry] {
        refreshRowCacheIfNeeded()
        return filterPackages(cachedPackages, filter: filter, search: searchText)
    }

    var overviewLeftovers: [LeftoverItem] {
        visibleOrphanedLeftovers(scanData?.leftovers ?? [], ignoring: ignoredLeftovers)
            .sorted { ($0.size_bytes ?? 0) > ($1.size_bytes ?? 0) }
    }

    var overviewStale: [SoftwareItem] {
        visibleStaleSoftware(scanData?.software ?? [], includeSystem: includeSystem)
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    var listedStaleCount: Int {
        visibleStaleSoftware(scanData?.software ?? [], includeSystem: includeSystem).count
    }

    var hasActionableCleanup: Bool {
        scriptHasActionableCommands(generateCleanupScript())
    }

    var overviewOutdated: [OutdatedEntry] {
        scanData?.outdated ?? []
    }

    func invalidateRowCache() {
        rowCacheKey = ""
    }

    private func refreshRowCacheIfNeeded() {
        let ignoredKey = ignoredLeftovers.sorted().joined(separator: ",")
        let key = "\(scanData?.scanned_at ?? "")\u{1e}\(searchText)\u{1e}\(ignoredKey)\u{1e}\(includeSystem)"
        guard key != rowCacheKey else { return }
        rowCacheKey = key
        guard let data = scanData else {
            cachedLeftovers = []
            cachedStale = []
            cachedOutdated = []
            cachedPackages = []
            return
        }
        let q = searchText.lowercased()
        cachedLeftovers = visibleOrphanedLeftovers(data.leftovers, ignoring: ignoredLeftovers).filter { item in
            if q.isEmpty { return true }
            return leftoverDisplayName(name: item.name, extraPaths: item.extra_paths ?? []).lowercased().contains(q)
                || item.name.lowercased().contains(q)
                || item.path.lowercased().contains(q)
                || item.root.lowercased().contains(q)
                || item.status.lowercased().contains(q)
                || (item.owner ?? "").lowercased().contains(q)
                || (item.reason ?? "").lowercased().contains(q)
                || (item.summary ?? "").lowercased().contains(q)
                || (item.shadows ?? "").lowercased().contains(q)
                || (item.extra_paths ?? []).contains { $0.lowercased().contains(q) }
        }.sorted { ($0.size_bytes ?? 0) > ($1.size_bytes ?? 0) }
        cachedStale = visibleStaleSoftware(data.software, includeSystem: includeSystem).filter { item in
            if q.isEmpty { return true }
            return item.name.lowercased().contains(q)
                || item.path.lowercased().contains(q)
                || item.source.lowercased().contains(q)
                || (item.tier ?? "").lowercased().contains(q)
                || (item.reason ?? "").lowercased().contains(q)
                || (item.summary ?? "").lowercased().contains(q)
                || (item.outdated == true && "outdated".hasPrefix(q))
        }.sorted { $0.totalBytes > $1.totalBytes }
        let outdated = data.outdated ?? []
        if q.isEmpty {
            cachedOutdated = outdated
        } else {
            cachedOutdated = outdated.filter {
                $0.name.lowercased().contains(q)
                    || $0.manager.lowercased().contains(q)
                    || ($0.title ?? "").lowercased().contains(q)
                    || ($0.summary ?? "").lowercased().contains(q)
                    || ($0.reason ?? "").lowercased().contains(q)
            }
        }
        cachedPackages = data.packages ?? []
    }

    var selectionCount: Int {
        selectedLeftovers.count + selectedApps.count + selectedOutdated.count
            + selectedPackages.count + selectedMarkManual.count
    }

    var cleanupSelectionCount: Int { selectedLeftovers.count + selectedApps.count + selectedPackages.count }

    var selectionReclaimableBytes: Int {
        var total = 0
        guard let data = scanData else { return 0 }
        for item in data.leftovers where selectedLeftovers.contains(item.path) {
            total += item.size_bytes ?? 0
        }
        for item in data.software where selectedApps.contains(item.path) {
            total += item.totalBytes
        }
        for item in data.packages ?? [] where selectedPackages.contains(item.id) {
            total += item.size_bytes ?? 0
        }
        return total
    }

    func start(includeSystem: Bool) {
        self.includeSystem = includeSystem
        invalidateRowCache()
        if let cache = loadScanCache() {
            if cache.includeSystem != includeSystem {
                scan(includeSystem: includeSystem)
                return
            }
            var data = cache.data
            data.from_cache = true
            scanData = data
            statusText = "cached · scanned \(formatDate(data.scanned_at))"
            refreshIfStale(includeSystem: includeSystem, cache: cache)
            return
        }
        scan(includeSystem: includeSystem)
    }

    func scan(includeSystem: Bool) {
        self.includeSystem = includeSystem
        invalidateRowCache()
        guard !isScanning else { return }
        runScan(includeSystem: includeSystem)
    }

    private func refreshIfStale(includeSystem: Bool, cache: ScanCacheFile) {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        progressMessage = "Checking last scan…"
        let vm = self
        DispatchQueue.global(qos: .utility).async {
            let fingerprint = scanFingerprint()
            let stale = isScanCacheStale(cache, includeSystem: includeSystem, fingerprint: fingerprint)
            DispatchQueue.main.async {
                if stale {
                    vm.runScan(includeSystem: includeSystem)
                } else {
                    vm.isScanning = false
                }
            }
        }
    }

    private func runScan(includeSystem: Bool) {
        isScanning = true
        errorMessage = nil
        progressMessage = scanData == nil ? "Starting scan…" : "Refreshing scan…"
        let vm = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runFullScan(includeSystem: includeSystem) { msg in
                DispatchQueue.main.async {
                    vm.progressMessage = msg
                }
            }
            DispatchQueue.main.async {
                vm.progressMessage = "Saving scan cache…"
            }
            let fingerprint = scanFingerprint()
            saveScanCache(ScanCacheFile(fingerprint: fingerprint, includeSystem: includeSystem, data: result))
            DispatchQueue.main.async {
                vm.scanData = result
                vm.pruneSelection()
                vm.isScanning = false
                vm.statusText = "scanned \(formatDate(result.scanned_at)) · \(String(format: "%.1f", result.duration_s))s"
            }
        }
    }

    func generateCleanupScript() -> String {
        guard let data = scanData else { return "" }
        var lines = [
            "#!/bin/sh",
            "set -e",
            "# AppAttic cleanup",
            "# Review every line before running. Nothing here is deleted automatically.",
            "",
        ]
        let leftItems = visibleOrphanedLeftovers(data.leftovers, ignoring: ignoredLeftovers)
            .filter { selectedLeftovers.contains($0.path) }
        let appItems = data.software.filter { selectedApps.contains($0.path) && selectableAppTiers.contains($0.tier ?? "") }
        if !leftItems.isEmpty {
            lines.append("# Leftover data and PATH overlays")
            for item in leftItems {
                lines.append(leftoverRemoveCommand(for: item))
            }
        }
        let formulas = appItems.filter { $0.source == "brew-formula" }
        let casks = appItems.filter { $0.source == "brew-cask" }
        let rest = appItems.filter { $0.source != "brew-formula" && $0.source != "brew-cask" }
        if !formulas.isEmpty {
            lines.append("")
            lines.append("# Brew formulas")
            lines.append("brew uninstall " + formulas.map { shellQuote($0.name) }.joined(separator: " "))
        }
        if !casks.isEmpty {
            lines.append("")
            lines.append("# Brew casks")
            lines.append("brew uninstall --cask " + casks.map { shellQuote($0.cask_name ?? $0.name) }.joined(separator: " "))
        }
        for app in rest {
            lines.append("")
            lines.append("# \(app.name)")
            lines.append(uninstallCommand(for: app))
        }
        let pkgItems = allPackages.filter { selectedPackages.contains($0.id) }
        if !pkgItems.isEmpty {
            lines.append("")
            lines.append("# Distro orphans and language globals")
            for item in pkgItems {
                lines.append(packageRemoveCommand(item))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func generateScript() -> String {
        previewScript(cleanup: generateCleanupScript(), update: generateUpdateScript())
            + markManualPreview()
    }

    func generateMarkManualScript() -> String {
        let items = allPackages.filter { selectedMarkManual.contains($0.id) }
        return packageActionScript(remove: [], markManual: items)
    }

    private func markManualPreview() -> String {
        let script = generateMarkManualScript()
        guard scriptHasActionableCommands(script) else { return "" }
        let extra = stripShellHeader(script)
        if extra.isEmpty { return "" }
        return "\n# Mark as manually installed. Delete in the UI does not run these lines.\n" + extra + "\n"
    }

    func generateUpdateScript() -> String {
        guard let data = scanData else { return "" }
        return updateScript(from: data, selectedIds: selectedOutdated)
    }

    func clearSelection() {
        selectedLeftovers = []
        selectedApps = []
        selectedOutdated = []
        selectedPackages = []
        selectedMarkManual = []
    }

    func pruneSelection() {
        guard let data = scanData else {
            clearSelection()
            return
        }
        let pruned = pruneCleanupSelection(
            leftovers: selectedLeftovers,
            apps: selectedApps,
            outdated: selectedOutdated,
            packages: selectedPackages,
            markManual: selectedMarkManual,
            data: data,
            ignoring: ignoredLeftovers
        )
        selectedLeftovers = pruned.leftovers
        selectedApps = pruned.apps
        selectedOutdated = pruned.outdated
        selectedPackages = pruned.packages
        selectedMarkManual = pruned.markManual
        invalidateRowCache()
    }

    func ignoreLeftover(_ item: LeftoverItem) {
        var ignored = ignoredLeftovers
        for path in leftoverIgnorePaths(item) where !path.isEmpty {
            ignored.insert(path)
        }
        ignoredLeftovers = ignored
        var selected = selectedLeftovers
        selected.remove(item.path)
        selectedLeftovers = selected
        invalidateRowCache()
    }

    func clearIgnoredLeftovers() {
        ignoredLeftovers = []
        invalidateRowCache()
    }

    func setLeftoverSelected(_ path: String, _ on: Bool) {
        var next = selectedLeftovers
        if on {
            next.insert(path)
        } else {
            next.remove(path)
        }
        selectedLeftovers = next
    }

    func setAppSelected(_ path: String, _ on: Bool) {
        var next = selectedApps
        if on {
            guard let item = scanData?.software.first(where: { $0.path == path }),
                  selectableAppTiers.contains(item.tier ?? "") else { return }
            next.insert(path)
        } else {
            next.remove(path)
        }
        selectedApps = next
    }

    func setOutdatedSelected(_ id: String, _ on: Bool) {
        var next = selectedOutdated
        if on {
            next.insert(id)
        } else {
            next.remove(id)
        }
        selectedOutdated = next
    }

    func setPackageSelected(_ id: String, _ on: Bool) {
        var next = selectedPackages
        var keep = selectedMarkManual
        if on {
            next.insert(id)
            keep.remove(id)
        } else {
            next.remove(id)
        }
        selectedPackages = next
        selectedMarkManual = keep
    }

    func setMarkManualSelected(_ id: String, _ on: Bool) {
        var next = selectedMarkManual
        var remove = selectedPackages
        if on {
            guard allPackages.contains(where: { $0.id == id && $0.canMarkManual }) else { return }
            next.insert(id)
            remove.remove(id)
        } else {
            next.remove(id)
        }
        selectedMarkManual = next
        selectedPackages = remove
    }

    func executeCleanup(then completion: @escaping (Bool) -> Void) {
        let script = generateCleanupScript()
        guard scriptHasActionableCommands(script) else {
            errorMessage = "Nothing to delete. Uninstall Steam and CrossOver items in those apps."
            completion(false)
            return
        }
        runTempScript(script, message: "Removing selected items…", clear: .cleanup, then: completion)
    }

    func executeUpdate(then completion: @escaping (Bool) -> Void) {
        let script = generateUpdateScript()
        guard scriptHasActionableCommands(script) else {
            errorMessage = "Nothing to update. \(outdatedSkippedManagersNote)"
            completion(false)
            return
        }
        runTempScript(script, message: "Updating selected packages…", clear: .update, then: completion)
    }

    func executeMarkManual(then completion: @escaping (Bool) -> Void) {
        let script = generateMarkManualScript()
        guard scriptHasActionableCommands(script) else {
            errorMessage = "Nothing to mark as manually installed."
            completion(false)
            return
        }
        runTempScript(script, message: "Marking packages as manually installed…", clear: .markManual, then: completion)
    }

    private enum ScriptClear {
        case cleanup
        case update
        case markManual
    }

    private func runTempScript(
        _ script: String,
        message: String,
        clear: ScriptClear,
        then completion: @escaping (Bool) -> Void
    ) {
        isScanning = true
        errorMessage = nil
        progressMessage = message
        let vm = self
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("appattic-run-\(UUID().uuidString).sh")
                let errURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("appattic-run-\(UUID().uuidString).err")
                try script.write(to: url, atomically: true, encoding: .utf8)
                FileManager.default.createFile(atPath: errURL.path, contents: nil)
                defer {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: errURL)
                }
                let errHandle = try FileHandle(forWritingTo: errURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [url.path]
                process.environment = Self.augmentedEnvironment()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errHandle
                process.standardInput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try errHandle.synchronize()
                try errHandle.close()
                let status = process.terminationStatus
                let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                DispatchQueue.main.async {
                    vm.isScanning = false
                    if status != 0 {
                        vm.errorMessage = commandFailureMessage(status: status, stderr: errText)
                        completion(false)
                        return
                    }
                    switch clear {
                    case .cleanup:
                        vm.selectedLeftovers = []
                        vm.selectedApps = remainingPendingAppPaths(
                            selected: vm.selectedApps,
                            software: vm.scanData?.software ?? []
                        )
                        vm.selectedPackages = []
                        if !vm.selectedApps.isEmpty {
                            vm.statusText = "Steam or CrossOver still needs to finish uninstall. Those items stay selected."
                        }
                    case .update:
                        vm.selectedOutdated = []
                    case .markManual:
                        vm.selectedMarkManual = []
                    }
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    vm.isScanning = false
                    vm.errorMessage = error.localizedDescription
                    completion(false)
                }
            }
        }
    }

    nonisolated private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = cleanupPathDirectories()
        var seen = Set<String>()
        var parts: [String] = []
        for dir in extras + (env["PATH"] ?? "").split(separator: ":").map(String.init) {
            if !dir.isEmpty, seen.insert(dir).inserted {
                parts.append(dir)
            }
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }
}
