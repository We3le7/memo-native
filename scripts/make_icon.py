#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「本机备忘录」App 图标（.icns）。

设计：macOS 圆角方形底（超椭圆）+ 白色便签卡 + 四条带优先级色点的横线，
与 App 内列表的四级优先级（🔴🟠🟡🔵）一一对应。

所有形状在 4 倍尺寸下绘制，再 LANCZOS 缩小，得到干净的抗锯齿边缘。
"""
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources"
SRC = OUT / "icon-src"
SS = 4                 # 超采样倍数
SIZE = 1024            # 输出尺寸
BIG = SIZE * SS

# 配色
BG_TOP = (0x4B, 0x7C, 0xFF)
BG_BOTTOM = (0x2A, 0x3F, 0xC4)
CARD = (0xFF, 0xFF, 0xFF)
LINE = (0xC7, 0xD0, 0xE0)
# 前三级保留红/橙/黄；最低优先级用中性灰，避免与蓝色底撞色
PRIORITY = [(0xE5, 0x48, 0x4D), (0xF0, 0x81, 0x0F), (0xD9, 0xA8, 0x00), (0x9A, 0xA3, 0xB2)]


def superellipse_mask(size: int, inset: int, n: float = 5.0) -> Image.Image:
    """macOS 风格的连续圆角方形（超椭圆），返回 L 模式遮罩。"""
    half = (size - 2 * inset) / 2
    center = size / 2
    ys, xs = np.mgrid[0:size, 0:size]
    dx = np.abs((xs - center) / half)
    dy = np.abs((ys - center) / half)
    inside = (dx ** n + dy ** n) <= 1.0
    mask = (inside * 255).astype(np.uint8)
    img = Image.fromarray(mask, mode="L")
    # 轻微模糊让边缘更接近苹果的连续曲率
    return img.filter(ImageFilter.GaussianBlur(radius=SS * 0.9))


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    ramp = np.linspace(0, 1, size)[:, None]
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for i in range(3):
        arr[..., i] = (top[i] + (bottom[i] - top[i]) * ramp).astype(np.uint8)
    arr[..., 3] = 255
    return Image.fromarray(arr, mode="RGBA")


def build_master() -> Image.Image:
    canvas = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))

    # 1) 圆角底：外扩阴影 + 主体渐变
    body_inset = int(BIG * 0.095)          # 824/1024 附近的视觉重量
    mask = superellipse_mask(BIG, body_inset)

    shadow = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    shadow_mask = superellipse_mask(BIG, body_inset).point(lambda v: int(v * 0.55))
    shadow_layer = Image.new("RGBA", (BIG, BIG), (0x0B, 0x18, 0x40, 255))
    shadow.paste(shadow_layer, (0, 0), shadow_mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=BIG * 0.012))
    canvas.alpha_composite(shadow, (0, int(BIG * 0.012)))

    grad = vertical_gradient(BIG, BG_TOP, BG_BOTTOM)
    canvas.paste(grad, (0, 0), mask)

    # 顶部高光（苹果图标的柔和层次）
    gloss = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    ImageDraw.Draw(gloss).ellipse(
        [-BIG * 0.25, -BIG * 0.72, BIG * 1.25, BIG * 0.42],
        fill=(255, 255, 255, 46),
    )
    gloss = gloss.filter(ImageFilter.GaussianBlur(radius=BIG * 0.05))
    gloss.putalpha(Image.composite(gloss.getchannel("A"), Image.new("L", (BIG, BIG), 0), mask))
    canvas.alpha_composite(gloss)

    draw = ImageDraw.Draw(canvas, "RGBA")

    # 2) 白色便签卡（略收窄，给两侧留出呼吸感）
    card_l, card_t = BIG * 0.268, BIG * 0.215
    card_r, card_b = BIG * 0.732, BIG * 0.792
    radius = BIG * 0.058
    # 卡片投影
    card_shadow = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    ImageDraw.Draw(card_shadow).rounded_rectangle(
        [card_l, card_t + BIG * 0.016, card_r, card_b + BIG * 0.016],
        radius=radius, fill=(0x0B, 0x18, 0x40, 130),
    )
    card_shadow = card_shadow.filter(ImageFilter.GaussianBlur(radius=BIG * 0.018))
    canvas.alpha_composite(card_shadow)
    draw.rounded_rectangle([card_l, card_t, card_r, card_b], radius=radius, fill=CARD)

    # 3) 四条优先级行：色点 + 横线
    # 三行 + 一条较短的收尾行：小尺寸下更容易分辨
    rows_y = [BIG * 0.330, BIG * 0.470, BIG * 0.610]
    dot_r = BIG * 0.052                      # 明显放大，16px 下仍占满 1 像素
    dot_x = card_l + BIG * 0.090
    line_x0 = dot_x + BIG * 0.090
    line_h = BIG * 0.038
    line_widths = [0.212, 0.170, 0.212]

    for i, y in enumerate(rows_y):
        draw.ellipse(
            [dot_x - dot_r, y - dot_r, dot_x + dot_r, y + dot_r],
            fill=PRIORITY[i],
        )
        w = BIG * line_widths[i]
        draw.rounded_rectangle(
            [line_x0, y - line_h / 2, line_x0 + w, y + line_h / 2],
            radius=line_h / 2,
            fill=LINE + (255,),
        )

    # 底部收尾：一条淡色短线，暗示“还有更多”，同时平衡构图
    tail_y = BIG * 0.722
    draw.ellipse(
        [dot_x - dot_r, tail_y - dot_r, dot_x + dot_r, tail_y + dot_r],
        fill=PRIORITY[3],
    )
    draw.rounded_rectangle(
        [line_x0, tail_y - line_h / 2, line_x0 + BIG * 0.130, tail_y + line_h / 2],
        radius=line_h / 2,
        fill=(0xDD, 0xE3, 0xEE, 255),
    )

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def write_iconset(master: Image.Image) -> Path:
    iconset = SRC / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

    specs = [
        (16, 1), (16, 2), (32, 1), (32, 2),
        (128, 1), (128, 2), (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]
    for base, scale in specs:
        px = base * scale
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(iconset / name)
    return iconset


def main() -> None:
    SRC.mkdir(parents=True, exist_ok=True)
    master = build_master()
    master.save(SRC / "AppIcon-1024.png")
    iconset = write_iconset(master)

    icns = OUT / "AppIcon.icns"
    result = subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print("iconutil 失败:", result.stderr)
        sys.exit(1)
    print(f"已生成 {icns}  ({icns.stat().st_size // 1024} KB)")
    print(f"预览图 {SRC / 'AppIcon-1024.png'}")


if __name__ == "__main__":
    main()
