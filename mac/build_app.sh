#!/bin/bash
# "Wireless ADB Reconnect.app"(메뉴 막대 앱)을 dist/ 에 만든다. 사용: ./mac/build_app.sh
# 서명: Developer ID가 있으면 그것으로(알림·권한이 다시 빌드해도 유지), 없으면 ad-hoc.
#       다른 인증서를 쓰려면 SIGN_ID="..." ./mac/build_app.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Wireless ADB Reconnect"
APP="$ROOT/dist/$NAME.app"
BUNDLE_ID="io.github.da-itda.wireless-adb-reconnect"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal (Apple silicon + Intel)
TMP="$(mktemp -d)"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos13 \
        "$ROOT/mac/main.swift" "$ROOT/mac/Setup.swift" -o "$TMP/$arch"
done
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/WirelessADBReconnect"
rm -rf "$TMP"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ADB Reconnect</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.1.1</string>
    <key>CFBundleShortVersionString</key><string>1.1.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WirelessADBReconnect</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
    <!-- 앱이 띄운 adb 서버가 같은 Wi-Fi의 휴대폰에 붙으려면 로컬 네트워크 권한이 필요 -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Needed to find your phone on Wi-Fi and reconnect wireless debugging.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_adb-tls-connect._tcp</string>
        <string>_adb-tls-pairing._tcp</string>
        <string>_adb._tcp</string>
    </array>
</dict>
</plist>
EOF

# 권한 안내 문구: 한국어 OS는 한국어, 그 밖에는 영어 (앱 화면과 같은 규칙)
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ko.lproj"
echo '"NSLocalNetworkUsageDescription" = "Needed to find your phone on Wi-Fi and reconnect wireless debugging.";' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
echo '"NSLocalNetworkUsageDescription" = "무선 디버깅 중인 휴대폰을 찾고 다시 연결하기 위해 로컬 네트워크 접근이 필요합니다.";' > "$APP/Contents/Resources/ko.lproj/InfoPlist.strings"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP" 2>/dev/null \
        || codesign --force --options runtime --sign "$SIGN_ID" "$APP"
    echo "서명: $SIGN_ID"
else
    codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
    echo "서명: ad-hoc (Developer ID 없음)"
fi
touch "$APP"
echo "빌드 완료: $APP"

# 공증(선택): NOTARY_PROFILE=<notarytool 키체인 프로필> ./mac/build_app.sh
# 배포용: 받은 사람이 Gatekeeper 경고 없이 열 수 있다 (※ 공증해도 macOS 기본 알림 문제는 그대로 — TROUBLESHOOTING)
if [ -n "$NOTARY_PROFILE" ]; then
    ZIP="$ROOT/dist/WirelessADBReconnect-$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)-mac.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
    spctl -a -vv "$APP" 2>&1 | head -2
    echo "공증 완료: $APP (배포용 zip: $ZIP)"
fi
