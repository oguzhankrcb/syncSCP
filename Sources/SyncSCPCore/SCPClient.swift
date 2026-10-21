// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Metadata returned by stat, with NUL-delimited paths (no parsing of ls output).
enum SCPMetadata {
    static func decode(_ data: Data, flavor: String) throws -> [FileEntry] {
        guard data.isEmpty || data.last == 0 else { throw ClientError.protocolError("Truncated SSH metadata.") }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard fields.count % 2 == 0, fields.count <= 2_000_000 else { throw ClientError.protocolError("Invalid SSH metadata record count.") }
        var entries: [FileEntry] = []
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard let path = String(data: fields[index], encoding: .utf8), path.hasPrefix("/"),
                  let metadata = String(data: fields[index + 1], encoding: .utf8) else { throw ClientError.unsupported("SCP requires UTF-8 remote filenames.") }
            let values = metadata.split(whereSeparator: { $0 == " " || $0 == "\n" })
            guard values.count == 3, let mode = UInt32(values[0], radix: flavor == "gnu" ? 16 : 8),
                  let size = UInt64(values[1]), let seconds = Int64(values[2]) else { throw ClientError.protocolError("Invalid remote stat metadata.") }
            let name = (path as NSString).lastPathComponent
            if path != "/" { try RemotePath.validateName(name) }
            entries.append(FileEntry(path: path, name: name, size: size, permissions: mode, modified: Date(timeIntervalSince1970: Double(seconds))))
        }
        return entries
    }
}

enum SCPRecord {
    static func file(_ data: Data, expectedName: String, expectedSize: UInt64) throws {
        guard let line = String(data: data, encoding: .utf8) else { throw ClientError.protocolError("Non-UTF-8 SCP control record.") }
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 5, fields[0].first == "C",
              fields[0].dropFirst().utf8.allSatisfy({ (48...55).contains($0) }),
              !fields[1].isEmpty, fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let size = UInt64(fields[1]), size == expectedSize, fields[2] == Substring(expectedName) else {
            throw ClientError.protocolError("SCP returned an unexpected file, size, or control record.")
        }
        try RemotePath.validateName(String(fields[2]))
    }
}

public actor SCPClient: RemoteFileClient {
    private var session: SCPSSHSession?
    private var flavor = ""
    public private(set) var home = "/"
    public init() {}

    public func connect(_ configuration: SSHConfiguration) throws -> String {
        disconnect()
        guard configuration.site.transferProtocol == .scp else { throw ClientError.invalid("Choose the SCP protocol.") }
        do {
            session = try SCPSSHSession(configuration)
            let probe = try ssh().run("command -v scp >/dev/null && command -v link >/dev/null || exit 69; if stat -c '%f %s %Y' / >/dev/null 2>&1; then printf gnu; elif stat -f '%p %z %m' / >/dev/null 2>&1; then printf bsd; else exit 69; fi")
            flavor = String(decoding: probe, as: UTF8.self)
            guard ["gnu", "bsd"].contains(flavor) else { throw ClientError.unsupported("SCP requires a Unix shell, scp, link, and GNU or BSD stat on the server.") }
            home = try canonical(ssh().run("pwd -P"))
            return home
        } catch ClientError.remote(_, 69, _) {
            disconnect(); throw ClientError.unsupported("SCP requires a Unix shell, scp, link, and GNU or BSD stat on the server.")
        } catch { disconnect(); throw error }
    }
    public func disconnect() { session?.close(); session = nil; flavor = "" }
    private func ssh() throws -> SCPSSHSession {
        guard let session else { throw ClientError.connection("Connect to an SCP site first.") }; return session
    }
    private func absolute(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else { throw ClientError.invalid("Enter a valid remote path.") }
        var full = path.hasPrefix("/") ? path : RemotePath.join(home, path)
        while full.count > 1, full.hasSuffix("/") { full.removeLast() }
        return full
    }
    private func transferable(_ path: String) throws -> String {
        let result = try absolute(path)
        guard !result.contains("\n"), !result.contains("\r") else {
            throw ClientError.unsupported("Legacy SCP cannot safely transfer paths containing line breaks. Use SFTP for this file.")
        }
        return result
    }
    private var statFunction: String {
        let format = flavor == "gnu" ? "-c '%f %s %Y'" : "-f '%p %z %m'"
        return "entry() { p=$1; shift; m=$(stat \"$@\" \(format) \"$p\") || exit 1; printf '%s\\000%s\\000' \"$p\" \"$m\"; }; "
    }
    private func existsScript(_ path: String) throws -> Bool {
        let result = try ssh().run("if [ -e \"$1\" ] || [ -L \"$1\" ]; then printf yes; else printf no; fi", arguments: [path])
        guard result == Data("yes".utf8) || result == Data("no".utf8) else { throw ClientError.protocolError("Unexpected SSH response.") }
        return result == Data("yes".utf8)
    }
    public func realpath(_ path: String) throws -> String {
        let data = try ssh().run("cd -P \"$1\" && pwd -P", arguments: [absolute(path)])
        return try canonical(data)
    }
    private func canonical(_ data: Data) throws -> String {
        guard data.last == 10, let value = String(data: data.dropLast(), encoding: .utf8), value.hasPrefix("/"), !value.contains("\0") else {
            throw ClientError.protocolError("Invalid canonical SSH path. Check noninteractive shell startup output.")
        }
        return value
    }
    public func list(_ path: String) throws -> [FileEntry] {
        let directory = try absolute(path)
        let script = statFunction + "[ -d \"$1\" ] && [ -r \"$1\" ] && [ -x \"$1\" ] || exit 1; for child in \"${1%/}\"/* \"${1%/}\"/.[!.]* \"${1%/}\"/..?*; do if [ -e \"$child\" ] || [ -L \"$child\" ]; then entry \"$child\"; fi; done"
        let entries = try SCPMetadata.decode(ssh().run(script, arguments: [directory]), flavor: flavor)
        guard entries.allSatisfy({ $0.path == RemotePath.join(directory, $0.name) }) else {
            throw ClientError.protocolError("SSH returned a path outside the requested directory.")
        }
        return entries.sorted(by: LocalFiles.order)
    }
    public func stat(_ path: String, followLinks: Bool = false) throws -> FileEntry {
        let full = try absolute(path)
        let script = statFunction + "if [ ! -e \"$1\" ] && [ ! -L \"$1\" ]; then exit 44; fi; entry \"$1\"" + (followLinks ? " -L" : "")
        let entries = try SCPMetadata.decode(ssh().run(script, arguments: [full]), flavor: flavor)
        guard entries.count == 1, entries[0].path == full else { throw ClientError.protocolError("Expected metadata for the requested SSH path.") }
        return entries[0]
    }
    public func exists(_ path: String) throws -> Bool { try existsScript(absolute(path)) }
    public func mkdir(_ path: String) throws { _ = try ssh().run("mkdir -m 755 \"$1\"", arguments: [absolute(path)]) }
    public func chmod(_ path: String, mode: UInt32) throws {
        guard mode <= 0o7777 else { throw ClientError.invalid("Invalid POSIX permissions.") }
        let path = try absolute(path)
        guard try !stat(path).isSymbolicLink else { throw ClientError.unsupported("SCP does not change symbolic-link targets' permissions.") }
        _ = try ssh().run("chmod \"$1\" \"$2\"", arguments: [String(mode, radix: 8), path])
    }
    public func rename(_ source: String, to destination: String, replace: Bool = false) throws {
        let source = try absolute(source), destination = try absolute(destination)
        if replace {
            guard try stat(source).isRegularFile, try stat(destination).isRegularFile else { throw ClientError.unsupported("SCP replacement requires regular files.") }
            _ = try ssh().run("[ ! -d \"$2\" ] && mv -f \"$1\" \"$2\"", arguments: [source, destination])
        } else {
            // BSD and GNU mv -n both refuse existing destinations. Their exit code alone
            // does not distinguish a successful move from a skipped move; inspect source.
            guard try !exists(destination) else { throw ClientError.conflict("The remote destination already exists.") }
            _ = try ssh().run("mv -n \"$1\" \"$2\"", arguments: [source, destination])
            guard try !exists(source) else { throw ClientError.conflict("The remote move was refused. The destination may already exist.") }
        }
    }
    public func remove(_ path: String, recursive: Bool = false, token: CancellationToken = CancellationToken()) throws {
        try token.check()
        let path = try absolute(path)
        guard path != "/", path != ".", path != "..", !path.hasSuffix("/.."), !path.hasSuffix("/.") else { throw ClientError.invalid("Refusing to delete a root or parent directory.") }
        let info = try stat(path)
        if info.isDirectory {
            guard try realpath(path) != "/" else { throw ClientError.invalid("Refusing to delete the remote root.") }
            if recursive { for child in try list(path) { try remove(child.path, recursive: true, token: token) } }
            _ = try ssh().run("rmdir \"$1\"", arguments: [path], token: token)
        } else { _ = try ssh().run("rm -f \"$1\"", arguments: [path], token: token) }
    }

    private func acknowledge(_ stream: SSHCommandChannel, token: CancellationToken) throws {
        let code = try stream.read(1, token: token)[0]
        if code == 0 { return }
        guard code == 1 || code == 2 else { throw ClientError.protocolError("Unexpected SCP acknowledgement.") }
        let message = String(decoding: try stream.line(token: token), as: UTF8.self)
        throw ClientError.remote("SCP", Int(code), message)
    }
    private func verifyDestination(_ path: String, expected: FileEntry?) throws {
        guard let expected else { return }
        guard try exists(path), try stat(path).hasSameVersion(as: expected) else { throw ClientError.conflict("The remote file changed after it was reviewed: \(path)") }
    }

    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil,
                       token: CancellationToken = CancellationToken(), progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let remote = try transferable(remote), manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: local.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw ClientError.unsupported("Only regular files can be uploaded. Symbolic links are not followed.") }
        let size = (before[.size] as? NSNumber)?.uint64Value ?? 0
        var mode = (before[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        try verifyDestination(remote, expected: expectedDestination)
        if try exists(remote) {
            guard replace else { throw ClientError.conflict("The remote file already exists. Confirm replacement first.") }
            let info = try stat(remote)
            guard info.isRegularFile else { throw ClientError.conflict("The destination is not a regular file.") }
            mode = info.permissions
        }
        let folder = RemotePath.join(RemotePath.parent(remote), ".syncscp-" + UUID().uuidString + ".filepart")
        let temporary = RemotePath.join(folder, "payload")
        let session = try ssh()
        _ = try session.run("mkdir -m 700 \"$1\"", arguments: [folder], token: token)
        defer { _ = try? session.run("rm -f \"$1/payload\"; rmdir \"$1\"", arguments: [folder]) }
        let stream = try session.open("exec scp -t \"$1\"", arguments: [folder], token: token)
        defer { stream.close() }
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        try acknowledge(stream, token: token)
        // The protocol name is fixed; user filenames never enter an SCP control line.
        try stream.send(Data("C0600 \(size) payload\n".utf8), token: token)
        try acknowledge(stream, token: token)
        var offset: UInt64 = 0
        progress(0, size)
        while offset < size {
            try token.check()
            let block = try source.read(upToCount: Int(min(size - offset, 65536))) ?? Data()
            guard !block.isEmpty else { throw ClientError.conflict("The local file changed during upload.") }
            try stream.send(block, token: token); offset += UInt64(block.count); progress(offset, size)
        }
        let after = try manager.attributesOfItem(atPath: local.path)
        guard (after[.size] as? NSNumber)?.uint64Value == size, after[.modificationDate] as? Date == before[.modificationDate] as? Date else { throw ClientError.conflict("The local file changed during upload.") }
        try stream.send(Data([0]), token: token); try acknowledge(stream, token: token)
        stream.finishInput()
        guard try stream.finish(token: token, limit: 16384).isEmpty else { throw ClientError.protocolError("Unexpected SCP sink output.") }
        stream.close()
        try token.check()
        try chmod(temporary, mode: mode & 0o777)
        if let date = before[.modificationDate] as? Date {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmm.ss"
            _ = try session.run("TZ=UTC0; export TZ; touch -t \"$1\" \"$2\"", arguments: [formatter.string(from: date), temporary], token: token)
        }
        try verifyDestination(remote, expected: expectedDestination)
        try token.check()
        do {
            // Hard-link publication gives no-clobber semantics, even if a file appears
            // after the initial check. Same-directory temporary storage shares the filesystem.
            let script = replace ? "[ ! -d \"$2\" ] && mv -f \"$1\" \"$2\"" : "link \"$1\" \"$2\""
            if replace, try exists(remote), try !stat(remote).isRegularFile { throw ClientError.conflict("The destination is no longer a regular file.") }
            _ = try session.run(script, arguments: [temporary, remote], token: token)
        } catch {
            if !replace, (try? exists(remote)) == true { throw ClientError.conflict("The destination appeared during upload and was preserved.") }
            throw error
        }
        progress(offset, size)
    }

    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let remote = try transferable(remote), info = try stat(remote), manager = FileManager.default
        guard info.isRegularFile else { throw ClientError.unsupported("Only regular files can be downloaded. Symbolic links and special files are not followed.") }
        if manager.fileExists(atPath: local.path), !replace { throw ClientError.conflict("The local file already exists. Confirm replacement first.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".syncscp-\(UUID().uuidString).filepart")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClientError.invalid("Cannot create a temporary download file.") }
        defer { try? manager.removeItem(at: temporary) }
        let target = try FileHandle(forWritingTo: temporary)
        defer { try? target.close() }
        let stream = try ssh().open("exec scp -f \"$1\"", arguments: [remote], token: token)
        defer { stream.close() }
        try stream.send(Data([0]), token: token)
        let record = try stream.line(token: token)
        if record.first == 1 || record.first == 2 { throw ClientError.remote("SCP", Int(record.first!), String(decoding: record.dropFirst(), as: UTF8.self)) }
        try SCPRecord.file(record, expectedName: (remote as NSString).lastPathComponent, expectedSize: info.size)
        try stream.send(Data([0]), token: token)
        var offset: UInt64 = 0
        progress(0, info.size)
        while offset < info.size {
            try token.check()
            let block = try stream.read(Int(min(info.size - offset, 65536)), token: token)
            try target.write(contentsOf: block); offset += UInt64(block.count); progress(offset, info.size)
        }
        try acknowledge(stream, token: token)
        try stream.send(Data([0]), token: token)
        let tail = try stream.finish(token: token, limit: 16384)
        guard tail.isEmpty else { throw ClientError.protocolError("SCP sent unexpected trailing records.") }
        guard try stat(remote).hasSameVersion(as: info) else { throw ClientError.conflict("The remote file changed during download.") }
        try token.check(); try target.synchronize(); try target.close()
        try manager.setAttributes([.posixPermissions: info.permissions & 0o777, .modificationDate: info.modified ?? Date()], ofItemAtPath: temporary.path)
        let result = temporary.path.withCString { source in local.path.withCString { destination in
            replace ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else {
            if errno == EEXIST { throw ClientError.conflict("The local destination already exists.") }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: local.path])
        }
        progress(offset, info.size)
    }
}
