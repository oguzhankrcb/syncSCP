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

struct TransferJob: Identifiable {
    let id = UUID()
    let direction: TransferDirection
    let entry: FileEntry
    let destination: String
    let replace: Bool
    let token = CancellationToken()
    var state = JobState.waiting
    var fraction = 0.0
    var detail = "Waiting"
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
    @Published var runningQueue = false
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
    private var sessionID = UUID()
    let client = RemoteSession()
    private(set) var store: SiteStore?

    var busy: Bool { connecting || operationBusy || runningQueue }
    // The ".." row can be selected for navigation but is never part of an action.
    var canUpload: Bool { connected && !busy && !localSelection.subtracting([ParentRow.id]).isEmpty }
    var canDownload: Bool { connected && !busy && !remoteSelection.subtracting([ParentRow.id]).isEmpty }
    var activeSelection: [FileEntry] {
        let entries = activeSide == .local ? localEntries : remoteEntries
        let selection = activeSide == .local ? localSelection : remoteSelection
        return entries.filter { selection.contains($0.id) }
    }
    var pendingCount: Int { jobs.filter { $0.state == .waiting || $0.state == .running }.count }

    init() {
        Self.migrateLegacyDefaults()
        do { let store = try SiteStore(); self.store = store; sites = try store.load() }
        catch { self.error = error.localizedDescription }
        refreshLocal()
        appendLog("syncSCP 0.13.0 · Community development preview")
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
        if case ClientError.connection = failure { closeFailedConnection() }
    }

    private func closeFailedConnection() {
        stopAllEdits()
        connected = false; remoteEntries = []; remoteSelection = []; remotePath = ""; currentSite = nil; sessionID = UUID()
        jobs.filter { $0.state == .waiting || $0.state == .running }.forEach { $0.token.cancel() }
        guard !connecting else { return }
        connecting = true
        Task { await client.disconnect(); connecting = false; appendLog("Closed the failed transport connection.") }
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

    /// Saves imported WinSCP sites, converted keys and host keys (see `WinSCPImport.commit`).
    func importFromWinSCP(_ chosen: [ImportedSite], hostKeys: [ImportedHostKey]) -> WinSCPImportSummary? {
        do {
            guard let store else { throw ClientError.invalid("The site store is unavailable.") }
            let summary = try WinSCPImport.commit(chosen, hostKeys: hostKeys, into: store, existing: sites)
            sites = try store.load()
            appendLog("Imported \(summary.sites.count) WinSCP sites, \(summary.convertedKeys.count) converted keys and \(summary.hostKeysAdded) host keys.")
            return summary
        } catch { report(error); return nil }
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
        let generation = sessionID
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
        guard live.session == sessionID, connected else { stopEditing(id, keepChanges: true); return }
        syncingEdits.insert(id)
        Task {
            defer { syncingEdits.remove(id) }
            do {
                switch try await live.edit.syncIfChanged() {
                case .unchanged, .missing: break
                case .uploaded:
                    setEditStatus(id, "Uploaded " + Date().formatted(date: .omitted, time: .standard))
                    appendLog("Uploaded edited \(live.edit.remotePath).")
                    if RemotePath.parent(live.edit.remotePath) == remotePath, !busy { navigateRemote(remotePath, recordHistory: false) }
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
                if case ClientError.connection = error { closeFailedConnection() }
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

    private func stopAllEdits() { for id in Array(editSessions.keys) { stopEditing(id, keepChanges: true) } }

    func deleteSite(_ id: UUID) {
        do { let updated = sites.filter { $0.id != id }; try store?.save(updated); sites = updated }
        catch { report(error) }
    }

    /// For S3, `password` is the secret access key and `sessionToken` optional temporary credentials; neither is saved.
    func connect(site: Site, password: String, sessionToken: String = "") {
        guard !busy else { return }
        stopAllEdits()
        connecting = true; status = "Connecting to \(site.host)…"
        Task {
            defer { connecting = false }
            var credential: String?
            defer {
                if let credential, !SessionCredential.remove(credential) {
                    report(ClientError.invalid("Keychain could not remove the temporary SSH credential. Remove account \(credential) for service io.github.oguzhankrcb.syncscp.session using Keychain Access."))
                }
            }
            do {
                try site.validate()
                var configuration: SSHConfiguration?
                if site.transferProtocol.usesSSH {
                    guard let store else { throw ClientError.invalid("The host key store is unavailable.") }
                    // A tunnel's bastion is verified first; the target key is then read through it.
                    let probe = SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path)
                    for (target, role) in [(probe.tunnelSite, "tunnel host"), (site, "SSH server")] {
                        guard let target, try await !HostTrust.isKnown(target, file: store.knownHostsFile) else { continue }
                        let identity = try await HostTrust.scan(target, knownHostsFile: store.knownHostsFile)
                        let alert = NSAlert()
                        alert.messageText = "Trust this \(role)?"
                        alert.informativeText = "\(identity.host)\n\(identity.algorithm)\n\n\(identity.fingerprint)\n\nVerify this fingerprint with the server administrator before connecting."
                        alert.addButton(withTitle: "Trust and Connect"); alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { status = "Connection cancelled"; return }
                        try HostTrust.trust(identity, file: store.knownHostsFile)
                    }
                    if !password.isEmpty { credential = try SessionCredential.store(password) }
                    configuration = SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path,
                                                     askpassExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0], credentialID: credential)
                }
                await client.disconnect(); connected = false
                let home = try await client.connect(site: site, password: password, sshConfiguration: configuration, s3SessionToken: sessionToken)
                let path = site.remotePath.isEmpty || site.remotePath == "." ? home : try await client.realpath(site.remotePath)
                let entries = try await client.list(path)
                sessionID = UUID(); currentSite = site; remotePath = path; remoteEntries = entries
                remoteHome = home; connectedAt = Date(); backHistory[.remote] = []; forwardHistory[.remote] = []
                remoteSelection = []; connected = true; showConnection = false; status = "Connected to \(site.host)"
                if FileManager.default.fileExists(atPath: site.localPath) { navigateLocal(site.localPath) }
                let security = site.transferProtocol.usesSSH ? "Host key verified by OpenSSH." : site.transferProtocol == .s3http ? "Unencrypted S3 connection; requests are signed with SigV4." : !site.transferProtocol.isEncrypted ? "Unencrypted \(site.transferProtocol.shortTitle) connection." : "Server certificate and hostname verified; TLS required."
                appendLog("Connected to \(site.username)@\(site.host):\(site.port) using \(site.transferProtocol.title). \(security)")
            } catch { await client.disconnect(); connected = false; remoteEntries = []; remotePath = ""; currentSite = nil; report(error) }
        }
    }

    func disconnect() {
        guard !connecting else { return }
        stopAllEdits()
        jobs.indices.filter { jobs[$0].state == .waiting || jobs[$0].state == .running }.forEach { jobs[$0].token.cancel() }
        sessionID = UUID(); connecting = true; connected = false
        remoteEntries = []; remoteSelection = []; remotePath = ""; currentSite = nil
        remoteHome = ""; connectedAt = nil; backHistory[.remote] = []; forwardHistory[.remote] = []
        Task { await client.disconnect(); connecting = false; status = "Disconnected"; appendLog("Disconnected.") }
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
        for entry in entries {
            jobs.append(TransferJob(direction: direction, entry: entry,
                                    destination: direction == .upload ? RemotePath.join(remotePath, entry.name) : URL(fileURLWithPath: localPath).appendingPathComponent(entry.name).path,
                                    replace: replace))
        }
        bottomTab = .queue; showBottom = true; startQueue()
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

    private func startQueue() {
        guard !runningQueue else { return }; runningQueue = true
        Task {
            defer { runningQueue = false; refresh() }
            while let index = jobs.firstIndex(where: { $0.state == .waiting }) {
                let job = jobs[index]
                if job.token.isCancelled { jobs[index].state = .cancelled; continue }
                jobs[index].state = .running; jobs[index].detail = "Preparing…"
                status = "\(job.direction.rawValue): \(job.entry.name)"
                appendLog("\(job.direction.rawValue) \(job.entry.path) → \(job.destination)")
                do {
                    try await transferTree(job.entry, destination: job.destination, job: job)
                    jobs[index].state = .done; jobs[index].fraction = 1; jobs[index].detail = "Complete"
                    appendLog("Transfer complete: \(job.entry.name)")
                } catch {
                    jobs[index].state = job.token.isCancelled ? .cancelled : .failed
                    jobs[index].detail = error.localizedDescription
                    appendLog("\(job.entry.name): \(error.localizedDescription)", error: !job.token.isCancelled)
                    if case ClientError.connection = error { closeFailedConnection() }
                }
            }
            status = jobs.contains(where: { $0.state == .failed }) ? "Transfers finished with errors — see queue" : "Transfers finished"
        }
    }

    private func transferTree(_ entry: FileEntry, destination: String, job: TransferJob, depth: Int = 0) async throws {
        try job.token.check()
        guard depth < 64 else { throw ClientError.unsupported("Directory transfers are limited to 64 levels.") }
        guard entry.isDirectory || entry.isRegularFile else { throw ClientError.unsupported("Symbolic links and special files are not transferred: \(entry.name)") }
        if entry.isDirectory {
            if job.direction == .upload {
                if try await client.exists(destination) {
                    let target = try await client.stat(destination)
                    guard target.isDirectory, job.replace else { throw ClientError.conflict("Destination exists: \(destination)") }
                } else { try await client.mkdir(destination) }
                for child in try LocalFiles.list(entry.path) { try await transferTree(child, destination: RemotePath.join(destination, child.name), job: job, depth: depth + 1) }
            } else {
                let manager = FileManager.default
                if manager.fileExists(atPath: destination) {
                    let attrs = try manager.attributesOfItem(atPath: destination)
                    guard attrs[.type] as? FileAttributeType == .typeDirectory, job.replace else { throw ClientError.conflict("Destination exists: \(destination)") }
                } else { try manager.createDirectory(atPath: destination, withIntermediateDirectories: false) }
                for child in try await client.list(entry.path) {
                    try await transferTree(child, destination: URL(fileURLWithPath: destination).appendingPathComponent(child.name).path, job: job, depth: depth + 1)
                }
            }
        } else {
            let update: @Sendable (UInt64, UInt64) -> Void = { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }), self.jobs[index].state == .running else { return }
                    self.jobs[index].fraction = total == 0 ? 0 : Double(done) / Double(total)
                    self.jobs[index].detail = "\(entry.name) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: done), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))"
                }
            }
            if job.direction == .upload {
                try await client.upload(local: URL(fileURLWithPath: entry.path), remote: destination, replace: job.replace, token: job.token, progress: update)
            } else {
                try await client.download(remote: entry.path, local: URL(fileURLWithPath: destination), replace: job.replace, token: job.token, progress: update)
            }
        }
    }

    func cancelJob(_ id: UUID) { jobs.first(where: { $0.id == id })?.token.cancel() }
    func clearCompleted() { guard !runningQueue else { return }; jobs.removeAll { $0.state != .waiting && $0.state != .running } }

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

    func promptPermissions() {
        guard !busy, activeSide == .remote, currentSite?.transferProtocol.supportsPermissions != false, let entry = activeSelection.first else { return }
        guard let value = prompt(title: "Permissions for \(entry.name) (octal)", value: entry.permissionsKnown ? String(entry.permissions & 0o7777, radix: 8) : "") else { return }
        guard let mode = UInt32(value, radix: 8), mode <= 0o7777 else { report(ClientError.invalid("Enter an octal mode such as 644 or 755.")); return }
        perform { try await self.client.chmod(entry.path, mode: mode) }
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

    func previewSynchronization() {
        guard connected, !busy else { return }
        syncLocal = localPath; syncRemote = remotePath; syncSessionID = sessionID
        perform {
            var local: [String: FileEntry] = [:]; var remote: [String: FileEntry] = [:]
            try self.collectLocal(self.syncLocal, relative: "", into: &local, depth: 0)
            try await self.collectRemote(self.syncRemote, relative: "", into: &remote, depth: 0)
            self.syncLocalSnapshot = local; self.syncRemoteSnapshot = remote
            self.syncItems = SyncPlanner.compare(local: local, remote: remote); self.showSync = true
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

    func executeSynchronization() {
        guard connected, !busy, !syncItems.contains(where: { $0.action == .conflict }) else { return }
        guard sessionID == syncSessionID else { report(ClientError.conflict("The remote session changed. Preview synchronization again.")); return }
        let items = syncItems; let local = syncLocal; let remote = syncRemote
        showSync = false
        perform {
            for item in items {
                let destination = RemotePath.join(remote, item.relativePath)
                let source = URL(fileURLWithPath: local).appendingPathComponent(item.relativePath)
                let sourceInfo = try LocalFiles.info(source.path)
                guard let expectedLocal = self.syncLocalSnapshot[item.relativePath],
                      expectedLocal.isDirectory ? sourceInfo.isDirectory : (sourceInfo.isRegularFile && sourceInfo.hasSameVersion(as: expectedLocal)) else {
                    throw ClientError.conflict("The local item changed since the preview: \(item.relativePath). Preview again.")
                }
                if item.action == .createDirectory {
                    guard try await !self.client.exists(destination) else { throw ClientError.conflict("The destination appeared since the preview: \(item.relativePath). Preview again.") }
                    try await self.client.mkdir(destination)
                } else {
                    try await self.client.upload(local: source, remote: destination, replace: item.replacesFile,
                                                 expectedDestination: self.syncRemoteSnapshot[item.relativePath])
                }
                self.appendLog("Synchronize: \(item.action.rawValue) \(item.relativePath)")
            }
        }
    }
}

struct RemoteDocument: Identifiable { let id = UUID(); let entry: FileEntry; let text: String; let sessionID: UUID }
