// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SyncSCPCore

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
            ToolButton(title: "New Session", icon: "plus") { model.showConnection = true }.disabled(!model.canConnect)
            ToolDivider()
            ToolButton(title: "Synchronize", icon: "arrow.triangle.2.circlepath") { model.previewSynchronization() }
                .disabled(!model.connected || model.busy).help("Synchronize · ⌘⇧S")
            ToolButton(title: "Terminal", icon: "terminal") { model.openTerminal() }
                .disabled(!model.canOpenTerminal).help(model.canOpenTerminal ? "Open an SSH terminal in the current remote folder · ⌘T" : "Connect with SFTP or SCP to open a terminal")
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

    /// One tab per connection, like WinSCP's session tabs; the shown tab uses the live site.
    private var sessionTabs: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(model.tabs) { tab in
                        let active = tab.id == model.activeTabID
                        SessionTabView(site: active ? (model.currentSite ?? tab.site) : tab.site, active: active,
                                       transfers: model.jobs.filter { $0.session == tab.id && ($0.state == .running || $0.state == .waiting) }.count,
                                       select: { model.activateTab(tab.id) }, close: { model.closeTab(tab.id) },
                                       canSelect: active || model.canSwitchTabs, canClose: !model.connecting && !(active && model.operationBusy))
                    }
                    if model.tabs.isEmpty || model.connecting {
                        HStack(spacing: 7) {
                            if model.connecting { ProgressView().controlSize(.small); Text("Connecting…") } else { Text("No session") }
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 13).frame(height: 28)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button { model.showConnection = true } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.borderless).frame(width: 28, height: 28).help("New Session · ⌘N").disabled(!model.canConnect)
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
            Text("Development preview · 0.15.0").foregroundStyle(.tertiary)
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

private struct SessionTabView: View {
    let site: Site
    let active: Bool
    let transfers: Int
    let select: () -> Void
    let close: () -> Void
    let canSelect: Bool
    let canClose: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let color = SiteColor.color(site.settings.color) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 14).help("Site color")
            }
            Image(systemName: site.transferProtocol.isEncrypted ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(site.transferProtocol.isEncrypted ? Color.green : Color.orange)
            Text(site.displayName).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            Text(site.transferProtocol.shortTitle).font(.system(size: 9.5, weight: .bold)).tracking(0.4)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(accent).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            if transfers > 0 {
                Label("\(transfers)", systemImage: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                    .help("\(transfers) transfer(s) running or waiting on this connection")
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Disconnect")
                .disabled(!canClose).accessibilityLabel("Disconnect \(site.displayName)")
        }
        .padding(.horizontal, 13).frame(height: active ? 29 : 27)
        .background(active ? chrome : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).stroke(Color.primary.opacity(active ? 0.12 : 0.07)))
        .contentShape(Rectangle())
        .onTapGesture { if canSelect { select() } }
        .help(site.settings.note.isEmpty ? "\(site.username)@\(site.host):\(site.port)" : site.settings.note)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
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
                tab(.editing, title: "Editing", count: model.externalEdits.count)
                tab(.log, title: "Log", count: 0)
                Spacer()
                if model.bottomTab == .queue {
                    Button("Clear finished") { model.clearCompleted() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.runningQueue)
                } else if model.bottomTab == .log {
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
            switch model.bottomTab { case .queue: queue; case .editing: editing; case .log: log }
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
                            if Set(model.jobs.map(\.session)).count > 1 || model.tabs.count > 1 {
                                Text(job.siteName).lineLimit(1).foregroundStyle(.secondary).frame(width: 140, alignment: .leading).help("Connection: \(job.siteName)")
                            }
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

    @ViewBuilder private var editing: some View {
        if model.externalEdits.isEmpty {
            Text("Use Edit With on a remote file to edit it in another application; every save is uploaded.")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.externalEdits) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.pencil").foregroundStyle(item.conflict ? Color.orange : accent).frame(width: 16)
                            Text(item.name).lineLimit(1).frame(width: 200, alignment: .leading)
                            Text(item.remotePath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.application).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(item.status).foregroundStyle(item.conflict ? Color.orange : Color.secondary).lineLimit(1).frame(width: 260, alignment: .leading).help(item.status)
                            Button("Upload Now") { model.syncEdit(item.id) }.buttonStyle(.borderless)
                            Button("Stop") { model.stopEditing(item.id) }.buttonStyle(.borderless).help("Stop uploading saves; unsaved changes are kept")
                        }
                        .font(.system(size: 12)).padding(.horizontal, 14).frame(height: 28)
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
    @State private var dropTargeted = false
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
            if !usable { disconnected } else {
                fileTable
                    .onDrop(of: local ? [DragPayload.remoteType] : [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                        local ? DragPayload.remotePaths(providers) { model.downloadDropped($0) } : DragPayload.fileURLs(providers) { model.uploadDropped($0) }
                    }
                    .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 4).stroke(accent, lineWidth: 2).padding(2).allowsHitTesting(false) } }
            }
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
        let chosen = selection.wrappedValue.subtracting([ParentRow.id])
        let one = chosen.count == 1, any = !chosen.isEmpty
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
            Menu {
                Button { act { model.promptMkdir() } } label: { Label("Folder…", systemImage: "folder.badge.plus") }
                Button { act { model.promptNewFile() } } label: { Label("File…", systemImage: "doc.badge.plus") }
            } label: { Label("New", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12)).padding(.horizontal, 8)
                .disabled(!usable || model.busy).help("New folder (F7) or file (⇧F4)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).frame(height: 32).disabled(!usable)
    }

    /// Every part of the path is a link to that folder; long paths scroll to keep the end visible.
    private var pathStrip: some View {
        let parts = path.split(separator: "/").map(String.init)
        let color = active ? Color.white : Color.secondary
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if path.isEmpty {
                        Text(local ? "" : "Not connected").foregroundStyle(color)
                    } else {
                        crumb("/", target: "/", current: parts.isEmpty)
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            if index > 0 { Text("/").foregroundStyle(color.opacity(0.7)) }
                            crumb(part, target: "/" + parts[...index].joined(separator: "/"), current: index == parts.count - 1)
                        }
                    }
                    Color.clear.frame(width: 1).id("end")
                }
                .font(.system(size: 12, weight: active ? .semibold : .regular, design: .monospaced))
                .padding(.horizontal, 12)
            }
            .onAppear { proxy.scrollTo("end", anchor: .trailing) }
            .onChange(of: path) { _ in proxy.scrollTo("end", anchor: .trailing) }
        }
        .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25)
        .background(active ? accent : Color.primary.opacity(0.05))
    }

    private func crumb(_ title: String, target: String, current: Bool) -> some View {
        Button { navigate(target) } label: {
            Text(title).foregroundStyle(active ? Color.white : current ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain).disabled(!usable || (!local && model.busy))
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .help(current ? "Refresh \(target)" : "Go to \(target)").accessibilityLabel("Go to \(target)")
    }

    private var nameColumn: TableColumn<FileEntry, KeyPathComparator<FileEntry>, some View, Text> {
        TableColumn("Name", value: \.name) { entry in
            HStack(spacing: 7) {
                Image(systemName: entry.path == ParentRow.id ? "arrow.turn.left.up" : entry.isDirectory ? "folder.fill" : entry.isSymbolicLink ? "link" : "doc")
                    .foregroundStyle(entry.isDirectory ? accent.opacity(0.85) : .secondary).frame(width: 16)
                Text(entry.name).lineLimit(1).help(entry.path == ParentRow.id ? "Parent folder" : entry.name)
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

    /// WinSCP's ".." row: always first (not sorted), opens the parent folder, never selected for actions.
    private var rows: [FileEntry] {
        guard usable, !path.isEmpty, path != "/" else { return entries }
        return [FileEntry(path: ParentRow.id, name: "..", permissions: 0o040755, permissionsKnown: false)] + entries
    }

    /// Local: Name, Size, Type, Changed. Remote: Name, Size, Changed, Rights — as in WinSCP.
    @ViewBuilder private var fileTable: some View {
        if local {
            decorated(Table(of: FileEntry.self, selection: selection, sortOrder: $sortOrder) {
                nameColumn.width(min: 160, ideal: 280)
                sizeColumn.width(min: 60, ideal: 80, max: 110)
                TableColumn("Type") { entry in Text(entry.path == ParentRow.id ? "" : FileType.describe(entry)).foregroundStyle(.secondary).lineLimit(1) }.width(min: 70, ideal: 130, max: 190)
                changedColumn.width(min: 110, ideal: 140, max: 170)
            } rows: {
                ForEach(rows) { entry in TableRow(entry).itemProvider { entry.path == ParentRow.id ? nil : DragPayload.provider(for: entry, local: true) } }
            })
        } else {
            decorated(Table(of: FileEntry.self, selection: selection, sortOrder: $sortOrder) {
                nameColumn.width(min: 160, ideal: 280)
                sizeColumn.width(min: 60, ideal: 80, max: 110)
                changedColumn.width(min: 110, ideal: 140, max: 170)
                TableColumn("Rights") { entry in
                    Text(entry.path == ParentRow.id ? "" : entry.rights).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.width(min: 80, ideal: 90, max: 110)
            } rows: {
                ForEach(rows) { entry in TableRow(entry).itemProvider { entry.path == ParentRow.id ? nil : DragPayload.provider(for: entry, local: false) } }
            })
        }
    }

    private func decorated<T: View>(_ table: T) -> some View {
        table
        .font(.system(size: 12.5))
        .contextMenu(forSelectionType: String.self) { clicked in
            let ids = clicked.subtracting([ParentRow.id])
            Button(local ? "Open" : "Open / Edit") { if let entry = allEntries.first(where: { ids.contains($0.id) }) { model.open(entry, side: side) } }
                .disabled(ids.count != 1 || model.busy)
            if ids.count == 1, let entry = allEntries.first(where: { ids.contains($0.id) }), entry.isRegularFile {
                Menu(local ? "Open With" : "Edit With") {
                    if !local {
                        Button("Built-in Editor") { model.activeSide = .remote; model.remoteSelection = [entry.id]; model.editSelected(builtIn: true) }
                        Divider()
                    }
                    ForEach(EditorApps.candidates(forFileNamed: entry.name), id: \.self) { app in
                        Button(EditorApps.name(app)) { openWith(entry, app) }
                    }
                    Divider()
                    Button("Other Application…") { if let app = EditorApps.chooseApplication() { openWith(entry, app) } }
                }.disabled(model.busy)
            }
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
            if ids.contains(ParentRow.id) { navigate(RemotePath.parent(path)) }
            else if let entry = allEntries.first(where: { ids.contains($0.id) }) { model.open(entry, side: side) }
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
    private func openWith(_ entry: FileEntry, _ app: URL) {
        model.activeSide = side
        if local { NSWorkspace.shared.open([URL(fileURLWithPath: entry.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        else { model.editExternally(entry, with: app) }
    }
    private func navigate(_ target: String) { model.activeSide = side; local ? model.navigateLocal(target) : model.navigateRemote(target) }
}

/// Drag and drop between panes and from Finder. Local rows carry file URLs (Finder and the
/// remote pane accept them); remote rows carry their paths under an app-private type that
/// only this app's local pane accepts, so a remote item is never mistaken for a local file.
enum DragPayload {
    static let remoteType = "io.github.oguzhankrcb.syncscp.remote-paths"

    static func provider(for entry: FileEntry, local: Bool) -> NSItemProvider {
        if local { return NSItemProvider(contentsOf: URL(fileURLWithPath: entry.path)) ?? NSItemProvider() }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: remoteType, visibility: .ownProcess) { completion in
            completion(try? JSONEncoder().encode([entry.path]), nil); return nil
        }
        return provider
    }

    static func fileURLs(_ providers: [NSItemProvider], deliver: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        collect(accepted, type: UTType.fileURL.identifier, decode: { URL(dataRepresentation: $0, relativeTo: nil).map { [$0] } ?? [] }, deliver: deliver)
        return true
    }

    static func remotePaths(_ providers: [NSItemProvider], deliver: @escaping @MainActor ([String]) -> Void) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(remoteType) }
        guard !accepted.isEmpty else { return false }
        collect(accepted, type: remoteType, decode: { (try? JSONDecoder().decode([String].self, from: $0)) ?? [] }, deliver: deliver)
        return true
    }

    /// Loads every provider, then delivers all items once on the main actor.
    private static func collect<T>(_ providers: [NSItemProvider], type: String, decode: @escaping @Sendable (Data) -> [T], deliver: @escaping @MainActor ([T]) -> Void) {
        let group = DispatchGroup(), lock = NSLock()
        var items: [T] = []
        for provider in providers {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                if let data { let decoded = decode(data); lock.lock(); items += decoded; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { let result = items; MainActor.assumeIsolated { deliver(result) } }
    }
}

/// Applications offered by Edit With / Open With: the file type's default first, then other
/// apps for the type and for plain text (so code editors appear for .php, .yml, files without extension…).
enum EditorApps {
    static func candidates(forFileNamed name: String) -> [URL] {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.plainText : (UTType(filenameExtension: ext) ?? .plainText)
        var urls: [URL] = []
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: type) { urls.append(preferred) }
        urls += NSWorkspace.shared.urlsForApplications(toOpen: type) + NSWorkspace.shared.urlsForApplications(toOpen: .plainText)
        var seen = Set<String>(), result: [URL] = []
        for url in urls where url.path != Bundle.main.bundlePath && seen.insert(url.resolvingSymlinksInPath().path).inserted { result.append(url) }
        return Array(result.prefix(12))
    }
    static func name(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.message = "Choose an application to edit with"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum ParentRow {
    /// Cannot collide with a real path: paths never contain NUL.
    static let id = "\u{0}parent"
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
