<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-svg

SVG rendering onto [z2d](https://github.com/vancluever/z2d) surfaces, for Zig
0.16. A document arrives as a byte slice and pixels come back as memory; the
library performs no I/O of its own — and because rendering is therefore a pure
function over memory, it can be run in a forked process that seccomp has
reduced to four system calls.

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

`spreadMethod="reflect"` and `"repeat"` are **refused**. z2d has no extend mode
— there is a `TODO` where one would go — so they cannot be drawn rather than
merely being unimplemented here, and they are visibly different pictures.
Drawing `pad` instead would be a wrong picture that looks deliberate.

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

The repository lives in three places that carry the same history. The Forgejo
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
seeds it. Any of the three is the whole project.

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
| `<linearGradient>`, `<radialGradient>` | yes, on `fill` and `stroke`, with `<stop>` and `href` inheritance |
| `gradientUnits`, `gradientTransform` | yes — both unit systems |
| `spreadMethod` | `pad` only; `reflect` and `repeat` are refused |
| A foreign namespace | passed over, not refused — an Inkscape file reads |
| `transform` | all six functions, on `<svg>`, `<g>` and any shape |
| `fill` | named colours, `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa`, `rgb()`, `rgba()`, `none`, `currentColor` |
| `fill-opacity`, `fill-rule`, `color` | yes, inherited through `<svg>` and `<g>` |
| `opacity` | yes, on a shape |
| `stroke`, `stroke-width`, `stroke-opacity` | yes, inherited |
| `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit` | yes, inherited |
| `stroke-dasharray`, `stroke-dashoffset` | yes, inherited; up to `raster.max_dashes` (64) lengths |
| `viewBox`, `width`, `height` | yes — the document's own size is what it is drawn at |
| `preserveAspectRatio` | all nine alignments, `meet`, `slice`, `none`, `defer` |
| Entity references in attribute values | yes, resolved as the document is parsed |
| `<title>`, `<desc>`, `<metadata>`, `<defs>` | passed over, and what is inside `<defs>` is not drawn |
| Lengths | `px`, `pt`, `pc`, `mm`, `cm`, `in`, `%`, and a bare number |
| Nesting depth | containers and `<use>` targets to `document.max_container_depth` (64) |
| `em`, `ex` lengths | **no** — refused; they need a font size |
| `<pattern>`, `style`, text, CSS | **no** |
| `opacity` on `<svg>` or `<g>` | **no** — refused; it needs a composited layer |

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
maps a circle to a circle, so the two are equivalent in geometry; what is not
equivalent is that z2d silently reverts the cap, join and miter limit to their
defaults whenever `line_width` is below 2. Handing it the user-space width
means `stroke-width="1"` — the initial value, so much the commonest one — loses
its round caps however large the picture is drawn. Handing it the device-space
width keeps them. Under a genuinely warped transform there is no equivalent
scalar, so the matrix goes to z2d and a thin stroke there may lose its caps;
the alternative would be a round pen where the specification asks for an
elliptical one, which is wrong in a way that does not announce itself.

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
reduced to `write`, `exit_group`, `exit` and `rt_sigreturn`, and passes the
pixels back through a shared `memfd`:

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

It does not make the pixels *trustworthy* — writing into the shared mapping is
the child's job. What the parent validates is the shape of the reply: that the
buffer is inside the mapping, correctly aligned, and exactly the length the
stated dimensions require.

Linux and 64-bit only. `svg.sandbox.available` says so at compile time, and
`render` returns `error.SandboxUnavailable` at run time rather than silently
rendering unsandboxed — a security feature that quietly turns itself off is
worse than one that was never there.

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

Four differences are deliberate, and `src/color.zig` says why for each. This
library **refuses** a value it cannot read where resvg falls back to the
initial one; and it accepts three things CSS Color 4 defines that resvg 0.48.1
paints black — `rebeccapurple`, the slash alpha separator `rgb(255 0 0 / 0.5)`,
and a percentage alpha `rgba(255, 0, 0, 50%)`. None of the three appears in the
corpus, since a fixture using one would be testing resvg's gap rather than this
code.

## Fuzzing

`tests/fuzz.zig` holds five targets — the path grammar, the same path
rasterized, the document reader, the whole renderer, and the arc conversion —
and the properties they hold to: it comes back, every coordinate is finite,
every subpath is closed, and a document the reader accepted can be drawn.

Zig 0.16.0 leaves the fuzzer's coverage table empty however the modules are
built, so `tools/fuzz.zig` is a loop of our own: it mutates the corpus, hands
the result to a target, and reports what comes back. It has found two things so far, each within
seconds of being pointed at new code.

An infinite loop in the path parser: a bare number after `Z`, which has no
argument sequence to repeat, so the implicit-command rule ran a command that
consumed nothing and the scanner never advanced.

And a panic — the failure a caller cannot catch — on `transform="scale(1e300)"`
over a four-unit square. z2d clamps a coordinate to a signed 24-bit range as it
is added, but on the **wrong side of the transform**: `clampI24(x)` happens and
*then* the matrix is applied, so path data is protected and a transform is not.
The rasterizer reduces the polygon's extent to an `i32` and dies. This library
now bounds the coordinates it hands over, checked on the stored nodes because
those are what the transform produced — see `document.max_coordinate`.

```console
$ zig build fuzz-run -- --seconds 300
$ zig build fuzz-run -- --target render --seed 12345
$ zig build fuzz-run -- --alloc-fail --seconds 60
```

`--alloc-fail` runs each input repeatedly with a different allocation failing
each time, which is the only way to reach the `errdefer` on the way out of a
path that never otherwise unwinds. It is **off for the `render` target**, and
for a reason worth stating rather than burying: z2d leaks when an allocation
fails part way through its stroke plotter —
`internal/tess/Polygon.zig`'s `plot` creates a `Corner` and the corners already
linked are not released when a later allocation in the same plot fails. The
trace runs entirely through z2d, so there is nothing this library can do about
it but say so. The other four targets still fail allocations, and `path-fill`
covers the fill side of the same rasterizer. `Target.alloc_fail` in
`tests/fuzz.zig` is the flag to turn back on when z2d is fixed.

## Looking at a picture

```console
$ zig build svgdump -- icon.svg out.png --size 256
$ zig build svgdump -- icon.svg out.png --size 256 --sandbox
```

## Features to come

Roughly in the order they are worth having. Each is a document that errors
today, and each should arrive with a fixture in `tests/oracle` that resvg
already renders.

**1. Clipping and masking, and group opacity.** `<clipPath>`, `<mask>`,
`clip-rule`, and `opacity` on a container. All four need a composited layer
rather than one surface: a group's opacity applies to the group once it is
flattened, so multiplying it into each shape shows every shape through every
other where the group would have shown only the upper one. That is why
`opacity` on an `<svg>` or a `<g>` is `error.GroupOpacityUnsupported` rather
than an approximation — on a `<path>`, where there is nothing to overlap, it is
implemented and exact.

**2. Text, and the font-relative lengths with it.** `<text>`, `<tspan>`,
`font-family`, `font-size`, `text-anchor` — and with a font size finally in
hand, the `em` and `ex` that are refused today. z2d can lay
out a font, but choosing one from a family name means a font database, which is
a dependency and a filesystem — and the filesystem is exactly what the sandbox
exists to take away, so this needs the fonts resolved by the *caller* and
handed in.

**3. Patterns and the rest of `spreadMethod`.** `<pattern>` needs a tile
rendered to its own surface and then repeated, and `reflect`/`repeat` need an
extend mode z2d does not have — so both are upstream work before they are work
here.

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
| [z2d](https://github.com/vancluever/z2d) | the rasterizer, and the surfaces this draws onto |
| [ztree](https://git.jcollie.dev/jeff/ztree) | the XML document tree, built on [zxml](https://git.jcollie.dev/jeff/zxml) |

Both are fetched by the Zig package manager. Nix builds fetch them through
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
- Ollie, J. C. *ztree*. <https://git.jcollie.dev/jeff/ztree> — the XML document
  tree this reads a document into. A pull parser is the right shape for reading
  a document once and the wrong shape for `<use href="#a">`, where `#a` may be
  defined anywhere including after the reference that names it.
- Ollie, J. C. *zxml*. <https://git.jcollie.dev/jeff/zxml> — the pull parser
  ztree is built on.
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
- McCanne, S., & Jacobson, V. (1993, January). The BSD Packet Filter: A New
  Architecture for User-level Packet Capture. In *Proceedings of the USENIX
  Winter 1993 Conference* (pp. 259–269). USENIX Association.
  <https://www.tcpdump.org/papers/bpf-usenix93.pdf> — the classic BPF machine a
  seccomp filter is a program for.
