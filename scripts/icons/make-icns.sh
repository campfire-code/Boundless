#!/bin/bash
# 渲染图标并生成 Resources/AppIcon.icns（选定版本：B 无限之环）
set -euo pipefail
cd "$(dirname "$0")/../.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift scripts/icons/render.swift "$WORK" >/dev/null
SRC="$WORK/B-无限之环.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SRC" Resources/AppIcon-1024.png
echo "已生成 Resources/AppIcon.icns"
