// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

final class SSHTerminalTests: XCTestCase {
    private var key: URL!
    override func setUpWithError() throws {
        key = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-terminal-key-\(UUID().uuidString)")
        try Data("not used".utf8).write(to: key)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: key) }

    private func launch(_ settings: SiteSettings = SiteSettings(), directory: String? = nil, environment: [String: String] = [:]) throws -> SSHTerminalLaunch {
        let site = Site(host: "example.com", port: 2222, username: "deploy", privateKey: key.path, transferProtocol: .scp, settings: settings)
        return try SSHConfiguration(site: site, knownHostsFile: "/tmp/known hosts").terminalLaunch(directory: directory, environment: environment)
    }

    func testTerminalIsInteractiveButKeepsTheSameHostKeyPolicy() throws {
        let arguments = try launch().arguments
        XCTAssertTrue(arguments.contains("-t")); XCTAssertFalse(arguments.contains("-T"))
        XCTAssertFalse(arguments.contains("BatchMode=yes"), "passwords are typed into the terminal")
        XCTAssertTrue(arguments.contains("NumberOfPasswordPrompts=3"))
        for option in ["StrictHostKeyChecking=yes", "UserKnownHostsFile=\"/tmp/known hosts\"", "GlobalKnownHostsFile=/dev/null", "ClearAllForwardings=yes", "PermitLocalCommand=no", "IdentitiesOnly=yes"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", "example.com"], "no directory and no shell: a plain login")
    }

    func testDirectoryAndShellBecomeOneSafeRemoteCommand() throws {
        let plain = try launch(directory: "/srv/it's here").arguments
        XCTAssertEqual(plain.last, "exec /bin/sh -c 'cd \"$1\" 2>/dev/null || echo \"syncSCP: cannot open $1\" >&2; exec \"${SHELL:-/bin/sh}\" -l' syncscp '/srv/it'\\''s here'")
        var settings = SiteSettings(); settings.shell = "sudo su -"
        let sudo = try launch(settings).arguments
        XCTAssertEqual(sudo.last, "exec /bin/sh -c 'exec sudo su -' syncscp")
        XCTAssertThrowsError(try launch(directory: "/bad\0path"))
    }

    func testEnvironmentDropsTheAskpassHook() throws {
        let environment = try launch(environment: ["SYNCSCP_ASKPASS_ID": "x", "SSH_ASKPASS": "/app", "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "syncscp:0",
                                                   "HOME": "/Users/me", "TERM": "dumb", "SSH_AUTH_SOCK": "/agent"]).environment
        XCTAssertEqual(environment, ["COLORTERM=truecolor", "HOME=/Users/me", "LANG=en_US.UTF-8", "SSH_AUTH_SOCK=/agent", "TERM=xterm-256color"])
        var settings = SiteSettings(); settings.tryAgent = false
        XCTAssertFalse(try launch(settings, environment: ["SSH_AUTH_SOCK": "/agent"]).environment.contains { $0.hasPrefix("SSH_AUTH_SOCK=") })
    }

    func testTerminalAppCommandFileQuotesEveryArgument() throws {
        let launch = try launch(directory: "/srv/$(touch pwned) `x` \"q\"")
        let script = launch.commandFile.replacingOccurrences(of: "exec '/usr/bin/ssh'", with: "printf '%s\\n'")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("syncscp-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ssh.command")
        try script.replacingOccurrences(of: "\nclear\n", with: "\n").write(to: file, atomically: true, encoding: .utf8)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [file.path]
        process.currentDirectoryURL = directory; process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(printed, launch.arguments)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the script removes itself and its private folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    }

    func testSavedPasswordLoginPassesOnlyItsOwnAskpass() throws {
        let site = Site(host: "example.com", username: "deploy", transferProtocol: .scp)
        let launch = try SSHConfiguration(site: site, knownHostsFile: "/tmp/known hosts", askpassExecutable: "/Applications/syncSCP.app/Contents/MacOS/SyncSCP", credentialID: "ID-1")
            .terminalLaunch(environment: ["SSH_ASKPASS": "/inherited", "SYNCSCP_ASKPASS_ID": "inherited", "HOME": "/Users/me"])
        XCTAssertTrue(launch.environment.contains("SSH_ASKPASS=/Applications/syncSCP.app/Contents/MacOS/SyncSCP"))
        XCTAssertTrue(launch.environment.contains("SYNCSCP_ASKPASS_ID=ID-1"))
        XCTAssertTrue(launch.environment.contains("SSH_ASKPASS_REQUIRE=force"))
        XCTAssertFalse(launch.environment.contains { $0.contains("inherited") })
        XCTAssertFalse(launch.arguments.contains("BatchMode=yes"))
    }

    func testPortForwardArgumentsKeepOnlyTheRequestedLoopbackForward() throws {
        var forward = PortForward(name: "db", localPort: 5433, remoteHost: "10.0.0.5", remotePort: 5432)
        let site = Site(host: "example.com", username: "deploy", privateKey: key.path, transferProtocol: .sftp)
        let configuration = SSHConfiguration(site: site, knownHostsFile: "/tmp/known hosts")
        let arguments = try configuration.forwardArguments(forward)
        XCTAssertFalse(arguments.contains("ClearAllForwardings=yes"), "it would cancel -L")
        XCTAssertTrue(arguments.contains("ExitOnForwardFailure=yes") && arguments.contains("-N") && arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes") && arguments.contains("PermitLocalCommand=no"))
        XCTAssertEqual(Array(arguments.suffix(4)), ["-L", "127.0.0.1:5433:10.0.0.5:5432", "--", "example.com"])
        forward.remoteHost = "::1"
        XCTAssertTrue(try configuration.forwardArguments(forward).contains("127.0.0.1:5433:[::1]:5432"))
        for (host, local, remote) in [("-oProxyCommand=x", 1, 2), ("a b", 1, 2), ("", 1, 2), ("db", 0, 2), ("db", 1, 70000), ("user@db", 1, 2)] {
            XCTAssertThrowsError(try configuration.forwardArguments(PortForward(localPort: local, remoteHost: host, remotePort: remote)), host)
        }
        XCTAssertEqual(try JSONDecoder().decode(SiteSettings.self, from: JSONEncoder().encode({ var s = SiteSettings(); s.portForwards = [forward]; return s }())).portForwards, [forward])
    }
}
