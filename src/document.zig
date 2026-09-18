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
} || transform.Error || color.Error || xml.Error;

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

/// A document that has been read and found drawable.
///
/// Borrows `src`, which must outlive it, and allocates nothing.
pub const Document = struct {
    view_box: ViewBox,
    /// The source this was read from. `paths` walks it again.
    src: []const u8,
    /// How many `<path>` elements `read` found, so that a caller can bound the
    /// work before starting it.
    shape_count: usize,
    /// What the root `<svg>` named, which every shape inherits unless a `<g>`
    /// or the shape itself overrides it. Informational: `paths` walks the
    /// document again and works this out for itself, rather than being seeded
    /// with it, so that the root and a `<g>` go through one code path.
    root: Inherited,

    /// Each `<path>`, in document order.
    ///
    /// Order is the painting order: SVG paints shapes in the order they are
    /// written, each over the last.
    pub fn paths(self: Document) PathIterator {
        return .{ .reader = .init(self.src) };
    }

    /// The viewBox-to-pixels transformation for drawing into `box`.
    ///
    /// The scale is uniform and takes the smaller of the two ratios, so a box
    /// of a different shape from the viewBox letterboxes rather than
    /// distorting -- which is what `preserveAspectRatio`'s default,
    /// `xMidYMid meet`, says to do. That attribute is not read; this is its
    /// default behaviour and the only behaviour available.
    pub fn transformFor(self: Document, x: f64, y: f64, width: f64, height: f64) z2d.Transformation {
        const scale = @min(width / self.view_box.width, height / self.view_box.height);
        return .{
            .ax = scale,
            .by = 0,
            .cx = 0,
            .dy = scale,
            .tx = x + (width - self.view_box.width * scale) / 2.0 - self.view_box.min_x * scale,
            .ty = y + (height - self.view_box.height * scale) / 2.0 - self.view_box.min_y * scale,
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

                if (try readGeometry(e)) |geometry| {
                    const effective = top.inherited.with(try readInherited(e));
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
                        .inherited = top.inherited.with(try readInherited(e)),
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
fn readGeometry(e: xml.Element) Error!?shapes.Geometry {
    if (xml.nameIs(e.name, "path")) {
        return .{ .path = e.attr("d") orelse return error.NoPath };
    }
    if (xml.nameIs(e.name, "rect")) {
        return .{
            .rect = .{
                .x = try length(e, "x", 0),
                .y = try length(e, "y", 0),
                .width = try length(e, "width", 0),
                .height = try length(e, "height", 0),
                // Null rather than zero: §9.2 makes one specified radius supply
                // the other, which "not specified" has to be distinguishable from
                // zero to express.
                .rx = try optionalLength(e, "rx"),
                .ry = try optionalLength(e, "ry"),
            },
        };
    }
    if (xml.nameIs(e.name, "circle")) {
        const r = try length(e, "r", 0);
        return .{ .ellipse = .{
            .cx = try length(e, "cx", 0),
            .cy = try length(e, "cy", 0),
            .rx = r,
            .ry = r,
        } };
    }
    if (xml.nameIs(e.name, "ellipse")) {
        return .{ .ellipse = .{
            .cx = try length(e, "cx", 0),
            .cy = try length(e, "cy", 0),
            .rx = try length(e, "rx", 0),
            .ry = try length(e, "ry", 0),
        } };
    }
    if (xml.nameIs(e.name, "line")) {
        return .{ .line = .{
            .x1 = try length(e, "x1", 0),
            .y1 = try length(e, "y1", 0),
            .x2 = try length(e, "x2", 0),
            .y2 = try length(e, "y2", 0),
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
fn length(e: xml.Element, name: []const u8, default: f64) Error!f64 {
    return (try optionalLength(e, name)) orelse default;
}

/// A length, or null when the attribute is absent.
///
/// A bare number, or one suffixed `px`, which is the same thing: the user unit
/// *is* the CSS pixel. Every other unit -- `pt`, `mm`, `em`, `%` -- is refused
/// rather than guessed at, because each needs something this reader has not
/// got yet: a document size, a font size, or a viewport to be a percentage of.
fn optionalLength(e: xml.Element, name: []const u8) Error!?f64 {
    const raw = e.attr(name) orelse return null;
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.endsWith(u8, text, "px")) text = text[0 .. text.len - 2];
    const value = std.fmt.parseFloat(f64, text) catch return error.BadLength;
    // An infinity or a NaN reaching the rasterizer is a hang or a panic rather
    // than a wrong picture, which is the same rule the path parser follows.
    if (!std.math.isFinite(value)) return error.BadLength;
    return value;
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
fn readInherited(e: xml.Element) Error!Inherited {
    return .{
        .fill = if (e.attr("fill")) |v| try color.parsePaint(v) else null,
        .fill_opacity = if (e.attr("fill-opacity")) |v| try color.parseOpacity(v) else null,
        .fill_rule = if (e.attr("fill-rule")) |v| try parseFillRule(v) else null,
        .current_color = if (e.attr("color")) |v| try color.parseColor(v) else null,
        .stroke = if (e.attr("stroke")) |v| try color.parsePaint(v) else null,
        .stroke_width = try optionalLength(e, "stroke-width"),
        .stroke_opacity = if (e.attr("stroke-opacity")) |v| try color.parseOpacity(v) else null,
        .stroke_linecap = if (e.attr("stroke-linecap")) |v| try parseLineCap(v) else null,
        .stroke_linejoin = if (e.attr("stroke-linejoin")) |v| try parseLineJoin(v) else null,
        .stroke_miterlimit = if (e.attr("stroke-miterlimit")) |v| try parseMiterLimit(v) else null,
        // Borrowed rather than parsed: see `Inherited.stroke_dasharray`.
        .stroke_dasharray = e.attr("stroke-dasharray"),
        .stroke_dashoffset = try optionalLength(e, "stroke-dashoffset"),
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

    // The root, for its `viewBox` -- the one thing the iterator has no use for
    // and so does not collect. The first element of an SVG document is its
    // `<svg>`; anything else is not one.
    var doc: Document = while (true) switch (try reader.next()) {
        .start_element => |e| {
            if (!xml.nameIs(e.name, "svg")) return error.NotAnSvg;
            break .{
                .view_box = try parseViewBox(e.attr("viewBox") orelse return error.BadViewBox),
                .src = src,
                .shape_count = 0,
                .root = try readInherited(e),
            };
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
    try testing.expectEqual(@as(f64, 0), doc.view_box.min_x);
    try testing.expectEqual(@as(f64, 24), doc.view_box.width);
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
    try testing.expectError(error.BadViewBox, read("<svg><path d=\"M0 0Z\"/></svg>"));
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

test "a viewBox with an offset is translated away" {
    const doc = try read("<svg viewBox=\"-12 -12 24 24\"><path d=\"M0 0Z\"/></svg>");
    const t = doc.transformFor(0, 0, 24, 24);
    try testing.expectApproxEqAbs(@as(f64, 1), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.ty, 1e-12);
}
