// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import WinSCPCore

struct ConnectionSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    @State private var site = Site()
    @State private var password = ""
    @State private var selectedSite: UUID?
    @State private var saveSite = true
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 23)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Login").font(.system(size: 19, weight: .semibold))
                    Text("Open a secure file transfer session").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SITES").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 16)
                    List(selection: $selectedSite) {
                        Label("New Site", systemImage: "plus.circle").tag(Optional<UUID>.none)
                        ForEach(model.sites) { saved in Label(saved.displayName, systemImage: "server.rack").tag(Optional(saved.id)) }
                    }.listStyle(.sidebar)
                    if let id = selectedSite {
                        Button("Remove saved site") { model.deleteSite(id); selectedSite = nil; site = Site() }
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary).padding(12)
                    }
                }.frame(width: 185)
                Divider()
                VStack(alignment: .leading, spacing: 17) {
                    HStack {
                        Text("File protocol").frame(width: 105, alignment: .leading)
                        Picker("File protocol", selection: Binding(get: { site.transferProtocol }, set: { value in
                            if site.port == site.transferProtocol.defaultPort { site.port = value.defaultPort }
                            site.transferProtocol = value
                            if value.usesWebDAV { showAdvanced = true }
                        })) {
                            ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityLabel("File protocol")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 13) {
                        GridRow { Text("Host name").frame(width: 93, alignment: .leading); TextField("example.com", text: $site.host).accessibilityLabel("Host name") }
                        GridRow { Text("Port number"); TextField("22", value: $site.port, format: .number.grouping(.never)).frame(width: 95).accessibilityLabel("Port number") }
                        GridRow { Text("User name"); TextField("username", text: $site.username).accessibilityLabel("User name") }
                        GridRow { Text("Password"); SecureField(site.transferProtocol.usesSSH ? "Password or key passphrase" : "Account password", text: $password).accessibilityLabel(site.transferProtocol.usesSSH ? "Password or key passphrase" : "Password") }
                    }
                    Text(site.transferProtocol.usesSSH ? "Leave the password blank to use your SSH agent or default SSH keys. Passwords are removed from Keychain after login." : "The password stays in memory for this connection and is never written to saved site settings.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            if site.transferProtocol.usesSSH { GridRow {
                                Text("Private key").frame(width: 87, alignment: .leading)
                                HStack { TextField("~/.ssh/id_ed25519", text: $site.privateKey); Button("Choose…") { chooseKey() } }
                            } }
                            if !site.transferProtocol.usesSSH && site.transferProtocol.isEncrypted {
                                GridRow {
                                    Text("CA certificate").frame(width: 87, alignment: .leading)
                                    HStack { TextField("System trust (default)", text: $site.certificateAuthorityFile); Button("Choose…") { chooseCA() } }
                                }
                            }
                            GridRow { Text(site.transferProtocol.usesWebDAV ? "WebDAV path" : "Remote folder"); TextField(site.transferProtocol.usesWebDAV ? "/dav/" : ".", text: $site.remotePath).accessibilityLabel("Remote folder") }
                            GridRow { Text("Local folder"); TextField("~", text: $site.localPath) }
                        }.padding(.top, 10)
                        if site.transferProtocol.usesWebDAV {
                            Text("Enter the server endpoint path, such as /dav/. Use HTTPS to protect your password and files.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    Toggle("Save site settings", isOn: $saveSite)
                    if saveSite {
                        HStack { Text("Site name").frame(width: 93, alignment: .leading); TextField("Optional display name", text: $site.name) }
                    }
                    if let error = model.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).padding(22).frame(width: 460)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Image(systemName: site.transferProtocol.isEncrypted ? "lock.shield" : "exclamationmark.triangle").foregroundStyle(.secondary)
                Text(site.transferProtocol.usesSSH ? "Server identity is verified before authentication." : !site.transferProtocol.isEncrypted ? "\(site.transferProtocol.shortTitle) sends credentials and files unencrypted." : "TLS requires a trusted certificate matching the server.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                Button("Cancel") { password = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(model.connecting)
                Button("Login") {
                    model.error = nil
                    do { try site.validate() } catch { model.report(error); return }
                    if saveSite { model.saveSite(site) }
                    model.connect(site: site, password: password)
                    password = ""
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.busy)
            }.padding(16)
        }
        .frame(width: 646)
        .onChange(of: selectedSite) { id in
            site = model.sites.first(where: { $0.id == id }) ?? Site(); password = ""; model.error = nil
        }
        .onAppear {
            if let requested = model.requestedSite { site = requested; selectedSite = requested.id; showAdvanced = requested.transferProtocol.usesWebDAV || !requested.privateKey.isEmpty || !requested.certificateAuthorityFile.isEmpty }
        }
        .onDisappear { model.requestedSite = nil }
        .interactiveDismissDisabled(model.connecting)
    }

    private func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose an OpenSSH private key. PuTTY .ppk keys must be converted first."
        if panel.runModal() == .OK, let url = panel.url { site.privateKey = url.path }
    }
    private func chooseCA() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.message = "Choose a PEM certificate authority bundle for this TLS site. Certificate and hostname verification remain required."
        if panel.runModal() == .OK, let url = panel.url { site.certificateAuthorityFile = url.path }
    }
}

struct EditorSheet: View {
    @ObservedObject var model: CommanderModel
    let document: RemoteDocument
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(document.entry.name).font(.headline)
                    Text(document.entry.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("UTF-8").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).disableAutocorrection(true).padding(8)
            Divider()
            HStack {
                Text("Changes are uploaded when you save.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    if text != document.text {
                        let alert = NSAlert(); alert.messageText = "Discard unsaved changes?"
                        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Keep Editing")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    dismiss()
                }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Save to Server") { model.saveDocument(document, text: text) }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(model.busy || text == document.text)
            }.padding(16)
        }.frame(width: 850, height: 600).onAppear { text = document.text }.interactiveDismissDisabled()
            .alert("Could not save file", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct SynchronizationSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    private var conflicts: Bool { model.syncItems.contains { $0.action == .conflict } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Synchronize · Local → Remote", systemImage: "arrow.triangle.2.circlepath").font(.title3.weight(.semibold))
            Text("Review changes before applying. Files present only on the server are kept. Symbolic links are skipped. Files are compared by size and modification time.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Table(model.syncItems) {
                TableColumn("Action") { item in Text(item.action.rawValue).foregroundStyle(item.action == .conflict ? .red : .primary) }.width(125)
                TableColumn("Relative path", value: \.relativePath)
                TableColumn("Existing file") { item in Text(item.replacesFile ? "Replace" : "—") }.width(90)
            }.frame(height: 280)
            if conflicts { Text("Resolve file/folder type conflicts before synchronizing.").font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text("\(model.syncItems.count) changes").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Changes") { model.executeSynchronization() }.buttonStyle(.borderedProminent)
                    .disabled(conflicts || model.syncItems.isEmpty || model.busy)
            }
        }.padding(22).frame(width: 730)
    }
}
