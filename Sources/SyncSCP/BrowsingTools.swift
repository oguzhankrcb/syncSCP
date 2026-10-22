// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SyncSCPCore

/// WinSCP's Properties for one or more remote items: rwx for owner, group and others, an octal
/// field that stays in step, and optional recursion into folders.
struct PermissionsSheet: View {
    @ObservedObject var model: CommanderModel
    let entries: [FileEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt32 = 0o644
    @State private var octal = "644"
    @State private var recursive = false
    @State private var addExecuteToFolders = true

    private let classes = [("Owner", UInt32(6)), ("Group", UInt32(3)), ("Others", UInt32(0))]
    private let bits = [("Read", UInt32(4)), ("Write", UInt32(2)), ("Execute", UInt32(1))]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entries.count == 1 ? "Permissions of \(entries[0].name)" : "Permissions of \(entries.count) items").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text(""); ForEach(bits, id: \.0) { Text($0.0).foregroundStyle(.secondary) } }
                ForEach(classes, id: \.0) { name, shift in
                    GridRow {
                        Text(name)
                        ForEach(bits, id: \.0) { _, bit in
                            Toggle("", isOn: Binding(get: { mode & (bit << shift) != 0 }, set: { on in
                                mode = on ? mode | (bit << shift) : mode & ~(bit << shift); octal = String(mode, radix: 8)
                            })).labelsHidden().toggleStyle(.checkbox)
                        }
                    }
                }
            }.font(.system(size: 12.5))
            HStack {
                Text("Octal")
                TextField("644", text: $octal).frame(width: 70).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .onChange(of: octal) { value in if let parsed = UInt32(value, radix: 8), parsed <= 0o777 { mode = parsed } }
                Text(FileEntry(path: "", name: "", permissions: 0o100000 | mode).rights).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            if entries.contains(where: \.isDirectory) {
                Toggle("Apply to everything inside the selected folders", isOn: $recursive).toggleStyle(.checkbox)
                Toggle("Add execute to folders that can be read (so they stay openable)", isOn: $addExecuteToFolders).toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.permissionsTarget = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.applyPermissions(entries, mode: mode, recursive: recursive, addExecuteToFolders: addExecuteToFolders) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(UInt32(octal, radix: 8).map { $0 > 0o777 } ?? true)
            }
        }
        .padding(22).frame(width: 440)
        .onAppear {
            let known = entries.first { $0.permissionsKnown }
            mode = (known?.permissions ?? 0o644) & 0o777; octal = String(mode, radix: 8)
        }
    }
}

/// WinSCP's Find Files: a recursive search of the server by name masks.
struct FindFilesSheet: View {
    @ObservedObject var model: CommanderModel
    @State private var masks = "*"
    @State private var folder = ""
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Files").font(.title3.weight(.semibold))
            HStack {
                TextField("Name masks, e.g. *.log; nginx*.conf", text: $masks).onSubmit(search)
                TextField("Search in", text: $folder).frame(width: 260)
                if model.findRunning { Button("Stop") { model.stopFindingFiles() } }
                else { Button("Search", action: search).keyboardShortcut(.defaultAction).disabled(!model.connected || model.busy) }
            }.textFieldStyle(.roundedBorder)
            Table(model.findResults, selection: $selection) {
                TableColumn("Name") { entry in Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc").lineLimit(1) }.width(min: 140, ideal: 200)
                TableColumn("Folder") { entry in Text(RemotePath.parent(entry.path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                TableColumn("Size") { entry in Text(entry.isDirectory ? "" : FileType.size(entry.size)).monospacedDigit() }.width(80)
                TableColumn("Changed") { entry in Text(entry.modified?.formatted(date: .numeric, time: .shortened) ?? "") }.width(130)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let entry = model.findResults.first(where: { ids.contains($0.path) }) { model.reveal(entry) }
            }
            .frame(height: 320)
            HStack {
                Text(model.findStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Panel") { if let entry = model.findResults.first(where: { $0.path == selection }) { model.reveal(entry) } }.disabled(selection == nil || model.findRunning)
                Button("Close") { model.stopFindingFiles(); model.showFindFiles = false }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 12.5)).padding(20).frame(width: 820)
        .onAppear { if folder.isEmpty { folder = model.remotePath } }
    }

    private func search() { model.findFiles(masks: masks, in: folder.isEmpty ? model.remotePath : folder) }
}

/// The folder tree beside a pane (WinSCP's directory tree): loaded lazily, following the current folder.
struct DirectoryTree: View {
    @ObservedObject var model: CommanderModel
    let side: PaneSide
    let current: String
    let navigate: (String) -> Void
    @StateObject private var store = TreeStore()

    var body: some View {
        ScrollViewReader { proxy in
            List { TreeNode(store: store, path: "/", name: "/", depth: 0, current: current, navigate: navigate) }
                .listStyle(.sidebar)
                .onAppear { reveal(current, proxy) }
                .onChange(of: current) { reveal($0, proxy) }
        }
        .environment(\.defaultMinListRowHeight, 20)
        .onAppear { store.loader = { [weak model] path in await model?.subfolders(of: path, side: side) ?? [] } }
    }

    private func reveal(_ path: String, _ proxy: ScrollViewProxy) {
        var chain = ["/"], folder = ""
        for part in path.split(separator: "/") { folder += "/" + part; chain.append(folder) }
        Task {
            for folder in chain.dropLast() { await store.expand(folder) }
            proxy.scrollTo(path, anchor: .center)
        }
    }
}

@MainActor
final class TreeStore: ObservableObject {
    @Published var children: [String: [FileEntry]] = [:]
    @Published var expanded = Set<String>()
    var loader: ((String) async -> [FileEntry])?

    func expand(_ path: String) async {
        expanded.insert(path)
        if children[path] == nil, let loader { children[path] = await loader(path) }
    }
    func toggle(_ path: String) { if expanded.contains(path) { expanded.remove(path) } else { Task { await expand(path) } } }
}

private struct TreeNode: View {
    @ObservedObject var store: TreeStore
    let path: String
    let name: String
    let depth: Int
    let current: String
    let navigate: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { store.toggle(path) } label: {
                Image(systemName: store.expanded.contains(path) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Image(systemName: "folder.fill").foregroundStyle(accent.opacity(0.8)).font(.system(size: 11))
            Text(name).lineLimit(1).fontWeight(path == current ? .semibold : .regular)
        }
        .font(.system(size: 12)).padding(.leading, CGFloat(depth) * 12)
        .listRowBackground(path == current ? accent.opacity(0.15) : Color.clear)
        .contentShape(Rectangle()).onTapGesture { navigate(path) }
        .id(path)
        if store.expanded.contains(path) {
            ForEach(store.children[path] ?? []) { child in
                TreeNode(store: store, path: child.path, name: child.name, depth: depth + 1, current: current, navigate: navigate)
            }
        }
    }
}
