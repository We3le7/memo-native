#!/bin/bash
# 把 MemoNative.app 打成拖拽式 DMG（内含「应用程序」替身，拖过去即安装）
#
# 用法：
#   ./scripts/make_dmg.sh                 构建并把 DMG 放到 build/
#   ./scripts/make_dmg.sh --skip-build    直接用现有 build/MemoNative.app
#   ./scripts/make_dmg.sh --no-background 不画自定义背景（Pillow 缺失时自动如此）
#   ./scripts/make_dmg.sh --out ~/Desktop/MemoNative.dmg
#
# 退出码：0 成功；非 0 失败（脚本会自动卸载并清理临时文件）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MemoNative"
APP_SRC="${ROOT}/build/${APP_NAME}.app"

SKIP_BUILD=0
WITH_BACKGROUND=1
OUT_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build)     SKIP_BUILD=1; shift ;;
    --no-background)  WITH_BACKGROUND=0; shift ;;
    --out)            OUT_PATH="${2:?--out 需要一个路径}"; shift 2 ;;
    -h|--help)        sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# ---------- 准备 ----------

if [ "${SKIP_BUILD}" -eq 0 ]; then
  echo "==> 构建"
  "${ROOT}/scripts/build.sh" >/dev/null
fi

if [ ! -d "${APP_SRC}" ]; then
  echo "找不到 ${APP_SRC}，先运行 scripts/build.sh" >&2
  exit 1
fi

VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${APP_SRC}/Contents/Info.plist" 2>/dev/null || echo "1.0")
VOL_NAME="${APP_NAME}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
if [ -z "${OUT_PATH}" ]; then
  OUT_PATH="${ROOT}/build/${DMG_NAME}"
fi

# ---------- 临时目录与清理 ----------

STAGE="$(mktemp -d)"
TMP_DMG="${STAGE}/rw.dmg"
MNT="/Volumes/${VOL_NAME}"

cleanup() {
  # 挂载点还在就卸载；不静音，失败时能看到原因
  if [ -d "${MNT}" ]; then
    /usr/bin/hdiutil detach "${MNT}" -force >/dev/null 2>&1 || true
  fi
  rm -rf "${STAGE}"
}
trap cleanup EXIT

# 上一轮如果异常退出，卷可能还挂着，先摘掉
if [ -d "${MNT}" ]; then
  echo "==> 清理残留挂载点 ${MNT}"
  /usr/bin/hdiutil detach "${MNT}" -force >/dev/null 2>&1 || true
  sleep 1
fi

# ---------- 背景图 ----------

BG_DIR="${STAGE}/.background"
CODEXIT=0
if [ "${WITH_BACKGROUND}" -eq 1 ]; then
  echo "==> 生成背景图"
  python3 "${ROOT}/scripts/make_dmg_background.py" "${BG_DIR}" || CODEXIT=$?
  # 退出码 2 表示没装 Pillow——降级处理，不算失败
  if [ "${CODEXIT}" -ne 0 ]; then
    echo "    背景图跳过，用纯白窗口"
    WITH_BACKGROUND=0
    rm -rf "${BG_DIR}"
  fi
fi

# ---------- 先摆好内容，再从文件夹建映像 ----------
#
# macOS 26 起 `hdiutil create -size … -format UDRW`（建空映像）
# 不再接受 -format，必须给 -srcfolder。所以顺序反过来：
# 先在临时目录里把成品摆好，再一次性建出来。
#
# 好处是容量由 hdiutil 自己算，不用估。

SRC_DIR="${STAGE}/src"
mkdir -p "${SRC_DIR}"

# ditto 比 cp -R 更适合 .app：完整保留资源分叉、扩展属性与符号链接
/usr/bin/ditto "${APP_SRC}" "${SRC_DIR}/${APP_NAME}.app"
ln -s /Applications "${SRC_DIR}/Applications"

if [ "${WITH_BACKGROUND}" -eq 1 ] && [ -d "${BG_DIR}" ]; then
  cp -R "${BG_DIR}" "${SRC_DIR}/.background"
fi

# 签名校验：打包前就查，免得生成一个改坏的、签名失效的 DMG
if /usr/bin/codesign --verify --strict "${SRC_DIR}/${APP_NAME}.app" 2>/dev/null; then
  echo "==> 签名校验通过"
else
  echo "==> ⚠️  签名校验失败，DMG 仍会生成，但首次打开可能被拦"
fi

echo "==> 创建临时磁盘映像"
/usr/bin/hdiutil create \
  -srcfolder "${SRC_DIR}" \
  -volname "${VOL_NAME}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "${TMP_DMG}" >/dev/null

echo "==> 挂载"
/usr/bin/hdiutil attach "${TMP_DMG}" -readwrite -noverify -noautoopen -mountpoint "${MNT}" >/dev/null

# ---------- Finder 窗口布局 ----------

# 坐标与 make_dmg_background.py 里的常量一致。
# 这一段失败不影响 DMG 可用性（只是窗口变成没排版的默认样子），
# 所以失败只提示、不中断。
echo "==> 设置窗口布局"
LAYOUT_SCRIPT="${STAGE}/layout.applescript"

APPLESCRIPT_LINES=(
  'tell application "Finder"'
  "  tell disk \"${VOL_NAME}\""
  '    open'
  '    set current view of container window to icon view'
  '    set toolbar visible of container window to false'
  '    set statusbar visible of container window to false'
  '    set the bounds of container window to {200, 120, 800, 548}'
  '    set vo to the icon view options of container window'
  '    set arrangement of vo to not arranged'
  '    set icon size of vo to 128'
  '    set text size of vo to 13'
)
if [ "${WITH_BACKGROUND}" -eq 1 ] && [ -d "${BG_DIR}" ]; then
  APPLESCRIPT_LINES+=('    set background picture of vo to file ".background:background.png"')
fi
APPLESCRIPT_LINES+=(
  "    set position of item \"${APP_NAME}.app\" of container window to {150, 185}"
  '    set position of item "Applications" of container window to {450, 185}'
  '    update without registering applications'
  '    delay 1'
  '    close'
  '  end tell'
  'end tell'
)

printf '%s\n' "${APPLESCRIPT_LINES[@]}" > "${LAYOUT_SCRIPT}"

if /usr/bin/osascript "${LAYOUT_SCRIPT}" 2>/dev/null; then
  echo "    布局完成"
else
  echo "    ⚠️  Finder 排版失败（可能是自动化权限未授予），改用默认布局"
fi

# 等 Finder 把 .DS_Store 写完，否则转成只读后布局会丢
sleep 1

# 读写挂载的副产物，卸载前清掉，成品里就不该有这些
rm -rf "${MNT}/.fseventsd" "${MNT}/.Trashes" 2>/dev/null || true

/usr/bin/hdiutil detach "${MNT}" >/dev/null

# ---------- 压缩成只读 ----------

echo "==> 压缩"
mkdir -p "$(dirname "${OUT_PATH}")"
rm -f "${OUT_PATH}"
/usr/bin/hdiutil convert "${TMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${OUT_PATH}" >/dev/null

SIZE=$(du -sh "${OUT_PATH}" | cut -f1)
echo
echo "==> 完成：${OUT_PATH}（${SIZE}）"
echo
echo "  分发说明：App 是 ad-hoc 签名，从网上下载后首次打开会被 Gatekeeper 拦。"
echo "  用户右键点「打开」即可，或执行："
echo "    xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app"
