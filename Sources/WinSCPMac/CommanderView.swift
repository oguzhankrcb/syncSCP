// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WinSCPCore

private let accent = Color(red: 0.16, green: 0.38, blue: 0.82)

struct CommanderView: View {
    @ObservedObject var model: CommanderModel

    var body: some View {
        VStack(spacing: 0) {
            sessionBar
            Divider()
            actionBar
            Divider()
            HSplitView {
                FilePane(model: model, side: .local)
                    .frame(minWidth: 350)
                FilePane(model: model, side: .remote)
                    .frame(minWidth: 350)
            }
            .layoutPriority(1)
            if model.showBottom {
                Divider()
                activityPanel.frame(height: 174)
            }
            Divider()
            functionBar
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $model.showConnection) { ConnectionSheet(model: model) }
        .sheet(item: $model.editor) { document in EditorSheet(model: model, document: document) }
        .sheet(isPresented: $model.showSync) { SynchronizationSheet(model: model) }
        .alert("Operation failed", isPresented: Binding(get: { model.error != nil && !model.showConnection && model.editor == nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sessionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.square.fill")
                .font(.system(size: 29, weight: .medium)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("WinSCP").font(.system(size: 17, weight: .semibold))
                Text("COMMUNITY PORT FOR macOS").font(.system(size: 9, weight: .medium)).tracking(1.25).foregroundStyle(.secondary)
            }
            Divider().frame(height: 31).padding(.horizontal, 8)
            if let site = model.currentSite, model.connected {
                HStack(spacing: 7) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Image(systemName: site.transferProtocol.isEncrypted ? "lock.shield" : "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text(site.displayName).font(.system(size: 12, weight: .medium))
                    Text(site.transferProtocol.shortTitle).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(model.connecting ? "Connecting…" : "No active session").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.connecting || model.operationBusy { ProgressView().controlSize(.small).padding(.trailing, 4) }
            Button { model.showConnection = true } label: { Label("New Session", systemImage: "plus") }
                .disabled(model.busy)
            if model.connected {
                Button { model.disconnect() } label: { Image(systemName: "eject") }.help("Disconnect")
                    .disabled(model.connecting || model.operationBusy)
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button { model.transfer(.upload) } label: { Label("Upload", systemImage: "arrow.up") }.disabled(!model.canUpload)
            Button { model.transfer(.download) } label: { Label("Download", systemImage: "arrow.down") }.disabled(!model.canDownload)
            Divider().frame(height: 18)
            Button { model.previewSynchronization() } label: { Label("Synchronize", systemImage: "arrow.triangle.2.circlepath") }.disabled(!model.connected || model.busy)
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy)
            Button { model.promptMkdir() } label: { Label("New Folder", systemImage: "folder.badge.plus") }.disabled(model.busy || (model.activeSide == .remote && !model.connected))
            Spacer(minLength: 8)
            Toggle(isOn: $model.showHidden) { Image(systemName: model.showHidden ? "eye" : "eye.slash") }
                .toggleStyle(.button).help("Show hidden files · ⌘⇧.")
            TextField("Filter files", text: $model.filter)
                .textFieldStyle(.roundedBorder).frame(width: 170)
                .accessibilityLabel("Filter files in both panels")
            Button { model.showBottom.toggle() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }.help("Toggle activity panel")
        }
        .buttonStyle(.borderless).font(.system(size: 12))
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var activityPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ForEach(BottomTab.allCases, id: \.self) { tab in
                    Button { model.bottomTab = tab } label: {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                            if tab == .queue && model.pendingCount > 0 {
                                Text("\(model.pendingCount)").font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(accent.opacity(0.12), in: Capsule())
                            }
                        }
                        .font(.system(size: 11, weight: model.bottomTab == tab ? .semibold : .regular))
                        .foregroundStyle(model.bottomTab == tab ? accent : .secondary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                if model.bottomTab == .queue {
                    Button("Clear finished") { model.clearCompleted() }.font(.system(size: 10)).buttonStyle(.plain).disabled(model.runningQueue)
                } else {
                    Button("Copy log") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.log.map(\.text).joined(separator: "\n"), forType: .string) }
                        .font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            Divider()
            if model.bottomTab == .queue {
                if model.jobs.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your transfers will appear here").font(.system(size: 12, weight: .medium))
                            Text("Select files, then choose Upload or Download.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.jobs) { job in
                                HStack(spacing: 12) {
                                    Image(systemName: job.direction == .upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(job.entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(job.detail).font(.system(size: 10)).foregroundStyle(job.state == .failed ? .red : .secondary).lineLimit(1).help(job.detail)
                                    }
                                    Spacer()
                                    if job.state == .running { ProgressView(value: job.fraction).frame(width: 130) }
                                    Text(job.state.rawValue).font(.system(size: 10)).foregroundStyle(job.state == .done ? .green : .secondary).frame(width: 78, alignment: .trailing)
                                    if job.state == .running || job.state == .waiting {
                                        Button { model.cancelJob(job.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel transfer")
                                    } else { Image(systemName: job.state == .done ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(job.state == .done ? .green : .secondary) }
                                }
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.log) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(line.date, style: .time).foregroundStyle(.tertiary).frame(width: 75, alignment: .leading)
                                    Text(line.text).foregroundStyle(line.isError ? .red : .secondary).textSelection(.enabled)
                                }.font(.system(size: 10, design: .monospaced)).id(line.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .onChange(of: model.log.count) { _ in if let id = model.log.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var functionBar: some View {
        HStack(spacing: 0) {
            actionKey("Edit", shortcut: "⌘E", icon: "pencil", disabled: model.busy || model.activeSelection.count != 1) { model.editSelected() }
            actionKey("Upload", shortcut: "⌘⇧U", icon: "arrow.up", disabled: !model.canUpload) { model.transfer(.upload) }
            actionKey("Download", shortcut: "⌘⇧D", icon: "arrow.down", disabled: !model.canDownload) { model.transfer(.download) }
            actionKey("Rename", shortcut: "⌘⇧R", icon: "character.cursor.ibeam", disabled: model.busy || model.activeSelection.count != 1) { model.promptRename() }
            actionKey("New Folder", shortcut: "⌘⇧N", icon: "folder.badge.plus", disabled: model.busy || (model.activeSide == .remote && !model.connected)) { model.promptMkdir() }
            actionKey("Delete", shortcut: "⌘⌫", icon: "trash", disabled: model.busy || model.activeSelection.isEmpty) { model.deleteSelected() }
        }.padding(.horizontal, 8).padding(.vertical, 8)
    }

    private func actionKey(_ title: String, shortcut: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
                Spacer(minLength: 4)
                Text(shortcut).foregroundStyle(.secondary).font(.system(size: 10))
            }.font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(model.connected ? .green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.status).lineLimit(1)
            Spacer()
            if model.connected {
                Image(systemName: model.currentSite?.transferProtocol.isEncrypted == true ? "lock.fill" : "exclamationmark.triangle")
                Text(model.currentSite?.transferProtocol.usesSSH == true ? "SSH encrypted" : model.currentSite?.transferProtocol.isEncrypted != true ? "Unencrypted \(model.currentSite?.transferProtocol.shortTitle ?? "")" : "TLS encrypted")
            }
            Text("Development preview · 0.4.0").padding(.leading, 14)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 7)
    }
}

struct FilePane: View {
    @ObservedObject var model: CommanderModel
    let side: PaneSide
    @State private var pathInput = ""
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name)]
    private var local: Bool { side == .local }
    private var path: String { local ? model.localPath : model.remotePath }
    private var selection: Binding<Set<String>> { local ? $model.localSelection : $model.remoteSelection }
    private var allEntries: [FileEntry] { local ? model.localEntries : model.remoteEntries }
    private var entries: [FileEntry] {
        allEntries.filter { (model.showHidden || !$0.isHidden) && (model.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(model.filter)) }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                for comparator in sortOrder {
                    let result = comparator.compare(left, right)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                return left.name < right.name
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            pathBar
            Divider()
            if !local && !model.connected { disconnected }
            else { fileTable }
            Divider()
            paneFooter
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { pathInput = path }
        .onChange(of: path) { pathInput = $0 }
        .onChange(of: selection.wrappedValue) { _ in model.activeSide = side }
        .simultaneousGesture(TapGesture().onEnded { model.activeSide = side })
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
                Image(systemName: local ? "laptopcomputer" : "server.rack").foregroundStyle(model.activeSide == side ? accent : .secondary)
                Text(local ? "LOCAL" : "REMOTE").font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Text(local ? "This Mac" : model.currentSite?.host ?? "Not connected").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(model.activeSide == side ? accent.opacity(0.045) : Color.clear)
    }

    private var pathBar: some View {
        HStack(spacing: 7) {
                Button { navigate(RemotePath.parent(path)) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(path == "/" || path.isEmpty || (!local && model.busy)).help("Parent directory")
                Image(systemName: "folder.fill").foregroundStyle(accent.opacity(0.7))
                TextField(local ? "Local path" : "Remote path", text: $pathInput)
                    .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
                    .onSubmit { navigate(pathInput) }.disabled(!local && (!model.connected || model.busy))
                    .accessibilityLabel(local ? "Local directory path" : "Remote directory path")
                if !path.isEmpty {
                    Button { navigate(path) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }.buttonStyle(.plain).help("Refresh this directory").disabled(model.busy)
                }
            }.padding(.horizontal, 13).padding(.vertical, 10)
    }

    private var fileTable: some View {
        Table(entries, selection: selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { entry in
                        HStack(spacing: 7) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : entry.isSymbolicLink ? "link" : "doc")
                                .foregroundStyle(entry.isDirectory ? accent.opacity(0.8) : .secondary)
                                .frame(width: 16)
                            Text(entry.name).lineLimit(1).help(entry.name)
                        }
                        .font(.system(size: 12))
                    }.width(min: 150, ideal: 240)
                    TableColumn("Size", value: \.size) { entry in
                        Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(min: 64, ideal: 76, max: 100)
                    TableColumn("Modified") { entry in
                        Text(entry.modified.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()) } ?? "—")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.width(min: 110, ideal: 138, max: 160)
                    TableColumn("Rights") { entry in
                        Text(entry.rights).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.width(min: 73, ideal: 80, max: 100)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Open / Edit") { if let entry = allEntries.first(where: { ids.contains($0.id) }) { model.open(entry, side: side) } }.disabled(ids.count != 1 || model.busy)
                    Button(local ? "Upload" : "Download") { model.activeSide = side; selection.wrappedValue = ids; model.transfer(local ? .upload : .download) }.disabled(!model.connected || ids.isEmpty || model.busy)
                    Divider()
                    Button("Rename…") { model.activeSide = side; selection.wrappedValue = ids; model.promptRename() }.disabled(ids.count != 1 || model.busy)
                    if !local {
                        Button("Permissions…") { model.activeSide = side; selection.wrappedValue = ids; model.promptPermissions() }.disabled(ids.count != 1 || model.busy || model.currentSite?.transferProtocol.usesWebDAV == true)
                    }
                    Button(local ? "Move to Trash…" : "Delete…") { model.activeSide = side; selection.wrappedValue = ids; model.deleteSelected() }.disabled(ids.isEmpty || model.busy)
                } primaryAction: { ids in
                    if let entry = allEntries.first(where: { ids.contains($0.id) }) { model.open(entry, side: side) }
                }
                .overlay {
                    if entries.isEmpty {
                        Text(model.filter.isEmpty ? "This folder is empty" : "No matching files")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
    }

    private var paneFooter: some View {
        HStack {
                Text("\(entries.count) items")
                Spacer()
                let count = selection.wrappedValue.count
                if count > 0 { Text("\(count) selected").foregroundStyle(accent) }
                else { Text(local ? "Local filesystem" : model.connected ? model.currentSite?.transferProtocol.title ?? "Remote filesystem" : "Connect to browse files") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var disconnected: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(accent.opacity(0.05)).frame(width: 82, height: 82)
                Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 32, weight: .light)).foregroundStyle(accent.opacity(0.7))
            }
            VStack(spacing: 7) {
                Text("Your server, beside your files").font(.system(size: 18, weight: .medium))
                Text("Connect over SFTP, SCP, FTP, FTPS, or WebDAV to manage your files.\nSSH keys, SSH agent, and password authentication.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            Button { model.showConnection = true } label: { Label("New Session", systemImage: "plus") }
                .buttonStyle(.borderedProminent).disabled(model.busy)
            if !model.sites.isEmpty {
                VStack(spacing: 9) {
                    Text("SAVED SITES").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.tertiary)
                    ForEach(model.sites.prefix(3)) { site in
                        Button { model.requestedSite = site; model.showConnection = true } label: {
                            Label(site.displayName, systemImage: "server.rack").font(.system(size: 11))
                        }.buttonStyle(.link).disabled(model.busy)
                    }
                }.padding(.top, 10)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func navigate(_ path: String) { model.activeSide = side; local ? model.navigateLocal(path) : model.navigateRemote(path) }
}
