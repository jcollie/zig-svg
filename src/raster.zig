// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! From an SVG document to pixels: the reader, the path grammar and z2d's
//! rasterizer wired together.
//!
//! Two entry points. `render` makes a surface of its own and is what a program
//! wanting a picture calls. `draw` paints into a surface the caller already
//! has, at a position the caller chooses, and is what a program composing
//! several things into one image calls -- an icon above a label, say.
//!
//! Neither performs any I/O. The source is a byte slice, the result is memory,
//! and where either came from is the calling program's business. That is what
//! makes `sandbox` possible: rendering never needed a file, so a process that
//! cannot open one is still a perfectly capable renderer.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const color = @import("color.zig");
const document = @import("document.zig");
const path = @import("path.zig");

/// How much a caller is willing to spend on a picture somebody else wrote.
///
/// Every number in an SVG is a number an attacker chose, and two of them --
/// the output size and the path length -- decide how much memory and how much
/// time the render takes. The defaults are sized for a program drawing icons
/// and illustrations for a person to look at: large enough that nothing real
/// is refused, small enough that a hostile file cannot ask for a terabyte.
pub const Limits = struct {
    /// The widest picture to rasterize.
    max_width: u32 = 1 << 14,

    /// The tallest picture to rasterize.
    max_height: u32 = 1 << 14,

    /// The most pixels to rasterize, however they are arranged. This is the
    /// bound that matters: width and height can each be modest while their
    /// product is not, and it is the product that is allocated. At four bytes
    /// a pixel the default is a quarter of a gigabyte.
    max_pixels: u64 = 1 << 26,

    /// The most `z2d.Path` nodes the document's shapes may produce between
    /// them.
    ///
    /// Nodes rather than bytes of source, because the two are not
    /// proportional: `a` with a large sweep produces four cubics from a dozen
    /// characters, and repeating it is the cheapest way to write an expensive
    /// path.
    ///
    /// A budget for the whole document rather than for each shape. Per shape
    /// it would bound nothing: ten thousand `<path>` elements, each just under
    /// the limit, is the same denial of service written out longhand.
    max_path_nodes: usize = 1 << 20,

    /// The most `<path>` elements to draw.
    ///
    /// The node budget does not cover this. An empty `d` produces no nodes and
    /// still costs a fill, and a fill allocates its plotted polygons and a
    /// scanline mask however little there is to plot -- so a document of a
    /// million empty paths is bounded by this and by nothing else.
    max_shapes: usize = 1 << 12,

    /// The most source to buffer, for the callers that have to buffer it --
    /// `sandbox.render` copies the document into memory before it forks,
    /// because a sandboxed process that could still read its input would need
    /// a system call this library would rather not permit it.
    ///
    /// Unused by `render` and `draw`, which are handed a slice and never hold
    /// anything the caller did not already have.
    max_input_bytes: u64 = 1 << 24,

    /// Nothing is refused. For a program drawing files it produced itself, on
    /// a machine it is not sharing.
    pub const unlimited: Limits = .{
        .max_width = math.maxInt(u32),
        .max_height = math.maxInt(u32),
        .max_pixels = math.maxInt(u64),
        .max_path_nodes = math.maxInt(usize),
        .max_shapes = math.maxInt(usize),
        .max_input_bytes = math.maxInt(u64),
    };

    /// Refuses a picture this budget will not pay for.
    ///
    /// Zero in either dimension is refused as well: z2d surfaces start at 1×1,
    /// and a renderer that returned a zero-pixel one would hand every caller
    /// an edge case to discover for themselves.
    pub fn check(self: Limits, width: u64, height: u64) error{ ImageTooLarge, BadSize }!void {
        if (width == 0 or height == 0) return error.BadSize;
        if (width > self.max_width or height > self.max_height) return error.ImageTooLarge;
        // In u64 and so cannot overflow: both sides are already below 2^32.
        if (width * height > self.max_pixels) return error.ImageTooLarge;
    }
};

/// How to draw.
pub const Options = struct {
    /// The output size in pixels. Either left null takes that dimension from
    /// the `viewBox`, rounded up -- which is what `width` and `height` on the
    /// `<svg>` element would say if this reader read them.
    width: ?u32 = null,
    height: ?u32 = null,

    /// What to paint a shape that names no colour of its own, and what
    /// `fill="currentColor"` resolves to.
    ///
    /// SVG's initial `fill` is black, and so is this -- but a shape whose
    /// document says nothing is painted in *this* colour rather than in black,
    /// which is a deliberate difference. Not one of the 7,447 Material Design
    /// Icons carries a `fill`, so under the letter of the specification the
    /// set could only ever be drawn black; this is what lets a caller draw one
    /// in any colour they like. A document that does name a colour is drawn in
    /// the colour it names.
    ///
    /// An `rgba` or `argb` pixel must be premultiplied, which z2d checks and
    /// refuses.
    fill: z2d.Pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },

    /// What to clear the surface to before drawing. Null leaves it at the
    /// pixel type's zero value, which for `rgba` is transparent and for `rgb`
    /// is black.
    ///
    /// Ignored by `draw`, which never clears a surface it did not make.
    background: ?z2d.Pixel = null,

    /// The surface to make. The default carries an alpha channel, because an
    /// icon that cannot be transparent is not much of an icon.
    ///
    /// Overridden by `background` when there is one: a surface cleared to a
    /// pixel takes its type from that pixel, so naming both and having them
    /// disagree would mean silently ignoring one of them.
    surface_type: z2d.surface.SurfaceType = .image_surface_rgba,

    /// The rule for a shape whose document names none. SVG's initial
    /// `fill-rule` is `nonzero`, and so is this.
    fill_rule: z2d.options.FillRule = .non_zero,

    anti_aliasing_mode: z2d.options.AntiAliasMode = .default,
    tolerance: f64 = z2d.options.default_tolerance,

    limits: Limits = .{},
};

/// Everything a render can fail with.
pub const Error = document.Error || path.BuildError || z2d.painter.FillError || error{
    /// The picture is larger than `Limits` permits.
    ImageTooLarge,
    /// A width or height of zero, whether asked for or taken from the viewBox.
    BadSize,
    /// The document has more `<path>` elements than `Limits.max_shapes`.
    TooManyShapes,
};

/// Where in a surface to draw, in pixels.
pub const Box = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64,
    height: f64,
};

/// Render `src` into a surface of its own.
///
/// The caller owns the surface and releases it with `z2d.Surface.deinit`.
pub fn render(gpa: Allocator, src: []const u8, opts: Options) Error!z2d.Surface {
    const doc = try document.read(src);

    // The viewBox is the default size, which is the one thing about the
    // picture the document does say. Rounded up, because half a pixel of a
    // drawing is still a pixel of the drawing.
    const width = opts.width orelse fitDimension(doc.view_box.width);
    const height = opts.height orelse fitDimension(doc.view_box.height);
    try opts.limits.check(width, height);

    var surface = if (opts.background) |px|
        try z2d.Surface.initPixel(px, gpa, @intCast(width), @intCast(height))
    else
        try z2d.Surface.init(opts.surface_type, gpa, @intCast(width), @intCast(height));
    errdefer surface.deinit(gpa);

    try drawDocument(gpa, &surface, doc, .{
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    }, opts);

    return surface;
}

/// Render `src` into a surface the caller already has, inside `box`.
///
/// The surface is not cleared: whatever is already there is drawn over, which
/// is the point -- this is how an icon goes on top of a background somebody
/// else painted.
pub fn draw(
    gpa: Allocator,
    surface: *z2d.Surface,
    src: []const u8,
    box: Box,
    opts: Options,
) Error!void {
    return drawDocument(gpa, surface, try document.read(src), box, opts);
}

/// The half of `draw` that has the document already, so that `render` does not
/// parse the XML twice to find out how large to make its surface.
///
/// Each `<path>` is built and filled on its own, in document order, which is
/// SVG's painting model: a shape is painted over whatever is already there.
///
/// Filling them separately is not the same as building them into one path and
/// filling that once, which would be cheaper. Two overlapping subpaths wound
/// in opposite directions leave a hole under the nonzero rule; painted as two
/// shapes the second simply covers the first. Merging them would quietly
/// choose the first answer for a document that means the second.
fn drawDocument(
    gpa: Allocator,
    surface: *z2d.Surface,
    doc: document.Document,
    box: Box,
    opts: Options,
) Error!void {
    if (doc.shape_count > opts.limits.max_shapes) return error.TooManyShapes;

    const transform = doc.transformFor(box.x, box.y, box.width, box.height);

    // Spent down across the whole document rather than reset per shape. See
    // `Limits.max_path_nodes`.
    var nodes_left = opts.limits.max_path_nodes;

    var shapes = doc.paths();
    while (try shapes.next()) |shape| {
        const paint = resolve(shape, opts) orelse continue;

        var p: z2d.Path = .empty;
        defer p.deinit(gpa);

        try document.buildShape(&p, gpa, shape.d, transform, .{ .max_nodes = nodes_left });
        nodes_left -= p.nodes.items.len;

        // An empty `d` is a shape that draws nothing, which is not an error;
        // `painter.fill` would take it too, but this says so on purpose.
        if (p.nodes.items.len == 0) continue;

        const source: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = paint } };
        try z2d.painter.fill(gpa, surface, &source, p.nodes.items, .{
            .fill_rule = shape.fill_rule orelse opts.fill_rule,
            .anti_aliasing_mode = opts.anti_aliasing_mode,
            .tolerance = opts.tolerance,
        });
    }
}

/// The pixel one shape is painted with, or null when it is not painted at all.
///
/// Three alphas multiply together: the colour's own, from `#rrggbbaa` or
/// `rgba()`; `fill-opacity`; and `opacity`. For a shape that has a fill and
/// nothing else, multiplying `opacity` in like this is exactly what
/// compositing the shape as its own layer would produce -- which is why
/// `opacity` on a `<path>` is implemented and `opacity` on the root `<svg>`,
/// where shapes could overlap, is refused by the reader instead.
fn resolve(shape: document.Shape, opts: Options) ?z2d.Pixel {
    const alpha = (shape.fill_opacity orelse 1.0) * shape.opacity;
    if (alpha <= 0) return null;

    // A shape that named no `fill` is treated as though it had named
    // `currentColor`, which lands on the caller's colour by the same route --
    // `color`'s initial value is the caller's choice. The two spellings are
    // the same picture, and the icon sets in the world use one or the other.
    const named: ?color.Color = switch (shape.fill orelse .current) {
        .none => return null,
        .color => |c| c,
        .current => shape.current_color,
    };

    if (named) |c| return fadeColor(c, alpha);
    return fadePixel(opts.fill, alpha);
}

/// A parsed colour as a premultiplied pixel, faded by `alpha`.
fn fadeColor(c: color.Color, alpha: f64) ?z2d.Pixel {
    const a = c.alpha * alpha;
    if (a <= 0) return null;
    return .{ .rgba = .fromClamped(
        @as(f64, @floatFromInt(c.r)) / 255.0,
        @as(f64, @floatFromInt(c.g)) / 255.0,
        @as(f64, @floatFromInt(c.b)) / 255.0,
        a,
    ) };
}

/// The caller's own pixel, faded by `alpha`.
///
/// Returned exactly as given when there is nothing to fade, so that a caller
/// who named an `rgb` pixel keeps it: widening every fill to `rgba` would make
/// z2d composite where it could have copied, for no visible difference.
fn fadePixel(px: z2d.Pixel, alpha: f64) ?z2d.Pixel {
    if (alpha >= 1.0) return px;
    if (alpha <= 0) return null;
    const straight = z2d.pixel.RGBA.fromPixel(px).demultiply();
    return .{ .rgba = .fromClamped(
        @as(f64, @floatFromInt(straight.r)) / 255.0,
        @as(f64, @floatFromInt(straight.g)) / 255.0,
        @as(f64, @floatFromInt(straight.b)) / 255.0,
        @as(f64, @floatFromInt(straight.a)) / 255.0 * alpha,
    ) };
}

/// A viewBox dimension as a pixel count.
///
/// Rounded up and clamped: the viewBox has already been checked to be positive
/// and finite, and anything past `u32` is refused by `Limits.check` a moment
/// later with an error that says which limit it broke.
fn fitDimension(v: f64) u32 {
    const rounded = @ceil(v);
    if (rounded >= @as(f64, math.maxInt(u32))) return math.maxInt(u32);
    return @intFromFloat(rounded);
}

// -- tests -------------------------------------------------------------------

const icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2,2H22V22H2V2Z" /></svg>
;

test "the viewBox is the default size" {
    var surface = try render(testing.allocator, icon, .{});
    defer surface.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 24), surface.getWidth());
    try testing.expectEqual(@as(i32, 24), surface.getHeight());
}

test "a square drawn across the middle of the viewBox lands in the middle" {
    var surface = try render(testing.allocator, icon, .{
        .width = 48,
        .height = 48,
        .fill = .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    });
    defer surface.deinit(testing.allocator);

    // Inside the square, which runs from 4 to 44 at this scale.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(24, 24).?.rgba.r);
    // And outside it, which nothing painted, so it is still transparent.
    try testing.expectEqual(@as(u8, 0), surface.getPixel(1, 1).?.rgba.a);
}

test "a background fills the surface before the path is drawn" {
    var surface = try render(testing.allocator, icon, .{
        .background = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } },
        .fill = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },
    });
    defer surface.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(0, 0).?.rgb.b);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(12, 12).?.rgb.r);
}

test "a picture larger than the limits allow is refused" {
    try testing.expectError(error.ImageTooLarge, render(testing.allocator, icon, .{
        .width = 4096,
        .height = 4096,
        .limits = .{ .max_pixels = 1024 },
    }));
}

test "a zero dimension is refused rather than made into a surface" {
    try testing.expectError(error.BadSize, render(testing.allocator, icon, .{ .width = 0 }));
}

test "every shape in the document is painted" {
    const gpa = testing.allocator;
    // Two squares side by side, neither covering the other.
    const src =
        \\<svg viewBox="0 0 4 2"><path d="M0 0H2V2H0Z"/><path d="M2 0H4V2H2Z"/></svg>
    ;
    var surface = try render(gpa, src, .{
        .width = 40,
        .height = 20,
        .fill = .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    });
    defer surface.deinit(gpa);

    try testing.expectEqual(@as(u8, 255), surface.getPixel(10, 10).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(30, 10).?.rgba.a);
}

test "shapes are painted in document order, the later over the earlier" {
    const gpa = testing.allocator;
    // A big square, then a smaller one on top of it. With `src_over` and an
    // opaque fill the picture is the same either way -- what this pins is that
    // both were drawn at all, and that the second did not erase the first.
    const src =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H8V8H0Z"/><path d="M2 2H6V6H2Z"/></svg>
    ;
    var surface = try render(gpa, src, .{
        .width = 80,
        .height = 80,
        .fill = .{ .rgba = .{ .r = 0, .g = 0, .b = 255, .a = 255 } },
    });
    defer surface.deinit(gpa);

    // Inside the inner square, and inside the outer one but outside the inner.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(40, 40).?.rgba.b);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(5, 40).?.rgba.b);
}

test "overlapping shapes are not merged into one fill" {
    const gpa = testing.allocator;
    // One subpath clockwise, the next counterclockwise, overlapping. Built
    // into a single path and filled once under the nonzero rule, the second
    // would punch a hole in the first. Painted as two shapes it does not --
    // which is what SVG means and what resvg draws.
    const merged =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H8V8H0ZM2 2V6H6V2Z"/></svg>
    ;
    const separate =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H8V8H0Z"/><path d="M2 2V6H6V2Z"/></svg>
    ;

    var holed = try render(gpa, merged, .{ .width = 80, .height = 80 });
    defer holed.deinit(gpa);
    var solid = try render(gpa, separate, .{ .width = 80, .height = 80 });
    defer solid.deinit(gpa);

    // The middle of the merged one is a hole; the middle of the other is not.
    try testing.expectEqual(@as(u8, 0), holed.getPixel(40, 40).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), solid.getPixel(40, 40).?.rgba.a);
}

test "the node budget is spent across the document, not per shape" {
    const gpa = testing.allocator;
    // Three shapes of five nodes each. A per-shape budget of eight would take
    // all three; a document-wide one runs out during the second.
    const src =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H2V2H0Z"/><path d="M3 3H5V5H3Z"/><path d="M6 6H8V8H6Z"/></svg>
    ;
    try testing.expectError(error.PathTooComplex, render(gpa, src, .{
        .width = 16,
        .height = 16,
        .limits = .{ .max_path_nodes = 8 },
    }));
    // And with room for all three it draws.
    var surface = try render(gpa, src, .{
        .width = 16,
        .height = 16,
        .limits = .{ .max_path_nodes = 64 },
    });
    defer surface.deinit(gpa);
}

test "a document with more shapes than the limit allows is refused" {
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H2V2H0Z"/><path d="M3 3H5V5H3Z"/><path d="M6 6H8V8H6Z"/></svg>
    ;
    try testing.expectError(error.TooManyShapes, render(gpa, src, .{
        .width = 16,
        .height = 16,
        .limits = .{ .max_shapes = 2 },
    }));
}

/// The pixel at the middle of a 20x20 render of a full-viewBox square.
fn middleOf(gpa: Allocator, src: []const u8, opts: Options) !z2d.pixel.RGBA {
    var o = opts;
    o.width = 20;
    o.height = 20;
    var surface = try render(gpa, src, o);
    defer surface.deinit(gpa);
    return z2d.pixel.RGBA.fromPixel(surface.getPixel(10, 10).?).demultiply();
}

fn square(comptime attrs: []const u8) []const u8 {
    return "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" " ++ attrs ++ "/></svg>";
}

test "a shape is painted the colour its document names" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        square("fill=\"red\""),
        square("fill=\"#f00\""),
        square("fill=\"#ff0000\""),
        square("fill=\"rgb(255,0,0)\""),
        square("fill=\"RED\""),
    }) |src| {
        const px = try middleOf(gpa, src, .{});
        try testing.expectEqual(@as(u8, 255), px.r);
        try testing.expectEqual(@as(u8, 0), px.g);
        try testing.expectEqual(@as(u8, 255), px.a);
    }
}

test "a shape that names no colour is painted the caller's" {
    // The whole reason a Material Design Icon can be drawn in any colour: not
    // one of the 7,447 carries a `fill`.
    const gpa = testing.allocator;
    const px = try middleOf(gpa, square(""), .{
        .fill = .{ .rgba = .{ .r = 0, .g = 255, .b = 0, .a = 255 } },
    });
    try testing.expectEqual(@as(u8, 255), px.g);
    try testing.expectEqual(@as(u8, 0), px.r);
}

test "currentColor is the caller's colour, or the color property when there is one" {
    const gpa = testing.allocator;
    const callers: Options = .{ .fill = .{ .rgba = .{ .r = 0, .g = 0, .b = 255, .a = 255 } } };

    const from_caller = try middleOf(gpa, square("fill=\"currentColor\""), callers);
    try testing.expectEqual(@as(u8, 255), from_caller.b);

    // `color` on the root is inherited and is what `currentColor` resolves to.
    const from_color = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" color=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"currentColor\"/></svg>",
        callers,
    );
    try testing.expectEqual(@as(u8, 255), from_color.r);
    try testing.expectEqual(@as(u8, 0), from_color.b);

    // `fill` on the root is *not* what it resolves to -- that is the trap, and
    // resvg agrees: a `fill` ancestor leaves `color` at its initial value.
    const not_fill = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"currentColor\"/></svg>",
        callers,
    );
    try testing.expectEqual(@as(u8, 255), not_fill.b);
}

test "fill and fill-opacity are inherited from the root, and overridden by the shape" {
    const gpa = testing.allocator;
    const inherited = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><path d=\"M0 0H8V8H0Z\"/></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), inherited.r);

    const overridden = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"blue\"/></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), overridden.b);
    try testing.expectEqual(@as(u8, 0), overridden.r);

    const faded = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill-opacity=\"0.5\"><path d=\"M0 0H8V8H0Z\" fill=\"red\"/></svg>",
        .{},
    );
    try testing.expectApproxEqAbs(@as(f64, 128), @as(f64, @floatFromInt(faded.a)), 1.0);
}

test "the three alphas multiply together" {
    const gpa = testing.allocator;
    // The colour's own alpha, then fill-opacity, then opacity.
    const px = try middleOf(gpa, square("fill=\"#ff000080\" fill-opacity=\"0.5\" opacity=\"0.5\""), .{});
    // 0.5 * 0.5 * 0.5 = 0.125, which is 32 of 255.
    try testing.expectApproxEqAbs(@as(f64, 32), @as(f64, @floatFromInt(px.a)), 1.5);
}

test "a shape that would paint nothing is skipped" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        square("fill=\"none\""),
        square("fill=\"transparent\""),
        square("fill-opacity=\"0\""),
        square("opacity=\"0\""),
        square("fill=\"#ff000000\""),
    }) |src| {
        const px = try middleOf(gpa, src, .{});
        try testing.expectEqual(@as(u8, 0), px.a);
    }
}

test "shapes in one document can be different colours" {
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 4 2"><path d="M0 0H2V2H0Z" fill="red"/><path d="M2 0H4V2H2Z" fill="blue"/></svg>
    ;
    var surface = try render(gpa, src, .{ .width = 40, .height = 20 });
    defer surface.deinit(gpa);
    const left = z2d.pixel.RGBA.fromPixel(surface.getPixel(10, 10).?).demultiply();
    const right = z2d.pixel.RGBA.fromPixel(surface.getPixel(30, 10).?).demultiply();
    try testing.expectEqual(@as(u8, 255), left.r);
    try testing.expectEqual(@as(u8, 0), left.b);
    try testing.expectEqual(@as(u8, 255), right.b);
    try testing.expectEqual(@as(u8, 0), right.r);
}

test "fill-rule is read from the document, and is case-sensitive" {
    const gpa = testing.allocator;
    // Both subpaths wound the same way: nonzero fills the middle, evenodd
    // leaves a hole.
    const both = "M0 0H8V8H0ZM2 2H6V6H2Z";
    const nonzero = "<svg viewBox=\"0 0 8 8\"><path d=\"" ++ both ++ "\"/></svg>";
    const evenodd = "<svg viewBox=\"0 0 8 8\"><path d=\"" ++ both ++ "\" fill-rule=\"evenodd\"/></svg>";

    try testing.expectEqual(@as(u8, 255), (try middleOf(gpa, nonzero, .{})).a);
    try testing.expectEqual(@as(u8, 0), (try middleOf(gpa, evenodd, .{})).a);

    // `EVENODD` is not `evenodd`: this is an XML attribute value, not a CSS
    // keyword, so it is not matched without regard to case. resvg reads it the
    // same way -- but it falls back to nonzero where this refuses.
    try testing.expectError(error.BadFillRule, render(gpa, "<svg viewBox=\"0 0 8 8\"><path d=\"" ++
        both ++ "\" fill-rule=\"EVENODD\"/></svg>", .{}));
}

test "a value that cannot be read is refused rather than defaulted" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadColor, render(gpa, square("fill=\"notacolour\""), .{}));
    try testing.expectError(error.BadColor, render(gpa, square("fill=\"#12345\""), .{}));
    try testing.expectError(error.BadOpacity, render(gpa, square("opacity=\"half\""), .{}));
    try testing.expectError(error.BadOpacity, render(gpa, square("fill-opacity=\"\""), .{}));
}

test "opacity on the root is refused rather than approximated" {
    const gpa = testing.allocator;
    try testing.expectError(error.GroupOpacityUnsupported, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\" opacity=\"0.5\"><path d=\"M0 0H8V8H0Z\"/></svg>",
        .{},
    ));
}

test "a path past the node limit is refused" {
    try testing.expectError(error.PathTooComplex, render(testing.allocator, icon, .{
        .limits = .{ .max_path_nodes = 2 },
    }));
}

test "draw paints into a surface somebody else made" {
    const gpa = testing.allocator;
    var surface = try z2d.Surface.initPixel(
        .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
        gpa,
        64,
        32,
    );
    defer surface.deinit(gpa);

    try draw(gpa, &surface, icon, .{
        .x = 32,
        .y = 0,
        .width = 32,
        .height = 32,
    }, .{ .fill = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } });

    // Painted on the right half and not on the left.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(48, 16).?.rgb.g);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(16, 16).?.rgb.g);
}
