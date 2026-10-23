<a id="top"></a>

<p align="center">
  <img src="docs/screenshots/header.png" alt="syncSCP" width="100%"/>
</p>

<p align="center">
  <strong>A native macOS file manager and SSH terminal for SFTP, SCP, FTP/FTPS, WebDAV and S3</strong>
</p>

<p align="center">
  <a href="#-features">Features</a> &bull;
  <a href="#-screenshots">Screenshots</a> &bull;
  <a href="#-installation">Installation</a> &bull;
  <a href="#-building">Building</a> &bull;
  <a href="#-testing">Testing</a> &bull;
  <a href="#-contributing">Contributing</a> &bull;
  <a href="#-license">License</a> &bull;
  <a href="README.tr.md">Türkçe</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.23.0-blue" alt="Version 0.23.0"/>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple" alt="Platform macOS 13+"/>
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-informational" alt="Universal binary"/>
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+"/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-green" alt="License GPL-3.0-or-later"/></a>
  <img src="https://img.shields.io/badge/status-development%20preview-orange" alt="Development preview"/>
</p>

<p align="center">
  Free and open-source, with the two-pane Commander workflow WinSCP users know, built natively for the Mac.<br/>
  Import your WinSCP sites, browse servers side by side, edit remote files in any app, and open an SSH terminal in the folder you are looking at.
</p>

---

<p align="center">
  <img src="docs/screenshots/commander.png" alt="syncSCP Commander window with local and remote panes, an SCP session through sudo su -, and the transfer queue" width="100%"/>
</p>
<p align="center"><em>Local and remote panes side by side: here an SCP session running through <code>sudo su -</code>, with a transfer in the queue.</em></p>

---

## 🚀 Overview

syncSCP is a native macOS app (SwiftUI and AppKit) that brings WinSCP's Commander workflow to the Mac: a local and a remote pane, a transfer queue, per-site Advanced settings and a built-in SSH terminal. It uses the OpenSSH and libcurl that ship with macOS, keeps its own strict host-key store, and never writes passwords to disk. No account, no subscription, no telemetry.

> **Status: 0.23.0 development preview.** syncSCP is an independent project, previously called "WinSCP for macOS". It is not affiliated with or endorsed by WinSCP and does not compile WinSCP's Windows code; it reimplements its workflows. Progress toward feature parity is tracked in the [parity matrix](docs/PARITY.md).

## ⚡ Coming from WinSCP

| Feature                              | syncSCP                                         | WinSCP                    |
| ------------------------------------ | ----------------------------------------------- | ------------------------- |
| Platform                             | macOS 13+, native (Apple Silicon and Intel)     | Windows                   |
| Two-pane Commander                   | Yes                                             | Yes                       |
| Session tabs (several servers)       | Yes                                             | Yes                       |
| SFTP, SCP, FTP/FTPS, WebDAV, S3      | Yes                                             | Yes                       |
| SSH terminal                         | Built-in window, or Terminal.app                | Via PuTTY                 |
| SCP through `sudo su -`              | Yes, one persistent shell                       | Yes                       |
| Advanced Site Settings               | Every page; most options applied ([details](docs/SETTINGS.md)) | Yes        |
| Import WinSCP sites, keys, host keys | Yes (`WinSCP.ini`, `reg export`, Wine/Whisky)   | —                         |
| Saved passwords                      | Opt-in, macOS Keychain, optional Touch ID       | Encrypted in its config   |
| External editors with upload on save | Yes                                             | Yes                       |
| Synchronization                      | One- and two-way, mirror, keep up to date       | One- and two-way          |
| Scripting / automation               | `syncscp` command-line tool                     | Yes (winscp.com)          |
| Transfer resume, parallel queue      | Yes (resume over SFTP)                          | Yes                       |
| License                              | GPL-3.0-or-later                                | GPL-3.0                   |

## ✨ Features

### 📁 Commander

- WinSCP's layout with a native finish: main toolbar, per-pane navigation and action bars
- **Session tabs**: connect to several servers at once, each tab in its site's color with its own remote and local folders; transfers keep running on their own connection while you work in another tab (⌘⇧] / ⌘⇧[ to switch, Duplicate Session ⌘⌥D)
- Path field with a parent-folder menu, back/forward history, a clickable path strip and a ".." row
- Local Name/Size/Type/Changed and remote Name/Size/Changed/Rights columns, with WinSCP's "0 B of 34.9 MB in 0 of 40" footer
- Drag and drop between the panes and from Finder, through the same queue and replacement prompts
- Commander keys (F2 rename, F4 edit, F5 copy to the other panel, F7 new folder, F8 delete) and a Go menu (⌘[ ⌘] ⌘↑ ⌘⇧H ⌃⇥)
- New ▸ Folder… and New ▸ File… in both panes; remembered folders per site
- Multiple selection, sorting, hidden files and filtering
- **Directory tree** beside each panel (⌥⌘T), following the current folder
- **Compare Directories** (⌥⌘C): newer, older, different and one-sided files are marked in both panels
- **Find Files** on the server (⌥⌘F): recursive, case-insensitive name masks such as `*.log; nginx*.conf`; a result opens its folder
- **Duplicate** (⇧F5) and **Move To** (⇧F6) on the server, never replacing anything; SCP copies with the server's own `cp`
- **Properties** for many items at once: rwx checkboxes or octal, optionally recursive, keeping folders openable
- **Quick Open** (⌘K): type to connect to a site, jump to a bookmark or run a command
- **Bookmarks** for local folders and per-site remote folders (⌥⌘B, the path menu, Go ▸ Bookmarks)
- **Quick Look** (⌘Y) for local and remote files; remote previews are fetched to a private temporary folder and removed afterwards

### 💻 SSH Terminal

- Terminal ▸ **Open Terminal** (⌘T) opens an interactive SSH login to the connected site in its own window
- Starts in the folder shown in the remote pane, through the site's SCP shell (for example `sudo su -`) when one is set
- Same Advanced settings, proxy, tunnel and strict `known_hosts` check as file sessions
- Passwords, key passphrases and sudo prompts are answered in the terminal and never stored
- **Open in Terminal.app** (⌘⇧T) runs the same login in macOS Terminal
- Terminal windows group as **tabs** (the tab bar's + opens another login); **Split Right** (⌘D) and **Split Down** (⌃⌘D) put more logins side by side; **Find** (⌘F, ⌘G)
- Open a terminal straight from the Login site list, without a file session
- **Snippets**: saved commands typed into the focused pane from Terminal ▸ Snippets
- **Port forwarding** (⇧⌘P): saved per site, `localhost:port → host:port` through the server, started and stopped from one list
- Choose any monospaced font, including Nerd Fonts for icon prompts; follows light and dark mode; Option types characters such as @ and |

### 🌐 Protocols

- **SFTP v3** over `/usr/bin/ssh`, with first-use fingerprint approval and strict verification afterwards
- **SCP** over shared OpenSSH channels, with a persistent shell for fast browsing ([requirements](docs/SCP.md))
- **FTP, explicit and implicit FTPS** through macOS libcurl: TLS on both channels, chain and hostname verification, optional private CA ([details](docs/FTP.md))
- **WebDAV over HTTP/HTTPS**: PROPFIND, collections, MOVE/DELETE, ETag-conditional replacement ([details](docs/WEBDAV.md))
- **S3 and S3-compatible storage**: SigV4 signed payloads, paginated listings, multipart uploads, conditional writes, server-side-copy rename ([details](docs/S3.md))

### 🔄 Transfers and Editing

- File and recursive folder upload/download through a queue with progress, cancellation and per-job results
- **Background, parallel transfers** on their own connections (2 at a time by default), so you keep browsing; a lost connection reconnects and retries automatically, **SFTP resumes partial files**, and a retried folder skips what it already finished
- Transfers go to temporary `.filepart` paths and are committed only when complete; replacing a file always asks first
- **Edit With** any application: every save is uploaded, but only if the server copy is still the version you opened
- Built-in UTF-8 editor for quick changes, with conflict checks
- **Synchronize** Local → Remote, Remote → Local or **both ways** (the newer file wins, undecidable ones are shown as conflicts), with newer-only, size-only and an opt-in mirror that deletes extras (local deletions go to the Trash); every item is rechecked before it is applied
- **Keep Remote Directory up to Date** (⌥⌘U): saved and new local files are uploaded as you work, creating remote folders as needed; editor scratch files are ignored and nothing is deleted

### 🧭 Sites and Settings

- WinSCP-style Login: sites grouped in folders, search, separate protocol and encryption choices, Save / Save As… and Manage
- WinSCP's **Advanced Site Settings**, page for page: SCP/Shell, SFTP server, timeouts, keepalives, IPv4/IPv6, SOCKS/HTTP/local proxies, SSH tunnels, TLS versions, cipher and key-exchange policy, rekey limits, authentication, S3 options, notes and colors. Options that cannot apply on macOS are shown disabled with a reason ([details](docs/SETTINGS.md))
- **Import from `~/.ssh/config`**: host names, users, ports, identity files, ProxyJump (as a tunnel), ProxyCommand, LocalForward and keepalives, with `Host *` defaults applied the way ssh does
- **PuTTY keys**, including passphrase-protected ones (format 2 and 3 with Argon2), convert to OpenSSH keys that keep their passphrase (Login ▸ Tools ▸ Convert PuTTY Key, or during import)
- **Import from WinSCP**: `WinSCP.ini`, `reg export` files, or WinSCP running under Wine, Whisky or CrossOver on this Mac. Sites keep their folders and settings, passphrase-free PuTTY keys become OpenSSH keys, trusted host keys come along, saved passwords can go into your Keychain if you choose, sites you already have are not duplicated, and your data is backed up first ([details](docs/IMPORT.md))

### 🔐 Security and Privacy

- Host keys live in the app's own `known_hosts`; a changed key fails, with no insecure bypass
- SSH config loading, forwarding and local commands are disabled (`-F /dev/null`)
- **Save password** is opt-in, per site, in your macOS Keychain on this Mac only; site files never contain passwords. Settings can require Touch ID or your Mac password before a saved password is used
- Unsaved passwords sit in Keychain only for the connection attempt; a saved one also logs the built-in terminal in
- Everything stays on your Mac: `~/Library/Application Support/SyncSCP`

### ⌨️ Automation

- **`syncscp` command-line tool**, in the style of `winscp.com`: `open`, `ls`, `get`, `put`, `rm`, `mv`, `cp`, `chmod`, `synchronize` and more, from a script file, the command line or an interactive prompt; same sites and host keys as the app, exit code 0 only on success. Help ▸ Install Command Line Tool links it into PATH ([guide](docs/SCRIPTING.md))

### 🌍 Languages

- English and **Turkish** interface; it follows macOS, or choose it in Settings ▸ Language. Messages from servers and the session log stay in English

## 📸 Screenshots

|                       Login                                   |                Advanced Site Settings                          |
| :-----------------------------------------------------------: | :------------------------------------------------------------: |
| ![Login with sites grouped in folders](docs/screenshots/login.png) | ![Advanced Site Settings, SCP/Shell page with sudo su -](docs/screenshots/advanced-settings.png) |
| _Sites in folders, protocol and encryption, explicit Save_    | _Every WinSCP page; unsupported options say why_               |

|                  SSH Terminal                                 |                    Import from WinSCP                          |
| :-----------------------------------------------------------: | :------------------------------------------------------------: |
| ![SSH terminal through sudo su -](docs/screenshots/terminal.png) | ![Import from WinSCP preview with sites, warnings and host keys](docs/screenshots/import.png) |
| _Opens in the remote folder, through the site's shell_        | _Sites, settings, PuTTY keys and host keys_                    |

<p align="center">
  <img src="docs/screenshots/editing.png" alt="Edited files uploaded on save from Visual Studio Code and BBEdit" width="80%"/>
</p>
<p align="center"><em>External editors in dark mode: every save uploads, only if the server copy is unchanged.</em></p>

<p align="center"><sub>Screenshots use sample data.</sub></p>

## 📥 Installation

**Homebrew:**

```bash
brew install --cask oguzhankrcb/tap/syncscp
```

This also links the `syncscp` command-line tool.

**Download:** get `syncSCP-<version>-macOS.zip` from the [latest release](https://github.com/oguzhankrcb/syncSCP/releases/latest), unzip it and move `syncSCP.app` to Applications. Releases are signed with a Developer ID and notarized by Apple, so they open normally.

You can also build from source (below).

### Requirements

- macOS 13 Ventura or later, on Apple Silicon or Intel
- For SFTP, SCP and the terminal: SSH access to your servers
- For S3: an access key and secret key

### Upgrading from "WinSCP for macOS"

On first launch syncSCP copies `~/Library/Application Support/WinSCPMac` (sites, `known_hosts`, converted keys, edits, backups) to `~/Library/Application Support/SyncSCP` and updates saved key paths. The old folder is left as a backup; delete it yourself when you are happy. Your default external editor is carried over too.

## 🔨 Building

Requires macOS 13+ and an Xcode toolchain with Swift 5.9 or later. No Homebrew libraries, Wine or Electron; the only downloaded package is SwiftTerm, pinned exactly.

```bash
git clone https://github.com/oguzhankrcb/syncSCP.git
cd syncSCP

# Unit tests, then the real local SFTP/SCP daemons
./scripts/swift.sh test
./scripts/test-ssh.sh

# Build and open the app
./scripts/build-app.sh
open dist/syncSCP.app
```

- `./scripts/build-app.sh --debug` makes a development build; `--universal` makes an Apple Silicon + Intel binary.
- `./scripts/package-release.sh` builds the universal app and writes verified, versioned app and source ZIPs to `dist/`.
- Developer ID signing, notarization, GitHub releases and the Homebrew cask are described in [docs/RELEASING.md](docs/RELEASING.md).
- You can also open `Package.swift` in Xcode and run the `SyncSCP` scheme.

## 🧪 Testing

`./scripts/swift.sh test` runs the codec, settings, import, synchronization and storage tests, plus SFTP tests against Apple's real `/usr/libexec/sftp-server`. Integration tests use disposable local folders, never your SSH account or a public server.

For the complete SFTP + SCP + FTP + FTPS + WebDAV + S3 + terminal suite, install the isolated **test-only** dependencies (Python 3.11+), start Docker for the MinIO S3 fixture, and run:

```bash
./scripts/setup-protocol-tests.sh
./scripts/test-ssh.sh --all
./scripts/test-ssh.sh --all -c release
```

- **SSH:** disposable keys and unprivileged daemons on `127.0.0.1`, including an SCP-only daemon so SCP can never fall back to SFTP, a fake `sudo su -` shell, and a real pseudo-terminal for the terminal tests. Your SSH configuration and Remote Login are untouched.
- **FTP/FTPS:** pyftpdlib servers with generated certificates: both FTPS modes, legacy listings, permission errors, cancellation, untrusted certificates, hostname mismatch and TLS downgrade.
- **WebDAV:** WsgiDAV/Cheroot over HTTP and HTTPS: conditional MOVE, authentication and read-only errors, redirects and partial status.
- **S3:** two localhost-only MinIO containers (HTTP and HTTPS) from a digest-pinned image: multipart, conditional writes, rename, abort cleanup and TLS trust. `SYNCSCP_SKIP_S3=1` skips only S3 where Docker is unavailable.

Results per release are in [docs/VERIFICATION.md](docs/VERIFICATION.md).

## 🛠 Tech Stack

| Layer             | Technology                                                          |
| ----------------- | ------------------------------------------------------------------- |
| UI                | SwiftUI and AppKit, native tables and menus                         |
| SSH, SFTP, SCP    | macOS OpenSSH (`/usr/bin/ssh`), own SFTP v3 codec                   |
| FTP, WebDAV, S3   | macOS libcurl through a small C bridge; CryptoKit for SigV4         |
| Terminal          | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0      |
| Credentials       | Keychain, only for the duration of a connection attempt             |
| Storage           | JSON site store and `known_hosts` in Application Support            |
| Build             | Swift Package Manager, universal binary via `lipo`                  |

## 🏗 Architecture

- **`SyncSCPCore`** holds everything protocol-related: site models and storage, a protocol-independent `RemoteSession`, serialized SFTP/SCP/FTP/WebDAV/S3 clients, the OpenSSH process transport, WinSCP import and the synchronization planner.
- **`SyncSCP`** is the app: the Commander window, login and settings sheets, host trust, Keychain-backed askpass, queue, editors and terminal windows. `CommanderModel` runs on the main actor; blocking I/O stays off it.
- **`CCurlTransport`** is a small original C bridge to the system libcurl.

```
Sources/
  CCurlTransport/        # C bridge to macOS libcurl
  SyncSCPCore/           # Protocols, sites, import, sync (no UI)
    SFTPClient.swift       SFTP v3 over OpenSSH
    SCPClient.swift        Legacy SCP + persistent shell
    FTPClient.swift        FTP / FTPS via libcurl
    WebDAVClient.swift     WebDAV over HTTP(S)
    S3Client.swift         S3 with SigV4
    SSHTerminal.swift      Interactive login for the terminal
    WinSCPImport.swift     WinSCP.ini / reg / Wine import
  SyncSCP/               # The macOS app
    CommanderView.swift    Two-pane Commander
    ConnectionSheet.swift  Login and site manager
    AdvancedSiteSettings.swift
    TerminalWindow.swift   SwiftTerm terminal windows
Tests/SyncSCPCoreTests/  # Unit and real-server integration tests
scripts/                 # Build, package and test fixtures
docs/                    # Architecture, parity, settings, verification
```

More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 🤝 Contributing

Contributions are welcome. Please open an issue first to discuss what you would like to change, then:

1. Fork the repository and create a branch: `git checkout -b feature/my-change`
2. Make the change with tests; run `./scripts/test-ssh.sh --all`
3. Open a pull request describing what you verified, and what you did not

See [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules: strict host and TLS verification, array-based process arguments, no-clobber transfers, and honest verification notes.

## 🐛 Troubleshooting

- **"Trust this SSH server?"** appears on the first connection. Compare the fingerprint with one from your server administrator before trusting it.
- **Host key verification failed:** the server's key changed since you trusted it. syncSCP never bypasses this; confirm the change, then remove the old line from `~/Library/Application Support/SyncSCP/known_hosts`.
- **SCP shell "did not start the command":** `sudo su -` must work without a password prompt for file sessions (`NOPASSWD` in sudoers). The terminal asks for the sudo password itself.
- **`sudo: unable to resolve host …`** in the terminal comes from the server: its own hostname is missing from `/etc/hosts`. sudo still works.
- **Icons show as `?` in the terminal:** pick a Nerd Font in Settings ▸ Terminal.
- **macOS blocks the app:** see [Installation](#-installation).

## 📄 License

syncSCP's original source code is licensed under the **GNU General Public License v3.0 or later**; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). There is no warranty.

## 🙏 Acknowledgments

- Inspired by [WinSCP](https://winscp.net/) by Martin Prikryl and contributors ([source](https://github.com/winscp/winscp)). syncSCP uses none of its code or icons; [upstream/REFERENCE.md](upstream/REFERENCE.md) records the revision studied.
- SSH by [OpenSSH](https://www.openssh.com/) and FTP/WebDAV/S3 transport by [libcurl](https://curl.se/libcurl/), both as shipped with macOS
- Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT)
- README layout inspired by [anySCP](https://github.com/macnev2013/anySCP)

---

<p align="center">
  If syncSCP is useful to you, consider giving it a ⭐ on GitHub.
</p>

<p align="center">
  <a href="#top">Back to top</a>
</p>
