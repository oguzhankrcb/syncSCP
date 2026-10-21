# FTP and FTPS in 0.2.0

The same Commander panels, queue, file editor, and one-way synchronization now work with FTP, explicit FTPS, and implicit FTPS. This is a tested baseline, not a claim of complete WinSCP FTP compatibility.

| Protocol | Standard port | Protection |
| --- | --- | --- |
| FTP | 21 | Unencrypted control and data; the UI labels this explicitly |
| Explicit FTPS | 21 | AUTH TLS required, with protected control and data channels |
| Implicit FTPS | 990 | TLS from connection start, with protected data channels |

## Server identity and credentials

Both FTPS modes require a verified certificate chain and a matching hostname, with TLS 1.2 or later. The default uses the system libcurl trust configuration. Advanced settings can select a PEM CA bundle for a private CA; this is scoped to the site and does not modify macOS trust settings. There is no insecure certificate bypass or automatic downgrade to plain FTP.

Passwords remain in memory for the active FTP session and are supplied through libcurl's API. Saved JSON contains protocol, host, username, directories, and the optional CA path, but no password. Credentials are not added to URLs, process arguments, environment values, or log messages. Proxies inherited from the environment and netrc credential loading are disabled.

## Files and listings

The client requests MLSD type/size/UTC modify/Unix-mode facts. Servers without MLSD, or with insufficient optional facts, fall back to Unix or DOS LIST. Unknown Unix permissions are displayed as unavailable; ambiguous LIST timestamps are left unavailable rather than assigning an invented timezone/year. Non-UTF-8 and unrecognized listings fail visibly. Local special files are not presented as regular transferable files.

FTP is line-oriented: control characters in paths are rejected before sending commands. Spaces, quotes, Unicode, percent signs, hashes, and question marks are preserved using URL encoding for transfers and validated raw FTP command arguments for operations. No shell is invoked. Only passive data connections are currently implemented, and PASV addresses are restricted to the control peer through libcurl's skip-PASV-IP option.

Files upload through UUID `.filepart` siblings. Cancellation and ordinary failures attempt to remove partial uploads without touching the original destination. Download commits use the same local atomic no-clobber/replacement rules as SFTP. FTP upload commits use RNFR/RNTO; replacement behavior and atomicity depend on the server. FTP has no standard compare-and-swap or guaranteed no-clobber rename, so concurrent writers can race the pre-commit checks. No delete-first replacement fallback is used.

MFMT preserves modification times and SITE CHMOD preserves mode bits when supported; unsupported metadata commands are optional. Ownership, ACLs, extended attributes, and setuid/setgid preservation are not implemented. Unsupported SITE CHMOD requests made explicitly through the permissions editor report the server error.

Recognized symlinks are not transferred by the UI. Some FTP servers resolve symlinks before reporting MLSD file types, so ordinary browsing/download type information is only as reliable as the server's metadata. Recursive deletion independently obtains Unix LIST types to distinguish existing symlinks from directories; a symlink is deleted as a link. Recursive deletion on servers exposing only DOS/unknown file types is refused. This is a best-effort path-based operation, not a guarantee against another actor replacing paths concurrently.

## Verification and remaining work

Independent pyftpdlib fixtures exercise all three transports, legacy/sparse listings, arbitrary binary and empty files, Unicode and URL metacharacters, cancellation and cleanup, permissions/timestamps, reviewed destination conflicts, recursive deletion and symlink handling, incorrect passwords, read-only accounts, untrusted certificates, hostname mismatch, and TLS downgrade rejection. The Python packages and generated certificates are test-only.

Pending: active mode, FTP proxies, client TLS certificates, transfer resuming, configurable encodings, more server implementations, larger transfer/latency coverage, and stronger synchronization options. Servers lacking reliable timestamps may cause repeated size/mtime synchronization proposals.

Protocol references: [RFC 3659](https://www.rfc-editor.org/rfc/rfc3659.html), [libcurl TLS requirement](https://curl.se/libcurl/c/CURLOPT_USE_SSL.html), [certificate verification](https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYPEER.html), [FTP command interface](https://curl.se/libcurl/c/CURLOPT_QUOTE.html).
