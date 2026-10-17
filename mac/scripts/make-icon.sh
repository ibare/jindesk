#!/bin/sh
# 앱 아이콘을 다시 그려 Jindesk/Assets.xcassets/AppIcon.appiconset 에 크기별로 넣는다. mac/ 에서 돌린다.
set -eu
dir="Jindesk/Assets.xcassets/AppIcon.appiconset"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swift scripts/make-icon.swift "$tmp/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$tmp/icon-1024.png" --out "$dir/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$tmp/icon-1024.png" --out "$dir/icon_${s}x${s}@2x.png" >/dev/null
done
echo "아이콘을 넣었습니다: $dir"
