// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; data.append(value); if data.count > 32768 { data = data.suffix(32768) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct SSHConfiguration: Sendable {
    public let site: Site
    public let knownHostsFile: String
    public let askpassExecutable: String?
    public let credentialID: String?

    public init(site: Site, knownHostsFile: String, askpassExecutable: String? = nil, credentialID: String? = nil) {
        self.site = site; self.knownHostsFile = knownHostsFile
        self.askpassExecutable = askpassExecutable; self.credentialID = credentialID
    }

    public func arguments() throws -> [String] {
        try baseArguments() + ["-s", "--", site.host, "sftp"]
    }

    func baseArguments() throws -> [String] {
        try site.validate()
        // OpenSSH parses -o values as config syntax even when passed as one argv element.
        let quotedKnownHosts = "\"" + knownHostsFile.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        var args = ["-F", "/dev/null", "-T", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(quotedKnownHosts)",
                    "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                    "-o", "PermitLocalCommand=no", "-o", "NumberOfPasswordPrompts=1", "-p", String(site.port), "-l", site.username]
        if !site.privateKey.isEmpty { args += ["-i", (site.privateKey as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if credentialID == nil { args += ["-o", "BatchMode=yes"] }
        return args
    }

    var environment: [String: String] {
        guard let executable = askpassExecutable, let id = credentialID else { return [:] }
        return ["SSH_ASKPASS": executable, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "winscp:0", "WINSCP_ASKPASS_ID": id]
    }
}

/// Owns one OpenSSH process. Protocol I/O is serialized by SFTPClient.
final class SSHTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let errorBuffer = ErrorBuffer()
    private var closed = false

    init(executable: String, arguments: [String], environment: [String: String] = [:]) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let buffer = errorBuffer
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        do { try process.run() } catch { errors.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }; closed = true
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func send(_ data: Data) throws {
        guard !closed else { throw ClientError.connection("The SSH session is closed.") }
        var packet = PacketWriter(); packet.uint32(UInt32(data.count)); packet.data.append(data)
        do { try input.fileHandleForWriting.write(contentsOf: packet.data) }
        catch { throw connectionError() }
    }

    func receive() throws -> Data {
        // A stalled or malicious server must not leave a worker blocked forever.
        let child = process
        let timeout = DispatchWorkItem { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
        defer { timeout.cancel() }
        var header = PacketReader(data: try readExactly(4))
        let size = try header.uint32()
        guard size > 0, size <= 16 * 1024 * 1024 else { throw ClientError.protocolError("Invalid SFTP packet size: \(size).") }
        return try readExactly(Int(size))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let part: Data
            do { part = try output.fileHandleForReading.read(upToCount: count - data.count) ?? Data() }
            catch { throw connectionError() }
            guard !part.isEmpty else { throw connectionError() }
            data.append(part)
        }
        return data
    }

    private func connectionError() -> ClientError {
        let detail = errorBuffer.text
        return .connection(detail.isEmpty ? "SSH closed the connection or did not respond in time. Check the server, host key, and authentication settings." : detail)
    }
}
