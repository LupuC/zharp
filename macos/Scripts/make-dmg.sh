#!/usr/bin/env bash
# Packages dist/Zharp.app into a compressed disk image for distribution:
#   dist/Zharp-<version>.dmg
#
# The image carries the app plus an /Applications symlink, so the window that
# opens on mount is the familiar drag-to-install layout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
APP="$ROOT/dist/Zharp.app"
DMG="$ROOT/dist/Zharp-$VERSION.dmg"
STAGE="$ROOT/dist/.dmg-stage"

[ -d "$APP" ] || { echo "missing $APP - run Scripts/make-app.sh first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Zharp.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Building $DMG"
hdiutil create \
  -volname "Zharp $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG" >/dev/null

rm -rf "$STAGE"

# A signed image is what lets Gatekeeper verify the download without the
# "damaged" warning; unsigned falls back to ad-hoc, which is fine locally.
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$MACOS_SIGN_IDENTITY" --timestamp "$DMG"
  echo "==> Signed with $MACOS_SIGN_IDENTITY"
fi

shasum -a 256 "$DMG" | sed "s|$ROOT/dist/||" > "$DMG.sha256"
echo "==> Done: $DMG"
echo "    $(cat "$DMG.sha256")"
