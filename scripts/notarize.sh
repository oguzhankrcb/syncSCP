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

# Inner code first, the app last; the hardened runtime is required for notarization.
run codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/syncscp-cli"
run codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
run codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
run codesign --verify --strict --deep --verbose=2 "$APP"
run ditto -c -k --keepParent "$APP" "$ZIP"
run xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl --assess --type execute --verbose=2 "$APP"
# The stapled app goes into the final archive.
run rm -f "$ZIP"
run ditto -c -k --keepParent "$APP" "$ZIP"
echo "Ready: $ZIP"
