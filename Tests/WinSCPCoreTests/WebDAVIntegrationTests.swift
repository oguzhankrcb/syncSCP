// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

/// Real WebDAV, including RFC conditions, against independent WsgiDAV over HTTP and TLS.
final class WebDAVIntegrationTests: XCTestCase {
    private var fixture: URL!, remote: URL!, local: URL!
    private var remotePath = ""
    private var httpPort = 0, httpsPort = 0
    private var client: RemoteSession!
    override func setUp() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WINSCP_TEST_WEBDAV_FIXTURE"] else {
            throw XCTSkip("Run scripts/test-webdav.sh for disposable WebDAV/HTTPS servers.")
        }
        fixture = URL(fileURLWithPath: directory)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("ready.json"))) as? [String: Any])
        httpPort = try XCTUnwrap(config["http"] as? Int); httpsPort = try XCTUnwrap(config["https"] as? Int)
        let id = UUID().uuidString
        remote = fixture.appendingPathComponent("remote/" + id); local = fixture.appendingPathComponent("local/" + id)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        remotePath = "/dav/" + id
        client = RemoteSession()
        _ = try await client.connect(site: site(), password: "test-only-password")
    }
    override func tearDown() async throws {
        await client?.disconnect()
        if let remote { try? FileManager.default.removeItem(at: remote) }
        if let local { try? FileManager.default.removeItem(at: local) }
    }
    private func site(tls: Bool = false, trusted: Bool = true, host: String = "localhost", path: String? = nil) -> Site {
        Site(host: host, port: tls ? httpsPort : httpPort, username: "winscp", remotePath: path ?? remotePath,
             transferProtocol: tls ? .webdavs : .webdav, certificateAuthorityFile: tls && trusted ? fixture.appendingPathComponent("ca.pem").path : "")
    }
    private func assertNoPartials(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: remote.path).contains { $0.hasPrefix(".winscp-") }, file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: local.path).contains { $0.hasPrefix(".winscp-") }, file: file, line: line)
    }
    func testHTTPAndHTTPSBinaryAndEmptyRoundTrips() async throws {
        for tls in [false, true] {
            _ = try await client.connect(site: site(tls: tls), password: "test-only-password")
            for size in [0, 1, 65536, 1_048_731] {
                let name = "file-\(tls)-\(size)", source = local.appendingPathComponent("source")
                let out = local.appendingPathComponent(name)
                let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
                try data.write(to: source)
                try await client.upload(local: source, remote: RemotePath.join(remotePath, name))
                try await client.download(remote: RemotePath.join(remotePath, name), local: out)
                XCTAssertEqual(try Data(contentsOf: out), data)
                let info = try await client.stat(RemotePath.join(remotePath, name))
                XCTAssertEqual(info.size, UInt64(size)); XCTAssertTrue(info.isRegularFile)
                XCTAssertNotNil(DAVETag.strong(info.versionTag)); XCTAssertFalse(info.permissionsKnown); XCTAssertEqual(info.rights, "—")
            }
        }
        try assertNoPartials()
    }
    func testUnicodeURLCharactersHiddenNamesAndFileOperations() async throws {
        let names = ["two words.txt", "İstanbul 日本語.txt", "quote'\"$`.txt", "100% #&+.txt", "-leading", ".hidden", "literal%2F.txt"]
        let source = local.appendingPathComponent("source"); try Data("WebDAV".utf8).write(to: source)
        for name in names {
            try await client.upload(local: source, remote: RemotePath.join(remotePath, name))
            let out = local.appendingPathComponent(UUID().uuidString)
            try await client.download(remote: RemotePath.join(remotePath, name), local: out)
            XCTAssertEqual(try String(contentsOf: out), "WebDAV")
        }
        let entries = try await client.list(remotePath)
        XCTAssertEqual(Set(entries.map(\.name)), Set(names))
        let directory = RemotePath.join(remotePath, "new collection")
        try await client.mkdir(directory)
        try await client.rename(RemotePath.join(remotePath, names[0]), to: RemotePath.join(directory, "renamed.txt"))
        do { try await client.remove(directory); XCTFail("Removed nonempty collection without recursion") } catch ClientError.conflict { }
        try await client.remove(directory, recursive: true)
        let exists = try await client.exists(directory); XCTAssertFalse(exists)
        do { try await client.chmod(RemotePath.join(remotePath, names[1]), mode: 0o644); XCTFail("Invented POSIX chmod support") } catch ClientError.unsupported { }
        let canonical = try await client.realpath(remotePath + "/./"); XCTAssertEqual(canonical, remotePath)
        try assertNoPartials()
    }
    func testNoClobberApprovedReplacementAndConcurrentDestination() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target"), out = local.appendingPathComponent("out")
        let path = RemotePath.join(remotePath, "target")
        try Data(repeating: 42, count: 256 * 1024).write(to: source); try Data("original".utf8).write(to: target)
        do { try await client.upload(local: source, remote: path); XCTFail("Overwrote without approval") } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "original")
        try await client.upload(local: source, remote: path, replace: true)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
        try Data("local original".utf8).write(to: out)
        do { try await client.download(remote: path, local: out); XCTFail("Overwrote local destination") } catch ClientError.conflict { }
        try await client.download(remote: path, local: out, replace: true)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: source))
        try FileManager.default.removeItem(at: target)
        let once = CancellationToken()
        do {
            try await client.upload(local: source, remote: path) { done, _ in
                if done >= 65536, !once.isCancelled { once.cancel(); try? Data("concurrent file".utf8).write(to: target) }
            }
            XCTFail("Overwrote a concurrent destination")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "concurrent file")
        try assertNoPartials()
    }
    func testDestinationETagConditionProtectsAtTheMoveBoundary() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("race-at-move.txt")
        let path = RemotePath.join(remotePath, target.lastPathComponent)
        try Data("original".utf8).write(to: target); try Data("my edited file".utf8).write(to: source)
        let reviewed = try await client.stat(path)
        do {
            try await client.upload(local: source, remote: path, replace: true, expectedDestination: reviewed)
            XCTFail("Ignored destination change after the final stat check")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "External change at the MOVE boundary; preserve this version.")
        let condition = try String(contentsOf: fixture.appendingPathComponent("race-condition-seen"))
        XCTAssertTrue(condition.contains(try XCTUnwrap(reviewed.versionTag)))
        XCTAssertTrue(condition.contains(path))
        try assertNoPartials()
    }
    func testReviewedChangesBeforeAndDuringUploadAreProtected() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target"), path = RemotePath.join(remotePath, "target")
        try Data(repeating: 42, count: 512 * 1024).write(to: source); try Data("original".utf8).write(to: target)
        let reviewed = try await client.stat(path)
        let once = CancellationToken()
        do {
            try await client.upload(local: source, remote: path, replace: true, expectedDestination: reviewed) { done, _ in
                if done >= 65536, !once.isCancelled { once.cancel(); try? Data("external version".utf8).write(to: target) }
            }
            XCTFail("Overwrote reviewed change")
        } catch ClientError.conflict { }
        do { try await client.upload(local: source, remote: path, replace: true, expectedDestination: reviewed); XCTFail("Ignored old review") } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "external version")
        try assertNoPartials()
    }
    func testCancellationPreservesOldFilesAndCleansTemporaryPaths() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target"), out = local.appendingPathComponent("out")
        let path = RemotePath.join(remotePath, "target")
        try Data(repeating: 42, count: 8 * 1024 * 1024).write(to: source); try Data("old remote".utf8).write(to: target)
        let upload = CancellationToken()
        do {
            try await client.upload(local: source, remote: path, replace: true, token: upload) { done, _ in if done >= 65536 { upload.cancel() } }
            XCTFail("Cancelled upload succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: target), "old remote")
        try assertNoPartials()
        try await client.upload(local: source, remote: path, replace: true)
        try Data("old local".utf8).write(to: out)
        let download = CancellationToken()
        do {
            try await client.download(remote: path, local: out, replace: true, token: download) { done, _ in if done >= 65536 { download.cancel() } }
            XCTFail("Cancelled download succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: out), "old local")
        try assertNoPartials()
    }
    func testTLSCertificatesHostnameMismatchDowngradeAndBadCredentials() async throws {
        let other = RemoteSession()
        do { _ = try await other.connect(site: site(), password: "wrong"); XCTFail("Wrong password accepted") } catch ClientError.remote(_, 401, _) { }
        do { _ = try await other.connect(site: site(tls: true, trusted: false), password: "test-only-password"); XCTFail("Untrusted CA accepted") } catch ClientError.connection { }
        do { _ = try await other.connect(site: site(tls: true, host: "127.0.0.1"), password: "test-only-password"); XCTFail("Hostname mismatch accepted") } catch ClientError.connection { }
        var downgrade = site(tls: true); downgrade.port = httpPort
        do { _ = try await other.connect(site: downgrade, password: "test-only-password"); XCTFail("Fell back to plain HTTP") } catch ClientError.connection { }
        _ = try await other.connect(site: site(tls: true), password: "test-only-password")
        await other.disconnect()
    }
    func testReadOnlyAndMultiStatusFailuresDoNotBecomeSuccess() async throws {
        let source = local.appendingPathComponent("source"); try Data("test".utf8).write(to: source)
        let other = RemoteSession()
        let readOnlyPath = remotePath.replacingOccurrences(of: "/dav/", with: "/readonly/")
        _ = try await other.connect(site: site(path: readOnlyPath), password: "test-only-password")
        do { try await other.upload(local: source, remote: RemotePath.join(readOnlyPath, "denied")); XCTFail("Wrote to readonly provider") } catch ClientError.remote(_, 403, _) { }
        await other.disconnect()
        let folder = remote.appendingPathComponent("partial-delete")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        do { try await client.remove(RemotePath.join(remotePath, "partial-delete"), recursive: true); XCTFail("Treated 207 as successful delete") } catch ClientError.remote(_, 207, _) { }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("keep.txt")), "keep")
        try assertNoPartials()
    }
    func testRedirectsCannotLeakCredentialsOrReplaceLocalFiles() async throws {
        let target = remote.appendingPathComponent("redirect-file.txt"), out = local.appendingPathComponent("out")
        try Data("redirect fixture".utf8).write(to: target); try Data("preserve local".utf8).write(to: out)
        for tls in [false, true] {
            _ = try await client.connect(site: site(tls: tls), password: "test-only-password")
            do { try await client.download(remote: RemotePath.join(remotePath, "redirect-file.txt"), local: out, replace: true); XCTFail("Followed foreign or downgrade redirect") } catch ClientError.remote(_, 302, _) { }
        }
        let other = RemoteSession()
        do { _ = try await other.connect(site: site(path: "/foreign-redirect"), password: "test-only-password"); XCTFail("Followed login redirect") } catch ClientError.remote(_, 301, _) { }
        await other.disconnect()
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("capture-count")), "0")
        XCTAssertEqual(try String(contentsOf: out), "preserve local")
        try assertNoPartials()
    }
    func testMissingETagsAndAmbiguousMoveDestinationsFailWithoutWriting() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("no-etag.txt")
        try Data("new".utf8).write(to: source); try Data("preserve".utf8).write(to: target)
        let path = RemotePath.join(remotePath, "no-etag.txt")
        let entry = try await client.stat(path); XCTAssertNil(entry.versionTag)
        do { try await client.upload(local: source, remote: path, replace: true); XCTFail("Replaced without an ETag") } catch ClientError.unsupported { }
        let out = local.appendingPathComponent("out"); try await client.download(remote: path, local: out)
        XCTAssertEqual(try String(contentsOf: out), "preserve")
        for name in ["query?part.txt", "parameters;part.txt"] {
            do { try await client.upload(local: source, remote: RemotePath.join(remotePath, name)); XCTFail("Used an ambiguous MOVE destination") } catch ClientError.unsupported { }
            // Existing names remain readable through the correctly escaped request URI.
            let remoteFile = remote.appendingPathComponent(name)
            try Data("readable".utf8).write(to: remoteFile)
            let downloaded = local.appendingPathComponent(UUID().uuidString)
            try await client.download(remote: RemotePath.join(remotePath, name), local: downloaded)
            XCTAssertEqual(try String(contentsOf: downloaded), "readable")
        }
        XCTAssertEqual(try String(contentsOf: target), "preserve")
        try assertNoPartials()
    }
    func testChangedLocalSourceDoesNotReplaceRemoteFile() async throws {
        let source = local.appendingPathComponent("source"), target = remote.appendingPathComponent("target")
        try Data(repeating: 42, count: 8 * 1024 * 1024).write(to: source); try Data("preserve remote".utf8).write(to: target)
        let once = CancellationToken()
        do {
            try await client.upload(local: source, remote: RemotePath.join(remotePath, "target"), replace: true) { done, _ in
                if done >= 65536, !once.isCancelled { once.cancel(); try? Data("changed local source".utf8).write(to: source) }
            }
            XCTFail("Published changed source")
        } catch ClientError.conflict { }
        XCTAssertEqual(try String(contentsOf: target), "preserve remote")
        try assertNoPartials()
    }
    func testLongNamesMissingFilesAndTypePolicy() async throws {
        let source = local.appendingPathComponent("source"); try Data("long filename".utf8).write(to: source)
        let name = String(repeating: "a", count: 245) + ".txt"
        try await client.upload(local: source, remote: RemotePath.join(remotePath, name))
        let out = local.appendingPathComponent("out"); try await client.download(remote: RemotePath.join(remotePath, name), local: out)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: source))
        do { _ = try await client.stat(RemotePath.join(remotePath, "missing")); XCTFail("Missing file succeeded") } catch ClientError.remote(_, 404, _) { }
        for path in ["/", ".", "..", remotePath + "/./", "/dav/../.."] {
            do { try await client.remove(path, recursive: true); XCTFail("Unsafe root/parent deletion") } catch ClientError.invalid { }
        }
        let link = local.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { try await client.upload(local: link, remote: RemotePath.join(remotePath, "link")); XCTFail("Followed local symlink") } catch ClientError.unsupported { }
        do { try await client.download(remote: remotePath, local: local.appendingPathComponent("directory")); XCTFail("Downloaded collection as a file") } catch ClientError.unsupported { }
        try assertNoPartials()
    }
}
