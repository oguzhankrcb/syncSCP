// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DAVPath {
    public static func normalize(_ path: String, relativeTo base: String = "/") throws -> String {
        for value in [path, base] {
            guard value.utf8.count <= 32768, value.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains("\\") else {
                throw ClientError.invalid("WebDAV paths cannot contain control characters or backslashes and must be at most 32 KiB.")
            }
        }
        let full = path.hasPrefix("/") ? path : RemotePath.join(base, path)
        var parts: [Substring] = []
        for part in full.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
    static func url(site: Site, path: String, directory: Bool = false) throws -> String {
        var components = URLComponents()
        components.scheme = site.transferProtocol == .webdavs ? "https" : "http"
        components.host = site.host.contains(":") && !site.host.hasPrefix("[") ? "[\(site.host)]" : site.host
        components.port = site.port == site.transferProtocol.defaultPort ? nil : site.port
        let path = try normalize(path)
        components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! + (directory && path != "/" ? "/" : "")
        guard let url = components.url?.absoluteString else { throw ClientError.invalid("Cannot form the WebDAV URL.") }
        return url
    }
    static func reference(site: Site, path: String, directory: Bool = false) throws -> String {
        URLComponents(string: try url(site: site, path: path, directory: directory))!.percentEncodedPath
    }
    static func href(_ value: String, site: Site) throws -> String {
        guard let components = URLComponents(string: value), components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil, components.percentEncodedPath.hasPrefix("/") else {
            throw ClientError.protocolError("Invalid WebDAV resource URL.")
        }
        if components.scheme != nil || components.host != nil {
            let origin = URLComponents(string: try url(site: site, path: "/"))!
            guard components.scheme?.lowercased() == origin.scheme, components.host?.lowercased() == origin.host?.lowercased(),
                  (components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)) == (origin.port ?? site.transferProtocol.defaultPort) else {
                throw ClientError.protocolError("WebDAV returned a resource on another origin.")
            }
        }
        let encoded = components.percentEncodedPath
        guard !encoded.lowercased().contains("%2f"), !encoded.lowercased().contains("%5c"), let decoded = encoded.removingPercentEncoding,
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ClientError.protocolError("WebDAV returned an ambiguous or traversing resource path.")
        }
        return try normalize(decoded)
    }
}

enum DAVETag {
    static func valid(_ value: String) -> Bool {
        let tag = value.hasPrefix("W/") ? String(value.dropFirst(2)) : value
        guard tag.utf8.count >= 2, tag.first == "\"", tag.last == "\"" else { return false }
        return tag.dropFirst().dropLast().utf8.allSatisfy { $0 == 33 || (35...126).contains($0) }
    }
    static func property(_ value: String) -> String? {
        if valid(value) { return value }
        // Some deployed servers, including WsgiDAV, omit quotes in getetag XML.
        // Normalize only an unambiguous opaque tag; never promote an unquoted weak tag.
        guard !value.isEmpty, !value.hasPrefix("W/"), valid("\"" + value + "\"") else { return nil }
        return "\"" + value + "\""
    }
    static func strong(_ value: String?) -> String? {
        guard let value, !value.hasPrefix("W/"), valid(value) else { return nil }; return value
    }
}

private struct DAVRecord {
    var href: String?
    var status: Int?
    var properties: [String: String] = [:]
}
private final class DAVXMLParser: NSObject, XMLParserDelegate {
    struct Node { let namespace: String; let name: String; var text = "" }
    var records: [DAVRecord] = []
    var failure: Error?
    private var stack: [Node] = []
    private var record: DAVRecord?
    private var properties: [String: String]?
    private var propertyStatus: Int?
    private var resourceType = "file"
    private var count = 0
    private func fail(_ parser: XMLParser, _ text: String) {
        if failure == nil { failure = ClientError.protocolError(text) }; parser.abortParsing()
    }
    private func matches(_ names: [String]) -> Bool {
        stack.count == names.count && zip(stack, names).allSatisfy { $0.namespace == "DAV:" && $0.name == $1 }
    }
    private func status(_ value: String, parser: XMLParser) -> Int? {
        let fields = value.split(separator: " ")
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), fields[1].count == 3,
              fields[1].utf8.allSatisfy({ (48...57).contains($0) }), let code = Int(fields[1]) else { fail(parser, "Invalid WebDAV status line."); return nil }
        return code
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 1_000_000 else { fail(parser, "WebDAV XML exceeds nesting or element limits."); return }
        stack.append(Node(namespace: namespaceURI ?? "", name: name))
        if stack.count == 1, !matches(["multistatus"]) { fail(parser, "Expected a DAV:multistatus response."); return }
        if matches(["multistatus", "response"]) { record = DAVRecord() }
        if matches(["multistatus", "response", "propstat"]) { properties = [:]; propertyStatus = nil }
        if matches(["multistatus", "response", "propstat", "prop", "resourcetype"]) { resourceType = "file" }
        if stack.count == 6, stack[4].namespace == "DAV:", stack[4].name == "resourcetype" {
            if name == "collection", namespaceURI == "DAV:" { resourceType = "collection" }
            else if resourceType != "collection" { resourceType = "unknown" }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard !stack.isEmpty, ["href", "status", "getcontentlength", "getlastmodified", "getetag"].contains(stack.last!.name) else { return }
        stack[stack.count - 1].text += text
        if stack.last!.text.utf8.count > 32768 { fail(parser, "A WebDAV XML value exceeds 32 KiB.") }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { fail(parser, "Invalid UTF-8 XML CDATA."); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.last else { fail(parser, "Unbalanced WebDAV XML."); return }
        let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(["multistatus", "response", "href"]) {
            if record?.href != nil { fail(parser, "Duplicate WebDAV resource URL.") }
            record?.href = value
        } else if matches(["multistatus", "response", "status"]) {
            if record?.status != nil { fail(parser, "Duplicate WebDAV response status.") }
            record?.status = status(value, parser: parser)
        }
        else if matches(["multistatus", "response", "propstat", "status"]) {
            if propertyStatus != nil { fail(parser, "Duplicate WebDAV property status.") }
            propertyStatus = status(value, parser: parser)
        }
        else if stack.count == 5, stack.allSatisfy({ $0.namespace == "DAV:" }), stack[3].name == "prop",
                ["resourcetype", "getcontentlength", "getlastmodified", "getetag"].contains(name) {
            if properties?[name] != nil { fail(parser, "Duplicate WebDAV property.") }
            properties?[name] = name == "resourcetype" ? resourceType : value
        } else if matches(["multistatus", "response", "propstat"]) {
            guard let propertyStatus else { fail(parser, "Missing WebDAV property status."); return }
            if (200...299).contains(propertyStatus) {
                for (key, value) in properties ?? [:] {
                    if record?.properties[key] != nil { fail(parser, "Duplicate successful WebDAV property.") }
                    record?.properties[key] = value
                }
            }
            properties = nil
        } else if matches(["multistatus", "response"]) {
            guard let record, record.href != nil, records.count < 100_000 else { fail(parser, "Missing WebDAV URL or too many responses."); return }
            records.append(record); self.record = nil
        }
        stack.removeLast()
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, "External XML entities are not allowed."); return nil
    }
}

enum WebDAVListing {
    static let requestBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>".utf8)
    static func decode(_ data: Data, site: Site, path: String, depth: Int) throws -> [FileEntry] {
        guard data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw ClientError.protocolError("WebDAV XML must be bounded UTF-8 without DTDs or entity declarations.")
        }
        let parser = XMLParser(data: data), delegate = DAVXMLParser()
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard parsed else { throw ClientError.protocolError("Malformed WebDAV XML response.") }
        var entries: [FileEntry] = [], seen = Set<String>()
        let path = try DAVPath.normalize(path)
        for record in delegate.records {
            let resource = try DAVPath.href(record.href!, site: site)
            guard resource == path || (depth == 1 && RemotePath.parent(resource) == path), seen.insert(resource).inserted else {
                throw ClientError.protocolError("WebDAV returned an out-of-scope or duplicate resource.")
            }
            if let code = record.status, !(200...299).contains(code) { throw ClientError.remote("WebDAV", code, "A resource in the listing could not be read.") }
            guard let type = record.properties["resourcetype"] else { throw ClientError.unsupported("The WebDAV server omitted resource types.") }
            let mode: UInt32 = type == "collection" ? 0o040000 : type == "file" ? 0o100000 : 0
            var size: UInt64 = 0
            if mode == 0o100000 {
                guard let value = record.properties["getcontentlength"], !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }), let length = UInt64(value) else { throw ClientError.unsupported("The WebDAV server omitted a valid file size.") }
                size = length
            }
            var modified: Date?
            if let value = record.properties["getlastmodified"], !value.isEmpty {
                modified = date(value)
                guard modified != nil else { throw ClientError.protocolError("Invalid WebDAV modification time.") }
            }
            var tag: String?
            if let raw = record.properties["getetag"], !raw.isEmpty {
                guard let normalized = DAVETag.property(raw) else { throw ClientError.protocolError("Invalid WebDAV entity tag.") }
                tag = normalized
            }
            entries.append(FileEntry(path: resource, name: resource == "/" ? "/" : (resource as NSString).lastPathComponent,
                                     size: size, permissions: mode, modified: modified, permissionsKnown: false, versionTag: tag))
        }
        guard seen.contains(path) else { throw ClientError.protocolError("WebDAV omitted the requested resource.") }
        return entries.sorted(by: LocalFiles.order)
    }
    private static func date(_ value: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format; formatter.isLenient = false
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
