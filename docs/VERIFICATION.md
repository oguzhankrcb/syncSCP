# Verification record

## 0.4.0 — WebDAV over HTTP/HTTPS

Verified locally on 2026-10-21 with Swift 6.2, macOS's system libcurl, and independent WsgiDAV 4.3.5 / Cheroot 11.1.2 fixtures. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **72 XCTest cases, zero failures, zero skips** on the final source, with no compiler warnings.

The 18 new WebDAV tests cover namespace-aware XML and failed property statuses, DTD/entity rejection and parser bounds, URL encoding/origin/path scope, ETag normalization/version comparisons, binary and empty HTTP/HTTPS round trips, Unicode/URL characters, long names, file/collection operations, no-clobber defaults, strong ETag replacement, a destination change injected immediately before MOVE, reviewed and local-source changes, cancellation and cleanup, absent ETags, rejected ambiguous destinations, unknown permissions, readonly/auth failures, untrusted CA/hostname rejection, TLS downgrade, redirect credential isolation, and partial multi-status errors.

Local synchronization snapshot checks now use the same no-follow stat timestamp conversion as listing. This avoids false conflicts caused by sub-microsecond differences between Foundation and POSIX timestamp construction while retaining file type, size, mode and mtime checks.

The universal 0.4.0 native app was checked against the disposable HTTPS server: protocol/standard-port selection, plaintext warning, untrusted-certificate refusal, verified login using its generated CA, file and recursive folder upload/download, UTF-8 editor save-back, and reviewed synchronization with both new and replaced files. Actual local/server bytes were compared and no temporary transfer collections remained. The final app also demonstrated successful synchronization after the local timestamp conversion fix. Both arm64 and x86_64 release slices compile and strict ad-hoc signature verification passes; physical Intel execution is not claimed.

Production servers beyond WsgiDAV, Digest/NTLM/OAuth, proxies, lock management, timestamp extensions, very large/slow transfers, older macOS and physical Intel hardware remain untested. The baseline's endpoint, strong ETag, MOVE character, timestamp and permission limits are explicit in [WEBDAV.md](WEBDAV.md). This remains an incomplete community development preview, not an official or complete WinSCP port.

## 0.3.0 — legacy SCP

Verified locally on 2026-10-21 with Swift 6.2 and Apple's OpenSSH. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **54 XCTest cases, zero failures, zero skips**. The SCP suite uses a second disposable SSH daemon with no SFTP subsystem and exercises the protocol-independent session, so the SCP path cannot be satisfied by an SFTP fallback.

Local listing now uses no-follow POSIX stat rather than fetching extended attributes during startup; its regular/directory/symlink/dangling-link/FIFO metadata is covered.

New coverage includes legacy file records and strict filename/size validation; GNU/BSD metadata parsing; binary and empty round trips; Unicode, quotes, shell metacharacters and hidden names; permissions/mtime; mkdir/rename/delete; no-clobber and approved replacement; concurrent destination files/directories; reviewed changes before/during upload; changed local sources; cancellation/temporary cleanup; long filenames; no-follow symlink deletion including a trailing slash; root-deletion refusal; missing-file errors; untrusted host refusal; stalled-command cancellation; master shutdown when its owner pipe closes; and refusal to reauthenticate when the control socket disappears.

The universal packaged 0.3.0 app was checked through the native UI against the SCP-only daemon: protocol selection, host fingerprint approval, encrypted private-key passphrase login through Keychain/askpass, file upload, recursive folder upload/download, UTF-8 editor save-back, and reviewed one-way synchronization. Actual local/server file bytes were compared, and no upload partials remained. Subsequent operations reused the authenticated connection after the login credential's normal cleanup.

Both arm64 and x86_64 release slices compile and the app passes strict ad-hoc signature verification. Physical Intel hardware, older macOS, Linux/GNU servers end to end, other SCP implementations, SSH account-password servers, internet latency/failure, and very large transfers remain untested. Remote shell requirements, CR/LF path limits, hard-link requirements and server-side rename race semantics are explicit in [SCP.md](SCP.md). The project remains a development preview, with broader parity tracked separately.

## 0.2.0 — SFTP, FTP, and FTPS

Verified locally on 2026-10-21 with the Swift 6.2 toolchain, Apple's OpenSSH, system libcurl, and independent pyftpdlib 2.2.0 fixtures.

`./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **41 XCTest cases, zero failures, zero skips**, including optimized Swift/C transport code. This includes the complete SFTP baseline, SFTP through the new protocol-independent session, saved-site backward compatibility, FTP listing/URL validation, and real server integration across FTP, explicit FTPS, implicit FTPS, Unix LIST fallback, and sparse MLSD metadata.

New integration coverage includes binary and empty files; Unicode, spaces, quotes and URL metacharacters; cancellation and cleanup; no-clobber defaults and approved replacement; long names; timestamps and permissions; rename/mkdir/recursive delete; symlinks hidden by MLSD; reviewed-destination conflicts; wrong passwords and read-only accounts; untrusted CA rejection; hostname mismatch; and rejection of TLS downgrade.

The packaged 0.2.0 macOS UI was also checked with the disposable explicit-FTPS server: protocol selection and standard-port changes, refusal of its initially untrusted certificate, successful verified connection using its generated CA file, queue upload/download, and UTF-8 editor save-back. Actual server file content was checked. Test passwords and CA keys are unrelated to the user's accounts.

Release packaging targets arm64 and x86_64 and uses ad-hoc signing. Intel is cross-compiled; physical Intel hardware and older macOS releases remain untested. Production FTP/FTPS implementations beyond this fixture, large files/latency, active mode, proxies, resume, client certificates, and non-UTF-8 encodings still need coverage. Server-dependent FTP rename and symlink limitations are recorded in [FTP.md](FTP.md).

## 0.1.0 — original SFTP baseline

Verified locally on 2026-10-21 with macOS on Apple Silicon, Xcode's Swift 6.2 toolchain, and Apple's OpenSSH 10.2p1. The package targets macOS 13+; older macOS versions and physical Intel hardware have not been exercised.

### Automated

`./scripts/test-ssh.sh` completed **22 XCTest cases, zero failures, zero skips** on the final implementation. This includes:

- Binary packet encoding/decoding, truncated/invalid input, names and connection validation, password-free site JSON, and synchronization planning.
- Real OpenSSH SFTP server tests for binary/empty files, Unicode/quotes/newlines, near-limit filename lengths, permissions, rename/mkdir/delete, no-clobber defaults, atomic replacement, cancellation, and partial-file cleanup.
- File-change detection before and during upload, preserving a changed reviewed destination and rejecting a changed local source.
- A real localhost SSH connection using generated keys and a pinned host key, including a known_hosts filename containing spaces, plus rejection of an untrusted host.

`./scripts/build-app.sh --universal` completed release compilation for **arm64 and x86_64**, generated the original icon, created the app bundle, and passed strict ad-hoc code-signature verification. The Intel slice is cross-compiled; that is not evidence of testing on an Intel Mac.

### Manual native UI checks

Using an unprivileged, disposable SSH daemon listening only on localhost, the packaged app was checked for:

- Opening the Commander window and navigating the local path field.
- Login sheet, host-key fingerprint display, fingerprint approval, and subsequent pinned-key connection.
- Explicit OpenSSH private-key login and encrypted-private-key passphrase login through Keychain/SSH_ASKPASS.
- Upload and download through the UI, completed queue entries, and matching file content.
- Opening a remote UTF-8 file, editing it, saving it to the server, and verifying the actual saved bytes.
- Synchronization preview; an external change after preview correctly produced a conflict instead of overwriting it; a new preview then applied successfully.
- Disconnecting the temporary session.

### Boundaries

Not yet verified: SSH password-authentication servers, keyboard-interactive/multifactor SSH flows, hardware keys, third-party SFTP implementations, internet latency/recovery, large multi-gigabyte transfers, VoiceOver, macOS 13–25, physical Intel hardware, Developer ID signing/notarization, and the missing protocol/automation features listed in [PARITY.md](PARITY.md). FTP/FTPS password authentication is covered by the 0.2.0 fixtures above.

The localhost fixture uses generated test keys and disposable local files. It does not modify the user's SSH configuration, enable Remote Login, or contact a public test server. Run `./scripts/test-ssh.sh --serve` for a manual fixture; it prints its directory/port/fingerprint and stays alive until Ctrl-C, then removes its files and stops its daemon.
