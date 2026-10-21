// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CCurlTransport

final class CStringArena {
    private var values: [UnsafeMutablePointer<CChar>] = []
    func store(_ text: String) throws -> UnsafePointer<CChar> {
        guard !text.contains("\0"), let value = strdup(text) else { throw ClientError.invalid("Invalid or unavailable request buffer.") }
        values.append(value); return UnsafePointer(value)
    }
    deinit { values.forEach { free($0) } }
}

final class CurlProgress {
    let token: CancellationToken
    let update: @Sendable (UInt64, UInt64) -> Void
    init(token: CancellationToken, update: @escaping @Sendable (UInt64, UInt64) -> Void) { self.token = token; self.update = update }
}

/// Called only by the owning FTPClient actor. No command-line process or shell is involved.
final class CurlFTPTransport {
    private let handle: OpaquePointer
    private let site: Site
    private let password: String
    init(site: Site, password: String) throws {
        guard !password.contains("\0"), password.rangeOfCharacter(from: .newlines) == nil else { throw ClientError.invalid("FTP passwords cannot contain null or newline characters.") }
        guard let handle = ws_curl_create() else { throw ClientError.connection("Cannot initialize the system FTP transport.") }
        self.handle = handle; self.site = site; self.password = password
    }
    deinit { ws_curl_destroy(handle) }

    struct Response { let body: Data; let entryPath: String }
    func perform(path: String, directory: Bool = true, loginHome: Bool = false, method: String = "", commands: [String] = [],
                 operation: Int32 = 0, file: Int32 = -1, size: UInt64 = 0, token: CancellationToken = CancellationToken(),
                 progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws -> Response {
        try token.check(); try FTPPath.validate(path)
        for command in commands { try FTPPath.validate(command) }
        guard size <= UInt64(Int64.max) else { throw ClientError.unsupported("This file is too large for the FTP transport.") }
        let arena = CStringArena()
        var request = WSCurlRequest()
        request.url = try arena.store(FTPPath.url(site: site, path: path, directory: directory, loginHome: loginHome))
        request.username = try arena.store(site.username); request.password = try arena.store(password)
        request.ca_file = try arena.store((site.certificateAuthorityFile as NSString).expandingTildeInPath)
        request.method = try arena.store(method)
        request.operation = operation; request.file_descriptor = file; request.upload_size = Int64(size)
        request.tls_mode = site.transferProtocol == .ftp ? 0 : site.transferProtocol == .ftpsExplicit ? 1 : 2
        let commandPointers: [UnsafePointer<CChar>?] = try commands.map { try arena.store($0) }
        let context = CurlProgress(token: token, update: progress)
        var result = WSCurlResult()
        withExtendedLifetime((arena, context)) { commandPointers.withUnsafeBufferPointer { pointers in
            request.commands = pointers.baseAddress; request.command_count = pointers.count
            ws_curl_perform(handle, &request, { opaque, total, done in
                guard let opaque else { return 1 }
                let context = Unmanaged<CurlProgress>.fromOpaque(opaque).takeUnretainedValue()
                if context.token.isCancelled { return 1 }
                context.update(UInt64(max(0, done)), UInt64(max(0, total)))
                return 0
            }, Unmanaged.passUnretained(context).toOpaque(), &result)
        } }
        defer { ws_curl_result_free(&result) }
        try token.check()
        if result.local_errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: result.local_errno) ?? .EIO) }
        if result.body_too_large != 0 { throw ClientError.unsupported("FTP directory listings are limited to 16 MB.") }
        if result.code != 0 {
            let message = withUnsafePointer(to: &result.error) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            let sanitized = password.isEmpty ? message : message.replacingOccurrences(of: password, with: "••••")
            if [5, 6, 7, 28, 35, 51, 58, 60, 64, 77].contains(result.code) {
                throw ClientError.connection("\(site.transferProtocol.shortTitle): \(sanitized)")
            }
            throw ClientError.remote(site.transferProtocol.shortTitle, result.reply == 0 ? Int(result.code) : result.reply, sanitized)
        }
        let body = result.body.map { Data(bytes: $0, count: result.body_size) } ?? Data()
        let entry = withUnsafePointer(to: &result.entry_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 4096) { String(validatingCString: $0) }
        }
        guard let entry else { throw ClientError.unsupported("The FTP login directory is not UTF-8.") }
        return Response(body: body, entryPath: entry)
    }
}
