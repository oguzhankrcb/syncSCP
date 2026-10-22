// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads OpenSSH client configuration (`~/.ssh/config`) into sites. For every concrete `Host`
/// alias, blocks are applied in file order and the first value of each keyword wins, as ssh
/// does, so `Host *` defaults at the end fill only what a host leaves unset. Match blocks and
/// Include are not evaluated; affected hosts say so.
public enum SSHConfigImport {
    public static func parse(_ text: String, home: String = NSHomeDirectory()) -> WinSCPImportResult {
        struct Block { var patterns: [String]; var options: [(String, String)] = [] }
        var blocks: [Block] = [Block(patterns: ["*"])] // options before the first Host apply to all
        var notes: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, value) = split(line)
            switch keyword {
            case "host": blocks.append(Block(patterns: words(value)))
            case "match": blocks.append(Block(patterns: [])); notes.append("Match blocks are not evaluated.")
            case "include": notes.append("Include \(value) was not followed; import that file separately.")
            default: blocks[blocks.count - 1].options.append((keyword, value))
            }
        }
        var aliases: [String] = []
        for block in blocks.dropFirst() {
            for pattern in block.patterns where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") && !aliases.contains(pattern) {
                aliases.append(pattern)
            }
        }
        var result = WinSCPImportResult()
        for alias in aliases {
            var values: [String: String] = [:], forwards: [String] = []
            for block in blocks where matches(alias, block.patterns) {
                for (keyword, value) in block.options {
                    if keyword == "localforward" { forwards.append(value) }
                    else if values[keyword] == nil { values[keyword] = value }
                }
            }
            result.sites.append(site(alias: alias, values: values, forwards: forwards, home: home, notes: notes))
        }
        if aliases.isEmpty { result.skipped.append("No concrete Host entries were found (only patterns such as Host *).") }
        return result
    }

    private static func site(alias: String, values: [String: String], forwards: [String], home: String, notes: [String]) -> ImportedSite {
        var warnings = Array(Set(notes)).sorted()
        func expand(_ path: String) -> String {
            var value = unquote(path)
            if value.hasPrefix("~/") { value = home + value.dropFirst(1) }
            return value.replacingOccurrences(of: "%d", with: home).replacingOccurrences(of: "%h", with: values["hostname"] ?? alias)
                .replacingOccurrences(of: "%r", with: values["user"] ?? NSUserName()).replacingOccurrences(of: "%u", with: NSUserName())
        }
        let host = values["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias
        var site = Site(name: "SSH config/\(alias)", host: host, port: values["port"].flatMap(Int.init) ?? 22,
                        username: values["user"] ?? NSUserName(), transferProtocol: .sftp)
        if let identity = values["identityfile"] {
            let path = expand(identity)
            if FileManager.default.fileExists(atPath: path) { site.privateKey = path }
            else { warnings.append("IdentityFile \(identity) does not exist on this Mac.") }
        }
        var settings = site.settings
        if let jump = values["proxyjump"], jump.lowercased() != "none" {
            let hops = jump.split(separator: ",")
            var first = String(hops[0])
            if let at = first.lastIndex(of: "@") { settings.tunnelUsername = String(first[..<at]); first = String(first[first.index(after: at)...]) }
            if let colon = first.lastIndex(of: ":"), let port = Int(first[first.index(after: colon)...]) { settings.tunnelPort = port; first = String(first[..<colon]) }
            settings.tunnel = true; settings.tunnelHost = first
            if hops.count > 1 { warnings.append("ProxyJump has \(hops.count) hops; only the first (\(hops[0])) is used as the SSH tunnel.") }
            warnings.append("The jump host \(first) is used as an SSH tunnel; if it is an alias, check its address in Advanced ▸ Tunnel.")
        } else if let command = values["proxycommand"], command.lowercased() != "none" {
            settings.proxyMethod = .local; settings.proxyLocalCommand = command
        }
        if let interval = values["serveraliveinterval"].flatMap(Int.init), interval > 0 { settings.keepalive = .nullPacket; settings.keepaliveSeconds = interval }
        if let timeout = values["connecttimeout"].flatMap(Int.init), timeout > 0 { settings.timeoutSeconds = timeout }
        if values["compression"]?.lowercased() == "yes" { settings.compression = true }
        if values["forwardagent"]?.lowercased() == "yes" { settings.agentForwarding = true }
        for forward in forwards {
            let parts = words(forward)
            guard parts.count == 2, let local = Int(parts[0].split(separator: ":").last ?? ""),
                  let colon = parts[1].lastIndex(of: ":"), let remotePort = Int(parts[1][parts[1].index(after: colon)...]) else {
                warnings.append("LocalForward \(forward) was not understood."); continue
            }
            let target = PortForward(name: "", localPort: local, remoteHost: String(parts[1][..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), remotePort: remotePort)
            if (try? target.validate()) != nil { settings.portForwards.append(target) } else { warnings.append("LocalForward \(forward) is not valid.") }
        }
        for unsupported in ["remoteforward", "dynamicforward", "certificatefile", "hostkeyalias", "localcommand"] where values[unsupported] != nil {
            warnings.append("\(unsupported) is not imported.")
        }
        site.settings = settings
        return ImportedSite(site: site, warnings: warnings, keySource: nil, tunnelKeySource: nil, password: nil)
    }

    /// ssh's Host matching: any positive pattern matches and no negated one does.
    static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") { if fnmatch(String(pattern.dropFirst()), alias, 0) == 0 { return false } }
            else if fnmatch(pattern, alias, 0) == 0 { matched = true }
        }
        return matched
    }

    private static func split(_ line: String) -> (String, String) {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let range = line.rangeOfCharacter(from: separators) else { return (line.lowercased(), "") }
        let keyword = String(line[..<range.lowerBound]).lowercased()
        let value = line[range.lowerBound...].trimmingCharacters(in: separators)
        return (keyword, value)
    }

    private static func words(_ value: String) -> [String] {
        var result: [String] = [], current = "", quoted = false
        for character in value {
            if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted { if !current.isEmpty { result.append(current); current = "" } }
            else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func unquote(_ value: String) -> String {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    }
}
