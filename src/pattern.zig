// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `<pattern>`: SVG 1.1 §13.3.
//!
//! A pattern is a picture drawn once and then repeated across whatever it
//! paints, on a lattice the document describes. This module reads the element;
//! `raster.zig` draws it, because drawing one needs a surface and this file
//! deliberately has none.
//!
//! ## The coordinate systems
//!
//! Three of them, and getting them the wrong way round is the whole difficulty
//! of the element.
//!
//! `patternUnits` says where the *tile* is -- its `x`, `y`, `width` and
//! `height`. It defaults to `objectBoundingBox`, so a `width` of `0.25` means
//! a quarter of the painted shape rather than a quarter of a user unit.
//!
//! `patternContentUnits` says where the tile's *contents* are. It defaults to
//! `userSpaceOnUse`, which is the opposite default to the one above -- so by
//! default the tile is a fraction of the shape and the things inside it are in
//! user units. A document that sets one usually wants to set the other.
//!
//! `viewBox` replaces `patternContentUnits` outright when it is present: the
//! contents are then in the viewBox's own space, fitted into the tile by
//! `preserveAspectRatio` exactly as the root `<svg>` is fitted into its
//! viewport. §13.3 says the content units are ignored in that case, and they
//! are ignored here.
//!
//! ## What the tile clips
//!
//! `overflow` on a `<pattern>` is `hidden`, so content that runs past the
//! tile's edge is cut off rather than showing up in the neighbour. That is not
//! a detail: a pattern of overlapping circles looks completely different if it
//! is not honoured, and resvg honours it. The renderer therefore has to clip
//! every tile it draws, which is why it draws them one at a time rather than
//! drawing one and stamping it.

const std = @import("std");
const testing = std.testing;

const ztree = @import("ztree");
const z2d = @import("z2d");

const document = @import("document.zig");
const length = @import("length.zig");
const transform = @import("transform.zig");

pub const Error = error{
    /// A `patternUnits` or `patternContentUnits` that is neither
    /// `userSpaceOnUse` nor `objectBoundingBox`.
    BadPatternUnits,
    /// A chain of `href` longer than `max_href_hops`.
    TooManyPatternHops,
} || transform.Error || length.Error || document.Error;

/// The most `href` links to follow before giving up.
pub const max_href_hops = 16;

/// Which coordinate system a `patternUnits` or `patternContentUnits` names.
pub const Units = enum {
    /// The user space in force on the shape being painted.
    user_space,
    /// Fractions of that shape's §7.11 bounding box.
    object_bounding_box,
};

/// A `<pattern>`, read but not drawn.
pub const Pattern = struct {
    /// The element the content is taken from. This is the *last* node of the
    /// href chain that had children, which is §13.3's rule: a pattern with no
    /// content of its own borrows the content of the one it references.
    content: ?ztree.NodeId = null,
    /// Where the tile is.
    units: Units = .object_bounding_box,
    /// Where the tile's contents are. Ignored when `view_box` is set.
    content_units: Units = .user_space,
    /// The tile, in whichever units `units` names.
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    /// `patternTransform`, which applies outside the units mapping.
    transform: z2d.Transformation = .identity,
    /// A `viewBox` on the pattern, which replaces `content_units`.
    view_box: ?document.ViewBox = null,
    preserve_aspect_ratio: document.PreserveAspectRatio = .meet_centred,

    /// Whether the pattern has a tile with any extent. §13.3 makes a zero
    /// `width` or `height` disable the element, which paints nothing.
    pub fn isDrawable(self: Pattern) bool {
        return self.content != null and self.width > 0 and self.height > 0;
    }
};

/// Read the pattern a node defines, or null when the node is not one.
///
/// §13.3 lets a pattern take its attributes and its content from another
/// through `href`, the same way §13.2.4 lets a gradient take its stops. The
/// chain is walked from the far end back, so each pattern in turn overrides
/// what it inherited.
pub fn read(
    tree: *const ztree.Document,
    ids: *const std.StringHashMapUnmanaged(ztree.NodeId),
    node: ztree.NodeId,
    viewport: length.Viewport,
) Error!?Pattern {
    if (!std.mem.eql(u8, tree.node(node).name.local, "pattern")) return null;

    var chain: [max_href_hops]ztree.NodeId = undefined;
    var links: usize = 0;
    var walk = node;
    while (true) {
        if (links == max_href_hops) return error.TooManyPatternHops;
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

    var result: Pattern = .{};
    var i = links;
    while (i > 0) {
        i -= 1;
        try applyOne(tree, chain[i], viewport, &result);
    }
    return result;
}

/// The pattern this one takes its unnamed attributes and its content from.
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
    // Only another `<pattern>` is inherited from; anything else is not one of
    // these and has nothing to contribute.
    if (!std.mem.eql(u8, tree.node(next).name.local, "pattern")) return null;
    return next;
}

/// Lay one pattern of the chain over what has been gathered so far.
fn applyOne(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    viewport: length.Viewport,
    out: *Pattern,
) Error!void {
    if (try unitsOf(tree, node, "patternUnits")) |u| out.units = u;
    if (try unitsOf(tree, node, "patternContentUnits")) |u| out.content_units = u;

    if (tree.attributeValue(node, "", "patternTransform")) |raw| {
        out.transform = try transform.parse(raw);
    }
    if (tree.attributeValue(node, "", "viewBox")) |raw| {
        out.view_box = try document.parseViewBox(raw);
    }
    if (tree.attributeValue(node, "", "preserveAspectRatio")) |raw| {
        out.preserve_aspect_ratio = try document.PreserveAspectRatio.parse(raw);
    }

    // In bounding-box units these are plain fractions, so there is no viewport
    // in them; in user space they are lengths like any other.
    if (try coord(tree, node, "x", .x, out.units, viewport)) |v| out.x = v;
    if (try coord(tree, node, "y", .y, out.units, viewport)) |v| out.y = v;
    if (try coord(tree, node, "width", .x, out.units, viewport)) |v| out.width = v;
    if (try coord(tree, node, "height", .y, out.units, viewport)) |v| out.height = v;

    // §13.3: a pattern with children of its own uses them; one without
    // borrows the content of whatever it references. Walking the chain from
    // the far end back means the nearest one with content wins.
    if (hasElementChild(tree, node)) out.content = node;
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
    return error.BadPatternUnits;
}

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

fn hasElementChild(tree: *const ztree.Document, node: ztree.NodeId) bool {
    for (tree.node(node).children.items) |child| {
        if (tree.node(child).kind == .element) return true;
    }
    return false;
}

// -- tests -------------------------------------------------------------------

const Read = struct {
    doc: document.Document,
    fn deinit(self: *Read) void {
        self.doc.deinit();
    }
};

fn readDoc(gpa: std.mem.Allocator, src: []const u8) !Read {
    return .{ .doc = try document.read(gpa, src) };
}

fn patternNamed(r: *Read, id: []const u8) !Pattern {
    const node = r.doc.ids.get(id).?;
    return (try read(r.doc.tree, &r.doc.ids, node, r.doc.viewport())).?;
}

test "the two unit attributes default to opposite systems" {
    // Which is §13.3's doing, not a mistake here: the tile is a fraction of
    // the shape and the things inside it are in user units, so a document that
    // sets one usually means to set the other.
    var r = try readDoc(testing.allocator, "<svg viewBox=\"0 0 8 8\"><defs><pattern id=\"p\" width=\"0.5\" height=\"0.5\">" ++
        "<rect width=\"1\" height=\"1\"/></pattern></defs><rect width=\"8\" height=\"8\"/></svg>");
    defer r.deinit();
    const p = try patternNamed(&r, "p");
    try testing.expectEqual(Units.object_bounding_box, p.units);
    try testing.expectEqual(Units.user_space, p.content_units);
    try testing.expectEqual(@as(f64, 0.5), p.width);
}

test "a pattern takes what it does not say from the one it references" {
    var r = try readDoc(testing.allocator, "<svg viewBox=\"0 0 8 8\"><defs>" ++
        "<pattern id=\"base\" width=\"4\" height=\"6\" patternUnits=\"userSpaceOnUse\">" ++
        "<rect width=\"2\" height=\"2\"/></pattern>" ++
        "<pattern id=\"derived\" href=\"#base\" width=\"9\"/>" ++
        "</defs><rect width=\"8\" height=\"8\"/></svg>");
    defer r.deinit();
    const p = try patternNamed(&r, "derived");
    // Its own `width` wins; the height, the units and -- because it has no
    // children of its own -- the content all come from the base.
    try testing.expectEqual(@as(f64, 9), p.width);
    try testing.expectEqual(@as(f64, 6), p.height);
    try testing.expectEqual(Units.user_space, p.units);
    try testing.expectEqual(r.doc.ids.get("base").?, p.content.?);
    try testing.expect(p.isDrawable());
}

test "a pattern with content of its own keeps it" {
    var r = try readDoc(testing.allocator, "<svg viewBox=\"0 0 8 8\"><defs>" ++
        "<pattern id=\"base\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\">" ++
        "<rect width=\"2\" height=\"2\"/></pattern>" ++
        "<pattern id=\"derived\" href=\"#base\"><circle r=\"1\"/></pattern>" ++
        "</defs><rect width=\"8\" height=\"8\"/></svg>");
    defer r.deinit();
    const p = try patternNamed(&r, "derived");
    try testing.expectEqual(r.doc.ids.get("derived").?, p.content.?);
}

test "a pattern with no tile or no content draws nothing" {
    var r = try readDoc(testing.allocator, "<svg viewBox=\"0 0 8 8\"><defs>" ++
        "<pattern id=\"flat\" width=\"0\" height=\"4\" patternUnits=\"userSpaceOnUse\">" ++
        "<rect width=\"2\" height=\"2\"/></pattern>" ++
        "<pattern id=\"empty\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"/>" ++
        "<pattern id=\"unsized\"><rect width=\"2\" height=\"2\"/></pattern>" ++
        "</defs><rect width=\"8\" height=\"8\"/></svg>");
    defer r.deinit();
    for ([_][]const u8{ "flat", "empty", "unsized" }) |id| {
        try testing.expect(!(try patternNamed(&r, id)).isDrawable());
    }
}

test "a cycle of references runs out rather than looping" {
    var r = try readDoc(testing.allocator, "<svg viewBox=\"0 0 8 8\"><defs>" ++
        "<pattern id=\"a\" href=\"#b\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"/>" ++
        "<pattern id=\"b\" href=\"#a\"><rect width=\"2\" height=\"2\"/></pattern>" ++
        "</defs><rect width=\"8\" height=\"8\"/></svg>");
    defer r.deinit();
    const p = try patternNamed(&r, "a");
    try testing.expectEqual(@as(f64, 4), p.width);
    try testing.expectEqual(r.doc.ids.get("b").?, p.content.?);
}

test "a units value that is neither of the two is refused" {
    var r = try readDoc(testing.allocator, "<svg viewBox=\"0 0 8 8\"><defs>" ++
        "<pattern id=\"p\" patternUnits=\"someOtherWay\" width=\"4\" height=\"4\">" ++
        "<rect width=\"2\" height=\"2\"/></pattern></defs><rect width=\"8\" height=\"8\"/></svg>");
    defer r.deinit();
    try testing.expectError(error.BadPatternUnits, patternNamed(&r, "p"));
}
