# Couch brand

## The idea

The wordmark `couch` is drawn in custom monoline letters, with the o as the remote's direction pad and its OK button. The symbol is that pad opened on the right into a C: the control you use most, spelling the name. A closed ring with a dot would read as a bullseye, so the symbol keeps the opening.

- **Wordmark**: the primary logo (README, banner, anywhere wide).
- **Pad**: the app icon, the phone icon and the menu bar glyph.

## Colour

| Name | HEX | Use |
|---|---|---|
| Terracotta | `#A8432E` | app icon tile; accent in light mode, white text on it (6.0:1) |
| Coral | `#EE8E73` | accent in dark mode, Ink text on it (7.2:1); the OK dot in the banner |
| Ink | `#1C1A18` | wordmark on light, banner background |
| Cream | `#F6F1E9` | wordmark on dark, the pad on the icon |
| Stone | `#A39B91` | secondary text on Ink (the banner's second line) |

`mac/Brand.swift` holds the accent (Terracotta in light mode, Coral in dark) and the menu bar glyph: the OK button is solid while the TV is on and connected, hollow otherwise. The phone page uses the same accent in `phone/style.css`.

## Files

| File | Use |
|---|---|
| `couch-wordmark-*.svg` | wordmark in black, white, Ink, Cream, Terracotta |
| `couch-pad-*.svg` | the pad symbol in the same colours |
| `app-icon.svg` | app icon master (824 tile on the 1024 grid) |
| `banner.svg` | animated README header: the word wipes in, the OK button presses, the line fades in. Still under reduced motion. |
| `banner-static.svg`, `banner.png` | still banner; the PNG is the GitHub social preview (1280x640) |
| `generate.py` | regenerates every SVG above |

`tools/make-icon.swift` draws the app icon and the full-bleed phone icon (`phone/icon.png`); `build-app.sh` runs it, so both stay in step with the design.

## Use

- Clear space around the logo: at least the height of the wordmark's o.
- Minimum size: wordmark 72 px wide, pad 16 px.
- Do not retype the wordmark in a font, close the pad's opening, or recolour outside these colours plus black and white.
