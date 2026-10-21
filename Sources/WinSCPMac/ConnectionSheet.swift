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
    @State private var showAdvancedSettings = false

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
                        ForEach(model.sites) { saved in
                            Label { Text(saved.displayName) } icon: { Image(systemName: "server.rack").foregroundStyle(SiteColor.color(saved.settings.color) ?? .secondary) }
                                .help(saved.settings.note).tag(Optional(saved.id))
                        }
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
                    HStack(alignment: .top, spacing: 10) {
                        Text(advancedSummary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Advanced…") { showAdvancedSettings = true }.accessibilityHint("Open Advanced Site Settings")
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
            if let requested = model.requestedSite { site = requested; selectedSite = requested.id }
        }
        .onDisappear { model.requestedSite = nil }
        .interactiveDismissDisabled(model.connecting)
        .sheet(isPresented: $showAdvancedSettings) { AdvancedSiteSettingsView(site: $site) }
    }

    private var s3: Bool { site.transferProtocol.usesS3 }
    /// One line of the settings that most change how this site connects.
    private var advancedSummary: String {
        let settings = site.settings
        var parts = ["Remote: \(site.remotePath.isEmpty ? (s3 ? "/" : ".") : site.remotePath)"]
        if site.transferProtocol.usesSSH, !site.privateKey.isEmpty { parts.append("Key: \((site.privateKey as NSString).lastPathComponent)") }
        if site.transferProtocol == .scp, !settings.shell.isEmpty { parts.append("Shell: \(settings.shell)") }
        if site.transferProtocol == .sftp, !settings.sftpServer.isEmpty { parts.append("SFTP server: \(settings.sftpServer)") }
        if settings.tunnel { parts.append("Tunnel: \(settings.tunnelHost)") }
        if settings.proxyMethod != .none { parts.append("Proxy: \(settings.proxyMethod.rawValue.uppercased())") }
        if s3 { parts.append("Region: \(site.s3Region.isEmpty ? "us-east-1" : site.s3Region)") }
        if !site.certificateAuthorityFile.isEmpty { parts.append("Custom CA") }
        return parts.joined(separator: " · ")
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
