// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SyncSCPCore

/// Independent pyftpdlib servers: actual FTP, AUTH TLS, implicit TLS, and legacy LIST.
final class FTPIntegrationTests: XCTestCase {
    private var fixture: URL!
    private var local: URL!
    private var diskRemote: URL!
    private var remote = ""
    private var ports: [String: Int] = [:]

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["SYNCSCP_TEST_FTP_FIXTURE"] else {
            throw XCTSkip("Run scripts/test-ftp.sh to enable the disposable FTP/FTPS fixture.")
        }
        fixture = URL(fileURLWithPath: path)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("ready.json"))) as? [String: Any])
        ports = try XCTUnwrap(json["ports"] as? [String: Int])
        let name = UUID().uuidString
        local = fixture.appendingPathComponent("local/" + name)
        diskRemote = fixture.appendingPathComponent("remote/" + name)
        remote = "/" + name
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: diskRemote, withIntermediateDirectories: false)
    }
    override func tearDown() async throws {
        if let local { try FileManager.default.removeItem(at: local) }
        if let diskRemote { try FileManager.default.removeItem(at: diskRemote) }
    }

    private func site(_ kind: TransferProtocol, legacy: Bool = false) -> Site {
        let key = legacy ? "legacy" : kind == .ftp ? "ftp" : kind == .ftpsExplicit ? "explicit" : "implicit"
        return Site(host: "localhost", port: ports[key]!, username: "syncscp", transferProtocol: kind,
                    certificateAuthorityFile: kind == .ftp ? "" : fixture.appendingPathComponent("ca.pem").path)
    }
    private func withClient(_ kind: TransferProtocol, legacy: Bool = false, _ body: (FTPClient) async throws -> Void) async throws {
        let client = FTPClient()
        do {
            let home = try await client.connect(site: site(kind, legacy: legacy), password: "test-only-password")
            XCTAssertEqual(home, "/")
            try await body(client)
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
    }

    func testBinaryAndEmptyRoundTripsAcrossAllFTPTransports() async throws {
        for kind in [TransferProtocol.ftp, .ftpsExplicit, .ftpsImplicit] {
            try await withClient(kind) { client in
                for size in [0, 1, 65536, 1_048_731] {
                    let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
                    let source = self.local.appendingPathComponent("source")
                    let download = self.local.appendingPathComponent("download-\(kind.rawValue)-\(size)")
                    let destination = self.remote + "/\(kind.rawValue)-\(size).bin"
                    try data.write(to: source)
                    try await client.upload(local: source, remote: destination)
                    try await client.download(remote: destination, local: download)
                    XCTAssertEqual(try Data(contentsOf: download), data, kind.title)
                }
            }
        }
    }
    func testUnicodeSpacesAndURLMetacharactersSurviveTransfer() async throws {
        try await withClient(.ftpsExplicit) { client in
            for name in ["two words.txt", "İstanbul 日本語.txt", "quote'\"$`;.txt", "hash# percent% question?.txt", " leading space.txt"] {
                let source = self.local.appendingPathComponent(name)
                try Data(name.utf8).write(to: source)
                try await client.upload(local: source, remote: self.remote + "/" + name)
                XCTAssertEqual(try String(contentsOf: self.diskRemote.appendingPathComponent(name)), name)
            }
            let entries = try await client.list(self.remote)
            XCTAssertEqual(entries.count, 5)
        }
    }
    func testNoClobberReplacementAndLongName() async throws {
        try await withClient(.ftp) { client in
            let source = self.local.appendingPathComponent("source")
            let target = self.diskRemote.appendingPathComponent("existing")
            try Data("new".utf8).write(to: source); try Data("original".utf8).write(to: target)
            do { try await client.upload(local: source, remote: self.remote + "/existing"); XCTFail("Overwrote without approval") }
            catch ClientError.conflict { }
            XCTAssertEqual(try String(contentsOf: target), "original")
            try await client.upload(local: source, remote: self.remote + "/existing", replace: true)
            XCTAssertEqual(try String(contentsOf: target), "new")
            let output = self.local.appendingPathComponent("output")
            try Data("local original".utf8).write(to: output)
            do { try await client.download(remote: self.remote + "/existing", local: output); XCTFail("Overwrote local file without approval") }
            catch ClientError.conflict { }
            XCTAssertEqual(try String(contentsOf: output), "local original")
            try await client.download(remote: self.remote + "/existing", local: output, replace: true)
            XCTAssertEqual(try String(contentsOf: output), "new")
            let name = String(repeating: "a", count: 245) + ".txt"
            try await client.upload(local: source, remote: self.remote + "/" + name)
            XCTAssertEqual(try String(contentsOf: self.diskRemote.appendingPathComponent(name)), "new")
        }
    }
    func testCancelledTransfersPreserveOriginalsAndCleanPartials() async throws {
        try await withClient(.ftpsExplicit) { client in
            let source = self.local.appendingPathComponent("source")
            let target = self.diskRemote.appendingPathComponent("existing")
            try Data(repeating: 31, count: 4 * 1024 * 1024).write(to: source)
            try Data("original".utf8).write(to: target)
            let uploadToken = CancellationToken()
            do {
                try await client.upload(local: source, remote: self.remote + "/existing", replace: true, token: uploadToken) { done, _ in
                    if done >= 65536 { uploadToken.cancel() }
                }
                XCTFail("Cancelled upload committed")
            } catch ClientError.cancelled { }
            XCTAssertEqual(try String(contentsOf: target), "original")
            try Data(repeating: 84, count: 4 * 1024 * 1024).write(to: target)
            let output = self.local.appendingPathComponent("output")
            try Data("local original".utf8).write(to: output)
            let downloadToken = CancellationToken()
            do {
                try await client.download(remote: self.remote + "/existing", local: output, replace: true, token: downloadToken) { done, _ in
                    if done >= 65536 { downloadToken.cancel() }
                }
                XCTFail("Cancelled download committed")
            } catch ClientError.cancelled { }
            XCTAssertEqual(try String(contentsOf: output), "local original")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: self.local.path).contains { $0.hasSuffix(".filepart") })
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: self.diskRemote.path).contains { $0.hasSuffix(".filepart") })
        }
    }
    func testMkdirRenamePermissionsRecursiveDeleteAndMissingParentErrors() async throws {
        try await withClient(.ftpsImplicit) { client in
            let directory = self.remote + "/folder with spaces"
            try await client.mkdir(directory)
            let source = self.local.appendingPathComponent("source")
            try Data("hello".utf8).write(to: source)
            try await client.upload(local: source, remote: directory + "/old")
            try await client.rename(directory + "/old", to: directory + "/new")
            try await client.chmod(directory + "/new", mode: 0o640)
            let info = try await client.stat(directory + "/new")
            XCTAssertEqual(info.permissions & 0o777, 0o640)
            try await client.remove(directory, recursive: true)
            let exists = try await client.exists(directory); XCTAssertFalse(exists)
            do { _ = try await client.exists(self.remote + "/missing-parent/file"); XCTFail("Missing parent error was swallowed") }
            catch ClientError.remote { }
            for path in ["/", ".", "..", "/../", "\r\nDELE /welcome.txt"] {
                do { try await client.remove(path, recursive: true); XCTFail("Unsafe path was accepted") }
                catch ClientError.invalid { }
            }
        }
    }
    func testLegacyLISTFallbackPreservesTypesAndFiles() async throws {
        try FileManager.default.createDirectory(at: diskRemote.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try Data("legacy".utf8).write(to: diskRemote.appendingPathComponent("two words.txt"))
        try FileManager.default.createSymbolicLink(at: diskRemote.appendingPathComponent("link"), withDestinationURL: diskRemote.appendingPathComponent("two words.txt"))
        try await withClient(.ftp, legacy: true) { client in
            let entries = try await client.list(self.remote)
            XCTAssertTrue(entries.first?.isDirectory == true)
            XCTAssertTrue(entries.contains { $0.name == "link" && $0.isSymbolicLink })
            try await client.download(remote: self.remote + "/two words.txt", local: self.local.appendingPathComponent("downloaded"))
            XCTAssertEqual(try String(contentsOf: self.local.appendingPathComponent("downloaded")), "legacy")
        }
    }
    func testFTPSRejectsUntrustedCAHostnameMismatchAndPlainServer() async throws {
        for kind in [TransferProtocol.ftpsExplicit, .ftpsImplicit] {
            for issue in ["untrusted", "hostname"] {
                let client = FTPClient(); var site = self.site(kind)
                if issue == "untrusted" { site.certificateAuthorityFile = "" }
                else { site.host = "127.0.0.1" }
                do { _ = try await client.connect(site: site, password: "test-only-password"); XCTFail("FTPS accepted \(issue)") }
                catch ClientError.connection { }
                await client.disconnect()
            }
        }
        let client = FTPClient(); var site = self.site(.ftpsExplicit); site.port = ports["ftp"]!
        do { _ = try await client.connect(site: site, password: "test-only-password"); XCTFail("FTPS silently downgraded to FTP") }
        catch ClientError.connection { }
        await client.disconnect()
    }
    func testWrongPasswordAndReadOnlyAccountErrors() async throws {
        let client = FTPClient()
        do { _ = try await client.connect(site: site(.ftp), password: "incorrect-test-password"); XCTFail("Incorrect password authenticated") }
        catch ClientError.remote(_, let code, let message) { XCTAssertEqual(code, 530); XCTAssertFalse(message.contains("incorrect-test-password")) }
        var readonly = site(.ftp); readonly.username = "readonly"
        _ = try await client.connect(site: readonly, password: "test-only-password")
        do { try await client.mkdir(remote + "/forbidden"); XCTFail("Read-only account created a directory") }
        catch ClientError.remote(_, let code, _) { XCTAssertEqual(code, 550) }
        await client.disconnect()
    }
    func testReviewedDestinationChangesAreProtected() async throws {
        try await withClient(.ftpsExplicit) { client in
            let target = self.diskRemote.appendingPathComponent("existing")
            try Data("original".utf8).write(to: target)
            let snapshot = try await client.stat(self.remote + "/existing")
            let source = self.local.appendingPathComponent("source")
            try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: source)
            let changed = CancellationToken()
            do {
                try await client.upload(local: source, remote: self.remote + "/existing", replace: true, expectedDestination: snapshot) { done, _ in
                    if done >= 65536, !changed.isCancelled { changed.cancel(); try? Data("external change".utf8).write(to: target) }
                }
                XCTFail("Overwrote a changed destination")
            } catch ClientError.conflict { }
            XCTAssertEqual(try String(contentsOf: target), "external change")
        }
    }
    func testProtocolIndependentSessionUsesFTPBackend() async throws {
        let session = RemoteSession()
        do {
            let home = try await session.connect(site: site(.ftpsExplicit), password: "test-only-password")
            XCTAssertEqual(home, "/")
            let entries = try await session.list("/")
            XCTAssertTrue(entries.contains { $0.name == "welcome.txt" })
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }
    func testMissingMLSDSizeFactsFallBackToLIST() async throws {
        let client = FTPClient(); var sparse = site(.ftp); sparse.port = ports["sparse"]!
        do {
            _ = try await client.connect(site: sparse, password: "test-only-password")
            let entries = try await client.list("/")
            let welcome = try XCTUnwrap(entries.first { $0.name == "welcome.txt" })
            XCTAssertEqual(welcome.size, 51) // UTF-8 bytes of the fixture's welcome.txt
            XCTAssertNil(welcome.modified)
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
    }
    func testUploadPreservesTimestampAndExistingPermissions() async throws {
        try await withClient(.ftpsExplicit) { client in
            let source = self.local.appendingPathComponent("source")
            let target = self.diskRemote.appendingPathComponent("existing")
            try Data("new content".utf8).write(to: source)
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o600], ofItemAtPath: source.path)
            try Data("old".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: target.path)
            try await client.upload(local: source, remote: self.remote + "/existing", replace: true)
            let info = try await client.stat(self.remote + "/existing")
            XCTAssertEqual(info.modified, date)
            XCTAssertTrue(info.permissionsKnown)
            XCTAssertEqual(info.permissions & 0o777, 0o750)
        }
    }
    func testRecursiveDeletionDoesNotFollowSymlinksEvenWhenMLSDResolvesThem() async throws {
        let target = diskRemote.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let keep = target.appendingPathComponent("keep.txt")
        try Data("keep this file".utf8).write(to: keep)
        let link = diskRemote.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await withClient(.ftpsExplicit) { client in
            try await client.remove(self.remote + "/link", recursive: true)
            XCTAssertEqual(try String(contentsOf: keep), "keep this file")
            XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        }
    }
}
