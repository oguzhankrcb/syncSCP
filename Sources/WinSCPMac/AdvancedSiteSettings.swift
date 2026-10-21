// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import WinSCPCore

/// WinSCP's Advanced Site Settings, page for page. Every control is either applied, or
/// disabled with a badge saying why: nothing is shown as editable that silently does nothing.
enum SettingsPage: String, Identifiable, Hashable {
    case environment, directories, recycleBin, encryption, sftp, shell, ftp, s3, webdav
    case connection, proxy, tunnel, tls, ssh, kex, authentication, bugs, note
    var id: String { rawValue }
    var title: String {
        switch self {
        case .environment: return "Environment"; case .directories: return "Directories"; case .recycleBin: return "Recycle bin"
        case .encryption: return "Encryption"; case .sftp: return "SFTP"; case .shell: return "SCP/Shell"; case .ftp: return "FTP"
        case .s3: return "S3"; case .webdav: return "WebDAV"; case .connection: return "Connection"; case .proxy: return "Proxy"
        case .tunnel: return "Tunnel"; case .tls: return "TLS/SSL"; case .ssh: return "SSH"; case .kex: return "Key exchange"
        case .authentication: return "Authentication"; case .bugs: return "Bugs"; case .note: return "Note"
        }
    }
    /// The same tree WinSCP shows for each protocol (page, indentation level).
    static func tree(for kind: TransferProtocol) -> [(page: SettingsPage, level: Int)] {
        var pages: [(SettingsPage, Int)] = [(.environment, 0), (.directories, 1), (.recycleBin, 1)]
        if kind == .sftp { pages += [(.encryption, 1), (.sftp, 1)] }
        if kind == .scp { pages += [(.shell, 1)] }
        if kind.usesFTP { pages += [(.ftp, 1)] }
        if kind.usesS3 { pages += [(.s3, 1)] }
        if kind.usesWebDAV { pages += [(.webdav, 1)] }
        pages += [(.connection, 0), (.proxy, 1), (.tunnel, 1)]
        if !kind.usesSSH, kind.isEncrypted { pages += [(.tls, 1)] }
        if kind.usesSSH { pages += [(.ssh, 0), (.kex, 1), (.authentication, 1), (.bugs, 1)] }
        pages += [(.note, 0)]
        return pages.map { (page: $0.0, level: $0.1) }
    }
}

enum SettingStatus: Equatable {
    case live, planned, notOpenSSH, notMacOS, alwaysOn, other(String)
    var badge: String? {
        switch self {
        case .live: return nil; case .planned: return "Planned"; case .notOpenSSH: return "Not available with OpenSSH"
        case .notMacOS: return "Not applicable on macOS"; case .alwaysOn: return "Always on"; case .other(let text): return text
        }
    }
}

private let settingsAccent = Color(red: 0.17, green: 0.42, blue: 0.85)

private struct Badge: View {
    let status: SettingStatus
    var body: some View {
        if let text = status.badge {
            Text(text).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(status == .planned ? settingsAccent : Color.secondary)
                .background((status == .planned ? settingsAccent.opacity(0.12) : Color.secondary.opacity(0.13)), in: RoundedRectangle(cornerRadius: 4))
                .help(help)
        }
    }
    private var help: String {
        switch status {
        case .planned: return "Stored with the site; this macOS port does not apply it yet."
        case .notOpenSSH: return "macOS uses OpenSSH, which has no equivalent of this PuTTY option."
        case .notMacOS: return "This option only affects Windows."
        case .alwaysOn: return "This port always behaves this way."
        default: return status.badge ?? ""
        }
    }
}

private struct Group<Content: View>: View {
    let title: String
    var status: SettingStatus = .live
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
                Badge(status: status)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09)))
                .disabled(status != .live && status != .alwaysOn)
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    var status: SettingStatus = .live
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 230, alignment: .leading).foregroundStyle(status == .live ? .primary : .secondary)
            content.disabled(status != .live)
            Badge(status: status)
        }
    }
}

private struct Check: View {
    let title: String
    @Binding var isOn: Bool
    var status: SettingStatus = .live
    var body: some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: status == .alwaysOn ? .constant(true) : $isOn).toggleStyle(.checkbox)
                .disabled(status != .live)
            Badge(status: status)
        }
    }
}

private struct TriPicker: View {
    @Binding var value: TriState
    var labels = ("Auto", "On", "Off")
    var body: some View {
        Picker("", selection: $value) { Text(labels.0).tag(TriState.auto); Text(labels.1).tag(TriState.on); Text(labels.2).tag(TriState.off) }
            .labelsHidden().fixedSize()
    }
}

/// Ordered policy list with WinSCP's Up/Down buttons and "warn below here" divider.
private struct PolicyList<Item: Hashable>: View {
    @Binding var items: [Item]
    let title: (Item) -> String
    let available: (Item) -> Bool
    let divider: Item
    @State private var selected: Item?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(items, id: \.self) { item in
                    let unavailable = item != divider && !available(item)
                    Button { selected = item } label: {
                        HStack {
                            Text(title(item)).foregroundStyle(item == divider || unavailable ? .secondary : .primary)
                            Spacer()
                            if unavailable { Text("not in macOS OpenSSH").font(.system(size: 9.5)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 8).frame(height: 22).contentShape(Rectangle())
                        .background(selected == item ? settingsAccent.opacity(0.18) : .clear)
                    }.buttonStyle(.plain)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            VStack(spacing: 6) {
                Button("Up") { move(-1) }.disabled(index == nil || index == 0)
                Button("Down") { move(1) }.disabled(index == nil || index == items.count - 1)
            }.frame(width: 70)
        }
    }
    private var index: Int? { selected.flatMap { items.firstIndex(of: $0) } }
    private func move(_ offset: Int) { guard let index else { return }; items.swapAt(index, index + offset) }
}

struct AdvancedSiteSettingsView: View {
    @Binding var site: Site
    var initialPage: SettingsPage?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Site()
    @State private var page: SettingsPage = .environment
    @State private var error: String?

    private var kind: TransferProtocol { draft.transferProtocol }
    private var s: Binding<SiteSettings> { $draft.settings }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: Binding(get: { page }, set: { if let value = $0 { page = value } })) {
                    ForEach(SettingsPage.tree(for: kind), id: \.page) { node in
                        Text(node.page.title).padding(.leading, CGFloat(node.level) * 14).tag(node.page)
                    }
                }
                .listStyle(.sidebar).frame(width: 200)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(page.title).font(.system(size: 17, weight: .semibold))
                        content
                    }
                    .font(.system(size: 12.5)).textFieldStyle(.roundedBorder)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack(spacing: 10) {
                colorMenu
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Link("Help", destination: URL(string: "https://winscp.net/eng/docs/ui_login_advanced")!).font(.system(size: 12))
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    do { try draft.settings.validate(); site = draft; dismiss() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(14)
        }
        .frame(width: 900, height: 640)
        .onAppear {
            draft = site
            let pages = SettingsPage.tree(for: site.transferProtocol).map(\.page)
            page = initialPage.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first ?? .environment
        }
    }

    private var colorMenu: some View {
        let colors: [(String, String)] = [("None", ""), ("Red", "#D9534F"), ("Orange", "#E8912D"), ("Yellow", "#D4B21F"), ("Green", "#3A9A4F"), ("Blue", "#2F6FDE"), ("Purple", "#8A55C7")]
        return Menu {
            ForEach(colors, id: \.1) { name, hex in Button(name) { draft.settings.color = hex } }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(SiteColor.color(draft.settings.color) ?? Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5))).frame(width: 12, height: 12)
                Text("Color")
            }
        }.fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .environment: environment
        case .directories: directories
        case .recycleBin: recycleBin
        case .encryption: encryption
        case .sftp: sftp
        case .shell: shell
        case .ftp: ftp
        case .s3: s3
        case .webdav: webdav
        case .connection: connection
        case .proxy: proxy
        case .tunnel: tunnel
        case .tls: tls
        case .ssh: ssh
        case .kex: kex
        case .authentication: authentication
        case .bugs: bugs
        case .note: note
        }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Server environment", status: .planned) {
                Field(label: "End-of-line characters (if not indicated by server)") {
                    Picker("", selection: s.eol) { Text("LF").tag(EOLType.lf); Text("CR/LF").tag(EOLType.crlf) }.labelsHidden().frame(width: 140)
                }
                Field(label: "UTF-8 encoding for filenames") { TriPicker(value: s.utf8) }
                Field(label: "Time zone offset") {
                    TextField("", value: s.timeOffsetMinutes, format: .number).frame(width: 70); Text("minutes").foregroundStyle(.secondary)
                    Toggle("Detect automatically", isOn: s.timeOffsetAuto).toggleStyle(.checkbox)
                }
                if kind.usesFTP { Check(title: "Trim VMS version numbers", isOn: s.trimVMSVersions) }
            }
            Group(title: "Daylight saving time", status: .notMacOS) {
                Picker("", selection: s.dstMode) {
                    Text("Adjust remote timestamp to local conventions").tag(DSTMode.unix)
                    Text("Adjust remote timestamp with DST").tag(DSTMode.win)
                }.pickerStyle(.radioGroup).labelsHidden()
            }
            if kind.usesSSH {
                Group(title: "PuTTY", status: .notOpenSSH) {
                    Field(label: "PuTTY terminal settings", status: .notOpenSSH) { Button("Edit in PuTTY…") {} }
                }
            }
        }
    }

    private var directories: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Directories") {
                Field(label: kind.usesS3 ? "Remote directory (bucket / folder)" : kind.usesWebDAV ? "Remote directory (WebDAV path)" : "Remote directory") {
                    TextField(kind.usesS3 ? "/ or /bucket" : kind.usesWebDAV ? "/dav/" : ".", text: $draft.remotePath)
                }
                Field(label: "Local directory") {
                    TextField("~", text: $draft.localPath)
                    Button("Choose…") { if let path = choose(directory: true, start: draft.localPath) { draft.localPath = path } }
                }
                Check(title: "Remember last used directory", isOn: s.rememberLastDirectory, status: .planned)
                Check(title: "Synchronize browsing", isOn: s.synchronizeBrowsing, status: .planned)
            }
            Group(title: "Directory reading options", status: .planned) {
                Check(title: "Cache visited remote directories", isOn: s.cacheDirectories)
                Check(title: "Cache directory changes", isOn: s.cacheDirectoryChanges)
                Check(title: "Permanent cache", isOn: s.permanentCache)
                if kind.usesSSH {
                    Check(title: "Resolve symbolic links", isOn: s.resolveSymlinks)
                    Check(title: "Follow symbolic links to directories", isOn: s.followDirectorySymlinks)
                }
            }
        }
    }

    private var recycleBin: some View {
        Group(title: "Recycle bin", status: .planned) {
            Check(title: "Preserve deleted remote files to recycle bin", isOn: s.deleteToRecycleBin)
            if kind == .sftp { Check(title: "Preserve overwritten remote files to recycle bin (SFTP only)", isOn: s.overwrittenToRecycleBin) }
            Field(label: "Remote recycle bin") { TextField("/tmp", text: s.recycleBinPath) }
        }
    }

    private var encryption: some View {
        Group(title: "Encryption options", status: .planned) {
            Check(title: "Encrypt files", isOn: s.encryptFiles)
            Field(label: "Encryption key") { SecureField("", text: .constant("")); Button("Generate Key") {} }
        }
    }

    private var sftp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Protocol options") {
                Field(label: "SFTP server") {
                    ComboField(text: s.sftpServer, placeholder: "Default (sftp subsystem)",
                               suggestions: ["", "sudo /usr/lib/openssh/sftp-server", "sudo /usr/libexec/openssh/sftp-server", "sudo /usr/lib/sftp-server"])
                }
                Text("A command instead of the subsystem runs through the login shell, so shell start-up files must print nothing. sudo must not prompt for a password (NOPASSWD).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Field(label: "Preferred SFTP protocol version", status: .other("Version 3 only")) {
                    Picker("", selection: s.sftpMaxVersion) { Text("3").tag(3) }.labelsHidden().fixedSize()
                }
                Field(label: "Canonicalize paths on the server", status: .planned) { TriPicker(value: s.canonicalizePaths) }
                Check(title: "Allow SCP fallback", isOn: s.allowSCPFallback, status: .planned)
                Check(title: "Use POSIX rename", isOn: s.usePosixRename, status: .other("Used for approved replacement"))
            }
            Group(title: "Detection of known bugs in SFTP servers", status: .planned) {
                Field(label: "Reverses order of link command arguments") { TriPicker(value: s.sftpBugSymlink) }
                Field(label: "Misinterprets file timestamps prior to 1970") { TriPicker(value: s.sftpBugSignedTimestamps) }
            }
        }
    }

    private var shell: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Shell") {
                Field(label: "Shell") {
                    ComboField(text: s.shell, placeholder: "Default", suggestions: ["", "/bin/bash", "/bin/ksh", "sudo su -", "sudo -s"])
                }
                Text("Every SCP command runs inside this shell, e.g. sudo su - to work as root. sudo must not prompt for a password (NOPASSWD).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Field(label: "Return code variable", status: .other("Exit status read from SSH")) {
                    TextField("Autodetect", text: s.returnCodeVariable).frame(width: 160)
                }
            }
            Group(title: "Directory listing", status: .other("Listings use stat, not ls")) {
                Field(label: "Listing command") { TextField("ls -la", text: s.listingCommand).frame(width: 160) }
                Check(title: "Ignore LS warnings", isOn: s.ignoreLsWarnings)
                Check(title: "Try to get full timestamp", isOn: s.scpFullTimestamp)
            }
            Group(title: "Other options") {
                Field(label: "Lookup user groups", status: .planned) { TriPicker(value: s.lookupUserGroups) }
                Check(title: "Clear aliases", isOn: s.clearAliases, status: .alwaysOn)
                Check(title: "Clear national variables", isOn: s.clearNationalVariables, status: .alwaysOn)
                Check(title: "Use scp2 with scp1 compatibility", isOn: s.scp1Compatibility, status: .notOpenSSH)
            }
        }
    }

    private var ftp: some View {
        Group(title: "Protocol options", status: .planned) {
            Field(label: "Post login commands") { TextEditor(text: s.ftpPostLoginCommands).frame(height: 54).border(Color.secondary.opacity(0.3)) }
            Field(label: "Support for listing of hidden files") { TriPicker(value: s.ftpListAll) }
            Field(label: "Use MLSD command for directory listing") { TriPicker(value: s.ftpUseMLSD) }
            Field(label: "Force IP address for passive mode connections") { TriPicker(value: s.ftpForcePassiveIP) }
            Field(label: "Use HOST command to select host on the server") { TriPicker(value: s.ftpUseHost) }
            Field(label: "Account") { TextField("", text: s.ftpAccount) }
            Check(title: "Display all file revisions on VMS servers", isOn: s.vmsAllRevisions)
        }
    }

    private var s3: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Protocol options") {
                Field(label: "Default region") { TextField("us-east-1", text: $draft.s3Region).frame(width: 180) }
                Field(label: "URL style") {
                    Picker("", selection: $draft.s3PathStyle) { Text("Virtual host").tag(false); Text("Path").tag(true) }.labelsHidden().frame(width: 180)
                }
                Check(title: "Requester pays", isOn: s.s3RequesterPays)
            }
            Group(title: "Authentication") {
                Field(label: "Session token", status: .other("Entered at login, never saved")) { SecureField("", text: .constant("")).frame(width: 180) }
                Field(label: "Role ARN", status: .planned) { TextField("arn:aws:iam::…", text: s.s3RoleARN) }
            }
        }
    }

    private var webdav: some View {
        Group(title: "Protocol options") {
            Check(title: "Tolerate non-encoded special characters in filenames", isOn: s.webdavLiberalEscaping, status: .planned)
            Check(title: "Allow redirects to other hosts", isOn: s.webdavCrossDomainRedirects, status: .other("Refused for security"))
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Connection") {
                if kind.usesFTP { Check(title: "Passive mode", isOn: s.passiveMode, status: .other("Always on; active mode planned")) }
                Check(title: "Optimize connection buffer size", isOn: s.optimizeBufferSize, status: kind.usesSSH ? .notOpenSSH : .other("Managed by libcurl"))
            }
            Group(title: "Timeouts") {
                Field(label: "Server response timeout") {
                    TextField("", value: s.timeoutSeconds, format: .number).frame(width: 70); Text("seconds").foregroundStyle(.secondary)
                }
            }
            if kind.usesSSH {
                Group(title: "Keepalives") {
                    Picker("", selection: s.keepalive) {
                        Text("Off").tag(KeepaliveMode.off)
                        Text("Sending of null SSH packets").tag(KeepaliveMode.nullPacket)
                        Text("Executing dummy protocol commands (planned)").tag(KeepaliveMode.dummyCommand).disabled(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    Field(label: "Seconds between keepalives") { TextField("", value: s.keepaliveSeconds, format: .number).frame(width: 70) }
                        .disabled(draft.settings.keepalive == .off)
                }
            } else {
                Group(title: "Keepalives", status: .planned) { Text("Off").foregroundStyle(.secondary) }
            }
            Group(title: "Internet protocol version") {
                Picker("", selection: s.addressFamily) {
                    Text("Auto").tag(AddressFamily.auto); Text("IPv4").tag(AddressFamily.ipv4); Text("IPv6").tag(AddressFamily.ipv6)
                }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
            }
        }
    }

    private var proxy: some View {
        let method = draft.settings.proxyMethod, ssh = kind.usesSSH
        return VStack(alignment: .leading, spacing: 16) {
            Group(title: "Proxy") {
                Field(label: "Proxy type") {
                    Picker("", selection: s.proxyMethod) {
                        Text("None").tag(ProxyMethod.none); Text("SOCKS4").tag(ProxyMethod.socks4); Text("SOCKS5").tag(ProxyMethod.socks5)
                        Text("HTTP").tag(ProxyMethod.http)
                        Text("Telnet (planned)").tag(ProxyMethod.telnet).disabled(true)
                        Text(ssh ? "Local" : "Local (SFTP/SCP only)").tag(ProxyMethod.local).disabled(!ssh)
                    }.labelsHidden().frame(width: 180)
                }
                if method != .none && method != .local {
                    Field(label: "Proxy hostname") {
                        TextField("", text: s.proxyHost)
                        Text("Port").foregroundStyle(.secondary)
                        TextField("", value: s.proxyPort, format: .number.grouping(.never)).frame(width: 70)
                    }
                    Field(label: "Username", status: .planned) { TextField("", text: s.proxyUsername) }
                    Field(label: "Password", status: .planned) { SecureField("", text: .constant("")) }
                }
            }
            if method != .none {
                Group(title: "Proxy settings") {
                    if method == .local {
                        Field(label: "Local proxy command") { TextField("/usr/bin/nc -X 5 -x proxy:1080 %host %port", text: s.proxyLocalCommand) }
                        Text("%host and %port are replaced with the server's address.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } else {
                        Field(label: "Do DNS name lookup at proxy end", status: ssh || method == .http ? .other("Decided by the proxy client") : .live) {
                            TriPicker(value: s.proxyDNS, labels: ("Auto", "Yes", "No"))
                        }
                    }
                    Check(title: "Consider proxying local host connections", isOn: s.proxyLocalhost)
                }
            }
        }
    }

    private var tunnel: some View {
        let live: SettingStatus = kind.usesSSH ? .live : .planned
        return VStack(alignment: .leading, spacing: 16) {
            Check(title: "Connect through SSH tunnel", isOn: s.tunnel, status: live)
            Group(title: "Host to setup tunnel on", status: live) {
                Field(label: "Hostname") {
                    TextField("bastion.example.com", text: s.tunnelHost)
                    Text("Port").foregroundStyle(.secondary)
                    TextField("", value: s.tunnelPort, format: .number.grouping(.never)).frame(width: 70)
                }
                Field(label: "Username") { TextField(draft.username, text: s.tunnelUsername) }
                Field(label: "Password", status: .planned) { SecureField("Use a key or the SSH agent", text: .constant("")) }
            }.disabled(!draft.settings.tunnel)
            Group(title: "Tunnel options", status: kind.usesSSH ? .other("Not needed: OpenSSH -W") : .planned) {
                Field(label: "Local tunnel port") { Picker("", selection: s.tunnelLocalPort) { Text("Autoselect").tag(0) }.labelsHidden().frame(width: 140) }
            }
            Group(title: "Tunnel authentication parameters", status: live) {
                Field(label: "Private key file") {
                    TextField("SSH agent or default keys", text: s.tunnelPrivateKey)
                    Button("Choose…") { if let path = choose(directory: false, start: "~/.ssh") { draft.settings.tunnelPrivateKey = path } }
                }
            }.disabled(!draft.settings.tunnel)
            if kind.usesSSH {
                Text("The tunnel host's key is verified like any server: you approve its fingerprint before the first connection.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var tls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "TLS options") {
                Field(label: "Minimum TLS version") {
                    Picker("", selection: s.tlsMinimum) { ForEach(TLSVersion.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 120)
                }
                Field(label: "Maximum TLS version") {
                    Picker("", selection: s.tlsMaximum) { ForEach(TLSVersion.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 120)
                }
                Check(title: "Reuse TLS session ID for data connections", isOn: s.tlsSessionReuse, status: .alwaysOn)
            }
            Group(title: "Authentication parameters") {
                Field(label: "Trusted CA certificate (PEM)") {
                    TextField("System trust (default)", text: $draft.certificateAuthorityFile)
                    Button("Choose…") { if let path = choose(directory: false, start: "~") { draft.certificateAuthorityFile = path } }
                }
                Field(label: "Client certificate file", status: .planned) { TextField("", text: s.tlsClientCertificate) }
            }
        }
    }

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Protocol options") { Check(title: "Enable compression", isOn: s.compression) }
            Group(title: "Encryption options") {
                Text("Encryption cipher selection policy:")
                PolicyList(items: s.ciphers, title: \.title, available: { !$0.openSSHNames.isEmpty }, divider: .warn)
                Text("OpenSSH cannot ask during the handshake, so ciphers below the warning line are not offered. The default order keeps OpenSSH's own defaults.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Check(title: "Enable legacy use of single-DES", isOn: s.legacySingleDES, status: .notOpenSSH)
            }
        }
    }

    private var kex: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group(title: "Key exchange algorithm options") {
                Text("Algorithm selection policy:")
                PolicyList(items: s.kex, title: \.title, available: { !$0.openSSHNames.isEmpty }, divider: .warn)
                Check(title: "Attempt GSSAPI key exchange", isOn: s.gssapiKeyExchange, status: .notOpenSSH)
            }
            Group(title: "Options controlling key re-exchange") {
                Field(label: "Max minutes before rekey (0 for no limit)") { TextField("", value: s.rekeyMinutes, format: .number).frame(width: 90) }
                Field(label: "Max data before rekey (0 for no limit)") { TextField("1G", text: s.rekeyData).frame(width: 90) }
            }
        }
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 16) {
            Check(title: "Bypass authentication entirely", isOn: s.bypassAuthentication, status: .planned)
            Group(title: "Authentication options") {
                Check(title: "Attempt authentication using agent", isOn: s.tryAgent)
                Check(title: "Attempt 'keyboard-interactive' authentication", isOn: s.keyboardInteractive)
                Check(title: "Respond with a password to the first prompt", isOn: s.keyboardInteractiveFirstPrompt, status: .alwaysOn).padding(.leading, 20)
            }
            Group(title: "Authentication parameters") {
                Check(title: "Allow agent forwarding", isOn: s.agentForwarding)
                Field(label: "Private key file") {
                    TextField("~/.ssh/id_ed25519", text: $draft.privateKey)
                    Button("Choose…") { if let path = choose(directory: false, start: "~/.ssh") { draft.privateKey = path } }
                }
                Field(label: "Certificate to use with the private key") {
                    TextField("", text: s.certificateFile)
                    Button("Choose…") { if let path = choose(directory: false, start: "~/.ssh") { draft.settings.certificateFile = path } }
                }
                Text("OpenSSH private keys only; convert PuTTY .ppk keys first.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Group(title: "GSSAPI") {
                Check(title: "Attempt GSSAPI authentication", isOn: s.gssapiAuthentication)
                Check(title: "Allow GSSAPI credential delegation", isOn: s.gssapiDelegation)
            }
        }
    }

    private var bugs: some View {
        let rows: [(String, WritableKeyPath<SiteSettings, TriState>)] = [
            ("Miscomputes SSH HMAC keys", \.bugHMAC2), ("Miscomputes SSH encryption keys", \.bugDeriveKey2),
            ("Requires padding on SSH RSA signatures", \.bugRSAPad2), ("Misuses the session ID in SSH PK auth", \.bugPKSessionID2),
            ("Handles SSH key re-exchange badly", \.bugRekey2), ("Ignores SSH maximum packet size", \.bugMaxPacket2),
            ("Chokes on SSH ignore messages", \.bugIgnore2), ("Chokes on WinSCP's SSH 'winadj' requests", \.bugWinAdj)]
        return VStack(alignment: .leading, spacing: 16) {
            Text("These are PuTTY workarounds for old SSH servers. macOS uses OpenSSH, which has no equivalent switches, so they are shown for parity and do not affect connections.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Group(title: "Detection of known bugs in SSH servers", status: .notOpenSSH) {
                ForEach(rows, id: \.0) { row in Field(label: row.0) { TriPicker(value: s[dynamicMember: row.1]) } }
            }
        }
    }

    private var note: some View {
        Group(title: "Note") {
            TextEditor(text: s.note).font(.system(size: 12.5)).frame(minHeight: 320)
        }
    }

    private func choose(directory: Bool, start: String) -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// An editable combo box like WinSCP's: free text plus common choices.
private struct ComboField: View {
    @Binding var text: String
    let placeholder: String
    let suggestions: [String]
    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
            Menu {
                ForEach(suggestions, id: \.self) { value in Button(value.isEmpty ? placeholder : value) { text = value } }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Common values")
        }
    }
}

enum SiteColor {
    static func color(_ hex: String) -> Color? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
