// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Darwin
@testable import SyncSCPCore

/// Advanced Site Settings against the real disposable SSH daemons from scripts/test-ssh.sh:
/// one with the SFTP subsystem, one SCP-only daemon without it.
final class AdvancedSettingsIntegrationTests: XCTestCase {
    private var fixture: URL!, root: URL!, local: URL!, remote: URL!
    private var sftpPort = 0, scpPort = 0
    private var client: RemoteSession!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SYNCSCP_TEST_SSH_FIXTURE"], let sftp = environment["SYNCSCP_TEST_SSH_PORT"].flatMap(Int.init),
              let scp = environment["SYNCSCP_TEST_SCP_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Run scripts/test-ssh.sh for the real SSH fixtures.")
        }
        fixture = URL(fileURLWithPath: directory); sftpPort = sftp; scpPort = scp
        root = fixture.appendingPathComponent("advanced-" + UUID().uuidString)
        local = root.appendingPathComponent("local"); remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        client = RemoteSession()
    }
    override func tearDown() async throws {
        await client?.disconnect()
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func site(_ kind: TransferProtocol, port: Int, settings: SiteSettings = SiteSettings()) -> Site {
        Site(host: "127.0.0.1", port: port, username: NSUserName(), privateKey: fixture.appendingPathComponent("client_key").path,
             transferProtocol: kind, settings: settings)
    }
    private func connect(_ site: Site) async throws {
        let configuration = SSHConfiguration(site: site, knownHostsFile: fixture.appendingPathComponent("known hosts").path)
        _ = try await client.connect(site: site, password: "", sshConfiguration: configuration)
    }
    /// An executable stand-in for `sudo su -`/`sudo …/sftp-server`: it logs each start, and the
    /// shell variant prints a login banner before reading commands from stdin like `su -`.
    private func script(_ name: String, _ body: String) throws -> (path: String, log: URL) {
        let log = root.appendingPathComponent(name + ".log")
        let path = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body.replacingOccurrences(of: "$LOG", with: "'" + log.path + "'")).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return (path.path, log)
    }
    private func starts(_ log: URL) -> Int {
        ((try? String(contentsOf: log)) ?? "").split(separator: "\n").count
    }
    private func roundTrip(_ name: String, size: Int = 300_001) async throws {
        let source = local.appendingPathComponent("source-" + name), out = local.appendingPathComponent("out-" + name)
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try data.write(to: source)
        try await client.upload(local: source, remote: remote.appendingPathComponent(name).path)
        try await client.download(remote: remote.appendingPathComponent(name).path, local: out)
        XCTAssertEqual(try Data(contentsOf: out), data)
    }

    func testSCPShellRunsEveryOperationInsideTheConfiguredShell() async throws {
        // Like `sudo su -`: prints a banner, switches to another home, then reads commands from stdin.
        let home = root.appendingPathComponent("fake root home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let shell = try script("fake-sudo-shell", """
        echo 'Last login: banner printed by the login shell'
        echo 'Message of the day with SYNCSCP-END- and SYNCSCP-READY- lookalike text'
        echo started >> $LOG
        cd '\(home.path)' || exit 1
        exec /bin/sh
        """)
        var settings = SiteSettings(); settings.shell = shell.path
        let site = site(.scp, port: scpPort, settings: settings)
        let connectedHome = try await client.connect(site: site, password: "", sshConfiguration: SSHConfiguration(site: site, knownHostsFile: fixture.appendingPathComponent("known hosts").path))
        XCTAssertEqual(URL(fileURLWithPath: connectedHome).resolvingSymlinksInPath().path, home.resolvingSymlinksInPath().path, "commands must run inside the configured shell")
        XCTAssertEqual(starts(shell.log), 1, "connection probes share one persistent shell")
        try await roundTrip("through shell.bin")
        XCTAssertEqual(starts(shell.log), 3, "each scp -t/-f transfer stream starts its own shell")
        try await client.mkdir(remote.appendingPathComponent("made in shell").path)
        try await client.rename(remote.appendingPathComponent("through shell.bin").path, to: remote.appendingPathComponent("made in shell/moved.bin").path)
        let listed = try await client.list(remote.appendingPathComponent("made in shell").path)
        XCTAssertEqual(listed.map(\.name), ["moved.bin"])
        do { _ = try await client.stat(remote.appendingPathComponent("missing").path); XCTFail("Stat invented a file") } catch ClientError.remote { }
        try await client.remove(remote.appendingPathComponent("made in shell").path, recursive: true)
        let exists = try await client.exists(remote.appendingPathComponent("made in shell").path); XCTAssertFalse(exists)
        XCTAssertEqual(starts(shell.log), 3, "metadata and file operations reuse the persistent shell, also after a failed command")
    }

    func testSlowShellStartIsPaidOnceLikeWinSCP() async throws {
        let shell = try script("slow-sudo-shell", "echo started >> $LOG\nsleep 0.5\nexec /bin/sh\n")
        var settings = SiteSettings(); settings.shell = shell.path
        let site = site(.scp, port: scpPort, settings: settings)
        _ = try await client.connect(site: site, password: "", sshConfiguration: SSHConfiguration(site: site, knownHostsFile: fixture.appendingPathComponent("known hosts").path))
        let started = Date()
        for _ in 0..<10 {
            _ = try await client.realpath(remote.path)
            _ = try await client.list(remote.path)
        }
        // Twenty commands through a per-command shell would take at least 10 s here.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(starts(shell.log), 1)
    }

    func testShellThatCannotStartFailsAtLogin() async throws {
        var settings = SiteSettings(); settings.shell = "/usr/bin/false"
        do { try await connect(site(.scp, port: scpPort, settings: settings)); XCTFail("Connected through a failing shell") }
        catch ClientError.connection(let text) { XCTAssertTrue(text.contains("did not start"), text); XCTAssertTrue(text.contains("NOPASSWD"), text) }
    }

    func testSFTPServerCommandReplacesTheMissingSubsystem() async throws {
        // The SCP-only daemon has no sftp subsystem: the default fails, the configured server works.
        do { try await connect(site(.sftp, port: scpPort)); XCTFail("SFTP subsystem unexpectedly available") } catch { }
        let server = try script("fake-sudo-sftp-server", "echo started >> $LOG\nexec /usr/libexec/sftp-server\n")
        var settings = SiteSettings(); settings.sftpServer = server.path
        try await connect(site(.sftp, port: scpPort, settings: settings))
        try await roundTrip("via custom server.bin")
        XCTAssertEqual(starts(server.log), 1)
    }

    func testSSHTunnelAndLocalProxyCarryRealSessions() async throws {
        // The SFTP daemon acts as the bastion for the SCP-only daemon; both keys are pinned.
        var tunnel = SiteSettings()
        tunnel.tunnel = true; tunnel.tunnelHost = "127.0.0.1"; tunnel.tunnelPort = sftpPort
        tunnel.tunnelUsername = NSUserName(); tunnel.tunnelPrivateKey = fixture.appendingPathComponent("client_key").path
        try await connect(site(.scp, port: scpPort, settings: tunnel))
        try await roundTrip("through tunnel.bin")
        var unknownBastion = tunnel; unknownBastion.tunnelHost = "localhost"
        do { try await connect(site(.scp, port: scpPort, settings: unknownBastion)); XCTFail("Trusted an unknown tunnel host key") } catch { }

        var proxy = SiteSettings()
        proxy.proxyMethod = .local; proxy.proxyLocalhost = true; proxy.proxyLocalCommand = "/usr/bin/nc %host %port"
        try await connect(site(.sftp, port: sftpPort, settings: proxy))
        try await roundTrip("through local proxy.bin")
    }

    func testCurlAddressFamilyAndSOCKSProxyAreApplied() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SYNCSCP_TEST_WEBDAV_FIXTURE"] else {
            throw XCTSkip("Run scripts/test-ssh.sh --all for the WebDAV fixture.")
        }
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("ready.json"))) as? [String: Any])
        let port = try XCTUnwrap(config["http"] as? Int)
        func dav(_ settings: SiteSettings) -> Site {
            Site(host: "localhost", port: port, username: "syncscp", remotePath: "/dav", transferProtocol: .webdav, settings: settings)
        }
        // The fixture listens on 127.0.0.1 only: IPv6 must fail, IPv4 must work.
        var settings = SiteSettings(); settings.addressFamily = .ipv6; settings.timeoutSeconds = 5
        do { _ = try await client.connect(site: dav(settings), password: "test-only-password"); XCTFail("IPv6-only reached an IPv4 listener") }
        catch ClientError.connection { }
        settings.addressFamily = .ipv4
        _ = try await client.connect(site: dav(settings), password: "test-only-password")

        // A real SOCKS5 proxy: OpenSSH dynamic forwarding through the SSH fixture.
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let probe = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(probe) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }
        let socksPort = Int(UInt16(bigEndian: address.sin_port)); Darwin.close(probe)
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        tunnel.arguments = ["-F", "/dev/null", "-N", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                            "-o", "UserKnownHostsFile=" + SSHOptions.configQuoted(fixture.appendingPathComponent("known hosts").path),
                            "-i", fixture.appendingPathComponent("client_key").path, "-p", String(sftpPort), "-l", NSUserName(),
                            "-D", "127.0.0.1:\(socksPort)", "127.0.0.1"]
        try tunnel.run()
        defer { if tunnel.isRunning { tunnel.terminate() } }
        for _ in 0..<100 {
            let check = socket(AF_INET, SOCK_STREAM, 0)
            var target = sockaddr_in(); target.sin_family = sa_family_t(AF_INET); target.sin_port = in_port_t(UInt16(socksPort).bigEndian); target.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(check, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            close(check)
            if connected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var proxied = SiteSettings(); proxied.proxyMethod = .socks5; proxied.proxyHost = "127.0.0.1"; proxied.proxyPort = socksPort
        proxied.proxyLocalhost = true; proxied.timeoutSeconds = 5
        _ = try await client.connect(site: dav(proxied), password: "test-only-password")
        let listed = try await client.list("/dav"); XCTAssertFalse(listed.isEmpty)
        tunnel.terminate(); tunnel.waitUntilExit()
        do { _ = try await client.connect(site: dav(proxied), password: "test-only-password"); XCTFail("Connected without the configured proxy") }
        catch ClientError.connection { }
        // With "Consider proxying local host connections" off, a localhost target bypasses the proxy.
        proxied.proxyLocalhost = false
        _ = try await client.connect(site: dav(proxied), password: "test-only-password")
    }

    func testHostKeyDiscoveryThroughTunnelRecordsOnlyTheTargetKey() throws {
        var tunnel = SiteSettings()
        tunnel.tunnel = true; tunnel.tunnelHost = "127.0.0.1"; tunnel.tunnelPort = sftpPort
        tunnel.tunnelUsername = NSUserName(); tunnel.tunnelPrivateKey = fixture.appendingPathComponent("client_key").path
        let configuration = SSHConfiguration(site: site(.scp, port: scpPort, settings: tunnel), knownHostsFile: fixture.appendingPathComponent("known hosts").path)
        XCTAssertEqual(configuration.tunnelSite?.host, "127.0.0.1"); XCTAssertEqual(configuration.tunnelSite?.port, sftpPort)
        XCTAssertEqual(configuration.tunnelSite?.settings.tunnel, false)
        let temporary = root.appendingPathComponent("discovered known_hosts")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try configuration.hostKeyDiscoveryArguments(temporaryKnownHosts: temporary.path)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let recorded = try String(contentsOf: temporary).split(separator: "\n")
        let hostKey = try String(contentsOf: fixture.appendingPathComponent("host_key.pub")).split(separator: " ")
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first.map { Array($0.split(separator: " ").dropFirst()) }, [hostKey[0], hostKey[1]])
        XCTAssertTrue(recorded.first?.hasPrefix("[127.0.0.1]:\(scpPort) ") == true)
    }

    /// Runs a terminal launch on a real pseudo-terminal, types `input`, and returns what the terminal showed.
    private func terminalOutput(_ launch: SSHTerminalLaunch, input: String) throws -> String {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ClientError.invalid("openpty failed") }
        defer { close(master) }
        let process = Process(), tty = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: launch.executable); process.arguments = launch.arguments
        process.environment = Dictionary(uniqueKeysWithValues: launch.environment.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1); return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
        process.standardInput = tty; process.standardOutput = tty; process.standardError = tty
        try process.run(); close(slave)
        _ = input.utf8CString.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count - 1) }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096), readError: Int32?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) > 0 else { if !process.isRunning { break }; continue }
            let count = read(master, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if count <= 0 { readError = count < 0 ? errno : 0; break }
            output.append(buffer, count: count)
        }
        let exited = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exited { usleep(50_000) }
        if process.isRunning { process.terminate(); XCTFail("The terminal session did not end (read \(readError.map(String.init) ?? "timeout")): \(String(decoding: output, as: UTF8.self))") }
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    func testTerminalOpensInTheRemoteFolderOnARealPTY() throws {
        let folder = remote.appendingPathComponent("it's a \"terminal\" $(folder)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = SSHConfiguration(site: site(.sftp, port: sftpPort), knownHostsFile: fixture.appendingPathComponent("known hosts").path)
        // Typed text is echoed; only real output contains the evaluated arithmetic.
        let output = try terminalOutput(configuration.terminalLaunch(directory: folder.path),
                                        input: "cd .; echo \"[$PWD]\" TERM=$TERM tty-$(test -t 0 && echo yes) done-$((40+2)); exit\n")
        XCTAssertTrue(output.contains("[\(folder.path)]") || output.contains("[\(folder.resolvingSymlinksInPath().path)]"), output)
        XCTAssertTrue(output.contains("TERM=xterm-256color tty-yes done-42"), output)
    }

    func testTerminalStartsTheConfiguredShellLikeSudoSu() throws {
        let shell = try script("fake-sudo-terminal", "echo started >> $LOG\necho FAKE-SUDO-$((1+1))\nexec /bin/sh\n")
        var settings = SiteSettings(); settings.shell = shell.path
        let configuration = SSHConfiguration(site: site(.scp, port: scpPort, settings: settings), knownHostsFile: fixture.appendingPathComponent("known hosts").path)
        let output = try terminalOutput(configuration.terminalLaunch(directory: remote.path), input: "echo inside-$((2+3)); exit\n")
        XCTAssertTrue(output.contains("FAKE-SUDO-2"), output)
        XCTAssertTrue(output.contains("inside-5"), output)
        XCTAssertEqual(starts(shell.log), 1)
    }

    func testTerminalRefusesAnUnknownHostKey() throws {
        let empty = root.appendingPathComponent("empty known_hosts")
        try Data().write(to: empty)
        let output = try terminalOutput(SSHConfiguration(site: site(.sftp, port: sftpPort), knownHostsFile: empty.path).terminalLaunch(), input: "")
        XCTAssertTrue(output.contains("Host key verification failed"), output)
    }

    func testPortForwardReachesAServiceBehindTheServer() throws {
        // Forward a free local port to the SCP daemon as seen from the SFTP daemon; its SSH banner proves the path.
        let probe = socket(AF_INET, SOCK_STREAM, 0); defer { close(probe) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }
        let localPort = Int(UInt16(bigEndian: address.sin_port)); close(probe)
        let forward = PortForward(localPort: localPort, remoteHost: "127.0.0.1", remotePort: scpPort)
        let configuration = SSHConfiguration(site: site(.sftp, port: sftpPort), knownHostsFile: fixture.appendingPathComponent("known hosts").path)
        func start() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = try configuration.forwardArguments(forward)
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
        let tunnel = try start(); defer { if tunnel.isRunning { tunnel.terminate() } }
        var banner = ""
        for _ in 0..<50 where banner.isEmpty {
            let connection = socket(AF_INET, SOCK_STREAM, 0)
            var target = sockaddr_in(); target.sin_family = sa_family_t(AF_INET); target.sin_addr.s_addr = inet_addr("127.0.0.1"); target.sin_port = UInt16(localPort).bigEndian
            let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if connected == 0 {
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = read(connection, &buffer, buffer.count)
                if count > 0 { banner = String(decoding: buffer[0..<count], as: UTF8.self) }
            }
            close(connection)
            if banner.isEmpty { usleep(100_000) }
        }
        XCTAssertTrue(banner.hasPrefix("SSH-2.0-"), "banner: \(banner)")
        // A second forward on the same busy port fails at once instead of running uselessly.
        let duplicate = try start()
        duplicate.waitUntilExit()
        XCTAssertNotEqual(duplicate.terminationStatus, 0)
        XCTAssertTrue(tunnel.isRunning)
    }

    func testServerSideCopyOverSFTPAndSCPNeverReplaces() async throws {
        for (kind, port) in [(TransferProtocol.sftp, sftpPort), (.scp, scpPort)] {
            let base = remote.appendingPathComponent("copy-\(kind.shortTitle)")
            try FileManager.default.createDirectory(at: base.appendingPathComponent("folder/inner"), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: base.appendingPathComponent("folder/a.txt"))
            try Data("two".utf8).write(to: base.appendingPathComponent("folder/inner/b.txt"))
            try await connect(site(kind, port: port))
            let folder = try await client.realpath(base.path)
            try await client.copy(folder + "/folder/a.txt", to: folder + "/a copy.txt")
            try await client.copy(folder + "/folder", to: folder + "/folder copy")
            XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("a copy.txt"), encoding: .utf8), "one", kind.shortTitle)
            XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("folder copy/inner/b.txt"), encoding: .utf8), "two", kind.shortTitle)
            XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("folder/a.txt"), encoding: .utf8), "one", "the source stays")
            do { try await client.copy(folder + "/folder/a.txt", to: folder + "/a copy.txt"); XCTFail("Replaced an existing file over \(kind.shortTitle)") } catch ClientError.conflict {}
            do { try await client.copy(folder + "/folder", to: folder + "/folder/inside"); XCTFail("Copied a folder into itself") } catch ClientError.invalid {}
            await client.disconnect()
        }
    }

    /// Runs a syncscp-cli script against the fixture with its own site store; returns exit code and output.
    private func script(_ lines: [String], store: SiteStore) async -> (Int32, String) {
        var output: [String] = []
        let session = ScriptSession(store: store, localPath: local.path, askpass: nil, output: { output.append($0) })
        let code = await session.run(lines)
        return (code, output.joined(separator: "\n"))
    }

    func testScriptCommandsAgainstARealServer() async throws {
        let storeFolder = root.appendingPathComponent("cli-store")
        let store = try SiteStore(directory: storeFolder)
        try FileManager.default.removeItem(at: store.knownHostsFile)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("known hosts"), to: store.knownHostsFile)
        try FileManager.default.createDirectory(at: local.appendingPathComponent("tree/inner"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Data("beta".utf8).write(to: local.appendingPathComponent("b.log"))
        try Data("inner".utf8).write(to: local.appendingPathComponent("tree/inner/c.txt"))
        let key = fixture.appendingPathComponent("client_key").path
        let url = "sftp://\(NSUserName())@127.0.0.1:\(sftpPort)\(remote.path)"
        let (code, output) = await script([
            "option batch abort",
            "open \(url) -privatekey=\"\(key)\"",
            "put a.txt", "put *.log uploaded", "put tree",
            "mkdir logs", "put b.log logs/", "put b.log",
            "ls", "cd tree/inner", "pwd", "cd ..", "cd ..",
            "get a.txt \"got a.txt\"", "get tree \"got tree\"",
            "mv a.txt renamed.txt", "cp renamed.txt copy.txt", "chmod 600 copy.txt",
            "synchronize remote \"\(local.path)/tree\" mirror -preview",
            "synchronize remote \"\(local.path)/tree\" mirror",
            "rm *.log", "echo done", "exit",
        ], store: store)
        XCTAssertEqual(code, 0, output)
        func remoteText(_ path: String) -> String? { try? String(contentsOf: remote.appendingPathComponent(path), encoding: .utf8) }
        XCTAssertEqual(remoteText("renamed.txt"), "alpha"); XCTAssertNil(remoteText("a.txt"))
        XCTAssertEqual(remoteText("copy.txt"), "alpha")
        XCTAssertEqual(((try FileManager.default.attributesOfItem(atPath: remote.appendingPathComponent("copy.txt").path))[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
        XCTAssertEqual(remoteText("uploaded"), "beta", "put to a name that is not a folder writes that file")
        XCTAssertEqual(remoteText("tree/inner/c.txt"), "inner")
        XCTAssertEqual(remoteText("mirror/inner/c.txt"), "inner", "synchronize remote copied the tree")
        XCTAssertNil(remoteText("b.log"), "rm with a mask")
        XCTAssertEqual(remoteText("logs/b.log"), "beta", "put into an existing folder")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("got a.txt"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("got tree/inner/c.txt"), encoding: .utf8), "inner")
        XCTAssertTrue(output.contains("/tree/inner"), output)
        XCTAssertTrue(output.contains("Create remote folder: inner") && output.contains("previewed"), output)
        XCTAssertTrue(output.hasSuffix("done"), output)

        // A failing command stops the script (batch abort) with exit code 1; with continue, later commands run.
        let (failed, failure) = await script(["open \(url) -privatekey=\"\(key)\"", "get missing.txt", "echo after"], store: store)
        XCTAssertEqual(failed, 1); XCTAssertFalse(failure.contains("after")); XCTAssertTrue(failure.contains("Error:"), failure)
        let (continued, more) = await script(["option batch continue", "open \(url) -privatekey=\"\(key)\"", "get missing.txt", "echo after"], store: store)
        XCTAssertEqual(continued, 1); XCTAssertTrue(more.contains("after"), more)
    }

    func testScriptHostKeyMustBeTrustedOrConfirmed() async throws {
        let store = try SiteStore(directory: root.appendingPathComponent("cli-untrusted"))
        let key = fixture.appendingPathComponent("client_key").path
        let url = "sftp://\(NSUserName())@127.0.0.1:\(sftpPort)/"
        let (refused, message) = await script(["open \(url) -privatekey=\"\(key)\""], store: store)
        XCTAssertEqual(refused, 1)
        let fingerprint = try XCTUnwrap(message.range(of: #"SHA256:[A-Za-z0-9+/]+"#, options: .regularExpression).map { String(message[$0]) }, message)
        let (wrong, mismatch) = await script(["open \(url) -privatekey=\"\(key)\" -hostkey=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"], store: store)
        XCTAssertEqual(wrong, 1); XCTAssertTrue(mismatch.contains("mismatch"), mismatch)
        let (accepted, trusted) = await script(["open \(url) -privatekey=\"\(key)\" -hostkey=\(fingerprint)", "pwd"], store: store)
        XCTAssertEqual(accepted, 0, trusted)
        XCTAssertTrue(try String(contentsOf: store.knownHostsFile, encoding: .utf8).contains("[127.0.0.1]:\(sftpPort)"))
        let (again, _) = await script(["open \(url) -privatekey=\"\(key)\"", "pwd"], store: store)
        XCTAssertEqual(again, 0, "the confirmed key is remembered")
    }
}
