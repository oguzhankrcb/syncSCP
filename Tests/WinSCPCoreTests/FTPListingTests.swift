// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

final class FTPListingTests: XCTestCase {
    func testMLSDPreservesNamesTypesUTCAndPermissionFacts() throws {
        let text = "type=cdir; .\r\ntype=pdir; ..\r\nTyPe=dir;modify=20261021120000;unix.mode=750; folder\r\ntype=file;size=12;modify=20261021120102.125;unix.mode=640;  quoted'\" %日本語.txt\r\ntype=OS.unix=slink:/target;size=0; link\r\n"
        let entries = try FTPListing.mlsd(Data(text.utf8), directory: "/root")
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.name, "folder")
        XCTAssertEqual(entries.first?.permissions, 0o040750)
        let file = try XCTUnwrap(entries.first { $0.isRegularFile })
        XCTAssertEqual(file.name, " quoted'\" %日本語.txt")
        XCTAssertEqual(file.size, 12)
        XCTAssertEqual(file.permissions, 0o100640)
        XCTAssertEqual(file.modified?.timeIntervalSince1970, 1792584062.125)
        XCTAssertTrue(entries.contains { $0.isSymbolicLink })
    }
    func testMalformedAndUnsafeMLSDEntriesAreRejected() throws {
        for text in ["type=file;size=abc; bad", "type=file; ../bad", "type=file; bad\rname", "size=1; unknown", "type=file;type=dir; duplicate", "type=file;modify=invalid; bad", "type=file; no-size"] {
            XCTAssertThrowsError(try FTPListing.mlsd(Data(text.utf8), directory: "/"), text)
        }
        XCTAssertThrowsError(try FTPListing.mlsd(Data([255]), directory: "/"))
    }
    func testUnixAndDOSLegacyListing() throws {
        let unix = "total 4\r\ndrwxr-xr-x 2 owner group 4096 Oct 21 12:01 folder\r\n-rw-r----- 1 owner group 12 Oct 21 2026 two words.txt\r\nlrwxrwxrwx 1 owner group 7 Oct 21 12:01 link -> /target\r\n"
        let entries = try FTPListing.legacy(Data(unix.utf8), directory: "/")
        XCTAssertEqual(entries.map(\.name), ["folder", "link", "two words.txt"])
        XCTAssertTrue(entries[1].isSymbolicLink)
        XCTAssertEqual(entries[2].size, 12)
        XCTAssertEqual(entries[2].permissions, 0o100640)
        XCTAssertNil(entries[2].modified)
        let dos = "10-21-26  12:01PM       <DIR>          folder\r\n10-21-2026  12:02PM                 123 file name.txt\r\n"
        let windows = try FTPListing.legacy(Data(dos.utf8), directory: "/")
        XCTAssertTrue(windows[0].isDirectory); XCTAssertEqual(windows[1].size, 123)
        XCTAssertThrowsError(try FTPListing.legacy(Data("unrecognized listing".utf8), directory: "/"))
    }
    func testFTPURLKeepsAbsolutePathsAndEscapesMetacharacters() throws {
        let site = Site(host: "localhost", port: 2121, transferProtocol: .ftp)
        let url = try FTPPath.url(site: site, path: "/space dir/a#b%?日本語.txt", directory: false)
        XCTAssertTrue(url.hasPrefix("ftp://localhost:2121//space%20dir/"))
        XCTAssertTrue(url.contains("%23")); XCTAssertTrue(url.contains("%25")); XCTAssertTrue(url.contains("%3F"))
        XCTAssertEqual(try FTPPath.normalize("../data/./file", relativeTo: "/home/user"), "/home/data/file")
        for path in ["\r\nDELE /important", "bad\0name", "bad\tname"] { XCTAssertThrowsError(try FTPPath.validate(path)) }
        let ipv6 = Site(host: "::1", port: 990, transferProtocol: .ftpsImplicit)
        XCTAssertTrue(try FTPPath.url(site: ipv6, path: "/", directory: true).hasPrefix("ftps://[::1]:990/"))
    }
    func testOldSavedSitesMigrateToSFTPWithoutLosingFields() throws {
        let original = Site(name: "Saved site", host: "example.com")
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "transferProtocol"); object.removeValue(forKey: "certificateAuthorityFile")
        let restored = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, original)
    }
    func testUnknownPermissionsAreNotInventedAndPortsFollowProtocol() throws {
        let entries = try FTPListing.mlsd(Data("type=file;size=5; example.txt\r\n".utf8), directory: "/")
        XCTAssertEqual(entries[0].rights, "—")
        XCTAssertFalse(entries[0].permissionsKnown)
        let prefixed = try FTPListing.mlsd(Data("type=file;size=1;unix.mode=0o640; example\r\n".utf8), directory: "/")
        XCTAssertEqual(prefixed[0].permissions & 0o777, 0o640)
        XCTAssertEqual(Site(transferProtocol: .ftp).port, 21)
        XCTAssertEqual(Site(transferProtocol: .ftpsExplicit).port, 21)
        XCTAssertEqual(Site(transferProtocol: .ftpsImplicit).port, 990)
        XCTAssertEqual(Site().port, 22)
    }
}
