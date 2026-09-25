// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Drawing a bitmap under a matrix: what an `<image>` comes to once it has
//! been decoded and placed.
//!
//! Every device pixel asks where its centre lands in the bitmap and takes the
//! colour there. That is the whole of it, and it is done here rather than
//! through z2d's `SurfacePattern` because that one samples the nearest pixel
//! and nothing else -- which the README records aliasing badly on the rotated
//! `<pattern>` fixtures, and which is only right for a picture that asked for
//! hard edges.
//!
//! What this does not do is decide where the picture *ends*. Samples are taken
//! clamped to the bitmap's edge, so the colour runs out past it in every
//! direction; the caller cuts that to the element's rectangle with an
//! anti-aliased coverage mask, which gives the edge the same treatment as the
//! edge of any other shape. Letting transparency in from outside instead would
//! give every picture a soft half-pixel border that no other renderer draws.
//!
//! Premultiplied throughout, like everything else in the renderer, so a
//! transparent pixel lends none of its colour to its neighbours.

const std = @import("std");
const testing = std.testing;

const z2d = @import("z2d");

const image = @import("image.zig");

/// How a picture is sampled when it is drawn at a size other than its own:
/// `image-rendering`, which is inherited.
pub const Sampling = enum {
    /// Bilinear, from a picture reduced first by powers of two when it is
    /// being drawn at less than half its size. `auto`, `optimizeQuality`, and
    /// CSS's `smooth` and `high-quality`.
    smooth,
    /// The nearest pixel, with no reduction: hard edges, which is the point
    /// of asking for it. `optimizeSpeed`, and CSS's `pixelated` and
    /// `crisp-edges`.
    nearest,
};

/// Paint `src` into `dst` over `box`, overwriting what is there.
///
/// `to_src` takes a device point to a point in `src`'s pixels, where pixel
/// `(i, j)` covers `[i, i+1) × [j, j+1)` and so has its centre at
/// `(i + 0.5, j + 0.5)`. Both surfaces are RGBA.
pub fn paint(
    dst: *z2d.Surface,
    src: *const z2d.Surface,
    to_src: z2d.Transformation,
    box: image.PixelBox,
    sampling: Sampling,
) void {
    const area = box.intersect(image.extent(dst));
    if (area.isEmpty()) return;
    const dw = dst.getWidth();
    const out = dst.image_surface_rgba.buf;
    const sw = src.getWidth();
    const sh = src.getHeight();
    const in = src.image_surface_rgba.buf;

    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        var x = area.x0;
        while (x < area.x1) : (x += 1) {
            var u: f64 = @as(f64, @floatFromInt(x)) + 0.5;
            var v: f64 = @as(f64, @floatFromInt(y)) + 0.5;
            to_src.userToDevice(&u, &v);
            out[@intCast(y * dw + x)] = switch (sampling) {
                .nearest => in[@intCast(clampIndex(@floor(v), sh) * sw + clampIndex(@floor(u), sw))],
                .smooth => bilinear(in, sw, sh, u - 0.5, v - 0.5),
            };
        }
    }
}

/// A coordinate as an index into `0..n`, with everything past either end --
/// infinities and NaN included -- held at that end.
fn clampIndex(f: f64, n: i32) i32 {
    if (!(f > 0)) return 0;
    const last: f64 = @floatFromInt(n - 1);
    if (f >= last) return n - 1;
    return @intFromFloat(f);
}

/// The colour at `(fx, fy)`, where pixel centres are at whole numbers.
fn bilinear(in: []const z2d.pixel.RGBA, w: i32, h: i32, fx: f64, fy: f64) z2d.pixel.RGBA {
    const flx = @floor(fx);
    const fly = @floor(fy);
    // NaN makes the weights NaN too, and a NaN weight rounds to garbage
    // rather than to anything; a matrix that produces one has already been
    // refused as non-finite upstream, but a sample should not depend on that.
    const tx: f32 = if (std.math.isFinite(fx)) @floatCast(fx - flx) else 0;
    const ty: f32 = if (std.math.isFinite(fy)) @floatCast(fy - fly) else 0;
    const x0 = clampIndex(flx, w);
    const x1 = clampIndex(flx + 1, w);
    const y0 = clampIndex(fly, h);
    const y1 = clampIndex(fly + 1, h);

    const a = in[@intCast(y0 * w + x0)];
    const b = in[@intCast(y0 * w + x1)];
    const c = in[@intCast(y1 * w + x0)];
    const d = in[@intCast(y1 * w + x1)];
    return .{
        .r = mix(a.r, b.r, c.r, d.r, tx, ty),
        .g = mix(a.g, b.g, c.g, d.g, tx, ty),
        .b = mix(a.b, b.b, c.b, d.b, tx, ty),
        .a = mix(a.a, b.a, c.a, d.a, tx, ty),
    };
}

fn mix(a: u8, b: u8, c: u8, d: u8, tx: f32, ty: f32) u8 {
    const top = lerp(@floatFromInt(a), @floatFromInt(b), tx);
    const bottom = lerp(@floatFromInt(c), @floatFromInt(d), tx);
    const v = lerp(top, bottom, ty);
    return @intFromFloat(@min(255.0, @max(0.0, @round(v))));
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// How many halvings to take a bitmap through before sampling it under
/// `to_src`, so that bilinear never reads fewer than one source pixel in two.
///
/// The step from one device pixel to the next, measured in source pixels, is
/// the length of a column of the matrix. The *shorter* of the two decides: a
/// picture squashed in one direction only is reduced as far as the other
/// allows and no further, which leaves a little aliasing along the squashed
/// axis rather than blurring the one that was not.
pub fn levelFor(to_src: z2d.Transformation, sampling: Sampling) usize {
    if (sampling == .nearest) return 0;
    const step_x = std.math.hypot(to_src.ax, to_src.cx);
    const step_y = std.math.hypot(to_src.by, to_src.dy);
    const step = @min(step_x, step_y);
    if (!std.math.isFinite(step) or step < 2) return 0;
    // At most thirty: a bitmap is at most 2^32 pixels wide, and by then every
    // level is one pixel.
    return @intFromFloat(@min(30.0, @floor(std.math.log2(step))));
}

// -- tests -------------------------------------------------------------------

fn surfaceOf(w: i32, h: i32) !z2d.Surface {
    return z2d.Surface.init(.image_surface_rgba, testing.allocator, w, h);
}

test "at its own size a bitmap is copied exactly" {
    var src = try surfaceOf(2, 2);
    defer src.deinit(testing.allocator);
    const colours = [4]z2d.pixel.RGBA{
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 255, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 128, .a = 128 },
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
    @memcpy(src.image_surface_rgba.buf, &colours);

    for ([_]Sampling{ .smooth, .nearest }) |sampling| {
        var dst = try surfaceOf(4, 4);
        defer dst.deinit(testing.allocator);
        // Drawn at (1, 1): device (1.5, 1.5) is source (0.5, 0.5).
        const to_src: z2d.Transformation = .{ .ax = 1, .by = 0, .cx = 0, .dy = 1, .tx = -1, .ty = -1 };
        paint(&dst, &src, to_src, .{ .x0 = 1, .y0 = 1, .x1 = 3, .y1 = 3 }, sampling);
        const out = dst.image_surface_rgba.buf;
        try testing.expectEqual(colours[0], out[1 * 4 + 1]);
        try testing.expectEqual(colours[1], out[1 * 4 + 2]);
        try testing.expectEqual(colours[2], out[2 * 4 + 1]);
        try testing.expectEqual(colours[3], out[2 * 4 + 2]);
        // Nothing outside the box is touched.
        try testing.expectEqual(z2d.pixel.RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 }, out[0]);
    }
}

test "enlarged, smooth sampling ramps and nearest does not" {
    var src = try surfaceOf(2, 1);
    defer src.deinit(testing.allocator);
    src.image_surface_rgba.buf[0] = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    src.image_surface_rgba.buf[1] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    // Four times as large: device x is four source-pixel quarters.
    const to_src: z2d.Transformation = .{ .ax = 0.25, .by = 0, .cx = 0, .dy = 0.25, .tx = 0, .ty = 0 };

    var smooth = try surfaceOf(8, 1);
    defer smooth.deinit(testing.allocator);
    paint(&smooth, &src, to_src, image.extent(&smooth), .smooth);
    const s = smooth.image_surface_rgba.buf;
    // Held at the ends, where there is nothing further to blend with, and a
    // ramp between the two centres (device 2 and 6), whose midpoint is grey.
    try testing.expectEqual(@as(u8, 0), s[0].r);
    try testing.expectEqual(@as(u8, 0), s[1].r);
    try testing.expect(s[2].r > 0 and s[2].r < s[3].r and s[3].r < s[4].r and s[4].r < s[5].r);
    try testing.expectEqual(@as(u8, 255), s[7].r);
    try testing.expectEqual(@as(u8, 128), mix(0, 255, 0, 255, 0.5, 0));

    var nearest = try surfaceOf(8, 1);
    defer nearest.deinit(testing.allocator);
    paint(&nearest, &src, to_src, image.extent(&nearest), .nearest);
    const n = nearest.image_surface_rgba.buf;
    for (0..4) |i| try testing.expectEqual(@as(u8, 0), n[i].r);
    for (4..8) |i| try testing.expectEqual(@as(u8, 255), n[i].r);
}

test "a bitmap drawn small is reduced first, and one drawn with hard edges is not" {
    const identity: z2d.Transformation = .identity;
    try testing.expectEqual(@as(usize, 0), levelFor(identity, .smooth));
    try testing.expectEqual(@as(usize, 0), levelFor(identity.scale(1.9, 1.9), .smooth));
    try testing.expectEqual(@as(usize, 1), levelFor(identity.scale(2, 2), .smooth));
    try testing.expectEqual(@as(usize, 3), levelFor(identity.scale(8, 8), .smooth));
    // Squashed along one axis only: reduced as far as the other allows.
    try testing.expectEqual(@as(usize, 0), levelFor(identity.scale(8, 1), .smooth));
    // Rotation does not change how far apart the samples are.
    try testing.expectEqual(@as(usize, 2), levelFor(identity.rotate(0.7).scale(4, 4), .smooth));
    try testing.expectEqual(@as(usize, 0), levelFor(identity.scale(8, 8), .nearest));
    try testing.expectEqual(@as(usize, 0), levelFor(identity.scale(std.math.inf(f64), 1), .smooth));
}
