// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Session-only S3 credentials; never encoded into saved sites.
struct S3Credentials: Sendable {
    let accessKey: String
    let secretKey: String
    let sessionToken: String
}

/// AWS Signature Version 4 for the S3 service, with signed (SHA-256) payloads.
enum S3Signer {
    static let emptyPayloadHash = hex(SHA256.hash(data: Data()))
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    static func hex(_ digest: SHA256.Digest) -> String { hex(Array(digest)) }

    /// RFC 3986 encoding used for both the request URL and the canonical request, so they cannot diverge.
    static func encode(_ value: String, keepSlash: Bool = false) -> String {
        value.addingPercentEncoding(withAllowedCharacters: keepSlash ? unreserved.union(CharacterSet(charactersIn: "/")) : unreserved)!
    }
    static func canonicalQuery(_ items: [(String, String)]) -> String {
        let pairs: [(String, String)] = items.map { (encode($0.0), encode($0.1)) }
        let sorted = pairs.sorted { (lhs: (String, String), rhs: (String, String)) -> Bool in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
        return sorted.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
    }
    static func timestamps(_ date: Date) -> (amzDate: String, day: String) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    /// `headers` uses lowercase names and must already contain host, x-amz-date and x-amz-content-sha256.
    static func authorization(method: String, encodedPath: String, canonicalQuery: String, headers: [String: String],
                              payloadHash: String, credentials: S3Credentials, region: String) -> String {
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { name in
            // Trim and collapse whitespace runs, as SigV4 requires.
            let value = headers[name]!.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            return "\(name):\(value)\n"
        }.joined()
        let signedHeaders = names.joined(separator: ";")
        let request = [method, encodedPath, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let amzDate = headers["x-amz-date"]!, day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(request.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data(("AWS4" + credentials.secretKey).utf8))
        for part in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(Array(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)))
        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    /// Streams `length` bytes at `offset` without moving the descriptor.
    static func digest(descriptor: Int32, offset: UInt64, length: UInt64, token: CancellationToken) throws -> SHA256.Digest {
        var hasher = SHA256(), done: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while done < length {
            try token.check()
            let wanted = Int(min(UInt64(buffer.count), length - done))
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, off_t(offset + done)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { throw ClientError.conflict("The local file became shorter while it was being read.") }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            done += UInt64(count)
        }
        return hasher.finalize()
    }
}

/// Minimal namespace-agnostic XML tree for bounded S3 responses; DTDs and entities are refused.
final class S3XMLNode {
    let name: String
    var text = ""
    var children: [S3XMLNode] = []
    init(name: String) { self.name = name }
    func child(_ name: String) -> S3XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [S3XMLNode] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text }
}

private final class S3XMLBuilder: NSObject, XMLParserDelegate {
    var root: S3XMLNode?
    var failure: Error?
    private var stack: [S3XMLNode] = []
    private var count = 0
    private func fail(_ parser: XMLParser, _ text: String) {
        if failure == nil { failure = ClientError.protocolError(text) }; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 16, count <= 2_000_000 else { fail(parser, "S3 XML exceeds nesting or element limits."); return }
        let node = S3XMLNode(name: name)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { fail(parser, "S3 XML has more than one root element."); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard let node = stack.last else { return }
        node.text += text
        if node.text.utf8.count > 65536 { fail(parser, "An S3 XML value exceeds 64 KiB.") }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { fail(parser, "Invalid UTF-8 XML CDATA."); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard !stack.isEmpty else { fail(parser, "Unbalanced S3 XML."); return }
        stack.removeLast()
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, "External XML entities are not allowed."); return nil
    }
}

enum S3XML {
    static func parse(_ data: Data) throws -> S3XMLNode {
        guard data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw ClientError.protocolError("S3 XML must be bounded UTF-8 without DTDs or entity declarations.")
        }
        let parser = XMLParser(data: data), builder = S3XMLBuilder()
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = builder
        let parsed = parser.parse()
        if let failure = builder.failure { throw failure }
        guard parsed, let root = builder.root else { throw ClientError.protocolError("Malformed S3 XML response.") }
        return root
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
