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
const document = @import("document.zig");
const length = @import("length.zig");
const style = @import("style.zig");

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

    pub fn deinit(self: *Filter, gpa: Allocator) void {
        gpa.free(self.primitives);
        gpa.free(self.merge_nodes);
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
    var i = links;
    while (i > 0) {
        i -= 1;
        try applyAttributes(tree, chain[i], viewport, &result);
    }

    // The primitives, nearest end first so the first filter in the chain that
    // has any is the one they come from.
    for (chain[0..links]) |n| {
        if (hasPrimitive(tree, n)) {
            try readPrimitives(gpa, tree, n, viewport, &result);
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

fn applyAttributes(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    viewport: length.Viewport,
    out: *Filter,
) Error!void {
    if (try unitsOf(tree, node, "filterUnits")) |u| out.units = u;
    if (try unitsOf(tree, node, "primitiveUnits")) |u| out.primitive_units = u;
    if (try coord(tree, node, "x", .x, out.units, viewport)) |v| out.x = v;
    if (try coord(tree, node, "y", .y, out.units, viewport)) |v| out.y = v;
    if (try coord(tree, node, "width", .x, out.units, viewport)) |v| out.width = v;
    if (try coord(tree, node, "height", .y, out.units, viewport)) |v| out.height = v;
}

fn readPrimitives(
    gpa: Allocator,
    tree: *const ztree.Document,
    node: ztree.NodeId,
    viewport: length.Viewport,
    out: *Filter,
) Error!void {
    // `color-interpolation-filters` is inherited, so what the `<filter>`
    // itself says is the default for every primitive in it.
    const inherited = try colorSpaceOf(tree, node) orelse ColorSpace.linear_rgb;

    var prims: std.ArrayList(Primitive) = .empty;
    defer prims.deinit(gpa);
    var merges: std.ArrayList(Input) = .empty;
    defer merges.deinit(gpa);

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
                .color = try floodColor(tree, child),
                .opacity = if (presentation(tree, child, "flood-opacity")) |raw|
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
        } else return error.UnsupportedFilterPrimitive;

        try prims.append(gpa, .{
            .kind = kind,
            .result = trimmedAttr(tree, child, "result"),
            .color_space = try colorSpaceOf(tree, child) orelse inherited,
            .x = try coord(tree, child, "x", .x, out.primitive_units, viewport),
            .y = try coord(tree, child, "y", .y, out.primitive_units, viewport),
            .width = try coord(tree, child, "width", .x, out.primitive_units, viewport),
            .height = try coord(tree, child, "height", .y, out.primitive_units, viewport),
        });
    }

    out.primitives = try prims.toOwnedSlice(gpa);
    out.merge_nodes = try merges.toOwnedSlice(gpa);
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

fn floodColor(tree: *const ztree.Document, node: ztree.NodeId) Error!?color.Color {
    const raw = presentation(tree, node, "flood-color") orelse return color.Color.black;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    // Resolved against the filtered element rather than against the filter,
    // which has no colour of its own.
    if (std.mem.eql(u8, t, "currentColor")) return null;
    return try color.parseColor(t);
}

fn colorSpaceOf(tree: *const ztree.Document, node: ztree.NodeId) Error!?ColorSpace {
    const raw = presentation(tree, node, "color-interpolation-filters") orelse return null;
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

/// A presentation property: the `style` block first, then the attribute, which
/// is §6.3's order and the same one `document.zig` applies to every other
/// element.
fn presentation(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    name: []const u8,
) ?[]const u8 {
    if (tree.attributeValue(node, "", "style")) |block| {
        if (style.property(block, name)) |value| return value;
    }
    return tree.attributeValue(node, "", name);
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
