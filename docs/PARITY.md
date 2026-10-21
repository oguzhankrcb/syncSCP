# WinSCP parity tracker

Target: preserve WinSCP's file-management and transfer workflows with macOS equivalents. A checked capability below means implemented in this repository, not guaranteed compatible with every upstream edge case. This is not a completed 1:1 port.

| Upstream capability | Preview status | Remaining work |
| --- | --- | --- |
| Commander dual panes | Implemented | WinSCP layout with per-pane navigation/action bars, back/forward history, Type/Changed/Rights columns and selection totals; drag/drop, directory tree, selection masks, multiple session tabs and complete shortcuts remain |
| Explorer interface | Missing | Single-panel mode |
| SFTP | Implemented, v3 | More server interoperability, extensions, pipelining, non-UTF-8 policy |
| SSH key / agent / password | Implemented | Hardware-key and keyboard-interactive coverage, GSSAPI, persistent credentials |
| Host-key verification | Implemented | Key rotation UI, import/export, SSH config integration |
| Files / recursive folders | Implemented | Symlink transfer policy, ownership, ACLs, extended attributes |
| Background transfer queue | Partial | Resume, retry, parallel workers, rate limits, queue persistence |
| FTP / explicit & implicit FTPS | Implemented baseline | Verified TLS, MLSD/Unix/DOS LIST, transfers and operations; active mode, proxies, advanced interoperability, resume remaining |
| SCP protocol | Implemented baseline | Real legacy SCP and shell/stat file management; Unix server requirements, line-break limits, Linux interoperability, and remote rename races documented in [SCP.md](SCP.md) |
| WebDAV / WebDAVS | Implemented baseline | Verified HTTPS, PROPFIND/XML, transfers, operations and ETag replacement; destination character limits, locks, authentication/vendor interoperability and timestamps documented in [WEBDAV.md](WEBDAV.md) |
| S3 | Implemented baseline | SigV4 signed payloads, paginated listings, multipart upload, conditional writes, server-side-copy rename and checksums verified against MinIO; AWS and other providers, region discovery, versioning, folder rename and bucket management documented in [S3.md](S3.md) |
| File operations | Partial | Remote copy, move across filesystems, custom commands, timestamps |
| Permissions | Partial (n/a for WebDAV/S3) | Single-file numeric POSIX mode, recursive editor and ownership remaining |
| Text editor | Partial | UTF-8 save-back, 4 MB limit; other encodings, large files, external editor watch remaining |
| Synchronization | Partial | One-way reviewed upload with size/mtime revalidation; two-way, checksums, masks, watches remaining |
| Sites / workspaces | Partial | JSON sites in WinSCP-style folders, with notes, colors, search, Save As and rename; tabs, workspaces, WinSCP INI import remaining |
| Advanced Site Settings | Implemented dialog, partial effect | All upstream pages and settings round-trip; shell/SFTP server, timeouts, keepalives, IP version, SOCKS/HTTP/local proxy, SSH tunnel, TLS versions, cipher/kex policy, rekey, authentication options and S3 options are applied; the rest are badged as planned or unavailable in [SETTINGS.md](SETTINGS.md) |
| Automation / CLI | Missing | Script parser, protocol URLs, compatible exit codes and logs |
| .NET assembly | Missing | Evaluate portable automation API and compatibility strategy |
| PuTTY / Pageant | macOS equivalent partial | OpenSSH agent; PPK conversion/import missing |
| Tunnel / proxy / jump host | Partial | SSH tunnel and SOCKS4/5/HTTP/local proxies for SFTP/SCP; SOCKS/HTTP proxies for FTP/WebDAV/S3; proxy authentication, Telnet proxy and tunnels for curl protocols remain |
| Localization / accessibility | Partial | English UI with native controls; localization, full VoiceOver/keyboard audit |
| Release distribution | Partial | Local ad-hoc signed .app; Developer ID, notarization, updates, DMG release remaining |

## Milestones

1. **Verified SFTP baseline**: native UI, real protocol integration tests, disposable SSH end-to-end harness, file integrity and cancellation. Implemented.
2. **Everyday parity**: drag/drop, session tabs, import, retry/resume, advanced authentication, external editing, synchronization conflict handling, localization.
3. **Protocol parity**: FTP/FTPS baseline now implemented with independent server fixtures. SCP baseline now also implemented with an SFTP-disabled SSH fixture. WebDAV over HTTP/HTTPS now has an independent server fixture and ETag-conditional writes. S3 over HTTP/HTTPS now has disposable MinIO fixtures, conditional writes and multipart uploads. Interoperability with AWS and other providers, and full parity, remain.
4. **Automation and release parity**: compatible scripting, portable settings, signed/notarized universal releases, public interoperability matrix and accessibility checks.

Upstream references: [feature index](https://winscp.net/eng/docs/feature_index), [protocol comparison](https://winscp.net/eng/docs/protocols), [source](https://github.com/winscp/winscp). Do not mark a milestone complete solely because its UI controls exist.
