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
