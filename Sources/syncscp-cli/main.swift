// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SyncSCPCore

// OpenSSH runs this same executable as SSH_ASKPASS; answer from the temporary Keychain item and stop.
if let id = ProcessInfo.processInfo.environment["SYNCSCP_ASKPASS_ID"] {
    if let secret = SessionCredential.read(id) { FileHandle.standardOutput.write(Data((secret + "\n").utf8)) }
    exit(0)
}

let usage = """
syncscp-cli — scripting for syncSCP, in the style of winscp.com

Usage:
  syncscp-cli                                  interactive prompt
  syncscp-cli /script=FILE                     run commands from FILE
  syncscp-cli /command "open mysite" "ls" "exit"
Options: /store=FOLDER uses another data folder (default: the app's).
Use - instead of / if you prefer (-script=FILE, -command …).

Commands: open SITE|URL [-hostkey=SHA256:…] [-password=…] [-privatekey=FILE], close, exit,
  ls [MASK], cd, pwd, lls, lcd, lpwd, get [-delete] REMOTE… [LOCAL], put [-delete] LOCAL… [REMOTE],
  rm, rmdir, mkdir, mv, cp, chmod MODE FILE…, stat,
  synchronize remote|local|both [LOCAL [REMOTE]] [-delete] [-criteria=size] [-preview],
  option batch abort|continue, echo TEXT.
SITE is a saved site name (Folder/Name); URL is like sftp://user@host:2222/path.
Host keys must be trusted in syncSCP, or confirmed with -hostkey. Passwords: -password, the URL,
SYNCSCP_PASSWORD, or a prompt when run in a terminal. Exit code 0 means every command succeeded.
"""

var lines: [String] = []
var storeFolder: String?
var interactive = true
var arguments = CommandLine.arguments.dropFirst()
func option(_ text: String, _ name: String) -> String? {
    for prefix in ["/", "-"] where text.lowercased().hasPrefix(prefix + name + "=") { return String(text.dropFirst(name.count + 2)) }
    return nil
}
while let argument = arguments.popFirst() {
    let lower = argument.lowercased()
    if ["/help", "-help", "--help", "-h", "/?"].contains(lower) { print(usage); exit(0) }
    if let file = option(argument, "script") {
        guard let text = try? String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Cannot read script \(file)\n".utf8)); exit(2)
        }
        lines += text.components(separatedBy: .newlines); interactive = false
    } else if let folder = option(argument, "store") {
        storeFolder = (folder as NSString).expandingTildeInPath
    } else if lower == "/command" || lower == "-command" {
        while let next = arguments.first, !(next.hasPrefix("/") && next.contains("=")) && !["/command", "-command"].contains(next.lowercased()) {
            lines.append(String(next)); arguments = arguments.dropFirst()
        }
        interactive = false
    } else {
        FileHandle.standardError.write(Data("Unknown parameter \(argument)\n\n\(usage)\n".utf8)); exit(2)
    }
}

let store: SiteStore
do { store = try storeFolder.map { try SiteStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SiteStore() }
catch { FileHandle.standardError.write(Data("Cannot open the data folder: \(error.localizedDescription)\n".utf8)); exit(2) }

let terminal = isatty(STDIN_FILENO) == 1
let session = ScriptSession(store: store, askpass: Bundle.main.executablePath ?? CommandLine.arguments[0],
                            output: { print($0); fflush(stdout) },
                            readPassword: { prompt in terminal ? getpass(prompt).map { String(cString: $0) } : nil })
if interactive {
    session.errorMode = .continue
    print("syncSCP scripting. Type help for commands, exit to quit.")
    var failed = false
    while true {
        print("syncscp> ", terminator: ""); fflush(stdout)
        guard let line = readLine() else { break }
        if line.trimmingCharacters(in: .whitespaces).lowercased() == "help" { print(usage); continue }
        do { if try await session.execute(line) == false { break } }
        catch { failed = true; print("Error: \(error.localizedDescription)") }
    }
    exit(failed ? 1 : 0)
}
exit(await session.run(lines))
