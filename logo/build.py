#!/usr/bin/env python3
"""Generates every logo asset for the web app and the iOS app icon.

Run with no arguments to regenerate the SVGs, then rasterise them to PNG with
headless Chrome and Pillow. Chrome is only needed for the PNG step; if it is
missing the SVGs are still written and the PNG step is skipped.

Layout of the icon, on a 256 grid:
  * squircle tile (rounded for the web, square for the platforms, which mask)
  * a thick track bleeding off two opposite corners, 180-degree symmetric about
    the centre so its midpoint lands exactly on the icon's centre
  * the track is cut out of a disc around the centre, so it reads as passing
    behind the ring instead of colliding with it
  * the navigation arrow inside the ring
"""
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
REPO = ROOT.parent
PUBLIC = REPO / "web" / "public"
PLATFORM = ROOT / "platform"

FULL = ("M186.4 73.8Q189.6 66.4 182.3 69.6L73.7 116.3Q66.3 119.5 74.3 120.1"
        "L110.6 137.1Q118 140 120.8 147.5L133.7 182.2Q136.5 189.7 139.7 182.4Z")
UPPER = ("M186.4 73.8Q189.6 66.4 182.3 69.6L73.7 116.3Q66.3 119.5 74.3 120.1"
         "L110.6 137.1Q118 140 120.8 147.5L186.4 73.8Z")

# Control points sum to (256, 256), which makes the track 180-degree symmetric
# about (128, 128) — the same point the ring and the arrow are centred on.
ROUTE = "M-20 276C22.4 148.7 233.6 107.3 276-20"
ROUTE_W = 46
KNOCKOUT_R = 92
RING_R = 76
RING_W = 14
ARROW_SCALE = 0.64

PALETTES = {
    "dark": dict(
        tile=[("#2B2F35", 0), ("#191C21", 0.55), ("#0B0C0E", 1)],
        glow=("#2E6BE6", 0.15), sheen=0.09,
        route="#7C848D", ring="#4C8DFF", upper="#FFFFFF", lower="#2E6BE6",
        theme="#191C21",
    ),
    "light": dict(
        tile=[("#FBFCFD", 0), ("#E9ECF0", 0.55), ("#D6DBE1", 1)],
        glow=("#2E6BE6", 0.07), sheen=0.0,
        route="#A3ABB4", ring="#1D4ED8", upper="#2E6BE6", lower="#9CC0F7",
        theme="#E9ECF0",
    ),
}

SVG = """<svg width="256" height="256" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="{k}-title {k}-desc">
<title id="{k}-title">{title}</title>
<desc id="{k}-desc">{desc}</desc>
<defs>
<linearGradient id="{k}-tile" x1="0" y1="0" x2="256" y2="256" gradientUnits="userSpaceOnUse">
{stops}
</linearGradient>
<radialGradient id="{k}-glow" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(150 108) rotate(45) scale(140)">
<stop stop-color="{glow}" stop-opacity="{glow_a}"/>
<stop offset="1" stop-color="{glow}" stop-opacity="0"/>
</radialGradient>
<linearGradient id="{k}-sheen" x1="0" y1="0" x2="180" y2="200" gradientUnits="userSpaceOnUse">
<stop stop-color="#FFFFFF" stop-opacity="{sheen}"/>
<stop offset="0.6" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<clipPath id="{k}-clip">
<rect width="256" height="256"{rx}/>
</clipPath>
<mask id="{k}-knockout">
<rect width="256" height="256" fill="#FFFFFF"/>
<circle cx="128" cy="128" r="{knock}"/>
</mask>
</defs>
<g{clip}>
{body}
</g>
</svg>
"""


def body(p, rx, tile=True):
    """The artwork, optionally without the tile so it can sit on transparency."""
    corner = f' rx="{rx}"' if rx else ""
    out = []
    if tile:
        out.append(f'<rect width="256" height="256"{corner} fill="url(#{{k}}-tile)"/>')
        out.append(f'<rect width="256" height="256"{corner} fill="url(#{{k}}-glow)"/>')
    out.append(
        f'<g mask="url(#{{k}}-knockout)">'
        f'<path d="{ROUTE}" fill="none" stroke="{p["route"]}" stroke-width="{ROUTE_W}"'
        f' stroke-linecap="round" stroke-linejoin="round"/></g>'
    )
    out.append(
        f'<circle cx="128" cy="128" r="{RING_R}" fill="none"'
        f' stroke="{p["ring"]}" stroke-width="{RING_W}"/>'
    )
    out.append(
        f'<g transform="translate(128 128) scale({ARROW_SCALE}) translate(-128 -128)">'
        f'<path d="{FULL}" fill="{p["lower"]}"/>'
        f'<path d="{UPPER}" fill="{p["upper"]}"/></g>'
    )
    if tile and p["sheen"]:
        out.append(f'<rect width="256" height="256"{corner} fill="url(#{{k}}-sheen)"/>')
    return "\n".join(out)


def render(key, palette, rx, desc):
    p = PALETTES[palette]
    stops = "".join(
        f'<stop offset="{o}" stop-color="{c}"/>\n' for c, o in p["tile"]
    ).rstrip("\n")
    return SVG.format(
        k=key,
        title=desc.split(",")[0],
        desc=desc,
        stops=stops,
        glow=p["glow"][0], glow_a=p["glow"][1], sheen=p["sheen"],
        rx=f' rx="{rx}"' if rx else "",
        knock=KNOCKOUT_R,
        clip=f' clip-path="url(#{key}-clip)"',
        body=body(p, rx).replace("{k}", key),
    )


SVGS = {
    "logo-dark.svg": lambda: render(
        "dark", "dark", 56, "GPX Plotter, graphite tile, for the web"),
    "logo-light.svg": lambda: render(
        "light", "light", 56, "GPX Plotter, light tile, for light web surfaces"),
    "icon-square-dark.svg": lambda: render(
        "sq", "dark", 0, "GPX Plotter, full-bleed square, for platform app icons"),
    "icon-square-light.svg": lambda: render(
        "sql", "light", 0, "GPX Plotter, full-bleed square, light platform app icon"),
    "safari-pinned-tab.svg": lambda: (
        '<svg width="256" height="256" viewBox="0 0 256 256"'
        ' xmlns="http://www.w3.org/2000/svg">'
        '<circle cx="128" cy="128" r="76" fill="none" stroke="#000"'
        f' stroke-width="{RING_W}"/>'
        f'<g transform="translate(128 128) scale({ARROW_SCALE}) translate(-128 -128)">'
        f'<path d="{FULL}"/><path d="{UPPER}" fill="#fff"/></g></svg>'
    ),
}

# (svg, output path, pixel size)
PNGS = [
    ("logo-dark.svg", PUBLIC / "favicon-16.png", 16),
    ("logo-dark.svg", PUBLIC / "favicon-32.png", 32),
    ("logo-dark.svg", PUBLIC / "favicon-48.png", 48),
    ("icon-square-dark.svg", PUBLIC / "apple-touch-icon.png", 180),
    ("icon-square-dark.svg", PUBLIC / "icon-192.png", 192),
    ("icon-square-dark.svg", PUBLIC / "icon-512.png", 512),
    ("icon-square-dark.svg", PLATFORM / "ios" / "AppIcon-1024.png", 1024),
]

CHROME = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
]


def find_chrome():
    for c in CHROME:
        if pathlib.Path(c).exists():
            return c
    return shutil.which("google-chrome") or shutil.which("chromium")


PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;background:transparent}}
img{{display:block;width:{w}px;height:{h}px}}
</style></head><body><img src="{src}"></body></html>"""


def rasterise(chrome, svg, out, size, opaque):
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp) / "page.html"
        page.write_text(PAGE.format(w=size, h=size, src=svg.resolve().as_uri()))
        shot = pathlib.Path(tmp) / "shot.png"
        cmd = [chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
               f"--screenshot={shot}", f"--window-size={size},{size}",
               f"--default-background-color={'ffffffff' if opaque else '00000000'}",
               page.as_uri()]
        subprocess.run(cmd, check=True, capture_output=True)
        from PIL import Image
        with Image.open(shot) as im:
            im.load()
            if im.size != (size, size):
                raise SystemExit(f"{out.name}: rendered {im.size}, wanted {(size, size)}")
            # The app icon must have no alpha channel at all, or App Store
            # Connect rejects the upload.
            im.convert("RGB" if opaque else "RGBA").save(out, "PNG", optimize=True)


def main():
    for name, fn in SVGS.items():
        (ROOT / name).write_text(fn())
        print("svg  ", name)
    shutil.copyfile(ROOT / "logo-dark.svg", PUBLIC / "favicon.svg")
    shutil.copyfile(ROOT / "safari-pinned-tab.svg", PUBLIC / "safari-pinned-tab.svg")
    print("svg   web/public/favicon.svg, web/public/safari-pinned-tab.svg")

    chrome = find_chrome()
    if not chrome:
        print("\nno Chrome found, skipped the PNG step", file=sys.stderr)
        return
    for svg, out, size in PNGS:
        rasterise(chrome, ROOT / svg, out, size, opaque=size >= 180)
        print("png  ", out.relative_to(REPO), f"{size}x{size}")

    from PIL import Image
    with Image.open(PUBLIC / "favicon-48.png") as im:
        im.load()
        im.resize((256, 256), Image.LANCZOS).save(
            PUBLIC / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
    print("ico   web/public/favicon.ico 16,32,48")

    # A maskable icon only has to keep its content inside the middle 80%, and
    # the ring sits at 65% of the width, so the square icon doubles as one.
    for size in (192, 512):
        src = PUBLIC / f"icon-{size}.png"
        shutil.copyfile(src, PUBLIC / f"maskable-{size}.png")
        print("png   web/public/maskable-%d.png" % size)


main()
