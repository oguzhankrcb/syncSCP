// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WinSCPCore

final class S3Tests: XCTestCase {
    /// Published examples from the AWS S3 SigV4 header-authentication documentation.
    func testSignatureVersion4MatchesPublishedExamples() {
        let credentials = S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: "")
        func signature(_ path: String, _ query: [(String, String)], extra: [String: String] = [:]) -> String {
            var headers = extra
            headers["host"] = "examplebucket.s3.amazonaws.com"; headers["x-amz-date"] = "20130524T000000Z"
            headers["x-amz-content-sha256"] = S3Signer.emptyPayloadHash
            let value = S3Signer.authorization(method: "GET", encodedPath: path, canonicalQuery: S3Signer.canonicalQuery(query), headers: headers,
                                               payloadHash: S3Signer.emptyPayloadHash, credentials: credentials, region: "us-east-1")
            return String(value.split(separator: "=").last!)
        }
        XCTAssertEqual(signature("/test.txt", [], extra: ["range": "bytes=0-9"]), "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual(signature("/", [("lifecycle", "")]), "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
        XCTAssertEqual(signature("/", [("prefix", "J"), ("max-keys", "2")]), "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
        XCTAssertEqual(S3Signer.emptyPayloadHash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testCanonicalQueryAndKeyEncoding() {
        XCTAssertEqual(S3Signer.canonicalQuery([("prefix", "a b/ç+"), ("delimiter", "/"), ("uploads", ""), ("a", "2"), ("a", "1")]),
                       "a=1&a=2&delimiter=%2F&prefix=a%20b%2F%C3%A7%2B&uploads=")
        XCTAssertEqual(S3Signer.encode("dir/a b~_.-+=;?#%.txt", keepSlash: true), "dir/a%20b~_.-%2B%3D%3B%3F%23%25.txt")
        XCTAssertEqual(S3Signer.timestamps(Date(timeIntervalSince1970: 1369353600)).amzDate, "20130524T000000Z")
    }

    func testEndpointAddressingStyles() throws {
        let aws = Site(host: "s3.eu-west-1.amazonaws.com", username: "AKIA", transferProtocol: .s3)
        var target = S3Endpoint(site: aws).target(try S3Location("/photos/2026/a b.jpg"))
        XCTAssertEqual(target.authority, "photos.s3.eu-west-1.amazonaws.com"); XCTAssertEqual(target.path, "/2026/a%20b.jpg")
        target = S3Endpoint(site: aws).target(try S3Location("/my.dotted.bucket/x"))
        XCTAssertEqual(target.authority, "s3.eu-west-1.amazonaws.com"); XCTAssertEqual(target.path, "/my.dotted.bucket/x")
        target = S3Endpoint(site: aws).target(try S3Location("/"))
        XCTAssertEqual(target.authority, "s3.eu-west-1.amazonaws.com"); XCTAssertEqual(target.path, "/")
        var local = Site(host: "localhost", port: 9000, username: "k", transferProtocol: .s3http)
        target = S3Endpoint(site: local).target(try S3Location("/bucket/folder"), trailingSlash: true)
        XCTAssertEqual(target.authority, "localhost:9000"); XCTAssertEqual(target.path, "/bucket/folder/")
        XCTAssertEqual(S3Endpoint(site: local).url(authority: target.authority, path: target.path, query: "a=1"), "http://localhost:9000/bucket/folder/?a=1")
        local.host = "::1"
        XCTAssertEqual(S3Endpoint(site: local).target(try S3Location("/bucket")).authority, "[::1]:9000")
        var forced = aws; forced.s3PathStyle = true
        XCTAssertEqual(S3Endpoint(site: forced).target(try S3Location("/photos/a")).path, "/photos/a")
        XCTAssertTrue(S3Endpoint(site: aws).usesPathStyle("Upper_Case"))
    }

    func testLocationsAndSiteCompatibility() throws {
        XCTAssertNil(try S3Location("/").bucket)
        let location = try S3Location("/bucket/a/./b/../c")
        XCTAssertEqual(location.bucket, "bucket"); XCTAssertEqual(location.key, "a/c"); XCTAssertEqual(location.folderPrefix, "a/c/")
        XCTAssertEqual(try S3Location(bucket: "b", key: "odd//x/./y").key, "odd//x/./y")
        XCTAssertThrowsError(try S3Location("/b/" + String(repeating: "k", count: 1025)))
        let legacy = Data(#"[{"id":"\#(UUID().uuidString)","name":"","host":"h","port":22,"username":"u","privateKey":"","remotePath":".","localPath":"/"}]"#.utf8)
        let decoded = try JSONDecoder().decode([Site].self, from: legacy)[0]
        XCTAssertEqual(decoded.transferProtocol, .sftp); XCTAssertEqual(decoded.s3Region, ""); XCTAssertFalse(decoded.s3PathStyle)
        let site = Site(host: "s3.amazonaws.com", username: "AKIA", remotePath: "/bucket", transferProtocol: .s3, s3Region: "eu-central-1", s3PathStyle: true)
        let round = try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site))
        XCTAssertEqual(round, site)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(site), as: UTF8.self).lowercased().contains("secret"))
        XCTAssertNoThrow(try site.validate())
        var invalid = site; invalid.s3Region = "EU_West"
        XCTAssertThrowsError(try invalid.validate())
        invalid = site; invalid.username = "key with space"
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(TransferProtocol.s3.defaultPort, 443); XCTAssertEqual(TransferProtocol.s3http.defaultPort, 80)
        XCTAssertTrue(TransferProtocol.s3.isEncrypted); XCTAssertFalse(TransferProtocol.s3http.isEncrypted)
        XCTAssertFalse(TransferProtocol.s3.supportsPermissions); XCTAssertTrue(TransferProtocol.sftp.supportsPermissions)
        XCTAssertEqual(TransferProtocol.s3http.shortTitle, "S3")
    }

    func testListingDecodingAndVisibilityRules() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name><EncodingType>url</EncodingType>
        <IsTruncated>true</IsTruncated><NextContinuationToken>tok/en==</NextContinuationToken>
        <Contents><Key>dir/</Key><Size>0</Size><ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag></Contents>
        <Contents><Key>dir/a+b%2Bc.txt</Key><Size>12</Size><LastModified>2026-10-21T14:23:33.720Z</LastModified><ETag>"abc"</ETag></Contents>
        <Contents><Key>dir/same</Key><Size>1</Size></Contents>
        <Contents><Key>dir/back%5Cslash</Key><Size>1</Size></Contents>
        <Contents><Key>dir/%01control</Key><Size>1</Size></Contents>
        <CommonPrefixes><Prefix>dir/same/</Prefix></CommonPrefixes>
        <CommonPrefixes><Prefix>dir//</Prefix></CommonPrefixes>
        <CommonPrefixes><Prefix>dir/./</Prefix></CommonPrefixes>
        <CommonPrefixes><Prefix>dir/%E6%97%A5%E6%9C%AC/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = try S3Listing.page(Data(xml.utf8), prefix: "dir/")
        XCTAssertEqual(page.nextToken, "tok/en==")
        XCTAssertEqual(page.objects.map(\.key), ["dir/", "dir/a b+c.txt", "dir/same", "dir/back\\slash", "dir/\u{1}control"])
        XCTAssertEqual(page.objects[1].etag, "\"abc\""); XCTAssertNotNil(page.objects[1].modified)
        let entries = S3Listing.entries(objects: page.objects, prefixes: page.prefixes, folder: "/b/dir", prefix: "dir/")
        XCTAssertEqual(entries.map(\.name), ["same", "日本", "a b+c.txt"])
        XCTAssertTrue(entries[0].isDirectory); XCTAssertEqual(entries[2].path, "/b/dir/a b+c.txt"); XCTAssertFalse(entries[2].permissionsKnown)
        XCTAssertThrowsError(try S3Listing.page(Data(xml.replacingOccurrences(of: "dir/same/", with: "other/").utf8), prefix: "dir/"))
        XCTAssertThrowsError(try S3Listing.page(Data(xml.replacingOccurrences(of: "<NextContinuationToken>tok/en==</NextContinuationToken>", with: "").utf8), prefix: "dir/"))
        XCTAssertThrowsError(try S3Listing.page(Data(("<!DOCTYPE x [<!ENTITY e \"x\">]>" + xml).utf8), prefix: "dir/"))
        XCTAssertThrowsError(try S3Listing.page(Data("<ListBucketResult><Contents><Key>dir/x</Key><Size>-1</Size></Contents></ListBucketResult>".utf8), prefix: "dir/"))
        XCTAssertThrowsError(try S3Listing.page(Data("<Error/>".utf8), prefix: ""))
        let buckets = try S3Listing.buckets(Data("<ListAllMyBucketsResult><Buckets><Bucket><Name>zeta</Name><CreationDate>2026-01-01T00:00:00Z</CreationDate></Bucket><Bucket><Name>alpha</Name></Bucket></Buckets></ListAllMyBucketsResult>".utf8))
        XCTAssertEqual(buckets.map(\.path), ["/alpha", "/zeta"]); XCTAssertTrue(buckets.allSatisfy(\.isDirectory))
    }

    func testErrorDocuments() {
        let detail = S3Listing.error(Data("<Error><Code>AuthorizationHeaderMalformed</Code><Message>wrong\nregion</Message><Region>eu-west-1</Region></Error>".utf8))
        XCTAssertEqual(detail, S3ErrorDetail(code: "AuthorizationHeaderMalformed", message: "wrongregion", region: "eu-west-1"))
        XCTAssertNil(S3Listing.error(Data("<CopyObjectResult/>".utf8)))
        XCTAssertNil(S3Listing.error(Data()))
        XCTAssertEqual(S3XML.escape("\"a&b<c>\""), "\"a&amp;b&lt;c&gt;\"")
    }
}
