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
    /// Whether retried transfers continue partial files (SFTP) instead of starting over.
    public var resumesTransfers: Bool { backend is SFTPClient }
}
