// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! SVG's basic shapes, as path operations.
//!
//! `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polyline>` and `<polygon>`
//! are each defined by SVG 1.1 §9 in terms of an equivalent path, and that is
//! what this emits -- straight into a `z2d.Path`, rather than by building a `d`
//! string for the path parser to read back. A shape's geometry is four or five
//! numbers the reader already has; spelling them out as text so that they can
//! be re-parsed would allocate, and would put a second number formatter and a
//! second number parser between the document and the picture.
//!
//! ## What draws nothing, and is not an error
//!
//! A zero or negative width, height or radius disables rendering: §9 says a
//! zero value does, and SVG 2 makes a negative one invalid and therefore zero.
//! A missing attribute is zero too. So `<rect/>` and `<circle r="-2"/>` both
//! produce no geometry at all, which is what resvg draws and is not a failure.
//!
//! **A `<line>` never draws anything here.** A line has no area, and this
//! library fills without stroking, so `<line>` is read, accepted, and produces
//! a subpath that covers no pixels -- exactly what resvg does when asked to
//! fill one. It is implemented rather than refused because that is the
//! honest answer to "can you draw this", and because it costs nothing to have
//! ready for when strokes arrive.
//!
//! ## `<polyline>` and `<polygon>` fill identically
//!
//! §11.4 fills every subpath as though it were closed, so the two differ only
//! when stroked. They are kept as separate variants all the same, since that
//! is the distinction a stroke will need and re-deriving it later would mean
//! changing the shape of what the reader produces.

const std = @import("std");
const ztree = @import("ztree");
const testing = std.testing;

const z2d = @import("z2d");

const arc = @import("arc.zig");
const path = @import("path.zig");

pub const Error = path.Error;
pub const BuildError = path.BuildError || error{
    /// A `.text` geometry reached `build`, which has no font and cannot turn
    /// one into a path. `raster.zig` handles text before it gets here; this is
    /// what any other caller meets.
    TextNeedsAFont,
};

/// An axis-aligned rectangle, with optionally rounded corners.
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    /// The corner radii as the document wrote them, before §9.2's defaulting
    /// and clamping, which `build` applies. Null is "not specified", which is
    /// not the same as zero: one specified radius supplies the other.
    rx: ?f64 = null,
    ry: ?f64 = null,
};

pub const Ellipse = struct {
    cx: f64 = 0,
    cy: f64 = 0,
    rx: f64 = 0,
    ry: f64 = 0,
};

pub const Line = struct {
    x1: f64 = 0,
    y1: f64 = 0,
    x2: f64 = 0,
    y2: f64 = 0,
};

/// `<polyline>` or `<polygon>`: the `points` attribute, borrowed from the
/// source and parsed when the shape is built.
pub const Poly = struct {
    points: []const u8,
    /// Whether the document said `<polygon>`. Nothing here reads it -- the two
    /// fill identically -- but a stroke will.
    closed: bool,
};

/// What a drawable element contributes.
pub const Geometry = union(enum) {
    /// A `<path>`'s `d`, borrowed from the source.
    path: []const u8,
    rect: Rect,
    ellipse: Ellipse,
    line: Line,
    poly: Poly,
    /// A `<text>`'s content and where it starts.
    ///
    /// The odd one out, and unavoidably so: every other geometry here is
    /// numbers this module can turn into a path on its own, and this one needs
    /// a *font* -- which the caller supplies, because finding one means a font
    /// database and a filesystem, and the filesystem is what the sandbox
    /// exists to take away. `build` therefore refuses it; `raster.zig` builds
    /// it, where the fonts are.
    text: Text,
};

/// Where along a `<textPath>`'s shape a run begins.
pub const OnPath = struct {
    /// The element whose geometry the glyphs follow.
    node: ztree.NodeId,
    /// §10.13's `startOffset`. A percentage is of the path's own length,
    /// which is not known until it has been measured, so which kind it is has
    /// to survive as far as the renderer.
    offset: Offset,

    pub const Offset = union(enum) {
        /// User units along the path.
        absolute: f64,
        /// A fraction of the path's length.
        fraction: f64,
    };
};

/// One run of text, as the document wrote it.
///
/// A `<text>` is not one run but a sequence of them: every `<tspan>` inside it
/// is a run of its own with its own properties, and the characters around them
/// are runs too. They share a pen that advances along the line, which is why a
/// run does not always know where it starts.
pub const Text = struct {
    /// A baseline of the font's that text can be aligned by; see `baseline`.
    pub const Baseline = enum { alphabetic, before_edge, after_edge, middle, central, hanging, mathematical };

    /// The characters, still as they appear in the document. Whitespace is
    /// collapsed at drawing time rather than here, because collapsing makes a
    /// new string and this one is borrowed from the tree's arena.
    utf8: []const u8,

    /// Where the run begins, when the element said. §10.4's `x` and `y` are
    /// absolute and each starts a new *chunk*; a run without them carries on
    /// from wherever the previous one left the pen.
    x: ?f64,
    y: ?f64,

    /// §10.4's `dx` and `dy`: a shift from wherever the pen is, which does
    /// not start a new chunk.
    dx: f64,
    dy: f64,

    /// The `<text>` this run belongs to.
    ///
    /// The renderer needs it to measure: `text-anchor` applies to a whole
    /// chunk rather than to a run, so placing the first run of one means
    /// knowing the width of all of them -- and the widths need a font, which
    /// only the renderer has. It walks this subtree to find them.
    owner: ztree.NodeId,

    /// True for the first run of its `<text>`, which is what tells the
    /// renderer to start a fresh pen rather than carry one on.
    starts_element: bool,

    /// Whether the run begins and ends with a space once its whitespace is
    /// collapsed.
    ///
    /// SVG's default `xml:space` collapses the whitespace of the whole
    /// `<text>`, not of each run: a space at the edge of a `<tspan>` or an
    /// `<a>` is the space between two words, and only the element's first
    /// and last are dropped. Whether a run's edge keeps its space depends on
    /// the runs around it, which only the walk sees, so the walk decides and
    /// says so here. Every run's inner whitespace collapses the same way
    /// whatever these say.
    lead_space: bool = false,
    trail_space: bool = false,

    /// §10.4's `rotate`, as the document wrote it: a list of angles in
    /// degrees, one per character, the last repeating for whatever is left.
    /// Kept as text for the same reason `stroke-dasharray` is -- it is a list,
    /// and splitting it here would mean allocating.
    rotate: ?[]const u8,

    /// CSS's `letter-spacing` and `word-spacing`, in user units: added after
    /// every character, and after every word separator, respectively.
    letter_spacing: f64 = 0,
    word_spacing: f64 = 0,

    /// `baseline-shift`, summed over the elements from this run's up to its
    /// `<text>`: the lengths and percentages in user units, positive upward,
    /// and how many `super`s and `sub`s -- which are the font's own offsets,
    /// so only the renderer, with the font, can turn them into distances.
    baseline_shift: f64 = 0,
    supers: i16 = 0,
    subs: i16 = 0,

    /// Which of the font's baselines sits on the pen's y, from
    /// `alignment-baseline`, or `dominant-baseline` where that says nothing.
    /// Its distance from the alphabetic baseline is the font's, so only the
    /// renderer knows it.
    baseline: Baseline = .alphabetic,

    /// The path this run is laid along, when it sits inside a `<textPath>`.
    ///
    /// §10.13: the glyphs follow the shape rather than a straight line, each
    /// turned to the tangent where it sits. The renderer needs the referenced
    /// element to measure the curve, which the reader cannot do -- measuring
    /// means flattening it, and that is drawing work.
    on_path: ?OnPath,

    /// §10.4's `textLength`: the width the run is to be adjusted to fit.
    ///
    /// Only `lengthAdjust="spacing"` is implemented, which is the initial
    /// value: the gaps between glyphs change and the glyphs do not. resvg
    /// draws it that way too, which a fixture pins by showing the same letters
    /// at different spacings.
    text_length: ?f64,
};

/// Append `geometry` to `p`, honouring `p.transformation`.
///
/// Every subpath is closed, so the result can be handed straight to
/// `z2d.painter.fill`.
pub fn build(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    geometry: Geometry,
    opts: path.Options,
) BuildError!void {
    switch (geometry) {
        // A `d` arrives with its entity references already resolved: ztree
        // decodes every attribute value into the tree's arena as it parses.
        .path => |d| return path.build(p, alloc, d, opts),
        // Text needs a font, which is the caller's to supply and not this
        // module's to find. `raster.zig` builds it, where the fonts are; this
        // says so rather than silently drawing nothing, because a `<text>`
        // that quietly vanishes is the kind of missing piece that looks like a
        // finished picture.
        .text => return error.TextNeedsAFont,
        .rect => |r| return buildRect(p, alloc, r, opts),
        .ellipse => |e| return buildEllipse(p, alloc, e, opts),
        .line => |l| return buildLine(p, alloc, l, opts),
        .poly => |poly| return buildPoly(p, alloc, poly.points, poly.closed, opts),
    }
}

/// Notes where a command of an equivalent path ended, for the markers that
/// go at its vertices: see `path.Options.command_ends`.
fn ended(p: *z2d.Path, alloc: std.mem.Allocator, opts: path.Options) BuildError!void {
    if (opts.command_ends) |ends| try ends.append(alloc, p.nodes.items.len);
}

/// §9.2's equivalent path for `<rect>`.
///
/// Its commands are SVG 2 §10.2's, in its order and from its starting point,
/// because a marker goes at the end of each: a square rectangle's four
/// corners, and a rounded one's eight ends of arcs and sides.
fn buildRect(p: *z2d.Path, alloc: std.mem.Allocator, r: Rect, opts: path.Options) BuildError!void {
    if (!(r.width > 0) or !(r.height > 0)) return;

    // §9.2: a radius given for one axis supplies the other; a negative one is
    // not a radius at all, so it is as though it had not been given. Then both
    // are clamped to half the side they run along, which is what makes
    // `rx="99"` a stadium rather than a shape turned inside out.
    const given_rx: ?f64 = if (r.rx) |v| (if (v >= 0) v else null) else null;
    const given_ry: ?f64 = if (r.ry) |v| (if (v >= 0) v else null) else null;
    var rx = given_rx orelse given_ry orelse 0;
    var ry = given_ry orelse given_rx orelse 0;
    rx = @min(rx, r.width / 2);
    ry = @min(ry, r.height / 2);

    if (rx <= 0 or ry <= 0) {
        try p.moveTo(alloc, r.x, r.y);
        try ended(p, alloc, opts);
        try p.lineTo(alloc, r.x + r.width, r.y);
        try ended(p, alloc, opts);
        try p.lineTo(alloc, r.x + r.width, r.y + r.height);
        try ended(p, alloc, opts);
        try p.lineTo(alloc, r.x, r.y + r.height);
        try ended(p, alloc, opts);
        try p.close(alloc);
        try ended(p, alloc, opts);
        return;
    }

    const right = r.x + r.width;
    const bottom = r.y + r.height;

    try p.moveTo(alloc, r.x + rx, r.y);
    try ended(p, alloc, opts);
    try p.lineTo(alloc, right - rx, r.y);
    try ended(p, alloc, opts);
    try corner(p, alloc, right - rx, r.y, right, r.y + ry, rx, ry);
    try ended(p, alloc, opts);
    try p.lineTo(alloc, right, bottom - ry);
    try ended(p, alloc, opts);
    try corner(p, alloc, right, bottom - ry, right - rx, bottom, rx, ry);
    try ended(p, alloc, opts);
    try p.lineTo(alloc, r.x + rx, bottom);
    try ended(p, alloc, opts);
    try corner(p, alloc, r.x + rx, bottom, r.x, bottom - ry, rx, ry);
    try ended(p, alloc, opts);
    try p.lineTo(alloc, r.x, r.y + ry);
    try ended(p, alloc, opts);
    try corner(p, alloc, r.x, r.y + ry, r.x + rx, r.y, rx, ry);
    try ended(p, alloc, opts);
    try p.close(alloc);
    try ended(p, alloc, opts);
}

/// One quarter-ellipse corner, swept the short way round.
fn corner(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    rx: f64,
    ry: f64,
) BuildError!void {
    try arc.append(p, alloc, .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
        .rx = rx,
        .ry = ry,
        .rotation_deg = 0,
        .large_arc = false,
        .sweep = true,
    });
}

/// §9.4's equivalent path for `<ellipse>`, which `<circle>` also uses with
/// both radii set to `r`: SVG 2 §10.3's, from the rightmost point and round
/// through the bottom, so that its markers go at the four ends of its axes.
fn buildEllipse(p: *z2d.Path, alloc: std.mem.Allocator, e: Ellipse, opts: path.Options) BuildError!void {
    if (!(e.rx > 0) or !(e.ry > 0)) return;

    // Four quarter sweeps rather than two halves: a half sweep has coincident
    // endpoints only in the degenerate case, but four keeps every arc well
    // inside the 90° the cubic approximation is accurate to.
    try p.moveTo(alloc, e.cx + e.rx, e.cy);
    try ended(p, alloc, opts);
    try corner(p, alloc, e.cx + e.rx, e.cy, e.cx, e.cy + e.ry, e.rx, e.ry);
    try ended(p, alloc, opts);
    try corner(p, alloc, e.cx, e.cy + e.ry, e.cx - e.rx, e.cy, e.rx, e.ry);
    try ended(p, alloc, opts);
    try corner(p, alloc, e.cx - e.rx, e.cy, e.cx, e.cy - e.ry, e.rx, e.ry);
    try ended(p, alloc, opts);
    try corner(p, alloc, e.cx, e.cy - e.ry, e.cx + e.rx, e.cy, e.rx, e.ry);
    try ended(p, alloc, opts);
    try p.close(alloc);
    try ended(p, alloc, opts);
}

/// §9.5's equivalent path for `<line>`, which covers no pixels when filled
/// and is the whole of the picture when stroked.
fn buildLine(p: *z2d.Path, alloc: std.mem.Allocator, l: Line, opts: path.Options) BuildError!void {
    try p.moveTo(alloc, l.x1, l.y1);
    try p.lineTo(alloc, l.x2, l.y2);
    // Closed for filling, because z2d refuses to fill an open subpath; left
    // open for stroking, because a closed line would be drawn up and back
    // again with a join at each end rather than a cap.
    if (opts.close_subpaths) try p.close(alloc);
}

/// §9.6 and §9.7: a run of points, joined and closed.
///
/// Reading stops at the first thing that is not a coordinate pair, and what
/// was read up to there is drawn. That covers an odd number of coordinates and
/// a number that is not one, and in both cases SVG 1.1 calls the element an
/// error while resvg, and every browser, draw the pairs they got.
///
/// Drawing them is the right answer here even though this library refuses a
/// colour it cannot read, and the difference is which failure is quiet. A
/// wrong colour is a picture that looks finished and is not; a truncated
/// points list is the same picture every other renderer produces. A trailing
/// comma or a stray space is the commonest way for a generated document to
/// have one, and refusing would mean no picture at all where everyone else
/// gets the right one.
fn buildPoly(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    points: []const u8,
    closed: bool,
    opts: path.Options,
) BuildError!void {
    // The same scanner the path data uses, because `points` is written in the
    // same number syntax down to abutting signs: `2-2 14-2` is two points, and
    // resvg reads it that way too.
    var s: path.Scanner = .{ .src = points };
    const ceiling = std.math.add(usize, p.nodes.items.len, opts.max_nodes) catch
        std.math.maxInt(usize);

    var started = false;
    while (true) {
        s.skipWsAndCommas();
        if (s.done()) break;
        const x = s.number() catch break; // not a number: draw what we have
        s.skipWsAndCommas();
        if (s.done()) break; // an odd coordinate: drop the incomplete pair
        const y = s.number() catch break;

        if (started) {
            try p.lineTo(alloc, x, y);
        } else {
            try p.moveTo(alloc, x, y);
            started = true;
        }
        if (p.nodes.items.len > ceiling) return error.PathTooComplex;
    }
    // `<polygon>` closes and `<polyline>` does not -- the one place the two
    // differ, and the reason `Poly.closed` has been carried since they were
    // added. For filling it makes no difference, since §11.4 fills every
    // subpath as though it were closed.
    if (started and (closed or opts.close_subpaths)) try p.close(alloc);
}

// -- tests -------------------------------------------------------------------

fn buildOne(gpa: std.mem.Allocator, geometry: Geometry) !z2d.Path {
    var p: z2d.Path = .empty;
    errdefer p.deinit(gpa);
    try build(&p, gpa, geometry, .{});
    return p;
}

/// The bounding box of every point in a path, for checking geometry without
/// rasterizing it.
fn extent(p: z2d.Path) [4]f64 {
    var box: [4]f64 = .{
        std.math.inf(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
        -std.math.inf(f64),
    };
    const see = struct {
        fn f(b: *[4]f64, pt: anytype) void {
            b[0] = @min(b[0], pt.x);
            b[1] = @min(b[1], pt.y);
            b[2] = @max(b[2], pt.x);
            b[3] = @max(b[3], pt.y);
        }
    }.f;
    for (p.nodes.items) |node| switch (node) {
        .move_to => |n| see(&box, n.point),
        .line_to => |n| see(&box, n.point),
        .curve_to => |n| {
            see(&box, n.p1);
            see(&box, n.p2);
            see(&box, n.p3);
        },
        .close_path => {},
    };
    return box;
}

test "a rectangle is its four corners" {
    const gpa = testing.allocator;
    var p = try buildOne(gpa, .{ .rect = .{ .x = 2, .y = 3, .width = 8, .height = 4 } });
    defer p.deinit(gpa);
    try testing.expect(p.isClosed());
    const box = extent(p);
    try testing.expectApproxEqAbs(@as(f64, 2), box[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3), box[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10), box[2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 7), box[3], 1e-12);
}

test "one corner radius supplies the other" {
    const gpa = testing.allocator;
    var only_rx = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .rx = 4 } });
    defer only_rx.deinit(gpa);
    var only_ry = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .ry = 4 } });
    defer only_ry.deinit(gpa);
    var both = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .rx = 4, .ry = 4 } });
    defer both.deinit(gpa);

    try testing.expectEqual(both.nodes.items.len, only_rx.nodes.items.len);
    try testing.expectEqual(both.nodes.items.len, only_ry.nodes.items.len);
    // And a rounded rectangle has more in it than a square-cornered one.
    var square = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16 } });
    defer square.deinit(gpa);
    try testing.expect(both.nodes.items.len > square.nodes.items.len);
}

test "a radius that is negative is no radius at all" {
    const gpa = testing.allocator;
    var square = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16 } });
    defer square.deinit(gpa);
    var negative = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .rx = -1 } });
    defer negative.deinit(gpa);
    var zero = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .rx = 0 } });
    defer zero.deinit(gpa);
    try testing.expectEqual(square.nodes.items.len, negative.nodes.items.len);
    try testing.expectEqual(square.nodes.items.len, zero.nodes.items.len);
}

test "a radius larger than the side is clamped to half of it" {
    const gpa = testing.allocator;
    var huge = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .rx = 99 } });
    defer huge.deinit(gpa);
    var half = try buildOne(gpa, .{ .rect = .{ .width = 16, .height = 16, .rx = 8 } });
    defer half.deinit(gpa);
    try testing.expectEqual(half.nodes.items.len, huge.nodes.items.len);
    // And it has not grown beyond the rectangle it rounds.
    const box = extent(huge);
    try testing.expect(box[0] >= -1e-9 and box[2] <= 16 + 1e-9);
}

test "a shape with no extent draws nothing" {
    const gpa = testing.allocator;
    for ([_]Geometry{
        .{ .rect = .{ .width = 0, .height = 6 } },
        .{ .rect = .{ .width = -4, .height = 6 } },
        .{ .rect = .{} },
        .{ .ellipse = .{ .rx = 0, .ry = 3 } },
        .{ .ellipse = .{ .rx = 4, .ry = -1 } },
        .{ .ellipse = .{} },
        .{ .poly = .{ .points = "", .closed = true } },
        .{ .poly = .{ .points = "   ", .closed = true } },
    }) |geometry| {
        var p = try buildOne(gpa, geometry);
        defer p.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), p.nodes.items.len);
    }
}

test "an ellipse spans its radii" {
    const gpa = testing.allocator;
    var p = try buildOne(gpa, .{ .ellipse = .{ .cx = 8, .cy = 8, .rx = 6, .ry = 3 } });
    defer p.deinit(gpa);
    try testing.expect(p.isClosed());
    const box = extent(p);
    // The control points of a cubic reach a little outside the curve, so this
    // is the extent of the hull rather than of the ellipse.
    try testing.expect(box[0] <= 2 + 1e-9 and box[0] > 1);
    try testing.expect(box[2] >= 14 - 1e-9 and box[2] < 15);
    try testing.expect(box[1] <= 5 + 1e-9 and box[1] > 4);
    try testing.expect(box[3] >= 11 - 1e-9 and box[3] < 12);
}

test "a line is a subpath that covers nothing" {
    const gpa = testing.allocator;
    var p = try buildOne(gpa, .{ .line = .{ .x1 = 2, .y1 = 2, .x2 = 12, .y2 = 12 } });
    defer p.deinit(gpa);
    // Closed, so `painter.fill` takes it -- and fills no pixels, because a
    // line encloses no area.
    try testing.expect(p.isClosed());

    var surface = try z2d.Surface.init(.image_surface_rgba, gpa, 16, 16);
    defer surface.deinit(gpa);
    const source: z2d.Pattern = .{
        .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } } },
    };
    try z2d.painter.fill(gpa, &surface, &source, p.nodes.items, .{});
    for (0..16) |y| for (0..16) |x| {
        try testing.expectEqual(
            @as(u8, 0),
            surface.getPixel(@intCast(x), @intCast(y)).?.rgba.a,
        );
    };
}

test "points are read like path data, separators and abutting signs alike" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "2,2 14,2 8,14",
        "2 2 14 2 8 14",
        "2,2,14,2,8,14",
        "2 2,14 2,8 14",
        "  2,2   14,2   8,14  ",
    }) |points| {
        var p = try buildOne(gpa, .{ .poly = .{ .points = points, .closed = true } });
        defer p.deinit(gpa);
        const box = extent(p);
        try testing.expectApproxEqAbs(@as(f64, 2), box[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 14), box[2], 1e-12);
    }
    // Abutting signs, which the number grammar allows and resvg reads too.
    var abutting = try buildOne(gpa, .{ .poly = .{ .points = "2-2 14-2 8-14", .closed = true } });
    defer abutting.deinit(gpa);
    const box = extent(abutting);
    try testing.expectApproxEqAbs(@as(f64, -14), box[1], 1e-12);
}

test "an odd coordinate count drops the incomplete pair" {
    const gpa = testing.allocator;
    var whole = try buildOne(gpa, .{ .poly = .{ .points = "2,2 14,2 14,14 2,14", .closed = true } });
    defer whole.deinit(gpa);
    for ([_][]const u8{
        "2,2 14,2 14,14 2,14 5",
        "2,2 14,2 14,14 2,14 5,",
        "2,2 14,2 14,14 2,14,",
    }) |points| {
        var p = try buildOne(gpa, .{ .poly = .{ .points = points, .closed = true } });
        defer p.deinit(gpa);
        try testing.expectEqual(whole.nodes.items.len, p.nodes.items.len);
    }
}

test "a polygon past the node budget is refused" {
    const gpa = testing.allocator;
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    try testing.expectError(error.PathTooComplex, build(
        &p,
        gpa,
        .{ .poly = .{ .points = "0,0 1,1 2,2 3,3 4,4 5,5 6,6", .closed = true } },
        .{ .max_nodes = 3 },
    ));
}
