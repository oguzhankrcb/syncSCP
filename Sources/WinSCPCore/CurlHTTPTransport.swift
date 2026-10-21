// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CCurlTransport

struct DAVHTTPResponse {
    let status: Int
    let body: Data
    let headers: [String: String]
    func require(_ statuses: Set<Int>) throws {
        guard statuses.contains(status) else {
            if status == 412 { throw ClientError.conflict("The WebDAV destination or version changed. Refresh and review the operation again.") }
            let detail: String
            switch status {
            case 401: detail = "Authentication failed. Check the username and password. This preview supports HTTP Basic authentication."
            case 403: detail = "The server denied permission for this operation."
            case 404: detail = "The requested resource does not exist."
            case 405, 501: detail = "The server does not support this WebDAV method."
            case 409: detail = "The parent collection is missing or the resource types conflict."
            case 423: detail = "The resource is locked. Lock management is not supported yet."
            case 507: detail = "The server has insufficient storage."
            case 207: detail = "The server reported a multi-status operation. Some resources may be unchanged; refresh the directory before retrying."
            case 300...399: detail = "The server redirected the request. Enter the canonical WebDAV host and folder; redirects are not followed automatically."
            default: detail = "The WebDAV server rejected or did not complete the operation."
            }
            throw ClientError.remote("WebDAV", status, detail)
        }
    }
}

/// Owned by one WebDAV actor; credentials and the libcurl connection cache are session-scoped.
final class CurlHTTPTransport {
    private let handle: OpaquePointer
    private let site: Site
    private let password: String
    init(site: Site, password: String) throws {
        guard !password.contains("\0") else { throw ClientError.invalid("A password cannot contain a null character.") }
        guard let handle = ws_curl_create() else { throw ClientError.connection("Cannot initialize the system HTTP transport.") }
        self.handle = handle; self.site = site; self.password = password
    }
    deinit { ws_curl_destroy(handle) }
    func perform(path: String, directory: Bool = false, method: String, headers: [String] = [], body: Data = Data(),
                 operation: Int32 = 0, file: Int32 = -1, size: UInt64 = 0, token: CancellationToken = CancellationToken(),
                 progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws -> DAVHTTPResponse {
        try token.check()
        guard size <= UInt64(Int64.max) else { throw ClientError.unsupported("The file is too large for HTTP transfer.") }
        for header in headers {
            guard !header.contains("\r"), !header.contains("\n"), !header.contains("\0") else { throw ClientError.invalid("Invalid HTTP header value.") }
        }
        let arena = CStringArena()
        var request = WSHTTPRequest()
        request.url = try arena.store(DAVPath.url(site: site, path: path, directory: directory))
        request.username = try arena.store(site.username); request.password = try arena.store(password)
        request.ca_file = try arena.store((site.certificateAuthorityFile as NSString).expandingTildeInPath)
        request.method = try arena.store(method); request.operation = operation
        request.file_descriptor = file; request.upload_size = Int64(size); request.use_tls = site.transferProtocol.isEncrypted ? 1 : 0
        let pointers: [UnsafePointer<CChar>?] = try (headers + ["Expect:"]).map { try arena.store($0) }
        let context = CurlProgress(token: token, update: progress)
        var result = WSHTTPResult()
        withExtendedLifetime((arena, context)) { pointers.withUnsafeBufferPointer { pointers in body.withUnsafeBytes { bytes in
            request.headers = pointers.baseAddress; request.header_count = pointers.count
            request.body = bytes.bindMemory(to: UInt8.self).baseAddress; request.body_size = bytes.count
            ws_http_perform(handle, &request, { opaque, total, done in
                guard let opaque else { return 1 }
                let context = Unmanaged<CurlProgress>.fromOpaque(opaque).takeUnretainedValue()
                if context.token.isCancelled { return 1 }
                context.update(UInt64(max(0, done)), UInt64(max(0, total))); return 0
            }, Unmanaged.passUnretained(context).toOpaque(), &result)
        } } }
        defer { ws_http_result_free(&result) }
        try token.check()
        if result.response.local_errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: result.response.local_errno) ?? .EIO) }
        if result.response.body_too_large != 0 { throw ClientError.unsupported("WebDAV responses are limited to 16 MB and headers to 256 KiB.") }
        if result.response.code != 0 {
            let message = withUnsafePointer(to: &result.response.error) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            throw ClientError.connection("\(site.transferProtocol.shortTitle): \(password.isEmpty ? message : message.replacingOccurrences(of: password, with: "••••"))")
        }
        let data = result.response.body.map { Data(bytes: $0, count: result.response.body_size) } ?? Data()
        let headerData = result.headers.map { Data(bytes: $0, count: result.headers_size) } ?? Data()
        guard let text = String(data: headerData, encoding: .isoLatin1), !text.contains("\0") else { throw ClientError.protocolError("Invalid HTTP response headers.") }
        var parsed: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            if line.hasPrefix("HTTP/") { parsed = [:]; continue }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard parsed[name] == nil || name != "location" else { throw ClientError.protocolError("Ambiguous HTTP redirect headers.") }
            parsed[name] = value
        }
        return DAVHTTPResponse(status: result.response.reply, body: data, headers: parsed)
    }
}
