// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public enum ClientError: LocalizedError, Equatable {
    case invalid(String), connection(String), protocolError(String), server(UInt32, String)
    case remote(String, Int, String)
    case conflict(String), cancelled, unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .connection(let text), .protocolError(let text), .conflict(let text), .unsupported(let text): return text
        case .server(let code, let text): return "SFTP \(code): \(text)"
        case .remote(let name, let code, let text): return "\(name) \(code): \(text)"
        case .cancelled: return "Transfer cancelled."
        }
    }
}

public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp, scp, ftp, ftpsExplicit, ftpsImplicit, webdav, webdavs, s3, s3http
    public var title: String {
        switch self { case .sftp: return "SFTP"; case .scp: return "SCP"; case .ftp: return "FTP"; case .ftpsExplicit: return "FTPS · Explicit TLS"; case .ftpsImplicit: return "FTPS · Implicit TLS"; case .webdav: return "WebDAV · HTTP"; case .webdavs: return "WebDAV · HTTPS"; case .s3: return "S3 · HTTPS"; case .s3http: return "S3 · HTTP" }
    }
    public var shortTitle: String { usesSSH ? title : usesS3 ? "S3" : usesWebDAV ? (isEncrypted ? "WebDAVS" : "WebDAV") : self == .ftp ? "FTP" : "FTPS" }
    public var usesWebDAV: Bool { self == .webdav || self == .webdavs }
    public var usesS3: Bool { self == .s3 || self == .s3http }
    /// Whether the protocol has a POSIX permission model the UI may edit.
    public var supportsPermissions: Bool { !usesWebDAV && !usesS3 }
    public var usesFTP: Bool { self == .ftp || self == .ftpsExplicit || self == .ftpsImplicit }
    public var usesSSH: Bool { self == .sftp || self == .scp }
    public var defaultPort: Int { usesSSH ? 22 : usesWebDAV || usesS3 ? (isEncrypted ? 443 : 80) : self == .ftpsImplicit ? 990 : 21 }
    public var isEncrypted: Bool { self != .ftp && self != .webdav && self != .s3http }
}

public struct Site: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var privateKey: String
    public var remotePath: String
    public var localPath: String
    public var transferProtocol: TransferProtocol
    public var certificateAuthorityFile: String
    /// S3 signing region; empty means us-east-1.
    public var s3Region: String
    /// Path-style S3 URLs (`host/bucket/key`) instead of virtual-hosted (`bucket.host/key`).
    public var s3PathStyle: Bool
    /// WinSCP Advanced Site Settings.
    public var settings: SiteSettings

    public init(id: UUID = UUID(), name: String = "", host: String = "", port: Int? = nil,
                username: String = NSUserName(), privateKey: String = "", remotePath: String = ".",
                localPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
                transferProtocol: TransferProtocol = .sftp, certificateAuthorityFile: String = "",
                s3Region: String = "", s3PathStyle: Bool = false, settings: SiteSettings = SiteSettings()) {
        self.id = id; self.name = name; self.host = host; self.port = port ?? transferProtocol.defaultPort
        self.username = username; self.privateKey = privateKey; self.remotePath = remotePath; self.localPath = localPath
        self.transferProtocol = transferProtocol; self.certificateAuthorityFile = certificateAuthorityFile
        self.s3Region = s3Region; self.s3PathStyle = s3PathStyle; self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case id, name, host, port, username, privateKey, remotePath, localPath, transferProtocol, certificateAuthorityFile, s3Region, s3PathStyle, settings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host); port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username); privateKey = try values.decode(String.self, forKey: .privateKey)
        remotePath = try values.decode(String.self, forKey: .remotePath); localPath = try values.decode(String.self, forKey: .localPath)
        transferProtocol = try values.decodeIfPresent(TransferProtocol.self, forKey: .transferProtocol) ?? .sftp
        certificateAuthorityFile = try values.decodeIfPresent(String.self, forKey: .certificateAuthorityFile) ?? ""
        s3Region = try values.decodeIfPresent(String.self, forKey: .s3Region) ?? ""
        s3PathStyle = try values.decodeIfPresent(Bool.self, forKey: .s3PathStyle) ?? false
        settings = try values.decodeIfPresent(SiteSettings.self, forKey: .settings) ?? SiteSettings()
    }

    public var displayName: String { name.isEmpty ? "\(username)@\(host)" : name }

    public func validate() throws {
        guard !host.isEmpty, !host.hasPrefix("-"), host.utf8.count <= 253,
              host.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !host.contains("/"), !host.contains("@"), !host.contains("%"), !host.contains("?"), !host.contains("#") else { throw ClientError.invalid("Enter a valid server host name or IP address.") }
        guard (1...65535).contains(port) else { throw ClientError.invalid("Port must be between 1 and 65535.") }
        guard !username.isEmpty, username.rangeOfCharacter(from: .controlCharacters) == nil else { throw ClientError.invalid("Enter a valid username.") }
        try settings.validate()
        if transferProtocol.usesSSH, !privateKey.isEmpty, !FileManager.default.fileExists(atPath: (privateKey as NSString).expandingTildeInPath) {
            throw ClientError.invalid("The private key file does not exist.")
        }
        if !transferProtocol.usesSSH {
            if transferProtocol.usesWebDAV || transferProtocol.usesS3 { _ = try DAVPath.normalize(remotePath) }
            else { try FTPPath.validate(remotePath) }
            if transferProtocol.usesS3 {
                guard username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw ClientError.invalid("Enter a valid S3 access key ID.") }
                guard s3Region.utf8.count <= 64, s3Region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                    throw ClientError.invalid("Enter an S3 region such as us-east-1, using lowercase letters, digits and hyphens.")
                }
            }
            if transferProtocol.usesWebDAV, username.contains(":") { throw ClientError.invalid("WebDAV Basic authentication usernames cannot contain a colon.") }
            if transferProtocol.isEncrypted, !certificateAuthorityFile.isEmpty, !FileManager.default.fileExists(atPath: (certificateAuthorityFile as NSString).expandingTildeInPath) {
                throw ClientError.invalid("The certificate authority file does not exist.")
            }
        }
    }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var size: UInt64
    public var permissions: UInt32
    public var modified: Date?
    public var permissionsKnown: Bool
    public var versionTag: String?
    public var id: String { path }
    public var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    public var isSymbolicLink: Bool { permissions & 0o170000 == 0o120000 }
    public var isRegularFile: Bool { permissions & 0o170000 == 0o100000 }
    public var isHidden: Bool { name.hasPrefix(".") }

    public func hasSameVersion(as other: FileEntry) -> Bool {
        size == other.size && modified == other.modified && permissions == other.permissions && versionTag == other.versionTag
    }

    public init(path: String, name: String, size: UInt64 = 0, permissions: UInt32 = 0o100644, modified: Date? = nil, permissionsKnown: Bool = true, versionTag: String? = nil) {
        self.path = path; self.name = name; self.size = size; self.permissions = permissions; self.modified = modified; self.permissionsKnown = permissionsKnown; self.versionTag = versionTag
    }

    public var rights: String {
        guard permissionsKnown else { return "—" }
        let bits: [(UInt32, String)] = [(0o400,"r"),(0o200,"w"),(0o100,"x"),(0o40,"r"),(0o20,"w"),(0o10,"x"),(0o4,"r"),(0o2,"w"),(0o1,"x")]
        return (isDirectory ? "d" : isSymbolicLink ? "l" : "-") + bits.map { permissions & $0.0 != 0 ? $0.1 : "-" }.joined()
    }
}

public enum RemotePath {
    public static func join(_ directory: String, _ name: String) -> String { directory == "/" ? "/" + name : directory + "/" + name }
    public static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ClientError.invalid("A file name cannot be empty, '.', '..', or contain '/' or a null character.")
        }
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw ClientError.cancelled } }
}

public enum LocalFiles {
    public static func info(_ path: String) throws -> FileEntry {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        // Use the same timestamp conversion for listing and snapshot revalidation.
        // Foundation's full attributes also fetch extended attributes, which can
        // stall on cloud/provider files. Only no-follow POSIX stat is needed here.
        var attributes = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &attributes) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileEntry(path: url.path, name: url.lastPathComponent,
                         size: UInt64(max(0, attributes.st_size)), permissions: UInt32(attributes.st_mode),
                         modified: Date(timeIntervalSince1970: Double(attributes.st_mtimespec.tv_sec) + Double(attributes.st_mtimespec.tv_nsec) / 1_000_000_000))
    }
    public static func list(_ path: String) throws -> [FileEntry] {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map { url in
            try info(url.path)
        }.sorted(by: order)
    }

    public static func order(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
