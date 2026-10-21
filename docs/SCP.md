# SCP in 0.3.0

SCP is a separate backend. File bytes use the legacy SCP wire protocol over SSH channels running the server's `scp -t` (sink) or `scp -f` (source). The app implements the acknowledgements and file records itself; it does not invoke a modern local `scp` client that might default to SFTP. SFTP is not used for SCP directory operations either.

## Server requirements

The server needs a Unix account that can execute `/bin/sh`, OpenSSH-compatible `scp -f/-t`, GNU or BSD `stat`, and ordinary tools on `/usr/bin:/bin:/usr/sbin:/sbin`: `link`, `mv -n`, `mkdir`, `rmdir`, `rm`, `chmod`, and `touch -t`. macOS/BSD metadata is exercised against a real server; GNU stat parsing is unit-tested, but a Linux server has not yet been exercised end to end. Windows SSH shells, SFTP-only accounts, restricted forced-command accounts, and BusyBox-only environments are not covered. The login shell must accept POSIX quoting when invoking `/bin/sh`. Noninteractive shell startup files must not print to stdout.

No Python, Perl, uploaded helper program, sudo, or server configuration change is required by the app. Account permissions still determine which files it can access. Like WinSCP, metadata and file-management commands run in **one persistent shell** per session (the configured SCP/Shell, such as `sudo su -`, or `/bin/sh`). The shell starts once; any login banner is skipped once. Each command runs as `/bin/sh -c` with no stdin and returns its exit status after a unique end marker. A cancelled or broken command closes that shell and the next command starts a new one. Only `scp -t`/`scp -f` transfer streams get channels of their own. This removes the per-command SSH channel and shell start-up that made folder navigation slow, especially with `sudo su -`.

## Authentication and lifetime

The app uses the same approved host-key store, strict OpenSSH verification, explicit key/agent authentication, and temporary Keychain/askpass login as SFTP. Port 22 is selected by default. Local SSH configuration and forwarding remain disabled.

One foreground OpenSSH master authenticates the session. Its control socket lives in an unpredictable mode-0700 directory beneath `/tmp`. The persistent shell and transfer channels reuse this master. An already-open shell may continue after the control socket disappears, because it needs no new authentication; any new channel fails. They use batch mode and a failing ProxyCommand so a missing control socket cannot silently create a new direct connection or ask for the deleted login credential. Disconnect terminates the master and removes its socket directory. An initial remote `cat` holds the master open only while the app owns its input pipe. Closing that pipe, including an app crash, ends the initial channel and master; unlike an idle `ssh -N`, it does not intentionally survive its owner. Pipe EOF shutdown is integration-tested. A crash can still leave a temporary directory; stale-directory maintenance remains future work.

## Names and metadata

All remote command paths are separately POSIX-quoted positional arguments to `/bin/sh`. Spaces, apostrophes, quotes, dollar signs, backticks, wildcard characters, leading hyphens, and UTF-8 are tested. No filename becomes executable shell code. Listing uses shell globbing and `stat` records, with NUL delimiters for paths; it never parses `ls`. Hidden entries, regular files, directories, and symbolic links are distinguished. Metadata includes basic mode, byte size, and whole-second modification time.

Listing and ordinary file operations can represent newline-containing names. SCP transfers explicitly reject CR/LF anywhere in the remote path because its control protocol is line-based; select SFTP for such files. Invalid UTF-8, unexpected filenames, directory records, size mismatches, excessive control lines/output, and trailing file records are rejected. Download filenames must exactly match the requested basename, and data always goes to the chosen local temporary file; the server cannot select an alternate local path.

Symlinks and special files are not transferred. Stat is no-follow by default, and recursive deletion removes symbolic links themselves. The app's existing directory traversal handles folder transfers; the SCP recursive wire mode is not enabled.

## Transfer commits and cancellation

Uploads create an exclusive mode-0700 temporary directory beside the destination and send a fixed `payload` filename into it. After SCP acknowledges completion and exits, the app verifies the local source, sets basic mode/mtime, rechecks any reviewed destination, and publishes the completed file. Existing destination permissions are preserved on approved replacement; setuid/setgid bits are not copied.

Unapproved uploads publish with the POSIX `link` utility. Unlike `ln`'s directory-target convention, this fails if the exact destination already exists, including a file, symlink, or directory that appears during transfer. The temporary hard link is then removed. This requires hard-link support on the destination filesystem and does not fall back to a clobbering move.

Approved replacements use the server's `mv -f` between sibling files. On ordinary local Unix filesystems this uses rename; behavior across unusual/network filesystems is server-dependent. Remote size/mtime/type checks and shell checks are best-effort, not an atomic compare-and-swap. Concurrent changes to destination directories or parent symlinks cannot be ruled out through portable shell commands; do not interpret this as protection against an adversarial server or another process replacing directory paths. Explicit remote rename uses `mv -n`; its directory semantics and concurrent type changes are also server-dependent. No delete-first replacement fallback is used.

Downloads use a mode-0600 local sibling temporary file, exact-size SCP records, a post-transfer stat check, then macOS atomic no-clobber rename or approved replacement. Only basic mode and mtime are preserved; ownership, ACLs, extended attributes, and sparse-file layout are not.

Reads and writes check cancellation with nonblocking pipes and a 45-second inactivity deadline. Cancelled/failed transfers close their channel and attempt temporary cleanup through the still-authenticated master. Network failure may leave a recognizable `.winscp-UUID.filepart` directory on the server. Resume, retry, parallel transfers, bandwidth limits, checksums, and multifactor authentication remain future work.

## Verification

`./scripts/test-ssh.sh` starts two disposable localhost SSH daemons using generated keys. One offers SFTP; the SCP-only daemon has **no SFTP subsystem**. SCP integration tests connect to the latter through `RemoteSession`, covering binary/empty files, names, listing, file operations, permissions/mtime, replacement, conflicts, cancellation/cleanup, symlink handling, root-deletion refusal, long names, host trust, prompt cancellation, owner-pipe shutdown, and failure rather than reauthentication after control-socket loss. `./scripts/test-ssh.sh --all` adds the independent FTP/FTPS fixtures. No user SSH settings or Remote Login settings are changed.

Protocol references: [OpenSSH scp manual](https://man.openbsd.org/scp), [OpenSSH SCP source](https://github.com/openssh/openssh-portable/blob/master/scp.c), and [OpenSSH multiplexing configuration](https://man.openbsd.org/ssh_config#ControlMaster). The new Swift implementation is original code, not copied OpenSSH source.
