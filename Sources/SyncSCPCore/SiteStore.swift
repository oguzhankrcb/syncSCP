// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SiteStore: Sendable {
    public let directory: URL
    public var knownHostsFile: URL { directory.appendingPathComponent("known_hosts") }
    private var sitesFile: URL { directory.appendingPathComponent("sites.json") }

    /// Folder names under Application Support: the current one and the one used before the
    /// project was renamed from "WinSCP for macOS" to syncSCP.
    public static let directoryName = "SyncSCP"
    public static let legacyDirectoryName = "WinSCPMac"

    public init(directory: URL? = nil) throws {
        if directory == nil {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try Self.migrateLegacy(from: support.appendingPathComponent(Self.legacyDirectoryName, isDirectory: true),
                                   to: support.appendingPathComponent(Self.directoryName, isDirectory: true))
        }
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: knownHostsFile.path) {
            guard FileManager.default.createFile(atPath: knownHostsFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw ClientError.invalid("Cannot create the host key store.") }
        }
    }

    /// Copies the pre-rename data folder (sites, known_hosts, converted keys, edits, backups)
    /// once, when the new folder does not exist yet. The old folder is left as a backup.
    /// Absolute paths inside sites.json that point into the old folder are rewritten.
    @discardableResult
    public static func migrateLegacy(from old: URL, to new: URL) throws -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: new.path), manager.fileExists(atPath: old.path) else { return false }
        try manager.copyItem(at: old, to: new)
        let store = try SiteStore(directory: new)
        let oldPrefix = old.path + "/", newPrefix = new.path + "/"
        func moved(_ path: String) -> String { path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path }
        let sites = try store.load().map { site -> Site in
            var site = site
            site.privateKey = moved(site.privateKey); site.certificateAuthorityFile = moved(site.certificateAuthorityFile)
            site.localPath = moved(site.localPath)
            site.settings.tunnelPrivateKey = moved(site.settings.tunnelPrivateKey); site.settings.certificateFile = moved(site.settings.certificateFile)
            site.settings.tlsClientCertificate = moved(site.settings.tlsClientCertificate)
            return site
        }
        if !sites.isEmpty { try store.save(sites) }
        return true
    }

    public func load() throws -> [Site] {
        guard FileManager.default.fileExists(atPath: sitesFile.path) else { return [] }
        return try JSONDecoder().decode([Site].self, from: Data(contentsOf: sitesFile))
    }

    public func save(_ sites: [Site]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sites).write(to: sitesFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sitesFile.path)
    }
}
