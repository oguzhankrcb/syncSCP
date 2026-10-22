// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import SyncSCPCore

enum PaneSide { case local, remote }
enum TransferDirection: String { case upload = "Upload", download = "Download" }
enum BottomTab: String, CaseIterable { case queue = "Transfer queue", editing = "Edited files", log = "Session log" }

/// A remote file open in an external application; saves are uploaded while it is watched.
struct ExternalEditItem: Identifiable {
    let id = UUID()
    let name: String
    let remotePath: String
    let application: String
    var status: String
    var conflict = false
}
enum JobState: String { case waiting = "Waiting", running = "Transferring", done = "Complete", failed = "Failed", cancelled = "Cancelled" }

/// What a job already finished, so a retry after a lost connection neither redoes nor refuses it.
final class TransferMemory {
    var completed = Set<String>()
    var createdDirectories = Set<String>()
    private var resumes: [String: TransferResume] = [:]
    func resume(_ destination: String) -> TransferResume {
        if let existing = resumes[destination] { return existing }
        let created = TransferResume(); resumes[destination] = created; return created
    }
}

struct TransferJob: Identifiable {
    let id = UUID()
    /// The session tab the job belongs to; it runs on its own background connection to that site.
    let session: UUID
    let siteName: String
    let direction: TransferDirection
    let entry: FileEntry
    let destination: String
    let replace: Bool
    let token = CancellationToken()
    var memory = TransferMemory()
    /// Keep up to date: missing remote folders between this root and the destination are created first.
    var createParentsBelow: String?
    var state = JobState.waiting
    var fraction = 0.0
    var detail = "Waiting"
}

/// One connection, like a WinSCP session tab. The active tab's state lives in the model's
/// published properties; the others keep a snapshot here until they are shown again.
struct SessionTab: Identifiable {
    let id: UUID
    let client: RemoteSession
    var site: Site
    var remotePath: String
    var remoteEntries: [FileEntry]
    var remoteSelection = Set<String>()
    var remoteHome: String
    var localPath: String
    let connectedAt = Date()
    var history: [PaneSide: (back: [String], forward: [String])] = [:]
    /// Kept in memory while the tab is open (like WinSCP) to open background transfer connections; never written anywhere.
    let password: String
    let sessionToken: String
}

/// A running `ssh -N -L` process for one port forward.
struct ActiveForward: Identifiable {
    let id = UUID()
    let site: Site
    let forward: PortForward
    let process = Process()
    let output = ForwardOutput()
    var state = "Starting…"
    var stopping = false
    var isRunning: Bool { process.isRunning }
}

/// ssh's error output for a forward, read on a background queue.
final class ForwardOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); data.append(value); if data.count > 8192 { data = data.suffix(8192) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct LogLine: Identifiable { let id = UUID(); let date = Date(); let text: String; let isError: Bool }

@MainActor
final class CommanderModel: ObservableObject {
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = ""
    @Published var localEntries: [FileEntry] = []
    @Published var remoteEntries: [FileEntry] = []
    @Published var localSelection = Set<String>()
    @Published var remoteSelection = Set<String>()
    @Published var activeSide = PaneSide.local
    @Published var showHidden = false
    @Published var filter = ""
    @Published var sites: [Site] = []
    @Published var connected = false
    @Published var connecting = false
    @Published var operationBusy = false
    @Published var currentSite: Site?
    @Published var showConnection = false
    @Published var requestedSite: Site?
    @Published var showBottom = true
    @Published var bottomTab = BottomTab.queue
    @Published var jobs: [TransferJob] = []
    @Published var log: [LogLine] = []
    @Published var error: String?
    @Published var status = "Ready"
    @Published var editor: RemoteDocument?
    @Published var syncItems: [SyncItem] = []
    @Published var showSync = false
    /// Back/forward history per pane, like WinSCP's navigation buttons.
    @Published private(set) var backHistory: [PaneSide: [String]] = [:]
    @Published private(set) var forwardHistory: [PaneSide: [String]] = [:]
    @Published private(set) var remoteHome = ""
    @Published private(set) var connectedAt: Date?
    @Published var showImport = false
    @Published var showPortForwarding = false
    @Published var activeForwards: [ActiveForward] = []
    @Published var snippets = TerminalSnippet.load() { didSet { TerminalSnippet.save(snippets) } }
    /// Saved sites that have a password in Keychain (Login ▸ Save password).
    @Published private(set) var sitesWithPasswords = Set<UUID>()
    @Published var externalEdits: [ExternalEditItem] = []
    /// Live external-edit sessions; each belongs to the connection it was opened on.
    private var editSessions: [UUID: (edit: RemoteEdit, monitor: FileChangeMonitor, session: UUID)] = [:]
    private var syncingEdits = Set<UUID>()
    static let externalEditorKey = "ExternalEditorPath"
    private var syncLocal = ""
    private var syncRemote = ""
    private var syncRemoteSnapshot: [String: FileEntry] = [:]
    private var syncLocalSnapshot: [String: FileEntry] = [:]
    private var syncSessionID = UUID()
    /// The active tab's id, or a fresh value while no tab is open, so stale results are dropped.
    private var sessionID = UUID()
    @Published private(set) var tabs: [SessionTab] = []
    @Published private(set) var activeTabID: UUID?
    private let idleClient = RemoteSession()
    /// The active tab's connection.
    var client: RemoteSession { tabs.first { $0.id == activeTabID }?.client ?? idleClient }
    private(set) var store: SiteStore?

    /// Transfers run on their own connections, so they do not make the panes busy.
    var busy: Bool { connecting || operationBusy }
    var runningQueue: Bool { jobs.contains { $0.state == .running } }
    static let maxTransfersKey = "MaxParallelTransfers", retriesKey = "TransferRetries"
    private var maxTransfers: Int { let value = UserDefaults.standard.integer(forKey: Self.maxTransfersKey); return value == 0 ? 2 : min(max(value, 1), 8) }
    private var maxRetries: Int { UserDefaults.standard.object(forKey: Self.retriesKey) == nil ? 3 : min(max(UserDefaults.standard.integer(forKey: Self.retriesKey), 0), 10) }
    /// Idle background transfer connections per session tab, reused by later jobs.
    private var idleTransferConnections: [UUID: [RemoteSession]] = [:]
    // The ".." row can be selected for navigation but is never part of an action.
    var canUpload: Bool { connected && !busy && !localSelection.subtracting([ParentRow.id]).isEmpty }
    var canDownload: Bool { connected && !busy && !remoteSelection.subtracting([ParentRow.id]).isEmpty }
    var activeSelection: [FileEntry] {
        let entries = activeSide == .local ? localEntries : remoteEntries
        let selection = activeSide == .local ? localSelection : remoteSelection
        return entries.filter { selection.contains($0.id) }
    }
    var pendingCount: Int { jobs.filter { $0.state == .waiting || $0.state == .running }.count }

    /// `store` is for tests and render harnesses; the app uses the default data folder.
    init(store custom: SiteStore? = nil) {
        if custom == nil { Self.migrateLegacyDefaults() }
        do { let store = try custom ?? SiteStore(); self.store = store; sites = try store.load() }
        catch { self.error = error.localizedDescription }
        if custom == nil { refreshSavedPasswords() }
        refreshLocal()
        appendLog("syncSCP 0.21.0 · Community development preview")
    }

    /// Carries preferences over from the bundle identifier used before the rename to syncSCP.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: externalEditorKey) == nil,
              let legacy = UserDefaults(suiteName: "org.winscp.community.mac")?.string(forKey: externalEditorKey) else { return }
        defaults.set(legacy, forKey: externalEditorKey)
    }

    func appendLog(_ text: String, error: Bool = false) {
        log.append(LogLine(text: text, isError: error))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    func report(_ failure: Error) {
        error = failure.localizedDescription; status = "Operation failed"
        appendLog(failure.localizedDescription, error: true)
        if case ClientError.connection = failure, let activeTabID { closeFailedConnection(activeTabID) }
    }

    private func closeFailedConnection(_ session: UUID) {
        guard tabs.contains(where: { $0.id == session }) else { return }
        closeTab(session, log: "Closed the failed transport connection.")
    }

    // MARK: Session tabs

    /// Keeps the shown state in the active tab before another tab is shown or opened.
    private func storeActiveTab() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }), let site = currentSite else { return }
        tabs[index].site = site; tabs[index].remotePath = remotePath; tabs[index].remoteEntries = remoteEntries
        tabs[index].remoteSelection = remoteSelection; tabs[index].remoteHome = remoteHome; tabs[index].localPath = localPath
        tabs[index].history = [.local: (backHistory[.local] ?? [], forwardHistory[.local] ?? []), .remote: (backHistory[.remote] ?? [], forwardHistory[.remote] ?? [])]
    }

    private func show(_ tab: SessionTab) {
        activeTabID = tab.id; sessionID = tab.id
        currentSite = tab.site; remotePath = tab.remotePath; remoteEntries = tab.remoteEntries; remoteSelection = tab.remoteSelection
        remoteHome = tab.remoteHome; connectedAt = tab.connectedAt; connected = true
        for side in [PaneSide.local, .remote] { backHistory[side] = tab.history[side]?.back ?? []; forwardHistory[side] = tab.history[side]?.forward ?? [] }
        if localPath != tab.localPath, FileManager.default.fileExists(atPath: tab.localPath) { localPath = tab.localPath; refreshLocal() }
        status = "Connected to \(tab.site.host)"
    }

    private func showNoSession() {
        activeTabID = nil; sessionID = UUID(); connected = false; currentSite = nil
        remoteEntries = []; remoteSelection = []; remotePath = ""; remoteHome = ""; connectedAt = nil
        backHistory[.remote] = []; forwardHistory[.remote] = []
    }

    /// A new tab can open while other tabs transfer files.
    var canConnect: Bool { !connecting && !operationBusy }
    var canSwitchTabs: Bool { tabs.count > 1 && !operationBusy && !connecting && editor == nil && !showSync }

    func activateTab(_ id: UUID) {
        guard id != activeTabID, !operationBusy, !connecting, let tab = tabs.first(where: { $0.id == id }) else { return }
        storeActiveTab(); show(tab)
    }

    /// ⌘⇧] / ⌘⇧[ — wraps around like Safari tabs.
    func activateNeighborTab(_ offset: Int) {
        guard canSwitchTabs, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activateTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// WinSCP's Duplicate Session: the login sheet with this site, so a password can be entered again.
    func duplicateSession() {
        guard let site = currentSite, canConnect, let tab = tabs.first(where: { $0.id == activeTabID }) else { return }
        connect(site: site, password: tab.password, sessionToken: tab.sessionToken)
    }

    /// Ends one connection: its queued transfers are cancelled and its edits stop (unsent changes are kept).
    func closeTab(_ id: UUID, log message: String = "Disconnected.") {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        stopEdits(of: id)
        jobs.filter { $0.session == id && ($0.state == .waiting || $0.state == .running) }.forEach { $0.token.cancel() }
        if id == activeTabID {
            if let next = tabs.indices.contains(index) ? tabs[index] : tabs.last { show(next) } else { showNoSession() }
        }
        appendLog("\(tab.site.displayName): \(message)")
        if tabs.isEmpty { status = "Disconnected" }
        if keepUpToDate?.session == id { stopKeepingUpToDate() }
        let idle = idleTransferConnections.removeValue(forKey: id) ?? []
        Task { await tab.client.disconnect(); for connection in idle { await connection.disconnect() } }
    }

    func saveSite(_ site: Site) {
        do {
            try site.validate()
            var updated = sites
            if let index = updated.firstIndex(where: { $0.id == site.id }) { updated[index] = site }
            else { updated.append(site) }
            guard let store else { throw ClientError.invalid("The site store is unavailable.") }
            try store.save(updated); sites = updated
        } catch { report(error) }
    }

    func refreshSavedPasswords() { sitesWithPasswords = SavedPasswords.sites(among: sites.map(\.id)) }

    func forgetPassword(_ site: UUID) {
        SavedPasswords.remove(site); refreshSavedPasswords()
        appendLog("Removed the saved password of \(sites.first { $0.id == site }?.displayName ?? "a site").")
    }

    /// Login: a typed password wins; otherwise a saved one is used (after Touch ID if Settings ask for it).
    /// `savePassword` stores the typed password in Keychain once the login succeeds.
    func login(site: Site, password: String, sessionToken: String = "", savePassword: Bool = false) {
        guard password.isEmpty, sitesWithPasswords.contains(site.id) else {
            connect(site: site, password: password, sessionToken: sessionToken, savePassword: savePassword); return
        }
        Task {
            guard await SavedPasswords.authorize("use the saved password for \(site.displayName)") else { status = "Login cancelled"; return }
            guard let saved = SavedPasswords.read(site.id) else {
                report(ClientError.invalid("The saved password for \(site.displayName) could not be read from Keychain. Type it again.")); return
            }
            connect(site: site, password: saved, sessionToken: sessionToken)
        }
    }
    /// Saves imported WinSCP sites, converted keys and host keys (see `WinSCPImport.commit`).
    func importFromWinSCP(_ chosen: [ImportedSite], hostKeys: [ImportedHostKey], passphrases: [String: String] = [:]) -> WinSCPImportSummary? {
        do {
            guard let store else { throw ClientError.invalid("The site store is unavailable.") }
            let summary = try WinSCPImport.commit(chosen, hostKeys: hostKeys, into: store, existing: sites, passphrases: passphrases,
                                                  protect: { [weak self] file, passphrase in try self?.protectKey(file, passphrase: passphrase) })
            sites = try store.load()
            appendLog("Imported \(summary.sites.count) WinSCP sites, \(summary.convertedKeys.count) converted keys and \(summary.hostKeysAdded) host keys.")
            return summary
        } catch { report(error); return nil }
    }

    /// Puts `passphrase` on a converted OpenSSH key; ssh-keygen reads it through the app's askpass.
    func protectKey(_ file: URL, passphrase: String) throws {
        let credential = try SessionCredential.store(passphrase)
        defer { _ = SessionCredential.remove(credential) }
        try OpenSSHKey.protect(file, askpass: ["SSH_ASKPASS": Bundle.main.executablePath ?? CommandLine.arguments[0], "SSH_ASKPASS_REQUIRE": "force",
                                               "DISPLAY": "syncscp:0", "SYNCSCP_ASKPASS_ID": credential])
    }

    /// Login ▸ Tools ▸ Convert PuTTY Key: writes the OpenSSH key (owner-only, with the same
    /// passphrase if it had one) into the app's keys folder and returns its path.
    func convertPuTTYKey(_ source: URL, passphrase: String?) throws -> String {
        guard let store else { throw ClientError.invalid("The site store is unavailable.") }
        let converted = try PuTTYKey.convert(String(contentsOf: source, encoding: .utf8), passphrase: passphrase)
        let keys = store.directory.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stem = source.deletingPathExtension().lastPathComponent
        var target = keys.appendingPathComponent(stem.isEmpty ? "converted-key" : stem), index = 2
        while FileManager.default.fileExists(atPath: target.path) { target = keys.appendingPathComponent("\(stem)-\(index)"); index += 1 }
        guard FileManager.default.createFile(atPath: target.path, contents: Data(converted.privateKey.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ClientError.invalid("Cannot write the converted key.")
        }
        do { if let passphrase, !passphrase.isEmpty { try protectKey(target, passphrase: passphrase) } }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        FileManager.default.createFile(atPath: target.path + ".pub", contents: Data(converted.publicKeyLine.utf8), attributes: [.posixPermissions: 0o644])
        appendLog("Converted PuTTY key \(source.lastPathComponent) to \(target.path)\(passphrase?.isEmpty == false ? " (still protected by its passphrase)" : "").")
        return target.path
    }

    // MARK: External editing (WinSCP's external editor)

    private var editsDirectory: URL? { store?.directory.appendingPathComponent("edits", isDirectory: true) }

    /// Downloads `entry`, opens it in `application` (or the file type's default app), and
    /// uploads each save while the file stays in Edited files.
    func editExternally(_ entry: FileEntry, with application: URL?) {
        guard connected, !busy, entry.isRegularFile, let directory = editsDirectory else { return }
        if let open = externalEdits.first(where: { $0.remotePath == entry.path }), let live = editSessions[open.id] {
            NSWorkspace.shared.open(live.edit.localFile); return
        }
        let generation = sessionID, client = client
        operationBusy = true
        Task {
            defer { operationBusy = false }
            do {
                let edit = try await RemoteEdit(client: client, entry: entry, directory: directory)
                let file = edit.localFile
                guard generation == sessionID else { await edit.discard(); return }
                guard let app = application ?? NSWorkspace.shared.urlForApplication(toOpen: file) else {
                    await edit.discard()
                    throw ClientError.unsupported("No application is set to open \(entry.name). Use Edit With ▸ Other Application….")
                }
                let item = ExternalEditItem(name: entry.name, remotePath: entry.path,
                                            application: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                                            status: "Watching for saves")
                let id = item.id
                let monitor = FileChangeMonitor(file: file) { [weak self] in Task { @MainActor [weak self] in self?.syncEdit(id) } }
                editSessions[id] = (edit, monitor, generation); externalEdits.append(item)
                bottomTab = .editing; showBottom = true
                appendLog("Editing \(entry.path) in \(item.application); saves are uploaded.")
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
            } catch { if generation == sessionID { report(error) } }
        }
    }

    func syncEdit(_ id: UUID) {
        guard let live = editSessions[id], !syncingEdits.contains(id) else { return }
        guard tabs.contains(where: { $0.id == live.session }) else { stopEditing(id, keepChanges: true); return }
        syncingEdits.insert(id)
        Task {
            defer { syncingEdits.remove(id) }
            do {
                switch try await live.edit.syncIfChanged() {
                case .unchanged, .missing: break
                case .uploaded:
                    setEditStatus(id, "Uploaded " + Date().formatted(date: .omitted, time: .standard))
                    appendLog("Uploaded edited \(live.edit.remotePath).")
                    if live.session == sessionID, RemotePath.parent(live.edit.remotePath) == remotePath, !busy { navigateRemote(remotePath, recordHistory: false) }
                case .conflict:
                    setEditStatus(id, "Changed on the server — not uploaded", conflict: true)
                    let alert = NSAlert(); alert.alertStyle = .warning
                    alert.messageText = "\((live.edit.remotePath as NSString).lastPathComponent) changed on the server"
                    alert.informativeText = "The server copy changed after you opened it. Overwrite it with your edited version?"
                    alert.addButton(withTitle: "Overwrite Server Version"); alert.addButton(withTitle: "Not Now")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    _ = try await live.edit.overwrite()
                    setEditStatus(id, "Uploaded " + Date().formatted(date: .omitted, time: .standard))
                    appendLog("Overwrote \(live.edit.remotePath) with the edited version.")
                }
            } catch {
                setEditStatus(id, "Upload failed: \(error.localizedDescription)", conflict: true)
                appendLog("\(live.edit.remotePath): \(error.localizedDescription)", error: true)
                if case ClientError.connection = error { closeFailedConnection(live.session) }
            }
        }
    }

    private func setEditStatus(_ id: UUID, _ text: String, conflict: Bool = false) {
        guard let index = externalEdits.firstIndex(where: { $0.id == id }) else { return }
        externalEdits[index].status = text; externalEdits[index].conflict = conflict
    }

    /// Stops watching. A copy with changes that were never uploaded is kept, never deleted.
    func stopEditing(_ id: UUID, keepChanges: Bool = false) {
        guard let live = editSessions.removeValue(forKey: id) else { externalEdits.removeAll { $0.id == id }; return }
        live.monitor.stop(); externalEdits.removeAll { $0.id == id }
        Task {
            if await live.edit.hasUnsyncedChanges {
                appendLog("Changes to \(live.edit.remotePath) were not uploaded; the copy was kept at \(live.edit.localFile.path).", error: true)
            } else { await live.edit.discard() }
        }
    }

    private func stopEdits(of session: UUID) { for (id, live) in editSessions where live.session == session { stopEditing(id, keepChanges: true) } }

    func deleteSite(_ id: UUID) {
        do { let updated = sites.filter { $0.id != id }; try store?.save(updated); sites = updated; SavedPasswords.remove(id); refreshSavedPasswords() }
        catch { report(error) }
    }

    /// Opens a new session tab; other tabs stay connected. For S3, `password` is the secret
    /// access key and `sessionToken` optional temporary credentials; neither is saved.
    func connect(site: Site, password: String, sessionToken: String = "", savePassword: Bool = false) {
        guard !connecting, !operationBusy else { return }
        let client = RemoteSession()
        connecting = true; status = "Connecting to \(site.host)…"
        Task {
            defer { connecting = false }
            do {
                try site.validate()
                // A tunnel's bastion is verified first; the target key is then read through it.
                guard try await confirmHostKeys(site) else { status = "Connection cancelled"; return }
                let home = try await open(client, site: site, password: password, sessionToken: sessionToken)
                let path = site.remotePath.isEmpty || site.remotePath == "." ? home : try await client.realpath(site.remotePath)
                let entries = try await client.list(path)
                storeActiveTab()
                let local = FileManager.default.fileExists(atPath: site.localPath) ? site.localPath : localPath
                let tab = SessionTab(id: UUID(), client: client, site: site, remotePath: path, remoteEntries: entries, remoteHome: home, localPath: local,
                                     password: password, sessionToken: sessionToken)
                tabs.append(tab); show(tab); showConnection = false
                if savePassword, !password.isEmpty, sites.contains(where: { $0.id == site.id }) {
                    do { try SavedPasswords.save(password, for: site.id); refreshSavedPasswords(); appendLog("Saved the password of \(site.displayName) in Keychain.") }
                    catch { appendLog(error.localizedDescription, error: true) }
                }
                let security = site.transferProtocol.usesSSH ? "Host key verified by OpenSSH." : site.transferProtocol == .s3http ? "Unencrypted S3 connection; requests are signed with SigV4." : !site.transferProtocol.isEncrypted ? "Unencrypted \(site.transferProtocol.shortTitle) connection." : "Server certificate and hostname verified; TLS required."
                appendLog("Connected to \(site.username)@\(site.host):\(site.port) using \(site.transferProtocol.title). \(security)")
            } catch {
                await client.disconnect()
                // A connection failure here belongs to the new tab only; the shown tab stays open.
                self.error = error.localizedDescription; status = "Connection failed"; appendLog(error.localizedDescription, error: true)
            }
        }
    }

    /// Connects `client` to an already trusted site. An SSH password reaches ssh through askpass
    /// from a Keychain item that exists only for the duration of the login.
    private func open(_ client: RemoteSession, site: Site, password: String, sessionToken: String) async throws -> String {
        var configuration: SSHConfiguration?
        var credential: String?
        defer {
            if let credential, !SessionCredential.remove(credential) {
                appendLog("Keychain could not remove the temporary SSH credential. Remove account \(credential) for service io.github.oguzhankrcb.syncscp.session using Keychain Access.", error: true)
            }
        }
        if site.transferProtocol.usesSSH {
            guard let store else { throw ClientError.invalid("The host key store is unavailable.") }
            if !password.isEmpty { credential = try SessionCredential.store(password) }
            configuration = SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path,
                                             askpassExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0], credentialID: credential)
        }
        return try await client.connect(site: site, password: password, sshConfiguration: configuration, s3SessionToken: sessionToken)
    }

    /// Closes the shown session tab.
    func disconnect() {
        guard !connecting, !operationBusy, let activeTabID else { return }
        closeTab(activeTabID)
    }

    func refreshLocal() {
        do {
            localEntries = try LocalFiles.list(localPath)
            localSelection.formIntersection(Set(localEntries.map(\.id)))
        } catch { report(error) }
    }

    func refresh() {
        refreshLocal()
        if connected { navigateRemote(remotePath) }
    }

    func navigateLocal(_ path: String, recordHistory: Bool = true) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        do {
            let entries = try LocalFiles.list(url.path)
            if recordHistory { record(.local, from: localPath, to: url.path) }
            localPath = url.path; localEntries = entries; localSelection = []
            rememberDirectories()
        } catch { report(error) }
    }

    private func record(_ side: PaneSide, from old: String, to new: String) {
        guard !old.isEmpty, old != new else { return }
        backHistory[side, default: []].append(old)
        if backHistory[side]!.count > 100 { backHistory[side]!.removeFirst() }
        forwardHistory[side] = []
    }
    func canGoBack(_ side: PaneSide) -> Bool { !(backHistory[side] ?? []).isEmpty }
    func canGoForward(_ side: PaneSide) -> Bool { !(forwardHistory[side] ?? []).isEmpty }
    /// Moves through history; the current folder goes onto the opposite stack only once the move succeeds.
    func goBack(_ side: PaneSide) { step(side, back: true) }
    func goForward(_ side: PaneSide) { step(side, back: false) }
    private func step(_ side: PaneSide, back: Bool) {
        guard let target = (back ? backHistory[side] : forwardHistory[side])?.last else { return }
        let current = side == .local ? localPath : remotePath
        let done: () -> Void = { [weak self] in
            guard let self else { return }
            if back { self.backHistory[side]?.removeLast(); self.forwardHistory[side, default: []].append(current) }
            else { self.forwardHistory[side]?.removeLast(); self.backHistory[side, default: []].append(current) }
        }
        if side == .local {
            let before = localPath
            navigateLocal(target, recordHistory: false)
            if localPath != before { done() }
        } else { navigateRemote(target, recordHistory: false, completion: done) }
    }
    func goUp(_ side: PaneSide) {
        let path = side == .local ? localPath : remotePath
        guard !path.isEmpty, path != "/", side == .local || connected else { return }
        activeSide = side
        side == .local ? navigateLocal(RemotePath.parent(path)) : navigateRemote(RemotePath.parent(path))
    }
    func goHome(_ side: PaneSide) {
        side == .local ? navigateLocal(FileManager.default.homeDirectoryForCurrentUser.path) : navigateRemote(remoteHome.isEmpty ? "/" : remoteHome)
    }

    func navigateRemote(_ path: String, recordHistory: Bool = true, completion: (() -> Void)? = nil) {
        guard connected, !operationBusy else { return }
        operationBusy = true
        let generation = sessionID
        Task {
            defer { operationBusy = false }
            do {
                let canonical = try await client.realpath(path)
                let entries = try await client.list(canonical)
                guard generation == sessionID else { return }
                if recordHistory { record(.remote, from: remotePath, to: canonical) }
                remotePath = canonical; remoteEntries = entries; remoteSelection = []
                rememberDirectories()
                completion?()
            } catch { if generation == sessionID { report(error) } }
        }
    }

    func open(_ entry: FileEntry, side: PaneSide) {
        activeSide = side
        if entry.isDirectory { side == .local ? navigateLocal(entry.path) : navigateRemote(entry.path) }
        else if entry.isSymbolicLink { report(ClientError.unsupported("Symbolic links are displayed but are not followed in this preview.")) }
        else if side == .local { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
        else { remoteSelection = [entry.id]; editSelected() }
    }

    /// Queues `chosen` (or the pane's selection) into the other pane's current folder.
    func transfer(_ direction: TransferDirection, entries chosen: [FileEntry]? = nil) {
        guard connected, !busy else { return }
        let entries = chosen ?? (direction == .upload ? localEntries.filter { localSelection.contains($0.id) } : remoteEntries.filter { remoteSelection.contains($0.id) })
        guard !entries.isEmpty else { return }
        let existing = direction == .upload ? remoteEntries : localEntries
        let conflicts = entries.filter { entry in existing.contains { $0.name == entry.name } }
        var replace = false
        if !conflicts.isEmpty {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Replace existing files?"
            alert.informativeText = "\(conflicts.count) selected item(s) already exist at the destination. Folders will be merged. Existing files inside selected folders may also be replaced."
            alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; replace = true
        }
        // A directory merge needs explicit approval even if its root did not exist at listing time.
        let siteName = currentSite?.displayName ?? ""
        for entry in entries {
            jobs.append(TransferJob(session: sessionID, siteName: siteName, direction: direction, entry: entry,
                                    destination: direction == .upload ? RemotePath.join(remotePath, entry.name) : URL(fileURLWithPath: localPath).appendingPathComponent(entry.name).path,
                                    replace: replace))
        }
        bottomTab = .queue; showBottom = true; scheduleQueue()
    }

    /// WinSCP's F5: copy the active pane's selection to the other pane.
    func copyToOtherPanel() { transfer(activeSide == .local ? .upload : .download) }
    var canCopyToOtherPanel: Bool { activeSide == .local ? canUpload : canDownload }

    /// Files or folders dropped from Finder (or the local pane) onto the remote pane.
    func uploadDropped(_ urls: [URL]) {
        let entries = urls.filter(\.isFileURL).compactMap { try? LocalFiles.info($0.path) }
        guard !entries.isEmpty else { return }
        activeSide = .remote
        transfer(.upload, entries: entries)
    }
    /// Remote items dragged onto the local pane; only entries of the current remote listing are accepted.
    func downloadDropped(_ paths: [String]) {
        let wanted = Set(paths)
        let entries = remoteEntries.filter { wanted.contains($0.path) }
        guard !entries.isEmpty else { return }
        activeSide = .local
        transfer(.download, entries: entries)
    }

    /// "Remember last used directory" (Advanced ▸ Directories) for saved sites.
    private func rememberDirectories() {
        guard connected, let site = currentSite, site.settings.rememberLastDirectory,
              let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        var saved = sites[index]
        guard saved.remotePath != remotePath || saved.localPath != localPath else { return }
        saved.remotePath = remotePath; saved.localPath = localPath
        do { try store?.save(sites.enumerated().map { $0.offset == index ? saved : $0.element }); sites[index] = saved; currentSite?.remotePath = remotePath; currentSite?.localPath = localPath }
        catch { appendLog("Could not remember the last directory: \(error.localizedDescription)", error: true) }
    }

    /// Starts waiting jobs up to the Settings limit; each runs on a background connection of its tab.
    private func scheduleQueue() {
        while jobs.filter({ $0.state == .running }).count < maxTransfers, let index = jobs.firstIndex(where: { $0.state == .waiting }) {
            if jobs[index].token.isCancelled { jobs[index].state = .cancelled; jobs[index].detail = "Cancelled"; continue }
            jobs[index].state = .running; jobs[index].detail = "Connecting…"
            let job = jobs[index]
            Task { await run(job) }
        }
    }

    private func updateJob(_ id: UUID, _ change: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// One job, retried on a fresh connection when the connection drops; SFTP continues partial files.
    private func run(_ job: TransferJob) async {
        appendLog("\(job.direction.rawValue) \(job.entry.path) → \(job.destination)")
        var attempt = 0
        while true {
            var connection: RemoteSession?
            do {
                try job.token.check()
                let client = try await acquireTransferConnection(job.session)
                connection = client
                updateJob(job.id) { $0.detail = "Transferring…" }
                if let root = job.createParentsBelow {
                    var folder = root
                    for part in RemotePath.parent(job.destination).dropFirst(root.count).split(separator: "/") {
                        folder = RemotePath.join(folder, String(part))
                        if try await !client.exists(folder) { try await client.mkdir(folder) }
                    }
                }
                try await transferTree(job.entry, destination: job.destination, job: job, client: client)
                releaseTransferConnection(client, session: job.session, healthy: true)
                updateJob(job.id) { $0.state = .done; $0.fraction = 1; $0.detail = "Complete" }
                appendLog("Transfer complete: \(job.entry.name)")
                break
            } catch {
                var lost = false
                if case ClientError.connection = error { lost = true }
                if let connection { releaseTransferConnection(connection, session: job.session, healthy: !lost) }
                if lost, !job.token.isCancelled, attempt < maxRetries, tabs.contains(where: { $0.id == job.session }) {
                    attempt += 1
                    let delay = min(2 * attempt, 10)
                    updateJob(job.id) { $0.detail = "Connection lost — retrying in \(delay) s (\(attempt) of \(self.maxRetries))" }
                    appendLog("\(job.entry.name): connection lost; retrying (\(attempt) of \(maxRetries)).", error: true)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    continue
                }
                updateJob(job.id) { $0.state = job.token.isCancelled ? .cancelled : .failed; $0.detail = error.localizedDescription }
                appendLog("\(job.entry.name): \(error.localizedDescription)", error: !job.token.isCancelled)
                break
            }
        }
        if job.session == sessionID {
            refreshLocal()
            if connected, !operationBusy { navigateRemote(remotePath, recordHistory: false) }
        }
        if !runningQueue && !jobs.contains(where: { $0.state == .waiting }) {
            status = jobs.contains(where: { $0.state == .failed }) ? "Transfers finished with errors — see queue" : "Transfers finished"
        }
        scheduleQueue()
    }

    private func acquireTransferConnection(_ session: UUID) async throws -> RemoteSession {
        guard let tab = tabs.first(where: { $0.id == session }) else { throw ClientError.cancelled }
        if var idle = idleTransferConnections[session], let connection = idle.popLast() {
            idleTransferConnections[session] = idle; return connection
        }
        let connection = RemoteSession()
        _ = try await open(connection, site: tab.site, password: tab.password, sessionToken: tab.sessionToken)
        return connection
    }

    private func releaseTransferConnection(_ connection: RemoteSession, session: UUID, healthy: Bool) {
        guard healthy, tabs.contains(where: { $0.id == session }) else { Task { await connection.disconnect() }; return }
        idleTransferConnections[session, default: []].append(connection)
    }

    private func transferTree(_ entry: FileEntry, destination: String, job: TransferJob, client: RemoteSession, depth: Int = 0) async throws {
        try job.token.check()
        guard depth < 64 else { throw ClientError.unsupported("Directory transfers are limited to 64 levels.") }
        guard entry.isDirectory || entry.isRegularFile else { throw ClientError.unsupported("Symbolic links and special files are not transferred: \(entry.name)") }
        if entry.isDirectory {
            let memory = job.memory
            if job.direction == .upload {
                if try await client.exists(destination) {
                    let target = try await client.stat(destination)
                    guard target.isDirectory, job.replace || memory.createdDirectories.contains(destination) else { throw ClientError.conflict("Destination exists: \(destination)") }
                } else { try await client.mkdir(destination); memory.createdDirectories.insert(destination) }
                for child in try LocalFiles.list(entry.path) { try await transferTree(child, destination: RemotePath.join(destination, child.name), job: job, client: client, depth: depth + 1) }
            } else {
                let manager = FileManager.default
                if manager.fileExists(atPath: destination) {
                    let attrs = try manager.attributesOfItem(atPath: destination)
                    guard attrs[.type] as? FileAttributeType == .typeDirectory, job.replace || memory.createdDirectories.contains(destination) else { throw ClientError.conflict("Destination exists: \(destination)") }
                } else { try manager.createDirectory(atPath: destination, withIntermediateDirectories: false); memory.createdDirectories.insert(destination) }
                for child in try await client.list(entry.path) {
                    try await transferTree(child, destination: URL(fileURLWithPath: destination).appendingPathComponent(child.name).path, job: job, client: client, depth: depth + 1)
                }
            }
        } else {
            guard !job.memory.completed.contains(destination) else { return }
            let resume = job.memory.resume(destination)
            let update: @Sendable (UInt64, UInt64) -> Void = { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }), self.jobs[index].state == .running else { return }
                    self.jobs[index].fraction = total == 0 ? 0 : Double(done) / Double(total)
                    self.jobs[index].detail = "\(entry.name) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: done), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))"
                }
            }
            if job.direction == .upload {
                try await client.upload(local: URL(fileURLWithPath: entry.path), remote: destination, replace: job.replace, token: job.token, resume: resume, progress: update)
            } else {
                try await client.download(remote: entry.path, local: URL(fileURLWithPath: destination), replace: job.replace, token: job.token, resume: resume, progress: update)
            }
            job.memory.completed.insert(destination)
        }
    }

    func cancelJob(_ id: UUID) { jobs.first(where: { $0.id == id })?.token.cancel() }
    func clearCompleted() { jobs.removeAll { $0.state != .waiting && $0.state != .running } }

    /// Puts a failed or cancelled job back in the queue; a folder skips the files it already finished.
    func retryJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .failed || job.state == .cancelled,
              tabs.contains(where: { $0.id == job.session }) else { return }
        var again = TransferJob(session: job.session, siteName: job.siteName, direction: job.direction, entry: job.entry, destination: job.destination, replace: job.replace)
        again.memory = job.memory; again.detail = "Waiting"
        jobs.removeAll { $0.id == id }; jobs.append(again)
        scheduleQueue()
    }

    func promptMkdir() {
        guard !busy, activeSide == .local || connected else { return }
        guard let name = prompt(title: "New directory", value: "New folder") else { return }
        let side = activeSide
        perform {
            try RemotePath.validateName(name)
            if side == .local { try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: self.localPath).appendingPathComponent(name).path, withIntermediateDirectories: false) }
            else { try await self.client.mkdir(RemotePath.join(self.remotePath, name)) }
        }
    }

    func promptRename() {
        guard !busy, activeSelection.count == 1, let entry = activeSelection.first else { return }
        guard let name = prompt(title: "Rename \(entry.name)", value: entry.name), name != entry.name else { return }
        let side = activeSide
        perform {
            try RemotePath.validateName(name)
            if side == .local {
                try FileManager.default.moveItem(atPath: entry.path, toPath: URL(fileURLWithPath: entry.path).deletingLastPathComponent().appendingPathComponent(name).path)
            } else { try await self.client.rename(entry.path, to: RemotePath.join(RemotePath.parent(entry.path), name)) }
        }
    }

    func deleteSelected() {
        guard !busy, !activeSelection.isEmpty else { return }
        let entries = activeSelection; let side = activeSide
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = side == .local ? "Move \(entries.count) item(s) to Trash?" : "Permanently delete \(entries.count) remote item(s)?"
        alert.informativeText = side == .local ? "You can restore these files from Trash." : "Selected directories and their contents will be deleted from the server. This cannot be undone."
        alert.addButton(withTitle: side == .local ? "Move to Trash" : "Delete Permanently"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            for entry in entries {
                if side == .local { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
                else { try await self.client.remove(entry.path, recursive: true) }
            }
        }
    }


    // MARK: Bookmarks

    @Published var localBookmarks = UserDefaults.standard.stringArray(forKey: "LocalBookmarks") ?? [] {
        didSet { UserDefaults.standard.set(localBookmarks, forKey: "LocalBookmarks") }
    }
    var remoteBookmarks: [String] { currentSite?.settings.bookmarks ?? [] }

    /// Go ▸ Bookmark This Folder: the active panel's folder; remote bookmarks belong to the site.
    func bookmarkCurrentFolder() {
        if activeSide == .local {
            guard !localBookmarks.contains(localPath) else { return }
            localBookmarks.append(localPath); appendLog("Bookmarked \(localPath).")
        } else if let site = currentSite, !remotePath.isEmpty, !site.settings.bookmarks.contains(remotePath) {
            setBookmarks(site.settings.bookmarks + [remotePath], for: site.id); appendLog("Bookmarked \(remotePath) for \(site.displayName).")
        }
    }

    func removeBookmark(_ path: String, side: PaneSide) {
        if side == .local { localBookmarks.removeAll { $0 == path } }
        else if let site = currentSite { setBookmarks(site.settings.bookmarks.filter { $0 != path }, for: site.id) }
    }

    private func setBookmarks(_ bookmarks: [String], for siteID: UUID) {
        if var saved = sites.first(where: { $0.id == siteID }) { saved.settings.bookmarks = bookmarks; saveSite(saved) }
        if currentSite?.id == siteID { currentSite?.settings.bookmarks = bookmarks }
        for index in tabs.indices where tabs[index].site.id == siteID { tabs[index].site.settings.bookmarks = bookmarks }
    }

    // MARK: Quick Look and Quick Open

    @Published var quickLookURL: URL?
    @Published var showQuickOpen = false
    private var quickLookFolder: URL?

    /// ⌘Y: previews the selected file; a remote file (up to 200 MB) is downloaded to a private temporary folder first.
    func quickLookSelected() {
        guard let entry = activeSelection.first(where: { $0.isRegularFile }), !busy else { return }
        if activeSide == .local { quickLookURL = URL(fileURLWithPath: entry.path); return }
        guard entry.size <= 200 * 1024 * 1024 else { report(ClientError.unsupported("Quick Look downloads files up to 200 MB. Download \(entry.name) instead.")); return }
        endQuickLook()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-preview-" + UUID().uuidString, isDirectory: true)
        quickLookFolder = folder
        perform {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(entry.name)
            try await self.client.download(remote: entry.path, local: file)
            self.quickLookURL = file
        }
    }

    /// Removes a downloaded preview once Quick Look closes.
    func endQuickLook() {
        if let folder = quickLookFolder { try? FileManager.default.removeItem(at: folder); quickLookFolder = nil }
    }

    /// Quick Open: a site logs in straight away when it needs no typed password; otherwise Login opens with it.
    func quickConnect(_ site: Site) {
        let ready = sitesWithPasswords.contains(site.id) || (site.transferProtocol.usesSSH && !site.privateKey.isEmpty)
        if ready { login(site: site, password: "") } else { requestedSite = site; showConnection = true }
    }

    // MARK: Compare Directories

    enum CompareMark { case newer, older, different, onlyHere }
    /// WinSCP's Compare Directories: files in the two folders shown are marked against each other by name.
    @Published var compareDirectories = false
    /// View ▸ Directory Tree beside both panels.
    @Published var showTree = UserDefaults.standard.bool(forKey: "ShowDirectoryTree") { didSet { UserDefaults.standard.set(showTree, forKey: "ShowDirectoryTree") } }

    func compareMark(_ entry: FileEntry, side: PaneSide) -> CompareMark? {
        guard compareDirectories, connected, entry.path != ParentRow.id else { return nil }
        let others = side == .local ? remoteEntries : localEntries
        guard let other = others.first(where: { $0.name == entry.name }) else { return .onlyHere }
        guard !entry.isDirectory, !other.isDirectory else { return entry.isDirectory == other.isDirectory ? nil : .different }
        if let mine = entry.modified, let theirs = other.modified, abs(mine.timeIntervalSince(theirs)) >= 2 { return mine > theirs ? .newer : .older }
        return entry.size == other.size ? nil : .different
    }

    // MARK: Permissions (WinSCP's Properties for several files)

    @Published var permissionsTarget: [FileEntry]?

    func promptPermissions() {
        guard !busy, activeSide == .remote, currentSite?.transferProtocol.supportsPermissions != false else { return }
        let chosen = activeSelection.filter { $0.path != ParentRow.id }
        guard !chosen.isEmpty else { return }
        permissionsTarget = chosen
    }

    /// Sets `mode` on each entry; with `recursive`, also inside folders. Folders get execute bits
    /// wherever read is allowed when `addExecuteToFolders` is on, so they stay openable.
    func applyPermissions(_ entries: [FileEntry], mode: UInt32, recursive: Bool, addExecuteToFolders: Bool) {
        permissionsTarget = nil
        let folderMode: UInt32 = addExecuteToFolders ? mode | ((mode & 0o444) >> 2) : mode
        perform {
            var changed = 0
            func apply(_ entry: FileEntry, depth: Int) async throws {
                guard depth < 64 else { throw ClientError.unsupported("Permissions are applied at most 64 folder levels deep.") }
                if entry.isSymbolicLink { return }
                try await self.client.chmod(entry.path, mode: entry.isDirectory ? folderMode : mode); changed += 1
                if recursive, entry.isDirectory { for child in try await self.client.list(entry.path) { try await apply(child, depth: depth + 1) } }
            }
            for entry in entries { try await apply(entry, depth: 0) }
            self.appendLog("Set permissions \(String(mode, radix: 8)) on \(changed) item(s).")
        }
    }

    // MARK: Remote copy and move

    /// WinSCP's Duplicate (⇧F5): copies the remote selection on the server.
    func duplicateRemote() {
        guard !busy, connected, activeSide == .remote else { return }
        let chosen = activeSelection.filter { $0.path != ParentRow.id }
        guard !chosen.isEmpty else { return }
        let single = chosen.count == 1 ? chosen[0] : nil
        let suggestion = single.map { RemotePath.join(remotePath, Self.copyName($0.name)) } ?? remotePath
        guard let target = prompt(title: single == nil ? "Duplicate \(chosen.count) items into folder" : "Duplicate \(single!.name) as", value: suggestion)?
            .trimmingCharacters(in: .whitespaces), !target.isEmpty else { return }
        let destination = target.hasPrefix("/") ? target : RemotePath.join(remotePath, target)
        perform {
            for entry in chosen {
                let to = single == nil ? RemotePath.join(destination, entry.name) : destination
                try await self.client.copy(entry.path, to: to)
                self.appendLog("Duplicated \(entry.path) → \(to)")
            }
        }
    }

    /// WinSCP's Move To (⇧F6): renames the remote selection into another folder or path.
    func moveRemote() {
        guard !busy, connected, activeSide == .remote else { return }
        let chosen = activeSelection.filter { $0.path != ParentRow.id }
        guard !chosen.isEmpty else { return }
        guard let target = prompt(title: chosen.count == 1 ? "Move \(chosen[0].name) to folder or new path" : "Move \(chosen.count) items to folder", value: remotePath)?
            .trimmingCharacters(in: .whitespaces), !target.isEmpty else { return }
        let destination = target.hasPrefix("/") ? target : RemotePath.join(remotePath, target)
        perform {
            // An existing folder receives the items; otherwise a single item is renamed to that path.
            var intoFolder = false
            if try await self.client.exists(destination) { intoFolder = try await self.client.stat(destination, followLinks: true).isDirectory }
            guard intoFolder || chosen.count == 1 else { throw ClientError.invalid("\(destination) is not an existing folder.") }
            for entry in chosen {
                let to = intoFolder ? RemotePath.join(destination, entry.name) : destination
                guard to != entry.path else { continue }
                guard !to.hasPrefix(entry.path + "/") else { throw ClientError.invalid("A folder cannot be moved into itself.") }
                try await self.client.rename(entry.path, to: to)
                self.appendLog("Moved \(entry.path) → \(to)")
            }
        }
    }

    static func copyName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        return ext.isEmpty || stem.isEmpty ? name + " copy" : stem + " copy." + ext
    }

    // MARK: Find Files

    @Published var showFindFiles = false
    @Published private(set) var findResults: [FileEntry] = []
    @Published private(set) var findRunning = false
    @Published private(set) var findStatus = ""
    private var findToken = CancellationToken()

    /// Searches below `folder` for names matching any of `masks` (`*.log; *.conf`, case-insensitive).
    func findFiles(masks: String, in folder: String) {
        let patterns = masks.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard connected, !busy, !patterns.isEmpty else { return }
        findToken = CancellationToken(); let token = findToken
        findResults = []; findRunning = true; operationBusy = true; findStatus = "Searching…"
        Task {
            var visited = 0
            do { try await findWalk(folder, patterns: patterns, token: token, depth: 0, visited: &visited); findStatus = "\(findResults.count) found in \(visited) folder(s)" }
            catch ClientError.cancelled { findStatus = "Stopped: \(findResults.count) found" }
            catch { findStatus = error.localizedDescription }
            findRunning = false; operationBusy = false
        }
    }

    private func findWalk(_ path: String, patterns: [String], token: CancellationToken, depth: Int, visited: inout Int) async throws {
        try token.check()
        guard depth < 32, visited < 20_000 else { return }
        visited += 1; findStatus = "Searching \(path)"
        let entries: [FileEntry]
        do { entries = try await client.list(path) } catch ClientError.remote { return } // unreadable folders are skipped
        for entry in entries {
            if patterns.contains(where: { fnmatch($0, entry.name, FNM_CASEFOLD) == 0 }) { findResults.append(entry) }
            if entry.isDirectory { try await findWalk(entry.path, patterns: patterns, token: token, depth: depth + 1, visited: &visited) }
        }
    }

    func stopFindingFiles() { findToken.cancel() }

    /// Opens a result's folder and selects it.
    func reveal(_ entry: FileEntry) {
        activeSide = .remote; showFindFiles = false
        navigateRemote(RemotePath.parent(entry.path)) { [weak self] in self?.remoteSelection = [entry.path] }
    }

    // MARK: Directory tree

    /// Subfolders for the directory tree, read without making the panes busy.
    func subfolders(of path: String, side: PaneSide) async -> [FileEntry] {
        if side == .local {
            return ((try? LocalFiles.list(path)) ?? []).filter { $0.isDirectory && (showHidden || !$0.isHidden) }
        }
        guard connected else { return [] }
        return ((try? await client.list(path)) ?? []).filter { $0.isDirectory && (showHidden || !$0.isHidden) }
    }

    /// WinSCP's New ▸ File (Shift+F4): creates an empty file without replacing an existing one,
    /// then selects it; a new remote file opens in the editor right away.
    func promptNewFile() {
        guard !busy, activeSide == .local || connected else { return }
        guard let name = prompt(title: "New file", value: "new file.txt") else { return }
        let side = activeSide
        operationBusy = true
        Task {
            do {
                try RemotePath.validateName(name)
                if side == .local {
                    let path = URL(fileURLWithPath: localPath).appendingPathComponent(name).path
                    let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                    guard descriptor >= 0 else {
                        if errno == EEXIST { throw ClientError.conflict("\(name) already exists.") }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    Darwin.close(descriptor)
                    operationBusy = false
                    navigateLocal(localPath, recordHistory: false); localSelection = [path]
                    appendLog("Created \(path).")
                } else {
                    let target = RemotePath.join(remotePath, name)
                    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-new-" + UUID().uuidString)
                    guard FileManager.default.createFile(atPath: empty.path, contents: Data(), attributes: [.posixPermissions: 0o644]) else {
                        throw ClientError.invalid("Cannot create a temporary empty file.")
                    }
                    defer { try? FileManager.default.removeItem(at: empty) }
                    // No-clobber upload: an existing file of that name is never replaced.
                    try await client.upload(local: empty, remote: target, replace: false)
                    operationBusy = false
                    appendLog("Created \(target).")
                    navigateRemote(remotePath, recordHistory: false) { [weak self] in
                        guard let self else { return }
                        self.activeSide = .remote; self.remoteSelection = [target]; self.editSelected()
                    }
                }
            } catch { operationBusy = false; report(error) }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; operationBusy = true
        Task {
            do { try await operation(); status = "Operation complete" }
            catch { report(error) }
            operationBusy = false; refresh()
        }
    }

    private func prompt(title: String, value: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// `builtIn` ignores the default external editor (Edit With ▸ Built-in Editor).
    func editSelected(builtIn: Bool = false) {
        guard !busy, let entry = activeSelection.first, activeSelection.count == 1, !entry.isDirectory else { return }
        if activeSide == .local { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)); return }
        if !builtIn, let path = UserDefaults.standard.string(forKey: Self.externalEditorKey), !path.isEmpty, entry.isRegularFile {
            editExternally(entry, with: URL(fileURLWithPath: path)); return
        }
        guard !entry.isSymbolicLink, entry.size <= 4 * 1024 * 1024 else { report(ClientError.unsupported("The built-in editor supports regular UTF-8 files up to 4 MB. Use Edit With to open this file in another application.")); return }
        perform {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let opened = try await self.client.stat(entry.path)
            try await self.client.download(remote: entry.path, local: temporary)
            let data = try Data(contentsOf: temporary)
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ClientError.unsupported("The built-in editor supports UTF-8 text files.") }
            guard try await self.client.stat(entry.path).hasSameVersion(as: opened) else {
                throw ClientError.conflict("The remote file changed while the editor was opening. Open it again.")
            }
            self.editor = RemoteDocument(entry: opened, text: text, sessionID: self.sessionID)
        }
    }

    func saveDocument(_ document: RemoteDocument, text: String) {
        guard !busy, connected else { return }
        guard document.sessionID == sessionID else { report(ClientError.conflict("The remote session changed. Reopen the file before saving.")); return }
        perform {
            let current = try await self.client.stat(document.entry.path)
            guard current.hasSameVersion(as: document.entry) else {
                throw ClientError.conflict("The remote file changed after it was opened. Close the editor and reopen the file before saving.")
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Data(text.utf8).write(to: temporary, options: .atomic)
            try await self.client.upload(local: temporary, remote: document.entry.path, replace: true, expectedDestination: document.entry)
            self.editor = nil; self.appendLog("Saved remote text file: \(document.entry.path)")
        }
    }

    var canOpenTerminal: Bool { connected && currentSite?.transferProtocol.usesSSH == true }

    /// WinSCP's Open Terminal: a separate SSH login to the current site, starting in the remote
    /// folder shown in the panel. Each pane or tab logs in on its own.
    func openTerminal(inTerminalApp: Bool = false) {
        guard canOpenTerminal, let site = currentSite else { return }
        openTerminal(site: site, directory: remotePath, password: tabs.first { $0.id == activeTabID }?.password ?? "", inTerminalApp: inTerminalApp)
    }

    /// Login ▸ Terminal: no file session; the host key is checked first, like a login.
    func openTerminal(fromLogin site: Site, password: String) {
        guard site.transferProtocol.usesSSH, !connecting else { return }
        Task {
            do {
                try site.validate()
                guard try await confirmHostKeys(site) else { status = "Terminal cancelled"; return }
                showConnection = false
                let start = site.remotePath.isEmpty || site.remotePath == "." ? nil : site.remotePath
                openTerminal(site: site, directory: start, password: password, inTerminalApp: false)
            } catch { report(error) }
        }
    }

    private func openTerminal(site: Site, directory: String?, password: String, inTerminalApp: Bool) {
        let title = "\(site.username)@\(site.host)"
        guard inTerminalApp else {
            TerminalWindowController.open(title: title, launcher: terminalLauncher(site, directory: directory, password: password))
            appendLog("Opened a terminal to \(title)\(directory.map { " in \($0)" } ?? "").")
            return
        }
        do {
            guard let store else { return }
            let launch = try SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path).terminalLaunch(directory: directory)
            guard let terminalApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw ClientError.invalid("Terminal.app was not found.")
            }
            // A private, self-deleting .command file: Terminal.app runs it without any automation permission.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-terminal-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("ssh.command")
            try Data(launch.commandFile.utf8).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open([file], withApplicationAt: terminalApp, configuration: NSWorkspace.OpenConfiguration())
            appendLog("Opened \(title) in Terminal.app.")
        } catch { report(error) }
    }

    /// A known password (the tab's, the one typed at Login, or a saved one after Touch ID) logs
    /// each terminal in through askpass; its temporary Keychain item lives until that ssh ends.
    private func terminalLauncher(_ site: Site, directory: String?, password: String) -> TerminalLauncher {
        return { [weak self] deliver in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                var secret = password
                if secret.isEmpty, self.sitesWithPasswords.contains(site.id),
                   await SavedPasswords.authorize("log in to \(site.displayName) in a terminal"), let saved = SavedPasswords.read(site.id) { secret = saved }
                do {
                    let credential = secret.isEmpty ? nil : try SessionCredential.store(secret)
                    let launch = try SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path,
                                                      askpassExecutable: credential == nil ? nil : Bundle.main.executablePath ?? CommandLine.arguments[0],
                                                      credentialID: credential).terminalLaunch(directory: directory)
                    deliver(launch, credential.map { id in { _ = SessionCredential.remove(id) } })
                } catch { self.report(error) }
            }
        }
    }

    /// Asks before trusting an unknown host key (the tunnel's bastion first); false if the user declines.
    private func confirmHostKeys(_ site: Site) async throws -> Bool {
        guard site.transferProtocol.usesSSH else { return true }
        guard let store else { throw ClientError.invalid("The host key store is unavailable.") }
        let probe = SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path)
        for (target, role) in [(probe.tunnelSite, "tunnel host"), (site, "SSH server")] {
            guard let target, try await !HostTrust.isKnown(target, file: store.knownHostsFile) else { continue }
            let identity = try await HostTrust.scan(target, knownHostsFile: store.knownHostsFile)
            let alert = NSAlert()
            alert.messageText = "Trust this \(role)?"
            alert.informativeText = "\(identity.host)\n\(identity.algorithm)\n\n\(identity.fingerprint)\n\nVerify this fingerprint with the server administrator before connecting."
            alert.addButton(withTitle: "Trust and Connect"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            try HostTrust.trust(identity, file: store.knownHostsFile)
        }
        return true
    }

    // MARK: Port forwarding

    /// Saves a site's port-forward list (and keeps open tabs of that site in step).
    func setPortForwards(_ forwards: [PortForward], for siteID: UUID) {
        if var saved = sites.first(where: { $0.id == siteID }) { saved.settings.portForwards = forwards; saveSite(saved) }
        if currentSite?.id == siteID { currentSite?.settings.portForwards = forwards }
        for index in tabs.indices where tabs[index].site.id == siteID { tabs[index].site.settings.portForwards = forwards }
    }

    /// Starts `ssh -N -L` for one forward; the tab's or a saved password logs it in through askpass.
    func startForward(_ forward: PortForward, site: Site) {
        guard !activeForwards.contains(where: { $0.forward.id == forward.id && $0.isRunning }) else { return }
        Task {
            do {
                try site.validate(); try forward.validate()
                guard let store, try await confirmHostKeys(site) else { return }
                var secret = tabs.first { $0.site.id == site.id }?.password ?? ""
                if secret.isEmpty, sitesWithPasswords.contains(site.id),
                   await SavedPasswords.authorize("open a port forward to \(site.displayName)"), let saved = SavedPasswords.read(site.id) { secret = saved }
                let credential = secret.isEmpty ? nil : try SessionCredential.store(secret)
                let configuration = SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path,
                                                     askpassExecutable: credential == nil ? nil : Bundle.main.executablePath ?? CommandLine.arguments[0], credentialID: credential)
                let active = ActiveForward(site: site, forward: forward)
                let process = active.process, errors = Pipe(), output = active.output
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = try configuration.forwardArguments(forward)
                process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SYNCSCP_") && !$0.key.hasPrefix("SSH_ASKPASS") }
                    .merging(configuration.environment) { _, configured in configured }
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
                errors.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { output.append(data) }
                }
                let id = active.id
                let release = { if let credential { _ = SessionCredential.remove(credential) } }
                process.terminationHandler = { [weak self] ended in
                    Task { @MainActor [weak self] in
                        release()
                        guard let self, let index = self.activeForwards.firstIndex(where: { $0.id == id }) else { return }
                        let detail = output.text.isEmpty ? "ssh exited with status \(ended.terminationStatus)" : output.text
                        self.activeForwards[index].state = self.activeForwards[index].stopping ? "Stopped" : "Failed: \(detail)"
                        if !self.activeForwards[index].stopping { self.appendLog("Port forward \(forward.summary) via \(site.host) ended: \(detail)", error: true) }
                    }
                }
                try process.run()
                activeForwards.append(active)
                appendLog("Starting port forward \(forward.summary) via \(site.username)@\(site.host).")
                // Authentication is long over after a few seconds; a forward that survives is listening.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { release() }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let index = activeForwards.firstIndex(where: { $0.id == id }), process.isRunning { activeForwards[index].state = "Active" }
            } catch { report(error) }
        }
    }

    func stopForward(_ id: UUID) {
        guard let index = activeForwards.firstIndex(where: { $0.id == id }) else { return }
        activeForwards[index].stopping = true
        if activeForwards[index].process.isRunning { activeForwards[index].process.terminate() } else { activeForwards.remove(at: index) }
    }

    func clearEndedForwards() { activeForwards.removeAll { !$0.isRunning } }

    /// On quit: forwards are child ssh processes and would otherwise outlive the app.
    func stopAllForwards() { for forward in activeForwards where forward.isRunning { forward.process.terminate() } }

    @Published var syncOptions = SyncOptions()

    // MARK: Keep Remote Directory up to Date

    /// WinSCP's Keep Remote Directory up to Date: local changes under `local` are uploaded to `remote`.
    struct KeepUpToDate {
        let session: UUID
        let siteName: String
        let local: String
        let remote: String
        var uploads = 0
    }
    @Published private(set) var keepUpToDate: KeepUpToDate?
    private var folderWatcher: LocalFolderWatcher?
    /// Size and time last queued per relative path, so repeated events do not upload twice.
    private var watchedVersions: [String: (UInt64, Date?)] = [:]

    func toggleKeepUpToDate() { keepUpToDate == nil ? startKeepingUpToDate() : stopKeepingUpToDate() }

    func startKeepingUpToDate() {
        guard connected, keepUpToDate == nil, let site = currentSite else { return }
        // FSEvents reports resolved paths (/private/var…), so the root is resolved the same way.
        // (Foundation's resolvingSymlinksInPath maps /private/var back to /var, so realpath(3) is used.)
        guard let resolved = Darwin.realpath(localPath, nil) else { report(ClientError.invalid("\(localPath) cannot be watched.")); return }
        let root = String(cString: resolved); free(resolved)
        do {
            folderWatcher = try LocalFolderWatcher(root: root) { [weak self] paths in self?.localFilesChanged(paths) }
            watchedVersions = [:]
            keepUpToDate = KeepUpToDate(session: sessionID, siteName: site.displayName, local: root, remote: remotePath)
            appendLog("Keeping \(remotePath) up to date with \(root): changed files are uploaded; nothing is deleted.")
        } catch { report(error) }
    }

    func stopKeepingUpToDate() {
        folderWatcher?.stop(); folderWatcher = nil
        if let state = keepUpToDate { appendLog("Stopped keeping \(state.remote) up to date (\(state.uploads) upload(s)).") }
        keepUpToDate = nil
    }

    /// Editor and system scratch files that should never be uploaded.
    static func ignoredByKeepUpToDate(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { part in
            part.hasPrefix(".syncscp-") || part == ".DS_Store" || part.hasPrefix(".#") || part.hasSuffix("~") || part.hasSuffix(".swp") || part.hasSuffix(".swx") || part == ".git"
        }
    }

    private func localFilesChanged(_ paths: [String]) {
        guard var state = keepUpToDate else { return }
        guard tabs.contains(where: { $0.id == state.session }) else { stopKeepingUpToDate(); return }
        for path in Set(paths) where path.hasPrefix(state.local + "/") {
            let relative = String(path.dropFirst(state.local.count + 1))
            guard !Self.ignoredByKeepUpToDate(relative), let info = try? LocalFiles.info(path), info.isRegularFile else { continue }
            if let known = watchedVersions[relative], known.0 == info.size, known.1 == info.modified { continue }
            let destination = RemotePath.join(state.remote, relative)
            guard !jobs.contains(where: { $0.destination == destination && $0.state == .waiting }) else { continue }
            watchedVersions[relative] = (info.size, info.modified)
            var job = TransferJob(session: state.session, siteName: state.siteName, direction: .upload, entry: info, destination: destination, replace: true)
            job.createParentsBelow = state.remote
            jobs.append(job); state.uploads += 1
        }
        keepUpToDate = state
        scheduleQueue()
    }

    /// Opens Synchronize for the two folders shown and compares them with the current options.
    func previewSynchronization() {
        guard connected, !busy else { return }
        syncItems = []; showSync = true
        compareForSynchronization()
    }

    func compareForSynchronization() {
        guard connected, !busy else { return }
        syncLocal = localPath; syncRemote = remotePath; syncSessionID = sessionID
        let options = syncOptions
        perform {
            var local: [String: FileEntry] = [:]; var remote: [String: FileEntry] = [:]
            try self.collectLocal(self.syncLocal, relative: "", into: &local, depth: 0)
            try await self.collectRemote(self.syncRemote, relative: "", into: &remote, depth: 0)
            self.syncLocalSnapshot = local; self.syncRemoteSnapshot = remote
            self.syncItems = SyncPlanner.compare(local: local, remote: remote, options: options)
        }
    }

    private func collectLocal(_ path: String, relative: String, into result: inout [String: FileEntry], depth: Int) throws {
        guard depth < 64, result.count < 100_000 else { throw ClientError.unsupported("Synchronization preview is limited to 64 levels and 100,000 files.") }
        for entry in try LocalFiles.list(path) {
            let key = relative.isEmpty ? entry.name : relative + "/" + entry.name
            result[key] = entry
            if entry.isDirectory { try collectLocal(entry.path, relative: key, into: &result, depth: depth + 1) }
        }
    }

    private func collectRemote(_ path: String, relative: String, into result: inout [String: FileEntry], depth: Int) async throws {
        guard depth < 64, result.count < 100_000 else { throw ClientError.unsupported("Synchronization preview is limited to 64 levels and 100,000 files.") }
        for entry in try await client.list(path) {
            let key = relative.isEmpty ? entry.name : relative + "/" + entry.name
            result[key] = entry
            if entry.isDirectory { try await collectRemote(entry.path, relative: key, into: &result, depth: depth + 1) }
        }
    }

    /// Applies the reviewed plan; conflicts are skipped. Every item is checked against the
    /// preview first, so nothing that changed since then is overwritten or deleted.
    func executeSynchronization() {
        guard connected, !busy else { return }
        guard sessionID == syncSessionID else { report(ClientError.conflict("The remote session changed. Compare again.")); return }
        let items = syncItems.filter { $0.action != .conflict }; let local = syncLocal; let remote = syncRemote
        let localSnapshot = syncLocalSnapshot, remoteSnapshot = syncRemoteSnapshot
        showSync = false
        perform {
            let manager = FileManager.default
            func changed(_ path: String) -> ClientError { .conflict("\(path) changed since the comparison. Compare again.") }
            func localUnchanged(_ item: SyncItem, _ url: URL) throws {
                guard let expected = localSnapshot[item.relativePath], let current = try? LocalFiles.info(url.path),
                      expected.isDirectory ? current.isDirectory : (current.isRegularFile && current.hasSameVersion(as: expected)) else { throw changed(item.relativePath) }
            }
            func remoteUnchanged(_ item: SyncItem, _ path: String) async throws {
                guard let expected = remoteSnapshot[item.relativePath] else { throw changed(item.relativePath) }
                let current = try await self.client.stat(path)
                guard expected.isDirectory ? current.isDirectory : current.hasSameVersion(as: expected) else { throw changed(item.relativePath) }
            }
            for item in items {
                let destination = RemotePath.join(remote, item.relativePath)
                let source = URL(fileURLWithPath: local).appendingPathComponent(item.relativePath)
                switch item.action {
                case .createDirectory:
                    try localUnchanged(item, source)
                    guard try await !self.client.exists(destination) else { throw ClientError.conflict("The destination appeared since the comparison: \(item.relativePath). Compare again.") }
                    try await self.client.mkdir(destination)
                case .upload:
                    try localUnchanged(item, source)
                    try await self.client.upload(local: source, remote: destination, replace: item.replacesFile, expectedDestination: remoteSnapshot[item.relativePath])
                case .createLocalDirectory:
                    try await remoteUnchanged(item, destination)
                    guard !manager.fileExists(atPath: source.path) else { throw ClientError.conflict("\(item.relativePath) appeared locally since the comparison. Compare again.") }
                    try manager.createDirectory(at: source, withIntermediateDirectories: false)
                case .download:
                    try await remoteUnchanged(item, destination)
                    if item.replacesFile { try localUnchanged(item, source) }
                    try await self.client.download(remote: destination, local: source, replace: item.replacesFile)
                case .deleteRemote:
                    try await remoteUnchanged(item, destination)
                    try await self.client.remove(destination, recursive: true)
                case .deleteLocal:
                    try localUnchanged(item, source)
                    try manager.trashItem(at: source, resultingItemURL: nil)
                case .conflict: continue
                }
                self.appendLog("Synchronize: \(item.action.rawValue) \(item.relativePath)")
            }
        }
    }
}

struct RemoteDocument: Identifiable { let id = UUID(); let entry: FileEntry; let text: String; let sessionID: UUID }
