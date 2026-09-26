// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `<filter>`: SVG 1.1 §15.
//!
//! A filter takes the picture an element would have drawn, puts it through a
//! chain of image operations, and draws the result instead. This module reads
//! the element and its primitives; `raster.zig` runs them, because running one
//! needs surfaces and this file deliberately has none.
//!
//! ## What a filter is applied to
//!
//! Not the element's geometry -- the element's *rendering*. Everything the
//! element would have painted, fill and stroke and children and all, is drawn
//! into a surface of its own first, and the chain reads that. The layer
//! machinery `raster.zig` already has for group opacity is the same machinery,
//! which is why a filter costs no new idea there: it is one more thing that
//! happens to a layer between painting it and compositing it down.
//!
//! ## The two coordinate systems, and the third one nobody writes down
//!
//! `filterUnits` says where the filter *region* is -- the `x`, `y`, `width`
//! and `height` that bound the whole operation and clip its result. It
//! defaults to `objectBoundingBox`, and so do the region's own defaults:
//! `-10%, -10%, 120%, 120%`, which is §15.7.5's allowance for a blur to spread
//! a little past the thing it blurs. A blur wide enough to reach further than
//! that is cut off, and that is not a bug in the renderer: it is what the
//! document asked for by not widening the region.
//!
//! `primitiveUnits` says where each primitive's own numbers are -- a
//! `stdDeviation`, an `feOffset`'s `dx`, a subregion. It defaults to
//! `userSpaceOnUse`, the opposite default to the region's, exactly as
//! `<pattern>`'s two unit attributes default opposite ways.
//!
//! The third system is the one the filter actually runs in, and no attribute
//! names it: the *canvas*. A filter is a pixel operation and pixels are on the
//! canvas, so a `stdDeviation` in user units becomes a standard deviation in
//! device pixels by the scale of the matrix in force, and a rotation in that
//! matrix is **not** carried into the filter. A horizontal blur under
//! `rotate(45)` blurs along the screen's horizontal, not the element's. That
//! is what resvg does, it is what browsers do, and it is the reason the filter
//! region is an axis-aligned rectangle of the canvas rather than a rotated
//! one.
//!
//! ## Colour
//!
//! Filters run in **linearRGB** by default, which is §15.3's doing and is
//! almost always a surprise: blurring the boundary between white and black
//! gives a midpoint of 188, not 128, because the average is taken of the light
//! rather than of the numbers. `color-interpolation-filters: sRGB` switches it
//! off per primitive. Getting this wrong is not subtle -- it is worth about
//! seventy levels in the middle of every gradient a filter touches.
//!
//! ## Where this differs from resvg
//!
//! `filterRes` is ignored. It is a deprecated request to run the filter at a
//! lower resolution than the canvas and then scale the result up, it was
//! dropped from Filter Effects 1, and resvg ignores it too. Ignoring it draws
//! a *sharper* picture than the document asked for rather than a wrong one,
//! which is the same trade already taken for a rotated `<pattern>`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ztree = @import("ztree");
const z2d = @import("z2d");

const color = @import("color.zig");
const css = @import("css");
const document = @import("document.zig");
const length = @import("length.zig");
const resample = @import("resample.zig");

pub const Error = error{
    /// A `filterUnits` or `primitiveUnits` that is neither `userSpaceOnUse`
    /// nor `objectBoundingBox`.
    BadFilterUnits,
    /// An `fe...` element this does not implement. Refused rather than
    /// skipped: a chain with a link missing is not the picture the document
    /// asked for, and skipping one would draw something that looks finished.
    UnsupportedFilterPrimitive,
    /// An `in` naming something that cannot be supplied -- `BackgroundImage`
    /// and the paint inputs, which need a stack no renderer keeps, or a
    /// `result` name that no earlier primitive produced.
    BadFilterInput,
    /// A negative `stdDeviation`, which §15.17 makes an error.
    BadStdDeviation,
    /// A `color-interpolation-filters` that is neither `linearRGB` nor `sRGB`.
    BadColorInterpolation,
    /// More primitives in one filter than `max_primitives`.
    TooManyFilterPrimitives,
    /// A chain of `href` longer than `max_href_hops`.
    TooManyFilterHops,
    /// An `feColorMatrix` whose `type` is not one of the four, or whose
    /// `values` are the wrong number for it, or a negative `saturate`.
    BadColorMatrix,
    /// An `feFuncR`, `feFuncG`, `feFuncB` or `feFuncA` whose `type` is not one
    /// of the five, or whose numbers do not parse.
    BadTransferFunction,
    /// An `feComposite` whose `operator` is not one of §15.12's, or whose
    /// `k1` to `k4` do not parse.
    BadCompositeOperator,
    /// An `feBlend` whose `mode` is not one of Compositing and Blending's.
    BadBlendMode,
    /// An `feMorphology` whose `operator` is neither `erode` nor `dilate`, or
    /// whose `radius` is not one or two numbers.
    BadMorphology,
    /// An `feConvolveMatrix` whose `order` is not one or two whole numbers
    /// from 1 to `max_convolve_order`, whose target is outside the kernel,
    /// whose `edgeMode` or `preserveAlpha` is not one of its keywords, or
    /// whose numbers do not parse.
    BadConvolveMatrix,
    /// An `feDisplacementMap` whose channel selector is not `R`, `G`, `B` or
    /// `A`, or whose `scale` does not parse.
    BadDisplacementMap,
    /// An `feTurbulence` with a negative or unparseable `baseFrequency`, a
    /// `numOctaves` that is not a whole number of none or more, or a `type`
    /// or `stitchTiles` that is not one of its keywords.
    BadTurbulence,
    /// An `feDiffuseLighting` or `feSpecularLighting` with no light source,
    /// a negative constant, a `specularExponent` outside one to 128, or a
    /// number that does not parse.
    BadLighting,
} || color.Error || length.Error || document.Error || Allocator.Error;

/// The most `href` links to follow before giving up.
pub const max_href_hops = 16;

/// The widest or tallest `feConvolveMatrix` kernel. Every output pixel costs
/// the kernel's area in multiplications, so this bounds the work of one
/// primitive at 256 per pixel; the kernels documents use are three or five.
pub const max_convolve_order = 16;

/// The most primitives one filter may chain. Each is a full-canvas surface
/// while it is live, so this is a memory bound as much as a sanity one.
pub const max_primitives = 64;

/// Which coordinate system a `filterUnits` or `primitiveUnits` names.
pub const Units = enum {
    /// The user space in force on the filtered element.
    user_space,
    /// Fractions of §7.11's object bounding box: the extent of the filtered
    /// element's own geometry, before its own `transform` and without its
    /// stroke.
    object_bounding_box,
};

/// §15.3's `color-interpolation-filters`.
pub const ColorSpace = enum {
    /// The default, and the one nobody expects.
    linear_rgb,
    srgb,
};

/// What a primitive reads.
pub const Input = union(enum) {
    /// The element's own rendering.
    source_graphic,
    /// Its alpha channel alone, as black.
    source_alpha,
    /// The primitive before this one -- which is what an omitted `in` means
    /// for anything but the first, where it means `SourceGraphic`.
    previous,
    /// A `result` name an earlier primitive gave itself.
    named: []const u8,
};

/// The operation a primitive performs.
pub const Kind = union(enum) {
    /// §15.17.
    gaussian_blur: struct {
        in: Input,
        /// In `primitiveUnits`, and separately per axis: `stdDeviation="2 0"`
        /// blurs horizontally and not vertically.
        std_dev_x: f64,
        std_dev_y: f64,
    },
    /// §15.21.
    offset: struct { in: Input, dx: f64, dy: f64 },
    /// §15.16. Reads nothing: it fills its subregion with one colour.
    flood: struct {
        /// Null where the document wrote `currentColor`, which is resolved
        /// against the filtered element rather than against the filter.
        color: ?color.Color,
        opacity: f64,
    },
    /// §15.19: several inputs stacked in document order, the first at the
    /// bottom. The nodes are `Filter.merge_nodes[first..][0..count]`.
    merge: struct { first: usize, count: usize },
    /// §15.10. Every `type` is read into the matrix it stands for, so the
    /// runner has one operation rather than four: row-major, five columns,
    /// the fifth being the constant.
    color_matrix: struct { in: Input, matrix: [20]f64 },
    /// §15.11: one function per channel, red, green, blue, alpha.
    component_transfer: struct { in: Input, funcs: [4]TransferFunction },
    /// §15.12: `in` composited with `in2` by a Porter-Duff operator, or by
    /// `arithmetic`'s `k1*i1*i2 + k2*i1 + k3*i2 + k4`.
    composite: struct { in: Input, in2: Input, operator: CompositeOperator, k: [4]f64 = @splat(0) },
    /// §15.9, with Filter Effects 1's modes: `in` blended over `in2`.
    blend: struct { in: Input, in2: Input, mode: BlendMode },
    /// §15.20: the input's subregion repeated across this one's.
    tile: struct { in: Input },
    /// §15.18: each channel's least or greatest value over a rectangle
    /// `radius_x` either side and `radius_y` above and below, in
    /// `primitiveUnits`. Zero or less in either passes the input through, as
    /// Filter Effects 1 has it.
    morphology: struct { in: Input, dilate: bool, radius_x: f64, radius_y: f64 },
    /// §15.13: a weighted sum over an `order_x` by `order_y` neighbourhood.
    convolve_matrix: ConvolveMatrix,
    /// §15.15: each pixel of `in` fetched from where `in2` says, `scale`
    /// times a channel's distance from a half, in `primitiveUnits`. The
    /// channels are 0 to 3 for red, green, blue and alpha.
    displacement_map: struct { in: Input, in2: Input, scale: f64, x_channel: u2, y_channel: u2 },
    /// §15.23: Perlin noise, from the specification's own reference code.
    /// Reads nothing.
    turbulence: Turbulence,
    /// §15.14 and §15.22: the input's alpha taken as a surface and lit.
    lighting: Lighting,
    /// Filter Effects 1's `feDropShadow`: the input over a blurred, offset,
    /// flooded copy of its own alpha. Its defaults are its own -- two for
    /// each of `dx`, `dy` and `stdDeviation`.
    /// §15.18 of SVG 1.1, 9.15 of Filter Effects 1: a picture, fitted into
    /// the subregion as an `<image>` is into its rectangle, or an element of
    /// the document drawn as a `<use>` of it would be. Reads nothing.
    image: struct {
        /// The `feImage` element, which a decoded picture is kept under.
        node: ztree.NodeId,
        /// As written; null where there is none, which draws nothing.
        href: ?[]const u8,
        preserve_aspect_ratio: document.PreserveAspectRatio = .{},
        sampling: resample.Sampling = .smooth,
    },
    drop_shadow: struct {
        in: Input,
        dx: f64 = 2,
        dy: f64 = 2,
        std_dev_x: f64 = 2,
        std_dev_y: f64 = 2,
        /// Null for `currentColor`.
        color: ?color.Color,
        opacity: f64,
    },
};

pub const Lighting = struct {
    in: Input,
    /// `feSpecularLighting` rather than `feDiffuseLighting`.
    specular: bool,
    surface_scale: f64 = 1,
    /// `diffuseConstant` or `specularConstant`.
    constant: f64 = 1,
    /// `specularExponent`, for a specular one.
    exponent: f64 = 1,
    /// `lighting-color`; null for `currentColor`, which is the filtered
    /// element's.
    color: ?color.Color,
    light: Light,
};

/// The first light-source child of a lighting primitive.
pub const Light = union(enum) {
    /// §15.25, in degrees.
    distant: struct { azimuth: f64 = 0, elevation: f64 = 0 },
    /// §15.26, in `primitiveUnits`.
    point: [3]f64,
    /// §15.27.
    spot: struct {
        at: [3]f64,
        points_at: [3]f64,
        exponent: f64 = 1,
        /// Degrees; null for no cone.
        cone: ?f64 = null,
    },
};

pub const Turbulence = struct {
    base_frequency_x: f64 = 0,
    base_frequency_y: f64 = 0,
    /// At most `max_octaves`: past about nine, an octave adds less than one
    /// level of an 8-bit channel, so the clamp changes no pixel.
    octaves: u32 = 1,
    /// Truncated towards zero, as Filter Effects 1 says.
    seed: i32 = 0,
    stitch: bool = false,
    fractal_noise: bool = false,

    pub const max_octaves = 24;
};

pub const EdgeMode = enum { duplicate, wrap, none };

pub const ConvolveMatrix = struct {
    in: Input,
    order_x: u32,
    order_y: u32,
    /// `kernelMatrix`, row by row, as a window into `Filter.numbers`. Null
    /// where it is missing or the wrong length for the order, which Filter
    /// Effects 1 makes a pass-through rather than an error.
    kernel: ?struct { first: usize, count: usize },
    /// Already defaulted: the kernel's sum, or one where that is nothing.
    divisor: f64,
    bias: f64,
    target_x: u32,
    target_y: u32,
    edge: EdgeMode,
    preserve_alpha: bool,
};

/// §15.12's `operator`, and Filter Effects 1's `lighter`.
pub const CompositeOperator = enum { over, in, out, atop, xor, lighter, arithmetic };

/// The modes of Compositing and Blending Level 1, which Filter Effects 1 lets
/// `feBlend` use; SVG 1.1 had the first five.
pub const BlendMode = enum {
    normal,
    multiply,
    screen,
    darken,
    lighten,
    overlay,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,

    /// The keyword, which is the tag with hyphens for underscores.
    pub fn parse(raw: []const u8) ?BlendMode {
        inline for (@typeInfo(BlendMode).@"enum".fields) |field| {
            const name = comptime blk: {
                var n: [field.name.len]u8 = undefined;
                for (&n, field.name) |*d, c| d.* = if (c == '_') '-' else c;
                break :blk n;
            };
            if (std.mem.eql(u8, raw, &name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// One `feFunc` element of an `feComponentTransfer`. §15.11.
pub const TransferFunction = struct {
    kind: Type = .identity,
    /// `tableValues`, as a window into `Filter.numbers`: `table` and
    /// `discrete` read it, and with no values they are the identity.
    first: usize = 0,
    count: usize = 0,
    slope: f64 = 1,
    intercept: f64 = 0,
    amplitude: f64 = 1,
    exponent: f64 = 1,
    offset: f64 = 0,

    pub const Type = enum { identity, table, discrete, linear, gamma };
};

/// One `fe...` element.
pub const Primitive = struct {
    kind: Kind,
    /// The name this primitive's output answers to, or null when it gave
    /// itself none and only the next primitive can read it.
    result: ?[]const u8 = null,
    color_space: ColorSpace = .linear_rgb,
    /// §15.7.6's subregion, in `primitiveUnits`. Null where the attribute was
    /// absent, which means "whatever the inputs covered" and is resolved when
    /// the chain is run rather than here.
    x: ?f64 = null,
    y: ?f64 = null,
    width: ?f64 = null,
    height: ?f64 = null,
};

/// A `<filter>`, read but not run.
pub const Filter = struct {
    units: Units = .object_bounding_box,
    primitive_units: Units = .user_space,
    /// The region, in whichever units `units` names. §15.7.5's defaults.
    x: f64 = -0.1,
    y: f64 = -0.1,
    width: f64 = 1.2,
    height: f64 = 1.2,
    primitives: []Primitive = &.{},
    /// The inputs of every `<feMerge>` in the filter, run together; each
    /// `merge` names a window into this.
    merge_nodes: []Input = &.{},
    /// Every list of numbers a primitive carries whose length the document
    /// chooses -- a transfer function's `tableValues` -- run together, each
    /// named by a window, the way `merge_nodes` is.
    numbers: []f64 = &.{},

    pub fn deinit(self: *Filter, gpa: Allocator) void {
        gpa.free(self.primitives);
        gpa.free(self.merge_nodes);
        gpa.free(self.numbers);
        self.* = .{};
    }

    /// §15.7.1: a filter with no primitives produces transparent black, so
    /// the element it is on draws nothing at all. That is a real answer rather
    /// than a failure, and resvg gives the same one.
    pub fn isEmpty(self: Filter) bool {
        return self.primitives.len == 0;
    }
};

/// Read the filter a node defines, or null when the node is not one.
///
/// §15.7 lets a filter take its attributes and its primitives from another
/// through `href`, the same way §13.2.4 lets a gradient take its stops. The
/// chain is walked from the far end back, so each filter in turn overrides
/// what it inherited -- and the *nearest* one with primitives of its own
/// supplies them, rather than the two sets being concatenated.
pub fn read(
    gpa: Allocator,
    tree: *const ztree.Document,
    ids: *const std.StringHashMapUnmanaged(ztree.NodeId),
    sheet: *const css.Stylesheet,
    node: ztree.NodeId,
    viewport: length.Viewport,
) Error!?Filter {
    if (!std.mem.eql(u8, tree.node(node).name.local, "filter")) return null;

    var chain: [max_href_hops]ztree.NodeId = undefined;
    var links: usize = 0;
    var walk = node;
    while (true) {
        if (links == max_href_hops) return error.TooManyFilterHops;
        chain[links] = walk;
        links += 1;
        const next = inheritsFrom(tree, ids, walk) orelse break;
        var seen = false;
        for (chain[0..links]) |c| {
            if (c == next) seen = true;
        }
        if (seen) break;
        walk = next;
    }

    var result: Filter = .{};
    errdefer result.deinit(gpa);

    // The attributes, far end first so the nearest wins.
    var named: Named = .{};
    var i = links;
    while (i > 0) {
        i -= 1;
        try applyAttributes(tree, chain[i], viewport, &result, &named);
    }
    // §15.7.5's defaults are percentages, `-10%` and `120%`, and what a
    // percentage is of depends on the units the chain settled on: a fraction
    // of the bounding box, or of the viewport in user space. So a coordinate
    // nothing named is filled in only now that the units are known -- taking
    // the fractions as user units would put the region a tenth of a unit
    // from the origin, whatever size the document is.
    if (result.units == .user_space) {
        if (!named.x) result.x = -0.1 * viewport.width;
        if (!named.y) result.y = -0.1 * viewport.height;
        if (!named.width) result.width = 1.2 * viewport.width;
        if (!named.height) result.height = 1.2 * viewport.height;
    }

    // The primitives, nearest end first so the first filter in the chain that
    // has any is the one they come from.
    for (chain[0..links]) |n| {
        if (hasPrimitive(tree, n)) {
            try readPrimitives(gpa, tree, sheet, n, viewport, &result);
            break;
        }
    }
    return result;
}

/// The filter this one takes its unnamed attributes and its primitives from.
fn inheritsFrom(
    tree: *const ztree.Document,
    ids: *const std.StringHashMapUnmanaged(ztree.NodeId),
    node: ztree.NodeId,
) ?ztree.NodeId {
    const raw = tree.attributeValue(node, "", "href") orelse
        tree.attributeValue(node, document.xlink_ns, "href") orelse
        return null;
    const target = std.mem.trim(u8, raw, " \t\r\n");
    if (target.len < 2 or target[0] != '#') return null;
    const next = ids.get(target[1..]) orelse return null;
    if (!std.mem.eql(u8, tree.node(next).name.local, "filter")) return null;
    return next;
}

fn hasPrimitive(tree: *const ztree.Document, node: ztree.NodeId) bool {
    for (tree.node(node).children.items) |child| {
        const n = tree.node(child);
        if (n.kind == .element and std.mem.startsWith(u8, n.name.local, "fe")) return true;
    }
    return false;
}

/// Which of the region's coordinates some filter in the chain named.
const Named = struct {
    x: bool = false,
    y: bool = false,
    width: bool = false,
    height: bool = false,
};

fn applyAttributes(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    viewport: length.Viewport,
    out: *Filter,
    named: *Named,
) Error!void {
    if (try unitsOf(tree, node, "filterUnits")) |u| out.units = u;
    if (try unitsOf(tree, node, "primitiveUnits")) |u| out.primitive_units = u;
    if (try coord(tree, node, "x", .x, out.units, viewport)) |v| {
        out.x = v;
        named.x = true;
    }
    if (try coord(tree, node, "y", .y, out.units, viewport)) |v| {
        out.y = v;
        named.y = true;
    }
    if (try coord(tree, node, "width", .x, out.units, viewport)) |v| {
        out.width = v;
        named.width = true;
    }
    if (try coord(tree, node, "height", .y, out.units, viewport)) |v| {
        out.height = v;
        named.height = true;
    }
}

fn readPrimitives(
    gpa: Allocator,
    tree: *const ztree.Document,
    sheet: *const css.Stylesheet,
    node: ztree.NodeId,
    viewport: length.Viewport,
    out: *Filter,
) Error!void {
    // `color-interpolation-filters` is inherited, so what the `<filter>`
    // itself says is the default for every primitive in it.
    const inherited = try colorSpaceOf(tree, sheet, node) orelse ColorSpace.linear_rgb;

    var prims: std.ArrayList(Primitive) = .empty;
    defer prims.deinit(gpa);
    var merges: std.ArrayList(Input) = .empty;
    defer merges.deinit(gpa);
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(gpa);

    for (tree.node(node).children.items) |child| {
        const n = tree.node(child);
        if (n.kind != .element) continue;
        if (!std.mem.startsWith(u8, n.name.local, "fe")) continue;
        if (prims.items.len == max_primitives) return error.TooManyFilterPrimitives;

        const name = n.name.local;
        const kind: Kind = if (std.mem.eql(u8, name, "feGaussianBlur")) blk: {
            var sx: f64 = 0;
            var sy: f64 = 0;
            if (attr(tree, child, "stdDeviation")) |raw| {
                const pair = try twoNumbers(raw);
                sx = pair[0];
                sy = pair[1];
            }
            if (sx < 0 or sy < 0) return error.BadStdDeviation;
            break :blk .{ .gaussian_blur = .{
                .in = inputOf(tree, child, "in"),
                .std_dev_x = sx,
                .std_dev_y = sy,
            } };
        } else if (std.mem.eql(u8, name, "feOffset")) blk: {
            break :blk .{ .offset = .{
                .in = inputOf(tree, child, "in"),
                .dx = try number(tree, child, "dx"),
                .dy = try number(tree, child, "dy"),
            } };
        } else if (std.mem.eql(u8, name, "feFlood")) blk: {
            break :blk .{ .flood = .{
                .color = try floodColor(tree, sheet, child),
                .opacity = if (css.property(sheet, tree, child, "flood-opacity")) |raw|
                    try color.parseOpacity(raw)
                else
                    1.0,
            } };
        } else if (std.mem.eql(u8, name, "feMerge")) blk: {
            const first = merges.items.len;
            for (n.children.items) |grand| {
                const g = tree.node(grand);
                if (g.kind != .element) continue;
                if (!std.mem.eql(u8, g.name.local, "feMergeNode")) continue;
                try merges.append(gpa, inputOf(tree, grand, "in"));
            }
            break :blk .{ .merge = .{
                .first = first,
                .count = merges.items.len - first,
            } };
        } else if (std.mem.eql(u8, name, "feColorMatrix")) blk: {
            break :blk .{ .color_matrix = .{
                .in = inputOf(tree, child, "in"),
                .matrix = try colorMatrixOf(trimmedAttr(tree, child, "type"), attr(tree, child, "values")),
            } };
        } else if (std.mem.eql(u8, name, "feComponentTransfer")) blk: {
            var funcs: [4]TransferFunction = @splat(.{});
            // §15.11 names one of each; a second of the same channel replaces
            // the first, as resvg has it.
            for (n.children.items) |grand| {
                const g = tree.node(grand);
                if (g.kind != .element) continue;
                const channel: usize = if (std.mem.eql(u8, g.name.local, "feFuncR"))
                    0
                else if (std.mem.eql(u8, g.name.local, "feFuncG"))
                    1
                else if (std.mem.eql(u8, g.name.local, "feFuncB"))
                    2
                else if (std.mem.eql(u8, g.name.local, "feFuncA"))
                    3
                else
                    continue;
                funcs[channel] = try transferFunction(gpa, tree, grand, &numbers);
            }
            break :blk .{ .component_transfer = .{ .in = inputOf(tree, child, "in"), .funcs = funcs } };
        } else if (std.mem.eql(u8, name, "feComposite")) blk: {
            const op_name = trimmedAttr(tree, child, "operator") orelse "over";
            const op = std.meta.stringToEnum(CompositeOperator, op_name) orelse return error.BadCompositeOperator;
            var k: [4]f64 = @splat(0);
            if (op == .arithmetic) {
                inline for (.{ "k1", "k2", "k3", "k4" }, 0..) |key, j| {
                    if (trimmedAttr(tree, child, key)) |raw| {
                        k[j] = std.fmt.parseFloat(f64, raw) catch return error.BadCompositeOperator;
                        if (!std.math.isFinite(k[j])) return error.BadCompositeOperator;
                    }
                }
            }
            break :blk .{ .composite = .{
                .in = inputOf(tree, child, "in"),
                .in2 = inputOf(tree, child, "in2"),
                .operator = op,
                .k = k,
            } };
        } else if (std.mem.eql(u8, name, "feBlend")) blk: {
            const mode_name = trimmedAttr(tree, child, "mode") orelse "normal";
            break :blk .{ .blend = .{
                .in = inputOf(tree, child, "in"),
                .in2 = inputOf(tree, child, "in2"),
                .mode = BlendMode.parse(mode_name) orelse return error.BadBlendMode,
            } };
        } else if (std.mem.eql(u8, name, "feTile")) blk: {
            break :blk .{ .tile = .{ .in = inputOf(tree, child, "in") } };
        } else if (std.mem.eql(u8, name, "feMorphology")) blk: {
            const op = trimmedAttr(tree, child, "operator") orelse "erode";
            const dilate = if (std.mem.eql(u8, op, "dilate"))
                true
            else if (std.mem.eql(u8, op, "erode"))
                false
            else
                return error.BadMorphology;
            var buf: [2]f64 = undefined;
            const r = try numberList(attr(tree, child, "radius") orelse "", &buf, error.BadMorphology);
            break :blk .{ .morphology = .{
                .in = inputOf(tree, child, "in"),
                .dilate = dilate,
                .radius_x = if (r.len > 0) r[0] else 0,
                .radius_y = if (r.len > 1) r[1] else if (r.len > 0) r[0] else 0,
            } };
        } else if (std.mem.eql(u8, name, "feConvolveMatrix")) blk: {
            break :blk .{ .convolve_matrix = try convolveMatrix(gpa, tree, child, &numbers) };
        } else if (std.mem.eql(u8, name, "feDiffuseLighting") or std.mem.eql(u8, name, "feSpecularLighting")) blk: {
            break :blk .{ .lighting = try lightingOf(tree, sheet, child, std.mem.eql(u8, name, "feSpecularLighting")) };
        } else if (std.mem.eql(u8, name, "feImage")) blk: {
            const href = tree.attributeValue(child, "", "href") orelse
                tree.attributeValue(child, document.xlink_ns, "href");
            break :blk .{ .image = .{
                .node = child,
                .href = if (href) |h| std.mem.trim(u8, h, " \t\r\n") else null,
                .preserve_aspect_ratio = if (attr(tree, child, "preserveAspectRatio")) |raw|
                    try document.PreserveAspectRatio.parse(raw)
                else
                    .{},
                .sampling = if (css.property(sheet, tree, child, "image-rendering")) |raw|
                    try document.parseImageRendering(raw)
                else
                    .smooth,
            } };
        } else if (std.mem.eql(u8, name, "feDropShadow")) blk: {
            var sx: f64 = 2;
            var sy: f64 = 2;
            if (attr(tree, child, "stdDeviation")) |raw| {
                const pair = try twoNumbers(raw);
                sx = pair[0];
                sy = pair[1];
            }
            if (sx < 0 or sy < 0) return error.BadStdDeviation;
            break :blk .{ .drop_shadow = .{
                .in = inputOf(tree, child, "in"),
                .dx = if (trimmedAttr(tree, child, "dx") != null) try number(tree, child, "dx") else 2,
                .dy = if (trimmedAttr(tree, child, "dy") != null) try number(tree, child, "dy") else 2,
                .std_dev_x = sx,
                .std_dev_y = sy,
                .color = try floodColor(tree, sheet, child),
                .opacity = if (css.property(sheet, tree, child, "flood-opacity")) |raw|
                    try color.parseOpacity(raw)
                else
                    1.0,
            } };
        } else if (std.mem.eql(u8, name, "feTurbulence")) blk: {
            break :blk .{ .turbulence = try turbulenceOf(tree, child) };
        } else if (std.mem.eql(u8, name, "feDisplacementMap")) blk: {
            const scale: f64 = if (trimmedAttr(tree, child, "scale")) |raw| s: {
                const v = std.fmt.parseFloat(f64, raw) catch return error.BadDisplacementMap;
                if (!std.math.isFinite(v)) return error.BadDisplacementMap;
                break :s v;
            } else 0;
            break :blk .{ .displacement_map = .{
                .in = inputOf(tree, child, "in"),
                .in2 = inputOf(tree, child, "in2"),
                .scale = scale,
                .x_channel = try channelOf(trimmedAttr(tree, child, "xChannelSelector")),
                .y_channel = try channelOf(trimmedAttr(tree, child, "yChannelSelector")),
            } };
        } else return error.UnsupportedFilterPrimitive;

        try prims.append(gpa, .{
            .kind = kind,
            .result = trimmedAttr(tree, child, "result"),
            .color_space = try colorSpaceOf(tree, sheet, child) orelse inherited,
            .x = try coord(tree, child, "x", .x, out.primitive_units, viewport),
            .y = try coord(tree, child, "y", .y, out.primitive_units, viewport),
            .width = try coord(tree, child, "width", .x, out.primitive_units, viewport),
            .height = try coord(tree, child, "height", .y, out.primitive_units, viewport),
        });
    }

    out.primitives = try prims.toOwnedSlice(gpa);
    out.merge_nodes = try merges.toOwnedSlice(gpa);
    out.numbers = try numbers.toOwnedSlice(gpa);
}

const identity_matrix: [20]f64 = .{
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
};

/// §15.10's four `type`s, each as the matrix it means.
///
/// `saturate` above one oversaturates, as Filter Effects 1 allows and
/// browsers draw; SVG 1.1 stopped at one, and resvg clamps there.
fn colorMatrixOf(kind: ?[]const u8, values: ?[]const u8) Error![20]f64 {
    const t = kind orelse "matrix";
    var buf: [20]f64 = undefined;
    const v = try numberList(values orelse "", &buf, error.BadColorMatrix);
    if (std.mem.eql(u8, t, "matrix")) {
        if (values == null) return identity_matrix;
        if (v.len != 20) return error.BadColorMatrix;
        return buf;
    }
    if (std.mem.eql(u8, t, "saturate")) {
        if (v.len > 1) return error.BadColorMatrix;
        const sat = if (v.len == 1) v[0] else 1;
        if (sat < 0) return error.BadColorMatrix;
        return saturateMatrix(sat);
    }
    if (std.mem.eql(u8, t, "hueRotate")) {
        if (v.len > 1) return error.BadColorMatrix;
        return hueRotateMatrix(if (v.len == 1) v[0] else 0);
    }
    if (std.mem.eql(u8, t, "luminanceToAlpha")) {
        if (v.len != 0) return error.BadColorMatrix;
        return .{
            0,      0,      0,      0, 0,
            0,      0,      0,      0, 0,
            0,      0,      0,      0, 0,
            0.2125, 0.7154, 0.0721, 0, 0,
        };
    }
    return error.BadColorMatrix;
}

pub fn saturateMatrix(s: f64) [20]f64 {
    return .{
        0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
        0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
        0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
        0,                 0,                 0,                 1, 0,
    };
}

pub fn hueRotateMatrix(degrees: f64) [20]f64 {
    const a = std.math.degreesToRadians(degrees);
    const c = @cos(a);
    const s = @sin(a);
    return .{
        0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
        0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
        0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
        0,                             0,                             0,                             1, 0,
    };
}

fn transferFunction(
    gpa: Allocator,
    tree: *const ztree.Document,
    node: ztree.NodeId,
    numbers: *std.ArrayList(f64),
) Error!TransferFunction {
    var f: TransferFunction = .{};
    const t = trimmedAttr(tree, node, "type") orelse return error.BadTransferFunction;
    f.kind = std.meta.stringToEnum(TransferFunction.Type, t) orelse return error.BadTransferFunction;
    f.first = numbers.items.len;
    if (attr(tree, node, "tableValues")) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
        while (it.next()) |word| {
            const v = std.fmt.parseFloat(f64, word) catch return error.BadTransferFunction;
            if (!std.math.isFinite(v)) return error.BadTransferFunction;
            try numbers.append(gpa, v);
        }
    }
    f.count = numbers.items.len - f.first;
    inline for (.{ "slope", "intercept", "amplitude", "exponent", "offset" }) |field| {
        if (trimmedAttr(tree, node, field)) |raw| {
            const v = std.fmt.parseFloat(f64, raw) catch return error.BadTransferFunction;
            if (!std.math.isFinite(v)) return error.BadTransferFunction;
            @field(f, field) = v;
        }
    }
    return f;
}

fn convolveMatrix(
    gpa: Allocator,
    tree: *const ztree.Document,
    node: ztree.NodeId,
    numbers: *std.ArrayList(f64),
) Error!ConvolveMatrix {
    var order_buf: [2]f64 = undefined;
    const order = try numberList(attr(tree, node, "order") orelse "", &order_buf, error.BadConvolveMatrix);
    const ox = if (order.len > 0) try wholeOrder(order[0]) else 3;
    const oy = if (order.len > 1) try wholeOrder(order[1]) else ox;

    // Every entry has to be a number, whatever the length; only a list of
    // the right length goes into the pool.
    var count: usize = 0;
    const raw_kernel = attr(tree, node, "kernelMatrix") orelse "";
    var check = std.mem.tokenizeAny(u8, raw_kernel, " \t\r\n,");
    while (check.next()) |word| {
        const v = std.fmt.parseFloat(f64, word) catch return error.BadConvolveMatrix;
        if (!std.math.isFinite(v)) return error.BadConvolveMatrix;
        count += 1;
    }
    const fits = count == ox * oy;
    const first = numbers.items.len;
    if (fits) {
        var it = std.mem.tokenizeAny(u8, raw_kernel, " \t\r\n,");
        while (it.next()) |word| try numbers.append(gpa, std.fmt.parseFloat(f64, word) catch unreachable);
    }

    var sum: f64 = 0;
    if (fits) for (numbers.items[first..]) |v| {
        sum += v;
    };
    // Filter Effects 1: the sum of the kernel, or one where the sum is
    // nothing; and a divisor of zero written out means that default too.
    const default_divisor: f64 = if (@abs(sum) < 1e-6) 1 else sum;
    var divisor = default_divisor;
    if (trimmedAttr(tree, node, "divisor")) |raw| {
        const v = std.fmt.parseFloat(f64, raw) catch return error.BadConvolveMatrix;
        if (!std.math.isFinite(v)) return error.BadConvolveMatrix;
        if (v != 0) divisor = v;
    }
    const bias: f64 = if (trimmedAttr(tree, node, "bias")) |raw| blk: {
        const v = std.fmt.parseFloat(f64, raw) catch return error.BadConvolveMatrix;
        if (!std.math.isFinite(v)) return error.BadConvolveMatrix;
        break :blk v;
    } else 0;

    const tx = try targetOf(trimmedAttr(tree, node, "targetX"), ox);
    const ty = try targetOf(trimmedAttr(tree, node, "targetY"), oy);
    const edge_name = trimmedAttr(tree, node, "edgeMode") orelse "duplicate";
    const edge = std.meta.stringToEnum(EdgeMode, edge_name) orelse return error.BadConvolveMatrix;
    const preserve = trimmedAttr(tree, node, "preserveAlpha") orelse "false";
    const preserve_alpha = if (std.mem.eql(u8, preserve, "true"))
        true
    else if (std.mem.eql(u8, preserve, "false"))
        false
    else
        return error.BadConvolveMatrix;

    return .{
        .in = inputOf(tree, node, "in"),
        .order_x = ox,
        .order_y = oy,
        .kernel = if (fits) .{ .first = first, .count = count } else null,
        .divisor = divisor,
        .bias = bias,
        .target_x = tx,
        .target_y = ty,
        .edge = edge,
        .preserve_alpha = preserve_alpha,
    };
}

fn lightingOf(
    tree: *const ztree.Document,
    sheet: *const css.Stylesheet,
    node: ztree.NodeId,
    specular: bool,
) Error!Lighting {
    var l: Lighting = .{
        .in = inputOf(tree, node, "in"),
        .specular = specular,
        .color = color.Color{ .r = 255, .g = 255, .b = 255 },
        .light = undefined,
    };
    if (try optionalNumber(tree, node, "surfaceScale")) |v| l.surface_scale = v;
    if (try optionalNumber(tree, node, if (specular) "specularConstant" else "diffuseConstant")) |v| {
        if (v < 0) return error.BadLighting;
        l.constant = v;
    }
    if (specular) if (try optionalNumber(tree, node, "specularExponent")) |v| {
        if (v < 1 or v > 128) return error.BadLighting;
        l.exponent = v;
    };
    if (css.property(sheet, tree, node, "lighting-color")) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        // Resolved against the filtered element, as `flood-color` is.
        l.color = if (std.mem.eql(u8, t, "currentColor")) null else try color.parseColor(t);
    }

    const light = for (tree.node(node).children.items) |child| {
        const n = tree.node(child);
        if (n.kind != .element) continue;
        const name = n.name.local;
        if (std.mem.eql(u8, name, "feDistantLight")) break Light{ .distant = .{
            .azimuth = try optionalNumber(tree, child, "azimuth") orelse 0,
            .elevation = try optionalNumber(tree, child, "elevation") orelse 0,
        } };
        if (std.mem.eql(u8, name, "fePointLight")) break Light{ .point = try position(tree, child, "x", "y", "z") };
        if (std.mem.eql(u8, name, "feSpotLight")) {
            const e = try optionalNumber(tree, child, "specularExponent") orelse 1;
            break Light{
                .spot = .{
                    .at = try position(tree, child, "x", "y", "z"),
                    .points_at = try position(tree, child, "pointsAtX", "pointsAtY", "pointsAtZ"),
                    // Filter Effects 1: a spot light's exponent is any positive
                    // number, and one where it is not.
                    .exponent = if (e > 0) e else 1,
                    .cone = try optionalNumber(tree, child, "limitingConeAngle"),
                },
            };
        }
    } else return error.BadLighting;
    l.light = light;
    return l;
}

fn position(tree: *const ztree.Document, node: ztree.NodeId, x: []const u8, y: []const u8, z: []const u8) Error![3]f64 {
    return .{
        try optionalNumber(tree, node, x) orelse 0,
        try optionalNumber(tree, node, y) orelse 0,
        try optionalNumber(tree, node, z) orelse 0,
    };
}

/// A finite number, or null when the attribute is absent.
fn optionalNumber(tree: *const ztree.Document, node: ztree.NodeId, name: []const u8) Error!?f64 {
    const raw = trimmedAttr(tree, node, name) orelse return null;
    const v = std.fmt.parseFloat(f64, raw) catch return error.BadLighting;
    if (!std.math.isFinite(v)) return error.BadLighting;
    return v;
}

fn turbulenceOf(tree: *const ztree.Document, node: ztree.NodeId) Error!Turbulence {
    var t: Turbulence = .{};
    var buf: [2]f64 = undefined;
    const f = try numberList(attr(tree, node, "baseFrequency") orelse "", &buf, error.BadTurbulence);
    if (f.len > 0) {
        t.base_frequency_x = f[0];
        t.base_frequency_y = if (f.len > 1) f[1] else f[0];
    }
    if (t.base_frequency_x < 0 or t.base_frequency_y < 0) return error.BadTurbulence;
    if (trimmedAttr(tree, node, "numOctaves")) |raw| {
        const v = std.fmt.parseFloat(f64, raw) catch return error.BadTurbulence;
        if (v != @floor(v) or v < 0) return error.BadTurbulence;
        t.octaves = @intFromFloat(@min(v, Turbulence.max_octaves));
    }
    if (trimmedAttr(tree, node, "seed")) |raw| {
        const v = std.fmt.parseFloat(f64, raw) catch return error.BadTurbulence;
        if (!std.math.isFinite(v)) return error.BadTurbulence;
        t.seed = @intFromFloat(std.math.clamp(@trunc(v), -std.math.maxInt(i32), std.math.maxInt(i32)));
    }
    const kind = trimmedAttr(tree, node, "type") orelse "turbulence";
    t.fractal_noise = if (std.mem.eql(u8, kind, "fractalNoise"))
        true
    else if (std.mem.eql(u8, kind, "turbulence"))
        false
    else
        return error.BadTurbulence;
    const stitch = trimmedAttr(tree, node, "stitchTiles") orelse "noStitch";
    t.stitch = if (std.mem.eql(u8, stitch, "stitch"))
        true
    else if (std.mem.eql(u8, stitch, "noStitch"))
        false
    else
        return error.BadTurbulence;
    return t;
}

/// `xChannelSelector` or `yChannelSelector`: alpha by default.
fn channelOf(raw: ?[]const u8) Error!u2 {
    const t = raw orelse return 3;
    if (t.len != 1) return error.BadDisplacementMap;
    return switch (t[0]) {
        'R' => 0,
        'G' => 1,
        'B' => 2,
        'A' => 3,
        else => error.BadDisplacementMap,
    };
}

fn wholeOrder(v: f64) Error!u32 {
    if (v != @floor(v) or v < 1 or v > max_convolve_order) return error.BadConvolveMatrix;
    return @intFromFloat(v);
}

/// `targetX` or `targetY`: inside the kernel, and the middle of it by
/// default.
fn targetOf(raw: ?[]const u8, order: u32) Error!u32 {
    const t = raw orelse return order / 2;
    const v = std.fmt.parseFloat(f64, t) catch return error.BadConvolveMatrix;
    if (v != @floor(v) or v < 0 or v >= @as(f64, @floatFromInt(order))) return error.BadConvolveMatrix;
    return @intFromFloat(v);
}

/// Up to `buf.len` numbers separated by whitespace or commas; more than that,
/// or anything that is not a finite number, is `err`.
fn numberList(raw: []const u8, buf: []f64, err: Error) Error![]f64 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    while (it.next()) |word| {
        if (n == buf.len) return err;
        const v = std.fmt.parseFloat(f64, word) catch return err;
        if (!std.math.isFinite(v)) return err;
        buf[n] = v;
        n += 1;
    }
    return buf[0..n];
}

/// §15.7.2's defaulting, which is not the same for the first primitive as for
/// the rest: an omitted `in` on the first means `SourceGraphic` and on any
/// other means whatever the one before it produced. Both are `.previous`
/// here, and the chain runner knows that "previous" at the head of a chain is
/// the source.
fn inputOf(tree: *const ztree.Document, node: ztree.NodeId, name: []const u8) Input {
    const raw = trimmedAttr(tree, node, name) orelse return .previous;
    if (std.mem.eql(u8, raw, "SourceGraphic")) return .source_graphic;
    if (std.mem.eql(u8, raw, "SourceAlpha")) return .source_alpha;
    return .{ .named = raw };
}

fn floodColor(
    tree: *const ztree.Document,
    sheet: *const css.Stylesheet,
    node: ztree.NodeId,
) Error!?color.Color {
    const raw = css.property(sheet, tree, node, "flood-color") orelse return color.Color.black;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    // Resolved against the filtered element rather than against the filter,
    // which has no colour of its own.
    if (std.mem.eql(u8, t, "currentColor")) return null;
    return try color.parseColor(t);
}

fn colorSpaceOf(
    tree: *const ztree.Document,
    sheet: *const css.Stylesheet,
    node: ztree.NodeId,
) Error!?ColorSpace {
    const raw = css.property(sheet, tree, node, "color-interpolation-filters") orelse return null;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "linearRGB")) return .linear_rgb;
    if (std.mem.eql(u8, t, "sRGB")) return .srgb;
    // `auto` is the initial value of the property and means the same as
    // linearRGB for a filter; `inherit` is handled by there being nothing to
    // override.
    if (std.mem.eql(u8, t, "auto")) return .linear_rgb;
    if (std.mem.eql(u8, t, "inherit")) return null;
    return error.BadColorInterpolation;
}

fn attr(tree: *const ztree.Document, node: ztree.NodeId, name: []const u8) ?[]const u8 {
    return tree.attributeValue(node, "", name);
}

fn trimmedAttr(tree: *const ztree.Document, node: ztree.NodeId, name: []const u8) ?[]const u8 {
    const raw = tree.attributeValue(node, "", name) orelse return null;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    return if (t.len == 0) null else t;
}

fn number(tree: *const ztree.Document, node: ztree.NodeId, name: []const u8) Error!f64 {
    const raw = trimmedAttr(tree, node, name) orelse return 0;
    return std.fmt.parseFloat(f64, raw) catch error.BadLength;
}

/// One number sets both axes; two set them separately. §15.17 writes the pair
/// separated by whitespace or a comma.
fn twoNumbers(raw: []const u8) Error![2]f64 {
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    const first = it.next() orelse return .{ 0, 0 };
    const x = std.fmt.parseFloat(f64, first) catch return error.BadLength;
    const second = it.next() orelse return .{ x, x };
    const y = std.fmt.parseFloat(f64, second) catch return error.BadLength;
    if (it.next() != null) return error.BadLength;
    return .{ x, y };
}

fn unitsOf(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    name: []const u8,
) Error!?Units {
    const raw = tree.attributeValue(node, "", name) orelse return null;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "userSpaceOnUse")) return .user_space;
    if (std.mem.eql(u8, t, "objectBoundingBox")) return .object_bounding_box;
    return error.BadFilterUnits;
}

/// A coordinate in whichever units are in force: a length when they are user
/// space, and a bare fraction -- with a percentage meaning a hundredth --
/// when they are the bounding box.
fn coord(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    name: []const u8,
    axis: length.Axis,
    units: Units,
    viewport: length.Viewport,
) Error!?f64 {
    const raw = tree.attributeValue(node, "", name) orelse return null;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return null;
    if (units == .user_space) return try length.parse(t, axis, viewport);
    if (std.mem.endsWith(u8, t, "%")) {
        const v = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch return error.BadLength;
        return v / 100.0;
    }
    return std.fmt.parseFloat(f64, t) catch error.BadLength;
}

// -- tests -------------------------------------------------------------------

fn readTest(src: []const u8) !Filter {
    var doc = try document.read(testing.allocator, src);
    defer doc.deinit();
    return (try read(testing.allocator, doc.tree, &doc.ids, &doc.stylesheet, doc.ids.get("f").?, doc.viewport())).?;
}

fn primitivesOf(comptime body: []const u8) !Filter {
    return readTest("<svg viewBox=\"0 0 8 8\"><filter id=\"f\">" ++ body ++ "</filter><rect width=\"8\" height=\"8\"/></svg>");
}

test "every colour matrix type is read into the matrix it means" {
    var f = try primitivesOf("<feColorMatrix/>" ++
        "<feColorMatrix type=\"saturate\" values=\"0\"/>" ++
        "<feColorMatrix type=\"hueRotate\" values=\"90\"/>" ++
        "<feColorMatrix type=\"luminanceToAlpha\"/>" ++
        "<feColorMatrix values=\"1,2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20\"/>");
    defer f.deinit(testing.allocator);
    try testing.expectEqual(identity_matrix, f.primitives[0].kind.color_matrix.matrix);
    // Saturation nothing is the luminance in every channel.
    const grey = f.primitives[1].kind.color_matrix.matrix;
    try testing.expectApproxEqAbs(@as(f64, 0.213), grey[5], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.715), grey[11], 1e-12);
    // A quarter turn: §15.10's coefficients at cos 0 and sin 1.
    try testing.expectApproxEqAbs(@as(f64, 0), f.primitives[2].kind.color_matrix.matrix[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.2125), f.primitives[3].kind.color_matrix.matrix[15], 1e-12);
    try testing.expectEqual(@as(f64, 20), f.primitives[4].kind.color_matrix.matrix[19]);
}

test "a colour matrix with the wrong values is refused" {
    for ([_][]const u8{
        "<feColorMatrix values=\"1 0 0\"/>",
        "<feColorMatrix type=\"saturate\" values=\"-0.5\"/>",
        "<feColorMatrix type=\"saturate\" values=\"0.5 0.5\"/>",
        "<feColorMatrix type=\"hueRotate\" values=\"ninety\"/>",
        "<feColorMatrix type=\"luminanceToAlpha\" values=\"1\"/>",
        "<feColorMatrix type=\"sepia\"/>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadColorMatrix, readTest(src));
    }
}

test "transfer functions: one per channel, the last of each winning" {
    var f = try primitivesOf("<feComponentTransfer>" ++
        "<feFuncR type=\"table\" tableValues=\"0 1\"/>" ++
        "<feFuncG type=\"linear\" slope=\"2\" intercept=\"-0.5\"/>" ++
        "<feFuncA type=\"gamma\" exponent=\"3\"/>" ++
        "<feFuncR type=\"discrete\" tableValues=\"0.25, 0.5 0.75\"/>" ++
        "</feComponentTransfer>");
    defer f.deinit(testing.allocator);
    const funcs = f.primitives[0].kind.component_transfer.funcs;
    try testing.expectEqual(TransferFunction.Type.discrete, funcs[0].kind);
    try testing.expectEqualSlices(f64, &.{ 0.25, 0.5, 0.75 }, f.numbers[funcs[0].first..][0..funcs[0].count]);
    try testing.expectEqual(@as(f64, 2), funcs[1].slope);
    try testing.expectEqual(@as(f64, -0.5), funcs[1].intercept);
    try testing.expectEqual(TransferFunction.Type.identity, funcs[2].kind);
    try testing.expectEqual(@as(f64, 3), funcs[3].exponent);
    try testing.expectEqual(@as(f64, 1), funcs[3].amplitude);
}

test "a transfer function with no type, an unknown one, or a bad number is refused" {
    for ([_][]const u8{
        "<feComponentTransfer><feFuncR/></feComponentTransfer>",
        "<feComponentTransfer><feFuncR type=\"curve\"/></feComponentTransfer>",
        "<feComponentTransfer><feFuncG type=\"linear\" slope=\"steep\"/></feComponentTransfer>",
        "<feComponentTransfer><feFuncB type=\"table\" tableValues=\"0 x\"/></feComponentTransfer>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadTransferFunction, readTest(src));
    }
}

test "composite operators and blend modes are read by their keywords" {
    var f = try primitivesOf("<feComposite in2=\"SourceAlpha\"/>" ++
        "<feComposite operator=\"arithmetic\" k1=\"0.5\" k4=\"-1\"/>" ++
        "<feBlend/>" ++
        "<feBlend in=\"SourceGraphic\" mode=\"color-dodge\"/>");
    defer f.deinit(testing.allocator);
    const over = f.primitives[0].kind.composite;
    try testing.expectEqual(CompositeOperator.over, over.operator);
    try testing.expectEqual(Input.previous, over.in);
    try testing.expectEqual(Input.source_alpha, over.in2);
    try testing.expectEqual([4]f64{ 0.5, 0, 0, -1 }, f.primitives[1].kind.composite.k);
    try testing.expectEqual(BlendMode.normal, f.primitives[2].kind.blend.mode);
    // An omitted `in2` is the result before, as an omitted `in` is.
    try testing.expectEqual(Input.previous, f.primitives[2].kind.blend.in2);
    try testing.expectEqual(BlendMode.color_dodge, f.primitives[3].kind.blend.mode);
}

test "an unknown operator or mode is refused" {
    const cases = [_]struct { []const u8, Error }{
        .{ "<feComposite operator=\"plus\"/>", error.BadCompositeOperator },
        .{ "<feComposite operator=\"arithmetic\" k2=\"half\"/>", error.BadCompositeOperator },
        .{ "<feBlend mode=\"plus-lighter\"/>", error.BadBlendMode },
        .{ "<feBlend mode=\"color_dodge\"/>", error.BadBlendMode },
    };
    for (cases) |case| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{case[0]});
        try testing.expectError(case[1], readTest(src));
    }
}

test "a morphology radius is one number or two, and the operator one of two" {
    var f = try primitivesOf("<feMorphology/>" ++
        "<feMorphology operator=\"dilate\" radius=\"2\"/>" ++
        "<feMorphology radius=\"1, 3\"/>" ++
        "<feTile in=\"SourceAlpha\"/>");
    defer f.deinit(testing.allocator);
    const none = f.primitives[0].kind.morphology;
    try testing.expect(!none.dilate);
    // No radius is zero, which passes the input through.
    try testing.expectEqual(@as(f64, 0), none.radius_x);
    const both = f.primitives[1].kind.morphology;
    try testing.expect(both.dilate);
    try testing.expectEqual(@as(f64, 2), both.radius_y);
    try testing.expectEqual(@as(f64, 3), f.primitives[2].kind.morphology.radius_y);
    try testing.expectEqual(Input.source_alpha, f.primitives[3].kind.tile.in);

    for ([_][]const u8{
        "<feMorphology operator=\"open\"/>",
        "<feMorphology radius=\"1 2 3\"/>",
        "<feMorphology radius=\"wide\"/>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadMorphology, readTest(src));
    }
}

test "a convolve matrix defaults its order, target and divisor" {
    var f = try primitivesOf("<feConvolveMatrix kernelMatrix=\"1 2 1 2 4 2 1 2 1\"/>" ++
        "<feConvolveMatrix order=\"2 1\" kernelMatrix=\"1 -1\" divisor=\"0\" targetX=\"1\" edgeMode=\"wrap\" preserveAlpha=\"true\"/>" ++
        // The wrong length for the order: a pass-through, not an error.
        "<feConvolveMatrix kernelMatrix=\"1 2 3\"/>" ++
        "<feConvolveMatrix/>");
    defer f.deinit(testing.allocator);
    const a = f.primitives[0].kind.convolve_matrix;
    try testing.expectEqual(@as(u32, 3), a.order_x);
    try testing.expectEqual(@as(u32, 1), a.target_y);
    try testing.expectEqual(@as(f64, 16), a.divisor);
    try testing.expectEqual(EdgeMode.duplicate, a.edge);
    const b = f.primitives[1].kind.convolve_matrix;
    try testing.expectEqual(@as(u32, 1), b.order_y);
    // A kernel summing to nothing divides by one, and a written divisor of
    // zero means that default.
    try testing.expectEqual(@as(f64, 1), b.divisor);
    try testing.expectEqual(@as(u32, 1), b.target_x);
    try testing.expect(b.preserve_alpha);
    try testing.expectEqualSlices(f64, &.{ 1, -1 }, f.numbers[b.kernel.?.first..][0..b.kernel.?.count]);
    try testing.expectEqual(@as(@TypeOf(a.kernel), null), f.primitives[2].kind.convolve_matrix.kernel);
    try testing.expectEqual(@as(@TypeOf(a.kernel), null), f.primitives[3].kind.convolve_matrix.kernel);
}

test "a convolve matrix with a bad order, target or keyword is refused" {
    for ([_][]const u8{
        "<feConvolveMatrix order=\"0\" kernelMatrix=\"1\"/>",
        "<feConvolveMatrix order=\"2.5\" kernelMatrix=\"1\"/>",
        "<feConvolveMatrix order=\"17\"/>",
        "<feConvolveMatrix kernelMatrix=\"1 x 1 1 1 1 1 1 1\"/>",
        "<feConvolveMatrix kernelMatrix=\"1 1 1 1 1 1 1 1 1\" targetX=\"3\"/>",
        "<feConvolveMatrix kernelMatrix=\"1 1 1 1 1 1 1 1 1\" edgeMode=\"mirror\"/>",
        "<feConvolveMatrix kernelMatrix=\"1 1 1 1 1 1 1 1 1\" preserveAlpha=\"yes\"/>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadConvolveMatrix, readTest(src));
    }
}

test "a displacement map's channels default to alpha, and its scale to nothing" {
    var f = try primitivesOf("<feDisplacementMap/>" ++
        "<feDisplacementMap in2=\"SourceGraphic\" scale=\"-2.5\" xChannelSelector=\"R\" yChannelSelector=\"B\"/>");
    defer f.deinit(testing.allocator);
    const a = f.primitives[0].kind.displacement_map;
    try testing.expectEqual(@as(u2, 3), a.x_channel);
    try testing.expectEqual(@as(f64, 0), a.scale);
    const b = f.primitives[1].kind.displacement_map;
    try testing.expectEqual(@as(u2, 0), b.x_channel);
    try testing.expectEqual(@as(u2, 2), b.y_channel);
    try testing.expectEqual(@as(f64, -2.5), b.scale);
    for ([_][]const u8{
        "<feDisplacementMap xChannelSelector=\"r\"/>",
        "<feDisplacementMap yChannelSelector=\"RG\"/>",
        "<feDisplacementMap scale=\"large\"/>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadDisplacementMap, readTest(src));
    }
}

test "turbulence defaults to one octave of turbulence at no frequency" {
    var f = try primitivesOf("<feTurbulence/>" ++
        "<feTurbulence type=\"fractalNoise\" baseFrequency=\"0.1, 0.2\" numOctaves=\"99\" seed=\"-2.9\" stitchTiles=\"stitch\"/>");
    defer f.deinit(testing.allocator);
    const a = f.primitives[0].kind.turbulence;
    try testing.expectEqual(Turbulence{}, a);
    const b = f.primitives[1].kind.turbulence;
    try testing.expect(b.fractal_noise and b.stitch);
    try testing.expectEqual(@as(f64, 0.2), b.base_frequency_y);
    try testing.expectEqual(@as(u32, Turbulence.max_octaves), b.octaves);
    // Truncated towards zero.
    try testing.expectEqual(@as(i32, -2), b.seed);
    for ([_][]const u8{
        "<feTurbulence baseFrequency=\"-0.1\"/>",
        "<feTurbulence numOctaves=\"1.5\"/>",
        "<feTurbulence numOctaves=\"-1\"/>",
        "<feTurbulence type=\"perlin\"/>",
        "<feTurbulence stitchTiles=\"yes\"/>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadTurbulence, readTest(src));
    }
}

test "a lighting primitive reads its first light source and defaults the rest" {
    var f = try primitivesOf("<feDiffuseLighting><feDistantLight azimuth=\"45\"/><fePointLight/></feDiffuseLighting>" ++
        "<feSpecularLighting specularExponent=\"20\" specularConstant=\"0.5\" lighting-color=\"currentColor\"><desc/><feSpotLight x=\"1\" pointsAtZ=\"-2\" limitingConeAngle=\"30\" specularExponent=\"0\"/></feSpecularLighting>");
    defer f.deinit(testing.allocator);
    const d = f.primitives[0].kind.lighting;
    try testing.expect(!d.specular);
    try testing.expectEqual(@as(f64, 1), d.surface_scale);
    try testing.expectEqual(@as(f64, 45), d.light.distant.azimuth);
    try testing.expectEqual(@as(u8, 255), d.color.?.g);
    const s = f.primitives[1].kind.lighting;
    try testing.expect(s.specular);
    try testing.expectEqual(@as(f64, 20), s.exponent);
    try testing.expectEqual(@as(?color.Color, null), s.color);
    try testing.expectEqual([3]f64{ 1, 0, 0 }, s.light.spot.at);
    try testing.expectEqual(@as(f64, -2), s.light.spot.points_at[2]);
    try testing.expectEqual(@as(?f64, 30), s.light.spot.cone);
    // A spot light's exponent of nothing is taken as one.
    try testing.expectEqual(@as(f64, 1), s.light.spot.exponent);

    for ([_][]const u8{
        "<feDiffuseLighting/>",
        "<feDiffuseLighting diffuseConstant=\"-1\"><feDistantLight/></feDiffuseLighting>",
        "<feSpecularLighting specularExponent=\"200\"><feDistantLight/></feSpecularLighting>",
        "<feSpecularLighting><fePointLight z=\"high\"/></feSpecularLighting>",
    }) |body| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 8 8\"><filter id=\"f\">{s}</filter><rect width=\"8\" height=\"8\"/></svg>", .{body});
        try testing.expectError(error.BadLighting, readTest(src));
    }
}

test "a drop shadow has its own defaults" {
    var f = try primitivesOf("<feDropShadow/>" ++
        "<feDropShadow dx=\"-1\" dy=\"0\" stdDeviation=\"3 0\" flood-color=\"currentColor\" flood-opacity=\"0.5\"/>");
    defer f.deinit(testing.allocator);
    const a = f.primitives[0].kind.drop_shadow;
    try testing.expectEqual(@as(f64, 2), a.dx);
    try testing.expectEqual(@as(f64, 2), a.std_dev_y);
    try testing.expectEqual(@as(u8, 0), a.color.?.r);
    try testing.expectEqual(@as(f64, 1), a.opacity);
    const b = f.primitives[1].kind.drop_shadow;
    try testing.expectEqual(@as(f64, -1), b.dx);
    try testing.expectEqual(@as(f64, 0), b.dy);
    try testing.expectEqual(@as(f64, 0), b.std_dev_y);
    try testing.expectEqual(@as(?color.Color, null), b.color);
    try testing.expectEqual(@as(f64, 0.5), b.opacity);
    try testing.expectError(error.BadStdDeviation, primitivesOf("<feDropShadow stdDeviation=\"-2\"/>"));
}

test "an feImage reads its href, fitting and sampling" {
    // Read with the document kept alive: the href is borrowed from its tree.
    var doc = try document.read(testing.allocator, "<svg viewBox=\"0 0 8 8\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><filter id=\"f\"><feImage/>" ++
        "<feImage xlink:href=\" #a \" preserveAspectRatio=\"xMinYMax slice\" image-rendering=\"optimizeSpeed\"/>" ++
        "</filter><rect width=\"8\" height=\"8\"/></svg>");
    defer doc.deinit();
    var f = (try read(testing.allocator, doc.tree, &doc.ids, &doc.stylesheet, doc.ids.get("f").?, doc.viewport())).?;
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), f.primitives[0].kind.image.href);
    const b = f.primitives[1].kind.image;
    try testing.expectEqualStrings("#a", b.href.?);
    try testing.expect(b.preserve_aspect_ratio.slice);
    try testing.expectEqual(resample.Sampling.nearest, b.sampling);
}
