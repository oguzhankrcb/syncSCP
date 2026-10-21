# Architecture

## Why a native implementation

Upstream's forms and components use Embarcadero VCL; its nonvisual core also uses C++Builder types (`UnicodeString`, `__property`, `__fastcall`), Windows APIs, and platform integrations. Replacing only the window framework is insufficient. This preview creates an independently buildable macOS baseline and makes the remaining parity work explicit. It must not be described as an unchanged compilation of upstream WinSCP.

## Layers

`SyncSCPCore` contains file/session models, site persistence, protocol-independent `RemoteSession` and `RemoteFileClient` interfaces, serialized SFTP/SCP/FTP/WebDAV/S3 actors, an SFTP v3 codec, OpenSSH process transport, and the synchronization planner. The original `CCurlTransport` C bridge wraps macOS libcurl for FTP/FTPS. The only downloaded package is SwiftTerm (MIT, pinned to 1.20.0), used by the app target for the terminal window; `SSHTerminalLaunch` in the core builds the interactive `ssh` command from the same site settings.

`SyncSCP` uses SwiftUI/AppKit for the Commander window, native tables and menus, connection settings, host trust, Keychain-backed askpass, queue, editor, and reviewed synchronization. `CommanderModel` is isolated to the main actor. The SFTP actor performs blocking pipe I/O away from the UI actor; each protocol operation is serialized. Only one session and one transfer worker are active at a time.

The UI routes every remote file operation through `RemoteSession`, which chooses the backend at login. SFTP, SCP, FTP, WebDAV and S3 share the same tables, queue, editor, and synchronization planner. Existing saved sites decode as SFTP when the newly added protocol/CA fields are absent.

FTP uses a per-session libcurl easy handle and connection cache owned by its actor. Credentials are supplied through the C API and live in process memory until disconnect; no shell, temporary credential file, or CLI arguments are involved. The C layer streams file descriptors, bounds listing memory, reports progress/cancellation, enforces response/connect/low-speed timeouts, and requires certificate plus hostname verification for both FTPS modes. See [FTP.md](FTP.md) for protocol-specific semantics.

WebDAV uses a separate HTTP entry point in the C bridge with streaming file descriptors and bounded headers/bodies. Its actor parses namespace-aware PROPFIND XML with external entities and DTDs disabled, validates URL origin/path scope, and retains ETags in `FileEntry`. Uploads use an owned temporary collection plus conditional MOVE; cancellation removes the parent to prevent a delayed PUT recreating its payload. Basic credentials are session-memory only; HTTPS always verifies trust and hostname. See [WEBDAV.md](WEBDAV.md) for semantics and limitations.

S3 reuses the HTTP entry point without Basic credentials. Each request is signed with AWS Signature Version 4 (CryptoKit HMAC/SHA-256) over an exact, already-encoded path that libcurl sends verbatim (`PATH_AS_IS`), and the host header is signed explicitly. Payloads are signed with their real SHA-256. File bodies, including multipart parts, are streamed with `pread` over an offset/length range, so a part never depends on the descriptor position. A bounded, namespace-agnostic XML tree parses listing, multipart and error documents with DTDs and entities refused. Writes use `If-None-Match: *` / `If-Match` (on `CompleteMultipartUpload` for multipart uploads and copies), and failed multipart uploads are aborted. The secret key and session token are session-memory only and never transmitted. See [S3.md](S3.md).

## SSH and credentials

Connection flow: validate settings → check application known_hosts → if new, scan a host key and obtain explicit fingerprint approval → start OpenSSH with strict checking → negotiate SFTP v3 or start the SCP SSH master → resolve initial directory → list files. The scanned key is untrusted until the user accepts the fingerprint. OpenSSH checks the actual connection against the approved key, including changes between scanning and login.

Passwords/passphrases are never passed as command-line arguments, environment values, or JSON. For password login a random account ID is associated with a temporary Keychain entry. OpenSSH invokes the application's own executable as `SSH_ASKPASS`; this helper reads the identified entry and writes the response to the helper pipe. The entry is deleted when connection establishment succeeds or fails. An abnormal application crash during login can leave a temporary entry behind; persistent password management and stale-entry cleanup are remaining work. No host-key confirmation is delegated to askpass.

Local OpenSSH processes are invoked with argument arrays and no local shell. SCP additionally executes separately quoted scripts on the remote Unix shell. Local SSH config is disabled so ProxyCommand, LocalCommand, and forwarding cannot change the transport unexpectedly; SSH config aliases are therefore not used. Advanced Site Settings are mapped explicitly onto OpenSSH options (`SSHOptions`): proxies through `nc` or a local command, and SSH tunnels as a nested strict `ssh -W` (not `ProxyJump`, whose jump hosts ignore command-line verification options). With a proxy or tunnel, the first-use host key is captured by OpenSSH with `accept-new` into a throwaway file and still requires the user's approval. An SCP/Shell setting such as `sudo su -` runs as each channel's remote command and receives the quoted script behind a unique marker. See [SETTINGS.md](SETTINGS.md).

SCP uses one authenticated OpenSSH master with a private control socket and separate raw command/SCP channels. Missing sockets fail closed rather than reconnecting. Transfers implement legacy SCP acknowledgements/file records; directory operations use NUL-delimited shell/stat metadata. Reads/writes are nonblocking, cancellable, and bounded. See [SCP.md](SCP.md) for remote requirements, publication behavior, and race limitations.

## Files and replacement

SFTP strings are byte-length-prefixed UTF-8; SFTP directory entries are validated before becoming local child paths. SFTP filenames are never shell-escaped or interpolated into commands. None of the backends parses `ls` output. Packet lengths, attribute flags, response IDs, and directory counts are bounded. The client rejects non-UTF-8 names rather than creating a different local name.

Uploads create a unique exclusive file in the remote destination directory, write 64 KiB blocks, close it, set basic permissions/mtime, then rename into place. Unapproved replacement uses v3 rename's no-replace semantics. Approved replacement requires `posix-rename@openssh.com`; no delete-then-rename fallback is used. Cancelled/failed transfers clean their temporary files when the connection is still usable. Network loss can leave a recognizable `.syncscp-UUID.filepart` on the server.

The preceding paragraph describes SFTP. FTP also uploads through UUID temporary files and commits with RNFR/RNTO, with no delete-first fallback. FTP has no standard atomic conditional rename, so checks for unapproved replacement and reviewed snapshots are best-effort, with server-dependent rename behavior. Timestamps/permissions are preserved when MFMT/SITE CHMOD and metadata support are available. Recursive deletion uses Unix LIST types to recognize symlinks even when MLSD follows them.

Downloads write a sibling temporary file, verify source size/mtime again, flush it, and commit with `renamex_np(RENAME_EXCL)` or approved atomic replacement. Cancelled/failed downloads clean up their temporary file. Basic mode bits are transferred; ACLs, extended attributes, ownership, and setuid/setgid bits are not.

Cancellation is checked between requests. A response watchdog kills an unresponsive process after 45 seconds; OpenSSH also has connect and keepalive timeouts. Resume, pipelining, bandwidth limits, concurrent sessions, and configurable retry policies remain parity work.

## Editing and synchronization

The editor downloads a regular UTF-8 file up to 4 MB. Save checks its size, mtime and available ETag against the opened version before atomic upload. This detects common external edits; it is not a content-hash lock and cannot detect every same-size/same-timestamp edit.

Synchronization is explicitly one-way and additive: recursively compare local and remote snapshots by size/mtime, preview creates/uploads/replacements, and apply after user review. Remote-only files are never deleted. Type conflicts block execution; symbolic links are skipped. Sources are rechecked against the preview, and reviewed remote replacements are rechecked both before upload and before commit. These size/mtime checks are best-effort conflict detection, not an atomic compare-and-swap or content-hash lock. This is not the upstream bidirectional synchronization engine. Cancellation, exclusion masks, checksum comparison, and watched synchronization need further work.

## Testing boundaries

Core integration tests launch macOS's real sftp-server over pipes with a disposable working directory. This validates protocol framing, operations, and file integrity without requiring SSH credentials. The test process is not chrooted; test code only addresses the disposable directory. SSH host verification and authentication require separate end-to-end tests. Never equate a protocol test with proof of every authentication or server implementation.
