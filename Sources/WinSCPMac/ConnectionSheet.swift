// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import WinSCPCore

struct ConnectionSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    @State private var site = Site()
    @State private var password = ""
    @State private var sessionToken = ""
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
                            if value.usesS3, !site.transferProtocol.usesS3, site.host.isEmpty { site.host = "s3.amazonaws.com" }
                            if value.usesS3, !site.transferProtocol.usesS3, site.username == NSUserName() { site.username = "" }
                            site.transferProtocol = value
                            if value.usesWebDAV || value.usesS3 { showAdvanced = true }
                        })) {
                            ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityLabel("File protocol")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 13) {
                        GridRow { Text("Host name").frame(width: 93, alignment: .leading); TextField(s3 ? "s3.amazonaws.com" : "example.com", text: $site.host).accessibilityLabel("Host name") }
                        GridRow { Text("Port number"); TextField("22", value: $site.port, format: .number.grouping(.never)).frame(width: 95).accessibilityLabel("Port number") }
                        GridRow { Text(s3 ? "Access key ID" : "User name"); TextField(s3 ? "AKIA…" : "username", text: $site.username).accessibilityLabel(s3 ? "Access key ID" : "User name") }
                        GridRow { Text(s3 ? "Secret key" : "Password"); SecureField(site.transferProtocol.usesSSH ? "Password or key passphrase" : s3 ? "Secret access key" : "Account password", text: $password).accessibilityLabel(site.transferProtocol.usesSSH ? "Password or key passphrase" : s3 ? "Secret access key" : "Password") }
                        if s3 { GridRow { Text("Session token"); SecureField("Optional, for temporary credentials", text: $sessionToken).accessibilityLabel("Session token") } }
                    }
                    Text(site.transferProtocol.usesSSH ? "Leave the password blank to use your SSH agent or default SSH keys. Passwords are removed from Keychain after login." : s3 ? "The secret key and session token stay in memory for this connection and are never written to saved site settings." : "The password stays in memory for this connection and is never written to saved site settings.")
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
                            if s3 {
                                GridRow { Text("Region"); TextField("us-east-1", text: $site.s3Region).accessibilityLabel("Region") }
                                GridRow { Text("URL style"); Toggle("Path-style (bucket in the URL path)", isOn: $site.s3PathStyle) }
                            }
                            GridRow { Text(site.transferProtocol.usesWebDAV ? "WebDAV path" : s3 ? "Bucket / folder" : "Remote folder"); TextField(site.transferProtocol.usesWebDAV ? "/dav/" : s3 ? "/ (all buckets) or /my-bucket" : ".", text: $site.remotePath).accessibilityLabel("Remote folder") }
                            GridRow { Text("Local folder"); TextField("~", text: $site.localPath) }
                        }.padding(.top, 10)
                        if site.transferProtocol.usesWebDAV {
                            Text("Enter the server endpoint path, such as /dav/. Use HTTPS to protect your password and files.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if s3 {
                            Text("Use the regional endpoint and region of your bucket. Listing all buckets needs extra permission; otherwise enter /bucket-name. IP addresses, localhost and dotted bucket names over HTTPS always use path-style URLs.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text(site.transferProtocol.usesSSH ? "Server identity is verified before authentication." : site.transferProtocol == .s3http ? "S3 over HTTP signs requests but sends files and session tokens unencrypted." : !site.transferProtocol.isEncrypted ? "\(site.transferProtocol.shortTitle) sends credentials and files unencrypted." : "TLS requires a trusted certificate matching the server.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                Button("Cancel") { password = ""; sessionToken = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(model.connecting)
                Button("Login") {
                    model.error = nil
                    do { try site.validate() } catch { model.report(error); return }
                    if saveSite { model.saveSite(site) }
                    model.connect(site: site, password: password, sessionToken: s3 ? sessionToken : "")
                    password = ""; sessionToken = ""
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.busy)
            }.padding(16)
        }
        .frame(width: 646)
        .onChange(of: selectedSite) { id in
            site = model.sites.first(where: { $0.id == id }) ?? Site(); password = ""; sessionToken = ""; model.error = nil
        }
        .onAppear {
            if let requested = model.requestedSite { site = requested; selectedSite = requested.id; showAdvanced = requested.transferProtocol.usesWebDAV || requested.transferProtocol.usesS3 || !requested.privateKey.isEmpty || !requested.certificateAuthorityFile.isEmpty }
        }
        .onDisappear { model.requestedSite = nil }
        .interactiveDismissDisabled(model.connecting)
    }

    private var s3: Bool { site.transferProtocol.usesS3 }

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
