// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading an `<svg>` element far enough to draw what is in it.
//!
//! What this understands is one `<svg>` carrying a `viewBox` and any number of
//! `<path>` elements carrying a `d`, each with its own colour:
//!
//! ```
//! <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3,9H7L12,4V20L7,15H3V9Z" fill="#c00" /></svg>
//! ```
//!
//! Which is every one of the 7,447 Material Design Icons, a great many other
//! icon sets, and a long way short of SVG. There is no `<g>`, no `transform`,
//! no `style`, no gradient and no stroke.
//!
//! ## Groups
//!
//! `<g>` nests: it carries the same presentation attributes a shape does and
//! passes them down, and it carries a `transform` that every descendant is
//! drawn under. The root `<svg>` is a container in exactly the same way, so
//! there is one code path rather than a special case for the root -- the only
//! thing that makes the root special is that it is where the `viewBox` is.
//!
//! Nesting is bounded by `max_container_depth`. A document nesting groups more
//! deeply than that is refused rather than overflowing a stack, which is the
//! failure that is not catchable.
//!
//! ## The presentation attributes it reads
//!
//! `fill`, `fill-opacity`, `fill-rule` and `color` on the root `<svg>` are
//! inherited by every shape, as CSS inheritance says; the same four on a
//! `<path>` override them for that shape. `opacity` is read on a `<path>` and
//! is not inherited, because it is not an inherited property.
//!
//! A shape that names no `fill` is painted in the colour the *caller* chose,
//! not in SVG's initial black. That is a deliberate difference, and it is the
//! whole reason a caller can draw a Material Design Icon in any colour: not
//! one of the 7,447 carries a `fill`, so under the letter of the specification
//! the set could only ever be black. `fill="currentColor"`, which many other
//! icon sets use instead, lands on the same caller's colour by the honest
//! route -- it is the initial value of the `color` property, and the caller
//! chooses that too.
//!
//! Anything else is ignored rather than refused: `xmlns`, `id`, `class`,
//! `width`, `height`, `style`. Elements are refused, attributes are ignored --
//! an element carries geometry that would go missing, and an attribute is
//! usually decoration. The exception is `opacity` on a container, which would
//! go quietly wrong; see `Error.GroupOpacityUnsupported`.
//!
//! An element this does not implement is **refused** rather than skipped.
//! Skipping it would draw a picture quietly missing a piece, which is the
//! failure nobody notices; `error.UnsupportedElement` is the failure somebody
//! does. The set of elements that carry no geometry -- `<title>`, `<desc>`,
//! `<metadata>`, `<defs>` -- is passed over, because passing those over is
//! correct rather than approximate.
//!
//! ## Two passes, and why
//!
//! `read` walks the whole document and keeps only the `viewBox`; `Document.paths`
//! walks it again to hand out each `d` in turn. Re-walking is deliberate. A
//! `Document` that held its shapes would have to allocate for them or cap how
//! many it could hold, and this way it does neither: `read` allocates nothing
//! at all, and a `Document` is four floats and a slice.
//!
//! It also decides *when* a document is refused. `read` validates everything
//! before the caller has drawn anything, so a `<g>` at the end of a document
//! is an error rather than four shapes painted and then an error -- a partial
//! picture and a failure at once being the worst of both.

const std = @import("std");
const xml = @import("zxml");
const z2d = @import("z2d");

const color = @import("color.zig");
const length = @import("length.zig");
const path = @import("path.zig");
const shapes = @import("shapes.zig");
const transform = @import("transform.zig");

pub const Error = error{
    /// The document has no `<svg>` element.
    NotAnSvg,
    /// `<svg>` has no `viewBox`, or one that is not four numbers.
    BadViewBox,
    /// There is no `<path>` at all, or one of them has no `d`.
    NoPath,
    /// An element this reader does not implement -- a `<g>`, a `<circle>`, a
    /// `<use>`. Refused rather than skipped: skipping it would draw a picture
    /// that is quietly missing a piece.
    UnsupportedElement,
    /// `opacity` on a container -- the root `<svg>` or a `<g>` -- which is a
    /// *group* opacity: the container is drawn into a layer of its own and
    /// that layer is composited once at the given alpha.
    ///
    /// Multiplying it into each shape's alpha instead -- which is what
    /// `opacity` on a single `<path>` amounts to, and is exactly right there
    /// -- is wrong the moment two shapes overlap, because each would then show
    /// through the other where the group would have shown only the upper one.
    /// Refused rather than approximated, and it comes back with the composited
    /// layers that clipping and masking need.
    GroupOpacityUnsupported,
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
    /// A length -- a coordinate, a radius, a width -- that is not a number,
    /// or that carries a unit this reader does not implement. Only a bare
    /// number and the `px` that means the same thing are read today; `pt`,
    /// `em` and `%` are on the feature list.
    BadLength,
    /// Containers nested more deeply than `max_container_depth`.
    TooDeeplyNested,
    /// A `transform` whose composed matrix has an infinity or a NaN in it.
    NonFiniteTransform,
    /// A point that landed outside what the rasterizer can work with, after
    /// the transforms and the viewBox mapping were applied. See
    /// `max_coordinate`.
    CoordinateOutOfRange,
} || transform.Error || color.Error || length.Error || xml.Error;

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

/// How deeply `<g>` may nest.
///
/// Sized so that the walk's stack is a few kilobytes rather than tens, and so
/// far above any drawing that a document reaching it is doing something other
/// than describing a picture. Refused rather than overflowed: a stack overflow
/// is the one failure a caller cannot catch.
pub const max_container_depth = 64;

/// The presentation attributes that an element passes down to its children.
///
/// Null in each field means nothing has named it, so the caller's choice
/// stands. That is what lets `Options.fill` be the default for a document that
/// names no colour anywhere, which is every icon set worth drawing.
pub const Inherited = struct {
    fill: ?color.Paint = null,
    fill_opacity: ?f64 = null,
    fill_rule: ?z2d.options.FillRule = null,
    /// The `color` property, which is what `fill="currentColor"` resolves to.
    current_color: ?color.Color = null,

    stroke: ?color.Paint = null,
    stroke_width: ?f64 = null,
    stroke_opacity: ?f64 = null,
    stroke_linecap: ?z2d.options.CapMode = null,
    stroke_linejoin: ?z2d.options.JoinMode = null,
    stroke_miterlimit: ?f64 = null,
    /// `stroke-dasharray` as the document wrote it, borrowed from the source
    /// and read when the shape is drawn. Kept as text because a dash list is
    /// a list: parsing it here would mean either allocating for it or giving
    /// every level of the container stack room for one.
    stroke_dasharray: ?[]const u8 = null,
    stroke_dashoffset: ?f64 = null,

    /// `self` with everything `child` names overridden.
    pub fn with(self: Inherited, child: Inherited) Inherited {
        return .{
            .fill = child.fill orelse self.fill,
            .fill_opacity = child.fill_opacity orelse self.fill_opacity,
            .fill_rule = child.fill_rule orelse self.fill_rule,
            .current_color = child.current_color orelse self.current_color,
            .stroke = child.stroke orelse self.stroke,
            .stroke_width = child.stroke_width orelse self.stroke_width,
            .stroke_opacity = child.stroke_opacity orelse self.stroke_opacity,
            .stroke_linecap = child.stroke_linecap orelse self.stroke_linecap,
            .stroke_linejoin = child.stroke_linejoin orelse self.stroke_linejoin,
            .stroke_miterlimit = child.stroke_miterlimit orelse self.stroke_miterlimit,
            .stroke_dasharray = child.stroke_dasharray orelse self.stroke_dasharray,
            .stroke_dashoffset = child.stroke_dashoffset orelse self.stroke_dashoffset,
        };
    }
};

/// One `<path>`, with the paint that applies to it.
pub const Shape = struct {
    /// What to draw: a `<path>`'s `d`, or one of the basic shapes' numbers.
    geometry: shapes.Geometry,
    /// What to paint it with, after inheritance. Null means nothing named a
    /// `fill`, so the caller's colour stands.
    fill: ?color.Paint,
    /// `fill-opacity`, or null for the caller's default of fully opaque.
    fill_opacity: ?f64,
    /// `fill-rule`, or null for the caller's choice.
    fill_rule: ?z2d.options.FillRule,
    /// The `color` in force, for a `fill` or `stroke` of `currentColor`. Null
    /// means the caller's colour.
    current_color: ?color.Color,
    /// The stroke properties in force, after inheritance. A null `stroke`
    /// means nothing named one, which -- unlike `fill` -- is *no stroke at
    /// all* rather than the caller's colour: SVG's initial `stroke` is `none`,
    /// and a shape that is stroked without asking to be is a picture with
    /// lines in it that the document does not have.
    stroke: ?color.Paint,
    stroke_width: ?f64,
    stroke_opacity: ?f64,
    stroke_linecap: ?z2d.options.CapMode,
    stroke_linejoin: ?z2d.options.JoinMode,
    stroke_miterlimit: ?f64,
    stroke_dasharray: ?[]const u8,
    stroke_dashoffset: ?f64,
    /// This element's own `opacity`, which is not inherited. One when the
    /// element does not name it.
    opacity: f64,
    /// Every `transform` from the root down to and including this element,
    /// composed. In user units: the viewBox-to-pixels mapping is *not* in
    /// here, because it belongs to the box being drawn into rather than to
    /// the document, and `Document.transformFor` supplies it.
    transform: z2d.Transformation,
};

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

/// A document that has been read and found drawable.
///
/// Borrows `src`, which must outlive it, and allocates nothing.
pub const Document = struct {
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
    ///
    /// This is what `render` draws at when the caller names no size. It is not
    /// what a percentage is measured against -- see `viewport`.
    width: f64,
    height: f64,
    /// How the `viewBox` is fitted into the box it is drawn in.
    preserve_aspect_ratio: PreserveAspectRatio,
    /// The source this was read from. `paths` walks it again.
    src: []const u8,
    /// How many shapes `read` found, so that a caller can bound the work
    /// before starting it.
    shape_count: usize,
    /// What the root `<svg>` named, which every shape inherits unless a `<g>`
    /// or the shape itself overrides it. Informational: `paths` walks the
    /// document again and works this out for itself, rather than being seeded
    /// with it, so that the root and a `<g>` go through one code path.
    root: Inherited,

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

    /// Each shape, in document order.
    ///
    /// Order is the painting order: SVG paints shapes in the order they are
    /// written, each over the last.
    pub fn paths(self: Document) PathIterator {
        return .{ .reader = .init(self.src), .viewport = self.viewport() };
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
        // `viewBox` larger scales that. Leaving the mapping at the identity
        // instead would draw such a document at 1:1 in the corner of whatever
        // box it was given, which is what it used to do and what one oracle
        // fixture noticed.
        const vb = self.view_box orelse ViewBox{
            .min_x = 0,
            .min_y = 0,
            .width = self.width,
            .height = self.height,
        };

        const par = self.preserve_aspect_ratio;
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
};

/// Walks a document handing out one `d` attribute at a time.
///
/// Every error it could return was already returned by `read`, which is what
/// lets a caller drawing shape after shape treat `next` as infallible in
/// practice -- it is still `try`ed, because a parser that answered differently
/// on a second pass would be a bug worth hearing about rather than one to
/// paper over.
pub const PathIterator = struct {
    reader: xml.Reader,
    /// What a percentage in this document is measured against.
    viewport: length.Viewport,
    /// What each open container contributes, innermost last. Level zero is
    /// what applies before any container has been entered, which is what a
    /// shape outside the root would see -- there is no such shape in a
    /// well-formed document, and starting the stack non-empty means `next`
    /// never has to ask whether there is one.
    stack: [max_container_depth + 1]Level = undefined,
    depth: usize = 0,
    /// How deep inside a subtree that is not painted. Kept because `read` and
    /// this have to agree exactly on what counts as a shape: a `<path>` inside
    /// `<defs>` is not one, and an iterator that yielded it anyway would paint
    /// something the document said to keep back, having passed every check.
    depth_ignored: usize = 0,
    started: bool = false,

    /// One open container's contribution, already combined with its ancestors'
    /// so that a shape reads the innermost entry and nothing else.
    pub const Level = struct {
        inherited: Inherited,
        transform: z2d.Transformation,
    };

    pub fn next(self: *PathIterator) Error!?Shape {
        if (!self.started) {
            self.started = true;
            self.stack[0] = .{ .inherited = .{}, .transform = .identity };
        }
        while (true) switch (try self.reader.next()) {
            .start_element => |e| {
                // First, and unconditionally: a `<defs>` inside a `<defs>` has
                // to be counted so that its end tag takes the counter back
                // down again. Every start tag has a matching end, the
                // synthetic one a self-closing tag reports included, so what
                // goes up here must come down there.
                if (isIgnorable(e.name)) {
                    self.depth_ignored += 1;
                    continue;
                }
                if (self.depth_ignored > 0) continue;
                const top = self.stack[self.depth];

                if (try readGeometry(e, self.viewport)) |geometry| {
                    const effective = top.inherited.with(try readInherited(e, self.viewport));
                    const ctm = top.transform.mul(try readTransform(e));
                    if (!transform.isFinite(ctm)) return error.NonFiniteTransform;
                    return .{
                        .geometry = geometry,
                        .fill = effective.fill,
                        .fill_opacity = effective.fill_opacity,
                        .fill_rule = effective.fill_rule,
                        .current_color = effective.current_color,
                        .stroke = effective.stroke,
                        .stroke_width = effective.stroke_width,
                        .stroke_opacity = effective.stroke_opacity,
                        .stroke_linecap = effective.stroke_linecap,
                        .stroke_linejoin = effective.stroke_linejoin,
                        .stroke_miterlimit = effective.stroke_miterlimit,
                        .stroke_dasharray = effective.stroke_dasharray,
                        .stroke_dashoffset = effective.stroke_dashoffset,
                        .opacity = if (e.attr("opacity")) |v|
                            try color.parseOpacity(v)
                        else
                            1.0,
                        .transform = ctm,
                    };
                }

                if (isContainer(e.name)) {
                    // Not `opacity`: on a container it is a group opacity, and
                    // there is no layer to composite one into.
                    if (e.attr("opacity") != null) return error.GroupOpacityUnsupported;
                    // Pushed even when self-closing. zxml reports a synthetic
                    // end tag for `<g/>`, so a container that did not push
                    // would have that end pop its *parent* -- which is how a
                    // `<g/>` next to a group used to leak the group's
                    // transform onto its siblings.
                    if (self.depth == max_container_depth) return error.TooDeeplyNested;
                    self.depth += 1;
                    self.stack[self.depth] = .{
                        .inherited = top.inherited.with(try readInherited(e, self.viewport)),
                        .transform = top.transform.mul(try readTransform(e)),
                    };
                    continue;
                }

                // Refused rather than skipped: skipping it would draw a
                // picture quietly missing a piece.
                return error.UnsupportedElement;
            },
            .end_element => |name| {
                // Matched on the name rather than by counting, so that a
                // `<path/>` inside a `<defs>` does not take the ignore counter
                // down with it.
                if (isIgnorable(name)) {
                    if (self.depth_ignored > 0) self.depth_ignored -= 1;
                } else if (self.depth_ignored == 0 and isContainer(name) and self.depth > 0) {
                    self.depth -= 1;
                }
            },
            .eof => return null,
            else => {},
        };
    }
};

/// The elements that hold other elements and pass their own attributes down.
///
/// The root is one of these, which is what lets `<svg>` and `<g>` share a code
/// path rather than the root being a special case that drifts from the general
/// one.
fn isContainer(name: []const u8) bool {
    return xml.nameIs(name, "svg") or xml.nameIs(name, "g");
}

/// What an element draws, or null when it is not a drawable element.
///
/// The basic shapes are read here rather than being turned into `d` strings
/// for the path parser: their geometry is four or five numbers this already
/// has, and spelling them out as text to read back would allocate and would
/// put a number formatter and a second number parser in the way of the
/// picture. See `shapes.zig`.
fn readGeometry(e: xml.Element, viewport: length.Viewport) Error!?shapes.Geometry {
    if (xml.nameIs(e.name, "path")) {
        return .{ .path = e.attr("d") orelse return error.NoPath };
    }
    if (xml.nameIs(e.name, "rect")) {
        return .{
            .rect = .{
                .x = try lengthOf(e, "x", .x, viewport, 0),
                .y = try lengthOf(e, "y", .y, viewport, 0),
                .width = try lengthOf(e, "width", .x, viewport, 0),
                .height = try lengthOf(e, "height", .y, viewport, 0),
                // Null rather than zero: §9.2 makes one specified radius supply
                // the other, which "not specified" has to be distinguishable from
                // zero to express.
                .rx = try optionalLengthOf(e, "rx", .x, viewport),
                .ry = try optionalLengthOf(e, "ry", .y, viewport),
            },
        };
    }
    if (xml.nameIs(e.name, "circle")) {
        const r = try lengthOf(e, "r", .other, viewport, 0);
        return .{ .ellipse = .{
            .cx = try lengthOf(e, "cx", .x, viewport, 0),
            .cy = try lengthOf(e, "cy", .y, viewport, 0),
            .rx = r,
            .ry = r,
        } };
    }
    if (xml.nameIs(e.name, "ellipse")) {
        return .{ .ellipse = .{
            .cx = try lengthOf(e, "cx", .x, viewport, 0),
            .cy = try lengthOf(e, "cy", .y, viewport, 0),
            .rx = try lengthOf(e, "rx", .x, viewport, 0),
            .ry = try lengthOf(e, "ry", .y, viewport, 0),
        } };
    }
    if (xml.nameIs(e.name, "line")) {
        return .{ .line = .{
            .x1 = try lengthOf(e, "x1", .x, viewport, 0),
            .y1 = try lengthOf(e, "y1", .y, viewport, 0),
            .x2 = try lengthOf(e, "x2", .x, viewport, 0),
            .y2 = try lengthOf(e, "y2", .y, viewport, 0),
        } };
    }
    if (xml.nameIs(e.name, "polyline")) {
        return .{ .poly = .{ .points = e.attr("points") orelse "", .closed = false } };
    }
    if (xml.nameIs(e.name, "polygon")) {
        return .{ .poly = .{ .points = e.attr("points") orelse "", .closed = true } };
    }
    return null;
}

/// One length-valued attribute, or `default` when the element does not carry
/// it.
fn lengthOf(
    e: xml.Element,
    name: []const u8,
    axis: length.Axis,
    viewport: length.Viewport,
    default: f64,
) Error!f64 {
    return (try optionalLengthOf(e, name, axis, viewport)) orelse default;
}

/// A length, or null when the attribute is absent.
///
/// `axis` is which measure of the viewport a percentage is of, and is a
/// property of the attribute rather than of its value: `width` and `cx` are
/// horizontal, `height` and `cy` vertical, and `r` and `stroke-width` are
/// neither, so they take §7.10's normalized diagonal. Getting one wrong is a
/// shape the right size in one direction and the wrong size in the other, on
/// documents that use percentages and nowhere else.
fn optionalLengthOf(
    e: xml.Element,
    name: []const u8,
    axis: length.Axis,
    viewport: length.Viewport,
) Error!?f64 {
    const raw = e.attr(name) orelse return null;
    return try length.parse(raw, axis, viewport);
}

/// An element's own `transform`, or the identity when it has none.
fn readTransform(e: xml.Element) Error!z2d.Transformation {
    const raw = e.attr("transform") orelse return .identity;
    return transform.parse(raw);
}

/// The four inherited presentation attributes, where an element names them.
///
/// Every one of them is refused rather than defaulted when it cannot be read.
/// resvg, and every browser, falls back to the initial value and paints on;
/// see `color.zig` for why this does not.
fn readInherited(e: xml.Element, viewport: length.Viewport) Error!Inherited {
    return .{
        .fill = if (e.attr("fill")) |v| try color.parsePaint(v) else null,
        .fill_opacity = if (e.attr("fill-opacity")) |v| try color.parseOpacity(v) else null,
        .fill_rule = if (e.attr("fill-rule")) |v| try parseFillRule(v) else null,
        .current_color = if (e.attr("color")) |v| try color.parseColor(v) else null,
        .stroke = if (e.attr("stroke")) |v| try color.parsePaint(v) else null,
        .stroke_width = try optionalLengthOf(e, "stroke-width", .other, viewport),
        .stroke_opacity = if (e.attr("stroke-opacity")) |v| try color.parseOpacity(v) else null,
        .stroke_linecap = if (e.attr("stroke-linecap")) |v| try parseLineCap(v) else null,
        .stroke_linejoin = if (e.attr("stroke-linejoin")) |v| try parseLineJoin(v) else null,
        .stroke_miterlimit = if (e.attr("stroke-miterlimit")) |v| try parseMiterLimit(v) else null,
        // Borrowed rather than parsed: see `Inherited.stroke_dasharray`.
        .stroke_dasharray = e.attr("stroke-dasharray"),
        .stroke_dashoffset = try optionalLengthOf(e, "stroke-dashoffset", .other, viewport),
    };
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

/// `nonzero` or `evenodd`, and nothing else.
///
/// Matched with regard to case, unlike a colour name. The difference is real
/// and it is not an inconsistency: a colour keyword is CSS, where keywords are
/// ASCII case-insensitive, while this is an XML attribute value, where they
/// are not. resvg draws `fill-rule="EVENODD"` with the nonzero rule, which is
/// the same reading.
fn parseFillRule(text: []const u8) Error!z2d.options.FillRule {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, t, "nonzero")) return .non_zero;
    if (std.mem.eql(u8, t, "evenodd")) return .even_odd;
    return error.BadFillRule;
}

/// The elements that carry no geometry and so may be passed over.
fn isIgnorable(name: []const u8) bool {
    return xml.nameIs(name, "title") or
        xml.nameIs(name, "desc") or
        xml.nameIs(name, "metadata") or
        xml.nameIs(name, "defs");
}

/// Read one document out of `src` and satisfy yourself it can be drawn.
///
/// Allocates nothing: the returned `Document` borrows `src`, which must
/// outlive it.
///
/// ## Why this drains the iterator
///
/// Everything a document can be refused for is refused here, before the caller
/// has drawn anything: a `<g>` at the end of a document is an error rather
/// than four shapes painted and then an error.
///
/// The obvious way to do that is a validating walk beside the drawing one --
/// and it was, and the two drifted. The reader knew a `<path>` inside `<defs>`
/// was not a shape and the iterator did not; the reader parsed each transform
/// and only the iterator composed them, so a pair that multiplied to an
/// infinity passed validation and failed while drawing. Each was a walk that
/// had to be kept in step with another walk by hand.
///
/// So there is one walk. `read` finds the root and then runs the *same*
/// iterator the renderer will, to the end, throwing the shapes away. Whatever
/// it refuses, `read` refuses, and `shape_count` is the number it produced
/// rather than a number counted alongside it. Agreement is not tested for
/// here, it is the only thing that can happen.
pub fn read(src: []const u8) Error!Document {
    var reader: xml.Reader = .init(src);

    // The root, for the three things the iterator has no use for: how large
    // the document says it is, what coordinate system its shapes are in, and
    // how the one is fitted into the other. The first element of an SVG
    // document is its `<svg>`; anything else is not one.
    var doc: Document = while (true) switch (try reader.next()) {
        .start_element => |e| {
            if (!xml.nameIs(e.name, "svg")) return error.NotAnSvg;
            break try readRoot(e, src);
        },
        .eof => return error.NotAnSvg,
        else => {},
    };

    var it = doc.paths();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    if (count == 0) return error.NoPath;
    doc.shape_count = count;
    return doc;
}

/// The root `<svg>`'s own attributes.
///
/// `width` and `height` are read against a viewport that is not known yet,
/// which is not the circularity it looks like: a percentage there would be of
/// the *parent* viewport, and a standalone document has none. So a percentage
/// resolves to zero and the `viewBox` supplies the size instead, which is what
/// resvg does with the `width="100%" height="100%"` that drawing programs like
/// to write.
fn readRoot(e: xml.Element, src: []const u8) Error!Document {
    const view_box: ?ViewBox = if (e.attr("viewBox")) |raw|
        try parseViewBox(raw)
    else
        null;

    const named_width = if (e.attr("width")) |raw|
        try length.parse(raw, .x, .unknown)
    else
        null;
    const named_height = if (e.attr("height")) |raw|
        try length.parse(raw, .y, .unknown)
    else
        null;

    // A named size wins, unless it came out as nothing -- which is what a
    // percentage of an unknown viewport does, and what `width="0"` means as
    // well. The viewBox is the fallback, and with neither there is nothing to
    // say how big the picture is.
    const width = pick(named_width, if (view_box) |vb| vb.width else null) orelse
        return error.NoSize;
    const height = pick(named_height, if (view_box) |vb| vb.height else null) orelse
        return error.NoSize;

    return .{
        .view_box = view_box,
        .width = width,
        .height = height,
        .preserve_aspect_ratio = if (e.attr("preserveAspectRatio")) |raw|
            try PreserveAspectRatio.parse(raw)
        else
            .meet_centred,
        .src = src,
        .shape_count = 0,
        .root = try readInherited(e, .unknown),
    };
}

/// The first of the two that is a usable extent.
fn pick(named: ?f64, fallback: ?f64) ?f64 {
    if (named) |v| if (v > 0) return v;
    if (fallback) |v| if (v > 0) return v;
    return null;
}

/// `min-x min-y width height`, separated by whitespace or commas.
fn parseViewBox(raw: []const u8) Error!ViewBox {
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
/// z2d does not re-export its path node type, so it is named through the
/// field that holds them rather than spelled out.
const PathNode = std.meta.Elem(@FieldType(z2d.Path, "nodes").Slice);

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

/// Every `d` in a document, for a test to look at.
fn collect(gpa: std.mem.Allocator, src: []const u8) ![][]const u8 {
    const doc = try read(src);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = doc.paths();
    while (try it.next()) |shape| try out.append(gpa, shape.geometry.path);
    return out.toOwnedSlice(gpa);
}

test "a well formed icon reads" {
    const doc = try read(icon);
    try testing.expectEqual(@as(f64, 0), doc.view_box.?.min_x);
    try testing.expectEqual(@as(f64, 24), doc.view_box.?.width);
    // With no `width` or `height`, the viewBox's extent is the size.
    try testing.expectEqual(@as(f64, 24), doc.width);
    try testing.expectEqual(@as(f64, 24), doc.height);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);

    var it = doc.paths();
    try testing.expectEqualStrings("M3,9H7L12,4V20L7,15H3V9Z", (try it.next()).?.geometry.path);
    try testing.expectEqual(@as(?Shape, null), try it.next());
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
    const doc = try read(src);
    try testing.expectEqual(@as(usize, 3), doc.shape_count);

    const found = try collect(gpa, src);
    defer gpa.free(found);
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
    const doc = try read(src);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);

    const found = try collect(gpa, src);
    defer gpa.free(found);
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
        const doc = try read(src);
        const found = try collect(gpa, src);
        defer gpa.free(found);
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
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 2), found.len);
}

test "a self-closing ignorable does not end the subtree it is in" {
    // The counter used to come down on *any* end tag while inside a `<defs>`,
    // so a `<title/>` in there ended the skipping early and everything after
    // it was drawn.
    const gpa = testing.allocator;
    const src = "<svg viewBox=\"0 0 8 8\"><defs><title/><path d=\"M9 9Z\"/></defs>" ++
        "<path d=\"M0 0Z\"/></svg>";
    const doc = try read(src);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
    const found = try collect(gpa, src);
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("M0 0Z", found[0]);
}

test "an element with geometry this reader cannot draw is refused" {
    try testing.expectError(
        error.UnsupportedElement,
        read("<svg viewBox=\"0 0 24 24\"><use href=\"#a\"/></svg>"),
    );
    try testing.expectError(
        error.UnsupportedElement,
        read("<svg viewBox=\"0 0 24 24\"><text x=\"1\" y=\"1\">hi</text></svg>"),
    );
    try testing.expectError(
        error.UnsupportedElement,
        read("<svg viewBox=\"0 0 24 24\"><image href=\"a.png\"/></svg>"),
    );
}

test "a document is refused before any of it is drawn" {
    // The `<g>` is last, after two perfectly good shapes. Reading has to fail
    // rather than hand out those two and fail on the third, which would be a
    // half-drawn picture and an error at once.
    try testing.expectError(error.UnsupportedElement, read(
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/><use href=\"#a\"/></svg>",
    ));
    try testing.expectError(error.NoPath, read(
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path/></svg>",
    ));
}

test "elements that carry no geometry are passed over" {
    const doc = try read(
        "<svg viewBox=\"0 0 24 24\"><title>x</title><desc>y</desc><path d=\"M0 0L2 2Z\"/></svg>",
    );
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
}

test "a viewBox that is not four positive numbers is refused" {
    try testing.expectError(error.BadViewBox, read("<svg viewBox=\"0 0\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read("<svg viewBox=\"0 0 0 0\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read("<svg viewBox=\"0 0 1 1 1\"><path d=\"M0 0Z\"/></svg>"));
    // A document with no `viewBox` at all is not a bad viewBox -- it is a
    // document whose user units are pixels, and which has to say how large it
    // is some other way.
    try testing.expectError(error.NoSize, read("<svg><path d=\"M0 0Z\"/></svg>"));
}

test "a document with no path is refused" {
    try testing.expectError(error.NoPath, read("<svg viewBox=\"0 0 24 24\"></svg>"));
    try testing.expectError(error.NoPath, read("<svg viewBox=\"0 0 24 24\"><path/></svg>"));
}

test "the viewBox is scaled into the box asked for" {
    const gpa = testing.allocator;
    const doc = try read(icon);
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    // A 24-unit viewBox into a 48-pixel box doubles everything.
    var it = doc.paths();
    try buildShape(&p, gpa, (try it.next()).?.geometry, doc.transformFor(0, 0, 48, 48), .{});
    try testing.expectApproxEqAbs(@as(f64, 6), p.nodes.items[0].move_to.point.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 18), p.nodes.items[0].move_to.point.y, 1e-9);
}

test "a box of a different shape letterboxes rather than distorting" {
    const doc = try read(icon);
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
    const sized = try read("<svg width=\"64\" height=\"32\" viewBox=\"0 0 16 16\"><path d=\"M0 0Z\"/></svg>");
    try testing.expectEqual(@as(f64, 64), sized.width);
    try testing.expectEqual(@as(f64, 32), sized.height);
    // The viewBox's extent is the fallback.
    const boxed = try read("<svg viewBox=\"0 0 16 8\"><path d=\"M0 0Z\"/></svg>");
    try testing.expectEqual(@as(f64, 16), boxed.width);
    try testing.expectEqual(@as(f64, 8), boxed.height);
    // A percentage of a viewport that does not exist is not a size, so the
    // viewBox supplies it -- which is what drawing programs' `100%` needs.
    const percent = try read("<svg width=\"100%\" height=\"100%\" viewBox=\"0 0 16 8\"><path d=\"M0 0Z\"/></svg>");
    try testing.expectEqual(@as(f64, 16), percent.width);
    // Units are resolved: 96pt is 128 pixels.
    const units = try read("<svg width=\"96pt\" height=\"48pt\" viewBox=\"0 0 16 8\"><path d=\"M0 0Z\"/></svg>");
    try testing.expectApproxEqAbs(@as(f64, 128), units.width, 1e-9);
    // And with neither there is nothing to go on.
    try testing.expectError(error.NoSize, read("<svg><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.NoSize, read("<svg width=\"0\" height=\"0\"><path d=\"M0 0Z\"/></svg>"));
}

test "a percentage is measured against the viewBox, not the drawn size" {
    // 50% of a viewBox height of 200 is 100 user units, whatever the document
    // says it is in pixels.
    const doc = try read(
        "<svg width=\"100\" height=\"50\" viewBox=\"0 0 100 200\">" ++
            "<rect width=\"10\" height=\"50%\"/></svg>",
    );
    try testing.expectEqual(@as(f64, 100), doc.viewport().width);
    try testing.expectEqual(@as(f64, 200), doc.viewport().height);
    var it = doc.paths();
    const shape = (try it.next()).?;
    try testing.expectApproxEqAbs(@as(f64, 100), shape.geometry.rect.height, 1e-9);
}

test "the fitting algorithm places the viewBox in the box" {
    // A 10x10 viewBox into an 80x40 box: meet scales by 4, slice by 8.
    const src = "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"";
    const tail = "\"><path d=\"M0 0Z\"/></svg>";

    const mid = (try read(src ++ "xMidYMid meet" ++ tail)).transformFor(0, 0, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 4), mid.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), mid.dy, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 20), mid.tx, 1e-12); // (80 - 40) / 2
    try testing.expectApproxEqAbs(@as(f64, 0), mid.ty, 1e-12);

    const min = (try read(src ++ "xMinYMin meet" ++ tail)).transformFor(0, 0, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 0), min.tx, 1e-12);

    const max = (try read(src ++ "xMaxYMax meet" ++ tail)).transformFor(0, 0, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 40), max.tx, 1e-12);

    // Slice takes the larger ratio, so the viewBox overflows and the leftover
    // is negative -- the same arithmetic saying which part is kept.
    const slice = (try read(src ++ "xMidYMid slice" ++ tail)).transformFor(0, 0, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 8), slice.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), slice.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -20), slice.ty, 1e-12); // (40 - 80) / 2

    // And `none` scales each axis on its own.
    const stretch = (try read(src ++ "none" ++ tail)).transformFor(0, 0, 80, 40);
    try testing.expectApproxEqAbs(@as(f64, 8), stretch.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), stretch.dy, 1e-12);
}

test "a document with no viewBox is scaled from its own size" {
    // Its user units are pixels at the size it claims, so drawing it larger
    // scales it rather than leaving it 1:1 in the corner.
    const doc = try read("<svg width=\"48\" height=\"24\"><path d=\"M0 0Z\"/></svg>");
    try testing.expectEqual(@as(?ViewBox, null), doc.view_box);
    const t = doc.transformFor(0, 0, 96, 48);
    try testing.expectApproxEqAbs(@as(f64, 2), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), t.dy, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), t.tx, 1e-12);
}

test "a viewBox with an offset is translated away" {
    const doc = try read("<svg viewBox=\"-12 -12 24 24\"><path d=\"M0 0Z\"/></svg>");
    const t = doc.transformFor(0, 0, 24, 24);
    try testing.expectApproxEqAbs(@as(f64, 1), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.ty, 1e-12);
}
