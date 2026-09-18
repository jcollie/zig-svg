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
    /// Whether `--alloc-fail` may run this target.
    ///
    /// Off for the one target that can reach z2d's stroke plotter, which
    /// **leaks** when an allocation fails part way through it:
    /// `internal/tess/Polygon.zig`'s `plot` does `alloc.create(Corner)` and
    /// the partially built corner list is not released when a later allocation
    /// in the same plot fails. The trace runs entirely through z2d, so there
    /// is nothing this library can do about it but say so.
    ///
    /// The mode is for *this* library's error paths, and the other four
    /// targets still exercise them -- `path-fill` covers the fill side of the
    /// same rasterizer. Turn this back on for `render` when z2d is fixed; the
    /// leak is easy to see again with
    /// `zig build fuzz-run -- --alloc-fail --target render`.
    alloc_fail: bool = true,
};

/// The path data grammar's own alphabet: every command letter in both
/// spellings, the digits, and the four characters that separate or sign a
/// number.
pub const path_interesting = "MmLlHhVvCcSsQqTtAaZz0123456789.-+, eE";

/// XML's punctuation, the element and attribute names this reader knows, and
/// the ones it deliberately refuses -- a mutation that turns `path` into `g`
/// reaches the refusal branch, where one that turns it into noise does not.
pub const xml_interesting = "<>/=\"' svgpathdviewBox0123456789.-gcircleretdfs&;" ++
    "fill-opacityrulenonzeevdcurColor#%()," ++
    "transformatrixlscewXYkyop" ++
    "rectcirclepsoygnlinwdthxy12points" ++
    "strokewidthcapjonmielmtdasharyofst" ++
    "preserveAspctRioMdnlx%emptcin" ++
    "&#;xampltqsogu09AZ" ++
    "usehrfid#defxlink:" ++
    "linearGradstopfetURuns%BoxpM";

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
        // See `Target.alloc_fail`: z2d's stroke plotter leaks under a failed
        // allocation, and this is the only target that reaches it.
        .alloc_fail = false,
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

    var doc = svg.read(backing, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer doc.deinit();
    // A viewBox that got past the reader is four finite numbers with a
    // positive extent, which is what every scale computed from it assumes.
    if (doc.view_box) |vb| {
        try testing.expect(std.math.isFinite(vb.min_x));
        try testing.expect(std.math.isFinite(vb.min_y));
        try testing.expect(vb.width > 0);
        try testing.expect(vb.height > 0);
    }
    // And the size it reports is one a surface can be made at.
    try testing.expect(std.math.isFinite(doc.width) and doc.width > 0);
    try testing.expect(std.math.isFinite(doc.height) and doc.height > 0);
    try testing.expect(doc.shape_count > 0);

    // Reading and iterating are two walks of the same document, and a
    // disagreement between them paints a shape that passed every check. The
    // reader is the one that refuses, so the iterator finding more than it
    // counted is the dangerous direction.
    var shapes = doc.paths();
    var seen: usize = 0;
    while (try shapes.next()) |shape| {
        seen += 1;
        // Whatever the shape borrowed points into the source it was given.
        // `<path>` borrows its `d` and the polys borrow their `points`; the
        // rest carry numbers and borrow nothing.
        const borrowed: ?[]const u8 = switch (shape.geometry) {
            .path => |d| d,
            .poly => |poly| poly.points,
            else => null,
        };
        // Whatever a shape borrows comes from the tree's arena, never from
        // the source: `read` copies every string as it parses, which is what
        // lets a caller free the source the moment it returns. A slice
        // pointing back into `src` would be a lifetime bug that only showed
        // up once somebody took that documented permission.
        if (borrowed) |b| if (b.len != 0) {
            const inside = @intFromPtr(b.ptr) >= @intFromPtr(src.ptr) and
                @intFromPtr(b.ptr) < @intFromPtr(src.ptr) + src.len;
            try testing.expect(!inside);
        };
        if (shape.stroke_width) |w| try expectUsable(w);
        if (shape.stroke_opacity) |o| try testing.expect(o >= 0.0 and o <= 1.0);
        if (shape.stroke_miterlimit) |m| {
            try expectUsable(m);
            // §11.4 says at least one, and `parseMiterLimit` clamps to it.
            try testing.expect(m >= 1.0);
        }
        if (shape.stroke_dashoffset) |o| try expectUsable(o);
        if (shape.stroke_dasharray) |raw| if (raw.len != 0) {
            const inside = @intFromPtr(raw.ptr) >= @intFromPtr(src.ptr) and
                @intFromPtr(raw.ptr) < @intFromPtr(src.ptr) + src.len;
            try testing.expect(!inside);
        };

        // And every number a shape carries is one the rasterizer can use.
        switch (shape.geometry) {
            .rect => |r| {
                try expectUsable(r.x);
                try expectUsable(r.y);
                try expectUsable(r.width);
                try expectUsable(r.height);
                if (r.rx) |v| try expectUsable(v);
                if (r.ry) |v| try expectUsable(v);
            },
            .ellipse => |el| {
                try expectUsable(el.cx);
                try expectUsable(el.cy);
                try expectUsable(el.rx);
                try expectUsable(el.ry);
            },
            .line => |l| {
                try expectUsable(l.x1);
                try expectUsable(l.y1);
                try expectUsable(l.x2);
                try expectUsable(l.y2);
            },
            else => {},
        }
        // And every alpha the reader produced is a number a compositor can
        // use: `parseOpacity` clamps, so nothing here should ever be outside
        // the range or be a NaN.
        try testing.expect(shape.opacity >= 0.0 and shape.opacity <= 1.0);
        if (shape.fill_opacity) |o| try testing.expect(o >= 0.0 and o <= 1.0);
        if (shape.fill) |paint| switch (paint) {
            .color => |c| try testing.expect(c.alpha >= 0.0 and c.alpha <= 1.0),
            else => {},
        };
        // A matrix with an infinity or a NaN in it is a hang or a panic in the
        // rasterizer rather than a wrong picture, so the reader has to have
        // refused it rather than handed it over.
        try testing.expect(svg.transform.isFinite(shape.transform));
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

fn expectUsable(v: f64) !void {
    if (!std.math.isFinite(v)) return error.NonFiniteLength;
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
    // The presentation attributes, in every syntax they are written in.
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"red\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"#ff000080\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"rgba(1,2,3,0.5)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"rgb(0% 60% 100%)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"none\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"currentColor\"/></svg>",
    "<svg viewBox=\"0 0 8 8\" color=\"teal\"><path d=\"M0 0H8V8H0Z\" fill=\"currentColor\"/></svg>",
    "<svg viewBox=\"0 0 8 8\" fill=\"red\" fill-opacity=\"0.5\"><path d=\"M0 0H8V8H0Z\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill-opacity=\"50%\" opacity=\"0.25\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill-rule=\"evenodd\"/></svg>",
    // And the shapes of them that have to be refused rather than defaulted.
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"notacolour\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill=\"#12345\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" opacity=\"half\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" fill-rule=\"EVENODD\"/></svg>",
    "<svg viewBox=\"0 0 8 8\" opacity=\"0.5\"><path d=\"M0 0H8V8H0Z\"/></svg>",
    // Groups: the stack has to come back down again, and a self-closing one
    // reports a synthetic end tag that used to pop its parent.
    "<svg viewBox=\"0 0 8 8\"><g><path d=\"M0 0H4V4H0Z\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g/><path d=\"M0 0H4V4H0Z\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,4)\"><g><path d=\"M0 0H4V4H0Z\"/></g></g><path d=\"M0 0Z\"/></svg>",
    "<svg viewBox=\"0 0 8 8\" fill=\"red\"><g fill=\"blue\"><g><path d=\"M0 0H4V4H0Z\" fill=\"lime\"/></g></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g><defs><title/><path d=\"M9 9Z\"/></defs><path d=\"M0 0Z\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"0.5\"><path d=\"M0 0Z\"/></g></svg>",
    // Every transform function, and the shapes that have to be refused.
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"translate(2,2)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"matrix(1 .3 -.3 1 2 2)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"rotate(30,4,4)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"skewX(20) skewY(10)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"scale(2) translate(1,1)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"bogus(1)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"scale(1e300) scale(1e300)\"/></svg>",
    // A finite matrix that puts a finite point out of the rasterizer's reach.
    // This one panicked -- z2d casts a polygon extent to an i32 -- which is
    // the failure a caller cannot catch.
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"scale(1e300)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(1e20,0)\"><path d=\"M0 0H4V4H0Z\"/></g></svg>",
    // Clamped by z2d rather than refused, because the clamp is applied before
    // the transform rather than after it. Kept so that a change to that order
    // shows up here.
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H1e300V1e300H0Z\"/></svg>",
    // The basic shapes, each in the spellings §9 gives them.
    "<svg viewBox=\"0 0 24 24\"><rect x=\"2\" y=\"2\" width=\"8\" height=\"6\" fill=\"red\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"16\" height=\"16\" rx=\"4\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"16\" height=\"16\" ry=\"4\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"16\" height=\"16\" rx=\"99\" ry=\"-1\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><circle cx=\"8\" cy=\"8\" r=\"5\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><ellipse cx=\"8\" cy=\"8\" rx=\"6\" ry=\"3\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"2\" x2=\"12\" y2=\"12\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><polygon points=\"2,2 12,2 8,12\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><polyline points=\"2 2 12 2 8 12\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><polygon points=\"2-2 12-2 8-12\"/></svg>",
    // Shapes with nothing in them, which draw nothing and are not errors.
    "<svg viewBox=\"0 0 24 24\"><rect/><path d=\"M0 0Z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><circle/><ellipse/><polygon points=\"\"/><path d=\"M0 0Z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"-4\" height=\"8\"/><path d=\"M0 0Z\"/></svg>",
    // An odd coordinate count, which drops the incomplete pair rather than
    // voiding the element -- the commonest way a generated document has one is
    // a trailing comma.
    "<svg viewBox=\"0 0 24 24\"><polygon points=\"2,2 12,2 8,12 5\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><polygon points=\"2,2 12,2 8,12,\"/></svg>",
    // Lengths: `px` is the user unit, and every other unit is refused today.
    "<svg viewBox=\"0 0 24 24\"><circle cx=\"8px\" cy=\"8px\" r=\"4px\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><circle cx=\"8\" cy=\"8\" r=\"4pt\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><circle cx=\"8\" cy=\"8\" r=\"50%\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"abc\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"1e400\" height=\"8\"/></svg>",
    // Strokes, which is the other half of painting a shape.
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"2\" x2=\"22\" y2=\"22\" stroke=\"red\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"2\" x2=\"22\" y2=\"22\" stroke=\"red\" stroke-width=\"4\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect x=\"4\" y=\"4\" width=\"8\" height=\"8\" fill=\"gold\" stroke=\"navy\" stroke-width=\"2\"/></svg>",
    "<svg viewBox=\"0 0 24 24\" stroke=\"red\" stroke-width=\"2\"><g stroke-width=\"4\"><line x1=\"2\" y1=\"2\" x2=\"22\" y2=\"2\"/></g></svg>",
    "<svg viewBox=\"0 0 24 24\"><polyline points=\"2,2 12,2 12,12\" fill=\"none\" stroke=\"red\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"square\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><polyline points=\"2,22 12,2 22,22\" fill=\"none\" stroke=\"red\" stroke-width=\"2\" stroke-miterlimit=\"1\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"12\" x2=\"22\" y2=\"12\" stroke=\"red\" stroke-width=\"2\" stroke-dasharray=\"4 2\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"12\" x2=\"22\" y2=\"12\" stroke=\"red\" stroke-width=\"2\" stroke-dasharray=\"4\" stroke-dashoffset=\"2\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"12\" x2=\"22\" y2=\"12\" stroke=\"red\" stroke-dasharray=\"-4 2\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"12\" x2=\"22\" y2=\"12\" stroke=\"red\" stroke-dasharray=\"0 0\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line x1=\"2\" y1=\"12\" x2=\"22\" y2=\"12\" stroke=\"red\" stroke-dasharray=\"none\"/></svg>",
    // A stroke under a transform, which takes a different route through the
    // rasterizer depending on whether the matrix is a similarity.
    "<svg viewBox=\"0 0 24 24\"><g transform=\"scale(2)\"><line x1=\"1\" y1=\"1\" x2=\"9\" y2=\"9\" stroke=\"red\"/></g></svg>",
    "<svg viewBox=\"0 0 24 24\"><g transform=\"scale(3,1)\"><line x1=\"1\" y1=\"1\" x2=\"7\" y2=\"9\" stroke=\"red\" stroke-width=\"2\"/></g></svg>",
    "<svg viewBox=\"0 0 24 24\"><g transform=\"skewX(20)\"><line x1=\"1\" y1=\"1\" x2=\"7\" y2=\"9\" stroke=\"red\" stroke-width=\"2\"/></g></svg>",
    "<svg viewBox=\"0 0 24 24\"><g transform=\"scale(0)\"><line x1=\"1\" y1=\"1\" x2=\"7\" y2=\"9\" stroke=\"red\" stroke-width=\"2\"/></g></svg>",
    // Stroke styles that have to be refused.
    "<svg viewBox=\"0 0 24 24\"><line stroke=\"red\" stroke-linecap=\"ROUND\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line stroke=\"red\" stroke-linejoin=\"bogus\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><line stroke=\"red\" stroke-miterlimit=\"wide\"/></svg>",
    // The document's own size, and the units a length is written in.
    "<svg width=\"64\" height=\"32\" viewBox=\"0 0 16 16\"><rect x=\"2\" y=\"2\" width=\"4\" height=\"4\"/></svg>",
    "<svg width=\"48\" height=\"24\"><rect x=\"4\" y=\"4\" width=\"16\" height=\"16\"/></svg>",
    "<svg width=\"100%\" height=\"100%\" viewBox=\"0 0 24 24\"><rect width=\"8\" height=\"8\"/></svg>",
    "<svg width=\"4cm\" height=\"2cm\" viewBox=\"0 0 16 8\"><rect width=\"8\" height=\"4\"/></svg>",
    "<svg width=\"96pt\" height=\"1in\" viewBox=\"0 0 16 8\"><rect width=\"8\" height=\"4\"/></svg>",
    "<svg viewBox=\"0 0 200 100\"><rect width=\"1in\" height=\"6pc\"/><rect x=\"2.54cm\" width=\"25.4mm\" height=\"72pt\"/></svg>",
    "<svg viewBox=\"0 0 200 100\"><rect width=\"50%\" height=\"10%\"/><circle cx=\"50%\" cy=\"70%\" r=\"10%\"/></svg>",
    // Units this reader refuses, and sizes it cannot work out.
    "<svg viewBox=\"0 0 24 24\"><rect width=\"10em\" height=\"4\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"10ex\" height=\"4\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect width=\"10 px\" height=\"4\"/></svg>",
    "<svg><rect width=\"4\" height=\"4\"/></svg>",
    "<svg width=\"0\" height=\"0\"><rect width=\"4\" height=\"4\"/></svg>",
    // preserveAspectRatio, in every shape it comes in.
    "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"none\"><rect width=\"10\" height=\"5\"/></svg>",
    "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"xMinYMax slice\"><rect width=\"10\" height=\"5\"/></svg>",
    "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"defer xMaxYMin meet\"><rect width=\"10\" height=\"5\"/></svg>",
    "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"XMidYMid\"><rect width=\"10\" height=\"5\"/></svg>",
    "<svg width=\"80\" height=\"40\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"bogus\"><rect width=\"10\" height=\"5\"/></svg>",
    // Entity references in an attribute value, which the XML reader hands
    // back raw. The parsed values go through a buffer and the borrowed ones
    // through an allocator, so both routes want exercising.
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&#90;\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&#x5A;\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"&#56;\" height=\"8\" fill=\"&#114;ed\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><polygon points=\"0,0 8,0 8,&#56;\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-dasharray=\"&#52; 2\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" transform=\"translate(&#48;,0)\"/></svg>",
    // References that have to be refused rather than drawn as text.
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"&nosuch;\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&nosuch;\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&#\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0&amp;&lt;&gt;&apos;&quot;\"/></svg>",
    // `<use>`, which is the first thing here that can name something
    // elsewhere in the document -- and so the first that can name itself.
    "<svg viewBox=\"0 0 8 8\"><defs><rect id=\"r\" width=\"4\" height=\"4\"/></defs><use href=\"#r\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><use href=\"#r\" x=\"2\" y=\"2\"/><defs><rect id=\"r\" width=\"4\" height=\"4\"/></defs></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><g id=\"g\"><rect width=\"2\" height=\"2\"/><circle r=\"1\"/></g></defs><use href=\"#g\"/><use href=\"#g\" x=\"4\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><rect id=\"a\" width=\"2\" height=\"2\"/><use id=\"b\" href=\"#a\" x=\"1\"/></defs><use href=\"#b\" x=\"2\"/></svg>",
    "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\" viewBox=\"0 0 8 8\"><defs><rect id=\"r\" width=\"4\" height=\"4\"/></defs><use xlink:href=\"#r\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect id=\"h\" width=\"4\" height=\"4\"/><use href=\"#h\" x=\"4\"/></svg>",
    // References that have to be refused, and the loops that have to be
    // noticed rather than followed.
    "<svg viewBox=\"0 0 8 8\"><use href=\"#nothing\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><use/></svg>",
    "<svg viewBox=\"0 0 8 8\"><use href=\"other.svg#a\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><use href=\"#\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g id=\"loop\"><use href=\"#loop\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g id=\"a\"><g id=\"b\"><use href=\"#a\"/></g></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><use id=\"self\" href=\"#self\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><path id=\"dup\" d=\"M0 0Z\"/><path id=\"dup\" d=\"M9 9Z\"/></defs><use href=\"#dup\"/></svg>",
    // A foreign namespace, which is passed over rather than refused.
    "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:sodipodi=\"http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd\" viewBox=\"0 0 8 8\"><sodipodi:namedview id=\"nv\"/><path d=\"M0 0Z\"/></svg>",
    // Gradients, which are named the way a `<use>` names its target.
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><radialGradient id=\"g\" fx=\"0.2\" fy=\"0.3\"><stop offset=\"0\"/><stop offset=\"1\" stop-color=\"teal\"/></radialGradient></defs><circle cx=\"4\" cy=\"4\" r=\"4\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" x2=\"8\"><stop offset=\"0\"/><stop offset=\"1\" stop-color=\"red\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\" gradientTransform=\"rotate(45)\"><stop offset=\"0\"/><stop offset=\"1\" stop-color=\"red\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"b\"><stop offset=\"0\"/><stop offset=\"1\" stop-color=\"red\"/></linearGradient><linearGradient id=\"g\" href=\"#b\" y2=\"1\"/></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\"><stop offset=\"0\"/></linearGradient></defs><rect width=\"8\" height=\"8\" stroke=\"url(#g)\" stroke-width=\"2\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\"><stop offset=\"0.8\"/><stop offset=\"0.2\" stop-color=\"red\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    // Gradients with nothing in them, and references that go wrong.
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\"/></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"url(#missing)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><pattern id=\"p\"/></defs><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\" spreadMethod=\"reflect\"><stop offset=\"0\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\" gradientUnits=\"bogus\"><stop offset=\"0\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"a\" href=\"#b\"><stop offset=\"0\"/></linearGradient><linearGradient id=\"b\" href=\"#a\"/></defs><rect width=\"8\" height=\"8\" fill=\"url(#a)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\"><stop offset=\"bogus\"/></linearGradient></defs><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    // A gradient on a shape with no extent, which has no box to be fractions
    // of.
    "<svg viewBox=\"0 0 8 8\"><defs><linearGradient id=\"g\"><stop offset=\"0\"/></linearGradient></defs><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" fill=\"url(#g)\"/></svg>",
    // Elements that are still refused.
    // `<use>` naming an id the document does not have.
    "<svg viewBox=\"0 0 24 24\"><use href=\"#a\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><text x=\"1\" y=\"1\">hi</text></svg>",
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
