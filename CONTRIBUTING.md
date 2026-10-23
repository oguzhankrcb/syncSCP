# Contributing

Interface texts are English keys translated in `Resources/tr.lproj/Localizable.strings`; run `python3 scripts/check-localization.py` after changing visible text, and add the Turkish line it lists. Texts that a component receives as `String` are shown through `L(_:)`.

Use macOS 13+ and a Swift 5.9+ Xcode toolchain. Start with `./scripts/swift.sh test`, then `./scripts/build-app.sh --debug`. Application dependencies are supplied by macOS, except SwiftTerm (MIT, pinned exactly in Package.swift) for the terminal window. The optional FTP/WebDAV test fixtures require Python 3.11+ and the pinned packages installed by `./scripts/setup-protocol-tests.sh`; the S3 fixture needs a running Docker daemon (pinned MinIO image, localhost only). Use `./scripts/test-ssh.sh --all` for the complete network suite; `SYNCSCP_SKIP_S3=1` skips only S3, explicitly, on hosts without Docker.

Keep protocol logic in SyncSCPCore, the libcurl C bridge in CCurlTransport, and UI/Keychain/AppKit work in SyncSCP. Preserve strict host and TLS verification, array-based process arguments, no-clobber defaults, protocol-appropriate commits, cancellation cleanup, and explicit destructive-operation confirmation. Keep remote SCP paths in separately quoted shell positional arguments. Preserve WebDAV ETag conditions, URL-origin checks and XML limits. Preserve S3 conditional writes, signed payload hashes, multipart abort on failure and verbatim key paths. Document server-dependent rename semantics instead of claiming guarantees absent from the protocol. Never add real credentials, host inventory, or private keys to fixtures or logs.

Protocol changes need meaningful integration coverage. Use disposable server fixtures; tests must not mutate a developer's real server or SSH configuration. Document what each fixture proves and what it does not. Update docs/PARITY.md when adding a capability or changing its limitations.

Before importing upstream source or artwork, inspect its per-file license and retain the required notices. Describe implementation and verification honestly: the UI's presence is not evidence of wire-protocol support or full WinSCP compatibility.
