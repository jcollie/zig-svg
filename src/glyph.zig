// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Glyphs from an OpenType `SVG ` table.
//!
//! A font's `SVG ` table holds documents, each describing a range of glyph
//! IDs, and glyph *N* is the element of its document whose `id` is
//! `glyphN`. One document often describes many glyphs and shares gradients
//! and parts between them, so it is parsed once into a `Document` and each
//! glyph is drawn from it by ID.
//!
//! ```zig
//! var doc = try svg.glyph.Document.parse(gpa, bytes, .{ .units_per_em = 1000 });
//! defer doc.deinit();
//!
//! // Font units to pixels: 1 SVG unit is 1 font unit, y down, origin on the
//! // baseline -- so this is the scale and the pen position, and nothing else.
//! const scale = size / 1000.0;
//! const m: z2d.Transformation = .{ .ax = scale, .by = 0, .cx = 0, .dy = scale, .tx = x, .ty = y };
//! const ink = try doc.bounds(gpa, 42, m, .{});
//! try doc.draw(gpa, &surface, 42, m, .{ .color = text_color, .variables = palette.entries() });
//! ```
//!
//! ## What the specification says, and this does
//!
//! The OpenType specification (1.9.1, "SVG — Scalable Vector Graphics
//! table") settles the three things SVG alone does not:
//!
//! * **Which part of the document is the glyph.** SVG has no notion of
//!   drawing part of a document, so the specification says the element is
//!   drawn "according to SVG's `<use>` tag behavior, as though the given
//!   element and its content were specified in a `<defs>` tag and then
//!   referenced as the graphic content of an SVG document." The elements
//!   between the root and the glyph therefore contribute nothing, and the
//!   root contributes what any root does. See `document.Document.glyph`.
//! * **Where it is.** One SVG unit is one font unit, the origin is the
//!   glyph origin, `y = 0` is the baseline, and y points down. The initial
//!   viewport is the em square, and a `viewBox`, `width` or `height` on the
//!   root "will have the effect of a scale transformation": the `viewBox` is
//!   fitted into `width` × `height`, and that box is then scaled to the em
//!   square. A document that names none of the three is in font units as it
//!   stands. The viewport is never a clip.
//! * **What its colors are.** `currentColor` is the text color. A CPAL
//!   palette reaches the document as custom properties `--color0`,
//!   `--color1` and on, through `var()`; `Palette` builds them. Following
//!   SVG 2, `context-fill` and `context-stroke` are the text color too.
//!   A shape that names no `fill` is black, SVG's initial value -- not the
//!   text color, which is the one place this differs from `svg.render`.
//!
//! ## Untrusted input
//!
//! A font is somebody else's file. Nothing here panics on any input, and
//! everything is bounded: the source by `ParseOptions.max_input_bytes`, the
//! tree by `ParseOptions.max_elements`, the nesting of containers by
//! `document.max_container_depth`, `<use>` by `document.max_use_hops` --
//! with a cycle caught as soon as it closes -- and the drawing by
//! `raster.Limits`, which caps shapes, path commands, layers and the rest.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");
const ztree = @import("ztree");

const color = @import("color.zig");
const document = @import("document.zig");
const raster = @import("raster.zig");
const variables = @import("variables.zig");

/// Everything parsing a glyph document or drawing a glyph can fail with.
pub const Error = raster.Error || error{
    /// A source longer than `ParseOptions.max_input_bytes`.
    InputTooLarge,
    /// A document with more nodes than `ParseOptions.max_elements`.
    TooManyElements,
    /// No element in the document has the id `glyphN`.
    NoSuchGlyph,
};

/// How a glyph document is read.
pub const ParseOptions = struct {
    /// The font's `head.unitsPerEm`: the size of the initial viewport, and
    /// what the root's `viewBox`, `width` and `height` are scaled to.
    units_per_em: f64,

    /// The longest source to parse, after any gzip has been inflated.
    max_input_bytes: usize = 1 << 24,

    /// The most nodes -- elements, text and the rest -- the parsed tree may
    /// hold.
    max_elements: usize = 1 << 18,

    /// The most elements one walk of one glyph may visit, counting each
    /// time a `<use>` draws its target again. A glyph is small, and a
    /// glyph that is not is ten `<use>`s of ten `<use>`s of ten, drawing a
    /// million rectangles from a few hundred bytes.
    max_visits: usize = 1 << 16,
};

/// How a glyph is drawn.
pub const DrawOptions = struct {
    /// The text color: what `currentColor`, `context-fill` and
    /// `context-stroke` mean.
    color: color.Color = .black,

    /// Custom properties for the document's `var()`s, usually the CPAL
    /// palette's: see `Palette`. Borrowed for the call.
    variables: []const variables.Entry = &.{},

    anti_aliasing_mode: z2d.options.AntiAliasMode = .default,
    tolerance: f64 = z2d.options.default_tolerance,

    limits: raster.Limits = .{},
};

/// An axis-aligned box.
pub const Box = raster.Box;

/// A parsed glyph document.
///
/// Drawing borrows the document mutably for the length of the call, to lend
/// the walk what it needs, so one document must not be drawn from two
/// threads at once. Parse one per thread, or hold a lock.
pub const Document = struct {
    doc: document.Document,
    units_per_em: f64,

    /// Parse `src`, which may be freed as soon as this returns.
    ///
    /// Inflating a gzipped document is the caller's: zig-font's
    /// `tables.svg.decompress` does it.
    pub fn parse(gpa: Allocator, src: []const u8, opts: ParseOptions) Error!Document {
        if (src.len > opts.max_input_bytes) return error.InputTooLarge;
        if (!(opts.units_per_em > 0) or !std.math.isFinite(opts.units_per_em)) return error.BadSize;
        // Not walked as a whole: a font's document is drawn one glyph at a
        // time, and each glyph is checked as it is drawn. A glyph that
        // cannot be drawn does not stop the others from being drawn.
        var doc = try document.readWith(gpa, src, .{
            .default_size = opts.units_per_em,
            .validate = false,
            .max_visits = opts.max_visits,
        });
        errdefer doc.deinit();
        if (doc.tree.nodes.items.len > opts.max_elements) return error.TooManyElements;
        return .{ .doc = doc, .units_per_em = opts.units_per_em };
    }

    pub fn deinit(self: *Document) void {
        self.doc.deinit();
        self.* = undefined;
    }

    /// The element describing `glyph_id`, or null when this document has
    /// none.
    pub fn node(self: *const Document, glyph_id: u32) ?ztree.NodeId {
        var buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "glyph{d}", .{glyph_id}) catch unreachable;
        return self.doc.ids.get(id);
    }

    /// Whether this document describes `glyph_id`.
    pub fn has(self: *const Document, glyph_id: u32) bool {
        return self.node(glyph_id) != null;
    }

    /// From the root's user space to font units, y down: the root's
    /// `viewBox` fitted into its `width` and `height`, and those scaled to
    /// the em square. The identity for a document that names none of them.
    pub fn rootTransform(self: *const Document) z2d.Transformation {
        const w = self.doc.width;
        const h = self.doc.height;
        const fit = self.doc.transformFor(0, 0, w, h);
        const scale: z2d.Transformation = .{
            .ax = self.units_per_em / w,
            .by = 0,
            .cx = 0,
            .dy = self.units_per_em / h,
            .tx = 0,
            .ty = 0,
        };
        return scale.mul(fit);
    }

    /// Draw `glyph_id` onto `surface` under `ctm`, which takes font units
    /// (y down, origin at the glyph origin) to pixels. The surface is drawn
    /// over, not cleared.
    pub fn draw(
        self: *Document,
        gpa: Allocator,
        surface: *z2d.Surface,
        glyph_id: u32,
        ctm: z2d.Transformation,
        opts: DrawOptions,
    ) Error!void {
        const n = self.node(glyph_id) orelse return error.NoSuchGlyph;
        const ropts = rasterOptions(opts);
        const base = try self.baseFor(ctm);
        _ = try raster.countFrom(gpa, &self.doc, self.walk(n, opts), ropts);
        try raster.drawFrom(gpa, surface, &self.doc, self.walk(n, opts), base, ropts);
    }

    /// The box `glyph_id` covers under `ctm`, or null when it draws nothing
    /// with any extent. With `ctm` the identity it is in font units, y down.
    ///
    /// Each shape's geometry, grown by as far as its stroke can reach, and
    /// each picture's rectangle, before any clip -- so it is never smaller
    /// than the ink, and may be larger. Filters and markers are not counted.
    pub fn bounds(
        self: *Document,
        gpa: Allocator,
        glyph_id: u32,
        ctm: z2d.Transformation,
        opts: DrawOptions,
    ) Error!?Box {
        const n = self.node(glyph_id) orelse return error.NoSuchGlyph;
        const ropts = rasterOptions(opts);
        const base = try self.baseFor(ctm);
        _ = try raster.countFrom(gpa, &self.doc, self.walk(n, opts), ropts);
        const box = (try raster.measureFrom(gpa, &self.doc, self.walk(n, opts), true, ropts)) orelse return null;
        return mapBox(base, box);
    }

    fn baseFor(self: *const Document, ctm: z2d.Transformation) Error!z2d.Transformation {
        const m = ctm.mul(self.rootTransform());
        inline for (.{ "ax", "by", "cx", "dy", "tx", "ty" }) |f| {
            if (!std.math.isFinite(@field(m, f))) return error.NonFiniteTransform;
        }
        return m;
    }

    fn walk(self: *const Document, n: ztree.NodeId, opts: DrawOptions) document.PathIterator {
        const text: color.Paint = .{ .color = opts.color };
        return self.doc.glyph(n, .{
            .fill = .{ .color = .black },
            .current_color = opts.color,
            .context = .{ .fill = text, .stroke = text },
        });
    }
};

fn rasterOptions(opts: DrawOptions) raster.Options {
    return .{
        .fill = premultiplied(opts.color),
        .variables = opts.variables,
        .anti_aliasing_mode = opts.anti_aliasing_mode,
        .tolerance = opts.tolerance,
        .limits = opts.limits,
    };
}

fn premultiplied(c: color.Color) z2d.Pixel {
    const a = std.math.clamp(c.alpha, 0, 1);
    const mul = struct {
        fn f(v: u8, alpha: f64) u8 {
            return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * alpha));
        }
    }.f;
    return .{ .rgba = .{
        .r = mul(c.r, a),
        .g = mul(c.g, a),
        .b = mul(c.b, a),
        .a = @intFromFloat(@round(a * 255)),
    } };
}

/// The box enclosing `box` under `m`.
fn mapBox(m: z2d.Transformation, box: Box) Box {
    const xs = [_]f64{ box.x, box.x + box.width };
    const ys = [_]f64{ box.y, box.y + box.height };
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    for (xs) |x| for (ys) |y| {
        const px = m.ax * x + m.cx * y + m.tx;
        const py = m.by * x + m.dy * y + m.ty;
        min_x = @min(min_x, px);
        min_y = @min(min_y, py);
        max_x = @max(max_x, px);
        max_y = @max(max_y, py);
    };
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

/// A CPAL palette as the custom properties `--color0`, `--color1` and on,
/// which is how an OpenType SVG document names palette entries.
///
/// Each value is written as `#rrggbbaa`, so a palette entry's alpha arrives
/// as the color's own and is multiplied into the `fill-opacity`,
/// `stroke-opacity` or `stop-opacity` it is painted with -- which is what
/// the specification asks for, and leaves the opacity property itself to be
/// inherited unchanged.
pub const Palette = struct {
    list: []variables.Entry,
    text: []u8,

    /// Each name is `--color` and a decimal index, and each value nine
    /// bytes; two allocations for the lot.
    pub fn init(gpa: Allocator, colors: []const color.Color) Allocator.Error!Palette {
        const list = try gpa.alloc(variables.Entry, colors.len);
        errdefer gpa.free(list);
        // "--color" and at most five digits for a u16 index, then nine for
        // the value.
        const per = 7 + 5 + 9;
        const text = try gpa.alloc(u8, per * colors.len);
        errdefer gpa.free(text);
        var at: usize = 0;
        for (colors, list, 0..) |c, *entry, i| {
            const name = std.fmt.bufPrint(text[at..], "--color{d}", .{i}) catch unreachable;
            at += name.len;
            const a: u8 = @intFromFloat(@round(std.math.clamp(c.alpha, 0, 1) * 255));
            const value = std.fmt.bufPrint(text[at..], "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, a }) catch unreachable;
            at += value.len;
            entry.* = .{ .name = name, .value = value };
        }
        return .{ .list = list, .text = text };
    }

    pub fn deinit(self: *Palette, gpa: Allocator) void {
        gpa.free(self.list);
        gpa.free(self.text);
        self.* = undefined;
    }

    pub fn entries(self: Palette) []const variables.Entry {
        return self.list;
    }
};

// -- tests --------------------------------------------------------------------

fn pixelAt(surface: *z2d.Surface, x: i32, y: i32) z2d.pixel.RGBA {
    return z2d.pixel.RGBA.fromPixel(surface.getPixel(x, y).?);
}

fn scaled(s: f64, tx: f64, ty: f64) z2d.Transformation {
    return .{ .ax = s, .by = 0, .cx = 0, .dy = s, .tx = tx, .ty = ty };
}

test "a glyph is its element, drawn above the baseline in font units" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg">
        \\  <rect id="glyph1" x="100" y="-600" width="200" height="600" fill="#ff0000"/>
        \\  <rect id="glyph2" x="0" y="-1000" width="1000" height="1000" fill="#0000ff"/>
        \\</svg>
    , .{ .units_per_em = 1000 });
    defer doc.deinit();

    try testing.expect(doc.has(1));
    try testing.expect(!doc.has(3));

    const box = (try doc.bounds(gpa, 1, .identity, .{})).?;
    try testing.expectApproxEqAbs(@as(f64, 100), box.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -600), box.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 200), box.width, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 600), box.height, 1e-9);

    // 10 pixels to the em, baseline at y = 10: the glyph occupies x 1..3,
    // y 4..10, and glyph 2 is not drawn with it.
    var surface = try z2d.Surface.init(.image_surface_rgba, gpa, 12, 12);
    defer surface.deinit(gpa);
    try doc.draw(gpa, &surface, 1, scaled(0.01, 0, 10), .{});
    try testing.expectEqual(@as(u8, 255), pixelAt(&surface, 2, 6).r);
    try testing.expectEqual(@as(u8, 0), pixelAt(&surface, 5, 6).a);
    try testing.expectEqual(@as(u8, 0), pixelAt(&surface, 2, 2).a);

    try testing.expectError(error.NoSuchGlyph, doc.draw(gpa, &surface, 7, .identity, .{}));
}

test "the elements between the root and the glyph contribute nothing" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg" fill="#00ff00">
        \\  <g transform="translate(5000 0)" fill="#ff0000">
        \\    <rect id="glyph4" width="10" height="10"/>
        \\  </g>
        \\</svg>
    , .{ .units_per_em = 100 });
    defer doc.deinit();
    const box = (try doc.bounds(gpa, 4, .identity, .{})).?;
    try testing.expectApproxEqAbs(@as(f64, 0), box.x, 1e-9);

    var surface = try z2d.Surface.init(.image_surface_rgba, gpa, 4, 4);
    defer surface.deinit(gpa);
    try doc.draw(gpa, &surface, 4, .identity, .{});
    // The root's fill, not the group's.
    try testing.expectEqual(@as(u8, 255), pixelAt(&surface, 1, 1).g);
    try testing.expectEqual(@as(u8, 0), pixelAt(&surface, 1, 1).r);
}

test "the root may itself be the glyph" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg id="glyph7" xmlns="http://www.w3.org/2000/svg"><rect y="-5" width="5" height="5"/></svg>
    , .{ .units_per_em = 10 });
    defer doc.deinit();
    const box = (try doc.bounds(gpa, 7, .identity, .{})).?;
    try testing.expectApproxEqAbs(@as(f64, -5), box.y, 1e-9);
}

test "a viewBox shifts and scales the root into the em square" {
    const gpa = testing.allocator;
    // The specification's Example 3: drawn as though the baseline were at
    // y = 1000, and shifted back up by the viewBox.
    var doc = try Document.parse(gpa,
        \\<svg id="glyph7" xmlns="http://www.w3.org/2000/svg" viewBox="0 1000 1000 1000">
        \\  <rect x="100" y="570" width="200" height="430"/>
        \\</svg>
    , .{ .units_per_em = 1000 });
    defer doc.deinit();
    const box = (try doc.bounds(gpa, 7, .identity, .{})).?;
    try testing.expectApproxEqAbs(@as(f64, -430), box.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 430), box.height, 1e-9);

    // The same viewBox at half the em scales by two.
    var half = try Document.parse(gpa,
        \\<svg id="glyph7" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500">
        \\  <rect width="100" height="100"/>
        \\</svg>
    , .{ .units_per_em = 1000 });
    defer half.deinit();
    const big = (try half.bounds(gpa, 7, .identity, .{})).?;
    try testing.expectApproxEqAbs(@as(f64, 200), big.width, 1e-9);

    // And `width` alone scales as well.
    var wide = try Document.parse(gpa,
        \\<svg id="glyph7" xmlns="http://www.w3.org/2000/svg" width="2000" height="2000">
        \\  <rect width="100" height="100"/>
        \\</svg>
    , .{ .units_per_em = 1000 });
    defer wide.deinit();
    const small = (try wide.bounds(gpa, 7, .identity, .{})).?;
    try testing.expectApproxEqAbs(@as(f64, 50), small.width, 1e-9);
}

test "bounds grow by the stroke, under the shape's own transform" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg">
        \\  <g id="glyph1"><path d="M0 0 H10" stroke="black" stroke-width="2" stroke-linecap="round" transform="scale(3)"/></g>
        \\</svg>
    , .{ .units_per_em = 100 });
    defer doc.deinit();
    const box = (try doc.bounds(gpa, 1, .identity, .{})).?;
    // The pen is 6 units wide once scaled, so it reaches at least 3 past
    // each end.
    try testing.expect(box.x <= -3);
    try testing.expect(box.x + box.width >= 33);
    try testing.expect(box.y <= -3);
}

test "currentColor, context paints and a shape with no fill" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg">
        \\  <g id="glyph1">
        \\    <rect width="1" height="1" fill="currentColor"/>
        \\    <rect x="1" width="1" height="1" fill="context-fill"/>
        \\    <rect x="2" width="1" height="1" fill="context-stroke"/>
        \\    <rect x="3" width="1" height="1"/>
        \\  </g>
        \\</svg>
    , .{ .units_per_em = 4 });
    defer doc.deinit();
    var surface = try z2d.Surface.init(.image_surface_rgba, gpa, 4, 1);
    defer surface.deinit(gpa);
    try doc.draw(gpa, &surface, 1, .identity, .{ .color = .{ .r = 0, .g = 0, .b = 255 } });
    for (0..3) |x| {
        const p = pixelAt(&surface, @intCast(x), 0);
        try testing.expectEqual(@as(u8, 255), p.b);
        try testing.expectEqual(@as(u8, 255), p.a);
    }
    const unfilled = pixelAt(&surface, 3, 0);
    try testing.expectEqual(@as(u8, 0), unfilled.b);
    try testing.expectEqual(@as(u8, 255), unfilled.a);
}

test "palette entries reach fills and gradient stops, with their alpha" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg">
        \\  <defs>
        \\    <linearGradient id="g"><stop offset="0" stop-color="var(--color1, red)"/><stop offset="1" stop-color="var(--color1, red)"/></linearGradient>
        \\  </defs>
        \\  <g id="glyph1">
        \\    <rect width="1" height="1" fill="var(--color0, yellow)"/>
        \\    <rect x="1" width="1" height="1" fill="url(#g)"/>
        \\    <rect x="2" width="1" height="1" fill="var(--color9, #00ff00)"/>
        \\  </g>
        \\</svg>
    , .{ .units_per_em = 3 });
    defer doc.deinit();

    var palette = try Palette.init(gpa, &.{
        .{ .r = 0, .g = 0, .b = 255, .alpha = 128.0 / 255.0 },
        .{ .r = 255, .g = 0, .b = 255 },
    });
    defer palette.deinit(gpa);
    try testing.expectEqualStrings("--color0", palette.entries()[0].name);
    try testing.expectEqualStrings("#0000ff80", palette.entries()[0].value);

    var surface = try z2d.Surface.init(.image_surface_rgba, gpa, 3, 1);
    defer surface.deinit(gpa);
    try doc.draw(gpa, &surface, 1, .identity, .{ .variables = palette.entries() });
    const half = pixelAt(&surface, 0, 0);
    try testing.expectEqual(@as(u8, 128), half.a);
    try testing.expectEqual(@as(u8, 128), half.b);
    const stop = pixelAt(&surface, 1, 0);
    try testing.expectEqual(@as(u8, 255), stop.r);
    try testing.expectEqual(@as(u8, 255), stop.b);
    // A palette without that entry takes the fallback.
    try testing.expectEqual(@as(u8, 255), pixelAt(&surface, 2, 0).g);

    // And with no palette at all, every one takes its fallback.
    var plain = try z2d.Surface.init(.image_surface_rgba, gpa, 3, 1);
    defer plain.deinit(gpa);
    try doc.draw(gpa, &plain, 1, .identity, .{});
    const yellow = pixelAt(&plain, 0, 0);
    try testing.expectEqual(@as(u8, 255), yellow.r);
    try testing.expectEqual(@as(u8, 255), yellow.g);
    try testing.expectEqual(@as(u8, 255), pixelAt(&plain, 1, 0).r);
}

test "shared parts through use, and a use cycle refused" {
    const gpa = testing.allocator;
    var doc = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
        \\  <defs><rect id="base" width="4" height="4"/></defs>
        \\  <g id="glyph2"><use xlink:href="#base" x="2"/></g>
        \\  <g id="glyph3"><use href="#base" y="-4"/></g>
        \\</svg>
    , .{ .units_per_em = 10 });
    defer doc.deinit();
    try testing.expectApproxEqAbs(@as(f64, 2), (try doc.bounds(gpa, 2, .identity, .{})).?.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -4), (try doc.bounds(gpa, 3, .identity, .{})).?.y, 1e-9);

    var cyclic = try Document.parse(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg"><g id="glyph1"><use href="#glyph1"/></g><rect id="glyph2" width="1" height="1"/></svg>
    , .{ .units_per_em = 10 });
    defer cyclic.deinit();
    try testing.expectError(error.RecursiveUse, cyclic.bounds(gpa, 1, .identity, .{}));
    // The glyph beside it is unaffected.
    _ = (try cyclic.bounds(gpa, 2, .identity, .{})).?;
}

test "a wide expansion of use is refused, not walked" {
    const gpa = testing.allocator;
    // Ten to the sixteenth groups, every one of them empty: nothing is ever
    // drawn, so only the visit budget can stop it.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\"><defs><g id=\"a0\"/>");
    for (1..17) |level| {
        try src.print(gpa, "<g id=\"a{d}\">", .{level});
        for (0..10) |_| try src.print(gpa, "<use href=\"#a{d}\"/>", .{level - 1});
        try src.appendSlice(gpa, "</g>");
    }
    try src.appendSlice(gpa, "</defs><use id=\"glyph1\" href=\"#a16\"/></svg>");
    var doc = try Document.parse(gpa, src.items, .{ .units_per_em = 10 });
    defer doc.deinit();
    try testing.expectError(error.TooManyVisits, doc.bounds(gpa, 1, .identity, .{}));
    var surface = try z2d.Surface.init(.image_surface_rgba, gpa, 1, 1);
    defer surface.deinit(gpa);
    try testing.expectError(error.TooManyVisits, doc.draw(gpa, &surface, 1, .identity, .{}));
}

test "limits on the source and the tree" {
    const gpa = testing.allocator;
    const src = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"glyph1\" width=\"1\" height=\"1\"/></svg>";
    try testing.expectError(error.InputTooLarge, Document.parse(gpa, src, .{ .units_per_em = 10, .max_input_bytes = 10 }));
    try testing.expectError(error.TooManyElements, Document.parse(gpa, src, .{ .units_per_em = 10, .max_elements = 1 }));
    try testing.expectError(error.BadSize, Document.parse(gpa, src, .{ .units_per_em = 0 }));
}
