// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

final class WebDAVListingTests: XCTestCase {
    private let site = Site(host: "example.com", username: "test", transferProtocol: .webdavs)
    private func resource(_ href: String, collection: Bool = false, properties: String = "") -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(collection ? "<d:collection/>" : "")</d:resourcetype>\(collection ? "" : "<d:getcontentlength>42</d:getcontentlength>")<d:getlastmodified>Tue, 14 Nov 2023 22:13:20 GMT</d:getlastmodified><d:getetag>&quot;version-1&quot;</d:getetag>\(properties)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
    private func xml(_ body: String) -> Data { Data(("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">" + body + "</d:multistatus>").utf8) }
    func testNamespaceAwareMetadataKeepsEncodedNamesTypesETagsAndUnknownPermissions() throws {
        let data = xml(resource("/dav/", collection: true) + resource("https://example.com/dav/%C4%B0stanbul%20%26%20%25%3F%23.txt"))
        let entries = try WebDAVListing.decode(data, site: site, path: "/dav", depth: 1)
        XCTAssertTrue(entries[0].isDirectory)
        let file = entries[1]
        XCTAssertEqual(file.name, "İstanbul & %?#.txt"); XCTAssertEqual(file.size, 42)
        XCTAssertEqual(file.modified, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(file.versionTag, "\"version-1\""); XCTAssertFalse(file.permissionsKnown); XCTAssertEqual(file.rights, "—")
        XCTAssertTrue(file.isRegularFile)
        let alternate = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "d:", with: "x:").replacingOccurrences(of: "xmlns:d", with: "xmlns:x")
        XCTAssertEqual(try WebDAVListing.decode(Data(alternate.utf8), site: site, path: "/dav", depth: 1), entries)
    }
    func testFailedOptionalPropertiesAreIgnoredAndCDATAIsSupported() throws {
        let text = resource("/dav/a").replacingOccurrences(of: "<d:href>/dav/a</d:href>", with: "<d:href><![CDATA[/dav/a]]></d:href>").replacingOccurrences(of: "<d:getetag>&quot;version-1&quot;</d:getetag>", with: "")
        let extra = "<d:propstat><d:prop><d:getetag>invalid ignored value</d:getetag></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>"
        let entries = try WebDAVListing.decode(xml(text.replacingOccurrences(of: "</d:response>", with: extra + "</d:response>")), site: site, path: "/dav/a", depth: 0)
        XCTAssertNil(entries[0].versionTag); XCTAssertEqual(entries[0].size, 42)
    }
    func testUntrustedXMLTraversalForeignURLsAndDuplicateResourcesAreRejected() throws {
        for href in ["https://other.example/dav/a", "http://example.com/dav/a", "/outside/file", "/dav/../secret", "/dav/%2e%2e/secret", "/dav/a%2Fsecret", "/dav/a%5Csecret", "/dav/a?query=1", "/dav/a#fragment", "relative"] {
            XCTAssertThrowsError(try WebDAVListing.decode(xml(resource("/dav", collection: true) + resource(href)), site: site, path: "/dav", depth: 1), href)
        }
        for data in [
            xml(resource("/dav/a") + resource("/dav/a")),
            xml(resource("/dav/a").replacingOccurrences(of: "42", with: "-1")),
            xml(resource("/dav/a").replacingOccurrences(of: "Tue, 14 Nov 2023 22:13:20 GMT", with: "invalid date")),
            Data("<!DOCTYPE x [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><x>&leak;</x>".utf8),
            Data("<!DOCTYPE x [<!ENTITY a 'many'>]><x>&a;</x>".utf8),
            Data("<d:multistatus xmlns:d='wrong:'/>".utf8),
            Data("<x>truncated".utf8),
            Data("\0<xml/>".utf8),
            xml(String(repeating: "<deep>", count: 33) + String(repeating: "</deep>", count: 33))
        ] {
            XCTAssertThrowsError(try WebDAVListing.decode(data, site: site, path: "/dav/a", depth: 0))
        }
    }
    func testFailedResourcesAndMissingRequiredMetadataCannotBecomeEmptySuccess() throws {
        let missing = xml("<d:response><d:href>/dav/a</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>")
        do { _ = try WebDAVListing.decode(missing, site: site, path: "/dav/a", depth: 0); XCTFail("Ignored resource failure") }
        catch ClientError.remote(_, 404, _) { }
        for text in ["", resource("/dav/a").replacingOccurrences(of: "<d:resourcetype></d:resourcetype>", with: ""), resource("/dav/a").replacingOccurrences(of: "<d:getcontentlength>42</d:getcontentlength>", with: ""), resource("/dav/a").replacingOccurrences(of: "HTTP/1.1 200 OK", with: "HTTP/1.1 404 Not Found")] {
            XCTAssertThrowsError(try WebDAVListing.decode(xml(text), site: site, path: "/dav/a", depth: 0))
        }
    }
    func testPathEscapingDefaultsAndETagConflictComparison() throws {
        let path = "/dav/İstanbul space%?#&+'\".txt"
        let url = try DAVPath.url(site: site, path: path)
        XCTAssertEqual(try DAVPath.href(url, site: site), path)
        XCTAssertEqual(try DAVPath.href("https://example.com:443/dav", site: site), "/dav")
        XCTAssertFalse(url.contains(":443"))
        XCTAssertTrue(url.contains("%25%3F%23%26%2B")); XCTAssertFalse(url.contains("@"))
        XCTAssertEqual(try DAVPath.normalize("../child", relativeTo: "/dav/folder"), "/dav/child")
        for path in ["/line\nbreak", "/a\\b", "/nul\0byte"] { XCTAssertThrowsError(try DAVPath.normalize(path)) }
        XCTAssertEqual(TransferProtocol.webdav.defaultPort, 80); XCTAssertFalse(TransferProtocol.webdav.isEncrypted)
        XCTAssertEqual(TransferProtocol.webdavs.defaultPort, 443); XCTAssertTrue(TransferProtocol.webdavs.isEncrypted)
        XCTAssertTrue(TransferProtocol.webdavs.usesWebDAV); XCTAssertFalse(TransferProtocol.webdav.usesFTP)
        let value = Site(host: "example.com", transferProtocol: .webdavs)
        XCTAssertEqual(try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(value)), value)
        var first = FileEntry(path: "/dav/a", name: "a", versionTag: "\"one\"")
        var second = first; second.versionTag = "\"two\""
        XCTAssertFalse(first.hasSameVersion(as: second))
        first.versionTag = nil; second.versionTag = nil; XCTAssertTrue(first.hasSameVersion(as: second))
        XCTAssertEqual(DAVETag.property("opaque-without-quotes"), "\"opaque-without-quotes\""); XCTAssertNil(DAVETag.property("W/unquoted-weak"))
        XCTAssertNotNil(DAVETag.strong("\"safe\"")); XCTAssertNil(DAVETag.strong("W/\"weak\""))
        for tag in ["unquoted", "\"nested\"quote\"", "\"newline\n\"", "\"space inside\"", "\"\r\nInjected: yes\""] { XCTAssertFalse(DAVETag.valid(tag)) }
    }
    func testPartialOperationAndRedirectStatusesNeverReportSuccess() throws {
        for code in [207, 301, 302, 401, 403, 423, 507] {
            XCTAssertThrowsError(try DAVHTTPResponse(status: code, body: Data(), headers: [:]).require([200, 201, 204]))
        }
        do { try DAVHTTPResponse(status: 412, body: Data(), headers: [:]).require([201]); XCTFail("Ignored conditional failure") } catch ClientError.conflict { }
    }
}
