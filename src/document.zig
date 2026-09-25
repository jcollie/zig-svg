// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading an SVG document far enough to draw what is in it.
//!
//! One `<svg>`, any number of shapes inside it, grouped by `<g>`, referenced
//! by `<use>`, each with its own paint and transform.
//!
//! ## A tree, not a stream
//!
//! This used to walk the document with [zxml](https://git.jcollie.dev/jeff/zxml),
//! a pull parser, which is the right shape for reading a document once and the
//! wrong shape for anything that has to look somewhere else in it.
//! `<use href="#a">` is exactly that: `#a` may be defined anywhere, including
//! *after* the `<use>` that names it, and `url(#gradient)` will want the same
//! thing again.
//!
//! So the document is read into a tree with
//! [ztree](https://git.jcollie.dev/jeff/ztree) and walked from there. Three
//! things fall out of that beyond the reference itself:
//!
//! * **Entity references are already resolved.** ztree decodes every attribute
//!   value into its arena as it parses, with the same `.attribute`
//!   normalization XML asks for, so nothing downstream has to think about
//!   `&#90;`.
//! * **Names are expanded**, so an element can be told apart by its namespace
//!   rather than only by its local name. That is what lets a foreign-namespace
//!   element be *ignored* rather than refused -- an Inkscape file's
//!   `<sodipodi:namedview>` is not SVG content and is not meant to be drawn,
//!   where an unknown element in the SVG namespace still is a refusal.
//! * **The walk's stack is small.** A frame is a node id, an index and the
//!   inherited state; suspending one to walk a `<use>`'s target costs a couple
//!   of hundred bytes rather than a whole suspended parser.
//!
//! What it costs is that reading now allocates and the `Document` owns what it
//! read. `read` takes an allocator and the result must be `deinit`ed; the
//! source may be freed the moment `read` returns, because every string in the
//! tree is a copy.
//!
//! ## The presentation attributes it reads
//!
//! `fill`, `fill-opacity`, `fill-rule`, `color` and the eight `stroke-*`
//! properties are inherited: named on the root `<svg>` or on a `<g>` they
//! apply to everything inside, and named on a shape they apply to it.
//! `opacity` is read on a shape and is not inherited, because it is not an
//! inherited property. A `transform` on any element composes with its
//! ancestors'.
//!
//! A shape that names no `fill` is painted in the colour the *caller* chose,
//! not in SVG's initial black. That is a deliberate difference, and it is the
//! whole reason a caller can draw a Material Design Icon in any colour: not
//! one of the 7,447 carries a `fill`, so under the letter of the specification
//! the set could only ever be black. `fill="currentColor"`, which many other
//! icon sets use instead, lands on the same caller's colour by the honest
//! route -- it is the initial value of the `color` property, and the caller
//! chooses that too. A `stroke` works the other way round: naming none means
//! *no stroke*, because SVG's initial `stroke` is `none` and a shape stroked
//! without asking would put lines in a picture the document does not have.
//!
//! Anything else is ignored rather than refused: `id`, `class`, `style`,
//! `font-size`. Elements are refused, attributes are ignored -- an element
//! carries geometry that would go missing, and an attribute is usually
//! decoration. The exception is `opacity` on a container, which would go
//! quietly wrong; see `Error.GroupOpacityUnsupported`.

const std = @import("std");
const ztree = @import("ztree");
const z2d = @import("z2d");

const color = @import("color.zig");
const length = @import("length.zig");
const path = @import("path.zig");
const resample = @import("resample.zig");
const shapes = @import("shapes.zig");
const css = @import("css");
const transform = @import("transform.zig");

/// The namespace SVG content is in. An element in no namespace is taken as
/// SVG too, because a document written without `xmlns` is still a document
/// somebody means to draw.
pub const svg_ns = "http://www.w3.org/2000/svg";

/// Where `xlink:href` lives, which is how SVG 1.1 spells a reference and how
/// most documents in the world still do.
pub const xlink_ns = "http://www.w3.org/1999/xlink";

pub const Error = error{
    /// The document has no `<svg>` element.
    NotAnSvg,
    /// `<svg>` has a `viewBox` that is not four numbers.
    BadViewBox,
    /// There is no shape at all, or a `<path>` has no `d`.
    NoPath,
    /// An element in the SVG namespace that this reader does not implement --
    /// a `<foreignObject>`, a `<switch>`. Refused rather than skipped:
    /// skipping it would draw a picture that is quietly missing a piece.
    ///
    /// An element in *another* namespace is not this: it is not SVG content,
    /// nothing is meant to draw it, and it is passed over.
    UnsupportedElement,
    /// A `fill-rule` that is neither `nonzero` nor `evenodd`.
    BadFillRule,
    /// A `preserveAspectRatio` that is not `none` or one of the nine
    /// alignments, optionally followed by `meet` or `slice`.
    BadPreserveAspectRatio,
    /// A document that says neither how large it is nor what its `viewBox` is,
    /// so there is nothing to say how big to draw it or what its coordinates
    /// mean.
    NoSize,
    /// A `stroke-linecap`, `stroke-linejoin` or `stroke-miterlimit` this
    /// reader does not recognise. Like `fill-rule`, these are XML attribute
    /// values rather than CSS keywords, so they are matched with regard to
    /// case: `stroke-linecap="ROUND"` is not `round`.
    BadStrokeStyle,
    /// Containers nested more deeply than `max_container_depth`.
    TooDeeplyNested,
    /// A `transform` whose composed matrix has an infinity or a NaN in it.
    NonFiniteTransform,
    /// A point that landed outside what the rasterizer can work with, after
    /// the transforms and the viewBox mapping were applied. See
    /// `max_coordinate`.
    CoordinateOutOfRange,
    /// A `<use>` with no `href`, or one naming something other than a fragment
    /// of this document. An external reference is a file this library will not
    /// fetch -- being sans-I/O is the whole reason the renderer can be
    /// sandboxed -- so it is refused rather than silently drawing nothing.
    BadReference,
    /// A `<use>` whose `href` names an id the document does not have.
    UnknownReference,
    /// A `<use>` that draws something containing itself, directly or through
    /// others. Caught by the frame stack rather than by a depth limit, so it
    /// is reported the moment it closes rather than after a budget runs out.
    RecursiveUse,
    /// A chain of `<use>` elements each naming the next, longer than
    /// `max_use_hops`. Not a cycle -- those are caught exactly -- but a chain
    /// nothing sensible produces.
    TooManyUseHops,
    /// A `text-anchor` that is not one of §10.9's three.
    BadTextAnchor,
    /// An `image-rendering` that is none of the keywords SVG 1.1 or CSS
    /// Images 3 define for it.
    BadImageRendering,
    /// A `visibility` that is none of `visible`, `hidden` and `collapse`.
    BadVisibility,
    /// A `font-weight` that is neither a number in range nor `normal` or
    /// `bold`.
    BadFontWeight,
    /// A `font-style` that is not `normal`, `italic` or `oblique`.
    BadFontStyle,
    /// A `rotate`, `textLength` or `lengthAdjust` on a `<text>` or a
    /// `<tspan>`. Each changes where the glyphs go, so ignoring one draws text
    /// that is in the wrong place and looks deliberate.
    UnsupportedTextLayout,
} || transform.Error || color.Error || css.Error || length.Error || ztree.ParseError;

/// The furthest from the origin a transformed point may land, in pixels.
///
/// Not a stylistic limit; it is here to stop a **panic**, which no caller can
/// catch, in a library reached by every picture from anywhere.
///
/// z2d clamps a point to a signed 24-bit range as it is added, which sounds
/// like it settles the matter, and does not:
///
/// ```zig
/// const point: Point = (Point{ .x = clampI24(x), .y = clampI24(y) })
///     .applyTransform(self.transformation);
/// ```
///
/// The clamp is on the **wrong side of the transform**. A coordinate written
/// in the path data is clamped and safe -- `H1e300` becomes 8388607 -- but
/// `transform="scale(1e300)"` multiplies the clamped value *afterwards*, and
/// nothing clamps it again. The rasterizer then reduces a polygon's extent to
/// an `i32` and dies on `@intFromFloat` with a value out of range. The fuzzer
/// found it, on a four-unit square.
///
/// So the check has to be on the stored nodes, which are what the transform
/// produced, and it is why `buildShape` looks at them rather than `path.build`
/// looking at the numbers it parsed.
///
/// Set at 2^28: eight thousand times the widest surface `Limits` permits, and
/// low enough that the plotter's multiply by the antialiasing scale and the
/// subtraction of two extents both stay comfortably inside an `i32`. A
/// document putting geometry further away than that is not a picture.
pub const max_coordinate: f64 = 1 << 28;

/// How deeply containers and `<use>` targets may nest.
///
/// Sized so that the walk's stack is a few kilobytes rather than tens, and so
/// far above any drawing that a document reaching it is doing something other
/// than describing a picture. Refused rather than overflowed: a stack overflow
/// is the one failure a caller cannot catch.
pub const max_container_depth = 64;

/// How many `<use>` elements may name one another in a row.
///
/// A cycle is caught exactly, by noticing that a target is already open, so
/// this is only for a chain that is finite and still absurd.
pub const max_use_hops = 16;

pub const ViewBox = struct {
    min_x: f64,
    min_y: f64,
    width: f64,
    height: f64,
};

/// How a `viewBox` is fitted into the box it is drawn in -- SVG 1.1 §7.8.
pub const PreserveAspectRatio = struct {
    /// Where the extra space goes along each axis when the two do not have the
    /// same proportions.
    align_x: Align = .mid,
    align_y: Align = .mid,
    /// `meet` fits the whole viewBox inside the box and leaves space; `slice`
    /// covers the box and lets the viewBox overflow it.
    slice: bool = false,
    /// `preserveAspectRatio="none"`, which scales each axis independently and
    /// so distorts. The alignment means nothing then, because there is no
    /// space left over to put anywhere.
    stretch: bool = false,

    pub const Align = enum { min, mid, max };

    /// The default, which is what a document that says nothing gets.
    pub const meet_centred: PreserveAspectRatio = .{};

    /// The fraction of the leftover space that goes *before* the viewBox.
    fn fraction(a: Align) f64 {
        return switch (a) {
            .min => 0.0,
            .mid => 0.5,
            .max => 1.0,
        };
    }

    /// `[defer] <align> [meet|slice]`.
    ///
    /// The `defer` keyword is read and ignored, which is what it is for: it
    /// applies to a `<use>` of an image and means nothing on a root `<svg>`.
    pub fn parse(text: []const u8) Error!PreserveAspectRatio {
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        var word = it.next() orelse return error.BadPreserveAspectRatio;
        if (std.mem.eql(u8, word, "defer")) {
            word = it.next() orelse return error.BadPreserveAspectRatio;
        }

        var result: PreserveAspectRatio = .{};
        if (std.mem.eql(u8, word, "none")) {
            result.stretch = true;
        } else {
            // `xMidYMid` and its eight siblings, matched with regard to case
            // like every other keyword that is an XML attribute value.
            if (word.len != 8) return error.BadPreserveAspectRatio;
            if (word[0] != 'x' or word[4] != 'Y') return error.BadPreserveAspectRatio;
            result.align_x = parseAlign(word[1..4]) orelse return error.BadPreserveAspectRatio;
            result.align_y = parseAlign(word[5..8]) orelse return error.BadPreserveAspectRatio;
        }

        if (it.next()) |mode| {
            if (std.mem.eql(u8, mode, "slice")) {
                result.slice = true;
            } else if (!std.mem.eql(u8, mode, "meet")) {
                return error.BadPreserveAspectRatio;
            }
        }
        if (it.next() != null) return error.BadPreserveAspectRatio;
        return result;
    }

    fn parseAlign(word: []const u8) ?Align {
        if (std.mem.eql(u8, word, "Min")) return .min;
        if (std.mem.eql(u8, word, "Mid")) return .mid;
        if (std.mem.eql(u8, word, "Max")) return .max;
        return null;
    }
};

/// The presentation attributes that an element passes down to its children.
///
/// Null in each field means nothing has named it, so the caller's choice
/// stands. That is what lets `Options.fill` be the default for a document that
/// names no colour anywhere, which is every icon set worth drawing.
pub const Inherited = struct {
    fill: ?color.Paint = null,
    fill_opacity: ?f64 = null,
    fill_rule: ?z2d.options.FillRule = null,
    /// §14.3's `clip-rule`, which is `fill-rule` for a shape inside a
    /// `<clipPath>` and is inherited separately from it -- a document can fill
    /// nonzero and clip even-odd, and several do.
    clip_rule: ?z2d.options.FillRule = null,
    /// The `color` property, which is what a `fill` or `stroke` of
    /// `currentColor` resolves to.
    current_color: ?color.Color = null,

    stroke: ?color.Paint = null,
    stroke_width: ?f64 = null,
    stroke_opacity: ?f64 = null,
    stroke_linecap: ?z2d.options.CapMode = null,
    stroke_linejoin: ?z2d.options.JoinMode = null,
    stroke_miterlimit: ?f64 = null,
    /// `stroke-dasharray` as the document wrote it. Kept as text because a
    /// dash list is a list: parsing it here would mean either allocating for
    /// it or giving every level of the walk's stack room for one. It borrows
    /// from the tree's arena, so it lives as long as the `Document`.
    stroke_dasharray: ?[]const u8 = null,
    stroke_dashoffset: ?f64 = null,

    /// The `font-family` list as the document wrote it, borrowed from the
    /// tree's arena. Kept as text for the same reason `stroke-dasharray` is: it
    /// is a list, and splitting it here would mean allocating or giving every
    /// level of the walk's stack room for one.
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,
    font_weight: ?u16 = null,
    font_italic: ?bool = null,
    text_anchor: ?TextAnchor = null,

    /// §11.7.6's `image-rendering`, which is inherited so that one on the root
    /// reaches every `<image>` in the document.
    image_rendering: ?resample.Sampling = null,

    /// §11.5's `visibility`: false for `hidden` or `collapse`. Inherited, and
    /// overridable -- a `visible` child of a hidden group is drawn, which is
    /// the one thing that tells it apart from `display="none"`.
    visible: ?bool = null,

    /// `self` with everything `child` names overridden.
    pub fn with(self: Inherited, child: Inherited) Inherited {
        return .{
            .fill = child.fill orelse self.fill,
            .fill_opacity = child.fill_opacity orelse self.fill_opacity,
            .fill_rule = child.fill_rule orelse self.fill_rule,
            .clip_rule = child.clip_rule orelse self.clip_rule,
            .current_color = child.current_color orelse self.current_color,
            .stroke = child.stroke orelse self.stroke,
            .stroke_width = child.stroke_width orelse self.stroke_width,
            .stroke_opacity = child.stroke_opacity orelse self.stroke_opacity,
            .stroke_linecap = child.stroke_linecap orelse self.stroke_linecap,
            .stroke_linejoin = child.stroke_linejoin orelse self.stroke_linejoin,
            .stroke_miterlimit = child.stroke_miterlimit orelse self.stroke_miterlimit,
            .stroke_dasharray = child.stroke_dasharray orelse self.stroke_dasharray,
            .stroke_dashoffset = child.stroke_dashoffset orelse self.stroke_dashoffset,
            .font_family = child.font_family orelse self.font_family,
            .font_size = child.font_size orelse self.font_size,
            .font_weight = child.font_weight orelse self.font_weight,
            .font_italic = child.font_italic orelse self.font_italic,
            .text_anchor = child.text_anchor orelse self.text_anchor,
            .image_rendering = child.image_rendering orelse self.image_rendering,
            .visible = child.visible orelse self.visible,
        };
    }
};

/// §10.9's `text-anchor`: which end of the text sits at the given point.
pub const TextAnchor = enum {
    /// The default. The point is where the text begins.
    start,
    /// The point is the middle of the text's advance.
    middle,
    /// The point is where the text ends.
    end,
};

/// What the walk produces: a shape to draw, or the edges of a group that has
/// to be drawn into a surface of its own.
///
/// A plain `<g>` produces neither -- it contributes its attributes to what is
/// inside it and nothing more, which is why the walk has always been able to
/// flatten one away. A group only becomes visible here when it needs
/// compositing: `opacity` on a container applies to the container once it is
/// flattened, so multiplying it into each shape would show every shape through
/// every other where the group shows only the upper one.
pub const Item = union(enum) {
    shape: Shape,
    image: Image,
    open_group: Group,
    close_group,
};

/// An `<image>`: SVG 1.1 §5.7. A picture placed in a rectangle, which is the
/// one drawable element with no paint and no outline.
pub const Image = struct {
    /// The `<image>` element itself, which is what the renderer keys its
    /// decoded picture by: a `<use>` of it reaches the same node.
    node: ztree.NodeId,
    /// The URL as written, borrowed from the tree's arena. Nothing here reads
    /// it -- fetching and decoding belong to the renderer.
    href: []const u8,
    /// The rectangle the picture is fitted into, in user units. A null
    /// `width` or `height` is SVG 2's `auto`, which is the picture's own size
    /// and is only known once it has been decoded.
    x: f64,
    y: f64,
    width: ?f64,
    height: ?f64,
    /// How the picture is fitted into that rectangle. §7.8's rule, with the
    /// picture's own pixel size standing in for a `viewBox`.
    preserve_aspect_ratio: PreserveAspectRatio,
    sampling: resample.Sampling,
    /// This element's own `opacity`, applied to the picture once.
    opacity: f64,
    clip_path: ?[]const u8,
    mask: ?[]const u8,
    filter: ?[]const u8,
    /// The `color` in force, which a `currentColor` in its filter resolves to.
    current_color: ?color.Color,
    /// False under `visibility: hidden`; see `Shape.visible`.
    visible: bool,
    /// Every `transform` down to and including this element's, as `Shape`
    /// carries it.
    transform: z2d.Transformation,
};

/// A container that needs a layer of its own.
pub const Group = struct {
    /// The element the container was resolved to -- the `<g>` itself, or what
    /// a `<use>` chain ended at. The renderer needs it to measure the group:
    /// a clip or a mask in `objectBoundingBox` units is a fraction of the
    /// union of everything inside, which can only be found by walking it, and
    /// `Document.subtree` walks from here.
    node: ztree.NodeId,
    /// The `opacity` to composite the finished layer at.
    opacity: f64,
    /// The id of a `<clipPath>` the layer is cut to, or null.
    clip_path: ?[]const u8,
    /// The id of a `<mask>` the layer is cut to, or null. A layer may have
    /// both, and then it is cut to the intersection.
    mask: ?[]const u8,
    /// The id of a `<filter>` the finished layer is put through, or null.
    /// §15 applies it before the clip, the mask and the opacity, so it sees
    /// the layer as painted and they see what it produced.
    filter: ?[]const u8,
    /// The `color` in force on the container, which is what a `currentColor`
    /// inside its filter resolves to. Carried because a filter's own elements
    /// inherit nothing from the document -- they are in `<defs>`.
    current_color: ?color.Color,
    /// The user-space matrix in force on the container, which is the space the
    /// clip path's own coordinates are in.
    transform: z2d.Transformation,
};

/// What an element's `clip-path`, `mask` and `filter` attributes name.
const Refs = struct {
    clip_path: ?[]const u8,
    mask: ?[]const u8,
    filter: ?[]const u8,

    /// Whether the element needs a surface of its own. Any of the three does
    /// it: a clip and a mask because `dst_in` is a whole-surface operation,
    /// and a filter because it reads the element's finished rendering.
    fn any(self: Refs) bool {
        return self.clip_path != null or self.mask != null or self.filter != null;
    }
};

/// One drawable element, with the paint and the transform that apply to it.
pub const Shape = struct {
    /// What to draw: a `<path>`'s `d`, or one of the basic shapes' numbers.
    /// Anything it borrows comes from the tree's arena.
    geometry: shapes.Geometry,
    /// What to paint it with, after inheritance. Null means nothing named a
    /// `fill`, so the caller's colour stands.
    fill: ?color.Paint,
    fill_opacity: ?f64,
    fill_rule: ?z2d.options.FillRule,
    clip_rule: ?z2d.options.FillRule,
    current_color: ?color.Color,
    stroke: ?color.Paint,
    stroke_width: ?f64,
    stroke_opacity: ?f64,
    stroke_linecap: ?z2d.options.CapMode,
    stroke_linejoin: ?z2d.options.JoinMode,
    stroke_miterlimit: ?f64,
    stroke_dasharray: ?[]const u8,
    stroke_dashoffset: ?f64,
    /// What `.text` geometry is drawn with. Meaningless for every other
    /// geometry, and inherited like the paint properties are, because a
    /// `font-size` on a `<g>` applies to the text inside it.
    font_family: ?[]const u8,
    font_size: ?f64,
    font_weight: ?u16,
    font_italic: ?bool,
    text_anchor: ?TextAnchor,
    /// This element's own `opacity`, which is not inherited. One when the
    /// element does not name it.
    opacity: f64,
    /// The id of a `<clipPath>` this shape is cut to, or null. Not inherited:
    /// a clip applies to the element that names it.
    clip_path: ?[]const u8,
    /// The id of a `<filter>` this shape's rendering is put through, or
    /// null. §15 applies it before the clip, the mask and the opacity.
    filter: ?[]const u8,
    /// The id of a `<mask>` this shape is cut to, or null. Not inherited
    /// either, and a shape may carry both.
    mask: ?[]const u8,
    /// False under `visibility: hidden` or `collapse`.
    ///
    /// A hidden shape is still yielded rather than dropped, because it still
    /// takes up room: a hidden run of text moves the pen as far as a visible
    /// one would, and a hidden shape is still part of its group's bounding
    /// box. It is only not painted.
    visible: bool,
    /// Every `transform` from the root down to and including this element,
    /// composed, with each `<use>`'s `x` and `y` folded in. In user units: the
    /// viewBox-to-pixels mapping is *not* in here, because it belongs to the
    /// box being drawn into rather than to the document, and
    /// `Document.transformFor` supplies it.
    transform: z2d.Transformation,
};

/// A document that has been read and found drawable.
///
/// Owns the tree it was read from, so `deinit` it when done. The source it was
/// read from may be freed as soon as `read` returns: every string here is a
/// copy in the tree's arena.
pub const Document = struct {
    /// The parsed tree. Public because a caller that wants to ask the document
    /// something this library does not -- what its title is, what ids it has
    /// -- should not have to parse it a second time.
    tree: *ztree.Document,
    /// The root `<svg>`.
    root_node: ztree.NodeId,
    /// Every element carrying an `id`, so that a reference resolves in one
    /// lookup rather than a scan. Allocated from the tree's arena, so
    /// `tree.destroy` frees it.
    ids: std.StringHashMapUnmanaged(ztree.NodeId),

    /// The coordinate system the shapes are written in, as the document wrote
    /// it, or null when it has no `viewBox`.
    ///
    /// Null does not mean there is no mapping: `transformFor` then behaves as
    /// though the document had said `viewBox="0 0 width height"`, since its
    /// user units are pixels at the size it claims to be. The field stays
    /// optional so that a caller can tell what the document actually said.
    view_box: ?ViewBox,
    /// How large the document says it is, in pixels. From `width` and `height`
    /// when it names them, and from the `viewBox`'s extent when it does not.
    width: f64,
    height: f64,
    /// How the `viewBox` is fitted into the box it is drawn in.
    preserve_aspect_ratio: PreserveAspectRatio,
    /// How many shapes the walk produces, so that a caller can bound the work
    /// before starting it.
    shape_count: usize,
    /// What the root `<svg>` named, which every shape inherits unless a `<g>`
    /// or the shape itself overrides it.
    root: Inherited,
    /// Every `<style>` element of the document, parsed into one stylesheet.
    /// Empty when the document has none, which is the usual case and costs
    /// nothing to ask.
    stylesheet: css.Stylesheet,

    pub fn deinit(self: *Document) void {
        self.stylesheet.deinit();
        self.tree.destroy();
        self.* = undefined;
    }

    /// What a percentage inside this document is measured against.
    ///
    /// The `viewBox` establishes a new viewport, so it is that rather than the
    /// size the picture is drawn at: a document 100 by 50 pixels with a
    /// `viewBox` of `0 0 100 200` resolves `50%` of a height as 100 user
    /// units. resvg agrees, and it is what §7.10 says.
    pub fn viewport(self: Document) length.Viewport {
        if (self.view_box) |vb| return .{ .width = vb.width, .height = vb.height };
        return .{ .width = self.width, .height = self.height };
    }

    /// Each shape, in painting order.
    pub fn paths(self: *const Document) PathIterator {
        return .{ .doc = self, .viewport = self.viewport() };
    }

    /// The same walk as `paths`, rooted somewhere else in the document and
    /// somewhere else in the coordinate system.
    ///
    /// Three things need it. A `<clipPath>` is walked with the matrix of the
    /// element being clipped, because `clipPathUnits="userSpaceOnUse"` means
    /// the user space of the *clipped* element rather than of the
    /// `<clipPath>`. A `<mask>` is walked the same way, with the region and
    /// content units folded into the matrix first. And measuring a container
    /// walks it with the identity, which puts every shape it yields in the
    /// container's own user space -- the space §7.11's object bounding box is
    /// measured in.
    ///
    /// The root's own `transform` and attributes are *not* applied: the
    /// caller's matrix stands in for everything above the children. That is
    /// what makes the identity case measure a group rather than measure it
    /// already transformed.
    ///
    /// A clip drops the `open_group` and `close_group` items it yields --
    /// §14.3 makes a clip the union of its shapes whatever they are nested in,
    /// and there is nothing to composite inside an alpha mask. A mask honours
    /// them, because a `<g opacity="0.5">` inside one is half as opaque and so
    /// masks half as much.
    pub fn subtree(
        self: *const Document,
        root: ztree.NodeId,
        ctm: z2d.Transformation,
    ) PathIterator {
        var it: PathIterator = .{ .doc = self, .viewport = self.viewport() };
        it.started = true;
        it.stack[0] = .{
            .node = root,
            .next_child = 0,
            .inherited = .{},
            .transform = ctm,
            // A `<use>` drawn as a group is measured as one: what is inside
            // it is what it names, not the children it does not have.
            .only_child = if (localIs(self.tree, root, "use")) self.useTarget(root) else null,
        };
        return it;
    }

    /// What a `<use>` names, or null when it names nothing this document
    /// has. The walk has already refused a `<use>` like that by the time
    /// anything asks this, so null only ever means "nothing to measure".
    fn useTarget(self: *const Document, use: ztree.NodeId) ?ztree.NodeId {
        const raw = self.tree.attributeValue(use, "", "href") orelse
            self.tree.attributeValue(use, xlink_ns, "href") orelse
            return null;
        const target = std.mem.trim(u8, raw, " \t\r\n");
        if (target.len < 2 or target[0] != '#') return null;
        return self.ids.get(target[1..]);
    }

    /// The runs of one `<text>`, for measuring.
    ///
    /// `subtree` deliberately leaves the root's own attributes alone, because
    /// a `<clipPath>` or a `<pattern>` contributes none of its own to what is
    /// inside it. A `<text>` is the opposite: its `font-size`, its
    /// `font-family` and its `text-anchor` are exactly what its runs are drawn
    /// with, and measuring them without it measures the wrong thing -- at the
    /// default size rather than the document's, which is a ratio rather than a
    /// small error.
    ///
    /// Used to find the width of a chunk, which `text-anchor` needs before the
    /// first run of one can be placed.
    pub fn textRuns(self: *const Document, root: ztree.NodeId) Error!PathIterator {
        var it: PathIterator = .{ .doc = self, .viewport = self.viewport() };
        it.started = true;
        // The element's own `font-size` first, against nothing -- there is no
        // parent here to make an `em` relative to -- and then everything else
        // against what it came to.
        it.viewport.font_size = null;
        const own = try it.readInherited(root);
        it.viewport.font_size = own.font_size;
        it.stack[0] = .{
            .node = root,
            .next_child = 0,
            .inherited = own,
            .transform = .identity,
        };
        return it;
    }

    /// One element's own geometry, or null when it has none.
    ///
    /// `subtree` walks a node's *children*, which is what a `<clipPath>` or a
    /// `<pattern>` wants and is exactly wrong for asking a `<path>` what it
    /// draws -- a `<path>` has no children, so rooting a walk there yields
    /// nothing at all. `<textPath>` needs the shape it names rather than
    /// whatever is inside it.
    ///
    /// The element's own `transform` is *not* applied: the caller is laying
    /// text along the shape in the referencing element's user space, and
    /// `transformOf` is there for a caller that wants it.
    pub fn geometryOf(self: *const Document, node: ztree.NodeId) Error!?shapes.Geometry {
        var it: PathIterator = .{ .doc = self, .viewport = self.viewport() };
        return it.readGeometry(node);
    }

    /// An element's own `transform`, or the identity when it has none.
    ///
    /// `subtree` deliberately leaves the root's attributes alone, because the
    /// caller's matrix stands in for everything above the children. §14.3's
    /// `transform` on a `<clipPath>` is the exception: it applies, and it is
    /// the caller that has to fold it in. A `transform` on a `<mask>` does
    /// *not* apply -- confirmed against resvg, which moves a clip and leaves a
    /// mask where it was.
    pub fn transformOf(self: Document, node: ztree.NodeId) Error!z2d.Transformation {
        const raw = self.tree.attributeValue(node, "", "transform") orelse return .identity;
        return transform.parse(raw);
    }

    /// The viewBox-to-pixels transformation for drawing into `box`.
    ///
    /// SVG 1.1 §7.8's algorithm, with `preserveAspectRatio` as the document
    /// wrote it. `meet` takes the smaller of the two ratios so the whole
    /// viewBox fits and space is left over; `slice` takes the larger so the
    /// box is covered and the viewBox runs off it; `none` takes both and
    /// distorts. The alignment says where any leftover space goes -- and under
    /// `slice` the leftover is negative, which is the same arithmetic saying
    /// which part of the viewBox is kept.
    pub fn transformFor(self: Document, x: f64, y: f64, width: f64, height: f64) z2d.Transformation {
        // A document with no `viewBox` behaves as though it had one covering
        // its own size: its user units *are* pixels at the size it says it is,
        // so drawing it larger scales it, exactly as drawing a document with a
        // `viewBox` larger scales that.
        const vb = self.view_box orelse ViewBox{
            .min_x = 0,
            .min_y = 0,
            .width = self.width,
            .height = self.height,
        };
        return viewBoxTransform(vb, self.preserve_aspect_ratio, x, y, width, height);
    }
};

/// §7.8's algorithm on its own, for anything with a `viewBox` to fit into a
/// box.
///
/// The root `<svg>` is the obvious caller and `<pattern>` is the other one: a
/// pattern with a `viewBox` fits its contents into its tile by exactly this
/// rule, which is why the arithmetic lives out here rather than inside
/// `Document`.
///
/// `meet` takes the smaller of the two ratios so the whole viewBox fits and
/// space is left over; `slice` takes the larger so the box is covered and the
/// viewBox runs off it; `none` takes both and distorts. The alignment says
/// where any leftover space goes -- and under `slice` the leftover is
/// negative, which is the same arithmetic saying which part of the viewBox is
/// kept.
pub fn viewBoxTransform(
    vb: ViewBox,
    par: PreserveAspectRatio,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) z2d.Transformation {
    const ratio_x = width / vb.width;
    const ratio_y = height / vb.height;
    const scale_x, const scale_y = if (par.stretch)
        .{ ratio_x, ratio_y }
    else if (par.slice)
        .{ @max(ratio_x, ratio_y), @max(ratio_x, ratio_y) }
    else
        .{ @min(ratio_x, ratio_y), @min(ratio_x, ratio_y) };

    const spare_x = width - vb.width * scale_x;
    const spare_y = height - vb.height * scale_y;
    return .{
        .ax = scale_x,
        .by = 0,
        .cx = 0,
        .dy = scale_y,
        .tx = x + spare_x * PreserveAspectRatio.fraction(par.align_x) - vb.min_x * scale_x,
        .ty = y + spare_y * PreserveAspectRatio.fraction(par.align_y) - vb.min_y * scale_y,
    };
}

/// Walks a document's drawable elements in painting order.
///
/// A depth-first walk with an explicit stack, so that suspending one subtree to
/// draw another -- which is the whole of what `<use>` does -- costs a frame
/// rather than a second parser.
pub const PathIterator = struct {
    doc: *const Document,
    /// What a relative length is measured against.
    ///
    /// Its `font_size` is **not** fixed for the walk: it is whatever the
    /// element being read came to, so `visit` sets it on the way in and every
    /// length read from that element resolves `em` against the right number.
    /// The rest of it -- the width and height a percentage refers to -- is the
    /// document's and does not change.
    viewport: length.Viewport,
    stack: [max_container_depth + 1]Frame = undefined,
    depth: usize = 0,
    started: bool = false,

    /// Whitespace across the runs of one `<text>`: which element the runs
    /// belong to, whether any has had anything in it yet, whether the last
    /// one ended with a space it kept, and whether whitespace has been seen
    /// since that has not yet become one. See `shapes.Text.lead_space`.
    ws_owner: ?ztree.NodeId = null,
    ws_seen: bool = false,
    ws_ended: bool = false,
    ws_pending: bool = false,

    /// One open container, and where the walk has got to inside it.
    pub const Frame = struct {
        node: ztree.NodeId,
        /// The next child to look at. Counting rather than holding a slice
        /// keeps a frame small and keeps it valid across anything that might
        /// reallocate the tree's node list.
        next_child: usize,
        /// Everything the container contributes to what is inside it, already
        /// combined with its ancestors'.
        inherited: Inherited,
        transform: z2d.Transformation,
        /// Whether this container opened a layer that has to be closed when
        /// the walk leaves it.
        opens_layer: bool = false,
        /// Whether this element has yet produced a run of text. Its `x`, `y`,
        /// `dx` and `dy` belong to the first one only; what follows carries on
        /// from the pen.
        first_run: bool = true,
        /// Whether that close has already been reported.
        closed: bool = false,
        /// For a `<use>` drawn as a group, the one element inside it: what
        /// the `<use>` names, walked as though it were the `<use>`'s only
        /// child. Null for every other frame, whose children are its own.
        only_child: ?ztree.NodeId = null,
    };

    pub fn next(self: *PathIterator) Error!?Item {
        const tree = self.doc.tree;

        if (!self.started) {
            self.started = true;
            const root = self.doc.root_node;
            const opacity = try self.opacityOf(root);
            const refs = try self.refsOf(root);
            const ctm = try self.readTransform(root);
            // Nothing above the root, so an `em` in its own `font-size` has
            // nothing to be relative to and is refused.
            self.viewport.font_size = null;
            const root_inherited = try self.readInherited(root);
            self.viewport.font_size = root_inherited.font_size;
            // A root with `display="none"` hides the whole document: its
            // frame starts exhausted, so the walk yields nothing.
            const hidden = self.displayNone(root);
            self.stack[0] = .{
                .node = root,
                .next_child = if (hidden) std.math.maxInt(usize) else 0,
                .inherited = root_inherited,
                .transform = ctm,
                .opens_layer = !hidden and (opacity < 1.0 or refs.any()),
            };
            // The root is the one container the walk never meets as somebody's
            // child, so its layer is opened here rather than in `visit`.
            if (self.stack[0].opens_layer) return .{ .open_group = .{
                .node = root,
                .opacity = opacity,
                .clip_path = refs.clip_path,
                .mask = refs.mask,
                .filter = refs.filter,
                .current_color = root_inherited.current_color,
                .transform = ctm,
            } };
        }

        while (true) {
            const top = &self.stack[self.depth];
            const children: []const ztree.NodeId = if (top.only_child) |*only|
                @as(*const [1]ztree.NodeId, only)
            else
                tree.node(top.node).children.items;
            if (top.next_child >= children.len) {
                if (top.opens_layer and !top.closed) {
                    top.closed = true;
                    return .close_group;
                }
                if (self.depth == 0) return null;
                self.depth -= 1;
                continue;
            }
            const child = children[top.next_child];
            top.next_child += 1;

            // Character data inside a `<text>` or a `<tspan>` is a run of its
            // own, in the order it appears among that element's `<tspan>`
            // children. The generic walk only visits *elements*, so this is
            // where text gets to be content rather than markup.
            if (tree.node(child).kind == .text and self.carriesText()) {
                if (try self.runFrom(child, top.*)) |item| return item;
                continue;
            }

            if (try self.visit(child, top.*)) |item| return item;
        }
    }

    /// The run one piece of character data makes, or null when it is only
    /// whitespace between markup.
    ///
    /// Its position comes from the element it sits in, and only when it is
    /// that element's *first* run: `<tspan x="40">ab<tspan>cd</tspan></tspan>`
    /// puts the forty on `ab` and leaves `cd` to carry on from wherever the
    /// pen reached. Everything else about it -- the paint, the font, the
    /// anchor -- is what the element came to, which the frame already holds.
    fn runFrom(self: *PathIterator, child: ztree.NodeId, parent: Frame) Error!?Item {
        const tree = self.doc.tree;
        // `lengthAdjust="spacingAndGlyphs"` stretches the glyphs themselves
        // rather than the gaps between them, which is a different drawing and
        // not one this does. The initial value is `spacing`, which is.
        if (self.attr(parent.node, "lengthAdjust")) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r\n");
            if (!std.mem.eql(u8, t, "spacing")) return error.UnsupportedTextLayout;
        }
        // §10.13: a `<textPath>` lays its run along the shape it names, each
        // glyph turned to the tangent where it sits.
        const on_path = try self.onPathOf(parent.node);

        const rotate = self.attr(parent.node, "rotate");
        const text_length = try self.optionalLengthOf(parent.node, "textLength", .x);
        // Both index into the characters of the element as a whole, so a
        // `<tspan>` inside one that carries them would have to be counted
        // into the same sequence. Refused rather than applied per run, which
        // would put the angles on the wrong letters.
        if ((rotate != null or text_length != null) and hasElementChild(tree, parent.node)) {
            return error.UnsupportedTextLayout;
        }
        const raw = tree.node(child).value;
        const owner = self.textOwnerOf(parent.node);

        // The whitespace between runs belongs to the whole `<text>`, so it is
        // decided here, in order, rather than run by run. A run that is only
        // whitespace yields nothing and leaves a space owed to the next one --
        // `a<tspan> </tspan>b` is two words.
        if (self.ws_owner != owner) {
            self.ws_owner = owner;
            self.ws_seen = false;
            self.ws_ended = false;
            self.ws_pending = false;
        }
        if (allWhitespace(raw)) {
            if (self.ws_seen) self.ws_pending = true;
            return null;
        }
        const lead_space = self.ws_seen and !self.ws_ended and
            (isXmlSpace(raw[0]) or self.ws_pending);
        const trail_space = isXmlSpace(raw[raw.len - 1]) and self.hasLaterText(owner, child);
        self.ws_seen = true;
        self.ws_pending = false;
        self.ws_ended = trail_space;

        const first = parent.first_run;
        // A frame is shared, so the flag has to be written back to the real
        // one rather than to the copy this was handed.
        self.stack[self.depth].first_run = false;

        self.viewport.font_size = parent.inherited.font_size;
        return .{
            .shape = .{
                .geometry = .{ .text = .{
                    .utf8 = raw,
                    .x = if (first) try self.optionalLengthOf(parent.node, "x", .x) else null,
                    .y = if (first) try self.optionalLengthOf(parent.node, "y", .y) else null,
                    .dx = if (first) try self.lengthOf(parent.node, "dx", .x, 0) else 0,
                    .dy = if (first) try self.lengthOf(parent.node, "dy", .y, 0) else 0,
                    .owner = owner,
                    .starts_element = owner == parent.node and first,
                    .lead_space = lead_space,
                    .trail_space = trail_space,
                    .rotate = rotate,
                    .text_length = text_length,
                    .on_path = on_path,
                } },
                .fill = parent.inherited.fill,
                .fill_opacity = parent.inherited.fill_opacity,
                .fill_rule = parent.inherited.fill_rule,
                .clip_rule = parent.inherited.clip_rule,
                .current_color = parent.inherited.current_color,
                .stroke = parent.inherited.stroke,
                .stroke_width = parent.inherited.stroke_width,
                .stroke_opacity = parent.inherited.stroke_opacity,
                .stroke_linecap = parent.inherited.stroke_linecap,
                .stroke_linejoin = parent.inherited.stroke_linejoin,
                .stroke_miterlimit = parent.inherited.stroke_miterlimit,
                .stroke_dasharray = parent.inherited.stroke_dasharray,
                .stroke_dashoffset = parent.inherited.stroke_dashoffset,
                .font_family = parent.inherited.font_family,
                .font_size = parent.inherited.font_size,
                .font_weight = parent.inherited.font_weight,
                .font_italic = parent.inherited.font_italic,
                .text_anchor = parent.inherited.text_anchor,
                .visible = parent.inherited.visible orelse true,
                // A run has no `opacity` of its own: the element it sits in does,
                // and that element opened a layer for it if it needed one.
                .opacity = 1.0,
                .clip_path = null,
                .mask = null,
                .filter = null,
                .transform = parent.transform,
            },
        };
    }

    /// The shape a run follows, when it is inside a `<textPath>`.
    ///
    /// Looked up on the stack rather than on the element, because the run may
    /// be inside a `<tspan>` inside the `<textPath>` -- the path belongs to
    /// the nearest such ancestor, the way the `<text>` owns the chunk.
    fn onPathOf(self: *const PathIterator, node: ztree.NodeId) Error!?shapes.OnPath {
        const tree = self.doc.tree;
        var found: ?ztree.NodeId = null;
        var i = self.depth + 1;
        while (i > 0) {
            i -= 1;
            if (localIs(tree, self.stack[i].node, "textPath")) {
                found = self.stack[i].node;
                break;
            }
        }
        if (found == null and localIs(tree, node, "textPath")) found = node;
        const element = found orelse return null;

        const raw = tree.attributeValue(element, "", "href") orelse
            tree.attributeValue(element, xlink_ns, "href") orelse
            return error.BadReference;
        const target = std.mem.trim(u8, raw, " \t\r\n");
        if (target.len < 2 or target[0] != '#') return error.BadReference;
        const shape = self.doc.ids.get(target[1..]) orelse return error.UnknownReference;

        // A percentage is of the path's own length, which nothing here has
        // measured, so which kind it is has to survive as far as the renderer.
        var offset: shapes.OnPath.Offset = .{ .absolute = 0 };
        if (tree.attributeValue(element, "", "startOffset")) |text| {
            const t = std.mem.trim(u8, text, " \t\r\n");
            if (std.mem.endsWith(u8, t, "%")) {
                const v = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch
                    return error.BadLength;
                offset = .{ .fraction = v / 100.0 };
            } else {
                offset = .{ .absolute = try length.parse(t, .other, self.viewport) };
            }
        }
        return .{ .node = shape, .offset = offset };
    }

    /// The `<text>` a run belongs to: the nearest such ancestor on the stack,
    /// which is the element `text-anchor` is measured across.
    fn textOwnerOf(self: *const PathIterator, node: ztree.NodeId) ztree.NodeId {
        var i = self.depth + 1;
        while (i > 0) {
            i -= 1;
            const frame_node = self.stack[i].node;
            if (localIs(self.doc.tree, frame_node, "text")) return frame_node;
        }
        return node;
    }

    /// Whether any text that will be drawn follows `after` inside `owner`, in
    /// document order: a trailing space is only the space between two words
    /// when there is a word after it.
    fn hasLaterText(self: *const PathIterator, owner: ztree.NodeId, after: ztree.NodeId) bool {
        var passed = false;
        return self.textAfter(owner, after, &passed);
    }

    fn textAfter(self: *const PathIterator, node: ztree.NodeId, after: ztree.NodeId, passed: *bool) bool {
        const tree = self.doc.tree;
        for (tree.node(node).children.items) |c| {
            if (c == after) {
                passed.* = true;
                continue;
            }
            const n = tree.node(c);
            switch (n.kind) {
                .text => if (passed.* and !allWhitespace(n.value)) return true,
                .element => {
                    if (!(isTextish(tree, c) or localIs(tree, c, "a"))) continue;
                    if (self.displayNone(c)) continue;
                    if (self.textAfter(c, after, passed)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Whether an element says `display: none`. The only value that matters
    /// here: every other one draws the element, and CSS has a great many of
    /// them, so none is refused.
    fn displayNone(self: *const PathIterator, node: ztree.NodeId) bool {
        const raw = self.presentation(node, "display") orelse return false;
        return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "none");
    }

    /// Whether character data inside the innermost open element is text to
    /// draw: it is when that element is a `<text>`, a `<tspan>` or a
    /// `<textPath>`, and when it is an `<a>` inside one of those -- a link in
    /// the middle of a sentence is part of the sentence.
    fn carriesText(self: *const PathIterator) bool {
        const tree = self.doc.tree;
        var i = self.depth + 1;
        while (i > 0) {
            i -= 1;
            const node = self.stack[i].node;
            if (isTextish(tree, node)) return true;
            if (!localIs(tree, node, "a")) return false;
        }
        return false;
    }

    /// An element's own `opacity`, which is not inherited.
    fn opacityOf(self: *const PathIterator, node: ztree.NodeId) Error!f64 {
        const raw = self.presentation(node, "opacity") orelse return 1.0;
        return color.parseOpacity(raw);
    }

    /// What an element's `clip-path`, `mask` and `filter` name, or null for
    /// each.
    fn refsOf(self: *const PathIterator, node: ztree.NodeId) Error!Refs {
        return .{
            .clip_path = try self.referenceAttr(node, "clip-path"),
            .mask = try self.referenceAttr(node, "mask"),
            .filter = try self.referenceAttr(node, "filter"),
        };
    }

    /// The id a `url(#...)` attribute names, or null when it names nothing.
    fn referenceAttr(
        self: *const PathIterator,
        node: ztree.NodeId,
        name: []const u8,
    ) Error!?[]const u8 {
        const raw = self.presentation(node, name) orelse return null;
        const t = std.mem.trim(u8, raw, " \t\r\n");
        // `none` is the initial value and says there is nothing to apply.
        if (t.len == 0 or std.mem.eql(u8, t, "none")) return null;
        return referenceId(t) orelse error.BadReference;
    }

    /// Look at one element, following any `<use>` to what it draws.
    ///
    /// Returns a shape when the element is one, and otherwise has either
    /// pushed a frame to descend into it or decided there is nothing to do.
    fn visit(self: *PathIterator, child: ztree.NodeId, parent: Frame) Error!?Item {
        const tree = self.doc.tree;
        if (tree.node(child).kind != .element) return null;

        // Follow a chain of `<use>`, gathering what each contributes on the
        // way. A cycle is caught by `push` noticing the target is already
        // open, so the hop count is only for a chain that is finite and still
        // absurd.
        var node = child;
        var inherited = parent.inherited;
        var ctm = parent.transform;
        var hops: usize = 0;
        while (true) {
            if (!self.isSvgContent(node)) return null;
            // §11.5: `display="none"` takes the element and everything in it
            // out of the picture -- and out of it here, before anything is
            // read, so that nothing inside can be refused either. Checked on
            // every hop, because a `<use>` can be hidden and so can what it
            // names.
            if (self.displayNone(node)) return null;
            if (!localIs(tree, node, "use")) break;

            hops += 1;
            if (hops > max_use_hops) return error.TooManyUseHops;

            // The `<use>` contributes its own paint and transform, and then
            // §5.6's `x` and `y` as a translation *inside* that.
            //
            // Its `font-size` is read against what it inherited and its `x`
            // and `y` against what it came to, for the same reason the
            // element at the end of the chain does below: each `<use>` in a
            // chain is an element with a font size of its own.
            self.viewport.font_size = inherited.font_size;
            inherited = inherited.with(try self.readInherited(node));
            self.viewport.font_size = inherited.font_size;
            ctm = ctm.mul(try self.readTransform(node));
            const dx = try self.lengthOf(node, "x", .x, 0);
            const dy = try self.lengthOf(node, "y", .y, 0);
            if (dx != 0 or dy != 0) {
                ctm = ctm.mul(.{ .ax = 1, .by = 0, .cx = 0, .dy = 1, .tx = dx, .ty = dy });
            }
            const target = try self.resolve(node);

            // §5.6 draws a `<use>` as a `<g>` holding what it names, so its
            // own `opacity`, `clip-path`, `mask` and `filter` belong to that
            // group rather than being lost on the way to the target. One that
            // asks for any of them is opened as a container whose only child
            // is the target, and the walk carries on inside it -- which also
            // means a chain of such `<use>` elements nests a group apiece.
            //
            // The group's matrix includes the `<use>`'s `x` and `y`, because
            // the generated `<g>` carries them as a translation: a clip on a
            // `<use>` moves with it, as resvg's does.
            const opacity = try self.opacityOf(node);
            const refs = try self.refsOf(node);
            if (opacity < 1.0 or refs.any()) {
                try self.push(node, inherited, ctm, true);
                self.stack[self.depth].only_child = target;
                return .{ .open_group = .{
                    .node = node,
                    .opacity = opacity,
                    .clip_path = refs.clip_path,
                    .mask = refs.mask,
                    .filter = refs.filter,
                    .current_color = inherited.current_color,
                    .transform = ctm,
                } };
            }
            node = target;
        }

        const name = tree.node(node).name.local;
        if (isIgnorable(name)) return null;
        const own_ctm = ctm.mul(try self.readTransform(node));
        if (!transform.isFinite(own_ctm)) return error.NonFiniteTransform;

        // The element's own attributes, on top of everything above it -- and
        // `font-size` first, because `em` in every *other* length on this
        // element means this element's size, while `em` in `font-size` itself
        // means the *parent's*. Reading them in one pass would resolve one of
        // the two against the wrong number.
        self.viewport.font_size = inherited.font_size;
        const effective = inherited.with(try self.readInherited(node));
        self.viewport.font_size = effective.font_size;

        // Read after that, so a `filter` on an element whose `font-size` is
        // unreadable still reports the length rather than the filter.
        const refs = try self.refsOf(node);

        if (try self.readGeometry(node)) |geometry| {
            return .{ .shape = .{
                .geometry = geometry,
                .fill = effective.fill,
                .fill_opacity = effective.fill_opacity,
                .fill_rule = effective.fill_rule,
                .clip_rule = effective.clip_rule,
                .current_color = effective.current_color,
                .stroke = effective.stroke,
                .stroke_width = effective.stroke_width,
                .stroke_opacity = effective.stroke_opacity,
                .stroke_linecap = effective.stroke_linecap,
                .stroke_linejoin = effective.stroke_linejoin,
                .stroke_miterlimit = effective.stroke_miterlimit,
                .stroke_dasharray = effective.stroke_dasharray,
                .stroke_dashoffset = effective.stroke_dashoffset,
                .font_family = effective.font_family,
                .font_size = effective.font_size,
                .font_weight = effective.font_weight,
                .font_italic = effective.font_italic,
                .text_anchor = effective.text_anchor,
                .visible = effective.visible orelse true,
                .opacity = try self.opacityOf(node),
                .clip_path = refs.clip_path,
                .mask = refs.mask,
                .filter = refs.filter,
                .transform = own_ctm,
            } };
        }

        if (std.mem.eql(u8, name, "image")) return self.readImage(node, effective, refs, own_ctm);

        if (isContainer(name)) {
            // A container's `opacity` applies to it once it is flattened, so
            // it needs a surface of its own to flatten into. One that does not
            // ask for that is invisible here, as it always was.
            const opacity = try self.opacityOf(node);
            const needs_layer = opacity < 1.0 or refs.any();
            try self.push(node, effective, own_ctm, needs_layer);
            if (needs_layer) return .{ .open_group = .{
                .node = node,
                .opacity = opacity,
                .clip_path = refs.clip_path,
                .mask = refs.mask,
                .filter = refs.filter,
                .current_color = effective.current_color,
                .transform = own_ctm,
            } };
            return null;
        }

        // Refused rather than skipped: skipping it would draw a picture
        // quietly missing a piece.
        return error.UnsupportedElement;
    }

    /// An `<image>`, or null when it draws nothing.
    ///
    /// §5.7: a zero `width` or `height` disables drawing the element, and so
    /// does SVG 2's missing or empty `href`. None of the three is an error --
    /// each is the document saying there is nothing here -- so none of them is
    /// refused. A negative size is SVG 1.1's error and SVG 2's zero, and is
    /// taken the SVG 2 way, as resvg takes it.
    fn readImage(
        self: *PathIterator,
        node: ztree.NodeId,
        effective: Inherited,
        refs: Refs,
        ctm: z2d.Transformation,
    ) Error!?Item {
        const tree = self.doc.tree;
        const raw = tree.attributeValue(node, "", "href") orelse
            tree.attributeValue(node, xlink_ns, "href") orelse
            return null;
        const href = std.mem.trim(u8, raw, " \t\r\n");
        if (href.len == 0) return null;

        const width = try self.autoLengthOf(node, "width", .x);
        const height = try self.autoLengthOf(node, "height", .y);
        if (width) |w| if (!(w > 0)) return null;
        if (height) |h| if (!(h > 0)) return null;

        return .{ .image = .{
            .node = node,
            .href = href,
            .x = try self.lengthOf(node, "x", .x, 0),
            .y = try self.lengthOf(node, "y", .y, 0),
            .width = width,
            .height = height,
            .preserve_aspect_ratio = if (self.attr(node, "preserveAspectRatio")) |v|
                try PreserveAspectRatio.parse(v)
            else
                .meet_centred,
            .sampling = effective.image_rendering orelse .smooth,
            .visible = effective.visible orelse true,
            .opacity = try self.opacityOf(node),
            .clip_path = refs.clip_path,
            .mask = refs.mask,
            .filter = refs.filter,
            .current_color = effective.current_color,
            .transform = ctm,
        } };
    }

    /// A length that may also be SVG 2's `auto`, which comes back as null, as
    /// does leaving the attribute out.
    fn autoLengthOf(
        self: *const PathIterator,
        node: ztree.NodeId,
        name: []const u8,
        axis: length.Axis,
    ) Error!?f64 {
        const raw = self.attr(node, name) orelse return null;
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "auto")) return null;
        return try length.parse(raw, axis, self.viewport);
    }

    /// Open a container, having satisfied itself that it is not already open.
    ///
    /// The stack *is* the cycle check: a node that is its own ancestor in the
    /// walk is a `<use>` that draws something containing itself, and saying so
    /// the moment the loop closes is better than letting a depth limit
    /// discover it several thousand frames later.
    fn push(
        self: *PathIterator,
        node: ztree.NodeId,
        inherited: Inherited,
        ctm: z2d.Transformation,
        opens_layer: bool,
    ) Error!void {
        for (self.stack[0 .. self.depth + 1]) |frame| {
            if (frame.node == node) return error.RecursiveUse;
        }
        if (self.depth == max_container_depth) return error.TooDeeplyNested;
        self.depth += 1;
        self.stack[self.depth] = .{
            .node = node,
            .next_child = 0,
            .inherited = inherited,
            .transform = ctm,
            .opens_layer = opens_layer,
        };
    }

    /// What a `<use>` names, as a node of this document.
    fn resolve(self: *PathIterator, use: ztree.NodeId) Error!ztree.NodeId {
        const tree = self.doc.tree;
        // SVG 2 spells it `href`; SVG 1.1 spells it `xlink:href`, which is
        // what most documents in the world still carry. Both, with the plain
        // one winning as SVG 2 says.
        const raw = tree.attributeValue(use, "", "href") orelse
            tree.attributeValue(use, xlink_ns, "href") orelse
            return error.BadReference;
        const target = std.mem.trim(u8, raw, " \t\r\n");
        // Only a fragment of this document. Anything else names a file, and
        // fetching one is exactly what being sans-I/O rules out -- it is the
        // reason the renderer can be put in a process that cannot open
        // anything.
        if (target.len < 2 or target[0] != '#') return error.BadReference;
        return self.doc.ids.get(target[1..]) orelse error.UnknownReference;
    }

    /// Whether this element is SVG content at all.
    ///
    /// An element in another namespace is not, and is passed over rather than
    /// refused: an Inkscape file's `<sodipodi:namedview>` is metadata that
    /// nothing is meant to draw, and refusing it would refuse the file. An
    /// element in no namespace is taken as SVG, because a document written
    /// without `xmlns` is still one somebody means to draw.
    fn isSvgContent(self: *const PathIterator, node: ztree.NodeId) bool {
        const uri = self.doc.tree.node(node).name.uri;
        return uri.len == 0 or std.mem.eql(u8, uri, svg_ns);
    }

    // -- attributes ----------------------------------------------------------

    fn attr(self: *const PathIterator, node: ztree.NodeId, name: []const u8) ?[]const u8 {
        return self.doc.tree.attributeValue(node, "", name);
    }

    /// A presentation property: §6.3's `style` attribute first, then the
    /// presentation attribute of the same name.
    ///
    /// That order is the specification's. A `style` declaration outranks the
    /// attribute, so `fill="red" style="fill:blue"` is blue -- which is the
    /// case that matters, because a drawing program that writes `style` often
    /// writes both.
    ///
    /// Only *presentation properties* go through here. A geometry attribute --
    /// a `<rect>`'s `width`, a `<circle>`'s `r` -- is not a property in SVG
    /// 1.1 and is not readable from `style`, so those keep using `attr`.
    fn presentation(
        self: *const PathIterator,
        node: ztree.NodeId,
        name: []const u8,
    ) ?[]const u8 {
        return css.property(&self.doc.stylesheet, self.doc.tree, node, name);
    }

    fn lengthOf(
        self: *const PathIterator,
        node: ztree.NodeId,
        name: []const u8,
        axis: length.Axis,
        default: f64,
    ) Error!f64 {
        return (try self.optionalLengthOf(node, name, axis)) orelse default;
    }

    /// A length, or null when the attribute is absent.
    ///
    /// `axis` is which measure of the viewport a percentage is of, and is a
    /// property of the attribute rather than of its value: `width` and `cx`
    /// are horizontal, `height` and `cy` vertical, and `r` and `stroke-width`
    /// are neither, so they take §7.10's normalized diagonal. Getting one
    /// wrong is a shape the right size in one direction and the wrong size in
    /// the other, on documents that use percentages and nowhere else.
    fn optionalLengthOf(
        self: *const PathIterator,
        node: ztree.NodeId,
        name: []const u8,
        axis: length.Axis,
    ) Error!?f64 {
        const raw = self.attr(node, name) orelse return null;
        return try length.parse(raw, axis, self.viewport);
    }

    /// A length that is also a presentation property, so `style` may carry it:
    /// `stroke-width`, `font-size`, `stroke-dashoffset`.
    fn optionalPresentationLength(
        self: *const PathIterator,
        node: ztree.NodeId,
        name: []const u8,
        axis: length.Axis,
    ) Error!?f64 {
        const raw = self.presentation(node, name) orelse return null;
        return try length.parse(raw, axis, self.viewport);
    }

    fn readInherited(self: *const PathIterator, node: ztree.NodeId) Error!Inherited {
        return .{
            .fill = if (self.presentation(node, "fill")) |v| try color.parsePaint(v) else null,
            .fill_opacity = if (self.presentation(node, "fill-opacity")) |v| try color.parseOpacity(v) else null,
            .fill_rule = if (self.presentation(node, "fill-rule")) |v| try parseFillRule(v) else null,
            .clip_rule = if (self.presentation(node, "clip-rule")) |v| try parseFillRule(v) else null,
            .current_color = if (self.presentation(node, "color")) |v| try color.parseColor(v) else null,
            .stroke = if (self.presentation(node, "stroke")) |v| try color.parsePaint(v) else null,
            .stroke_width = try self.optionalPresentationLength(node, "stroke-width", .other),
            .stroke_opacity = if (self.presentation(node, "stroke-opacity")) |v| try color.parseOpacity(v) else null,
            .stroke_linecap = if (self.presentation(node, "stroke-linecap")) |v| try parseLineCap(v) else null,
            .stroke_linejoin = if (self.presentation(node, "stroke-linejoin")) |v| try parseLineJoin(v) else null,
            .stroke_miterlimit = if (self.presentation(node, "stroke-miterlimit")) |v| try parseMiterLimit(v) else null,
            .stroke_dasharray = self.presentation(node, "stroke-dasharray"),
            .stroke_dashoffset = try self.optionalPresentationLength(node, "stroke-dashoffset", .other),
            .font_family = self.presentation(node, "font-family"),
            .font_size = try self.optionalPresentationLength(node, "font-size", .other),
            .font_weight = if (self.presentation(node, "font-weight")) |v| try parseFontWeight(v) else null,
            .font_italic = if (self.presentation(node, "font-style")) |v| try parseFontStyle(v) else null,
            .text_anchor = if (self.presentation(node, "text-anchor")) |v| try parseTextAnchor(v) else null,
            .image_rendering = if (self.presentation(node, "image-rendering")) |v| try parseImageRendering(v) else null,
            .visible = if (self.presentation(node, "visibility")) |v| try parseVisibility(v) else null,
        };
    }

    fn readTransform(self: *const PathIterator, node: ztree.NodeId) Error!z2d.Transformation {
        const raw = self.attr(node, "transform") orelse return .identity;
        return transform.parse(raw);
    }

    /// What an element draws, or null when it is not a drawable one.
    ///
    /// The basic shapes are read here rather than being turned into `d`
    /// strings for the path parser: their geometry is four or five numbers
    /// this already has, and spelling them out as text to read back would
    /// allocate and would put a number formatter and a second number parser in
    /// the way of the picture. See `shapes.zig`.
    fn readGeometry(self: *const PathIterator, node: ztree.NodeId) Error!?shapes.Geometry {
        const name = self.doc.tree.node(node).name.local;
        if (std.mem.eql(u8, name, "path")) {
            return .{ .path = self.attr(node, "d") orelse return error.NoPath };
        }
        if (std.mem.eql(u8, name, "rect")) {
            return .{
                .rect = .{
                    .x = try self.lengthOf(node, "x", .x, 0),
                    .y = try self.lengthOf(node, "y", .y, 0),
                    .width = try self.lengthOf(node, "width", .x, 0),
                    .height = try self.lengthOf(node, "height", .y, 0),
                    // Null rather than zero: §9.2 makes one specified radius
                    // supply the other, which "not specified" has to be
                    // distinguishable from zero to express.
                    .rx = try self.optionalLengthOf(node, "rx", .x),
                    .ry = try self.optionalLengthOf(node, "ry", .y),
                },
            };
        }
        if (std.mem.eql(u8, name, "circle")) {
            const r = try self.lengthOf(node, "r", .other, 0);
            return .{ .ellipse = .{
                .cx = try self.lengthOf(node, "cx", .x, 0),
                .cy = try self.lengthOf(node, "cy", .y, 0),
                .rx = r,
                .ry = r,
            } };
        }
        if (std.mem.eql(u8, name, "ellipse")) {
            return .{ .ellipse = .{
                .cx = try self.lengthOf(node, "cx", .x, 0),
                .cy = try self.lengthOf(node, "cy", .y, 0),
                .rx = try self.lengthOf(node, "rx", .x, 0),
                .ry = try self.lengthOf(node, "ry", .y, 0),
            } };
        }
        if (std.mem.eql(u8, name, "line")) {
            return .{ .line = .{
                .x1 = try self.lengthOf(node, "x1", .x, 0),
                .y1 = try self.lengthOf(node, "y1", .y, 0),
                .x2 = try self.lengthOf(node, "x2", .x, 0),
                .y2 = try self.lengthOf(node, "y2", .y, 0),
            } };
        }
        if (std.mem.eql(u8, name, "polyline")) {
            return .{ .poly = .{ .points = self.attr(node, "points") orelse "", .closed = false } };
        }
        if (std.mem.eql(u8, name, "polygon")) {
            return .{ .poly = .{ .points = self.attr(node, "points") orelse "", .closed = true } };
        }
        return null;
    }
};

/// Whether an attribute value names a resource rather than saying `none`.
fn namesSomething(raw: ?[]const u8) bool {
    const t = std.mem.trim(u8, raw orelse return false, " \t\r\n");
    return t.len != 0 and !std.mem.eql(u8, t, "none");
}

/// The id inside a `url(#id)`, or null when the value is not one.
fn referenceId(t: []const u8) ?[]const u8 {
    if (t.len < 7) return null;
    if (!std.ascii.eqlIgnoreCase(t[0..4], "url(")) return null;
    if (t[t.len - 1] != ')') return null;
    const inner = std.mem.trim(u8, t[4 .. t.len - 1], " \t\r\n'\"");
    if (inner.len < 2 or inner[0] != '#') return null;
    return inner[1..];
}

/// The elements that hold other elements and pass their own attributes down.
///
/// The root is one of these, which is what lets `<svg>` and `<g>` share a code
/// path rather than the root being a special case that drifts from the general
/// one.
fn isContainer(name: []const u8) bool {
    return std.mem.eql(u8, name, "svg") or std.mem.eql(u8, name, "g") or
        // A link is a group as far as drawing goes: §17.1 gives it nothing to
        // paint and nothing to change, and what is inside it is drawn as
        // though it were not there.
        std.mem.eql(u8, name, "a") or
        isTextishName(name);
}

/// Whether an element holds runs of text: a `<text>` or a `<tspan>`.
///
/// Both are containers here, which is what lets the walk descend into one and
/// meet its character data and its `<tspan>` children in document order. That
/// order is the whole of text layout: the runs share a pen, and which one
/// comes first decides where the next begins.
fn isTextishName(name: []const u8) bool {
    return std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "tspan") or
        std.mem.eql(u8, name, "textPath");
}

fn isTextish(tree: *const ztree.Document, node: ztree.NodeId) bool {
    return isTextishName(tree.node(node).name.local);
}

/// XML's whitespace characters.
fn isXmlSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Whether a piece of character data is only the whitespace between markup.
///
/// `<text>\n  <tspan>a</tspan>\n</text>` has character data on either side of
/// the tspan that the document did not mean as text. Collapsing would leave a
/// single space, and SVG's own rule agrees that leading and trailing
/// whitespace in a text element goes -- so a run that is nothing else is not a
/// run at all.
/// Whether an element has any element children -- a `<tspan>`, for a `<text>`.
fn hasElementChild(tree: *const ztree.Document, node: ztree.NodeId) bool {
    for (tree.node(node).children.items) |child| {
        if (tree.node(child).kind == .element) return true;
    }
    return false;
}

fn allWhitespace(raw: []const u8) bool {
    for (raw) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        else => return false,
    };
    return true;
}

/// The elements that are not drawn where they stand.
///
/// Two kinds, and they are passed over for two different reasons.
///
/// `<title>`, `<desc>` and `<metadata>` carry no geometry at all, and neither
/// does `<style>`, whose text was read into the document's stylesheet before
/// the walk began. `<defs>` carries plenty and says not to draw it, which is
/// what `<defs>` is for.
///
/// The rest are *definitions*: a gradient, a clip path, a mask, a pattern, a
/// symbol, a marker, a filter. §5.5 says none of them is rendered directly --
/// each exists to be named by something else -- and that is true wherever they
/// are written. Putting them in `<defs>` is a convention rather than a
/// requirement, and a document that writes a `<linearGradient>` straight into
/// the body used to be refused for it.
///
/// Every one of them stays in the tree and stays indexed, so a reference still
/// finds it.
fn isIgnorable(name: []const u8) bool {
    const names = [_][]const u8{
        "title",          "desc",           "metadata", "defs",     "style",
        "linearGradient", "radialGradient", "pattern",  "clipPath", "mask",
        "symbol",         "marker",         "filter",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn localIs(tree: *const ztree.Document, node: ztree.NodeId, name: []const u8) bool {
    return std.mem.eql(u8, tree.node(node).name.local, name);
}

/// `nonzero` or `evenodd`, and nothing else.
///
/// Matched with regard to case, unlike a colour name. The difference is real
/// and it is not an inconsistency: a colour keyword is CSS, where keywords are
/// ASCII case-insensitive, while this is an XML attribute value, where they
/// are not. resvg draws `fill-rule="EVENODD"` with the nonzero rule, which is
/// the same reading.
/// §10.9's `text-anchor`. Matched with regard to case, like the other
/// presentation attributes that are not colours.
fn parseTextAnchor(raw: []const u8) Error!TextAnchor {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, t, "start")) return .start;
    if (std.mem.eql(u8, t, "middle")) return .middle;
    if (std.mem.eql(u8, t, "end")) return .end;
    // `inherit` is the CSS keyword for "what the parent said", which is what
    // leaving the attribute out already does here.
    if (std.mem.eql(u8, t, "inherit")) return error.BadTextAnchor;
    return error.BadTextAnchor;
}

/// §11.5's `visibility`. `collapse` is `hidden` for anything that is not a
/// table row, which nothing in SVG is.
fn parseVisibility(raw: []const u8) Error!bool {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, t, "visible")) return true;
    if (std.mem.eql(u8, t, "hidden") or std.mem.eql(u8, t, "collapse")) return false;
    return error.BadVisibility;
}

/// `image-rendering`: SVG 1.1's three keywords and CSS Images 3's four.
///
/// Only the difference between smooth and hard edges survives, because that
/// is the only difference any renderer draws: `optimizeQuality` and
/// `high-quality` are what `auto` already does here, and `crisp-edges` asks
/// for "an algorithm that preserves contrast" which in practice every
/// implementation, resvg included, answers with nearest-neighbour.
fn parseImageRendering(raw: []const u8) Error!resample.Sampling {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    const smooth = [_][]const u8{ "auto", "optimizeQuality", "smooth", "high-quality" };
    const nearest = [_][]const u8{ "optimizeSpeed", "pixelated", "crisp-edges" };
    for (smooth) |k| if (std.mem.eql(u8, t, k)) return .smooth;
    for (nearest) |k| if (std.mem.eql(u8, t, k)) return .nearest;
    return error.BadImageRendering;
}

/// §10.10's `font-weight`, as the number the resolver is asked for.
///
/// The numeric spellings and the two names. `bolder` and `lighter` are
/// relative to the inherited weight, which means resolving them against what
/// the parent said rather than against a fixed table, and nothing here has
/// asked for them yet.
fn parseFontWeight(raw: []const u8) Error!u16 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, t, "normal")) return 400;
    if (std.mem.eql(u8, t, "bold")) return 700;
    const n = std.fmt.parseInt(u16, t, 10) catch return error.BadFontWeight;
    if (n < 1 or n > 1000) return error.BadFontWeight;
    return n;
}

/// §10.10's `font-style`, as whether the face is italic.
///
/// `oblique` is a slanted upright rather than a true italic, and a resolver
/// asked for one and given the other is closer than a resolver asked for
/// nothing -- so both ask for an italic face here.
fn parseFontStyle(raw: []const u8) Error!bool {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, t, "normal")) return false;
    if (std.mem.eql(u8, t, "italic") or std.mem.eql(u8, t, "oblique")) return true;
    return error.BadFontStyle;
}

fn parseFillRule(text: []const u8) Error!z2d.options.FillRule {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, t, "nonzero")) return .non_zero;
    if (std.mem.eql(u8, t, "evenodd")) return .even_odd;
    return error.BadFillRule;
}

/// `butt`, `round` or `square`, matched with regard to case.
fn parseLineCap(text: []const u8) Error!z2d.options.CapMode {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, t, "butt")) return .butt;
    if (std.mem.eql(u8, t, "round")) return .round;
    if (std.mem.eql(u8, t, "square")) return .square;
    return error.BadStrokeStyle;
}

/// `miter`, `round` or `bevel`, matched with regard to case.
fn parseLineJoin(text: []const u8) Error!z2d.options.JoinMode {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, t, "miter")) return .miter;
    if (std.mem.eql(u8, t, "round")) return .round;
    if (std.mem.eql(u8, t, "bevel")) return .bevel;
    return error.BadStrokeStyle;
}

/// A `stroke-miterlimit`, which §11.4 says is at least one.
///
/// Clamped rather than refused, because resvg clamps: `stroke-miterlimit="0.5"`
/// draws exactly what `"1"` draws. A number below one asks for a miter shorter
/// than the join itself, which is not a limit anyone means.
fn parseMiterLimit(text: []const u8) Error!f64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const value = std.fmt.parseFloat(f64, t) catch return error.BadStrokeStyle;
    if (std.math.isNan(value)) return error.BadStrokeStyle;
    return @max(1.0, value);
}

/// Read a document and satisfy yourself it can be drawn.
///
/// The returned `Document` owns the tree it was read from; `deinit` it. `src`
/// may be freed as soon as this returns, because every string in the tree is a
/// copy in the tree's own arena.
///
/// ## Why this drains the iterator
///
/// Everything a document can be refused for is refused here, before the caller
/// has drawn anything: a `<text>` at the end of a document is an error rather
/// than four shapes painted and then an error.
///
/// The obvious way to do that is a validating walk beside the drawing one --
/// and it was, and the two drifted twice. So there is one walk: `read` finds
/// the root and then runs the *same* iterator the renderer will, to the end,
/// throwing the shapes away. Whatever it refuses, `read` refuses, and
/// `shape_count` is the number it produced rather than a number counted
/// alongside it. Agreement is not tested for here, it is the only thing that
/// can happen.
pub fn read(gpa: std.mem.Allocator, src: []const u8) Error!Document {
    // `.strict` on entities, so a name the document never declared is an error
    // rather than text that survives into a parser which will call it
    // something less helpful. Nothing external is fetched under any setting.
    const tree = try ztree.parse(gpa, src, .{ .entities = .strict });
    errdefer tree.destroy();

    var doc: Document = .{
        .tree = tree,
        .root_node = undefined,
        .ids = .empty,
        .view_box = null,
        .width = 0,
        .height = 0,
        .preserve_aspect_ratio = .meet_centred,
        .shape_count = 0,
        .root = .{},
        .stylesheet = .{},
    };
    errdefer doc.stylesheet.deinit();

    const root = tree.documentElement() orelse return error.NotAnSvg;
    if (!std.mem.eql(u8, tree.node(root).name.local, "svg")) return error.NotAnSvg;
    doc.root_node = root;

    try indexIds(&doc);
    // Before anything reads a property, because from here on every one of them
    // goes through the cascade.
    try readStylesheet(gpa, &doc);
    try readRoot(&doc, root);

    var it = doc.paths();
    var count: usize = 0;
    while (try it.next()) |item| {
        // Shapes and pictures, not items: `shape_count` is what
        // `Limits.max_shapes` bounds, and a group is not a thing that gets
        // painted.
        if (item == .shape or item == .image) count += 1;
    }
    if (count == 0) return error.NoPath;
    doc.shape_count = count;
    return doc;
}

/// Every element carrying an `id`, so that a reference resolves in one lookup.
///
/// Built once over the whole tree rather than scanned per reference, because
/// every feature still to come -- a gradient, a clip path, a mask -- names one
/// the same way, and a scan apiece would be quadratic in a document made of
/// references.
///
/// The first of a duplicated id wins, which is what a document scanned in
/// order would find, and what browsers do.
fn indexIds(doc: *Document) Error!void {
    const arena = doc.tree.alloc();
    for (doc.tree.nodes.items, 0..) |node, id| {
        if (node.kind != .element) continue;
        const value = doc.tree.attributeValue(@intCast(id), "", "id") orelse continue;
        if (value.len == 0) continue;
        const slot = try doc.ids.getOrPut(arena, value);
        if (!slot.found_existing) slot.value_ptr.* = @intCast(id);
    }
}

/// Parse every `<style>` element of the document into one stylesheet.
///
/// §6.2 makes them one sheet in document order, which is what breaks a
/// specificity tie between two of them. The text of each is concatenated from
/// its children, so a `<style>` written as CDATA -- which is how a document
/// with a `>` in a selector has to write it -- reads the same as one written
/// as plain text.
fn readStylesheet(gpa: std.mem.Allocator, doc: *Document) Error!void {
    const arena = doc.tree.alloc();
    var sources: std.ArrayList([]const u8) = .empty;
    defer sources.deinit(gpa);

    for (doc.tree.nodes.items, 0..) |node, id| {
        if (node.kind != .element) continue;
        if (!std.mem.eql(u8, node.name.local, "style")) continue;
        const elem: ztree.NodeId = @intCast(id);
        if (!try isStyleSheet(doc.tree, elem)) continue;
        // Into the tree's arena, so the selectors and blocks the parser slices
        // out of it live exactly as long as the tree does.
        const text = try doc.tree.stringValue(arena, elem);
        if (text.len == 0) continue;
        try sources.append(gpa, text);
    }
    if (sources.items.len == 0) return;
    doc.stylesheet = try css.parse(gpa, sources.items);
}

/// Whether a `<style>` element holds CSS this should read.
///
/// `type` says what the content is, and a type that is not CSS means the
/// element is not a stylesheet at all -- there is nothing being dropped by
/// passing over it, and resvg passes over it too. `media` is the opposite
/// case: it says the rules apply somewhere, and skipping them would lose rules
/// the document meant, so anything but a medium this renders for is refused.
fn isStyleSheet(tree: *const ztree.Document, node: ztree.NodeId) Error!bool {
    if (tree.attributeValue(node, "", "type")) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len != 0 and !std.mem.eql(u8, t, "text/css")) return false;
    }
    if (tree.attributeValue(node, "", "media")) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len != 0 and !std.mem.eql(u8, t, "all") and !std.mem.eql(u8, t, "screen")) {
            return error.UnsupportedAtRule;
        }
    }
    return true;
}

/// The root `<svg>`'s own attributes.
///
/// `width` and `height` are read against a viewport that is not known yet,
/// which is not the circularity it looks like: a percentage there would be of
/// the *parent* viewport, and a standalone document has none. So a percentage
/// resolves to zero and the `viewBox` supplies the size instead, which is what
/// resvg does with the `width="100%" height="100%"` that drawing programs like
/// to write.
fn readRoot(doc: *Document, root: ztree.NodeId) Error!void {
    const tree = doc.tree;
    if (tree.attributeValue(root, "", "viewBox")) |raw| {
        doc.view_box = try parseViewBox(raw);
    }

    const named_width = if (tree.attributeValue(root, "", "width")) |raw|
        try length.parse(raw, .x, .unknown)
    else
        null;
    const named_height = if (tree.attributeValue(root, "", "height")) |raw|
        try length.parse(raw, .y, .unknown)
    else
        null;

    // A named size wins, unless it came out as nothing -- which is what a
    // percentage of an unknown viewport does, and what `width="0"` means as
    // well. The viewBox is the fallback, and with neither there is nothing to
    // say how big the picture is.
    doc.width = pick(named_width, if (doc.view_box) |vb| vb.width else null) orelse
        return error.NoSize;
    doc.height = pick(named_height, if (doc.view_box) |vb| vb.height else null) orelse
        return error.NoSize;

    if (tree.attributeValue(root, "", "preserveAspectRatio")) |raw| {
        doc.preserve_aspect_ratio = try PreserveAspectRatio.parse(raw);
    }

    var it = doc.paths();
    doc.root = try it.readInherited(root);
}

/// The first of the two that is a usable extent.
fn pick(named: ?f64, fallback: ?f64) ?f64 {
    if (named) |v| if (v > 0) return v;
    if (fallback) |v| if (v > 0) return v;
    return null;
}

/// `min-x min-y width height`, separated by whitespace or commas.
pub fn parseViewBox(raw: []const u8) Error!ViewBox {
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    var v: [4]f64 = undefined;
    for (&v) |*slot| {
        const tok = it.next() orelse return error.BadViewBox;
        slot.* = std.fmt.parseFloat(f64, tok) catch return error.BadViewBox;
        if (!std.math.isFinite(slot.*)) return error.BadViewBox;
    }
    if (it.next() != null) return error.BadViewBox;
    if (v[2] <= 0 or v[3] <= 0) return error.BadViewBox;
    return .{ .min_x = v[0], .min_y = v[1], .width = v[2], .height = v[3] };
}

pub const BuildError = Error || shapes.BuildError;

/// z2d does not re-export its path node type, so it is named through the
/// field that holds them rather than spelled out.
const PathNode = std.meta.Elem(@FieldType(z2d.Path, "nodes").Slice);

/// Build one shape's geometry into `p`, under `ctm`.
///
/// z2d applies the transformation when a point is added rather than when the
/// path is filled, so it has to be in place before the first `moveTo`; this
/// puts it there and takes it away again.
pub fn buildShape(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    geometry: shapes.Geometry,
    ctm: z2d.Transformation,
    opts: path.Options,
) BuildError!void {
    const first = p.nodes.items.len;
    {
        const saved = p.transformation;
        defer p.transformation = saved;
        p.transformation = saved.mul(ctm);
        try shapes.build(p, alloc, geometry, opts);
    }
    // Checked here rather than in `path.build`, because z2d applies the matrix
    // when a point is added: the numbers the parser read are in user units and
    // the ones that reach the rasterizer are these.
    try checkInRange(p.nodes.items[first..]);
}

/// Refuses points the rasterizer would panic on.
///
/// The parser already refuses a number that is not finite, and `transform`
/// refuses a matrix that is not -- but a perfectly finite matrix applied to a
/// perfectly finite point produces `scale(1e300)` times four, and z2d reduces
/// a polygon's extent to an `i32`. See `max_coordinate`.
fn checkInRange(nodes: []const PathNode) Error!void {
    for (nodes) |node| switch (node) {
        .move_to => |n| try checkPoint(n.point),
        .line_to => |n| try checkPoint(n.point),
        .curve_to => |n| {
            try checkPoint(n.p1);
            try checkPoint(n.p2);
            try checkPoint(n.p3);
        },
        .close_path => {},
    };
}

fn checkPoint(point: anytype) Error!void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) {
        return error.CoordinateOutOfRange;
    }
    if (@abs(point.x) > max_coordinate or @abs(point.y) > max_coordinate) {
        return error.CoordinateOutOfRange;
    }
}
// -- tests -------------------------------------------------------------------

const testing = std.testing;

const icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3,9H7L12,4V20L7,15H3V9Z" /></svg>
;

/// Every `d` in a document, copied, for a test to look at.
///
/// Copied because the tree they borrow from is freed on the way out -- which
/// is the whole point of the tree owning what it read.
fn collect(gpa: std.mem.Allocator, src: []const u8) ![][]u8 {
    var doc = try read(gpa, src);
    defer doc.deinit();
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |d| gpa.free(d);
        out.deinit(gpa);
    }
    var it = doc.paths();
    while (try it.next()) |item| switch (item) {
        .shape => |shape| try out.append(gpa, try gpa.dupe(u8, shape.geometry.path)),
        // A group is not a shape; `collect` is about what gets drawn.
        else => {},
    };
    return out.toOwnedSlice(gpa);
}

fn freeCollected(gpa: std.mem.Allocator, found: [][]u8) void {
    for (found) |d| gpa.free(d);
    gpa.free(found);
}

/// A document read and immediately measured, for a test that wants one matrix
/// out of it rather than the document itself.
fn transformOf(src: []const u8, width: f64, height: f64) !z2d.Transformation {
    var doc = try read(testing.allocator, src);
    defer doc.deinit();
    return doc.transformFor(0, 0, width, height);
}

test "a well formed icon reads" {
    var doc = try read(testing.allocator, icon);
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 0), doc.view_box.?.min_x);
    try testing.expectEqual(@as(f64, 24), doc.view_box.?.width);
    // With no `width` or `height`, the viewBox's extent is the size.
    try testing.expectEqual(@as(f64, 24), doc.width);
    try testing.expectEqual(@as(f64, 24), doc.height);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);

    var it = doc.paths();
    try testing.expectEqualStrings("M3,9H7L12,4V20L7,15H3V9Z", (try it.next()).?.shape.geometry.path);
    try testing.expectEqual(@as(?Item, null), try it.next());
}

test "every path is handed out, in document order" {
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 24 24">
        \\  <path d="M0 0L1 1Z"/>
        \\  <path d="M2 2L3 3Z"/>
        \\  <path d="M4 4L5 5Z"/>
        \\</svg>
    ;
    var doc = try read(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.shape_count);

    const found = try collect(gpa, src);
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("M0 0L1 1Z", found[0]);
    try testing.expectEqualStrings("M2 2L3 3Z", found[1]);
    try testing.expectEqualStrings("M4 4L5 5Z", found[2]);
}

test "a path inside an ignored element is not a shape" {
    // `<defs>` holds things to be referenced rather than drawn, and nothing
    // here implements `<use>`, so what is in it is not painted.
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 24 24"><defs><path d="M9 9Z"/></defs><path d="M0 0L2 2Z"/></svg>
    ;
    var doc = try read(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.shape_count);

    const found = try collect(gpa, src);
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("M0 0L2 2Z", found[0]);
}

test "the reader and the iterator agree on what a shape is" {
    // True by construction now that `read` drains the iterator rather than
    // walking beside it, so this cannot fail without someone having put a
    // second walk back. That is exactly what it is here to notice: the two
    // walks drifted twice before they were made one.
    const gpa = testing.allocator;
    const documents = [_][]const u8{
        icon,
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><defs><path d=\"M9 9Z\"/></defs><path d=\"M0 0Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><defs><title>x</title><path d=\"M9 9Z\"/></defs><path d=\"M0 0Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><title>x</title><path d=\"M0 0Z\"/><desc>y</desc><path d=\"M1 1Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><metadata/><path d=\"M0 0Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><g><path d=\"M0 0Z\"/></g></svg>",
        "<svg viewBox=\"0 0 24 24\"><g><g><path d=\"M0 0Z\"/></g><path d=\"M1 1Z\"/></g></svg>",
        "<svg viewBox=\"0 0 24 24\"><g/><path d=\"M0 0Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><g><defs><path d=\"M9 9Z\"/></defs><path d=\"M0 0Z\"/></g></svg>",
    };
    for (documents) |src| {
        var doc = try read(testing.allocator, src);
        defer doc.deinit();
        const found = try collect(gpa, src);
        defer freeCollected(gpa, found);
        try testing.expectEqual(doc.shape_count, found.len);
    }
}

test "a self-closing container does not disturb its siblings" {
    // zxml reports a synthetic end tag for `<g/>`, so a container that opened
    // without pushing had that end pop its *parent*. The shape after the
    // `<g/>` then drew under the outer group's transform having escaped it.
    const gpa = testing.allocator;
    const found = try collect(gpa, "<svg viewBox=\"0 0 8 8\"><g/><g></g>" ++
        "<g transform=\"translate(4,4)\"><g/><path d=\"M0 0H2V2H0Z\"/></g>" ++
        "<path d=\"M0 0H2V2H0Z\"/></svg>");
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 2), found.len);
}

test "a self-closing ignorable does not end the subtree it is in" {
    // The counter used to come down on *any* end tag while inside a `<defs>`,
    // so a `<title/>` in there ended the skipping early and everything after
    // it was drawn.
    const gpa = testing.allocator;
    const src = "<svg viewBox=\"0 0 8 8\"><defs><title/><path d=\"M9 9Z\"/></defs>" ++
        "<path d=\"M0 0Z\"/></svg>";
    var doc = try read(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
    const found = try collect(gpa, src);
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("M0 0Z", found[0]);
}

test "an element with geometry this reader cannot draw is refused" {
    try testing.expectError(
        error.UnsupportedElement,
        read(testing.allocator, "<svg viewBox=\"0 0 24 24\"><foreignObject/></svg>"),
    );
    try testing.expectError(
        error.UnsupportedElement,
        read(testing.allocator, "<svg viewBox=\"0 0 24 24\"><switch/></svg>"),
    );
}

/// The one `<image>` a document yields, for looking at.
fn onlyImage(doc: *const Document) !Image {
    var it = doc.paths();
    var found: ?Image = null;
    while (try it.next()) |item| switch (item) {
        .image => |im| {
            if (found != null) return error.TestUnexpectedResult;
            found = im;
        },
        else => {},
    };
    return found orelse error.TestUnexpectedResult;
}

test "an image is read with its rectangle, its fit and its URL" {
    var doc = try read(testing.allocator,
        \\<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
        \\     viewBox="0 0 100 100" image-rendering="optimizeSpeed">
        \\  <image xlink:href=" data:image/png;base64,AAAA " x="10" y="20" width="30" height="40"
        \\         preserveAspectRatio="xMinYMax slice" opacity="0.5" transform="translate(1 2)"/>
        \\</svg>
    );
    defer doc.deinit();
    const im = try onlyImage(&doc);
    try testing.expectEqualStrings("data:image/png;base64,AAAA", im.href);
    try testing.expectEqual(@as(f64, 10), im.x);
    try testing.expectEqual(@as(f64, 20), im.y);
    try testing.expectEqual(@as(?f64, 30), im.width);
    try testing.expectEqual(@as(?f64, 40), im.height);
    try testing.expectEqual(
        PreserveAspectRatio{ .align_x = .min, .align_y = .max, .slice = true },
        im.preserve_aspect_ratio,
    );
    // Inherited from the root.
    try testing.expectEqual(resample.Sampling.nearest, im.sampling);
    try testing.expectEqual(@as(f64, 0.5), im.opacity);
    try testing.expectEqual(@as(f64, 1), im.transform.tx);
    try testing.expectEqualStrings("image", doc.tree.node(im.node).name.local);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
}

test "the plain href wins, and a missing size is auto" {
    var doc = try read(testing.allocator,
        \\<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">
        \\  <image href="a.png" xlink:href="b.png" width="auto"/>
        \\</svg>
    );
    defer doc.deinit();
    const im = try onlyImage(&doc);
    try testing.expectEqualStrings("a.png", im.href);
    try testing.expectEqual(@as(?f64, null), im.width);
    try testing.expectEqual(@as(?f64, null), im.height);
    try testing.expectEqual(resample.Sampling.smooth, im.sampling);
    try testing.expectEqual(PreserveAspectRatio.meet_centred, im.preserve_aspect_ratio);
}

test "an image that draws nothing is passed over rather than refused" {
    // No href, an empty one, and a zero or negative size are each the
    // document saying there is nothing here. With nothing else in it, the
    // document has nothing to draw at all.
    const nothing = [_][]const u8{
        "<svg viewBox=\"0 0 10 10\"><image width=\"4\" height=\"4\"/></svg>",
        "<svg viewBox=\"0 0 10 10\"><image href=\"  \"/></svg>",
        "<svg viewBox=\"0 0 10 10\"><image href=\"a.png\" width=\"0\"/></svg>",
        "<svg viewBox=\"0 0 10 10\"><image href=\"a.png\" height=\"-3\"/></svg>",
    };
    for (nothing) |src| try testing.expectError(error.NoPath, read(testing.allocator, src));
}

test "a use of an image reaches the image" {
    var doc = try read(testing.allocator,
        \\<svg viewBox="0 0 10 10">
        \\  <defs><image id="pic" href="a.png" width="2" height="2"/></defs>
        \\  <use href="#pic" x="3" y="4"/>
        \\</svg>
    );
    defer doc.deinit();
    const im = try onlyImage(&doc);
    try testing.expectEqual(@as(f64, 3), im.transform.tx);
    try testing.expectEqual(@as(f64, 4), im.transform.ty);
    try testing.expectEqual(doc.ids.get("pic").?, im.node);
}

test "image-rendering takes both vocabularies and refuses anything else" {
    try testing.expectEqual(resample.Sampling.smooth, try parseImageRendering("auto"));
    try testing.expectEqual(resample.Sampling.smooth, try parseImageRendering(" optimizeQuality "));
    try testing.expectEqual(resample.Sampling.nearest, try parseImageRendering("pixelated"));
    try testing.expectEqual(resample.Sampling.nearest, try parseImageRendering("crisp-edges"));
    try testing.expectError(error.BadImageRendering, parseImageRendering("OPTIMIZESPEED"));
    try testing.expectError(error.BadImageRendering, parseImageRendering("blurry"));
}

test "a document is refused before any of it is drawn" {
    // The `<g>` is last, after two perfectly good shapes. Reading has to fail
    // rather than hand out those two and fail on the third, which would be a
    // half-drawn picture and an error at once.
    try testing.expectError(error.UnsupportedElement, read(
        testing.allocator,
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/><foreignObject/></svg>",
    ));
    try testing.expectError(error.NoPath, read(
        testing.allocator,
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path/></svg>",
    ));
}

test "elements that carry no geometry are passed over" {
    var doc = try read(
        testing.allocator,
        "<svg viewBox=\"0 0 24 24\"><title>x</title><desc>y</desc><path d=\"M0 0L2 2Z\"/></svg>",
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
}

test "a viewBox that is not four positive numbers is refused" {
    try testing.expectError(error.BadViewBox, read(testing.allocator, "<svg viewBox=\"0 0\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read(testing.allocator, "<svg viewBox=\"0 0 0 0\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read(testing.allocator, "<svg viewBox=\"0 0 1 1 1\"><path d=\"M0 0Z\"/></svg>"));
    // A document with no `viewBox` at all is not a bad viewBox -- it is a
    // document whose user units are pixels, and which has to say how large it
    // is some other way.
    try testing.expectError(error.NoSize, read(testing.allocator, "<svg><path d=\"M0 0Z\"/></svg>"));
}

test "a document with no path is refused" {
    try testing.expectError(error.NoPath, read(testing.allocator, "<svg viewBox=\"0 0 24 24\"></svg>"));
    try testing.expectError(error.NoPath, read(testing.allocator, "<svg viewBox=\"0 0 24 24\"><path/></svg>"));
}

test "the viewBox is scaled into the box asked for" {
    const gpa = testing.allocator;
    var doc = try read(testing.allocator, icon);
    defer doc.deinit();
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    // A 24-unit viewBox into a 48-pixel box doubles everything.
    var it = doc.paths();
    try buildShape(&p, gpa, (try it.next()).?.shape.geometry, doc.transformFor(0, 0, 48, 48), .{});
    try testing.expectApproxEqAbs(@as(f64, 6), p.nodes.items[0].move_to.point.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 18), p.nodes.items[0].move_to.point.y, 1e-9);
}

test "a box of a different shape letterboxes rather than distorting" {
    var doc = try read(testing.allocator, icon);
    defer doc.deinit();
    // 48 wide by 24 tall: the scale is 1, and the drawing is centred.
    const t = doc.transformFor(0, 0, 48, 24);
    try testing.expectApproxEqAbs(@as(f64, 1), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), t.dy, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), t.ty, 1e-12);
}

test "preserveAspectRatio is read in all its spellings" {
    try testing.expectEqual(PreserveAspectRatio{}, try PreserveAspectRatio.parse("xMidYMid meet"));
    try testing.expectEqual(PreserveAspectRatio{}, try PreserveAspectRatio.parse("xMidYMid"));
    try testing.expectEqual(
        PreserveAspectRatio{ .align_x = .min, .align_y = .max, .slice = true },
        try PreserveAspectRatio.parse("xMinYMax slice"),
    );
    try testing.expectEqual(
        PreserveAspectRatio{ .stretch = true },
        try PreserveAspectRatio.parse("none"),
    );
    // `defer` applies to a `<use>` of an image and means nothing here, so it
    // is read and dropped rather than refused.
    try testing.expectEqual(
        PreserveAspectRatio{ .align_x = .max, .align_y = .min },
        try PreserveAspectRatio.parse("defer xMaxYMin meet"),
    );
    try testing.expectEqual(
        PreserveAspectRatio{},
        try PreserveAspectRatio.parse("  xMidYMid   meet  "),
    );
}

test "a preserveAspectRatio that is not one is refused" {
    for ([_][]const u8{
        "",
        "bogus",
        "XMidYMid",
        "xmidymid",
        "xMidYMid MEET",
        "xMidYMid meet slice",
        "xMidYMi",
        "xQidYMid",
        "none meet extra",
    }) |t| {
        try testing.expectError(error.BadPreserveAspectRatio, PreserveAspectRatio.parse(t));
    }
}

test "a document says how large it is" {
    // `width` and `height` win.
    var sized = try read(testing.allocator, "<svg width=\"64\" height=\"32\" viewBox=\"0 0 16 16\"><path d=\"M0 0Z\"/></svg>");
    defer sized.deinit();
    try testing.expectEqual(@as(f64, 64), sized.width);
    try testing.expectEqual(@as(f64, 32), sized.height);
    // The viewBox's extent is the fallback.
    var boxed = try read(testing.allocator, "<svg viewBox=\"0 0 16 8\"><path d=\"M0 0Z\"/></svg>");
    defer boxed.deinit();
    try testing.expectEqual(@as(f64, 16), boxed.width);
    try testing.expectEqual(@as(f64, 8), boxed.height);
    // A percentage of a viewport that does not exist is not a size, so the
    // viewBox supplies it -- which is what drawing programs' `100%` needs.
    var percent = try read(testing.allocator, "<svg width=\"100%\" height=\"100%\" viewBox=\"0 0 16 8\"><path d=\"M0 0Z\"/></svg>");
    defer percent.deinit();
    try testing.expectEqual(@as(f64, 16), percent.width);
    // Units are resolved: 96pt is 128 pixels.
    var units = try read(testing.allocator, "<svg width=\"96pt\" height=\"48pt\" viewBox=\"0 0 16 8\"><path d=\"M0 0Z\"/></svg>");
    defer units.deinit();
    try testing.expectApproxEqAbs(@as(f64, 128), units.width, 1e-9);
    // And with neither there is nothing to go on.
    try testing.expectError(error.NoSize, read(testing.allocator, "<svg><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.NoSize, read(testing.allocator, "<svg width=\"0\" height=\"0\"><path d=\"M0 0Z\"/></svg>"));
}

test "a percentage is measured against the viewBox, not the drawn size" {
    // 50% of a viewBox height of 200 is 100 user units, whatever the document
    // says it is in pixels.
    var doc = try read(
        testing.allocator,
        "<svg width=\"100\" height=\"50\" viewBox=\"0 0 100 200\">" ++
            "<rect width=\"10\" height=\"50%\"/></svg>",
    );
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 100), doc.viewport().width);
    try testing.expectEqual(@as(f64, 200), doc.viewport().height);
    var it = doc.paths();
    const shape = (try it.next()).?.shape;
    try testing.expectApproxEqAbs(@as(f64, 100), shape.geometry.rect.height, 1e-9);
}

test "the fitting algorithm places the viewBox in the box" {
    // A 10x10 viewBox into an 80x40 box: meet scales by 4, slice by 8.
    const src = "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"";
    const tail = "\"><path d=\"M0 0Z\"/></svg>";

    const mid = try transformOf(src ++ "xMidYMid meet" ++ tail, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 4), mid.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), mid.dy, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 20), mid.tx, 1e-12); // (80 - 40) / 2
    try testing.expectApproxEqAbs(@as(f64, 0), mid.ty, 1e-12);

    const min = try transformOf(src ++ "xMinYMin meet" ++ tail, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 0), min.tx, 1e-12);

    const max = try transformOf(src ++ "xMaxYMax meet" ++ tail, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 40), max.tx, 1e-12);

    // Slice takes the larger ratio, so the viewBox overflows and the leftover
    // is negative -- the same arithmetic saying which part is kept.
    const slice = try transformOf(src ++ "xMidYMid slice" ++ tail, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 8), slice.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), slice.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -20), slice.ty, 1e-12); // (40 - 80) / 2

    // And `none` scales each axis on its own.
    const stretch = try transformOf(src ++ "none" ++ tail, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 8), stretch.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), stretch.dy, 1e-12);
}

test "a document with no viewBox is scaled from its own size" {
    // Its user units are pixels at the size it claims, so drawing it larger
    // scales it rather than leaving it 1:1 in the corner.
    var doc = try read(testing.allocator, "<svg width=\"48\" height=\"24\"><path d=\"M0 0Z\"/></svg>");
    defer doc.deinit();
    try testing.expectEqual(@as(?ViewBox, null), doc.view_box);
    const t = doc.transformFor(0, 0, 96, 48);
    try testing.expectApproxEqAbs(@as(f64, 2), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), t.dy, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), t.tx, 1e-12);
}

test "a use draws what it names, wherever that is" {
    const gpa = testing.allocator;
    // Forward reference: `#later` is defined after the `<use>` that names it,
    // which a single forward walk could not have resolved at all.
    const found = try collect(gpa, "<svg viewBox=\"0 0 8 8\">" ++
        "<use href=\"#later\"/><defs><path id=\"later\" d=\"M0 0H4V4H0Z\"/></defs></svg>");
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("M0 0H4V4H0Z", found[0]);
}

test "a use of a group draws everything in it" {
    const gpa = testing.allocator;
    const found = try collect(gpa, "<svg viewBox=\"0 0 8 8\">" ++
        "<defs><g id=\"pair\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/></g></defs>" ++
        "<use href=\"#pair\"/><use href=\"#pair\" x=\"4\"/></svg>");
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 4), found.len);
}

test "a use inherits from where it is, not from where its target is" {
    // §5.6 deep-clones the target into the `<use>`, so it takes its paint from
    // the `<use>`'s ancestors. A `<defs>` that names a fill does not reach it.
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 8 8\">" ++
        "<defs fill=\"red\"><path id=\"p\" d=\"M0 0Z\"/></defs>" ++
        "<g fill=\"blue\"><use href=\"#p\"/></g></svg>");
    defer doc.deinit();
    var it = doc.paths();
    const shape = (try it.next()).?.shape;
    try testing.expectEqual(@as(u8, 255), shape.fill.?.color.b);
    try testing.expectEqual(@as(u8, 0), shape.fill.?.color.r);
}

test "a use folds its x and y into the transform" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 8 8\">" ++
        "<defs><path id=\"p\" d=\"M0 0Z\"/></defs><use href=\"#p\" x=\"3\" y=\"5\"/></svg>");
    defer doc.deinit();
    var it = doc.paths();
    const shape = (try it.next()).?.shape;
    try testing.expectApproxEqAbs(@as(f64, 3), shape.transform.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), shape.transform.ty, 1e-12);
}

test "a reference that goes nowhere is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownReference, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><use href=\"#nothing\"/></svg>",
    ));
    try testing.expectError(error.BadReference, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><use/></svg>",
    ));
    // An external reference names a file, and fetching one is exactly what
    // being sans-I/O rules out -- it is why the renderer can be put in a
    // process that cannot open anything.
    try testing.expectError(error.BadReference, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><use href=\"other.svg#a\"/></svg>",
    ));
    try testing.expectError(error.BadReference, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><use href=\"#\"/></svg>",
    ));
}

test "a use that draws itself is refused" {
    const gpa = testing.allocator;
    // Directly: a group containing a `<use>` of that group.
    try testing.expectError(error.RecursiveUse, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g id=\"loop\"><use href=\"#loop\"/></g></svg>",
    ));
    // And round a longer way.
    try testing.expectError(error.RecursiveUse, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g id=\"a\"><g id=\"b\"><use href=\"#a\"/></g></g></svg>",
    ));
    // A `<use>` naming itself is a chain rather than a subtree, so the hop
    // count is what stops it.
    try testing.expectError(error.TooManyUseHops, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><use id=\"self\" href=\"#self\"/></svg>",
    ));
}

test "the same target used twice is not a cycle" {
    // The stack is the cycle check, so a target that has been *closed* again
    // must not look like one -- two siblings naming the same group are
    // perfectly ordinary.
    const gpa = testing.allocator;
    const found = try collect(gpa, "<svg viewBox=\"0 0 8 8\">" ++
        "<defs><g id=\"g\"><path d=\"M0 0Z\"/></g></defs>" ++
        "<use href=\"#g\"/><use href=\"#g\"/><use href=\"#g\"/></svg>");
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 3), found.len);
}

test "an element in a foreign namespace is passed over, not refused" {
    // An Inkscape file's `<sodipodi:namedview>` is not SVG content and nothing
    // is meant to draw it. Refusing it would refuse the file.
    const gpa = testing.allocator;
    const found = try collect(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\" " ++
        "xmlns:sodipodi=\"http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd\" " ++
        "viewBox=\"0 0 8 8\"><sodipodi:namedview id=\"nv\"/>" ++
        "<path d=\"M0 0Z\"/></svg>");
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
}

test "the first of a duplicated id wins" {
    const gpa = testing.allocator;
    const found = try collect(gpa, "<svg viewBox=\"0 0 8 8\">" ++
        "<defs><path id=\"dup\" d=\"M0 0Z\"/><path id=\"dup\" d=\"M9 9Z\"/></defs>" ++
        "<use href=\"#dup\"/></svg>");
    defer freeCollected(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("M0 0Z", found[0]);
}

test "a viewBox with an offset is translated away" {
    var doc = try read(testing.allocator, "<svg viewBox=\"-12 -12 24 24\"><path d=\"M0 0Z\"/></svg>");
    defer doc.deinit();
    const t = doc.transformFor(0, 0, 24, 24);
    try testing.expectApproxEqAbs(@as(f64, 1), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.ty, 1e-12);
}

test "em on an element means that element's own font size" {
    const gpa = testing.allocator;
    // The inner rect sets its own `font-size`, so its `2em` is twice *that*
    // and not twice what the group said.
    var doc = try read(gpa, "<svg viewBox=\"0 0 64 32\"><g font-size=\"10\">" ++
        "<rect width=\"1em\" height=\"1\"/>" ++
        "<rect font-size=\"6\" width=\"2em\" height=\"1\"/>" ++
        "<rect width=\"4ex\" height=\"1\"/>" ++
        "</g></svg>");
    defer doc.deinit();

    var it = doc.paths();
    const widths = [_]f64{ 10, 12, 20 };
    for (widths) |want| {
        const item = (try it.next()).?;
        try testing.expectApproxEqAbs(want, item.shape.geometry.rect.width, 1e-9);
    }
}

test "em inside font-size means the parent's font size" {
    const gpa = testing.allocator;
    // CSS's rule, and the reason `font-size` is read before every other
    // length on the same element: `2em` here is twice the eight the group
    // said, not twice itself.
    var doc = try read(gpa, "<svg viewBox=\"0 0 64 32\"><g font-size=\"8\">" ++
        "<rect font-size=\"2em\" width=\"1em\" height=\"1\"/>" ++
        "</g></svg>");
    defer doc.deinit();

    var it = doc.paths();
    const item = (try it.next()).?;
    // font-size resolved to 16, so the element's own `1em` is 16.
    try testing.expectApproxEqAbs(@as(f64, 16), item.shape.geometry.rect.width, 1e-9);
}

test "em with no font size anywhere is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadLength, read(
        gpa,
        "<svg viewBox=\"0 0 64 32\"><rect width=\"1em\" height=\"1\"/></svg>",
    ));
    // Including in `font-size` on the root, which has nothing above it to be
    // relative to.
    try testing.expectError(error.BadLength, read(
        gpa,
        "<svg viewBox=\"0 0 64 32\" font-size=\"2em\"><rect width=\"1\" height=\"1\"/></svg>",
    ));
}

test "a text element is a sequence of runs sharing a pen" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 96 32\"><text x=\"4\" y=\"20\" font-size=\"10\">" ++
        "ab<tspan fill=\"red\" font-size=\"6\">cd</tspan>ef</text></svg>");
    defer doc.deinit();

    var it = doc.paths();
    // Three runs in document order, and only the first carries the `<text>`'s
    // own position -- the rest carry on from wherever the pen reached, which
    // is why they have none of their own.
    const first = (try it.next()).?.shape;
    try testing.expectEqualStrings("ab", first.geometry.text.utf8);
    try testing.expectEqual(@as(?f64, 4), first.geometry.text.x);
    try testing.expect(first.geometry.text.starts_element);
    try testing.expectEqual(@as(?f64, 10), first.font_size);

    const second = (try it.next()).?.shape;
    try testing.expectEqualStrings("cd", second.geometry.text.utf8);
    try testing.expectEqual(@as(?f64, null), second.geometry.text.x);
    try testing.expect(!second.geometry.text.starts_element);
    // The tspan's own properties, over what it inherited.
    try testing.expectEqual(@as(?f64, 6), second.font_size);
    try testing.expectEqual(@as(u8, 255), second.fill.?.color.r);

    const third = (try it.next()).?.shape;
    try testing.expectEqualStrings("ef", third.geometry.text.utf8);
    try testing.expectEqual(@as(?f64, null), third.geometry.text.x);
    // Back to the `<text>`'s own size: a tspan's properties end with it.
    try testing.expectEqual(@as(?f64, 10), third.font_size);

    // All three belong to the same element, which is what `text-anchor` is
    // measured across.
    try testing.expectEqual(first.geometry.text.owner, second.geometry.text.owner);
    try testing.expectEqual(first.geometry.text.owner, third.geometry.text.owner);

    try testing.expectEqual(@as(?Item, null), try it.next());
}

test "a tspan that places itself starts a chunk" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 96 32\"><text x=\"4\" y=\"12\" font-size=\"10\">" ++
        "one<tspan x=\"4\" y=\"26\">two</tspan></text></svg>");
    defer doc.deinit();

    var it = doc.paths();
    _ = (try it.next()).?;
    const second = (try it.next()).?.shape.geometry.text;
    try testing.expectEqual(@as(?f64, 4), second.x);
    try testing.expectEqual(@as(?f64, 26), second.y);
}

test "whitespace between markup is not a run" {
    const gpa = testing.allocator;
    // The newlines and indentation around the tspans are not text the document
    // meant to draw, and a run made of nothing else is not a run.
    var doc = try read(gpa, "<svg viewBox=\"0 0 96 32\"><text x=\"4\" y=\"20\" font-size=\"10\">\n" ++
        "  <tspan>a</tspan>\n  <tspan>b</tspan>\n</text></svg>");
    defer doc.deinit();

    var it = doc.paths();
    try testing.expectEqualStrings("a", (try it.next()).?.shape.geometry.text.utf8);
    try testing.expectEqualStrings("b", (try it.next()).?.shape.geometry.text.utf8);
    try testing.expectEqual(@as(?Item, null), try it.next());
}

test "a textPath carries the shape it follows and where to start" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 96 48\"><defs><path id=\"c\" d=\"M6 40 Q48 4 90 40\"/></defs>" ++
        "<text font-size=\"12\"><textPath href=\"#c\" startOffset=\"30\">go</textPath></text></svg>");
    defer doc.deinit();

    var it = doc.paths();
    const run = (try it.next()).?.shape.geometry.text;
    try testing.expectEqual(doc.ids.get("c").?, run.on_path.?.node);
    try testing.expectEqual(@as(f64, 30), run.on_path.?.offset.absolute);
}

test "a startOffset in percent stays a fraction until the path is measured" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 96 48\"><defs><path id=\"c\" d=\"M6 40 Q48 4 90 40\"/></defs>" ++
        "<text font-size=\"12\"><textPath href=\"#c\" startOffset=\"25%\">go</textPath></text></svg>");
    defer doc.deinit();

    var it = doc.paths();
    const run = (try it.next()).?.shape.geometry.text;
    // A quarter of the path's own length, which the reader has no way to
    // know -- measuring a curve means flattening it, and that is drawing.
    try testing.expectApproxEqAbs(@as(f64, 0.25), run.on_path.?.offset.fraction, 1e-9);
}

test "a textPath naming nothing is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownReference, read(
        gpa,
        "<svg viewBox=\"0 0 96 48\"><text font-size=\"12\">" ++
            "<textPath href=\"#missing\">go</textPath></text></svg>",
    ));
    try testing.expectError(error.BadReference, read(
        gpa,
        "<svg viewBox=\"0 0 96 48\"><text font-size=\"12\">" ++
            "<textPath>go</textPath></text></svg>",
    ));
}
test "rotate and textLength are read, and refused where they would mislead" {
    const gpa = testing.allocator;
    {
        var doc = try read(gpa, "<svg viewBox=\"0 0 96 32\"><text x=\"4\" y=\"20\" font-size=\"10\"" ++
            " rotate=\"0 30\" textLength=\"40\">ab</text></svg>");
        defer doc.deinit();
        var it = doc.paths();
        const run = (try it.next()).?.shape.geometry.text;
        try testing.expectEqualStrings("0 30", run.rotate.?);
        try testing.expectEqual(@as(?f64, 40), run.text_length);
    }

    // Both index into the characters of the element as a whole, so a `<tspan>`
    // inside one would have to be counted into the same sequence. Refused
    // rather than applied per run, which would put the angles on the wrong
    // letters.
    for ([_][]const u8{ "rotate=\"30\"", "textLength=\"40\"" }) |attr| {
        const src = try std.fmt.allocPrint(
            gpa,
            "<svg viewBox=\"0 0 96 32\"><text x=\"4\" y=\"20\" {s}>a<tspan>b</tspan></text></svg>",
            .{attr},
        );
        defer gpa.free(src);
        try testing.expectError(error.UnsupportedTextLayout, read(gpa, src));
    }

    // `spacingAndGlyphs` stretches the glyphs themselves, which is a different
    // drawing; `spacing` is the initial value and is the one implemented.
    try testing.expectError(error.UnsupportedTextLayout, read(
        gpa,
        "<svg viewBox=\"0 0 96 32\"><text x=\"4\" y=\"20\" textLength=\"40\"" ++
            " lengthAdjust=\"spacingAndGlyphs\">ab</text></svg>",
    ));
}

test "a style declaration outranks the presentation attribute" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\"" ++
        " fill=\"red\" style=\"fill:blue\"/></svg>");
    defer doc.deinit();
    var it = doc.paths();
    const shape = (try it.next()).?.shape;
    try testing.expectEqual(@as(u8, 0), shape.fill.?.color.r);
    try testing.expectEqual(@as(u8, 255), shape.fill.?.color.b);
}

test "style carries every presentation property, and geometry stays an attribute" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"" ++
        "fill:lime;fill-opacity:0.5;stroke:blue;stroke-width:3;" ++
        "stroke-linecap:round;font-size:11;text-anchor:middle\"/></svg>");
    defer doc.deinit();
    var it = doc.paths();
    const shape = (try it.next()).?.shape;
    try testing.expectEqual(@as(u8, 255), shape.fill.?.color.g);
    try testing.expectApproxEqAbs(@as(f64, 0.5), shape.fill_opacity.?, 1e-9);
    try testing.expectEqual(@as(u8, 255), shape.stroke.?.color.b);
    try testing.expectApproxEqAbs(@as(f64, 3), shape.stroke_width.?, 1e-9);
    try testing.expectEqual(z2d.options.CapMode.round, shape.stroke_linecap.?);
    try testing.expectApproxEqAbs(@as(f64, 11), shape.font_size.?, 1e-9);
    try testing.expectEqual(TextAnchor.middle, shape.text_anchor.?);

    // §6.3 lists the *presentation properties*, and a `<rect>`'s geometry is
    // not among them in SVG 1.1 -- so a width in a style attribute is not a
    // width, and the attribute is what says how big the rectangle is.
    try testing.expectApproxEqAbs(@as(f64, 8), shape.geometry.rect.width, 1e-9);
}

test "a style on a container is inherited like an attribute" {
    const gpa = testing.allocator;
    var doc = try read(gpa, "<svg viewBox=\"0 0 8 8\"><g style=\"fill:blue;font-size:9\">" ++
        "<rect width=\"4\" height=\"8\"/>" ++
        "<rect x=\"4\" width=\"4\" height=\"8\" style=\"fill:lime\"/>" ++
        "</g></svg>");
    defer doc.deinit();
    var it = doc.paths();
    const first = (try it.next()).?.shape;
    try testing.expectEqual(@as(u8, 255), first.fill.?.color.b);
    try testing.expectApproxEqAbs(@as(f64, 9), first.font_size.?, 1e-9);
    // The child's own style wins over what it inherited, and takes only what
    // it names with it.
    const second = (try it.next()).?.shape;
    try testing.expectEqual(@as(u8, 255), second.fill.?.color.g);
    try testing.expectApproxEqAbs(@as(f64, 9), second.font_size.?, 1e-9);
}

test "a value a style names is read by the same parser an attribute uses" {
    const gpa = testing.allocator;
    // Which means it is refused the same way, rather than being skipped for
    // sitting in a style attribute.
    try testing.expectError(error.BadColor, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:wobble\"/></svg>",
    ));
    try testing.expectError(error.BadFillRule, read(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill-rule:sideways\"/></svg>",
    ));
}

test "a use with its own opacity, clip, mask or filter is drawn as a group around its target" {
    var doc = try read(testing.allocator,
        \\<svg viewBox="0 0 10 10">
        \\  <defs><rect id="r" width="2" height="2"/><clipPath id="c"><rect width="1" height="1"/></clipPath></defs>
        \\  <use href="#r" x="3" opacity="0.5" clip-path="url(#c)"/>
        \\  <use href="#r" x="6"/>
        \\</svg>
    );
    defer doc.deinit();
    var it = doc.paths();
    // The first opens a group carrying what the `<use>` said, with its `x`
    // in the group's matrix, around the rect; the second has nothing of its
    // own and is the plain shape it always was.
    const open = (try it.next()).?.open_group;
    try testing.expectEqual(@as(f64, 0.5), open.opacity);
    try testing.expectEqualStrings("c", open.clip_path.?);
    try testing.expectEqual(@as(f64, 3), open.transform.tx);
    try testing.expectEqualStrings("use", doc.tree.node(open.node).name.local);
    const inner = (try it.next()).?.shape;
    try testing.expectEqual(@as(f64, 3), inner.transform.tx);
    try testing.expect((try it.next()).? == .close_group);
    try testing.expectEqual(@as(f64, 6), (try it.next()).?.shape.transform.tx);
    try testing.expectEqual(@as(?Item, null), try it.next());

    // Measured as a group, it holds what it names.
    var sub = doc.subtree(open.node, .identity);
    try testing.expect((try sub.next()).? == .shape);
    try testing.expectEqual(@as(?Item, null), try sub.next());
}

test "a use drawn as a group that contains itself is still recursion" {
    try testing.expectError(error.RecursiveUse, read(testing.allocator,
        \\<svg viewBox="0 0 10 10"><g id="g"><rect width="1" height="1"/><use href="#g" opacity="0.5"/></g></svg>
    ));
    try testing.expectError(error.RecursiveUse, read(testing.allocator,
        \\<svg viewBox="0 0 10 10"><use id="u" href="#u" opacity="0.5"/></svg>
    ));
}

test "display none takes an element and everything in it out of the walk" {
    // Hidden things are not read at all, so what is inside one cannot be
    // refused: the `<foo>` would be `UnsupportedElement` anywhere else.
    var doc = try read(testing.allocator,
        \\<svg viewBox="0 0 10 10">
        \\  <rect width="1" height="1" display="none"/>
        \\  <g display="none"><rect width="2" height="2"/><foo/></g>
        \\  <defs><rect id="r" width="3" height="3"/></defs>
        \\  <use href="#r" display="none"/>
        \\  <g style="display: none"><rect width="4" height="4"/></g>
        \\  <rect width="5" height="5" display="inline"/>
        \\</svg>
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
    var it = doc.paths();
    try testing.expectEqual(@as(f64, 5), (try it.next()).?.shape.geometry.rect.width);
    try testing.expectEqual(@as(?Item, null), try it.next());

    // A hidden root hides the document, which then has nothing to draw.
    try testing.expectError(error.NoPath, read(testing.allocator,
        \\<svg viewBox="0 0 10 10" display="none"><rect width="1" height="1"/></svg>
    ));
}

test "visibility is inherited, overridable, and hides without removing" {
    var doc = try read(testing.allocator,
        \\<svg viewBox="0 0 10 10">
        \\  <g visibility="hidden">
        \\    <rect width="1" height="1"/>
        \\    <rect width="2" height="2" visibility="visible"/>
        \\  </g>
        \\  <rect width="3" height="3" visibility="collapse"/>
        \\</svg>
    );
    defer doc.deinit();
    // All three are still yielded: a hidden shape takes up room.
    try testing.expectEqual(@as(usize, 3), doc.shape_count);
    var it = doc.paths();
    try testing.expect(!(try it.next()).?.shape.visible);
    try testing.expect((try it.next()).?.shape.visible);
    try testing.expect(!(try it.next()).?.shape.visible);

    try testing.expectError(error.BadVisibility, read(testing.allocator,
        \\<svg viewBox="0 0 10 10"><rect width="1" height="1" visibility="invisible"/></svg>
    ));
}

test "a link is a group, and inside text it carries the text" {
    var doc = try read(testing.allocator,
        \\<svg viewBox="0 0 10 10">
        \\  <a href="https://example.com" fill="red"><rect width="1" height="1"/></a>
        \\  <text x="1" y="5">see <a href="#x">here</a> now</text>
        \\</svg>
    );
    defer doc.deinit();
    var it = doc.paths();
    const rect = (try it.next()).?.shape;
    try testing.expectEqual(@as(f64, 1), rect.geometry.rect.width);
    try testing.expect(rect.fill != null);
    // The three runs, the middle one the link's.
    try testing.expectEqualStrings("see ", (try it.next()).?.shape.geometry.text.utf8);
    try testing.expectEqualStrings("here", (try it.next()).?.shape.geometry.text.utf8);
    try testing.expectEqualStrings(" now", (try it.next()).?.shape.geometry.text.utf8);
    try testing.expectEqual(@as(?Item, null), try it.next());
}

/// The runs of the first `<text>` in `src`, with the space each is to begin
/// and end with.
fn runSpaces(src: []const u8) ![8][2]bool {
    var doc = try read(testing.allocator, src);
    defer doc.deinit();
    var out: [8][2]bool = undefined;
    var it = doc.paths();
    var i: usize = 0;
    while (try it.next()) |item| switch (item) {
        .shape => |sh| if (sh.geometry == .text) {
            out[i] = .{ sh.geometry.text.lead_space, sh.geometry.text.trail_space };
            i += 1;
        },
        else => {},
    };
    return out;
}

test "the spaces between runs belong to the whole text element" {
    // A space at the edge of a `<tspan>` is the space between two words;
    // only the element's first and last are dropped.
    const a = try runSpaces("<svg viewBox=\"0 0 9 9\"><text>  a <tspan>b</tspan> c  </text></svg>");
    try testing.expectEqual([2]bool{ false, true }, a[0]); // "a "
    try testing.expectEqual([2]bool{ false, false }, a[1]); // "b"
    try testing.expectEqual([2]bool{ true, false }, a[2]); // " c", last
    // Two spaces meeting at a boundary are one.
    const b = try runSpaces("<svg viewBox=\"0 0 9 9\"><text>a <tspan> b</tspan></text></svg>");
    try testing.expectEqual([2]bool{ false, true }, b[0]);
    try testing.expectEqual([2]bool{ false, false }, b[1]);
    // A run of nothing but whitespace is still a space between words.
    const c = try runSpaces("<svg viewBox=\"0 0 9 9\"><text>a<tspan> </tspan>b</text></svg>");
    try testing.expectEqual([2]bool{ false, false }, c[0]);
    try testing.expectEqual([2]bool{ true, false }, c[1]);
    // A trailing space with only hidden text after it is the last one.
    const d = try runSpaces("<svg viewBox=\"0 0 9 9\"><text>a <tspan display=\"none\">b</tspan></text></svg>");
    try testing.expectEqual([2]bool{ false, false }, d[0]);
}
