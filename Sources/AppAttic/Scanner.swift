import Foundation
import SwiftCrossUI
import AppAtticScan

@ObservableObject
final class ScannerViewModel {
    var scanData: ScanData?
    var isScanning = false
    var errorMessage: String?
    /// Settings load/save failures stay visible across scans until dismissed or saved.
    var holdsSettingsError = false
    var selectedLeftovers: Set<String> = []
    var selectedApps: Set<String> = []
    var selectedOutdated: Set<String> = []
    var selectedPackages: Set<String> = []
    var selectedMarkManual: Set<String> = []
    var searchText = ""
    var statusText = ""
    /// What a finished script run did, carried into the status line of the
    /// rescan that follows it. The rescan writes `statusText` itself, so a
    /// message set before it would be replaced before it was ever read.
    var pendingNote = ""
    var ignoredLeftovers: Set<String> = []
    var progressMessage = "Starting scan…"

    var includeSystem = false

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
            .sorted { a, b in
                let (ls, rs) = (a.size_bytes ?? 0, b.size_bytes ?? 0)
                // Collated tie-break, not byte order: two leftovers of the same
                // size whose paths differ only in a non-ASCII name ("Über",
                // "日本語") otherwise land in code-point order, which reads as
                // unordered. Same order the CLI prints and the Qt window lists.
                return ls == rs ? collatedBefore(a.path, b.path, tieBreak: a.path, b.path) : ls > rs
            }
    }

    var overviewStale: [SoftwareItem] {
        visibleStaleSoftware(scanData?.software ?? [], includeSystem: includeSystem)
            .sorted { a, b in
                a.totalBytes == b.totalBytes
                    ? collatedBefore(a.path, b.path, tieBreak: a.path, b.path)
                    : a.totalBytes > b.totalBytes
            }
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
        let ignoredKey = ignoredLeftovers.sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{1f}")
        let counts = scanData.map {
            "\($0.leftovers.count)\u{1f}\($0.software.count)\u{1f}\($0.totals.orphaned_items)\u{1f}\($0.totals.outdated_apps)"
        } ?? "0"
        let key = "\(scanData?.scanned_at ?? "")\u{1e}\(searchText)\u{1e}\(ignoredKey)\u{1e}\(includeSystem)\u{1e}\(counts)"
        guard key != rowCacheKey else { return }
        rowCacheKey = key
        guard let data = scanData else {
            cachedLeftovers = []
            cachedStale = []
            cachedOutdated = []
            cachedPackages = []
            return
        }
        let q = searchQuery(searchText)
        cachedLeftovers = visibleOrphanedLeftovers(data.leftovers, ignoring: ignoredLeftovers).filter {
            leftoverMatchesSearch($0, q)
        }.sorted { a, b in
            let (ls, rs) = (a.size_bytes ?? 0, b.size_bytes ?? 0)
            return ls == rs ? collatedBefore(a.path, b.path, tieBreak: a.path, b.path) : ls > rs
        }
        cachedStale = visibleStaleSoftware(data.software, includeSystem: includeSystem).filter {
            softwareMatchesSearch($0, q)
        }.sorted { a, b in
            a.totalBytes == b.totalBytes
                ? collatedBefore(a.path, b.path, tieBreak: a.path, b.path)
                : a.totalBytes > b.totalBytes
        }
        cachedOutdated = (data.outdated ?? []).filter { outdatedMatchesSearch($0, q) }
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
            total = addBytes(total, item.size_bytes ?? 0)
        }
        for item in data.software where selectedApps.contains(item.path) {
            total = addBytes(total, item.totalBytes)
        }
        for item in data.packages ?? [] where selectedPackages.contains(item.id) {
            total = addBytes(total, item.size_bytes ?? 0)
        }
        return total
    }

    func start(includeSystem: Bool) {
        self.includeSystem = includeSystem
        invalidateRowCache()
        if let cache = loadScanCache() {
            // The instant view is only worth showing while the snapshot is
            // inside the documented tolerance. Age is checked here because the
            // inventory stamp that `refreshIfStale` computes is too slow to
            // gate a launch on; the fingerprint check still runs behind it.
            // Past the retention bound the snapshot is deleted rather than
            // left holding the account's paths for a rescan that overwrites it.
            let expired = isScanCacheExpired(cache)
            if expired { clearScanCache() }
            if cache.includeSystem != includeSystem
                || cache.data.incomplete == true
                || expired {
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
        // Guard first. A suppressed scan owns no data, so it must not leave the
        // model describing a view the running scan will not produce: with the
        // assignment after the guard, the rows on screen came from a scan with
        // the old includeSystem while the model claimed the new one.
        guard !isScanning else { return }
        self.includeSystem = includeSystem
        invalidateRowCache()
        runScan(includeSystem: includeSystem)
    }

    private func refreshIfStale(includeSystem: Bool, cache: ScanCacheFile) {
        guard !isScanning else { return }
        isScanning = true
        if !holdsSettingsError {
            errorMessage = nil
        }
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

    /// Stamp the inventory before and after the scan. `commitScanCache` drops
    /// the result when the two differ, so a scan that raced an install is not
    /// served to the next launch.
    private func runScan(includeSystem: Bool) {
        isScanning = true
        if !holdsSettingsError {
            errorMessage = nil
        }
        progressMessage = scanData == nil ? "Starting scan…" : "Refreshing scan…"
        let vm = self
        DispatchQueue.global(qos: .userInitiated).async {
            // One clock for both stamps and for the scan between them: a walk
            // budget read from a different source on each call probes further
            // on one stamp than on the other, and `commitScanCache` then drops
            // a snapshot of a machine that did not change.
            let clock = monotonicSeconds
            let before = scanFingerprint(clock: clock)
            let now = Date()
            let result = runFullScan(includeSystem: includeSystem, now: now, clock: clock) { msg in
                DispatchQueue.main.async {
                    vm.progressMessage = msg
                }
            }
            let after = scanFingerprint(clock: clock)
            if before == after, result.incomplete != true {
                DispatchQueue.main.async {
                    vm.progressMessage = "Saving scan cache…"
                }
            }
            var cacheWriteFailure: String?
            do {
                // `false` here is a snapshot dropped on purpose, not a write
                // that happened: the inventory moved under the scan, so what
                // was measured is a mixture. The next launch would rescan
                // anyway, and saying so beats a report that reads like it was
                // saved. The CLI reports the same two cases the same way.
                let committed = try commitScanCache(
                    includeSystem: includeSystem,
                    data: result,
                    before: before,
                    after: after
                )
                if !committed, result.incomplete != true {
                    cacheWriteFailure = "installed software changed while the scan was running"
                }
            } catch {
                cacheWriteFailure = error.localizedDescription
            }
            DispatchQueue.main.async {
                vm.scanData = result
                vm.pruneSelection()
                vm.isScanning = false
                let note = vm.pendingNote
                vm.pendingNote = ""
                vm.statusText = note.isEmpty
                    ? "scanned \(formatDate(result.scanned_at)) · \(formatSeconds(result.duration_s))s"
                    : "\(note). Scanned \(formatDate(result.scanned_at))"
                if result.incomplete == true {
                    // No cache is written for this scan, and the outdated and
                    // unused-package lists are missing whatever the failed
                    // checks would have found. Saying so beats lists that look
                    // complete.
                    vm.statusText += " · check failed, not cached"
                }
                if let cacheWriteFailure {
                    vm.statusText += " · not cached: \(redactHomePaths(cacheWriteFailure))"
                }
            }
        }
    }

    func generateCleanupScript() -> String {
        guard let data = scanData else { return "" }
        let header = [
            "#!/bin/sh",
            "set -e",
            "# AppAttic cleanup",
            "# Review every line before running. Nothing here is deleted automatically.",
            "",
        ]
        var body: [String] = []
        let leftItems = visibleOrphanedLeftovers(data.leftovers, ignoring: ignoredLeftovers)
            .filter { selectedLeftovers.contains($0.path) }
        let appItems = data.software.filter { selectedApps.contains($0.path) && StaleTier.isSelectable($0.tierKind) }
        if !leftItems.isEmpty {
            body.append("# Leftover data and PATH overlays")
            for item in leftItems {
                body.append(withRootCmd(leftoverRemoveCommand(for: item)))
            }
        }
        for app in appItems {
            body.append("")
            body.append("# \(shellComment(app.name))")
            body.append(withRootCmd(uninstallCommand(for: app)))
        }
        let pkgItems = allPackages.filter { selectedPackages.contains($0.id) }
        if !pkgItems.isEmpty {
            body.append("")
            body.append("# Distro orphans and language globals")
            for item in pkgItems {
                body.append(withRootCmd(packageRemoveCommand(item)))
            }
        }
        return scriptWithHeader(header, body)
    }

    func generateScript() -> String {
        let merged = previewScript(cleanup: generateCleanupScript(), update: generateUpdateScript())
        let manual = markManualPreview()
        guard !manual.isEmpty else { return merged }
        // The mark-manual body arrives without its own `rootcmd` helper, so the
        // merged script needs one when this section is what escalates.
        return ensureRootHelper(merged + manual)
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

    func restoreIgnoredLeftover(_ path: String) {
        guard ignoredLeftovers.contains(path) else { return }
        var ignored = ignoredLeftovers
        ignored.remove(path)
        ignoredLeftovers = ignored
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
                  StaleTier.isSelectable(item.tierKind) else { return }
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
        run(Action.cleanup, then: completion)
    }

    func executeUpdate(then completion: @escaping (Bool) -> Void) {
        run(.update, then: completion)
    }

    func executeMarkManual(then completion: @escaping (Bool) -> Void) {
        run(.markManual, then: completion)
    }

    private func run(_ action: Action, then completion: @escaping (Bool) -> Void) {
        let script = action.script(self)
        guard scriptHasActionableCommands(script) else {
            errorMessage = action.emptyMessage
            completion(false)
            return
        }
        runTempScript(script, message: action.progressMessage, clear: action.clear, then: completion)
    }

    /// The three destructive actions, each naming the script it writes, what
    /// the progress line says while it runs, what an empty selection reports,
    /// and which selection the run clears.
    private enum Action {
        case cleanup
        case update
        case markManual

        func script(_ vm: ScannerViewModel) -> String {
            switch self {
            case .cleanup: return vm.generateCleanupScript()
            case .update: return vm.generateUpdateScript()
            case .markManual: return vm.generateMarkManualScript()
            }
        }

        var progressMessage: String {
            switch self {
            case .cleanup: return "Removing selected items…"
            case .update: return "Updating selected packages…"
            case .markManual: return "Marking packages as manually installed…"
            }
        }

        var emptyMessage: String {
            switch self {
            case .cleanup: return "Nothing to delete. Uninstall Steam and CrossOver items in those apps."
            case .update: return "Nothing to update. \(outdatedSkippedManagersNote)"
            case .markManual: return "Nothing to mark as manually installed."
            }
        }

        var clear: ScriptClear {
            switch self {
            case .cleanup: return .cleanup
            case .update: return .update
            case .markManual: return .markManual
            }
        }
    }

    private enum ScriptClear {
        case cleanup
        case update
        case markManual
    }

    /// One script at a time. It uninstalls packages and deletes files, so a
    /// second copy running beside the first is two package managers contending
    /// for the same dpkg or rpm lock, and neither finishes its transaction. The
    /// buttons are disabled while `isScanning`, but a confirm can land twice
    /// before SwiftUI re-renders. The Qt shell keeps the same guard in
    /// `runScript`.
    private func runTempScript(
        _ script: String,
        message: String,
        clear: ScriptClear,
        then completion: @escaping (Bool) -> Void
    ) {
        guard !isScanning else {
            completion(false)
            return
        }
        isScanning = true
        if !holdsSettingsError {
            errorMessage = nil
        }
        progressMessage = message
        let vm = self
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // A script blocked on a stale package lock, an unreachable
                // mirror, or a prompt nothing can answer would otherwise hold
                // isScanning forever with every action disabled. The runner
                // stops it and says what it had already done; the selections
                // stay, because what the script did before the stop is unknown
                // and re-running the same list is the operator's call.
                let run = try runGeneratedScript(script, discardStdout: true)
                DispatchQueue.main.async {
                    vm.isScanning = false
                    // Both failure paths below drop the snapshot: `set -e` halts
                    // the line after the failure, so the lines before it
                    // already ran, and a cache kept across the run describes
                    // software that is gone.
                    if !run.finished {
                        // A stopped run always carries the reason in its
                        // stderr, so there is no empty case to skip.
                        vm.errorMessage = scriptStoppedMessage() + " Selection kept.\n"
                            + commandFailureMessage(status: run.status, stderr: run.stderr)
                        clearScanCache()
                        completion(false)
                        return
                    }
                    if run.status != 0 {
                        vm.errorMessage = commandFailureMessage(status: run.status, stderr: run.stderr)
                            + " Selection kept."
                        clearScanCache()
                        completion(false)
                        return
                    }
                    switch clear {
                    case .cleanup:
                        let count = vm.cleanupSelectionCount
                        vm.selectedLeftovers = []
                        vm.selectedApps = remainingPendingAppPaths(
                            selected: vm.selectedApps,
                            software: vm.scanData?.software ?? []
                        )
                        vm.selectedPackages = []
                        // A successful run then a rescan left the window saying
                        // only "scanned <time>", the same line a plain Rescan
                        // prints. The rows vanishing was the only sign the
                        // script had run, and an app the user did not expect to
                        // go read as a scan that found nothing.
                        var note = count == 1
                            ? "Removed 1 selected item"
                            : "Removed \(count) selected items"
                        if !vm.selectedApps.isEmpty {
                            note +=
                                ". Steam or CrossOver still needs to finish uninstall; those items stay selected"
                        }
                        vm.pendingNote = note
                    case .update:
                        let count = vm.selectedOutdated.count
                        vm.selectedOutdated = []
                        vm.pendingNote = count == 1
                            ? "Updated 1 package"
                            : "Updated \(count) packages"
                    case .markManual:
                        let count = vm.selectedMarkManual.count
                        vm.selectedMarkManual = []
                        vm.pendingNote = count == 1
                            ? "Marked 1 package as manually installed"
                            : "Marked \(count) packages as manually installed"
                    }
                    // The script just removed files, upgraded packages, or
                    // changed install state: exactly what the snapshot
                    // describes. Drop it, or the next launch opens on rows for
                    // items that are already gone. Every caller rescans on
                    // success anyway, which rewrites the file. The CLI's
                    // update path clears the same file for the same reason.
                    clearScanCache()
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    vm.isScanning = false
                    vm.errorMessage = redactHomePaths(error.localizedDescription)
                    completion(false)
                }
            }
        }
    }
}
