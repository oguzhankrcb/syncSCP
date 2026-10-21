// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

final class SCPTests: XCTestCase {
    func testMetadataDecodesGNUAndBSDWithoutSplittingFilenames() throws {
        for (flavor, mode) in [("gnu", "81a0"), ("bsd", "100640")] {
            let path = "/tmp/İstanbul ' 日本語\nline.txt"
            let entries = try SCPMetadata.decode(Data("\(path)\0\(mode) 42 1700000000\n\0".utf8), flavor: flavor)
            XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].path, path)
            XCTAssertEqual(entries[0].size, 42); XCTAssertEqual(entries[0].permissions, 0o100640)
            XCTAssertEqual(entries[0].modified, Date(timeIntervalSince1970: 1700000000))
        }
        for data in [Data("/tmp/a\0bad\0".utf8), Data("/tmp/a\0".utf8), Data("relative\081a4 1 1\0".utf8), Data([47, 255, 0, 0]), Data("/tmp/a\081a4 1 1".utf8)] {
            XCTAssertThrowsError(try SCPMetadata.decode(data, flavor: "gnu"))
        }
    }
    func testSCPRejectsUnexpectedNamesSizesAndControlRecords() throws {
        XCTAssertNoThrow(try SCPRecord.file(Data("C0644 123 a b'$.txt".utf8), expectedName: "a b'$.txt", expectedSize: 123))
        for line in ["C0644 123 ../out", "C0644 123 /tmp/out", "C0644 123 .", "C0644 123 other", "C0644 124 target", "D0755 0 target", "T0 0 0 0", "C9999 123 target", "C0644 -1 target", "C+644 123 target", "C0644 +123 target"] {
            XCTAssertThrowsError(try SCPRecord.file(Data(line.utf8), expectedName: "target", expectedSize: 123))
        }
    }
    func testShellQuotingAndSCPSitePersistence() throws {
        XCTAssertEqual(try SCPShell.quote("a'$(touch injected);`id`"), "'a'\\''$(touch injected);`id`'")
        XCTAssertThrowsError(try SCPShell.quote("nul\0byte"))
        let site = Site(name: "SCP", host: "example.com", transferProtocol: .scp)
        XCTAssertEqual(site.port, 22); XCTAssertTrue(site.transferProtocol.usesSSH)
        XCTAssertEqual(site.transferProtocol.shortTitle, "SCP")
        XCTAssertEqual(try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site)), site)
        var invalidKey = site; invalidKey.privateKey = "/this/key/does/not/exist"
        XCTAssertThrowsError(try invalidKey.validate())
    }
}
