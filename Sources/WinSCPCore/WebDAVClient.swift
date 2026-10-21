// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public actor WebDAVClient: RemoteFileClient {
    private var transport: CurlHTTPTransport?
    private var site: Site?
    public private(set) var home = "/"
    public init() {}
    public func connect(site: Site, password: String) throws -> String {
        disconnect(); try site.validate()
        guard site.transferProtocol.usesWebDAV else { throw ClientError.invalid("Choose WebDAV over HTTP or HTTPS.") }
        do {
            self.site = site; transport = try CurlHTTPTransport(site: site, password: password)
            home = try DAVPath.normalize(site.remotePath)
            let entries = try metadata(home, depth: 1, directory: true)
            guard entries.first(where: { $0.path == home })?.isDirectory == true else { throw ClientError.invalid("The initial WebDAV folder is not a collection.") }
            return home
        } catch { disconnect(); throw error }
    }
    public func disconnect() { transport = nil; site = nil; home = "/" }
    private func connection() throws -> (CurlHTTPTransport, Site) {
        guard let transport, let site else { throw ClientError.connection("Connect to a WebDAV site first.") }; return (transport, site)
    }
    private func path(_ value: String) throws -> String { try DAVPath.normalize(value, relativeTo: home) }
    private func metadata(_ path: String, depth: Int, directory: Bool = false, token: CancellationToken = CancellationToken()) throws -> [FileEntry] {
        let (transport, site) = try connection()
        let headers = ["Depth: \(depth)", "Content-Type: application/xml; charset=utf-8", "Accept: application/xml"]
        var response = try transport.perform(path: path, directory: directory, method: "PROPFIND", headers: headers, body: WebDAVListing.requestBody, token: token)
        // Some servers canonicalize collection URLs by appending '/'. Only that exact,
        // same-origin PROPFIND redirect is safe and useful here; never follow a login page.
        if !directory, [301, 302, 307, 308].contains(response.status), let location = response.headers["location"],
           location.hasSuffix("/"), try DAVPath.href(location, site: site) == path {
            response = try transport.perform(path: path, directory: true, method: "PROPFIND", headers: headers, body: WebDAVListing.requestBody, token: token)
        }
        try response.require([207])
        return try WebDAVListing.decode(response.body, site: site, path: path, depth: depth)
    }
    private func info(_ path: String, token: CancellationToken = CancellationToken()) throws -> FileEntry {
        let entries = try metadata(path, depth: 0, token: token)
        guard entries.count == 1, entries[0].path == path else { throw ClientError.protocolError("Expected metadata for one WebDAV resource.") }
        return entries[0]
    }
    private func optionalInfo(_ path: String, token: CancellationToken = CancellationToken()) throws -> FileEntry? {
        do { return try info(path, token: token) } catch ClientError.remote(_, 404, _) { return nil }
    }
    public func realpath(_ value: String) throws -> String {
        let path = try path(value)
        guard try info(path).isDirectory else { throw ClientError.invalid("The WebDAV path is not a collection.") }; return path
    }
    public func list(_ value: String) throws -> [FileEntry] {
        let path = try path(value), entries = try metadata(path, depth: 1, directory: true)
        guard entries.first(where: { $0.path == path })?.isDirectory == true else { throw ClientError.invalid("The WebDAV path is not a collection.") }
        return entries.filter { $0.path != path }
    }
    public func stat(_ value: String, followLinks: Bool = false) throws -> FileEntry {
        guard !followLinks else { throw ClientError.unsupported("WebDAV does not expose portable symbolic-link semantics.") }
        return try info(path(value))
    }
    public func exists(_ value: String) throws -> Bool { try optionalInfo(path(value)) != nil }
    public func mkdir(_ value: String) throws {
        let path = try path(value)
        guard path != "/" else { throw ClientError.conflict("The root collection already exists.") }
        let (transport, _) = try connection()
        let response = try transport.perform(path: path, directory: true, method: "MKCOL")
        if response.status == 405 { throw ClientError.conflict("The collection already exists or MKCOL is unavailable.") }
        try response.require([201])
    }
    public func chmod(_ path: String, mode: UInt32) throws {
        throw ClientError.unsupported("WebDAV has no standard POSIX chmod operation. Manage permissions on the server.")
    }
    private func destinationHeaders(_ destination: String, replacing entry: FileEntry?, site: Site) throws -> [String] {
        // Deployed MOVE implementations may decode Destination before URI parsing,
        // treating an escaped '?' as a query or ';' as parameters. Refuse those writes
        // in this baseline rather than risk modifying a different destination.
        guard !destination.contains("?"), !destination.contains(";") else {
            throw ClientError.unsupported("This WebDAV preview requires MOVE destination paths without '?' or ';'. Other names can still be listed and downloaded.")
        }
        let url = try DAVPath.url(site: site, path: destination)
        if let entry {
            guard entry.isRegularFile, let tag = DAVETag.strong(entry.versionTag) else {
                throw ClientError.unsupported("Safe WebDAV replacement requires a regular destination with a strong ETag. This server did not provide one.")
            }
            // If-Match applies to the MOVE source. A tagged WebDAV If condition checks
            // the destination's ETag atomically as part of MOVE instead.
            return ["Destination: " + url, "Overwrite: T", "If: <\(try DAVPath.reference(site: site, path: destination))> ([\(tag)])"]
        }
        return ["Destination: " + url, "Overwrite: F"]
    }
    private func sourceCondition(_ entry: FileEntry, path: String, site: Site, headers: inout [String]) throws {
        guard let tag = DAVETag.strong(entry.versionTag) else { return }
        let condition = "<\(try DAVPath.reference(site: site, path: path, directory: entry.isDirectory))> ([\(tag)])"
        if let index = headers.firstIndex(where: { $0.hasPrefix("If: ") }) { headers[index] += " " + condition }
        else { headers.append("If: " + condition) }
    }
    public func rename(_ source: String, to destination: String, replace: Bool = false) throws {
        let source = try path(source), destination = try path(destination)
        guard source != "/", destination != "/", source != destination else { throw ClientError.invalid("Choose distinct, non-root WebDAV paths for rename.") }
        let sourceInfo = try info(source), existing = try optionalInfo(destination)
        if existing != nil, !replace { throw ClientError.conflict("The WebDAV destination already exists.") }
        if existing != nil, !sourceInfo.isRegularFile { throw ClientError.unsupported("WebDAV replacement is limited to regular files.") }
        let (transport, site) = try connection()
        var headers = try destinationHeaders(destination, replacing: existing, site: site)
        try sourceCondition(sourceInfo, path: source, site: site, headers: &headers)
        try transport.perform(path: source, directory: sourceInfo.isDirectory, method: "MOVE", headers: headers).require([201, 204])
    }
    public func remove(_ value: String, recursive: Bool = false, token: CancellationToken = CancellationToken()) throws {
        try token.check()
        let path = try path(value), last = value.split(separator: "/").last
        guard path != "/", last != ".", last != ".." else { throw ClientError.invalid("Refusing to delete a root or parent WebDAV collection.") }
        let entry = try info(path, token: token)
        if entry.isDirectory, !recursive, try !list(path).isEmpty { throw ClientError.conflict("The collection is not empty. Confirm recursive deletion first.") }
        let (transport, _) = try connection()
        var headers = ["Depth: infinity"]
        if let tag = DAVETag.strong(entry.versionTag) { headers.append("If-Match: " + tag) }
        try transport.perform(path: path, directory: entry.isDirectory, method: "DELETE", headers: headers, token: token).require([200, 204])
    }
    private func verify(_ expected: FileEntry, at path: String, token: CancellationToken) throws {
        guard let current = try optionalInfo(path, token: token), current.hasSameVersion(as: expected) else {
            throw ClientError.conflict("The WebDAV resource changed after it was reviewed: \(path)")
        }
    }

    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil,
                       token: CancellationToken = CancellationToken(), progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let destination = try path(remote), manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: local.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw ClientError.unsupported("Only regular local files can be uploaded. Symbolic links are not followed.") }
        let size = (before[.size] as? NSNumber)?.uint64Value ?? 0
        let existing = try optionalInfo(destination, token: token)
        if let expectedDestination {
            guard existing?.hasSameVersion(as: expectedDestination) == true else { throw ClientError.conflict("The WebDAV file changed after review.") }
        }
        if existing != nil, !replace { throw ClientError.conflict("The WebDAV destination already exists. Confirm replacement first.") }
        let (transport, site) = try connection()
        var headers = try destinationHeaders(destination, replacing: existing, site: site)
        let folder = RemotePath.join(RemotePath.parent(destination), ".winscp-\(UUID().uuidString).filepart")
        let temporary = RemotePath.join(folder, "payload")
        try transport.perform(path: folder, directory: true, method: "MKCOL", token: token).require([201])
        var cleanup = true
        defer {
            if cleanup {
                // Removing the owned parent also prevents a delayed, aborted PUT
                // from recreating its payload after cleanup on another connection.
                for attempt in 0..<3 {
                    guard let result = try? transport.perform(path: folder, directory: true, method: "DELETE", headers: ["Depth: infinity"]) else { break }
                    if [200, 204, 404].contains(result.status) || ![207, 409, 423].contains(result.status) { break }
                    if attempt < 2 { Thread.sleep(forTimeInterval: 0.02) }
                }
            }
        }
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        progress(0, size)
        let response: DAVHTTPResponse
        do { response = try transport.perform(path: temporary, method: "PUT", headers: ["If-None-Match: *", "Content-Type: application/octet-stream"],
                                             operation: 2, file: source.fileDescriptor, size: size, token: token, progress: progress)
        } catch {
            try token.check()
            let current = try? manager.attributesOfItem(atPath: local.path)
            if current?[.type] as? FileAttributeType != .typeRegular || (current?[.size] as? NSNumber)?.uint64Value != size || current?[.modificationDate] as? Date != before[.modificationDate] as? Date {
                throw ClientError.conflict("The local file changed during WebDAV upload.")
            }
            throw error
        }
        if response.status == 412 { cleanup = false }
        try response.require([200, 201, 204]); try token.check()
        let after = try manager.attributesOfItem(atPath: local.path)
        guard try source.offset() == size, (after[.size] as? NSNumber)?.uint64Value == size,
              after[.modificationDate] as? Date == before[.modificationDate] as? Date else { throw ClientError.conflict("The local file changed during WebDAV upload.") }
        let uploaded = try info(temporary, token: token)
        guard uploaded.isRegularFile, uploaded.size == size else { throw ClientError.protocolError("The WebDAV server did not store the expected file.") }
        if let expectedDestination { try verify(expectedDestination, at: destination, token: token) }
        if let existing { try verify(existing, at: destination, token: token) }
        try sourceCondition(uploaded, path: temporary, site: site, headers: &headers)
        try token.check()
        try transport.perform(path: temporary, method: "MOVE", headers: headers, token: token).require([201, 204])
        guard let published = try optionalInfo(destination, token: token), published.isRegularFile, published.size == size else {
            throw ClientError.protocolError("The server reported MOVE success but did not expose the expected destination. Refresh before retrying.")
        }
        progress(size, size)
    }

    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let remote = try path(remote), info = try info(remote, token: token), manager = FileManager.default
        guard info.isRegularFile else { throw ClientError.unsupported("Only regular WebDAV resources can be downloaded.") }
        if manager.fileExists(atPath: local.path), !replace { throw ClientError.conflict("The local destination already exists. Confirm replacement first.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".winscp-\(UUID().uuidString).filepart")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClientError.invalid("Cannot create a temporary download file.") }
        defer { try? manager.removeItem(at: temporary) }
        let target = try FileHandle(forWritingTo: temporary)
        defer { try? target.close() }
        let (transport, _) = try connection()
        var headers = ["Accept-Encoding: identity"]
        if let tag = DAVETag.strong(info.versionTag) { headers.append("If-Match: " + tag) }
        progress(0, info.size)
        try transport.perform(path: remote, method: "GET", headers: headers, operation: 1, file: target.fileDescriptor, token: token, progress: progress).require([200])
        try token.check()
        guard try target.offset() == info.size else { throw ClientError.conflict("The WebDAV file size changed during download.") }
        try verify(info, at: remote, token: token)
        try target.synchronize(); try target.close()
        if let modified = info.modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path) }
        let result = temporary.path.withCString { source in local.path.withCString { destination in
            replace ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else {
            if errno == EEXIST { throw ClientError.conflict("The local destination appeared during download and was preserved.") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        progress(info.size, info.size)
    }
}
