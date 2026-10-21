"""Regenerates the Couch logo masters and README banners in this folder.

Run: python3 brand/generate.py
Copies to keep in step when anything changes:
- pad geometry (ring radius 82, stroke 32, opening 40 to 320 degrees, OK button 26): tools/make-icon.swift, mac/Brand.swift
- colours: mac/Brand.swift, tools/make-icon.swift, phone/style.css (--accent), brand/BRAND.md
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TERRACOTTA, CORAL, INK, CREAM, STONE = "#A8432E", "#EE8E73", "#1C1A18", "#F6F1E9", "#A39B91"
WEIGHT = 22
# The wordmark is drawn on a 256 high grid (ascender 53, x-height 103, baseline 203); its ink runs y 42 to 214.
INK_TOP, INK_HEIGHT, WIDTH = 42, 172, 582


def arc(cx, cy, r, a0, a1):
    """Clockwise arc from a0 to a1 degrees (y down)."""
    x0, y0 = cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))
    x1, y1 = cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))
    large = 1 if (a1 - a0) % 360 > 180 else 0
    return f"M{x0:.2f},{y0:.2f} A{r},{r} 0 {large} 1 {x1:.2f},{y1:.2f}"


# Letters: c, o (the remote's direction pad with its OK button), u, c, h.
LETTERS = " ".join([
    arc(61, 153, 50, 40, 320),
    "M261,103 V163 A40,40 0 0 0 341,163 V103 M341,103 V203",
    arc(421, 153, 50, 40, 320),
    "M491,53 V203 M491,143 A40,40 0 0 1 571,143 V203",
])
PAD = dict(cx=179, cy=153, r=50, dot=13)


def wordmark(color):
    return (f'<path d="{LETTERS}" fill="none" stroke="{color}" stroke-width="{WEIGHT}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
            f'<circle cx="{PAD["cx"]}" cy="{PAD["cy"]}" r="{PAD["r"]}" fill="none" stroke="{color}" stroke-width="{WEIGHT}"/>'
            f'<circle cx="{PAD["cx"]}" cy="{PAD["cy"]}" r="{PAD["dot"]}" fill="{color}"/>')


def pad(color):
    """The symbol: the direction pad opened on the right into a C, with the OK button in the middle.
    A closed ring with a dot would read as a bullseye, so the pad keeps the c's opening."""
    return (f'<path d="{arc(128, 128, 82, 40, 320)}" fill="none" stroke="{color}" stroke-width="32" stroke-linecap="round"/>'
            f'<circle cx="128" cy="128" r="26" fill="{color}"/>')


def write(name, body, w, h, top=0):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 {top} {w} {h}" width="{w}" height="{h}">'
           f'<title>Couch</title>{body}</svg>\n')
    with open(os.path.join(HERE, name), "w") as f:
        f.write(svg)


def banner(animated):
    """1280 x 640 README header and social preview. Animated: the word wipes in left to right,
    then the OK button presses, then the line fades in."""
    s = 1.5
    top = 130  # wordmark top; the wordmark and two text lines sit centred on the 640 height
    x, y = 140, top - INK_TOP * s
    style = ""
    if animated:
        style = """<style>
.wipe{transform-box:fill-box;transform-origin:left center;animation:wipe 1.4s cubic-bezier(.65,0,.35,1) .2s both}
.dot{transform-box:fill-box;transform-origin:center;animation:press .7s cubic-bezier(.34,1.56,.64,1) 1.5s both}
.line{animation:fade .8s ease-out 2s both}
@keyframes wipe{from{transform:scaleX(0)}to{transform:scaleX(1)}}
@keyframes press{0%{transform:scale(0)}60%{transform:scale(1.35)}100%{transform:scale(1)}}
@keyframes fade{from{opacity:0}to{opacity:1}}
@media (prefers-reduced-motion:reduce){.wipe,.dot,.line{animation:none}}
</style><defs><clipPath id="reveal"><rect class="wipe" x="100" y="0" width="1100" height="640"/></clipPath></defs>"""
    cls = lambda c: f' class="{c}"' if animated else ""
    clip = ' clip-path="url(#reveal)"' if animated else ""
    word = (f'<path d="{LETTERS}" fill="none" stroke="{CREAM}" stroke-width="{WEIGHT}" stroke-linecap="round" stroke-linejoin="round"/>'
            f'<circle cx="{PAD["cx"]}" cy="{PAD["cy"]}" r="{PAD["r"]}" fill="none" stroke="{CREAM}" stroke-width="{WEIGHT}"/>')
    mark = (f'<g{clip}><g transform="translate({x},{y}) scale({s})">{word}</g></g>'
            f'<g transform="translate({x},{y}) scale({s})"><circle{cls("dot")} cx="{PAD["cx"]}" cy="{PAD["cy"]}" r="{PAD["dot"]}" fill="{CORAL}"/></g>')
    font = 'font-family="-apple-system,BlinkMacSystemFont,Helvetica Neue,Arial,sans-serif"'
    text = (f'<g{cls("line")}><text x="140" y="{top + INK_HEIGHT * s + 70}" {font} font-size="40" fill="{CREAM}">'
            'A native Mac remote for Google TV.</text>'
            f'<text x="140" y="{top + INK_HEIGHT * s + 122}" font-family="Menlo,monospace" font-size="24" fill="{STONE}">'
            'menu bar · keyboard · trackpad · voice · phone</text></g>')
    return f'<rect width="1280" height="640" fill="{INK}"/>{style}{mark}{text}'


def main():
    for suffix, color in (("", "#000"), ("-white", "#FFFFFF"), ("-ink", INK), ("-cream", CREAM), ("-terracotta", TERRACOTTA)):
        write(f"couch-wordmark{suffix}.svg", wordmark(color), WIDTH, INK_HEIGHT, INK_TOP)
        write(f"couch-pad{suffix}.svg", pad(color), 256, 256)
    # macOS app icon: the 824 tile on the 1024 grid, pad in cream at 2.5x.
    write("app-icon.svg", f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{TERRACOTTA}"/>'
          f'<g transform="translate(192,192) scale(2.5)">{pad(CREAM)}</g>', 1024, 1024)
    write("banner.svg", banner(animated=True), 1280, 640)
    write("banner-static.svg", banner(animated=False), 1280, 640)


if __name__ == "__main__":
    main()
