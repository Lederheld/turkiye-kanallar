"""tvOS 'App Icon & Top Shelf Image' brand assets üretir (3 katmanlı paralaks ikon).

Kullanım: python3 tvos/tools/make_icons.py tvos/TurkiyeTV/Assets.xcassets   (Pillow gerekir)
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SS = 4  # süper örnekleme (kenar yumuşatma)
RED_TOP = (214, 26, 48)
RED_BOTTOM = (140, 8, 28)
WHITE = (255, 255, 255, 255)
SCREEN = (24, 24, 30, 255)
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
INFO = {"author": "xcode", "version": 1}


def finish(img, size):
    return img.resize(size, Image.LANCZOS)


def gradient(w, h):
    """Küçük çizilip büyütülür: degrade zaten yumuşak, büyük boyutta hızlı kalır."""
    full = (w, h)
    w, h = max(2, w // 8), max(2, h // 8)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = min(1.0, max(0.0, (y / h) * 0.8 + (x / w) * 0.2))
            # sol üstte hafif parlaklık
            glow = max(0.0, 1 - math.hypot(x / w - 0.3, y / h - 0.2) / 0.9) * 0.18
            px[x, y] = tuple(min(255, int((a + (b - a) * t) * (1 + glow))) for a, b in zip(RED_TOP, RED_BOTTOM))
    return img.resize(full, Image.BICUBIC)


def tv_geometry(cx, cy, height):
    """Ekranın kutusu (yükseklik verilen birimde)."""
    sw, sh = height * 1.5, height
    return (cx - sw / 2, cy - sh / 2, cx + sw / 2, cy + sh / 2)


def draw_tv(draw, box, s):
    x0, y0, x1, y1 = box
    h = y1 - y0
    bezel = h * 0.09
    radius = h * 0.14
    line = max(1, int(h * 0.06))
    # anten
    top_mid = ((x0 + x1) / 2, y0)
    draw.line([top_mid, (top_mid[0] - h * 0.28, y0 - h * 0.30)], fill=WHITE, width=line)
    draw.line([top_mid, (top_mid[0] + h * 0.28, y0 - h * 0.30)], fill=WHITE, width=line)
    # ayak
    foot_w = h * 0.5
    draw.rounded_rectangle([(x0 + x1) / 2 - foot_w / 2, y1 - h * 0.02, (x0 + x1) / 2 + foot_w / 2, y1 + h * 0.10],
                           radius=h * 0.04, fill=WHITE)
    # çerçeve + ekran
    draw.rounded_rectangle(box, radius=radius, fill=WHITE)
    draw.rounded_rectangle([x0 + bezel, y0 + bezel, x1 - bezel, y1 - bezel], radius=radius * 0.6, fill=SCREEN)


def draw_crescent_star(img, center, unit):
    """unit = ekranın iç yüksekliği; ay yıldız grubu bu alana ortalanır."""
    cx_group, cy = center
    r_out, r_in, offset = 0.30 * unit, 0.24 * unit, 0.075 * unit
    star_r = 0.14 * unit
    star_dx = offset + r_in + 0.05 * unit + star_r * 0.81
    # grup yatayda ortalanır
    left, right = -r_out, star_dx + star_r
    cx = cx_group - (left + right) / 2

    mask = Image.new("L", img.size, 0)
    md = ImageDraw.Draw(mask)
    md.ellipse([cx - r_out, cy - r_out, cx + r_out, cy + r_out], fill=255)
    md.ellipse([cx + offset - r_in, cy - r_in, cx + offset + r_in, cy + r_in], fill=0)
    sx = cx + star_dx
    points = []
    for i in range(10):
        r = star_r if i % 2 == 0 else star_r * 0.382
        a = math.pi + i * math.pi / 5  # bir ucu aya bakar
        points.append((sx + r * math.cos(a), cy + r * math.sin(a)))
    md.polygon(points, fill=255)
    img.paste(Image.new("RGBA", img.size, WHITE), (0, 0), mask)


def icon_layers(w, h):
    W, H = w * SS, h * SS
    back = gradient(w, h)

    screen_h = H * 0.50
    box = tv_geometry(W / 2, H * 0.53, screen_h)
    middle = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_tv(ImageDraw.Draw(middle), box, SS)

    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    inner_h = screen_h * (1 - 2 * 0.09)
    draw_crescent_star(front, ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2), inner_h)
    return {"Back": back, "Middle": finish(middle, (w, h)), "Front": finish(front, (w, h))}


def top_shelf(w, h):
    ss = 2  # büyük görsellerde bellek için daha düşük süper örnekleme
    W, H = w * ss, h * ss
    img = gradient(W, H).convert("RGBA")
    screen_h = H * 0.42
    gap = H * 0.22
    font = ImageFont.truetype(FONT, int(H * 0.22))
    text = "Türkiye TV"
    d = ImageDraw.Draw(img)
    tw = d.textlength(text, font=font)
    tv_w = screen_h * 1.5
    start = (W - (tv_w + gap + tw)) / 2
    box = tv_geometry(start + tv_w / 2, H * 0.52, screen_h)
    draw_tv(d, box, ss)
    inner_h = screen_h * (1 - 2 * 0.09)
    draw_crescent_star(img, ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2), inner_h)
    d = ImageDraw.Draw(img)
    d.text((start + tv_w + gap, H * 0.50), text, font=font, fill=WHITE, anchor="lm")
    return finish(img, (w, h)).convert("RGB")


def write_json(path, data):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(data, indent=2) + "\n")


def imagestack(root, name, base_size, scales):
    stack = root / f"{name}.imagestack"
    write_json(stack, {"info": INFO, "layers": [{"filename": f"{n}.imagestacklayer"} for n in ("Front", "Middle", "Back")]})
    rendered = {scale: icon_layers(base_size[0] * scale, base_size[1] * scale) for scale in scales}
    for layer in ("Front", "Middle", "Back"):
        layer_dir = stack / f"{layer}.imagestacklayer"
        write_json(layer_dir, {"info": INFO})
        imageset = layer_dir / "Content.imageset"
        images = []
        for scale in scales:
            filename = f"{layer.lower()}@{scale}x.png"
            images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
            imageset.mkdir(parents=True, exist_ok=True)
            rendered[scale][layer].save(imageset / filename, optimize=True)
        write_json(imageset, {"images": images, "info": INFO})


def imageset(root, name, base_size):
    path = root / f"{name}.imageset"
    images = []
    for scale in (1, 2):
        filename = f"{name.lower().replace(' ', '-')}@{scale}x.png"
        images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
        path.mkdir(parents=True, exist_ok=True)
        top_shelf(base_size[0] * scale, base_size[1] * scale).save(path / filename, optimize=True)
    write_json(path, {"images": images, "info": INFO})


def main(catalog):
    write_json(catalog, {"info": INFO})
    brand = catalog / "App Icon & Top Shelf Image.brandassets"
    write_json(brand, {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ], "info": INFO})
    imagestack(brand, "App Icon", (400, 240), (1, 2))
    imagestack(brand, "App Icon - App Store", (1280, 768), (1,))
    imageset(brand, "Top Shelf Image", (1920, 720))
    imageset(brand, "Top Shelf Image Wide", (2320, 720))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
