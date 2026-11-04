#!/bin/bash
# 构建「本机备忘录」原生 App：输出 build/MemoNative.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos13.0"
BUILD="${ROOT}/build"
APP="${BUILD}/MemoNative.app"
CACHE="${BUILD}/modulecache"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${CACHE}"

echo "==> 编译 Swift 源码"
xcrun swiftc \
  -module-cache-path "${CACHE}" \
  -sdk "${SDK}" \
  -target "${TARGET}" \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -framework UserNotifications \
  -framework ServiceManagement \
  "${ROOT}"/Sources/MemoNative/*.swift \
  -o "${APP}/Contents/MacOS/MemoNative"

echo "==> 写入 Info.plist"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

echo "==> 生成图标"
if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
  cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

echo "==> 临时签名（本机运行必需）"
codesign --force --deep --sign - "${APP}" 2>&1 | tail -2

echo "==> 完成：${APP}"
echo "    启动：open \"${APP}\""
