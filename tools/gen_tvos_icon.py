#!/usr/bin/env python3
"""Write packaging/ios/TVAssets.xcassets: Horizon's Apple TV icon, from the geometry of AppIcon-source.png.

tvOS wants a layered icon so the Siri Remote can tilt it: three stacked layers (back, middle, front) for the
App Icon in two sizes, and two flat Top Shelf images. The logo is the iPhone one redrawn at each size: the
dark field (back), the two bars (middle), and the purple horizon line crossing them (front).

    pip install pillow && python3 tools/gen_tvos_icon.py

The measurements below are from the 512x512 source: bars 46 wide at x 166 and 300, spanning y 144 to 345,
the line y 233 to 255 across the full width.
"""
import json
import pathlib
from PIL import Image, ImageDraw

OUT = pathlib.Path(__file__).resolve().parent.parent / "packaging/ios/TVAssets.xcassets"
BACK = (22, 24, 31, 255)
BAR = (236, 237, 243, 255)
BAR_LOWER = (236, 237, 243, 92)  # the bars' lower half: the same white at about a third
LINE = (154, 134, 255, 255)
SS = 4  # drawn at 4x and shrunk, for clean edges


def layer(kind, w, h):
    """One layer of the logo on a w x h canvas, the 512 square scaled to the height and centred."""
    s = h / 512.0
    ox = (w - 512 * s) / 2

    def x(v):
        return (ox + v * s) * SS

    def y(v):
        return v * s * SS

    img = Image.new("RGBA", (w * SS, h * SS), BACK if kind == "back" else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if kind == "middle":
        for bx in (166, 300):
            d.rectangle([x(bx), y(144), x(bx + 46) - 1, y(233) - 1], fill=BAR)
            d.rectangle([x(bx), y(256), x(bx + 46) - 1, y(345) - 1], fill=BAR_LOWER)
    if kind == "front":
        d.rectangle([0, y(233), w * SS, y(256) - 1], fill=LINE)
    return img.resize((w, h), Image.LANCZOS)


def flat(w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for kind in ("back", "middle", "front"):
        img = Image.alpha_composite(img, layer(kind, w, h))
    return img.convert("RGB")


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


INFO = {"author": "xcode", "version": 1}


def imageset(folder, name, w, h, render):
    """folder/<name>.imageset with 1x and 2x PNGs."""
    base = folder / f"{name}.imageset"
    images = []
    for scale in (1, 2):
        file = f"{name.replace(' ', '')}@{scale}x.png"
        base.mkdir(parents=True, exist_ok=True)
        render(w * scale, h * scale).save(base / file, optimize=True)
        images.append({"filename": file, "idiom": "tv", "scale": f"{scale}x"})
    write(base / "Contents.json", {"images": images, "info": INFO})


def stack(brand, name, w, h):
    base = brand / f"{name}.imagestack"
    layers = []
    for title, kind in (("Front", "front"), ("Middle", "middle"), ("Back", "back")):
        folder = base / f"{title}.imagestacklayer"
        write(folder / "Contents.json", {"info": INFO})
        imageset(folder, "Content", w, h, lambda a, b, k=kind: layer(k, a, b))
        layers.append({"filename": f"{title}.imagestacklayer"})
    write(base / "Contents.json", {"layers": layers, "info": INFO})


def main():
    write(OUT / "Contents.json", {"info": INFO})
    brand = OUT / "App Icon & Top Shelf Image.brandassets"
    stack(brand, "App Icon - Large", 1280, 768)
    stack(brand, "App Icon - Small", 400, 240)
    imageset(brand, "Top Shelf Image", 1920, 720, flat)
    imageset(brand, "Top Shelf Image Wide", 2320, 720, flat)
    write(brand / "Contents.json", {
        "assets": [
            {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
        ],
        "info": INFO,
    })
    print("wrote", OUT)


if __name__ == "__main__":
    main()
