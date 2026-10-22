// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An interactive SSH login for a terminal, like WinSCP's Open Terminal / Open in PuTTY.
/// It uses the site's settings and the app's known_hosts exactly as file sessions do; there
/// is no askpass, so OpenSSH (and sudo) ask for passwords on the terminal itself.
public struct SSHTerminalLaunch: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// `KEY=value` entries for the ssh process.
    public let environment: [String]

    /// A self-deleting script for Terminal.app (opened as a .command file).
    public var commandFile: String {
        "#!/bin/sh\nrm -f -- \"$0\"; rmdir -- \"$(dirname -- \"$0\")\" 2>/dev/null\nclear\nexec " + ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ") + "\n"
    }
    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension SSHConfiguration {
    /// Opens in `directory` when given, then starts the site's SCP/Shell setting (for example
    /// `sudo su -`) or the user's login shell. The remote command is run by /bin/sh so it does
    /// not depend on the login shell's syntax; the directory is a positional argument.
    public func terminalLaunch(directory: String? = nil, environment base: [String: String] = ProcessInfo.processInfo.environment) throws -> SSHTerminalLaunch {
        var arguments = try baseArguments(interactive: true) + ["--", site.host]
        let shell = site.settings.shell.trimmingCharacters(in: .whitespaces)
        let directory = directory?.isEmpty == false ? directory : nil
        if directory != nil || !shell.isEmpty {
            let start = shell.isEmpty ? "\"${SHELL:-/bin/sh}\" -l" : shell
            let script = (directory == nil ? "" : "cd \"$1\" 2>/dev/null || echo \"syncSCP: cannot open $1\" >&2; ") + "exec " + start
            arguments.append(try "exec /bin/sh -c " + SCPShell.quote(script) + " syncscp" + (directory.map { " " + (try SCPShell.quote($0)) } ?? ""))
        }
        // Never pass on an askpass hook inherited from the app's own environment.
        var environment = base.filter { key, _ in !key.hasPrefix("SYNCSCP_") && !key.hasPrefix("SSH_ASKPASS") && key != "DISPLAY" }
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if !site.settings.tryAgent { environment["SSH_AUTH_SOCK"] = nil }
        // Only an askpass configured for this login (a saved password) is passed on.
        environment.merge(self.environment) { _, configured in configured }
        return SSHTerminalLaunch(executable: "/usr/bin/ssh", arguments: arguments, environment: environment.map { "\($0.key)=\($0.value)" }.sorted())
    }
}

/// An SSH local port forward, like PuTTY's Tunnels page: `127.0.0.1:localPort` on this Mac
/// reaches `remoteHost:remotePort` as seen from the server.
public struct PortForward: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(name: String = "", localPort: Int, remoteHost: String = "127.0.0.1", remotePort: Int) {
        self.name = name; self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort
    }

    public var summary: String { "localhost:\(localPort) → \(remoteHost):\(remotePort)" }

    public func validate() throws {
        guard (1...65535).contains(localPort), (1...65535).contains(remotePort) else { throw ClientError.invalid("Ports must be between 1 and 65535.") }
        let host = remoteHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "/" && $0 != "@" }) else {
            throw ClientError.invalid("Enter a host name or address for the destination.")
        }
    }
}

extension SSHConfiguration {
    /// `ssh -N -L` for one forward, bound to the loopback address only. ClearAllForwardings is
    /// left out (it would cancel -L); ExitOnForwardFailure makes a busy local port fail at once.
    public func forwardArguments(_ forward: PortForward) throws -> [String] {
        try forward.validate()
        var arguments = try baseArguments()
        if let index = arguments.firstIndex(of: "ClearAllForwardings=yes") { arguments.removeSubrange(index - 1...index) }
        let host = forward.remoteHost.contains(":") ? "[\(forward.remoteHost)]" : forward.remoteHost
        return arguments + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveCountMax=3",
                            "-L", "127.0.0.1:\(forward.localPort):\(host):\(forward.remotePort)", "--", site.host]
    }
}
