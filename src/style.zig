// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The `style` attribute: SVG 1.1 §6.3.
//!
//! One CSS declaration block on an element -- `style="fill:red;stroke:none"` --
//! which is the same presentation properties the attributes carry, written the
//! other way and taking priority over them. Every drawing program writes it:
//! Inkscape, Illustrator and Figma all emit `style` where a hand-written
//! document would use attributes, so a renderer that does not read it renders
//! a large part of the world's SVG in the wrong colours.
//!
//! This is *not* CSS. There is no cascade here, no selectors, no `<style>`
//! element and no stylesheet: one element, one declaration block, and the
//! properties it names. That is the part of CSS SVG can be read without, and
//! the rest stays refused.
//!
//! ## Where this differs from resvg
//!
//! A malformed declaration -- one with no colon in it -- is skipped and the
//! ones after it are still read, which is what CSS 2.1 §4.2 says to do and
//! what browsers do. resvg stops at the first one instead, so
//! `style="nonsense;fill:blue"` is blue here and black there. Losing one
//! declaration of a broken document is better than losing all of them, and the
//! documents this actually matters for are the broken ones.
//!
//! Property *names* are matched with regard to case, which is what resvg does
//! and is not what CSS says. Values are left to the parsers that already read
//! them, so a colour keyword stays case-insensitive.

const std = @import("std");
const testing = std.testing;

/// A declaration as written: its value, and whether it carried `!important`.
pub const Declaration = struct {
    value: []const u8,
    /// Which band of CSS 2.1 §6.4.3's cascade this belongs to. Meaningless
    /// for a `style` attribute read on its own, and the whole of the ordering
    /// once there is a stylesheet to disagree with.
    important: bool,
};

/// The value of `name` in a declaration block, or null when it is not there.
///
/// `!important` is stripped, because a value being read has already won
/// whatever it was going to win. Use `declaration` where the cascade still has
/// to be decided.
pub fn property(block: []const u8, name: []const u8) ?[]const u8 {
    return (declaration(block, name) orelse return null).value;
}

/// The value of `name` in a declaration block, with its importance.
pub fn declaration(block: []const u8, name: []const u8) ?Declaration {
    // The *last* declaration of a name wins, which is what a cascade of one
    // block comes to -- so the whole block is read rather than stopping at the
    // first match.
    var found: ?Declaration = null;
    var it = std.mem.splitScalar(u8, block, ';');
    while (it.next()) |raw| {
        const decl = std.mem.trim(u8, raw, " \t\r\n");
        if (decl.len == 0) continue;
        // No colon is not a declaration. CSS says to skip it and read on.
        const colon = std.mem.findScalar(u8, decl, ':') orelse continue;
        const key = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        if (!std.mem.eql(u8, key, name)) continue;

        var value = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        var important = false;
        if (std.mem.endsWith(u8, value, "!important")) {
            value = std.mem.trim(u8, value[0 .. value.len - "!important".len], " \t\r\n");
            important = true;
        }
        if (value.len == 0) continue;
        found = .{ .value = value, .important = important };
    }
    return found;
}

test "a declaration block gives up its properties" {
    try testing.expectEqualStrings("red", property("fill:red", "fill").?);
    try testing.expectEqualStrings("red", property(" fill : red ; ", "fill").?);
    try testing.expectEqualStrings("red", property("stroke:blue;fill:red", "fill").?);
    try testing.expectEqualStrings("blue", property("stroke:blue;fill:red", "stroke").?);
    try testing.expectEqual(@as(?[]const u8, null), property("fill:red", "stroke"));
    try testing.expectEqual(@as(?[]const u8, null), property("", "fill"));

    // A value that is a function keeps its own punctuation, colons included --
    // which is why the *first* colon is what splits a declaration.
    try testing.expectEqualStrings("url(#g)", property("fill:url(#g)", "fill").?);

    // `!important` decides which of two declarations wins a cascade. There is
    // no cascade here, so a value being read has already won.
    try testing.expectEqualStrings("red", property("fill:red !important", "fill").?);
    try testing.expectEqualStrings("red", property("fill:red!important", "fill").?);

    // Names are matched with regard to case, as resvg does.
    try testing.expectEqual(@as(?[]const u8, null), property("FILL:red", "fill"));
    // Values are left to whoever reads them, so their case survives.
    try testing.expectEqualStrings("RED", property("fill:RED", "fill").?);
}

test "a malformed declaration is skipped and the rest are read" {
    // CSS 2.1 §4.2, and what browsers do. resvg stops at the first one
    // instead, which loses every declaration after it.
    try testing.expectEqualStrings("red", property("nonsense;fill:red", "fill").?);
    try testing.expectEqualStrings("red", property("fill:red;nonsense", "fill").?);
    try testing.expectEqualStrings("red", property(";;fill:red;;", "fill").?);
    try testing.expectEqualStrings("red", property("stroke;fill:red", "fill").?);

    // A declaration with a name and no value says nothing, and does not hide
    // a later one that does.
    try testing.expectEqualStrings("red", property("fill:;fill:red", "fill").?);
    try testing.expectEqual(@as(?[]const u8, null), property("fill:", "fill"));
    try testing.expectEqual(@as(?[]const u8, null), property("fill: ", "fill"));

    // The last declaration of a name wins, which is what a cascade of one
    // block comes to.
    try testing.expectEqualStrings("blue", property("fill:red;fill:blue", "fill").?);
}
