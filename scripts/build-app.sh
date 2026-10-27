#!/bin/bash
# 构建通用二进制（Apple 芯片 + Intel）并打包签名为 build/Boundless.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/Boundless"
APP="build/Boundless.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Boundless"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# 优先用固定证书签名：系统权限按签名识别，固定证书重新编译后不必重新授权；没有证书时退回临时签名
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

rm -f build/Boundless.zip
ditto -c -k --keepParent "$APP" build/Boundless.zip
echo "已生成 $APP 和 build/Boundless.zip（签名：${IDENTITY:-临时签名}）"
