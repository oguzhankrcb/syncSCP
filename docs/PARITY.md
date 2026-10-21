# WinSCP parity tracker

Target: preserve WinSCP's file-management and transfer workflows with macOS equivalents. A checked capability below means implemented in this repository, not guaranteed compatible with every upstream edge case. This is not a completed 1:1 port.

| Upstream capability | Preview status | Remaining work |
| --- | --- | --- |
| Commander dual panes | Implemented | Drag/drop, navigation history, directory tree, selection masks, complete shortcuts |
| Explorer interface | Missing | Single-panel mode |
| SFTP | Implemented, v3 | More server interoperability, extensions, pipelining, non-UTF-8 policy |
| SSH key / agent / password | Implemented | Hardware-key and keyboard-interactive coverage, GSSAPI, persistent credentials |
| Host-key verification | Implemented | Key rotation UI, import/export, SSH config integration |
| Files / recursive folders | Implemented | Symlink transfer policy, ownership, ACLs, extended attributes |
| Background transfer queue | Partial | Resume, retry, parallel workers, rate limits, queue persistence |
| FTP / explicit & implicit FTPS | Implemented baseline | Verified TLS, MLSD/Unix/DOS LIST, transfers and operations; active mode, proxies, advanced interoperability, resume remaining |
| SCP protocol | Implemented baseline | Real legacy SCP and shell/stat file management; Unix server requirements, line-break limits, Linux interoperability, and remote rename races documented in [SCP.md](SCP.md) |
| WebDAV / WebDAVS | Implemented baseline | Verified HTTPS, PROPFIND/XML, transfers, operations and ETag replacement; destination character limits, locks, authentication/vendor interoperability and timestamps documented in [WEBDAV.md](WEBDAV.md) |
| S3 | Missing | SigV4, regions, pagination, multipart upload, credentials |
| File operations | Partial | Remote copy, move across filesystems, custom commands, timestamps |
| Permissions | Partial | Single-file numeric POSIX mode, recursive editor and ownership remaining |
| Text editor | Partial | UTF-8 save-back, 4 MB limit; other encodings, large files, external editor watch remaining |
| Synchronization | Partial | One-way reviewed upload with size/mtime revalidation; two-way, checksums, masks, watches remaining |
| Sites / workspaces | Partial | Basic JSON sites; tabs, workspaces, WinSCP INI import remaining |
| Automation / CLI | Missing | Script parser, protocol URLs, compatible exit codes and logs |
| .NET assembly | Missing | Evaluate portable automation API and compatibility strategy |
| PuTTY / Pageant | macOS equivalent partial | OpenSSH agent; PPK conversion/import missing |
| Tunnel / proxy / jump host | Missing | Explicit transport configuration and verification |
| Localization / accessibility | Partial | English UI with native controls; localization, full VoiceOver/keyboard audit |
| Release distribution | Partial | Local ad-hoc signed .app; Developer ID, notarization, updates, DMG release remaining |

## Milestones

1. **Verified SFTP baseline**: native UI, real protocol integration tests, disposable SSH end-to-end harness, file integrity and cancellation. Implemented.
2. **Everyday parity**: drag/drop, session tabs, import, retry/resume, advanced authentication, external editing, synchronization conflict handling, localization.
3. **Protocol parity**: FTP/FTPS baseline now implemented with independent server fixtures. SCP baseline now also implemented with an SFTP-disabled SSH fixture. WebDAV over HTTP/HTTPS now has an independent server fixture and ETag-conditional writes. S3 and full interoperability remain.
4. **Automation and release parity**: compatible scripting, portable settings, signed/notarized universal releases, public interoperability matrix and accessibility checks.

Upstream references: [feature index](https://winscp.net/eng/docs/feature_index), [protocol comparison](https://winscp.net/eng/docs/protocols), [source](https://github.com/winscp/winscp). Do not mark a milestone complete solely because its UI controls exist.
