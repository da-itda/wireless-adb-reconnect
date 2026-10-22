#!/bin/bash
# 사용자 심볼(assets/symbol-*.png)로 모든 아이콘을 다시 만든다. 사용: ./assets/make_icons.sh
#   앱 아이콘(녹색 심볼 + 흰 둥근 사각형): icon.png, AppIcon.icns(Mac), app.ico(Windows), docs/images/icon.png
#   Mac 메뉴 막대: status-body.png / status-waves.png — 모양 마스크. 앱이 몸체는 메뉴 막대 글자색, 전파는 상태색으로 칠한다
#   Windows 트레이: tray-{ok,fail}-{light,dark}.ico — 회색=연결됨, 빨강=끊김. light/dark는 작업 표시줄 밝기
#   (몸체가 검정이라 어두운 메뉴 막대·작업 표시줄에서는 흰색으로 바꿔야 보인다)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/assets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GRAY_LIGHT=494949   # 밝은 배경의 회색 (사용자 시안)
GRAY_DARK=A0A0A0    # 어두운 배경의 회색
RED=FF383C

# 앱 아이콘
swift "$A/compose_icon.swift" "$A/symbol-green.png" "$A/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$A/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$A/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$A/AppIcon.icns"
swift "$A/make_ico.swift" "$A/icon.png" "$A/app.ico"
sips -z 256 256 "$A/icon.png" --out "$ROOT/docs/images/icon.png" >/dev/null

# Mac 메뉴 막대 마스크 (18pt의 4배)
swift "$A/tint_symbol.swift" "$A/symbol-gray.png" "$A/status-body.png" FFFFFF none 72
swift "$A/tint_symbol.swift" "$A/symbol-gray.png" "$A/status-waves.png" none FFFFFF 72

# Windows 트레이
for v in "ok-light 000000 $GRAY_LIGHT" "ok-dark FFFFFF $GRAY_DARK" "fail-light 000000 $RED" "fail-dark FFFFFF $RED"; do
    set -- $v
    swift "$A/tint_symbol.swift" "$A/symbol-gray.png" "$TMP/tray-$1.png" "$2" "$3"
    swift "$A/make_ico.swift" "$TMP/tray-$1.png" "$A/tray-$1.ico"
done

cp "$A/app.ico" "$A"/tray-*.ico "$ROOT/windows/WirelessAdbReconnect/"
echo "아이콘 생성 완료"
