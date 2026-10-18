#!/bin/sh
# 앱 아이콘 그림(1024 정사각형, 투명 없음)을 Jindesk/Assets.xcassets/AppIcon.appiconset 에 크기별로 넣는다.
# 폰 앱(ios/)에는 1024 하나를 넣는다. 둥근 모서리는 시스템이 씌운다. mac/ 에서 돌린다.
# 사용: scripts/make-icon.sh <그림.png>
set -eu
src="${1:?사용: scripts/make-icon.sh <1024 정사각형 PNG>}"
w="$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')"
h="$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')"
alpha="$(sips -g hasAlpha "$src" | awk '/hasAlpha/ {print $2}')"
[ "$w" = 1024 ] && [ "$h" = 1024 ] || { echo "1024×1024 가 아닙니다: ${w}×${h}" >&2; exit 1; }
[ "$alpha" = no ] || { echo "투명 층이 있습니다. 폰 아이콘은 투명을 받지 않습니다" >&2; exit 1; }
dir="Jindesk/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 128 256 512; do
  sips -s format png -z "$s" "$s" "$src" --out "$dir/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -s format png -z "$d" "$d" "$src" --out "$dir/icon_${s}x${s}@2x.png" >/dev/null
done
sips -s format png "$src" --out ../ios/JindeskMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png >/dev/null
echo "아이콘을 넣었습니다: $dir, ../ios/JindeskMobile/Assets.xcassets/AppIcon.appiconset"
