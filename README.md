<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-svg

SVG rendering onto [z2d](https://github.com/vancluever/z2d) surfaces, for Zig
0.16. A document arrives as a byte slice and pixels come back as memory; the
library performs no I/O of its own — and because rendering is therefore a pure
function over memory, it can be run in a forked process that seccomp has
reduced to four system calls on Linux, or that Capsicum has cut off from
everything but its reply pipe on FreeBSD.

The API documentation is generated from the doc comments and published at
**<https://jeff.jcollie.page/zig-svg/>**.

```zig
const svg = @import("svg");

var surface = try svg.render(gpa, source, .{ .width = 64, .height = 64 });
defer surface.deinit(gpa);
```

or onto a surface you already have, inside a box you choose:

```zig
try svg.draw(gpa, &surface, source, .{ .x = 0, .y = 0, .width = 72, .height = 56 }, .{
    .fill = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },
});
```

A zero or negative width, height or radius draws nothing and is not an error —
`<rect/>` and `<circle r="-2"/>` are both simply empty, which is what resvg
does. A `stroke-width` of zero or less disables the stroke the same way.

`<use>` draws what it names, from anywhere in the document — including from
*after* the `<use>` itself, and through a chain of other `<use>` elements. It
takes its paint from where it stands rather than from where its target was
written, as §5.6 says, and folds its `x` and `y` into the transform. A
reference that names a file rather than a fragment is refused: fetching one is
exactly what being sans-I/O rules out, and it is the reason the renderer can be
put in a process that cannot open anything.

A `<use>` that draws something containing itself is `error.RecursiveUse`,
caught by noticing the target is already open rather than by waiting for a
depth limit — so it is reported the moment the loop closes, and the same target
used twice by two siblings is not mistaken for one.

An element in a **foreign namespace** is passed over rather than refused. An
Inkscape file's `<sodipodi:namedview>` is not SVG content and nothing is meant
to draw it; refusing it would refuse the file.

`fill="url(#g)"` and `stroke="url(#g)"` name a gradient the same way a `<use>`
names its target, so the tree resolves both. A gradient's numbers live in a
space of their own, and three things stack up to say where that space is — the
shape's transform, then the units mapping, then `gradientTransform` inside
that. `objectBoundingBox`, the default, makes them fractions of the shape's own
bounding box, which is why a gradient on a wide shape comes out stretched: the
space itself is stretched.

All three `spreadMethod` values are drawn. `pad` holds the end colours
outwards, `repeat` starts the gradient over, and `reflect` turns it around so
that tiles meet without a seam — three visibly different pictures, which is why
a fourth value is refused rather than taken as the default. The extend modes
they map onto were added to the z2d fork; all six fixtures covering them,
linear and radial and one with a focal point, match resvg exactly rather than
merely within tolerance.

`<pattern>` is a picture drawn once per cell of a lattice and then cut to the
shape. It is not a z2d pattern — z2d paints from a colour, a gradient or a
dither, and none of those is a picture — so it goes through the layer machinery
`<mask>` uses instead, and the tile's contents are drawn by the same code that
draws the document. A gradient inside a tile therefore works, and so does a
group, a clip, or another pattern.

Three properties of §13.3 decide that shape. `overflow` on a `<pattern>` is
`hidden`, so content running past a tile's edge is cut rather than appearing in
the neighbour — which means a tile needs a clip, and drawing one tile and
stamping it is not enough. `patternTransform`, and any rotation on the shape
itself, turn the lattice, so an axis-aligned stamp could not place the cells
anyway. And `patternUnits` and `patternContentUnits` default to *opposite*
systems: the tile is a fraction of the shape and the things inside it are in
user units. That last one is the trap — leaving the bounding-box scale in the
matrix puts the contents through it as well, and a `<rect width="4">` in a tile
a quarter the width of a 32-unit shape comes out 128 units across.

The clip is built only for a tile the contents actually leave, and that is not
an optimisation. Clipping content that was never going to overflow makes the
clip's edge and the content's edge the same edge, anti-aliased twice, and
multiplying one coverage by the other squares it: a half-covered pixel along
the tile boundary comes out a quarter covered. For the usual tile whose content
fills it, that is a pale fringe along every edge in the picture, and it took
`tests/oracle/pattern-transform-rotate.svg` from 0.553 to 0.224. Where a clip
*is* needed, the cells are summed rather than painted over one another, because
two anti-aliased half-covered edges composited together come to three quarters
where they should come to one.

`<textPath>` lays a run along a shape, each glyph turned to the tangent where
it sits and placed so that the **middle of its advance** is on the curve —
the middle rather than the start, because a glyph turned about its own left
edge leans away from the line it is meant to sit on. Distances along a Bézier
have no closed form, so the shape is flattened and the pieces added up.

**The oracle cannot judge it**, which is worth saying rather than leaving as a
gap in the corpus. On a straight path a `<textPath>` must draw exactly what the
same text drawn plainly does, and this renderer's two outputs are
*pixel-identical*; resvg's differ from each other by a mean of 1.247, which is
more than this project's whole tolerance. So a textPath fixture would be
measuring resvg's per-glyph placement against its own plain text more than it
would be measuring this. What covers it instead is that equivalence, and unit
tests over the arc-length machinery — the length of a flattened quarter circle,
the point and tangent at a distance, a distance off either end being a glyph
that is not drawn.

Drawing each cell rather than stamping one has a consequence worth naming: on a
densely patterned shape under a rotation, this and resvg genuinely differ.
resvg rasterises the tile into a pixmap and tiles that pixmap through the
matrix, so its edges are resampled; these are drawn analytically at each cell,
so they are *sharper*. The difference is a pixel's worth of alpha along every
edge, in both directions, and it is large enough on a fine rotated lattice to
run past the oracle's tolerance. The fixtures are sized so that what they
compare is placement and clipping rather than resampling, because the latter is
a difference this is on the right side of.

A `<text>` is a *sequence* of runs, not one string: every `<tspan>` inside it
is a run with its own properties, and the characters around them are runs too.
They share a pen that advances along the line, so a run with no position of its
own carries on from wherever the last one ended — which means the walk yields
them in document order and the renderer keeps the pen across them. `x` and `y`
on a run are absolute and start a new *chunk*; `dx` and `dy` shift the pen
without starting one.

That is what makes `text-anchor` the awkward one. It moves a whole chunk rather
than a run, so placing the *first* run of one means knowing the width of every
run in it — and those widths need the font, which the reader does not have. The
renderer measures the chunk by walking the `<text>` a second time, which is the
same trick a clip in bounding-box units uses to measure a group. That second
walk has to read the `<text>`'s own `font-size` and `font-family`, which is why
it is `Document.textRuns` and not `Document.subtree`: the latter deliberately
ignores the root's attributes, which is right for a `<clipPath>` and wrong
here, and measuring without them measures at the default size — a ratio wrong,
not a rounding.

Each run is drawn as an ordinary path. z2d hands back the glyph outlines and
everything after that treats them like any other geometry, which is why text
can be stroked, clipped, masked and filled with a gradient or a pattern without
a second set of routines that would drift from the first —
`tests/oracle/text-as-clip.svg` cuts a rectangle to the letters of a word.

**Fonts are the caller's to supply**, through `Options.fonts`. Choosing a face
from a family name means a font database, which means a filesystem, and the
filesystem is exactly what the sandbox exists to take away — so this library
never looks for one. The resolver is offered each name in the `font-family`
list in turn, and then asked for its default; a family nothing answers to falls
back to that default, because naming a font the machine does not have is the
ordinary case rather than the exceptional one, and refusing would diverge from
every other renderer. A document with text and *no* resolver at all is refused
rather than drawn with the words missing.

The resolver runs inside the sandboxed child, so it must answer out of memory
it already holds: one that opens a file dies of the seccomp filter. That is a
loud failure rather than a quiet one, but it is still a failure, and reading
the font files before the render is the caller's job.

Two things about placement were not guessable and are worth naming. A
`<text>`'s `y` is the **baseline**, and z2d places a run by the top of its em
box — one em above, because the glyph outline is reflected about the em box
rather than about the baseline. Getting that wrong puts every line one
font-size down the page, which looks like a plausible picture. And whitespace
is collapsed the way XML's default `xml:space` asks: text indented across
several lines in the source draws as one line, which is how documents are
actually written.

`em` and `ex` resolve against the `font-size` in force, which arrived with the
fonts: `1em` is that size and `1ex` is half of it, measured against resvg,
which does not read the font's x-height for `ex` either. The subtlety is the
*order*: `em` in any other length on an element means that element's own size,
while `em` in `font-size` itself means the **parent's** — so `font-size` is
read first and separately, and reading them in one pass would resolve one of
the two against the wrong number. Where no `font-size` is in force anywhere
they are still refused, because CSS's initial value is `medium` and browsers
make that 16 while resvg makes it 12, so picking one draws a picture the wrong
size in half the world.

A document is drawn at the size it says it is — its `width` and `height` if it
names them, its `viewBox`'s extent if not — unless the caller asks for
something else. `preserveAspectRatio` then decides how the one is fitted into
the other. A document with no `viewBox` at all behaves as though it had
`viewBox="0 0 width height"`: its user units *are* pixels at the size it claims
to be, so drawing it larger scales it.

Percentages are of the viewport the `viewBox` establishes, not of the size the
picture is drawn at, and which measure depends on what the attribute measures —
`width` and `cx` of its width, `height` and `cy` of its height, and `r` and
`stroke-width` of §7.10's normalized diagonal.

**`em` and `ex` are refused.** Both are a multiple of a font size, and there is
no font here and no right answer for what it would be: CSS's initial
`font-size` is `medium`, which browsers make 16 pixels and resvg makes 12, so
`10em` is 160 pixels in a browser and 120 in the oracle this library is checked
against. Either choice draws a picture the wrong size somewhere. They arrive
with text.

`opacity` on a `<g>` or on the root is a **group** opacity, and is drawn as
one: the container goes into a surface of its own, that surface's alpha is
multiplied by the opacity, and the result is painted down once. Multiplying it
into each shape instead would be wrong the moment two shapes overlap — each
would show through the other where the group shows only the upper one, and
`tests/oracle/opacity-group-vs-shape.svg` is the two side by side. The layers
are composited in float rather than integer precision, because each nested one
is another multiply rounded back into a byte and two of them put every pixel
about two levels off.

`clip-path` cuts an element — a shape or a whole group — to the union of a
`<clipPath>`'s shapes, using the same layer as group opacity with an alpha mask
in place of a uniform alpha. `clip-rule` is read as a property of its own
rather than as `fill-rule`: a document can fill nonzero and clip even-odd, and
reading one for the other cuts the wrong hole.

`mask` uses that same layer, and differs from a clip in one thing: the
`<mask>`'s content is drawn as an ordinary picture and then each pixel's
**luminance** becomes its alpha. A clip asks where its shapes are, a mask asks
how bright they are — so white masks nothing away, mid-grey halves what is
under it, and a gradient from black to white is a fade. Because the content is
drawn by the same code that draws the document, a mask is as expressive as the
picture: a gradient inside one gets its bounding box, a `<g opacity="0.5">`
inside one masks half as much, and a clip inside one gets cut.

Two things make that luminance pass exact rather than approximate. The surface
holds **premultiplied** colour, and luminance is linear, so the luminance of
the premultiplied channels is already the luminance times the alpha — which is
the product §14.4 asks for, with no demultiply to round through. And the
coefficients go on the bytes **as stored**: SVG 1.1's `color-interpolation-filters`
would have them linearized first, and resvg does not, which measuring says
plainly — `#808080` masks to an alpha of 128 where a linearized one would give
55. This follows resvg, and a fixture pins it.

`mask-type="alpha"` asks for the content's opacity instead of its brightness,
and is implemented because resvg implements it; a spelling that is neither is
refused rather than falling back to luminance, which would draw a mask the
document did not ask for. It is a presentation property like any other, so it
comes through the cascade: the attribute, `style="mask-type:alpha"`, and a
`mask-type` declaration in a `<style>` rule all reach it.

`maskUnits` and `maskContentUnits` are both implemented, as is
`clipPathUnits="objectBoundingBox"`, and all three needed the same thing: the
bounding box of the element being clipped. For a shape that is its own
geometry, before its own `transform` and without its stroke, which §7.11
defines and a gradient already wanted. For a **group** it is the union of
everything inside, which is found by walking the group's subtree from the
identity — the same walk the renderer uses, rooted elsewhere, which puts every
shape it yields in the group's own user space. It costs a walk and a rebuild of
every path under the element, so it is asked for only when some `…Units`
attribute actually says `objectBoundingBox`, and asked for once per element
however many of them say it.

A `transform` on the `<clipPath>` element itself applies, and a `transform` on
a `<mask>` element does not — §14.3 gives the first one and §14.4 gives the
second nothing, resvg agrees, and `tests/oracle` pins both halves, because an
asymmetry nobody expects is exactly the one that rots.

A `<clipPath>` may carry a `clip-path` of its own and a `<mask>` a `mask` of
its own, and then the result is the intersection. Those are read off the tree
rather than by the walk, which never visits either element as somebody's child;
`Limits.max_mask_depth` bounds the recursion, because a mask naming *itself* is
a cycle the walk cannot see — each level starts a fresh walk that is perfectly
finite on its own.

**`<filter>` applies to what an element *drew*, not to what it is.** It takes
the picture the element would have produced, puts it through a chain of image
operations, and draws the result instead. That is why it costs no new idea
here: the element is already drawn into a surface of its own for group opacity,
and a filter is one more thing that happens to that surface between painting it
and compositing it down. §15 orders that carefully — the filter
runs first, and the element's `clip-path`, `mask` and `opacity` then apply to
what the filter produced rather than to what it read.

`feGaussianBlur`, `feOffset`, `feFlood`, `feMerge`, `feColorMatrix`,
`feComponentTransfer`, `feComposite`, `feBlend`, `feTile`, `feMorphology`,
`feConvolveMatrix`, `feDisplacementMap`, `feTurbulence`, `feDiffuseLighting`,
`feSpecularLighting`, `feDropShadow` and `feImage` are implemented, with `in`,
`result`, `SourceGraphic` and `SourceAlpha` wiring them together. Any other `fe`
element is **refused**, because a chain with a link missing is not the picture
the document asked for.

The two colour primitives work on colour with the alpha divided out, as §15.10
and §15.11 define them, so a matrix with a constant in its alpha row can light
up pixels that were transparent — anywhere in the primitive's subregion, not
only where its input drew. `saturate` above one oversaturates, as Filter
Effects 1 allows and browsers draw; resvg still clamps it to one, and the
fixture that shows it is a recorded divergence. A matrix with the wrong number
of `values`, a negative `saturate`, and a transfer function with no `type` or
an unknown one are refused, where resvg quietly draws the identity.

`feComposite` has §15.12's operators and Filter Effects 1's `lighter`, which
resvg does not know and draws as `over`. `feBlend` has every mode of
Compositing and Blending Level 1. The four non-separable ones — `hue`,
`saturation`, `color` and `luminosity` — follow that specification's
ClipColor, which pulls a colour pushed below black back towards its
luminance; resvg's tiny-skia tests the wrong channel there and clamps it to
black instead, which its fixture measures at up to fifty levels. An unknown
operator or mode is refused rather than drawn as the default.

`feMorphology`'s window is centred and `2r+1` pixels wide, the radius rounded
to whole pixels, as Skia's is; resvg's is `2⌈r⌉` wide and a pixel off centre,
which is a recorded divergence. A radius of zero or less passes the input
through, as Filter Effects 1 says, where resvg makes it one. `feTile`
replicates its input's subregion across the whole filter region unless it
names a subregion of its own; resvg forgets the colour space of a tile, so the
linearRGB case is a recorded divergence and the sRGB one agrees.

`feConvolveMatrix` has all three edge modes, `preserveAlpha`, and a bias scaled
by alpha, and agrees with resvg to the level. Its kernel is at most
`filter.max_convolve_order` (16) on a side, so that one primitive costs at
most 256 multiplications a pixel. A kernel of the wrong length for its order
passes the input through and a divisor of zero means the default, both as
Filter Effects 1 says; a bad order, target or keyword is refused.
`kernelUnitLength` is ignored, as it is in resvg: the kernel steps one pixel
of the canvas.

`feDisplacementMap` reads its map with the alpha divided out, as §15.15 says,
and fetches the nearest pixel, as resvg does. resvg multiplies by `scale`
twice and so displaces by its square; the fixture at a scale of one agrees to
a level and the one at six is a recorded divergence.

`feTurbulence` is the reference code §15.23 gives, ported line for line —
generator, lattice, gradients and stitching — because any other noise is a
different picture; it agrees with resvg to a few levels. Each pixel is sampled
at its corner taken back into user space. Stitching tiles the noise across the
primitive subregion in user space, as the specification says; resvg measures
that tile in pixels from the current pixel, which is a recorded divergence.
`numOctaves` above 24 is taken as 24, which changes no pixel: past about nine,
an octave adds less than one level.

`feDiffuseLighting` and `feSpecularLighting` take the input's alpha as a
surface, with §15.14's normals at every edge and corner, and light it with a
distant, point or spot light; they agree with resvg to a level or so. Light
positions go through the matrix in force and a height is scaled by the
matrix's diagonal over the square root of two, as Filter Effects 1 says.
`lighting-color` is taken into the filter's colour space as `flood-color` is;
resvg converts a flood's colour but not a light's, which is a recorded
divergence for a coloured light in linearRGB. A lighting primitive with no
light source, a negative constant or a `specularExponent` outside 1 to 128 is
refused.

`feDropShadow` is run as the chain Filter Effects 1 defines it by — the
input's alpha blurred, offset and flooded with the shadow's colour, and the
input merged over it — and agrees with that chain written out. resvg takes an
sRGB shadow's colour through a conversion from linearRGB, which it never was,
and so draws it pale; that is a recorded divergence.

`feImage` draws a picture, fetched and decoded as an `<image>`'s is — the
same cache, budgets and resolver — and fitted into the primitive subregion by
`preserveAspectRatio` and `image-rendering`. Or it draws an element of the
document, as a `<use>` of it would, in the filtered element's user space as
Filter Effects 1 says, cut by the subregion; resvg draws it from the
subregion's corner instead, which is a recorded divergence. An element that
filters itself through its own `feImage` is bounded by `Limits.max_mask_depth`,
and a reference to nothing draws nothing.

**A filter runs on the canvas, not in user space.** A `stdDeviation` in user
units becomes a standard deviation in device pixels by the scale of the matrix
in force, and the rotation in that matrix is deliberately *not* carried: a
horizontal blur under `rotate(45)` blurs along the screen's horizontal, not the
element's. That is what resvg does, what browsers do, and the reason the filter
region is an axis-aligned rectangle of the canvas rather than a rotated one.

**It runs in linearRGB.** §15.3 makes that the default, and it is the surprise
in the whole element: blurring the boundary between white and black gives a
midpoint of 188, not 128, because the average is taken of the light rather than
of the numbers. `color-interpolation-filters: sRGB` switches it off, per
primitive. Getting this wrong is worth about seventy levels in the middle of
every gradient a filter touches. Note that it is *not* used for the luminance
of a `<mask>`, where this follows resvg in leaving the bytes alone — the two
neighbouring decisions genuinely go opposite ways, and each has a fixture.

**A filter naming nothing draws nothing.** §15.7.1 makes a `filter` pointing at
a missing id, at an element that is not a `<filter>`, or at a filter with no
primitives mean that *the element is not rendered* — not that the filter is
skipped. It is one of the few places in SVG where a dangling reference is
defined rather than an error, and resvg agrees.

`filterRes` is ignored, which resvg does too. It is a deprecated request to run
the filter at a lower resolution and scale the result up, it was dropped from
Filter Effects 1, and ignoring it draws a *sharper* picture than the document
asked for rather than a wrong one.

A `style` attribute is read, and outranks the presentation attribute of the
same name — `fill="red" style="fill:blue"` is blue. It matters more than its
size suggests: every drawing program writes it, so Inkscape, Illustrator and
Figma documents use `style` where a hand-written one would use attributes, and
a renderer that skips it renders a large part of the world's SVG in the wrong
colours. That is what it did here until it was tested, and it did it *silently*
— which is the failure this library is meant not to have.

Values go to the same parsers the attributes use, so `style="fill:wobble"` is
refused exactly as `fill="wobble"` is. A malformed declaration is skipped and
the ones after it are still read, which is CSS 2.1 §4.2 and what browsers do;
resvg stops at the first one, so `style="nonsense;fill:blue"` is blue here and
black there.

**A `<style>` element is the rest of §6**, and the selectors it needs are CSS
2's: `*`, a type name, `.class`, `#id`, `[attr]` with the three CSS 2
operators, in any combination; the four combinators ` `, `>`, `+` and `~`; and
lists of those. A type name is matched case-sensitively, because this is XML
and `RECT` is not `rect`. Every `<style>` in the document is one sheet in
document order, which is what breaks a tie between two of them, and a
`<style>` whose `type` is not CSS is passed over because its content is not a
stylesheet at all.

The cascade is CSS 2.1 §6.4.3 with SVG 1.1 §6.4's addition, and written out
for the one origin a standalone SVG has it comes to five bands: an
`!important` `style` attribute, an `!important` rule, a `style` attribute, a
rule, and last of all a presentation attribute. Specificity orders within a
band and source order breaks the remaining ties. That order lives in exactly
one function, `css.property` — in a [library of its own][zig-css], because
none of it knows what a shape is — and **everything** that reads a presentation
property goes through it — the walk, a gradient's `stop-color`, a filter
primitive's `flood-color`, a `mask-type`. A property read any other way would
be one the cascade silently did not reach, which is the bug `style` itself had
here until it was implemented: `<stop style="stop-color:red">`, which is how
Inkscape writes every gradient it saves, was being ignored.

[zig-css]: https://git.jcollie.dev/jeff/zig-css

What is refused rather than skipped: at-rules, pseudo-classes, pseudo-elements,
namespace selectors, and the CSS 3 attribute operators. `@import` could not be
implemented here in any case — fetching a stylesheet is the I/O that being
sans-I/O rules out, exactly as it rules out `<use xlink:href="other.svg#x">`.

A **definition** is never drawn where it stands. A `<linearGradient>` or a
`<clipPath>` written straight into the document body rather than into `<defs>`
is passed over and still indexed, which §5.5 requires and which this used to
refuse — every gradient fixture had put them in `<defs>`, so the oracle never
saw it.

`fill` and `stroke` default differently, and deliberately. A shape naming no
`fill` gets the caller's colour; a shape naming no `stroke` is **not stroked**,
because SVG's initial `stroke` is `none` and a shape stroked without asking
would put lines in a picture the document does not have.

Groups nest, and carry both presentation attributes and a transform:

```xml
<svg viewBox="0 0 24 24" fill="crimson">
  <g transform="translate(4,4)" fill="steelblue">
    <path d="M0 0H8V8H0Z"/>                     <!-- steelblue, moved -->
    <path d="M0 0H8V8H0Z" transform="rotate(30)"/>
  </g>
  <path d="M12 12H20V20H12Z"/>                  <!-- crimson, not moved -->
</svg>
```

## Where this lives

The repository lives in four places that carry the same history. The Forgejo
instance at <https://git.jcollie.dev/jeff/zig-svg> is the web-visible one:

```console
$ git clone https://git.jcollie.dev/jeff/zig-svg.git
```

it is mirrored on Tangled at <https://tangled.org/jcollie.dev/zig-svg>, and it
is also on the Radicle network, where the repository's identifier is

```
rad:z2u6JeD6AUFAFSTYuG32WjsSivLnc
```

and `rad clone rad:z2u6JeD6AUFAFSTYuG32WjsSivLnc` fetches it from any node that
seeds it.

It is mirrored on GitHub at <https://github.com/jcollie/zig-svg> as well, for
one reason: GitHub has macOS and Windows runners, and the Forgejo runners are
all Linux. `.github/workflows/test.yaml` runs the tests and compiles every tool
on those two, where there is no sandbox and the library has to say so rather
than render unconfined; everything else the continuous integration does runs
on Forgejo, from `.forgejo/workflows/test.yaml`. Any of the four is the whole
project.

## What it draws

One `<svg>` carrying a `viewBox`, and any number of shapes inside it — `<path>`
and the five basic shapes — each filled and stroked in its own colours, under
its own transform, painted in document order. That is every one of the 7,447
[Material Design Icons](https://pictogrammers.com/library/mdi/), most other
icon sets, a good deal of hand-written and exported SVG, and still a long way
short of the specification.

| | |
| --- | --- |
| Path data — SVG 1.1 §8.3 | complete, every command in both spellings |
| Elliptical arcs — appendix F.6 | complete, including the degenerate cases |
| Several shapes | yes, painted in document order |
| `<rect>` | yes, including `rx`/`ry` rounded corners |
| `<circle>`, `<ellipse>`, `<polygon>`, `<polyline>` | yes |
| `<line>` | yes, and visible once stroked |
| `<g>` | yes, nested, with inherited attributes |
| `<use>`, `<defs>` | yes — `href` and `xlink:href`, forward references, chains |
| Nested `<svg>` | yes — its own viewport: `x`, `y`, `width`, `height`, `viewBox`, `preserveAspectRatio`, percentages of it, and a clip unless `overflow` is visible |
| `<symbol>` | yes, through a `<use>`, which sizes it — `viewBox`, `preserveAspectRatio` and `overflow` as a nested `<svg>` |
| `opacity`, `clip-path`, `mask`, `filter` on a `<use>` | yes — on the group §5.6 draws it as, with its `x` and `y` |
| `<linearGradient>`, `<radialGradient>` | yes, on `fill` and `stroke`, with `<stop>` and `href` inheritance |
| `gradientUnits`, `gradientTransform` | yes — both unit systems |
| `spreadMethod` | all three — `pad`, `reflect`, `repeat` |
| A foreign namespace | passed over, not refused — an Inkscape file reads |
| `transform` | all six functions, on `<svg>`, `<g>`, any shape, and a `<clipPath>` |
| `fill` | named colours, `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa`, `rgb()`, `rgba()`, `none`, `currentColor` |
| `fill-opacity`, `fill-rule`, `color` | yes, inherited through `<svg>` and `<g>` |
| `opacity` | yes, on a shape **and** on `<svg>` or `<g>`, as a composited layer |
| `stroke`, `stroke-width`, `stroke-opacity` | yes, inherited |
| `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit` | yes, inherited |
| `stroke-dasharray`, `stroke-dashoffset` | yes, inherited; up to `raster.max_dashes` (64) lengths |
| `paint-order` | yes, inherited — `fill`, `stroke` and `markers` in any order |
| `<marker>`, `marker-start`, `marker-mid`, `marker-end` | yes, inherited, on `<path>`, `<line>`, `<polyline>` and `<polygon>`; `marker` as the shorthand in CSS — `orient` (`auto`, `auto-start-reverse`, an angle), both `markerUnits`, `viewBox`, `preserveAspectRatio` and `overflow` |
| Markers in one document | to `Limits.max_markers` (16384), counted before any is drawn |
| `viewBox`, `width`, `height` | yes — the document's own size is what it is drawn at |
| `preserveAspectRatio` | all nine alignments, `meet`, `slice`, `none`, `defer` |
| Entity references in attribute values | yes, resolved as the document is parsed |
| `<title>`, `<desc>`, `<metadata>`, `<defs>` | passed over, and what is inside `<defs>` is not drawn |
| `<a>` | yes, drawn as a group — including inside `<text>`, where it carries its words |
| `<switch>` | yes — the first child whose conditions pass, so Illustrator's `<foreignObject>` wrapper falls through to the drawing |
| `systemLanguage`, `requiredExtensions`, `requiredFeatures` | yes, on any element — languages from `Options.languages` (default `en`), by §5.8.5's prefix rule; no extensions |
| `display` | yes — `none` removes an element and everything in it; any other value draws it |
| `visibility` | yes, inherited — `hidden` and `collapse` paint nothing but still take up room, and a `visible` child of a hidden group is drawn |
| Lengths | `px`, `pt`, `pc`, `mm`, `cm`, `in`, `%`, `em`, `ex`, and a bare number |
| Nesting depth | containers and `<use>` targets to `document.max_container_depth` (64) |
| Composited layers | to `Limits.max_layers` (8); each is a surface the size of the picture |
| Masks, clips and patterns inside one another | to `Limits.max_mask_depth` (4) |
| Tiles for one `<pattern>` | to `Limits.max_pattern_tiles` (16384) |
| `clip-path`, `clip-rule` | yes, on a shape or a group, and on a `<clipPath>` itself |
| `mask`, `mask-type` | yes — luminance or alpha; on a shape or a group, and on a `<mask>` itself |
| `clipPathUnits`, `maskUnits`, `maskContentUnits` | yes — both unit systems, including the bounding box of a group |
| `<filter>` | yes — `feGaussianBlur`, `feOffset`, `feFlood`, `feMerge`, `feColorMatrix`, `feComponentTransfer`, `feComposite`, `feBlend`, `feTile`, `feMorphology`, `feConvolveMatrix`, `feDisplacementMap`, `feTurbulence`, `feDiffuseLighting`, `feSpecularLighting` and the three light sources, `feDropShadow`, `feImage` of a picture or an element; any other `fe` element is refused |
| `filterUnits`, `primitiveUnits`, the filter region | yes — both unit systems, and §15.7.6 subregions |
| `color-interpolation-filters` | yes — linearRGB by default, per primitive |
| `filterRes` | ignored, as resvg ignores it |
| Definitions outside `<defs>` | yes — a gradient or clip path is never drawn where it stands |
| `<pattern>` | yes — `patternUnits`, `patternContentUnits`, `patternTransform`, `viewBox`, `href`, and `overflow` |
| `<text>`, `<tspan>` | yes — a sequence of runs, filled or stroked, and usable as a clip |
| `x`, `y`, `dx`, `dy` on a run | yes — `x`/`y` start a chunk, `dx`/`dy` shift the pen |
| `font-family`, `font-size`, `font-weight`, `font-style` | yes, inherited; the caller resolves the family |
| `text-anchor` | yes — `start`, `middle`, `end` |
| `rotate`, `textLength` | yes — `lengthAdjust="spacing"`, which is the initial value |
| `<textPath>`, `startOffset` | yes, including a percentage of the path's length |
| `em`, `ex` lengths | yes, against the `font-size` in force; refused when none is |
| `style` | yes — §6.3's declaration block, which outranks the attributes |
| `<style>` | yes — every one of them, as one sheet in document order |
| Selectors | `*`, type, `.class`, `#id`, `[attr]`, `[attr=v]`, `[attr~=v]`, `[attr\|=v]`; ` `, `>`, `+`, `~`; lists |
| The cascade | yes — §6.4's five bands, specificity, source order, `!important` |
| At-rules, pseudo-classes, namespace selectors | **no** — refused, not skipped |
| `<image>` | yes — a `data:` URL, or any other `href` the caller's `ImageResolver` answers |
| Picture formats | whatever [z2dimg](https://git.jcollie.dev/jeff/z2dimg) reads: PNG, JPEG, GIF, WebP, BMP, TGA, ICO, Netpbm, PCX, XBM, XPM |
| `width`, `height` on `<image>` | yes, including SVG 2's `auto` — the picture's own size, or what the other side implies |
| `preserveAspectRatio` on `<image>` | yes — the picture's own size stands in for a `viewBox` |
| `image-rendering` | yes, inherited — Mitchell's cubic by default, as resvg; nearest for `optimizeSpeed`, `pixelated`, `crisp-edges` |
| An SVG inside an `<image>` | **no** — `error.UnsupportedImageFormat` |
| Pictures decoded | to `Limits.max_images` (256) and `Limits.max_image_pixels` (2²⁴, reductions included) |

A shape that names no `fill` is painted in the colour the **caller** chose, not
in SVG's initial black. That is a deliberate difference and it is the whole
reason an icon can be drawn in any colour: not one of the 7,447 Material Design
Icons carries a `fill`, so under the letter of the specification the set could
only ever be black. `fill="currentColor"`, which many other icon sets use
instead, reaches the same colour by the honest route — it is the initial value
of the `color` property, and the caller chooses that too. A document that
*does* name a colour is drawn in the colour it names.

An element it cannot draw is **refused**, not skipped, and so is an attribute
value it cannot read. A renderer that skips what it does not understand
produces a picture quietly missing a piece, and one that falls back to black on
`fill="notacolour"` produces a picture that looks finished and is not — both
are the failure nobody notices, where `error.UnsupportedElement` and
`error.BadColor` are the failure somebody does. resvg and every browser default
instead; see [resvg as the oracle](#resvg-as-the-oracle) for where the two
deliberately part company.

The refusal happens while the document is *read*, before anything has been
painted, so an unsupported element at the end of a document is an error rather
than four shapes drawn and then an error. That is not a validating walk beside
the drawing one — it *is* the drawing one. `read` runs the same iterator the
renderer will, to the end, and throws the shapes away; `shape_count` is the
number that iterator produced rather than a number counted alongside it.

## Pictures

An `<image>` names its picture by URL. In a document meant to stand on its own
that URL is a `data:` one — RFC 2397, the bytes of a PNG or a JPEG written into
the attribute in base64, usually broken across lines — and needs nothing from
the caller: [zig-uri](https://git.jcollie.dev/jeff/zig-uri) reads the URL and
[z2dimg](https://git.jcollie.dev/jeff/z2dimg) decodes what it carries. Any other
`href` is handed to `Options.images`, which answers out of memory the caller
already holds, exactly as `Options.fonts` does for `<text>`; with no resolver,
or no answer, it is `error.UnresolvedImage` rather than a picture missing a
piece.

```zig
var surface = try svg.render(gpa, source, .{
    .images = .{ .ctx = &pictures, .resolve = Pictures.resolve },
});
```

What the bytes are is read from the bytes. The media type a `data:` URL claims
is not what chooses the decoder — z2dimg reads the signature, as a browser
does, and a PNG labelled `image/jpeg` is drawn as the PNG it is. The one claim
believed is `image/svg+xml`, which is refused by name: a document inside a
document is a render of its own rather than a decode.

The picture is fitted into the element's rectangle by §7.8's rule, with its own
pixel size standing in for a `viewBox`, and the rectangle is then filled with
the picture as paint — a `z2d.SurfacePattern` — so that its edge gets the same
anti-aliased coverage any shape's does. The pattern samples with Mitchell and
Netravali's cubic, B = C = 1/3, which is what Skia calls high-quality sampling
and so what resvg draws pictures with; the two agree to a level. It works on
premultiplied pixels, so transparency lends no colour to its neighbours, and a
picture drawn at its own size, however it is moved, is copied rather than
filtered. A picture drawn at less than half its size is halved first, as many
times as it takes, so that the filter never skips a pixel.
`image-rendering: optimizeSpeed` — or CSS's `pixelated` or `crisp-edges` —
samples the nearest pixel instead.

**Decoding happens while drawing, not while reading.** That is the one
exception to refusing before anything is painted: a picture is only worth
decoding once the document has been found drawable, and decoding it twice to
say so would double the most expensive thing in the render. So a broken
picture is refused part-way through. `render` frees its surface when it fails,
so no half-drawn picture escapes it; `draw` onto a surface the caller owns may
leave the elements before the `<image>` painted. Each picture is decoded once
per render and kept however many times a `<use>` or a pattern tile draws it.

No colour management: an ICC profile or a PNG `gAMA` is not applied and the
pixels are taken as sRGB, which is what resvg does. EXIF orientation is not
applied, and an animation — GIF, APNG or WebP — is drawn as its first frame.

Two walks kept in step by hand is what it was, and they drifted twice: once
where the reader knew a `<path>` inside `<defs>` was not a shape and the
iterator did not, and once where the reader parsed each `transform` but only
the iterator composed them, so a pair multiplying to an infinity passed
validation and failed while drawing. One walk cannot disagree with itself.

Each shape is filled on its own rather than built into one path and filled
once, which would be cheaper. Two overlapping subpaths wound in opposite
directions leave a hole under the nonzero rule; painted as two shapes the
second simply covers the first. Merging them would quietly choose the first
answer for a document that means the second — `tests/oracle/multi-overlapping-opposite-winding.svg`
is that document, and resvg agrees.

See [Features to come](#features-to-come) for what is next.

Strokes are painted after the fill, per shape, and warp correctly under a
transform:

```xml
<svg viewBox="0 0 32 32">
  <rect x="4" y="4" width="10" height="10" fill="gold" stroke="crimson" stroke-width="3"/>
  <polyline points="4,28 14,18 24,28" fill="none" stroke="indigo"
            stroke-width="2" stroke-linejoin="round" stroke-dasharray="4 2"/>
</svg>
```

A stroke is drawn twice over in a sense the code makes precise. The path is
built a second time with its subpaths left **open**, because a stroked open
subpath is capped at its ends rather than joined back to its start — that is
the one place the same `d` has to become two different node sets, and it is why
`path.Options.close_subpaths` is a decision rather than an invariant.

And the pen is scaled here rather than by z2d wherever the transform is a
*similarity* — a uniform scale with any rotation and translation. Such a matrix
maps a circle to a circle, so the two are equivalent in geometry, and the
similarity case stays exact rather than being derived from a matrix. Under a
genuinely warped transform there is no equivalent scalar, so the matrix goes to
z2d, which shapes the elliptical pen the specification asks for.

That used to be a compromise rather than a choice. z2d reverts the cap, join
and miter limit to their defaults for a thin line, and decided which lines were
thin by the *user-space* width — so `stroke-width="1"`, the initial value and
much the commonest one, lost its round caps however large the picture was
drawn, and a thin stroke under a warped transform lost them even with the pen
scaled here. The z2d this builds against decides that guard by the device width
instead, so both branches are right;
`tests/oracle/stroke-thin-warped-caps-and-joins.svg` is the case that used to
be wrong and now is not.

## Limits

Every number in a document is a number somebody else chose, and two of them —
the output size and the path length — decide what the render costs. `Limits`
bounds both, and the defaults are sized for a program drawing pictures for a
person to look at:

```zig
var surface = try svg.render(gpa, source, .{
    .limits = .{ .max_pixels = 1 << 20, .max_path_nodes = 4096 },
});
```

`max_path_nodes` is the one worth thinking about: a single `a` command with a
large sweep produces four cubic curves from a dozen characters, so a `d`
attribute is not proportional to the work it asks for. It is a budget for the
whole document rather than for each shape — per shape it would bound nothing,
since ten thousand `<path>` elements each just under the limit is the same
denial of service written out longhand. `max_shapes` covers what the node
budget cannot: an empty `d` produces no nodes and still costs a fill.

`max_image_pixels` bounds what the pictures cost. The encoded bytes are inside
the document and `max_input_bytes` bounds those, but a PNG of a few hundred
bytes can declare itself sixteen thousand pixels square and compress the lot to
nothing, so the decoded size needs a budget of its own — shared by every
picture in the document, and paid for again by each reduction made to draw one
small. `max_images` bounds the number of decodes, which a thousand one-pixel
pictures would otherwise get for free.

`max_markers` is the node budget's counterpart for markers: each vertex of
every marked path draws the whole of a `<marker>`'s content again, so a
polyline of a few thousand points is a few thousand drawings. The vertices are
counted before any marker is drawn, and a document past the budget is refused
whole rather than drawn part of the way. A marker drawn inside a marker counts
against `max_mask_depth`, and one met again inside itself — which a `marker`
property on a group around the `<marker>` does, since its content inherits from
there — draws nothing, as in resvg.

`max_layers` and `max_mask_depth` bound the *memory* rather than the work.
Every composited group, every clip and every mask is a surface the size of the
whole picture, so the ceiling is `max_pixels` times four bytes times how many
of them can be alive at once — which is what a sandboxed render's
`working_bytes` has to cover.

## A tree, not a stream

The document is read into a tree with
[ztree](https://git.jcollie.dev/jeff/ztree) rather than walked with a pull
parser. `<use href="#a">` is why: `#a` may be defined anywhere, including after
the `<use>` that names it, and `url(#gradient)` will want the same thing again.
A stream cannot answer that without either re-scanning the document per lookup
or carrying a stack of suspended parsers.

Three things come with it beyond the reference itself. Entity references are
resolved as the document is parsed, so nothing downstream thinks about `&#90;`.
Names are expanded, which is what lets a foreign-namespace element be *ignored*
rather than refused. And the walk's stack is small — a frame is a node id, an
index and the inherited state, so suspending one subtree to draw another costs
a couple of hundred bytes rather than a whole parser.

What it costs is that reading allocates and the `Document` owns what it read:
`read` takes an allocator and the result must be `deinit`ed. The source may be
freed the moment `read` returns, because every string in the tree is a copy —
which is a simpler lifetime than the borrowed slices it replaced.

## Sandboxing

`svg.sandbox.render` runs the renderer in a forked process that seccomp has
reduced to `write` — on one descriptor — plus `exit_group`, `exit` and
`rt_sigreturn`, and passes the pixels back through a shared `memfd`:

```zig
var image = try svg.sandbox.render(gpa, source, .{
    .render = .{ .width = 256, .height = 256 },
});
defer image.deinit();          // not surface.deinit — the pixels are a mapping
```

This matters more for SVG than for most formats. The full specification
*includes* fetching documents, running scripts and reading fonts, so a renderer
growing towards it grows towards exactly the capabilities the sandbox takes
away. A renderer subverted into opening a file, reaching the network or
spawning a program dies at the attempt, and a renderer that segfaults comes
back as `error.RendererCrashed` rather than as a dead program.

Before that filter goes on, four things are taken away from the child, none of
which needs permitting because all of it happens first. Its **inherited
descriptors** are closed: a forked child keeps everything the parent had, since
`CLOEXEC` means nothing to a process that never execs, and while a renderer
cannot *open* a socket under this profile, `write` is a call it has — so a
subverted one could put attacker-controlled bytes into a connection the parent
already had. The reply pipe is moved to a fixed number, everything above it is
closed, and `write` is then permitted on that descriptor and no other; the two
halves make each other worth having, since closing takes away what there is to
write to and the filter takes away the ability to name anything else. Then
**processor time** through `RLIMIT_CPU`, so a renderer stuck in a loop is
killed by the kernel rather than waited for; **core dumps** through
`RLIMIT_CORE`, so a crash cannot write the shared mapping out to disk; and
**dumpability** through `PR_SET_DUMPABLE`, which stops another process of the
same user attaching with `ptrace` to read that mapping.

Each is proved against the kernel rather than asserted: two children differing
only in the descriptor they write to, a child reporting through the one
descriptor it kept that the one it should not have is gone, and a child that
spins until the kernel ends it.

Pictures are decoded inside that child, by the same filter. z2dimg can decode
in a sandbox of its own and is not asked to: the render already has one, and a
second fork from inside it would be a sandbox in a sandbox that the first one's
filter refuses anyway. The decoders are handed a slice and an allocator and
make no system calls, which a test proves by decoding a PNG, a JPEG, a WebP and
a GIF under the strict profile. The shared mapping is reserved with room for
them: `max_image_pixels` at four bytes a pixel, on top of the picture and
`working_bytes`.

It does not make the pixels *trustworthy* — writing into the shared mapping is
the child's job. What the parent validates is the shape of the reply: that the
buffer is inside the mapping, correctly aligned, and exactly the length the
stated dimensions require.

### On FreeBSD

The same design, with [Capsicum](https://www.cl.cam.ac.uk/research/security/capsicum/)
in place of seccomp; the design came from [z2dimg](https://git.jcollie.dev/jeff/z2dimg),
whose decoders are sandboxed the same way. Capsicum is not a system call
filter. It takes away every global namespace at once when a process calls
`cap_enter`, so that no path can be opened, no address reached and no other
process signalled, and it limits each descriptor the process still holds to
the rights it was given. The child arrives at `cap_enter` holding exactly this:

| descriptor | rights |
| --- | --- |
| the reply pipe | `CAP_WRITE` |
| standard input, output and error, under `strict` | none |

— everything else having been closed with `closefrom`, exactly as on Linux.
The shared mapping is anonymous rather than a `memfd`, so there is no
descriptor behind it to inherit at all.

Capsicum's own answer to a forbidden call is an error, which would leave a
subverted renderer looking like one that failed quietly. `PROC_TRAPCAP_CTL`
turns that error into a `SIGTRAP`, so a refused call ends the child and the
parent reports `error.SandboxViolation`, as it does for `SIGSYS` on Linux.
`PROC_TRACE_CTL` stands in for `PR_SET_DUMPABLE`, though a process may turn its
own tracing back on, which the seccomp filter leaves no way to do; that helps
only another process of the same user already waiting to attach, and such a
process could attach to the parent instead.

**What it does not refuse that seccomp does.** Capsicum permits `fork`, which
names nothing global. The child sets `RLIMIT_NPROC` to zero, which refuses
`fork` to any user but root, so a program rendering as root has only
capability mode between a subverted renderer and a fork bomb. It also permits
the long tail of calls that touch only the process itself — `getpid`,
anonymous `mmap`, `sigaction` — none of which reaches anything outside.

The same tests run on both. On FreeBSD they were run by cross-compiling
`zig build test -Dtarget=x86_64-freebsd` and running the test executables in a
FreeBSD 14.5 virtual machine as an unprivileged user — root is exempt from
`RLIMIT_NPROC`, so testing as root would test less. Everything passes there
but the three tests that are claims about seccomp's filter alone, which skip;
and `svgdump --sandbox` draws the same bytes there as unsandboxed, and as on
Linux.

### Elsewhere

64-bit Linux and 64-bit FreeBSD only. `svg.sandbox.available` says so at
compile time, and `render` returns `error.SandboxUnavailable` at run time
rather than silently rendering unsandboxed — a security feature that quietly
turns itself off is worse than one that was never there. On macOS or Windows,
render with `svg.render` and decide for yourself what isolation the program
around it needs.

## resvg as the oracle

A library's own tests can only check it against itself: they would agree with a
mistake the parser and the rasterizer shared. So the corpus in `tests/oracle`
is rendered both by this library and by [resvg](https://github.com/linebender/resvg),
an independent implementation of the same specification, and the two pictures
are compared.

```console
$ zig build oracle
$ python3 tools/check_oracle.py tests/oracle zig-out/oracle
ok   arc-rotated-ellipse     mean  0.033  outliers  0.008%  worst  64
...
86 compared against resvg, 0 beyond tolerance
```

Each fixture is rendered at the size the **document** says it is — its own
`width` and `height`, or its `viewBox`'s extent — scaled so the longer side is
256, and that size is written to `manifest.txt` beside the PNGs for resvg to be
given verbatim. Driving it from the document is what makes `preserveAspectRatio`
testable at all: a fixture can ask for a box its `viewBox` does not fit, and
both renderers work to the same one.

Not pixel for pixel: two correct rasterizers disagree along every antialiased
edge, since resvg's tiny-skia computes exact analytic coverage where z2d
multisamples at 4×. The comparison is of the shape — the mean difference and
the fraction of pixels more than a little apart — with thresholds set from what
the corpus measures, so a regression moves a number somebody can see rather
than flipping a boolean. A fixture this library refuses produces no PNG and is
reported as *not implemented*, which is how the feature list stays honest.

Colour is the exception that *is* exact. `fill-named-table.svg` paints all 147
CSS colour keywords resvg knows as a grid aligned to whole pixels, so there is
no antialiasing anywhere in it, and the two renderers agree on every pixel:
`mean 0.000  worst 0`.

One selector is deliberate too: the general sibling combinator, `~`, selects
here and does not in resvg. Like the colours below, nothing in the corpus uses
it, because a fixture that did would be measuring resvg's gap rather than this
code.

Four differences in colour are deliberate, and `src/color.zig` says why for each. This
library **refuses** a value it cannot read where resvg falls back to the
initial one; and it accepts three things CSS Color 4 defines that resvg 0.48.1
paints black — `rebeccapurple`, the slash alpha separator `rgb(255 0 0 / 0.5)`,
and a percentage alpha `rgba(255, 0, 0, 50%)`. None of the three appears in the
corpus, since a fixture using one would be testing resvg's gap rather than this
code.

Some fixtures are held to their own tolerances, named in `DIVERGENCES` at the
top of `tools/check_oracle.py` with the reason beside each and printed as
*diff* rather than *ok* so they stay visible. Five are `<filter>`, for two
separate reasons, and one is `<image>`.

The first is the **blur kernel**. §15.17 defines `feGaussianBlur` as a Gaussian
and then offers an approximation — "the implementation *can* approximate the
Gaussian blur with three successive box-blurs" — and the word is *can*. This
convolves the Gaussian itself. resvg's kernel was measured here against an
impulse and is neither: it is an infinite-impulse-response approximation,
noticeably more peaked than a Gaussian below about `stdDeviation` three and
indistinguishable from one above it. Two approximations of the same curve
differ by a level or two across the whole of a blurred area rather than along
an edge, which is exactly the shape of disagreement a tolerance tuned for
antialiasing does not fit — `filter-srgb` measures 0.704 with a worst pixel of
5, which is a lot of pixels differing by one and none differing visibly.

The second is the **region edge**, and here the oracle is the one that is
wrong. §15.7.5 makes the filter region "a hard clip" on the filter's input and
its output: clip the input, convolve, clip the output, and at the boundary the
result is half the kernel's weight. That is what this draws — 140 of 255 where
it was measured. resvg draws 77, which is the *square* of that, and matches
`blur(source) × blur(region)` to within a level across the whole profile. A
product of two blurs is not a linear operator, and `feGaussianBlur` is defined
as a convolution, which is. `filter-region` exists to record the difference
rather than being reshaped to avoid it.

The other is `<image>`. The image fixtures are written by
`tools/image_fixtures.py`, so that the base64 in them comes from an encoder
that is not z2dimg's, and all but one match resvg to a level: both sample with
Mitchell's cubic, and a black and a white pixel enlarged thirty-two times come
out the same S-curve in both. `image-downscale` is the exception, and the one
place resvg is the worse picture: resvg does not reduce a picture drawn small,
so the rings in that fixture are a moiré there and a faint one here. resvg
0.48.1 also draws CSS's `pixelated` and `crisp-edges` smooth, knowing only SVG
1.1's `optimizeSpeed`; no fixture uses them, since it would be measuring
resvg's gap.

## Fuzzing

`tests/fuzz.zig` holds five targets — the path grammar, the same path
rasterized, the document reader, the whole renderer, and the arc conversion —
and the properties they hold to: it comes back, every coordinate is finite,
every subpath is closed, and a document the reader accepted can be drawn.

Zig 0.16.0 leaves the fuzzer's coverage table empty however the modules are
built, so `tools/fuzz.zig` is a loop of our own: it mutates the corpus, hands
the result to a target, and reports what comes back. It has found three things
so far, each within minutes of being pointed at new code.

An infinite loop in the path parser: a bare number after `Z`, which has no
argument sequence to repeat, so the implicit-command rule ran a command that
consumed nothing and the scanner never advanced.

And a panic — the failure a caller cannot catch — on `transform="scale(1e300)"`
over a four-unit square. z2d clamps a coordinate to a signed 24-bit range as it
is added, but on the **wrong side of the transform**: `clampI24(x)` happens and
*then* the matrix is applied, so path data is protected and a transform is not.
The rasterizer reduces the polygon's extent to an `i32` and dies. This library
bounds the coordinates it hands over, checked on the stored nodes because those
are what the transform produced — see `document.max_coordinate`.

Moving that clamp after the matrix looks like it would settle the matter in
z2d, and does not. It was tried in the fork and reverted: clamping afterwards
leaves a corner at the origin where it is and snaps the rest to the bound, so
`transform="scale(1e10)"` on a small square stops being far off-screen and
covers the viewport instead — a solid fill where every other renderer draws
nothing. No choice of bound avoids it, because it is the corner at the origin
that does it. The real fix is for the rasterizer to *clip* rather than clamp,
which keeps the geometry it cannot represent instead of folding it back into
range; until then the check belongs here, where refusing is available and
drawing the wrong picture is not.

And an integer overflow — a panic again — reached through a `<pattern>`. A
pattern draws its content once per cell of its lattice and every cell spends
from the same `max_path_nodes` budget, so a fine enough tile drains it to
nearly nothing. Several builders then produce a fixed number of nodes whatever
the budget says, because there is no sensible half-drawn rectangle, and
subtracting five from a `usize` holding two is a crash rather than an error.
Overshooting the budget *is* the budget running out, so that is what
`spendNodes` reports now. The input was
`<pattern width="07.0001" …>`, which no test would have thought to write.

```console
$ zig build fuzz-run -- --seconds 300
$ zig build fuzz-run -- --target render --seed 12345
$ zig build fuzz-run -- --alloc-fail --seconds 60
```

`--alloc-fail` runs each input repeatedly with a different allocation failing
each time, which is the only way to reach the `errdefer` on the way out of a
path that never otherwise unwinds. Every target runs under it.

It was off for `render` for a while. That is the only target reaching z2d's
dashed stroke plotter, which leaked when an allocation failed part way through
capping its initial polygon — found by this very mode, and enough to make it
unusable here. The z2d this builds against fixes it, and carries a test of its
own so it cannot come back unnoticed.

## Looking at a picture

```console
$ zig build svgdump -- icon.svg out.png --size 256
$ zig build svgdump -- icon.svg out.png --size 256 --sandbox
```

## Features to come

Next are the CSS filter functions. Outside those, what SVG 1.1 has that this
does not is `@media`, the CSS pseudo-classes, the `spacingAndGlyphs` form of
`lengthAdjust`, and an `<image>` of another SVG document, which wants a render
nested in a render with its own viewport and a share of the budget. Each is
refused rather than ignored, so a document needing one says so.

**`<pattern>` sampled rather than drawn was on this list, and was tried and
dropped.** The reasoning was that drawing the tile once per cell costs a draw
per cell, and that sampling a tile as paint would be the same picture for less
work. A `SurfacePattern` went into the z2d fork to do it — it is still there,
tested, and is a good thing for that library to have.

It was neither cheaper nor the same picture. Timed on a 256-unit square filled
with a fine pattern at 1024×1024, both ways came out at 72 ms; at the tile
limit, 16384 cells, both came out at 73 ms.

**Time that on a release build, and mind which allocator it gets.** A tool
built through `std.process.Init` is handed a `DebugAllocator` in Debug and
ReleaseSafe and a fast one otherwise, and a pattern makes a couple of
allocations per cell — so the same 16384-cell document measures 3035 ms one
way and 181 ms the other. That seventeenfold gap is the allocator's
book-keeping and none of it is the renderer, which is a good way to spend an
afternoon concluding the wrong thing about where a pattern's time goes. On a
release build the shape of it is the one above: painting the same lattice into
a sixteenth of the pixels takes 29 ms rather than 64, so the cost follows the
area painted, and going from 16 cells to 16384 of them moves 19 ms to 64. The per-cell draw was already
sizing each cell's scratch surfaces to *that cell's* device footprint, so its
total work scales with the area painted rather than with area times tiles —
there was nothing left to win. And sampling is nearest-neighbour, so the
rotated fixtures went from 0.224 and 0.237 to 1.356 and 0.401, which is aliasing
where the per-cell draw is analytic. Worse pictures for the same time is not a
trade, so the per-cell draw stayed.

Deliberately not on the list: scripting, `<foreignObject>`, animation, and
external document references. Those are the parts of SVG that make it a
programming language rather than a picture format.

## Building

```console
$ nix develop
$ zig build test          # unit tests and the fuzz corpus
$ zig build oracle        # render tests/oracle, then check_oracle.py
$ zig build check         # compile everything, run nothing
$ zig build docs-serve    # read the API documentation
```

The devshell's Zig carries a one-line patch to its own standard library, without
which no project holding a fuzz test can build a test executable at all;
`flake.nix` says what and why.

## Dependencies

| | |
| --- | --- |
| [z2d](https://git.jcollie.dev/jeff/z2d) | the rasterizer, and the surfaces this draws onto |
| [ztree](https://git.jcollie.dev/jeff/ztree) | the XML document tree, built on [zxml](https://git.jcollie.dev/jeff/zxml) |
| [zig-css](https://git.jcollie.dev/jeff/zig-css) | §6's `style` attribute, `<style>` selectors, and the cascade |
| [z2dimg](https://git.jcollie.dev/jeff/z2dimg) | decoding the pictures an `<image>` names, onto the same z2d |
| [zig-uri](https://git.jcollie.dev/jeff/zig-uri) | reading a `data:` URL |

The CSS was `src/css.zig` and `src/style.zig` here until it was lifted out.
Deciding which of several declarations of one property applies to an element
is a job with one right answer that has nothing to do with drawing, and
nothing in it knows what a shape is — so it is a library rather than a
chapter of this one. What stayed here is the part that knows what `fill`
*means*.

The z2d is a fork of [vancluever/z2d](https://github.com/vancluever/z2d),
carrying what this library needs and upstream does not have: gradient extend
modes, without which `spreadMethod` cannot be drawn; a fix for a leak in the
dashed stroke plotter when an allocation fails; the thin-line guard being
decided by the user-space width rather than the device-space one; `PathNode`
not being exported although the painters take it; a surface usable as paint,
filtered with bilinear or Mitchell's cubic, and halved for drawing small, which
is how an `<image>` is drawn; and pre-multiplication that rounds rather than
truncates, which had darkened every translucent pixel by a level or so. Each arrived with
a test in z2d's own suite.

All are fetched by the Zig package manager. Nix builds fetch them through
`build.zig.zon.nix`, generated by [zon2nix](https://git.jcollie.dev/jeff/zon2nix):

```console
$ nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
```

## Licence

MIT. The project follows the [REUSE](https://reuse.software/) standard and
passes `reuse lint`.

## References cited

Kept in the Zotero collection **zig-svg**.

- World Wide Web Consortium (W3C). (2011, August). *Scalable Vector Graphics
  (SVG) 1.1 (Second Edition)* (W3C Recommendation).
  <https://www.w3.org/TR/SVG11/> — §8.3 is the path data grammar implemented
  in `src/path.zig`, and appendix F.6 the endpoint-to-centre arc conversion in
  `src/arc.zig`.
- Reizner, Y. *resvg*. Linebender. <https://github.com/linebender/resvg> — the
  independent implementation of that specification this renderer is held
  against, and the reason `tools/check_oracle.py` exists.
- Marchesi, C. *z2d*. <https://github.com/vancluever/z2d> — the rasterizer, and
  the surfaces this draws onto. Its transformation is applied when a point is
  added rather than when the path is filled, which is why the viewBox scale
  goes on `Path.transformation` before the first `moveTo`.
- World Wide Web Consortium (W3C). (2011, June). *Cascading Style Sheets Level
  2 Revision 1 (CSS 2.1) Specification* (W3C Recommendation).
  <https://www.w3.org/TR/CSS21/> — §6.4.3 is the cascade SVG 1.1 §6.4 adds the
  presentation attributes to the bottom of.
- Ollie, J. C. *zig-css*. <https://git.jcollie.dev/jeff/zig-css> — §6, lifted
  out of this one: the `style` attribute, a `<style>` element's selectors, and
  the cascade.
- Ollie, J. C. *ztree*. <https://git.jcollie.dev/jeff/ztree> — the XML document
  tree this reads a document into. A pull parser is the right shape for reading
  a document once and the wrong shape for `<use href="#a">`, where `#a` may be
  defined anywhere including after the reference that names it.
- Ollie, J. C. *zxml*. <https://git.jcollie.dev/jeff/zxml> — the pull parser
  ztree is built on.
- Masinter, L. (1998, August). *The "data" URL scheme* (RFC 2397). RFC Editor.
  <https://www.rfc-editor.org/info/rfc2397> — how an `<image>` carries its
  picture inside the document.
- World Wide Web Consortium (W3C). (2023, December). *CSS Images Module Level 3*
  (W3C Candidate Recommendation Draft). <https://www.w3.org/TR/css-images-3/> — the
  `image-rendering` values beyond SVG 1.1's three: `smooth`, `high-quality`,
  `crisp-edges` and `pixelated`.
- Ollie, J. C. *z2dimg*. <https://git.jcollie.dev/jeff/z2dimg> — the decoders
  an `<image>` is read with.
- Ollie, J. C. *zig-uri*. <https://git.jcollie.dev/jeff/zig-uri> — the `data:`
  URL reader.
- Pictogrammers. *Material Design Icons*. <https://pictogrammers.com/library/mdi/>
  — the 7,447-icon set that decided what this reader had to implement: every
  path command, and no other element.
- Herold, S. *glycin*. GNOME. <https://gitlab.gnome.org/GNOME/glycin> — the
  design `src/sandbox.zig` follows: a confined process per picture, with the
  pixels returned through shared memory.
- *Seccomp BPF (SEcure COMPuting with filters)*. The Linux Kernel
  documentation.
  <https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html>
- Kerrisk, M. *seccomp(2)*. Linux man-pages.
  <https://man7.org/linux/man-pages/man2/seccomp.2.html>
- Kerrisk, M. *memfd_create(2)*. Linux man-pages.
  <https://man7.org/linux/man-pages/man2/memfd_create.2.html>
- Kerrisk, M. *prctl(2)*. Linux man-pages.
  <https://man7.org/linux/man-pages/man2/prctl.2.html>
- Watson, R. N. M., Anderson, J., Laurie, B., & Kennaway, K. (2010, August).
  Capsicum: Practical Capabilities for UNIX. In *Proceedings of the 19th USENIX
  Security Symposium* (pp. 29–46). USENIX Association.
  <https://www.usenix.org/legacy/event/sec10/tech/full_papers/Watson.pdf> —
  the design `src/sandbox/capsicum.zig` locks the FreeBSD child down with.
- The FreeBSD Project. *capsicum(4)*. FreeBSD Manual Pages.
  <https://man.freebsd.org/cgi/man.cgi?query=capsicum&sektion=4>
- The FreeBSD Project. *cap_enter(2)*. FreeBSD Manual Pages.
  <https://man.freebsd.org/cgi/man.cgi?query=cap_enter&sektion=2>
- The FreeBSD Project. *cap_rights_limit(2)*. FreeBSD Manual Pages.
  <https://man.freebsd.org/cgi/man.cgi?query=cap_rights_limit&sektion=2>
- The FreeBSD Project. *procctl(2)*. FreeBSD Manual Pages.
  <https://man.freebsd.org/cgi/man.cgi?query=procctl&sektion=2> —
  `PROC_TRAPCAP_CTL`, which makes a refused call fatal, and `PROC_TRACE_CTL`.
- The FreeBSD Project. *closefrom(2)*. FreeBSD Manual Pages.
  <https://man.freebsd.org/cgi/man.cgi?query=closefrom&sektion=2>
- McCanne, S., & Jacobson, V. (1993, January). The BSD Packet Filter: A New
  Architecture for User-level Packet Capture. In *Proceedings of the USENIX
  Winter 1993 Conference* (pp. 259–269). USENIX Association.
  <https://www.tcpdump.org/papers/bpf-usenix93.pdf> — the classic BPF machine a
  seccomp filter is a program for.
