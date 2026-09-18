// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading an `<svg>` element far enough to draw what is in it.
//!
//! What this understands is one shape of document -- one `<svg>` carrying a
//! `viewBox`, one `<path>` carrying a `d`, and nothing else:
//!
//! ```
//! <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3,9H7L12,4V20L7,15H3V9Z" /></svg>
//! ```
//!
//! Which is every one of the 7,447 Material Design Icons, and a great many
//! other icon sets besides, and is a long way short of SVG. There is no `<g>`,
//! no `transform`, no `style`, no gradient, no stroke and no `fill-rule`.
//!
//! An element this does not implement is **refused** rather than skipped.
//! Skipping it would draw a picture quietly missing a piece, which is the
//! failure nobody notices; `error.UnsupportedElement` is the failure somebody
//! does. The set of elements that carry no geometry -- `<title>`, `<desc>`,
//! `<metadata>`, `<defs>` -- is passed over, because passing those over is
//! correct rather than approximate.

const std = @import("std");
const xml = @import("zxml");
const z2d = @import("z2d");

const path = @import("path.zig");

pub const Error = error{
    /// The document has no `<svg>` element.
    NotAnSvg,
    /// `<svg>` has no `viewBox`, or one that is not four numbers.
    BadViewBox,
    /// There is no `<path>`, or it has no `d`.
    NoPath,
    /// An element this reader does not implement -- a `<g>`, a `<circle>`, a
    /// `<use>`. Refused rather than skipped: skipping it would draw a picture
    /// that is quietly missing a piece.
    UnsupportedElement,
} || xml.Error;

pub const ViewBox = struct {
    min_x: f64,
    min_y: f64,
    width: f64,
    height: f64,
};

pub const Document = struct {
    view_box: ViewBox,
    /// The `d` attribute, borrowed from the source buffer.
    d: []const u8,
};

/// The elements that carry no geometry and so may be passed over.
fn isIgnorable(name: []const u8) bool {
    return xml.nameIs(name, "title") or
        xml.nameIs(name, "desc") or
        xml.nameIs(name, "metadata") or
        xml.nameIs(name, "defs");
}

/// Read one document out of `src`.
///
/// Allocates nothing: the returned `d` points into `src`, which must outlive
/// the `Document`.
pub fn read(src: []const u8) Error!Document {
    var reader: xml.Reader = .init(src);

    var view_box: ?ViewBox = null;
    var d: ?[]const u8 = null;
    var depth_ignored: usize = 0;

    while (true) switch (try reader.next()) {
        .start_element => |e| {
            if (depth_ignored > 0) {
                if (!e.self_closing) depth_ignored += 1;
                continue;
            }
            if (xml.nameIs(e.name, "svg")) {
                view_box = try parseViewBox(e.attr("viewBox") orelse return error.BadViewBox);
            } else if (xml.nameIs(e.name, "path")) {
                // The first `<path>` wins. Taking the last would be no more
                // right than taking the first, and drawing both would need the
                // painting model this reader does not have.
                if (d == null) d = e.attr("d") orelse return error.NoPath;
            } else if (isIgnorable(e.name)) {
                if (!e.self_closing) depth_ignored += 1;
            } else {
                return error.UnsupportedElement;
            }
        },
        .end_element => {
            if (depth_ignored > 0) depth_ignored -= 1;
        },
        .eof => break,
        else => {},
    };

    return .{
        .view_box = view_box orelse return error.NotAnSvg,
        .d = d orelse return error.NoPath,
    };
}

/// `min-x min-y width height`, separated by whitespace or commas.
fn parseViewBox(raw: []const u8) Error!ViewBox {
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    var v: [4]f64 = undefined;
    for (&v) |*slot| {
        const tok = it.next() orelse return error.BadViewBox;
        slot.* = std.fmt.parseFloat(f64, tok) catch return error.BadViewBox;
        if (!std.math.isFinite(slot.*)) return error.BadViewBox;
    }
    if (it.next() != null) return error.BadViewBox;
    if (v[2] <= 0 or v[3] <= 0) return error.BadViewBox;
    return .{ .min_x = v[0], .min_y = v[1], .width = v[2], .height = v[3] };
}

pub const BuildError = Error || path.BuildError;

/// Read `src` and build its path, scaled to fill a `width` by `height` box.
pub fn buildPath(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    src: []const u8,
    width: f64,
    height: f64,
    opts: path.Options,
) BuildError!void {
    return buildPathIn(p, alloc, src, 0, 0, width, height, opts);
}

/// Read `src` and build its path, scaled to fit the box at `(x, y)`.
///
/// The scale is uniform and takes the smaller of the two ratios, so a box of a
/// different shape from the viewBox letterboxes rather than distorting --
/// which is what `preserveAspectRatio`'s default, `xMidYMid meet`, says to do.
/// That attribute is not read; this is its default behaviour and the only
/// behaviour available.
pub fn buildPathIn(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    src: []const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    opts: path.Options,
) BuildError!void {
    const doc = try read(src);
    try buildDocumentIn(p, alloc, doc, x, y, width, height, opts);
}

/// The same, for a `Document` that has already been read.
///
/// Worth having separately because `read` is the cheap half: a caller that
/// wants the viewBox before deciding how large to draw -- which is what
/// `render` does -- would otherwise have to parse the XML twice.
pub fn buildDocumentIn(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    doc: Document,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    opts: path.Options,
) path.BuildError!void {
    const scale = @min(width / doc.view_box.width, height / doc.view_box.height);
    const tx = x + (width - doc.view_box.width * scale) / 2.0 - doc.view_box.min_x * scale;
    const ty = y + (height - doc.view_box.height * scale) / 2.0 - doc.view_box.min_y * scale;

    // z2d applies the transformation when a point is added, not when the path
    // is filled, so this has to be in place before the first `moveTo`.
    const saved = p.transformation;
    defer p.transformation = saved;
    p.transformation = saved.mul(.{
        .ax = scale,
        .by = 0,
        .cx = 0,
        .dy = scale,
        .tx = tx,
        .ty = ty,
    });

    try path.build(p, alloc, doc.d, opts);
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

const icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3,9H7L12,4V20L7,15H3V9Z" /></svg>
;

test "a well formed icon reads" {
    const doc = try read(icon);
    try testing.expectEqual(@as(f64, 0), doc.view_box.min_x);
    try testing.expectEqual(@as(f64, 24), doc.view_box.width);
    try testing.expectEqualStrings("M3,9H7L12,4V20L7,15H3V9Z", doc.d);
}

test "an element with geometry this reader cannot draw is refused" {
    try testing.expectError(
        error.UnsupportedElement,
        read("<svg viewBox=\"0 0 24 24\"><g><path d=\"M0 0L1 1Z\"/></g></svg>"),
    );
    try testing.expectError(
        error.UnsupportedElement,
        read("<svg viewBox=\"0 0 24 24\"><circle cx=\"1\" cy=\"1\" r=\"1\"/></svg>"),
    );
}

test "elements that carry no geometry are passed over" {
    const doc = try read(
        "<svg viewBox=\"0 0 24 24\"><title>x</title><desc>y</desc><path d=\"M0 0L2 2Z\"/></svg>",
    );
    try testing.expectEqualStrings("M0 0L2 2Z", doc.d);
}

test "a viewBox that is not four positive numbers is refused" {
    try testing.expectError(error.BadViewBox, read("<svg viewBox=\"0 0\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read("<svg viewBox=\"0 0 0 0\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read("<svg viewBox=\"0 0 1 1 1\"><path d=\"M0 0Z\"/></svg>"));
    try testing.expectError(error.BadViewBox, read("<svg><path d=\"M0 0Z\"/></svg>"));
}

test "a document with no path is refused" {
    try testing.expectError(error.NoPath, read("<svg viewBox=\"0 0 24 24\"></svg>"));
    try testing.expectError(error.NoPath, read("<svg viewBox=\"0 0 24 24\"><path/></svg>"));
}

test "the viewBox is scaled into the box asked for" {
    const gpa = testing.allocator;
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    // A 24-unit viewBox into a 48-pixel box doubles everything.
    try buildPath(&p, gpa, icon, 48, 48, .{});
    try testing.expectApproxEqAbs(@as(f64, 6), p.nodes.items[0].move_to.point.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 18), p.nodes.items[0].move_to.point.y, 1e-9);
}

test "a box of a different shape letterboxes rather than distorting" {
    const gpa = testing.allocator;
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    // 48 wide by 24 tall: the scale is 1, and the drawing is centred.
    try buildPath(&p, gpa, icon, 48, 24, .{});
    try testing.expectApproxEqAbs(@as(f64, 3 + 12), p.nodes.items[0].move_to.point.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 9), p.nodes.items[0].move_to.point.y, 1e-9);
}
