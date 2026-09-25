// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! How a picture is resampled when an `<image>` draws it at a size other than
//! its own: which filter, and how far to reduce it first.
//!
//! The sampling itself is z2d's. An `<image>` is filled with a
//! `z2d.SurfacePattern` over the decoded picture, which filters with
//! Mitchell and Netravali's cubic -- the one Skia calls high quality, and so
//! the one resvg draws with -- or takes the nearest pixel when the document
//! asks for hard edges. What is left here is the decision the pattern cannot
//! make for itself: a filter reads a few pixels around each point, so a
//! picture drawn at less than half its size has pixels between the points
//! that no sample reads, and has to be halved first, as many times as it
//! takes.

const std = @import("std");
const testing = std.testing;

const z2d = @import("z2d");

/// How a picture is sampled when it is drawn at a size other than its own:
/// `image-rendering`, which is inherited.
pub const Sampling = enum {
    /// Mitchell's cubic, from a picture reduced first by powers of two when
    /// it is being drawn at less than half its size. `auto`,
    /// `optimizeQuality`, and CSS's `smooth` and `high-quality`.
    smooth,
    /// The nearest pixel, with no reduction: hard edges, which is the point
    /// of asking for it. `optimizeSpeed`, and CSS's `pixelated` and
    /// `crisp-edges`.
    nearest,
};

/// How many halvings to take a bitmap through before sampling it under
/// `to_src`, so that the filter never steps more than two source pixels at a time.
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
