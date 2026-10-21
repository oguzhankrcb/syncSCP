// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import SyncSCPCore

struct HostIdentity: Sendable {
    var host: String
    var algorithm: String
    var fingerprint: String
    var knownHostsLine: String
}

enum HostTrust {
    static func lookupKey(_ site: Site) -> String { site.port == 22 ? site.host : "[\(site.host)]:\(site.port)" }

    static func isKnown(_ site: Site, file: URL) async throws -> Bool {
        let result = try await run("/usr/bin/ssh-keygen", ["-F", lookupKey(site), "-f", file.path])
        guard result.status == 0 || result.status == 1 else { throw ClientError.connection(result.error) }
        return result.status == 0 && !result.output.isEmpty
    }

    static func scan(_ site: Site, knownHostsFile: URL) async throws -> HostIdentity {
        try site.validate()
        guard !site.settings.tunnel, !SSHOptions.usesProxy(site.settings, host: site.host) else {
            return try await scanThroughSSH(site, knownHostsFile: knownHostsFile)
        }
        let result = try await run("/usr/bin/ssh-keyscan", ["-T", "5", "-p", String(site.port), "-t", "ed25519,ecdsa,rsa", site.host])
        let lines = result.output.split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard let identity = identities(lines, site: site).first(where: { $0.algorithm == "ssh-ed25519" }) ?? identities(lines, site: site).first else {
            throw ClientError.connection("Could not read the SSH host key. \(result.error)")
        }
        return identity
    }

    /// Through a proxy or tunnel, OpenSSH itself records the presented key in a temporary file.
    private static func scanThroughSSH(_ site: Site, knownHostsFile: URL) async throws -> HostIdentity {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-hostkey-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("known_hosts")
        let configuration = SSHConfiguration(site: site, knownHostsFile: knownHostsFile.path)
        let result = try await run("/usr/bin/ssh", configuration.hostKeyDiscoveryArguments(temporaryKnownHosts: file.path))
        let lines = ((try? String(contentsOf: file)) ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard let identity = identities(lines, site: site).first else {
            throw ClientError.connection("Could not read the SSH host key through the proxy or tunnel. \(result.error)")
        }
        return identity
    }

    private static func identities(_ lines: [Substring], site: Site) -> [HostIdentity] {
        let supported = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"]
        return lines.compactMap { line -> HostIdentity? in
            let fields = line.split(separator: " ")
            guard fields.count == 3, supported.contains(String(fields[1])), let bytes = Data(base64Encoded: String(fields[2])) else { return nil }
            let fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return HostIdentity(host: lookupKey(site), algorithm: String(fields[1]), fingerprint: fingerprint,
                                knownHostsLine: "\(lookupKey(site)) \(fields[1]) \(fields[2])\n")
        }
    }

    static func trust(_ identity: HostIdentity, file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(identity.knownHostsLine.utf8)); try handle.synchronize()
    }

    private struct ToolResult: Sendable { var status: Int32; var output: String; var error: String }

    private static func run(_ path: String, _ arguments: [String]) async throws -> ToolResult {
        try await Task.detached {
            let process = Process(); let output = Pipe(); let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
            let buffer = LockedData()
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
            }
            try process.run()
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
            defer { timer.cancel(); errors.fileHandleForReading.readabilityHandler = nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), error: buffer.text)
        }.value
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; if data.count < 32768 { data.append(value) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
