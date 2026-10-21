// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SiteStore: Sendable {
    public let directory: URL
    public var knownHostsFile: URL { directory.appendingPathComponent("known_hosts") }
    private var sitesFile: URL { directory.appendingPathComponent("sites.json") }

    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WinSCPMac", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: knownHostsFile.path) {
            guard FileManager.default.createFile(atPath: knownHostsFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw ClientError.invalid("Cannot create the host key store.") }
        }
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
