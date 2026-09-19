// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The pixel operations a filter is made of: SVG 1.1 §15.
//!
//! Nothing here knows what an SVG element is. Each function takes a surface
//! of premultiplied RGBA and changes it, which is what `<filter>`'s primitives
//! come to once the document has been read and the coordinate systems have
//! been resolved. `filter.zig` reads the element, `raster.zig` decides which
//! of these to call and with what, and this file is where the arithmetic is,
//! so the arithmetic can be tested without a document in sight.
//!
//! ## Premultiplied, throughout
//!
//! Every buffer in a filter chain is premultiplied, which is not what the
//! specification's prose assumes and is what every implementation does. A blur
//! of straight alpha smears the colour of transparent pixels into their
//! neighbours -- a black halo around anything drawn on transparency, because
//! the colour behind a zero alpha is usually black and still counts towards
//! the average. Premultiplied, a transparent pixel contributes nothing to
//! either the colour or the alpha, which is the answer that looks right.
//!
//! The one operation that has to leave premultiplied form is the colour space
//! conversion, because a transfer curve applied to `colour × alpha` is not the
//! curve applied to the colour.
//!
//! ## Eight bits of linear light
//!
//! `toLinear` and `toSrgb` convert in place, in eight bits, which throws away
//! real precision in the darks: sRGB 1..12 all land on linear 0 or 1. That is
//! a deliberate match rather than an oversight. resvg converts its filter
//! buffers in place in eight bits too, and the whole purpose of the oracle is
//! to be told when this renderer and that one disagree -- so this one rounds
//! where that one rounds.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

pub const Error = error{
    /// A blur whose kernel would be wider than any picture could use. Only
    /// reachable from a `stdDeviation` in the thousands.
    BlurTooWide,
} || Allocator.Error;

/// A rectangle of whole pixels: `x0` and `y0` are inside it, `x1` and `y1` are
/// one past. An empty box has `x1 <= x0` and covers nothing.
pub const PixelBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn isEmpty(self: PixelBox) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }

    pub fn intersect(a: PixelBox, b: PixelBox) PixelBox {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    pub fn unite(a: PixelBox, b: PixelBox) PixelBox {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        };
    }
};

/// The whole of a surface, as a box.
pub fn extent(sfc: *const z2d.Surface) PixelBox {
    return .{ .x0 = 0, .y0 = 0, .x1 = sfc.getWidth(), .y1 = sfc.getHeight() };
}

/// The pixels of an RGBA surface, which is the only kind a filter runs on.
fn pixels(sfc: *z2d.Surface) []z2d.pixel.RGBA {
    return sfc.image_surface_rgba.buf;
}

/// Zero every pixel outside `box`. §15.7.6: a primitive's subregion is a hard
/// edge, and everything it does not cover is transparent black.
pub fn clipTo(sfc: *z2d.Surface, box: PixelBox) void {
    const w = sfc.getWidth();
    const h = sfc.getHeight();
    const buf = pixels(sfc);
    const clipped = box.intersect(extent(sfc));
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        const row = buf[@intCast(y * w)..][0..@intCast(w)];
        if (clipped.isEmpty() or y < clipped.y0 or y >= clipped.y1) {
            @memset(row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
            continue;
        }
        @memset(row[0..@intCast(clipped.x0)], .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        @memset(row[@intCast(clipped.x1)..], .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    }
}

/// `SourceAlpha`: the alpha channel alone, as black. §15.7.3.
pub fn alphaOnly(sfc: *z2d.Surface) void {
    for (pixels(sfc)) |*px| {
        px.r = 0;
        px.g = 0;
        px.b = 0;
    }
}

/// Fill `box` with one premultiplied colour, leaving the rest transparent.
/// §15.16's `feFlood`.
pub fn flood(sfc: *z2d.Surface, px: z2d.pixel.RGBA, box: PixelBox) void {
    const w = sfc.getWidth();
    const buf = pixels(sfc);
    @memset(buf, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const clipped = box.intersect(extent(sfc));
    if (clipped.isEmpty()) return;
    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        const row = buf[@intCast(y * w)..][0..@intCast(w)];
        @memset(row[@intCast(clipped.x0)..@intCast(clipped.x1)], px);
    }
}

/// `feOffset`: shift the picture by whole pixels. §15.21.
///
/// Whole pixels because the offset has already been taken into the canvas'
/// own grid by the time it gets here; a fractional part would need resampling
/// and resvg rounds it away too.
pub fn offset(dst: *z2d.Surface, src: *z2d.Surface, dx: i32, dy: i32) void {
    const w = dst.getWidth();
    const h = dst.getHeight();
    const out = pixels(dst);
    const in = pixels(src);
    @memset(out, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        const sy = y - dy;
        if (sy < 0 or sy >= h) continue;
        // The overlapping span, so the row is one copy rather than a test per
        // pixel.
        const x0 = @max(@as(i32, 0), dx);
        const x1 = @min(w, w + dx);
        if (x1 <= x0) continue;
        const len: usize = @intCast(x1 - x0);
        const dst_row = out[@intCast(y * w + x0)..][0..len];
        const src_row = in[@intCast(sy * w + x0 - dx)..][0..len];
        @memcpy(dst_row, src_row);
    }
}

// -- colour space ------------------------------------------------------------

/// sRGB's transfer curve, on bytes. IEC 61966-2-1, and the piecewise linear
/// segment near black matters: without it the darkest few levels go to zero.
fn srgbToLinearTable() [256]u8 {
    @setEvalBranchQuota(20000);
    var t: [256]u8 = undefined;
    for (&t, 0..) |*slot, i| {
        const c = @as(f64, @floatFromInt(i)) / 255.0;
        const lin = if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        slot.* = @intFromFloat(@round(lin * 255.0));
    }
    return t;
}

fn linearToSrgbTable() [256]u8 {
    @setEvalBranchQuota(20000);
    var t: [256]u8 = undefined;
    for (&t, 0..) |*slot, i| {
        const c = @as(f64, @floatFromInt(i)) / 255.0;
        const s = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
        slot.* = @intFromFloat(@round(s * 255.0));
    }
    return t;
}

const to_linear = srgbToLinearTable();
const to_srgb = linearToSrgbTable();

/// Apply a byte-to-byte curve to the colour channels of a premultiplied
/// surface, leaving alpha alone.
///
/// The curve belongs to the *colour*, so each pixel is divided by its alpha
/// before the table and multiplied back afterwards. A fully transparent pixel
/// has no colour to convert and is left as it is.
fn mapColors(sfc: *z2d.Surface, table: *const [256]u8) void {
    for (pixels(sfc)) |*px| {
        if (px.a == 0) {
            px.r = 0;
            px.g = 0;
            px.b = 0;
            continue;
        }
        if (px.a == 255) {
            px.r = table[px.r];
            px.g = table[px.g];
            px.b = table[px.b];
            continue;
        }
        const a: u32 = px.a;
        px.r = remultiply(table[demultiply(px.r, a)], a);
        px.g = remultiply(table[demultiply(px.g, a)], a);
        px.b = remultiply(table[demultiply(px.b, a)], a);
    }
}

fn demultiply(v: u8, a: u32) u8 {
    const scaled = (@as(u32, v) * 255 + a / 2) / a;
    return @intCast(@min(scaled, 255));
}

fn remultiply(v: u8, a: u32) u8 {
    return @intCast((@as(u32, v) * a + 127) / 255);
}

/// Into linearRGB, which §15.3 makes the space a filter runs in by default.
pub fn toLinear(sfc: *z2d.Surface) void {
    mapColors(sfc, &to_linear);
}

/// Back to sRGB, which is what the canvas holds.
pub fn toSrgb(sfc: *z2d.Surface) void {
    mapColors(sfc, &to_srgb);
}

/// One sRGB channel in linearRGB, for a colour that is named rather than
/// sampled -- an `feFlood`'s, which never passes through a surface.
pub fn linearize(v: u8) u8 {
    return to_linear[v];
}

// -- blur --------------------------------------------------------------------

/// §15.17's `feGaussianBlur`: a Gaussian, convolved directly.
///
/// ## Why not the three box blurs
///
/// §15.17 offers them -- "if the `stdDeviation` is greater than 2.0, the
/// implementation *can* approximate the Gaussian blur with three successive
/// box-blurs" -- and the word is *can*. The normative definition is the
/// Gaussian itself, and the box approximation is a performance trade from an
/// era when a wide convolution was expensive. It is also about three percent
/// off, which on an eight-bit channel is a couple of levels across the whole
/// of a blurred edge.
///
/// resvg does neither: its kernel was measured against this one and is an
/// infinite-impulse-response approximation, narrower than a true Gaussian at
/// small deviations and indistinguishable from one by about `stdDeviation`
/// four. So there is no single answer that agrees with both the specification
/// and the oracle, and the specification wins. What that costs is written
/// down in the README and measured by the fixtures.
///
/// ## The region, and why the blur is given one
///
/// `within` is the filter region. Everything outside it counts as transparent
/// black rather than as more picture, which is what §15.7.5's "hard clip on
/// the filter input" means and is what makes a blur fade out at the region's
/// edge instead of reading pixels the region excluded.
pub fn gaussianBlur(
    gpa: Allocator,
    sfc: *z2d.Surface,
    within: PixelBox,
    sigma_x: f64,
    sigma_y: f64,
) Error!void {
    const box = within.intersect(extent(sfc));
    if (box.isEmpty()) return;
    const span_x: usize = @intCast(box.x1 - box.x0);
    const span_y: usize = @intCast(box.y1 - box.y0);

    const half_x = halfWidth(sigma_x, span_x);
    const half_y = halfWidth(sigma_y, span_y);
    if (half_x == 0 and half_y == 0) return;
    if (half_x > max_half or half_y > max_half) return error.BlurTooWide;

    const w: usize = @intCast(sfc.getWidth());
    const buf = pixels(sfc);

    // One scratch line and one kernel, reused down the whole picture.
    const line = try gpa.alloc(z2d.pixel.RGBA, @max(span_x, span_y));
    defer gpa.free(line);
    const weights = try gpa.alloc(f32, @max(half_x, half_y) * 2 + 1);
    defer gpa.free(weights);

    if (half_x != 0) {
        const k = kernel(weights, sigma_x, half_x);
        var y = box.y0;
        while (y < box.y1) : (y += 1) {
            const start: usize = @intCast(y * @as(i32, @intCast(w)) + box.x0);
            convolve(buf, start, 1, line[0..span_x], k, half_x);
        }
    }
    if (half_y != 0) {
        const k = kernel(weights, sigma_y, half_y);
        var x = box.x0;
        while (x < box.x1) : (x += 1) {
            const start: usize = @intCast(box.y0 * @as(i32, @intCast(w)) + x);
            convolve(buf, start, w, line[0..span_y], k, half_y);
        }
    }
}

/// The most taps a kernel may have either side of its centre. A blur wider
/// than this is a `stdDeviation` nothing sensible wrote, and the cost of a
/// direct convolution is linear in it.
const max_half = 1 << 12;

/// How far a Gaussian of this deviation has to reach.
///
/// Three and a half standard deviations, beyond which the weight is below one
/// part in two thousand and cannot move an eight-bit channel. Never further
/// than the line is long, because weights that fall entirely outside the
/// region multiply nothing.
fn halfWidth(sigma: f64, span: usize) usize {
    if (!(sigma > 0)) return 0;
    const want = @ceil(sigma * 3.5);
    if (want < 1) return 0;
    const cap: f64 = @floatFromInt(@min(span, max_half + 1));
    return @intFromFloat(@min(want, cap));
}

/// A normalized Gaussian sampled at whole-pixel offsets, into `out`.
fn kernel(out: []f32, sigma: f64, half: usize) []const f32 {
    const k = out[0 .. half * 2 + 1];
    const denom = 2.0 * sigma * sigma;
    var total: f64 = 0;
    for (k, 0..) |*slot, i| {
        const d = @as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(half));
        const v = @exp(-(d * d) / denom);
        slot.* = @floatCast(v);
        total += v;
    }
    const scale: f32 = @floatCast(1.0 / total);
    for (k) |*slot| slot.* *= scale;
    return k;
}

/// One line -- a row or a column -- convolved in place.
///
/// `stride` is how far apart the line's pixels are in the buffer, so a column
/// is the same code as a row with a stride of the surface's width. The line is
/// gathered into a contiguous buffer first, which is what lets the column case
/// run at the same speed as the row case rather than touching a new cache line
/// for every tap of every pixel.
fn convolve(
    buf: []z2d.pixel.RGBA,
    start: usize,
    stride: usize,
    line: []z2d.pixel.RGBA,
    k: []const f32,
    half: usize,
) void {
    const n = line.len;
    for (line, 0..) |*slot, i| slot.* = buf[start + i * stride];

    for (0..n) |i| {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        var a: f32 = 0;
        // Only the taps that land on the line: everything else is outside the
        // region and contributes nothing, which is what makes the edge fade.
        const lo = if (i < half) half - i else 0;
        const hi = @min(k.len, half + n - i);
        for (lo..hi) |t| {
            const px = line[i + t - half];
            const wgt = k[t];
            r += @as(f32, @floatFromInt(px.r)) * wgt;
            g += @as(f32, @floatFromInt(px.g)) * wgt;
            b += @as(f32, @floatFromInt(px.b)) * wgt;
            a += @as(f32, @floatFromInt(px.a)) * wgt;
        }
        buf[start + i * stride] = .{
            .r = roundByte(r),
            .g = roundByte(g),
            .b = roundByte(b),
            .a = roundByte(a),
        };
    }
}

fn roundByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

// -- tests -------------------------------------------------------------------

fn surfaceOf(gpa: Allocator, w: i32, h: i32) !z2d.Surface {
    return z2d.Surface.init(.image_surface_rgba, gpa, w, h);
}

fn at(sfc: *z2d.Surface, x: i32, y: i32) z2d.pixel.RGBA {
    const w = sfc.getWidth();
    return sfc.image_surface_rgba.buf[@intCast(y * w + x)];
}

test "a box blur of a single lit pixel spreads it and keeps its weight" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 33, 1);
    defer sfc.deinit(gpa);
    sfc.image_surface_rgba.buf[16] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    try gaussianBlur(gpa, &sfc, extent(&sfc), 2.0, 0);

    // Symmetric about the pixel it started on. An even box gets that only
    // because its first two passes straddle opposite sides; placing both the
    // same way shifts the whole line half a pixel, which this would catch.
    var i: i32 = 1;
    while (i <= 6) : (i += 1) {
        try testing.expectEqual(at(&sfc, 16 - i, 0).a, at(&sfc, 16 + i, 0).a);
    }
    try testing.expect(at(&sfc, 16, 0).a > at(&sfc, 17, 0).a);
    try testing.expect(at(&sfc, 17, 0).a > at(&sfc, 19, 0).a);
}

test "a blur of nothing is nothing, and a zero deviation changes nothing" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 8, 8);
    defer sfc.deinit(gpa);
    sfc.image_surface_rgba.buf[27] = .{ .r = 10, .g = 20, .b = 30, .a = 40 };

    // §15.17: a `stdDeviation` of zero disables the primitive, which is not
    // the same as it being an error.
    try gaussianBlur(gpa, &sfc, extent(&sfc), 0, 0);
    try testing.expectEqual(@as(u8, 40), sfc.image_surface_rgba.buf[27].a);

    // And one small enough that the box comes out empty does the same rather
    // than dividing by zero.
    try gaussianBlur(gpa, &sfc, extent(&sfc), 0.01, 0.01);
    try testing.expectEqual(@as(u8, 40), sfc.image_surface_rgba.buf[27].a);
}

test "a blur runs on each axis independently" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 17, 17);
    defer sfc.deinit(gpa);
    sfc.image_surface_rgba.buf[8 * 17 + 8] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    // `stdDeviation="2 0"` is horizontal only, which is the case a filter on a
    // rotated element makes visible: it blurs along the canvas rather than
    // along the element.
    try gaussianBlur(gpa, &sfc, extent(&sfc), 2.0, 0);
    try testing.expect(at(&sfc, 6, 8).a > 0);
    try testing.expectEqual(@as(u8, 0), at(&sfc, 8, 6).a);
}

test "the colour space round trip leaves alpha alone and is applied unpremultiplied" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 2, 1);
    defer sfc.deinit(gpa);
    // Opaque mid grey, and the same grey at half alpha -- premultiplied, so
    // its stored value is half as big.
    sfc.image_surface_rgba.buf[0] = .{ .r = 128, .g = 128, .b = 128, .a = 255 };
    sfc.image_surface_rgba.buf[1] = .{ .r = 64, .g = 64, .b = 64, .a = 128 };

    toLinear(&sfc);
    try testing.expectEqual(@as(u8, 255), at(&sfc, 0, 0).a);
    try testing.expectEqual(@as(u8, 128), at(&sfc, 1, 0).a);
    // sRGB 128 is a little over a fifth of the light, not a half. This is the
    // whole reason a filter looks wrong when the space is skipped.
    try testing.expectEqual(@as(u8, 55), at(&sfc, 0, 0).r);
    // The same colour at half alpha converts to the same colour, which is
    // only true because the curve is applied to the unpremultiplied value.
    try testing.expectApproxEqAbs(@as(f64, 55.0 / 2.0), @as(f64, @floatFromInt(at(&sfc, 1, 0).r)), 1.5);

    toSrgb(&sfc);
    try testing.expectEqual(@as(u8, 128), at(&sfc, 0, 0).r);
}

test "a transparent pixel has no colour to convert" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 1, 1);
    defer sfc.deinit(gpa);
    sfc.image_surface_rgba.buf[0] = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    toLinear(&sfc);
    try testing.expectEqual(z2d.pixel.RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 }, at(&sfc, 0, 0));
}

test "a subregion is a hard edge" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 8, 8);
    defer sfc.deinit(gpa);
    @memset(sfc.image_surface_rgba.buf, .{ .r = 255, .g = 255, .b = 255, .a = 255 });

    clipTo(&sfc, .{ .x0 = 2, .y0 = 3, .x1 = 6, .y1 = 5 });
    try testing.expectEqual(@as(u8, 255), at(&sfc, 2, 3).a);
    try testing.expectEqual(@as(u8, 255), at(&sfc, 5, 4).a);
    try testing.expectEqual(@as(u8, 0), at(&sfc, 1, 3).a);
    try testing.expectEqual(@as(u8, 0), at(&sfc, 6, 4).a);
    try testing.expectEqual(@as(u8, 0), at(&sfc, 2, 5).a);
}

test "an empty subregion covers nothing at all" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 4, 4);
    defer sfc.deinit(gpa);
    @memset(sfc.image_surface_rgba.buf, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    clipTo(&sfc, .{ .x0 = 2, .y0 = 2, .x1 = 2, .y1 = 3 });
    for (sfc.image_surface_rgba.buf) |px| try testing.expectEqual(@as(u8, 0), px.a);
}

test "an offset moves the picture and leaves transparency behind it" {
    const gpa = testing.allocator;
    var src = try surfaceOf(gpa, 8, 8);
    defer src.deinit(gpa);
    var dst = try surfaceOf(gpa, 8, 8);
    defer dst.deinit(gpa);
    src.image_surface_rgba.buf[2 * 8 + 3] = .{ .r = 9, .g = 9, .b = 9, .a = 99 };

    offset(&dst, &src, 2, 1);
    try testing.expectEqual(@as(u8, 99), at(&dst, 5, 3).a);
    try testing.expectEqual(@as(u8, 0), at(&dst, 3, 2).a);

    // Shifted off the canvas entirely rather than wrapping round it.
    offset(&dst, &src, -100, 0);
    for (dst.image_surface_rgba.buf) |px| try testing.expectEqual(@as(u8, 0), px.a);
}

test "a flood fills its subregion and nothing else" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 6, 6);
    defer sfc.deinit(gpa);
    flood(&sfc, .{ .r = 7, .g = 0, .b = 0, .a = 7 }, .{ .x0 = 1, .y0 = 1, .x1 = 3, .y1 = 3 });
    try testing.expectEqual(@as(u8, 7), at(&sfc, 1, 1).a);
    try testing.expectEqual(@as(u8, 7), at(&sfc, 2, 2).a);
    try testing.expectEqual(@as(u8, 0), at(&sfc, 3, 3).a);
    try testing.expectEqual(@as(u8, 0), at(&sfc, 0, 0).a);
}

test "SourceAlpha keeps the shape and throws the colour away" {
    const gpa = testing.allocator;
    var sfc = try surfaceOf(gpa, 2, 1);
    defer sfc.deinit(gpa);
    sfc.image_surface_rgba.buf[0] = .{ .r = 200, .g = 100, .b = 50, .a = 200 };
    alphaOnly(&sfc);
    try testing.expectEqual(z2d.pixel.RGBA{ .r = 0, .g = 0, .b = 0, .a = 200 }, at(&sfc, 0, 0));
}

test "boxes intersect and unite" {
    const a: PixelBox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 };
    const b: PixelBox = .{ .x0 = 5, .y0 = 5, .x1 = 20, .y1 = 8 };
    try testing.expectEqual(PixelBox{ .x0 = 5, .y0 = 5, .x1 = 10, .y1 = 8 }, a.intersect(b));
    try testing.expectEqual(PixelBox{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 10 }, a.unite(b));
    // An empty box unites to the other one rather than dragging it to zero,
    // which is what a chain with an input covering nothing needs.
    const empty: PixelBox = .{ .x0 = 3, .y0 = 3, .x1 = 3, .y1 = 3 };
    try testing.expectEqual(a, a.unite(empty));
    try testing.expect(a.intersect(empty).isEmpty());
}
