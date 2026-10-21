# WinSCP for macOS — community port

A native macOS implementation of WinSCP's Commander workflow, built with SwiftUI, AppKit, and macOS's OpenSSH and libcurl. Free software under **GPL-3.0-or-later**.

**Status: 0.4.0 development preview. This is an independent community project, not an official WinSCP release, and not yet a feature-complete or source-compatible port.** The current code reimplements selected WinSCP workflows; it does not compile the upstream Windows/VCL code. The target is functional parity, tracked explicitly in [the parity matrix](docs/PARITY.md).

## Build and run

Requires macOS 13 or later and an Xcode toolchain with Swift 5.9 or later. No Homebrew libraries, package downloads, Wine, Electron, or external servers are needed to build.

```sh
./scripts/swift.sh test
./scripts/test-ssh.sh
./scripts/build-app.sh
open "dist/WinSCP for macOS.app"
```

For a development build, use `./scripts/build-app.sh --debug`. For an Apple Silicon + Intel binary, use `./scripts/build-app.sh --universal`. You can also open `Package.swift` in Xcode and run the `WinSCPMac` executable scheme. The bundle is signed ad hoc for local use; Developer ID signing and notarization are not configured.

`./scripts/package-release.sh` builds the universal app and creates verified, versioned application/source ZIP archives in `dist/` from the current checkout, including uncommitted source changes.

## Available now

- Commander-style local and remote file tables, multiple selection, sorting by name/size, path navigation, hidden-file toggle, and filtering.
- Real SFTP v3 over `/usr/bin/ssh`, with explicit first-use host fingerprint approval and strict verification on subsequent connections.
- Real legacy SCP over shared OpenSSH channels, with a separate Unix shell/stat backend for directory and file operations. See [SCP requirements and limits](docs/SCP.md).
- FTP, explicit FTPS, and implicit FTPS through macOS's system libcurl. FTPS requires TLS on both control and data channels, certificate-chain verification, and hostname verification. Optional per-site PEM CA bundles support private certificate authorities without disabling verification.
- WebDAV over HTTP and verified HTTPS: namespace-aware PROPFIND, GET/PUT, collections, MOVE/DELETE, ETag-conditional replacement, and temporary-collection cleanup. See [WebDAV requirements and limits](docs/WEBDAV.md).
- FTP MLSD listings with Unix/DOS LIST fallback, binary transfers, UTC modification times when exposed, and permissions when the server provides them. Unknown rights are shown as unavailable.
- SSH-agent/default-key, explicit OpenSSH private key, and password/key-passphrase authentication. Passwords are temporarily placed in Keychain for `SSH_ASKPASS`, then removed after the connection attempt; saved site JSON contains no passwords.
- File and recursive directory upload/download; a sequential queue, progress, cancellation, and per-job results. Files are transferred through temporary `.filepart` paths and committed after completion.
- Explicit approval before replacement. Cancelling a transfer preserves the old destination file. SFTP atomic replacement requires the OpenSSH `posix-rename` extension; FTP uses server-provided RNFR/RNTO semantics, whose atomicity and race behavior are server-dependent.
- Remote mkdir, rename, recursive delete, POSIX permission editing; local folder creation, rename, and Trash integration.
- UTF-8 remote text editor (4 MB maximum) with save-back and size/mtime conflict checks.
- Reviewed, one-way local → remote synchronization by size/mtime. No remote deletions; symlinks are skipped; type conflicts block execution.
- Saved site settings and bounded session logs.

SFTP uses binary protocol messages rather than shell commands or parsing `ls`. Spaces, quotes, Unicode, and newline characters in SFTP filenames are preserved. Invalid UTF-8 names are reported, not silently changed. SFTP and local filesystem operations reject symlink transfers. FTP paths reject control characters, and FTP relies on the file types reported by its server; recursive deletion requires Unix LIST types so an existing symlink can be removed without traversing it. See [FTP capabilities and limits](docs/FTP.md).

## Connect

Choose **New Session**, select SFTP, SCP, FTP, an FTPS mode, or WebDAV over HTTP/HTTPS, then enter the host, port, and username. Protocol selection updates standard ports (SFTP/SCP 22, FTP/explicit FTPS 21, implicit FTPS 990, HTTP WebDAV 80, HTTPS WebDAV 443). Saved sites open in the login sheet so passwords can be entered again; older site files retain their original settings and default to SFTP.

For SFTP or SCP, compare the first-use host fingerprint with a trusted source before approving it. Key and agent authentication do not require a saved password. For FTPS, the certificate must be valid for the selected host and trusted by the system or the selected PEM CA bundle. Plain FTP displays its unencrypted status. FTP/FTPS passwords stay in memory until disconnect and are never written to site JSON or command-line arguments. Advanced settings select initial directories, an SSH key, or a TLS CA file. For WebDAV, enter the endpoint path in WebDAV path; Basic authentication and ETag-conditional replacement are supported.

The application keeps its own host-key store and site settings in `~/Library/Application Support/WinSCPMac/`. It deliberately disables SSH config loading (`-F /dev/null`), forwarding, and local commands. ProxyJump, user SSH config aliases, SSH tunnels, PuTTY `.ppk` keys, and imported WinSCP password blobs are not currently supported. A changed trusted host key fails verification; there is no automatic reset or insecure bypass.

Select local files and choose **Upload** (`⌘⇧U`), or select remote files and choose **Download** (`⌘⇧D`). Double-click folders to browse and remote text files to edit. File operations are also available in the context menu and the macOS menu bar.

## Verification

`./scripts/swift.sh test` includes binary-codec tests, configuration/path validation, synchronization planning, site storage, WebDAV XML/URL/ETag validation, and integration tests against Apple's real `/usr/libexec/sftp-server`. Integration tests use disposable local directories, not your SSH account or a public test service. They cover binary and empty-file round trips, difficult filenames, atomic replacement, cancellation, cleanup, permissions, and symlink handling. These protocol tests do not by themselves verify password prompts, host trust dialogs, or internet interoperability.

`./scripts/test-ssh.sh` additionally generates disposable SSH keys, starts unprivileged daemons listening only on `127.0.0.1`, verifies actual SFTP and legacy SCP round trips, and confirms rejection of an untrusted host key. The SCP daemon has no SFTP subsystem, so these tests also demonstrate that SCP does not fall back to SFTP. It removes its keys and stops both daemons on exit. This requires permission to open a localhost port; it does not change your SSH configuration or require Remote Login to be enabled.

For the complete SFTP + SCP + FTP + FTPS + WebDAV suite, install the isolated **test-only** dependencies using Python 3.11+, then run both server fixtures together:

```sh
./scripts/setup-protocol-tests.sh
./scripts/test-ssh.sh --all
# Also verify optimized Swift/C transport code:
./scripts/test-ssh.sh --all -c release
```

The application has no Python dependency. The FTP fixture uses independent pyftpdlib servers and generated certificates in a disposable localhost directory. It covers plain FTP, both FTPS modes, legacy/sparse listings, wrong credentials, permission errors, cancellation, file integrity, timestamps, replacement conflicts, symlink deletion, untrusted certificates, hostname mismatch, and rejection of TLS downgrade. `./scripts/test-ftp.sh` runs this fixture separately; network fixtures are explicitly skipped when unavailable during the offline test command. `./scripts/test-webdav.sh` uses an independent WsgiDAV/Cheroot HTTP/HTTPS fixture with real transfers, conditional MOVE, generated certificates, authentication/read-only errors, cancellation, redirect protection, and partial-status handling. [WebDAV limits](docs/WEBDAV.md) include destination `?`/`;` refusal, no POSIX chmod/upload mtime preservation, and strong ETags being required for replacement.

See [verification results](docs/VERIFICATION.md), [architecture](docs/ARCHITECTURE.md), [feature parity](docs/PARITY.md), and [contributing](CONTRIBUTING.md). [Türkçe](README.tr.md).

## Upstream and license

Original [WinSCP](https://winscp.net/) is maintained by Martin Prikryl and contributors; its source is [winscp/winscp](https://github.com/winscp/winscp). Upstream relies on C++Builder/VCL and Windows integrations, which cannot simply be compiled against AppKit. [The upstream reference](upstream/REFERENCE.md) records the revision investigated for this work.

This repository's original source code is GPL-3.0-or-later; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). The upstream icon set is not used. There is no warranty.
