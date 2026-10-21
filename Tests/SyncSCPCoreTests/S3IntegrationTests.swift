// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

/// Real S3 against disposable MinIO containers over HTTP and TLS.
final class S3IntegrationTests: XCTestCase {
    private static let bucket = "syncscp-test", secret = "test-only-secret-key"
    private var fixture: URL!, local: URL!
    private var httpPort = 0, httpsPort = 0
    private var id = "", remotePath = ""
    private var client: RemoteSession!
    private var raw: S3Client!

    override func setUp() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SYNCSCP_TEST_S3_FIXTURE"] else {
            throw XCTSkip("Run scripts/test-s3.sh for disposable MinIO S3 servers (requires Docker).")
        }
        fixture = URL(fileURLWithPath: directory)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("ready.json"))) as? [String: Any])
        httpPort = try XCTUnwrap(config["http_port"] as? Int); httpsPort = try XCTUnwrap(config["https_port"] as? Int)
        id = UUID().uuidString
        local = fixture.appendingPathComponent("local/" + id)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        raw = S3Client()
        _ = try await raw.connect(site: site(path: "/" + Self.bucket), secretKey: Self.secret)
        remotePath = "/\(Self.bucket)/\(id)"
        try await raw.mkdir(remotePath)
        client = RemoteSession()
        _ = try await client.connect(site: site(), password: Self.secret)
    }
    override func tearDown() async throws {
        await client?.disconnect()
        if let raw { try? await raw.remove(remotePath, recursive: true); await raw.disconnect() }
        if let local { try? FileManager.default.removeItem(at: local) }
    }
    private func site(tls: Bool = false, trusted: Bool = true, host: String = "localhost", user: String = "syncscp-tester",
                      path: String? = nil, region: String = "") -> Site {
        Site(host: host, port: tls ? httpsPort : httpPort, username: user, remotePath: path ?? remotePath,
             transferProtocol: tls ? .s3 : .s3http, certificateAuthorityFile: tls && trusted ? fixture.appendingPathComponent("ca.pem").path : "",
             s3Region: region, s3PathStyle: true)
    }
    private func key(_ name: String) -> String { id + "/" + name }
    private func path(_ name: String) -> String { RemotePath.join(remotePath, name) }

    /// Writes with an independent connection, e.g. from inside a transfer's progress callback.
    @discardableResult
    private func put(_ key: String, _ data: Data, headers: [String: String] = [:]) async throws -> DAVHTTPResponse {
        try await raw.send("PUT", S3Location(bucket: Self.bucket, key: key), headers: headers, body: data)
    }
    private func blocking(_ work: @escaping @Sendable () async throws -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached { try? await work(); done.signal() }
        done.wait()
    }
    private func object(_ key: String) async throws -> Data? {
        let response = try await raw.send("GET", S3Location(bucket: Self.bucket, key: key))
        if response.status == 404 { return nil }
        XCTAssertEqual(response.status, 200); return response.body
    }
    private func assertObject(_ key: String, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await object(key)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func keys() async throws -> [String] {
        let response = try await raw.send("GET", S3Location(bucket: Self.bucket), query: [("list-type", "2"), ("prefix", id + "/")])
        return try S3Listing.page(response.body, prefix: id + "/").objects.map(\.key)
    }
    private func pendingUploads() async throws -> [String] {
        let response = try await raw.send("GET", S3Location(bucket: Self.bucket), query: [("uploads", ""), ("prefix", id + "/")])
        XCTAssertEqual(response.status, 200)
        return try S3XML.parse(response.body).all("Upload").compactMap { $0.value("Key") }
    }
    private func assertNoPartials(file: StaticString = #filePath, line: UInt = #line) async throws {
        let pending = try await pendingUploads()
        XCTAssertEqual(pending, [], file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: local.path).contains { $0.hasPrefix(".syncscp-") }, file: file, line: line)
    }

    func testHTTPAndHTTPSBinaryAndEmptyRoundTrips() async throws {
        for tls in [false, true] {
            // The HTTPS fixture is a separate server; give it the same per-test folder.
            if tls { _ = try await client.connect(site: site(tls: true, path: "/" + Self.bucket), password: Self.secret); try await client.mkdir(remotePath) }
            _ = try await client.connect(site: site(tls: tls), password: Self.secret)
            for size in [0, 1, 65536, 1_048_731] {
                let name = "file-\(tls)-\(size)", source = local.appendingPathComponent("source"), out = local.appendingPathComponent(name)
                let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
                try data.write(to: source)
                try await client.upload(local: source, remote: path(name))
                try await client.download(remote: path(name), local: out)
                XCTAssertEqual(try Data(contentsOf: out), data)
                let info = try await client.stat(path(name))
                XCTAssertEqual(info.size, UInt64(size)); XCTAssertTrue(info.isRegularFile); XCTAssertNotNil(info.modified)
                XCTAssertNotNil(DAVETag.strong(info.versionTag)); XCTAssertFalse(info.permissionsKnown); XCTAssertEqual(info.rights, "—")
                if !tls { try await assertObject(key(name), data) }
            }
            let buckets = try await client.list("/")
            XCTAssertTrue(Set(buckets.map(\.name)).isSuperset(of: ["syncscp-test", "syncscp-empty"]))
            let empty = try await client.list("/syncscp-empty"); XCTAssertEqual(empty, [])
            if tls { try await client.remove(remotePath, recursive: true) }
        }
        try await assertNoPartials()
    }

    func testNamesFoldersAndFileOperations() async throws {
        let names = ["two words.txt", "İstanbul 日本語.txt", "quote'\"$`.txt", "100% #&+.txt", "a+b=c;d?.txt", "-leading", ".hidden", "literal%2F.txt"]
        let source = local.appendingPathComponent("source"); try Data("S3".utf8).write(to: source)
        for name in names {
            try await client.upload(local: source, remote: path(name))
            let out = local.appendingPathComponent(UUID().uuidString)
            try await client.download(remote: path(name), local: out)
            XCTAssertEqual(try String(contentsOf: out), "S3")
        }
        let listed = try await client.list(remotePath)
        XCTAssertEqual(Set(listed.map(\.name)), Set(names))
        let remaining = try await keys(); XCTAssertEqual(Set(remaining), Set([id + "/"] + names.map(key)))
        let folder = path("new folder")
        try await client.mkdir(folder)
        do { try await client.mkdir(folder); XCTFail("Created a folder twice") } catch ClientError.conflict { }
        do { try await client.mkdir(path(names[0])); XCTFail("Created a folder over an object") } catch ClientError.conflict { }
        do { try await client.mkdir(path("missing/child")); XCTFail("Created a folder in a missing parent") } catch ClientError.conflict { }
        do { try await client.upload(local: source, remote: folder, replace: true); XCTFail("Uploaded over a folder") } catch ClientError.conflict { }
        let made = try await client.stat(folder); XCTAssertTrue(made.isDirectory)
        try await client.rename(path(names[0]), to: RemotePath.join(folder, "renamed.txt"))
        let moved = try await client.exists(path(names[0])); XCTAssertFalse(moved)
        do { try await client.rename(folder, to: path("other folder")); XCTFail("Claimed folder rename support") } catch ClientError.unsupported { }
        do { try await client.remove(folder); XCTFail("Removed nonempty folder without recursion") } catch ClientError.conflict { }
        try await client.remove(folder, recursive: true)
        let exists = try await client.exists(folder); XCTAssertFalse(exists)
        do { _ = try await client.list(folder); XCTFail("Listed a deleted folder") } catch ClientError.remote(_, 404, _) { }
        do { _ = try await client.stat(path("missing.txt")); XCTFail("Stat invented a file") } catch ClientError.remote(_, 404, _) { }
        do { try await client.chmod(path(names[1]), mode: 0o644); XCTFail("Invented POSIX chmod support") } catch ClientError.unsupported { }
        do { try await client.mkdir("/new-bucket-\(id.lowercased())"); XCTFail("Created a bucket") } catch ClientError.unsupported { }
        do { try await client.remove("/" + Self.bucket, recursive: true); XCTFail("Deleted a bucket") } catch ClientError.unsupported { }
        let canonical = try await client.realpath(remotePath + "/./"); XCTAssertEqual(canonical, remotePath)
        try await assertNoPartials()
    }

    func testNoClobberApprovedReplacementAndInFlightDestinationChanges() async throws {
        let source = local.appendingPathComponent("source"), out = local.appendingPathComponent("out"), target = path("target")
        try Data(repeating: 42, count: 4 << 20).write(to: source)
        try await put(key("target"), Data("original".utf8))
        do { try await client.upload(local: source, remote: target); XCTFail("Overwrote without approval") } catch ClientError.conflict { }
        try await client.upload(local: source, remote: target, replace: true)
        try await assertObject(key("target"), try Data(contentsOf: source))
        try Data("local original".utf8).write(to: out)
        do { try await client.download(remote: target, local: out); XCTFail("Overwrote local destination") } catch ClientError.conflict { }
        try await client.download(remote: target, local: out, replace: true)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: source))

        // A destination created after the client's own check must still win: the server
        // enforces If-None-Match. (MinIO locks objects during a PUT, so a write cannot be
        // injected mid-stream; the first progress callback runs after the pre-check.)
        let fresh = path("fresh"), once = CancellationToken(), freshKey = key("fresh")
        do {
            try await client.upload(local: source, remote: fresh) { _, _ in
                if !once.isCancelled { once.cancel(); self.blocking { try await self.put(freshKey, Data("concurrent file".utf8)) } }
            }
            XCTFail("Overwrote a concurrently created destination")
        } catch ClientError.conflict { }
        try await assertObject(freshKey, Data("concurrent file".utf8))

        // A reviewed destination replaced after the client's check must still win (If-Match).
        let reviewed = try await client.stat(target), twice = CancellationToken(), targetKey = key("target")
        do {
            try await client.upload(local: source, remote: target, replace: true, expectedDestination: reviewed) { _, _ in
                if !twice.isCancelled { twice.cancel(); self.blocking { try await self.put(targetKey, Data("external version".utf8)) } }
            }
            XCTFail("Overwrote a reviewed change")
        } catch ClientError.conflict { }
        do { try await client.upload(local: source, remote: target, replace: true, expectedDestination: reviewed); XCTFail("Ignored old review") } catch ClientError.conflict { }
        try await assertObject(targetKey, Data("external version".utf8))
        try await assertNoPartials()
    }

    func testMultipartRoundTripConditionsCancellationAndCleanup() async throws {
        let multipart = RemoteSession()
        _ = try await multipart.connect(site: site(), password: Self.secret)
        let s3 = S3Client(partSize: 5 << 20, multipartThreshold: 5 << 20)
        _ = try await s3.connect(site: site(), secretKey: Self.secret)
        let source = local.appendingPathComponent("source"), out = local.appendingPathComponent("out")
        let data = Data((0..<(12 << 20) + 3).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 13) })
        try data.write(to: source)
        let updates = CancellationToken(), size = UInt64(data.count)
        try await s3.upload(local: source, remote: path("big.bin")) { done, total in XCTAssertEqual(total, size); if done > 5 << 20 { updates.cancel() } }
        XCTAssertTrue(updates.isCancelled, "Progress did not span parts")
        let info = try await s3.stat(path("big.bin"))
        XCTAssertEqual(info.size, UInt64(data.count)); XCTAssertTrue(info.versionTag?.hasSuffix("-3\"") == true)
        try await s3.download(remote: path("big.bin"), local: out)
        XCTAssertEqual(try Data(contentsOf: out), data)
        do { try await s3.upload(local: source, remote: path("big.bin")); XCTFail("Multipart overwrote without approval") } catch ClientError.conflict { }

        let cancel = CancellationToken()
        do {
            try await s3.upload(local: source, remote: path("cancelled.bin"), token: cancel) { done, _ in if done >= 6 << 20 { cancel.cancel() } }
            XCTFail("Cancelled multipart upload succeeded")
        } catch ClientError.cancelled { }
        let cancelled = try await object(key("cancelled.bin")); XCTAssertNil(cancelled)
        try await assertNoPartials()

        // CompleteMultipartUpload carries the no-clobber condition.
        let once = CancellationToken(), raceKey = key("race.bin")
        do {
            try await s3.upload(local: source, remote: path("race.bin")) { _, _ in
                if !once.isCancelled { once.cancel(); self.blocking { try await self.put(raceKey, Data("concurrent".utf8)) } }
            }
            XCTFail("Multipart overwrote a concurrently created destination")
        } catch ClientError.conflict { }
        try await assertObject(raceKey, Data("concurrent".utf8))
        try await assertNoPartials()
        await s3.disconnect(); await multipart.disconnect()
    }

    func testCancellationAndChangedLocalSourcePreserveRemoteObject() async throws {
        let source = local.appendingPathComponent("source"), out = local.appendingPathComponent("out"), target = path("target")
        try Data(repeating: 42, count: 8 << 20).write(to: source)
        try await put(key("target"), Data("old remote".utf8))
        let upload = CancellationToken()
        do {
            try await client.upload(local: source, remote: target, replace: true, token: upload) { done, _ in if done >= 65536 { upload.cancel() } }
            XCTFail("Cancelled upload succeeded")
        } catch ClientError.cancelled { }
        try await assertObject(key("target"), Data("old remote".utf8))
        // Same-size rewrite during transfer: bytes no longer match the signed SHA-256.
        let once = CancellationToken(), path = source.path
        do {
            try await client.upload(local: source, remote: target, replace: true) { done, _ in
                if done >= 65536, !once.isCancelled { once.cancel(); try? Data(repeating: 7, count: 8 << 20).write(to: URL(fileURLWithPath: path)) }
            }
            XCTFail("Uploaded a file that changed during transfer")
        } catch let error as ClientError {
            if case .conflict = error {} else if case .remote(_, 400, _) = error {} else { XCTFail("Unexpected error \(error)") }
        }
        try await assertObject(key("target"), Data("old remote".utf8))
        try await client.upload(local: source, remote: target, replace: true)
        try Data("old local".utf8).write(to: out)
        let download = CancellationToken()
        do {
            try await client.download(remote: target, local: out, replace: true, token: download) { done, _ in if done >= 65536 { download.cancel() } }
            XCTFail("Cancelled download succeeded")
        } catch ClientError.cancelled { }
        XCTAssertEqual(try String(contentsOf: out), "old local")
        try await assertNoPartials()
    }

    func testRenamePreservesMetadataAndHonorsDestinationConditions() async throws {
        try await put(key("a.txt"), Data("alpha".utf8), headers: ["Content-Type": "text/plain; charset=utf-8", "x-amz-meta-origin": "syncscp test"])
        try await put(key("b.txt"), Data("beta".utf8))
        do { try await client.rename(path("a.txt"), to: path("b.txt")); XCTFail("Rename overwrote without approval") } catch ClientError.conflict { }
        try await client.rename(path("a.txt"), to: path("c.txt"))
        let head = try await raw.send("HEAD", S3Location(bucket: Self.bucket, key: key("c.txt")))
        XCTAssertEqual(head.headers["content-type"], "text/plain; charset=utf-8"); XCTAssertEqual(head.headers["x-amz-meta-origin"], "syncscp test")
        try await assertObject(key("c.txt"), Data("alpha".utf8))
        let gone = try await object(key("a.txt")); XCTAssertNil(gone)
        try await client.rename(path("c.txt"), to: path("b.txt"), replace: true)
        try await assertObject(key("b.txt"), Data("alpha".utf8))
        let empty = local.appendingPathComponent("empty"); try Data().write(to: empty)
        try await client.upload(local: empty, remote: path("empty"))
        try await client.rename(path("empty"), to: path("still empty"))
        try await assertObject(key("still empty"), Data())
        do { try await client.rename(path("missing"), to: path("x")); XCTFail("Renamed a missing object") } catch ClientError.remote(_, 404, _) { }
        try await assertNoPartials()
    }

    func testUnaddressableKeysAreHiddenAndDeletedExactly() async throws {
        // MinIO rejects empty/dot segments and resolves file/folder name collisions in its own way;
        // those cases are covered by the listing unit tests.
        for name in ["weird/back\\slash.txt", "weird/con\u{1}trol.txt", "weird/ok.txt", "plain.txt"] {
            let response = try await put(key(name), Data(name.utf8)); XCTAssertEqual(response.status, 200, name)
        }
        let top = try await client.list(remotePath); XCTAssertEqual(top.map(\.name), ["weird", "plain.txt"])
        let weird = try await client.list(path("weird")); XCTAssertEqual(weird.map(\.name), ["ok.txt"])
        do { try await client.remove(path("weird")); XCTFail("Hidden keys did not keep the folder non-empty") } catch ClientError.conflict { }
        try await client.remove(path("weird"), recursive: true)
        let remaining = try await keys(); XCTAssertEqual(Set(remaining), [id + "/", key("plain.txt")])
    }

    func testPaginatedListing() async throws {
        let paged = S3Client(listPageSize: 2)
        _ = try await paged.connect(site: site(), secretKey: Self.secret)
        for index in 0..<5 { try await put(key("file-\(index)"), Data([UInt8(index)])) }
        for index in 0..<3 { try await put(key("folder-\(index)/inner"), Data()) }
        let entries = try await paged.list(remotePath)
        XCTAssertEqual(entries.map(\.name), ["folder-0", "folder-1", "folder-2", "file-0", "file-1", "file-2", "file-3", "file-4"])
        await paged.disconnect()
    }

    func testTLSCredentialsRegionAndReadOnlyFailures() async throws {
        let attempt = RemoteSession()
        do { _ = try await attempt.connect(site: site(tls: true, trusted: false), password: Self.secret); XCTFail("Trusted an unknown CA") } catch ClientError.connection { }
        do { _ = try await attempt.connect(site: site(tls: true, host: "127.0.0.1"), password: Self.secret); XCTFail("Ignored hostname mismatch") } catch ClientError.connection { }
        do { _ = try await attempt.connect(site: site(), password: "wrong-secret"); XCTFail("Accepted a wrong secret") }
        catch ClientError.remote(_, 403, let text) { XCTAssertTrue(text.contains("Authentication failed"), text) }
        do { _ = try await attempt.connect(site: site(region: "eu-west-1"), password: Self.secret); XCTFail("Accepted the wrong region") }
        catch ClientError.remote(_, _, let text) { XCTAssertTrue(text.contains("us-east-1"), text) }
        do { _ = try await attempt.connect(site: site(), password: ""); XCTFail("Accepted an empty secret") } catch ClientError.invalid { }

        let source = local.appendingPathComponent("source"); try Data("readonly".utf8).write(to: source)
        try await put(key("welcome.txt"), Data("hello".utf8))
        _ = try await attempt.connect(site: site(user: "syncscp-reader"), password: "test-only-reader-key")
        let listed = try await attempt.list(remotePath); XCTAssertEqual(listed.map(\.name), ["welcome.txt"])
        try await attempt.download(remote: path("welcome.txt"), local: local.appendingPathComponent("w"))
        do { try await attempt.upload(local: source, remote: path("denied.txt")); XCTFail("Read-only upload succeeded") } catch ClientError.remote(_, 403, _) { }
        do { try await attempt.remove(path("welcome.txt")); XCTFail("Read-only delete succeeded") } catch ClientError.remote(_, 403, _) { }
        do { try await attempt.mkdir(path("denied")); XCTFail("Read-only mkdir succeeded") } catch ClientError.remote(_, 403, _) { }
        await attempt.disconnect()
        try await assertNoPartials()
    }
}
