#!/usr/bin/env python3
"""Draws DMGAssist's own icon: a bold gold "D" on a dark crimson disc with a gold rim, like Masque's "M".

Output: addons/DMGAssist/Media/DMGAssist.tga (64x64, 32-bit with alpha, uncompressed: the format WoW reads).
Rendered at 4x and scaled down for smooth edges. Run again after changing the colours.
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "addons", "DMGAssist", "Media", "DMGAssist.tga")
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"
S = 256  # working size


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # the disc: a dark crimson centre fading to near black, then a gold rim
    for i in range(S // 2, 0, -1):
        t = i / (S / 2)
        r = int(120 * (1 - t) + 30 * t)
        g = int(14 * (1 - t) + 6 * t)
        b = int(18 * (1 - t) + 8 * t)
        d.ellipse((S / 2 - i, S / 2 - i, S / 2 + i, S / 2 + i), fill=(r, g, b, 255))
    d.ellipse((6, 6, S - 6, S - 6), outline=(214, 160, 52, 255), width=12)
    d.ellipse((20, 20, S - 20, S - 20), outline=(90, 56, 12, 255), width=4)
    # the letter, with a dark outline and a soft shadow
    font = ImageFont.truetype(FONT, 176)
    box = d.textbbox((0, 0), "D", font=font)
    x = (S - (box[2] - box[0])) / 2 - box[0]
    y = (S - (box[3] - box[1])) / 2 - box[1] + 2
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((x + 6, y + 8), "D", font=font, fill=(0, 0, 0, 200))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(6)))
    d = ImageDraw.Draw(img)
    d.text((x, y), "D", font=font, fill=(255, 176, 32, 255), stroke_width=9, stroke_fill=(40, 16, 0, 255))
    # a lighter top half on the letter, for a little shine
    shine = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shine).text((x, y), "D", font=font, fill=(255, 226, 120, 255))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rectangle((0, 0, S, S * 0.47), fill=150)
    img.paste(shine, (0, 0), Image.composite(shine.getchannel("A"), Image.new("L", (S, S), 0), mask))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.resize((64, 64), Image.LANCZOS).save(OUT, compression=None)
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(os.environ.get("ICON_PREVIEW_DIR", "/tmp"),
                                                            "dmgassist_icon_preview.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
