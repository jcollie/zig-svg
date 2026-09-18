// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the renderer must do with input nobody wrote.
//!
//! An SVG renderer is exposed code: it parses text chosen by whoever supplied
//! the document, does floating-point arithmetic on numbers out of that text,
//! and turns the results into buffer indices. So the properties here are not
//! "this document draws that picture" -- the tests beside each module are for
//! that -- but "whatever arrives, the renderer terminates, allocates within
//! its limits, stays inside its buffers, and either fails or produces
//! something that can be drawn".
//!
//! Four properties, in rough order of how much they are worth:
//!
//! * **It comes back.** No panic, no hang, no leak, no allocation beyond what
//!   `Limits` allowed. This is the one that matters; everything an attacker
//!   wants from a renderer is on the other side of breaking it.
//! * **Every coordinate is finite.** A NaN or an infinity reaching z2d is a
//!   hang or a panic rather than a wrong picture, so the parser has to refuse
//!   one rather than pass it on.
//! * **Every subpath is closed.** SVG fills as though every subpath were
//!   closed and z2d refuses to fill one that is not, so closing them is this
//!   parser's job. A path that parses and then will not fill is a bug here.
//! * **A parse survives rasterizing.** If the reader accepted the document,
//!   drawing it must not then fail for a reason the reader should have caught.
//!
//! The limits are deliberately tiny. A fuzzer will find a document asking for
//! a 65535×65535 picture within a few thousand inputs, and the interesting
//! thing about that input is that it is *refused*, not that the machine spends
//! a minute allocating for it.
//!
//! Each target is an ordinary test as well as a fuzz target. Without `--fuzz`
//! it runs the corpus beside it, so `zig build test` exercises the same
//! properties on input that has already been interesting once.
//!
//! Note that Zig 0.16.0 cannot build a test executable in fuzz mode without a
//! patched standard library, and leaves the fuzzer's coverage table empty even
//! then; `flake.nix` says more, and `tools/fuzz.zig` is the loop that works.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;

const z2d = @import("z2d");
const svg = @import("svg");

/// The allocator the targets run against.
///
/// Under `zig build test` that is the testing allocator, which reports a leak
/// as a failure. `tools/fuzz.zig` cannot name it -- it is not a test build --
/// so it sets this to a checked allocator of its own instead.
pub var backing: Allocator = if (builtin.is_test) testing.allocator else undefined;

/// Small enough that a document asking for an enormous picture is refused in
/// microseconds rather than allocated for.
const limits: svg.Limits = .{
    .max_width = 128,
    .max_height = 128,
    .max_pixels = 1 << 12,
    .max_path_nodes = 4096,
};

/// A fuzz target: a property, the inputs it is worth starting from, and how
/// many bytes of content its `Smith` reads.
pub const Target = struct {
    name: []const u8,
    run: *const fn ([]const u8) anyerror!void,
    corpus: []const []const u8,
    /// The buffer the target hands `Smith.slice`, which the generator has to
    /// know: a length larger than the buffer yields an *empty* slice rather
    /// than a truncated one, so a generator that writes a bigger length is
    /// silently fuzzing nothing.
    content_max: usize,
    /// Restores whatever internal consistency the format needs before a parser
    /// will look past its front door. Nothing in SVG has a checksum, so this
    /// is always null here; the field is what `tools/fuzz.zig` expects.
    repair: ?*const fn (bytes: []u8) void = null,
    /// Bytes worth mutating towards. Mutating a character into *another
    /// character the grammar defines* reaches a different branch; mutating it
    /// into noise mostly reaches the same refusal again.
    interesting: []const u8 = path_interesting,
};

/// The path data grammar's own alphabet: every command letter in both
/// spellings, the digits, and the four characters that separate or sign a
/// number.
pub const path_interesting = "MmLlHhVvCcSsQqTtAaZz0123456789.-+, eE";

/// XML's punctuation, the element and attribute names this reader knows, and
/// the ones it deliberately refuses -- a mutation that turns `path` into `g`
/// reaches the refusal branch, where one that turns it into noise does not.
pub const xml_interesting = "<>/=\"' svgpathdviewBox0123456789.-gcircleretdfs&;";

pub const all = [_]Target{
    .{ .name = "path-data", .run = pathData, .corpus = &path_corpus, .content_max = 4096 },
    .{ .name = "path-fill", .run = pathFill, .corpus = &path_corpus, .content_max = 1024 },
    .{
        .name = "document",
        .run = documentTarget,
        .corpus = &document_corpus,
        .content_max = 4096,
        .interesting = xml_interesting,
    },
    .{
        .name = "render",
        .run = renderTarget,
        .corpus = &document_corpus,
        .content_max = 4096,
        .interesting = xml_interesting,
    },
    .{ .name = "arc", .run = arcTarget, .corpus = &.{}, .content_max = 64 },
};

/// Build a path out of whatever the input says, and throw it away.
///
/// The parser must answer with one of its own errors or a clean path for every
/// possible input; what it must never do is loop, overrun, or hand z2d a
/// coordinate that is not finite.
fn pathData(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    var buf: [4096]u8 = undefined;
    const d = buf[0..smith.slice(&buf)];
    if (d.len == 0) return;

    var p: z2d.Path = .empty;
    defer p.deinit(backing);
    svg.path.build(&p, backing, d, .{ .max_nodes = limits.max_path_nodes }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    try expectAllFinite(p);
    // SVG fills as though every subpath were closed, and closing them is this
    // parser's job rather than its caller's.
    if (p.nodes.items.len != 0) try testing.expect(p.isClosed());
}

/// The same, but actually rasterized.
///
/// A path that parses and then will not fill is a bug here and not in z2d.
/// Anything z2d refuses for another reason is allowed through.
fn pathFill(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    var buf: [1024]u8 = undefined;
    const d = buf[0..smith.slice(&buf)];
    if (d.len == 0) return;

    var p: z2d.Path = .empty;
    defer p.deinit(backing);
    p.transformation = .{ .ax = 2, .by = 0, .cx = 0, .dy = 2, .tx = 0, .ty = 0 };
    svg.path.build(&p, backing, d, .{ .max_nodes = limits.max_path_nodes }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (p.nodes.items.len == 0) return;

    var surface = try z2d.Surface.init(.image_surface_rgb, backing, 32, 32);
    defer surface.deinit(backing);
    const source: z2d.Pattern = .{
        .opaque_pattern = .{ .pixel = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } } },
    };
    z2d.painter.fill(backing, &surface, &source, p.nodes.items, .{
        .fill_rule = .non_zero,
    }) catch |err| switch (err) {
        // The one failure that would be this parser's fault.
        error.PathNotClosed => return error.ParserLeftSubpathOpen,
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
}

/// The document reader on its own, which allocates nothing and so must never
/// fail for a reason that involves memory.
fn documentTarget(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    if (src.len == 0) return;

    const doc = svg.read(src) catch return;
    // A viewBox that got past the reader is four finite numbers with a
    // positive extent, which is what every scale computed from it assumes.
    try testing.expect(std.math.isFinite(doc.view_box.min_x));
    try testing.expect(std.math.isFinite(doc.view_box.min_y));
    try testing.expect(doc.view_box.width > 0);
    try testing.expect(doc.view_box.height > 0);
    try testing.expect(doc.shape_count > 0);

    // Reading and iterating are two walks of the same document, and a
    // disagreement between them paints a shape that passed every check. The
    // reader is the one that refuses, so the iterator finding more than it
    // counted is the dangerous direction.
    var shapes = doc.paths();
    var seen: usize = 0;
    while (try shapes.next()) |d| {
        seen += 1;
        // Every `d` points into the source the reader was given.
        try testing.expect(@intFromPtr(d.ptr) >= @intFromPtr(src.ptr));
        try testing.expect(@intFromPtr(d.ptr) + d.len <= @intFromPtr(src.ptr) + src.len);
    }
    try testing.expectEqual(doc.shape_count, seen);
}

/// The whole thing, from bytes to pixels.
fn renderTarget(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    if (src.len == 0) return;

    var surface = svg.render(backing, src, .{
        .width = 32,
        .height = 32,
        .limits = limits,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A document the reader accepted must not then fail to fill for a
        // reason the reader should have caught.
        error.PathNotClosed => return error.RendererLeftSubpathOpen,
        else => return,
    };
    defer surface.deinit(backing);

    try testing.expectEqual(@as(i32, 32), surface.getWidth());
    try testing.expectEqual(@as(i32, 32), surface.getHeight());
}

/// One elliptical arc, from parameters chosen directly rather than parsed.
///
/// The endpoint-to-centre conversion has a square root, two divisions and an
/// `acos` in it, every one of which has an input that answers NaN, and the
/// degenerate cases -- coincident endpoints, a zero radius, radii too small to
/// reach -- are each handled by a different clause of appendix F.6.
fn arcTarget(input: []const u8) anyerror!void {
    var smith: Smith = .{ .in = input };
    const p: svg.arc.Params = .{
        .x1 = coord(&smith),
        .y1 = coord(&smith),
        .x2 = coord(&smith),
        .y2 = coord(&smith),
        .rx = coord(&smith),
        .ry = coord(&smith),
        .rotation_deg = coord(&smith),
        .large_arc = smith.value(bool),
        .sweep = smith.value(bool),
    };

    var path: z2d.Path = .empty;
    defer path.deinit(backing);
    try path.moveTo(backing, p.x1, p.y1);
    svg.arc.append(&path, backing, p) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    try expectAllFinite(path);
}

/// A coordinate in roughly the range real path data uses, plus the edges.
///
/// `smith.value` answers a range's *minimum* for anything out of range rather
/// than reducing it, so asking for a small integer and scaling is the way to
/// get a spread rather than the same number every time.
fn coord(smith: *Smith) f64 {
    const n = smith.valueRangeAtMost(u16, 0, 2000);
    return (@as(f64, @floatFromInt(n)) - 1000.0) / 10.0;
}

fn expectAllFinite(p: z2d.Path) !void {
    for (p.nodes.items) |node| {
        switch (node) {
            .move_to => |n| try expectFinite(n.point),
            .line_to => |n| try expectFinite(n.point),
            .curve_to => |n| {
                try expectFinite(n.p1);
                try expectFinite(n.p2);
                try expectFinite(n.p3);
            },
            .close_path => {},
        }
    }
}

fn expectFinite(point: anytype) !void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) {
        return error.NonFiniteCoordinate;
    }
}

// -- the corpus --------------------------------------------------------------

/// Path data worth starting from: real icons, every command in both spellings,
/// and each shape that has its own clause in the specification.
const path_corpus = [_][]const u8{
    // Nothing at all, and one byte of nothing.
    "",
    "M",
    // Real icons, which is what the parser will actually see.
    "M3,9H7L12,4V20L7,15H3V9M16.59,12L14,9.41L15.41,8L18,10.59L20.59,8L22,9.41L19.41,12L22,14.59L20.59,16L18,13.41L15.41,16L14,14.59L16.59,12Z",
    "M15,2L17,9H7L9,2M11,10H13V20H16V22H8V20H11V10Z",
    "M20,5V19L13,12M6,5V19H4V5M13,5V19L6,12",
    "M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2Z",
    // Every command, absolute and relative, in one path.
    "M1 1L2 2H3V4C5 5 6 6 7 7S8 8 9 9Q10 10 11 11T12 12A1 1 0 0 1 13 13Z",
    "m1 1l2 2h3v4c5 5 6 6 7 7s8 8 9 9q10 10 11 11t12 12a1 1 0 0 1 13 13z",
    // A repeated moveto argument, which §8.3.2 makes a lineto.
    "M1 1 2 2 3 3Z",
    // Numbers that abut, with no separator at all.
    "M1-2L.5.5L3e2-4e-1Z",
    // Arc flags with nothing between them or the endpoint that follows.
    "M0 0a1 1 0 011 1z",
    // The degenerate arcs F.6.2 names: coincident endpoints, a zero radius,
    // and radii too small to reach, which F.6.6.2 scales up.
    "M5 5A2 2 0 0 1 5 5Z",
    "M0 0A0 4 0 1 1 10 10Z",
    "M0 0A1 1 0 0 1 10 10Z",
    // A subpath the data never closes, which the parser has to close itself.
    "M0 0L10 0L10 10",
    // Two subpaths, one closed and one not.
    "M0 0L5 0L5 5ZM6 6L9 6L9 9",
    // A command following Z with no intervening M: §8.3.3 says the current
    // point is the start of the subpath that was just closed.
    "M2 2L4 2L4 4ZL8 8Z",
    // A bare number after Z, which has no argument sequence to repeat. This
    // one hung the parser until the fuzzer found it.
    "M3 9L12 4Z6",
    "M0 0L1 1z9 9",
    // A reflected control point with nothing to reflect.
    "M0 0S1 1 2 2Z",
    "M0 0T5 5Z",
    // Unknown commands, and data that does not begin with a moveto.
    "L1 1",
    "M0 0X1 1",
    // Numbers at the edges of what a double holds.
    "M0 0L1e308 1e308Z",
    "M0 0L1e-308 1e-308Z",
};

/// Whole documents, for the reader and the renderer.
const document_corpus = [_][]const u8{
    "",
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M3,9H7L12,4V20L7,15H3V9Z\" /></svg>",
    "<svg viewBox=\"0 0 24 24\"><path d=\"M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2Z\"/></svg>",
    // The elements that are passed over, and the ones that are refused.
    "<svg viewBox=\"0 0 24 24\"><title>x</title><desc>y</desc><path d=\"M0 0L2 2Z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><defs><path d=\"M9 9Z\"/></defs><path d=\"M0 0L2 2Z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><g><path d=\"M0 0L1 1Z\"/></g></svg>",
    "<svg viewBox=\"0 0 24 24\"><circle cx=\"1\" cy=\"1\" r=\"1\"/></svg>",
    // viewBoxes that are not four positive numbers.
    "<svg viewBox=\"0 0\"><path d=\"M0 0Z\"/></svg>",
    "<svg viewBox=\"0 0 0 0\"><path d=\"M0 0Z\"/></svg>",
    "<svg viewBox=\"-4 -4 8 8\"><path d=\"M-3 -3L3 3Z\"/></svg>",
    "<svg viewBox=\"0 0 1e400 24\"><path d=\"M0 0Z\"/></svg>",
    // A document with no path, and one whose path has no d.
    "<svg viewBox=\"0 0 24 24\"></svg>",
    "<svg><path/></svg>",
    // Several paths, which are all painted, in the order they are written.
    "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0L1 1Z\"/><path d=\"M2 2L3 3Z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0H8V8H0Z\"/><path d=\"M2 2V6H6V2Z\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"\"/><path d=\"M0 0H4V4H0Z\"/><path d=\"\"/></svg>",
    // A path inside `<defs>` is not painted, and one after it is. The reader
    // and the iterator have to agree about that, which is what `document`
    // checks on every input.
    "<svg viewBox=\"0 0 24 24\"><defs><path d=\"M9 9Z\"/></defs><path d=\"M0 0L2 2Z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><defs><defs><path d=\"M9 9Z\"/></defs></defs><path d=\"M0 0Z\"/></svg>",
    // An unsupported element after several good shapes: refused, rather than
    // those shapes painted and then an error.
    "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/><g/></svg>",
    // XML that is not well formed, which is the reader's other job.
    "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"></svg>",
    "<svg viewBox=\"0 0 24 24\"",
    "<?xml version=\"1.0\"?><svg viewBox=\"0 0 24 24\"><path d=\"M0 0L1 1Z\"/></svg>",
    "<!-- just a comment -->",
    // An entity reference in the attribute this reader hands to the path
    // parser without decoding. It is not a path today; it is here so that it
    // is noticed the day the reader learns to decode one.
    "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0L1 1&#90;\"/></svg>",
};

// -- tests -------------------------------------------------------------------

test "every target survives every corpus entry" {
    for (all) |target| {
        for (target.corpus) |entry| {
            const input = try encode(testing.allocator, entry, target.content_max);
            defer testing.allocator.free(input);
            try target.run(input);
        }
    }
}

test "the arc target survives an input of nothing" {
    // It reads values rather than a slice, and `Smith` answers a range's
    // minimum when it runs out, so this is the all-zeroes arc.
    try arcTarget(&.{});
}

test "the target table is well formed" {
    for (all) |target| {
        try testing.expect(target.name.len > 0);
        try testing.expect(target.content_max > 0);
        try testing.expect(target.interesting.len > 0);
        for (target.corpus) |entry| {
            try testing.expect(entry.len <= target.content_max);
        }
    }
}

/// One corpus entry, in the encoding `Smith` reads: a little-endian `u32`
/// length and then that many bytes.
///
/// An entry longer than the target's buffer would be handed back as the
/// *empty* slice rather than truncated, which is the silent way to fuzz
/// nothing, so this refuses rather than letting that happen.
fn encode(gpa: Allocator, entry: []const u8, content_max: usize) ![]u8 {
    if (entry.len > content_max) return error.CorpusEntryTooLongForTarget;
    const buf = try gpa.alloc(u8, 4 + entry.len);
    std.mem.writeInt(u32, buf[0..4], @intCast(entry.len), .little);
    @memcpy(buf[4..], entry);
    return buf;
}
