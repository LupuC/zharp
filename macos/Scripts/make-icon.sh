#!/usr/bin/env bash
# Builds Packaging/AppIcon.icns from the shared brand package - the same master
# the Windows build renders its .ico from.
#
# The source art is full-bleed, as Windows icons are. IconGen insets it onto a
# transparent canvas following Apple's icon grid, so the Dock renders it at the
# same visual size as every other app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Assets/brand/icons/icon-1024.png"
OUT="$ROOT/Packaging/AppIcon.iconset"
TOOL="$ROOT/.build/icongen"

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

mkdir -p "$ROOT/.build"
if [ ! -x "$TOOL" ] || [ "$ROOT/Scripts/IconGen.swift" -nt "$TOOL" ]; then
  swiftc -O "$ROOT/Scripts/IconGen.swift" -o "$TOOL"
fi

rm -rf "$OUT"
"$TOOL" "$SRC" "$OUT"
iconutil -c icns "$OUT" -o "$ROOT/Packaging/AppIcon.icns"
rm -rf "$OUT"
echo "==> Packaging/AppIcon.icns"
