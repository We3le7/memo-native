#!/usr/bin/env python3
"""生成 DMG 安装窗口的背景图。

为什么单独生成而不是塞一张图进仓库：
背景要和窗口尺寸严格对齐，图标坐标写在 make_dmg.sh 里，
图一旦和坐标脱节，DMG 里那个箭头就会指歪。
由脚本按同一组常量画出来，两边就不会各说各话。

设计原则和 App 一致：浅色中性底、一根细箭头、一句提示，
不加阴影、不加边框。

输出 background.png(1x) + background@2x.png(2x)。
Finder 在 Retina 上会自动挑 @2x 那张。

用法：
    python3 scripts/make_dmg_background.py <输出目录>
"""

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    # 没装 Pillow 不算失败：make_dmg.sh 会退回无背景的纯白窗口。
    print("SKIP: 未安装 Pillow，跳过背景图")
    sys.exit(2)

# 和 make_dmg.sh 里 Finder 布局用同一组坐标（单位：点）
WIDTH, HEIGHT = 600, 400
APP_ICON_X = 150
FOLDER_ICON_X = 450
ICON_Y = 185          # 图标中心（Finder 的 position 是图标左上角附近，这里留出视觉居中）
ARROW_Y = ICON_Y + 10  # 箭头略低于图标中心，视觉上对准图标主体

# 配色：浅色中性，和 App 的浅色主题同一套灰度
BG_TOP = (250, 250, 249)
BG_BOTTOM = (242, 242, 240)
ARROW = (196, 196, 192)
HINT = (138, 138, 133)
TITLE = (60, 60, 58)

# 中文字体：按可用性依次尝试。PingFang 在部分系统上被移进 AssetsV2，
# 路径带哈希，不能写死，所以列了一串候选。
FONT_CANDIDATES = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def draw_arrow(draw: ImageDraw.ImageDraw, scale: int) -> None:
    """在两个图标之间画一根细箭头。

    不用 emoji 或素材图：一条线加一个折角足够，
    而且任意缩放下都干净。
    """
    x1 = (APP_ICON_X + 62) * scale
    x2 = (FOLDER_ICON_X - 62) * scale
    y = ARROW_Y * scale
    head = 7 * scale
    width = max(1, round(1.5 * scale))

    draw.line([(x1, y), (x2, y)], fill=ARROW, width=width)
    # 箭头头部：两条斜线
    draw.line([(x2 - head, y - head), (x2, y)], fill=ARROW, width=width)
    draw.line([(x2 - head, y + head), (x2, y)], fill=ARROW, width=width)


def render(scale: int) -> Image.Image:
    w, h = WIDTH * scale, HEIGHT * scale
    img = Image.new("RGB", (w, h), BG_TOP)
    draw = ImageDraw.Draw(img)

    # 极轻的竖向渐变，避免大面积纯色显得平
    for i in range(h):
        t = i / max(1, h - 1)
        r = round(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = round(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = round(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        draw.line([(0, i), (w, i)], fill=(r, g, b))

    draw_arrow(draw, scale)

    # 底部提示：怎么装
    hint_font = load_font(13 * scale)
    hint = "拖入「应用程序」文件夹即可安装"
    tw = draw.textlength(hint, font=hint_font)
    draw.text(((w - tw) / 2, 296 * scale), hint, font=hint_font, fill=HINT)

    # 顶部留一句平台说明，代替窗口标题栏里看不到的信息
    title_font = load_font(12 * scale)
    title = "MemoNative · macOS 13+ (Apple Silicon)"
    tw = draw.textlength(title, font=title_font)
    draw.text(((w - tw) / 2, 44 * scale), title, font=title_font, fill=TITLE)

    return img


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    out_dir.mkdir(parents=True, exist_ok=True)

    render(1).save(out_dir / "background.png")
    render(2).save(out_dir / "background@2x.png")
    print(f"背景图已生成：{out_dir}/background.png（含 @2x）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
