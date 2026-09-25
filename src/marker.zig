// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Where a path's markers go, and which way each one faces: SVG 1.1 §11.6.
//!
//! A marker sits at a *vertex* -- the start of the path, the end of every
//! segment the document wrote -- and `orient="auto"` turns it to the path's
//! direction there. This works that out from a built path: the nodes, and
//! where each of the document's commands ended among them, since an arc
//! comes out as several cubics and the joins between them are not vertices.
//!
//! Nothing here reads a `<marker>` or draws anything. It is geometry, so that
//! it can be tested on paths without a document in sight.
//!
//! ## The direction at a vertex
//!
//! A segment has a direction where it leaves its start and where it arrives
//! at its end: a line's own, and for a cubic the tangent, which is towards
//! its first control point that is not where it starts, and from its last
//! that is not where it ends. At a vertex between two segments the marker
//! faces the bisector of the one arriving and the one leaving; at the start
//! of the path it faces the first segment's way out, and at the end the last
//! one's way in.
//!
//! A closed subpath has no ends, so its first vertex -- and the one `Z`
//! returns to, which is the same point -- faces the bisector of the closing
//! segment and the first. A segment of zero length has no direction, and
//! takes the one arriving at its start, or failing that the next one out.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const PathNode = std.meta.Elem(@FieldType(z2d.Path, "nodes").Slice);

/// One place a marker goes.
pub const Vertex = struct {
    x: f64,
    y: f64,
    /// The way the path runs here, in radians, for `orient="auto"`.
    angle: f64,
    /// The first vertex of the path, which `marker-start` goes on.
    start: bool,
    /// The last, which `marker-end` goes on. A path of one vertex has it
    /// both ways, and no middle.
    end: bool,
};

const Point = struct {
    x: f64,
    y: f64,

    fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    fn isZero(self: Point) bool {
        return self.x == 0 and self.y == 0;
    }
};

const Kind = enum { move, draw, close };

/// One of the document's commands, reduced to what a marker needs.
const Segment = struct {
    kind: Kind,
    /// Where it ends, which is the vertex it makes.
    end: Point,
    /// Its direction leaving its start and arriving at its end; zero when it
    /// has none, which a `move` never does and a zero-length line does not.
    out: Point = .{ .x = 0, .y = 0 },
    in: Point = .{ .x = 0, .y = 0 },
};

/// The markers' places along `nodes`, whose commands end at `ends` -- as
/// `path.Options.command_ends` records them. Appended to `out`.
pub fn vertices(gpa: Allocator, nodes: []const PathNode, ends: []const usize, out: *std.ArrayList(Vertex)) Allocator.Error!void {
    var segs: std.ArrayList(Segment) = .empty;
    defer segs.deinit(gpa);
    try segments(gpa, nodes, ends, &segs);
    const s = segs.items;
    if (s.len == 0) return;

    for (s, 0..) |seg, k| {
        // What arrives at this vertex and what leaves it. A `move` has
        // nothing arriving -- unless it begins a closed subpath, where the
        // closing segment arrives at the same point.
        var in = if (seg.kind == .move) closingInto(s, k) else seg.in;
        var leaves: ?usize = if (k + 1 < s.len and s[k + 1].kind != .move) k + 1 else null;
        // And a `Z` leaves by the subpath's first segment, unless the path
        // carries on from it with a segment of its own.
        if (leaves == null and seg.kind == .close) leaves = firstOfSubpath(s, k);
        var out_dir = if (leaves) |j| s[j].out else Point{ .x = 0, .y = 0 };

        // A segment of zero length has no direction of its own, and takes
        // the direction arriving at its start -- SVG 2 §9.5.1 -- or, first in
        // its subpath, the one leaving after it.
        if (in.isZero()) in = inBefore(s, k);
        if (out_dir.isZero() and leaves != null) out_dir = if (!in.isZero()) in else outAfter(s, leaves.?);

        const angle = if (!in.isZero() and !out_dir.isZero())
            bisect(in, out_dir)
        else if (!out_dir.isZero())
            math.atan2(out_dir.y, out_dir.x)
        else if (!in.isZero())
            math.atan2(in.y, in.x)
        else
            0;

        try out.append(gpa, .{
            .x = seg.end.x,
            .y = seg.end.y,
            .angle = angle,
            .start = k == 0,
            .end = k == s.len - 1,
        });
    }
}

/// The document's commands, from the nodes each one built.
fn segments(gpa: Allocator, nodes: []const PathNode, ends: []const usize, out: *std.ArrayList(Segment)) Allocator.Error!void {
    var begin: usize = 0;
    var cur: Point = .{ .x = 0, .y = 0 };
    var sub_start: Point = cur;
    for (ends) |end| {
        if (end <= begin or end > nodes.len) continue;
        const slice = nodes[begin..end];
        begin = end;
        switch (slice[0]) {
            .move_to => |m| {
                cur = .{ .x = m.point.x, .y = m.point.y };
                sub_start = cur;
                try out.append(gpa, .{ .kind = .move, .end = cur });
            },
            .close_path => {
                const dir = sub_start.sub(cur);
                try out.append(gpa, .{ .kind = .close, .end = sub_start, .out = dir, .in = dir });
                cur = sub_start;
            },
            .line_to, .curve_to => {
                var seg: Segment = .{ .kind = .draw, .end = cur };
                var prev = cur;
                for (slice, 0..) |node, i| {
                    switch (node) {
                        .line_to => |l| {
                            const p: Point = .{ .x = l.point.x, .y = l.point.y };
                            if (i == 0) seg.out = p.sub(prev);
                            seg.in = p.sub(prev);
                            prev = p;
                        },
                        .curve_to => |c| {
                            const p1: Point = .{ .x = c.p1.x, .y = c.p1.y };
                            const p2: Point = .{ .x = c.p2.x, .y = c.p2.y };
                            const p3: Point = .{ .x = c.p3.x, .y = c.p3.y };
                            if (i == 0) seg.out = firstNonZero(&.{ p1.sub(prev), p2.sub(prev), p3.sub(prev) });
                            seg.in = firstNonZero(&.{ p3.sub(p2), p3.sub(p1), p3.sub(prev) });
                            prev = p3;
                        },
                        else => {},
                    }
                }
                seg.end = prev;
                cur = prev;
                try out.append(gpa, seg);
            },
        }
    }
}

fn firstNonZero(candidates: []const Point) Point {
    for (candidates) |p| if (!p.isZero()) return p;
    return .{ .x = 0, .y = 0 };
}

/// The closing segment arriving at the `move` at `k`, when its subpath is
/// closed; nothing otherwise.
fn closingInto(s: []const Segment, k: usize) Point {
    var j = k + 1;
    while (j < s.len and s[j].kind != .move) : (j += 1) {
        if (s[j].kind == .close) return if (s[j].in.isZero()) inBefore(s, j) else s[j].in;
    }
    return .{ .x = 0, .y = 0 };
}

/// The first segment drawn in the subpath the `close` at `k` ends.
fn firstOfSubpath(s: []const Segment, k: usize) ?usize {
    var j = k;
    while (j > 0) {
        j -= 1;
        if (s[j].kind == .move) return if (j + 1 < k) j + 1 else null;
    }
    return null;
}

/// The nearest direction arriving at or before `k`.
fn inBefore(s: []const Segment, k: usize) Point {
    var j = k + 1;
    while (j > 0) {
        j -= 1;
        if (s[j].kind == .move) break;
        if (!s[j].in.isZero()) return s[j].in;
    }
    return .{ .x = 0, .y = 0 };
}

/// The nearest direction leaving at or after `k`.
fn outAfter(s: []const Segment, k: usize) Point {
    var j = k;
    while (j < s.len and s[j].kind != .move) : (j += 1) {
        if (!s[j].out.isZero()) return s[j].out;
    }
    return .{ .x = 0, .y = 0 };
}

/// The angle halfway between two directions, going the short way round.
fn bisect(in: Point, out: Point) f64 {
    const a = math.atan2(in.y, in.x);
    const b = math.atan2(out.y, out.x);
    var d = b - a;
    while (d > math.pi) d -= 2 * math.pi;
    while (d <= -math.pi) d += 2 * math.pi;
    return a + d / 2;
}

// -- tests -------------------------------------------------------------------

const path = @import("path.zig");

fn verticesOf(d: []const u8) !std.ArrayList(Vertex) {
    const gpa = testing.allocator;
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    try path.build(&p, gpa, d, .{ .close_subpaths = false, .command_ends = &ends });
    var out: std.ArrayList(Vertex) = .empty;
    try vertices(gpa, p.nodes.items, ends.items, &out);
    return out;
}

fn expectVertex(v: Vertex, x: f64, y: f64, degrees: f64) !void {
    try testing.expectApproxEqAbs(x, v.x, 1e-9);
    try testing.expectApproxEqAbs(y, v.y, 1e-9);
    try testing.expectApproxEqAbs(degrees, math.radiansToDegrees(v.angle), 1e-6);
}

test "an open path faces its ends outwards and bisects its corners" {
    var v = try verticesOf("M0 0 L10 0 L10 10");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), v.items.len);
    try expectVertex(v.items[0], 0, 0, 0);
    try testing.expect(v.items[0].start and !v.items[0].end);
    // Arriving eastwards, leaving southwards: half way is south-east.
    try expectVertex(v.items[1], 10, 0, 45);
    try expectVertex(v.items[2], 10, 10, 90);
    try testing.expect(v.items[2].end);
}

test "an arc is one segment however many cubics it became" {
    var v = try verticesOf("M0 0 A5 5 0 0 1 10 0");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), v.items.len);
    // A half circle over the top, clockwise in SVG's y-down space: leaves
    // straight up and arrives straight down.
    try expectVertex(v.items[0], 0, 0, -90);
    try expectVertex(v.items[1], 10, 0, 90);
}

test "a closed subpath's start faces between its closing segment and its first" {
    var v = try verticesOf("M0 0 L10 0 L10 10 Z");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), v.items.len);
    // Arriving from (10,10) north-westwards, leaving eastwards.
    try expectVertex(v.items[0], 0, 0, -67.5);
    try expectVertex(v.items[3], 0, 0, -67.5);
    try testing.expect(v.items[3].end);
}

test "a zero-length segment takes its neighbour's direction" {
    var v = try verticesOf("M0 0 L10 0 L10 0 L10 10");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), v.items.len);
    // Arriving eastwards and leaving by a segment that carries that on.
    try expectVertex(v.items[1], 10, 0, 0);
    // Arriving by that segment, so eastwards, and leaving southwards.
    try expectVertex(v.items[2], 10, 0, 45);
}

test "a lone moveto is a start and an end at once" {
    var v = try verticesOf("M3 4");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), v.items.len);
    try testing.expect(v.items[0].start and v.items[0].end);
}
