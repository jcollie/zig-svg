// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The pixel operations of the filter primitives beyond the four `image.zig`
//! has: SVG 1.1 §15.
//!
//! Each works on premultiplied 8-bit RGBA -- the only kind of surface a filter
//! chain holds -- over one `PixelBox`, the primitive's subregion, and leaves
//! the pixels outside it for the chain to clear. None of them allocate a
//! surface; the chain hands each one the buffers it is to write.
//!
//! ## Premultiplied or not
//!
//! §15 says per primitive which it means. The colour operations --
//! `feColorMatrix`, `feComponentTransfer` -- are defined on colour that is
//! *not* premultiplied, because a matrix that adds a constant to alpha would
//! otherwise have nothing to multiply the colour by. So they divide the alpha
//! out, work in floating point on values in `[0, 1]`, clamp, and multiply it
//! back in, rounding to nearest as z2d does rather than truncating.

const std = @import("std");
const testing = std.testing;

const z2d = @import("z2d");

const filter = @import("filter.zig");
const image = @import("image.zig");

const RGBA = z2d.pixel.RGBA;

/// A pixel with its alpha divided out, each channel in `[0, 1]`.
const Straight = [4]f32;

fn straight(px: RGBA) Straight {
    if (px.a == 0) return .{ 0, 0, 0, 0 };
    const a: f32 = @floatFromInt(px.a);
    return .{
        @min(@as(f32, @floatFromInt(px.r)) / a, 1),
        @min(@as(f32, @floatFromInt(px.g)) / a, 1),
        @min(@as(f32, @floatFromInt(px.b)) / a, 1),
        a / 255,
    };
}

fn premultiplied(c: Straight) RGBA {
    const a = std.math.clamp(c[3], 0, 1);
    return .{
        .r = byte(std.math.clamp(c[0], 0, 1) * a),
        .g = byte(std.math.clamp(c[1], 0, 1) * a),
        .b = byte(std.math.clamp(c[2], 0, 1) * a),
        .a = byte(a),
    };
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// Every pixel of `box`, in place.
fn eachPixel(sfc: *z2d.Surface, box: image.PixelBox, ctx: anytype, comptime f: fn (@TypeOf(ctx), RGBA) RGBA) void {
    const clipped = box.intersect(image.extent(sfc));
    if (clipped.isEmpty()) return;
    const w = sfc.getWidth();
    const buf = sfc.image_surface_rgba.buf;
    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        const row = buf[@intCast(y * w + clipped.x0)..@intCast(y * w + clipped.x1)];
        for (row) |*px| px.* = f(ctx, px.*);
    }
}

/// `feColorMatrix`, §15.10: every `type` has already been turned into the
/// matrix it stands for.
pub fn colorMatrix(sfc: *z2d.Surface, box: image.PixelBox, m: *const [20]f64) void {
    var mf: [20]f32 = undefined;
    for (&mf, m) |*d, s| d.* = @floatCast(s);
    eachPixel(sfc, box, &mf, applyMatrix);
}

fn applyMatrix(m: *const [20]f32, px: RGBA) RGBA {
    const c = straight(px);
    var out: Straight = undefined;
    for (0..4) |row| {
        const r = m[row * 5 ..][0..5];
        out[row] = r[0] * c[0] + r[1] * c[1] + r[2] * c[2] + r[3] * c[3] + r[4];
    }
    return premultiplied(out);
}

/// `feComponentTransfer`, §15.11: each channel through its own function, the
/// `tableValues` of each being a window into `numbers`.
pub fn componentTransfer(
    sfc: *z2d.Surface,
    box: image.PixelBox,
    funcs: *const [4]filter.TransferFunction,
    numbers: []const f64,
) void {
    // Each function is a map from 256 levels to 256 levels once the alpha is
    // divided out, so it is worked out once per level rather than per pixel.
    var tables: [4][256]f32 = undefined;
    for (&tables, funcs) |*table, f| {
        for (table, 0..) |*slot, level| {
            const c = @as(f64, @floatFromInt(level)) / 255;
            slot.* = @floatCast(std.math.clamp(transfer(f, numbers, c), 0, 1));
        }
    }
    eachPixel(sfc, box, &tables, applyTables);
}

fn applyTables(tables: *const [4][256]f32, px: RGBA) RGBA {
    const c = straight(px);
    var out: Straight = undefined;
    for (0..4) |i| out[i] = lookup(&tables[i], c[i]);
    return premultiplied(out);
}

/// A table indexed by a value in `[0, 1]`, interpolated between levels: the
/// straight value of a translucent pixel falls between them.
fn lookup(table: *const [256]f32, c: f32) f32 {
    const pos = std.math.clamp(c, 0, 1) * 255;
    const lo: usize = @intFromFloat(@floor(pos));
    if (lo >= 255) return table[255];
    const t = pos - @as(f32, @floatFromInt(lo));
    return table[lo] + (table[lo + 1] - table[lo]) * t;
}

/// One transfer function at one value. §15.11's five `type`s.
pub fn transfer(f: filter.TransferFunction, numbers: []const f64, c: f64) f64 {
    const v = numbers[f.first..][0..f.count];
    return switch (f.kind) {
        .identity => c,
        .table => blk: {
            if (v.len == 0) break :blk c;
            if (v.len == 1) break :blk v[0];
            const n: f64 = @floatFromInt(v.len - 1);
            const k: usize = @intFromFloat(@min(@floor(c * n), n - 1));
            const lo = @as(f64, @floatFromInt(k)) / n;
            break :blk v[k] + (c - lo) * n * (v[k + 1] - v[k]);
        },
        .discrete => blk: {
            if (v.len == 0) break :blk c;
            const n: f64 = @floatFromInt(v.len);
            const k: usize = @intFromFloat(@min(@floor(c * n), n - 1));
            break :blk v[k];
        },
        .linear => f.slope * c + f.intercept,
        .gamma => f.amplitude * std.math.pow(f64, c, f.exponent) + f.offset,
    };
}

/// Every pixel of `box` in `out`, from the same pixel of `a` and `b`.
fn eachPair(
    out: *z2d.Surface,
    a: *z2d.Surface,
    b: *z2d.Surface,
    box: image.PixelBox,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), RGBA, RGBA) RGBA,
) void {
    const clipped = box.intersect(image.extent(out));
    if (clipped.isEmpty()) return;
    const w = out.getWidth();
    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        const lo: usize = @intCast(y * w + clipped.x0);
        const hi: usize = @intCast(y * w + clipped.x1);
        for (out.image_surface_rgba.buf[lo..hi], a.image_surface_rgba.buf[lo..hi], b.image_surface_rgba.buf[lo..hi]) |*o, pa, pb| {
            o.* = f(ctx, pa, pb);
        }
    }
}

/// A premultiplied pixel as four fractions.
fn fractions(px: RGBA) [4]f32 {
    return .{
        @as(f32, @floatFromInt(px.r)) / 255,
        @as(f32, @floatFromInt(px.g)) / 255,
        @as(f32, @floatFromInt(px.b)) / 255,
        @as(f32, @floatFromInt(px.a)) / 255,
    };
}

/// Back to bytes, with the colour held to no more than the alpha so that the
/// pixel stays a premultiplied one.
fn fromFractions(c: [4]f32) RGBA {
    const a = std.math.clamp(c[3], 0, 1);
    return .{
        .r = byte(@min(std.math.clamp(c[0], 0, 1), a)),
        .g = byte(@min(std.math.clamp(c[1], 0, 1), a)),
        .b = byte(@min(std.math.clamp(c[2], 0, 1), a)),
        .a = byte(a),
    };
}

const CompositeArgs = struct { op: filter.CompositeOperator, k: [4]f32 };

/// `feComposite`, §15.12: `a` is `in`, `b` is `in2`, both premultiplied, and
/// the result goes to `out`.
pub fn composite(
    out: *z2d.Surface,
    a: *z2d.Surface,
    b: *z2d.Surface,
    box: image.PixelBox,
    op: filter.CompositeOperator,
    k: [4]f64,
) void {
    const args: CompositeArgs = .{ .op = op, .k = .{
        @floatCast(k[0]), @floatCast(k[1]), @floatCast(k[2]), @floatCast(k[3]),
    } };
    eachPair(out, a, b, box, args, compositePixel);
}

fn compositePixel(args: CompositeArgs, pa: RGBA, pb: RGBA) RGBA {
    const a = fractions(pa);
    const b = fractions(pb);
    // The Porter-Duff factors: how much of each input survives.
    const fa: f32, const fb: f32 = switch (args.op) {
        .over => .{ 1, 1 - a[3] },
        .in => .{ b[3], 0 },
        .out => .{ 1 - b[3], 0 },
        .atop => .{ b[3], 1 - a[3] },
        .xor => .{ 1 - b[3], 1 - a[3] },
        .lighter => .{ 1, 1 },
        .arithmetic => {
            // Every channel, alpha included, by the same polynomial, clamped;
            // then the colour held under the alpha.
            const k = args.k;
            var c: [4]f32 = undefined;
            for (0..4) |i| c[i] = k[0] * a[i] * b[i] + k[1] * a[i] + k[2] * b[i] + k[3];
            return fromFractions(c);
        },
    };
    var c: [4]f32 = undefined;
    for (0..4) |i| c[i] = a[i] * fa + b[i] * fb;
    return fromFractions(c);
}

/// `feBlend`: `a` is `in`, the source, blended over `b`, `in2`, the backdrop.
/// Compositing and Blending Level 1 §5, which Filter Effects 1 defers to.
pub fn blend(
    out: *z2d.Surface,
    a: *z2d.Surface,
    b: *z2d.Surface,
    box: image.PixelBox,
    mode: filter.BlendMode,
) void {
    eachPair(out, a, b, box, mode, blendPixel);
}

fn blendPixel(mode: filter.BlendMode, ps: RGBA, pb: RGBA) RGBA {
    const s = straight(ps);
    const b = straight(pb);
    const as = s[3];
    const ab = b[3];
    const mixed = blendColor(mode, .{ b[0], b[1], b[2] }, .{ s[0], s[1], s[2] });
    var c: [4]f32 = undefined;
    for (0..3) |i| {
        // §5.1: the source where the backdrop is not, the backdrop where the
        // source is not, and the blend where both are.
        c[i] = (1 - ab) * as * s[i] + (1 - as) * ab * b[i] + as * ab * mixed[i];
    }
    c[3] = as + ab - as * ab;
    return fromFractions(c);
}

/// B(Cb, Cs): the blended colour, straight, for each mode.
fn blendColor(mode: filter.BlendMode, cb: [3]f32, cs: [3]f32) [3]f32 {
    switch (mode) {
        .hue => return setLum(setSat(cs, sat(cb)), lum(cb)),
        .saturation => return setLum(setSat(cb, sat(cs)), lum(cb)),
        .color => return setLum(cs, lum(cb)),
        .luminosity => return setLum(cb, lum(cs)),
        else => {
            var out: [3]f32 = undefined;
            for (0..3) |i| out[i] = separable(mode, cb[i], cs[i]);
            return out;
        },
    }
}

fn separable(mode: filter.BlendMode, cb: f32, cs: f32) f32 {
    return switch (mode) {
        .normal => cs,
        .multiply => cb * cs,
        .screen => screen(cb, cs),
        .overlay => hardLight(cs, cb),
        .darken => @min(cb, cs),
        .lighten => @max(cb, cs),
        .color_dodge => if (cb == 0) 0 else if (cs >= 1) 1 else @min(1, cb / (1 - cs)),
        .color_burn => if (cb >= 1) 1 else if (cs == 0) 0 else 1 - @min(1, (1 - cb) / cs),
        .hard_light => hardLight(cb, cs),
        .soft_light => blk: {
            if (cs <= 0.5) break :blk cb - (1 - 2 * cs) * cb * (1 - cb);
            const d = if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb);
            break :blk cb + (2 * cs - 1) * (d - cb);
        },
        .difference => @abs(cb - cs),
        .exclusion => cb + cs - 2 * cb * cs,
        .hue, .saturation, .color, .luminosity => unreachable,
    };
}

fn screen(cb: f32, cs: f32) f32 {
    return cb + cs - cb * cs;
}

fn hardLight(cb: f32, cs: f32) f32 {
    return if (cs <= 0.5) cb * 2 * cs else screen(cb, 2 * cs - 1);
}

fn lum(c: [3]f32) f32 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

/// ClipColor, Compositing and Blending §5.9: a colour SetLum pushed out of
/// range is drawn back towards its luminance, not clamped.
///
/// resvg's tiny-skia 0.11.4 tests the *largest* channel where this tests the
/// smallest (`highp.rs`, `clip_color`), so it never pulls a negative channel
/// back and clamps it to nought instead. That is the whole of the difference
/// `filter-blend-nonseparable` measures, at up to fifty levels where a hue or
/// colour blend lands below black.
fn clipColor(c: [3]f32) [3]f32 {
    const l = lum(c);
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    var out = c;
    for (&out) |*v| {
        if (n < 0) v.* = l + (v.* - l) * l / (l - n);
        if (x > 1) v.* = l + (v.* - l) * (1 - l) / (x - l);
    }
    return out;
}

fn setLum(c: [3]f32, l: f32) [3]f32 {
    const d = l - lum(c);
    return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
}

fn sat(c: [3]f32) f32 {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
}

/// SetSat: the largest channel to `s`, the smallest to nought, the middle one
/// in proportion.
fn setSat(c: [3]f32, s: f32) [3]f32 {
    var idx = [3]usize{ 0, 1, 2 };
    std.mem.sort(usize, &idx, c, struct {
        fn lt(col: [3]f32, i: usize, j: usize) bool {
            return col[i] < col[j];
        }
    }.lt);
    var out: [3]f32 = .{ 0, 0, 0 };
    const lo = c[idx[0]];
    const mid = c[idx[1]];
    const hi = c[idx[2]];
    if (hi > lo) {
        out[idx[1]] = (mid - lo) * s / (hi - lo);
        out[idx[2]] = s;
    }
    return out;
}

/// `feTile`, §15.20: `out`'s `box` covered with copies of `tile`, the input's
/// subregion, lined up so that one copy sits exactly where the input was.
pub fn tile(out: *z2d.Surface, in: *z2d.Surface, tile_box: image.PixelBox, box: image.PixelBox) void {
    const t = tile_box.intersect(image.extent(in));
    const clipped = box.intersect(image.extent(out));
    if (t.isEmpty() or clipped.isEmpty()) return;
    const tw = t.x1 - t.x0;
    const th = t.y1 - t.y0;
    const w = out.getWidth();
    const src = in.image_surface_rgba.buf;
    const dst = out.image_surface_rgba.buf;
    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        const sy = t.y0 + @mod(y - t.y0, th);
        var x = clipped.x0;
        while (x < clipped.x1) : (x += 1) {
            const sx = t.x0 + @mod(x - t.x0, tw);
            dst[@intCast(y * w + x)] = src[@intCast(sy * w + sx)];
        }
    }
}

/// `feMorphology`, §15.18: every channel of `out` the least (erode) or the
/// greatest (dilate) of that channel of `in` over the `2rx+1` by `2ry+1`
/// rectangle centred on it. Pixels past the edge of the surface take no
/// part, rather than counting as transparent: an erosion does not eat in
/// from the edge of the canvas.
///
/// The rectangle is separable -- the extreme over a rectangle is the extreme
/// over its rows' extremes -- and each pass is van Herk and Gil-Werman's, so
/// a radius of a thousand costs what a radius of one does.
pub fn morphology(gpa: std.mem.Allocator, out: *z2d.Surface, in: *const z2d.Surface, dilate: bool, rx: u32, ry: u32) std.mem.Allocator.Error!void {
    const w: usize = @intCast(out.getWidth());
    const h: usize = @intCast(out.getHeight());
    const src = in.image_surface_rgba.buf;
    const dst = out.image_surface_rgba.buf;
    const longest = @max(w, h);
    const rmax = @max(@min(rx, w), @min(ry, h));
    // One line, padded by the radius either side, and the two running
    // extremes van Herk needs, per channel.
    const line = try gpa.alloc([4]u8, longest + 2 * rmax);
    defer gpa.free(line);
    const g = try gpa.alloc([4]u8, longest + 2 * rmax);
    defer gpa.free(g);
    const hh = try gpa.alloc([4]u8, longest + 2 * rmax);
    defer gpa.free(hh);
    const lines: Lines = .{ .line = line, .g = g, .h = hh, .dilate = dilate };

    // Across each row, from `in` into `out`...
    const r_x: usize = @min(rx, w);
    for (0..h) |y| {
        lines.run(src[y * w ..][0..w], 1, dst[y * w ..][0..w], 1, w, r_x);
    }
    // ...and down each column of `out`, in place: the line is copied out
    // before anything is written back.
    const r_y: usize = @min(ry, h);
    for (0..w) |x| {
        lines.run(dst[x..], w, dst[x..], w, h, r_y);
    }
}

const Lines = struct {
    line: [][4]u8,
    g: [][4]u8,
    h: [][4]u8,
    dilate: bool,

    fn pick(self: Lines, a: [4]u8, b: [4]u8) [4]u8 {
        var out: [4]u8 = undefined;
        for (0..4) |i| out[i] = if (self.dilate) @max(a[i], b[i]) else @min(a[i], b[i]);
        return out;
    }

    /// `n` pixels `stride` apart from `from`, each replaced in `to` by the
    /// extreme over the `2r+1` of them centred on it.
    fn run(self: Lines, from: []const RGBA, from_stride: usize, to: []RGBA, to_stride: usize, n: usize, r: usize) void {
        if (r == 0) {
            if (from.ptr != to.ptr) for (0..n) |i| {
                to[i * to_stride] = from[i * from_stride];
            };
            return;
        }
        // The identity of the operation beyond each end, so that every
        // window is full length and the edges need no case of their own.
        const pad: [4]u8 = if (self.dilate) .{ 0, 0, 0, 0 } else .{ 255, 255, 255, 255 };
        const len = n + 2 * r;
        const f = self.line[0..len];
        @memset(f[0..r], pad);
        @memset(f[r + n ..], pad);
        for (0..n) |i| {
            const px = from[i * from_stride];
            f[r + i] = .{ px.r, px.g, px.b, px.a };
        }
        const k = 2 * r + 1;
        const g = self.g[0..len];
        const h = self.h[0..len];
        for (0..len) |i| {
            g[i] = if (i % k == 0) f[i] else self.pick(g[i - 1], f[i]);
        }
        var i = len;
        while (i > 0) {
            i -= 1;
            h[i] = if (i == len - 1 or (i + 1) % k == 0) f[i] else self.pick(h[i + 1], f[i]);
        }
        // The window for output `j` is `f[j .. j + k]`: a suffix of one block
        // and a prefix of the next.
        for (0..n) |j| {
            const v = self.pick(h[j], g[j + k - 1]);
            to[j * to_stride] = .{ .r = v[0], .g = v[1], .b = v[2], .a = v[3] };
        }
    }
};

// -- tests -------------------------------------------------------------------

fn surfaceOf(px: RGBA) !z2d.Surface {
    const sfc = try z2d.Surface.init(.image_surface_rgba, testing.allocator, 2, 1);
    @memset(sfc.image_surface_rgba.buf, px);
    return sfc;
}

test "a colour matrix works on colour with the alpha divided out" {
    // Half-transparent red; the matrix swaps red and green and adds a quarter
    // to alpha.
    var sfc = try surfaceOf(.{ .r = 128, .g = 0, .b = 0, .a = 128 });
    defer sfc.deinit(testing.allocator);
    const m: [20]f64 = .{
        0, 1, 0, 0, 0,
        1, 0, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0.25,
    };
    colorMatrix(&sfc, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }, &m);
    const px = sfc.image_surface_rgba.buf[0];
    // Alpha 128/255 + 0.25 is 0.752, so green at full strength is 192.
    try testing.expectEqual(RGBA{ .r = 0, .g = 192, .b = 0, .a = 192 }, px);
    // Outside the box, untouched.
    try testing.expectEqual(RGBA{ .r = 128, .g = 0, .b = 0, .a = 128 }, sfc.image_surface_rgba.buf[1]);
}

test "a matrix can make a transparent pixel opaque" {
    var sfc = try surfaceOf(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer sfc.deinit(testing.allocator);
    var m: [20]f64 = @splat(0);
    m[4] = 1;
    m[19] = 1;
    colorMatrix(&sfc, image.extent(&sfc), &m);
    try testing.expectEqual(RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 }, sfc.image_surface_rgba.buf[0]);
}

test "each transfer function, at the points §15.11 defines it by" {
    const numbers = [_]f64{ 0, 1, 0.5, 0.25, 0.75 };
    const table: filter.TransferFunction = .{ .kind = .table, .first = 0, .count = 3 };
    try testing.expectApproxEqAbs(@as(f64, 0), transfer(table, &numbers, 0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), transfer(table, &numbers, 0.25), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), transfer(table, &numbers, 0.5), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), transfer(table, &numbers, 1), 1e-12);
    const discrete: filter.TransferFunction = .{ .kind = .discrete, .first = 3, .count = 2 };
    try testing.expectEqual(@as(f64, 0.25), transfer(discrete, &numbers, 0.49));
    try testing.expectEqual(@as(f64, 0.75), transfer(discrete, &numbers, 0.5));
    try testing.expectEqual(@as(f64, 0.75), transfer(discrete, &numbers, 1));
    const empty: filter.TransferFunction = .{ .kind = .table };
    try testing.expectEqual(@as(f64, 0.3), transfer(empty, &numbers, 0.3));
    try testing.expectApproxEqAbs(@as(f64, 0.7), transfer(.{ .kind = .linear, .slope = 2, .intercept = 0.1 }, &numbers, 0.3), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), transfer(.{ .kind = .gamma, .amplitude = 2, .exponent = 2, .offset = 0 }, &numbers, 0.5), 1e-12);
}

test "a component transfer clamps what its functions give" {
    var sfc = try surfaceOf(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    defer sfc.deinit(testing.allocator);
    const funcs = [4]filter.TransferFunction{
        .{ .kind = .linear, .slope = 2 },
        .{ .kind = .linear, .intercept = -1 },
        .{ .kind = .linear, .intercept = 0.5 },
        .{},
    };
    componentTransfer(&sfc, image.extent(&sfc), &funcs, &.{});
    try testing.expectEqual(RGBA{ .r = 255, .g = 0, .b = 128, .a = 255 }, sfc.image_surface_rgba.buf[0]);
}

fn pairOf(a: RGBA, b: RGBA) !struct { z2d.Surface, z2d.Surface, z2d.Surface } {
    return .{ try surfaceOf(a), try surfaceOf(b), try surfaceOf(.{ .r = 0, .g = 0, .b = 0, .a = 0 }) };
}

test "each Porter-Duff operator keeps what §15.12 says it keeps" {
    // Half-opaque red over opaque blue.
    const red: RGBA = .{ .r = 128, .g = 0, .b = 0, .a = 128 };
    const blue: RGBA = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const cases = [_]struct { filter.CompositeOperator, RGBA }{
        .{ .over, .{ .r = 128, .g = 0, .b = 127, .a = 255 } },
        .{ .in, red },
        .{ .out, .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        .{ .atop, .{ .r = 128, .g = 0, .b = 127, .a = 255 } },
        .{ .xor, .{ .r = 0, .g = 0, .b = 127, .a = 127 } },
        .{ .lighter, .{ .r = 128, .g = 0, .b = 255, .a = 255 } },
    };
    for (cases) |case| {
        var a, var b, var out = try pairOf(red, blue);
        defer a.deinit(testing.allocator);
        defer b.deinit(testing.allocator);
        defer out.deinit(testing.allocator);
        composite(&out, &a, &b, image.extent(&out), case[0], @splat(0));
        try testing.expectEqual(case[1], out.image_surface_rgba.buf[0]);
    }
}

test "arithmetic clamps, and keeps the colour under the alpha" {
    // Opaque red with opaque black: `k1*i1*i2` is nothing in the colour
    // channels and everything in alpha, so taking half of it back leaves red
    // at full strength over an alpha of a half -- which is held to a half.
    var a, var b, var out = try pairOf(.{ .r = 255, .g = 0, .b = 0, .a = 255 }, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer a.deinit(testing.allocator);
    defer b.deinit(testing.allocator);
    defer out.deinit(testing.allocator);
    composite(&out, &a, &b, image.extent(&out), .arithmetic, .{ -0.5, 1, 0, 0 });
    try testing.expectEqual(RGBA{ .r = 128, .g = 0, .b = 0, .a = 128 }, out.image_surface_rgba.buf[0]);
    // And past one it clamps.
    composite(&out, &a, &b, image.extent(&out), .arithmetic, .{ 0, 2, 2, 0.5 });
    try testing.expectEqual(RGBA{ .r = 255, .g = 128, .b = 128, .a = 255 }, out.image_surface_rgba.buf[0]);
}

test "blending an opaque source over an opaque backdrop is the mode's colour" {
    const s: RGBA = .{ .r = 255, .g = 128, .b = 0, .a = 255 };
    const bd: RGBA = .{ .r = 128, .g = 128, .b = 128, .a = 255 };
    const cases = [_]struct { filter.BlendMode, RGBA }{
        .{ .normal, s },
        .{ .multiply, .{ .r = 128, .g = 64, .b = 0, .a = 255 } },
        .{ .screen, .{ .r = 255, .g = 192, .b = 128, .a = 255 } },
        .{ .darken, .{ .r = 128, .g = 128, .b = 0, .a = 255 } },
        .{ .lighten, .{ .r = 255, .g = 128, .b = 128, .a = 255 } },
        .{ .difference, .{ .r = 127, .g = 0, .b = 128, .a = 255 } },
        // A grey backdrop has no saturation, so its hue is the source's at
        // none: grey, at the backdrop's luminance.
        .{ .saturation, bd },
    };
    for (cases) |case| {
        var a, var b, var out = try pairOf(s, bd);
        defer a.deinit(testing.allocator);
        defer b.deinit(testing.allocator);
        defer out.deinit(testing.allocator);
        blend(&out, &a, &b, image.extent(&out), case[0]);
        const got = out.image_surface_rgba.buf[0];
        errdefer std.debug.print("{t}: {any}\n", .{ case[0], got });
        try testing.expect(@abs(@as(i32, got.r) - case[1].r) <= 1);
        try testing.expect(@abs(@as(i32, got.g) - case[1].g) <= 1);
        try testing.expect(@abs(@as(i32, got.b) - case[1].b) <= 1);
        try testing.expectEqual(case[1].a, got.a);
    }
}

test "a blend over nothing is the source, and nothing over a backdrop is the backdrop" {
    const s: RGBA = .{ .r = 100, .g = 50, .b = 0, .a = 128 };
    const none: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    inline for (.{ .{ s, none, s }, .{ none, s, s } }) |case| {
        var a, var b, var out = try pairOf(case[0], case[1]);
        defer a.deinit(testing.allocator);
        defer b.deinit(testing.allocator);
        defer out.deinit(testing.allocator);
        blend(&out, &a, &b, image.extent(&out), .multiply);
        const got = out.image_surface_rgba.buf[0];
        try testing.expect(@abs(@as(i32, got.r) - case[2].r) <= 1);
        try testing.expect(@abs(@as(i32, got.g) - case[2].g) <= 1);
        try testing.expectEqual(case[2].a, got.a);
    }
}

test "a tile repeats the input's subregion, lined up with where it was" {
    const gpa = testing.allocator;
    var in = try z2d.Surface.init(.image_surface_rgba, gpa, 6, 1);
    defer in.deinit(gpa);
    var out = try z2d.Surface.init(.image_surface_rgba, gpa, 6, 1);
    defer out.deinit(gpa);
    const buf = in.image_surface_rgba.buf;
    buf[2] = .{ .r = 1, .g = 0, .b = 0, .a = 255 };
    buf[3] = .{ .r = 2, .g = 0, .b = 0, .a = 255 };
    tile(&out, &in, .{ .x0 = 2, .y0 = 0, .x1 = 4, .y1 = 1 }, image.extent(&out));
    var reds: [6]u8 = undefined;
    for (out.image_surface_rgba.buf, &reds) |px, *r| r.* = px.r;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 1, 2, 1, 2 }, &reds);
}

test "morphology takes the extreme over a centred window, the edge taking no part" {
    const gpa = testing.allocator;
    var in = try z2d.Surface.init(.image_surface_rgba, gpa, 9, 1);
    defer in.deinit(gpa);
    const buf = in.image_surface_rgba.buf;
    // Opaque from 3 to 5, and one brighter pixel at 4.
    for (buf[3..6]) |*px| px.* = .{ .r = 10, .g = 0, .b = 0, .a = 255 };
    buf[4].r = 200;
    buf[0] = .{ .r = 5, .g = 0, .b = 0, .a = 255 };

    var out = try in.clone(gpa);
    defer out.deinit(gpa);
    try morphology(gpa, &out, &in, true, 1, 0);
    var alphas: [9]u8 = undefined;
    for (out.image_surface_rgba.buf, &alphas) |px, *a| a.* = px.a;
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 255, 255, 255, 0, 0 }, &alphas);
    try testing.expectEqual(@as(u8, 200), out.image_surface_rgba.buf[5].r);

    try morphology(gpa, &out, &in, false, 1, 0);
    for (out.image_surface_rgba.buf, &alphas) |px, *a| a.* = px.a;
    // Pixel 0 keeps its alpha: past the edge counts for nothing.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 255, 0, 0, 0, 0 }, &alphas);
    try testing.expectEqual(@as(u8, 10), out.image_surface_rgba.buf[4].r);
}

test "a radius wider than the picture is the extreme over all of it" {
    const gpa = testing.allocator;
    var in = try z2d.Surface.init(.image_surface_rgba, gpa, 3, 3);
    defer in.deinit(gpa);
    in.image_surface_rgba.buf[4] = .{ .r = 9, .g = 9, .b = 9, .a = 9 };
    var out = try in.clone(gpa);
    defer out.deinit(gpa);
    try morphology(gpa, &out, &in, true, 1000, 1000);
    for (out.image_surface_rgba.buf) |px| try testing.expectEqual(@as(u8, 9), px.a);
}
