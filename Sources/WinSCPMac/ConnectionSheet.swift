// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import WinSCPCore

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
    @State private var selectedSite: UUID?
    @State private var search = ""
    @State private var showAdvancedSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sitesSidebar
                Divider()
                sessionForm
            }
            Divider()
            HStack(spacing: 8) {
                Menu("Manage") {
                    Button("Rename…") { renameSelected() }.disabled(selectedSite == nil)
                    Button("Delete") { if let id = selectedSite { model.deleteSite(id); selectedSite = nil; site = Site() } }.disabled(selectedSite == nil)
                }.fixedSize()
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                Link("Help", destination: URL(string: "https://winscp.net/eng/docs/ui_login")!).font(.system(size: 12))
                Button("Close") { password = ""; sessionToken = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(model.connecting)
                Button("Login") {
                    model.error = nil
                    do { try site.validate() } catch { model.report(error); return }
                    model.connect(site: site, password: password, sessionToken: s3 ? sessionToken : "")
                    password = ""; sessionToken = ""
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.busy)
            }
            .padding(.horizontal, 16).frame(height: 54)
        }
        .frame(width: 860, height: 540)
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
                            Label { Text(SiteName.leaf(saved.displayName)).lineLimit(1) } icon: {
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
                        ForEach(ProtocolFamily(site.transferProtocol).variants, id: \.0) { Text($0.1).tag($0.0) }
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
                    SecureField(site.transferProtocol.usesSSH ? "Password or key passphrase" : "", text: $password)
                        .accessibilityLabel(s3 ? "Secret access key" : "Password")
                }
            }
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
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var securityNote: String {
        let kind = site.transferProtocol
        if kind.usesSSH { return "Server identity is verified before authentication. Leave the password empty to use the SSH agent or default keys; passwords are never saved." }
        if kind == .s3http { return "S3 over HTTP signs requests but sends files and session tokens unencrypted." }
        if !kind.isEncrypted { return "\(kind.shortTitle) sends credentials and files unencrypted." }
        return "TLS requires a trusted certificate matching the server. Passwords and keys stay in memory for this session only."
    }

    /// WinSCP's Save / Save As: the name may contain "/" to place the site in a folder.
    private func save(asNew: Bool) {
        let alert = NSAlert()
        alert.messageText = asNew ? "Save session as site" : "Save site"
        alert.informativeText = "Use Folder/Name to group sites. Passwords are not saved."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = site.name.isEmpty ? "\(site.username)@\(site.host)" : site.name
        alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
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
        let alert = NSAlert(); alert.messageText = "Rename site"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = saved.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saved.name = field.stringValue.trimmingCharacters(in: .whitespaces)
        model.saveSite(saved); site.name = saved.name
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
