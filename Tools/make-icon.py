"""Draws Kaka's 1024px app icons in the 青石巷 palette. Run: python3 Tools/make-icon.py

AppIcon.png is the default icon. iOS 18+ home screens can also show dark and tinted icons:
AppIcon-Dark.png moves 青石 from the background into the strip (the system draws its own dark
background behind the transparent corners) and AppIcon-Tinted.png is a grayscale version the
system colours, with the seams cut through the strip."""
from PIL import Image, ImageDraw, ImageFilter

S = 4                      # supersample factor
W = 1024 * S
STONE, STONE_DEEP = (0x55, 0x69, 0x6B), (0x46, 0x58, 0x5A)   # 青石, lighter at the top like wet stone
WALL = (0xF2, 0xF0, 0xEA)                                    # 粉墙
MIST, MOSS_MIST = (0xDC, 0xE0, 0xDC), (0xCF, 0xD9, 0xD5)     # 雨雾 bubbles
TILE = (0x2B, 0x31, 0x35)                                    # 黛瓦 seams

def s(v): return int(v * S)

bg = Image.new("RGB", (W, W))
px = ImageDraw.Draw(bg)
for y in range(W):                     # very gentle vertical tone, reads as solid
    t = y / (W - 1)
    px.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(STONE, STONE_DEEP)))

card = (s(332), s(150), s(692), s(874))
shadow = Image.new("L", (W, W), 0)
ImageDraw.Draw(shadow).rounded_rectangle((card[0], card[1] + s(18), card[2], card[3] + s(18)), s(70), fill=90)
shadow = shadow.filter(ImageFilter.GaussianBlur(s(34)))
bg.paste((0x22, 0x2C, 0x2E), (0, 0), shadow)

layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
d.rounded_rectangle(card, s(70), fill=WALL)
left = [(376, 206, 526), (376, 360, 546), (376, 522, 516), (376, 684, 496)]
right = [(528, 262, 648), (538, 416, 648), (488, 578, 648), (498, 740, 648)]
for x0, y, x1 in left:
    d.rounded_rectangle((s(x0), s(y), s(x1), s(y + 30)), s(15), fill=MIST)
for x0, y, x1 in right:
    d.rounded_rectangle((s(x0), s(y), s(x1), s(y + 30)), s(15), fill=MOSS_MIST)
for y in (316, 632):
    x = 332
    while x < 692:
        d.rounded_rectangle((s(x), s(y - 6), s(min(x + 38, 692)), s(y + 6)), s(6), fill=TILE)
        x += 48
mask = Image.new("L", (W, W), 0)
ImageDraw.Draw(mask).rounded_rectangle(card, s(70), fill=255)
bg.paste(layer, (0, 0), Image.composite(layer.getchannel("A"), mask, mask))

bg.resize((1024, 1024), Image.LANCZOS).save("Kaka/Assets.xcassets/AppIcon.appiconset/AppIcon.png")


def seam_dashes():
    for y in (316, 632):
        x = 332
        while x < 692:
            yield (s(x), s(y - 6), s(min(x + 38, 692)), s(y + 6))
            x += 48


def strip_only(top, bottom, mist, moss, seam=None):
    """The strip on a transparent background. Without a seam colour the dashes are cut out."""
    tone = Image.new("RGBA", (W, W))
    td = ImageDraw.Draw(tone)
    for y in range(card[1], card[3]):
        t = (y - card[1]) / (card[3] - card[1])
        td.line([(card[0], y), (card[2], y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    d = ImageDraw.Draw(tone)
    for x0, y, x1 in left:
        d.rounded_rectangle((s(x0), s(y), s(x1), s(y + 30)), s(15), fill=mist + (255,))
    for x0, y, x1 in right:
        d.rounded_rectangle((s(x0), s(y), s(x1), s(y + 30)), s(15), fill=moss + (255,))
    alpha = Image.new("L", (W, W), 0)
    ImageDraw.Draw(alpha).rounded_rectangle(card, s(70), fill=255)
    for dash in seam_dashes():
        if seam:
            d.rounded_rectangle(dash, s(6), fill=seam + (255,))
        else:
            ImageDraw.Draw(alpha).rounded_rectangle(dash, s(6), fill=0)
    tone.putalpha(alpha)
    return tone.resize((1024, 1024), Image.LANCZOS)


# Dark: 青石 strip, lighter at the top like wet stone, with 粉墙 seams.
strip_only((0x5E, 0x73, 0x75), (0x48, 0x5A, 0x5C), (0x89, 0x9C, 0x9D), (0x84, 0xA2, 0x9F), WALL) \
    .save("Kaka/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png")
# Tinted: grayscale; the strip takes the tint, the bubbles less of it, the seams none.
strip_only((0xFF, 0xFF, 0xFF), (0xE4, 0xE4, 0xE4), (0xA6, 0xA6, 0xA6), (0xA6, 0xA6, 0xA6)) \
    .save("Kaka/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png")

# Small copies for the About page (76 pt at 3x); the app icon set itself can't be loaded by name.
for name in ("AppIcon", "AppIcon-Dark"):
    Image.open(f"Kaka/Assets.xcassets/AppIcon.appiconset/{name}.png").resize((240, 240), Image.LANCZOS) \
        .save(f"Kaka/Assets.xcassets/AboutIcon.imageset/{name.replace('AppIcon', 'AboutIcon')}.png")
