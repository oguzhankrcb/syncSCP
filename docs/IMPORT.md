# Importing from Windows WinSCP (0.8.0)

**File ▸ Import from WinSCP…**, or **Tools ▸ Import Sites from WinSCP…** on the Login sheet, reads WinSCP's own storage:

- an exported `WinSCP.ini` (WinSCP ▸ Tools ▸ Export/Backup Configuration),
- a registry export: `reg export "HKCU\Software\Martin Prikryl\WinSCP 2" winscp.reg` (UTF-16, dword and wrapped hex values),
- WinSCP running under Wine, Whisky or CrossOver on this Mac. **Find on This Mac** checks each prefix's `user.reg` and the usual `WinSCP.ini` folders.

Nothing is written until **Import**. The preview lists every site with its protocol, user/host/port, shell, SFTP server, tunnel and proxy. It shows what will not carry over, the trusted host keys with their fingerprints, and entries that cannot be imported.

## What is imported

- **Sites and folders:** a `Folder/Name` site keeps its folder. Names are decoded with PuTTY's `%XX` escaping, including UTF-8 names. A name that already exists gets an `(imported)` suffix.
- **Settings:** every field read by upstream `TSessionData::DoLoad` that maps to [Advanced Site Settings](SETTINGS.md):
  - protocol and encryption, host (including `user@host`), port and user;
  - remote and local folder, note and color;
  - shell, return variable and listing options, SFTP server and version, path canonicalization, POSIX rename;
  - environment, directory caching, recycle bin;
  - FTP, S3 (region, URL style, requester pays, role ARN) and WebDAV options, TLS versions;
  - timeout, keepalives, IP version, proxy (type, host, port, DNS, local command), tunnel;
  - compression, cipher and key-exchange policies, rekey limits;
  - agent, keyboard-interactive, agent forwarding, GSSAPI, certificate;
  - SSH bug flags.
- **Paths:** inside a Wine/Whisky/CrossOver prefix, `C:\…` paths are resolved through the prefix's `dosdevices`. Local folders and keys are therefore found where WinSCP used them.
- **Keys:**
  - PuTTY `.ppk` keys without a passphrase (formats 2 and 3; RSA, Ed25519, ECDSA) are converted to OpenSSH format, after the file's MAC is verified;
  - converted keys go into `~/Library/Application Support/SyncSCP/keys` with owner-only access, and a file shared by several sites is converted once;
  - OpenSSH keys at resolvable paths are referenced in place.
- **Host keys:** keys trusted in WinSCP (`SshHostKeys`: Ed25519, RSA, ECDSA in PuTTY's format) are converted to OpenSSH `known_hosts` lines. A different key already trusted for the same host is never replaced; it is reported instead.
- **Backup:** `sites.json` and `known_hosts` are copied to `backups/before-import-…` before anything changes.

## What is not imported

- **Saved passwords (0.16.0):** WinSCP's `Password` (its reversible "simple" encoding, used when no master password is set) and `PasswordPlain` are decoded in memory. The decoded text must start with the site's user name + host name, as upstream requires, or it is rejected. Nothing is stored unless you tick **Save … saved passwords in my Keychain**; then each goes into the macOS Keychain under that site, never into `sites.json`. Values protected by a master password cannot be read and the site says so.
- Sites that already exist (same name, protocol, host, port and user) are marked and not selected, so importing again does not duplicate them; their passwords can still be saved.
- Proxy and tunnel passwords, S3 session tokens and the file-encryption key are never imported; each affected site says so.
- **Passphrase-protected PuTTY keys (0.21.0):** the preview asks for the passphrase. Format 2 (SHA-1 key derivation) and format 3 (Argon2) are decrypted and MAC-checked, and the converted OpenSSH key gets the same passphrase through `ssh-keygen -p` with the app's askpass, so neither the passphrase nor an unprotected copy is ever written to disk.

## `~/.ssh/config` (0.21.0)

Import ▸ **Import ~/.ssh/config** turns every concrete `Host` alias into a site in the "SSH config" folder. Blocks apply in file order and the first value of each keyword wins, so `Host *` defaults fill only what a host leaves unset; negated patterns are honored. Imported: HostName, User, Port, IdentityFile (if it exists), ProxyJump (first hop as the site's SSH tunnel), ProxyCommand (as a local proxy command), LocalForward (saved port forwards), ServerAliveInterval, ConnectTimeout, Compression and ForwardAgent. Match blocks, Include files, RemoteForward, DynamicForward, CertificateFile, HostKeyAlias and LocalCommand are not imported and the sites say so. Host keys are confirmed on first connection as usual.
- Workspaces and site shortcuts are not supported yet.
- `Default Settings` is skipped, as are DSA and Ed448 host keys.
- Passphrase-protected `.ppk` files are not converted: convert them with `puttygen key.ppk -O private-openssh -o key`, then choose the result in Advanced ▸ Authentication.
- Windows paths outside a Wine prefix cannot be used; the site keeps your home folder and asks you to copy the key.

Values this port cannot apply are imported as they are and badged as in [SETTINGS.md](SETTINGS.md), with these exceptions. A dummy-command keepalive becomes null packets, SFTP versions above 3 become 3, and FTP active mode stays passive; each one is noted. Telnet proxies, proxy authentication and tunnels on non-SSH protocols are imported but stop the connection with an explanation until changed.
