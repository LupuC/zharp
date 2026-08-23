#!/usr/bin/env bash
# Assembles dist/Zharp.app from a SwiftPM build. The result is a self-contained
# bundle you can drag into /Applications - the macOS counterpart of the Windows
# build's Inno Setup step.
#
#   make-app.sh [debug|release] [--arch <arch>]... 
#
# With no --arch it builds for this machine. Passing --arch cross-compiles;
# repeat it for a universal binary:
#   ./Scripts/make-app.sh release --arch x86_64              # Intel, what ships
#   ./Scripts/make-app.sh release --arch arm64 --arch x86_64 # universal
#
# --arch needs SwiftPM's multi-arch path, which requires a full Xcode install
# (the Command Line Tools alone do not ship XCBuild). CI runners have Xcode;
# a CLT-only machine should build natively.
set -euo pipefail

CONFIG="release"
ARCH_FLAGS=()
ARCH_NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    debug|release) CONFIG="$1"; shift ;;
    --arch)
      [ -n "${2:-}" ] || { echo "--arch needs a value" >&2; exit 2; }
      ARCH_FLAGS+=(--arch "$2"); ARCH_NAMES+=("$2"); shift 2 ;;
    *) echo "usage: make-app.sh [debug|release] [--arch <arch>]..." >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
APP="$ROOT/dist/Zharp.app"

# Collected once so the build and the bin-path query stay in step. Appending
# conditionally keeps this working under `set -u` with bash 3.2, where
# expanding an empty array is an error.
BUILD_ARGS=(-c "$CONFIG" --package-path "$ROOT")
if [ ${#ARCH_FLAGS[@]} -gt 0 ]; then
  BUILD_ARGS+=("${ARCH_FLAGS[@]}")
  echo "==> Building Zharp $VERSION ($CONFIG, ${ARCH_NAMES[*]})"
else
  echo "==> Building Zharp $VERSION ($CONFIG, $(uname -m))"
fi

swift build "${BUILD_ARGS[@]}" --product Zharp

# Ask SwiftPM where it put the binary rather than guessing: the output path
# differs between a native build (.build/<config>), a single --arch build
# (.build/<triple>/<config>) and a universal one (.build/apple/Products/<Config>).
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

[ -f "$BUILD_DIR/Zharp" ] || {
  echo "build produced no binary at $BUILD_DIR/Zharp" >&2
  exit 1
}

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Zharp" "$APP/Contents/MacOS/Zharp"

# SwiftPM stages target resources in a .bundle beside the binary. Copy their
# CONTENTS into Contents/Resources rather than the directory itself: that is the
# conventional .app layout, and codesign --deep rejects a nested .bundle that
# has no Info.plist of its own, which would block Developer ID signing.
if [ -d "$BUILD_DIR/Zharp_ZharpApp.bundle" ]; then
  find "$BUILD_DIR/Zharp_ZharpApp.bundle" -type f -exec cp {} "$APP/Contents/Resources/" \;
fi

sed "s/__VERSION__/$VERSION/g" "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"

# The icon is generated from the shared logo set rather than committed, so
# build it on demand - this script is called directly by CI.
if [ ! -f "$ROOT/Packaging/AppIcon.icns" ]; then
  "$ROOT/Scripts/make-icon.sh"
fi
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# A Developer ID identity (MACOS_SIGN_IDENTITY) produces a distributable
# bundle; without one an ad-hoc signature is enough for local runs and stops
# Gatekeeper complaining about a missing signature outright.
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp \
    --sign "$MACOS_SIGN_IDENTITY" "$APP"
  echo "==> Signed with $MACOS_SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "==> Ad-hoc signed" \
    || echo "==> codesign unavailable, bundle left unsigned"
fi

echo "==> Done: $APP  ($(lipo -archs "$APP/Contents/MacOS/Zharp"))"
