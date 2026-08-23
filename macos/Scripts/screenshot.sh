#!/usr/bin/env bash
# Captures the running Zharp window to the given path (largest on-screen window).
set -euo pipefail
OUT="${1:?usage: screenshot.sh <out.png>}"
ID="$(/tmp/winid)"
[ "$ID" = "0" ] && { echo "Zharp window not found"; exit 1; }
screencapture -x -o -l"$ID" "$OUT"
echo "$OUT"
