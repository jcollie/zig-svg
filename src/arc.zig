// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! SVG's elliptical arc command as cubic Béziers.
//!
//! `A` gives the arc by where it ends -- two radii, a rotation, two flags and
//! an endpoint -- and says nothing about where its centre is. Drawing it means
//! recovering that centre, which is SVG 1.1 appendix F.6.5, and then sweeping
//! from one angle to another.
//!
//! z2d has `Path.arc`, and it is not usable for this. It is circular, it takes
//! a centre and two angles rather than an endpoint, and it draws a connecting
//! line from the current point before it starts. The ellipse recipe in its own
//! documentation -- translate, scale, arc, restore -- cannot be used either,
//! because the scale would have to go on `Path.transformation`, which is
//! already carrying the viewBox scale and is applied to every point added.
//! So the arc is flattened to cubics here and appended as ordinary curves.
//!
//! The approximation is the standard one: split the sweep into segments of at
//! most 90°, and give each a control-point offset of
//! `4/3 · tan(Δ/4)`, which matches the arc at both endpoints in position and
//! tangent. At 90° its worst-case radial error is about 2.7 parts in 10,000 --
//! well under a thousandth of a pixel on a 72-pixel icon.

const std = @import("std");
const z2d = @import("z2d");

pub const Params = struct {
    /// The current point, where the arc starts.
    x1: f64,
    y1: f64,
    /// The endpoint the command names.
    x2: f64,
    y2: f64,
    rx: f64,
    ry: f64,
    /// The x-axis rotation, in degrees, as the command spells it.
    rotation_deg: f64,
    large_arc: bool,
    sweep: bool,
};

pub const Error = std.mem.Allocator.Error || z2d.Path.Error;

/// Append the arc to `path` as a run of cubics, ending at `(x2, y2)`.
///
/// The caller is responsible for the current point already being `(x1, y1)`.
pub fn append(path: *z2d.Path, alloc: std.mem.Allocator, p: Params) Error!void {
    // F.6.2: an arc whose endpoints coincide is not drawn at all. Not a
    // degenerate case to approximate -- the specification says to omit it.
    if (p.x1 == p.x2 and p.y1 == p.y2) return;

    // F.6.2: a zero radius makes it a straight line.
    var rx = @abs(p.rx);
    var ry = @abs(p.ry);
    if (rx == 0 or ry == 0) {
        try path.lineTo(alloc, p.x2, p.y2);
        return;
    }

    const phi = std.math.degreesToRadians(p.rotation_deg);
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    // F.6.5.1: the endpoint halved and rotated into the ellipse's own frame.
    const dx2 = (p.x1 - p.x2) / 2.0;
    const dy2 = (p.y1 - p.y2) / 2.0;
    const x1p = cos_phi * dx2 + sin_phi * dy2;
    const y1p = -sin_phi * dx2 + cos_phi * dy2;

    // F.6.6.2: radii too small to reach the endpoint are scaled up until they
    // just do. This is a correction the specification requires rather than an
    // error, and it is common in real path data.
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1.0) {
        const s = @sqrt(lambda);
        rx *= s;
        ry *= s;
    }

    // F.6.5.2: the centre, in the ellipse's frame.
    const rx2 = rx * rx;
    const ry2 = ry * ry;
    const x1p2 = x1p * x1p;
    const y1p2 = y1p * y1p;
    const numerator = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2;
    const denominator = rx2 * y1p2 + ry2 * x1p2;
    // `lambda` above guarantees the numerator is not negative, but it is a
    // guarantee made in floating point; clamping costs nothing and a negative
    // under the root would be a NaN through every point that follows.
    const radicand = if (denominator == 0) 0 else @max(0.0, numerator / denominator);
    const coef_sign: f64 = if (p.large_arc == p.sweep) -1.0 else 1.0;
    const coef = coef_sign * @sqrt(radicand);
    const cxp = coef * (rx * y1p / ry);
    const cyp = coef * -(ry * x1p / rx);

    // F.6.5.3: back out of the ellipse's frame.
    const cx = cos_phi * cxp - sin_phi * cyp + (p.x1 + p.x2) / 2.0;
    const cy = sin_phi * cxp + cos_phi * cyp + (p.y1 + p.y2) / 2.0;

    // F.6.5.5 and F.6.5.6: the start angle and the sweep.
    const ux = (x1p - cxp) / rx;
    const uy = (y1p - cyp) / ry;
    const vx = (-x1p - cxp) / rx;
    const vy = (-y1p - cyp) / ry;

    const theta1 = angle(1, 0, ux, uy);
    var delta = angle(ux, uy, vx, vy);
    // F.6.5.6: the sweep flag decides which way round, and the raw angle
    // between the vectors is always in (-2π, 2π), so it is corrected by a
    // whole turn rather than recomputed.
    if (!p.sweep and delta > 0) {
        delta -= 2 * std.math.pi;
    } else if (p.sweep and delta < 0) {
        delta += 2 * std.math.pi;
    }

    // At most 90° per cubic. Anything larger and the four-thirds-tangent
    // approximation starts to show.
    const segments: usize = @intFromFloat(@max(1.0, @ceil(@abs(delta) / (std.math.pi / 2.0))));
    const delta_per = delta / @as(f64, @floatFromInt(segments));
    // The control-point offset that matches the arc's tangent at both ends.
    const alpha = 4.0 / 3.0 * @tan(delta_per / 4.0);

    var theta = theta1;
    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const theta_next = theta + delta_per;

        const cos_a = @cos(theta);
        const sin_a = @sin(theta);
        const cos_b = @cos(theta_next);
        const sin_b = @sin(theta_next);

        // The point on the unrotated, unit-centred ellipse and its derivative,
        // both mapped back out through the rotation.
        const p1x = cx + rx * cos_phi * cos_a - ry * sin_phi * sin_a;
        const p1y = cy + rx * sin_phi * cos_a + ry * cos_phi * sin_a;
        const p2x = cx + rx * cos_phi * cos_b - ry * sin_phi * sin_b;
        const p2y = cy + rx * sin_phi * cos_b + ry * cos_phi * sin_b;

        const d1x = -rx * cos_phi * sin_a - ry * sin_phi * cos_a;
        const d1y = -rx * sin_phi * sin_a + ry * cos_phi * cos_a;
        const d2x = -rx * cos_phi * sin_b - ry * sin_phi * cos_b;
        const d2y = -rx * sin_phi * sin_b + ry * cos_phi * cos_b;

        // The last cubic ends at the arc's endpoint up to rounding, but the
        // command names that endpoint exactly and a subpath that closes back
        // to it should not be a hair short: F.6.5's own note says to use the
        // given values rather than the computed ones. So it ends *on* them.
        //
        // It used to get there by a line from the computed point, which was
        // right to the eye and wrong to a marker: that line is a sliver a
        // rounding error long pointing wherever the error pointed, and a
        // marker at the arc's end took its direction from it.
        const last = i + 1 == segments;
        try path.curveTo(
            alloc,
            p1x + alpha * d1x,
            p1y + alpha * d1y,
            p2x - alpha * d2x,
            p2y - alpha * d2y,
            if (last) p.x2 else p2x,
            if (last) p.y2 else p2y,
        );

        theta = theta_next;
    }
}

/// The signed angle from `(ux, uy)` to `(vx, vy)`, as F.6.5.4 defines it.
fn angle(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
    const dot = ux * vx + uy * vy;
    const len = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    if (len == 0) return 0;
    // Rounding can put the quotient a hair outside the domain of `acos`, which
    // answers NaN rather than saturating.
    const cosine = std.math.clamp(dot / len, -1.0, 1.0);
    const a = std.math.acos(cosine);
    return if (ux * vy - uy * vx < 0) -a else a;
}

test "an arc with coincident endpoints draws nothing" {
    const gpa = std.testing.allocator;
    var path: z2d.Path = .empty;
    defer path.deinit(gpa);
    try path.moveTo(gpa, 5, 5);
    try append(&path, gpa, .{
        .x1 = 5,
        .y1 = 5,
        .x2 = 5,
        .y2 = 5,
        .rx = 2,
        .ry = 2,
        .rotation_deg = 0,
        .large_arc = false,
        .sweep = true,
    });
    try std.testing.expectEqual(@as(usize, 1), path.nodes.items.len);
}

test "a zero radius makes a straight line" {
    const gpa = std.testing.allocator;
    var path: z2d.Path = .empty;
    defer path.deinit(gpa);
    try path.moveTo(gpa, 0, 0);
    try append(&path, gpa, .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 10,
        .y2 = 10,
        .rx = 0,
        .ry = 4,
        .rotation_deg = 0,
        .large_arc = true,
        .sweep = true,
    });
    try std.testing.expectEqual(@as(usize, 2), path.nodes.items.len);
    try std.testing.expect(path.nodes.items[1] == .line_to);
}

test "a half-circle ends exactly where the command says" {
    const gpa = std.testing.allocator;
    var path: z2d.Path = .empty;
    defer path.deinit(gpa);
    try path.moveTo(gpa, 0, 0);
    try append(&path, gpa, .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 20,
        .y2 = 0,
        .rx = 10,
        .ry = 10,
        .rotation_deg = 0,
        .large_arc = false,
        .sweep = true,
    });
    // Exactly, and by the last cubic itself: two quarter turns and nothing
    // after them. A line onto the endpoint from where rounding left the
    // cubic would be a sliver pointing wherever the rounding did, and a
    // marker at the end of the arc would face that way.
    try std.testing.expectEqual(@as(usize, 3), path.nodes.items.len);
    const last = path.nodes.items[path.nodes.items.len - 1];
    try std.testing.expectEqual(@as(f64, 20), last.curve_to.p3.x);
    try std.testing.expectEqual(@as(f64, 0), last.curve_to.p3.y);
}
