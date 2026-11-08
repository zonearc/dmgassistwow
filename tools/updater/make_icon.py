# make_icon.py: draws tools/updater/dmgassist.ico (the updater app icon). Run: python3 make_icon.py dmgassist.ico
import sys
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
S = 256
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# dark rounded square with a gold rim
d.rounded_rectangle([6, 6, S - 7, S - 7], radius=52, fill=(28, 24, 44, 255), outline=(232, 176, 58, 255), width=12)
# gold "D"
font = None
for f in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"]:
    try:
        font = ImageFont.truetype(f, 190); break
    except OSError:
        pass
bbox = d.textbbox((0, 0), "D", font=font)
w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
d.text(((S - w) / 2 - bbox[0] - 14, (S - h) / 2 - bbox[1] - 4), "D", font=font, fill=(245, 190, 60, 255))
# blue "update" arrow, bottom right
cx, cy, r = 190, 190, 46
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(40, 150, 230, 255), outline=(28, 24, 44, 255), width=8)
d.polygon([(cx, cy - 30), (cx - 26, cy - 2), (cx - 10, cy - 2), (cx - 10, cy + 28), (cx + 10, cy + 28), (cx + 10, cy - 2), (cx + 26, cy - 2)], fill=(255, 255, 255, 255))
sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
img.save(out, format="ICO", sizes=sizes)
img.save(out.replace(".ico", ".png"))
