// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin

/// A remote file being edited in an external application (WinSCP's "external editor").
/// The file is downloaded into a private folder; `syncIfChanged` uploads it only when its
/// content differs from what was last synced, and only if the server still has the version
/// that was opened or last uploaded.
public actor RemoteEdit {
    public enum SyncResult: Equatable, Sendable {
        case unchanged
        case uploaded(FileEntry)
        /// The server's file changed since it was opened or last uploaded; nothing was written.
        case conflict
        /// The local copy is missing (for example in the middle of an editor's atomic save).
        case missing
    }

    public nonisolated let remotePath: String
    public nonisolated let localFile: URL
    public private(set) var remoteVersion: FileEntry
    private var syncedDigest: Data
    private let client: RemoteSession

    /// Downloads `entry` into a new owner-only folder under `directory`.
    public init(client: RemoteSession, entry: FileEntry, directory: URL) async throws {
        guard entry.isRegularFile else { throw ClientError.unsupported("Only regular files can be edited.") }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(entry.name)
        do {
            try await client.download(remote: entry.path, local: file)
            let opened = try await client.stat(entry.path)
            self.client = client; remotePath = entry.path; localFile = file; remoteVersion = opened
            syncedDigest = try Self.digest(file)
        } catch {
            try? FileManager.default.removeItem(at: folder); throw error
        }
    }

    public var hasUnsyncedChanges: Bool {
        guard let current = try? Self.digest(localFile) else { return false }
        return current != syncedDigest
    }

    public func syncIfChanged(token: CancellationToken = CancellationToken()) async throws -> SyncResult {
        guard FileManager.default.fileExists(atPath: localFile.path) else { return .missing }
        let current = try Self.digest(localFile)
        guard current != syncedDigest else { return .unchanged }
        do {
            try await client.upload(local: localFile, remote: remotePath, replace: true, expectedDestination: remoteVersion, token: token)
        } catch ClientError.conflict {
            // Either the server copy changed, or the editor wrote again during upload; both are re-checked.
            if let now = try? await client.stat(remotePath), now.hasSameVersion(as: remoteVersion) {
                return try await syncIfChanged(token: token)
            }
            return .conflict
        }
        return try await recordUploaded(current)
    }

    /// Replaces whatever is on the server with the local copy, after the user chose to overwrite.
    public func overwrite(token: CancellationToken = CancellationToken()) async throws -> FileEntry {
        let current = try Self.digest(localFile)
        let server = try await client.stat(remotePath)
        try await client.upload(local: localFile, remote: remotePath, replace: true, expectedDestination: server, token: token)
        guard case .uploaded(let entry) = try await recordUploaded(current) else { throw ClientError.protocolError("Upload was not recorded.") }
        return entry
    }

    private func recordUploaded(_ digest: Data) async throws -> SyncResult {
        remoteVersion = try await client.stat(remotePath); syncedDigest = digest
        return .uploaded(remoteVersion)
    }

    /// Removes the private folder. Callers keep it when there are unsynced changes.
    public func discard() { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }

    static func digest(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }
}

/// Notices saves by any editor: in-place writes and atomic replace-on-save (new inode) alike.
/// Polls the file's inode, size and modification time; once a change has been stable for one
/// interval, `onChange` runs. Polling one small stat per second per edited file is negligible.
public final class FileChangeMonitor: @unchecked Sendable {
    private struct Signature: Equatable { let inode: UInt64; let size: Int64; let seconds: Int; let nanoseconds: Int }
    private let timer: DispatchSourceTimer
    private let file: URL
    private var reported: Signature?
    private var candidate: Signature?

    public init(file: URL, interval: TimeInterval = 1, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.github.oguzhankrcb.syncscp.file-monitor"))
        reported = Self.signature(file)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.signature(self.file)
            guard let now, now != self.reported else { self.candidate = nil; return }
            // Report only once the file has stopped changing (editors may write in several steps).
            if now == self.candidate { self.reported = now; self.candidate = nil; onChange() }
            else { self.candidate = now }
        }
        timer.resume()
    }
    private static func signature(_ file: URL) -> Signature? {
        var info = Darwin.stat()
        guard file.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        return Signature(inode: UInt64(info.st_ino), size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
    public func stop() { timer.cancel() }
    deinit { timer.cancel() }
}
