// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The `transform` attribute: SVG 1.1 §7.6's transform list, as one matrix.
//!
//! ```
//! transform="translate(8,0) scale(2)"
//! transform="rotate(45, 12, 12)"
//! transform="matrix(1 0 0 1 8 8)"
//! ```
//!
//! A list composes left to right, and the rightmost is applied to the point
//! first: `translate(8,0) scale(2)` scales about the origin and then moves the
//! result, which is not what scaling a moved shape would do. Separators are
//! commas, whitespace, both, or neither, like every other number list in SVG.
//!
//! ## z2d's matrix is not laid out the way its field names suggest
//!
//! `z2d.Transformation` is
//!
//! ```text
//! [ ax by tx ]        x' = ax·x + by·y + tx
//! [ cx dy ty ]        y' = cx·x + dy·y + ty
//! ```
//!
//! so `by` is the *y* coefficient of the *x* row and `cx` is the *x*
//! coefficient of the *y* row. SVG's `matrix(a b c d e f)` is
//!
//! ```text
//! x' = a·x + c·y + e        ax = a    by = c    tx = e
//! y' = b·x + d·y + f        cx = b    dy = d    ty = f
//! ```
//!
//! -- so `b` and `c` cross over on the way in. Reading `by` as SVG's `b`
//! transposes every rotation and skew, which is a picture that is wrong in a
//! way that looks deliberate. `skewX` widening a square rather than making it
//! taller is the cheapest check that it is the right way round, and
//! `tests/oracle/transform-functions.svg` is resvg agreeing.
//!
//! ## The CSS property is a different syntax
//!
//! SVG 2 makes `transform` a CSS property too, and in `style` or a
//! stylesheet it is written as CSS Transforms 1 has it: lengths with units,
//! angles with units, commas between arguments, and functions the attribute
//! does not have -- `translateX`, `scaleY`, `skew`. `parseCss` reads that,
//! and is as strict as Chrome about the difference: `translate(5)` is not
//! CSS, since a length other than zero needs a unit, and `rotate(90)` is not
//! either. Chrome drops such a declaration; this refuses it, as it refuses
//! every value it cannot read. A percentage in a translation is of the
//! reference box that `transform-box` names, which the caller supplies.
//!
//! ## A list this cannot read is refused
//!
//! resvg ignores a malformed `transform` entirely and draws the shape
//! untransformed -- `bogus(1)`, `translate(`, and `rotate(45,1)` all come out
//! as the identity. This refuses them, for the same reason it refuses a colour
//! it cannot read: a shape drawn in the wrong place looks deliberate. An empty
//! list is *not* malformed -- the grammar allows zero transforms -- so
//! `transform=""` is the identity here as well.

const std = @import("std");
const testing = std.testing;

const css = @import("css");
const z2d = @import("z2d");

const length = @import("length.zig");
const path = @import("path.zig");

pub const Error = error{
    /// A transform list this module cannot read: an unknown function, a
    /// missing bracket, or the wrong number of arguments for the function
    /// named.
    BadTransform,
    /// A CSS transform function in three dimensions -- `rotate3d`,
    /// `perspective` and the rest -- which a flat picture has no way to
    /// draw.
    UnsupportedTransform,
};

/// The whole of a `transform` attribute, composed into one matrix.
pub fn parse(text: []const u8) Error!z2d.Transformation {
    var s: path.Scanner = .{ .src = text };
    var result: z2d.Transformation = .identity;

    while (true) {
        s.skipWsAndCommas();
        if (s.done()) return result;

        const name_start = s.pos;
        while (!s.done() and std.ascii.isAlphabetic(s.peek())) : (s.pos += 1) {}
        if (s.pos == name_start) return error.BadTransform;
        const name = text[name_start..s.pos];

        s.skipWsAndCommas();
        if (s.done() or s.peek() != '(') return error.BadTransform;
        s.pos += 1;

        // At most six, which is `matrix`. Reading more than that is an error
        // rather than something to truncate.
        var args: [6]f64 = undefined;
        var n: usize = 0;
        while (true) {
            s.skipWsAndCommas();
            if (s.done()) return error.BadTransform;
            if (s.peek() == ')') {
                s.pos += 1;
                break;
            }
            if (n == args.len) return error.BadTransform;
            args[n] = s.number() catch return error.BadTransform;
            n += 1;
        }

        result = result.mul(try one(name, args[0..n]));
    }
}

/// One function of the list.
fn one(name: []const u8, args: []const f64) Error!z2d.Transformation {
    // Case-sensitive, and `skewX` proves it has to be: these are XML attribute
    // values, not CSS keywords. resvg reads them the same way.
    if (std.mem.eql(u8, name, "matrix")) {
        if (args.len != 6) return error.BadTransform;
        return .{
            .ax = args[0],
            .cx = args[1],
            .by = args[2],
            .dy = args[3],
            .tx = args[4],
            .ty = args[5],
        };
    }
    if (std.mem.eql(u8, name, "translate")) {
        // §7.6: the y displacement defaults to zero.
        if (args.len != 1 and args.len != 2) return error.BadTransform;
        return .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = args[0],
            .ty = if (args.len == 2) args[1] else 0,
        };
    }
    if (std.mem.eql(u8, name, "scale")) {
        // §7.6: one argument scales both axes equally.
        if (args.len != 1 and args.len != 2) return error.BadTransform;
        return .{
            .ax = args[0],
            .by = 0,
            .cx = 0,
            .dy = if (args.len == 2) args[1] else args[0],
            .tx = 0,
            .ty = 0,
        };
    }
    if (std.mem.eql(u8, name, "rotate")) {
        if (args.len != 1 and args.len != 3) return error.BadTransform;
        const rad = std.math.degreesToRadians(args[0]);
        const c = @cos(rad);
        const s = @sin(rad);
        const r: z2d.Transformation = .{
            .ax = c,
            .by = -s,
            .cx = s,
            .dy = c,
            .tx = 0,
            .ty = 0,
        };
        if (args.len == 1) return r;
        // §7.6: three arguments rotate about a point rather than the origin,
        // which is `translate(cx,cy) rotate(a) translate(-cx,-cy)`.
        const to: z2d.Transformation = .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = args[1],
            .ty = args[2],
        };
        const back: z2d.Transformation = .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = -args[1],
            .ty = -args[2],
        };
        return to.mul(r).mul(back);
    }
    if (std.mem.eql(u8, name, "skewX")) {
        if (args.len != 1) return error.BadTransform;
        return .{
            .ax = 1,
            .by = @tan(std.math.degreesToRadians(args[0])),
            .cx = 0,
            .dy = 1,
            .tx = 0,
            .ty = 0,
        };
    }
    if (std.mem.eql(u8, name, "skewY")) {
        if (args.len != 1) return error.BadTransform;
        return .{
            .ax = 1,
            .by = 0,
            .cx = @tan(std.math.degreesToRadians(args[0])),
            .dy = 1,
            .tx = 0,
            .ty = 0,
        };
    }
    return error.BadTransform;
}

/// A `transform` written as CSS: a list of CSS Transforms 1's functions,
/// or `none`.
///
/// `box` is the reference box, as a viewport: its `width` and `height` are
/// what a percentage in `translate` is of, and its `font_size` what an `em`
/// is of.
pub fn parseCss(text: []const u8, box: length.Viewport) Error!z2d.Transformation {
    if (css.values.split.isKeyword(text, "none")) return .identity;

    var t: css.tokenizer.Tokenizer = .init(text);
    var result: z2d.Transformation = .identity;
    var any = false;
    while (true) {
        var tok = t.next();
        while (tok.tag == .whitespace) tok = t.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .function) return error.BadTransform;
        const name = tok.value;
        const open = tok.loc.end;
        // Everything to the matching parenthesis is the arguments; a list the
        // text ran out inside of is not a list.
        var depth: usize = 1;
        var close: usize = open;
        while (depth > 0) {
            const inner = t.next();
            switch (inner.tag) {
                .eof => return error.BadTransform,
                .open_paren, .open_square, .open_curly, .function => depth += 1,
                .close_paren, .close_square, .close_curly => depth -= 1,
                else => {},
            }
            close = inner.loc.start;
        }
        result = result.mul(try cssOne(text, name, text[open..close], box));
        any = true;
    }
    // An empty value is not `none`; it is not a value at all.
    if (!any) return error.BadTransform;
    return result;
}

/// One CSS transform function.
fn cssOne(src: []const u8, name: css.tokenizer.Span, arguments: []const u8, box: length.Viewport) Error!z2d.Transformation {
    const is = struct {
        fn f(s: []const u8, span: css.tokenizer.Span, want: []const u8) bool {
            return css.tokenizer.eqlDecoded(s, span, want, .ascii);
        }
    }.f;

    var items = css.values.split.Items.init(arguments);
    var args: [6][]const u8 = undefined;
    var n: usize = 0;
    while (items.next()) |item| : (n += 1) {
        if (n == args.len) return error.BadTransform;
        const trimmed = std.mem.trim(u8, item, " \t\r\n\x0c");
        if (trimmed.len == 0) return error.BadTransform;
        args[n] = trimmed;
    }

    if (is(src, name, "matrix")) {
        if (n != 6) return error.BadTransform;
        var v: [6]f64 = undefined;
        for (args[0..6], &v) |a, *out| out.* = css.values.parseNumber(a) orelse return error.BadTransform;
        return one("matrix", &v);
    }
    if (is(src, name, "translate")) {
        if (n != 1 and n != 2) return error.BadTransform;
        const x = try cssLength(args[0], .x, box);
        const y = if (n == 2) try cssLength(args[1], .y, box) else 0;
        return one("translate", &.{ x, y });
    }
    if (is(src, name, "translatex")) {
        if (n != 1) return error.BadTransform;
        return one("translate", &.{ try cssLength(args[0], .x, box), 0 });
    }
    if (is(src, name, "translatey")) {
        if (n != 1) return error.BadTransform;
        return one("translate", &.{ 0, try cssLength(args[0], .y, box) });
    }
    if (is(src, name, "scale")) {
        if (n != 1 and n != 2) return error.BadTransform;
        const x = try cssScale(args[0]);
        return one("scale", &.{ x, if (n == 2) try cssScale(args[1]) else x });
    }
    if (is(src, name, "scalex")) {
        if (n != 1) return error.BadTransform;
        return one("scale", &.{ try cssScale(args[0]), 1 });
    }
    if (is(src, name, "scaley")) {
        if (n != 1) return error.BadTransform;
        return one("scale", &.{ 1, try cssScale(args[0]) });
    }
    if (is(src, name, "rotate")) {
        // No centre, unlike the attribute's: that is what `transform-origin`
        // is for.
        if (n != 1) return error.BadTransform;
        return one("rotate", &.{try cssAngle(args[0])});
    }
    if (is(src, name, "skew")) {
        if (n != 1 and n != 2) return error.BadTransform;
        const ax = @tan(std.math.degreesToRadians(try cssAngle(args[0])));
        const ay = if (n == 2) @tan(std.math.degreesToRadians(try cssAngle(args[1]))) else 0;
        return .{ .ax = 1, .by = ax, .cx = ay, .dy = 1, .tx = 0, .ty = 0 };
    }
    if (is(src, name, "skewx")) {
        if (n != 1) return error.BadTransform;
        return one("skewX", &.{try cssAngle(args[0])});
    }
    if (is(src, name, "skewy")) {
        if (n != 1) return error.BadTransform;
        return one("skewY", &.{try cssAngle(args[0])});
    }
    for ([_][]const u8{
        "matrix3d", "translate3d", "translatez", "scale3d", "scalez",
        "rotate3d", "rotatex",     "rotatey",    "rotatez", "perspective",
    }) |three_d| if (is(src, name, three_d)) return error.UnsupportedTransform;
    return error.BadTransform;
}

/// A `<length-percentage>`: a length with a unit, a percentage of the
/// reference box, or zero.
fn cssLength(text: []const u8, axis: length.Axis, box: length.Viewport) Error!f64 {
    if (css.values.parsePercentage(text)) |p| return p.of(box.reference(axis));
    const l = css.values.parseLength(text) orelse return error.BadTransform;
    if (l.toPx()) |px| return px;
    const size = box.font_size orelse return error.BadTransform;
    return switch (l.unit) {
        .em => l.value * size,
        // Half an em, as everywhere else here: see `length.parse`.
        .ex => l.value * size / 2,
        else => error.BadTransform,
    };
}

/// A scale factor: a number, or CSS Transforms 2's percentage of one.
fn cssScale(text: []const u8) Error!f64 {
    if (css.values.parseNumber(text)) |v| return v;
    if (css.values.parsePercentage(text)) |p| return p.value / 100;
    return error.BadTransform;
}

/// An `<angle>` or a zero, in degrees.
fn cssAngle(text: []const u8) Error!f64 {
    const a = css.values.parseAngle(text, .allow) orelse return error.BadTransform;
    return a.degrees;
}

/// Whether every number in the matrix is finite.
///
/// A `rotate(90)` inside a `skewX(90)` produces an infinity through `@tan`,
/// and an infinity reaching z2d is a hang or a panic rather than a wrong
/// picture. Checked where the matrix is used rather than where it is built, so
/// that composing two finite matrices into a non-finite one is caught too.
pub fn isFinite(t: z2d.Transformation) bool {
    return std.math.isFinite(t.ax) and std.math.isFinite(t.by) and
        std.math.isFinite(t.cx) and std.math.isFinite(t.dy) and
        std.math.isFinite(t.tx) and std.math.isFinite(t.ty);
}

// -- tests -------------------------------------------------------------------

/// Where a transform sends a point, in the layout z2d uses.
fn apply(t: z2d.Transformation, x: f64, y: f64) [2]f64 {
    return .{ t.ax * x + t.by * y + t.tx, t.cx * x + t.dy * y + t.ty };
}

fn expectPoint(expected: [2]f64, t: z2d.Transformation, x: f64, y: f64) !void {
    const got = apply(t, x, y);
    try testing.expectApproxEqAbs(expected[0], got[0], 1e-9);
    try testing.expectApproxEqAbs(expected[1], got[1], 1e-9);
}

test "an empty list is the identity" {
    try expectPoint(.{ 3, 4 }, try parse(""), 3, 4);
    try expectPoint(.{ 3, 4 }, try parse("   "), 3, 4);
}

test "translate, with and without its second argument" {
    try expectPoint(.{ 7, 9 }, try parse("translate(4,5)"), 3, 4);
    try expectPoint(.{ 7, 4 }, try parse("translate(4)"), 3, 4);
    try expectPoint(.{ 7, 9 }, try parse("translate( 4 , 5 )"), 3, 4);
}

test "scale, with and without its second argument" {
    try expectPoint(.{ 6, 8 }, try parse("scale(2)"), 3, 4);
    try expectPoint(.{ 6, 4 }, try parse("scale(2,1)"), 3, 4);
}

test "rotate, about the origin and about a point" {
    // A quarter turn sends (1,0) to (0,1) in SVG's y-down space.
    try expectPoint(.{ 0, 1 }, try parse("rotate(90)"), 1, 0);
    try expectPoint(.{ -1, 0 }, try parse("rotate(180)"), 1, 0);
    // About (2,2), the point (2,2) does not move and (3,2) goes to (2,3).
    try expectPoint(.{ 2, 2 }, try parse("rotate(90,2,2)"), 2, 2);
    try expectPoint(.{ 2, 3 }, try parse("rotate(90,2,2)"), 3, 2);
}

test "matrix maps a b c d e f onto the right cells" {
    // z2d's `by` is SVG's `c` and its `cx` is SVG's `b`, so this is the test
    // that catches a transposed rotation.
    const t = try parse("matrix(1 2 3 4 5 6)");
    try testing.expectEqual(@as(f64, 1), t.ax);
    try testing.expectEqual(@as(f64, 2), t.cx);
    try testing.expectEqual(@as(f64, 3), t.by);
    try testing.expectEqual(@as(f64, 4), t.dy);
    try testing.expectEqual(@as(f64, 5), t.tx);
    try testing.expectEqual(@as(f64, 6), t.ty);
    // x' = 1·x + 3·y + 5, y' = 2·x + 4·y + 6
    try expectPoint(.{ 1 + 6 + 5, 2 + 8 + 6 }, t, 1, 2);
}

test "skewX widens and skewY heightens" {
    // The cheapest check that `by` and `cx` are not swapped: skewX moves a
    // point sideways in proportion to its y, and leaves y alone.
    try expectPoint(.{ 1 + 1, 1 }, try parse("skewX(45)"), 1, 1);
    try expectPoint(.{ 1, 1 + 1 }, try parse("skewY(45)"), 1, 1);
}

test "a list composes left to right, rightmost applied first" {
    // scale then translate: the point is doubled and then moved, so (1,0)
    // lands at (8+2, 0) rather than at (2·(1+8), 0).
    try expectPoint(.{ 10, 0 }, try parse("translate(8,0) scale(2)"), 1, 0);
    try expectPoint(.{ 18, 0 }, try parse("scale(2) translate(8,0)"), 1, 0);
}

test "the separators are commas, whitespace, both, or neither" {
    const expected: [2]f64 = .{ 10, 0 };
    for ([_][]const u8{
        "translate(8,0) scale(2)",
        "translate(8 0)scale(2)",
        "translate(8,0),scale(2)",
        "  translate( 8 , 0 )  scale( 2 )  ",
        "translate(8-0)scale(2)",
    }) |t| {
        try expectPoint(expected, try parse(t), 1, 0);
    }
}

test "a list that cannot be read is refused" {
    for ([_][]const u8{
        "bogus(1)",
        "translate(",
        "translate(1,2,3)",
        "rotate(45,1)",
        "scale()",
        "matrix(1 2 3 4 5)",
        "matrix(1 2 3 4 5 6 7)",
        "skewX(1,2)",
        "translate(1,2) bogus(3)",
        "(1,2)",
        "translate 1 2",
        "SCALE(2)",
    }) |t| {
        try testing.expectError(error.BadTransform, parse(t));
    }
}

test "a number that is not finite never enters a matrix" {
    // The scanner refuses one, so no single function can build a matrix with
    // an infinity in it.
    try testing.expectError(error.BadTransform, parse("matrix(1e400 0 0 1 0 0)"));
    try testing.expectError(error.BadTransform, parse("scale(1e400)"));
}

test "a composition that overflows is caught" {
    // Every argument is finite and the product is not: this is why `isFinite`
    // is checked where the matrix is used rather than where each one is built.
    // `skewX(90)` is *not* an example -- the tangent of a right angle in
    // floating point is about 1.6e16, which is finite and merely enormous.
    try testing.expect(isFinite(try parse("skewX(90)")));
    try testing.expect(isFinite(.identity));
    try testing.expect(!isFinite(try parse("scale(1e300) scale(1e300)")));
    try testing.expect(!isFinite(try parse("scale(1e300) scale(1e300) scale(2)")));
}

test "the CSS syntax, with units, commas and CSS's own functions" {
    const box: length.Viewport = .{ .width = 40, .height = 20, .font_size = 10 };
    try expectPoint(.{ 15, 10 }, try parseCss("translate(5px)", box), 10, 10);
    try expectPoint(.{ 15, 20 }, try parseCss("translate(5px, 10px)", box), 10, 10);
    // Percentages of the reference box, each on its own axis.
    try expectPoint(.{ 30, 15 }, try parseCss("translate(50%, 25%)", box), 10, 10);
    try expectPoint(.{ 20, 10 }, try parseCss("translateX(1em)", box), 10, 10);
    try expectPoint(.{ 10, 106 }, try parseCss("TRANSLATEY(1in)", box), 10, 10);
    try expectPoint(.{ 20, 5 }, try parseCss("scale(2, 50%)", box), 10, 10);
    try expectPoint(.{ 20, 10 }, try parseCss("scaleX(2)", box), 10, 10);
    try expectPoint(.{ -10, 10 }, try parseCss("rotate(0.25turn)", box), 10, 10);
    try expectPoint(.{ -10, 10 }, try parseCss("rotate(100grad)", box), 10, 10);
    try expectPoint(.{ 20, 10 }, try parseCss("skewX(45deg)", box), 10, 10);
    try expectPoint(.{ 20, 20 }, try parseCss("skew(45deg, 45deg)", box), 10, 10);
    try expectPoint(.{ 15, 15 }, try parseCss("matrix(1, 0, 0, 1, 5, 5)", box), 10, 10);
    // Left to right, and adjacent functions need no space between them.
    try expectPoint(.{ 10, 10 }, try parseCss("scale(0.5)translate(10px, 10px)", box), 10, 10);
    try expectPoint(.{ 10, 10 }, try parseCss("  none ", box), 10, 10);
    try expectPoint(.{ 10, 10 }, try parseCss("rotate(0)", box), 10, 10);
}

test "what is not CSS is refused, and so is what is not flat" {
    const box: length.Viewport = .{ .width = 40, .height = 20 };
    for ([_][]const u8{
        "",                       "translate(5)",        "rotate(90)",     "translate(5px 10px)", "translate(1em)",
        "scale(2,)",              "matrix(1 0 0 1 5 5)", "translate(5px",  "bogus(1px)",          "none none",
        "translate(5px) garbage", "skewX(45deg, 10deg)", "translate(1vw)",
    }) |t| testing.expectError(error.BadTransform, parseCss(t, box)) catch |err| {
        std.debug.print("{s}\n", .{t});
        return err;
    };
    for ([_][]const u8{ "rotateZ(45deg)", "translate3d(1px, 2px, 3px)", "perspective(100px)" }) |t| {
        try testing.expectError(error.UnsupportedTransform, parseCss(t, box));
    }
}
