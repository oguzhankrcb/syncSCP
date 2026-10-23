# Verification record

## 0.22.0 — Turkish interface

Verified locally on 2026-10-23. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **134 XCTest cases, zero failures, zero skips** (no core change).

- `scripts/check-localization.py` collects every interface text (the compiler's `-emit-localized-strings` output plus texts that components receive as `String`) and reports 0 of 585 keys without a Turkish translation; `plutil -lint` accepts the strings file, and every translation keeps its key's format specifiers.
- The main window, Settings, Advanced Site Settings (SSH page) and Synchronize were rendered with `-AppleLanguages (tr)` and an empty data store: toolbar, panes, column headers, file kinds, queue tabs, footers, settings tree and badges, synchronization directions and actions were Turkish.
- **Not tried by me:** the menu bar and every alert in the running app in Turkish, and the Settings ▸ Language restart. Error messages from the core and the session log stay English.

## 0.21.0 — Quick Open, bookmarks, Quick Look, SSH config import, protected PuTTY keys

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **134 XCTest cases, zero failures, zero skips**.

- New BLAKE2b and Argon2 tests: the RFC 7693 and RFC 9106 known-answer vectors for Argon2d, Argon2i and Argon2id all match. PuTTY's typical default cost (8 MiB × 21 passes) takes about 4 s in a debug build and well under a second in release.
- New PuTTY key tests: format 2 and format 3 (Argon2id) passphrase-protected files, built from the existing vectors following sshpubk.c, convert to keys whose public halves `ssh-keygen -y` confirms; a wrong or missing passphrase is refused. A converted key protected through askpass opens only with its passphrase; a failing askpass is reported instead of leaving a key that looks protected.
- New SSH config test: first-value-wins with `Host *` defaults, negated patterns, ProxyJump with user and port (extra hops reported), ProxyCommand, two LocalForwards (one IPv6), keepalive, missing identity files and unsupported keywords.
- A scripted run of the real `CommanderModel` against the SFTP test daemon passed 12 checks: Quick Open connected a key-based site directly and sent a password site to Login; remote bookmarks were saved with the site and removed; a local bookmark was added once; a remote file was fetched for Quick Look and its temporary copy removed afterwards; a PuTTY key converted from the app into the keys folder, owner-only, and worked with ssh-keygen.
- **Not tried by me:** the ⌘K window and Quick Look panel by hand, importing the user's real ~/.ssh/config, and a passphrase-protected key file written by PuTTY itself (no puttygen on this Mac; the format was built from the specification and Argon2 checked against RFC vectors).

## 0.20.0 — Directory tree, Compare Directories, Find Files, remote copy/move, bulk permissions

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **128 XCTest cases, zero failures, zero skips**.

- New integration test against both SSH daemons: duplicating a file and a folder tree on the server over SFTP (through temporary files) and SCP (`cp -pR`), refusing an existing destination and a folder copied into itself.
- A scripted run of the real `CommanderModel` against the SFTP test daemon passed 12 checks: Compare Directories marks (newer/older/one-sided, nothing for identical, none when off); Find Files with `*.log; *.MD` matched case-insensitively in subfolders and a result opened its folder with the file selected; recursive permissions gave folders 750 and files 640; a move into a folder; the tree listed only subfolders.
- The window was rendered with the tree and compare marks against the test daemon and looked right.
- **Not tried by me:** the Duplicate / Move To dialogs and the Permissions sheet by hand; the tree does not show folders reached through a symbolic link (such as /var).

## 0.19.0 — Two-way synchronization and Keep Remote Directory up to Date

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **127 XCTest cases, zero failures, zero skips**.

- New planner test: both ways (newer wins, an unknown time is a conflict, folders both ways, never deletes), newer-only, plain one-way, mirror deletions in each direction with a deleted folder covering its contents, size-only, and a symlink in the way.
- A scripted run of the real `CommanderModel` against the SFTP test daemon passed 19 checks: a two-way synchronization of files and folders with different ages; a local file edited after the comparison stopped the run and the server copy was kept; a second comparison found nothing; a mirror upload deleted a remote-only file; Keep up to date uploaded a new file inside new folders and a later save, ignored .DS_Store, did not mirror a local deletion and stopped uploading when stopped.
- Fixed while testing: watching a folder under /var or /tmp never matched FSEvents paths, because Foundation turns /private/var into /var; the root is now resolved with realpath(3).
- **Not tried by me:** Remote → Local mirror deleting into the Trash in the running app (planner-tested only), and the new Synchronize window controls by hand.

## 0.18.0 — Terminal tabs, split panes, find, snippets and port forwarding

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **126 XCTest cases, zero failures, zero skips**.

- New unit test: port-forward arguments keep only the requested loopback `-L`, drop ClearAllForwardings (which would cancel it), keep strict host keys, bracket IPv6 destinations and reject option-like or malformed hosts and ports; forwards round-trip in site settings.
- New integration test: a forward through the SFTP daemon to the SCP daemon's port returned an `SSH-2.0-` banner on the local port; a second forward on the same port exited at once with an error.
- A terminal window was opened against the SCP-only daemon (through a `sudo su -` stand-in), split right and then down: three separate logins in a left / top-right / bottom-right layout; a snippet ran in the focused pane; closing the window ended all three.
- **Not tried by me:** Find in the running app, the tab bar's + button, Close Pane's confirmation, Login ▸ Terminal, and the Port Forwarding window itself (its ssh command is the tested one).

## 0.17.0 — Background transfers, retry and resume

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **124 XCTest cases, zero failures, zero skips**.

- New SFTP tests against Apple's sftp-server, killing the server process mid-transfer: an interrupted 5 MB upload and 4 MB download are kept as partial files and finish on a new connection without resending what arrived; a source that changed between attempts starts over; cancellation still removes partials.
- A scripted run of the real `CommanderModel` against the SFTP test daemon passed 16 checks: two 60 MB uploads ran at the same time on two extra ssh connections while the panes stayed usable and browsing worked; one transfer connection was killed, the job reported a retry and both files arrived byte for byte, with 18 MB not sent again; no partial files were left; a retried folder job skipped files it had already finished. The 0.15.0 session-tab scenario still passes.
- **Not tried by me:** retries over SCP, FTP, WebDAV and S3 (they start the file over by design), a real network drop, the Settings steppers and the quit warning in the running app.

## 0.16.0 — Saved passwords

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **121 XCTest cases, zero failures, zero skips**.

- New import test: passwords written with WinSCP's own encoding steps (flagged and old format, with and without padding) decode; a different user+host prefix, truncated values and garbage are rejected with a "master password" warning; `PasswordPlain` is read.
- The decoder was run on the user's real WinSCP.ini printing counts only: 8 of 8 saved passwords decoded with the user+host prefix check passing.
- New terminal test: a saved-password login passes only its own askpass, never an inherited one, and keeps BatchMode off.
- The Keychain layer was exercised with a temporary item: save, update, list without reading secrets, remove.
- **Not tried by me:** logging in with a saved password to a password-authenticated server (the SSH fixtures use keys), the Touch ID prompt, the import sheet's password option in the running app, and the macOS Keychain access prompt after an app update.

## 0.15.0 — Session tabs

Verified locally on 2026-10-22. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **119 XCTest cases, zero failures, zero skips** (the core is unchanged).

- A scripted run of the real `CommanderModel` against the SFTP and SCP-only test daemons (with its own site store, never the user's) passed 16 checks: a second site opens a second tab while the first stays connected; each tab keeps its remote and local folders; a 48 MB upload started on tab B completes on B's connection while tab A is shown and browsed; nothing lands in A's folder; next-tab wraps; closing a tab shows its neighbor; closing the last leaves no session.
- **Not tried by me:** clicking the tab strip in the running app, Duplicate Session, and external edits across tabs.

## 0.14.0 — SSH terminal

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **119 XCTest cases, zero failures, zero skips**.

- New unit tests: the terminal login keeps the strict host-key options while dropping BatchMode; the folder and the SCP shell become one quoted remote command; the askpass hook never reaches the terminal environment; and Terminal.app's `.command` file reproduces every argument, including `$(…)`, backticks and quotes, then deletes itself and its folder.
- New tests against the real SSH daemons on a pseudo-terminal: the session starts in a remote folder whose name contains quotes and `$( )`, gets `TERM=xterm-256color` and a remote tty; a configured shell (a `sudo su -` stand-in) starts once and runs typed commands; an unknown host key is refused.
- The terminal window was opened against the SSH fixture and captured in light and dark mode: listing, Turkish characters, ANSI colors, `vi` full-screen, the window subtitle from the remote title, a Nerd Font prompt, and the "Session ended" line after `exit`.
- **Not tried by me:** typing into the packaged app by hand, password/keyboard-interactive prompts on a real server, a real `sudo` that asks for a password, Terminal.app opening, and the close/quit confirmations.

## 0.13.0 — Renamed to syncSCP

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **112 XCTest cases, zero failures, zero skips**. Older entries below keep the names that were current at the time (WinSCPMac, WinSCPCore, `WINSCP_*`).

- Modules, bundle, bundle identifier, Keychain service, environment variables and archive names were renamed (see README).
- New unit test: a legacy data folder is copied once, paths into it are rewritten, the old folder stays intact, and a second run does nothing.
- The migration was also run against a copy of the real local data folder (the original was only read): every site and every key path came across, key files existed at their new paths, and `known_hosts` was complete. The copy was deleted.
- The FTP fixture's welcome text changed with the name, so one size expectation moved from 50 to 51 bytes.
- README screenshots were re-rendered offscreen with the new window title. The app was packaged and codesign-verified. **The packaged app's first launch (which performs the real migration) was not run by me.**

## 0.12.0 — New file

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **111 XCTest cases, zero failures, zero skips**.

- New SFTP test: the exact New File path (an empty upload with `replace: false`) creates a 0-byte file, refuses to replace an existing file (whose content is kept), and opens for editing.
- Empty-file round trips and no-clobber uploads were already covered for every protocol.
- Local creation uses `O_CREAT | O_EXCL`.
- The New ▾ menu was rendered offscreen. The app was packaged, codesign-verified, and launched and quit normally. **The menu and Shift+F4 were not clicked through interactively.**

## 0.11.0 — External editors

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **110 XCTest cases, zero failures, zero skips**. The 3 new tests use the real SFTP daemon:

- A downloaded copy lives in a 0700 folder. Touches and unchanged saves upload nothing.
- In-place saves and atomic replace-on-save each upload exactly the new content. A missing file mid-save is reported as missing, not as an error.
- A server-side change made after opening blocks the upload (the server copy is kept) until an explicit overwrite. After that, the new version is the baseline.
- The change monitor notices in-place writes and atomic replacements, and stays quiet without changes.

The Editing tab and the Settings window were rendered offscreen. The app was packaged, codesign-verified, and launched and quit normally. **Opening a real external application, the conflict dialog, and the Edit With menu were not exercised interactively.** Change detection compares content hashes locally, and the server check uses size/mtime (and ETags where the protocol has them), so a same-size, same-second change on the server can go unnoticed, as documented for the built-in editor.

## 0.10.0 — Persistent SCP shell, ".." row, clickable path

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **107 XCTest cases, zero failures, zero skips**. Integration tests on the SCP-only daemon show:

- The configured shell (a `sudo su -` stand-in that prints a banner and changes to another home) starts once for the whole session. The session's home is the shell's directory, so the commands really ran inside it.
- Only the two transfer streams start further shells. mkdir, rename, list, a failed stat, recursive delete and exists all reuse the persistent shell.
- With a shell that takes 0.5 s to start, 20 realpath/list commands complete in under 3 s, using a single shell start. The previous per-command design needed at least 10 s.
- The control-socket test was tightened. After the socket disappears, the existing authenticated shell may continue; a new transfer channel fails; and after a cancellation closes the shell, the next command fails instead of re-authenticating.

The ".." row and the breadcrumb strip were rendered offscreen. The ".." row is first, unsorted, and excluded from every selection action and drag. The app was packaged, codesign-verified, and launched and quit normally. **The speed-up was not measured against the user's real servers**, and the new UI was not clicked through interactively. GNU stat listings still start one `stat` process per entry on the server.

## 0.9.0 — Drag and drop, Commander keys, remembered folders

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **106 XCTest cases, zero failures, zero skips**. A first debug attempt exited with code 1 before running any test and left an empty log; the rerun passed, and the cause was not identified. A headless harness checked the drag payloads:

- remote rows round-trip their paths (including quotes and `$`) under the app-private type;
- local rows deliver their file URL;
- each pane refuses the other side's type;
- F5 maps to `NSF5FunctionKey`.

The universal 0.9.0 app was packaged (the ignored mockup no longer enters the source ZIP), passed strict codesign verification, and launched and quit normally. **Dragging with the mouse, the function keys and remembered folders were not exercised interactively in the running app.** Dragging remote items into Finder (file promises) is not implemented.

## 0.8.0 — WinSCP import

Verified locally on 2026-10-21. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **106 XCTest cases, zero failures, zero skips**, with no compiler warnings.

The 8 new tests cover:

- A realistic `WinSCP.ini` and the same data as a UTF-16 `reg export` (dwords, wrapped binary float, escaped quotes) and as a Wine `user.reg` (doubled key backslashes, timestamps, `\x` escapes).
- Key names, enum numbers/names and mappings taken from upstream `TSessionData::DoLoad`.
- Skipped defaults, workspaces and hostless sites, and that no secret reaches `sites.json`.
- Ed25519/RSA/ECDSA host keys converted from PuTTY's format, compared exactly with vectors produced independently from `ssh-keygen` keys (Ed25519 points decompressed in separate Python math and checked to recompress).
- PPK format 3 (Ed25519) and format 2 (RSA) written by a separate Python implementation of PuTTY's format; the converted keys derive the original public key with `ssh-keygen -y`. Tampered, encrypted and malformed files are refused.
- An end-to-end commit from a fake Wine prefix: `C:\` resolution, a shared key converted once at mode 0600, unique names, the backup, re-import recognized, and a conflicting trusted key kept.

A real backup bug was found and fixed: two imports in the same second collided on the backup folder name.

**Real data:** at the user's request, the WinSCP configuration of their WinSCP under Whisky was found with **Find on This Mac** logic and imported through the same commit code the app uses. Only aggregate counts were printed:

- 26 sites (12 SCP, 14 SFTP), none skipped, all valid, including 14 custom shells;
- 3 PPK v3 keys (2 RSA, 1 Ed25519, no passphrase) converted for 19 sites, each deriving its original public key at mode 0600;
- 34 Ed25519 host keys added with no conflicts;
- the previous `known_hosts` backed up first; no password-like fields written.

The import window was rendered offscreen. The universal 0.8.0 app was packaged, passed strict codesign verification, and launched and quit normally. **Logging in to the imported servers was not attempted**, and the import window was not clicked through in the running app.

## 0.7.0 — Commander and Login redesign

Verified locally on 2026-10-21. The redesign follows the mockup the user approved. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **98 XCTest cases, zero failures, zero skips** (there are no new automated UI tests; the core is unchanged). The main window was rendered offscreen in light and dark mode, disconnected and with sample connected state. The Login sheet was rendered with grouped sample sites. Two layout faults found in those renders were fixed: clipped Rights columns, and "Zero KB" totals. The universal 0.7.0 app was packaged, passed strict ad-hoc codesign verification, and launched and quit normally.

**Not exercised interactively:** clicking through the new toolbars, back/forward history, Save As/Rename, or a real session in the running app. Mockup controls without a feature behind them were deliberately left out rather than added as dead buttons: Compare directories, Terminal, transfer-settings presets, Find Files, and the Owner column.

## 0.6.0 — Advanced Site Settings

Verified locally on 2026-10-21 with Swift 6.2, OpenSSH 10.2p1, system libcurl and the existing SSH, FTP, WebDAV and MinIO fixtures. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **98 XCTest cases, zero failures, zero skips**, with no compiler warnings.

The 5 new unit tests cover:

- Default options that keep the previous behavior and OpenSSH's own algorithm defaults.
- Mapping of edited timeouts, keepalives, address family, compression, cipher/kex policies (groups below the warning line are excluded), rekey limits, agent/keyboard-interactive/agent-forwarding/GSSAPI and certificate options.
- The custom SFTP server command.
- `nc` proxies for SOCKS4/5 and HTTP, local proxy token mapping, and the localhost bypass. Telnet, authenticated-proxy and dummy-keepalive values are refused.
- Nested tunnel quoting, including `%` escaping and a proxy inside the tunnel.
- Validation and data-size parsing, and lenient decoding of missing, unknown and future values.

The 6 new integration tests show:

- Every SCP operation runs inside a configured shell that prints a login banner and then reads commands like `sudo su -`. This includes both connection probes, upload, download, mkdir, rename, list and recursive delete.
- A shell that cannot start fails at login with a NOPASSWD hint.
- On the SCP-only daemon, the default SFTP subsystem fails and a configured SFTP server command works.
- SCP works through a real SSH tunnel, the SFTP daemon acting as bastion with both keys pinned; an unknown bastion is refused.
- SFTP works through a local proxy command (`/usr/bin/nc %host %port`).
- Host-key discovery through the tunnel records exactly the target's key.
- libcurl honors IPv6-only versus IPv4.
- WebDAV works through a real SOCKS5 proxy (`ssh -D`), fails once that proxy is stopped, and bypasses it for localhost when local proxying is off.

The existing site-store test caught a new setting name containing "password" in `sites.json`; the field was renamed rather than relaxing the test.

The dialog was rendered offscreen for SCP/Shell, SSH, SFTP, Tunnel, S3 and Proxy pages and inspected. The universal 0.6.0 app (arm64 and x86_64) was packaged, passed strict ad-hoc codesign verification, and launched and quit normally. **The Login → Advanced… flow and a real `sudo` account were not exercised interactively in the running app.** Proxy authentication, Telnet proxies, tunnels for FTP/WebDAV/S3, and the options badged Planned are not applied. See [SETTINGS.md](SETTINGS.md).

## 0.5.0 — S3 over HTTP/HTTPS

Verified locally on 2026-10-21 with Swift 6.2, macOS's system libcurl and CryptoKit. The independent fixture is MinIO `DEVELOPMENT.2025-07-23T15-54-02Z` from the digest-pinned `bitnamilegacy/minio:2025.7.23` image under Docker 27.3.1. Official community MinIO images are no longer published. `./scripts/test-ssh.sh --all` and `./scripts/test-ssh.sh --all -c release` each completed **87 XCTest cases, zero failures, zero skips** on the final source, with no compiler warnings. Both runs removed their containers.

The 6 S3 unit tests cover:

- SigV4 signatures matching three AWS-published examples, and canonical query/key encoding.
- Virtual-hosted and path-style addressing, including IP, localhost, IPv6, non-DNS and dotted-bucket rules.
- Path/key mapping and the 1024-byte key limit.
- Backward-compatible site decoding, with no secret in saved JSON, and region/access-key validation.
- URL-encoded listings, pagination tokens, out-of-scope and DTD rejection.
- Hidden unaddressable keys, folder-over-object precedence, and bucket and error documents.

The 9 integration tests use separate HTTP and HTTPS MinIO servers with a generated CA. They cover:

- Binary and empty round trips on both servers, and bucket listing.
- Unicode and URL-metacharacter names, folder markers, mkdir/rename/delete rules, refused bucket operations, and missing paths.
- No-clobber and approved replacement, with a destination created or replaced after the client's checks. The server condition rejected each write and the other version was kept.
- A 3-part multipart round trip; cancellation and conditional failure with no remaining multipart uploads.
- Cancellation and same-size local changes during upload. The server rejected the mismatched signed payload and the old object was kept.
- Download cancellation.
- Server-side-copy rename that keeps Content-Type and user metadata, including onto an existing object and for an empty object.
- Backslash and control-character keys: hidden from listings, but deleted exactly by recursive delete.
- Paginated listings.
- Untrusted CA, hostname mismatch, wrong secret, wrong region, empty secret, and a list/read-only account refused on upload, delete and mkdir.

Before implementation, MinIO's behavior was probed directly:

- It enforces `If-None-Match`/`If-Match` on PUT and on CompleteMultipartUpload.
- It ignores them on CopyObject and DELETE. This is why rename uses multipart copy with a conditional completion, and why the source delete is documented as unconditional.
- It locks an object for the whole PUT, so race tests inject changes after the client's checks rather than mid-stream.
- It rejects keys with empty or dot segments.

`./scripts/package-release.sh` built the universal 0.5.0 app (arm64 and x86_64) and verified ZIPs; strict ad-hoc codesign verification passed. The packaged app launched and quit normally. **The S3 login sheet and transfers were not exercised through the native UI in this session.** AWS S3 and other providers, virtual-hosted addressing on real DNS, STS tokens against a real service, region redirects, very large or slow transfers, older macOS and physical Intel hardware remain untested. GitHub-hosted CI has no Docker and therefore sets `WINSCP_SKIP_S3=1`; S3 is verified only where Docker runs. Limits are in [S3.md](S3.md).

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
