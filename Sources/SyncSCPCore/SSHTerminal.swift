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
