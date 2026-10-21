// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Darwin
@testable import WinSCPCore

/// Every transfer uses scp -f/-t on a real SSH channel, never the SFTP subsystem.
final class SCPIntegrationTests: XCTestCase {
    private var root: URL!, local: URL!, remote: URL!, fixture: URL!
    private var site: Site!, configuration: SSHConfiguration!
    private var client: RemoteSession!
    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["WINSCP_TEST_SSH_FIXTURE"], let text = environment["WINSCP_TEST_SCP_PORT"], let port = Int(text) else {
            throw XCTSkip("Run scripts/test-ssh.sh for the real SCP/SSH fixture.")
        }
        fixture = URL(fileURLWithPath: directory)
        root = fixture.appendingPathComponent("scp-" + UUID().uuidString)
        local = root.appendingPathComponent("local"); remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        site = Site(host: "127.0.0.1", port: port, username: NSUserName(), privateKey: fixture.appendingPathComponent("client_key").path, transferProtocol: .scp)
        configuration = SSHConfiguration(site: site, knownHostsFile: fixture.appendingPathComponent("known hosts").path)
        client = RemoteSession()
        _ = try await client.connect(site: site, password: "", sshConfiguration: configuration)
    }
    override func tearDown() async throws {
        await client?.disconnect()
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    func testBinaryAndEmptyRoundTripsAndPermissions() async throws {
        for size in [0, 1, 65536, 1_048_731] {
            let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target-\(size)"), out = local.appendingPathComponent("out-\(size)")
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try data.write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1700000000)], ofItemAtPath: source.path)
            try await client.upload(local: source, remote: target.path)
            try await client.download(remote: target.path, local: out)
            XCTAssertEqual(try Data(contentsOf: out), data)
            let info = try await client.stat(target.path)
            XCTAssertEqual(info.permissions & 0o777, 0o640); XCTAssertEqual(info.size, UInt64(size))
            XCTAssertEqual(info.modified, Date(timeIntervalSince1970: 1700000000))
        }
    }
    func testQuotedNamesListingAndFileOperationsNeverExecuteShellFragments() async throws {
        let names = ["İstanbul 日本語.txt", "two words.txt", "quote'\"$`;.txt", "$(touch injected)", "*?[abc].txt", "-leading", ".hidden", "line\nbreak"]
        let source = local.appendingPathComponent("source"); try Data("test".utf8).write(to: source)
        for name in names {
            if name.contains("\n") { try Data().write(to: remote.appendingPathComponent(name)) }
            else {
                try await client.upload(local: source, remote: remote.appendingPathComponent(name).path)
                let out = local.appendingPathComponent(UUID().uuidString)
                try await client.download(remote: remote.appendingPathComponent(name).path, local: out)
                XCTAssertEqual(try String(contentsOf: out), "test")
            }
        }
        let entries = try await client.list(remote.path)
        XCTAssertEqual(Set(entries.map(\.name)), Set(names))
        let folder = remote.appendingPathComponent("folder ' ; $(touch injected)")
        try await client.mkdir(folder.path)
        let renamed = folder.appendingPathComponent("renamed")
        try await client.rename(remote.appendingPathComponent(names[0]).path, to: renamed.path)
        try await client.chmod(renamed.path, mode: 0o750)
        let info = try await client.stat(renamed.path); XCTAssertEqual(info.permissions & 0o777, 0o750)
        try await client.remove(folder.path, recursive: true)
        let exists = try await client.exists(folder.path); XCTAssertFalse(exists)
        let canonical = try await client.realpath(remote.path)
        let resolved = try XCTUnwrap(realpath(remote.path, nil))
        defer { free(resolved) }
        XCTAssertEqual(canonical, String(cString: resolved))
    }
    func testNoClobberApprovedReplacementAndConcurrentDestination() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target"), out = local.appendingPathComponent("out")
        try Data(repeating: 42, count: 256 * 1024).write(to: source)
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: target.path)
        do { try await client.upload(local: source, remote: target.path); XCTFail("Overwrote without approval") } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "original")
        try await client.upload(local: source, remote: target.path, replace: true)
        let info = try await client.stat(target.path); XCTAssertEqual(info.permissions & 0o777, 0o750)
        try Data("local original".utf8).write(to: out)
        do { try await client.download(remote: target.path, local: out); XCTFail("Overwrote local destination") } catch ClientError.conflict { }
        try await client.download(remote: target.path, local: out, replace: true)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: source))
        try FileManager.default.removeItem(at: target)
        let captured = target
        let once = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path) { done, _ in
                if done > 0, !once.isCancelled { once.cancel(); try? Data("arrived concurrently".utf8).write(to: captured) }
            }
            XCTFail("Overwrote concurrent file")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "arrived concurrently")
        let entries = try await client.list(remote.path); XCTAssertEqual(entries.map(\.name), ["target"])
    }
    func testCancellationPreservesDestinationAndCleansBothSides() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target"), out = local.appendingPathComponent("out")
        try Data(repeating: 84, count: 2 * 1024 * 1024).write(to: source)
        try Data("original".utf8).write(to: target)
        let uploadToken = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path, replace: true, token: uploadToken) { done, _ in if done >= 65536 { uploadToken.cancel() } }
            XCTFail("Cancelled upload succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: target), "original")
        let entries = try await client.list(remote.path); XCTAssertEqual(entries.map(\.name), ["target"])
        try await client.upload(local: source, remote: target.path, replace: true)
        try Data("local original".utf8).write(to: out)
        let downloadToken = CancellationToken()
        do {
            try await client.download(remote: target.path, local: out, replace: true, token: downloadToken) { done, _ in if done >= 65536 { downloadToken.cancel() } }
            XCTFail("Cancelled download succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: out), "local original")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: local.path)), Set(["source", "out"]))
    }
    func testReviewedConflictsAndChangedLocalSource() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target")
        try Data(repeating: 42, count: 256 * 1024).write(to: source)
        try Data("original".utf8).write(to: target)
        let snapshot = try await client.stat(target.path)
        let capturedTarget = target, capturedSource = source
        let changed = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path, replace: true, expectedDestination: snapshot) { done, _ in
                if done > 0, !changed.isCancelled { changed.cancel(); try? Data("external change".utf8).write(to: capturedTarget) }
            }
            XCTFail("Overwrote reviewed destination change")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "external change")
        do { try await client.upload(local: source, remote: target.path, replace: true, expectedDestination: snapshot); XCTFail("Overwrote prior change") } catch ClientError.conflict { }
        let changedSource = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path, replace: true) { done, _ in
                if done > 0, !changedSource.isCancelled { changedSource.cancel(); try? Data("changed source".utf8).write(to: capturedSource) }
            }
            XCTFail("Uploaded changed local source")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "external change")
        let entries = try await client.list(remote.path); XCTAssertEqual(entries.map(\.name), ["target"])
    }
    func testSymlinksLineBreaksAndRootDeletionPolicy() async throws {
        let folder = remote.appendingPathComponent("target"), link = remote.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let keep = folder.appendingPathComponent("keep"); try Data("keep".utf8).write(to: keep)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let info = try await client.stat(link.path); XCTAssertTrue(info.isSymbolicLink)
        let followed = try await client.stat(link.path, followLinks: true); XCTAssertTrue(followed.isDirectory)
        do { try await client.download(remote: link.path, local: local.appendingPathComponent("out")); XCTFail("Followed symlink") } catch ClientError.unsupported { }
        do { try await client.upload(local: link, remote: remote.appendingPathComponent("out").path); XCTFail("Followed local symlink") } catch ClientError.unsupported { }
        try await client.remove(link.path + "/", recursive: true)
        XCTAssertEqual(try String(contentsOf: keep), "keep")
        for path in ["/", ".", "..", "/tmp/..", "/tmp/.", remote.path + "/./", remote.path + "/../", "///"] {
            do { try await client.remove(path, recursive: true); XCTFail("Unsafe root deletion") } catch ClientError.invalid { }
        }
        do { try await client.upload(local: keep, remote: remote.appendingPathComponent("line\nbreak").path); XCTFail("SCP accepted newline") } catch ClientError.unsupported { }
        do { _ = try await client.stat(remote.appendingPathComponent("missing").path); XCTFail("Missing file succeeded") } catch ClientError.remote(_, 44, _) { }
        let entries = try await client.list(remote.path); XCTAssertEqual(entries.map(\.name), ["target"])
    }
    func testLongNamesAndConcurrentDirectoryAreHandledWithoutClobbering() async throws {
        let source = local.appendingPathComponent("source")
        try Data(repeating: 42, count: 256 * 1024).write(to: source)
        let long = remote.appendingPathComponent(String(repeating: "a", count: 245) + ".txt")
        try await client.upload(local: source, remote: long.path)
        let out = local.appendingPathComponent("long download")
        try await client.download(remote: long.path, local: out)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: source))
        let destination = remote.appendingPathComponent("concurrent directory")
        let once = CancellationToken()
        do {
            try await client.upload(local: source, remote: destination.path) { done, _ in
                if done > 0, !once.isCancelled {
                    once.cancel(); try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                }
            }
            XCTFail("Published a file inside an unapproved directory")
        } catch ClientError.conflict { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        let listing = try await client.list(remote.path)
        XCTAssertEqual(listing.count, 2)
    }
    func testMasterLifetimeEndsWhenOwnerInputCloses() async throws {
        let directory = URL(fileURLWithPath: "/tmp/winscp-lifetime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("s").path
        let master = try SSHCommandChannel(arguments: SCPSSHSession.masterArguments(configuration, socket: socket))
        defer { master.close() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline, master.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(master.isRunning); XCTAssertTrue(FileManager.default.fileExists(atPath: socket))
        let timeout = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { timeout.cancel() }
        // This is also what happens to the pipe when the owning app crashes.
        master.finishInput()
        XCTAssertEqual(try master.finish(token: timeout), Data())
        XCTAssertFalse(master.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }
    func testHostTrustAndControlSocketCannotFallBackToNewAuthentication() async throws {
        let untrusted = root.appendingPathComponent("untrusted hosts"); try Data().write(to: untrusted)
        let other = SCPClient()
        do { _ = try await other.connect(SSHConfiguration(site: site, knownHostsFile: untrusted.path)); XCTFail("Untrusted host accepted") } catch ClientError.connection { }
        await other.disconnect()
        let session = try SCPSSHSession(configuration)
        defer { session.close() }
        let cancellation = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { cancellation.cancel() }
        let started = Date()
        do { _ = try session.run("sleep 10", token: cancellation); XCTFail("Stalled command ignored cancellation") } catch ClientError.cancelled { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(try session.run("printf usable"), Data("usable".utf8))
        try FileManager.default.removeItem(atPath: session.controlPath)
        // The already-authenticated persistent shell may continue; no new channel may authenticate.
        XCTAssertEqual(try session.run("printf existing"), Data("existing".utf8))
        let transfer = try session.open("printf unexpected")
        defer { transfer.close() }
        do { _ = try transfer.finish(); XCTFail("Opened a new channel after control socket loss") } catch ClientError.connection { }
        let stop = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { stop.cancel() }
        do { _ = try session.run("sleep 10", token: stop); XCTFail("Stalled command ignored cancellation") } catch ClientError.cancelled { }
        do { _ = try session.run("printf unexpected"); XCTFail("Reauthenticated after control socket loss") } catch ClientError.connection { }
    }
}
