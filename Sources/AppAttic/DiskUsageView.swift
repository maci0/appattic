import Foundation
import SwiftCrossUI
import AppAtticScan
#if canImport(AppKit)
import AppKit
#endif

struct DiskUsageView: View {
    @State private var volumes: [DiskVolume] = listDiskVolumes()
    @State private var root: DiskUsageNode? = nil
    @State private var scanning = false
    @State private var status = ""
    /// Reported once, by the next finished scan, next to its totals. A message
    /// set before a scan is replaced by the scan's own "Scanning ..." line, and
    /// the scan's result replaces that, so a notice has to wait for the result.
    @State private var notice = ""
    @State private var path = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var selected: DiskUsageNode? = nil
    /// Folders whose child list is past the cap and the user asked to see.
    @State private var expandedFolders: Set<String> = []
    /// The node waiting for the trash confirmation. Moving to Trash is not
    /// undoable from here, so the button arms this instead of deleting.
    @State private var pendingTrash: DiskUsageNode? = nil
    @State private var activeScan: ScanTicket? = nil

    /// A walk started before the one the user asked for last. Cancelled, not
    /// merely ignored: a full-tree walk holds its whole node tree until the
    /// main queue takes the result, so a superseded walk left running keeps that
    /// memory for the length of its own tree.
    private final class ScanTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.sm) {
                Button("Scan Home") { scan(FileManager.default.homeDirectoryForCurrentUser.path) }
                    .disabled(scanning)
                Button("Scan File System") { scan("/") }
                    .disabled(scanning)
                Button("Scan Path") { scan(path) }
                    .disabled(scanning || path.isEmpty)
                TextField("Folder path", text: $path)
                Spacer()
            }
            .padding(Metrics.lg)
            .padding(Metrics.sm)
            HRule()
            // A rescan (after a Trash, or a second root) keeps the tree on
            // screen under a progress line. Replacing the page with one line
            // of text took away the result the user was reading, and left a
            // blank pane with no way back.
            if scanning {
                HStack {
                    Text(status.isEmpty ? "Scanning…" : status)
                        .font(.system(size: TypeScale.body))
                        .foregroundColor(Color.appDim)
                    Spacer()
                    Button("Stop") { stopScan() }
                }
                .padding(.horizontal, Metrics.lg)
                .padding(.vertical, Metrics.sm)
                HRule()
            }
            if scanning && root == nil {
                Spacer()
            } else if let root {
                HStack {
                    Button("Devices") {
                        self.root = nil
                        self.selected = nil
                    }
                    Text(root.path)
                        .font(.system(size: TypeScale.body))
                    Spacer()
                    Text(humanSize(root.metric(allocatedSize: true)))
                        .font(.system(size: TypeScale.body))
                        .foregroundColor(Color.appDim)
                }
                .padding(Metrics.lg)
                .padding(Metrics.sm)
                HRule()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        diskRows(root, depth: 0)
                    }
                    .padding(Metrics.lg)
                    .padding(Metrics.sm)
                }
                HRule()
                HStack {
                    if let selected {
                        Button("Open") {
                            let url = URL(fileURLWithPath: selected.isDir ? selected.path : (selected.path as NSString).deletingLastPathComponent)
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                        // The tree under them is the one being replaced by the
                        // running scan, so acting on a row now would act on a
                        // result the window is about to redraw.
                        .disabled(scanning)
                        Button("Move to Trash") {
                            guard selected.path != root.path else { return }
                            pendingTrash = selected
                        }
                        .disabled(scanning || selected.path == root.path)
                    }
                    Spacer()
                    Text(status)
                        .font(.system(size: TypeScale.small))
                        .foregroundColor(Color.appDim)
                }
                .padding(Metrics.lg)
                .padding(Metrics.sm)
            } else {
                if let failure = diskDevicesStatus(status: status, scanning: scanning, hasRoot: false) {
                    Text(failure)
                        .font(.system(size: TypeScale.body))
                        .foregroundColor(Color.appRed)
                        .padding(Metrics.lg)
                        .padding(Metrics.sm)
                    HRule()
                }
                Text("Devices")
                    .font(.system(size: TypeScale.title, weight: .semibold))
                    .padding(Metrics.lg)
                    .padding(Metrics.md)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(volumes.enumerated()), id: \.offset) { _, vol in
                            Button(action: { scan(vol.rootPath) }) {
                                HStack {
                                    Text(vol.name)
                                        .font(.system(size: TypeScale.body))
                                        .foregroundColor(Color.appText)
                                    Spacer()
                                    Text(vol.rootPath)
                                        .font(.system(size: TypeScale.small))
                                        .foregroundColor(Color.appDim)
                                    Text(humanSize(vol.bytesTotal))
                                        .font(.system(size: TypeScale.small))
                                        .foregroundColor(Color.appDim)
                                        .frame(width: 72, alignment: .trailing)
                                }
                                .padding(Metrics.sm)
                            }
                            HRule()
                        }
                    }
                    .padding(Metrics.lg)
                }
            }
        }
        .alert(trashConfirmTitle, isPresented: trashConfirmBinding) {
            Button("Cancel") { pendingTrash = nil }
            Button("Move to Trash") {
                if let node = pendingTrash { trash(node) }
                pendingTrash = nil
            }
        }
    }

    /// The alert names the path, not only the last component: two rows can
    /// share a name. A folder says that its contents go with it.
    private var trashConfirmTitle: String {
        guard let node = pendingTrash else { return "Move to Trash?" }
        let whereTo = redactHomePaths(node.path)
        if node.isDir {
            return "Move \(whereTo) to Trash? Everything in it goes too."
        }
        return "Move \(whereTo) to Trash?"
    }

    private var trashConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingTrash != nil },
            set: { if !$0 { pendingTrash = nil } }
        )
    }

    /// Rows drawn per folder. The cap keeps a folder with thousands of entries
    /// from building thousands of views, but a silent cut reads as the whole
    /// folder, so the rest are counted in a closing row.
    private static let maxRowsPerFolder = 40

    @ViewBuilder
    func diskRows(_ node: DiskUsageNode, depth: Int) -> some View {
        diskRow(node, depth: depth)
        let expanded = expandedFolders.contains(node.path)
        let limit = expanded ? node.children.count : Self.maxRowsPerFolder
        let kids = Array(node.children.prefix(limit))
        ForEach(Array(kids.enumerated()), id: \.offset) { _, child in
            diskRows(child, depth: depth + 1)
        }
        let hidden = node.children.count - kids.count
        if hidden > 0 {
            Button(String(repeating: "  ", count: depth + 1) + "Show \(hidden) more") {
                expandedFolders.insert(node.path)
            }
        }
    }

    func diskRowLabel(_ node: DiskUsageNode) -> String {
        var label = node.name
        if node.unreadable { label += " (unreadable)" }
        if node.mountPoint { label += " (other file system)" }
        return label
    }

    func diskRow(_ node: DiskUsageNode, depth: Int) -> some View {
        Button(action: { selected = node }) {
            HStack {
                Text(String(repeating: "  ", count: depth) + diskRowLabel(node))
                    .font(.system(size: TypeScale.body))
                    .foregroundColor(selected?.path == node.path ? Color.appOnAccent : Color.appText)
                Spacer()
                Text(humanSize(node.metric(allocatedSize: true)))
                    .font(.system(size: TypeScale.small))
                    .foregroundColor(selected?.path == node.path ? Color.appOnAccent : Color.appDim)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(Metrics.xs)
            .background(selected?.path == node.path ? Color.appBlue : Color.clear)
        }
    }

    func scan(_ rootPath: String) {
        activeScan?.cancel()
        let ticket = ScanTicket()
        activeScan = ticket
        scanning = true
        status = "Scanning \(redactHomePaths(rootPath))"
        path = rootPath
        DispatchQueue.global(qos: .userInitiated).async {
            // A missing path used to come back as an unreadable node whose
            // total read as 0 B. Name the problem and do not install that tree.
            do {
                try validateDiskRoot(rootPath)
            } catch {
                DispatchQueue.main.async {
                    guard activeScan === ticket else { return }
                    activeScan = nil
                    scanning = false
                    root = nil
                    selected = nil
                    expandedFolders = []
                    status = (error as? LocalizedError)?.errorDescription ?? redactHomePaths(String(describing: error))
                }
                return
            }
            // One file system: the root is the volume the user picked, and its
            // siblings are separate volumes the walk would double count.
            let tree = scanDiskUsage(root: rootPath, oneFileSystem: true, cancel: { ticket.isCancelled })
            DispatchQueue.main.async {
                // A scan that a newer one superseded says nothing: the newer
                // run owns the state and will write it.
                guard activeScan === ticket else { return }
                activeScan = nil
                root = tree
                // The scan root is the whole walk. Leaving it selected armed
                // Move to Trash for every file under it.
                selected = nil
                expandedFolders = []
                // The device list is read once when the view state is created,
                // so a scan that freed or filled a volume would leave it
                // showing the sizes it had then. `listDiskVolumes` is the
                // mounted-volume list plus a capacity read per volume, cheap
                // enough to redo whenever the tree is re-measured.
                volumes = listDiskVolumes()
                scanning = false
                // A cancelled walk returns what it measured so far, so the tree
                // is real but partial. Printing the same totals a finished scan
                // prints would read as the whole disk.
                let stopped = ticket.isCancelled
                var totals = "\(humanSize(tree.metric(allocatedSize: true))) · \(diskFolderContentsLabel(items: tree.items, unreadable: tree.unreadable))"
                if tree.reportsPartialTotal() {
                    totals += " · some folders could not be read"
                }
                status = [stopped ? "Scan stopped" : nil, notice, totals]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                notice = ""
            }
        }
    }

    /// A stop returns the folders already measured rather than nothing, and
    /// says the totals are partial, so the user can act on them or rescan.
    func stopScan() {
        guard scanning, let ticket = activeScan else { return }
        ticket.cancel()
        notice = "stopped early, totals are partial"
    }

    func trash(_ node: DiskUsageNode) {
        guard node.path != root?.path else { return }
        let url = URL(fileURLWithPath: node.path)
        let name = node.name
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            notice = "Moved \(name) to Trash"
            if let p = root?.path {
                scan(p)
            } else {
                status = notice
                notice = ""
            }
        } catch {
            // A bare NSError description ("The file doesn't exist.") names no
            // action and no path, so the user is left guessing which row failed.
            status = "Could not move \(name) to Trash: "
                + redactHomePaths(error.localizedDescription)
        }
    }
}
