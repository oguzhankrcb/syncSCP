// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin

/// S3 over HTTP(S) with SigV4 signed payloads. Writes use conditional requests
/// (`If-None-Match: *` / `If-Match`) so no-clobber and reviewed replacement are
/// enforced by the server when it supports S3 conditional writes.
public actor S3Client: RemoteFileClient {
    private var transport: CurlHTTPTransport?
    private var site: Site?
    private var credentials: S3Credentials?
    public private(set) var home = "/"
    private let partSize: UInt64
    private let multipartThreshold: UInt64
    private let copyPartSize: UInt64
    private let listPageSize: Int

    /// S3 requires parts of at least 5 MiB except the last; tests lower the defaults to that minimum.
    public init(partSize: UInt64 = 16 << 20, multipartThreshold: UInt64 = 64 << 20, copyPartSize: UInt64 = 1 << 30, listPageSize: Int = 1000) {
        self.partSize = max(5 << 20, partSize); self.multipartThreshold = max(self.partSize, multipartThreshold)
        self.copyPartSize = min(5 << 30, max(5 << 20, copyPartSize)); self.listPageSize = min(1000, max(1, listPageSize))
    }

    public func connect(site: Site, accessKey: String? = nil, secretKey: String, sessionToken: String = "") throws -> String {
        disconnect(); try site.validate()
        guard site.transferProtocol.usesS3 else { throw ClientError.invalid("Choose S3 over HTTPS or HTTP.") }
        guard !secretKey.isEmpty else { throw ClientError.invalid("Enter the S3 secret access key.") }
        for value in [secretKey, sessionToken] {
            guard value.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil else { throw ClientError.invalid("S3 credentials cannot contain control characters.") }
        }
        do {
            self.site = site
            credentials = S3Credentials(accessKey: accessKey ?? site.username, secretKey: secretKey, sessionToken: sessionToken)
            transport = try CurlHTTPTransport(site: site, password: secretKey, basicAuth: false)
            home = try realpath(site.remotePath.isEmpty ? "/" : site.remotePath)
            return home
        } catch { disconnect(); throw error }
    }
    public func disconnect() { transport = nil; site = nil; credentials = nil; home = "/" }

    // MARK: Requests

    func send(_ method: String, _ location: S3Location, trailingSlash: Bool = false, query: [(String, String)] = [],
                      headers extra: [String: String] = [:], body: Data = Data(), payloadHash: String? = nil,
                      operation: Int32 = 0, file: Int32 = -1, offset: UInt64? = nil, size: UInt64 = 0,
                      token: CancellationToken = CancellationToken(),
                      progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws -> DAVHTTPResponse {
        guard let transport, let site, let credentials else { throw ClientError.connection("Connect to an S3 site first.") }
        let endpoint = S3Endpoint(site: site), target = endpoint.target(location, trailingSlash: trailingSlash)
        let query = S3Signer.canonicalQuery(query), hash = payloadHash ?? S3Signer.hex(SHA256.hash(data: body))
        var headers = Dictionary(uniqueKeysWithValues: extra.map { ($0.key.lowercased(), $0.value) })
        headers["host"] = target.authority
        headers["x-amz-date"] = S3Signer.timestamps(Date()).amzDate
        headers["x-amz-content-sha256"] = hash
        if !credentials.sessionToken.isEmpty { headers["x-amz-security-token"] = credentials.sessionToken }
        let region = site.s3Region.isEmpty ? "us-east-1" : site.s3Region
        let authorization = S3Signer.authorization(method: method, encodedPath: target.path, canonicalQuery: query, headers: headers,
                                                   payloadHash: hash, credentials: credentials, region: region)
        var lines = headers.map { "\($0.key): \($0.value)" } + ["Authorization: " + authorization]
        // libcurl sends no length for an empty custom PUT/POST; S3 requires one. Not signed.
        if body.isEmpty, operation != 2, method == "PUT" || method == "POST" { lines.append("Content-Length: 0") }
        return try transport.perform(url: endpoint.url(authority: target.authority, path: target.path, query: query), method: method,
                                     headers: lines, body: body, operation: operation, file: file, offset: offset, size: size,
                                     token: token, progress: progress)
    }

    private func failure(_ response: DAVHTTPResponse, _ subject: String) -> ClientError {
        let detail = S3Listing.error(response.body)
        let code = detail?.code ?? ""
        if response.status == 412 || code == "PreconditionFailed" {
            return .conflict("The S3 object changed or already exists: \(subject). Refresh and review the operation again.")
        }
        if code == "ConditionalRequestConflict" || response.status == 409 && code == "OperationAborted" {
            return .conflict("Another S3 request changed \(subject) at the same time. Refresh and try again.")
        }
        if let region = detail?.region ?? response.headers["x-amz-bucket-region"], ["PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException", ""].contains(code),
           [301, 307, 400].contains(response.status) {
            return .remote("S3", response.status, "The bucket is in region \(region). Set that region (and, for AWS, the regional endpoint such as s3.\(region).amazonaws.com) in Advanced settings.")
        }
        let text: String
        switch (response.status, code) {
        case (_, "RequestTimeTooSkewed"): text = "The Mac's clock differs too much from the server's. Correct the date and time, then retry."
        case (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"), (_, "InvalidToken"), (_, "ExpiredToken"), (_, "TokenRefreshRequired"), (401, _):
            text = "Authentication failed. Check the access key ID, secret access key, session token and region."
        case (_, "AccessDenied"), (403, ""): text = "The credentials are not permitted to access \(subject). Listing all buckets needs extra permission; enter a bucket path such as /my-bucket instead."
        case (_, "NoSuchBucket"): text = "The bucket does not exist: \(subject)."
        case (_, "NoSuchKey"), (404, ""): text = "The object or folder does not exist: \(subject)."
        case (_, "InvalidObjectState"): text = "The object is archived (for example in Glacier) and must be restored before download."
        case (_, "XAmzContentSHA256Mismatch"), (_, "BadDigest"), (_, "InvalidDigest"): text = "The server rejected the data checksum; the local file probably changed during upload."
        case (_, "EntityTooLarge"): text = "The object exceeds the server's size limit."
        case (_, "NotImplemented"), (501, _): text = "The server does not implement this S3 operation."
        case (300...399, _): text = "The server redirected the request. Enter the canonical endpoint and region; redirects are not followed."
        default: text = "The S3 server rejected or did not complete the operation."
        }
        let server = detail.map { $0.code.isEmpty ? "" : " [\($0.code)\($0.message.isEmpty ? "" : ": " + $0.message)]" } ?? ""
        return .remote("S3", response.status, text + server)
    }
    private func require(_ response: DAVHTTPResponse, _ statuses: Set<Int>, _ subject: String) throws {
        guard statuses.contains(response.status) else { throw failure(response, subject) }
        // CopyObject/UploadPartCopy/CompleteMultipartUpload may report errors inside a 200 body.
        if S3Listing.error(response.body) != nil { throw failure(DAVHTTPResponse(status: 500, body: response.body, headers: response.headers), subject) }
    }

    // MARK: Metadata

    private func listPage(_ bucket: String, prefix: String, delimiter: Bool, maxKeys: Int? = nil, continuation: String? = nil,
                          token: CancellationToken = CancellationToken()) throws -> S3ListPage {
        var query = [("list-type", "2"), ("prefix", prefix), ("encoding-type", "url"), ("max-keys", String(maxKeys ?? listPageSize))]
        if delimiter { query.append(("delimiter", "/")) }
        if let continuation { query.append(("continuation-token", continuation)) }
        let response = try send("GET", S3Location(bucket: bucket), query: query, token: token)
        try require(response, [200], "/" + bucket + "/" + prefix)
        return try S3Listing.page(response.body, prefix: prefix)
    }
    private func listAll(_ bucket: String, prefix: String, delimiter: Bool, token: CancellationToken = CancellationToken()) throws -> S3ListPage {
        var result = S3ListPage(), continuation: String?
        repeat {
            try token.check()
            let page = try listPage(bucket, prefix: prefix, delimiter: delimiter, continuation: continuation, token: token)
            result.objects += page.objects; result.prefixes += page.prefixes
            guard result.objects.count + result.prefixes.count <= 1_000_000 else { throw ClientError.unsupported("S3 folders are limited to one million entries in this preview.") }
            guard page.nextToken == nil || page.nextToken != continuation else { throw ClientError.protocolError("S3 repeated a continuation token.") }
            continuation = page.nextToken
        } while continuation != nil
        return result
    }
    private func folderExists(_ location: S3Location, token: CancellationToken = CancellationToken()) throws -> Bool {
        guard let bucket = location.bucket else { return true }
        let page = try listPage(bucket, prefix: location.folderPrefix, delimiter: false, maxKeys: 1, token: token)
        return location.key.isEmpty || !page.objects.isEmpty || !page.prefixes.isEmpty
    }
    private func head(_ location: S3Location, token: CancellationToken = CancellationToken()) throws -> (FileEntry, DAVHTTPResponse)? {
        let response = try send("HEAD", location, token: token)
        if response.status == 404 { return nil }
        try require(response, [200], display(location))
        guard let value = response.headers["content-length"], value.utf8.allSatisfy({ (48...57).contains($0) }), let size = UInt64(value) else {
            throw ClientError.protocolError("S3 omitted a valid object size.")
        }
        let tag = response.headers["etag"].flatMap(DAVETag.property)
        let entry = FileEntry(path: display(location), name: (location.key as NSString).lastPathComponent, size: size, permissions: 0o100000,
                              modified: response.headers["last-modified"].flatMap(S3Listing.httpDate), permissionsKnown: false, versionTag: tag)
        return (entry, response)
    }
    private func display(_ location: S3Location) -> String {
        guard let bucket = location.bucket else { return "/" }
        return "/" + bucket + (location.key.isEmpty ? "" : "/" + location.key)
    }
    private func directory(_ path: String) -> FileEntry {
        FileEntry(path: path, name: path == "/" ? "/" : (path as NSString).lastPathComponent, permissions: 0o040000, permissionsKnown: false)
    }
    /// Folders win over a same-named object, matching the listing.
    private func optionalInfo(_ location: S3Location, token: CancellationToken = CancellationToken()) throws -> FileEntry? {
        if try location.key.isEmpty || folderExists(location, token: token) { return directory(display(location)) }
        return try head(location, token: token)?.0
    }
    private func info(_ location: S3Location, token: CancellationToken = CancellationToken()) throws -> FileEntry {
        guard let entry = try optionalInfo(location, token: token) else { throw ClientError.remote("S3", 404, "The object or folder does not exist: \(display(location)).") }
        return entry
    }

    public func realpath(_ value: String) throws -> String {
        let location = try S3Location(DAVPath.normalize(value, relativeTo: home))
        if location.bucket == nil {
            let response = try send("GET", location); try require(response, [200], "/")
            _ = try S3Listing.buckets(response.body); return "/"
        }
        guard try info(location).isDirectory else { throw ClientError.invalid("The S3 path is not a bucket or folder.") }
        return display(location)
    }
    public func list(_ value: String) throws -> [FileEntry] {
        let location = try S3Location(DAVPath.normalize(value, relativeTo: home))
        guard let bucket = location.bucket else {
            let response = try send("GET", location); try require(response, [200], "/")
            return try S3Listing.buckets(response.body)
        }
        let prefix = location.folderPrefix
        let page = try listAll(bucket, prefix: prefix, delimiter: true)
        if !location.key.isEmpty, page.objects.isEmpty, page.prefixes.isEmpty {
            throw ClientError.remote("S3", 404, "The folder does not exist: \(display(location)).")
        }
        return S3Listing.entries(objects: page.objects, prefixes: page.prefixes, folder: display(location), prefix: prefix)
    }
    public func stat(_ value: String, followLinks: Bool = false) throws -> FileEntry {
        guard !followLinks else { throw ClientError.unsupported("S3 has no symbolic links.") }
        return try info(S3Location(DAVPath.normalize(value, relativeTo: home)))
    }
    public func exists(_ value: String) throws -> Bool {
        do { return try optionalInfo(S3Location(DAVPath.normalize(value, relativeTo: home))) != nil }
        catch ClientError.remote(_, 404, _) { return false }
    }
    private func objectLocation(_ value: String, _ action: String) throws -> S3Location {
        let location = try S3Location(DAVPath.normalize(value, relativeTo: home))
        guard location.bucket != nil, !location.key.isEmpty else { throw ClientError.unsupported("This preview cannot \(action) buckets. Manage buckets with your provider's tools.") }
        return location
    }

    // MARK: Changes

    public func mkdir(_ value: String) throws {
        let location = try objectLocation(value, "create")
        let parent = try S3Location(RemotePath.parent(display(location)))
        guard try optionalInfo(parent)?.isDirectory == true else { throw ClientError.conflict("The parent S3 folder does not exist.") }
        if try optionalInfo(location) != nil { throw ClientError.conflict("An S3 object or folder with this name already exists.") }
        let response = try send("PUT", location, trailingSlash: true, headers: ["If-None-Match": "*", "Content-Type": "application/x-directory"])
        try require(response, [200], display(location) + "/")
    }
    public func chmod(_ path: String, mode: UInt32) throws {
        throw ClientError.unsupported("S3 has no POSIX permissions. Manage access with bucket policies or ACLs on the server.")
    }
    public func remove(_ value: String, recursive: Bool = false, token: CancellationToken = CancellationToken()) throws {
        try token.check()
        let location = try objectLocation(value, "delete")
        let entry = try info(location, token: token)
        guard entry.isDirectory, let bucket = location.bucket else {
            try require(send("DELETE", location, token: token), [200, 204], entry.path); return
        }
        let prefix = location.folderPrefix
        let keys = try listAll(bucket, prefix: prefix, delimiter: false, token: token).objects.map(\.key)
        if !recursive, keys.contains(where: { $0 != prefix }) { throw ClientError.conflict("The folder is not empty. Confirm recursive deletion first.") }
        // Delete contents before the folder marker so an interrupted delete leaves a visible folder.
        for key in keys.filter({ $0 != prefix }) + keys.filter({ $0 == prefix }) {
            try token.check()
            try require(send("DELETE", S3Location(bucket: bucket, key: key), token: token), [200, 204], "/" + bucket + "/" + key)
        }
    }

    /// Server-side multipart copy: the source version is pinned by `x-amz-copy-source-if-match`
    /// and the destination condition is enforced by CompleteMultipartUpload.
    public func rename(_ source: String, to destination: String, replace: Bool = false) throws {
        let from = try objectLocation(source, "rename"), to = try objectLocation(destination, "rename")
        guard from != to else { throw ClientError.invalid("Choose distinct S3 paths for rename.") }
        let sourceEntry = try info(from)
        guard !sourceEntry.isDirectory else {
            throw ClientError.unsupported("Renaming S3 folders requires copying every object and is not supported in this preview. Rename files individually.")
        }
        guard let sourceTag = DAVETag.strong(sourceEntry.versionTag) else { throw ClientError.unsupported("S3 did not provide an entity tag for the source object.") }
        let existing = try optionalInfo(to)
        if existing?.isDirectory == true { throw ClientError.conflict("An S3 folder with the destination name exists.") }
        if existing != nil, !replace { throw ClientError.conflict("The S3 destination already exists.") }
        let parent = try S3Location(RemotePath.parent(display(to)))
        guard try optionalInfo(parent)?.isDirectory == true else { throw ClientError.conflict("The destination S3 folder does not exist.") }
        guard let current = try head(from), current.0.versionTag == sourceTag else {
            throw ClientError.conflict("The S3 source changed after it was reviewed: \(sourceEntry.path)")
        }
        try copy(from, size: current.0.size, tag: sourceTag, metadata: current.1.headers, to: to, condition: try condition(existing))
        // S3 deletes are unconditional; recheck the source immediately before removing it.
        guard let after = try head(from), after.0.versionTag == sourceTag else {
            throw ClientError.conflict("The S3 source changed during rename; the copy was created and the newer source was kept.")
        }
        try require(send("DELETE", from), [200, 204], sourceEntry.path)
    }
    private func condition(_ existing: FileEntry?) throws -> [String: String] {
        guard let existing else { return ["If-None-Match": "*"] }
        guard existing.isRegularFile, let tag = DAVETag.strong(existing.versionTag) else {
            throw ClientError.unsupported("Safe S3 replacement requires a destination object with an entity tag.")
        }
        return ["If-Match": tag]
    }
    private func copy(_ from: S3Location, size: UInt64, tag: String, metadata: [String: String], to: S3Location, condition: [String: String]) throws {
        var preserved: [String: String] = [:]
        let names: Set<String> = ["content-type", "cache-control", "content-disposition", "content-encoding", "content-language", "expires",
                                  "x-amz-storage-class", "x-amz-server-side-encryption", "x-amz-server-side-encryption-aws-kms-key-id", "x-amz-website-redirect-location"]
        for (name, value) in metadata where names.contains(name) || name.hasPrefix("x-amz-meta-") {
            // Headers are decoded as Latin-1; re-sending non-ASCII would change the bytes.
            guard value.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
                throw ClientError.unsupported("The object has non-ASCII metadata (\(name)) that cannot be preserved by this preview's rename.")
            }
            preserved[name] = value
        }
        let upload = try initiate(to, headers: preserved)
        var completed = false
        defer { if !completed { abort(to, upload) } }
        let copySource = "/" + S3Signer.encode(from.bucket!) + "/" + S3Signer.encode(from.key, keepSlash: true)
        var parts: [(Int, String)] = [], offset: UInt64 = 0
        let partSize = max(copyPartSize, (size + 9999) / 10000)
        repeat {
            var headers = ["x-amz-copy-source": copySource, "x-amz-copy-source-if-match": tag]
            let length = min(partSize, size - offset)
            if size > 0 { headers["x-amz-copy-source-range"] = "bytes=\(offset)-\(offset + length - 1)" }
            let response = try send("PUT", to, query: [("partNumber", String(parts.count + 1)), ("uploadId", upload)], headers: headers)
            try require(response, [200], display(to))
            let result = try S3XML.parse(response.body)
            guard result.name == "CopyPartResult", let etag = result.value("ETag").flatMap(DAVETag.property) else {
                throw ClientError.protocolError("S3 did not confirm the copied part.")
            }
            parts.append((parts.count + 1, etag)); offset += length
        } while offset < size
        try complete(to, upload, parts: parts, condition: condition)
        completed = true
    }
    private func initiate(_ location: S3Location, headers: [String: String]) throws -> String {
        let response = try send("POST", location, query: [("uploads", "")], headers: headers)
        try require(response, [200], display(location))
        let result = try S3XML.parse(response.body)
        guard result.name == "InitiateMultipartUploadResult", let id = result.value("UploadId"), !id.isEmpty,
              id.rangeOfCharacter(from: .controlCharacters) == nil else { throw ClientError.protocolError("S3 did not return a multipart upload ID.") }
        return id
    }
    private func complete(_ location: S3Location, _ upload: String, parts: [(Int, String)], condition: [String: String]) throws {
        let body = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" + parts.map {
            "<Part><PartNumber>\($0.0)</PartNumber><ETag>\(S3XML.escape($0.1))</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        var headers = condition; headers["Content-Type"] = "application/xml"
        let response = try send("POST", location, query: [("uploadId", upload)], headers: headers, body: Data(body.utf8))
        try require(response, [200], display(location))
    }
    /// Best effort with a fresh token: abandoned multipart parts otherwise keep using storage.
    private func abort(_ location: S3Location, _ upload: String) {
        for _ in 0..<2 {
            guard let response = try? send("DELETE", location, query: [("uploadId", upload)]) else { continue }
            if [200, 204, 404].contains(response.status) { return }
        }
    }

    public func upload(local: URL, remote: String, replace: Bool = false, expectedDestination: FileEntry? = nil,
                       token: CancellationToken = CancellationToken(), progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let location = try objectLocation(remote, "upload to")
        let before = try LocalFiles.info(local.path)
        guard before.isRegularFile else { throw ClientError.unsupported("Only regular local files can be uploaded. Symbolic links are not followed.") }
        let size = before.size
        let existing = try optionalInfo(location, token: token)
        if existing?.isDirectory == true { throw ClientError.conflict("An S3 folder with this name exists.") }
        if let expectedDestination {
            guard existing?.hasSameVersion(as: expectedDestination) == true else { throw ClientError.conflict("The S3 object changed after review.") }
        }
        if existing != nil, !replace { throw ClientError.conflict("The S3 destination already exists. Confirm replacement first.") }
        var headers = try condition(existing)
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        let descriptor = source.fileDescriptor
        func unchanged() throws {
            let now = try LocalFiles.info(local.path)
            guard now.isRegularFile, now.size == size, now.modified == before.modified else { throw ClientError.conflict("The local file changed during S3 upload.") }
        }
        progress(0, size)
        if size <= multipartThreshold {
            // The signed payload hash makes the server reject bytes that differ from what was hashed.
            let digest = try S3Signer.digest(descriptor: descriptor, offset: 0, length: size, token: token)
            try unchanged()
            headers["Content-Type"] = "application/octet-stream"
            headers["x-amz-checksum-sha256"] = Data(digest).base64EncodedString()
            let response = try send("PUT", location, headers: headers, payloadHash: S3Signer.hex(digest), operation: 2,
                                    file: descriptor, offset: 0, size: size, token: token, progress: progress)
            try token.check()
            try require(response, [200], display(location))
        } else {
            let upload = try initiate(location, headers: ["Content-Type": "application/octet-stream"])
            var completed = false
            defer { if !completed { abort(location, upload) } }
            var parts: [(Int, String)] = [], offset: UInt64 = 0
            let partSize = max(self.partSize, (size + 9999) / 10000)
            while offset < size {
                let length = min(partSize, size - offset), base = offset
                let digest = try S3Signer.digest(descriptor: descriptor, offset: offset, length: length, token: token)
                let response = try send("PUT", location, query: [("partNumber", String(parts.count + 1)), ("uploadId", upload)],
                                        payloadHash: S3Signer.hex(digest), operation: 2, file: descriptor, offset: offset, size: length,
                                        token: token, progress: { done, _ in progress(base + done, size) })
                try token.check()
                try require(response, [200], display(location))
                guard let etag = response.headers["etag"].flatMap(DAVETag.property) else { throw ClientError.protocolError("S3 did not return a part entity tag.") }
                parts.append((parts.count + 1, etag)); offset += length
            }
            try unchanged(); try token.check()
            try complete(location, upload, parts: parts, condition: headers)
            completed = true
        }
        try unchanged()
        progress(size, size)
    }

    public func download(remote: String, local: URL, replace: Bool = false, token: CancellationToken = CancellationToken(),
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        try token.check()
        let location = try objectLocation(remote, "download")
        let info = try info(location, token: token), manager = FileManager.default
        guard info.isRegularFile else { throw ClientError.unsupported("Only S3 objects can be downloaded as files.") }
        if manager.fileExists(atPath: local.path), !replace { throw ClientError.conflict("The local destination already exists. Confirm replacement first.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".winscp-\(UUID().uuidString).filepart")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClientError.invalid("Cannot create a temporary download file.") }
        defer { try? manager.removeItem(at: temporary) }
        let target = try FileHandle(forWritingTo: temporary)
        defer { try? target.close() }
        var headers = ["Accept-Encoding": "identity", "x-amz-checksum-mode": "ENABLED"]
        if let tag = DAVETag.strong(info.versionTag) { headers["If-Match"] = tag }
        progress(0, info.size)
        let response = try send("GET", location, headers: headers, operation: 1, file: target.fileDescriptor, token: token, progress: progress)
        try token.check()
        try require(response, [200], info.path)
        guard try target.offset() == info.size else { throw ClientError.conflict("The S3 object size changed during download.") }
        // Verify full-object SHA-256 checksums when the server stored one; composite (multipart) values end in -N.
        if let expected = response.headers["x-amz-checksum-sha256"], !expected.contains("-"),
           response.headers["x-amz-checksum-type"].map({ $0.uppercased() == "FULL_OBJECT" }) ?? true {
            let reader = try FileHandle(forReadingFrom: temporary)
            defer { try? reader.close() }
            let digest = try S3Signer.digest(descriptor: reader.fileDescriptor, offset: 0, length: info.size, token: token)
            guard Data(digest).base64EncodedString() == expected else { throw ClientError.protocolError("The downloaded S3 object failed its SHA-256 checksum.") }
        }
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
