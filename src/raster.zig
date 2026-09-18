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

    /// The most `z2d.Path` nodes the `d` attribute may produce.
    ///
    /// Nodes rather than bytes of source, because the two are not
    /// proportional: `a` with a large sweep produces four cubics from a dozen
    /// characters, and repeating it is the cheapest way to write an expensive
    /// path.
    max_path_nodes: usize = 1 << 20,

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

    /// What to paint the path with. SVG's default `fill` is black, and this
    /// is that; the `fill` attribute is not read.
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

    /// SVG's default `fill-rule` is `nonzero`, and this is that; the
    /// attribute is not read.
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
fn drawDocument(
    gpa: Allocator,
    surface: *z2d.Surface,
    doc: document.Document,
    box: Box,
    opts: Options,
) Error!void {
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);

    try document.buildDocumentIn(
        &p,
        gpa,
        doc,
        box.x,
        box.y,
        box.width,
        box.height,
        .{ .max_nodes = opts.limits.max_path_nodes },
    );
    // An empty `d` is a document that draws nothing, which is not an error;
    // `painter.fill` would take it too, but this says so on purpose.
    if (p.nodes.items.len == 0) return;

    const source: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = opts.fill } };
    try z2d.painter.fill(gpa, surface, &source, p.nodes.items, .{
        .fill_rule = opts.fill_rule,
        .anti_aliasing_mode = opts.anti_aliasing_mode,
        .tolerance = opts.tolerance,
    });
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
