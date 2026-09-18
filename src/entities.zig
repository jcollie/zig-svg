// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Entity references inside an attribute value.
//!
//! The XML reader hands an attribute's value back exactly as it was written,
//! references and all, because resolving one means allocating for it and the
//! reader allocates nothing. So `d="M0 0L1 1&#90;"` arrives here as those
//! fifteen characters rather than as the path it spells, and something has to
//! turn one into the other.
//!
//! ## Only `&` matters
//!
//! XML's attribute-value normalization does two things: it resolves references
//! and it replaces a literal tab, carriage return or newline with a space.
//! zxml's `needsDecode` reports both, and this deliberately looks only for the
//! first.
//!
//! The reason is that every grammar this library parses already treats those
//! three characters as whitespace: path data separates its numbers with them,
//! `points` does, a colour is trimmed of them, and a keyword containing one is
//! not that keyword either before normalization or after. Turning them into
//! spaces would change nothing and would mean copying the many multi-line `d`
//! attributes that real documents are full of. A reference is different: it
//! stands for a character the parser has to see.
//!
//! ## Where a value is decoded
//!
//! Wherever there is already an allocator, and not before. A value that is
//! parsed into a number, a colour or a matrix is decoded where it is read,
//! into a buffer on the stack, because those are short by their nature and are
//! consumed immediately. The three that are *borrowed* rather than parsed --
//! a `<path>`'s `d`, a poly's `points` and a `stroke-dasharray` -- stay raw in
//! the `Shape` and are decoded when they are drawn, which is where an
//! allocator is to hand and where the length is not bounded by anything but
//! the document.

const std = @import("std");
const testing = std.testing;

const xml = @import("zxml");

pub const Error = error{
    /// A decoded attribute value longer than `max_short_value`, in one of the
    /// places that decodes into a fixed buffer.
    AttributeTooLong,
} || xml.Error;

/// Room for a decoded attribute value that is parsed rather than borrowed.
///
/// Every value decoded into a buffer this size is one number, one colour, one
/// keyword or one transform list, and a kilobyte is a long way past any of
/// those. The three that can be arbitrarily long are decoded with an allocator
/// instead.
pub const max_short_value = 1024;

/// Whether `raw` has anything in it that needs resolving.
///
/// Only `&`, for the reason given above.
pub fn needed(raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw, '&') != null;
}

/// `raw` with its references resolved, in `scratch`, or `raw` itself when
/// there is nothing to resolve.
///
/// The returned slice borrows from one or the other, so it lives exactly as
/// long as whichever it came from -- which for `scratch` means until the next
/// call that uses the same buffer. Every caller parses the value into a number
/// or a colour before reading another, which is what makes one buffer enough.
pub fn decodeShort(raw: []const u8, scratch: *[max_short_value]u8) Error![]const u8 {
    if (!needed(raw)) return raw;

    var fba: std.heap.FixedBufferAllocator = .init(scratch);
    var out: std.ArrayList(u8) = .empty;
    xml.decodeAppend(fba.allocator(), &out, raw, .strict, .attribute) catch |err| switch (err) {
        error.OutOfMemory => return error.AttributeTooLong,
        else => |e| return e,
    };
    return out.items;
}

/// `raw` with its references resolved, allocated, or null when there was
/// nothing to resolve and the caller should go on using `raw`.
///
/// Null rather than a copy so that the overwhelmingly common case -- a `d`
/// with no reference in it, which is every document anybody has -- costs
/// nothing at all.
pub fn decodeLong(gpa: std.mem.Allocator, raw: []const u8) (Error || std.mem.Allocator.Error)!?[]u8 {
    if (!needed(raw)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);
    try xml.decodeAppend(gpa, &out, raw, .strict, .attribute);
    return try out.toOwnedSlice(gpa);
}

// -- tests -------------------------------------------------------------------

test "a value with no reference is handed back untouched" {
    var scratch: [max_short_value]u8 = undefined;
    const raw = "M0 0L1 1Z";
    const got = try decodeShort(raw, &scratch);
    // The same slice, not a copy of it.
    try testing.expectEqual(raw.ptr, got.ptr);
    try testing.expect(!needed(raw));
}

test "whitespace alone is not a reason to decode" {
    // A multi-line `d` is what most real documents have, and normalizing its
    // newlines into spaces would change nothing a parser here can see.
    const raw = "M0 0\n  L1 1\tZ";
    try testing.expect(!needed(raw));
    var scratch: [max_short_value]u8 = undefined;
    try testing.expectEqual(raw.ptr, (try decodeShort(raw, &scratch)).ptr);
}

test "a character reference is resolved" {
    var scratch: [max_short_value]u8 = undefined;
    try testing.expectEqualStrings("M0 0L1 1Z", try decodeShort("M0 0L1 1&#90;", &scratch));
    try testing.expectEqualStrings("M0 0L1 1Z", try decodeShort("M0 0L1 1&#x5A;", &scratch));
    try testing.expectEqualStrings("red", try decodeShort("&#114;ed", &scratch));
}

test "the five predefined names are resolved" {
    var scratch: [max_short_value]u8 = undefined;
    try testing.expectEqualStrings("&", try decodeShort("&amp;", &scratch));
    try testing.expectEqualStrings("<", try decodeShort("&lt;", &scratch));
    try testing.expectEqualStrings(">", try decodeShort("&gt;", &scratch));
    try testing.expectEqualStrings("'", try decodeShort("&apos;", &scratch));
    try testing.expectEqualStrings("\"", try decodeShort("&quot;", &scratch));
}

test "a name nobody declared is refused rather than passed through" {
    // `.strict`, so an unknown name is an error instead of surviving as text
    // and reaching a parser that will call it something less helpful.
    var scratch: [max_short_value]u8 = undefined;
    try testing.expectError(error.UnknownEntity, decodeShort("&nosuch;", &scratch));
    try testing.expectError(error.UnknownEntity, decodeShort("&mdash;", &scratch));
}

test "a decoded value too long for the buffer is refused" {
    var scratch: [max_short_value]u8 = undefined;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    // Each reference is five characters in and one out, so this is well under
    // the buffer raw and well over it decoded... no: it is over either way,
    // which is what makes it a fair test of the buffer rather than of the
    // ratio.
    for (0..max_short_value + 1) |_| try long.appendSlice(testing.allocator, "&#65;");
    try testing.expectError(error.AttributeTooLong, decodeShort(long.items, &scratch));
}

test "a long value is allocated only when it has to be" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(?[]u8, null), try decodeLong(gpa, "M0 0L1 1Z"));
    const decoded = (try decodeLong(gpa, "M0 0L1 1&#90;")).?;
    defer gpa.free(decoded);
    try testing.expectEqualStrings("M0 0L1 1Z", decoded);
}
