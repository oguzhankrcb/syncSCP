# WebDAV and WebDAVS in 0.4.0

The native app has a separate WebDAV backend using macOS's system libcurl and Foundation XML parser. File operations use real HTTP methods: PROPFIND, GET, PUT, MKCOL, MOVE and DELETE. The existing Commander panes, file/folder queue, UTF-8 editor and reviewed one-way synchronization use this backend through `RemoteSession`. No Python, server helper, downloaded app library or mounted filesystem is required by the application.

## Connecting

Select **WebDAV · HTTPS** (port 443) or **WebDAV · HTTP** (port 80). Enter a hostname, not a URL, in Host name. Advanced settings open for WebDAV; put the endpoint path in **WebDAV path**, such as `/dav/` or `/remote.php/dav/files/username/`. This is an initial folder, not a client-enforced access boundary. Server permissions determine access.

This baseline supports HTTP Basic username/password authentication. Passwords remain in memory for the session and are not saved in JSON, Keychain, URLs, CLI arguments or logs. Use HTTPS to protect credentials and content. Plain HTTP explicitly displays its unencrypted status. Digest, NTLM, OAuth/browser login, client certificates and proxy configuration are future work.

HTTPS requires TLS 1.2 or later, certificate-chain verification and hostname verification. A per-site PEM CA bundle supports private authorities without disabling checks. Requests do not load netrc or use ambient proxies. Cross-origin, downgrade and arbitrary redirects are never followed. Only a same-origin, same-path PROPFIND redirect that appends a collection slash can be retried; login-page redirects require a correct endpoint instead.

## Metadata and paths

PROPFIND uses Depth 0 for one resource and Depth 1 for a collection. The namespace-aware parser reads resource type, file size, modification time and ETag only from successful property statuses. Missing required types/sizes, failed resources, duplicate entries, unexpected descendants, foreign origins and traversal paths fail the listing rather than becoming an incomplete success. Display names come from the validated resource URL. File sizes are required for regular resources.

Responses must be UTF-8. DTDs and entity declarations are rejected before parsing; external entity resolution is disabled. XML, element count, nesting, value lengths, response headers and body sizes are bounded. Percent encoding is decoded once, and encoded path separators, dot segments, controls and backslashes are rejected. Unicode, spaces, apostrophes, quotes, percent signs, hash signs, ampersands, plus signs, leading hyphens and hidden files are exercised against a real server.

Some deployed MOVE implementations decode `Destination` before parsing its URI. This can interpret an escaped `?` as a query or `;` as parameters and modify a different file. This preview therefore **rejects upload/rename destination paths containing `?` or `;` before writing**. Existing such names can still be listed and downloaded. This conservative compatibility limit also applies to servers that correctly implement those names; broader interoperability needs a separate design and verification. Control characters and backslashes are not supported in WebDAV paths.

WebDAV does not standardize POSIX mode bits or portable symlink identity. Rights are shown as unavailable; the permissions action is disabled. Collections and regular resources are identified from DAV:resourcetype. Local symlinks/special files are not uploaded. Server aliases, virtual collections, access control and DELETE behavior remain server responsibilities.

## Replacement and editing

Each upload creates an exclusively allocated `.winscp-UUID.filepart` collection next to its destination using MKCOL. A fixed `payload` file is PUT inside it with `If-None-Match: *`. The client verifies the local source's size/mtime and the uploaded size before publishing with MOVE, then verifies the destination's existence/type/size. Upload access therefore requires collection creation and deletion as well as PUT and MOVE.

New destinations use **Overwrite: F**, so a conforming server refuses files or collections that appear during transfer. Approved replacements require a regular destination and a **strong ETag**. A tagged WebDAV `If` condition identifies the destination and its reviewed tag in the MOVE request, while a separate source condition protects the uploaded payload. These use RFC 4918 absolute-path resource tags. An ordinary `If-Match` header on MOVE would condition the source rather than the destination.

The editor and synchronization snapshots retain ETags as well as size/mtime. A changed review is rejected before upload and before commit, and the MOVE condition checks again at the server. HTTP 412 becomes a conflict. Unquoted, unambiguous opaque getetag properties from deployed servers such as WsgiDAV are normalized to quoted tags; malformed tags and unquoted weak tags are rejected. Servers without a strong destination ETag support reading/new uploads but cannot safely replace through this preview. There is no unconditional overwrite or delete-first fallback.

Conditions rely on server compliance and storage semantics. ETags are server version identifiers, not necessarily content hashes, and this is not a distributed lock against a server's external filesystem writers. Lock-token management is not implemented; locked resources report an error. A failed multi-status MOVE/DELETE is not reported as complete; some children may already have changed, so refresh before retrying.

## Downloads, cancellation and timestamps

Downloads GET a regular resource, use If-Match when a strong ETag is available, and recheck metadata afterward. HTTP error/redirect bodies cannot become downloaded file bytes. Data goes to a mode-0600 local sibling file, is flushed, and is published using macOS atomic no-clobber rename or an approved replacement. The server's modification time is preserved locally. Unknown POSIX permissions are not invented.

Progress/cancellation use libcurl callbacks; connection and low-speed timeouts bound stalled I/O. An aborted upload deletes its owned temporary collection, with bounded retries for in-flight conflicts, preventing a delayed PUT from recreating a payload after cleanup. A lost connection, refused cleanup, or a failed temporary precondition can leave a recognizable transfer collection on the server. Transfers that have already committed cannot be undone by a later cancellation.

WebDAV's standard last-modified property is server-controlled, so uploads do not preserve local mtimes or POSIX modes. Size/mtime synchronization may propose repeated uploads when timestamps differ even if bytes match. Checksums, server-specific timestamp extensions, LOCK/UNLOCK, resume, retry, parallel workers, COPY, ACL editing and complete vendor interoperability remain future work.

## Verification

Install isolated test dependencies with `./scripts/setup-protocol-tests.sh`, then run `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release`. `./scripts/test-webdav.sh` runs WebDAV separately; without its fixture the network cases are explicitly skipped by the offline Swift test command.

The independent WsgiDAV 4.3.5 / Cheroot 11.1.2 fixture exposes authenticated HTTP and HTTPS endpoints only on localhost, with a generated CA/certificate and a read-only provider. Normal responses and operations come from WsgiDAV. Test-only middleware injects a destination change immediately before MOVE, redirects to a separate credential-capture counter, and a partial DELETE status. Tests cover actual byte integrity, empty files, names, long names, permissions being unavailable, file operations, replacement, ETag conditions, changed sources, cancellation/cleanup, readonly/auth errors, certificate and hostname failures, TLS downgrade, redirects and partial statuses. No user account or production server is used.

Protocol references: [RFC 4918](https://www.rfc-editor.org/rfc/rfc4918), especially Sections 8.3 and 10.4; [libcurl authentication](https://curl.se/libcurl/c/CURLOPT_HTTPAUTH.html); [WsgiDAV](https://github.com/mar10/wsgidav). The Swift/C implementation here is original code. Test server packages are not bundled in the app. Third-party production services, large/slow transfers and proxy deployments still need independent coverage.
