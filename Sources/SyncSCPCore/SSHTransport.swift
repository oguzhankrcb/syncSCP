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

    /// SFTP uses the server's `sftp` subsystem unless Advanced settings name an SFTP server
    /// command (for example `sudo /usr/lib/openssh/sftp-server`), which runs as a remote command.
    public func arguments() throws -> [String] {
        let server = site.settings.sftpServer.trimmingCharacters(in: .whitespaces)
        return try baseArguments() + (server.isEmpty ? ["-s", "--", site.host, "sftp"] : ["--", site.host, server])
    }

    /// Host keys behind a proxy or tunnel cannot be read with ssh-keyscan. OpenSSH records the
    /// presented key in a throwaway file instead (no authentication is attempted); the caller
    /// still shows it to the user and only an approved key enters the real known_hosts.
    public func hostKeyDiscoveryArguments(temporaryKnownHosts: String) throws -> [String] {
        ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=" + SSHOptions.configQuoted(temporaryKnownHosts),
         "-o", "HashKnownHosts=no", "-o", "BatchMode=yes", "-o", "PreferredAuthentications=none,publickey", "-o", "IdentityAgent=none",
         "-o", "IdentityFile=/dev/null", "-o", "IdentitiesOnly=yes", "-o", "ConnectionAttempts=1"]
            + (try baseArguments()).filter { $0 != "-i" && $0 != (site.privateKey as NSString).expandingTildeInPath }
            + ["--", site.host, "exit"]
    }
    /// The bastion of an SSH tunnel as a site of its own, so its key is verified first.
    public var tunnelSite: Site? {
        let settings = site.settings
        guard settings.tunnel else { return nil }
        var inner = settings; inner.tunnel = false
        return Site(host: settings.tunnelHost, port: settings.tunnelPort, username: settings.tunnelUsername.isEmpty ? site.username : settings.tunnelUsername,
                    privateKey: settings.tunnelPrivateKey, transferProtocol: .sftp, settings: inner)
    }

    /// `interactive` is the terminal window: a remote pty, and OpenSSH prompts on the terminal itself.
    func baseArguments(interactive: Bool = false) throws -> [String] {
        try site.validate()
        // OpenSSH parses -o values as config syntax even when passed as one argv element.
        var args = ["-F", "/dev/null", interactive ? "-t" : "-T", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(SSHOptions.configQuoted(knownHostsFile))",
                    "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ClearAllForwardings=yes",
                    "-o", "PermitLocalCommand=no", "-o", "NumberOfPasswordPrompts=\(interactive ? 3 : 1)", "-p", String(site.port), "-l", site.username]
        args += try SSHOptions.arguments(site.settings, host: site.host, knownHostsFile: knownHostsFile)
        if !site.privateKey.isEmpty { args += ["-i", (site.privateKey as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if credentialID == nil && !interactive { args += ["-o", "BatchMode=yes"] }
        return args
    }

    /// The askpass variables for this configuration (empty without a credential).
    public var environment: [String: String] {
        guard let executable = askpassExecutable, let id = credentialID else { return [:] }
        return ["SSH_ASKPASS": executable, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "syncscp:0", "SYNCSCP_ASKPASS_ID": id]
    }
}

/// Maps WinSCP's Advanced Site Settings onto OpenSSH options. Settings with no OpenSSH
/// equivalent are not mapped and are disabled in the UI; unsupported stored values fail closed.
public enum SSHOptions {
    static func configQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// One POSIX shell word inside ProxyCommand; '%' is doubled so OpenSSH does not expand it.
    static func shellWord(_ value: String) throws -> String { try SCPShell.quote(value).replacingOccurrences(of: "%", with: "%%") }

    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }
    /// The proxy applies unless the target is local and "Consider proxying local host connections" is off.
    public static func usesProxy(_ settings: SiteSettings, host: String) -> Bool {
        settings.proxyMethod != .none && (settings.proxyLocalhost || !isLocal(host))
    }

    static func arguments(_ settings: SiteSettings, host: String, knownHostsFile: String) throws -> [String] {
        var options: [String] = []
        func set(_ name: String, _ value: String) { options += ["-o", "\(name)=\(value)"] }
        set("ConnectTimeout", String(settings.timeoutSeconds))
        switch settings.keepalive {
        case .off: set("ServerAliveInterval", "0")
        case .nullPacket: set("ServerAliveInterval", String(settings.keepaliveSeconds)); set("ServerAliveCountMax", "2")
        case .dummyCommand: throw ClientError.unsupported("Keepalives by dummy protocol commands are not implemented yet. Choose null SSH packets or Off.")
        }
        set("AddressFamily", settings.addressFamily == .ipv4 ? "inet" : settings.addressFamily == .ipv6 ? "inet6" : "any")
        set("Compression", settings.compression ? "yes" : "no")
        // Only an edited policy overrides OpenSSH's own (security-maintained) defaults.
        // OpenSSH cannot warn mid-handshake, so groups below the warning line are not offered.
        if settings.ciphers != CipherGroup.defaultOrder {
            let names = settings.ciphers.prefix { $0 != .warn }.flatMap(\.openSSHNames)
            guard !names.isEmpty else { throw ClientError.invalid("Keep at least one available cipher above the warning line.") }
            set("Ciphers", names.joined(separator: ","))
        }
        if settings.kex != KexGroup.defaultOrder {
            let names = settings.kex.prefix { $0 != .warn }.flatMap(\.openSSHNames)
            guard !names.isEmpty else { throw ClientError.invalid("Keep at least one available key exchange algorithm above the warning line.") }
            set("KexAlgorithms", names.joined(separator: ","))
        }
        let data = SiteSettings.dataLimit(settings.rekeyData) ?? 0
        set("RekeyLimit", (data == 0 ? "default" : String(data)) + " " + (settings.rekeyMinutes == 0 ? "none" : "\(settings.rekeyMinutes * 60)s"))
        if !settings.tryAgent { set("IdentityAgent", "none") }
        set("KbdInteractiveAuthentication", settings.keyboardInteractive ? "yes" : "no")
        set("ForwardAgent", settings.agentForwarding ? "yes" : "no")
        set("GSSAPIAuthentication", settings.gssapiAuthentication ? "yes" : "no")
        set("GSSAPIDelegateCredentials", settings.gssapiDelegation ? "yes" : "no")
        if !settings.certificateFile.isEmpty { set("CertificateFile", configQuoted((settings.certificateFile as NSString).expandingTildeInPath)) }
        if let command = try proxyCommand(settings, host: host, knownHostsFile: knownHostsFile) { set("ProxyCommand", command) }
        return options
    }

    /// The tunnel is a nested `ssh -W`, verified against the same application known_hosts
    /// file; it may itself use the configured proxy. Otherwise the proxy is reached with nc.
    static func proxyCommand(_ settings: SiteSettings, host: String, knownHostsFile: String) throws -> String? {
        if settings.tunnel {
            var words = ["/usr/bin/ssh", "-F", "/dev/null", "-T", "-o", "StrictHostKeyChecking=yes",
                         "-o", "UserKnownHostsFile=" + configQuoted(knownHostsFile), "-o", "GlobalKnownHostsFile=/dev/null",
                         "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                         "-o", "ConnectTimeout=\(settings.timeoutSeconds)", "-p", String(settings.tunnelPort)]
            if !settings.tunnelUsername.isEmpty { words += ["-l", settings.tunnelUsername] }
            if !settings.tunnelPrivateKey.isEmpty { words += ["-i", (settings.tunnelPrivateKey as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
            if let proxy = try directProxy(settings, host: settings.tunnelHost) { words += ["-o", "ProxyCommand=" + proxy] }
            words += ["-W", "%h:%p", "--", settings.tunnelHost]
            return try words.enumerated().map { index, word in
                // %h:%p must stay expandable; everything else is literal.
                word == "%h:%p" ? word : try shellWord(word)
            }.joined(separator: " ")
        }
        return try directProxy(settings, host: host)
    }

    private static func directProxy(_ settings: SiteSettings, host: String) throws -> String? {
        guard usesProxy(settings, host: host) else { return nil }
        switch settings.proxyMethod {
        case .none: return nil
        case .socks4, .socks5, .http:
            guard settings.proxyUsername.isEmpty else { throw ClientError.unsupported("Authenticated proxies are not supported for SSH yet. Leave the proxy user name empty.") }
            let kind = settings.proxyMethod == .socks4 ? "4" : settings.proxyMethod == .socks5 ? "5" : "connect"
            let proxy = settings.proxyHost.contains(":") ? "[\(settings.proxyHost)]:\(settings.proxyPort)" : "\(settings.proxyHost):\(settings.proxyPort)"
            return try "/usr/bin/nc -X \(kind) -x \(shellWord(proxy)) %h %p"
        case .local:
            // WinSCP's %host/%port become OpenSSH's own tokens; the command is the user's own.
            let command = settings.proxyLocalCommand.replacingOccurrences(of: "%host", with: "%h").replacingOccurrences(of: "%port", with: "%p")
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw ClientError.invalid("Enter the local proxy command.") }
            return command
        case .telnet: throw ClientError.unsupported("Telnet proxies are not implemented yet.")
        }
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

    var processIdentifier: Int32 { process.processIdentifier }

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
