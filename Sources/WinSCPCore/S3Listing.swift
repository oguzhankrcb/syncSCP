// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Maps the application's paths onto S3: `/` lists buckets, `/bucket/a/b` is key `a/b`.
struct S3Location: Equatable {
    let bucket: String?
    let key: String
    /// Raw keys from listings are used verbatim; they are never re-normalized as paths.
    init(bucket: String?, key: String = "") throws {
        if let bucket, bucket.isEmpty || bucket.utf8.count > 255 || bucket.contains("/") { throw ClientError.invalid("Invalid S3 bucket name.") }
        guard key.utf8.count <= 1024, bucket != nil || key.isEmpty else { throw ClientError.invalid("S3 object keys are limited to 1024 bytes.") }
        self.bucket = bucket; self.key = key
    }
    init(_ path: String) throws {
        let parts = try DAVPath.normalize(path).split(separator: "/").map(String.init)
        try self.init(bucket: parts.first, key: parts.dropFirst().joined(separator: "/"))
    }
    /// Prefix that lists this location as a folder.
    var folderPrefix: String { key.isEmpty ? "" : key + "/" }
}

struct S3Endpoint {
    let site: Site
    var secure: Bool { site.transferProtocol == .s3 }
    private var hostIsLiteral: Bool {
        let host = site.host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.contains(":") { return true }
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }
    private func authority(_ host: String) -> String {
        let literal = site.host.contains(":") && !site.host.hasPrefix("[") ? "[\(host)]" : host
        return site.port == site.transferProtocol.defaultPort ? literal : "\(literal):\(site.port)"
    }
    /// Virtual-hosted requests need a DNS label; TLS wildcard certificates also cannot match dotted buckets.
    func usesPathStyle(_ bucket: String) -> Bool {
        let bytes = Array(bucket.utf8)
        let dnsLabel = (3...63).contains(bytes.count) && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
            && bytes.first != 45 && bytes.last != 45 && bytes.first != 46 && bytes.last != 46 && !bucket.contains("..")
        return site.s3PathStyle || hostIsLiteral || !dnsLabel || (secure && bucket.contains("."))
    }
    /// Returns the Host header value and the encoded path; both are what gets signed.
    func target(_ location: S3Location, trailingSlash: Bool = false) -> (authority: String, path: String) {
        let key = S3Signer.encode(location.key, keepSlash: true) + (trailingSlash ? "/" : "")
        guard let bucket = location.bucket else { return (authority(site.host), "/") }
        if usesPathStyle(bucket) {
            return (authority(site.host), "/" + S3Signer.encode(bucket) + (key.isEmpty ? "" : "/" + key))
        }
        return (authority(bucket + "." + site.host), "/" + key)
    }
    func url(authority: String, path: String, query: String) -> String {
        (secure ? "https://" : "http://") + authority + path + (query.isEmpty ? "" : "?" + query)
    }
}

struct S3Object: Equatable {
    let key: String
    let size: UInt64
    let modified: Date?
    let etag: String?
}

struct S3ListPage {
    var objects: [S3Object] = []
    var prefixes: [String] = []
    var nextToken: String?
}

struct S3ErrorDetail: Equatable {
    var code = ""
    var message = ""
    var region: String?
}

enum S3Listing {
    static func buckets(_ data: Data) throws -> [FileEntry] {
        let root = try S3XML.parse(data)
        guard root.name == "ListAllMyBucketsResult" else { throw ClientError.protocolError("Expected an S3 bucket list.") }
        var seen = Set<String>()
        return try (root.child("Buckets")?.all("Bucket") ?? []).compactMap { bucket in
            guard let name = bucket.value("Name"), !name.isEmpty else { throw ClientError.protocolError("S3 returned a bucket without a name.") }
            guard representable(name), seen.insert(name).inserted else { return nil }
            return FileEntry(path: "/" + name, name: name, permissions: 0o040000, modified: bucket.value("CreationDate").flatMap(date), permissionsKnown: false)
        }.sorted(by: LocalFiles.order)
    }

    static func page(_ data: Data, prefix: String) throws -> S3ListPage {
        let root = try S3XML.parse(data)
        guard root.name == "ListBucketResult" else { throw ClientError.protocolError("Expected an S3 object list.") }
        let encoded = root.value("EncodingType")?.lowercased() == "url"
        func decode(_ value: String) throws -> String {
            guard encoded else { return value }
            // URL encoding-type uses form encoding: '+' is a space, a literal '+' arrives as %2B.
            guard let text = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw ClientError.protocolError("Invalid URL-encoded S3 key.") }
            return text
        }
        var page = S3ListPage()
        for item in root.all("Contents") {
            guard let raw = item.value("Key"), let sizeText = item.value("Size"), !sizeText.isEmpty,
                  sizeText.utf8.allSatisfy({ (48...57).contains($0) }), let size = UInt64(sizeText) else {
                throw ClientError.protocolError("S3 returned an object without a valid key or size.")
            }
            let key = try decode(raw)
            guard key.hasPrefix(prefix) else { throw ClientError.protocolError("S3 returned an object outside the requested folder.") }
            var tag: String?
            if let value = item.value("ETag"), !value.isEmpty {
                guard let normalized = DAVETag.property(value) else { throw ClientError.protocolError("Invalid S3 entity tag.") }
                tag = normalized
            }
            page.objects.append(S3Object(key: key, size: size, modified: item.value("LastModified").flatMap(date), etag: tag))
        }
        for item in root.all("CommonPrefixes") {
            guard let raw = item.value("Prefix") else { throw ClientError.protocolError("S3 returned a folder without a prefix.") }
            let value = try decode(raw)
            guard value.hasPrefix(prefix), value.hasSuffix("/") else { throw ClientError.protocolError("S3 returned a folder outside the requested folder.") }
            page.prefixes.append(value)
        }
        if root.value("IsTruncated")?.lowercased() == "true" {
            guard let token = root.value("NextContinuationToken"), !token.isEmpty else { throw ClientError.protocolError("S3 truncated a listing without a continuation token.") }
            page.nextToken = token
        }
        return page
    }

    /// Builds the visible folder from one level of objects and common prefixes.
    /// Keys that cannot be addressed as a path (empty, `.`, `..`, control characters,
    /// backslashes) and objects shadowed by a same-named folder are not shown.
    static func entries(objects: [S3Object], prefixes: [String], folder: String, prefix: String) -> [FileEntry] {
        var entries: [FileEntry] = [], names = Set<String>()
        for value in prefixes {
            let name = String(value.dropFirst(prefix.count).dropLast())
            guard representable(name), names.insert(name).inserted else { continue }
            entries.append(FileEntry(path: RemotePath.join(folder, name), name: name, permissions: 0o040000, permissionsKnown: false))
        }
        for object in objects {
            let name = String(object.key.dropFirst(prefix.count))
            guard representable(name), !name.contains("/"), names.insert(name).inserted else { continue }
            entries.append(FileEntry(path: RemotePath.join(folder, name), name: name, size: object.size, permissions: 0o100000,
                                     modified: object.modified, permissionsKnown: false, versionTag: object.etag))
        }
        return entries.sorted(by: LocalFiles.order)
    }

    static func representable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("\\") && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func error(_ data: Data) -> S3ErrorDetail? {
        guard !data.isEmpty, let root = try? S3XML.parse(data), root.name == "Error" else { return nil }
        func clean(_ value: String?) -> String {
            String((value ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(300))
        }
        let region = clean(root.value("Region"))
        return S3ErrorDetail(code: clean(root.value("Code")), message: clean(root.value("Message")), region: region.isEmpty ? nil : region)
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value)
    }
}
