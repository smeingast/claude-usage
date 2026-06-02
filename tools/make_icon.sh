#!/usr/bin/env bash
# Renders the app icon and produces Resources/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Rendering 1024px master…"
swiftc -O "$ROOT/tools/icongen/main.swift" -o "$TMP/icongen"
"$TMP/icongen" "$TMP/icon_1024.png"

echo "==> Building iconset…"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size      "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}.png"      >/dev/null
    sips -z $((size*2)) $((size*2)) "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> Packing .icns…"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "==> Wrote $ROOT/Resources/AppIcon.icns"
