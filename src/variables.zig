// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `var()` in a property value, substituted from custom properties the
//! caller supplies.
//!
//! The case this exists for is OpenType's: an SVG glyph names its colors as
//! `fill="var(--color0, yellow)"`, and the text engine defines `--color0`
//! and its siblings from the font's CPAL palette. The font is told not to
//! define any variables of its own, so only the caller's are consulted -- a
//! `--name: value` declaration in the document is not.
//!
//! A value that cannot be substituted -- a `var()` naming nothing, with no
//! fallback, or one that is malformed -- is what CSS calls *invalid at
//! computed-value time*, and the property behaves as though it were unset:
//! inherited if it inherits, its initial value if not. That is what reading
//! it as absent comes to here.
//!
//! Substitution builds text that exists nowhere in the document, so it
//! allocates. Each value is substituted once per `Variables` and kept, keyed
//! by where the original text lives, so a document walked several times --
//! once to count, once to measure, once to draw -- pays once, and what it
//! keeps is bounded by the source rather than by the number of walks.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const css = @import("css");

/// One custom property: its name with the leading `--`, and its value as
/// CSS text -- `#8b0000ff`, `rgb(0 170 179)`, `darkblue`.
pub const Entry = css.custom.Map.Entry;

/// The custom properties a document's `var()`s are substituted from, and
/// the text each substitution produced.
pub const Variables = struct {
    gpa: Allocator,
    map: css.custom.Map,
    cache: std.AutoHashMapUnmanaged(Key, ?[]const u8) = .empty,
    /// The allocation that failed, when one did. `resolve` cannot report it
    /// -- a property read has no error to return -- so it answers as though
    /// the value were unset and keeps this for whoever installed it to
    /// check once the walk is over.
    failure: ?Allocator.Error = null,

    const Key = struct { ptr: usize, len: usize };

    pub fn init(gpa: Allocator, entries: []const Entry) Variables {
        return .{ .gpa = gpa, .map = .{ .entries = entries } };
    }

    pub fn deinit(self: *Variables) void {
        var it = self.cache.valueIterator();
        while (it.next()) |v| if (v.*) |text| self.gpa.free(text);
        self.cache.deinit(self.gpa);
        self.* = undefined;
    }

    /// `raw` with every `var()` in it replaced, or `raw` itself when it has
    /// none. Null when the value is invalid at computed-value time, or when
    /// substituting it ran out of memory -- see `failure`.
    ///
    /// The text lives as long as this does.
    pub fn resolve(self: *Variables, raw: []const u8) ?[]const u8 {
        if (!css.custom.holdsVar(raw)) return raw;
        const key: Key = .{ .ptr = @intFromPtr(raw.ptr), .len = raw.len };
        if (self.cache.get(key)) |known| return known;

        var out: std.ArrayList(u8) = .empty;
        const text: ?[]const u8 = if (css.custom.substitute(self.gpa, raw, self.map, &out)) |_|
            out.toOwnedSlice(self.gpa) catch |err| return self.fail(&out, err)
        else |err| switch (err) {
            error.OutOfMemory => |e| return self.fail(&out, e),
            else => blk: {
                out.deinit(self.gpa);
                break :blk null;
            },
        };
        self.cache.put(self.gpa, key, text) catch |err| {
            if (text) |t| self.gpa.free(t);
            self.failure = err;
            return null;
        };
        return text;
    }

    fn fail(self: *Variables, out: *std.ArrayList(u8), err: Allocator.Error) ?[]const u8 {
        out.deinit(self.gpa);
        self.failure = err;
        return null;
    }
};

test "a var() takes the caller's value, and its fallback without one" {
    var vars: Variables = .init(testing.allocator, &.{.{ .name = "--color0", .value = "#ff000080" }});
    defer vars.deinit();
    try testing.expectEqualStrings("#ff000080", vars.resolve("var(--color0, yellow)").?);
    try testing.expectEqualStrings("yellow", std.mem.trim(u8, vars.resolve("var(--color1, yellow)").?, " "));
    try testing.expectEqualStrings("blue", vars.resolve("blue").?);
}

test "a var() naming nothing, with no fallback, is unset" {
    var vars: Variables = .init(testing.allocator, &.{});
    defer vars.deinit();
    try testing.expectEqual(@as(?[]const u8, null), vars.resolve("var(--color3)"));
    try testing.expectEqual(@as(?Allocator.Error, null), vars.failure);
}

test "the same text is substituted once" {
    var vars: Variables = .init(testing.allocator, &.{.{ .name = "--c", .value = "red" }});
    defer vars.deinit();
    const raw = "var(--c)";
    const a = vars.resolve(raw).?;
    const b = vars.resolve(raw).?;
    try testing.expectEqual(a.ptr, b.ptr);
}
