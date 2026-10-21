// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public actor FTPClient: RemoteFileClient {
    private var transport: CurlFTPTransport?
    private var supportsMLSD = true
    public private(set) var home = "/"
    public init() {}

    public func connect(site: Site, password: String) throws -> String {
        disconnect(); try site.validate()
        guard site.transferProtocol.usesFTP else { throw ClientError.invalid("Choose an FTP or FTPS protocol.") }
        do {
            transport = try CurlFTPTransport(site: site, password: password)
            let response = try requireTransport().perform(path: "/", loginHome: true, operation: 3)
            home = try FTPPath.normalize(response.entryPath.isEmpty ? "/" : response.entryPath)
            _ = try list(home)
            return home
        } catch { disconnect(); throw error }
    }
    public func disconnect() { transport = nil; supportsMLSD = true; home = "/" }
    private func requireTransport() throws -> CurlFTPTransport {
        guard let transport else { throw ClientError.connection("Connect to an FTP site first.") }; return transport
    }
    private func path(_ value: String) throws -> String { try FTPPath.normalize(value, relativeTo: home) }
    private func commands(_ values: [String], token: CancellationToken = CancellationToken()) throws {
        _ = try requireTransport().perform(path: home, commands: values, operation: 3, token: token)
    }
    public func realpath(_ value: String) throws -> String {
        let normalized = try path(value)
        _ = try requireTransport().perform(path: normalized, operation: 3)
        return normalized
    }
    public func list(_ value: String) throws -> [FileEntry] {
        let normalized = try path(value)
        if supportsMLSD {
            do {
                let response = try requireTransport().perform(path: normalized, method: "MLSD", commands: ["*OPTS MLST type;size;modify;unix.mode;"])
                return try FTPListing.mlsd(response.body, directory: normalized)
            } catch ClientError.remote(_, let code, _) where [500, 501, 502, 504].contains(code) {
                supportsMLSD = false
            } catch ClientError.unsupported {
                // Optional MLSD facts may be missing even when the command exists.
                supportsMLSD = false
            }
        }
        let response = try requireTransport().perform(path: normalized, method: "LIST")
        return try FTPListing.legacy(response.body, directory: normalized)
    }
    public func stat(_ value: String, followLinks: Bool = false) throws -> FileEntry {
        guard !followLinks else { throw ClientError.unsupported("Following FTP symbolic links is not supported.") }
        let normalized = try path(value)
        if normalized == "/" {
            _ = try realpath(normalized)
            return FileEntry(path: normalized, name: "/", permissions: 0o040755, permissionsKnown: false)
        }
        let parent = RemotePath.parent(normalized)
        guard let entry = try list(parent).first(where: { $0.path == normalized }) else {
            throw ClientError.remote("FTP", 550, "The file is not present in its parent directory: \(normalized)")
        }
        return entry
    }
    public func exists(_ value: String) throws -> Bool {
        let normalized = try path(value)
        if normalized == "/" { _ = try realpath(normalized); return true }
        return try list(RemotePath.parent(normalized)).contains { $0.path == normalized }
    }
    public func mkdir(_ value: String) throws {
        let normalized = try path(value)
        guard normalized != "/", try !exists(normalized) else { throw ClientError.conflict("The destination already exists: \(normalized)") }
        try commands(["MKD " + normalized])
    }
    public func rename(_ source: String, to destination: String, replace: Bool = false) throws {
        let source = try path(source); let destination = try path(destination)
        guard source != "/", destination != "/", source != destination else { throw ClientError.invalid("Choose distinct, non-root FTP paths for rename.") }
        if try exists(destination) {
            guard replace else { throw ClientError.conflict("The destination already exists: \(destination)") }
            guard try stat(destination).isRegularFile else { throw ClientError.conflict("The destination is not a regular file: \(destination)") }
        }
        // FTP RNTO replacement and atomicity are server-dependent; no delete-first fallback.
        try commands(["RNFR " + source, "RNTO " + destination])
    }
    public func chmod(_ value: String, mode: UInt32) throws {
        guard mode <= 0o7777 else { throw ClientError.invalid("Invalid POSIX permissions.") }
        try commands(["SITE CHMOD " + String(mode, radix: 8) + " " + path(value)])
    }
    public func remove(_ value: String, recursive: Bool = false, token: CancellationToken = CancellationToken()) throws {
        let normalized = try path(value)
        guard normalized != "/", value != ".", value != ".." else { throw ClientError.invalid("Refusing to delete a root or parent directory.") }
        try token.check()
        var entry = try stat(normalized)
        if recursive && entry.isDirectory {
            guard let found = try deletionEntries(RemotePath.parent(normalized)).first(where: { $0.path == normalized }) else {
                throw ClientError.remote("FTP", 550, "The file is not present in its parent directory.")
            }
            entry = found
        }
        try removeTree(entry, recursive: recursive, token: token, depth: 0)
    }
    private func deletionEntries(_ directory: String) throws -> [FileEntry] {
        // MLSD servers may resolve symlinks before reporting type=dir/file. Unix LIST
        // identifies the link itself, which is essential before recursive deletion.
        let listing = try requireTransport().perform(path: directory, method: "LIST")
        let entries = try FTPListing.legacy(listing.body, directory: directory)
        guard entries.allSatisfy(\.permissionsKnown) else {
            throw ClientError.unsupported("Recursive FTP deletion requires Unix LIST entries that distinguish symbolic links. This server does not expose those types.")
        }
        return entries
    }
    private func removeTree(_ entry: FileEntry, recursive: Bool, token: CancellationToken, depth: Int) throws {
        try token.check()
        guard depth < 64 else { throw ClientError.unsupported("Recursive FTP deletion is limited to 64 levels.") }
        if entry.isDirectory {
            if recursive { for child in try deletionEntries(entry.path) { try removeTree(child, recursive: true, token: token, depth: depth + 1) } }
            try commands(["RMD " + entry.path], token: token)
        } else {
            guard entry.isRegularFile || entry.isSymbolicLink else { throw ClientError.unsupported("Cannot delete an unidentified FTP file type.") }
            try commands(["DELE " + entry.path], token: token)
        }
    }

    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil,
                       token: CancellationToken = CancellationToken(), progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let destination = try path(remote)
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: local.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ClientError.unsupported("Only regular local files can be uploaded.") }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let expectedDestination { try verify(expectedDestination, at: destination) }
        var mode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        if try exists(destination) {
            guard replace else { throw ClientError.conflict("The destination already exists: \(destination)") }
            let existing = try stat(destination)
            guard existing.isRegularFile else { throw ClientError.conflict("The destination is not a regular file.") }
            if existing.permissionsKnown { mode = existing.permissions }
        }
        let temporary = RemotePath.join(RemotePath.parent(destination), ".winscp-\(UUID().uuidString).filepart")
        var committed = false
        defer { if !committed { try? commands(["DELE " + temporary]) } }
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        progress(0, size)
        _ = try requireTransport().perform(path: temporary, directory: false, operation: 2, file: source.fileDescriptor, size: size, token: token, progress: progress)
        try token.check()
        let after = try manager.attributesOfItem(atPath: local.path)
        guard try source.offset() == size,
              (after[.size] as? NSNumber)?.uint64Value == size,
              after[.modificationDate] as? Date == attributes[.modificationDate] as? Date else {
            throw ClientError.conflict("The local file changed during upload. Transfer it again.")
        }
        try commands(["*SITE CHMOD " + String(mode & 0o777, radix: 8) + " " + temporary], token: token)
        if let date = attributes[.modificationDate] as? Date {
            try commands(["*MFMT " + FTPListing.timestampFormatter().string(from: date) + " " + temporary], token: token)
        }
        if let expectedDestination { try verify(expectedDestination, at: destination) }
        try token.check()
        try rename(temporary, to: destination, replace: replace)
        committed = true; progress(size, size)
    }

    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let remote = try path(remote); let info = try stat(remote)
        guard info.isRegularFile else { throw ClientError.unsupported("Only identified regular FTP files can be downloaded.") }
        let manager = FileManager.default
        if manager.fileExists(atPath: local.path), !replace { throw ClientError.conflict("The local destination already exists.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".winscp-\(UUID().uuidString).filepart")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClientError.invalid("Cannot create a temporary download file.") }
        defer { try? manager.removeItem(at: temporary) }
        let target = try FileHandle(forWritingTo: temporary)
        defer { try? target.close() }
        progress(0, info.size)
        _ = try requireTransport().perform(path: remote, directory: false, operation: 1, file: target.fileDescriptor, token: token, progress: progress)
        try token.check()
        guard try target.offset() == info.size else { throw ClientError.conflict("The remote file changed during download.") }
        try verify(info, at: remote)
        try target.synchronize(); try target.close()
        if info.permissionsKnown { try manager.setAttributes([.posixPermissions: info.permissions & 0o777], ofItemAtPath: temporary.path) }
        if let modified = info.modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path) }
        let result = temporary.path.withCString { source in local.path.withCString { destination in
            replace ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else {
            if errno == EEXIST { throw ClientError.conflict("The local destination appeared during download.") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        progress(info.size, info.size)
    }

    private func verify(_ snapshot: FileEntry, at path: String) throws {
        guard try stat(path).hasSameVersion(as: snapshot) else { throw ClientError.conflict("The remote file changed after it was reviewed: \(path)") }
    }
}
