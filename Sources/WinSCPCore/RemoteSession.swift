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

/// Protocol-independent entry point used by every UI operation.
public actor RemoteSession {
    private var backend: (any RemoteFileClient)?
    public init() {}
    public func connect(site: Site, password: String, sshConfiguration: SSHConfiguration? = nil) async throws -> String {
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
    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil,
                       token: CancellationToken = CancellationToken(), progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws {
        try await client().upload(local: local, remote: remote, replace: replace, expectedDestination: expectedDestination, token: token, progress: progress)
    }
    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws {
        try await client().download(remote: remote, local: local, replace: replace, token: token, progress: progress)
    }
}
