# Upstream reference

- Project: WinSCP, Martin Prikryl and contributors
- Source: https://github.com/winscp/winscp
- Revision investigated on 2026-10-21: `24e7b4ec1001406cc2edf2b8c88483d66d4449d8`
- Commit subject: `Avoid compiler warning`
- Source license entry point: https://github.com/winscp/winscp/blob/24e7b4ec1001406cc2edf2b8c88483d66d4449d8/license.txt

No upstream source is vendored into this preview. This directory records provenance and helps prevent accidentally claiming that this native rewrite compiles upstream unchanged.

| Upstream area | macOS implementation / work |
| --- | --- |
| `source/forms`, `source/components`, `source/packages` | SwiftUI/AppKit views; workflow parity incomplete |
| `source/core/SessionData.*` | `Site`, `SiteStore`, `SSHConfiguration`; many settings remain |
| `source/core/RemoteFiles.*` | `FileEntry`, `RemotePath`; metadata subset |
| `source/core/SftpFileSystem.*` | Binary v3 `SFTPClient` over macOS OpenSSH; independent implementation |
| `source/putty` | System OpenSSH; crypto is not reimplemented |
| `source/filezilla` | Independent FTP/FTPS backend via system libcurl, MLSD/LIST parsers, and server fixtures; full parity pending |
| WebDAV / libs3 | Separate protocol backends still required |
| `source/console`, `dotnet` | Automation compatibility still required |
| `source/dragext`, `source/windows`, deployment | macOS integration and bundle scripts; distribution incomplete |

For a source-level port branch, keep the upstream tree separate and preserve its individual notices. Audit core dependencies before moving files: C++Builder runtime types and Win32 calls also appear outside the visual layer. The feature matrix is the acceptance contract for progressively replacing or adapting those dependencies.
