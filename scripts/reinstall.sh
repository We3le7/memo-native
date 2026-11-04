#!/bin/bash
# 把最新构建（含图标）安装到 /Applications 并重启。
# 因为沙箱限制，需要你在自己的终端/访达里执行一次。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/MemoNative.app"
DST="/Applications/MemoNative.app"

if [ ! -d "${SRC}" ]; then
  echo "❌ 找不到 $SRC，请先运行 scripts/build.sh"
  exit 1
fi

echo "==> 校验源包图标"
if [ ! -f "${SRC}/Contents/Resources/AppIcon.icns" ]; then
  echo "❌ 源包缺少 AppIcon.icns"
  exit 1
fi
echo "    OK: $(du -h "${SRC}/Contents/Resources/AppIcon.icns" | cut -f1)"

echo "==> 退出正在运行的实例"
pkill -f MemoNative 2>/dev/null || true
sleep 1

echo "==> 替换 /Applications/MemoNative.app"
rm -rf "${DST}"
cp -R "${SRC}" "${DST}"

echo "==> 刷新图标缓存与 LaunchServices 注册"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"${LSREGISTER}" -f "${DST}" 2>/dev/null || true
# 清除该 bundle 的图标缓存（不影响其他 App）
touch "${DST}"

echo "==> 启动"
open "${DST}"
sleep 2

echo
echo "✅ 完成。当前运行："
pgrep -fl MemoNative | head -2
echo
echo "如果 Dock / 启动台仍显示旧图标，注销重登或执行："
echo "  sudo killall Dock"
