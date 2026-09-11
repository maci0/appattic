import Foundation
import SwiftCrossUI
import AppAtticScan
#if canImport(AppKit)
import AppKit
#endif

private struct DiskRule: View {
    var body: some View {
        Color.appHairline
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

struct DiskUsageView: View {
    @State private var volumes: [DiskVolume] = listDiskVolumes()
    @State private var root: DiskUsageNode? = nil
    @State private var scanning = false
    @State private var status = ""
    @State private var path = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var allocated = true
    @State private var oneFileSystem = true
    @State private var selected: DiskUsageNode? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button("Scan Home") { scan(FileManager.default.homeDirectoryForCurrentUser.path) }
                    .disabled(scanning)
                Button("Scan File System") { scan("/") }
                    .disabled(scanning)
                Button("Scan Path") { scan(path) }
                    .disabled(scanning || path.isEmpty)
                TextField("Folder path", text: $path)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            DiskRule()
            if scanning {
                Text(status.isEmpty ? "Scanning" : status)
                    .font(.system(size: 13))
                    .foregroundColor(Color.appDim)
                    .padding(16)
                Spacer()
            } else if let root {
                HStack {
                    Text(root.path)
                        .font(.system(size: 13))
                    Spacer()
                    Text(humanSize(root.metric(allocatedSize: allocated)))
                        .font(.system(size: 13))
                        .foregroundColor(Color.appDim)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                DiskRule()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        diskRows(root, depth: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                DiskRule()
                HStack {
                    if let selected {
                        Button("Open") {
                            let url = URL(fileURLWithPath: selected.isDir ? selected.path : (selected.path as NSString).deletingLastPathComponent)
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                        Button("Move to Trash") {
                            trash(selected)
                        }
                    }
                    Spacer()
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(Color.appDim)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                Text("Devices")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(volumes.enumerated()), id: \.offset) { _, vol in
                            Button(action: { scan(vol.rootPath) }) {
                                HStack {
                                    Text(vol.name)
                                        .font(.system(size: 13))
                                        .foregroundColor(Color.appText)
                                    Spacer()
                                    Text(vol.rootPath)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.appDim)
                                    Text(humanSize(vol.bytesTotal))
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.appDim)
                                        .frame(width: 72, alignment: .trailing)
                                }
                                .padding(.vertical, 6)
                            }
                            DiskRule()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    func diskRows(_ node: DiskUsageNode, depth: Int) -> some View {
        diskRow(node, depth: depth)
        let kids = Array(node.children.prefix(40))
        ForEach(Array(kids.enumerated()), id: \.offset) { _, child in
            diskRows(child, depth: depth + 1)
        }
    }

    func diskRow(_ node: DiskUsageNode, depth: Int) -> some View {
        Button(action: { selected = node }) {
            HStack {
                Text(String(repeating: "  ", count: depth) + node.name)
                    .font(.system(size: 13))
                    .foregroundColor(selected?.path == node.path ? Color.appOnAccent : Color.appText)
                Spacer()
                Text(humanSize(node.metric(allocatedSize: allocated)))
                    .font(.system(size: 11))
                    .foregroundColor(selected?.path == node.path ? Color.appOnAccent : Color.appDim)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 3)
            .background(selected?.path == node.path ? Color.appBlue : Color.clear)
        }
    }

    func scan(_ rootPath: String) {
        scanning = true
        status = "Scanning \(rootPath)"
        path = rootPath
        let one = oneFileSystem
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = scanDiskUsage(root: rootPath, oneFileSystem: one)
            DispatchQueue.main.async {
                root = tree
                selected = tree
                scanning = false
                status = "\(humanSize(tree.metric(allocatedSize: allocated))) · \(tree.items) items"
            }
        }
    }

    func trash(_ node: DiskUsageNode) {
        let url = URL(fileURLWithPath: node.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let p = root?.path { scan(p) }
        } catch {
            status = error.localizedDescription
        }
    }
}
