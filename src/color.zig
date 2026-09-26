// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The colour syntax an SVG presentation attribute is written in.
//!
//! This is CSS colour, as SVG 1.1 §4.1 and CSS Color 3 define it, plus the
//! four- and eight-digit hex forms and the space-separated `rgb()` that CSS
//! Color 4 added and every renderer now takes:
//!
//! ```
//! #f00   #ff0000   #f00f   #ff0000ff
//! rgb(255, 0, 0)   rgb(255 0 0)   rgb(100%, 0%, 0%)
//! rgba(255, 0, 0, 0.5)             rgba(255, 0, 0, 50%)
//! red    REBECCAPURPLE   transparent
//! none   currentColor
//! ```
//!
//! ## Two case rules, and they are different
//!
//! A colour **name** is matched without regard to case -- `RED`, `Red` and
//! `red` are one colour -- because CSS keywords are ASCII case-insensitive.
//! A **keyword elsewhere in SVG** is not: `fill-rule="EVENODD"` is not
//! `evenodd`, because that is an XML attribute value and XML is case-sensitive.
//! resvg draws both of those the same way and so does this. Getting the two
//! rules the same way round as each other would be wrong twice.
//!
//! ## Where this and resvg disagree, on purpose
//!
//! resvg is this project's oracle, and every colour here was checked against
//! it. Four differences survived that check, and each is deliberate.
//!
//! **A value this cannot read is refused.** `fill="notacolour"` is
//! `error.BadColor`; resvg, and every browser, falls back to the initial value
//! and paints the shape black. A shape painted the wrong colour is a picture
//! that looks finished and is not, which is the failure nobody notices -- the
//! same reason an element this library cannot draw is refused rather than
//! skipped. A caller who wants resvg's behaviour can catch the error and go on
//! with a colour of their own.
//!
//! The other three are places where this is the *more* permissive of the two,
//! because CSS Color 4 and SVG 2 define them and resvg 0.48.1 has not caught
//! up; it paints black for each. None of them appears in `tests/oracle`, since
//! a fixture using one would be testing resvg's gap rather than this code.
//!
//! * `rebeccapurple`, the 148th colour keyword.
//! * The slash alpha separator: `rgb(255 0 0 / 0.5)`.
//! * A percentage alpha: `rgba(255, 0, 0, 50%)`.
//!
//! What resvg *does* take, and so does this: the space-separated component
//! form `rgb(255 0 0)`, a fourth comma-separated argument to either `rgb` or
//! `rgba`, percentages for the components, and all four hex lengths.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;

pub const Error = error{
    /// A `fill` this module cannot read.
    BadColor,
    /// An `opacity` or `fill-opacity` that is not a number or a percentage.
    BadOpacity,
};

/// A colour, in straight (not premultiplied) alpha.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    /// 0 to 1. From `#rrggbbaa`, from `rgba()`, or 1 when the syntax carries
    /// no alpha of its own.
    alpha: f64 = 1.0,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .alpha = 0 };
};

/// What a `fill` attribute can say.
pub const Paint = union(enum) {
    /// `fill="none"`: the shape is not painted. Different from a transparent
    /// colour only in that nothing is computed for it.
    none,
    /// `fill="currentColor"`: whatever the `color` property holds, which is
    /// inherited and whose initial value the caller chooses.
    current,
    /// A colour the document named.
    color: Color,
    /// `fill="url(#g)"`: a paint server elsewhere in the document, named by
    /// the id this holds -- without the `#`, and borrowed from wherever the
    /// attribute value lives.
    reference: []const u8,
    /// SVG 2's `context-fill` and `context-stroke`: the fill or the stroke
    /// of the context element -- the shape a marker is drawn on, or the
    /// `<use>` a shape is drawn through. Resolved by the walk, so a renderer
    /// never sees one; where there is no context it paints nothing.
    context_fill,
    context_stroke,
};

/// Read a `fill`.
pub fn parsePaint(text: []const u8) Error!Paint {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (ascii.eqlIgnoreCase(t, "none")) return .none;
    if (ascii.eqlIgnoreCase(t, "currentcolor")) return .current;
    if (ascii.eqlIgnoreCase(t, "context-fill")) return .context_fill;
    if (ascii.eqlIgnoreCase(t, "context-stroke")) return .context_stroke;
    if (parseReference(t)) |id| return .{ .reference = id };
    return .{ .color = try parseColor(t) };
}

/// The id inside a `url(#id)`, or null when this is not one.
///
/// Only a fragment of this document. `url(other.svg#g)` names a file, and
/// fetching one is what being sans-I/O rules out -- so it is not a reference
/// this can resolve, and falls through to being refused as a colour, which is
/// what it is not.
fn parseReference(t: []const u8) ?[]const u8 {
    if (t.len < 7) return null; // `url(#x)` is the shortest there is
    if (!ascii.eqlIgnoreCase(t[0..4], "url(")) return null;
    if (t[t.len - 1] != ')') return null;
    const inner = std.mem.trim(u8, t[4 .. t.len - 1], " \t\r\n'\"");
    if (inner.len < 2 or inner[0] != '#') return null;
    return inner[1..];
}

/// Read a colour, which `none` and `currentColor` are not.
pub fn parseColor(text: []const u8) Error!Color {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.BadColor;
    if (t[0] == '#') return parseHex(t[1..]);
    if (std.mem.findScalar(u8, t, '(') != null) return parseFunctional(t);
    return parseName(t) orelse error.BadColor;
}

/// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`.
fn parseHex(digits: []const u8) Error!Color {
    for (digits) |c| {
        if (!ascii.isHex(c)) return error.BadColor;
    }
    // The short forms double each digit rather than shifting it, so that `#fff`
    // is white and not `#f0f0f0`.
    return switch (digits.len) {
        3 => .{
            .r = nybble(digits[0]) * 17,
            .g = nybble(digits[1]) * 17,
            .b = nybble(digits[2]) * 17,
        },
        4 => .{
            .r = nybble(digits[0]) * 17,
            .g = nybble(digits[1]) * 17,
            .b = nybble(digits[2]) * 17,
            .alpha = @as(f64, @floatFromInt(nybble(digits[3]) * 17)) / 255.0,
        },
        6 => .{
            .r = byte(digits[0..2].*),
            .g = byte(digits[2..4].*),
            .b = byte(digits[4..6].*),
        },
        8 => .{
            .r = byte(digits[0..2].*),
            .g = byte(digits[2..4].*),
            .b = byte(digits[4..6].*),
            .alpha = @as(f64, @floatFromInt(byte(digits[6..8].*))) / 255.0,
        },
        else => error.BadColor,
    };
}

fn nybble(c: u8) u8 {
    return std.fmt.charToDigit(c, 16) catch unreachable; // checked by the caller
}

fn byte(pair: [2]u8) u8 {
    return nybble(pair[0]) * 16 + nybble(pair[1]);
}

/// `rgb(…)` and `rgba(…)`, with the components separated by commas or by
/// spaces, and the alpha by a comma or a slash.
fn parseFunctional(text: []const u8) Error!Color {
    const open = std.mem.findScalar(u8, text, '(').?;
    if (text[text.len - 1] != ')') return error.BadColor;
    const name = std.mem.trim(u8, text[0..open], " \t\r\n");
    const is_rgba = ascii.eqlIgnoreCase(name, "rgba");
    if (!is_rgba and !ascii.eqlIgnoreCase(name, "rgb")) return error.BadColor;

    // `rgb` and `rgba` have been interchangeable since CSS Color 4, so the
    // name decides nothing; the argument count does.
    var it = std.mem.tokenizeAny(u8, text[open + 1 .. text.len - 1], " \t\r\n,/");
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == parts.len) return error.BadColor;
        parts[n] = part;
    }
    if (n != 3 and n != 4) return error.BadColor;

    return .{
        .r = try component(parts[0]),
        .g = try component(parts[1]),
        .b = try component(parts[2]),
        .alpha = if (n == 4) try alphaValue(parts[3]) else 1.0,
    };
}

/// One `rgb()` component: `0`–`255`, or a percentage of 255.
fn component(text: []const u8) Error!u8 {
    const value = if (std.mem.endsWith(u8, text, "%")) pct: {
        const p = std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch return error.BadColor;
        break :pct p / 100.0 * 255.0;
    } else std.fmt.parseFloat(f64, text) catch return error.BadColor;
    if (std.math.isNan(value)) return error.BadColor;
    // CSS clamps a component that is out of range rather than rejecting it.
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 255.0)));
}

/// An alpha inside `rgba()`: `0`–`1`, or a percentage.
fn alphaValue(text: []const u8) Error!f64 {
    const value = if (std.mem.endsWith(u8, text, "%")) pct: {
        const p = std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch return error.BadColor;
        break :pct p / 100.0;
    } else std.fmt.parseFloat(f64, text) catch return error.BadColor;
    if (std.math.isNan(value)) return error.BadColor;
    return std.math.clamp(value, 0.0, 1.0);
}

/// An `opacity` or `fill-opacity`: a number, or a percentage, clamped to 0–1.
///
/// Clamped rather than refused because CSS says so, and because a document
/// saying `fill-opacity="2"` means "as opaque as possible" clearly enough. A
/// value that is not a number at all is still refused.
pub fn parseOpacity(text: []const u8) Error!f64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.BadOpacity;
    const value = if (std.mem.endsWith(u8, t, "%")) pct: {
        const p = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch return error.BadOpacity;
        break :pct p / 100.0;
    } else std.fmt.parseFloat(f64, t) catch return error.BadOpacity;
    if (std.math.isNan(value)) return error.BadOpacity;
    return std.math.clamp(value, 0.0, 1.0);
}

/// A CSS colour keyword, matched without regard to case.
fn parseName(text: []const u8) ?Color {
    // Long enough for `lightgoldenrodyellow`, which is the longest of them at
    // twenty characters. Anything longer is not a name, so it need not fit.
    var buf: [24]u8 = undefined;
    if (text.len > buf.len) return null;
    const lower = ascii.lowerString(buf[0..text.len], text);

    // `transparent` is a keyword rather than a colour, and it is the one whose
    // alpha is not 1.
    if (std.mem.eql(u8, lower, "transparent")) return .transparent;
    return named.get(lower);
}

/// The CSS colour keywords.
///
/// Cross-checked against resvg, which is this project's oracle: a document
/// naming all 148 was rendered by resvg and every pixel compared against this
/// table. The one disagreement is `rebeccapurple`, which resvg 0.48.1 does not
/// know and paints black. It is kept here because CSS Color 4 and SVG 2 both
/// define it; it is deliberately absent from `tests/oracle`, since a fixture
/// using it would be testing resvg's gap rather than this table.
const named = std.StaticStringMap(Color).initComptime(.{
    .{ "aliceblue", Color{ .r = 240, .g = 248, .b = 255 } },
    .{ "antiquewhite", Color{ .r = 250, .g = 235, .b = 215 } },
    .{ "aqua", Color{ .r = 0, .g = 255, .b = 255 } },
    .{ "aquamarine", Color{ .r = 127, .g = 255, .b = 212 } },
    .{ "azure", Color{ .r = 240, .g = 255, .b = 255 } },
    .{ "beige", Color{ .r = 245, .g = 245, .b = 220 } },
    .{ "bisque", Color{ .r = 255, .g = 228, .b = 196 } },
    .{ "black", Color{ .r = 0, .g = 0, .b = 0 } },
    .{ "blanchedalmond", Color{ .r = 255, .g = 235, .b = 205 } },
    .{ "blue", Color{ .r = 0, .g = 0, .b = 255 } },
    .{ "blueviolet", Color{ .r = 138, .g = 43, .b = 226 } },
    .{ "brown", Color{ .r = 165, .g = 42, .b = 42 } },
    .{ "burlywood", Color{ .r = 222, .g = 184, .b = 135 } },
    .{ "cadetblue", Color{ .r = 95, .g = 158, .b = 160 } },
    .{ "chartreuse", Color{ .r = 127, .g = 255, .b = 0 } },
    .{ "chocolate", Color{ .r = 210, .g = 105, .b = 30 } },
    .{ "coral", Color{ .r = 255, .g = 127, .b = 80 } },
    .{ "cornflowerblue", Color{ .r = 100, .g = 149, .b = 237 } },
    .{ "cornsilk", Color{ .r = 255, .g = 248, .b = 220 } },
    .{ "crimson", Color{ .r = 220, .g = 20, .b = 60 } },
    .{ "cyan", Color{ .r = 0, .g = 255, .b = 255 } },
    .{ "darkblue", Color{ .r = 0, .g = 0, .b = 139 } },
    .{ "darkcyan", Color{ .r = 0, .g = 139, .b = 139 } },
    .{ "darkgoldenrod", Color{ .r = 184, .g = 134, .b = 11 } },
    .{ "darkgray", Color{ .r = 169, .g = 169, .b = 169 } },
    .{ "darkgreen", Color{ .r = 0, .g = 100, .b = 0 } },
    .{ "darkgrey", Color{ .r = 169, .g = 169, .b = 169 } },
    .{ "darkkhaki", Color{ .r = 189, .g = 183, .b = 107 } },
    .{ "darkmagenta", Color{ .r = 139, .g = 0, .b = 139 } },
    .{ "darkolivegreen", Color{ .r = 85, .g = 107, .b = 47 } },
    .{ "darkorange", Color{ .r = 255, .g = 140, .b = 0 } },
    .{ "darkorchid", Color{ .r = 153, .g = 50, .b = 204 } },
    .{ "darkred", Color{ .r = 139, .g = 0, .b = 0 } },
    .{ "darksalmon", Color{ .r = 233, .g = 150, .b = 122 } },
    .{ "darkseagreen", Color{ .r = 143, .g = 188, .b = 143 } },
    .{ "darkslateblue", Color{ .r = 72, .g = 61, .b = 139 } },
    .{ "darkslategray", Color{ .r = 47, .g = 79, .b = 79 } },
    .{ "darkslategrey", Color{ .r = 47, .g = 79, .b = 79 } },
    .{ "darkturquoise", Color{ .r = 0, .g = 206, .b = 209 } },
    .{ "darkviolet", Color{ .r = 148, .g = 0, .b = 211 } },
    .{ "deeppink", Color{ .r = 255, .g = 20, .b = 147 } },
    .{ "deepskyblue", Color{ .r = 0, .g = 191, .b = 255 } },
    .{ "dimgray", Color{ .r = 105, .g = 105, .b = 105 } },
    .{ "dimgrey", Color{ .r = 105, .g = 105, .b = 105 } },
    .{ "dodgerblue", Color{ .r = 30, .g = 144, .b = 255 } },
    .{ "firebrick", Color{ .r = 178, .g = 34, .b = 34 } },
    .{ "floralwhite", Color{ .r = 255, .g = 250, .b = 240 } },
    .{ "forestgreen", Color{ .r = 34, .g = 139, .b = 34 } },
    .{ "fuchsia", Color{ .r = 255, .g = 0, .b = 255 } },
    .{ "gainsboro", Color{ .r = 220, .g = 220, .b = 220 } },
    .{ "ghostwhite", Color{ .r = 248, .g = 248, .b = 255 } },
    .{ "gold", Color{ .r = 255, .g = 215, .b = 0 } },
    .{ "goldenrod", Color{ .r = 218, .g = 165, .b = 32 } },
    .{ "gray", Color{ .r = 128, .g = 128, .b = 128 } },
    .{ "green", Color{ .r = 0, .g = 128, .b = 0 } },
    .{ "greenyellow", Color{ .r = 173, .g = 255, .b = 47 } },
    .{ "grey", Color{ .r = 128, .g = 128, .b = 128 } },
    .{ "honeydew", Color{ .r = 240, .g = 255, .b = 240 } },
    .{ "hotpink", Color{ .r = 255, .g = 105, .b = 180 } },
    .{ "indianred", Color{ .r = 205, .g = 92, .b = 92 } },
    .{ "indigo", Color{ .r = 75, .g = 0, .b = 130 } },
    .{ "ivory", Color{ .r = 255, .g = 255, .b = 240 } },
    .{ "khaki", Color{ .r = 240, .g = 230, .b = 140 } },
    .{ "lavender", Color{ .r = 230, .g = 230, .b = 250 } },
    .{ "lavenderblush", Color{ .r = 255, .g = 240, .b = 245 } },
    .{ "lawngreen", Color{ .r = 124, .g = 252, .b = 0 } },
    .{ "lemonchiffon", Color{ .r = 255, .g = 250, .b = 205 } },
    .{ "lightblue", Color{ .r = 173, .g = 216, .b = 230 } },
    .{ "lightcoral", Color{ .r = 240, .g = 128, .b = 128 } },
    .{ "lightcyan", Color{ .r = 224, .g = 255, .b = 255 } },
    .{ "lightgoldenrodyellow", Color{ .r = 250, .g = 250, .b = 210 } },
    .{ "lightgray", Color{ .r = 211, .g = 211, .b = 211 } },
    .{ "lightgreen", Color{ .r = 144, .g = 238, .b = 144 } },
    .{ "lightgrey", Color{ .r = 211, .g = 211, .b = 211 } },
    .{ "lightpink", Color{ .r = 255, .g = 182, .b = 193 } },
    .{ "lightsalmon", Color{ .r = 255, .g = 160, .b = 122 } },
    .{ "lightseagreen", Color{ .r = 32, .g = 178, .b = 170 } },
    .{ "lightskyblue", Color{ .r = 135, .g = 206, .b = 250 } },
    .{ "lightslategray", Color{ .r = 119, .g = 136, .b = 153 } },
    .{ "lightslategrey", Color{ .r = 119, .g = 136, .b = 153 } },
    .{ "lightsteelblue", Color{ .r = 176, .g = 196, .b = 222 } },
    .{ "lightyellow", Color{ .r = 255, .g = 255, .b = 224 } },
    .{ "lime", Color{ .r = 0, .g = 255, .b = 0 } },
    .{ "limegreen", Color{ .r = 50, .g = 205, .b = 50 } },
    .{ "linen", Color{ .r = 250, .g = 240, .b = 230 } },
    .{ "magenta", Color{ .r = 255, .g = 0, .b = 255 } },
    .{ "maroon", Color{ .r = 128, .g = 0, .b = 0 } },
    .{ "mediumaquamarine", Color{ .r = 102, .g = 205, .b = 170 } },
    .{ "mediumblue", Color{ .r = 0, .g = 0, .b = 205 } },
    .{ "mediumorchid", Color{ .r = 186, .g = 85, .b = 211 } },
    .{ "mediumpurple", Color{ .r = 147, .g = 112, .b = 219 } },
    .{ "mediumseagreen", Color{ .r = 60, .g = 179, .b = 113 } },
    .{ "mediumslateblue", Color{ .r = 123, .g = 104, .b = 238 } },
    .{ "mediumspringgreen", Color{ .r = 0, .g = 250, .b = 154 } },
    .{ "mediumturquoise", Color{ .r = 72, .g = 209, .b = 204 } },
    .{ "mediumvioletred", Color{ .r = 199, .g = 21, .b = 133 } },
    .{ "midnightblue", Color{ .r = 25, .g = 25, .b = 112 } },
    .{ "mintcream", Color{ .r = 245, .g = 255, .b = 250 } },
    .{ "mistyrose", Color{ .r = 255, .g = 228, .b = 225 } },
    .{ "moccasin", Color{ .r = 255, .g = 228, .b = 181 } },
    .{ "navajowhite", Color{ .r = 255, .g = 222, .b = 173 } },
    .{ "navy", Color{ .r = 0, .g = 0, .b = 128 } },
    .{ "oldlace", Color{ .r = 253, .g = 245, .b = 230 } },
    .{ "olive", Color{ .r = 128, .g = 128, .b = 0 } },
    .{ "olivedrab", Color{ .r = 107, .g = 142, .b = 35 } },
    .{ "orange", Color{ .r = 255, .g = 165, .b = 0 } },
    .{ "orangered", Color{ .r = 255, .g = 69, .b = 0 } },
    .{ "orchid", Color{ .r = 218, .g = 112, .b = 214 } },
    .{ "palegoldenrod", Color{ .r = 238, .g = 232, .b = 170 } },
    .{ "palegreen", Color{ .r = 152, .g = 251, .b = 152 } },
    .{ "paleturquoise", Color{ .r = 175, .g = 238, .b = 238 } },
    .{ "palevioletred", Color{ .r = 219, .g = 112, .b = 147 } },
    .{ "papayawhip", Color{ .r = 255, .g = 239, .b = 213 } },
    .{ "peachpuff", Color{ .r = 255, .g = 218, .b = 185 } },
    .{ "peru", Color{ .r = 205, .g = 133, .b = 63 } },
    .{ "pink", Color{ .r = 255, .g = 192, .b = 203 } },
    .{ "plum", Color{ .r = 221, .g = 160, .b = 221 } },
    .{ "powderblue", Color{ .r = 176, .g = 224, .b = 230 } },
    .{ "purple", Color{ .r = 128, .g = 0, .b = 128 } },
    .{ "rebeccapurple", Color{ .r = 102, .g = 51, .b = 153 } },
    .{ "red", Color{ .r = 255, .g = 0, .b = 0 } },
    .{ "rosybrown", Color{ .r = 188, .g = 143, .b = 143 } },
    .{ "royalblue", Color{ .r = 65, .g = 105, .b = 225 } },
    .{ "saddlebrown", Color{ .r = 139, .g = 69, .b = 19 } },
    .{ "salmon", Color{ .r = 250, .g = 128, .b = 114 } },
    .{ "sandybrown", Color{ .r = 244, .g = 164, .b = 96 } },
    .{ "seagreen", Color{ .r = 46, .g = 139, .b = 87 } },
    .{ "seashell", Color{ .r = 255, .g = 245, .b = 238 } },
    .{ "sienna", Color{ .r = 160, .g = 82, .b = 45 } },
    .{ "silver", Color{ .r = 192, .g = 192, .b = 192 } },
    .{ "skyblue", Color{ .r = 135, .g = 206, .b = 235 } },
    .{ "slateblue", Color{ .r = 106, .g = 90, .b = 205 } },
    .{ "slategray", Color{ .r = 112, .g = 128, .b = 144 } },
    .{ "slategrey", Color{ .r = 112, .g = 128, .b = 144 } },
    .{ "snow", Color{ .r = 255, .g = 250, .b = 250 } },
    .{ "springgreen", Color{ .r = 0, .g = 255, .b = 127 } },
    .{ "steelblue", Color{ .r = 70, .g = 130, .b = 180 } },
    .{ "tan", Color{ .r = 210, .g = 180, .b = 140 } },
    .{ "teal", Color{ .r = 0, .g = 128, .b = 128 } },
    .{ "thistle", Color{ .r = 216, .g = 191, .b = 216 } },
    .{ "tomato", Color{ .r = 255, .g = 99, .b = 71 } },
    .{ "turquoise", Color{ .r = 64, .g = 224, .b = 208 } },
    .{ "violet", Color{ .r = 238, .g = 130, .b = 238 } },
    .{ "wheat", Color{ .r = 245, .g = 222, .b = 179 } },
    .{ "white", Color{ .r = 255, .g = 255, .b = 255 } },
    .{ "whitesmoke", Color{ .r = 245, .g = 245, .b = 245 } },
    .{ "yellow", Color{ .r = 255, .g = 255, .b = 0 } },
    .{ "yellowgreen", Color{ .r = 154, .g = 205, .b = 50 } },
});

// -- tests -------------------------------------------------------------------

fn expectColor(expected: Color, text: []const u8) !void {
    const got = try parseColor(text);
    try testing.expectEqual(expected.r, got.r);
    try testing.expectEqual(expected.g, got.g);
    try testing.expectEqual(expected.b, got.b);
    try testing.expectApproxEqAbs(expected.alpha, got.alpha, 1.0 / 255.0);
}

test "the hex forms" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0 };
    try expectColor(red, "#f00");
    try expectColor(red, "#ff0000");
    try expectColor(red, "#FF0000");
    try expectColor(red, "#f00f");
    try expectColor(red, "#ff0000ff");
    // The short form doubles each digit rather than shifting it, so `#fff` is
    // white and not `#f0f0f0`.
    try expectColor(.{ .r = 255, .g = 255, .b = 255 }, "#fff");
    try expectColor(.{ .r = 255, .g = 0, .b = 0, .alpha = 0.5 }, "#ff000080");
    try expectColor(.{ .r = 0, .g = 0, .b = 0, .alpha = 0 }, "#0000");
}

test "a hex value of the wrong length or with a stray digit is refused" {
    for ([_][]const u8{ "#", "#f", "#ff", "#12345", "#1234567", "#123456789", "#gg0000" }) |t| {
        try testing.expectError(error.BadColor, parseColor(t));
    }
}

test "the functional forms" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0 };
    try expectColor(red, "rgb(255,0,0)");
    try expectColor(red, "rgb(255, 0, 0)");
    try expectColor(red, "rgb( 255 , 0 , 0 )");
    try expectColor(red, "rgb(255 0 0)");
    try expectColor(red, "rgb(100%, 0%, 0%)");
    try expectColor(red, "RGB(255,0,0)");
    try expectColor(.{ .r = 255, .g = 0, .b = 0, .alpha = 0.5 }, "rgba(255, 0, 0, 0.5)");
    try expectColor(.{ .r = 255, .g = 0, .b = 0, .alpha = 0.5 }, "rgba(255, 0, 0, 50%)");
    try expectColor(.{ .r = 255, .g = 0, .b = 0, .alpha = 0.5 }, "rgb(255 0 0 / 0.5)");
}

test "a component out of range is clamped, as CSS says" {
    try expectColor(.{ .r = 255, .g = 0, .b = 0 }, "rgb(300, -20, 0)");
    try expectColor(.{ .r = 255, .g = 0, .b = 0, .alpha = 1 }, "rgba(255,0,0,7)");
    try expectColor(.{ .r = 255, .g = 0, .b = 0, .alpha = 0 }, "rgba(255,0,0,-7)");
}

test "a functional form that is malformed is refused" {
    for ([_][]const u8{
        "rgb(255,0)",
        "rgb(1,2,3,4,5)",
        "rgb(255,0,0",
        "hsl(0,100%,50%)",
        "rgb(a,b,c)",
        "rgb()",
    }) |t| {
        try testing.expectError(error.BadColor, parseColor(t));
    }
}

test "names are matched without regard to case" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0 };
    try expectColor(red, "red");
    try expectColor(red, "RED");
    try expectColor(red, "Red");
    try expectColor(red, " red ");
    try expectColor(.{ .r = 0, .g = 128, .b = 0 }, "green");
    try expectColor(.{ .r = 102, .g = 51, .b = 153 }, "rebeccapurple");
}

test "transparent is a colour whose alpha is zero" {
    try expectColor(.{ .r = 0, .g = 0, .b = 0, .alpha = 0 }, "transparent");
    try expectColor(.{ .r = 0, .g = 0, .b = 0, .alpha = 0 }, "TRANSPARENT");
}

test "every name in the table round trips, and nothing else is a name" {
    // The table is generated, so what is worth checking is that the lookup
    // finds every key it holds -- including the longest, which is what sizes
    // the buffer `parseName` lowercases into.
    for (named.keys()) |key| {
        _ = try parseColor(key);
        try testing.expect(key.len <= 24);
    }
    try testing.expectEqual(@as(usize, 148), named.keys().len);
    for ([_][]const u8{ "notacolour", "", "reddish", "lightgoldenrodyellowish" }) |t| {
        try testing.expectError(error.BadColor, parseColor(t));
    }
}

test "a url reference is read as one" {
    try testing.expectEqualStrings("g", (try parsePaint("url(#g)")).reference);
    try testing.expectEqualStrings("a-b", (try parsePaint("url( #a-b )")).reference);
    try testing.expectEqualStrings("q", (try parsePaint("URL(#q)")).reference);
    try testing.expectEqualStrings("q", (try parsePaint("url('#q')")).reference);
    // A reference to a file is not one this can resolve, so it is not a
    // reference at all -- and it is not a colour either.
    try testing.expectError(error.BadColor, parsePaint("url(other.svg#g)"));
    try testing.expectError(error.BadColor, parsePaint("url(#)"));
}

test "none and currentColor are not colours" {
    try testing.expectEqual(Paint.none, try parsePaint("none"));
    try testing.expectEqual(Paint.none, try parsePaint("NONE"));
    try testing.expectEqual(Paint.current, try parsePaint("currentColor"));
    try testing.expectEqual(Paint.current, try parsePaint("currentcolor"));
    try testing.expect((try parsePaint("red")) == .color);
    try testing.expectError(error.BadColor, parsePaint("notacolour"));
}

test "opacity takes a number or a percentage and clamps it" {
    try testing.expectApproxEqAbs(@as(f64, 0.5), try parseOpacity("0.5"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), try parseOpacity("50%"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), try parseOpacity("1"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), try parseOpacity("2"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try parseOpacity("-1"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try parseOpacity(" 0 "), 1e-12);
    for ([_][]const u8{ "", "notanumber", "%", "half" }) |t| {
        try testing.expectError(error.BadOpacity, parseOpacity(t));
    }
}

test "a non-finite number never gets out of here" {
    // `parseFloat` takes "inf" and "nan", and either reaching the compositor
    // is a wrong picture or worse.
    for ([_][]const u8{ "nan", "NaN" }) |t| {
        try testing.expectError(error.BadOpacity, parseOpacity(t));
    }
    // An infinity is a number, and clamping puts it in range.
    try testing.expectApproxEqAbs(@as(f64, 1.0), try parseOpacity("inf"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try parseOpacity("-inf"), 1e-12);
    try expectColor(.{ .r = 255, .g = 0, .b = 0 }, "rgb(inf, -inf, 0)");
    try testing.expectError(error.BadColor, parseColor("rgb(nan, 0, 0)"));
}
