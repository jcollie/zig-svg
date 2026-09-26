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
} || color.Error || length.Error || document.Error || Allocator.Error;

/// The most `href` links to follow before giving up.
pub const max_href_hops = 16;

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
