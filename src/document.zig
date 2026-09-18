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
const shapes = @import("shapes.zig");
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
    /// a `<text>`, an `<image>`. Refused rather than skipped: skipping it
    /// would draw a picture that is quietly missing a piece.
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
} || transform.Error || color.Error || length.Error || ztree.ParseError;

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
    open_group: Group,
    close_group,
};

/// A container that needs a layer of its own.
pub const Group = struct {
    /// The `opacity` to composite the finished layer at.
    opacity: f64,
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
    current_color: ?color.Color,
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

    pub fn deinit(self: *Document) void {
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

/// Walks a document's drawable elements in painting order.
///
/// A depth-first walk with an explicit stack, so that suspending one subtree to
/// draw another -- which is the whole of what `<use>` does -- costs a frame
/// rather than a second parser.
pub const PathIterator = struct {
    doc: *const Document,
    /// What a percentage in this document is measured against.
    viewport: length.Viewport,
    stack: [max_container_depth + 1]Frame = undefined,
    depth: usize = 0,
    started: bool = false,

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
        /// Whether that close has already been reported.
        closed: bool = false,
    };

    pub fn next(self: *PathIterator) Error!?Item {
        const tree = self.doc.tree;

        if (!self.started) {
            self.started = true;
            const root = self.doc.root_node;
            const opacity = try self.opacityOf(root);
            self.stack[0] = .{
                .node = root,
                .next_child = 0,
                .inherited = try self.readInherited(root),
                .transform = try self.readTransform(root),
                .opens_layer = opacity < 1.0,
            };
            // The root is the one container the walk never meets as somebody's
            // child, so its layer is opened here rather than in `visit`.
            if (self.stack[0].opens_layer) return .{ .open_group = .{ .opacity = opacity } };
        }

        while (true) {
            const top = &self.stack[self.depth];
            const children = tree.node(top.node).children.items;
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

            if (try self.visit(child, top.*)) |item| return item;
        }
    }

    /// An element's own `opacity`, which is not inherited.
    fn opacityOf(self: *const PathIterator, node: ztree.NodeId) Error!f64 {
        const raw = self.attr(node, "opacity") orelse return 1.0;
        return color.parseOpacity(raw);
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
            if (!localIs(tree, node, "use")) break;

            hops += 1;
            if (hops > max_use_hops) return error.TooManyUseHops;

            // The `<use>` contributes its own paint and transform, and then
            // §5.6's `x` and `y` as a translation *inside* that.
            inherited = inherited.with(try self.readInherited(node));
            ctm = ctm.mul(try self.readTransform(node));
            const dx = try self.lengthOf(node, "x", .x, 0);
            const dy = try self.lengthOf(node, "y", .y, 0);
            if (dx != 0 or dy != 0) {
                ctm = ctm.mul(.{ .ax = 1, .by = 0, .cx = 0, .dy = 1, .tx = dx, .ty = dy });
            }
            node = try self.resolve(node);
        }

        const name = tree.node(node).name.local;
        if (isIgnorable(name)) return null;

        // The element's own attributes, on top of everything above it.
        const effective = inherited.with(try self.readInherited(node));
        const own_ctm = ctm.mul(try self.readTransform(node));
        if (!transform.isFinite(own_ctm)) return error.NonFiniteTransform;

        if (try self.readGeometry(node)) |geometry| {
            return .{ .shape = .{
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
                .opacity = try self.opacityOf(node),
                .transform = own_ctm,
            } };
        }

        if (isContainer(name)) {
            // A container's `opacity` applies to it once it is flattened, so
            // it needs a surface of its own to flatten into. One that does not
            // ask for that is invisible here, as it always was.
            const opacity = try self.opacityOf(node);
            try self.push(node, effective, own_ctm, opacity < 1.0);
            if (opacity < 1.0) return .{ .open_group = .{ .opacity = opacity } };
            return null;
        }

        // Refused rather than skipped: skipping it would draw a picture
        // quietly missing a piece.
        return error.UnsupportedElement;
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

    fn readInherited(self: *const PathIterator, node: ztree.NodeId) Error!Inherited {
        return .{
            .fill = if (self.attr(node, "fill")) |v| try color.parsePaint(v) else null,
            .fill_opacity = if (self.attr(node, "fill-opacity")) |v| try color.parseOpacity(v) else null,
            .fill_rule = if (self.attr(node, "fill-rule")) |v| try parseFillRule(v) else null,
            .current_color = if (self.attr(node, "color")) |v| try color.parseColor(v) else null,
            .stroke = if (self.attr(node, "stroke")) |v| try color.parsePaint(v) else null,
            .stroke_width = try self.optionalLengthOf(node, "stroke-width", .other),
            .stroke_opacity = if (self.attr(node, "stroke-opacity")) |v| try color.parseOpacity(v) else null,
            .stroke_linecap = if (self.attr(node, "stroke-linecap")) |v| try parseLineCap(v) else null,
            .stroke_linejoin = if (self.attr(node, "stroke-linejoin")) |v| try parseLineJoin(v) else null,
            .stroke_miterlimit = if (self.attr(node, "stroke-miterlimit")) |v| try parseMiterLimit(v) else null,
            .stroke_dasharray = self.attr(node, "stroke-dasharray"),
            .stroke_dashoffset = try self.optionalLengthOf(node, "stroke-dashoffset", .other),
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

/// The elements that hold other elements and pass their own attributes down.
///
/// The root is one of these, which is what lets `<svg>` and `<g>` share a code
/// path rather than the root being a special case that drifts from the general
/// one.
fn isContainer(name: []const u8) bool {
    return std.mem.eql(u8, name, "svg") or std.mem.eql(u8, name, "g");
}

/// The elements that carry no geometry and so may be passed over.
///
/// What is inside `<defs>` is not drawn where it stands -- that is what
/// `<defs>` is for -- but it is still in the tree and still indexed, so a
/// `<use>` can name it.
fn isIgnorable(name: []const u8) bool {
    return std.mem.eql(u8, name, "title") or
        std.mem.eql(u8, name, "desc") or
        std.mem.eql(u8, name, "metadata") or
        std.mem.eql(u8, name, "defs");
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
    };

    const root = tree.documentElement() orelse return error.NotAnSvg;
    if (!std.mem.eql(u8, tree.node(root).name.local, "svg")) return error.NotAnSvg;
    doc.root_node = root;

    try indexIds(&doc);
    try readRoot(&doc, root);

    var it = doc.paths();
    var count: usize = 0;
    while (try it.next()) |item| {
        // Shapes, not items: `shape_count` is what `Limits.max_shapes` bounds,
        // and a group is not a thing that gets painted.
        if (item == .shape) count += 1;
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
        read(testing.allocator, "<svg viewBox=\"0 0 24 24\"><text x=\"1\" y=\"1\">hi</text></svg>"),
    );
    try testing.expectError(
        error.UnsupportedElement,
        read(testing.allocator, "<svg viewBox=\"0 0 24 24\"><image href=\"a.png\"/></svg>"),
    );
}

test "a document is refused before any of it is drawn" {
    // The `<g>` is last, after two perfectly good shapes. Reading has to fail
    // rather than hand out those two and fail on the third, which would be a
    // half-drawn picture and an error at once.
    try testing.expectError(error.UnsupportedElement, read(
        testing.allocator,
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/><text>x</text></svg>",
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
