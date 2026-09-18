// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading an `<svg>` element far enough to draw what is in it.
//!
//! What this understands is one `<svg>` carrying a `viewBox` and any number of
//! `<path>` elements carrying a `d`:
//!
//! ```
//! <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3,9H7L12,4V20L7,15H3V9Z" /></svg>
//! ```
//!
//! Which is every one of the 7,447 Material Design Icons, a great many other
//! icon sets, and a long way short of SVG. There is no `<g>`, no `transform`,
//! no `style`, no gradient, no stroke and no `fill` attribute.
//!
//! An element this does not implement is **refused** rather than skipped.
//! Skipping it would draw a picture quietly missing a piece, which is the
//! failure nobody notices; `error.UnsupportedElement` is the failure somebody
//! does. The set of elements that carry no geometry -- `<title>`, `<desc>`,
//! `<metadata>`, `<defs>` -- is passed over, because passing those over is
//! correct rather than approximate.
//!
//! ## Two passes, and why
//!
//! `read` walks the whole document and keeps only the `viewBox`; `Document.paths`
//! walks it again to hand out each `d` in turn. Re-walking is deliberate. A
//! `Document` that held its shapes would have to allocate for them or cap how
//! many it could hold, and this way it does neither: `read` allocates nothing
//! at all, and a `Document` is four floats and a slice.
//!
//! It also decides *when* a document is refused. `read` validates everything
//! before the caller has drawn anything, so a `<g>` at the end of a document
//! is an error rather than four shapes painted and then an error -- a partial
//! picture and a failure at once being the worst of both.

const std = @import("std");
const xml = @import("zxml");
const z2d = @import("z2d");

const path = @import("path.zig");

pub const Error = error{
    /// The document has no `<svg>` element.
    NotAnSvg,
    /// `<svg>` has no `viewBox`, or one that is not four numbers.
    BadViewBox,
    /// There is no `<path>` at all, or one of them has no `d`.
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

/// A document that has been read and found drawable.
///
/// Borrows `src`, which must outlive it, and allocates nothing.
pub const Document = struct {
    view_box: ViewBox,
    /// The source this was read from. `paths` walks it again.
    src: []const u8,
    /// How many `<path>` elements `read` found, so that a caller can bound the
    /// work before starting it.
    shape_count: usize,

    /// The `d` of each `<path>`, in document order.
    ///
    /// Order is the painting order: SVG paints shapes in the order they are
    /// written, each over the last.
    pub fn paths(self: Document) PathIterator {
        return .{ .reader = .init(self.src) };
    }

    /// The viewBox-to-pixels transformation for drawing into `box`.
    ///
    /// The scale is uniform and takes the smaller of the two ratios, so a box
    /// of a different shape from the viewBox letterboxes rather than
    /// distorting -- which is what `preserveAspectRatio`'s default,
    /// `xMidYMid meet`, says to do. That attribute is not read; this is its
    /// default behaviour and the only behaviour available.
    pub fn transformFor(self: Document, x: f64, y: f64, width: f64, height: f64) z2d.Transformation {
        const scale = @min(width / self.view_box.width, height / self.view_box.height);
        return .{
            .ax = scale,
            .by = 0,
            .cx = 0,
            .dy = scale,
            .tx = x + (width - self.view_box.width * scale) / 2.0 - self.view_box.min_x * scale,
            .ty = y + (height - self.view_box.height * scale) / 2.0 - self.view_box.min_y * scale,
        };
    }
};

/// Walks a document handing out one `d` attribute at a time.
///
/// Every error it could return was already returned by `read`, which is what
/// lets a caller drawing shape after shape treat `next` as infallible in
/// practice -- it is still `try`ed, because a parser that answered differently
/// on a second pass would be a bug worth hearing about rather than one to
/// paper over.
pub const PathIterator = struct {
    reader: xml.Reader,
    /// How deep inside a subtree that is not painted. Kept because `read` and
    /// this have to agree exactly on what counts as a shape: a `<path>` inside
    /// `<defs>` is not one, and an iterator that yielded it anyway would paint
    /// something the document said to keep back, having passed every check.
    depth_ignored: usize = 0,

    pub fn next(self: *PathIterator) Error!?[]const u8 {
        while (true) switch (try self.reader.next()) {
            .start_element => |e| {
                if (self.depth_ignored > 0) {
                    if (!e.self_closing) self.depth_ignored += 1;
                    continue;
                }
                if (xml.nameIs(e.name, "path")) {
                    return e.attr("d") orelse return error.NoPath;
                }
                if (isIgnorable(e.name) and !e.self_closing) self.depth_ignored += 1;
            },
            .end_element => {
                if (self.depth_ignored > 0) self.depth_ignored -= 1;
            },
            .eof => return null,
            else => {},
        };
    }
};

/// The elements that carry no geometry and so may be passed over.
fn isIgnorable(name: []const u8) bool {
    return xml.nameIs(name, "title") or
        xml.nameIs(name, "desc") or
        xml.nameIs(name, "metadata") or
        xml.nameIs(name, "defs");
}

/// Read one document out of `src` and satisfy yourself it can be drawn.
///
/// Allocates nothing: the returned `Document` borrows `src`, which must
/// outlive it.
pub fn read(src: []const u8) Error!Document {
    var reader: xml.Reader = .init(src);

    var view_box: ?ViewBox = null;
    var shapes: usize = 0;
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
                // Checked here rather than left to the iterator, so that a
                // `<path>` with no `d` is refused before anything is drawn
                // like every other malformed thing.
                _ = e.attr("d") orelse return error.NoPath;
                shapes += 1;
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

    if (shapes == 0) return error.NoPath;
    return .{
        .view_box = view_box orelse return error.NotAnSvg,
        .src = src,
        .shape_count = shapes,
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

/// Build one `d` into `p`, under `transform`.
///
/// z2d applies the transformation when a point is added rather than when the
/// path is filled, so it has to be in place before the first `moveTo`; this
/// puts it there and takes it away again.
pub fn buildShape(
    p: *z2d.Path,
    alloc: std.mem.Allocator,
    d: []const u8,
    transform: z2d.Transformation,
    opts: path.Options,
) path.BuildError!void {
    const saved = p.transformation;
    defer p.transformation = saved;
    p.transformation = saved.mul(transform);
    try path.build(p, alloc, d, opts);
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

const icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3,9H7L12,4V20L7,15H3V9Z" /></svg>
;

/// Every `d` in a document, for a test to look at.
fn collect(gpa: std.mem.Allocator, src: []const u8) ![][]const u8 {
    const doc = try read(src);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = doc.paths();
    while (try it.next()) |d| try out.append(gpa, d);
    return out.toOwnedSlice(gpa);
}

test "a well formed icon reads" {
    const doc = try read(icon);
    try testing.expectEqual(@as(f64, 0), doc.view_box.min_x);
    try testing.expectEqual(@as(f64, 24), doc.view_box.width);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);

    var it = doc.paths();
    try testing.expectEqualStrings("M3,9H7L12,4V20L7,15H3V9Z", (try it.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try it.next());
}

test "every path is handed out, in document order" {
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 24 24">
        \\  <path d="M0 0L1 1Z"/>
        \\  <path d="M2 2L3 3Z"/>
        \\  <path d="M4 4L5 5Z"/>
        \\</svg>
    ;
    const doc = try read(src);
    try testing.expectEqual(@as(usize, 3), doc.shape_count);

    const found = try collect(gpa, src);
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("M0 0L1 1Z", found[0]);
    try testing.expectEqualStrings("M2 2L3 3Z", found[1]);
    try testing.expectEqualStrings("M4 4L5 5Z", found[2]);
}

test "a path inside an ignored element is not a shape" {
    // `<defs>` holds things to be referenced rather than drawn, and nothing
    // here implements `<use>`, so what is in it is not painted.
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 24 24"><defs><path d="M9 9Z"/></defs><path d="M0 0L2 2Z"/></svg>
    ;
    const doc = try read(src);
    try testing.expectEqual(@as(usize, 1), doc.shape_count);

    const found = try collect(gpa, src);
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("M0 0L2 2Z", found[0]);
}

test "the reader and the iterator agree on what a shape is" {
    // They are two walks of the same document, and a disagreement between them
    // paints something that passed every check -- so every document in the
    // corpus is counted both ways.
    const gpa = testing.allocator;
    const documents = [_][]const u8{
        icon,
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><defs><path d=\"M9 9Z\"/></defs><path d=\"M0 0Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><defs><title>x</title><path d=\"M9 9Z\"/></defs><path d=\"M0 0Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><title>x</title><path d=\"M0 0Z\"/><desc>y</desc><path d=\"M1 1Z\"/></svg>",
        "<svg viewBox=\"0 0 24 24\"><metadata/><path d=\"M0 0Z\"/></svg>",
    };
    for (documents) |src| {
        const doc = try read(src);
        const found = try collect(gpa, src);
        defer gpa.free(found);
        try testing.expectEqual(doc.shape_count, found.len);
    }
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

test "a document is refused before any of it is drawn" {
    // The `<g>` is last, after two perfectly good shapes. Reading has to fail
    // rather than hand out those two and fail on the third, which would be a
    // half-drawn picture and an error at once.
    try testing.expectError(error.UnsupportedElement, read(
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path d=\"M1 1Z\"/><g/></svg>",
    ));
    try testing.expectError(error.NoPath, read(
        "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0Z\"/><path/></svg>",
    ));
}

test "elements that carry no geometry are passed over" {
    const doc = try read(
        "<svg viewBox=\"0 0 24 24\"><title>x</title><desc>y</desc><path d=\"M0 0L2 2Z\"/></svg>",
    );
    try testing.expectEqual(@as(usize, 1), doc.shape_count);
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
    const doc = try read(icon);
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    // A 24-unit viewBox into a 48-pixel box doubles everything.
    var it = doc.paths();
    try buildShape(&p, gpa, (try it.next()).?, doc.transformFor(0, 0, 48, 48), .{});
    try testing.expectApproxEqAbs(@as(f64, 6), p.nodes.items[0].move_to.point.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 18), p.nodes.items[0].move_to.point.y, 1e-9);
}

test "a box of a different shape letterboxes rather than distorting" {
    const doc = try read(icon);
    // 48 wide by 24 tall: the scale is 1, and the drawing is centred.
    const t = doc.transformFor(0, 0, 48, 24);
    try testing.expectApproxEqAbs(@as(f64, 1), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), t.dy, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), t.ty, 1e-12);
}

test "a viewBox with an offset is translated away" {
    const doc = try read("<svg viewBox=\"-12 -12 24 24\"><path d=\"M0 0Z\"/></svg>");
    const t = doc.transformFor(0, 0, 24, 24);
    try testing.expectApproxEqAbs(@as(f64, 1), t.ax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.tx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 12), t.ty, 1e-12);
}
