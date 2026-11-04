#!/bin/bash
# 安装到「应用程序」并建立快捷召唤入口
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${ROOT}/build/MemoNative.app"
# 优先安装到 /Applications；无写入权限时退回 ~/Applications（无需管理员）
if [ -w "/Applications" ] && touch "/Applications/.memo-write-probe" 2>/dev/null; then
  rm -f "/Applications/.memo-write-probe"
  APP_DST="/Applications/MemoNative.app"
else
  mkdir -p "${HOME}/Applications"
  APP_DST="${HOME}/Applications/MemoNative.app"
fi

if [ ! -d "${APP_SRC}" ]; then
  echo "找不到 ${APP_SRC}，请先运行 scripts/build.sh"
  exit 1
fi

echo "==> 停止正在运行的实例"
pkill -f MemoNative 2>/dev/null || true
sleep 1

echo "==> 复制到 /Applications"
rm -rf "${APP_DST}"
cp -R "${APP_SRC}" "${APP_DST}"

echo "==> 注册到 LaunchServices（通知与 URL Scheme 需要）"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"${LSREGISTER}" -f "${APP_DST}" || true

echo "==> 完成"
echo
echo "  应用：${APP_DST}"
echo "  召唤：⌥Space（任意 App 内）"
echo "  菜单栏图标单击：打开面板"
echo "  命令行：open memo://add?title=买牛奶&priority=high"
echo
echo "  首次运行请允许通知，否则提醒会走 osascript 降级通道。"
