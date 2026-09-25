# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

"""Write the `<image>` fixtures in tests/oracle.

    python3 tools/image_fixtures.py tests/oracle

An `<image>` fixture is mostly base64, which is not something to write by hand
or to review as a diff. So the pictures are made here, by Pillow -- an encoder
that is not z2dimg's, which is the point of having one -- and each fixture is
the document around one of them. Running this again writes the same files, so
a change to a fixture is a change to this script.

The pictures are small, sixteen pixels or so, and drawn large: the oracle
renders every fixture with its longer side at 256 pixels, so a sixteen-pixel
picture across the whole document is enlarged sixteen times, and the
resampling is what is being compared. The one exception is the downscaling
fixture, which needs a picture with more pixels than it is drawn at.
"""

import base64
import colorsys
import io
import math
import pathlib
import sys

from PIL import Image


def data_url(image, fmt, media, **save):
    out = io.BytesIO()
    image.save(out, fmt, **save)
    return f"data:{media};base64," + base64.b64encode(out.getvalue()).decode("ascii")


def colourful(width, height, alpha=True):
    """Hue across, fading down, with a white diagonal to show edges."""
    im = Image.new("RGBA", (width, height))
    for y in range(height):
        for x in range(width):
            r, g, b = colorsys.hsv_to_rgb(x / width, 0.9, 0.95)
            a = round(255 - 191 * y / max(1, height - 1)) if alpha else 255
            if x == y:
                r, g, b = 1.0, 1.0, 1.0
            im.putpixel((x, y), (round(r * 255), round(g * 255), round(b * 255), a))
    return im


def rings(size):
    """Concentric rings two pixels apart, which alias badly when drawn small."""
    im = Image.new("RGB", (size, size))
    c = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - c, y - c)
            v = 255 if int(d / 2) % 2 == 0 else 0
            im.putpixel((x, y), (v, v // 2, 255 - v))
    return im


def main(out_dir):
    out = pathlib.Path(out_dir)
    p16 = colourful(16, 16)
    rgb16 = colourful(16, 16, alpha=False).convert("RGB")
    wide = colourful(16, 8)

    png = data_url(p16, "PNG", "image/png", optimize=True)
    wide_png = data_url(wide, "PNG", "image/png", optimize=True)
    jpeg = data_url(rgb16, "JPEG", "image/jpeg", quality=92)
    gif = data_url(rgb16.quantize(64), "GIF", "image/gif")
    webp_lossless = data_url(p16, "WEBP", "image/webp", lossless=True)
    webp_lossy = data_url(rgb16, "WEBP", "image/webp", quality=90)
    big = data_url(rings(96), "PNG", "image/png", optimize=True)

    ns = 'xmlns="http://www.w3.org/2000/svg"'
    xlink = 'xmlns:xlink="http://www.w3.org/1999/xlink"'

    def doc(body, view="0 0 16 16", extra=""):
        return f'<svg {ns}{extra} viewBox="{view}">{body}</svg>\n'

    fixtures = {
        # One of each format z2dimg reads that a document is likely to embed.
        "image-png-alpha": doc(f'<image href="{png}" width="16" height="16"/>'),
        "image-jpeg": doc(f'<image href="{jpeg}" width="16" height="16"/>'),
        "image-gif": doc(f'<image href="{gif}" width="16" height="16"/>'),
        "image-webp-lossless": doc(f'<image href="{webp_lossless}" width="16" height="16"/>'),
        "image-webp-lossy": doc(f'<image href="{webp_lossy}" width="16" height="16"/>'),
        # SVG 1.1 documents still spell it this way far more often than not.
        "image-xlink-href": doc(
            f'<image xlink:href="{png}" x="2" y="2" width="12" height="12"/>',
            extra=" " + xlink,
        ),
        # SVG 1.1's keyword rather than CSS's `pixelated`: resvg 0.48 reads
        # only the SVG ones and draws `pixelated` and `crisp-edges` smooth,
        # which is its gap and not a disagreement worth a fixture.
        "image-optimize-speed": doc(
            f'<image href="{png}" width="16" height="16" image-rendering="optimizeSpeed"/>'
        ),
        # SVG 2's `auto`: the picture's own size, sixteen user units.
        "image-auto-size": doc(f'<image href="{png}"/>', view="0 0 24 24"),
        # §7.8's fit, with a picture twice as wide as it is tall.
        "image-par-meet": doc(
            f'<rect width="16" height="16" fill="#ddd"/><image href="{wide_png}" width="16" height="16"/>'
        ),
        "image-par-meet-min": doc(
            f'<rect width="16" height="16" fill="#ddd"/><image href="{wide_png}" width="16" height="16"'
            ' preserveAspectRatio="xMinYMax meet"/>'
        ),
        "image-par-slice": doc(
            f'<rect width="16" height="16" fill="#ddd"/><image href="{wide_png}" x="2" y="2"'
            ' width="12" height="12" preserveAspectRatio="xMinYMid slice"/>'
        ),
        "image-par-none": doc(
            f'<image href="{wide_png}" width="16" height="16" preserveAspectRatio="none"/>'
        ),
        "image-rotated": doc(
            f'<image href="{png}" x="3" y="3" width="10" height="10" transform="rotate(30 8 8)"/>'
        ),
        "image-skewed": doc(
            f'<image href="{png}" x="1" y="3" width="10" height="10" transform="skewX(20)"/>'
        ),
        "image-opacity": doc(
            '<rect x="4" width="8" height="16" fill="black"/>'
            f'<image href="{png}" width="16" height="16" opacity="0.6"/>'
        ),
        "image-clip": doc(
            '<clipPath id="c"><circle cx="8" cy="8" r="6"/></clipPath>'
            f'<image href="{png}" width="16" height="16" clip-path="url(#c)"/>'
        ),
        "image-in-mask": doc(
            f'<mask id="m"><image href="{png}" width="16" height="16"/></mask>'
            '<rect width="16" height="16" fill="navy" mask="url(#m)"/>'
        ),
        "image-use": doc(
            f'<defs><image id="p" href="{png}" width="7" height="7"/></defs>'
            '<use href="#p"/><use href="#p" x="9" y="9"/><use href="#p" x="9" transform="rotate(10 12 3)"/>'
        ),
        "image-in-pattern": doc(
            '<pattern id="t" width="4" height="4" patternUnits="userSpaceOnUse">'
            f'<image href="{png}" width="4" height="4"/></pattern>'
            '<circle cx="8" cy="8" r="7" fill="url(#t)"/>'
        ),
        # Ninety-six pixels drawn at thirty-two and at sixty-four -- the
        # document is four pixels a unit at the oracle's size. The reduction
        # case, and the one where resampling choices show most.
        "image-downscale": doc(
            f'<image href="{big}" x="4" y="4" width="8" height="8"/>'
            f'<image href="{big}" x="20" y="4" width="16" height="16"/>',
            view="0 0 64 64",
        ),
    }
    for name, text in fixtures.items():
        (out / f"{name}.svg").write_text(text, encoding="utf-8")
    print(f"wrote {len(fixtures)} fixtures to {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "tests/oracle")
