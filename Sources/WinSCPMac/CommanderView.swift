// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WinSCPCore

/// WinSCP's Commander layout with a native macOS finish: toolbar, session tab, two panes
/// with their own navigation and action bars, a queue/log panel and a status bar.
let accent = Color(red: 0.17, green: 0.42, blue: 0.85)
private let chrome = Color(nsColor: .windowBackgroundColor)
private let surface = Color(nsColor: .controlBackgroundColor)
private let barShade = Color.primary.opacity(0.035)

struct CommanderView: View {
    @ObservedObject var model: CommanderModel

    var body: some View {
        VStack(spacing: 0) {
            mainToolbar
            Divider()
            sessionTabs
            Divider()
            HSplitView {
                FilePane(model: model, side: .local).frame(minWidth: 380)
                FilePane(model: model, side: .remote).frame(minWidth: 380)
            }
            .layoutPriority(1)
            if model.showBottom {
                Divider()
                QueuePanel(model: model).frame(height: 150)
            }
            Divider()
            statusBar
        }
        .background(chrome)
        .tint(accent)
        .sheet(isPresented: $model.showConnection) { ConnectionSheet(model: model) }
        .sheet(item: $model.editor) { document in EditorSheet(model: model, document: document) }
        .sheet(isPresented: $model.showSync) { SynchronizationSheet(model: model) }
        .sheet(isPresented: $model.showImport) { ImportSheet(model: model) }
        .alert("Operation failed", isPresented: Binding(get: { model.error != nil && !model.showConnection && model.editor == nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var mainToolbar: some View {
        HStack(spacing: 4) {
            ToolButton(title: "New Session", icon: "plus") { model.showConnection = true }.disabled(model.busy)
            ToolDivider()
            ToolButton(title: "Synchronize", icon: "arrow.triangle.2.circlepath") { model.previewSynchronization() }
                .disabled(!model.connected || model.busy).help("Synchronize · ⌘⇧S")
            Menu {
                Toggle("Show Queue Panel", isOn: $model.showBottom)
                Button("Show Session Log") { model.bottomTab = .log; model.showBottom = true }
                Divider()
                Button("Clear Finished Transfers") { model.clearCompleted() }.disabled(model.runningQueue)
            } label: {
                Label(model.pendingCount > 0 ? "Queue (\(model.pendingCount))" : "Queue", systemImage: "list.bullet.rectangle")
            }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8)
            ToolButton(title: "Refresh", icon: "arrow.clockwise") { model.refresh() }.disabled(model.busy).help("Refresh both panels · ⌘R")
            Spacer(minLength: 12)
            Toggle(isOn: $model.showHidden) { Image(systemName: model.showHidden ? "eye" : "eye.slash") }
                .toggleStyle(.button).buttonStyle(.borderless).help("Show hidden files · ⌘⇧.")
                .accessibilityLabel("Show hidden files")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter both panels", text: $model.filter).textFieldStyle(.plain)
                    .accessibilityLabel("Filter files in both panels")
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear filter")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 9).frame(width: 230, height: 26)
            .background(surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 12).frame(height: 44).background(barShade)
    }

    private var sessionTabs: some View {
        HStack(alignment: .bottom, spacing: 2) {
            if let site = model.currentSite, model.connected {
                HStack(spacing: 8) {
                    if let color = SiteColor.color(site.settings.color) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 14).help("Site color")
                    }
                    Image(systemName: site.transferProtocol.isEncrypted ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(site.transferProtocol.isEncrypted ? Color.green : Color.orange)
                    Text(site.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(site.transferProtocol.shortTitle).font(.system(size: 9.5, weight: .bold)).tracking(0.4)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(accent).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Button { model.disconnect() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Disconnect")
                        .disabled(model.connecting || model.operationBusy).accessibilityLabel("Disconnect")
                }
                .padding(.horizontal, 13).frame(height: 29)
                .background(chrome, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).stroke(Color.primary.opacity(0.12)))
                .help(site.settings.note.isEmpty ? "\(site.username)@\(site.host):\(site.port)" : site.settings.note)
            } else {
                HStack(spacing: 7) {
                    if model.connecting { ProgressView().controlSize(.small); Text("Connecting…") } else { Text("No session") }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 13).frame(height: 28)
            }
            Button { model.showConnection = true } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.borderless).frame(width: 28, height: 28).help("New Session · ⌘N").disabled(model.busy)
                .accessibilityLabel("New session")
            Spacer()
            if model.operationBusy { ProgressView().controlSize(.small).padding(.bottom, 6) }
        }
        .padding(.horizontal, 10).frame(height: 34).background(Color.primary.opacity(0.06))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let site = model.currentSite, model.connected {
                Label(site.transferProtocol.usesSSH ? "Host key verified" : site.transferProtocol.isEncrypted ? "TLS certificate verified" : "Unencrypted connection",
                      systemImage: site.transferProtocol.isEncrypted ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(site.transferProtocol.isEncrypted ? Color.primary : Color.orange)
                Text(site.transferProtocol.title)
                ForEach(details(site), id: \.self) { Text($0) }
            } else {
                Text(model.status).lineLimit(1)
            }
            Spacer()
            if model.connected, let start = model.connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Connected " + duration(context.date.timeIntervalSince(start))).monospacedDigit()
                }
            }
            Text("Development preview · 0.8.0").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 14).frame(height: 26).background(barShade)
    }

    private func details(_ site: Site) -> [String] {
        var result: [String] = []
        if site.transferProtocol == .scp, !site.settings.shell.isEmpty { result.append("Shell: \(site.settings.shell)") }
        if site.transferProtocol == .sftp, !site.settings.sftpServer.isEmpty { result.append("Server: \(site.settings.sftpServer)") }
        if site.settings.tunnel { result.append("Tunnel: \(site.settings.tunnelHost)") }
        if site.settings.proxyMethod != .none { result.append("Proxy: \(site.settings.proxyMethod.rawValue.uppercased())") }
        return result
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

struct ToolButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}

private struct ToolDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 4) }
}

private struct IconButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

struct QueuePanel: View {
    @ObservedObject var model: CommanderModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                tab(.queue, title: "Queue", count: model.pendingCount)
                tab(.log, title: "Log", count: 0)
                Spacer()
                if model.bottomTab == .queue {
                    Button("Clear finished") { model.clearCompleted() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.runningQueue)
                } else {
                    Button("Copy log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.log.map(\.text).joined(separator: "\n"), forType: .string)
                    }.buttonStyle(.borderless).font(.system(size: 11))
                }
                Button { model.showBottom = false } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("Hide panel")
                    .accessibilityLabel("Hide queue panel")
            }
            .padding(.horizontal, 14).frame(height: 30)
            Divider()
            if model.bottomTab == .queue { queue } else { log }
        }
        .background(surface)
    }

    private func tab(_ value: BottomTab, title: String, count: Int) -> some View {
        Button { model.bottomTab = value } label: {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(accent.opacity(0.14), in: Capsule())
                }
            }
            .font(.system(size: 12, weight: model.bottomTab == value ? .semibold : .regular))
            .foregroundStyle(model.bottomTab == value ? accent : .secondary)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var queue: some View {
        if model.jobs.isEmpty {
            Text("Transfers appear here. Select files, then choose Upload or Download.")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                        HStack(spacing: 12) {
                            Image(systemName: job.direction == .upload ? "arrow.up" : "arrow.down")
                                .foregroundStyle(job.state == .running ? accent : .secondary).frame(width: 16)
                            Text(job.entry.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(job.destination).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).help(job.destination)
                            ProgressView(value: job.state == .done ? 1 : job.fraction).frame(width: 180)
                                .opacity(job.state == .running || job.state == .done ? 1 : 0.35)
                            Text(job.state == .running ? "\(Int(job.fraction * 100))%" : job.state.rawValue)
                                .monospacedDigit().foregroundStyle(job.state == .failed ? .red : job.state == .done ? .green : .secondary)
                                .frame(width: 90, alignment: .trailing).help(job.detail)
                            if job.state == .running || job.state == .waiting {
                                Button { model.cancelJob(job.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).help("Cancel transfer").accessibilityLabel("Cancel \(job.entry.name)")
                            } else { Color.clear.frame(width: 16) }
                        }
                        .font(.system(size: 12)).padding(.horizontal, 14).frame(height: 28)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    }
                }
            }
        }
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.log) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.date, style: .time).foregroundStyle(.tertiary).frame(width: 75, alignment: .leading)
                            Text(line.text).foregroundStyle(line.isError ? .red : .secondary).textSelection(.enabled)
                        }.font(.system(size: 11, design: .monospaced)).id(line.id)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .onChange(of: model.log.count) { _ in if let id = model.log.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
}

struct FilePane: View {
    @ObservedObject var model: CommanderModel
    let side: PaneSide
    @State private var pathInput = ""
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name)]
    private var local: Bool { side == .local }
    private var active: Bool { model.activeSide == side }
    private var path: String { local ? model.localPath : model.remotePath }
    private var selection: Binding<Set<String>> { local ? $model.localSelection : $model.remoteSelection }
    private var allEntries: [FileEntry] { local ? model.localEntries : model.remoteEntries }
    private var visible: [FileEntry] {
        allEntries.filter { (model.showHidden || !$0.isHidden) && (model.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(model.filter)) }
    }
    private var entries: [FileEntry] {
        visible.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            for comparator in sortOrder {
                let result = comparator.compare(left, right)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return left.name < right.name
        }
    }
    private var usable: Bool { local || model.connected }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            actionBar
            Divider()
            pathStrip
            if !usable { disconnected } else { fileTable }
            Divider()
            footer
        }
        .background(surface)
        .overlay(alignment: .top) { if active { Rectangle().fill(accent).frame(height: 2) } }
        .onAppear { pathInput = path }
        .onChange(of: path) { pathInput = $0 }
        .onChange(of: selection.wrappedValue) { _ in model.activeSide = side }
        .simultaneousGesture(TapGesture().onEnded { model.activeSide = side })
    }

    private var navigationBar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: local ? "folder.fill" : "externaldrive.connected.to.line.below")
                    .font(.system(size: 11)).foregroundStyle(accent.opacity(0.8))
                TextField(local ? "Local folder" : "Remote folder", text: $pathInput)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { navigate(pathInput) }.disabled(!usable || (!local && model.busy))
                    .accessibilityLabel(local ? "Local folder path" : "Remote folder path")
                Menu {
                    ForEach(ancestors, id: \.self) { folder in Button(folder) { navigate(folder) } }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!usable || path.isEmpty)
                    .accessibilityLabel("Parent folders")
            }
            .padding(.horizontal, 8).frame(height: 26).frame(maxWidth: 420)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            ToolDivider()
            IconButton(icon: "chevron.left", label: "Back") { model.activeSide = side; model.goBack(side) }
                .disabled(!model.canGoBack(side) || !usable || (!local && model.busy))
            IconButton(icon: "chevron.right", label: "Forward") { model.activeSide = side; model.goForward(side) }
                .disabled(!model.canGoForward(side) || !usable || (!local && model.busy))
            IconButton(icon: "arrow.up", label: "Parent folder") { navigate(RemotePath.parent(path)) }
                .disabled(path == "/" || path.isEmpty || !usable || (!local && model.busy))
            IconButton(icon: "slash.circle", label: "Root folder") { navigate("/") }
                .disabled(path == "/" || !usable || (!local && model.busy))
            IconButton(icon: "house", label: "Home folder") { model.activeSide = side; model.goHome(side) }
                .disabled(!usable || (!local && model.busy))
            IconButton(icon: "arrow.clockwise", label: "Refresh") { navigate(path) }
                .disabled(path.isEmpty || !usable || (!local && model.busy))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 36).background(barShade)
    }

    private var ancestors: [String] {
        var result: [String] = [], current = path
        while !current.isEmpty, current != "/" { current = RemotePath.parent(current); result.append(current) }
        return result
    }

    private var actionBar: some View {
        let one = selection.wrappedValue.count == 1, any = !selection.wrappedValue.isEmpty
        let selected = allEntries.filter { selection.wrappedValue.contains($0.id) }
        return HStack(spacing: 0) {
            if local {
                ToolButton(title: "Upload", icon: "arrow.up") { act { model.transfer(.upload) } }.disabled(!model.canUpload)
            } else {
                ToolButton(title: "Download", icon: "arrow.down") { act { model.transfer(.download) } }.disabled(!model.canDownload)
            }
            ToolButton(title: local ? "Open" : "Edit", icon: local ? "arrow.up.forward.app" : "pencil") { act { model.editSelected() } }
                .disabled(!one || model.busy || selected.first?.isDirectory == true)
            ToolButton(title: local ? "Trash" : "Delete", icon: "trash", role: .destructive) { act { model.deleteSelected() } }
                .disabled(!any || model.busy)
            ToolButton(title: "Rename", icon: "character.cursor.ibeam") { act { model.promptRename() } }.disabled(!one || model.busy)
            if local {
                ToolButton(title: "Show in Finder", icon: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting(selected.isEmpty ? [URL(fileURLWithPath: path)] : selected.map { URL(fileURLWithPath: $0.path) })
                }
            } else {
                ToolButton(title: "Properties", icon: "info.circle") { act { model.promptPermissions() } }
                    .disabled(!one || model.busy || model.currentSite?.transferProtocol.supportsPermissions == false)
                    .help(model.currentSite?.transferProtocol.supportsPermissions == false ? "This protocol has no POSIX permissions." : "Edit permissions")
            }
            ToolButton(title: "New Folder", icon: "folder.badge.plus") { act { model.promptMkdir() } }.disabled(!usable || model.busy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).frame(height: 32).disabled(!usable)
    }

    private var pathStrip: some View {
        Text(path.isEmpty ? (local ? "" : "Not connected") : path)
            .font(.system(size: 12, weight: active ? .semibold : .regular, design: .monospaced))
            .lineLimit(1).truncationMode(.head).textSelection(.enabled)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
            .background(active ? accent : Color.primary.opacity(0.05))
    }

    private var nameColumn: TableColumn<FileEntry, KeyPathComparator<FileEntry>, some View, Text> {
        TableColumn("Name", value: \.name) { entry in
            HStack(spacing: 7) {
                Image(systemName: entry.isDirectory ? "folder.fill" : entry.isSymbolicLink ? "link" : "doc")
                    .foregroundStyle(entry.isDirectory ? accent.opacity(0.85) : .secondary).frame(width: 16)
                Text(entry.name).lineLimit(1).help(entry.name)
            }
        }
    }
    private var sizeColumn: TableColumn<FileEntry, KeyPathComparator<FileEntry>, some View, Text> {
        TableColumn("Size", value: \.size) { entry in
            Text(entry.isDirectory ? "" : FileType.size(entry.size))
                .monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    private var changedColumn: TableColumn<FileEntry, Never, some View, Text> {
        TableColumn("Changed") { entry in
            Text(entry.modified.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()) } ?? "")
                .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Local: Name, Size, Type, Changed. Remote: Name, Size, Changed, Rights — as in WinSCP.
    @ViewBuilder private var fileTable: some View {
        if local {
            decorated(Table(entries, selection: selection, sortOrder: $sortOrder) {
                nameColumn.width(min: 160, ideal: 280)
                sizeColumn.width(min: 60, ideal: 80, max: 110)
                TableColumn("Type") { entry in Text(FileType.describe(entry)).foregroundStyle(.secondary).lineLimit(1) }.width(min: 70, ideal: 130, max: 190)
                changedColumn.width(min: 110, ideal: 140, max: 170)
            })
        } else {
            decorated(Table(entries, selection: selection, sortOrder: $sortOrder) {
                nameColumn.width(min: 160, ideal: 280)
                sizeColumn.width(min: 60, ideal: 80, max: 110)
                changedColumn.width(min: 110, ideal: 140, max: 170)
                TableColumn("Rights") { entry in
                    Text(entry.rights).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.width(min: 80, ideal: 90, max: 110)
            })
        }
    }

    private func decorated<T: View>(_ table: T) -> some View {
        table
        .font(.system(size: 12.5))
        .contextMenu(forSelectionType: String.self) { ids in
            Button(local ? "Open" : "Open / Edit") { if let entry = allEntries.first(where: { ids.contains($0.id) }) { model.open(entry, side: side) } }
                .disabled(ids.count != 1 || model.busy)
            Button(local ? "Upload" : "Download") { model.activeSide = side; selection.wrappedValue = ids; model.transfer(local ? .upload : .download) }
                .disabled(!model.connected || ids.isEmpty || model.busy)
            Divider()
            Button("Rename…") { model.activeSide = side; selection.wrappedValue = ids; model.promptRename() }.disabled(ids.count != 1 || model.busy)
            if !local {
                Button("Properties…") { model.activeSide = side; selection.wrappedValue = ids; model.promptPermissions() }
                    .disabled(ids.count != 1 || model.busy || model.currentSite?.transferProtocol.supportsPermissions == false)
            }
            Button(local ? "Move to Trash…" : "Delete…") { model.activeSide = side; selection.wrappedValue = ids; model.deleteSelected() }
                .disabled(ids.isEmpty || model.busy)
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

    /// WinSCP's "0 B of 34.9 MB in 0 of 40" summary.
    private var footer: some View {
        let chosen = visible.filter { selection.wrappedValue.contains($0.id) }
        let size: ([FileEntry]) -> String = { FileType.size($0.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 &+ $1.size }) }
        let hidden = model.showHidden ? 0 : allEntries.filter(\.isHidden).count
        return HStack {
            if usable {
                Text("\(size(chosen)) of \(size(visible)) in \(chosen.count) of \(visible.count)").monospacedDigit()
                if hidden > 0 { Text("· \(hidden) hidden") }
            } else { Text("Connect to browse remote files") }
            Spacer()
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24).background(barShade)
    }

    private var disconnected: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.7))
            Text("No remote session").font(.system(size: 16, weight: .medium))
            Text("SFTP, SCP, FTP/FTPS, WebDAV and S3").font(.system(size: 12)).foregroundStyle(.secondary)
            Button { model.showConnection = true } label: { Label("New Session", systemImage: "plus") }
                .buttonStyle(.borderedProminent).disabled(model.busy)
            if !model.sites.isEmpty {
                VStack(spacing: 7) {
                    Text("SAVED SITES").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    ForEach(model.sites.prefix(4)) { site in
                        Button { model.requestedSite = site; model.showConnection = true } label: {
                            Label { Text(site.displayName) } icon: { Image(systemName: "server.rack").foregroundStyle(SiteColor.color(site.settings.color) ?? accent) }
                                .font(.system(size: 12))
                        }.buttonStyle(.link).disabled(model.busy)
                    }
                }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func act(_ action: () -> Void) { model.activeSide = side; action() }
    private func navigate(_ target: String) { model.activeSide = side; local ? model.navigateLocal(target) : model.navigateRemote(target) }
}

enum FileType {
    static func size(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    /// Finder-style kind ("Folder", "Plain Text Document", "ZIP archive"…), falling back to "EXT file".
    static func describe(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "Folder" }
        if entry.isSymbolicLink { return "Symbolic link" }
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty, !entry.name.hasPrefix(".") || entry.name.dropFirst().contains(".") else { return "File" }
        if let type = UTType(filenameExtension: ext), !type.isDynamic, let description = type.localizedDescription { return description }
        return ext.uppercased() + " file"
    }
}
