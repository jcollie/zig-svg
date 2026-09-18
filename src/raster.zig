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
const transform = @import("transform.zig");

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

    /// What `stroke="currentColor"` resolves to when nothing named a `color`,
    /// which is the same colour a fill would use.
    ///
    /// There is deliberately no "default stroke": SVG's initial `stroke` is
    /// `none`, so a shape whose document says nothing about stroking is not
    /// stroked. Doing otherwise would put lines in a picture that the document
    /// does not have -- which is the opposite of the `fill` case, where the
    /// document saying nothing is the *normal* case for an icon.
    stroke_width: f64 = 1.0,

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
    /// A `stroke-dasharray` naming more than `max_dashes` lengths.
    TooManyDashes,
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
    var doc = try document.read(gpa, src);
    defer doc.deinit();

    // The document's own size, which is what `width` and `height` say when it
    // has them and the `viewBox`'s extent when it does not.
    const width = opts.width orelse fitDimension(doc.width);
    const height = opts.height orelse fitDimension(doc.height);
    try opts.limits.check(width, height);

    var surface = if (opts.background) |px|
        try z2d.Surface.initPixel(px, gpa, @intCast(width), @intCast(height))
    else
        try z2d.Surface.init(opts.surface_type, gpa, @intCast(width), @intCast(height));
    errdefer surface.deinit(gpa);

    try drawDocument(gpa, &surface, &doc, .{
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
    var doc = try document.read(gpa, src);
    defer doc.deinit();
    return drawDocument(gpa, surface, &doc, box, opts);
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
    doc: *const document.Document,
    box: Box,
    opts: Options,
) Error!void {
    if (doc.shape_count > opts.limits.max_shapes) return error.TooManyShapes;

    const view_box = doc.transformFor(box.x, box.y, box.width, box.height);

    // Spent down across the whole document rather than reset per shape. See
    // `Limits.max_path_nodes`.
    var nodes_left = opts.limits.max_path_nodes;

    var shapes = doc.paths();
    while (try shapes.next()) |shape| {
        const ctm = view_box.mul(shape.transform);
        const fill_paint = resolveFill(shape, opts);
        const stroke = try resolveStroke(shape, opts);

        // §11.3: fill first, then stroke over it, per element.
        if (fill_paint) |paint| {
            var p: z2d.Path = .empty;
            defer p.deinit(gpa);

            // The viewBox mapping outside, the shape's own `transform` chain
            // inside, so that a `transform` is in user units like the path
            // data it applies to.
            try document.buildShape(&p, gpa, shape.geometry, ctm, .{
                .max_nodes = nodes_left,
            });
            nodes_left -= p.nodes.items.len;

            // A shape with no geometry draws nothing, which is not an error;
            // `painter.fill` would take it too, but this says so on purpose.
            if (p.nodes.items.len != 0) {
                const source: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = paint } };
                try z2d.painter.fill(gpa, surface, &source, p.nodes.items, .{
                    .fill_rule = shape.fill_rule orelse opts.fill_rule,
                    .anti_aliasing_mode = opts.anti_aliasing_mode,
                    .tolerance = opts.tolerance,
                });
            }
        }

        if (stroke) |*s| {
            // Built a second time, because the subpaths have to be left as
            // the document wrote them: a stroked open subpath is capped at its
            // ends rather than joined back to its start.
            //
            // The points are transformed exactly as the fill's are. z2d takes
            // the matrix *as well*, and uses it only to shape the pen -- which
            // is Cairo's model, and is what makes the pen warp under a
            // non-uniform scale as SVG says it must. Passing untransformed
            // points and relying on the matrix to place them draws the whole
            // document in the top-left corner at user-space coordinates.
            var p: z2d.Path = .empty;
            defer p.deinit(gpa);

            try document.buildShape(&p, gpa, shape.geometry, ctm, .{
                .max_nodes = nodes_left,
                .close_subpaths = false,
            });
            nodes_left -= p.nodes.items.len;

            if (p.nodes.items.len != 0) {
                // Where the matrix is a similarity, the pen is scaled here and
                // z2d is handed the identity; where it is not, z2d is handed
                // the matrix and shapes the pen itself. `uniformScale` says
                // why the two are not interchangeable in practice even though
                // they are in geometry.
                var pen = s.*;
                var pen_ctm: z2d.Transformation = ctm;
                if (uniformScale(ctm)) |factor| {
                    pen.scaleBy(factor);
                    pen_ctm = .identity;
                }

                const source: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = pen.paint } };
                z2d.painter.stroke(gpa, surface, &source, p.nodes.items, .{
                    .line_width = pen.width,
                    .line_cap_mode = pen.cap,
                    .line_join_mode = pen.join,
                    .miter_limit = pen.miter_limit,
                    .dashes = pen.dashes(),
                    .dash_offset = pen.dash_offset,
                    .transformation = pen_ctm,
                    .anti_aliasing_mode = opts.anti_aliasing_mode,
                    .tolerance = opts.tolerance,
                }) catch |err| switch (err) {
                    // A `transform` that collapses the plane -- `scale(0)` --
                    // has nothing to stroke through. Filling it draws nothing
                    // and stroking it should too, rather than failing.
                    error.InvalidMatrix => {},
                    else => |e| return e,
                };
            }
        }
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
fn resolveFill(shape: document.Shape, opts: Options) ?z2d.Pixel {
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

/// The most dashes a `stroke-dasharray` may name.
///
/// The list is read into the caller's frame rather than allocated, so it needs
/// a ceiling; and a dash pattern with more than this many phases in it is a
/// pattern nobody can see. A longer list is refused rather than truncated,
/// because truncating one would change where every dash after it falls.
pub const max_dashes = 64;

/// Everything `z2d.painter.stroke` needs, resolved from a shape.
///
/// The dash lengths are held as an array and a count rather than as a slice,
/// and `dashes()` makes the slice from whichever copy you are holding. A
/// `dashes: []const f64` field pointing into a `storage` field beside it would
/// be a slice into *this* struct -- and this struct is returned by value, so
/// every copy's slice would point at the dead frame of the function that built
/// it. It would read the right numbers for a while, too.
const Stroke = struct {
    paint: z2d.Pixel,
    width: f64,
    cap: z2d.options.CapMode,
    join: z2d.options.JoinMode,
    miter_limit: f64,
    dash_offset: f64,
    dash_count: usize = 0,
    dash_storage: [max_dashes]f64 = undefined,

    fn dashes(self: *const Stroke) []const f64 {
        return self.dash_storage[0..self.dash_count];
    }

    /// Rescales the pen for stroking in device space. See `uniformScale`.
    fn scaleBy(self: *Stroke, s: f64) void {
        self.width *= s;
        self.dash_offset *= s;
        for (self.dash_storage[0..self.dash_count]) |*d| d.* *= s;
    }
};

/// The scale factor of `t` if it is a similarity, and null otherwise.
///
/// A similarity -- a uniform scale, with any rotation and translation -- maps
/// a circle to a circle, so a round pen of radius `r` under it is exactly a
/// round pen of radius `r * s`. That makes two ways of stroking *equivalent*
/// rather than merely close, and the choice between them matters for a reason
/// that has nothing to do with geometry:
///
/// z2d reverts `line_cap_mode`, `line_join_mode` and `miter_limit` to their
/// defaults whenever `line_width` is below 2, to keep thin lines from showing
/// artifacts. Handing it the *user-space* width means a `stroke-width="1"` --
/// the initial value, so much the commonest one -- silently loses its round
/// caps however large the picture is drawn. Handing it the device-space width
/// instead, which for any ordinary viewBox mapping is several pixels, keeps
/// them.
///
/// So where the matrix is a similarity this strokes in device space, and
/// everywhere else it hands z2d the matrix and accepts that a thin stroke
/// under a genuinely warped transform may lose its caps. The alternative is a
/// round pen where the specification asks for an elliptical one, which is
/// wrong in a way that does not announce itself.
///
/// The columns of the linear part have to be the same length and at right
/// angles, which is the definition, tested proportionally so that it holds for
/// a matrix scaled by a millionth as well as by a million.
fn uniformScale(t: z2d.Transformation) ?f64 {
    const len_x = @sqrt(t.ax * t.ax + t.cx * t.cx);
    const len_y = @sqrt(t.by * t.by + t.dy * t.dy);
    if (!(len_x > 0) or !(len_y > 0)) return null;

    const tolerance = 1e-9;
    if (@abs(len_x - len_y) > tolerance * @max(len_x, len_y)) return null;
    const dot = t.ax * t.by + t.cx * t.dy;
    if (@abs(dot) > tolerance * len_x * len_y) return null;
    return len_x;
}

/// How to stroke one shape, or null when it is not stroked.
///
/// SVG's initial `stroke` is `none`, so a shape whose document says nothing
/// about stroking is not stroked. That is the opposite of `fill`, where saying
/// nothing means the caller's colour -- and deliberately so: an icon with no
/// `fill` is the normal case, while a shape stroked without asking would put
/// lines in a picture the document does not have.
fn resolveStroke(shape: document.Shape, opts: Options) Error!?Stroke {
    const paint = shape.stroke orelse return null;

    // §11.4: a width of zero, or less, disables the stroke.
    const width = shape.stroke_width orelse opts.stroke_width;
    if (!(width > 0)) return null;

    const alpha = (shape.stroke_opacity orelse 1.0) * shape.opacity;
    const named: ?color.Color = switch (paint) {
        .none => return null,
        .color => |c| c,
        .current => shape.current_color,
    };
    const pixel = (if (named) |c| fadeColor(c, alpha) else fadePixel(opts.fill, alpha)) orelse
        return null;

    var result: Stroke = .{
        .paint = pixel,
        .width = width,
        .cap = shape.stroke_linecap orelse .butt,
        .join = shape.stroke_linejoin orelse .miter,
        // SVG's initial `stroke-miterlimit` is **4**. z2d's is 10, which would
        // miter every corner sharper than about 11 degrees that should have
        // been bevelled -- a difference that shows on any spike and on nothing
        // else, so it is exactly the kind of wrong nobody notices. resvg was
        // asked, and it is 4.
        .miter_limit = shape.stroke_miterlimit orelse 4.0,
        .dash_offset = shape.stroke_dashoffset orelse 0,
    };
    if (shape.stroke_dasharray) |raw| {
        result.dash_count = try readDashes(raw, &result.dash_storage);
    }
    return result;
}

/// Reads a `stroke-dasharray` into `out`, and says how much of it was used.
///
/// §11.4, and what resvg actually does, which is not quite the same: reading
/// stops at the first value that is not a length and the lengths before it are
/// used, the way a `points` list truncates. A list that is empty, says `none`,
/// is all zeroes, or holds a negative number is not a dash pattern at all and
/// leaves the stroke solid -- the negative case because §11.4 calls it an
/// error, and an erroneous value falls back to the initial one.
///
/// An odd count is repeated, so `4` dashes four on and four off. That is the
/// specification rather than a convenience, and z2d does not do it for us.
fn readDashes(raw: []const u8, out: *[max_dashes]f64) Error!usize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return 0;

    var s: path.Scanner = .{ .src = trimmed };
    var n: usize = 0;
    var total: f64 = 0;
    while (true) {
        s.skipWsAndCommas();
        if (s.done()) break;
        const v = s.number() catch break;
        if (v < 0) return 0; // §11.4: an error, so the initial value stands
        // Doubling below needs room for two of everything.
        if (n >= max_dashes / 2) return error.TooManyDashes;
        out[n] = v;
        n += 1;
        total += v;
    }
    if (n == 0 or total <= 0) return 0;

    if (n % 2 == 1) {
        @memcpy(out[n..][0..n], out[0..n]);
        n *= 2;
    }
    return n;
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

/// The document's own size as a pixel count.
///
/// Rounded to nearest, which is what resvg does with an explicit `width`: a
/// `4cm` document comes out 151 pixels rather than 152, and `1.4` comes out 1.
/// Clamped as well -- the size has already been checked to be positive and
/// finite, and anything past `u32` is refused by `Limits.check` a moment later
/// with an error that says which limit it broke.
fn fitDimension(v: f64) u32 {
    const rounded = @round(v);
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

test "a transform moves a shape" {
    const gpa = testing.allocator;
    // A 4x4 square at the origin of an 8x8 viewBox, rendered at 8 pixels: the
    // square covers the top-left quadrant, and translate(4,4) puts it in the
    // bottom-right.
    const plain = "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" fill=\"red\"/></svg>";
    const moved = "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" fill=\"red\" transform=\"translate(4,4)\"/></svg>";

    var a = try render(gpa, plain, .{ .width = 8, .height = 8 });
    defer a.deinit(gpa);
    var b = try render(gpa, moved, .{ .width = 8, .height = 8 });
    defer b.deinit(gpa);

    try testing.expectEqual(@as(u8, 255), a.getPixel(1, 1).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), a.getPixel(6, 6).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), b.getPixel(1, 1).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), b.getPixel(6, 6).?.rgba.a);
}

test "a group's transform applies to what is inside it, and composes" {
    const gpa = testing.allocator;
    // Two ways of putting the square in the bottom-right: on the group, or
    // split between the group and the shape. Both must land in the same place.
    const on_group = "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,4)\">" ++
        "<path d=\"M0 0H4V4H0Z\" fill=\"red\"/></g></svg>";
    const split = "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,0)\">" ++
        "<path d=\"M0 0H4V4H0Z\" fill=\"red\" transform=\"translate(0,4)\"/></g></svg>";
    const nested = "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,0)\">" ++
        "<g transform=\"translate(0,4)\"><path d=\"M0 0H4V4H0Z\" fill=\"red\"/></g></g></svg>";

    for ([_][]const u8{ on_group, split, nested }) |src| {
        var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
        defer surface.deinit(gpa);
        try testing.expectEqual(@as(u8, 255), surface.getPixel(6, 6).?.rgba.a);
        try testing.expectEqual(@as(u8, 0), surface.getPixel(1, 1).?.rgba.a);
    }
}

test "a group's transform is undone when the group closes" {
    const gpa = testing.allocator;
    // The second shape is a sibling of the group, not a child, so the
    // translate must not still be in force when it is drawn. A stack that
    // never pops would put both squares in the bottom-right.
    const src = "<svg viewBox=\"0 0 8 8\">" ++
        "<g transform=\"translate(4,4)\"><path d=\"M0 0H4V4H0Z\" fill=\"red\"/></g>" ++
        "<path d=\"M0 0H4V4H0Z\" fill=\"blue\"/></svg>";
    var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
    defer surface.deinit(gpa);
    const top_left = z2d.pixel.RGBA.fromPixel(surface.getPixel(1, 1).?).demultiply();
    const bottom_right = z2d.pixel.RGBA.fromPixel(surface.getPixel(6, 6).?).demultiply();
    try testing.expectEqual(@as(u8, 255), top_left.b);
    try testing.expectEqual(@as(u8, 255), bottom_right.r);
}

test "a group's presentation attributes are inherited and overridden" {
    const gpa = testing.allocator;
    const inherited = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g fill=\"red\"><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), inherited.r);

    const overridden = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g fill=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"blue\"/></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), overridden.b);

    // Three levels: the root, a group, and the shape, each overriding the last.
    const deep = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><g fill=\"blue\">" ++
            "<g><path d=\"M0 0H8V8H0Z\" fill=\"lime\"/></g></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), deep.g);
    try testing.expectEqual(@as(u8, 0), deep.r);
    try testing.expectEqual(@as(u8, 0), deep.b);

    // And a group that names nothing passes its parent's value straight down.
    const through = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><g><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), through.r);
}

test "a transform on the root applies in user units" {
    const gpa = testing.allocator;
    // viewBox 8 units wide rendered at 32 pixels, so the scale is 4. A root
    // translate of 2 *user* units moves the shape 8 pixels, not 2 -- the
    // viewBox mapping is outside the document's own transforms.
    const src = "<svg viewBox=\"0 0 8 8\" transform=\"translate(2,0)\">" ++
        "<path d=\"M0 0H2V2H0Z\" fill=\"red\"/></svg>";
    var surface = try render(gpa, src, .{ .width = 32, .height = 32 });
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(4, 4).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(12, 4).?.rgba.a);
}

test "a malformed transform is refused, and an empty one is the identity" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadTransform, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" transform=\"bogus(1)\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadTransform, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(\"><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    ));
    const identity = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" transform=\"\"/></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), identity.a);
}

test "opacity on a group is refused like opacity on the root" {
    const gpa = testing.allocator;
    try testing.expectError(error.GroupOpacityUnsupported, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g opacity=\"0.5\"><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    ));
}

test "groups nested past the limit are refused rather than overflowing" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<svg viewBox=\"0 0 8 8\">");
    for (0..document.max_container_depth + 2) |_| try src.appendSlice(gpa, "<g>");
    try src.appendSlice(gpa, "<path d=\"M0 0H8V8H0Z\"/>");
    for (0..document.max_container_depth + 2) |_| try src.appendSlice(gpa, "</g>");
    try src.appendSlice(gpa, "</svg>");

    try testing.expectError(error.TooDeeplyNested, render(gpa, src.items, .{}));
}

test "a transform that puts a point past the rasterizer's reach is refused" {
    // Found by the fuzzer, and it was a *panic* rather than an error: z2d
    // reduces a polygon's extent to an i32, so a four-unit square scaled by
    // 1e300 is `@intFromFloat` on a value out of range. The matrix itself is
    // perfectly finite, which is why checking the matrix is not enough.
    const gpa = testing.allocator;
    try testing.expectError(error.CoordinateOutOfRange, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"scale(1e300)\"/></svg>",
        .{},
    ));
    // The same number written in the path data is *not* an error, because
    // z2d clamps a coordinate as it is added -- `H1e300` becomes 8388607. The
    // clamp is on the wrong side of the transform, which is the whole reason
    // the check above has to exist; see `document.max_coordinate`.
    var clamped = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H1e300V1e300H0Z\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer clamped.deinit(gpa);
    // And a translation far enough out to be nothing but arithmetic.
    try testing.expectError(error.CoordinateOutOfRange, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(1e20,0)\">" ++
            "<path d=\"M0 0H4V4H0Z\"/></g></svg>",
        .{},
    ));
    // Far off the canvas but within reach is drawn, not refused: clipping is
    // the rasterizer's job and an off-screen shape is perfectly legal.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"translate(1000,1000)\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer surface.deinit(gpa);
}

test "a transform that overflows to infinity is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.NonFiniteTransform, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g transform=\"scale(1e300)\">" ++
            "<path d=\"M0 0H8V8H0Z\" transform=\"scale(1e300)\"/></g></svg>",
        .{},
    ));
}

test "a similarity transform is recognised, and a warped one is not" {
    try testing.expect(uniformScale(.identity).? == 1.0);
    try testing.expectApproxEqAbs(@as(f64, 3), uniformScale(try transform.parse("scale(3)")).?, 1e-12);
    // Rotation and translation do not change the scale.
    try testing.expectApproxEqAbs(
        @as(f64, 2),
        uniformScale(try transform.parse("translate(5,7) rotate(37) scale(2)")).?,
        1e-9,
    );
    // A reflection is still a similarity: it maps a circle to a circle.
    try testing.expectApproxEqAbs(@as(f64, 2), uniformScale(try transform.parse("scale(2,-2)")).?, 1e-12);
    // These are not.
    try testing.expectEqual(@as(?f64, null), uniformScale(try transform.parse("scale(3,1)")));
    try testing.expectEqual(@as(?f64, null), uniformScale(try transform.parse("skewX(20)")));
    try testing.expectEqual(@as(?f64, null), uniformScale(try transform.parse("scale(0)")));
}

fn dashesOf(raw: []const u8) ![]const f64 {
    const S = struct {
        var storage: [max_dashes]f64 = undefined;
    };
    const n = try readDashes(raw, &S.storage);
    return S.storage[0..n];
}

test "a dash array is read, and an odd one is repeated" {
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, try dashesOf("4 2"));
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, try dashesOf("4,2"));
    // §11.4: an odd count is repeated, so `4` is four on and four off.
    try testing.expectEqualSlices(f64, &.{ 4, 4 }, try dashesOf("4"));
    try testing.expectEqualSlices(f64, &.{ 4, 2, 1, 4, 2, 1 }, try dashesOf("4,2,1"));
}

test "a dash array that is not one leaves the stroke solid" {
    for ([_][]const u8{ "", "   ", "none", "0", "0 0", "0,0,0", "-4 2", "abc" }) |raw| {
        try testing.expectEqual(@as(usize, 0), (try dashesOf(raw)).len);
    }
}

test "a dash array stops at the first value that is not a length" {
    // The same leniency a `points` list gets, and for the same reason: resvg
    // and every browser draw the dashes they managed to read.
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, try dashesOf("4 2 bogus"));
}

test "a dash array longer than the ceiling is refused" {
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..max_dashes) |_| try long.appendSlice(testing.allocator, "1 ");
    var storage: [max_dashes]f64 = undefined;
    try testing.expectError(error.TooManyDashes, readDashes(long.items, &storage));
}

test "a shape with no stroke named is not stroked" {
    const gpa = testing.allocator;
    // SVG's initial `stroke` is `none`, so unlike `fill` the caller's colour
    // is *not* the default here -- a shape stroked without asking would put
    // lines in a picture the document does not have.
    var surface = try render(gpa, square(""), .{ .width = 20, .height = 20 });
    defer surface.deinit(gpa);
    var doc = try document.read(gpa, square(""));
    defer doc.deinit();
    var it = doc.paths();
    const only = (try it.next()).?;
    try testing.expectEqual(@as(?color.Paint, null), only.stroke);
    try testing.expectEqual(@as(?Stroke, null), try resolveStroke(only, .{}));
}

test "a stroke of zero or negative width is not drawn" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-width=\"0\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-width=\"-3\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"none\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-opacity=\"0\"/></svg>",
    }) |src| {
        var surface = try render(gpa, src, .{ .width = 16, .height = 16 });
        defer surface.deinit(gpa);
        for (0..16) |y| for (0..16) |x| {
            try testing.expectEqual(
                @as(u8, 0),
                surface.getPixel(@intCast(x), @intCast(y)).?.rgba.a,
            );
        };
    }
}

test "a stroked line finally draws something" {
    const gpa = testing.allocator;
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-width=\"2\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(8, 8).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(8, 1).?.rgba.a);
}

test "fill is painted first and the stroke over it" {
    const gpa = testing.allocator;
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 16 16\"><rect x=\"4\" y=\"4\" width=\"8\" height=\"8\" " ++
            "fill=\"blue\" stroke=\"red\" stroke-width=\"4\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer surface.deinit(gpa);
    const middle = z2d.pixel.RGBA.fromPixel(surface.getPixel(8, 8).?).demultiply();
    const edge = z2d.pixel.RGBA.fromPixel(surface.getPixel(4, 8).?).demultiply();
    try testing.expectEqual(@as(u8, 255), middle.b);
    try testing.expectEqual(@as(u8, 255), edge.r);
}

test "a stroke style this reader does not know is refused" {
    const gpa = testing.allocator;
    const line = "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" ";
    try testing.expectError(error.BadStrokeStyle, render(
        gpa,
        line ++ "stroke-linecap=\"ROUND\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadStrokeStyle, render(
        gpa,
        line ++ "stroke-linejoin=\"bogus\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadStrokeStyle, render(
        gpa,
        line ++ "stroke-miterlimit=\"wide\"/></svg>",
        .{},
    ));
    // A miter limit below one is clamped rather than refused, which is what
    // resvg does: `0.5` draws exactly what `1` draws.
    var surface = try render(gpa, line ++ "stroke-miterlimit=\"0.5\"/></svg>", .{});
    defer surface.deinit(gpa);
}

test "an entity reference in an attribute value is resolved" {
    const gpa = testing.allocator;
    // `&#90;` is `Z`, so this closes the subpath and fills a square. Without
    // decoding it reaches the path parser as five literal characters and is
    // `error.UnknownCommand`.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&#90;\" fill=\"red\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(8, 8).?.rgba.a);
}

test "a reference is resolved in every kind of attribute value" {
    const gpa = testing.allocator;
    // A colour, a number, a length, a transform, a `points` list and a dash
    // array -- the parsed ones through the reader's buffer and the borrowed
    // ones where they are drawn.
    const cases = [_][]const u8{
        // `&#114;ed` is `red`.
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"&#114;ed\"/></svg>",
        // `&#56;` is `8`.
        "<svg viewBox=\"0 0 8 8\"><rect width=\"&#56;\" height=\"8\" fill=\"red\"/></svg>",
        // A transform list.
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"red\" transform=\"translate(&#48;,0)\"/></svg>",
        // A `points` list, decoded with an allocator rather than a buffer.
        "<svg viewBox=\"0 0 8 8\"><polygon points=\"0,0 8,0 8,&#56; 0,8\" fill=\"red\"/></svg>",
    };
    for (cases) |src| {
        var surface = try render(gpa, src, .{ .width = 16, .height = 16 });
        defer surface.deinit(gpa);
        try testing.expectEqual(@as(u8, 255), surface.getPixel(8, 8).?.rgba.a);
    }

    // And a dash array, which is read where the stroke is resolved.
    var dashed = try render(
        gpa,
        "<svg viewBox=\"0 0 16 16\"><line x1=\"0\" y1=\"8\" x2=\"16\" y2=\"8\" " ++
            "stroke=\"red\" stroke-width=\"4\" stroke-dasharray=\"&#52; 2\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer dashed.deinit(gpa);
    // Dashed rather than solid: something along the line is unpainted.
    var gaps: usize = 0;
    for (0..16) |x| {
        if (dashed.getPixel(@intCast(x), 8).?.rgba.a == 0) gaps += 1;
    }
    try testing.expect(gaps > 0);
}

test "an entity nobody declared is refused rather than drawn as text" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownEntity, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"&nosuch;\"/></svg>",
        .{},
    ));
    try testing.expectError(error.UnknownEntity, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&nosuch;\"/></svg>",
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
