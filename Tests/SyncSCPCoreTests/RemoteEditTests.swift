// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

/// External editing against the real disposable OpenSSH/SFTP daemon from scripts/test-ssh.sh.
final class RemoteEditTests: XCTestCase {
    private var root: URL!, remote: URL!, edits: URL!
    private var client: RemoteSession!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SYNCSCP_TEST_SSH_FIXTURE"], let port = environment["SYNCSCP_TEST_SSH_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Run scripts/test-ssh.sh for the real SSH fixture.")
        }
        let fixture = URL(fileURLWithPath: directory)
        root = fixture.appendingPathComponent("edit-" + UUID().uuidString)
        remote = root.appendingPathComponent("remote"); edits = root.appendingPathComponent("edits")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let site = Site(host: "127.0.0.1", port: port, username: NSUserName(), privateKey: fixture.appendingPathComponent("client_key").path, transferProtocol: .sftp)
        client = RemoteSession()
        _ = try await client.connect(site: site, password: "", sshConfiguration: SSHConfiguration(site: site, knownHostsFile: fixture.appendingPathComponent("known hosts").path))
    }
    override func tearDown() async throws {
        await client?.disconnect()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func open(_ name: String, _ text: String) async throws -> RemoteEdit {
        try Data(text.utf8).write(to: remote.appendingPathComponent(name))
        let entry = try await client.stat(remote.appendingPathComponent(name).path)
        return try await RemoteEdit(client: client, entry: entry, directory: edits)
    }
    private func server(_ name: String) throws -> String { try String(contentsOf: remote.appendingPathComponent(name)) }

    func testSavesUploadOnlyRealChangesForInPlaceAndAtomicSaves() async throws {
        let edit = try await open("config.yml", "version: 1\n")
        let local = edit.localFile
        XCTAssertEqual(try String(contentsOf: local), "version: 1\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: local.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var result = try await edit.syncIfChanged(); XCTAssertEqual(result, .unchanged)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: local.path)
        result = try await edit.syncIfChanged(); XCTAssertEqual(result, .unchanged, "a touch without new content uploads nothing")

        try Data("version: 2\n".utf8).write(to: local) // in-place save
        result = try await edit.syncIfChanged()
        guard case .uploaded = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try server("config.yml"), "version: 2\n")
        result = try await edit.syncIfChanged(); XCTAssertEqual(result, .unchanged)

        let scratch = local.deletingLastPathComponent().appendingPathComponent(".config.yml.swp")
        try Data("version: 3\n".utf8).write(to: scratch) // atomic replace-on-save
        _ = try FileManager.default.replaceItemAt(local, withItemAt: scratch)
        result = try await edit.syncIfChanged()
        guard case .uploaded = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try server("config.yml"), "version: 3\n")
        let unsynced = await edit.hasUnsyncedChanges; XCTAssertFalse(unsynced)

        try FileManager.default.removeItem(at: local)
        result = try await edit.syncIfChanged(); XCTAssertEqual(result, .missing)
        await edit.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
    }

    func testServerChangesAreNeverOverwrittenWithoutConsent() async throws {
        let edit = try await open("index.php", "<?php echo 'original';\n")
        let local = edit.localFile
        try Data("<?php echo 'changed by a colleague';\n".utf8).write(to: remote.appendingPathComponent("index.php"))
        try Data("<?php echo 'my edit';\n".utf8).write(to: local)
        var result = try await edit.syncIfChanged()
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(try server("index.php"), "<?php echo 'changed by a colleague';\n")
        let pending = await edit.hasUnsyncedChanges; XCTAssertTrue(pending)
        _ = try await edit.overwrite()
        XCTAssertEqual(try server("index.php"), "<?php echo 'my edit';\n")
        result = try await edit.syncIfChanged(); XCTAssertEqual(result, .unchanged)
        try Data("<?php echo 'next edit';\n".utf8).write(to: local)
        result = try await edit.syncIfChanged()
        guard case .uploaded = result else { return XCTFail("after overwrite, the new server version is the baseline: \(result)") }
    }

    /// New ▸ File uploads an empty file with replace: false, then opens it for editing.
    func testNewFileIsCreatedEmptyAndNeverReplacesAnExistingFile() async throws {
        let empty = root.appendingPathComponent("empty"); try Data().write(to: empty)
        let target = remote.appendingPathComponent("notes.md")
        try await client.upload(local: empty, remote: target.path, replace: false)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        try Data("existing content".utf8).write(to: target)
        do { try await client.upload(local: empty, remote: target.path, replace: false); XCTFail("New file replaced an existing file") }
        catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "existing content")
        let edit = try await RemoteEdit(client: client, entry: try await client.stat(target.path), directory: edits)
        XCTAssertEqual(try String(contentsOf: edit.localFile), "existing content")
    }

    func testChangeMonitorSeesInPlaceAndAtomicSaves() async throws {
        let folder = root.appendingPathComponent("monitor")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data("one".utf8).write(to: file)
        let counter = Counter()
        let monitor = FileChangeMonitor(file: file, interval: 0.1) { counter.increment() }
        defer { monitor.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(counter.value, 0, "no change, no callback")
        let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: Data("two".utf8)); try handle.close()
        try await wait(for: 1, counter)
        let replacement = folder.appendingPathComponent("tmp")
        try Data("three".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        try await wait(for: 2, counter)
    }

    private func wait(for count: Int, _ counter: Counter) async throws {
        for _ in 0..<50 where counter.value < count { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(counter.value, count)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
