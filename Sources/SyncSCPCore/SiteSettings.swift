// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum TriState: String, Codable, CaseIterable, Sendable { case auto, on, off }
public enum EOLType: String, Codable, CaseIterable, Sendable { case lf, crlf }
public enum DSTMode: String, Codable, CaseIterable, Sendable { case unix, win }
public enum KeepaliveMode: String, Codable, CaseIterable, Sendable { case off, nullPacket, dummyCommand }
public enum AddressFamily: String, Codable, CaseIterable, Sendable { case auto, ipv4, ipv6 }
public enum ProxyMethod: String, Codable, CaseIterable, Sendable { case none, socks4, socks5, http, telnet, local }
public enum TLSVersion: String, Codable, CaseIterable, Comparable, Sendable {
    case tls10, tls11, tls12, tls13
    public var title: String { switch self { case .tls10: return "TLS 1.0"; case .tls11: return "TLS 1.1"; case .tls12: return "TLS 1.2"; case .tls13: return "TLS 1.3" } }
    public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
}

/// WinSCP's cipher selection policy groups. `warn` is the "warn below here" divider.
public enum CipherGroup: String, Codable, CaseIterable, Sendable {
    case aes, chacha20, aesGCM, tripleDES, warn, blowfish, arcfour, des
    public static let defaultOrder: [CipherGroup] = [.aes, .chacha20, .aesGCM, .tripleDES, .warn, .blowfish, .arcfour, .des]
    public var title: String {
        switch self {
        case .aes: return "AES (SSH-2 only)"; case .chacha20: return "ChaCha20 (SSH-2 only)"; case .aesGCM: return "AES-GCM (SSH-2 only)"
        case .tripleDES: return "Triple-DES"; case .warn: return "— warn below here —"; case .blowfish: return "Blowfish"
        case .arcfour: return "Arcfour (SSH-2 only)"; case .des: return "DES"
        }
    }
    /// OpenSSH names; empty when macOS's OpenSSH no longer implements the group.
    public var openSSHNames: [String] {
        switch self {
        case .aes: return ["aes256-ctr", "aes192-ctr", "aes128-ctr", "aes256-cbc", "aes192-cbc", "aes128-cbc"]
        case .chacha20: return ["chacha20-poly1305@openssh.com"]
        case .aesGCM: return ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"]
        case .tripleDES: return ["3des-cbc"]
        case .warn, .blowfish, .arcfour, .des: return []
        }
    }
}

/// WinSCP's key exchange policy groups.
public enum KexGroup: String, Codable, CaseIterable, Sendable {
    case mlkem, ntru, ecdh, dhGEX, dhGroup18, dhGroup17, dhGroup16, dhGroup15, dhGroup14, rsa, warn, dhGroup1
    public static let defaultOrder: [KexGroup] = [.mlkem, .ntru, .ecdh, .dhGEX, .dhGroup18, .dhGroup17, .dhGroup16, .dhGroup15, .dhGroup14, .rsa, .warn, .dhGroup1]
    public var title: String {
        switch self {
        case .mlkem: return "ML-KEM / Curve25519 hybrid"; case .ntru: return "NTRU Prime / Curve25519 hybrid"
        case .ecdh: return "ECDH (Curve25519 and NIST)"; case .dhGEX: return "Diffie-Hellman group exchange"
        case .dhGroup18: return "Diffie-Hellman group 18"; case .dhGroup17: return "Diffie-Hellman group 17"
        case .dhGroup16: return "Diffie-Hellman group 16"; case .dhGroup15: return "Diffie-Hellman group 15"
        case .dhGroup14: return "Diffie-Hellman group 14"; case .rsa: return "RSA-based key exchange"
        case .warn: return "— warn below here —"; case .dhGroup1: return "Diffie-Hellman group 1"
        }
    }
    public var openSSHNames: [String] {
        switch self {
        case .mlkem: return ["mlkem768x25519-sha256"]
        case .ntru: return ["sntrup761x25519-sha512", "sntrup761x25519-sha512@openssh.com"]
        case .ecdh: return ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521"]
        case .dhGEX: return ["diffie-hellman-group-exchange-sha256", "diffie-hellman-group-exchange-sha1"]
        case .dhGroup18: return ["diffie-hellman-group18-sha512"]
        case .dhGroup16: return ["diffie-hellman-group16-sha512"]
        case .dhGroup14: return ["diffie-hellman-group14-sha256", "diffie-hellman-group14-sha1"]
        case .dhGroup1: return ["diffie-hellman-group1-sha1"]
        case .dhGroup17, .dhGroup15, .rsa, .warn: return []
        }
    }
}

/// Every page of WinSCP's Advanced Site Settings. Fields the macOS port cannot or does not
/// yet apply are still stored so the dialog round-trips them; the UI marks their status.
/// Passwords and keys are never stored here.
public struct SiteSettings: Codable, Equatable, Sendable {
    // Environment
    public var eol = EOLType.lf
    public var utf8 = TriState.auto
    public var timeOffsetMinutes = 0
    public var timeOffsetAuto = true
    public var trimVMSVersions = false
    public var dstMode = DSTMode.unix
    // Directories
    public var rememberLastDirectory = false
    public var synchronizeBrowsing = false
    public var cacheDirectories = true
    public var cacheDirectoryChanges = true
    public var permanentCache = false
    public var resolveSymlinks = true
    public var followDirectorySymlinks = false
    // Recycle bin
    public var deleteToRecycleBin = false
    public var overwrittenToRecycleBin = false
    public var recycleBinPath = "/tmp"
    // Encryption
    public var encryptFiles = false
    // SFTP
    public var sftpServer = ""
    public var sftpMaxVersion = 3
    public var canonicalizePaths = TriState.auto
    public var allowSCPFallback = false
    public var usePosixRename = true
    public var sftpBugSymlink = TriState.auto
    public var sftpBugSignedTimestamps = TriState.auto
    // SCP/Shell
    public var shell = ""
    public var returnCodeVariable = ""
    public var listingCommand = "ls -la"
    public var ignoreLsWarnings = true
    public var scpFullTimestamp = true
    public var lookupUserGroups = TriState.auto
    public var clearAliases = true
    public var clearNationalVariables = true
    public var scp1Compatibility = false
    // FTP
    public var ftpPostLoginCommands = ""
    public var ftpListAll = TriState.auto
    public var ftpUseMLSD = TriState.auto
    public var ftpForcePassiveIP = TriState.auto
    public var ftpAccount = ""
    public var ftpUseHost = TriState.auto
    public var vmsAllRevisions = false
    // S3
    public var s3RequesterPays = false
    public var s3RoleARN = ""
    // WebDAV
    public var webdavLiberalEscaping = false
    public var webdavCrossDomainRedirects = false
    // Connection
    public var passiveMode = true
    public var optimizeBufferSize = true
    public var timeoutSeconds = 15
    public var keepalive = KeepaliveMode.nullPacket
    public var keepaliveSeconds = 15
    public var addressFamily = AddressFamily.auto
    // Proxy
    public var proxyMethod = ProxyMethod.none
    public var proxyHost = ""
    public var proxyPort = 1080
    public var proxyUsername = ""
    public var proxyTelnetCommand = "connect %host %port\\n"
    public var proxyLocalCommand = ""
    public var proxyDNS = TriState.auto
    public var proxyLocalhost = false
    // Tunnel
    public var tunnel = false
    public var tunnelHost = ""
    public var tunnelPort = 22
    public var tunnelUsername = ""
    public var tunnelPrivateKey = ""
    public var tunnelLocalPort = 0
    // TLS/SSL
    public var tlsMinimum = TLSVersion.tls12
    public var tlsMaximum = TLSVersion.tls13
    public var tlsSessionReuse = true
    public var tlsClientCertificate = ""
    // SSH
    public var compression = false
    public var ciphers = CipherGroup.defaultOrder
    public var legacySingleDES = false
    // Key exchange
    public var kex = KexGroup.defaultOrder
    public var gssapiKeyExchange = false
    public var rekeyMinutes = 60
    public var rekeyData = "1G"
    // Authentication
    public var bypassAuthentication = false
    public var tryAgent = true
    public var keyboardInteractive = true
    public var keyboardInteractiveFirstPrompt = true
    public var agentForwarding = false
    public var certificateFile = ""
    public var gssapiAuthentication = false
    public var gssapiDelegation = false
    // Bugs (PuTTY workarounds; no OpenSSH equivalent)
    public var bugHMAC2 = TriState.auto
    public var bugDeriveKey2 = TriState.auto
    public var bugRSAPad2 = TriState.auto
    public var bugPKSessionID2 = TriState.auto
    public var bugRekey2 = TriState.auto
    public var bugMaxPacket2 = TriState.auto
    public var bugIgnore2 = TriState.auto
    public var bugWinAdj = TriState.auto
    // Note and color
    public var note = ""
    public var color = ""

    public init() {}

    /// Lenient decoding: missing or unknown values keep their defaults, so older
    /// and newer site files both load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ target: inout T) { if let value = try? c.decodeIfPresent(T.self, forKey: key) { target = value } }
        load(.eol, &eol)
        load(.utf8, &utf8)
        load(.timeOffsetMinutes, &timeOffsetMinutes)
        load(.timeOffsetAuto, &timeOffsetAuto)
        load(.trimVMSVersions, &trimVMSVersions)
        load(.dstMode, &dstMode)
        load(.rememberLastDirectory, &rememberLastDirectory)
        load(.synchronizeBrowsing, &synchronizeBrowsing)
        load(.cacheDirectories, &cacheDirectories)
        load(.cacheDirectoryChanges, &cacheDirectoryChanges)
        load(.permanentCache, &permanentCache)
        load(.resolveSymlinks, &resolveSymlinks)
        load(.followDirectorySymlinks, &followDirectorySymlinks)
        load(.deleteToRecycleBin, &deleteToRecycleBin)
        load(.overwrittenToRecycleBin, &overwrittenToRecycleBin)
        load(.recycleBinPath, &recycleBinPath)
        load(.encryptFiles, &encryptFiles)
        load(.sftpServer, &sftpServer)
        load(.sftpMaxVersion, &sftpMaxVersion)
        load(.canonicalizePaths, &canonicalizePaths)
        load(.allowSCPFallback, &allowSCPFallback)
        load(.usePosixRename, &usePosixRename)
        load(.sftpBugSymlink, &sftpBugSymlink)
        load(.sftpBugSignedTimestamps, &sftpBugSignedTimestamps)
        load(.shell, &shell)
        load(.returnCodeVariable, &returnCodeVariable)
        load(.listingCommand, &listingCommand)
        load(.ignoreLsWarnings, &ignoreLsWarnings)
        load(.scpFullTimestamp, &scpFullTimestamp)
        load(.lookupUserGroups, &lookupUserGroups)
        load(.clearAliases, &clearAliases)
        load(.clearNationalVariables, &clearNationalVariables)
        load(.scp1Compatibility, &scp1Compatibility)
        load(.ftpPostLoginCommands, &ftpPostLoginCommands)
        load(.ftpListAll, &ftpListAll)
        load(.ftpUseMLSD, &ftpUseMLSD)
        load(.ftpForcePassiveIP, &ftpForcePassiveIP)
        load(.ftpAccount, &ftpAccount)
        load(.ftpUseHost, &ftpUseHost)
        load(.vmsAllRevisions, &vmsAllRevisions)
        load(.s3RequesterPays, &s3RequesterPays)
        load(.s3RoleARN, &s3RoleARN)
        load(.webdavLiberalEscaping, &webdavLiberalEscaping)
        load(.webdavCrossDomainRedirects, &webdavCrossDomainRedirects)
        load(.passiveMode, &passiveMode)
        load(.optimizeBufferSize, &optimizeBufferSize)
        load(.timeoutSeconds, &timeoutSeconds)
        load(.keepalive, &keepalive)
        load(.keepaliveSeconds, &keepaliveSeconds)
        load(.addressFamily, &addressFamily)
        load(.proxyMethod, &proxyMethod)
        load(.proxyHost, &proxyHost)
        load(.proxyPort, &proxyPort)
        load(.proxyUsername, &proxyUsername)
        load(.proxyTelnetCommand, &proxyTelnetCommand)
        load(.proxyLocalCommand, &proxyLocalCommand)
        load(.proxyDNS, &proxyDNS)
        load(.proxyLocalhost, &proxyLocalhost)
        load(.tunnel, &tunnel)
        load(.tunnelHost, &tunnelHost)
        load(.tunnelPort, &tunnelPort)
        load(.tunnelUsername, &tunnelUsername)
        load(.tunnelPrivateKey, &tunnelPrivateKey)
        load(.tunnelLocalPort, &tunnelLocalPort)
        load(.tlsMinimum, &tlsMinimum)
        load(.tlsMaximum, &tlsMaximum)
        load(.tlsSessionReuse, &tlsSessionReuse)
        load(.tlsClientCertificate, &tlsClientCertificate)
        load(.compression, &compression)
        load(.ciphers, &ciphers)
        load(.legacySingleDES, &legacySingleDES)
        load(.kex, &kex)
        load(.gssapiKeyExchange, &gssapiKeyExchange)
        load(.rekeyMinutes, &rekeyMinutes)
        load(.rekeyData, &rekeyData)
        load(.bypassAuthentication, &bypassAuthentication)
        load(.tryAgent, &tryAgent)
        load(.keyboardInteractive, &keyboardInteractive)
        load(.keyboardInteractiveFirstPrompt, &keyboardInteractiveFirstPrompt)
        load(.agentForwarding, &agentForwarding)
        load(.certificateFile, &certificateFile)
        load(.gssapiAuthentication, &gssapiAuthentication)
        load(.gssapiDelegation, &gssapiDelegation)
        load(.bugHMAC2, &bugHMAC2)
        load(.bugDeriveKey2, &bugDeriveKey2)
        load(.bugRSAPad2, &bugRSAPad2)
        load(.bugPKSessionID2, &bugPKSessionID2)
        load(.bugRekey2, &bugRekey2)
        load(.bugMaxPacket2, &bugMaxPacket2)
        load(.bugIgnore2, &bugIgnore2)
        load(.bugWinAdj, &bugWinAdj)
        load(.note, &note)
        load(.color, &color)
    }

    public func validate() throws {
        func line(_ value: String, _ name: String) throws {
            guard value.rangeOfCharacter(from: CharacterSet.newlines.union(CharacterSet(charactersIn: "\0"))) == nil else {
                throw ClientError.invalid("\(name) cannot contain line breaks.")
            }
        }
        try line(shell, "The shell command"); try line(sftpServer, "The SFTP server command"); try line(proxyLocalCommand, "The local proxy command")
        try line(certificateFile, "The certificate file"); try line(tunnelHost, "The tunnel host"); try line(proxyHost, "The proxy host")
        guard (1...3600).contains(timeoutSeconds) else { throw ClientError.invalid("The server response timeout must be between 1 and 3600 seconds.") }
        guard (1...3600).contains(keepaliveSeconds) else { throw ClientError.invalid("Seconds between keepalives must be between 1 and 3600.") }
        guard (0...100_000).contains(rekeyMinutes) else { throw ClientError.invalid("Enter a rekey time between 0 and 100000 minutes.") }
        guard Self.dataLimit(rekeyData) != nil else { throw ClientError.invalid("Enter the rekey data limit as a number with an optional K, M or G suffix.") }
        guard tlsMinimum <= tlsMaximum else { throw ClientError.invalid("The minimum TLS version cannot be above the maximum.") }
        if proxyMethod != .none {
            guard proxyMethod == .local || !proxyHost.isEmpty else { throw ClientError.invalid("Enter the proxy host name.") }
            guard (1...65535).contains(proxyPort) else { throw ClientError.invalid("The proxy port must be between 1 and 65535.") }
        }
        if tunnel {
            guard !tunnelHost.isEmpty, !tunnelHost.hasPrefix("-"), tunnelHost.rangeOfCharacter(from: .whitespaces) == nil else { throw ClientError.invalid("Enter the tunnel host name.") }
            guard (1...65535).contains(tunnelPort) else { throw ClientError.invalid("The tunnel port must be between 1 and 65535.") }
            guard !tunnelUsername.contains("@"), tunnelUsername.rangeOfCharacter(from: .whitespaces) == nil else { throw ClientError.invalid("Enter a valid tunnel user name.") }
        }
        guard ciphers.contains(where: { !$0.openSSHNames.isEmpty && isAboveWarning($0, in: ciphers) }) else { throw ClientError.invalid("Keep at least one available cipher above the warning line.") }
        guard kex.contains(where: { !$0.openSSHNames.isEmpty && isAboveWarning($0, in: kex) }) else { throw ClientError.invalid("Keep at least one available key exchange algorithm above the warning line.") }
    }

    /// "1G", "512M", "0" → bytes; nil when malformed.
    public static func dataLimit(_ value: String) -> UInt64? {
        let text = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = text.last else { return nil }
        let multiplier: UInt64 = last == "K" ? 1 << 10 : last == "M" ? 1 << 20 : last == "G" ? 1 << 30 : 1
        let digits = multiplier == 1 ? text : String(text.dropLast())
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(digits), number <= UInt64.max / multiplier else { return nil }
        return number * multiplier
    }
}

func isAboveWarning<T: Equatable>(_ item: T, in order: [T], warn: T) -> Bool {
    guard let index = order.firstIndex(of: item) else { return false }
    return order.firstIndex(of: warn).map { index < $0 } ?? true
}
private func isAboveWarning(_ item: CipherGroup, in order: [CipherGroup]) -> Bool { isAboveWarning(item, in: order, warn: .warn) }
private func isAboveWarning(_ item: KexGroup, in order: [KexGroup]) -> Bool { isAboveWarning(item, in: order, warn: .warn) }
