// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public protocol RemoteFileClient: Actor {
    func disconnect() async
    func realpath(_ path: String) async throws -> String
    func list(_ path: String) async throws -> [FileEntry]
    func stat(_ path: String, followLinks: Bool) async throws -> FileEntry
    func exists(_ path: String) async throws -> Bool
    func mkdir(_ path: String) async throws
    func rename(_ source: String, to destination: String, replace: Bool) async throws
    func chmod(_ path: String, mode: UInt32) async throws
    func remove(_ path: String, recursive: Bool, token: CancellationToken) async throws
    func upload(local: URL, remote: String, replace: Bool, expectedDestination: FileEntry?, token: CancellationToken,
                progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws
    func download(remote: String, local: URL, replace: Bool, token: CancellationToken,
                  progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws
}

extension SFTPClient: RemoteFileClient {}

/// Lets a retried transfer continue a partial (.filepart) file left by a lost connection. One
/// instance per file; the partial is used only while the source keeps the same size and time.
public final class TransferResume: @unchecked Sendable {
    public struct Version: Equatable, Sendable { let size: UInt64; let modified: Date? }
    private let lock = NSLock()
    private var partial: String?
    private var source: Version?
    private var resumed: UInt64 = 0
    public init() {}
    /// Bytes that did not have to be sent again, over all attempts.
    public var resumedBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return resumed }
    func take(source current: Version) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let partial, source == current else { return nil }
        return partial
    }
    func remember(_ path: String, source current: Version) { lock.lock(); partial = path; source = current; lock.unlock() }
    func record(resumedFrom offset: UInt64) { lock.lock(); resumed += offset; lock.unlock() }
    func finish() { lock.lock(); partial = nil; source = nil; lock.unlock() }
}

/// Protocol-independent entry point used by every UI operation.
public actor RemoteSession {
    private var backend: (any RemoteFileClient)?
    public init() {}
    /// For S3 the user name is the access key ID, `password` the secret key and `s3SessionToken` optional temporary credentials.
    public func connect(site: Site, password: String, sshConfiguration: SSHConfiguration? = nil, s3SessionToken: String = "") async throws -> String {
        await disconnect()
        do {
            if site.transferProtocol.usesSSH {
                guard let sshConfiguration, sshConfiguration.site == site else { throw ClientError.invalid("A matching SSH configuration is required for SSH protocols.") }
                if site.transferProtocol == .scp {
                    let client = SCPClient(); backend = client
                    return try await client.connect(sshConfiguration)
                }
                let client = SFTPClient(); backend = client
                return try await client.connect(sshConfiguration)
            } else if site.transferProtocol.usesS3 {
                let client = S3Client(); backend = client
                return try await client.connect(site: site, secretKey: password, sessionToken: s3SessionToken)
            } else if site.transferProtocol.usesWebDAV {
                let client = WebDAVClient(); backend = client
                return try await client.connect(site: site, password: password)
            } else {
                let client = FTPClient(); backend = client
                return try await client.connect(site: site, password: password)
            }
        } catch { await disconnect(); throw error }
    }
    public func disconnect() async { let previous = backend; backend = nil; await previous?.disconnect() }
    private func client() throws -> any RemoteFileClient {
        guard let backend else { throw ClientError.connection("Connect to a site first.") }; return backend
    }
    public func realpath(_ path: String) async throws -> String { try await client().realpath(path) }
    public func list(_ path: String) async throws -> [FileEntry] { try await client().list(path) }
    public func stat(_ path: String, followLinks: Bool = false) async throws -> FileEntry { try await client().stat(path, followLinks: followLinks) }
    public func exists(_ path: String) async throws -> Bool { try await client().exists(path) }
    public func mkdir(_ path: String) async throws { try await client().mkdir(path) }
    public func rename(_ source: String, to destination: String, replace: Bool = false) async throws { try await client().rename(source, to: destination, replace: replace) }
    public func chmod(_ path: String, mode: UInt32) async throws { try await client().chmod(path, mode: mode) }
    public func remove(_ path: String, recursive: Bool = false, token: CancellationToken = CancellationToken()) async throws { try await client().remove(path, recursive: recursive, token: token) }
    /// `resume` is honored by SFTP; other protocols start over on a retry.
    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil,
                       token: CancellationToken = CancellationToken(), resume: TransferResume? = nil,
                       progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws {
        if let sftp = backend as? SFTPClient {
            try await sftp.upload(local: local, remote: remote, replace: replace, expectedDestination: expectedDestination, token: token, resume: resume, progress: progress)
        } else {
            try await client().upload(local: local, remote: remote, replace: replace, expectedDestination: expectedDestination, token: token, progress: progress)
        }
    }
    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         resume: TransferResume? = nil, progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws {
        if let sftp = backend as? SFTPClient {
            try await sftp.download(remote: remote, local: local, replace: replace, token: token, resume: resume, progress: progress)
        } else {
            try await client().download(remote: remote, local: local, replace: replace, token: token, progress: progress)
        }
    }
    /// Copies a file or folder on the server (WinSCP's Duplicate). SCP copies with the server's
    /// own `cp -pR`; other protocols pass each file through a temporary local file. Nothing
    /// existing is replaced, symbolic links are not followed, and a folder cannot go into itself.
    public func copy(_ source: String, to destination: String, token: CancellationToken = CancellationToken()) async throws {
        guard destination != source, !destination.hasPrefix(source.hasSuffix("/") ? source : source + "/") else {
            throw ClientError.invalid("A folder cannot be copied into itself.")
        }
        if let scp = backend as? SCPClient { try await scp.copy(source, to: destination); return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-copy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await copyTree(try stat(source), to: destination, through: scratch, token: token, depth: 0)
    }

    private func copyTree(_ entry: FileEntry, to destination: String, through scratch: URL, token: CancellationToken, depth: Int) async throws {
        try token.check()
        guard depth < 64 else { throw ClientError.unsupported("Copies are limited to 64 folder levels.") }
        if entry.isDirectory {
            guard try await !exists(destination) else { throw ClientError.conflict("\(destination) already exists.") }
            try await mkdir(destination)
            for child in try await list(entry.path) {
                try await copyTree(child, to: RemotePath.join(destination, child.name), through: scratch, token: token, depth: depth + 1)
            }
        } else if entry.isRegularFile {
            let temporary = scratch.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await download(remote: entry.path, local: temporary, token: token)
            try await upload(local: temporary, remote: destination, replace: false, token: token)
        } else {
            throw ClientError.unsupported("Symbolic links and special files are not copied: \(entry.name)")
        }
    }

    /// Whether retried transfers continue partial files (SFTP) instead of starting over.
    public var resumesTransfers: Bool { backend is SFTPClient }
}
