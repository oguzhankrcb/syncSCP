// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum FTPPath {
    public static func validate(_ path: String) throws {
        guard path.utf8.count <= 32768, path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ClientError.invalid("FTP paths cannot contain control characters and must be at most 32 KiB.")
        }
    }
    public static func normalize(_ path: String, relativeTo base: String = "/") throws -> String {
        try validate(path); try validate(base)
        let absolute = path.hasPrefix("/") ? path : RemotePath.join(base, path)
        var components: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        return "/" + components.joined(separator: "/")
    }
    static func url(site: Site, path: String, directory: Bool, loginHome: Bool = false) throws -> String {
        try validate(path)
        var components = URLComponents()
        components.scheme = site.transferProtocol == .ftpsImplicit ? "ftps" : "ftp"
        components.host = site.host.contains(":") && !site.host.hasPrefix("[") ? "[\(site.host)]" : site.host
        components.port = site.port
        // FTP URLs are relative to the login directory unless their decoded path begins with '/'.
        let encoded = try normalize(path).addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
        components.percentEncodedPath = loginHome ? "/" : "/" + encoded + (directory && !encoded.hasSuffix("/") ? "/" : "")
        guard let url = components.url?.absoluteString else { throw ClientError.invalid("Cannot form the FTP URL.") }
        return url
    }
}

enum FTPListing {
    static func mlsd(_ data: Data, directory: String) throws -> [FileEntry] {
        let lines = try lines(data)
        let formatter = timestampFormatter()
        return try lines.compactMap { line in
            guard let separator = line.firstIndex(of: " ") else { throw ClientError.protocolError("Malformed MLSD listing.") }
            let name = String(line[line.index(after: separator)...])
            var facts: [String: String] = [:]
            for item in line[..<separator].split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw ClientError.protocolError("Malformed MLSD fact.") }
                let key = pair[0].lowercased()
                guard facts[key] == nil else { throw ClientError.protocolError("Duplicate MLSD fact.") }
                facts[key] = String(pair[1])
            }
            guard let type = facts["type"]?.lowercased() else { throw ClientError.unsupported("The FTP server omitted MLSD file types.") }
            if type == "cdir" || type == "pdir" || name == "." || name == ".." { return nil }
            try RemotePath.validateName(name); try FTPPath.validate(name)
            let fileType: UInt32
            if type == "dir" { fileType = 0o040000 }
            else if type == "file" { fileType = 0o100000 }
            else if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") { fileType = 0o120000 }
            else { fileType = 0 }
            let size: UInt64
            if let text = facts["size"] {
                guard let parsed = UInt64(text) else { throw ClientError.protocolError("Invalid MLSD file size.") }; size = parsed
            } else {
                guard fileType != 0o100000 else { throw ClientError.unsupported("The FTP server omitted MLSD file sizes.") }
                size = 0
            }
            var mode: UInt32 = fileType == 0o040000 ? 0o755 : 0o644
            if let text = facts["unix.mode"] {
                // Some servers expose this nonstandard fact using Python's 0o prefix.
                let digits = text.lowercased().hasPrefix("0o") ? String(text.dropFirst(2)) : text
                guard let parsed = UInt32(digits, radix: 8), parsed <= 0o7777 else { throw ClientError.protocolError("Invalid MLSD permissions.") }
                mode = parsed
            }
            var date: Date?
            if let text = facts["modify"] {
                let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts[0].count == 14, let parsed = formatter.date(from: String(parts[0])) else { throw ClientError.protocolError("Invalid MLSD modification time.") }
                date = parsed
                if parts.count == 2 {
                    guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                          let fraction = Double("0." + parts[1]) else { throw ClientError.protocolError("Invalid MLSD fractional time.") }
                    date = parsed.addingTimeInterval(fraction)
                }
            }
            return FileEntry(path: RemotePath.join(directory, name), name: name, size: size, permissions: fileType | mode, modified: date, permissionsKnown: facts["unix.mode"] != nil)
        }.sorted(by: LocalFiles.order)
    }

    static func legacy(_ data: Data, directory: String) throws -> [FileEntry] {
        let unix = try NSRegularExpression(pattern: "^([bcdlps-][rwxStTs-]{9})[+@.]?\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+[A-Za-z]{3}\\s+\\d{1,2}\\s+(?:\\d{4}|\\d{1,2}:\\d{2}(?::\\d{2})?) (.*)$")
        let dos = try NSRegularExpression(pattern: "^\\d{2}-\\d{2}-\\d{2,4}\\s+\\d{1,2}:\\d{2}(?:AM|PM)\\s+(<DIR>|\\d+)\\s+(.*)$", options: .caseInsensitive)
        return try lines(data).compactMap { line in
            if line.hasPrefix("total "), UInt64(line.dropFirst(6)) != nil { return nil }
            let range = NSRange(line.startIndex..., in: line)
            var name: String; var size: UInt64 = 0; var permissions: UInt32; var permissionsKnown = true
            if let match = unix.firstMatch(in: line, range: range) {
                func field(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
                let rights = Array(field(1)); name = field(3)
                guard let parsed = UInt64(field(2)) else { throw ClientError.protocolError("Invalid FTP LIST size.") }; size = parsed
                permissions = rights[0] == "d" ? 0o040000 : rights[0] == "l" ? 0o120000 : rights[0] == "-" ? 0o100000 : 0
                for (index, bit) in [UInt32(0o400), 0o200, 0o100, 0o40, 0o20, 0o10, 0o4, 0o2, 0o1].enumerated() {
                    if "rwxst".contains(rights[index + 1]) { permissions |= bit }
                }
                if rights[0] == "l", let separator = name.range(of: " -> ") { name = String(name[..<separator.lowerBound]) }
            } else if let match = dos.firstMatch(in: line, range: range) {
                let amount = String(line[Range(match.range(at: 1), in: line)!])
                name = String(line[Range(match.range(at: 2), in: line)!])
                permissions = amount.uppercased() == "<DIR>" ? 0o040755 : 0o100644
                permissionsKnown = false
                if !amount.hasPrefix("<") { guard let parsed = UInt64(amount) else { throw ClientError.protocolError("Invalid FTP LIST size.") }; size = parsed }
            } else { throw ClientError.unsupported("Unsupported FTP LIST format. The server must provide MLSD, Unix LIST, or DOS LIST.") }
            if name == "." || name == ".." { return nil }
            try RemotePath.validateName(name); try FTPPath.validate(name)
            // LIST does not specify a timezone or a reliable year for recent files.
            return FileEntry(path: RemotePath.join(directory, name), name: name, size: size, permissions: permissions, modified: nil, permissionsKnown: permissionsKnown)
        }.sorted(by: LocalFiles.order)
    }

    private static func lines(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.unsupported("The FTP listing is not UTF-8.") }
        let lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }.filter { !$0.isEmpty }
        guard lines.count <= 100_000 else { throw ClientError.unsupported("FTP directories are limited to 100,000 entries.") }
        return lines
    }
    static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"; formatter.isLenient = false
        return formatter
    }
}
