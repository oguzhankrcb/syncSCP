# Releasing syncSCP

`./scripts/package-release.sh` already produces an ad-hoc signed universal app and ZIPs in `dist/`. That is enough for your own Macs. Anything for other people needs the steps below; each needs a decision or an account of the maintainer's, so none of them runs automatically.

## 1. Developer ID signing and notarization

Without them macOS shows "cannot be opened because the developer cannot be verified" for downloaded copies.

1. Join the Apple Developer Program and create a **Developer ID Application** certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates).
2. Store notarization credentials once: `xcrun notarytool store-credentials syncscp-notary --apple-id YOU@example.com --team-id TEAMID` (it asks for an app-specific password).
3. Build and notarize:

```bash
./scripts/build-app.sh --universal
SYNCSCP_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" SYNCSCP_NOTARY_PROFILE=syncscp-notary ./scripts/notarize.sh
```

`./scripts/notarize.sh --dry-run` prints every step without signing anything. The hardened runtime needs no extra entitlements: syncSCP runs Apple's `/usr/bin/ssh` and itself as askpass.

Note: after the switch from ad-hoc to Developer ID signing, macOS asks once whether syncSCP may use its Keychain items (saved passwords).

## 2. GitHub release

The repository is private, so its releases are visible only to people with access. For a public download, make the repository (or a separate releases repository) public, then:

```bash
gh release create v0.23.0 dist/syncSCP-0.23.0-macOS.zip --title "syncSCP 0.23.0" --notes-file RELEASE_NOTES.md
```

## 3. Homebrew

`packaging/syncscp.rb` is a cask template (it also links `syncscp`). It needs a public, notarized ZIP: fill in `version` and `sha256`, then publish it in a tap such as `oguzhankrcb/homebrew-tap` (`brew install --cask oguzhankrcb/tap/syncscp`).

## 4. Automatic updates (later)

Sparkle would add in-app updates. It needs a public appcast URL, an EdDSA signing key kept by the maintainer, and notarized builds, so it waits for steps 1–3.
