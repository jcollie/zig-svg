// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The lengths an SVG attribute is written in.
//!
//! A number, optionally with a unit: `10`, `10px`, `4cm`, `50%`. The user unit
//! *is* the CSS pixel, so `px` and a bare number are the same thing, and the
//! absolute units are fixed ratios to it -- `1in` is 96 pixels by definition,
//! and everything else follows from that.
//!
//! | unit | pixels | |
//! | --- | --- | --- |
//! | `px` | 1 | and a bare number is this |
//! | `in` | 96 | the definition the rest hang off |
//! | `pc` | 16 | a pica is a sixth of an inch |
//! | `pt` | 4/3 | a point is a seventy-second |
//! | `cm` | 96/2.54 | |
//! | `mm` | 96/25.4 | |
//!
//! ## Percentages
//!
//! A percentage is of the viewport, and *which* measure of the viewport
//! depends on what the attribute measures: `width` and `x` are of its width,
//! `height` and `y` of its height, and anything that is neither -- a radius, a
//! stroke width -- of the diagonal divided by the square root of two, which is
//! SVG 1.1 §7.10's normalized diagonal and is the length that reduces to the
//! side when the viewport is square.
//!
//! The viewport is the one the `viewBox` establishes, not the size the picture
//! is drawn at. A document that is 100 by 50 pixels with a `viewBox` of
//! `0 0 100 200` resolves `50%` of a height as 100 user units, not as 25
//! pixels, and resvg agrees.
//!
//! ## `em` and `ex` are refused
//!
//! Both are a multiple of the font size, and there is no font here and no
//! right answer for what it would be. CSS's initial `font-size` is `medium`,
//! which browsers make 16 pixels and resvg makes 12 -- so `10em` is 160 pixels
//! in a browser and 120 in the oracle this library is checked against, and
//! either choice draws a picture the wrong size somewhere. `ex` is worse,
//! being the x-height of a font nobody named.
//!
//! So they are `error.BadLength` until there is a font size to ask, which
//! arrives with text.

const std = @import("std");
const testing = std.testing;

pub const Error = error{
    /// A length that is not a number, or one carrying a unit this reader
    /// cannot resolve.
    BadLength,
};

/// Which measure of the viewport a percentage is of.
pub const Axis = enum {
    /// `x`, `width`, `rx`, `cx` -- horizontal.
    x,
    /// `y`, `height`, `ry`, `cy` -- vertical.
    y,
    /// `r`, `stroke-width`, a dash length -- neither, so the normalized
    /// diagonal.
    other,
};

/// What a percentage is measured against.
pub const Viewport = struct {
    width: f64,
    height: f64,

    /// A viewport of no extent, for reading a length before the real one is
    /// known -- the root's own `width` and `height`, which cannot be a
    /// percentage of themselves.
    pub const unknown: Viewport = .{ .width = 0, .height = 0 };

    /// The length a percentage on `axis` is a percentage of.
    pub fn reference(self: Viewport, axis: Axis) f64 {
        return switch (axis) {
            .x => self.width,
            .y => self.height,
            // §7.10's normalized diagonal, which is the side of a square of
            // the same diagonal -- so it equals the side when the viewport is
            // square, which is what makes it the natural answer for a radius.
            .other => @sqrt(self.width * self.width + self.height * self.height) /
                @sqrt(2.0),
        };
    }
};

const per_inch: f64 = 96.0;

/// Read one length.
pub fn parse(text: []const u8, axis: Axis, viewport: Viewport) Error!f64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.BadLength;

    const Unit = struct { suffix: []const u8, scale: f64 };
    const units = [_]Unit{
        .{ .suffix = "px", .scale = 1.0 },
        .{ .suffix = "pt", .scale = per_inch / 72.0 },
        .{ .suffix = "pc", .scale = per_inch / 6.0 },
        .{ .suffix = "mm", .scale = per_inch / 25.4 },
        .{ .suffix = "cm", .scale = per_inch / 2.54 },
        .{ .suffix = "in", .scale = per_inch },
    };

    var number = t;
    var scale: f64 = 1.0;
    if (std.mem.endsWith(u8, t, "%")) {
        number = t[0 .. t.len - 1];
        scale = viewport.reference(axis) / 100.0;
    } else if (std.mem.endsWith(u8, t, "em") or std.mem.endsWith(u8, t, "ex")) {
        // See the note above: there is no font, and no answer that is right
        // everywhere.
        return error.BadLength;
    } else for (units) |unit| {
        if (std.mem.endsWith(u8, t, unit.suffix)) {
            number = t[0 .. t.len - unit.suffix.len];
            scale = unit.scale;
            break;
        }
    }

    // Not trimmed again: the unit has to be adjacent to the number, so
    // `10 px` is not a length even though ` 10px ` is.
    const value = std.fmt.parseFloat(f64, number) catch return error.BadLength;
    // An infinity or a NaN reaching the rasterizer is a hang or a panic rather
    // than a wrong picture, which is the rule the path parser follows too.
    if (!std.math.isFinite(value)) return error.BadLength;
    const result = value * scale;
    if (!std.math.isFinite(result)) return error.BadLength;
    return result;
}

// -- tests -------------------------------------------------------------------

const square: Viewport = .{ .width = 100, .height = 100 };

fn expectLength(expected: f64, text: []const u8) !void {
    try testing.expectApproxEqAbs(expected, try parse(text, .x, square), 1e-9);
}

test "a bare number is pixels, and so is px" {
    try expectLength(10, "10");
    try expectLength(10, "10px");
    try expectLength(-2.5, "-2.5");
    try expectLength(10, " 10 ");
    try expectLength(0.5, ".5");
    try expectLength(1000, "1e3");
}

test "the absolute units are fixed ratios to the pixel" {
    try expectLength(96, "1in");
    try expectLength(16, "1pc");
    try expectLength(96.0 / 72.0, "1pt");
    try expectLength(96.0 / 2.54, "1cm");
    try expectLength(96.0 / 25.4, "1mm");
    // The numbers resvg produces for the same input, to a pixel.
    try testing.expectApproxEqAbs(@as(f64, 151.18), try parse("4cm", .x, square), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 128), try parse("96pt", .x, square), 1e-9);
}

test "a percentage is of the viewport, and of which measure depends on the axis" {
    const wide: Viewport = .{ .width = 200, .height = 100 };
    try testing.expectApproxEqAbs(@as(f64, 20), try parse("10%", .x, wide), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), try parse("10%", .y, wide), 1e-9);
    // §7.10's normalized diagonal: sqrt(200² + 100²) / sqrt(2) ≈ 158.11.
    try testing.expectApproxEqAbs(@as(f64, 15.811), try parse("10%", .other, wide), 0.001);
    // Which is the side itself when the viewport is square.
    try testing.expectApproxEqAbs(@as(f64, 10), try parse("10%", .other, square), 1e-9);
}

test "em and ex are refused rather than guessed at" {
    for ([_][]const u8{ "1em", "10em", "1ex", "0.5ex" }) |t| {
        try testing.expectError(error.BadLength, parse(t, .x, square));
    }
}

test "a length that is not one is refused" {
    for ([_][]const u8{ "", "   ", "abc", "px", "%", "10 px", "1e400", "nan", "10qq" }) |t| {
        try testing.expectError(error.BadLength, parse(t, .x, square));
    }
}

test "a percentage of an unknown viewport is zero rather than an error" {
    // Used for the root's own `width` and `height`, which cannot be a
    // percentage of themselves; the caller falls back to the viewBox.
    try testing.expectApproxEqAbs(@as(f64, 0), try parse("100%", .x, .unknown), 1e-12);
}
