# Advanced Site Settings in 0.6.0

The **Advanced…** button on the Login sheet opens WinSCP's Advanced Site Settings, page for page (upstream `source/forms/SiteAdvanced.dfm`). The page tree depends on the protocol, as in WinSCP:

- **SFTP:** Environment ▸ Directories, Recycle bin, Encryption, SFTP · Connection ▸ Proxy, Tunnel · SSH ▸ Key exchange, Authentication, Bugs · Note
- **SCP:** Environment ▸ Directories, Recycle bin, SCP/Shell · Connection ▸ Proxy, Tunnel · SSH ▸ … · Note
- **FTP/FTPS, WebDAV, S3:** Environment ▸ Directories, Recycle bin, FTP/WebDAV/S3 · Connection ▸ Proxy, Tunnel, TLS/SSL (encrypted variants) · Note

Every control is in one of these states. Nothing editable silently does nothing.

| Badge | Meaning |
| --- | --- |
| *(none)* | Applied to connections in this release |
| **Planned** | Stored with the site and disabled; not applied yet |
| **Not available with OpenSSH** | PuTTY-only option with no OpenSSH equivalent; disabled |
| **Not applicable on macOS** | Windows-only behavior; disabled |
| **Always on** | This port always behaves this way |
| Other text | A specific explanation, e.g. "Listings use stat, not ls" |

Settings are saved in the site's `settings` object in `sites.json`. Missing or unknown values fall back to defaults, so older and newer site files both load. Passwords, proxy passwords, tunnel passwords, S3 secret keys and session tokens are never saved.

## Applied settings

| Page | Setting | How it is applied |
| --- | --- | --- |
| SCP/Shell | **Shell** (e.g. `sudo su -`, `sudo -s`) | Each SCP command channel starts the shell as the remote command. It then sends one line: a unique marker followed by `exec` of the quoted script. Banner output before the marker is discarded, and SCP data is only written after the shell has consumed that line. The connection probe also runs through the shell, so a shell that cannot start fails at login. `sudo` must not prompt (NOPASSWD), as in WinSCP. |
| SFTP | **SFTP server** (e.g. `sudo /usr/lib/openssh/sftp-server`) | Runs as the remote command instead of the `sftp` subsystem. Shell start-up files must print nothing. |
| Directories | Remote / local directory | Initial folders (the former Login fields). |
| Directories | Remember last used directory | Saved sites store the folders of both panes after each successful navigation. |
| Connection | Server response timeout | SSH `ConnectTimeout`. libcurl connect and FTP response timeouts, with a stall limit of at least 45 s. |
| Connection | Keepalives: Off / null SSH packets, interval | `ServerAliveInterval` (`ServerAliveCountMax=2`). |
| Connection | Internet protocol version | SSH `AddressFamily`, libcurl `IPRESOLVE`. |
| Proxy | SOCKS4, SOCKS5, HTTP (no authentication) | SFTP/SCP: `ProxyCommand=/usr/bin/nc -X 4/5/connect -x host:port %h %p`. FTP/WebDAV/S3: libcurl proxy (`socks4a`/`socks5h` unless DNS lookup at proxy end is No). |
| Proxy | Local proxy command (SFTP/SCP) | `ProxyCommand`, with `%host`/`%port` mapped to `%h`/`%p`. |
| Proxy | Consider proxying local host connections | When off, `localhost`, `127.*` and `::1` bypass the proxy. |
| Tunnel | Host, port, user, private key (SFTP/SCP) | A nested `ssh -W %h:%p` used as `ProxyCommand`, verified strictly against the app's own known_hosts (optionally through the proxy). `ProxyJump` is not used because OpenSSH ignores command-line verification options for jump hosts. The bastion's fingerprint is approved first; the target's key is then read through the tunnel. |
| TLS/SSL | Minimum / maximum TLS version | libcurl `SSLVERSION` (default TLS 1.2 – library maximum). |
| TLS/SSL | Trusted CA certificate | Per-site PEM bundle (the former Login field). |
| SSH | Enable compression | `Compression`. |
| SSH | Encryption cipher selection policy | When reordered, `Ciphers` lists the groups above the warning line. The default order keeps OpenSSH's own defaults. OpenSSH cannot ask mid-handshake, so groups below the line are not offered. Blowfish, Arcfour and DES are not in macOS's OpenSSH. |
| Key exchange | Algorithm selection policy | `KexAlgorithms` on the same rule. RSA kex and DH groups 15/17 are not in macOS's OpenSSH. |
| Key exchange | Max minutes / data before rekey | `RekeyLimit` (`0` → OpenSSH default / none). |
| Authentication | Attempt agent; keyboard-interactive; agent forwarding | `IdentityAgent=none` when off; `KbdInteractiveAuthentication`; `ForwardAgent`. |
| Authentication | Private key, certificate | `-i` with `IdentitiesOnly`; `CertificateFile`. |
| Authentication | GSSAPI authentication, credential delegation | `GSSAPIAuthentication`, `GSSAPIDelegateCredentials` (off by default to avoid Kerberos delays; WinSCP defaults to on). |
| S3 | Default region, URL style, Requester pays | SigV4 region; path or virtual-hosted URLs; `x-amz-request-payer: requester`. |
| Note, Color | Note text, site color | Shown as a tooltip and colored icon in the site list; the color also appears in the session bar. |

If a stored value cannot be applied, the connection fails with an explanation rather than ignoring it. Examples: a dummy-command keepalive, a Telnet proxy, an authenticated proxy, or a tunnel on a curl-based protocol.

## Not applied in this release

- **Planned:** EOL/UTF-8/time-zone overrides; synchronized browsing and directory caching options; recycle bin; file encryption; SFTP versions 4–6, path canonicalization, SCP fallback and SFTP bug flags; SCP user-group lookup; all FTP protocol options (post-login commands, MLSD/LIST control, HOST, account, VMS, active mode, FTP keepalives); S3 role ARN; WebDAV liberal escaping; dummy-command keepalives; proxy authentication and Telnet proxy; tunnel passwords; tunnels for FTP/WebDAV/S3; TLS client certificates; bypass authentication.
- **Not available with OpenSSH:** PuTTY terminal settings, scp1 compatibility, single-DES, GSSAPI key exchange, SSH connection buffer optimization, and the whole SSH Bugs page.
- **By design:**
  - Return code variable and LS listing options: the port reads exit status from SSH and lists with `stat`.
  - Clearing aliases and national variables is always on: scripts run in a fresh `/bin/sh` with `LC_ALL=C`.
  - "Respond with a password to the first prompt" is always on: askpass answers with the entered password.
  - Cross-host WebDAV redirects are refused for security.
  - Daylight-saving adjustment is Windows-specific.

## Verification

See [VERIFICATION.md](VERIFICATION.md).

- **Unit tests** cover the OpenSSH option mapping, proxy and tunnel command quoting, validation and lenient decoding.
- **Integration tests** use the disposable SSH, WebDAV and MinIO fixtures:
  - every SCP operation (connect probes, transfers, mkdir, rename, list, delete) runs inside a stand-in `sudo su -` shell that prints a login banner;
  - a failing shell is reported at login;
  - a custom SFTP server command works on a daemon without an SFTP subsystem;
  - SCP works through a real SSH tunnel and SFTP through a local proxy command;
  - host-key discovery through a tunnel records only the target's key;
  - IPv4/IPv6 selection is honored by libcurl;
  - WebDAV works through a real SOCKS5 proxy (`ssh -D`) and fails once that proxy stops.

  Real `sudo` and real authenticated proxies were not exercised.
