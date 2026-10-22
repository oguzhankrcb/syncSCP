// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import SyncSCPCore

/// Import from Windows WinSCP: an exported WinSCP.ini, a `reg export` file, or WinSCP running
/// under Wine/Whisky/CrossOver on this Mac. Preview first; nothing is written until Import.
struct ImportSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var result: WinSCPImportResult?
    @State private var chosen = Set<UUID>()
    @State private var trustHostKeys = true
    @State private var savePasswords = false
    @State private var passwordsSaved = 0
    @State private var found: [URL]?
    @State private var summary: WinSCPImportSummary?
    @State private var error: String?
    /// Opens straight into the preview of this configuration file.
    var preload: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 22)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from WinSCP").font(.system(size: 17, weight: .semibold))
                    Text(source?.lastPathComponent ?? "Sites with all their settings, and trusted host keys").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(source?.path ?? "")
                        .lineLimit(1).truncationMode(.middle)
                }
            }.padding(18)
            Divider()
            Group {
                if let summary { done(summary) }
                else if let result { preview(result) }
                else { start }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if summary != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if let result {
                        Button("Import \(chosen.count) Site\(chosen.count == 1 ? "" : "s")") { commit(result) }
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                            .disabled(chosen.isEmpty && !(trustHostKeys && !result.hostKeys.isEmpty) && !(savePasswords && !existingWithPasswords(result).isEmpty))
                    }
                }
            }.padding(14)
        }
        .frame(width: 820, height: 600)
        .onAppear { if let preload, result == nil { load(preload) } }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a WinSCP configuration. PuTTY keys without a passphrase are converted to OpenSSH format. Saved passwords are imported only if you choose to, into your Keychain.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("On Windows: WinSCP ▸ Tools ▸ Export/Backup Configuration… saves a WinSCP.ini file.", systemImage: "1.circle")
                Label("Or in a Command Prompt: reg export \"HKCU\\Software\\Martin Prikryl\\WinSCP 2\" winscp.reg", systemImage: "2.circle")
                Label("WinSCP under Wine, Whisky or CrossOver on this Mac is found automatically.", systemImage: "3.circle")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("Find on This Mac") { found = WinSCPImport.locateOnThisMac(); if found?.count == 1 { load(found![0]) } }
                Button("Choose File…") { choose() }
            }
            if let found {
                if found.isEmpty { Text("No WinSCP configuration was found in Wine, Whisky or CrossOver prefixes.").foregroundStyle(.secondary) }
                ForEach(found, id: \.self) { url in
                    Button { load(url) } label: { Label(url.path, systemImage: "doc.text").lineLimit(1).truncationMode(.middle) }.buttonStyle(.link)
                }
            }
        }.font(.system(size: 12.5)).padding(20)
    }

    private func preview(_ result: WinSCPImportResult) -> some View {
        List {
            Section {
                ForEach(result.sites) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { chosen.contains(item.id) }, set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(item.site.name).font(.system(size: 12.5, weight: .medium))
                                Text(item.site.transferProtocol.shortTitle).font(.system(size: 9.5, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1).foregroundStyle(accent).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                Text("\(item.site.username)@\(item.site.host):\(item.site.port)").foregroundStyle(.secondary)
                                if item.password != nil { Image(systemName: "key.fill").font(.system(size: 10)).foregroundStyle(.secondary).help("A saved password was found") }
                            }
                            if existing(item) != nil {
                                Label("Already in syncSCP; importing it again adds a copy.", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            let extras = [item.site.settings.shell.isEmpty ? nil : "Shell: \(item.site.settings.shell)",
                                          item.site.settings.sftpServer.isEmpty ? nil : "SFTP server: \(item.site.settings.sftpServer)",
                                          item.site.settings.tunnel ? "Tunnel: \(item.site.settings.tunnelHost)" : nil,
                                          item.site.settings.proxyMethod == .none ? nil : "Proxy: \(item.site.settings.proxyMethod.rawValue.uppercased())"].compactMap { $0 }
                            if !extras.isEmpty { Text(extras.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary) }
                            ForEach(item.warnings, id: \.self) { warning in
                                Label(warning, systemImage: warning.contains("will be converted") ? "key" : "exclamationmark.triangle")
                                    .font(.system(size: 11)).foregroundStyle(warning.contains("will be converted") ? Color.secondary : Color.orange)
                            }
                        }
                    }.padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("\(result.sites.count) sites")
                    Spacer()
                    Button(chosen.count == result.sites.count ? "Select None" : "Select All") {
                        chosen = chosen.count == result.sites.count ? [] : Set(result.sites.map(\.id))
                    }.buttonStyle(.link)
                }
            }
            let withPasswords = result.sites.filter { $0.password != nil }
            if !withPasswords.isEmpty {
                Section {
                    Toggle("Save \(withPasswords.count) saved password\(withPasswords.count == 1 ? "" : "s") in my Keychain", isOn: $savePasswords)
                    let updates = existingWithPasswords(result).count
                    Text("Passwords go to the macOS Keychain on this Mac, never into site files\(updates > 0 ? "; \(updates) of them also update sites already in syncSCP" : ""). Otherwise you type them at login.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } header: { Text("Passwords") }
            }
            if !result.hostKeys.isEmpty {
                Section {
                    Toggle("Trust \(result.hostKeys.count) host key\(result.hostKeys.count == 1 ? "" : "s") already trusted in WinSCP", isOn: $trustHostKeys)
                    ForEach(result.hostKeys) { key in
                        HStack {
                            Text(key.port == 22 ? key.host : "\(key.host):\(key.port)").frame(width: 220, alignment: .leading)
                            Text(key.algorithm).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                            Text(key.fingerprint).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.system(size: 11.5)).opacity(trustHostKeys ? 1 : 0.5)
                    }
                } header: { Text("Host keys") } footer: {
                    Text("A different key already trusted for the same host is never replaced.").font(.system(size: 11))
                }
            }
            if !result.skipped.isEmpty {
                Section("Not imported") { ForEach(result.skipped, id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(.secondary) } }
            }
        }
    }

    private func done(_ summary: WinSCPImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Imported \(summary.sites.count) site\(summary.sites.count == 1 ? "" : "s").", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 14, weight: .semibold))
            if !summary.convertedKeys.isEmpty { Text("Converted \(summary.convertedKeys.count) PuTTY key\(summary.convertedKeys.count == 1 ? "" : "s") into \(URL(fileURLWithPath: summary.convertedKeys[0]).deletingLastPathComponent().path) (owner-only access).") }
            Text("Host keys: \(summary.hostKeysAdded) added, \(summary.hostKeysAlreadyKnown) already trusted.")
            ForEach(summary.hostKeyConflicts, id: \.self) { Label("\($0): a different key is already trusted and was kept.", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
            ForEach(summary.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let backup = summary.backup { Text("Previous sites and host keys were backed up to \(backup.path).").foregroundStyle(.secondary).textSelection(.enabled) }
            Text(passwordsSaved > 0 ? "Saved \(passwordsSaved) password\(passwordsSaved == 1 ? "" : "s") in your Keychain." : "Passwords were not imported; enter them when you log in.").foregroundStyle(.secondary)
        }.font(.system(size: 12.5)).padding(20).fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.message = "Choose WinSCP.ini, a .reg export, or a Wine user.reg"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        error = nil
        do {
            let parsed = try WinSCPImport.parse(Data(contentsOf: url), source: url)
            source = url; result = parsed
            // Sites that are already here are not selected, so importing again does not duplicate them.
            chosen = Set(parsed.sites.filter { existing($0) == nil }.map(\.id))
        } catch { self.error = error.localizedDescription }
    }

    /// The same site already saved: same name, protocol, host, port and user.
    private func existing(_ item: ImportedSite) -> Site? {
        model.sites.first { $0.name == item.site.name && $0.transferProtocol == item.site.transferProtocol && $0.host == item.site.host
            && $0.port == item.site.port && $0.username == item.site.username }
    }
    private func existingWithPasswords(_ result: WinSCPImportResult) -> [(Site, String)] {
        result.sites.compactMap { item in item.password.flatMap { password in existing(item).map { ($0, password) } } }
    }

    private func commit(_ result: WinSCPImportResult) {
        error = nil
        let picked = result.sites.filter { chosen.contains($0.id) }
        guard let summary = model.importFromWinSCP(picked, hostKeys: trustHostKeys ? result.hostKeys : []) else { error = model.error; return }
        if savePasswords {
            let imported = Set(summary.sites.map(\.id))
            let targets = picked.compactMap { item in item.password.flatMap { imported.contains(item.id) ? (item.id, $0) : nil } }
                + existingWithPasswords(result).map { ($0.0.id, $0.1) }
            for (site, password) in targets {
                do { try SavedPasswords.save(password, for: site); passwordsSaved += 1 } catch { self.error = error.localizedDescription }
            }
            model.refreshSavedPasswords()
            if passwordsSaved > 0 { model.appendLog("Saved \(passwordsSaved) imported password(s) in Keychain.") }
        }
        self.summary = summary
    }
}
