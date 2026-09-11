import Foundation
import SwiftCrossUI
import AppAtticScan

private enum DateFmt {
    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

func formatDate(_ iso: String?) -> String {
    guard let iso = iso, !iso.isEmpty else { return "-" }
    guard let d = parseISODate(iso) else { return String(iso.prefix(10)) }
    guard let days = calendarDaysSince(d) else { return DateFmt.medium.string(from: d) }
    if days <= 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 45 { return "\(days) days ago" }
    return DateFmt.medium.string(from: d)
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case leftovers = "Leftovers"
    case stale = "Stale Apps"
    case outdated = "Outdated"
    case packages = "Packages"
    case diskUsage = "Disk Usage"
    case settings = "Settings"
    var id: Self { self }
}

private enum Col {
    static let mark = 22
    static let loc = 128
    static let date = 92
    static let size = 72
    static let tier = 72
    static let mgr = 88
    static let ver = 118
    static let kind = 72
}

private struct HRule: View {
    var body: some View {
        Color.appHairline
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

private struct VRule: View {
    var body: some View {
        Color.appHairline
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

struct ContentView: View {
    @State var vm = ScannerViewModel()
    @State private var selected: SidebarItem = ContentView.initialSidebar()
    @State private var leftoverSel: String? = nil
    @State private var staleSel: String? = nil
    @State private var outdatedSel: String? = nil
    @State private var packageSel: String? = nil
    @State private var packageFilter: PackageListFilter = .all
    @State private var showScript = false
    @State private var showConfirm = false
    @State private var confirmMode = "delete"
    @State private var includeSystem = false
    @State private var confirmDelete = true
    @State private var settingsLoadFailed = false
    @State private var settingsLoadError = ""
    @State private var scriptCopied = false

    private static func initialSidebar() -> SidebarItem {
        switch ProcessInfo.processInfo.environment["APPATTIC_PAGE"] {
        case "leftovers": return .leftovers
        case "stale": return .stale
        case "outdated": return .outdated
        case "packages": return .packages
        case "disk": return .diskUsage
        case "settings": return .settings
        default: return .overview
        }
    }

    private var leftoverRows: [LeftoverItem] { vm.leftoverRows }
    private var staleRows: [SoftwareItem] { vm.staleRows }
    private var outdatedRows: [OutdatedEntry] { vm.outdatedRows }
    private var packageRows: [PackageEntry] { vm.packageRows(filter: packageFilter) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.appChrome)
                HRule()
                if let error = vm.errorMessage, vm.scanData != nil || vm.isScanning {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(Color.appRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss") {
                            vm.errorMessage = nil
                            vm.holdsSettingsError = false
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    HRule()
                }
                if vm.isScanning && vm.scanData == nil {
                    scanningState
                } else if let error = vm.errorMessage, vm.scanData == nil {
                    errorState(error)
                } else {
                    detailBody
                }
                if vm.selectionCount > 0 {
                    HRule()
                    actionBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.appBg)
        }
        .onAppear {
            do {
                let settings = try loadSettings()
                includeSystem = settings.includeSystem
                confirmDelete = settings.confirmDelete
                vm.ignoredLeftovers = Set(settings.ignoredLeftoverPaths)
                vm.start(includeSystem: includeSystem)
            } catch {
                settingsLoadFailed = true
                settingsLoadError = error.localizedDescription
                vm.errorMessage = settingsErrorUserMessage(error)
                vm.holdsSettingsError = true
            }
        }
        .alert(confirmTitle, isPresented: $showConfirm) {
            Button("Cancel") { showConfirm = false }
            Button(confirmMode == "update" ? "Update" : (confirmMode == "mark-manual" ? "Mark Manual" : "Delete")) {
                if confirmMode == "update" {
                    vm.executeUpdate { ok in
                        showScript = false
                        if ok { vm.scan(includeSystem: includeSystem) }
                    }
                } else if confirmMode == "mark-manual" {
                    vm.executeMarkManual { ok in
                        showScript = false
                        if ok { vm.scan(includeSystem: includeSystem) }
                    }
                } else {
                    vm.executeCleanup { ok in
                        showScript = false
                        if ok { vm.scan(includeSystem: includeSystem) }
                    }
                }
            }
        }
        .sheet(isPresented: $showScript) {
            scriptSheet
        }
    }

    private var confirmTitle: String {
        if confirmMode == "update" {
            return "Update \(vm.selectedOutdated.count) Homebrew or Flatpak packages?"
        }
        if confirmMode == "mark-manual" {
            return "Mark \(vm.selectedMarkManual.count) packages as manually installed?"
        }
        return "Delete \(vm.cleanupSelectionCount) selected items? This runs the previewed uninstall script now. Steam may still ask you to confirm."
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarItem.allCases, id: \.id) { item in
                let on = selected == item
                HStack {
                    Text(item.rawValue)
                        .font(.system(size: 13))
                        .foregroundColor(on ? Color.appOnAccent : Color.appText)
                    Spacer()
                    if let count = sidebarCount(item) {
                        Text("\(count)")
                            .font(.system(size: 11))
                            .foregroundColor(on ? Color.appOnAccent.opacity(0.9) : Color.appDim)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(on ? Color.appBlue : Color.clear)
                .cornerRadius(6)
                .onTapGesture {
                    guard item != selected else { return }
                    selected = item
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(minWidth: 200, maxWidth: 220, maxHeight: .infinity, alignment: .topLeading)
    }

    func sidebarCount(_ item: SidebarItem) -> Int? {
        guard let totals = vm.scanData?.totals else { return nil }
        let count: Int
        switch item {
        case .leftovers:
            count = visibleOrphanCount
        case .stale:
            count = vm.listedStaleCount
        case .outdated:
            count = totals.outdated_apps ?? 0
        case .packages:
            count = vm.allPackages.count
        default:
            return nil
        }
        return count == 0 ? nil : count
    }

    var toolbar: some View {
        HStack(spacing: 8) {
            if let count = toolbarCount {
                Text(count)
                    .font(.system(size: 11))
                    .foregroundColor(Color.appDim)
            }
            if !vm.isScanning, !vm.statusText.isEmpty, toolbarCount != nil {
                Text(vm.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(Color.appDim)
            }
            Spacer()
            if vm.isScanning {
                Text(vm.progressMessage)
                    .font(.system(size: 13))
                    .foregroundColor(Color.appDim)
            } else if toolbarCount == nil, !vm.statusText.isEmpty {
                Text(vm.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(Color.appDim)
            }
            if vm.scanData != nil && (selected == .leftovers || selected == .stale || selected == .outdated || selected == .packages) {
                TextField("Search", text: $vm.searchText)
                    .font(.system(size: 13))
                    .frame(width: 200)
            }
            if selected == .packages {
                packageFilterChips
            }
            if canSelectAll {
                Button(allVisibleSelected ? "Deselect All" : "Select All") {
                    toggleSelectAll()
                }
                .disabled(vm.isScanning)
            }
            Button("Rescan") { vm.scan(includeSystem: includeSystem) }
                .disabled(vm.isScanning)
        }
    }

    private var toolbarCount: String? {
        switch selected {
        case .leftovers:
            return leftoverCountLabel
        case .stale:
            return staleCountLabel
        case .outdated:
            return outdatedCountLabel
        case .packages:
            return packageCountLabel
        default:
            return nil
        }
    }

    var scanningState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Scanning")
                .font(.system(size: 13, weight: .semibold))
            Text(vm.progressMessage)
                .font(.system(size: 13))
                .foregroundColor(Color.appDim)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    func errorState(_ error: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(vm.holdsSettingsError ? "Settings could not be loaded" : "Scan failed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.appRed)
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(Color.appDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if vm.holdsSettingsError {
                Text("Fix the file, or change a setting to write a new one.")
                    .font(.system(size: 13))
                    .foregroundColor(Color.appDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            } else {
                Button("Try Again") { vm.scan(includeSystem: includeSystem) }
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    @ViewBuilder
    var detailBody: some View {
        switch selected {
        case .overview:
            overview
        case .leftovers:
            leftoverPage
        case .stale:
            stalePage
        case .outdated:
            outdatedPage
        case .packages:
            packagePage
        case .diskUsage:
            DiskUsageView()
        case .settings:
            settings
        }
    }

    var overview: some View {
        let leftoverRows = vm.overviewLeftovers
        let staleRows = vm.overviewStale
        let outdatedRows = vm.overviewOutdated
        return VStack(alignment: .leading, spacing: 0) {
            if let totals = vm.scanData?.totals {
                HStack(alignment: .top, spacing: 28) {
                    overviewStat("Installed", "\(totals.apps_installed)")
                    overviewStat("Leftovers", "\(visibleOrphanCount)", Color.appRed)
                    overviewStat("Leftover data", humanSize(visibleOrphanedBytes), Color.appGreen)
                    overviewStat(
                        "Stale",
                        overviewStaleTotalLabel(count: vm.listedStaleCount, bytes: staleReclaimableBytes(staleRows)),
                        Color.appYellow
                    )
                    overviewStat("Outdated", "\(totals.outdated_apps ?? 0)", Color.appYellow)
                    overviewStat("Packages", "\(vm.allPackages.count)")
                    overviewStat("Last scan", lastScanLabel, Color.appDim)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            if leftoverRows.isEmpty && staleRows.isEmpty && outdatedRows.isEmpty {
                if vm.scanData != nil {
                    let packageCount = vm.allPackages.count
                    if packageCount > 0 {
                        emptyState(
                            "Open Packages to review",
                            packageCount == 1
                                ? "1 unused package is listed on the Packages page."
                                : "\(packageCount) unused packages are listed on the Packages page.",
                            actionTitle: "Open Packages"
                        ) {
                            selected = .packages
                        }
                    } else {
                        emptyState(
                            "Nothing to review",
                            "No leftover data, stale apps, outdated packages, or unused packages in this scan."
                        )
                    }
                }
            } else {
                HRule()
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        if !leftoverRows.isEmpty {
                            overviewColumn(title: "Largest leftovers") {
                                ForEach(Array(leftoverRows.prefix(12)), id: \.path) { item in
                                    overviewTappableRow(
                                        leftoverName(item),
                                        leftoverWhat(item),
                                        leftoverSizeLabel(item)
                                    ) {
                                        leftoverSel = item.path
                                        selected = .leftovers
                                    }
                                }
                            }
                        }
                        if !leftoverRows.isEmpty && (!staleRows.isEmpty || !outdatedRows.isEmpty) {
                            VRule()
                        }
                        if !staleRows.isEmpty {
                            overviewColumn(title: "Largest stale apps") {
                                ForEach(Array(staleRows.prefix(12)), id: \.path) { item in
                                    overviewTappableRow(item.name, staleOverviewDetail(item), staleSizeLabel(item)) {
                                        staleSel = item.path
                                        selected = .stale
                                    }
                                }
                            }
                        }
                        if !staleRows.isEmpty && !outdatedRows.isEmpty {
                            VRule()
                        }
                        if !outdatedRows.isEmpty {
                            overviewColumn(title: "Outdated packages") {
                                ForEach(Array(outdatedRows.prefix(12)), id: \.id) { item in
                                    overviewTappableRow(
                                        item.displayName,
                                        outdatedWhat(item),
                                        item.kind == "untrusted"
                                            ? "untrusted tap"
                                            : "\(item.current_version ?? "-") → \(item.latest_version ?? "?")"
                                    ) {
                                        outdatedSel = item.id
                                        selected = .outdated
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func overviewColumn<Content: View>(
        title: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.appChrome)
            HRule()
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var lastScanLabel: String {
        guard let data = vm.scanData else { return "Never" }
        let when = formatDate(data.scanned_at)
        if data.from_cache == true {
            return "\(when), cached"
        }
        return "\(when), \(String(format: "%.1f", data.duration_s))s"
    }

    func overviewStat(_ label: String, _ value: String, _ color: Color = Color.appText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.appDim)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(color)
        }
    }

    func overviewTappableRow(_ name: String, _ detail: String, _ trailing: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            overviewDetailRow(name, detail, trailing)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            HRule()
        }
        .onTapGesture(perform: action)
    }

    var leftoverPage: some View {
        let rows = leftoverRows
        let selectedPath = resolvedSelection(leftoverSel, visibleIds: rows.map(\.path))
        return HStack(alignment: .top, spacing: 0) {
            listPane(
                isEmpty: rows.isEmpty,
                emptyTitle: "No leftover data",
                emptyDetail: leftoverEmptyDetail,
                header: { leftoverHeader }
            ) {
                ForEach(rows, id: \.path) { item in
                    let on = selectedPath == item.path
                    VStack(spacing: 0) {
                        compactLeftoverRow(item, selected: on)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(on ? Color.appBlue : Color.clear)
                        HRule()
                    }
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        leftoverSel = item.path
                    }
                }
            }
            VRule()
            if let item = rows.first(where: { $0.path == selectedPath }) {
                leftoverInspector(item)
            } else {
                emptyState("Select a leftover", "What it is, why it was flagged, plus path and size.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var leftoverCountLabel: String {
        let n = leftoverRows.count
        return n == 1 ? "1 leftover" : "\(n) leftovers"
    }

    var stalePage: some View {
        let rows = staleRows
        let selectedPath = resolvedSelection(staleSel, visibleIds: rows.map(\.path))
        return HStack(alignment: .top, spacing: 0) {
            listPane(
                isEmpty: rows.isEmpty,
                emptyTitle: "No stale apps",
                emptyDetail: vm.searchText.isEmpty
                    ? (vm.includeSystem
                        ? "No remove, review, or system apps in this scan."
                        : "No remove or review candidates.")
                    : "No stale apps match this search.",
                header: { staleHeader }
            ) {
                ForEach(rows, id: \.path) { item in
                    let on = selectedPath == item.path
                    VStack(spacing: 0) {
                        compactStaleRow(item, selected: on)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(on ? Color.appBlue : Color.clear)
                        HRule()
                    }
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        staleSel = item.path
                    }
                }
            }
            VRule()
            if let item = rows.first(where: { $0.path == selectedPath }) {
                staleInspector(item)
            } else {
                emptyState("Select an app", "What it is, why it was flagged, plus path and size.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var staleCountLabel: String {
        let n = staleRows.count
        return n == 1 ? "1 stale app" : "\(n) stale apps"
    }

    var outdatedPage: some View {
        let rows = outdatedRows
        let selectedId = resolvedSelection(outdatedSel, visibleIds: rows.map(\.id))
        return HStack(alignment: .top, spacing: 0) {
            listPane(
                isEmpty: rows.isEmpty,
                emptyTitle: "No outdated packages",
                emptyDetail: vm.searchText.isEmpty
                    ? "Brew, Flatpak, Snap, apt, pacman, AUR, dnf, yum, zypper, and the App Store reported nothing, or those tools are not installed."
                    : "No outdated packages match this search.",
                header: { outdatedHeader }
            ) {
                ForEach(rows, id: \.id) { item in
                    let on = selectedId == item.id
                    VStack(spacing: 0) {
                        compactOutdatedRow(item, selected: on)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(on ? Color.appBlue : Color.clear)
                        HRule()
                    }
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        outdatedSel = item.id
                    }
                }
            }
            VRule()
            if let item = rows.first(where: { $0.id == selectedId }) {
                outdatedInspector(item)
            } else {
                emptyState("Select a package", "What it is, why it is listed, plus current and latest versions.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var outdatedCountLabel: String {
        let n = outdatedRows.count
        return n == 1 ? "1 outdated package" : "\(n) outdated packages"
    }

    var packageFilterChips: some View {
        HStack(spacing: 4) {
            packageFilterChip("All", .all)
            packageFilterChip("Leaves", .leaves)
            packageFilterChip("Globals", .globals)
        }
    }

    func packageFilterChip(_ title: String, _ filter: PackageListFilter) -> some View {
        let on = packageFilter == filter
        return Text(title)
            .font(.system(size: 11))
            .foregroundColor(on ? Color.appOnAccent : Color.appText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(on ? Color.appBlue : Color.appChrome)
            .cornerRadius(4)
            .onTapGesture {
                guard filter != packageFilter else { return }
                packageFilter = filter
            }
    }

    var packagePage: some View {
        let rows = packageRows
        let selectedId = resolvedSelection(packageSel, visibleIds: rows.map(\.id))
        return HStack(alignment: .top, spacing: 0) {
            listPane(
                isEmpty: rows.isEmpty,
                emptyTitle: "No unused packages",
                emptyDetail: packageEmptyDetail,
                header: { packageHeader }
            ) {
                ForEach(rows, id: \.id) { item in
                    let on = selectedId == item.id
                    VStack(spacing: 0) {
                        compactPackageRow(item, selected: on)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(on ? Color.appBlue : Color.clear)
                        HRule()
                    }
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        packageSel = item.id
                    }
                }
            }
            VRule()
            if let item = rows.first(where: { $0.id == selectedId }) {
                packageInspector(item)
            } else {
                emptyState("Select a package", "Orphan distro packages and user-global language tools. Remove or mark-manual after confirm.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var packageCountLabel: String {
        let n = packageRows.count
        return n == 1 ? "1 package" : "\(n) packages"
    }

    private var packageEmptyDetail: String {
        if !vm.searchText.isEmpty {
            return "No packages match this search."
        }
        switch packageFilter {
        case .leaves:
            return "No distro orphans. apt/pacman/dnf/zypper reported nothing, or those tools are not installed."
        case .globals:
            return "No user-global npm, pnpm, bun, pipx, or uv tools."
        case .all:
            return "No distro orphans or language globals. Missing package managers simply have nothing to list."
        }
    }

    func listPane<Header: View, Rows: View>(
        isEmpty: Bool,
        emptyTitle: String,
        emptyDetail: String,
        @ViewBuilder header: () -> Header,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                if !vm.searchText.isEmpty {
                    emptyState(emptyTitle, emptyDetail, actionTitle: "Clear search") {
                        vm.searchText = ""
                    }
                } else {
                    emptyState(emptyTitle, emptyDetail)
                }
            } else {
                header()
                HRule()
                ScrollView {
                    rows()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var leftoverHeader: some View {
        headerRow {
            Text("")
                .frame(width: Col.mark, alignment: .leading)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Location")
                .frame(width: Col.loc, alignment: .leading)
            Text("Modified")
                .frame(width: Col.date, alignment: .leading)
            Text("Size")
                .frame(width: Col.size, alignment: .trailing)
        }
    }

    var staleHeader: some View {
        headerRow {
            Text("")
                .frame(width: Col.mark, alignment: .leading)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Status")
                .frame(width: Col.tier, alignment: .leading)
            Text("Last used")
                .frame(width: Col.date, alignment: .leading)
            Text("Size")
                .frame(width: Col.size, alignment: .trailing)
        }
    }

    var outdatedHeader: some View {
        headerRow {
            Text("")
                .frame(width: Col.mark, alignment: .leading)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Manager")
                .frame(width: Col.mgr, alignment: .leading)
            Text("Current")
                .frame(width: Col.ver, alignment: .trailing)
        }
    }

    var packageHeader: some View {
        headerRow {
            Text("")
                .frame(width: Col.mark, alignment: .leading)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Manager")
                .frame(width: Col.mgr, alignment: .leading)
            Text("Kind")
                .frame(width: Col.kind, alignment: .leading)
            Text("Size")
                .frame(width: Col.size, alignment: .trailing)
        }
    }

    func headerRow<Content: View>(@ViewBuilder columns: () -> Content) -> some View {
        HStack(spacing: 8) {
            columns()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color.appDim)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.appChrome)
    }

    func overviewDetailRow(_ name: String, _ detail: String, _ trailing: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundColor(Color.appText)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color.appDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(trailing)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.appDim)
                .frame(minWidth: Col.size, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
    }

    func compactLeftoverRow(_ item: LeftoverItem, selected: Bool) -> some View {
        let marked = vm.selectedLeftovers.contains(item.path)
        return HStack(spacing: 8) {
            Text(marked ? "in" : "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selected ? Color.appOnAccent : Color.appBlue)
                .frame(width: Col.mark, alignment: .leading)
            Text(leftoverName(item))
                .font(.system(size: 13))
                .foregroundColor(selected ? Color.appOnAccent : leftoverNameColor(item))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(leftoverLocationLabel(rootLabel: item.root, extraCount: item.extra_paths?.count ?? 0))
                .font(.system(size: 11))
                .foregroundColor(selected ? Color.appOnAccent.opacity(0.9) : leftoverSecondaryColor(item))
                .frame(width: Col.loc, alignment: .leading)
            Text(formatDate(item.mtime))
                .font(.system(size: 11))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.date, alignment: .leading)
            Text(leftoverSizeLabel(item))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.size, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func compactStaleRow(_ item: SoftwareItem, selected: Bool) -> some View {
        let selectable = selectableCleanupTiers.contains(item.tier ?? "")
        let marked = selectable && vm.selectedApps.contains(item.path)
        let status = item.outdated == true ? "\(displayTier(item.tier)) · out" : displayTier(item.tier)
        return HStack(spacing: 8) {
            Text(marked ? "in" : "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selected ? Color.appOnAccent : Color.appBlue)
                .frame(width: Col.mark, alignment: .leading)
            Text(item.name)
                .font(.system(size: 13))
                .foregroundColor(rowPrimary(selected))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status)
                .font(.system(size: 11))
                .foregroundColor(selected ? Color.appOnAccent : tierColor(item.tier))
                .frame(width: Col.tier, alignment: .leading)
            Text(formatDate(item.last_used))
                .font(.system(size: 11))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.date, alignment: .leading)
            Text(staleSizeLabel(item))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.size, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func compactOutdatedRow(_ item: OutdatedEntry, selected: Bool) -> some View {
        let marked = vm.selectedOutdated.contains(item.id)
        let ver: String
        if item.kind == "untrusted" {
            ver = "untrusted tap"
        } else {
            ver = "\(item.current_version ?? "-") → \(item.latest_version ?? "?")"
        }
        return HStack(spacing: 8) {
            Text(marked ? "in" : "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selected ? Color.appOnAccent : Color.appBlue)
                .frame(width: Col.mark, alignment: .leading)
            Text(item.displayName)
                .font(.system(size: 13))
                .foregroundColor(rowPrimary(selected))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.manager.replacingOccurrences(of: "-", with: " "))
                .font(.system(size: 11))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.mgr, alignment: .leading)
            Text(ver)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(selected ? Color.appOnAccent : Color.appYellow)
                .frame(width: Col.ver, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func compactPackageRow(_ item: PackageEntry, selected: Bool) -> some View {
        let marked = vm.selectedPackages.contains(item.id) || vm.selectedMarkManual.contains(item.id)
        let kind = item.kind == "global" ? "Global" : "Orphan"
        let kindColor = item.kind == "global" ? Color.appYellow : Color.appRed
        return HStack(spacing: 8) {
            Text(marked ? "in" : "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selected ? Color.appOnAccent : Color.appBlue)
                .frame(width: Col.mark, alignment: .leading)
            Text(item.name)
                .font(.system(size: 13))
                .foregroundColor(rowPrimary(selected))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.manager.replacingOccurrences(of: "-", with: " "))
                .font(.system(size: 11))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.mgr, alignment: .leading)
            Text(kind)
                .font(.system(size: 11))
                .foregroundColor(selected ? Color.appOnAccent : kindColor)
                .frame(width: Col.kind, alignment: .leading)
            Text(packageSizeLabel(item))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(rowSecondary(selected))
                .frame(width: Col.size, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func leftoverName(_ item: LeftoverItem) -> String {
        leftoverDisplayName(name: item.name, extraPaths: item.extra_paths ?? [])
    }

    func leftoverWhat(_ item: LeftoverItem) -> String {
        leftoverWhatText(
            rootLabel: item.root,
            kind: item.kind,
            name: item.name,
            extraPaths: item.extra_paths ?? [],
            storedSummary: item.summary,
            shadows: item.shadows
        )
    }

    func leftoverWhy(_ item: LeftoverItem) -> String {
        leftoverWhyText(
            rootLabel: item.root,
            kind: item.kind,
            extraPaths: item.extra_paths ?? [],
            storedReason: item.reason,
            shadows: item.shadows
        )
    }

    func leftoverNameColor(_ item: LeftoverItem) -> Color {
        item.status == "shadow" ? Color.appYellow : Color.appText
    }

    func leftoverSecondaryColor(_ item: LeftoverItem) -> Color {
        item.status == "shadow" ? Color.appYellow.opacity(0.85) : Color.appDim
    }

    func leftoverStatusColor(_ item: LeftoverItem) -> Color {
        if item.status == "orphaned" { return Color.appRed }
        if item.status == "shadow" { return Color.appYellow }
        return Color.appText
    }

    func staleWhat(_ item: SoftwareItem) -> String {
        if let summary = item.summary, !summary.isEmpty, !isJunkAppBlurb(summary) {
            if item.source != "steam" || summary.split(whereSeparator: \.isWhitespace).count >= 4 {
                return summary
            }
        }
        if item.source == "brew-formula" { return "Homebrew formula" }
        if item.source == "brew-cask" { return "Homebrew cask" }
        if item.source == "steam" {
            if item.steam_appid == nil, item.name.compare("Steam", options: .caseInsensitive) == .orderedSame {
                return "Steam client"
            }
            return "Steam game"
        }
        if item.source == "crossover" { return "CrossOver bottle" }
        if item.source == "flatpak" { return "Flatpak app" }
        if item.source == "snap" { return "Snap app" }
        if item.source == "appimage" { return "AppImage" }
        return "Installed application"
    }

    func staleOverviewDetail(_ item: SoftwareItem) -> String {
        let what = staleWhat(item)
        let data = item.data_bytes ?? 0
        if data > 0 {
            return "\(what) · \(humanSize(data)) data"
        }
        return what
    }

    func staleWhy(_ item: SoftwareItem) -> String {
        if let reason = item.reason, !reason.isEmpty { return displayStaleReason(reason) }
        return "Flagged as unused or unconfirmed."
    }

    func outdatedWhat(_ item: OutdatedEntry) -> String {
        if let summary = item.summary, !summary.isEmpty { return summary }
        return "Package managed by \(item.manager.replacingOccurrences(of: "-", with: " "))"
    }

    func outdatedWhy(_ item: OutdatedEntry) -> String {
        if let reason = item.reason, !reason.isEmpty { return reason }
        let cur = item.current_version ?? "installed"
        let latest = item.latest_version ?? "newer"
        if item.updatable {
            return "\(item.manager.replacingOccurrences(of: "-", with: " ")) reports \(cur) installed, \(latest) available. You can update it from this page."
        }
        return "\(item.manager.replacingOccurrences(of: "-", with: " ")) reports \(cur) installed, \(latest) available. AppAttic does not run this upgrade."
    }

    func rowPrimary(_ selected: Bool) -> Color {
        selected ? Color.appOnAccent : Color.appText
    }

    func rowSecondary(_ selected: Bool) -> Color {
        selected ? Color.appOnAccent.opacity(0.9) : Color.appDim
    }

    func leftoverInspector(_ item: LeftoverItem) -> some View {
        inspectorPane {
            Text(leftoverName(item))
                .font(.system(size: 13, weight: .semibold))
            infoBlock("What", leftoverWhat(item))
            infoBlock("Why", leftoverWhy(item))
            inspectorFacts {
                infoRow("Kind", item.kind)
                infoRow("Status", displayTier(item.status), color: leftoverStatusColor(item))
                infoRow("Size", leftoverSizeLabel(item), mono: true)
                infoRow("Modified", formatDate(item.mtime))
                infoRow("Location", leftoverLocationLabel(rootLabel: item.root, extraCount: item.extra_paths?.count ?? 0))
                infoBlock("Path", item.path, mono: true)
                if let extra = item.extra_paths, !extra.isEmpty {
                    infoBlock("Also", extra.joined(separator: "\n"), mono: true)
                }
                if let shadows = item.shadows, !shadows.isEmpty {
                    infoBlock("Shadows", shadows, mono: true)
                }
                if let owner = item.owner, !owner.isEmpty {
                    infoRow("Owner", owner)
                }
            }
            Spacer()
            inspectorFooter {
                HStack {
                    Text("Include in cleanup")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: leftoverToggle(item.path))
                        .toggleStyle(.switch)
                }
                Button(revealLabel) { revealPath(item.path) }
                Button("Ignore leftover") {
                    vm.ignoreLeftover(item)
                    leftoverSel = nil
                    persistSettings()
                }
            }
        }
    }

    func staleInspector(_ item: SoftwareItem) -> some View {
        inspectorPane {
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
            infoBlock("What", staleWhat(item))
            infoBlock("Why", staleWhy(item))
            inspectorFacts {
                infoRow("Status", displayTier(item.tier), color: tierColor(item.tier))
                infoRow("Source", item.source)
                if let version = item.version, !version.isEmpty {
                    infoRow("Version", version)
                }
                if item.outdated == true {
                    infoRow("Latest", item.latest_version ?? "newer available", color: Color.appYellow)
                }
                infoRow("Size", staleSizeLabel(item), mono: true)
                infoRow("Last used", formatDate(item.last_used))
                infoRow("Installed", formatDate(item.installed_at))
                infoBlock("Path", item.path, mono: true)
                if let paths = item.data_paths, !paths.isEmpty {
                    infoBlock("App data", paths.joined(separator: "\n"), mono: true)
                }
                if item.running_service == true {
                    infoRow("Service", "Running")
                }
            }
            Spacer()
            inspectorFooter {
                if selectableCleanupTiers.contains(item.tier ?? "") {
                    HStack {
                        Text("Include in cleanup")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: staleToggle(item.path))
                            .toggleStyle(.switch)
                    }
                }
                Button(revealLabel) { revealPath(item.path) }
            }
        }
    }

    func outdatedInspector(_ item: OutdatedEntry) -> some View {
        inspectorPane {
            Text(item.displayName)
                .font(.system(size: 13, weight: .semibold))
            if let title = item.title, !title.isEmpty, title != item.name {
                Text(item.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.appDim)
            }
            infoBlock("What", outdatedWhat(item))
            infoBlock("Why", outdatedWhy(item))
            inspectorFacts {
                infoRow("Manager", item.manager.replacingOccurrences(of: "-", with: " "))
                if item.kind == "untrusted" {
                    infoRow("Status", "untrusted tap", color: Color.appYellow)
                } else {
                    infoRow("Current", item.current_version ?? "-", mono: true)
                    infoRow("Latest", item.latest_version ?? "?", color: Color.appYellow, mono: true)
                }
            }
            Spacer()
            inspectorFooter {
                if item.updatable {
                    HStack {
                        Text("Include in update")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: outdatedToggle(item.id))
                            .toggleStyle(.switch)
                    }
                } else if item.kind == "untrusted" {
                    Text("Listed so you can see it. AppAttic will not trust the tap.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.appDim)
                }
            }
        }
    }

    func packageInspector(_ item: PackageEntry) -> some View {
        inspectorPane {
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
            infoBlock("What", item.summary ?? packageWhatText(manager: item.manager, kind: item.kind))
            infoBlock("Why", item.reason ?? packageWhyText(manager: item.manager, kind: item.kind))
            inspectorFacts {
                infoRow("Manager", item.manager.replacingOccurrences(of: "-", with: " "))
                infoRow(
                    "Kind",
                    item.kind == "global" ? "Global" : "Orphan",
                    color: item.kind == "global" ? Color.appYellow : Color.appRed
                )
                if let version = item.version, !version.isEmpty {
                    infoRow("Version", version, mono: true)
                }
                infoRow("Size", packageSizeLabel(item), mono: true)
                if let children = item.children, !children.isEmpty {
                    infoBlock("Depends", children.joined(separator: "\n"), mono: true)
                }
            }
            Spacer()
            inspectorFooter {
                HStack {
                    Text("Include in remove")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: packageToggle(item.id))
                        .toggleStyle(.switch)
                }
                if item.canMarkManual {
                    HStack {
                        Text("Mark as manually installed")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: markManualToggle(item.id))
                            .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    func inspectorPane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(minWidth: 280, maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBg)
    }

    func inspectorFacts<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HRule()
            content()
        }
        .padding(.top, 4)
    }

    func inspectorFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HRule()
            content()
        }
    }

    func infoRow(_ label: String, _ value: String, color: Color = Color.appText, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.appDim)
                .frame(width: 88, alignment: .trailing)
            Text(value)
                .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    func infoBlock(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.appDim)
                .frame(width: 88, alignment: .trailing)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 13))
                .foregroundColor(Color.appText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelectionEnabled()
        }
    }

    func emptyState(
        _ title: String,
        _ detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(Color.appDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 32) {
                settingsSection("Scan") {
                    HStack {
                        Text("Include system apps in scan")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: includeSystemBinding)
                            .toggleStyle(.switch)
                            .disabled(vm.isScanning)
                    }
                    Text("Off by default. System apps are easy to misread as unused.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.appDim)
                }
                settingsSection("Deletion") {
                    HStack {
                        Text("Confirm before running")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: confirmDeleteBinding)
                            .toggleStyle(.switch)
                    }
                    Text("Shows an alert before rm, brew uninstall, package remove, or named package updates.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.appDim)
                }
                settingsSection("Ignored leftovers") {
                    if vm.ignoredLeftovers.isEmpty {
                        Text("None. Ignore a leftover from its inspector to hide it on later scans.")
                            .font(.system(size: 11))
                            .foregroundColor(Color.appDim)
                    } else {
                        Text(ignoredCountLabel)
                            .font(.system(size: 11))
                            .foregroundColor(Color.appDim)
                        ForEach(Array(vm.ignoredLeftovers.sorted().prefix(12)), id: \.self) { path in
                            Text(ignoredPathLabel(path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color.appText)
                        }
                        if vm.ignoredLeftovers.count > 12 {
                            Text("and \(vm.ignoredLeftovers.count - 12) more")
                                .font(.system(size: 11))
                                .foregroundColor(Color.appDim)
                        }
                        Button("Clear ignored leftovers") {
                            vm.clearIgnoredLeftovers()
                            persistSettings()
                        }
                    }
                }
            }
            .padding(16)
            Spacer()
            Text("AppAttic 1.2.0")
                .font(.system(size: 11))
                .foregroundColor(Color.appDim)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var actionBar: some View {
        HStack(spacing: 8) {
            Text("\(vm.selectionCount) selected")
                .font(.system(size: 11))
                .foregroundColor(Color.appDim)
            if vm.cleanupSelectionCount > 0 {
                Text(humanSize(vm.selectionReclaimableBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.appGreen)
            }
            Spacer()
            Button("Clear") { vm.clearSelection() }
                .disabled(vm.isScanning)
            Button("Preview Script") {
                scriptCopied = false
                showScript = true
            }
                .disabled(vm.isScanning)
            if !vm.selectedOutdated.isEmpty {
                Button("Update") {
                    confirmMode = "update"
                    if confirmDelete {
                        showConfirm = true
                    } else {
                        vm.executeUpdate { ok in
                            showScript = false
                            if ok { vm.scan(includeSystem: includeSystem) }
                        }
                    }
                }
                .disabled(vm.isScanning)
            }
            if !vm.selectedMarkManual.isEmpty {
                Button("Mark Manual") {
                    confirmMode = "mark-manual"
                    if confirmDelete {
                        showConfirm = true
                    } else {
                        vm.executeMarkManual { ok in
                            showScript = false
                            if ok { vm.scan(includeSystem: includeSystem) }
                        }
                    }
                }
                .disabled(vm.isScanning)
            }
            if vm.hasActionableCleanup {
                Button("Delete") {
                    confirmMode = "delete"
                    if confirmDelete {
                        showConfirm = true
                    } else {
                        vm.executeCleanup { ok in
                            showScript = false
                            if ok {
                                vm.scan(includeSystem: includeSystem)
                            }
                        }
                    }
                }
                .disabled(vm.isScanning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.appChrome)
    }

    var scriptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Script")
                .font(.system(size: 13, weight: .semibold))
            Text("Review every line before running.")
                .font(.system(size: 13))
                .foregroundColor(Color.appDim)
            ScrollView {
                Text(vm.generateScript())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.appText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelectionEnabled()
            }
            HStack {
                Button(scriptCopied ? "Copied" : "Copy") {
                    copyScriptToClipboard(vm.generateScript())
                }
                Spacer()
                Button("Close") { showScript = false }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }

    private var leftoverEmptyDetail: String {
        if !vm.searchText.isEmpty {
            return "No leftovers match this search."
        }
        let base = "No leftover data from uninstalled apps, and no PATH or desktop overlays hiding package-manager files."
        if vm.ignoredLeftovers.isEmpty { return base }
        return "\(base) \(ignoredCountLabel)"
    }

    private var ignoredCountLabel: String {
        let n = vm.ignoredLeftovers.count
        return n == 1 ? "1 leftover path hidden from the list." : "\(n) leftover paths hidden from the list."
    }

    private var visibleOrphanCount: Int {
        visibleOrphanedLeftovers(vm.scanData?.leftovers ?? [], ignoring: vm.ignoredLeftovers).count
    }

    func leftoverSizeLabel(_ item: LeftoverItem) -> String {
        if item.size_measured { return humanSize(item.size_bytes ?? 0) }
        if item.kind == "bundleid" || item.kind == "group"
            || item.root == "Containers" || item.root == "Group Containers" || item.root == "WebKit"
        {
            return "protected"
        }
        return "unknown"
    }

    func packageSizeLabel(_ item: PackageEntry) -> String {
        if item.size_measured { return humanSize(item.size_bytes ?? 0) }
        return "unknown"
    }

    func staleSizeLabel(_ item: SoftwareItem) -> String {
        staleSizeText(
            sizeBytes: item.size_bytes ?? 0,
            sizeMeasured: item.size_measured != false,
            dataBytes: item.data_bytes ?? 0
        )
    }

    private var visibleOrphanedBytes: Int {
        visibleOrphanedLeftovers(vm.scanData?.leftovers ?? [], ignoring: vm.ignoredLeftovers)
            .reduce(0) { addBytes($0, $1.size_bytes ?? 0) }
    }

    private var includeSystemBinding: Binding<Bool> {
        Binding(
            get: { includeSystem },
            set: { value in
                includeSystem = value
                persistSettings()
                vm.scan(includeSystem: value)
            }
        )
    }

    private var confirmDeleteBinding: Binding<Bool> {
        Binding(
            get: { confirmDelete },
            set: { value in
                confirmDelete = value
                persistSettings()
            }
        )
    }

    func persistSettings() {
        if settingsLoadFailed {
            vm.errorMessage = settingsLoadError
            return
        }
        do {
            try saveSettings(
                AppAtticSettings(
                    includeSystem: includeSystem,
                    confirmDelete: confirmDelete,
                    ignoredLeftoverPaths: vm.ignoredLeftovers.sorted()
                )
            )
            if vm.holdsSettingsError {
                vm.holdsSettingsError = false
                vm.errorMessage = nil
            }
        } catch {
            vm.errorMessage = settingsErrorUserMessage(error)
            vm.holdsSettingsError = true
        }
    }

    func ignoredPathLabel(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" {
            return name.isEmpty ? path : name
        }
        return parent + "/" + name
    }

    func copyScriptToClipboard(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                vm.errorMessage = "Could not copy the script."
                scriptCopied = false
            } else {
                scriptCopied = true
            }
        } catch {
            vm.errorMessage = "Could not copy the script."
            scriptCopied = false
        }
    }

    func leftoverToggle(_ path: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedLeftovers.contains(path) },
            set: { on in vm.setLeftoverSelected(path, on) }
        )
    }

    func staleToggle(_ path: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedApps.contains(path) },
            set: { on in vm.setAppSelected(path, on) }
        )
    }

    func outdatedToggle(_ id: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedOutdated.contains(id) },
            set: { on in vm.setOutdatedSelected(id, on) }
        )
    }

    func packageToggle(_ id: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedPackages.contains(id) },
            set: { on in vm.setPackageSelected(id, on) }
        )
    }

    func markManualToggle(_ id: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedMarkManual.contains(id) },
            set: { on in vm.setMarkManualSelected(id, on) }
        )
    }

    func selectAllLeftovers() {
        vm.selectedLeftovers = toggleListedSelection(
            selected: vm.selectedLeftovers,
            visible: leftoverRows.map(\.path)
        )
    }

    func selectAllStale() {
        vm.selectedApps = toggleListedSelection(
            selected: vm.selectedApps,
            visible: staleRows.filter { selectableCleanupTiers.contains($0.tier ?? "") }.map(\.path)
        )
    }

    func selectAllOutdated() {
        vm.selectedOutdated = toggleListedSelection(
            selected: vm.selectedOutdated,
            visible: outdatedRows.filter(\.updatable).map(\.id)
        )
    }

    func selectAllPackages() {
        vm.selectedPackages = toggleListedSelection(
            selected: vm.selectedPackages,
            visible: packageRows.map(\.id)
        )
        if !packageRows.isEmpty {
            var keep = vm.selectedMarkManual
            for id in packageRows.map(\.id) {
                keep.remove(id)
            }
            vm.selectedMarkManual = keep
        }
    }

    private var canSelectAll: Bool {
        switch selected {
        case .leftovers:
            return !leftoverRows.isEmpty
        case .stale:
            return staleRows.contains { selectableCleanupTiers.contains($0.tier ?? "") }
        case .outdated:
            return outdatedRows.contains(where: \.updatable)
        case .packages:
            return !packageRows.isEmpty
        default:
            return false
        }
    }

    private var allVisibleSelected: Bool {
        switch selected {
        case .leftovers:
            return leftoverRows.allSatisfy { vm.selectedLeftovers.contains($0.path) }
        case .stale:
            let paths = staleRows.filter { selectableCleanupTiers.contains($0.tier ?? "") }.map(\.path)
            return !paths.isEmpty && paths.allSatisfy { vm.selectedApps.contains($0) }
        case .outdated:
            let ids = outdatedRows.filter(\.updatable).map(\.id)
            return !ids.isEmpty && ids.allSatisfy { vm.selectedOutdated.contains($0) }
        case .packages:
            return !packageRows.isEmpty && packageRows.allSatisfy { vm.selectedPackages.contains($0.id) }
        default:
            return false
        }
    }

    func toggleSelectAll() {
        switch selected {
        case .leftovers:
            selectAllLeftovers()
        case .stale:
            selectAllStale()
        case .outdated:
            selectAllOutdated()
        case .packages:
            selectAllPackages()
        default:
            break
        }
    }

    func displayTier(_ tier: String?) -> String {
        guard let tier, !tier.isEmpty else { return "-" }
        return tier.prefix(1).uppercased() + tier.dropFirst()
    }

    func tierColor(_ tier: String?) -> Color {
        switch tier {
        case "remove":
            return Color.appRed
        case "review":
            return Color.appYellow
        case "keep":
            return Color.appGreen
        default:
            return Color.appDim
        }
    }

    private var revealLabel: String {
        #if os(macOS)
        return "Show in Finder"
        #else
        return "Show in Files"
        #endif
    }

    func revealPath(_ path: String) {
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", path]
        #else
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [folder]
        #endif
        try? process.run()
    }
}
