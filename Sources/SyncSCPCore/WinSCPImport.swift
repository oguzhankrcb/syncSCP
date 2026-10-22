// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// One site found in a WinSCP configuration, ready to be saved, with what could not be carried over.
public struct ImportedSite: Identifiable, Sendable {
    public var id: UUID { site.id }
    public var site: Site
    public var warnings: [String]
    /// A key file found on this Mac (through a Wine prefix) that is converted or linked on import.
    public var keySource: String?
    public var tunnelKeySource: String?
    /// The saved password, decoded only in memory; the app stores it in Keychain if the user asks.
    public var password: String?
}

/// A host key the user trusted in WinSCP, converted from PuTTY's format to an OpenSSH known_hosts line.
public struct ImportedHostKey: Identifiable, Hashable, Sendable {
    public var id: String { knownHostsLine }
    public let host: String
    public let port: Int
    public let algorithm: String
    public let fingerprint: String
    public let knownHostsLine: String
}

public struct WinSCPImportResult: Sendable {
    public var sites: [ImportedSite] = []
    public var hostKeys: [ImportedHostKey] = []
    /// Entries that were found but not imported, with the reason.
    public var skipped: [String] = []
}

/// Reads WinSCP's own storage: an exported `WinSCP.ini` (Tools ▸ Export/Backup Configuration),
/// a registry export of `HKEY_CURRENT_USER\Software\Martin Prikryl\WinSCP 2` (`reg export`),
/// or the `user.reg` of a Wine/CrossOver prefix where WinSCP runs on this Mac.
/// Key names and setting values follow upstream `TSessionData::DoLoad`. Passwords and other
/// secrets are never imported.
public enum WinSCPImport {
    enum Raw: Equatable { case string(String), integer(Int), binary(Data) }
    typealias Storage = [String: [String: Raw]]

    /// `source` is the file's location; inside a Wine/CrossOver/Whisky prefix, Windows paths
    /// such as `C:\\Users\\me\\key.ppk` are resolved through the prefix's `dosdevices`.
    public static func parse(_ data: Data, source: URL? = nil) throws -> WinSCPImportResult {
        let prefix = source.flatMap(winePrefix)
        guard data.count <= 64 * 1024 * 1024 else { throw ClientError.invalid("The WinSCP configuration file is larger than 64 MB.") }
        let text = try decode(data)
        let isRegistry = text.contains("Windows Registry Editor") || text.hasPrefix("REGEDIT4") || text.hasPrefix("WINE REGISTRY")
        let storage = isRegistry ? try registry(text) : ini(text)
        var result = WinSCPImportResult()
        let sessions = storage.keys.filter { $0.lowercased().hasPrefix("sessions\\") }.sorted()
        guard !sessions.isEmpty || storage.keys.contains(where: { $0.lowercased() == "sshhostkeys" }) else {
            throw ClientError.invalid("No WinSCP sites or host keys were found. Export the configuration from WinSCP (Tools ▸ Export/Backup Configuration) or with reg export.")
        }
        for section in sessions {
            let name = unmunge(String(section.dropFirst("Sessions\\".count)))
            guard name != "Default Settings" else { continue }
            let values = Values(raw: storage[section]!)
            if values.bool("IsWorkspace") == true { result.skipped.append("\(name): workspaces (saved tab sets) are not supported yet."); continue }
            if let link = values.string("Link"), !link.isEmpty { result.skipped.append("\(name): site shortcuts are not supported."); continue }
            do { result.sites.append(try site(named: name, values, prefix: prefix)) }
            catch { result.skipped.append("\(name): \(error.localizedDescription)") }
        }
        result.sites.sort { $0.site.name < $1.site.name }
        if let keys = storage.first(where: { $0.key.lowercased() == "sshhostkeys" })?.value {
            for (name, raw) in keys.sorted(by: { $0.key < $1.key }) {
                guard case .string(let value) = raw else { continue }
                do { result.hostKeys.append(try hostKey(name: name, value: unmunge(value))) }
                catch { result.skipped.append("Host key \(name): \(error.localizedDescription)") }
            }
        }
        return result
    }

    // MARK: Storage formats

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw ClientError.invalid("The WinSCP configuration file is not readable text.")
    }

    /// INI sections are storage paths below the WinSCP root (`Sessions\name`); every value is text.
    static func ini(_ text: String) -> Storage {
        var storage: Storage = [:], section: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast()); storage[section!, default: [:]] = storage[section!] ?? [:]
            } else if let section, !trimmed.hasPrefix(";"), let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%3D", with: "=")
                storage[section]![unmungeIniName(key)] = .string(String(trimmed[trimmed.index(after: equals)...]))
            }
        }
        return storage
    }

    /// `reg export` output: keys under `...\WinSCP 2\`, values as strings, dwords or hex.
    static func registry(_ text: String) throws -> Storage {
        var storage: Storage = [:], section: String?
        var lines: [String] = [], pending = ""
        // Only hex values wrap: a trailing backslash continues them on the next line.
        // (String values always end with their closing quote, even when they end in "\\".)
        for raw in text.split(whereSeparator: \.isNewline) {
            pending += raw.trimmingCharacters(in: .whitespaces)
            if pending.hasSuffix("\\"), pending.range(of: "=hex", options: .caseInsensitive) != nil { pending.removeLast(); continue }
            lines.append(pending); pending = ""
        }
        if !pending.isEmpty { lines.append(pending) }
        for line in lines {
            // Wine's user.reg doubles the backslashes and appends a timestamp after the key.
            if line.hasPrefix("["), let close = line.lastIndex(of: "]") {
                let key = String(line[line.index(after: line.startIndex)..<close]).replacingOccurrences(of: "\\\\", with: "\\")
                if let range = key.range(of: "\\WinSCP 2\\", options: .caseInsensitive) {
                    section = String(key[range.upperBound...]); storage[section!, default: [:]] = storage[section!] ?? [:]
                } else { section = nil }
                continue
            }
            guard let section, line.hasPrefix("\""), let (name, rest) = quoted(line), rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst()
            if value.hasPrefix("\""), let (string, _) = quoted(String(value)) { storage[section]![name] = .string(string) }
            else if value.lowercased().hasPrefix("dword:"), let number = UInt32(value.dropFirst(6), radix: 16) { storage[section]![name] = .integer(Int(Int32(bitPattern: number))) }
            else if value.lowercased().hasPrefix("hex:") {
                let bytes = value.dropFirst(4).split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                storage[section]![name] = .binary(Data(bytes))
            }
        }
        return storage
    }

    /// A .reg quoted token with `\\` and `\"` escapes; returns the text and what follows it.
    private static func quoted(_ line: String) -> (String, Substring)? {
        guard line.first == "\"" else { return nil }
        var result = "", escaped = false
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let character = line[index]
            if escaped, character == "x" {
                // Wine writes non-ASCII as \xNNNN.
                var digits = "", next = line.index(after: index)
                while next < line.endIndex, digits.count < 4, line[next].isHexDigit { digits.append(line[next]); next = line.index(after: next) }
                if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar); index = next; escaped = false; continue }
                result.append(character); escaped = false
            } else if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { return (result, line[line.index(after: index)...]) }
            else { result.append(character) }
            index = line.index(after: index)
        }
        return nil
    }

    /// PuTTY's `unescape_registry_key`: %XX bytes; an escaped UTF-8 BOM marks UTF-8 text.
    static func unmunge(_ value: String) -> String {
        var bytes: [UInt8] = [], scalars = Array(value.utf8), index = 0
        while index < scalars.count {
            if scalars[index] == 37, index + 2 < scalars.count, let byte = UInt8(String(bytes: scalars[index + 1...index + 2], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(byte); index += 3
            } else { bytes.append(scalars[index]); index += 1 }
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        return String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .windowsCP1252) ?? value
    }
    private static func unmungeIniName(_ value: String) -> String { value.hasPrefix("%EF%BB%BF") ? unmunge(value) : value }

    struct Values {
        let raw: [String: Raw]
        private func find(_ name: String) -> Raw? { raw[name] ?? raw.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        func exists(_ name: String) -> Bool { find(name) != nil }
        func string(_ name: String) -> String? {
            switch find(name) { case .string(let value): return unmunge(value); case .integer(let value): return String(value); default: return nil }
        }
        func int(_ name: String, names: [String] = []) -> Int? {
            switch find(name) {
            case .integer(let value): return value
            case .string(let value):
                let text = unmunge(value).trimmingCharacters(in: .whitespaces)
                if let number = Int(text) { return number }
                return names.firstIndex { $0.caseInsensitiveCompare(text) == .orderedSame }
            default: return nil
            }
        }
        func bool(_ name: String) -> Bool? {
            switch find(name) {
            case .integer(let value): return value != 0
            case .string(let value):
                switch unmunge(value).lowercased() { case "1", "true", "on", "yes": return true; case "0", "false", "off", "no": return false; default: return nil }
            default: return nil
            }
        }
        /// WinSCP's TAutoSwitch: asOn = 0, asOff = 1, asAuto = 2, or the names on/off/auto.
        func autoSwitch(_ name: String) -> TriState? {
            switch int(name, names: ["on", "off", "auto"]) { case 0: return .on; case 1: return .off; case 2: return .auto; default: return nil }
        }
        func double(_ name: String) -> Double? {
            switch find(name) {
            case .binary(let data) where data.count == 8: return Double(bitPattern: data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
            case .string(let value):
                let text = unmunge(value)
                if text.count == 16, let bits = UInt64(text, radix: 16) { return Double(bitPattern: UInt64(littleEndian: bits.byteSwapped)) }
                return Double(text)
            case .integer(let value): return Double(value)
            default: return nil
            }
        }
    }

    // MARK: Sites

    private static func isWindowsPath(_ path: String) -> Bool {
        path.contains("\\") || (path.count >= 2 && path.dropFirst().first == ":")
    }

    /// The Wine prefix (directory with `dosdevices`) that contains `url`, if any.
    static func winePrefix(_ url: URL) -> URL? {
        var directory = url.resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("dosdevices").path, isDirectory: &isDirectory), isDirectory.boolValue { return directory }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    /// `X:\\a\\b` → `<prefix>/dosdevices/x:/a/b` when that file exists on this Mac.
    static func resolve(_ path: String, prefix: URL?) -> String? {
        guard let prefix, path.count >= 3, path.dropFirst().first == ":", let drive = path.first, drive.isLetter else { return nil }
        let parts = path.dropFirst(3).split(separator: "\\").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var url = prefix.appendingPathComponent("dosdevices").appendingPathComponent(drive.lowercased() + ":")
        for part in parts { url.appendPathComponent(part) }
        let resolved = url.resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    /// WinSCP's reversible "simple" password encoding (upstream `DecryptPassword`, used when no
    /// master password is set): hex pairs, each byte `~(b ^ 0xA3)`; a 0xFF flag means the
    /// plaintext starts with `key` (user name + host name), which must match. Returns nil for
    /// anything that does not decode cleanly, such as master-password (AES) values.
    static func decodePassword(_ encoded: String, key: String) -> String? {
        var bytes: [UInt8] = []
        let digits = Array(encoded.uppercased().utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hex(digits[index]), let low = hex(digits[index + 1]) else { return nil }
            bytes.append(~((high << 4 | low) ^ 0xA3))
        }
        func hex(_ digit: UInt8) -> UInt8? {
            switch digit { case 48...57: return digit - 48; case 65...70: return digit - 55; default: return nil }
        }
        var position = 0
        func next() -> UInt8? { guard position < bytes.count else { return nil }; defer { position += 1 }; return bytes[position] }
        guard let flag = next() else { return nil }
        let length: UInt8
        if flag == 0xFF { guard next() != nil, let value = next() else { return nil }; length = value } else { length = flag }
        guard let shift = next() else { return nil }
        position += Int(shift)
        guard position + Int(length) <= bytes.count else { return nil }
        var plain = Array(bytes[position..<position + Int(length)])
        if flag == 0xFF {
            let prefix = Array(key.utf8)
            guard plain.starts(with: prefix) else { return nil }
            plain.removeFirst(prefix.count)
        }
        guard let text = String(bytes: plain, encoding: .utf8), !text.isEmpty, !text.contains(where: { $0.isASCII && $0.asciiValue! < 32 }) else { return nil }
        return text
    }

    static func site(named name: String, _ v: Values, prefix: URL? = nil) throws -> ImportedSite {
        var warnings: [String] = []
        var keySource: String?, tunnelKeySource: String?
        // TFSProtocol: 0 SCP only, 1 SFTP (SCP fallback), 2 SFTP only, 5 FTP, 6 WebDAV, 7 S3.
        let fs = v.int("FSProtocol") ?? 1
        let ftps = v.int("Ftps") ?? 0 // TFtps: none, implicit, explicit SSL, explicit TLS
        let kind: TransferProtocol
        switch fs {
        case 0: kind = .scp
        case 1, 2: kind = .sftp
        case 5: kind = ftps == 0 ? .ftp : ftps == 1 ? .ftpsImplicit : .ftpsExplicit
        case 6: kind = ftps == 0 ? .webdav : .webdavs
        case 7: kind = ftps == 0 ? .s3http : .s3
        default: throw ClientError.unsupported("protocol number \(fs) is unknown.")
        }
        var host = v.string("HostName") ?? "", user = v.string("UserName") ?? ""
        if let at = host.lastIndex(of: "@") {
            if user.isEmpty { user = String(host[..<at]) }
            host = String(host[host.index(after: at)...])
        }
        guard !host.isEmpty else { throw ClientError.invalid("no host name.") }
        var site = Site(name: name, host: host, port: v.int("PortNumber"), username: user.isEmpty ? (kind.usesS3 ? "" : NSUserName()) : user,
                        transferProtocol: kind)
        if user.isEmpty, kind.usesS3 { warnings.append("No access key ID was saved; enter it before logging in.") }

        if let remote = v.string("RemoteDirectory"), !remote.isEmpty { site.remotePath = remote }
        if let local = v.string("LocalDirectory"), !local.isEmpty {
            if let resolved = resolve(local, prefix: prefix) { site.localPath = resolved }
            else if isWindowsPath(local) { warnings.append("Local folder \(local) is a Windows path; your home folder is used instead.") }
            else { site.localPath = local }
        }
        if let key = v.string("PublicKeyFile"), !key.isEmpty {
            let file = key.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? key
            if let resolved = resolve(key, prefix: prefix) {
                keySource = resolved
                if resolved.lowercased().hasSuffix(".ppk") {
                    if let text = try? String(contentsOfFile: resolved, encoding: .utf8), PuTTYKey.isEncrypted(text) {
                        warnings.append("Private key \(file) is protected by a passphrase; enter it below to convert it (the converted key keeps the passphrase).")
                    } else {
                        warnings.append("Private key \(file) will be converted from PuTTY to OpenSSH format.")
                    }
                }
            } else if isWindowsPath(key) || key.lowercased().hasSuffix(".ppk") {
                warnings.append("Private key \(file) must be copied to this Mac\(key.lowercased().hasSuffix(".ppk") ? " and converted with Login ▸ Tools ▸ Convert PuTTY Key…" : ""), then chosen in Advanced ▸ Authentication.")
            } else if FileManager.default.fileExists(atPath: (key as NSString).expandingTildeInPath) { site.privateKey = key }
            else { warnings.append("Private key \(key) does not exist on this Mac.") }
        }
        // The stored key is UserName + HostName exactly as saved, before any user@host split.
        var password: String?
        if let plain = v.string("PasswordPlain"), !plain.isEmpty { password = plain }
        else if let encoded = v.string("Password"), !encoded.isEmpty {
            password = decodePassword(encoded, key: (v.string("UserName") ?? "") + (v.string("HostName") ?? ""))
            if password == nil { warnings.append("The saved password could not be read (it may be protected by a WinSCP master password); enter it at login.") }
        }
        if v.exists("S3SessionToken") { warnings.append("The S3 session token was not imported; enter it at login.") }
        if v.exists("ProxyPassword") || v.exists("ProxyPasswordEnc") { warnings.append("The proxy password was not imported.") }
        if v.exists("TunnelPassword") || v.exists("TunnelPasswordPlain") || v.exists("TunnelPassphrase") { warnings.append("The tunnel password or passphrase was not imported; use a key or the SSH agent for the tunnel.") }
        if v.exists("EncryptKey") || v.exists("EncryptKeyPlain") { warnings.append("The file encryption key was not imported.") }

        var s = site.settings
        // Environment
        if let eol = v.int("EOLType") { s.eol = eol == 1 ? .crlf : .lf }
        if let utf = v.int("Utf", names: ["on", "off", "auto"]) ?? v.int("SFTPUtfBug", names: ["on", "off", "auto"]) {
            // Stored with WinSCP's reversed mapping for "not UTF": on → UTF-8 on.
            s.utf8 = utf == 0 ? .on : utf == 1 ? .off : .auto
        }
        if let days = v.double("TimeDifference") { s.timeOffsetMinutes = Int((days * 1440).rounded()) }
        s.timeOffsetAuto = v.bool("TimeDifferenceAuto") ?? (s.timeOffsetMinutes == 0)
        s.trimVMSVersions = v.bool("TrimVMSVersions") ?? s.trimVMSVersions
        if let dst = v.int("ConsiderDST") { s.dstMode = dst == 0 ? .win : .unix } // dstmWin, dstmUnix, dstmKeep
        // Directories
        s.synchronizeBrowsing = v.bool("SynchronizeBrowsing") ?? s.synchronizeBrowsing
        s.rememberLastDirectory = v.bool("UpdateDirectories") ?? s.rememberLastDirectory
        s.cacheDirectories = v.bool("CacheDirectories") ?? s.cacheDirectories
        s.cacheDirectoryChanges = v.bool("CacheDirectoryChanges") ?? s.cacheDirectoryChanges
        s.permanentCache = v.bool("PreserveDirectoryChanges") ?? s.permanentCache
        s.resolveSymlinks = v.bool("ResolveSymlinks") ?? s.resolveSymlinks
        s.followDirectorySymlinks = v.bool("FollowDirectorySymlinks") ?? s.followDirectorySymlinks
        // Recycle bin
        s.deleteToRecycleBin = v.bool("DeleteToRecycleBin") ?? s.deleteToRecycleBin
        s.overwrittenToRecycleBin = v.bool("OverwrittenToRecycleBin") ?? s.overwrittenToRecycleBin
        s.recycleBinPath = v.string("RecycleBinPath") ?? s.recycleBinPath
        // SFTP
        s.sftpServer = v.string("SftpServer") ?? s.sftpServer
        if fs == 1 { s.allowSCPFallback = true }
        if let version = v.int("SFTPMaxVersion") {
            if version > 3 { warnings.append("Preferred SFTP version \(version) was lowered to 3, the only version this port speaks.") }
            s.sftpMaxVersion = 3
        }
        s.canonicalizePaths = v.autoSwitch("SFTPRealPath") ?? s.canonicalizePaths
        s.usePosixRename = v.bool("UsePosixRename") ?? s.usePosixRename
        s.sftpBugSymlink = v.autoSwitch("SFTPSymlinkBug") ?? s.sftpBugSymlink
        s.sftpBugSignedTimestamps = v.autoSwitch("SFTPSignedTSBug") ?? s.sftpBugSignedTimestamps
        // SCP/Shell
        s.shell = v.string("Shell") ?? s.shell
        s.returnCodeVariable = v.string("ReturnVar") ?? s.returnCodeVariable
        s.listingCommand = v.string("ListingCommand") ?? (v.bool("AliasGroupList") == true ? "ls -gla" : s.listingCommand)
        s.ignoreLsWarnings = v.bool("IgnoreLsWarnings") ?? s.ignoreLsWarnings
        if let full = v.autoSwitch("SCPLsFullTime") { s.scpFullTimestamp = full != .off }
        s.lookupUserGroups = v.autoSwitch("LookupUserGroups2") ?? s.lookupUserGroups
        s.clearAliases = v.bool("ClearAliases") ?? s.clearAliases
        s.clearNationalVariables = v.bool("UnsetNationalVars") ?? s.clearNationalVariables
        s.scp1Compatibility = v.bool("Scp1Compatibility") ?? s.scp1Compatibility
        // FTP
        s.ftpPostLoginCommands = v.string("PostLoginCommands") ?? s.ftpPostLoginCommands
        s.ftpListAll = v.autoSwitch("FtpListAll") ?? s.ftpListAll
        s.ftpUseMLSD = v.autoSwitch("FtpUseMlsd") ?? s.ftpUseMLSD
        s.ftpForcePassiveIP = v.autoSwitch("FtpForcePasvIp2") ?? s.ftpForcePassiveIP
        s.ftpUseHost = v.autoSwitch("FtpHost") ?? s.ftpUseHost
        s.ftpAccount = v.string("FtpAccount") ?? s.ftpAccount
        s.vmsAllRevisions = v.bool("VMSAllRevisions") ?? s.vmsAllRevisions
        if let passive = v.bool("FtpPasvMode") {
            s.passiveMode = passive
            if !passive { warnings.append("FTP active mode is not supported yet; passive mode will be used.") }
        }
        // S3
        site.s3Region = v.string("S3DefaultRegion") ?? site.s3Region
        if let style = v.int("S3UrlStyle") { site.s3PathStyle = style == 1 }
        s.s3RequesterPays = v.bool("S3RequesterPays") ?? s.s3RequesterPays
        s.s3RoleARN = v.string("S3RoleArn") ?? s.s3RoleARN
        // WebDAV
        s.webdavLiberalEscaping = v.bool("WebDavLiberalEscaping") ?? s.webdavLiberalEscaping
        s.webdavCrossDomainRedirects = v.bool("WebDavCrossDomainRedirects") ?? s.webdavCrossDomainRedirects
        // Connection
        if let seconds = v.int("Timeout"), (1...3600).contains(seconds) { s.timeoutSeconds = seconds }
        if let type = v.int("PingType") {
            switch type {
            case 0: s.keepalive = .off
            case 2: s.keepalive = .nullPacket; warnings.append("Keepalives by dummy commands are not supported yet; null SSH packets are used.")
            default: s.keepalive = .nullPacket
            }
        }
        let interval = (v.int("PingInterval") ?? 0) * 60 + (v.int("PingIntervalSecs") ?? v.int("PingIntervalSec") ?? 0)
        if interval > 0 { s.keepaliveSeconds = min(3600, interval) }
        if let family = v.int("AddressFamily") { s.addressFamily = family == 1 ? .ipv4 : family == 2 ? .ipv6 : .auto }
        // Proxy (ProxyMethod is a name or a TProxyMethod number)
        if let method = v.int("ProxyMethod", names: ["none", "socks4", "socks5", "http", "telnet", "cmd"]) {
            switch method {
            case 1: s.proxyMethod = .socks4
            case 2: s.proxyMethod = .socks5
            case 3: s.proxyMethod = .http
            case 4: s.proxyMethod = .telnet; warnings.append("Telnet proxies are not supported yet; the site will not connect until the proxy is changed.")
            case 5: s.proxyMethod = kind.usesSSH ? .local : .none
                if !kind.usesSSH { warnings.append("Local proxy commands are supported for SFTP and SCP only; the proxy was turned off.") }
            default: s.proxyMethod = .none
            }
        }
        s.proxyHost = v.string("ProxyHost") ?? s.proxyHost
        if let port = v.int("ProxyPort"), (1...65535).contains(port) { s.proxyPort = port }
        s.proxyUsername = v.string("ProxyUsername") ?? s.proxyUsername
        if !s.proxyUsername.isEmpty, s.proxyMethod != .none { warnings.append("Proxy authentication is not supported yet; the site will not connect until the proxy user name is cleared.") }
        if let command = v.string("ProxyTelnetCommand") {
            if s.proxyMethod == .local { s.proxyLocalCommand = command } else { s.proxyTelnetCommand = command }
        }
        // PuTTY convention 0 No, 1 Auto, 2 Yes → TAutoSwitch((n + 1) % 3).
        if let dns = v.int("ProxyDNS") { s.proxyDNS = [TriState.off, .auto, .on][((dns % 3) + 3) % 3] }
        s.proxyLocalhost = v.bool("ProxyLocalhost") ?? s.proxyLocalhost
        // Tunnel
        s.tunnel = v.bool("Tunnel") ?? s.tunnel
        if var tunnelHost = v.string("TunnelHostName") {
            var tunnelUser = v.string("TunnelUserName") ?? ""
            if let at = tunnelHost.lastIndex(of: "@") {
                if tunnelUser.isEmpty { tunnelUser = String(tunnelHost[..<at]) }
                tunnelHost = String(tunnelHost[tunnelHost.index(after: at)...])
            }
            s.tunnelHost = tunnelHost; s.tunnelUsername = tunnelUser
        } else { s.tunnelUsername = v.string("TunnelUserName") ?? s.tunnelUsername }
        if let port = v.int("TunnelPortNumber"), (1...65535).contains(port) { s.tunnelPort = port }
        if let key = v.string("TunnelPublicKeyFile"), !key.isEmpty {
            if let resolved = resolve(key, prefix: prefix) { tunnelKeySource = resolved }
            else if isWindowsPath(key) || key.lowercased().hasSuffix(".ppk") { warnings.append("The tunnel private key must be copied to this Mac (and converted if it is .ppk).") }
            else { s.tunnelPrivateKey = key }
        }
        s.tunnelLocalPort = v.int("TunnelLocalPortNumber") ?? s.tunnelLocalPort
        if s.tunnel, !kind.usesSSH { warnings.append("SSH tunnels are supported for SFTP and SCP only; the site will not connect until the tunnel is turned off.") }
        // TLS
        let tls: (Int) -> TLSVersion? = { [10: .tls10, 11: .tls11, 12: .tls12, 13: .tls13][$0] }
        if let minimum = v.int("MinTlsVersion").flatMap(tls) { s.tlsMinimum = minimum }
        if let maximum = v.int("MaxTlsVersion").flatMap(tls) { s.tlsMaximum = maximum }
        s.tlsSessionReuse = v.bool("SslSessionReuse") ?? s.tlsSessionReuse
        s.tlsClientCertificate = v.string("TlsCertificateFile") ?? s.tlsClientCertificate
        // SSH
        s.compression = v.bool("Compression") ?? s.compression
        s.legacySingleDES = v.bool("Ssh2DES") ?? s.legacySingleDES
        if let list = v.string("Cipher") { s.ciphers = order(list, CipherGroup.defaultOrder, [
            "warn": .warn, "3des": .tripleDES, "blowfish": .blowfish, "aes": .aes, "des": .des, "arcfour": .arcfour, "chacha20": .chacha20, "aesgcm": .aesGCM]) }
        if let list = v.string("KEX") { s.kex = order(list, KexGroup.defaultOrder, [
            "warn": .warn, "dh-group1-sha1": .dhGroup1, "dh-group14-sha1": .dhGroup14, "dh-group15-sha512": .dhGroup15,
            "dh-group16-sha512": .dhGroup16, "dh-group17-sha512": .dhGroup17, "dh-group18-sha512": .dhGroup18,
            "dh-gex-sha1": .dhGEX, "rsa": .rsa, "ecdh": .ecdh, "ntru-curve25519": .ntru, "mlkem-curve25519": .mlkem]) }
        s.gssapiKeyExchange = v.bool("AuthGSSAPIKEX") ?? s.gssapiKeyExchange
        if let minutes = v.int("RekeyTime"), (0...100_000).contains(minutes) { s.rekeyMinutes = minutes }
        if let data = v.string("RekeyBytes"), SiteSettings.dataLimit(data) != nil { s.rekeyData = data }
        // Authentication
        s.bypassAuthentication = v.bool("SshNoUserAuth") ?? s.bypassAuthentication
        s.tryAgent = v.bool("TryAgent") ?? s.tryAgent
        s.keyboardInteractive = v.bool("AuthKI") ?? s.keyboardInteractive
        s.keyboardInteractiveFirstPrompt = v.bool("AuthKIPassword") ?? s.keyboardInteractiveFirstPrompt
        s.agentForwarding = v.bool("AgentFwd") ?? s.agentForwarding
        if let certificate = v.string("DetachedCertificate"), !certificate.isEmpty {
            if isWindowsPath(certificate) { warnings.append("The SSH certificate must be copied to this Mac.") } else { s.certificateFile = certificate }
        }
        s.gssapiAuthentication = v.bool("AuthGSSAPI") ?? v.bool("AuthSSPI") ?? s.gssapiAuthentication
        s.gssapiDelegation = v.bool("GSSAPIFwdTGT") ?? v.bool("GssapiFwd") ?? v.bool("SSPIFwdTGT") ?? s.gssapiDelegation
        // Bugs: stored as 2 - TAutoSwitch.
        func bug(_ name: String) -> TriState? { v.int("Bug" + name).map { [TriState.on, .off, .auto][min(2, max(0, 2 - $0))] } }
        s.bugHMAC2 = bug("HMAC2") ?? s.bugHMAC2; s.bugDeriveKey2 = bug("DeriveKey2") ?? s.bugDeriveKey2
        s.bugRSAPad2 = bug("RSAPad2") ?? s.bugRSAPad2; s.bugPKSessionID2 = bug("PKSessID2") ?? s.bugPKSessionID2
        s.bugRekey2 = bug("Rekey2") ?? s.bugRekey2; s.bugMaxPacket2 = bug("MaxPkt2") ?? s.bugMaxPacket2
        s.bugIgnore2 = bug("Ignore2") ?? s.bugIgnore2; s.bugWinAdj = bug("WinAdj") ?? s.bugWinAdj
        // Note and color (TColor is 0x00BBGGRR)
        s.note = v.string("Note") ?? s.note
        if let color = v.int("Color"), color > 0 {
            s.color = String(format: "#%02X%02X%02X", color & 0xFF, (color >> 8) & 0xFF, (color >> 16) & 0xFF)
        }
        site.settings = s
        do { try site.validate() } catch { throw ClientError.invalid("its settings are invalid: \(error.localizedDescription)") }
        return ImportedSite(site: site, warnings: warnings, keySource: keySource, tunnelKeySource: tunnelKeySource, password: password)
    }

    /// WinSCP algorithm lists name a priority order; missing groups are appended in default order.
    private static func order<T: Equatable>(_ list: String, _ defaults: [T], _ names: [String: T]) -> [T] {
        var result: [T] = []
        for name in list.split(separator: ",") {
            if let item = names[name.trimmingCharacters(in: .whitespaces).lowercased()], !result.contains(item) { result.append(item) }
        }
        return result + defaults.filter { !result.contains($0) }
    }

    // MARK: Host keys

    /// `type@port:host` = PuTTY's key text: ed25519 "0xX,0xY"; rsa2 "0xE,0xN"; ecdsa "nistpNNN,0xX,0xY".
    static func hostKey(name: String, value: String) throws -> ImportedHostKey {
        guard let at = name.firstIndex(of: "@"), let colon = name[at...].firstIndex(of: ":"),
              let port = Int(name[name.index(after: at)..<colon]), (1...65535).contains(port) else { throw ClientError.invalid("unrecognized entry name.") }
        let type = String(name[..<at]), host = String(name[name.index(after: colon)...])
        guard !host.isEmpty, host.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",#*?!["))) == nil else {
            throw ClientError.invalid("invalid host name.")
        }
        let fields = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        func number(_ text: String) throws -> [UInt8] {
            guard text.lowercased().hasPrefix("0x") else { throw ClientError.invalid("not a PuTTY host key.") }
            var hex = String(text.dropFirst(2)); if hex.count % 2 == 1 { hex = "0" + hex }
            var bytes: [UInt8] = [], index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { throw ClientError.invalid("invalid hexadecimal key data.") }
                bytes.append(byte); index = next
            }
            while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
            return bytes
        }
        func string(_ bytes: [UInt8]) -> [UInt8] { withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init) + bytes }
        func mpint(_ bytes: [UInt8]) -> [UInt8] { string(bytes == [0] ? [] : (bytes.first! & 0x80 != 0 ? [0] + bytes : bytes)) }
        func padded(_ bytes: [UInt8], _ size: Int) throws -> [UInt8] {
            guard bytes.count <= size else { throw ClientError.invalid("key coordinate is too large.") }
            return [UInt8](repeating: 0, count: size - bytes.count) + bytes
        }
        let algorithm: String, blob: [UInt8]
        switch type {
        case "ssh-ed25519":
            guard fields.count == 2 else { throw ClientError.invalid("invalid Ed25519 key.") }
            let x = try number(fields[0]); var y = Array(try padded(number(fields[1]), 32).reversed())
            guard y[31] & 0x80 == 0 else { throw ClientError.invalid("invalid Ed25519 key.") }
            if (x.last ?? 0) & 1 == 1 { y[31] |= 0x80 }
            algorithm = "ssh-ed25519"; blob = string(Array(algorithm.utf8)) + string(y)
        case "rsa2":
            guard fields.count == 2 else { throw ClientError.invalid("invalid RSA key.") }
            algorithm = "ssh-rsa"; blob = string(Array(algorithm.utf8)) + mpint(try number(fields[0])) + mpint(try number(fields[1]))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = String(type.dropFirst("ecdsa-sha2-".count)), size = curve == "nistp256" ? 32 : curve == "nistp384" ? 48 : 66
            guard fields.count == 3, fields[0] == curve else { throw ClientError.invalid("invalid ECDSA key.") }
            algorithm = type
            blob = string(Array(type.utf8)) + string(Array(curve.utf8)) + string([4] + (try padded(number(fields[1]), size)) + (try padded(number(fields[2]), size)))
        case "dss": throw ClientError.unsupported("DSA host keys are no longer supported by OpenSSH.")
        default: throw ClientError.unsupported("\(type) host keys are not supported.")
        }
        let encoded = Data(blob).base64EncodedString()
        let target = port == 22 ? host : "[\(host)]:\(port)"
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: Data(blob))).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return ImportedHostKey(host: host, port: port, algorithm: algorithm, fingerprint: fingerprint, knownHostsLine: "\(target) \(algorithm) \(encoded)\n")
    }
}

public struct WinSCPImportSummary: Sendable {
    public var sites: [Site] = []
    public var convertedKeys: [String] = []
    public var hostKeysAdded = 0
    public var hostKeysAlreadyKnown = 0
    /// Hosts whose existing trusted key differs; the existing key is kept.
    public var hostKeyConflicts: [String] = []
    public var problems: [String] = []
    public var backup: URL?
}

extension WinSCPImport {
    /// Saves the chosen sites (unique names), converts or links their keys into `<store>/keys`
    /// (0600), and appends chosen host keys to the app's known_hosts without replacing a
    /// different key already trusted for that host. `sites.json` and known_hosts are backed up first.
    /// `passphrases` unlock passphrase-protected PuTTY keys (by source path); `protect` then puts
    /// the same passphrase on the converted OpenSSH key, so it is never stored unprotected.
    public static func commit(_ chosen: [ImportedSite], hostKeys: [ImportedHostKey], into store: SiteStore, existing: [Site],
                              passphrases: [String: String] = [:], protect: ((URL, String) throws -> Void)? = nil) throws -> WinSCPImportSummary {
        let manager = FileManager.default
        var summary = WinSCPImportSummary()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = store.directory.appendingPathComponent("backups/before-import-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["sites.json", "known_hosts"] where manager.fileExists(atPath: store.directory.appendingPathComponent(name).path) {
            try manager.copyItem(at: store.directory.appendingPathComponent(name), to: backup.appendingPathComponent(name))
        }
        summary.backup = backup

        let keys = store.directory.appendingPathComponent("keys", isDirectory: true)
        try manager.createDirectory(at: keys, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var installed: [String: String] = [:]
        func install(_ source: String) -> String? {
            if let done = installed[source] { return done }
            guard source.lowercased().hasSuffix(".ppk") else { installed[source] = source; return source }
            do {
                let text = try String(contentsOfFile: source, encoding: .utf8)
                let passphrase = PuTTYKey.isEncrypted(text) ? passphrases[source] : nil
                if passphrase != nil, protect == nil { throw ClientError.invalid("a protected key cannot be converted here.") }
                let converted = try PuTTYKey.convert(text, passphrase: passphrase)
                let stem = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
                var name = stem.isEmpty ? "imported-key" : stem, index = 2
                while manager.fileExists(atPath: keys.appendingPathComponent(name).path) { name = "\(stem)-\(index)"; index += 1 }
                let target = keys.appendingPathComponent(name)
                guard manager.createFile(atPath: target.path, contents: Data(converted.privateKey.utf8), attributes: [.posixPermissions: 0o600]),
                      manager.createFile(atPath: target.path + ".pub", contents: Data(converted.publicKeyLine.utf8), attributes: [.posixPermissions: 0o644]) else {
                    throw ClientError.invalid("cannot write the converted key.")
                }
                if let passphrase, let protect {
                    do { try protect(target, passphrase) }
                    catch { try? manager.removeItem(at: target); try? manager.removeItem(atPath: target.path + ".pub"); throw error }
                }
                installed[source] = target.path; summary.convertedKeys.append(target.path)
                return target.path
            } catch {
                summary.problems.append("\((source as NSString).lastPathComponent): \(error.localizedDescription)")
                installed[source] = ""; return nil
            }
        }

        var names = Set(existing.map(\.name))
        var updated = existing
        for item in chosen {
            var site = item.site
            if let source = item.keySource, let path = install(source), !path.isEmpty { site.privateKey = path }
            if let source = item.tunnelKeySource, let path = install(source), !path.isEmpty { site.settings.tunnelPrivateKey = path }
            var name = site.name, index = 2
            while names.contains(name) { name = "\(site.name) (imported\(index == 2 ? "" : " \(index - 1)"))"; index += 1 }
            site.name = name; names.insert(name)
            do { try site.validate(); updated.append(site); summary.sites.append(site) }
            catch { summary.problems.append("\(site.name): \(error.localizedDescription)") }
        }
        try store.save(updated)

        // known_hosts: never replace a different key the user already trusts.
        let file = store.knownHostsFile
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let existingLines = text.split(separator: "\n").map(String.init)
        for key in hostKeys {
            let fields = key.knownHostsLine.trimmingCharacters(in: .newlines).split(separator: " ")
            let same = existingLines.filter { $0.split(separator: " ").first == fields[0] && $0.split(separator: " ").dropFirst().first == fields[1] }
            if same.contains(where: { $0.split(separator: " ").dropFirst(2).first == fields[2] }) { summary.hostKeysAlreadyKnown += 1; continue }
            if !same.isEmpty { summary.hostKeyConflicts.append("\(fields[0]) (\(key.algorithm))"); continue }
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += key.knownHostsLine; summary.hostKeysAdded += 1
        }
        try Data(text.utf8).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return summary
    }
}

extension WinSCPImport {
    /// WinSCP configurations of Windows apps run on this Mac: Wine (~/.wine, ~/.local/share/wineprefixes),
    /// Whisky and CrossOver bottles. Checks WinSCP.ini in the usual folders and each prefix's user.reg,
    /// keeping only files that actually contain WinSCP sites or host keys.
    public static func locateOnThisMac(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let manager = FileManager.default
        var prefixes = [home.appendingPathComponent(".wine")]
        for parent in [".local/share/wineprefixes", "Library/Containers/com.isaacmarovitz.Whisky/Bottles", "Library/Application Support/CrossOver/Bottles"] {
            let directory = home.appendingPathComponent(parent)
            prefixes += ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        }
        var found: [URL] = []
        for prefix in prefixes where manager.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) {
            var candidates = [prefix.appendingPathComponent("user.reg")]
            let driveC = prefix.appendingPathComponent("drive_c")
            for folder in ["WinSCP", "Program Files/WinSCP", "Program Files (x86)/WinSCP"] { candidates.append(driveC.appendingPathComponent(folder).appendingPathComponent("WinSCP.ini")) }
            for user in (try? manager.contentsOfDirectory(at: driveC.appendingPathComponent("users"), includingPropertiesForKeys: nil)) ?? [] {
                candidates.append(user.appendingPathComponent("AppData/Roaming/WinSCP.ini"))
                candidates.append(user.appendingPathComponent("Application Data/WinSCP.ini"))
            }
            for candidate in candidates where manager.fileExists(atPath: candidate.path) {
                guard let handle = try? FileHandle(forReadingFrom: candidate) else { continue }
                defer { try? handle.close() }
                let text = String(decoding: (try? handle.read(upToCount: 64 * 1024 * 1024)) ?? Data(), as: UTF8.self)
                if text.contains("[Sessions\\") || text.contains("WinSCP 2\\\\Sessions\\\\") || text.contains("WinSCP 2\\\\SshHostKeys") || text.contains("[SshHostKeys]") {
                    found.append(candidate.resolvingSymlinksInPath())
                }
            }
        }
        return found
    }
}
