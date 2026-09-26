# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

"""Hold this renderer's output against resvg's.

The one claim about a renderer that its own tests cannot make. A Zig test here
can check this parser against this rasterizer, and does; what it cannot do is
notice that both of them read the specification the same wrong way. resvg is an
independent implementation of the same specification -- a different language, a
different rasterizer, a different author -- so it disagrees exactly where the
specification was misread, which is the class of bug no self-consistent test
can see.

    zig build oracle
    python3 tools/check_oracle.py tests/oracle zig-out/oracle

The size each fixture is rendered at comes from `manifest.txt`, which
`tools/oracle.zig` writes beside the PNGs, and is passed straight to resvg.
resvg's `--width` and `--height` are a box to *fit* rather than a size to
produce, so a square box and a document twice as wide as it is tall give a
picture half the height asked for; taking both numbers from the manifest is
what keeps the two sides drawing the same picture.

What it is not is a pixel-for-pixel comparison, and it must not pretend to be.
Two correct rasterizers disagree along every antialiased edge: resvg's tiny-skia
computes exact analytic coverage, z2d multisamples at 4x, and a curve flattened
to a different tolerance puts its vertices in different places. So the test is
of the *shape* -- how far the two pictures are apart on average, and how much of
the picture is more than a little apart -- with the thresholds chosen from what
the corpus actually measures and written down below, so that a regression moves
a number somebody can see rather than flipping a boolean.

A fixture named in `DIVERGENCES` is held to its own tolerance and printed as
"diff" rather than "ok", because it is a place where the two renderers really
do disagree and the disagreement has been argued rather than absorbed. The
reason is written beside the entry.

A fixture this renderer refuses produces no PNG. That is reported as "not
implemented" and is not a failure: the corpus deliberately holds documents that
are on the feature list, and a missing feature should read as a missing feature
rather than as a broken renderer. `--strict` makes them failures, which is what
to use when the list is meant to be empty.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

from PIL import Image

# What two correct rasterizers are allowed to disagree by.
#
# Both are measured over the alpha-composited picture, on a scale where 255 is
# the whole range of a channel.
#
#   mean:     the average absolute difference over every channel of every
#             pixel. Antialiasing differences live on edges, which are a small
#             fraction of any picture, so this stays near zero even when the
#             edges differ visibly.
#   outliers: the fraction of pixels differing by more than `outlier_level` in
#             any channel. This is the one that catches a curve flattened
#             wrongly or an arc swept the wrong way round: those move an area,
#             not an edge.
#
# The numbers are set from what the corpus measures with about five times the
# headroom, rather than at some round figure. Across the 26 fixtures the worst
# mean is 0.089 and the worst outlier fraction is 0.050%, both on a document
# whose whole outline is curved; most of the corpus is an order of magnitude
# below that. Leaving the thresholds at a comfortable 1.5 and 2% would let an
# arc sweep the wrong way round and still pass.
MEAN_TOLERANCE = 0.5
OUTLIER_LEVEL = 32
OUTLIER_FRACTION = 0.0025

# Fixtures where this renderer and resvg are *both* doing what they meant to,
# and the numbers above are the wrong yardstick.
#
# Each entry is a deliberate, argued exception with the measurement it was set
# from, not a threshold raised until something passed. Anything not named here
# is held to the tolerances above, so a new disagreement still shows up as a
# failure rather than disappearing into a blanket allowance.
#
# The first five are `<filter>`, and they are here for two separate
# reasons; the rest each carry their reason beside them.
#
# **The kernel.** §15.17 defines `feGaussianBlur` as a Gaussian and then offers
# an approximation -- "the implementation *can* approximate the Gaussian blur
# with three successive box-blurs". This renderer convolves the Gaussian
# itself; resvg's kernel was measured against an impulse and is an
# infinite-impulse-response approximation, noticeably more peaked than a
# Gaussian below about `stdDeviation` three and indistinguishable from one
# above it. Two approximations of the same curve differ by a level or two
# across the whole of a blurred area rather than along an edge, which is
# exactly the shape of disagreement a mean tolerance tuned for antialiasing
# does not fit.
#
# **The region edge.** §15.7.5 makes the filter region "a hard clip" on the
# filter's input and its output. Clip the input, convolve, clip the output:
# at the region's boundary the result is half the kernel's weight, and that is
# what this renderer draws. resvg draws the square of that -- measured at
# 77/255 where a convolution gives 140/255, and matching `blur(source) x
# blur(region)` to within a level across the whole profile. That product is
# not a linear operator, and `feGaussianBlur` is defined as a convolution,
# which is; so this is one of the places where the oracle is the one that is
# wrong, and the fixture is kept to record it rather than reshaped to hide it.
DIVERGENCES = {
    "filter-blur": (1.2, 0.0025, "region-edge clip, and the blur kernel"),
    "filter-linear": (1.5, 0.0025, "blur kernel, in linearRGB"),
    "filter-srgb": (1.5, 0.0025, "blur kernel, in sRGB"),
    "filter-region": (4.0, 0.09, "region-edge clip, which this fixture exists to exercise"),
    # A blur on a `<use>`, which is there to prove the filter reaches the
    # group a `<use>` is drawn as; the whole of its difference is the kernel,
    # at a `stdDeviation` of one where resvg's is most peaked. Measured at
    # 0.375 and 0.25% -- the same `<use>` with a mask or a clip instead is
    # exact to a level.
    "use-filter": (0.6, 0.005, "blur kernel, on a <use>"),
    # One `<image>` fixture. The rest match resvg to a level: pictures are
    # sampled with Mitchell's cubic, which is what resvg draws them with, and
    # z2d's pre-multiplication rounds rather than truncating, which is what
    # used to darken every translucent pixel by a level or so.
    #
    # This one is where the two renderers do different things on purpose. A
    # picture drawn at less than half its size is halved first here, and is
    # not by resvg, which samples it directly and aliases: the ninety-six-pixel
    # rings drawn at thirty-two are a strong moire in resvg's picture and a
    # faint one in this one. The one place resvg is the worse picture, and so
    # the one entry with outliers to allow for. Measured at 0.972 and 1.556%.
    "image-downscale": (1.5, 0.025, "a box prefilter where resvg has none, so resvg aliases"),
    # A `<tspan>` holding nothing but a space, between two letters. SVG 1.1
    # §10.15's default `xml:space` collapses the characters of the whole
    # `<text>`, and that space is one of them, so "d e" is two words -- which
    # is what this draws and what browsers draw. resvg drops a text node that
    # is only whitespace and draws "de". The whole of the difference is the
    # "e" sitting one space further right. Measured at 7.187 and 3.259%.
    "text-space-only-tspan": (8.0, 0.04, "a whitespace-only run is a space; resvg drops it"),
    # `feColorMatrix type="saturate"` above one. SVG 1.1 gave the value a
    # range of zero to one; Filter Effects 1 lifted the top, and a value past
    # it oversaturates -- which is what this draws and what browsers draw.
    # resvg still clamps to one, and draws the input unchanged. Measured at
    # 4.108 and 9.440%.
    "filter-color-matrix-saturate-over": (4.5, 0.10, "saturate above one oversaturates; resvg clamps it to one"),
    # `feComposite operator="lighter"`, which Filter Effects 1 added: the two
    # inputs summed. resvg does not know the operator and draws `over`, which
    # is what SVG 1.1 made the default. Measured at 1.213 and 2.865%.
    "filter-composite-lighter": (1.5, 0.035, "lighter is a sum; resvg does not know it and draws over"),
    # `feTile` in linearRGB. resvg's `apply_tile` labels what it makes as
    # sRGB whatever space its input was in, so a tile of linearRGB pixels is
    # never converted back and comes out dark -- the same filter with
    # `color-interpolation-filters="sRGB"`, `filter-tile`, agrees to a
    # fraction of a level. Measured at 15.386 and 27.083%.
    "filter-tile-linear": (16.0, 0.28, "resvg labels a tile sRGB whatever its input was, and never converts it back"),
    # `feMorphology`. §15.18's window is centred on the pixel, `2r+1` wide,
    # as Skia's is. resvg's is `2*ceil(r)` wide and reaches one pixel further
    # left and up than right and down, so everything it erodes or dilates is
    # a pixel out along two of its four edges. Measured at 1.881 and 1.900%.
    "filter-morphology": (2.2, 0.022, "resvg's window is 2*ceil(r) wide and off centre by a pixel"),
    # `feDisplacementMap` with a `scale` other than one. §15.15 fetches from
    # `scale * (C - 0.5)` away; resvg multiplies by `scale` twice -- once in
    # `scale_coordinates` and again in `displacement_map::apply` -- so it
    # displaces by the square of the scale. Measured on a one-pixel canvas,
    # `scale="4"` moves a half-red map's content eight pixels where the
    # formula gives two. `filter-displacement-map`, at a scale of one where
    # the two agree, matches to a level. Measured at 48.113 and 40.975%.
    "filter-displacement-map-scale": (50.0, 0.42, "resvg displaces by the square of the scale"),
    # `feTurbulence stitchTiles="stitch"`. §15.23 stitches across the
    # primitive subregion in user space. resvg hands the reference code the
    # current pixel's index as the tile's origin and the region's width in
    # pixels as its width, while the noise itself is sampled in user units,
    # so its frequencies are nudged for the wrong tile and its wrap point
    # moves with every pixel. The same noise unstitched, `filter-turbulence`,
    # agrees to a few levels. Measured at 15.500 and 26.615%.
    "filter-turbulence-stitch": (16.5, 0.28, "resvg stitches a tile measured in pixels from the current pixel"),
    # A coloured `lighting-color` in linearRGB. §15.14 takes it into the
    # filter's colour space as `flood-color` is taken, and resvg converts a
    # flood's colour but not a light's, so its light is the sRGB bytes read
    # as linear and comes out washed pale: the same colour lit straight
    # overhead beside the same colour flooded draws (229,168,122) and
    # (200,100,50) in resvg, and (200,100,50) twice here. Every light in
    # `filter-lighting` that is not white runs in sRGB and agrees. Measured
    # at 28.500 and 50.000%.
    "filter-lighting-color-linear": (30.0, 0.51, "resvg does not convert lighting-color into linearRGB, as it does flood-color"),
    # `feDropShadow`, twice. The primitive is the blur, offset, flood and
    # merge it abbreviates, and `filter-drop-shadow`, that chain written
    # out, agrees; so does the first shadow here, which is the same one.
    #
    # The other two blur at a small `stdDeviation`, one of them `1` on an
    # axis, where resvg's recursive blur is most peaked -- the blur kernel
    # entry above. All of the difference is in the shadows' faint tails.
    # Measured at 0.689 and 0.040%.
    "filter-drop-shadow-primitive": (0.9, 0.001, "blur kernel, in a shadow"),
    # And in sRGB, resvg takes a drop shadow's colour through
    # `into_srgb` -- a conversion from linearRGB -- when the colour was
    # sRGB all along, so crimson's shadow is drawn (239,79,133), which is
    # crimson converted from linear, rather than (220,20,60). In linearRGB,
    # its default, it converts the right way. Measured at 2.570 and 5.263%.
    "filter-drop-shadow-srgb": (2.8, 0.055, "resvg converts an sRGB shadow colour as if it were linear"),
    # `feImage` naming an element. Filter Effects 1 draws it "according to
    # the behavior of the use element", in the filtered element's user
    # space, and the subregion only cuts it: a circle at (16,16) under a
    # region from y=20 shows its bottom edge. resvg translates what it draws
    # to the subregion's corner and so draws the whole circle eight units
    # right and twenty down. `filter-image-element`, whose region starts at
    # the origin where the two come to the same thing, agrees. Measured at
    # 12.109 and 7.963%.
    "filter-image-element-offset": (13.0, 0.085, "resvg draws an feImage element from the subregion's corner, not user space"),
    # The CSS filter functions that blur: `blur()` and `drop-shadow()`. Every
    # colour and every offset agrees; what differs is the blur kernel, as in
    # the entries above, a level or four across the whole of a large blurred
    # area rather than along an edge. (The shadows are black on purpose: a
    # coloured `drop-shadow()` meets the sRGB conversion recorded for
    # `filter-drop-shadow-srgb`, since functions always run in sRGB.)
    # Measured at 1.396 and 0.549%.
    "filter-functions-spread": (1.6, 0.006, "blur kernel, in blur() and drop-shadow()"),
    # Text on a `<textPath>`. Every glyph is where resvg puts it to within
    # half a pixel, the two agreeing on the whole run's centre of ink to a
    # hundredth, but no closer: resvg finds each glyph's point on the path with
    # kurbo's `inv_arclen` at an accuracy of half a user unit over the canvas
    # scale (`collect_normals`, text/layout.rs), a quarter of a unit here,
    # and even a straight line goes through that solver as a cubic whose
    # control points sit at 0.33 and 0.66 rather than thirds. The same text
    # laid glyph by glyph on a straight baseline agrees to a level. Measured at
    # 1.304 and 1.074%.
    "text-spacing-on-path": (1.5, 0.012, "resvg places glyphs on a path only to a quarter of a unit"),
    # A text decoration under `paint-order: stroke`. This paints a decoration
    # in its text's order, stroke and then fill; resvg paints every
    # decoration fill then stroke whatever the order says, so under a stroke
    # wider than the band its underline is solid stroke colour where this one
    # shows the fill down its middle. SVG 2 leaves the question open. Part of
    # the measurement is the glyphs' own 1.5-unit stroke, where the two
    # strokers already differ at the joins by about 0.7 on their own.
    # Measured at 1.920 and 1.543%.
    "text-decoration-paint-order": (2.1, 0.017, "resvg paints a decoration fill then stroke, whatever paint-order says"),
    # Three marker fixtures, each where resvg departs from §11.6 and from
    # Firefox's marker code, and each kept apart from the fixtures that agree
    # so that those still hold markers to the ordinary tolerance.
    #
    # An arc is one path command, so it makes one vertex and gets no
    # `marker-mid` along its length. resvg turns arcs into cubics before it
    # places markers, and puts one on every join between them: here a square
    # at the top of the half circle that the document never asked for.
    # Measured at 1.370 and 1.050%.
    "marker-arc": (1.6, 0.012, "resvg marks the joins of the cubics an arc became"),
    # A closed subpath's first vertex faces the bisector of the closing
    # segment and the first one, at its start and again at the `Z` that
    # returns to it. resvg faces the start along the first segment and the end
    # along the closing one, so each corner marker points a different way.
    # Measured at 2.411 and 2.635%.
    "marker-closed": (2.7, 0.029, "resvg does not bisect at a closed subpath's start"),
    # §11.6.2 clips a marker whose `overflow` is hidden to its viewport,
    # `markerWidth` by `markerHeight`; a `slice` fit overhangs that, and is
    # cut to it here. resvg clips to the `viewBox` instead, and draws the
    # whole overhang. Measured at 14.509 and 7.807%.
    "marker-viewbox-clip": (15.5, 0.085, "resvg clips a marker to its viewBox, not its viewport"),
}


def render_reference(resvg, svg_path, png_path, width, height):
    """Render one fixture with resvg, at exactly the size we rendered it.

    The text fixtures are drawn with one font, and resvg is given that same
    file and told to ignore the ones installed on the machine. Otherwise the
    two renderers would be drawing different faces, and the comparison would be
    measuring the faces rather than the rendering -- and it would pass or fail
    depending on which fonts the machine happened to have.
    """
    argv = [resvg, "--width", str(width), "--height", str(height)]
    font = os.environ.get("SVG_TEST_FONT")
    if font:
        # `--skip-system-fonts` alone is not enough: resvg's default family is
        # still "Times New Roman", so a fixture that names no `font-family`
        # finds nothing and draws nothing at all. The loaded face has to be
        # named as the default as well, which is what the resolver on our side
        # does by answering every request with the same face.
        argv += [
            "--skip-system-fonts",
            "--use-font-file", font,
            "--font-family", os.environ.get("SVG_TEST_FONT_FAMILY", "DejaVu Sans"),
        ]
    argv += [str(svg_path), str(png_path)]
    subprocess.run(argv, check=True, capture_output=True)


def read_manifest(path):
    """name -> (width, height), as tools/oracle.zig wrote it."""
    sizes = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            name, width, height = line.split("\t")
            sizes[name] = (int(width), int(height))
    return sizes


def compare(ours_path, theirs_path):
    """Return (mean difference, outlier fraction, worst pixel) for two PNGs."""
    ours = Image.open(ours_path).convert("RGBA")
    theirs = Image.open(theirs_path).convert("RGBA")
    if ours.size != theirs.size:
        raise ValueError(f"{ours.size} against {theirs.size}")

    # Composited onto white before comparing. A transparent pixel carries no
    # colour, so two renderers can write different RGB under alpha zero and be
    # identically correct; compositing makes the comparison about what a person
    # would see rather than about what is in the buffer.
    a = Image.alpha_composite(Image.new("RGBA", ours.size, (255, 255, 255, 255)), ours)
    b = Image.alpha_composite(Image.new("RGBA", theirs.size, (255, 255, 255, 255)), theirs)

    pa = a.convert("RGB").tobytes()
    pb = b.convert("RGB").tobytes()

    total = 0
    outliers = 0
    worst = 0
    pixels = ours.size[0] * ours.size[1]
    for i in range(0, len(pa), 3):
        d = max(
            abs(pa[i] - pb[i]),
            abs(pa[i + 1] - pb[i + 1]),
            abs(pa[i + 2] - pb[i + 2]),
        )
        total += abs(pa[i] - pb[i]) + abs(pa[i + 1] - pb[i + 1]) + abs(pa[i + 2] - pb[i + 2])
        if d > OUTLIER_LEVEL:
            outliers += 1
        worst = max(worst, d)

    return total / (pixels * 3), outliers / pixels, worst


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=pathlib.Path, help="directory of .svg files")
    parser.add_argument("ours", type=pathlib.Path, help="directory of our .png files")
    parser.add_argument(
        "--reference",
        type=pathlib.Path,
        default=None,
        help="where to leave resvg's output (default: alongside ours, as NAME.resvg.png)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="treat a fixture this renderer refused as a failure",
    )
    args = parser.parse_args()

    resvg = shutil.which("resvg")
    if resvg is None:
        print("resvg is not on PATH; run this inside `nix develop`", file=sys.stderr)
        return 2

    manifest_path = args.ours / "manifest.txt"
    if not manifest_path.exists():
        print(f"{manifest_path} is missing; run `zig build oracle` first", file=sys.stderr)
        return 2
    sizes = read_manifest(manifest_path)

    reference_dir = args.reference or args.ours
    reference_dir.mkdir(parents=True, exist_ok=True)

    failures = []
    skipped = []
    checked = 0

    for svg_path in sorted(args.fixtures.glob("*.svg")):
        name = svg_path.stem
        ours_path = args.ours / f"{name}.png"
        if not ours_path.exists() or name not in sizes:
            skipped.append(name)
            continue

        width, height = sizes[name]
        theirs_path = reference_dir / f"{name}.resvg.png"
        render_reference(resvg, svg_path, theirs_path, width, height)

        mean, outlier_fraction, worst = compare(ours_path, theirs_path)
        mean_limit, outlier_limit, reason = DIVERGENCES.get(
            name, (MEAN_TOLERANCE, OUTLIER_FRACTION, None)
        )
        ok = mean <= mean_limit and outlier_fraction <= outlier_limit
        checked += 1
        label = "FAIL" if not ok else ("diff" if reason else "ok  ")
        print(
            f"{label} {name:<38} "
            f"mean {mean:6.3f}  outliers {outlier_fraction * 100:6.3f}%  worst {worst:3d}"
            + (f"   [{reason}]" if reason else "")
        )
        if not ok:
            failures.append(name)

    print()
    diverging = sum(1 for name in DIVERGENCES if name in sizes)
    print(
        f"{checked} compared against resvg, {len(failures)} beyond tolerance"
        + (f", {diverging} marked as known divergences" if diverging else "")
    )
    if skipped:
        print(f"{len(skipped)} not implemented: {', '.join(skipped)}")

    if failures:
        return 1
    if skipped and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
