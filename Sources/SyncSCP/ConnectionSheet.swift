// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import SyncSCPCore

/// WinSCP's file protocol families; the Encryption choice picks the concrete protocol.
private enum ProtocolFamily: String, CaseIterable, Identifiable {
    case sftp = "SFTP", scp = "SCP", ftp = "FTP", webdav = "WebDAV", s3 = "Amazon S3"
    var id: String { rawValue }
    init(_ value: TransferProtocol) {
        self = value.usesFTP ? .ftp : value.usesWebDAV ? .webdav : value.usesS3 ? .s3 : value == .scp ? .scp : .sftp
    }
    var variants: [(TransferProtocol, String)] {
        switch self {
        case .sftp: return [(.sftp, "SSH (always encrypted)")]
        case .scp: return [(.scp, "SSH (always encrypted)")]
        case .ftp: return [(.ftp, "No encryption"), (.ftpsExplicit, "TLS/SSL Explicit encryption"), (.ftpsImplicit, "TLS/SSL Implicit encryption")]
        case .webdav: return [(.webdavs, "TLS/SSL Implicit encryption"), (.webdav, "No encryption")]
        case .s3: return [(.s3, "TLS/SSL Implicit encryption"), (.s3http, "No encryption")]
        }
    }
}

struct ConnectionSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    @State private var site = Site()
    @State private var password = ""
    @State private var sessionToken = ""
    @State private var savePassword = false
    @State private var selectedSite: UUID?
    @State private var search = ""
    @State private var showAdvancedSettings = false
    @State private var showImport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sitesSidebar
                Divider()
                sessionForm
            }
            Divider()
            HStack(spacing: 8) {
                Menu("Tools") {
                    Button("Import Sites from WinSCP or SSH Config…") { showImport = true }
                    Button("Convert PuTTY Key…") { convertKey() }
                }.fixedSize()
                Menu("Manage") {
                    Button("Rename…") { renameSelected() }.disabled(selectedSite == nil)
                    Button("Delete") { if let id = selectedSite { model.deleteSite(id); selectedSite = nil; site = Site() } }.disabled(selectedSite == nil)
                }.fixedSize()
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                Link("Help", destination: URL(string: "https://winscp.net/eng/docs/ui_login")!).font(.system(size: 12))
                Button("Close") { password = ""; sessionToken = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(model.connecting)
                if site.transferProtocol.usesSSH {
                    Button { model.error = nil; model.openTerminal(fromLogin: site, password: password); password = "" } label: { Label("Terminal", systemImage: "terminal") }
                        .disabled(!model.canConnect).help("Open an SSH terminal to this site without a file session")
                }
                Button("Login") {
                    model.error = nil
                    do { try site.validate() } catch { model.report(error); return }
                    model.login(site: site, password: password, sessionToken: s3 ? sessionToken : "", savePassword: savePassword && isSaved)
                    password = ""; sessionToken = ""
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!model.canConnect)
            }
            .padding(.horizontal, 16).frame(height: 54)
        }
        .frame(width: 860, height: 540)
        .onChange(of: selectedSite) { id in
            site = model.sites.first(where: { $0.id == id }) ?? Site(); password = ""; sessionToken = ""; model.error = nil; savePassword = false
        }
        .onAppear {
            if let requested = model.requestedSite { site = requested; selectedSite = requested.id }
        }
        .onDisappear { model.requestedSite = nil }
        .interactiveDismissDisabled(model.connecting)
        .sheet(isPresented: $showAdvancedSettings) { AdvancedSiteSettingsView(site: $site) }
        .sheet(isPresented: $showImport) { ImportSheet(model: model) }
    }

    /// Sites grouped like WinSCP's folders: a saved name "Production/db-1" is "db-1" in "Production".
    private var groups: [(folder: String, sites: [Site])] {
        let matching = model.sites.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) }
        let grouped = Dictionary(grouping: matching) { SiteName.folder($0.displayName) }
        return grouped.keys.sorted { $0.isEmpty != $1.isEmpty ? !$0.isEmpty : $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, grouped[$0]!.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
    }

    private var sitesSidebar: some View {
        VStack(spacing: 8) {
            List(selection: $selectedSite) {
                Label("New Site", systemImage: "plus.circle").tag(Optional<UUID>.none)
                ForEach(groups, id: \.folder) { group in
                    Section(group.folder.isEmpty ? "Sites" : group.folder) {
                        ForEach(group.sites) { saved in
                            Label {
                                HStack(spacing: 5) {
                                    Text(SiteName.leaf(saved.displayName)).lineLimit(1)
                                    if model.sitesWithPasswords.contains(saved.id) {
                                        Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Password saved in Keychain")
                                    }
                                }
                            } icon: {
                                Image(systemName: "server.rack").foregroundStyle(SiteColor.color(saved.settings.color) ?? accent)
                            }
                            .help(saved.settings.note.isEmpty ? "\(saved.username)@\(saved.host)" : saved.settings.note).tag(Optional(saved.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search sites", text: $search).textFieldStyle(.plain).accessibilityLabel("Search sites")
            }
            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            .padding([.horizontal, .bottom], 10)
        }
        .frame(width: 260)
    }

    private var family: Binding<ProtocolFamily> {
        Binding(get: { ProtocolFamily(site.transferProtocol) }, set: { setProtocol($0.variants[0].0) })
    }
    private func setProtocol(_ value: TransferProtocol) {
        if site.port == site.transferProtocol.defaultPort { site.port = value.defaultPort }
        if value.usesS3, !site.transferProtocol.usesS3, site.host.isEmpty { site.host = "s3.amazonaws.com" }
        if value.usesS3, !site.transferProtocol.usesS3, site.username == NSUserName() { site.username = "" }
        site.transferProtocol = value
    }

    private var sessionForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("SESSION").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                labeled("File protocol") {
                    Picker("File protocol", selection: family) { ForEach(ProtocolFamily.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                }
                labeled("Encryption") {
                    Picker("Encryption", selection: Binding(get: { site.transferProtocol }, set: { setProtocol($0) })) {
                        ForEach(ProtocolFamily(site.transferProtocol).variants, id: \.0) { Text(L($0.1)).tag($0.0) }
                    }.labelsHidden().disabled(site.transferProtocol.usesSSH)
                }
            }
            HStack(spacing: 14) {
                labeled("Host name") { TextField(s3 ? "s3.amazonaws.com" : "example.com", text: $site.host).accessibilityLabel("Host name") }
                labeled("Port number") { TextField("22", value: $site.port, format: .number.grouping(.never)).accessibilityLabel("Port number") }.frame(width: 110)
            }
            HStack(spacing: 14) {
                labeled(s3 ? "Access key ID" : "User name") { TextField(s3 ? "AKIA…" : "username", text: $site.username).accessibilityLabel(s3 ? "Access key ID" : "User name") }
                labeled(s3 ? "Secret access key" : "Password") {
                    SecureField(hasSavedPassword ? "Saved in Keychain" : site.transferProtocol.usesSSH ? "Password or key passphrase" : "", text: $password)
                        .accessibilityLabel(s3 ? "Secret access key" : "Password")
                }
            }
            HStack(spacing: 10) {
                Toggle(hasSavedPassword ? (s3 ? "Save the typed key instead" : "Save the typed password instead") : (s3 ? "Save secret key in Keychain" : "Save password in Keychain"), isOn: $savePassword)
                    .toggleStyle(.checkbox).disabled(!isSaved)
                    .help(isSaved ? "Stored in your macOS Keychain after a successful login, never in the site file." : "Save the site first.")
                if hasSavedPassword {
                    Label(s3 ? "Saved key will be used" : "Saved password will be used", systemImage: "key.fill").foregroundStyle(.secondary)
                    Button("Forget") { model.forgetPassword(site.id) }.buttonStyle(.link)
                }
            }.font(.system(size: 11.5))
            if s3 { labeled("Session token (optional)") { SecureField("For temporary credentials", text: $sessionToken).accessibilityLabel("Session token") } }
            HStack(spacing: 10) {
                Menu("Save") {
                    Button("Save") { save(asNew: false) }
                    Button("Save As…") { save(asNew: true) }
                }.fixedSize()
                Spacer()
                Button("Advanced…") { showAdvancedSettings = true }.accessibilityHint("Open Advanced Site Settings")
            }
            Text(advancedSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: site.transferProtocol.isEncrypted ? "info.circle" : "exclamationmark.triangle")
                Text(securityNote).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(site.transferProtocol.isEncrypted ? accent : Color.orange)
            .background((site.transferProtocol.isEncrypted ? accent : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder).font(.system(size: 12.5)).padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var securityNote: String {
        let kind = site.transferProtocol
        if kind.usesSSH { return "Server identity is verified before authentication. Leave the password empty to use the SSH agent or default keys. A saved password stays in your Keychain, never in the site file." }
        if kind == .s3http { return "S3 over HTTP signs requests but sends files and session tokens unencrypted." }
        if !kind.isEncrypted { return "\(kind.shortTitle) sends credentials and files unencrypted." }
        return "TLS requires a trusted certificate matching the server. Passwords and keys stay in memory for this session only."
    }

    /// WinSCP's Save / Save As: the name may contain "/" to place the site in a folder.
    private func save(asNew: Bool) {
        let alert = NSAlert()
        alert.messageText = asNew ? "Save session as site" : "Save site"
        alert.informativeText = String(localized: "Use Folder/Name to group sites. Passwords are saved only with Save password, in your Keychain.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = site.name.isEmpty ? "\(site.username)@\(site.host)" : site.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK")); alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var saved = site
        if asNew { saved.id = UUID() }
        saved.name = name
        model.saveSite(saved)
        if model.sites.contains(where: { $0.id == saved.id }) { site = saved; selectedSite = saved.id }
    }

    private func renameSelected() {
        guard let id = selectedSite, var saved = model.sites.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Rename site")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = saved.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename")); alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saved.name = field.stringValue.trimmingCharacters(in: .whitespaces)
        model.saveSite(saved); site.name = saved.name
    }

    /// Converts a .ppk into an OpenSSH key in the app's keys folder and uses it for this site.
    private func convertKey() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = []; panel.allowsOtherFileTypes = true; panel.message = String(localized: "Choose a PuTTY private key (.ppk)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var passphrase: String?
        if let text = try? String(contentsOf: url, encoding: .utf8), PuTTYKey.isEncrypted(text) {
            let alert = NSAlert(); alert.messageText = String(localized: "Passphrase for \(url.lastPathComponent)")
            alert.informativeText = String(localized: "The converted OpenSSH key keeps this passphrase.")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Convert")); alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            passphrase = field.stringValue
        }
        do {
            site.privateKey = try model.convertPuTTYKey(url, passphrase: passphrase)
            model.error = nil
        } catch { model.report(error) }
    }

    private var s3: Bool { site.transferProtocol.usesS3 }
    private var isSaved: Bool { model.sites.contains { $0.id == site.id } }
    private var hasSavedPassword: Bool { model.sitesWithPasswords.contains(site.id) }
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

enum SiteName {
    static func folder(_ name: String) -> String {
        guard let index = name.lastIndex(of: "/") else { return "" }
        return String(name[..<index]).trimmingCharacters(in: .whitespaces)
    }
    static func leaf(_ name: String) -> String {
        guard let index = name.lastIndex(of: "/") else { return name }
        let leaf = name[name.index(after: index)...].trimmingCharacters(in: .whitespaces)
        return leaf.isEmpty ? name : leaf
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
                        let alert = NSAlert(); alert.messageText = String(localized: "Discard unsaved changes?")
                        alert.addButton(withTitle: String(localized: "Discard")); alert.addButton(withTitle: String(localized: "Keep Editing"))
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
    private var conflicts: Int { model.syncItems.filter { $0.action == .conflict }.count }
    private var deletions: Int { model.syncItems.filter { $0.action == .deleteRemote || $0.action == .deleteLocal }.count }
    private var actionable: Int { model.syncItems.count - conflicts }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Synchronize", systemImage: "arrow.triangle.2.circlepath").font(.title3.weight(.semibold))
            Text("\(model.localPath)  ⇄  \(model.remotePath)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 16) {
                Picker("Direction", selection: $model.syncOptions.direction) { ForEach(SyncDirection.allCases) { Text(L($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 360)
                Toggle("Newer files only", isOn: $model.syncOptions.newerOnly).disabled(model.syncOptions.direction == .both)
                    .help("Copy a file only when the source is newer than the destination")
                Toggle("Compare size only", isOn: $model.syncOptions.sizeOnly).help("Ignore modification times, for servers whose clocks or time zones differ")
            }.toggleStyle(.checkbox).font(.system(size: 12))
            HStack(spacing: 16) {
                Toggle(model.syncOptions.direction == .download ? "Delete local files that are not on the server (to Trash)" : "Delete remote files that are not on this Mac",
                       isOn: $model.syncOptions.deleteExtras).disabled(model.syncOptions.direction == .both).toggleStyle(.checkbox)
                    .foregroundStyle(model.syncOptions.deleteExtras && model.syncOptions.direction != .both ? Color.red : Color.primary)
                Spacer()
                Button("Compare") { model.compareForSynchronization() }.disabled(model.busy)
            }.font(.system(size: 12))
            Table(model.syncItems) {
                TableColumn("Action") { item in
                    Text(L(item.action.rawValue)).foregroundStyle(item.action == .conflict ? Color.orange : item.action == .deleteRemote || item.action == .deleteLocal ? Color.red : Color.primary)
                }.width(150)
                TableColumn("Relative path") { item in Text(item.relativePath).help(item.reason) }
                TableColumn("Note") { item in Text(item.action == .conflict ? item.reason : item.replacesFile ? "Replaces existing" : "").foregroundStyle(.secondary) }.width(220)
            }.frame(height: 300)
            if conflicts > 0 { Text("\(conflicts) conflict(s) skipped; resolve them by hand or synchronize one way.").font(.system(size: 11)).foregroundStyle(.orange) }
            if deletions > 0 { Text(model.syncOptions.direction == .download ? "\(deletions) local item(s) will be moved to the Trash." : "\(deletions) item(s) will be deleted from the server; this cannot be undone.").font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text(model.busy ? "Comparing…" : "\(actionable) change\(actionable == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Changes") { model.executeSynchronization() }.buttonStyle(.borderedProminent)
                    .disabled(actionable == 0 || model.busy)
            }
        }.padding(22).frame(width: 820)
        .onChange(of: model.syncOptions.direction) { direction in if direction == .both { model.syncOptions.deleteExtras = false; model.syncOptions.newerOnly = false } }
    }
}
