// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `<linearGradient>` and `<radialGradient>`, as something z2d can paint with.
//!
//! A gradient is named the way a `<use>` names its target -- `fill="url(#g)"`
//! -- so the tree that made `<use>` possible makes this possible too, and the
//! id index is already there.
//!
//! ## The coordinate systems
//!
//! A gradient's numbers are in a space of their own, and three things stack up
//! to say where that space is:
//!
//! ```text
//!   device  ←  ctm  ←  units mapping  ←  gradientTransform  ←  the numbers
//! ```
//!
//! `gradientUnits="userSpaceOnUse"` makes the units mapping the identity: the
//! numbers are in the user space in force where the gradient is *used*, not
//! where it is written. `objectBoundingBox`, which is the default, makes them
//! fractions of the bounding box of the shape being painted -- so `x1="0"
//! x2="1"` runs across it whatever size it is. That mapping is a translate to
//! the box's corner and a scale by its extent, and it is why a gradient on a
//! wide shape comes out stretched: the space itself is stretched, and a
//! `gradientTransform` inside it is stretched with it.
//!
//! z2d wants the whole stack as one matrix and inverts it to turn a device
//! pixel back into an offset, so the numbers stay exactly as the document
//! wrote them.
//!
//! ## `spreadMethod` is `pad`, and the other two are refused
//! z2d has no
//! extend mode -- there is a `TODO` where one would go -- so `reflect` and
//! `repeat` cannot be drawn rather than merely being unimplemented here. They
//! are visibly different pictures, so drawing `pad` instead would be a wrong
//! picture that looks deliberate.

const std = @import("std");
const testing = std.testing;

const ztree = @import("ztree");
const z2d = @import("z2d");

const color = @import("color.zig");
const length = @import("length.zig");
const transform = @import("transform.zig");

pub const Error = error{
    /// A `spreadMethod` of `reflect` or `repeat`, which z2d cannot draw, or
    /// one that is not a spread method at all.
    UnsupportedSpreadMethod,
    /// A `gradientUnits` that is neither `userSpaceOnUse` nor
    /// `objectBoundingBox`.
    BadGradientUnits,
    /// More `<stop>` elements than `max_stops`.
    TooManyStops,
    /// A `<stop>` whose `offset` is not a number or a percentage.
    BadStopOffset,
    /// A chain of gradients each inheriting from the next, longer than
    /// `max_href_hops`.
    TooManyGradientHops,
} || color.Error || length.Error || transform.Error;

/// The most `<stop>` elements one gradient may have.
///
/// Held in the gradient by value rather than allocated, so it needs a ceiling;
/// and a gradient with more colour stops than this has more than any eye can
/// separate. z2d takes the same buffer, so nothing is copied again on the way
/// out.
pub const max_stops = 64;

/// How many gradients may inherit from one another in a row.
pub const max_href_hops = 16;

/// Which space a gradient's numbers are in.
pub const Units = enum {
    /// The user space in force where the gradient is used.
    user_space,
    /// Fractions of the bounding box of the shape being painted. The default.
    object_bounding_box,
};

/// One colour stop, with its alpha already folded in from `stop-opacity`.
pub const Stop = struct {
    offset: f64,
    value: color.Color,
};

pub const Kind = union(enum) {
    /// §13.2.2's defaults: a line across the object, left to right.
    linear: struct {
        x1: f64 = 0,
        y1: f64 = 0,
        x2: f64 = 1,
        y2: f64 = 0,
    },
    /// §13.2.3's defaults: a circle filling the object, lit from its centre.
    /// `fx` and `fy` default to `cx` and `cy`, which is what makes the focal
    /// point optional.
    radial: struct {
        cx: f64 = 0.5,
        cy: f64 = 0.5,
        r: f64 = 0.5,
        fx: ?f64 = null,
        fy: ?f64 = null,
    },
};

/// A gradient, read and ready to be turned into a z2d pattern.
pub const Gradient = struct {
    kind: Kind,
    units: Units = .object_bounding_box,
    /// `gradientTransform`, which applies inside the units mapping.
    transform: z2d.Transformation = .identity,
    stops: [max_stops]Stop = undefined,
    stop_count: usize = 0,

    pub fn slice(self: *const Gradient) []const Stop {
        return self.stops[0..self.stop_count];
    }
};

/// Read the gradient a node defines, or null when the node is not one.
///
/// `ids` resolves an `href` to the gradient it inherits from -- §13.2.4 lets a
/// gradient take its stops and its attributes from another, which is how a
/// document defines one palette and four geometries over it.
pub fn read(
    tree: *const ztree.Document,
    ids: *const std.StringHashMapUnmanaged(ztree.NodeId),
    node: ztree.NodeId,
    viewport: length.Viewport,
    current_color: color.Color,
) Error!?Gradient {
    const name = tree.node(node).name.local;
    const is_linear = std.mem.eql(u8, name, "linearGradient");
    const is_radial = std.mem.eql(u8, name, "radialGradient");
    if (!is_linear and !is_radial) return null;

    var result: Gradient = .{ .kind = if (is_linear) .{ .linear = .{} } else .{ .radial = .{} } };

    // §13.2.4: walk the inheritance chain from the far end back, so that each
    // gradient in turn overrides what it inherited. The chain is bounded, and
    // a cycle simply runs the budget out -- there is nothing to draw either
    // way, and unlike `<use>` a loop here costs one pass rather than a tree.
    var chain: [max_href_hops]ztree.NodeId = undefined;
    var links: usize = 0;
    var walk = node;
    while (true) {
        if (links == max_href_hops) return error.TooManyGradientHops;
        chain[links] = walk;
        links += 1;
        const next = inheritsFrom(tree, ids, walk) orelse break;
        // A gradient already in the chain is a cycle; stop rather than loop.
        var seen = false;
        for (chain[0..links]) |c| {
            if (c == next) seen = true;
        }
        if (seen) break;
        walk = next;
    }

    var i = links;
    while (i > 0) {
        i -= 1;
        try applyOne(tree, chain[i], viewport, current_color, &result);
    }
    return result;
}

/// The gradient this one takes its unnamed attributes and its stops from.
fn inheritsFrom(
    tree: *const ztree.Document,
    ids: *const std.StringHashMapUnmanaged(ztree.NodeId),
    node: ztree.NodeId,
) ?ztree.NodeId {
    const raw = tree.attributeValue(node, "", "href") orelse
        tree.attributeValue(node, xlink_ns, "href") orelse
        return null;
    const target = std.mem.trim(u8, raw, " \t\r\n");
    if (target.len < 2 or target[0] != '#') return null;
    return ids.get(target[1..]);
}

const xlink_ns = "http://www.w3.org/1999/xlink";

/// Lay one gradient of the chain over what has been gathered so far.
fn applyOne(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    viewport: length.Viewport,
    current_color: color.Color,
    out: *Gradient,
) Error!void {
    if (tree.attributeValue(node, "", "gradientUnits")) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, t, "userSpaceOnUse")) {
            out.units = .user_space;
        } else if (std.mem.eql(u8, t, "objectBoundingBox")) {
            out.units = .object_bounding_box;
        } else {
            return error.BadGradientUnits;
        }
    }
    if (tree.attributeValue(node, "", "gradientTransform")) |raw| {
        out.transform = try transform.parse(raw);
    }
    if (tree.attributeValue(node, "", "spreadMethod")) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        // `pad` is the initial value and the only one z2d can draw.
        if (!std.mem.eql(u8, t, "pad")) return error.UnsupportedSpreadMethod;
    }

    // A gradient's own coordinates only apply to its own kind: a
    // `<radialGradient>` inheriting from a `<linearGradient>` takes its stops
    // and nothing geometric, which is what §13.2.4 says.
    switch (out.kind) {
        .linear => |*l| {
            if (try coord(tree, node, "x1", .x, viewport)) |v| l.x1 = v;
            if (try coord(tree, node, "y1", .y, viewport)) |v| l.y1 = v;
            if (try coord(tree, node, "x2", .x, viewport)) |v| l.x2 = v;
            if (try coord(tree, node, "y2", .y, viewport)) |v| l.y2 = v;
        },
        .radial => |*r| {
            if (try coord(tree, node, "cx", .x, viewport)) |v| r.cx = v;
            if (try coord(tree, node, "cy", .y, viewport)) |v| r.cy = v;
            if (try coord(tree, node, "r", .other, viewport)) |v| r.r = v;
            if (try coord(tree, node, "fx", .x, viewport)) |v| r.fx = v;
            if (try coord(tree, node, "fy", .y, viewport)) |v| r.fy = v;
        },
    }

    // Stops replace rather than merge: a gradient that has any of its own uses
    // only those, and one with none keeps what it inherited.
    var found: usize = 0;
    var highest: f64 = 0;
    for (tree.node(node).children.items) |child| {
        if (tree.node(child).kind != .element) continue;
        if (!std.mem.eql(u8, tree.node(child).name.local, "stop")) continue;
        if (found == max_stops) return error.TooManyStops;

        const raw = tree.attributeValue(child, "", "offset") orelse "0";
        var offset = try parseOffset(raw);
        // §13.2.4: each offset is at least the one before it, and any that is
        // not is raised to match. An unsorted list is a step rather than a
        // reversal, which is what resvg draws too.
        offset = std.math.clamp(offset, 0.0, 1.0);
        offset = @max(offset, highest);
        highest = offset;

        var value: color.Color = if (tree.attributeValue(child, "", "stop-color")) |c|
            switch (try color.parsePaint(c)) {
                .color => |named| named,
                // `currentColor` here is the `color` in force, like anywhere
                // else. `none` is not a colour and a `url(...)` is not one
                // either -- §13.2.4 has no use for a stop that is a paint
                // server -- so both fall back to the initial black.
                .current => current_color,
                .none, .reference => color.Color.black,
            }
        else
            color.Color.black;
        if (tree.attributeValue(child, "", "stop-opacity")) |o| {
            value.alpha *= try color.parseOpacity(o);
        }

        out.stops[found] = .{ .offset = offset, .value = value };
        found += 1;
    }
    if (found != 0) out.stop_count = found;
}

fn coord(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    name: []const u8,
    axis: length.Axis,
    viewport: length.Viewport,
) Error!?f64 {
    const raw = tree.attributeValue(node, "", name) orelse return null;
    return try length.parse(raw, axis, viewport);
}

/// A `<stop>`'s `offset`: a number or a percentage, clamped to 0..1.
///
/// Not a length -- there is no viewport involved and `50%` means half of the
/// gradient rather than half of anything on the page -- so it is read here
/// rather than through `length.parse`.
fn parseOffset(raw: []const u8) Error!f64 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return error.BadStopOffset;
    const value = if (std.mem.endsWith(u8, t, "%")) pct: {
        const p = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch return error.BadStopOffset;
        break :pct p / 100.0;
    } else std.fmt.parseFloat(f64, t) catch return error.BadStopOffset;
    if (std.math.isNan(value)) return error.BadStopOffset;
    return std.math.clamp(value, 0.0, 1.0);
}

// -- tests -------------------------------------------------------------------

const Read = struct {
    doc: *ztree.Document,
    ids: std.StringHashMapUnmanaged(ztree.NodeId),

    fn deinit(self: *Read) void {
        self.doc.destroy();
    }
};

/// Parse a document and index its ids, so a test can ask for one gradient.
fn readDoc(gpa: std.mem.Allocator, src: []const u8) !Read {
    const doc = try ztree.parse(gpa, src, .{ .entities = .strict });
    errdefer doc.destroy();
    var ids: std.StringHashMapUnmanaged(ztree.NodeId) = .empty;
    for (doc.nodes.items, 0..) |node, id| {
        if (node.kind != .element) continue;
        const value = doc.attributeValue(@intCast(id), "", "id") orelse continue;
        const slot = try ids.getOrPut(doc.alloc(), value);
        if (!slot.found_existing) slot.value_ptr.* = @intCast(id);
    }
    return .{ .doc = doc, .ids = ids };
}

fn gradientNamed(r: *Read, id: []const u8) !Gradient {
    const node = r.ids.get(id).?;
    return (try read(r.doc, &r.ids, node, .{ .width = 100, .height = 100 }, .black)).?;
}

test "a linear gradient runs left to right unless told otherwise" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg><linearGradient id=\"g\">" ++
        "<stop offset=\"0\" stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/>" ++
        "</linearGradient></svg>");
    defer r.deinit();

    const g = try gradientNamed(&r, "g");
    try testing.expectEqual(Units.object_bounding_box, g.units);
    try testing.expectEqual(@as(f64, 0), g.kind.linear.x1);
    try testing.expectEqual(@as(f64, 1), g.kind.linear.x2);
    try testing.expectEqual(@as(f64, 0), g.kind.linear.y1);
    try testing.expectEqual(@as(f64, 0), g.kind.linear.y2);
    try testing.expectEqual(@as(usize, 2), g.stop_count);
    try testing.expectEqual(@as(u8, 255), g.slice()[0].value.r);
    try testing.expectEqual(@as(u8, 255), g.slice()[1].value.b);
}

test "a radial gradient fills the object and takes its focus from its centre" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg><radialGradient id=\"g\"><stop offset=\"0\"/></radialGradient>" ++
        "<radialGradient id=\"f\" fx=\"0.25\"><stop offset=\"0\"/></radialGradient></svg>");
    defer r.deinit();

    const plain = try gradientNamed(&r, "g");
    try testing.expectEqual(@as(f64, 0.5), plain.kind.radial.cx);
    try testing.expectEqual(@as(f64, 0.5), plain.kind.radial.r);
    // Null, so that the renderer can fall back to `cx` -- which is what makes
    // the focal point optional rather than zero.
    try testing.expectEqual(@as(?f64, null), plain.kind.radial.fx);

    const focal = try gradientNamed(&r, "f");
    try testing.expectEqual(@as(?f64, 0.25), focal.kind.radial.fx);
    try testing.expectEqual(@as(?f64, null), focal.kind.radial.fy);
}

test "stop offsets are clamped and never go backwards" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg><linearGradient id=\"g\">" ++
        "<stop offset=\"0.8\"/><stop offset=\"0.2\"/><stop offset=\"3\"/><stop offset=\"-1\"/>" ++
        "</linearGradient></svg>");
    defer r.deinit();

    const g = try gradientNamed(&r, "g");
    const stops = g.slice();
    try testing.expectEqual(@as(usize, 4), stops.len);
    // §13.2.4: an offset below the one before it is raised to match, so an
    // unsorted list is a step rather than a reversal.
    try testing.expectApproxEqAbs(@as(f64, 0.8), stops[0].offset, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.8), stops[1].offset, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), stops[2].offset, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), stops[3].offset, 1e-12);
}

test "a gradient takes what it does not name from the one it references" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg>" ++
        "<linearGradient id=\"base\" gradientUnits=\"userSpaceOnUse\" x1=\"4\" x2=\"9\">" ++
        "<stop offset=\"0\" stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/>" ++
        "</linearGradient>" ++
        "<linearGradient id=\"child\" href=\"#base\" x2=\"20\"/></svg>");
    defer r.deinit();

    const g = try gradientNamed(&r, "child");
    // Its own `x2` wins; everything else comes from the base, stops included.
    try testing.expectEqual(@as(f64, 20), g.kind.linear.x2);
    try testing.expectEqual(@as(f64, 4), g.kind.linear.x1);
    try testing.expectEqual(Units.user_space, g.units);
    try testing.expectEqual(@as(usize, 2), g.stop_count);
}

test "a cycle of references is stopped rather than followed" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg>" ++
        "<linearGradient id=\"a\" href=\"#b\"><stop offset=\"0\"/></linearGradient>" ++
        "<linearGradient id=\"b\" href=\"#a\"/></svg>");
    defer r.deinit();
    // Nothing to draw either way; what matters is that it comes back at all.
    const g = try gradientNamed(&r, "a");
    try testing.expectEqual(@as(usize, 1), g.stop_count);
}

test "stop-opacity multiplies into the stop's own alpha" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg><linearGradient id=\"g\">" ++
        "<stop offset=\"0\" stop-color=\"#ff000080\" stop-opacity=\"0.5\"/>" ++
        "</linearGradient></svg>");
    defer r.deinit();
    const g = try gradientNamed(&r, "g");
    try testing.expectApproxEqAbs(@as(f64, 0.25), g.slice()[0].value.alpha, 0.01);
}

test "a spread method z2d cannot draw is refused" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg>" ++
        "<linearGradient id=\"pad\" spreadMethod=\"pad\"><stop offset=\"0\"/></linearGradient>" ++
        "<linearGradient id=\"reflect\" spreadMethod=\"reflect\"><stop offset=\"0\"/></linearGradient>" ++
        "<linearGradient id=\"repeat\" spreadMethod=\"repeat\"><stop offset=\"0\"/></linearGradient>" ++
        "<linearGradient id=\"bogus\" spreadMethod=\"bogus\"><stop offset=\"0\"/></linearGradient>" ++
        "</svg>");
    defer r.deinit();

    _ = try gradientNamed(&r, "pad");
    for ([_][]const u8{ "reflect", "repeat", "bogus" }) |id| {
        try testing.expectError(error.UnsupportedSpreadMethod, gradientNamed(&r, id));
    }
}

test "a gradientUnits nobody defines is refused" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg><linearGradient id=\"g\" gradientUnits=\"bogus\">" ++
        "<stop offset=\"0\"/></linearGradient></svg>");
    defer r.deinit();
    try testing.expectError(error.BadGradientUnits, gradientNamed(&r, "g"));
}

test "an element that is not a gradient is not read as one" {
    const gpa = testing.allocator;
    var r = try readDoc(gpa, "<svg><pattern id=\"p\"/><rect id=\"r\"/></svg>");
    defer r.deinit();
    for ([_][]const u8{ "p", "r" }) |id| {
        const node = r.ids.get(id).?;
        try testing.expectEqual(
            @as(?Gradient, null),
            try read(r.doc, &r.ids, node, .{ .width = 10, .height = 10 }, .black),
        );
    }
}
