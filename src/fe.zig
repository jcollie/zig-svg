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

/// `feConvolveMatrix`, §15.13: every pixel of `box` in `out` the weighted sum
/// of the `order_x` by `order_y` pixels of `in` around it, the kernel turned
/// through a half turn as convolution has it, divided by the divisor and
/// offset by the bias.
///
/// `bounds` is the image the primitive is given -- the filter region -- and
/// `edge` says what lies past it: the nearest pixel on the edge, the pixel
/// from the far side, or transparent black. With `preserve_alpha` the
/// colour is convolved with the alpha divided out and the alpha is kept;
/// without it, every channel is convolved as it is, premultiplied.
pub fn convolve(
    out: *z2d.Surface,
    in: *const z2d.Surface,
    bounds: image.PixelBox,
    box: image.PixelBox,
    c: filter.ConvolveMatrix,
    kernel: []const f64,
) void {
    const b = bounds.intersect(image.extent(in));
    const clipped = box.intersect(b);
    if (clipped.isEmpty()) return;
    const w = in.getWidth();
    const src = in.image_surface_rgba.buf;
    const dst = out.image_surface_rgba.buf;
    const ox: i32 = @intCast(c.order_x);
    const oy: i32 = @intCast(c.order_y);
    const tx: i32 = @intCast(c.target_x);
    const ty: i32 = @intCast(c.target_y);
    const divisor: f32 = @floatCast(c.divisor);
    const bias: f32 = @floatCast(c.bias);

    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        var x = clipped.x0;
        while (x < clipped.x1) : (x += 1) {
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            var j: i32 = 0;
            while (j < oy) : (j += 1) {
                var i: i32 = 0;
                while (i < ox) : (i += 1) {
                    const sx = edgeOf(c.edge, x - tx + i, b.x0, b.x1) orelse continue;
                    const sy = edgeOf(c.edge, y - ty + j, b.y0, b.y1) orelse continue;
                    const k: f32 = @floatCast(kernel[@intCast((oy - 1 - j) * ox + (ox - 1 - i))]);
                    const px = src[@intCast(sy * w + sx)];
                    const v = if (c.preserve_alpha) straight(px) else fractions(px);
                    for (0..4) |ch| sum[ch] += v[ch] * k;
                }
            }
            const here = src[@intCast(y * w + x)];
            // Alpha first, since the bias is scaled by it -- by the value
            // before it is clamped, as resvg has it.
            const alpha = if (c.preserve_alpha)
                @as(f32, @floatFromInt(here.a)) / 255
            else
                sum[3] / divisor + bias;
            const a = std.math.clamp(alpha, 0, 1);
            var result: [4]f32 = undefined;
            for (0..3) |ch| {
                const v = sum[ch] / divisor + bias * alpha;
                result[ch] = if (c.preserve_alpha) std.math.clamp(v, 0, 1) * a else std.math.clamp(v, 0, a);
            }
            result[3] = a;
            dst[@intCast(y * w + x)] = fromFractions(result);
        }
    }
}

/// Where a coordinate past the edge of `[lo, hi)` reads from, or null for
/// transparent black.
fn edgeOf(mode: filter.EdgeMode, v: i32, lo: i32, hi: i32) ?i32 {
    if (v >= lo and v < hi) return v;
    return switch (mode) {
        .duplicate => std.math.clamp(v, lo, hi - 1),
        .wrap => lo + @mod(v - lo, hi - lo),
        .none => null,
    };
}

/// `feDisplacementMap`, §15.15: every pixel of `box` in `out` fetched from
/// `in` at an offset of `scale` times how far a channel of `map` is from a
/// half -- the map's colour with its alpha divided out, as the specification
/// says. `scale` is in canvas pixels, per axis. A fetch from outside
/// `bounds`, the image the primitive is given, is transparent black.
///
/// The nearest pixel is fetched, as resvg does, rather than interpolating
/// between four: the specification leaves it open, and a displacement map is
/// usually noise, where the difference does not show.
pub fn displace(
    out: *z2d.Surface,
    in: *const z2d.Surface,
    map: *const z2d.Surface,
    bounds: image.PixelBox,
    box: image.PixelBox,
    scale: [2]f64,
    x_channel: u2,
    y_channel: u2,
) void {
    const b = bounds.intersect(image.extent(in));
    const clipped = box.intersect(b);
    if (clipped.isEmpty()) return;
    const w = in.getWidth();
    const src = in.image_surface_rgba.buf;
    const m = map.image_surface_rgba.buf;
    const dst = out.image_surface_rgba.buf;
    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        var x = clipped.x0;
        while (x < clipped.x1) : (x += 1) {
            const c = straight(m[@intCast(y * w + x)]);
            const fx = @as(f64, @floatFromInt(x)) + scale[0] * (@as(f64, c[x_channel]) - 0.5);
            const fy = @as(f64, @floatFromInt(y)) + scale[1] * (@as(f64, c[y_channel]) - 0.5);
            if (!std.math.isFinite(fx) or !std.math.isFinite(fy)) continue;
            const sx = @round(fx);
            const sy = @round(fy);
            if (sx < @as(f64, @floatFromInt(b.x0)) or sx >= @as(f64, @floatFromInt(b.x1)) or
                sy < @as(f64, @floatFromInt(b.y0)) or sy >= @as(f64, @floatFromInt(b.y1))) continue;
            dst[@intCast(y * w + x)] = src[@as(usize, @intFromFloat(sy)) * @as(usize, @intCast(w)) + @as(usize, @intFromFloat(sx))];
        }
    }
}

/// How a canvas pixel maps back to the user space the noise is a function
/// of: its position less `origin`, divided by `scale`.
pub const NoiseSpace = struct {
    origin_x: f64,
    origin_y: f64,
    scale_x: f64,
    scale_y: f64,
};

/// `feTurbulence`, §15.23: every pixel of `box` in `out` a sample of Perlin
/// noise, one independent noise per channel.
///
/// This is the reference code the specification gives, ported as it stands --
/// the generator, the lattice, the gradients and the stitching arithmetic
/// down to the order of the operations -- because any other noise, however
/// good, is a different picture. Each pixel is sampled at its corner mapped
/// into user space, which is where resvg samples it too. With `stitch` the
/// frequencies are nudged so that the noise tiles across the primitive's
/// subregion, in user space as §15.23 says.
///
/// The noise is straight colour in the primitive's colour space, and is
/// multiplied by its own alpha on the way into the surface.
pub fn turbulence(out: *z2d.Surface, box: image.PixelBox, t: filter.Turbulence, space: NoiseSpace) void {
    const clipped = box.intersect(image.extent(out));
    if (clipped.isEmpty() or !(space.scale_x > 0) or !(space.scale_y > 0)) return;
    const noise: Noise = .init(t.seed);
    const w = out.getWidth();
    const dst = out.image_surface_rgba.buf;
    // The stitching stitch_tile is the subregion, taken into user space.
    const stitch_tile: [4]f64 = .{
        (@as(f64, @floatFromInt(clipped.x0)) - space.origin_x) / space.scale_x,
        (@as(f64, @floatFromInt(clipped.y0)) - space.origin_y) / space.scale_y,
        @as(f64, @floatFromInt(clipped.x1 - clipped.x0)) / space.scale_x,
        @as(f64, @floatFromInt(clipped.y1 - clipped.y0)) / space.scale_y,
    };
    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        var x = clipped.x0;
        while (x < clipped.x1) : (x += 1) {
            const point: [2]f64 = .{
                (@as(f64, @floatFromInt(x)) - space.origin_x) / space.scale_x,
                (@as(f64, @floatFromInt(y)) - space.origin_y) / space.scale_y,
            };
            var c: [4]f32 = undefined;
            for (0..4) |ch| {
                const n = noise.turbulence(ch, point, stitch_tile, t);
                const v = if (t.fractal_noise) (n + 1) / 2 else n;
                c[ch] = @floatCast(std.math.clamp(v, 0, 1));
            }
            dst[@intCast(y * w + x)] = premultiplied(c);
        }
    }
}

const b_size = 0x100;
const b_len = b_size + b_size + 2;
const bm = 0xff;
const perlin_n = 0x1000;
const rand_m: i32 = 2147483647;
const rand_a: i32 = 16807;
const rand_q: i32 = 127773;
const rand_r: i32 = 2836;

/// The reference code's lattice and gradients, for one seed.
const Noise = struct {
    lattice: [b_len]usize,
    gradient: [4][b_len][2]f64,

    fn random(seed: i32) i32 {
        var result = rand_a * @rem(seed, rand_q) - rand_r * @divTrunc(seed, rand_q);
        if (result <= 0) result += rand_m;
        return result;
    }

    fn init(seed_in: i32) Noise {
        var self: Noise = undefined;
        var seed = seed_in;
        if (seed <= 0) seed = @rem(-seed, rand_m - 1) + 1;
        if (seed > rand_m - 1) seed = rand_m - 1;
        for (0..4) |k| {
            for (0..b_size) |i| {
                self.lattice[i] = i;
                for (0..2) |j| {
                    seed = random(seed);
                    self.gradient[k][i][j] = @as(f64, @floatFromInt(@rem(seed, b_size + b_size) - b_size)) / b_size;
                }
                const g = &self.gradient[k][i];
                const len = @sqrt(g[0] * g[0] + g[1] * g[1]);
                g[0] /= len;
                g[1] /= len;
            }
        }
        var i: usize = b_size - 1;
        while (i > 0) : (i -= 1) {
            const k = self.lattice[i];
            seed = random(seed);
            const j: usize = @intCast(@rem(seed, b_size));
            self.lattice[i] = self.lattice[j];
            self.lattice[j] = k;
        }
        for (0..b_size + 2) |n| {
            self.lattice[b_size + n] = self.lattice[n];
            for (0..4) |k| self.gradient[k][b_size + n] = self.gradient[k][n];
        }
        return self;
    }

    const Stitch = struct { width: i32, height: i32, wrap_x: i32, wrap_y: i32 };

    fn noise2(self: *const Noise, ch: usize, x: f64, y: f64, stitch: ?Stitch) f64 {
        const tx = x + perlin_n;
        var bx0: i32 = truncate(tx);
        var bx1 = bx0 +% 1;
        const rx0 = tx - @trunc(tx);
        const rx1 = rx0 - 1;
        const ty = y + perlin_n;
        var by0: i32 = truncate(ty);
        var by1 = by0 +% 1;
        const ry0 = ty - @trunc(ty);
        const ry1 = ry0 - 1;
        if (stitch) |st| {
            if (bx0 >= st.wrap_x) bx0 -%= st.width;
            if (bx1 >= st.wrap_x) bx1 -%= st.width;
            if (by0 >= st.wrap_y) by0 -%= st.height;
            if (by1 >= st.wrap_y) by1 -%= st.height;
        }
        const i = self.lattice[@intCast(bx0 & bm)];
        const j = self.lattice[@intCast(bx1 & bm)];
        const b00 = self.lattice[i + @as(usize, @intCast(by0 & bm))];
        const b10 = self.lattice[j + @as(usize, @intCast(by0 & bm))];
        const b01 = self.lattice[i + @as(usize, @intCast(by1 & bm))];
        const b11 = self.lattice[j + @as(usize, @intCast(by1 & bm))];
        const sx = sCurve(rx0);
        const sy = sCurve(ry0);
        const g = &self.gradient[ch];
        const a = lerp(sx, rx0 * g[b00][0] + ry0 * g[b00][1], rx1 * g[b10][0] + ry0 * g[b10][1]);
        const b = lerp(sx, rx0 * g[b01][0] + ry1 * g[b01][1], rx1 * g[b11][0] + ry1 * g[b11][1]);
        return lerp(sy, a, b);
    }

    fn turbulence(self: *const Noise, ch: usize, point: [2]f64, stitch_tile: [4]f64, t: filter.Turbulence) f64 {
        var fx = t.base_frequency_x;
        var fy = t.base_frequency_y;
        var stitch: ?Stitch = null;
        if (t.stitch) {
            // Nudge each frequency to the nearer of the two that make a
            // whole number of periods across the stitch_tile.
            if (fx != 0) fx = nearestWhole(fx, stitch_tile[2]);
            if (fy != 0) fy = nearestWhole(fy, stitch_tile[3]);
            const sw = truncate(stitch_tile[2] * fx + 0.5);
            const sh = truncate(stitch_tile[3] * fy + 0.5);
            stitch = .{
                .width = sw,
                .height = sh,
                .wrap_x = truncate(stitch_tile[0] * fx + perlin_n + @as(f64, @floatFromInt(sw))),
                .wrap_y = truncate(stitch_tile[1] * fy + perlin_n + @as(f64, @floatFromInt(sh))),
            };
        }
        var sum: f64 = 0;
        var x = point[0] * fx;
        var y = point[1] * fy;
        var ratio: f64 = 1;
        for (0..t.octaves) |_| {
            const n = self.noise2(ch, x, y, stitch);
            sum += (if (t.fractal_noise) n else @abs(n)) / ratio;
            x *= 2;
            y *= 2;
            ratio *= 2;
            if (stitch) |*st| {
                // Subtracting perlin_n before the doubling and adding it back
                // after comes to subtracting it once.
                st.width *%= 2;
                st.wrap_x = 2 *% st.wrap_x -% perlin_n;
                st.height *%= 2;
                st.wrap_y = 2 *% st.wrap_y -% perlin_n;
            }
        }
        return sum;
    }

    fn nearestWhole(freq: f64, size: f64) f64 {
        const lo = @floor(size * freq) / size;
        const hi = @ceil(size * freq) / size;
        return if (freq / lo < hi / freq) lo else hi;
    }

    fn sCurve(v: f64) f64 {
        return v * v * (3 - 2 * v);
    }

    fn lerp(tt: f64, a: f64, b: f64) f64 {
        return a + tt * (b - a);
    }

    /// C's conversion to an integer, towards zero, held inside `i32` so
    /// that an absurd frequency wraps the lattice rather than trapping.
    fn truncate(v: f64) i32 {
        if (!std.math.isFinite(v)) return 0;
        return @intFromFloat(std.math.clamp(@trunc(v), -2147483648.0, 2147483647.0));
    }
};

/// A light source in canvas pixels, as `light` takes it.
pub const Light = union(enum) {
    /// Azimuth and elevation, in degrees.
    distant: [2]f64,
    point: [3]f64,
    spot: struct { at: [3]f64, points_at: [3]f64, exponent: f64, cone: ?f64 },
};

pub const Lighting = struct {
    specular: bool,
    surface_scale: f64,
    /// `diffuseConstant` or `specularConstant`.
    constant: f64,
    exponent: f64,
    /// `lighting-color` in the primitive's colour space.
    color: [3]f32,
    light: Light,
};

/// `feDiffuseLighting` and `feSpecularLighting`, §15.14 and §15.22: the alpha
/// of `in` taken as a height field, lit, over the pixels of `box` in `out`.
///
/// The surface normal is §15.14's Sobel operator, with its own kernels where
/// the image stops -- at the edges and corners of `bounds`, the image the
/// primitive is given. Those kernels all come to one rule: each difference
/// is taken across whichever of the two neighbours exist, weighted 1-2-1 down
/// whichever rows exist, and scaled by two over the product of the weights
/// and the distance. That gives the specification's `1/4`, `1/3`, `1/2` and
/// `2/3` exactly, without eight functions to say so.
///
/// Every pixel is its corner, as resvg has it. A diffuse result is opaque;
/// a specular one takes the greatest of its channels as its alpha, and its
/// colour as already premultiplied by it, as Skia and resvg both do.
pub fn light(out: *z2d.Surface, in: *const z2d.Surface, bounds: image.PixelBox, box: image.PixelBox, l: Lighting) void {
    const b = bounds.intersect(image.extent(in));
    const clipped = box.intersect(b);
    if (clipped.isEmpty()) return;
    const w = in.getWidth();
    const src = in.image_surface_rgba.buf;
    const dst = out.image_surface_rgba.buf;
    const alphaAt = struct {
        fn f(buf: []const RGBA, width: i32, x: i32, y: i32) f64 {
            return @as(f64, @floatFromInt(buf[@intCast(y * width + x)].a)) / 255;
        }
    }.f;

    // A distant light's direction is the same everywhere.
    const distant: [3]f64 = switch (l.light) {
        .distant => |d| blk: {
            const az = std.math.degreesToRadians(d[0]);
            const el = std.math.degreesToRadians(d[1]);
            break :blk .{ @cos(az) * @cos(el), @sin(az) * @cos(el), @sin(el) };
        },
        else => .{ 0, 0, 1 },
    };
    const spot_axis: ?[3]f64 = switch (l.light) {
        .spot => |sp| normalize(.{ sp.points_at[0] - sp.at[0], sp.points_at[1] - sp.at[1], sp.points_at[2] - sp.at[2] }),
        else => null,
    };

    var y = clipped.y0;
    while (y < clipped.y1) : (y += 1) {
        var x = clipped.x0;
        while (x < clipped.x1) : (x += 1) {
            // The normal.
            const left = if (x - 1 >= b.x0) x - 1 else x;
            const right = if (x + 1 < b.x1) x + 1 else x;
            const up = if (y - 1 >= b.y0) y - 1 else y;
            const down = if (y + 1 < b.y1) y + 1 else y;
            var nx: f64 = 0;
            var wx: f64 = 0;
            var r = up;
            while (r <= down) : (r += 1) {
                const weight: f64 = if (r == y) 2 else 1;
                nx += weight * (alphaAt(src, w, right, r) - alphaAt(src, w, left, r));
                wx += weight;
            }
            var ny: f64 = 0;
            var wy: f64 = 0;
            var c = left;
            while (c <= right) : (c += 1) {
                const weight: f64 = if (c == x) 2 else 1;
                ny += weight * (alphaAt(src, w, c, down) - alphaAt(src, w, c, up));
                wy += weight;
            }
            const dx: f64 = @floatFromInt(right - left);
            const dy: f64 = @floatFromInt(down - up);
            const fx = if (dx > 0) 2 / (wx * dx) else 0;
            const fy = if (dy > 0) 2 / (wy * dy) else 0;
            const normal = normalize(.{ -l.surface_scale * fx * nx, -l.surface_scale * fy * ny, 1 }) orelse .{ 0, 0, 1 };

            // The light's direction, and its colour here.
            const z = l.surface_scale * alphaAt(src, w, x, y);
            const fxp: f64 = @floatFromInt(x);
            const fyp: f64 = @floatFromInt(y);
            const dir: [3]f64 = switch (l.light) {
                .distant => distant,
                .point => |pt| unitOr(.{ pt[0] - fxp, pt[1] - fyp, pt[2] - z }),
                .spot => |sp| unitOr(.{ sp.at[0] - fxp, sp.at[1] - fyp, sp.at[2] - z }),
            };
            var tint: [3]f64 = .{ l.color[0], l.color[1], l.color[2] };
            if (l.light == .spot) {
                const sp = l.light.spot;
                const along = if (spot_axis) |s| -dot(dir, s) else 0;
                const inside = along > 0 and (sp.cone == null or along >= @cos(std.math.degreesToRadians(sp.cone.?)));
                const k = if (inside) std.math.pow(f64, along, sp.exponent) else 0;
                // Rounded to a byte, as resvg rounds the spot light's colour.
                for (&tint) |*t| t.* = @round(std.math.clamp(t.* * k, 0, 1) * 255) / 255;
            }

            const factor = if (l.specular) blk: {
                const h = normalize(.{ dir[0], dir[1], dir[2] + 1 }) orelse break :blk 0;
                const n_dot_h = dot(normal, h);
                break :blk l.constant * (if (n_dot_h > 0) std.math.pow(f64, n_dot_h, l.exponent) else 0);
            } else l.constant * dot(normal, dir);

            var px: [3]u8 = undefined;
            for (&px, tint) |*v, t| {
                const scaled = t * factor;
                v.* = if (std.math.isFinite(scaled)) @intFromFloat(@round(std.math.clamp(scaled, 0, 1) * 255)) else 0;
            }
            dst[@intCast(y * w + x)] = .{
                .r = px[0],
                .g = px[1],
                .b = px[2],
                .a = if (l.specular) @max(px[0], @max(px[1], px[2])) else 255,
            };
        }
    }
}

fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize(v: [3]f64) ?[3]f64 {
    const len = @sqrt(dot(v, v));
    if (!(len > 0) or !std.math.isFinite(len)) return null;
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

/// A direction of no length stays as it is, as resvg leaves it.
fn unitOr(v: [3]f64) [3]f64 {
    return normalize(v) orelse v;
}

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

fn convolveOne(kernel: []const f64, c: filter.ConvolveMatrix, row: []const RGBA) ![]RGBA {
    const gpa = testing.allocator;
    var in = try z2d.Surface.init(.image_surface_rgba, gpa, @intCast(row.len), 1);
    defer in.deinit(gpa);
    @memcpy(in.image_surface_rgba.buf, row);
    var out = try in.clone(gpa);
    defer out.deinit(gpa);
    convolve(&out, &in, image.extent(&in), image.extent(&in), c, kernel);
    return gpa.dupe(RGBA, out.image_surface_rgba.buf);
}

const opaque_grey = [_]RGBA{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 100, .g = 100, .b = 100, .a = 255 },
    .{ .r = 200, .g = 200, .b = 200, .a = 255 },
};

fn rowKernel(order_x: u32, edge: filter.EdgeMode) filter.ConvolveMatrix {
    return .{
        .in = .previous,
        .order_x = order_x,
        .order_y = 1,
        .kernel = .{ .first = 0, .count = order_x },
        .divisor = 1,
        .bias = 0,
        .target_x = order_x / 2,
        .target_y = 0,
        .edge = edge,
        .preserve_alpha = false,
    };
}

test "the kernel is turned through a half turn" {
    // [1 0 0] reads the pixel to the *right*: the kernel's first entry
    // weighs the last of the neighbourhood.
    const got = try convolveOne(&.{ 1, 0, 0 }, rowKernel(3, .duplicate), &opaque_grey);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(u8, 100), got[0].r);
    try testing.expectEqual(@as(u8, 200), got[1].r);
    // Past the right edge, duplicated.
    try testing.expectEqual(@as(u8, 200), got[2].r);
}

test "each edge mode says what lies past the edge" {
    const cases = [_]struct { filter.EdgeMode, u8, u8 }{
        .{ .duplicate, 200, 255 },
        .{ .wrap, 0, 255 },
        // Transparent black: the colour and the alpha both fall away.
        .{ .none, 0, 0 },
    };
    for (cases) |case| {
        const got = try convolveOne(&.{ 1, 0, 0 }, rowKernel(3, case[0]), &opaque_grey);
        defer testing.allocator.free(got);
        try testing.expectEqual(case[1], got[2].r);
        try testing.expectEqual(case[2], got[2].a);
    }
}

test "the divisor divides, the bias adds, and preserveAlpha keeps the alpha" {
    var c = rowKernel(3, .duplicate);
    c.divisor = 3;
    const box = try convolveOne(&.{ 1, 1, 1 }, c, &opaque_grey);
    defer testing.allocator.free(box);
    try testing.expectEqual(@as(u8, 100), box[1].r);

    // Half-transparent white under a kernel that takes half: without
    // preserveAlpha the alpha halves too; with it the alpha is kept and the
    // colour, straight, is halved.
    const half = [_]RGBA{.{ .r = 128, .g = 128, .b = 128, .a = 128 }} ** 3;
    c.divisor = 2;
    c.kernel = .{ .first = 0, .count = 3 };
    const plain = try convolveOne(&.{ 0, 1, 0 }, c, &half);
    defer testing.allocator.free(plain);
    try testing.expectEqual(@as(u8, 64), plain[1].a);
    c.preserve_alpha = true;
    const kept = try convolveOne(&.{ 0, 1, 0 }, c, &half);
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(u8, 128), kept[1].a);
    try testing.expectEqual(@as(u8, 64), kept[1].r);
    // And a bias, scaled by the alpha.
    c.preserve_alpha = false;
    c.bias = 0.5;
    const biased = try convolveOne(&.{ 0, 1, 0 }, c, &opaque_grey);
    defer testing.allocator.free(biased);
    try testing.expectEqual(@as(u8, 255), biased[1].a);
    try testing.expectEqual(@as(u8, 178), biased[1].r);
}

test "a displacement fetches from a half-scale step either way, and nothing past the edge" {
    const gpa = testing.allocator;
    var in = try z2d.Surface.init(.image_surface_rgba, gpa, 8, 1);
    defer in.deinit(gpa);
    for (in.image_surface_rgba.buf, 0..) |*px, i| px.* = .{ .r = @intCast(i * 10), .g = 0, .b = 0, .a = 255 };
    var map = try z2d.Surface.init(.image_surface_rgba, gpa, 8, 1);
    defer map.deinit(gpa);
    // Red full is a half forward; half-transparent red at full strength,
    // straight, is the same -- the map is read with its alpha divided out.
    // Green at a half is no step at all, so the y channel stays put.
    @memset(map.image_surface_rgba.buf, .{ .r = 255, .g = 128, .b = 0, .a = 255 });
    map.image_surface_rgba.buf[1] = .{ .r = 128, .g = 64, .b = 0, .a = 128 };
    var out = try z2d.Surface.init(.image_surface_rgba, gpa, 8, 1);
    defer out.deinit(gpa);
    displace(&out, &in, &map, image.extent(&in), image.extent(&in), .{ 4, 4 }, 0, 1);
    const got = out.image_surface_rgba.buf;
    try testing.expectEqual(@as(u8, 20), got[0].r);
    try testing.expectEqual(@as(u8, 30), got[1].r);
    try testing.expectEqual(@as(u8, 70), got[5].r);
    // From 8, past the edge.
    try testing.expectEqual(@as(u8, 0), got[6].a);
}

test "the noise generator is the reference code's" {
    // The Park-Miller minimal standard: from a seed of one, 16807 and then
    // 282475249, as every implementation of it gives.
    try testing.expectEqual(@as(i32, 16807), Noise.random(1));
    try testing.expectEqual(@as(i32, 282475249), Noise.random(16807));
    // Every gradient is a unit vector, and the lattice is a permutation
    // repeated.
    const n: Noise = .init(0);
    for (n.gradient) |channel| for (channel[0..b_size]) |g| {
        try testing.expectApproxEqAbs(@as(f64, 1), @sqrt(g[0] * g[0] + g[1] * g[1]), 1e-9);
    };
    var seen: [b_size]bool = @splat(false);
    for (n.lattice[0..b_size]) |v| seen[v] = true;
    for (seen) |v| try testing.expect(v);
    try testing.expectEqual(n.lattice[3], n.lattice[b_size + 3]);
    // Noise is nothing on the lattice points themselves.
    try testing.expectEqual(@as(f64, 0), n.noise2(0, 5, 7, null));
}

test "stitched noise repeats across its tile" {
    const n: Noise = .init(3);
    const t: filter.Turbulence = .{ .base_frequency_x = 0.13, .base_frequency_y = 0.07, .octaves = 3, .stitch = true };
    const stitch_tile: [4]f64 = .{ 10, 20, 50, 40 };
    for ([_][2]f64{ .{ 12.5, 21.25 }, .{ 30, 33 } }) |p| {
        const a = n.turbulence(1, p, stitch_tile, t);
        const b = n.turbulence(1, .{ p[0] + 50, p[1] }, stitch_tile, t);
        const c = n.turbulence(1, .{ p[0], p[1] + 40 }, stitch_tile, t);
        try testing.expectApproxEqAbs(a, b, 1e-9);
        try testing.expectApproxEqAbs(a, c, 1e-9);
    }
}

fn lit(alpha: []const u8, width: i32, l: Lighting) ![]RGBA {
    const gpa = testing.allocator;
    const h: i32 = @intCast(@divExact(@as(i32, @intCast(alpha.len)), width));
    var in = try z2d.Surface.init(.image_surface_rgba, gpa, width, h);
    defer in.deinit(gpa);
    for (in.image_surface_rgba.buf, alpha) |*px, a| px.* = .{ .r = 0, .g = 0, .b = 0, .a = a };
    var out = try z2d.Surface.init(.image_surface_rgba, gpa, width, h);
    defer out.deinit(gpa);
    light(&out, &in, image.extent(&in), image.extent(&in), l);
    return gpa.dupe(RGBA, out.image_surface_rgba.buf);
}

test "a flat surface under a light straight overhead is lit fully, and opaque" {
    const got = try lit(&(.{128} ** 9), 3, .{
        .specular = false,
        .surface_scale = 5,
        .constant = 1,
        .exponent = 1,
        .color = .{ 1, 0.5, 0 },
        .light = .{ .distant = .{ 0, 90 } },
    });
    defer testing.allocator.free(got);
    for (got) |px| try testing.expectEqual(RGBA{ .r = 255, .g = 128, .b = 0, .a = 255 }, px);
}

test "a slope faces towards the light or away from it" {
    // Alpha rising to the right: the surface leans left, so a light low in
    // the west lights it and one low in the east barely does.
    const ramp = [_]u8{ 0, 128, 255 } ** 3;
    const west = try lit(&ramp, 3, .{ .specular = false, .surface_scale = 4, .constant = 1, .exponent = 1, .color = .{ 1, 1, 1 }, .light = .{ .distant = .{ 180, 30 } } });
    defer testing.allocator.free(west);
    const east = try lit(&ramp, 3, .{ .specular = false, .surface_scale = 4, .constant = 1, .exponent = 1, .color = .{ 1, 1, 1 }, .light = .{ .distant = .{ 0, 30 } } });
    defer testing.allocator.free(east);
    try testing.expect(west[4].r > 200);
    try testing.expect(east[4].r < 20);
}

test "the edge kernels are the specification's factors" {
    // On a ramp of one level per pixel, every kernel -- interior, edge and
    // corner -- sees the same slope, so every pixel is lit the same.
    var ramp: [16]u8 = undefined;
    for (&ramp, 0..) |*a, i| a.* = @intCast((i % 4) * 60);
    const got = try lit(&ramp, 4, .{ .specular = false, .surface_scale = 1, .constant = 1, .exponent = 1, .color = .{ 1, 1, 1 }, .light = .{ .distant = .{ 0, 90 } } });
    defer testing.allocator.free(got);
    for (got) |px| try testing.expectEqual(got[0].r, px.r);
}

test "a specular highlight's alpha is its brightest channel" {
    const got = try lit(&(.{0} ** 9), 3, .{ .specular = true, .surface_scale = 1, .constant = 0.5, .exponent = 4, .color = .{ 1, 0.5, 0.25 }, .light = .{ .distant = .{ 0, 90 } } });
    defer testing.allocator.free(got);
    try testing.expectEqual(RGBA{ .r = 128, .g = 64, .b = 32, .a = 128 }, got[4]);
}

test "a spot light is dark outside its cone" {
    const flat = [_]u8{0} ** 25;
    const spot: Light = .{ .spot = .{ .at = .{ 0, 2, 3 }, .points_at = .{ 0, 2, 0 }, .exponent = 1, .cone = 30 } };
    const got = try lit(&flat, 5, .{ .specular = false, .surface_scale = 1, .constant = 1, .exponent = 1, .color = .{ 1, 1, 1 }, .light = spot });
    defer testing.allocator.free(got);
    // Straight below it, lit; four pixels across at a height of three is
    // well outside thirty degrees.
    try testing.expect(got[10].r > 200);
    try testing.expectEqual(@as(u8, 0), got[14].r);
}
