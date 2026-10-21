#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
BUILD_MODE=release
BUILD_ARCHES=("$(uname -m)")
for argument in "$@"; do
    case "$argument" in
        --debug) BUILD_MODE=debug ;;
        --universal) BUILD_ARCHES=(arm64 x86_64) ;;
        *) echo "Usage: $0 [--debug] [--universal]" >&2; exit 2 ;;
    esac
done
# One architecture per build, merged with lipo: SwiftPM's multi-arch (Xcode) build system
# cannot build SwiftTerm's build-tool plugin.
BINARIES=()
for arch in "${BUILD_ARCHES[@]}"; do
    "$TASK_ROOT/scripts/swift.sh" build -c "$BUILD_MODE" --arch "$arch"
    BINARY_DIR="$("$TASK_ROOT/scripts/swift.sh" build -c "$BUILD_MODE" --arch "$arch" --show-bin-path)"
    BINARIES+=("$BINARY_DIR/SyncSCP")
done
APP_BUNDLE="$TASK_ROOT/dist/syncSCP.app"
# Start from an empty bundle so files removed from the project never linger in a release.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/SyncSCP"
cp "$TASK_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$TASK_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
# SwiftTerm (MIT): its license, and its resource bundle where Bundle lookups find it.
cp "$TASK_ROOT/.build/checkouts/SwiftTerm/LICENSE" "$APP_BUNDLE/Contents/Resources/SwiftTerm-LICENSE.txt"
cp -R "$BINARY_DIR/SwiftTerm_SwiftTerm.bundle" "$APP_BUNDLE/Contents/Resources/"
cp "$TASK_ROOT/LICENSE" "$TASK_ROOT/README.md" "$TASK_ROOT/README.tr.md" "$TASK_ROOT/NOTICE.md" "$TASK_ROOT/CONTRIBUTING.md" "$APP_BUNDLE/Contents/Resources/"
cp -R "$TASK_ROOT/docs" "$APP_BUNDLE/Contents/Resources/"
rm -rf "$APP_BUNDLE/Contents/Resources/docs/screenshots" # README images are not needed in the app
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/clang-cache"
xcrun swift "$TASK_ROOT/scripts/draw-icon.swift" "$TASK_ROOT/.build/AppIcon.iconset"
iconutil -c icns "$TASK_ROOT/.build/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
echo "Built: $APP_BUNDLE"
