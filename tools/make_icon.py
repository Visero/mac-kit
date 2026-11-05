#!/usr/bin/env python3
"""生成 mac-kit 图标（Liquid Glass 风格，亮/暗两套）

层次：投影 → 底色渐变 → 色晕 → 顶部镜面 → 边缘亮环 → 底部厚度 → 字形
"""

import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024
SS = 4
CANVAS = S * SS
INSET = 100 * SS
N = 5.0
FONT = "/System/Library/Fonts/SFNS.ttf"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "..", "build", "icons")


def squircle(size, inset, n=N, blur=0.0):
    half = (size - 2 * inset) / 2
    c = size / 2
    y, x = np.mgrid[0:size, 0:size]
    inside = (np.abs((x - c) / half) ** n + np.abs((y - c) / half) ** n) <= 1.0
    img = Image.fromarray((inside * 255).astype(np.uint8))
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur))
    return img


def vgrad(size, top, bottom):
    """top/bottom 为 (r,g,b,a)"""
    t = np.linspace(0, 1, size)[:, None, None]
    top = np.array(top, dtype=np.float64).reshape(1, 1, 4)
    bottom = np.array(bottom, dtype=np.float64).reshape(1, 1, 4)
    arr = np.repeat(top * (1 - t) + bottom * t, size, axis=1)
    return Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")


def rgrad(size, center, radius, color, strength):
    y, x = np.mgrid[0:size, 0:size]
    d = np.sqrt((x - center[0]) ** 2 + (y - center[1]) ** 2) / radius
    a = np.clip(1 - d, 0, 1) ** 2 * strength
    arr = np.zeros((size, size, 4), dtype=np.float64)
    arr[..., 0], arr[..., 1], arr[..., 2] = color
    arr[..., 3] = a * 255
    return Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")


def clip_to(layer, mask):
    return Image.composite(layer, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask)


def glyph(size, char, color, ratio=0.46, shadow=None, blur=0, offset=(0, 0)):
    font = ImageFont.truetype(FONT, int(size * ratio))
    try:
        font.set_variation_by_axes([700])
    except Exception:
        pass
    bbox = font.getbbox(char)
    pos = ((size - (bbox[2] - bbox[0])) / 2 - bbox[0], (size - (bbox[3] - bbox[1])) / 2 - bbox[1])

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if shadow:
        sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        ImageDraw.Draw(sh).text((pos[0] + offset[0], pos[1] + offset[1]), char, font=font, fill=shadow)
        if blur:
            sh = sh.filter(ImageFilter.GaussianBlur(blur))
        layer = Image.alpha_composite(layer, sh)
    ImageDraw.Draw(layer).text(pos, char, font=font, fill=color)
    return layer


def build(p):
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # 投影
    sh_mask = squircle(CANVAS, INSET, blur=10 * SS)
    sh = Image.new("RGBA", (CANVAS, CANVAS), p["shadow"])
    sh.putalpha(Image.fromarray((np.array(sh_mask, dtype=np.float64) * p["shadow"][3] / 255).astype(np.uint8)))
    sh = sh.filter(ImageFilter.GaussianBlur(18 * SS))
    canvas.alpha_composite(sh, (0, int(10 * SS)))

    mask = squircle(CANVAS, INSET)

    # 底色
    body = clip_to(vgrad(CANVAS, p["top"], p["bottom"]), mask)

    # 色晕（右下）＋ 顶部冷光
    body = Image.alpha_composite(body, clip_to(rgrad(CANVAS, (CANVAS * .70, CANVAS * .80), CANVAS * .62, p["glow"], p["glow_alpha"]), mask))
    body = Image.alpha_composite(body, clip_to(rgrad(CANVAS, (CANVAS * .30, CANVAS * .16), CANVAS * .55, (255, 255, 255), p["top_light"]), mask))

    # 顶部镜面：上半部分白色渐隐
    body = Image.alpha_composite(body, clip_to(vgrad(CANVAS, (255, 255, 255, p["spec"]), (255, 255, 255, 0)), mask))

    # 斜向玻璃反光：整块玻璃上斜切一道高光
    streak = vgrad(CANVAS, (255, 255, 255, p["streak"]), (255, 255, 255, 0)).rotate(28, resample=Image.BICUBIC, expand=False)
    streak = streak.filter(ImageFilter.GaussianBlur(18 * SS))
    body = Image.alpha_composite(body, clip_to(streak, mask))

    # 边缘亮环
    ring = np.array(mask, dtype=np.int16) - np.array(squircle(CANVAS, INSET + 7 * SS), dtype=np.int16)
    ring_img = Image.fromarray(ring.clip(0, 255).astype(np.uint8))
    body = Image.alpha_composite(body, Image.composite(vgrad(CANVAS, (255, 255, 255, p["rim_top"]), (255, 255, 255, p["rim_bottom"])), Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0)), ring_img))

    # 底部厚度
    body = Image.alpha_composite(body, clip_to(vgrad(CANVAS, (0, 0, 0, 0), (0, 0, 0, p["bottom_shade"])), mask))

    # 字形
    body = Image.alpha_composite(body, glyph(CANVAS, "⌘", p["glyph"], shadow=p["glyph_shadow"], blur=5 * SS, offset=(0, 2 * SS)))

    canvas = Image.alpha_composite(canvas, body)
    return canvas.resize((S, S), Image.LANCZOS)


LIGHT = dict(
    top=(236, 242, 255, 255), bottom=(170, 188, 220, 255),
    glow=(96, 132, 255), glow_alpha=0.42,
    top_light=0.30,
    spec=150, streak=70,
    rim_top=245, rim_bottom=40,
    bottom_shade=30,
    shadow=(20, 28, 52, 90),
    glyph=(22, 27, 38, 255), glyph_shadow=(255, 255, 255, 120),
)

DARK = dict(
    top=(58, 70, 104, 255), bottom=(16, 18, 28, 255),
    glow=(110, 140, 255), glow_alpha=0.55,
    top_light=0.16,
    spec=80, streak=90,
    rim_top=200, rim_bottom=30,
    bottom_shade=60,
    shadow=(0, 0, 0, 150),
    glyph=(235, 241, 255, 255), glyph_shadow=(0, 0, 0, 140),
)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, p in (("Light", LIGHT), ("Dark", DARK)):
        img = build(p)
        img.save(os.path.join(OUT_DIR, f"AppIcon-{name}-1024.png"))
        img.resize((128, 128), Image.LANCZOS).save(os.path.join(OUT_DIR, f"preview-{name}-128.png"))
        img.resize((32, 32), Image.LANCZOS).save(os.path.join(OUT_DIR, f"preview-{name}-32.png"))
        print("wrote", name)


if __name__ == "__main__":
    main()
