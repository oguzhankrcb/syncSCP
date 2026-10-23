#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Signs dist/syncSCP.app with a Developer ID (hardened runtime), notarizes it with Apple and
# staples the ticket, then writes dist/syncSCP-<version>-macOS.zip. See docs/RELEASING.md.
#
#   SYNCSCP_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   SYNCSCP_NOTARY_PROFILE=syncscp-notary ./scripts/notarize.sh [--dry-run]
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
run() { if [ "$DRY_RUN" = 1 ]; then printf '+'; printf ' %q' "$@"; echo; else "$@"; fi; }

IDENTITY="${SYNCSCP_SIGNING_IDENTITY:-}"
PROFILE="${SYNCSCP_NOTARY_PROFILE:-}"
if [ "$DRY_RUN" = 0 ] && { [ -z "$IDENTITY" ] || [ -z "$PROFILE" ]; }; then
    echo "Set SYNCSCP_SIGNING_IDENTITY and SYNCSCP_NOTARY_PROFILE (see docs/RELEASING.md), or use --dry-run." >&2
    exit 2
fi
IDENTITY="${IDENTITY:-Developer ID Application: (identity)}"; PROFILE="${PROFILE:-(profile)}"
APP="dist/syncSCP.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="dist/syncSCP-$VERSION-macOS.zip"
[ -d "$APP" ] || { echo "Build the app first: ./scripts/build-app.sh --universal" >&2; exit 2; }

# Work outside the checkout: folders synced by iCloud (a Desktop in iCloud Drive) put
# FinderInfo/provenance attributes back on the bundle, which codesign refuses.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/syncscp-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGED="$WORK/syncSCP.app"
run ditto --norsrc --noextattr --noqtn "$APP" "$STAGED"
run xattr -cr "$STAGED"
# Inner code first, the app last; the hardened runtime is required for notarization.
# SwiftTerm_SwiftTerm.bundle holds only resources (no Info.plist); the app's signature seals it.
run codesign --force --timestamp --options runtime --sign "$IDENTITY" "$STAGED/Contents/MacOS/syncscp-cli"
run codesign --force --timestamp --options runtime --sign "$IDENTITY" "$STAGED"
run codesign --verify --strict --deep --verbose=2 "$STAGED"
run ditto -c -k --keepParent "$STAGED" "$WORK/upload.zip"
run xcrun notarytool submit "$WORK/upload.zip" --keychain-profile "$PROFILE" --wait
run xcrun stapler staple "$STAGED"
run xcrun stapler validate "$STAGED"
run spctl --assess --type execute --verbose=2 "$STAGED"
# The stapled app goes into the final archive and replaces the unsigned one in dist/.
run rm -f "$ZIP"
run ditto -c -k --keepParent "$STAGED" "$ZIP"
run rm -rf "$APP"
run ditto "$STAGED" "$APP"
echo "Ready: $ZIP"
