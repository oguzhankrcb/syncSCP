// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Darwin
@testable import WinSCPCore

/// These tests speak binary SFTP to Apple's real OpenSSH sftp-server.
/// Every file is isolated beneath a disposable test directory; no account or network is required.
final class SFTPIntegrationTests: XCTestCase {
    private var root: URL!
    private var remote: URL!
    private var local: URL!
    private var client: SFTPClient!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("winscp-tests-" + UUID().uuidString)
        remote = root.appendingPathComponent("remote", isDirectory: true)
        local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        client = SFTPClient()
        _ = try await client.connectLocalServer(root: remote.path)
    }

    override func tearDown() async throws {
        await client?.disconnect()
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testRealpathAndListingPreserveUnicodeSpacesQuotesAndNewlines() async throws {
        let names = ["two words.txt", "İstanbul 日本語.txt", "quote'\"$`;.txt", "line\nbreak.txt", ".hidden"]
        for name in names { try Data(name.utf8).write(to: remote.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("directory"), withIntermediateDirectories: false)
        let path = try await client.realpath(".")
        let resolved = try XCTUnwrap(realpath(remote.path, nil))
        defer { free(resolved) }
        XCTAssertEqual(path, String(cString: resolved))
        let entries = try await client.list(path)
        XCTAssertEqual(Set(entries.map(\.name)), Set(names + ["directory"]))
        XCTAssertEqual(entries.first?.name, "directory")
        XCTAssertTrue(entries.first?.isDirectory == true)
    }

    func testBinaryRoundTripAndZeroByteFile() async throws {
        for size in [0, 1, 65536, 1_048_731] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let source = local.appendingPathComponent("source-\(size)")
            let destination = local.appendingPathComponent("download-\(size)")
            let path = remote.appendingPathComponent("file-\(size)").path
            try data.write(to: source)
            try await client.upload(local: source, remote: path)
            try await client.download(remote: path, local: destination)
            XCTAssertEqual(try Data(contentsOf: destination), data)
            let attributes = try await client.stat(path)
            XCTAssertEqual(attributes.size, UInt64(size))
        }
    }

    func testNoClobberAndExplicitAtomicReplacement() async throws {
        let source = local.appendingPathComponent("source")
        let target = remote.appendingPathComponent("existing")
        try Data("new".utf8).write(to: source)
        try Data("original".utf8).write(to: target)
        do { try await client.upload(local: source, remote: target.path); XCTFail("Unapproved overwrite succeeded") }
        catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "original")
        try await client.upload(local: source, remote: target.path, replace: true)
        XCTAssertEqual(try String(contentsOf: target), "new")
        let download = local.appendingPathComponent("existing")
        try Data("keep me".utf8).write(to: download)
        do { try await client.download(remote: target.path, local: download); XCTFail("Unapproved download overwrite succeeded") }
        catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: download), "keep me")
        try await client.download(remote: target.path, local: download, replace: true)
        XCTAssertEqual(try String(contentsOf: download), "new")
    }

    func testCancelledUploadPreservesOriginalAndCleansPartial() async throws {
        let source = local.appendingPathComponent("large")
        let target = remote.appendingPathComponent("existing")
        try Data(repeating: 42, count: 1024 * 1024).write(to: source)
        try Data("original".utf8).write(to: target)
        let token = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path, replace: true, token: token) { done, _ in
                if done >= 65536 { token.cancel() }
            }
            XCTFail("Cancelled upload succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: target), "original")
        let listing = try await client.list(remote.path)
        XCTAssertEqual(listing.map(\.name), ["existing"])
    }

    func testCancelledDownloadPreservesOriginalAndCleansPartial() async throws {
        let source = remote.appendingPathComponent("large")
        let target = local.appendingPathComponent("existing")
        try Data(repeating: 84, count: 1024 * 1024).write(to: source)
        try Data("original".utf8).write(to: target)
        let token = CancellationToken()
        do {
            try await client.download(remote: source.path, local: target, replace: true, token: token) { done, _ in
                if done >= 65536 { token.cancel() }
            }
            XCTFail("Cancelled download succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: target), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), ["existing"])
    }

    func testMkdirRenamePermissionsAndRecursiveDelete() async throws {
        let directory = remote.appendingPathComponent("new folder")
        try await client.mkdir(directory.path)
        let file = directory.appendingPathComponent("old")
        try Data("hello".utf8).write(to: file)
        let renamed = directory.appendingPathComponent("new")
        try await client.rename(file.path, to: renamed.path)
        try await client.chmod(renamed.path, mode: 0o640)
        let attributes = try await client.stat(renamed.path)
        XCTAssertEqual(attributes.permissions & 0o777, 0o640)
        try await client.remove(directory.path, recursive: true)
        let exists = try await client.exists(directory.path)
        XCTAssertFalse(exists)
    }

    func testSymlinkDeleteDoesNotFollowTarget() async throws {
        let directory = remote.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("keep")
        try Data("important".utf8).write(to: file)
        let link = remote.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let info = try await client.stat(link.path)
        XCTAssertTrue(info.isSymbolicLink)
        try await client.remove(link.path, recursive: true)
        XCTAssertEqual(try String(contentsOf: file), "important")
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testSymlinkTransfersAreRejected() async throws {
        let target = remote.appendingPathComponent("target")
        try Data("secret".utf8).write(to: target)
        let link = remote.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do { try await client.download(remote: link.path, local: local.appendingPathComponent("out")); XCTFail("Followed remote symlink") }
        catch ClientError.unsupported { }
        do { try await client.upload(local: link, remote: remote.appendingPathComponent("out").path); XCTFail("Followed local symlink") }
        catch ClientError.unsupported { }
    }

    func testMissingFilesSurfaceServerErrorAndSessionRemainsUsable() async throws {
        do { _ = try await client.stat(remote.appendingPathComponent("missing").path); XCTFail("Missing file succeeded") }
        catch ClientError.server(let code, _) { XCTAssertEqual(code, 2) }
        let listing = try await client.list(remote.path)
        XCTAssertTrue(listing.isEmpty)
    }

    func testRootDeletionIsRejected() async throws {
        for path in ["/", ".", "..", "/tmp/..", "/tmp/."] {
            do { try await client.remove(path, recursive: true); XCTFail("Unsafe deletion was allowed") }
            catch ClientError.invalid { }
        }
    }

    func testUploadReplacementPreservesPermissions() async throws {
        let source = local.appendingPathComponent("source")
        let target = remote.appendingPathComponent("executable")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: target.path)
        try Data("new content".utf8).write(to: source)
        try await client.upload(local: source, remote: target.path, replace: true)
        let info = try await client.stat(target.path)
        XCTAssertEqual(info.permissions & 0o777, 0o750)
    }

    func testReviewedDestinationChangeBeforeUploadIsRejected() async throws {
        let source = local.appendingPathComponent("source")
        let target = remote.appendingPathComponent("target")
        try Data("original".utf8).write(to: target)
        let snapshot = try await client.stat(target.path)
        try Data("external change".utf8).write(to: target)
        try Data("my edit".utf8).write(to: source)
        do {
            try await client.upload(local: source, remote: target.path, replace: true, expectedDestination: snapshot)
            XCTFail("Overwrote a changed destination")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "external change")
    }

    func testReviewedDestinationChangeDuringUploadIsRejectedAndCleaned() async throws {
        let source = local.appendingPathComponent("source")
        let target = remote.appendingPathComponent("target")
        try Data("original".utf8).write(to: target)
        let snapshot = try await client.stat(target.path)
        try Data(repeating: 42, count: 256 * 1024).write(to: source)
        let changed = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path, replace: true, expectedDestination: snapshot) { done, _ in
                if done >= 65536, !changed.isCancelled {
                    changed.cancel()
                    try? Data("external change".utf8).write(to: target)
                }
            }
            XCTFail("Overwrote a destination changed during transfer")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "external change")
        let entries = try await client.list(remote.path)
        XCTAssertEqual(entries.map(\.name), ["target"])
    }

    func testLocalSourceChangeDuringUploadIsRejectedAndCleaned() async throws {
        let source = local.appendingPathComponent("source")
        let target = remote.appendingPathComponent("target")
        try Data(repeating: 42, count: 256 * 1024).write(to: source)
        let changed = CancellationToken()
        do {
            try await client.upload(local: source, remote: target.path) { done, _ in
                if done >= 65536, !changed.isCancelled {
                    changed.cancel()
                    try? Data("local change".utf8).write(to: source)
                }
            }
            XCTFail("Committed a transfer with a changed source")
        } catch ClientError.conflict { }
        let entries = try await client.list(remote.path)
        XCTAssertTrue(entries.isEmpty)
    }

    func testLongDestinationNameDoesNotOverflowTemporaryFilename() async throws {
        let name = String(repeating: "a", count: 245) + ".txt"
        let source = local.appendingPathComponent("source")
        let target = remote.appendingPathComponent(name)
        try Data("long filename".utf8).write(to: source)
        try await client.upload(local: source, remote: target.path)
        XCTAssertEqual(try String(contentsOf: target), "long filename")
    }
}
