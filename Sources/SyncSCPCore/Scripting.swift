// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// WinSCP-style scripting (a subset of winscp.com's commands) on top of `RemoteSession`, for
/// the `syncscp-cli` tool. Sites, host keys and settings come from the app's own store; a host
/// key must already be trusted, or be confirmed with `open … -hostkey=SHA256:…`.
public final class ScriptSession {
    public enum ErrorMode { case abort, `continue` }

    private let store: SiteStore
    private let askpass: String?
    private let output: (String) -> Void
    private let readPassword: (String) -> String?
    private var client = RemoteSession()
    private var site: Site?
    private var remotePath = ""
    private(set) public var localPath: String
    public var errorMode = ErrorMode.abort

    /// `askpass` is the executable OpenSSH runs for passwords (this tool, which answers from a
    /// temporary Keychain item); `readPassword` asks interactively and may return nil in batch use.
    public init(store: SiteStore, localPath: String = FileManager.default.currentDirectoryPath, askpass: String?,
                output: @escaping (String) -> Void, readPassword: @escaping (String) -> String? = { _ in nil }) {
        self.store = store; self.localPath = localPath; self.askpass = askpass; self.output = output; self.readPassword = readPassword
    }

    /// Runs commands in order. Returns the exit code: 0 when every command succeeded.
    public func run(_ lines: [String]) async -> Int32 {
        var failed = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            do {
                if try await execute(line) == false { break }
            } catch {
                failed = true
                output("Error: \(error.localizedDescription)")
                if errorMode == .abort { break }
            }
        }
        await client.disconnect()
        return failed ? 1 : 0
    }

    /// One command; false for `exit`.
    @discardableResult
    public func execute(_ line: String) async throws -> Bool {
        let words = try Self.split(line)
        guard let command = words.first?.lowercased() else { return true }
        let options = Dictionary(words.dropFirst().filter { $0.hasPrefix("-") }.map { option -> (String, String) in
            let parts = option.dropFirst().split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0].lowercased(), parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { $1 })
        let arguments = Array(words.dropFirst().filter { !$0.hasPrefix("-") })
        switch command {
        case "exit", "bye", "quit": return false
        case "echo": output(arguments.joined(separator: " "))
        case "option": try option(arguments)
        case "open": try await open(arguments, options: options)
        case "close": await client.disconnect(); site = nil; remotePath = ""; output("Session closed.")
        case "lpwd": output(localPath)
        case "lcd":
            let target = try localDirectory(try argument(arguments, 0, command))
            localPath = target
            output(localPath)
        case "lls":
            for entry in try LocalFiles.list(arguments.first.map(localAbsolute) ?? localPath) { output(Self.describe(entry)) }
        default:
            try await remoteCommand(command, arguments, options: options)
        }
        return true
    }

    private func remoteCommand(_ command: String, _ arguments: [String], options: [String: String]) async throws {
        guard site != nil else { throw ClientError.invalid("\(command): not connected. Use open first.") }
        switch command {
        case "pwd": output(remotePath)
        case "cd":
            remotePath = try await client.realpath(remoteAbsolute(arguments.first ?? "~"))
            output(remotePath)
        case "ls", "dir":
            let (folder, pattern) = try await remotePattern(arguments.first ?? ".")
            for entry in try await client.list(folder) where pattern.map({ fnmatch($0, entry.name, 0) == 0 }) ?? true { output(Self.describe(entry)) }
        case "stat":
            output(Self.describe(try await client.stat(remoteAbsolute(try argument(arguments, 0, command)))))
        case "mkdir":
            for path in arguments { try await client.mkdir(remoteAbsolute(path)) }
        case "rm":
            guard !arguments.isEmpty else { throw ClientError.invalid("rm: name a remote file.") }
            for entry in try await remoteMatches(arguments) { try await client.remove(entry.path, recursive: true); output("Deleted \(entry.path)") }
        case "rmdir":
            for path in arguments { try await client.remove(remoteAbsolute(path), recursive: false) }
        case "mv":
            guard arguments.count >= 2 else { throw ClientError.invalid("mv: name the source(s) and a target.") }
            let target = remoteAbsolute(arguments.last!)
            let sources = try await remoteMatches(Array(arguments.dropLast()))
            let intoFolder = try await isRemoteDirectory(target)
            guard intoFolder || sources.count == 1 else { throw ClientError.invalid("mv: \(target) is not a folder.") }
            for entry in sources { try await client.rename(entry.path, to: intoFolder ? RemotePath.join(target, entry.name) : target) }
        case "cp":
            guard arguments.count >= 2 else { throw ClientError.invalid("cp: name the source(s) and a target.") }
            let target = remoteAbsolute(arguments.last!)
            let sources = try await remoteMatches(Array(arguments.dropLast()))
            let intoFolder = try await isRemoteDirectory(target)
            guard intoFolder || sources.count == 1 else { throw ClientError.invalid("cp: \(target) is not a folder.") }
            for entry in sources { try await client.copy(entry.path, to: intoFolder ? RemotePath.join(target, entry.name) : target) }
        case "chmod":
            guard arguments.count >= 2, let mode = UInt32(arguments[0], radix: 8), mode <= 0o7777 else { throw ClientError.invalid("chmod: use an octal mode, e.g. chmod 644 file.") }
            for entry in try await remoteMatches(Array(arguments.dropFirst())) { try await client.chmod(entry.path, mode: mode) }
        case "get":
            guard !arguments.isEmpty else { throw ClientError.invalid("get: name a remote file.") }
            let explicitTarget = arguments.count > 1 ? localAbsolute(arguments.last!) : nil
            let sources = try await remoteMatches(arguments.count > 1 ? Array(arguments.dropLast()) : arguments)
            let intoFolder = explicitTarget.map { Self.isLocalDirectory($0) || $0.hasSuffix("/") } ?? true
            guard intoFolder || sources.count == 1 else { throw ClientError.invalid("get: \(explicitTarget!) is not a folder.") }
            for entry in sources {
                let destination = intoFolder ? URL(fileURLWithPath: explicitTarget ?? localPath).appendingPathComponent(entry.name).path : explicitTarget!
                try await download(entry, to: destination)
                if options["delete"] != nil { try await client.remove(entry.path, recursive: true) }
            }
        case "put":
            guard !arguments.isEmpty else { throw ClientError.invalid("put: name a local file.") }
            let explicitTarget = arguments.count > 1 ? remoteAbsolute(arguments.last!) : nil
            let sources = try localMatches(arguments.count > 1 ? Array(arguments.dropLast()) : arguments)
            var intoFolder = true
            if let explicitTarget { intoFolder = explicitTarget.hasSuffix("/") ? true : try await isRemoteDirectory(explicitTarget) }
            guard intoFolder || sources.count == 1 else { throw ClientError.invalid("put: \(explicitTarget!) is not a folder.") }
            for entry in sources {
                let destination = intoFolder ? RemotePath.join(explicitTarget ?? remotePath, entry.name) : explicitTarget!
                try await upload(entry, to: destination)
                if options["delete"] != nil { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
            }
        case "synchronize":
            try await synchronize(arguments, options: options)
        default:
            throw ClientError.invalid("Unknown command \(command). Commands: open, close, ls, cd, pwd, lls, lcd, lpwd, get, put, rm, rmdir, mkdir, mv, cp, chmod, stat, synchronize, option, echo, exit.")
        }
    }

    // MARK: open

    private func open(_ arguments: [String], options: [String: String]) async throws {
        let target = try argument(arguments, 0, "open")
        var password = options["password"] ?? ProcessInfo.processInfo.environment["SYNCSCP_PASSWORD"] ?? ""
        var site: Site
        if let saved = try store.load().first(where: { $0.name == target || $0.displayName == target || $0.name.caseInsensitiveCompare(target) == .orderedSame }) {
            site = saved
        } else {
            let parsed = try Self.parseURL(target)
            site = parsed.site
            if let inline = parsed.password { password = inline }
        }
        if let key = options["privatekey"] { site.privateKey = (key as NSString).expandingTildeInPath }
        if let start = arguments.dropFirst().first { site.remotePath = start }
        try site.validate()
        try await confirmHostKey(site, expected: options["hostkey"])
        if password.isEmpty, !site.transferProtocol.usesSSH || site.privateKey.isEmpty, let typed = readPassword("Password for \(site.username)@\(site.host): ") {
            password = typed
        }
        await client.disconnect()
        var credential: String?
        defer { if let credential { _ = SessionCredential.remove(credential) } }
        var configuration: SSHConfiguration?
        if site.transferProtocol.usesSSH {
            if !password.isEmpty, askpass != nil { credential = try SessionCredential.store(password) }
            configuration = SSHConfiguration(site: site, knownHostsFile: store.knownHostsFile.path, askpassExecutable: credential == nil ? nil : askpass, credentialID: credential)
        }
        let home = try await client.connect(site: site, password: password, sshConfiguration: configuration,
                                            s3SessionToken: ProcessInfo.processInfo.environment["SYNCSCP_S3_SESSION_TOKEN"] ?? "")
        remotePath = site.remotePath.isEmpty || site.remotePath == "." ? home : try await client.realpath(site.remotePath)
        self.site = site
        output("Connected to \(site.username)@\(site.host):\(site.port) (\(site.transferProtocol.title)). Remote folder: \(remotePath)")
    }

    /// An unknown SSH host key is refused unless `expected` (SHA256:… or *) matches what the server presents.
    private func confirmHostKey(_ site: Site, expected: String?) async throws {
        guard site.transferProtocol.usesSSH, try await !HostTrust.isKnown(site, file: store.knownHostsFile) else { return }
        let identity = try await HostTrust.scan(site, knownHostsFile: store.knownHostsFile)
        guard let expected else {
            throw ClientError.connection("The host key of \(identity.host) is not trusted yet (\(identity.algorithm) \(identity.fingerprint)). Verify it, then run open again with -hostkey=\"\(identity.fingerprint)\", or connect once in syncSCP.")
        }
        let wanted = expected.hasPrefix("SHA256:") ? expected : "SHA256:" + expected
        guard expected == "*" || wanted == identity.fingerprint else {
            throw ClientError.connection("Host key mismatch for \(identity.host): the server presents \(identity.fingerprint), not \(wanted).")
        }
        if expected == "*" { output("Warning: accepting \(identity.host)'s host key \(identity.fingerprint) without checking it.") }
        try HostTrust.trust(identity, file: store.knownHostsFile)
        output("Trusted host key \(identity.algorithm) \(identity.fingerprint) for \(identity.host).")
    }

    /// `sftp://user:password@host:2222/path` and the other schemes winscp.com accepts.
    static func parseURL(_ text: String) throws -> (site: Site, password: String?) {
        let kinds: [String: TransferProtocol] = ["sftp": .sftp, "scp": .scp, "ftp": .ftp, "ftps": .ftpsImplicit, "ftpes": .ftpsExplicit,
                                                 "dav": .webdav, "http": .webdav, "davs": .webdavs, "https": .webdavs, "s3": .s3]
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let kind = kinds[scheme],
              let host = components.host, !host.isEmpty else {
            throw ClientError.invalid("\(text) is neither a saved site nor a URL such as sftp://user@host/path.")
        }
        var site = Site(name: "", host: host, port: components.port, username: components.user ?? NSUserName(), transferProtocol: kind)
        if !components.path.isEmpty { site.remotePath = components.path }
        return (site, components.password)
    }

    // MARK: transfers

    private func download(_ entry: FileEntry, to destination: String, depth: Int = 0) async throws {
        guard depth < 64 else { throw ClientError.unsupported("Folders are copied at most 64 levels deep.") }
        if entry.isDirectory {
            if !Self.isLocalDirectory(destination) { try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false) }
            for child in try await client.list(entry.path) {
                try await download(child, to: URL(fileURLWithPath: destination).appendingPathComponent(child.name).path, depth: depth + 1)
            }
        } else if entry.isRegularFile {
            try await client.download(remote: entry.path, local: URL(fileURLWithPath: destination), replace: true)
            output("\(entry.path) → \(destination) (\(entry.size) bytes)")
        } else {
            output("Skipped \(entry.path): symbolic links and special files are not transferred.")
        }
    }

    private func upload(_ entry: FileEntry, to destination: String, depth: Int = 0) async throws {
        guard depth < 64 else { throw ClientError.unsupported("Folders are copied at most 64 levels deep.") }
        if entry.isDirectory {
            if try await !isRemoteDirectory(destination) { try await client.mkdir(destination) }
            for child in try LocalFiles.list(entry.path) { try await upload(child, to: RemotePath.join(destination, child.name), depth: depth + 1) }
        } else if entry.isRegularFile {
            let existing = try await client.exists(destination)
            try await client.upload(local: URL(fileURLWithPath: entry.path), remote: destination, replace: existing)
            output("\(entry.path) → \(destination) (\(entry.size) bytes)")
        } else {
            output("Skipped \(entry.path): symbolic links and special files are not transferred.")
        }
    }

    /// `synchronize local|remote|both [local folder [remote folder]] [-delete] [-criteria=size] [-preview]`
    private func synchronize(_ arguments: [String], options: [String: String]) async throws {
        let modes: [String: SyncDirection] = ["remote": .upload, "local": .download, "both": .both]
        guard let mode = arguments.first.flatMap({ modes[$0.lowercased()] }) else { throw ClientError.invalid("synchronize: say remote, local or both.") }
        let local = arguments.count > 1 ? localAbsolute(arguments[1]) : localPath
        let remote = arguments.count > 2 ? remoteAbsolute(arguments[2]) : remotePath
        guard mode != .both || options["delete"] == nil else { throw ClientError.invalid("synchronize both cannot delete.") }
        // A missing target folder is treated as empty and created when the changes are applied.
        let remoteExists = try await isRemoteDirectory(remote), localExists = Self.isLocalDirectory(local)
        guard remoteExists || mode == .upload else { throw ClientError.invalid("synchronize: \(remote) is not a remote folder.") }
        guard localExists || mode == .download else { throw ClientError.invalid("synchronize: \(local) is not a local folder.") }
        var localTree: [String: FileEntry] = [:], remoteTree: [String: FileEntry] = [:]
        if localExists { try collectLocal(local, "", &localTree, 0) }
        if remoteExists { try await collectRemote(remote, "", &remoteTree, 0) }
        if options["preview"] == nil {
            if !remoteExists { try await client.mkdir(remote) }
            if !localExists { try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true) }
        }
        let plan = SyncPlanner.compare(local: localTree, remote: remoteTree,
                                       options: SyncOptions(direction: mode, sizeOnly: options["criteria"]?.lowercased() == "size", deleteExtras: options["delete"] != nil))
        for item in plan {
            output("\(item.action.rawValue): \(item.relativePath)\(item.reason.isEmpty ? "" : " (\(item.reason))")")
            guard options["preview"] == nil else { continue }
            let localItem = URL(fileURLWithPath: local).appendingPathComponent(item.relativePath).path
            let remoteItem = RemotePath.join(remote, item.relativePath)
            switch item.action {
            case .createDirectory: try await client.mkdir(remoteItem)
            case .upload: try await client.upload(local: URL(fileURLWithPath: localItem), remote: remoteItem, replace: item.replacesFile)
            case .createLocalDirectory: try FileManager.default.createDirectory(atPath: localItem, withIntermediateDirectories: false)
            case .download: try await client.download(remote: remoteItem, local: URL(fileURLWithPath: localItem), replace: item.replacesFile)
            case .deleteRemote: try await client.remove(remoteItem, recursive: true)
            case .deleteLocal: try FileManager.default.trashItem(at: URL(fileURLWithPath: localItem), resultingItemURL: nil)
            case .conflict: continue
            }
        }
        output(plan.isEmpty ? "Nothing to synchronize." : "\(plan.filter { $0.action != .conflict }.count) change(s)\(options["preview"] == nil ? "" : " previewed").")
    }

    private func collectLocal(_ path: String, _ relative: String, _ result: inout [String: FileEntry], _ depth: Int) throws {
        guard depth < 64 else { return }
        for entry in try LocalFiles.list(path) {
            let key = relative.isEmpty ? entry.name : relative + "/" + entry.name
            result[key] = entry
            if entry.isDirectory { try collectLocal(entry.path, key, &result, depth + 1) }
        }
    }

    private func collectRemote(_ path: String, _ relative: String, _ result: inout [String: FileEntry], _ depth: Int) async throws {
        guard depth < 64 else { return }
        for entry in try await client.list(path) {
            let key = relative.isEmpty ? entry.name : relative + "/" + entry.name
            result[key] = entry
            if entry.isDirectory { try await collectRemote(entry.path, key, &result, depth + 1) }
        }
    }

    // MARK: paths and wildcards

    private func option(_ arguments: [String]) throws {
        guard let name = arguments.first?.lowercased() else { throw ClientError.invalid("option: name an option.") }
        switch (name, arguments.dropFirst().first?.lowercased()) {
        case ("batch", "abort"?), ("batch", "on"?): errorMode = .abort
        case ("batch", "continue"?), ("batch", "off"?): errorMode = .continue
        case ("confirm", _), ("transfer", _), ("reconnecttime", _): break // accepted for winscp.com scripts; no effect here
        default: throw ClientError.invalid("option \(arguments.joined(separator: " ")) is not supported.")
        }
    }

    private func argument(_ arguments: [String], _ index: Int, _ command: String) throws -> String {
        guard arguments.count > index else { throw ClientError.invalid("\(command): missing argument.") }
        return arguments[index]
    }

    private func remoteAbsolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" { return "." }
        return RemotePath.join(remotePath, path)
    }

    private func localAbsolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: localPath).appendingPathComponent(expanded).standardizedFileURL.path
    }

    private func localDirectory(_ path: String) throws -> String {
        let absolute = localAbsolute(path)
        guard Self.isLocalDirectory(absolute) else { throw ClientError.invalid("\(absolute) is not a local folder.") }
        return absolute
    }

    private static func isLocalDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func isRemoteDirectory(_ path: String) async throws -> Bool {
        guard try await client.exists(path) else { return false }
        return try await client.stat(path, followLinks: true).isDirectory
    }

    /// A folder and, when the last part has wildcards, the pattern to filter it with.
    private func remotePattern(_ path: String) async throws -> (String, String?) {
        let absolute = remoteAbsolute(path)
        let name = (absolute as NSString).lastPathComponent
        if name.contains("*") || name.contains("?") { return (RemotePath.parent(absolute), name) }
        return (absolute, nil)
    }

    private func remoteMatches(_ paths: [String]) async throws -> [FileEntry] {
        var result: [FileEntry] = []
        for path in paths {
            let (folder, pattern) = try await remotePattern(path)
            if let pattern {
                let matched = try await client.list(folder).filter { fnmatch(pattern, $0.name, 0) == 0 }
                guard !matched.isEmpty else { throw ClientError.invalid("No remote file matches \(path).") }
                result += matched
            } else {
                result.append(try await client.stat(folder))
            }
        }
        return result
    }

    private func localMatches(_ paths: [String]) throws -> [FileEntry] {
        var result: [FileEntry] = []
        for path in paths {
            let absolute = localAbsolute(path)
            let name = (absolute as NSString).lastPathComponent
            if name.contains("*") || name.contains("?") {
                let matched = try LocalFiles.list((absolute as NSString).deletingLastPathComponent).filter { fnmatch(name, $0.name, 0) == 0 }
                guard !matched.isEmpty else { throw ClientError.invalid("No local file matches \(path).") }
                result += matched
            } else {
                result.append(try LocalFiles.info(absolute))
            }
        }
        return result
    }

    /// `ls` lines: rights, size, time, name.
    static func describe(_ entry: FileEntry) -> String {
        let time = entry.modified.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]) } ?? "-"
        return "\(entry.rights.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(entry.isDirectory ? 0 : entry.size).leftPadded(12)) \(time) \(entry.name)\(entry.isDirectory ? "/" : "")"
    }

    /// Splits a command line into words; double quotes group, and "" inside quotes is a quote (WinSCP's rule).
    static func split(_ line: String) throws -> [String] {
        var words: [String] = [], current = "", quoted = false, started = false
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            if character == "\"" {
                if quoted, characters.first == "\"" { current.append("\""); characters = characters.dropFirst() }
                else { quoted.toggle(); started = true }
            } else if character.isWhitespace && !quoted {
                if started || !current.isEmpty { words.append(current); current = ""; started = false }
            } else { current.append(character) }
        }
        guard !quoted else { throw ClientError.invalid("A quote is not closed: \(line)") }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
