#!/usr/bin/env python3
"""生成 MacKit 的 macOS 27 原生图标资源。

使用 Apple 官方 Icon Composer 渲染器与 actool：
- Resources/MacKit.icon：透明 ⌘ 图层 + Automatic 背景、高光、投影
- Resources/Assets.car：actool 编译的 Aqua / DarkAqua 图标栈
- Resources/MacKit.icns：actool 生成的旧版回退图标
- docs/icon-light.png / icon-dark.png：文档用亮/暗图标预览
"""

import json
import os
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFont

S = 1024
# actool 的 macOS 回退图标在 256px 画布上占 206px；同一网格在
# 1024px 上占 824px。ictool 导出的是无外边距的图标表面，不能直接
# 当作 applicationIconImage，否则运行中 Dock 会比系统图标大一圈。
MACOS_ICON_BODY = 824
FONT = "/System/Library/Fonts/SFNS.ttf"
GLYPH_COLOR = (92, 157, 255, 255)
GLYPH_RATIO = 0.56
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES_DIR = os.path.join(ROOT, "Resources")
ICON_DIR = os.path.join(RES_DIR, "MacKit.icon")
ASSET_DIR = os.path.join(ICON_DIR, "Assets")
OUT_DIR = os.path.join(ROOT, "build", "icons")
ASSET_OUT = os.path.join(ROOT, "build", "icon-assets")
DOCS_DIR = os.path.join(ROOT, "docs")

XCODE_DEVELOPER = "/Applications/Xcode.app/Contents/Developer"
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ACTOOL = os.path.join(XCODE_DEVELOPER, "usr", "bin", "actool")
ASSET_NAME = "MacKit"


def make_glyph():
    os.makedirs(ASSET_DIR, exist_ok=True)
    font = ImageFont.truetype(FONT, int(S * GLYPH_RATIO))
    try:
        font.set_variation_by_axes([700])
    except Exception:
        pass
    char = "⌘"
    bbox = font.getbbox(char)
    pos = ((S - (bbox[2] - bbox[0])) / 2 - bbox[0],
           (S - (bbox[3] - bbox[1])) / 2 - bbox[1])
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(img).text(pos, char, font=font, fill=GLYPH_COLOR)
    img.save(os.path.join(ASSET_DIR, "MacKit-glyph.png"))


def write_icon_json():
    data = {
        "fill": "automatic",
        "groups": [
            {
                "layers": [
                    {"image-name": "MacKit-glyph.png", "name": "MacKit command"}
                ],
                "name": "MacKit",
                "shadow": {"kind": "neutral", "opacity": 0.3},
                "specular": True,
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(ICON_DIR, "icon.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def render_native():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DOCS_DIR, exist_ok=True)
    for label, rendition in (("Light", "Default"), ("Dark", "Dark")):
        out = os.path.join(OUT_DIR, f"AppIcon-{label}-1024.png")
        subprocess.run([
            ICTOOL, ICON_DIR,
            "--export-image",
            "--output-file", out,
            "--platform", "macOS",
            "--rendition", rendition,
            "--width", str(S), "--height", str(S), "--scale", "1",
            "--design-generation", "27",
        ], check=True)
        surface = Image.open(out).convert("RGBA")
        img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        inset = (S - MACOS_ICON_BODY) // 2
        img.alpha_composite(surface.resize((MACOS_ICON_BODY, MACOS_ICON_BODY), Image.LANCZOS),
                            (inset, inset))
        img.save(out)
        img.resize((128, 128), Image.LANCZOS).save(os.path.join(OUT_DIR, f"preview-{label}-128.png"))
        img.resize((32, 32), Image.LANCZOS).save(os.path.join(OUT_DIR, f"preview-{label}-32.png"))
        img.save(os.path.join(DOCS_DIR, f"icon-{label.lower()}.png"))
    return {
        "Light": Image.open(os.path.join(OUT_DIR, "AppIcon-Light-1024.png")).convert("RGBA"),
        "Dark": Image.open(os.path.join(OUT_DIR, "AppIcon-Dark-1024.png")).convert("RGBA"),
    }


def compile_native():
    if os.path.isdir(ASSET_OUT):
        shutil.rmtree(ASSET_OUT)
    os.makedirs(ASSET_OUT)
    subprocess.run([
        ACTOOL, ICON_DIR,
        "--compile", ASSET_OUT,
        "--output-format", "human-readable-text",
        "--notices", "--warnings",
        "--output-partial-info-plist", os.path.join(ASSET_OUT, "partial.plist"),
        "--app-icon", ASSET_NAME,
        "--include-all-app-icons",
        "--enable-on-demand-resources", "NO",
        "--development-region", "en",
        "--target-device", "mac",
        "--minimum-deployment-target", "26.0",
        "--platform", "macosx",
    ], check=True, env={**os.environ, "DEVELOPER_DIR": XCODE_DEVELOPER})
    for name in ("Assets.car", "MacKit.icns"):
        src = os.path.join(ASSET_OUT, name)
        if not os.path.isfile(src) or os.path.getsize(src) == 0:
            raise SystemExit(f"actool 未生成 {name}")
        shutil.copy2(src, os.path.join(RES_DIR, name))


def main():
    print("生成透明 ⌘ 图层")
    make_glyph()
    write_icon_json()
    print("用 Apple ictool 渲染亮/暗图标")
    render_native()
    print("用 Apple actool 编译 Assets.car 与回退 icns")
    compile_native()
    print("完成：Resources/Assets.car, Resources/MacKit.icns, docs/icon-*.png")


if __name__ == "__main__":
    main()
