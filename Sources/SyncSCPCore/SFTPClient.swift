// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public actor SFTPClient {
    private var transport: SSHTransport?
    private var sequence: UInt32 = 0
    private var extensions: [String: String] = [:]
    public private(set) var home = "/"

    public init() {}

    public func connect(_ configuration: SSHConfiguration) throws -> String {
        guard configuration.site.transferProtocol == .sftp else { throw ClientError.invalid("Choose the SFTP protocol.") }
        var environment: [String: String] = [:]
        if let executable = configuration.askpassExecutable, let id = configuration.credentialID {
            environment = ["SSH_ASKPASS": executable, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "syncscp:0", "SYNCSCP_ASKPASS_ID": id]
        }
        return try start(executable: "/usr/bin/ssh", arguments: configuration.arguments(), environment: environment)
    }

    /// Exercises the real SFTP protocol against a local OpenSSH server without opening a network port.
    public func connectLocalServer(root: String) throws -> String {
        try start(executable: "/usr/libexec/sftp-server", arguments: ["-d", root])
    }

    private func start(executable: String, arguments: [String], environment: [String: String] = [:]) throws -> String {
        disconnect()
        do {
            transport = try SSHTransport(executable: executable, arguments: arguments, environment: environment)
            var packet = PacketWriter(); packet.byte(1); packet.uint32(3)
            try transport!.send(packet.data)
            var response = PacketReader(data: try transport!.receive())
            guard try response.byte() == 2, try response.uint32() == 3 else {
                throw ClientError.unsupported("The server must support SFTP version 3.")
            }
            while response.remaining > 0 { let key = try response.string(); extensions[key] = try response.string() }
            home = try realpath(".")
            return home
        } catch { disconnect(); throw error }
    }

    public func disconnect() { transport?.close(); transport = nil; extensions = [:]; sequence = 0 }

    private func request(_ type: UInt8, _ encode: (inout PacketWriter) -> Void) throws -> (UInt8, PacketReader) {
        guard let transport else { throw ClientError.connection("Connect to a site first.") }
        sequence &+= 1
        var packet = PacketWriter(); packet.byte(type); packet.uint32(sequence); encode(&packet)
        do {
            try transport.send(packet.data)
            var reader = PacketReader(data: try transport.receive())
            let responseType = try reader.byte()
            guard try reader.uint32() == sequence else { throw ClientError.protocolError("SFTP response ID does not match the request.") }
            return (responseType, reader)
        } catch { disconnect(); throw error }
    }

    private func status(_ response: (UInt8, PacketReader), allowEOF: Bool = false) throws -> Bool {
        guard response.0 == 101 else { throw ClientError.protocolError("Expected SFTP status, received \(response.0).") }
        var reader = response.1
        let code = try reader.uint32()
        let message = try reader.string()
        _ = try reader.string()
        if code == 0 { return true }
        if code == 1 && allowEOF { return false }
        throw ClientError.server(code, message.isEmpty ? "The server rejected the operation." : message)
    }

    private func handle(_ type: UInt8, _ path: String, flags: UInt32? = nil) throws -> Data {
        let response = try request(type) { packet in
            packet.string(path)
            if let flags { packet.uint32(flags); packet.uint32(0) }
        }
        if response.0 == 101 { _ = try status(response) }
        guard response.0 == 102 else { throw ClientError.protocolError("Expected an SFTP file handle.") }
        var reader = response.1
        return try reader.bytes()
    }

    private func closeHandle(_ handle: Data) throws { _ = try status(request(4) { $0.bytes(handle) }) }

    public func realpath(_ path: String) throws -> String {
        let response = try request(16) { $0.string(path) }
        if response.0 == 101 { _ = try status(response) }
        guard response.0 == 104 else { throw ClientError.protocolError("Expected a canonical SFTP path.") }
        var reader = response.1
        guard try reader.uint32() == 1 else { throw ClientError.protocolError("Invalid canonical SFTP path.") }
        return try reader.string()
    }

    public func list(_ path: String) throws -> [FileEntry] {
        let directory = try handle(11, path)
        defer { try? closeHandle(directory) }
        var entries: [FileEntry] = []
        while true {
            let response = try request(12) { $0.bytes(directory) }
            if response.0 == 101 {
                if try !status(response, allowEOF: true) { break }
                throw ClientError.protocolError("Unexpected success status during directory listing.")
            }
            guard response.0 == 104 else { throw ClientError.protocolError("Expected an SFTP directory listing.") }
            var reader = response.1
            let count = try reader.uint32()
            guard count > 0, count <= 100_000, entries.count + Int(count) <= 1_000_000 else {
                throw ClientError.protocolError("Invalid or excessively large SFTP directory listing.")
            }
            for _ in 0..<count {
                let name = try reader.string(); _ = try reader.string()
                let entry = try reader.attributes(path: RemotePath.join(path, name), name: name)
                if name != ".", name != ".." {
                    try RemotePath.validateName(name)
                    entries.append(entry)
                }
            }
        }
        return entries.sorted(by: LocalFiles.order)
    }

    public func stat(_ path: String, followLinks: Bool = false) throws -> FileEntry {
        let response = try request(followLinks ? 17 : 7) { $0.string(path) }
        if response.0 == 101 { _ = try status(response) }
        guard response.0 == 105 else { throw ClientError.protocolError("Expected SFTP file attributes.") }
        var reader = response.1
        return try reader.attributes(path: path, name: (path as NSString).lastPathComponent)
    }

    public func exists(_ path: String) throws -> Bool {
        do { _ = try stat(path); return true }
        catch ClientError.server(2, _) { return false }
    }

    public func mkdir(_ path: String) throws { _ = try status(request(14) { $0.string(path); $0.uint32(4); $0.uint32(0o755) }) }

    public func rename(_ source: String, to destination: String, replace: Bool = false) throws {
        if replace {
            guard extensions["posix-rename@openssh.com"] != nil else {
                throw ClientError.unsupported("This server does not support atomic replacement. Rename the destination first.")
            }
            _ = try status(request(200) { $0.string("posix-rename@openssh.com"); $0.string(source); $0.string(destination) })
        } else {
            _ = try status(request(18) { $0.string(source); $0.string(destination) })
        }
    }

    public func chmod(_ path: String, mode: UInt32) throws {
        guard mode <= 0o7777 else { throw ClientError.invalid("Invalid POSIX file permissions.") }
        _ = try status(request(9) { $0.string(path); $0.uint32(4); $0.uint32(mode) })
    }

    public func remove(_ path: String, recursive: Bool = false, token: CancellationToken = CancellationToken()) throws {
        try token.check()
        guard path != "/", path != ".", path != "..", !path.hasSuffix("/.."), !path.hasSuffix("/.") else {
            throw ClientError.invalid("Refusing to delete a root or parent directory.")
        }
        let entry = try stat(path)
        if entry.isDirectory {
            guard try realpath(path) != "/" else { throw ClientError.invalid("Refusing to delete the remote root directory.") }
            if recursive { for child in try list(path) { try remove(child.path, recursive: true, token: token) } }
            _ = try status(request(15) { $0.string(path) })
        } else {
            // LSTAT ensures a symlink is removed, never traversed.
            _ = try status(request(13) { $0.string(path) })
        }
    }

    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil, token: CancellationToken = CancellationToken(),
                       progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ClientError.unsupported("Only regular files can be uploaded. Symbolic links are not followed.")
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let expectedDestination {
            guard try stat(remote).hasSameVersion(as: expectedDestination) else {
                throw ClientError.conflict("The remote file changed after it was reviewed: \(remote)")
            }
        }
        var mode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        if try exists(remote) {
            guard replace else { throw ClientError.conflict("\(remote) already exists. Confirm replacement first.") }
            let existing = try stat(remote)
            guard existing.isRegularFile else { throw ClientError.conflict("The destination is not a regular file: \(remote)") }
            mode = existing.permissions
        }
        let temporary = RemotePath.join(RemotePath.parent(remote), ".syncscp-" + UUID().uuidString + ".filepart")
        let file = try handle(3, temporary, flags: 2 | 8 | 32)
        var opened = true
        var committed = false
        defer {
            if opened { try? closeHandle(file) }
            if !committed { _ = try? status(request(13) { $0.string(temporary) }) }
        }
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        var offset: UInt64 = 0
        progress(0, size)
        while let data = try source.read(upToCount: 64 * 1024), !data.isEmpty {
            try token.check()
            _ = try status(request(6) { $0.bytes(file); $0.uint64(offset); $0.bytes(data) })
            offset += UInt64(data.count); progress(offset, size)
        }
        try token.check()
        let sourceAfter = try FileManager.default.attributesOfItem(atPath: local.path)
        guard offset == size,
              (sourceAfter[.size] as? NSNumber)?.uint64Value == size,
              sourceAfter[.modificationDate] as? Date == attributes[.modificationDate] as? Date else {
            throw ClientError.conflict("The local file changed during upload. Transfer it again.")
        }
        try closeHandle(file); opened = false
        try chmod(temporary, mode: mode & 0o777)
        if let modified = attributes[.modificationDate] as? Date {
            let timestamp = UInt32(clamping: Int64(modified.timeIntervalSince1970))
            _ = try status(request(9) { $0.string(temporary); $0.uint32(8); $0.uint32(timestamp); $0.uint32(timestamp) })
        }
        // Recheck at commit time: an unapproved concurrent file must never be replaced.
        if let expectedDestination {
            guard try stat(remote).hasSameVersion(as: expectedDestination) else {
                throw ClientError.conflict("The remote file changed during upload: \(remote)")
            }
        }
        if replace, try exists(remote) { try rename(temporary, to: remote, replace: true) }
        else { try rename(temporary, to: remote) }
        committed = true
        progress(offset, offset)
    }

    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let info = try stat(remote)
        guard info.isRegularFile else { throw ClientError.unsupported("Only regular files can be downloaded. Symbolic links and special files are not followed.") }
        let manager = FileManager.default
        if manager.fileExists(atPath: local.path), !replace { throw ClientError.conflict("\(local.lastPathComponent) already exists. Confirm replacement first.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".syncscp-\(UUID().uuidString).filepart")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ClientError.invalid("Cannot create a temporary download file.")
        }
        defer { try? manager.removeItem(at: temporary) }
        let target = try FileHandle(forWritingTo: temporary)
        defer { try? target.close() }
        let file = try handle(3, remote, flags: 1)
        defer { try? closeHandle(file) }
        var offset: UInt64 = 0
        progress(0, info.size)
        while true {
            try token.check()
            let response = try request(5) { $0.bytes(file); $0.uint64(offset); $0.uint32(64 * 1024) }
            if response.0 == 101 {
                if try !status(response, allowEOF: true) { break }
                throw ClientError.protocolError("Unexpected success status during download.")
            }
            guard response.0 == 103 else { throw ClientError.protocolError("Expected SFTP file data.") }
            var reader = response.1
            let data = try reader.bytes()
            guard !data.isEmpty, data.count <= 64 * 1024 else { throw ClientError.protocolError("Invalid SFTP data block.") }
            try target.write(contentsOf: data); offset += UInt64(data.count); progress(offset, info.size)
        }
        try token.check()
        guard offset == info.size else { throw ClientError.conflict("The remote file changed during download. Download it again.") }
        let current = try stat(remote)
        guard current.size == info.size, current.modified == info.modified else { throw ClientError.conflict("The remote file changed during download. Download it again.") }
        try target.synchronize(); try target.close()
        try manager.setAttributes([.posixPermissions: info.permissions & 0o777], ofItemAtPath: temporary.path)
        if let modified = info.modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path) }
        // renamex_np(RENAME_EXCL) is an atomic, no-clobber move on macOS.
        let result = temporary.path.withCString { source in local.path.withCString { destination in
            replace ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else {
            if errno == EEXIST { throw ClientError.conflict("\(local.lastPathComponent) already exists.") }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: local.path])
        }
        progress(offset, offset)
    }
}
