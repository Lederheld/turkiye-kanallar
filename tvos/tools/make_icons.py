"""tvOS 'App Icon & Top Shelf Image' brand assets üretir (3 katmanlı paralaks ikon).

Kullanım: python3 tvos/tools/make_icons.py tvos/TurkiyeTV/Assets.xcassets   (Pillow gerekir)
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4  # süper örnekleme (kenar yumuşatma)
INFO = {"author": "xcode", "version": 1}

# Koyu zemin, ortada ekranın rengini yansıtan yumuşak bir hale; ekran canlı bir degrade.
BG_TOP = (30, 30, 38)
BG_BOTTOM = (8, 8, 12)
HALO = (255, 50, 80)
SCREEN_STOPS = [(0.0, (255, 140, 60)), (0.45, (255, 45, 85)), (1.0, (175, 40, 230))]


def finish(img, size):
    return img.resize(size, Image.LANCZOS)


def background(w, h, halo=(0.5, 0.45, 0.42)):
    """Küçük çizilip büyütülür: her şey yumuşak, büyük boyutta da hızlı kalır."""
    sw, sh = max(4, w // 8), max(4, h // 8)
    img = Image.new("RGB", (sw, sh))
    d = ImageDraw.Draw(img)
    for y in range(sh):
        t = y / (sh - 1)
        d.line([(0, y), (sw, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    hx, hy, hr = halo
    cx, cy, rr = hx * sw, hy * sh, hr * sh
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).ellipse([cx - rr * 1.5, cy - rr, cx + rr * 1.5, cy + rr], fill=90)
    img.paste(Image.new("RGB", (sw, sh), HALO), (0, 0), mask.filter(ImageFilter.GaussianBlur(rr * 0.5)))
    return img.resize((w, h), Image.BICUBIC)


def diagonal_gradient(size, stops):
    """Sol üstten sağ alta çok duraklı renk degradesi (küçük çizilip büyütülür)."""
    w, h = size
    sw, sh = max(2, w // 8), max(2, h // 8)
    img = Image.new("RGB", (sw, sh))
    px = img.load()
    for y in range(sh):
        for x in range(sw):
            t = (x / sw * 0.6 + y / sh * 0.4)
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t <= t1:
                    k = (t - t0) / (t1 - t0)
                    px[x, y] = tuple(int(a + (b - a) * k) for a, b in zip(c0, c1))
                    break
    return img.resize(size, Image.BICUBIC)


def tv_geometry(cx, cy, height):
    """Gövdenin kutusu (16:10). Ayak bu kutunun altına çizilir."""
    sw, sh = height * 1.6, height
    return (cx - sw / 2, cy - sh / 2, cx + sw / 2, cy + sh / 2)


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def linear_alpha(size, box, top, bottom):
    """Kutuda yukarıdan aşağı opaklık degradesi (cam parlaması için)."""
    x0, y0, x1, y1 = (int(v) for v in box)
    g = Image.new("L", (1, 256))
    for i in range(256):
        g.putpixel((0, i), int(top + (bottom - top) * i / 255))
    g = g.resize((max(1, x1 - x0), max(1, y1 - y0)), Image.BILINEAR)
    out = Image.new("L", size, 0)
    out.paste(g, (x0, y0))
    return out


def multiply(a, b):
    return ImageChops.multiply(a, b)


def draw_glass_tv(img, box):
    """Cam TV: yarı saydam gövde, içten parlayan ekran, ince parlak kenar."""
    x0, y0, x1, y1 = box
    h = y1 - y0
    W, H = img.size
    radius = h * 0.13
    bezel = h * 0.05
    white = Image.new("RGBA", (W, H), (255, 255, 255, 255))

    # alttaki yumuşak gölge
    shadow = rounded_mask((W, H), [x0 + h * 0.08, y0 + h * 0.25, x1 - h * 0.08, y1 + h * 0.22], radius)
    shadow = shadow.point(lambda v: v * 0.55).filter(ImageFilter.GaussianBlur(h * 0.12))
    img.paste(Image.new("RGBA", (W, H), (0, 0, 0, 255)), (0, 0), shadow)

    # ayak: cam hap
    cx = (x0 + x1) / 2
    stand = rounded_mask((W, H), [cx - h * 0.30, y1 + h * 0.10, cx + h * 0.30, y1 + h * 0.16], h * 0.03)
    neck = rounded_mask((W, H), [cx - h * 0.035, y1 - h * 0.02, cx + h * 0.035, y1 + h * 0.12], h * 0.02)
    stand = ImageChops.lighter(stand, neck)
    img.paste(white, (0, 0), stand.point(lambda v: v * 0.95))

    # gövde: yarı saydam beyaz, üstte daha parlak
    body = rounded_mask((W, H), box, radius)
    img.paste(white, (0, 0), multiply(body, linear_alpha((W, H), box, 255, 228)))

    # ekran: canlı degrade, açık bir TV gibi
    screen_box = [x0 + bezel, y0 + bezel, x1 - bezel, y1 - bezel]
    screen = rounded_mask((W, H), screen_box, radius * 0.6)
    sx0, sy0, sx1, sy1 = (int(v) for v in screen_box)
    fill = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    fill.paste(diagonal_gradient((sx1 - sx0, sy1 - sy0), SCREEN_STOPS).convert("RGBA"), (sx0, sy0))
    img.paste(fill, (0, 0), screen)
    # üstte hafif iç parlaklık
    img.paste(white, (0, 0), multiply(screen, linear_alpha((W, H), [sx0, sy0, sx1, sy0 + (sy1 - sy0) * 0.5], 50, 0)))
    return screen_box, radius


def draw_glass_rim(img, box, radius):
    """Ön katman: gövdenin ince parlak kenarı ve ekranda çapraz cam yansıması."""
    x0, y0, x1, y1 = box
    h = y1 - y0
    W, H = img.size
    white = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    outer = rounded_mask((W, H), box, radius)
    t = h * 0.018
    inner = rounded_mask((W, H), [x0 + t, y0 + t, x1 - t, y1 - t], radius - t)
    rim = ImageChops.subtract(outer, inner)
    img.paste(white, (0, 0), multiply(rim, linear_alpha((W, H), [x0, y0, x1, y1 + 1], 255, 90)))

    bezel = h * 0.05
    screen = rounded_mask((W, H), [x0 + bezel, y0 + bezel, x1 - bezel, y1 - bezel], radius * 0.6)
    streak = Image.new("L", (W, H), 0)
    ImageDraw.Draw(streak).polygon([(x0 + h * 0.15, y0), (x0 + h * 0.62, y0), (x0 + h * 0.05, y1), (x0 - h * 0.42, y1)],
                                   fill=40)
    img.paste(white, (0, 0), multiply(streak.filter(ImageFilter.GaussianBlur(h * 0.02)), screen))


def icon_layers(w, h):
    W, H = w * SS, h * SS
    back = background(w, h)
    tv_h = H * 0.47
    box = tv_geometry(W / 2, H * 0.44, tv_h)
    middle = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    _, radius = draw_glass_tv(middle, box)
    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_glass_rim(front, box, radius)
    return {"Back": back, "Middle": finish(middle, (w, h)), "Front": finish(front, (w, h))}


def top_shelf(w, h):
    ss = 2  # büyük görsellerde bellek için daha düşük süper örnekleme
    W, H = w * ss, h * ss
    img = background(W, H).convert("RGBA")
    box = tv_geometry(W / 2, H * 0.44, H * 0.46)
    _, radius = draw_glass_tv(img, box)
    draw_glass_rim(img, box, radius)
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
