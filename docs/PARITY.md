# WinSCP parity tracker

Target: preserve WinSCP's file-management and transfer workflows with macOS equivalents. A checked capability below means implemented in this repository, not guaranteed compatible with every upstream edge case. This is not a completed 1:1 port.

| Upstream capability | Preview status | Remaining work |
| --- | --- | --- |
| Session tabs | Implemented | Several connections at once, each with its own remote/local folders and history; queue jobs stay on their connection; Duplicate Session; workspaces (saved tab sets) remain |
| Commander dual panes | Implemented | WinSCP layout with per-pane navigation/action bars, back/forward history, Type/Changed/Rights columns, selection totals, drag and drop between panes and from Finder, F2/F4/F5/F7/F8 and Go-menu shortcuts, the ".." row and a clickable path strip; dragging remote items to Finder, directory tree, Compare Directories and Find Files; selection masks remain |
| Explorer interface | Missing | Single-panel mode |
| Open Terminal / Open in PuTTY | Implemented | Interactive `ssh -t` logins in SwiftTerm windows (tabs, split panes, find, snippets) or Terminal.app, from a session or straight from Login, starting in the remote folder through the site's shell; WinSCP's non-interactive command console and custom commands remain |
| Port forwarding (PuTTY Tunnels) | Implemented | Saved local forwards per site, loopback only, ExitOnForwardFailure; remote and dynamic (SOCKS) forwards remain |
| SFTP | Implemented, v3 | More server interoperability, extensions, pipelining, non-UTF-8 policy |
| SSH key / agent / password | Implemented | Opt-in saved passwords in Keychain with optional Touch ID, also imported from WinSCP; hardware-key and keyboard-interactive coverage, GSSAPI remain |
| Host-key verification | Implemented | Key rotation UI, import/export, SSH config integration |
| Files / recursive folders | Implemented | Symlink transfer policy, ownership, ACLs, extended attributes |
| Background transfer queue | Implemented | Background connections per site, parallel workers (Settings), automatic retry after a lost connection, SFTP resume of partial files, retry button; rate limits, queue persistence across launches and resume for FTP/WebDAV/S3/SCP remain |
| FTP / explicit & implicit FTPS | Implemented baseline | Verified TLS, MLSD/Unix/DOS LIST, transfers and operations; active mode, proxies, advanced interoperability, resume remaining |
| SCP protocol | Implemented baseline | Real legacy SCP and shell/stat file management; Unix server requirements, line-break limits, Linux interoperability, and remote rename races documented in [SCP.md](SCP.md) |
| WebDAV / WebDAVS | Implemented baseline | Verified HTTPS, PROPFIND/XML, transfers, operations and ETag replacement; destination character limits, locks, authentication/vendor interoperability and timestamps documented in [WEBDAV.md](WEBDAV.md) |
| S3 | Implemented baseline | SigV4 signed payloads, paginated listings, multipart upload, conditional writes, server-side-copy rename and checksums verified against MinIO; AWS and other providers, region discovery, versioning, folder rename and bucket management documented in [S3.md](S3.md) |
| File operations | Implemented | Remote duplicate (server `cp` over SCP, temporary copy otherwise) and move/rename into folders; custom commands and timestamps remain |
| Permissions | Implemented (n/a for WebDAV/S3) | Multi-item rwx/octal editor, recursive with execute kept on readable folders; ownership remains |
| Text editor | Partial | Built-in UTF-8 editor (4 MB) plus external editors with save watching, conflict-checked upload and Edit With/Open With; other encodings and large files in the built-in editor remaining |
| Synchronization | Implemented | Upload, download and two-way with newer-only, size-only and opt-in mirror deletion, every item rechecked before it is applied; Keep Remote Directory up to Date via FSEvents; checksum comparison and file masks remain |
| Sites / workspaces | Partial | JSON sites in WinSCP-style folders, with notes, colors, search, Save As and rename; import of WinSCP.ini, `reg export` and Wine/Whisky/CrossOver configurations ([IMPORT.md](IMPORT.md)); workspaces remaining |
| Advanced Site Settings | Implemented dialog, partial effect | All upstream pages and settings round-trip; shell/SFTP server, timeouts, keepalives, IP version, SOCKS/HTTP/local proxy, SSH tunnel, TLS versions, cipher/kex policy, rekey, authentication options and S3 options are applied; the rest are badged as planned or unavailable in [SETTINGS.md](SETTINGS.md) |
| Automation / CLI | Missing | Script parser, protocol URLs, compatible exit codes and logs |
| .NET assembly | Missing | Evaluate portable automation API and compatibility strategy |
| PuTTY / Pageant | macOS equivalent partial | OpenSSH agent; passphrase-free PPK v2/v3 conversion on import; encrypted PPK and Pageant remaining |
| Tunnel / proxy / jump host | Partial | SSH tunnel and SOCKS4/5/HTTP/local proxies for SFTP/SCP; SOCKS/HTTP proxies for FTP/WebDAV/S3; proxy authentication, Telnet proxy and tunnels for curl protocols remain |
| Localization / accessibility | Partial | English UI with native controls; localization, full VoiceOver/keyboard audit |
| Release distribution | Partial | Local ad-hoc signed .app; Developer ID, notarization, updates, DMG release remaining |

## Milestones

1. **Verified SFTP baseline**: native UI, real protocol integration tests, disposable SSH end-to-end harness, file integrity and cancellation. Implemented.
2. **Everyday parity**: drag/drop, session tabs, import, retry/resume, advanced authentication, external editing, synchronization conflict handling, localization.
3. **Protocol parity**: FTP/FTPS baseline now implemented with independent server fixtures. SCP baseline now also implemented with an SFTP-disabled SSH fixture. WebDAV over HTTP/HTTPS now has an independent server fixture and ETag-conditional writes. S3 over HTTP/HTTPS now has disposable MinIO fixtures, conditional writes and multipart uploads. Interoperability with AWS and other providers, and full parity, remain.
4. **Automation and release parity**: compatible scripting, portable settings, signed/notarized universal releases, public interoperability matrix and accessibility checks.

Upstream references: [feature index](https://winscp.net/eng/docs/feature_index), [protocol comparison](https://winscp.net/eng/docs/protocols), [source](https://github.com/winscp/winscp). Do not mark a milestone complete solely because its UI controls exist.
