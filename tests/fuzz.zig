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
    // A mutated PNG header is the cheapest way to ask for a huge picture, so
    // the decode budget is as small as the canvas.
    .max_image_pixels = 1 << 12,
    .max_images = 4,
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
    /// On for everything. It was off for `render` for a while, because that is
    /// the only target reaching z2d's dashed stroke plotter, which leaked when
    /// an allocation failed part way through capping its initial polygon --
    /// found by this very mode, and enough to make it unusable here. The fork
    /// this now builds against fixes it, and carries a test of its own so it
    /// cannot come back unnoticed.
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
    "linearGradstopfetURuns%BoxpM" ++
    "clip-pathruevnodmaskfilter" ++
    "maskUnitContbjeBoudgxywh-typelumnac" ++
    "patternUnitsContTransfombjeBox" ++
    "textfon-amilysizewghtylanchormddlbup" ++
    "emx0.5" ++
    "textPathstOf%" ++
    "style:;!importan" ++
    "filterGausinBlurOfetMrgNodFlvyUS" ++
    "<style>{}#.*~|[]=:,>+/**/!important " ++
    "imagehrefdata:;base64,/pngjpegwebpgifsvg+xmlimage-renderingoptimizeSpeedpixelatedauto" ++
    "iVBORw0KGgoAAAANSUhEUgIDATIEND+/=" ++
    "displaynoneinlinevisibilityhiddencollapsevisible" ++
    "switchsystemLanguagerequiredExtensionsrequiredFeaturesen-USfr," ++
    "symboloverflowvisiblehiddenauto" ++
    "paint-orderstrokefillmarkersnormal" ++
    "markermarker-startmarker-midmarker-endurl(#)orientauto-start-reverseturnradgraddeg" ++
    "markerUnitsstrokeWidthuserSpaceOnUsemarkerWidthmarkerHeightrefXrefY" ++
    "feColorMatrixtypevaluessaturatehueRotateluminanceToAlphamatrix" ++
    "feComponentTransferfeFuncRfeFuncGfeFuncBfeFuncAtableValuestablediscretelineargammaidentityslopeinterceptamplitudeexponentoffset" ++
    "feCompositein2operatoroverinoutatopxorlighterarithmetick1k2k3k4" ++
    "feBlendmodenormalmultiplyscreendarkenlightenoverlaycolor-dodgecolor-burnhard-lightsoft-lightdifferenceexclusionhuesaturationcolorluminosity" ++
    "feTilefeMorphologyradiuserodedilate" ++
    "feConvolveMatrixorderkernelMatrixdivisorbiastargetXtargetYedgeModeduplicatewrapnonepreserveAlphatruefalse" ++
    "feDisplacementMapscalexChannelSelectoryChannelSelectorRGBA" ++
    "feTurbulencebaseFrequencynumOctavesseedstitchTilesstitchnoStitchfractalNoiseturbulence" ++
    "feDiffuseLightingfeSpecularLightingsurfaceScalediffuseConstantspecularConstantspecularExponentlighting-color" ++
    "feDistantLightazimuthelevationfePointLightxyzfeSpotLightpointsAtXpointsAtYpointsAtZlimitingConeAngle" ++
    "feDropShadowdxdystdDeviationflood-colorflood-opacity" ++
    "feImagehrefxlink:hrefpreserveAspectRatioimage-renderingoptimizeSpeed#" ++
    "blur(drop-shadow(grayscale(sepia(saturate(hue-rotate(invert(opacity(brightness(contrast(url(#)%pxdegturnradgrad" ++
    "writing-modehorizontal-tbvertical-rltblr-tbdirectionrtlltrunicode-bidinormalbidi-override" ++
    "letter-spacingword-spacingnormalem";

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
    var open_groups: usize = 0;
    while (try shapes.next()) |item| {
        const shape = switch (item) {
            .shape => |sh| sh,
            // Every group the walk opens has to be closed again, or the
            // renderer's surface stack never comes back down.
            .open_group => {
                open_groups += 1;
                continue;
            },
            .close_group => {
                if (open_groups == 0) return error.GroupClosedWithoutOpening;
                open_groups -= 1;
                continue;
            },
            // A picture carries a URL it borrows and a rectangle, and the
            // same promises hold of both: the URL is the tree's, not the
            // source's, and every number is one the rasterizer can use. A
            // size, when there is one, is positive -- the walk drops an
            // `<image>` whose size is zero rather than yielding it.
            .image => |im| {
                seen += 1;
                const inside = @intFromPtr(im.href.ptr) >= @intFromPtr(src.ptr) and
                    @intFromPtr(im.href.ptr) < @intFromPtr(src.ptr) + src.len;
                try testing.expect(!inside);
                try testing.expect(im.href.len != 0);
                try expectUsable(im.x);
                try expectUsable(im.y);
                if (im.width) |w| {
                    try expectUsable(w);
                    try testing.expect(w > 0);
                }
                if (im.height) |h| {
                    try expectUsable(h);
                    try testing.expect(h > 0);
                }
                try testing.expect(im.opacity >= 0.0 and im.opacity <= 1.0);
                continue;
            },
        };
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
    try testing.expectEqual(@as(usize, 0), open_groups);
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
    // A container's `opacity`, which needs a layer of its own -- so the walk
    // has to open and close one, and the renderer has to balance a stack of
    // surfaces.
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"0.5\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\" opacity=\"0.5\"><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"0.5\"><g opacity=\"0.5\"><rect width=\"8\" height=\"8\"/></g></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"0.5\"/><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"0\"><rect width=\"8\" height=\"8\"/></g><rect width=\"2\" height=\"2\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"1\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"bogus\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g opacity=\"0.5\" transform=\"rotate(20)\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><g id=\"g\" opacity=\"0.5\"><rect width=\"4\" height=\"4\"/></g></defs><use href=\"#g\"/><use href=\"#g\" x=\"4\"/></svg>",
    // `clip-path`, which needs a layer and a mask built from somewhere else
    // in the document.
    "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\"><circle cx=\"4\" cy=\"4\" r=\"3\"/></clipPath></defs><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\"><rect width=\"4\" height=\"8\"/><rect x=\"4\" y=\"4\" width=\"4\" height=\"4\"/></clipPath></defs><g clip-path=\"url(#c)\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\"><path d=\"M0 0H8V8H0ZM2 2H6V6H2Z\" clip-rule=\"evenodd\"/></clipPath></defs><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\"><rect width=\"4\" height=\"4\" transform=\"rotate(20)\"/></clipPath></defs><g clip-path=\"url(#c)\" opacity=\"0.5\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\"/></defs><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" clip-path=\"none\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" clip-path=\"url(#missing)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><rect id=\"r\" width=\"4\" height=\"4\"/></defs><rect width=\"8\" height=\"8\" clip-path=\"url(#r)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\" clipPathUnits=\"objectBoundingBox\"><rect width=\"0.5\" height=\"1\"/></clipPath></defs><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><clipPath id=\"c\" clipPathUnits=\"objectBoundingBox\"><circle cx=\"0.5\" cy=\"0.5\" r=\"0.4\"/></clipPath><g clip-path=\"url(#c)\"><rect width=\"4\" height=\"8\"/><rect x=\"4\" width=\"4\" height=\"4\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><clipPath id=\"a\"><rect width=\"8\" height=\"4\"/></clipPath><clipPath id=\"c\" clip-path=\"url(#a)\"><rect width=\"4\" height=\"8\"/></clipPath><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    // `<mask>`, which draws its content as a picture and takes its luminance
    // -- so every path the renderer has runs inside one too, which is what
    // makes these worth mutating rather than just the shapes above.
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><rect width=\"8\" height=\"8\" fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" maskUnits=\"userSpaceOnUse\" x=\"1\" y=\"1\" width=\"4\" height=\"4\"><circle cx=\"4\" cy=\"4\" r=\"4\" fill=\"#808080\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" maskContentUnits=\"objectBoundingBox\"><rect width=\"0.5\" height=\"1\" fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"black\"/><stop offset=\"1\" stop-color=\"white\"/></linearGradient><mask id=\"m\"><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></mask><g mask=\"url(#m)\" opacity=\"0.5\"><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"a\"><rect width=\"8\" height=\"4\" fill=\"white\"/></mask><mask id=\"m\" mask=\"url(#a)\"><rect width=\"4\" height=\"8\" fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    // A mask that masks itself, and a clip that clips itself: bounded by
    // `Limits.max_mask_depth` rather than by the walk, which sees no cycle.
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask=\"url(#m)\"><rect width=\"8\" height=\"8\" fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><clipPath id=\"c\" clip-path=\"url(#c)\"><rect width=\"8\" height=\"8\"/></clipPath><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    // The nastier shape of the same thing: the recursion is through what the
    // mask *draws* rather than through a `mask` attribute, so the walk sees no
    // cycle and each level is a perfectly finite document on its own.
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><use href=\"#r\"/></mask><rect id=\"r\" width=\"8\" height=\"8\" fill=\"white\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><g><rect width=\"8\" height=\"8\" fill=\"white\" mask=\"url(#m)\"/></g></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><rect width=\"8\" height=\"8\" fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\" clip-path=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" x=\"0\" y=\"0\" width=\"0\" height=\"0\"><rect width=\"8\" height=\"8\" fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    // `<pattern>`, which draws its content once per cell of a lattice and
    // cuts each to its tile. Every path the renderer has runs inside one.
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"><rect width=\"2\" height=\"2\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"0.5\" height=\"0.5\"><circle cx=\"1\" cy=\"1\" r=\"1\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\" patternTransform=\"rotate(30)\"><rect width=\"2\" height=\"2\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\" viewBox=\"0 0 2 2\"><rect width=\"1\" height=\"1\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    // Content that leaves its tile, which is the case that needs the clip.
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"><circle cx=\"3\" cy=\"3\" r=\"3\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    // A pattern on a stroke, which covers the stroked outline instead.
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"2\" height=\"2\" patternUnits=\"userSpaceOnUse\"><rect width=\"1\" height=\"1\"/></pattern><circle cx=\"4\" cy=\"4\" r=\"3\" fill=\"none\" stroke=\"url(#p)\" stroke-width=\"2\"/></svg>",
    // A tile with no extent, a pattern with nothing in it, and a reference
    // that goes round in a circle.
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"0\" height=\"4\" patternUnits=\"userSpaceOnUse\"><rect width=\"2\" height=\"2\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"/><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"a\" href=\"#b\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"/><pattern id=\"b\" href=\"#a\"><rect width=\"2\" height=\"2\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#a)\"/></svg>",
    // A pattern whose tile is small enough that the lattice runs past
    // `Limits.max_pattern_tiles`.
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"0.0001\" height=\"0.0001\" patternUnits=\"userSpaceOnUse\"><rect width=\"1\" height=\"1\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    // A pattern that paints itself, and one inside a mask: both are recursion
    // the walk cannot see, because each level is a finite document on its own.
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"><rect width=\"4\" height=\"4\" fill=\"url(#p)\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"><rect width=\"2\" height=\"2\" fill=\"white\"/></pattern><mask id=\"m\"><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    // `<text>`. No font reaches the fuzzer, so every one of these ends in
    // `NoFontSupplied` -- which is the point: what is being exercised is the
    // reading, the whitespace collapsing and the family walk, all of which
    // happen before a face is ever asked for.
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-size=\"6\">hi</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-size=\"6\" font-family=\"'A B', C , D\">hi</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"4\" y=\"6\" font-size=\"6\" text-anchor=\"middle\">hi</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-weight=\"700\" font-style=\"italic\">hi</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><g font-size=\"5\" font-family=\"X\"><text x=\"1\" y=\"6\">hi</text></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\">   spaced\n   out   </text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\"></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-size=\"0\">hi</text></svg>",
    // `<tspan>`: a `<text>` is a sequence of runs sharing a pen, so these
    // exercise the walk's interleaving of character data and markup.
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\">a<tspan>b</tspan>c</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\">a<tspan x=\"4\" y=\"7\">b</tspan>c</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\">a<tspan dx=\"2\" dy=\"-1\">b</tspan></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-size=\"4\">a<tspan font-size=\"2\" fill=\"red\">b</tspan></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"4\" y=\"6\" text-anchor=\"middle\">a<tspan>bc</tspan></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\">\n  <tspan>a</tspan>\n  <tspan>b</tspan>\n</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\"><tspan><tspan>deep</tspan></tspan></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\"><tspan/></text></svg>",
    // `rotate` and `textLength`, which place glyphs one at a time.
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" rotate=\"30\">ab</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" rotate=\"0 30 -30\">abcd</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" rotate=\"\">ab</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" rotate=\"0 wobbly\">ab</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" textLength=\"4\">ab</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" textLength=\"0\">ab</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" textLength=\"4\">a</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"4\" y=\"6\" text-anchor=\"end\" textLength=\"4\">ab</text></svg>",
    // Still refused: the ones that would need the pen to leave a straight
    // line, or would put the angles on the wrong letters.
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" rotate=\"30\">a<tspan>b</tspan></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" textLength=\"4\" lengthAdjust=\"spacingAndGlyphs\">ab</text></svg>",
    // `<textPath>`, which lays a run along a shape.
    "<svg viewBox=\"0 0 8 8\"><path id=\"c\" d=\"M1 6 Q4 1 7 6\"/><text font-size=\"3\"><textPath href=\"#c\">ab</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><path id=\"c\" d=\"M1 6 L7 6\"/><text font-size=\"3\"><textPath href=\"#c\" startOffset=\"2\">ab</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><path id=\"c\" d=\"M1 6 L7 6\"/><text font-size=\"3\"><textPath href=\"#c\" startOffset=\"50%\">ab</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><path id=\"c\" d=\"M1 6 L7 6\"/><text font-size=\"3\"><textPath href=\"#c\">far too long to fit on it</textPath></text></svg>",
    // A path with no length, a second subpath, and a reference to something
    // with no geometry at all.
    "<svg viewBox=\"0 0 8 8\"><path id=\"c\" d=\"M1 6 L1 6\"/><text font-size=\"3\"><textPath href=\"#c\">ab</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><path id=\"c\" d=\"M1 6 L7 6 M1 1 L7 1\"/><text font-size=\"3\"><textPath href=\"#c\">ab</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><g id=\"c\"/><text font-size=\"3\"><textPath href=\"#c\">ab</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\"><textPath href=\"#p\">a</textPath></text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\"><textPath>a</textPath></text></svg>",
    // Text as a clip path, and text inside a pattern: both reach the builder
    // by a route that is not the ordinary fill.
    "<svg viewBox=\"0 0 8 8\"><clipPath id=\"c\"><text x=\"1\" y=\"6\" font-size=\"6\">c</text></clipPath><rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"><text x=\"0\" y=\"3\" font-size=\"3\">x</text></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    // `em` and `ex`, whose whole subtlety is the order: `em` in `font-size`
    // is the parent's size and `em` in anything else is this element's.
    "<svg viewBox=\"0 0 8 8\"><g font-size=\"4\"><rect width=\"1em\" height=\"1ex\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><g font-size=\"4\"><rect font-size=\"2em\" width=\"1em\" height=\"1\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"1em\" height=\"1\"/></svg>",
    "<svg viewBox=\"0 0 8 8\" font-size=\"2em\"><rect width=\"1\" height=\"1\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g font-size=\"0\"><rect width=\"1em\" height=\"1\"/></g></svg>",
    // §6's `<style>`: selectors, the cascade, and the ways a stylesheet can
    // be malformed.
    "<svg viewBox=\"0 0 8 8\"><style>rect{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>.a{fill:red}#b{fill:blue}*{stroke:lime}</style><rect id=\"b\" class=\"a\" width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>g rect{fill:red}g>rect{fill:blue}text+rect{fill:lime}text~rect{fill:teal}</style><g><rect width=\"8\" height=\"8\"/></g></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect[a]{fill:red}rect[a=\"b\"]{fill:blue}rect[a~=b]{fill:lime}rect[a|=b]{fill:teal}</style><rect a=\"b\" width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect{fill:red!important}</style><rect width=\"8\" height=\"8\" style=\"fill:blue\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>/* c */rect/* c */{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style><![CDATA[rect{fill:red}]]></style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect{fill:red}</style><style>rect{fill:blue}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style type=\"text/css\">rect{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style type=\"text/plain\">rect{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>stop{stop-color:red}</style><linearGradient id=\"g\"><stop offset=\"0\"/><stop offset=\"1\"/></linearGradient><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    // What a stylesheet can be that is not one.
    "<svg viewBox=\"0 0 8 8\"><style></style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect{fill:red</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect>{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect:first-child{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>@media screen{rect{fill:red}}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>@import url(x.css);</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>svg|rect{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect{fill:\"{\"}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style>rect{fill:wobble}</style><rect width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><style media=\"print\">rect{fill:red}</style><rect width=\"8\" height=\"8\"/></svg>",
    // §15's `<filter>`: the region, the primitives, and the ways a chain can
    // be wired up.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"1\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"2 0\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\" filterUnits=\"userSpaceOnUse\" x=\"1\" y=\"1\" width=\"4\" height=\"4\"><feGaussianBlur stdDeviation=\"1\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\" primitiveUnits=\"objectBoundingBox\"><feGaussianBlur stdDeviation=\"0.1\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feOffset dx=\"2\" dy=\"-1\"/></filter><rect width=\"4\" height=\"4\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feFlood flood-color=\"red\" flood-opacity=\"0.5\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feFlood flood-color=\"currentColor\"/></filter><rect width=\"8\" height=\"8\" color=\"lime\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"1\" result=\"b\"/>" ++
        "<feOffset in=\"b\" dx=\"1\" dy=\"1\" result=\"o\"/><feMerge><feMergeNode in=\"o\"/><feMergeNode in=\"SourceGraphic\"/></feMerge></filter>" ++
        "<rect width=\"6\" height=\"6\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\" color-interpolation-filters=\"sRGB\"><feGaussianBlur stdDeviation=\"1\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"1\" color-interpolation-filters=\"sRGB\"/><feOffset dx=\"1\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feFlood x=\"1\" y=\"1\" width=\"2\" height=\"2\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"1\" x=\"2\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g filter=\"url(#f)\"><rect width=\"4\" height=\"4\"/></g><filter id=\"f\"><feGaussianBlur stdDeviation=\"1\"/></filter></svg>",
    // The shapes a filter reference can be in, well-formed and not.
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" filter=\"url(#gone)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"/><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feTurbulence/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"-1\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feOffset in=\"nothing\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"1e9\"/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"a\" href=\"#b\"/><filter id=\"b\" href=\"#a\"><feOffset/></filter><rect width=\"8\" height=\"8\" filter=\"url(#a)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feMerge/></filter><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    // §6.3's `style`, which is the same properties written the other way and
    // outranking the attributes.
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:red\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"red\" style=\"fill:blue\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:red;stroke:blue;stroke-width:2;opacity:0.5\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g style=\"fill:red\"><rect width=\"8\" height=\"8\"/></g></svg>",
    // The shapes a declaration block can be in, well-formed and not.
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\";;;\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"nonsense;fill:red\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:red !important\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:url(#g);stroke:none\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" style=\"fill:wobble\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" style=\"font-size:4;text-anchor:middle\">a</text></svg>",
    // Text properties that are not values at all.
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" text-anchor=\"centre\">hi</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-weight=\"heavy\">hi</text></svg>",
    "<svg viewBox=\"0 0 8 8\"><text x=\"1\" y=\"6\" font-style=\"slanted\">hi</text></svg>",
    // Still refused: a filter, and units that are neither of the two.
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" mask=\"none\" filter=\"none\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" maskUnits=\"nope\"><rect width=\"8\" height=\"8\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask-type=\"alpha\"><rect width=\"8\" height=\"8\" fill=\"#ff0000\" fill-opacity=\"0.5\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask-type=\"nope\"><rect width=\"8\" height=\"8\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" patternUnits=\"nope\" width=\"4\" height=\"4\"><rect width=\"2\" height=\"2\"/></pattern><rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    // A definition written outside `<defs>`, which is not drawn where it
    // stands and used to be refused for standing there.
    "<svg viewBox=\"0 0 8 8\"><linearGradient id=\"g\"><stop offset=\"0\"/></linearGradient><rect width=\"8\" height=\"8\" fill=\"url(#g)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><symbol id=\"s\"><rect width=\"4\" height=\"4\"/></symbol><rect width=\"8\" height=\"8\"/></svg>",
    // Elements that are still refused.
    // `<use>` naming an id the document does not have.
    "<svg viewBox=\"0 0 24 24\"><use href=\"#a\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><text x=\"1\" y=\"1\">hi</text></svg>",
    // `<image>`: a picture in each of three formats, placed, fitted and
    // sampled every way the element allows, and the refusals.
    "<svg viewBox=\"0 0 8 8\"><image href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42gXBAQEAAACAEP9PFyIJBQM/0gX7Pk0ZHwAAAABJRU5ErkJggg==\" width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><image href=\"data:image/webp;base64,UklGRhwAAABXRUJQVlA4TBAAAAAvAUAAAAdQwOh//wMR0f8A\" x=\"1\" width=\"4\" preserveAspectRatio=\"xMinYMax slice\" transform=\"rotate(20)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\" image-rendering=\"optimizeSpeed\"><image href=\"data:image/gif;base64,R0lGODdhAgACAIEAAP//AAAAAAAAAAAAACwAAAAAAgACAAAIBgABCAQQEAA7\" opacity=\"0.5\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><defs><image id=\"i\" href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42gXBAQEAAACAEP9PFyIJBQM/0gX7Pk0ZHwAAAABJRU5ErkJggg==\" height=\"3\"/></defs><use href=\"#i\"/><use href=\"#i\" x=\"4\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><image href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42gXBAQEAAACAEP9PFyIJBQM/0gX7Pk0ZHwAAAABJRU5ErkJggg==\" width=\"8\" height=\"8\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><image href=\"data:image/svg+xml,&lt;svg/>\" width=\"8\" height=\"8\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><image href=\"picture.png\" width=\"8\" height=\"8\"/></svg>",
    // `display` and `visibility`: hidden things are not read, hidden ones
    // are laid out and not painted.
    "<svg viewBox=\"0 0 8 8\"><g display=\"none\"><foo/><rect width=\"8\" height=\"8\"/></g><rect width=\"4\" height=\"4\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g visibility=\"hidden\"><rect width=\"8\" height=\"8\"/><rect width=\"4\" height=\"4\" visibility=\"visible\"/></g></svg>",
    // `<a>`, and the whitespace between runs, which belongs to the element.
    "<svg viewBox=\"0 0 8 8\"><a href=\"#x\"><rect width=\"4\" height=\"4\"/></a><text> a <a>b</a><tspan> </tspan>c </text></svg>",
    // `<switch>` and the conditional attributes.
    "<svg viewBox=\"0 0 8 8\"><switch><foreignObject requiredExtensions=\"x\"/><rect systemLanguage=\"fr\" width=\"8\" height=\"8\"/><rect systemLanguage=\"en-US\" width=\"4\" height=\"4\"/></switch></svg>",
    // Viewports: a nested `<svg>`, and a `<symbol>` through a `<use>`.
    "<svg viewBox=\"0 0 8 8\"><svg x=\"1\" width=\"50%\" height=\"4\" viewBox=\"0 0 2 1\" preserveAspectRatio=\"xMinYMid slice\"><rect width=\"50%\" height=\"1\"/></svg></svg>",
    "<svg viewBox=\"0 0 8 8\"><symbol id=\"s\" viewBox=\"0 0 1 1\" overflow=\"visible\"><rect width=\"1\" height=\"1\"/></symbol><use href=\"#s\" width=\"4\" height=\"4\" opacity=\"0.5\"/></svg>",
    // `paint-order`, on a shape and on a run of text.
    "<svg viewBox=\"0 0 8 8\"><rect width=\"4\" height=\"4\" stroke=\"red\" style=\"paint-order: stroke\"/><text style=\"paint-order: markers stroke\" stroke=\"red\">a</text></svg>",
    // Markers: every placement on a path with an arc and a close, a viewBox,
    // and one reaching its own content through inheritance.
    "<svg viewBox=\"0 0 8 8\"><marker id=\"m\" viewBox=\"0 0 2 2\" refX=\"1\" refY=\"1\" orient=\"auto-start-reverse\" preserveAspectRatio=\"xMinYMin slice\"><circle cx=\"1\" cy=\"1\" r=\"1\"/></marker><path d=\"M1 1 L4 1 A2 2 0 0 1 4 5 Q1 5 1 3 Z\" stroke=\"red\" style=\"marker: url(#m)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><g style=\"marker: url(#m)\"><marker id=\"m\" markerUnits=\"userSpaceOnUse\" orient=\"0.1turn\" overflow=\"visible\"><path d=\"M0 0 L2 2\" stroke=\"blue\"/></marker><polyline points=\"1 1 4 4 7 1\"/><line x2=\"8\" y2=\"8\" marker-mid=\"none\"/></g></svg>",
    // The colour primitives: a matrix that lights up transparent pixels, and
    // every transfer function.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feColorMatrix type=\"hueRotate\" values=\"30\"/><feColorMatrix values=\"0 1 0 0 0 0 0 1 0 0 1 0 0 0 0 0 0 0 1 0.5\"/></filter><rect width=\"4\" height=\"4\" fill=\"red\" fill-opacity=\"0.5\" filter=\"url(#f)\"/></svg>",
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feComponentTransfer><feFuncR type=\"table\" tableValues=\"1 0 1\"/><feFuncG type=\"discrete\" tableValues=\"0 1\"/><feFuncB type=\"gamma\" exponent=\"2\"/><feFuncA type=\"linear\" intercept=\"0.5\"/></feComponentTransfer></filter><circle cx=\"4\" cy=\"4\" r=\"3\" fill=\"teal\" filter=\"url(#f)\"/></svg>",
    // The two-input primitives, reading a result and a source.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feOffset dx=\"1\" result=\"o\"/><feComposite in=\"SourceGraphic\" in2=\"o\" operator=\"arithmetic\" k1=\"1\" k2=\"0.5\" k3=\"0.5\" k4=\"-0.2\"/><feBlend in2=\"SourceAlpha\" mode=\"luminosity\"/></filter><rect width=\"4\" height=\"4\" fill=\"orange\" filter=\"url(#f)\"/></svg>",
    // Morphology on the alpha, then tiled from a subregion.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feMorphology in=\"SourceAlpha\" operator=\"dilate\" radius=\"1 0.5\"/><feOffset x=\"1\" y=\"1\" width=\"2\" height=\"3\"/><feTile/><feMorphology radius=\"0.3\"/></filter><circle cx=\"3\" cy=\"3\" r=\"2\" fill=\"purple\" filter=\"url(#f)\"/></svg>",
    // Convolution with an off-centre target, each edge mode in turn.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feConvolveMatrix order=\"3 2\" kernelMatrix=\"1 -1 0 2 0 -2\" targetY=\"1\" bias=\"0.3\" edgeMode=\"wrap\"/><feConvolveMatrix kernelMatrix=\"1 1 1 1 1 1 1 1 1\" edgeMode=\"none\" preserveAlpha=\"true\"/></filter><circle cx=\"4\" cy=\"4\" r=\"3\" fill=\"coral\" filter=\"url(#f)\"/></svg>",
    // Displacement by a translucent map, reading each channel.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feFlood flood-color=\"rgba(200,20,90,0.5)\" result=\"m\"/><feDisplacementMap in=\"SourceGraphic\" in2=\"m\" scale=\"3\" xChannelSelector=\"B\" yChannelSelector=\"A\"/><feDisplacementMap in2=\"SourceAlpha\" scale=\"-40\"/></filter><rect x=\"1\" y=\"1\" width=\"5\" height=\"5\" fill=\"navy\" filter=\"url(#f)\"/></svg>",
    // Noise of both kinds, stitched, under a transform, feeding a map.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"><feTurbulence type=\"fractalNoise\" baseFrequency=\"0.3 0.1\" numOctaves=\"4\" seed=\"-9.5\" stitchTiles=\"stitch\" result=\"n\"/><feTurbulence baseFrequency=\"1e9\" numOctaves=\"30\"/><feDisplacementMap in=\"SourceGraphic\" in2=\"n\" scale=\"2\"/></filter><rect width=\"6\" height=\"6\" transform=\"rotate(20) scale(0.5 2)\" filter=\"url(#f)\"/></svg>",
    // Every light, on the alpha of a shape, one of them in bounding-box
    // units, and a highlight composited back over it.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\" primitiveUnits=\"objectBoundingBox\"><feDiffuseLighting in=\"SourceAlpha\" surfaceScale=\"3\" lighting-color=\"currentColor\"><fePointLight x=\"0.2\" y=\"0.1\" z=\"0.5\"/></feDiffuseLighting></filter><filter id=\"g\"><feSpecularLighting in=\"SourceAlpha\" specularExponent=\"128\" result=\"s\"><feSpotLight x=\"1\" y=\"1\" z=\"9\" pointsAtX=\"4\" pointsAtY=\"4\" limitingConeAngle=\"-20\" specularExponent=\"-1\"/></feSpecularLighting><feComposite in=\"SourceGraphic\" in2=\"s\" operator=\"arithmetic\" k2=\"1\" k3=\"1\"/><feDiffuseLighting><feDistantLight azimuth=\"1e30\" elevation=\"-90\"/></feDiffuseLighting></filter><circle cx=\"3\" cy=\"3\" r=\"2\" color=\"red\" filter=\"url(#f)\"/><rect x=\"4\" y=\"4\" width=\"3\" height=\"3\" filter=\"url(#g)\"/></svg>",
    // A drop shadow on its own defaults, and one of the current colour.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feDropShadow/><feDropShadow in=\"SourceAlpha\" dx=\"-1e9\" stdDeviation=\"0 1\" flood-color=\"currentColor\" flood-opacity=\"0.3\"/></filter><rect width=\"4\" height=\"4\" color=\"blue\" filter=\"url(#f)\"/></svg>",
    // feImage of an element in bounding-box units, of a missing one, of the
    // element filtering itself, and of a picture.
    "<svg viewBox=\"0 0 8 8\"><defs><circle id=\"c\" cx=\"2\" cy=\"2\" r=\"2\" fill=\"red\"/></defs><filter id=\"f\" primitiveUnits=\"objectBoundingBox\"><feImage href=\"#c\" x=\"0.5\"/><feImage href=\"#none\"/><feImage href=\"#r\" result=\"r\"/><feImage href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==\" preserveAspectRatio=\"xMaxYMid slice\" width=\"2\"/></filter><rect id=\"r\" width=\"4\" height=\"4\" filter=\"url(#f)\"/></svg>",
    // Filter functions, alone and in a list with a url, in both the
    // attribute and a style.
    "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feOffset dx=\"1\"/></filter><rect width=\"4\" height=\"4\" fill=\"teal\" filter=\"sepia(50%) url(#f) hue-rotate(1rad) drop-shadow(red 1px 1px 1px)\"/><circle cx=\"6\" cy=\"6\" r=\"1\" style=\"filter: blur(0.5px) invert() opacity(0.5) contrast(3) brightness(0) url(#nothing)\"/></svg>",
    // Spacing, positive and negative, in em, anchored and along a path.
    "<svg viewBox=\"0 0 8 8\"><path id=\"p\" d=\"M0 4 Q4 0 8 4\"/><text x=\"4\" y=\"4\" font-size=\"2\" letter-spacing=\"0.3em\" word-spacing=\"-9\" text-anchor=\"middle\">a b<tspan letter-spacing=\"normal\">c d</tspan></text><text font-size=\"1\" letter-spacing=\"1e9\"><textPath href=\"#p\">e f</textPath></text></svg>",
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
