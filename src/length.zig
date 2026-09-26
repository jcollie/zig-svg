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
//! ## `em` and `ex`
//!
//! Both are a multiple of the font size in force, which `Viewport.font_size`
//! carries. `1em` is that size and `1ex` is half of it -- measured against
//! resvg, which does not read the font's x-height for it, and half an em is
//! the convention every renderer falls back on when it cannot.
//!
//! Where no `font-size` is in force anywhere, there is no right answer: CSS's
//! initial value is `medium`, which browsers make 16 pixels and resvg makes
//! 12, so `10em` is 160 pixels in a browser and 120 in the oracle this library
//! is checked against. That is the caller's choice rather than this module's,
//! so `font_size` is null until somebody says, and a `em` or `ex` read against
//! a null one is `error.BadLength` -- the same refusal these both used to get
//! unconditionally.

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

/// What a relative length is measured against: a percentage against the
/// viewport, an `em` or an `ex` against the font size in force.
pub const Viewport = struct {
    width: f64,
    height: f64,

    /// The `font-size` in force where the length is being read, or null when
    /// none is. `em` and `ex` are refused against a null one rather than
    /// guessed at -- see the note above about which number that would be.
    ///
    /// Not the *document's* font size: it is whatever the element and its
    /// ancestors came to, so it changes as the walk descends.
    font_size: ?f64 = null,

    /// A viewport of no extent, for reading a length before the real one is
    /// known -- the root's own `width` and `height`, which cannot be a
    /// percentage of themselves.
    pub const unknown: Viewport = .{ .width = 0, .height = 0 };

    /// The same viewport with a different font size in force.
    pub fn withFontSize(self: Viewport, size: ?f64) Viewport {
        var out = self;
        out.font_size = size;
        return out;
    }

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
        // Both are relative to the font size in force. With none in force
        // there is no answer that is right everywhere -- see the note above --
        // so this is refused rather than guessed at.
        const size = viewport.font_size orelse return error.BadLength;
        number = t[0 .. t.len - 2];
        // Half an em for `ex`: resvg does not read the font's x-height for it,
        // and half is what every renderer falls back on when it cannot.
        scale = if (t[t.len - 1] == 'x') size / 2.0 else size;
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

/// The lengths of a list, one at a time: `x="10 20 30"` on a `<text>`, where
/// each is the position of one character. Separated by whitespace, commas,
/// or both, as every number list in SVG is.
pub const List = struct {
    entries: std.mem.TokenIterator(u8, .any),
    axis: Axis,
    viewport: Viewport,

    pub fn next(self: *List) Error!?f64 {
        const entry = self.entries.next() orelse return null;
        return try parse(entry, self.axis, self.viewport);
    }
};

pub fn list(text: []const u8, axis: Axis, viewport: Viewport) List {
    return .{ .entries = std.mem.tokenizeAny(u8, text, " \t\r\n,"), .axis = axis, .viewport = viewport };
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

test "em and ex are the font size in force, and half of it" {
    const with_font = square.withFontSize(20);
    try testing.expectApproxEqAbs(@as(f64, 20), try parse("1em", .x, with_font), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50), try parse("2.5em", .x, with_font), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10), try parse("-0.5em", .x, with_font), 1e-9);
    // Half an em, measured against resvg: it does not read the font's
    // x-height for `ex`, and half is what every renderer falls back on when it
    // cannot.
    try testing.expectApproxEqAbs(@as(f64, 10), try parse("1ex", .x, with_font), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 40), try parse("4ex", .x, with_font), 1e-9);

    // Neither depends on the axis, unlike a percentage.
    for ([_]Axis{ .x, .y, .other }) |axis| {
        try testing.expectApproxEqAbs(@as(f64, 20), try parse("1em", axis, with_font), 1e-9);
    }

    // A size of zero is a size: it makes them zero rather than refusing.
    try testing.expectEqual(@as(f64, 0), try parse("3em", .x, square.withFontSize(0)));
}

test "em and ex are refused when no font size is in force" {
    // There is no answer that is right everywhere -- CSS's initial `font-size`
    // is `medium`, which browsers make 16 and resvg makes 12 -- so this is
    // refused rather than picking one of them and drawing a picture that is
    // the wrong size in half the world.
    try testing.expectEqual(@as(?f64, null), square.font_size);
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

test "a list of lengths is read one at a time, and refused at the first bad one" {
    var l = list(" 10, 20%  3in", .x, square);
    try testing.expectEqual(@as(?f64, 10), try l.next());
    try testing.expectEqual(@as(?f64, 20), try l.next());
    try testing.expectEqual(@as(?f64, 288), try l.next());
    try testing.expectEqual(@as(?f64, null), try l.next());
    var bad = list("1 two", .x, square);
    _ = try bad.next();
    try testing.expectError(error.BadLength, bad.next());
}
