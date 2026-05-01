#!/usr/bin/env bash
# Generate FoqosMac AppIcon variants by resizing Foqos's iOS marketing icon.
# Idempotent — overwrites existing PNGs. Run once after pulling fresh upstream
# Foqos icons; the resulting PNGs are committed to the FoqosMac asset catalog.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Foqos/Foqos/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png"
DST="$ROOT/FoqosMac/FoqosMac/Assets.xcassets/AppIcon.appiconset"

[ -f "$SRC" ] || { echo "Source icon missing: $SRC" >&2; exit 1; }
mkdir -p "$DST"

resize() {
  local size="$1" name="$2"
  if [ "$size" -eq 1024 ]; then
    cp "$SRC" "$DST/$name"
  else
    sips -z "$size" "$size" "$SRC" --out "$DST/$name" >/dev/null
  fi
  echo "  $name (${size}x${size})"
}

# macOS AppIcon set: 5 base sizes x 2 scales = 10 PNGs. Some pixel sizes are
# shared between slots (32 == 16@2x, 64 == 32@2x, etc.) but we keep separate
# files per slot for clarity.
resize 16   icon_16.png
resize 32   icon_16@2x.png
resize 32   icon_32.png
resize 64   icon_32@2x.png
resize 128  icon_128.png
resize 256  icon_128@2x.png
resize 256  icon_256.png
resize 512  icon_256@2x.png
resize 512  icon_512.png
resize 1024 icon_512@2x.png

echo "Done. ${DST#$ROOT/}/"
