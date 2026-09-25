// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The pictures an `<image>` names: SVG 1.1 §5.7.
//!
//! An `<image>` names a bitmap by URL, and in a document meant to stand on its
//! own that URL is almost always a `data:` one -- RFC 2397, the bytes of a PNG
//! or a JPEG written into the attribute in base64. This file turns that
//! attribute into a surface: it reads the URL with zig-uri, hands anything
//! that is not a `data:` URL to the caller's `Resolver`, decodes the bytes
//! with z2dimg, and keeps what it decoded for the rest of the render.
//!
//! ## Decoded in-process, on purpose
//!
//! z2dimg can decode in a sandbox of its own, and this does not ask it to. A
//! render that wants isolation already has it: `sandbox.render` forks and
//! installs its filter before the document is parsed, so the decoder runs
//! inside that child with everything else. A second fork from there would be a
//! sandbox inside a sandbox, and one the first sandbox's filter refuses anyway.
//! The decoders make no system calls -- they are handed a slice and an
//! allocator -- so the strict filter is enough for them.
//!
//! ## What the bytes are is read from the bytes
//!
//! The media type a `data:` URL claims is not consulted to choose a decoder.
//! z2dimg reads the signature, which is what a browser does too, and a PNG
//! labelled `image/jpeg` is drawn as the PNG it is. The one claim that is
//! believed is `image/svg+xml`, because a document inside a document is a
//! render of its own rather than a decode, and it is refused as such.
//!
//! ## What is ignored
//!
//! No colour management: an ICC profile or a PNG `gAMA` is not applied, and
//! the pixels are taken as sRGB, which is what resvg does. EXIF orientation is
//! not applied either. An animated GIF, APNG or WebP is drawn as its first
//! frame, which is what SVG 1.1 says a static renderer does.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const uri = @import("uri");
const z2d = @import("z2d");
const z2dimg = @import("z2dimg");
const ztree = @import("ztree");

pub const Error = error{
    /// An `href` that starts `data:` and is not a data URL: no comma, a
    /// parameter with no value, or `;base64` over something that is not.
    BadDataUrl,
    /// An `href` that is not a `data:` URL, with either no `Options.images`
    /// to ask or a resolver that had no answer. Refused rather than drawn
    /// without the picture, which would be a picture quietly missing a piece.
    UnresolvedImage,
    /// Bytes that claim to be an image of a kind z2dimg reads, and are broken:
    /// a length that does not fit, a stream that ends early.
    BadImageData,
    /// Bytes that are no image z2dimg reads -- a format it does not know, a
    /// variant of one it does that it refuses, or an SVG, which would be a
    /// document inside a document.
    UnsupportedImageFormat,
    /// An image larger than what is left of `Limits.max_image_pixels`, or
    /// wider or taller than the picture itself may be.
    EmbeddedImageTooLarge,
    /// More distinct `<image>` elements than `Limits.max_images`.
    TooManyImages,
} || Allocator.Error;

/// How the caller supplies a picture an `<image>` names by anything other
/// than a `data:` URL.
///
/// A callback, like `FontResolver`, so that the caller decides what a
/// relative URL is relative to and what may be fetched at all. The bytes are
/// borrowed: the resolver keeps ownership and they must outlive the render.
///
/// **It runs inside the sandboxed child.** `sandbox.render` has installed its
/// filter before the document is parsed, so a resolver that opens a file or
/// reaches the network dies of it, and the render comes back as
/// `error.SandboxViolation`. A resolver must answer out of memory it already
/// holds; fetching is the caller's job, and doing it before the render is the
/// caller's job too.
pub const Resolver = struct {
    /// Passed back to `resolve` untouched.
    ctx: ?*anyopaque = null,

    /// Answers with the encoded bytes of the picture `href` names, or null
    /// when it has none. `href` is the attribute as written, trimmed of
    /// surrounding whitespace.
    resolve: *const fn (ctx: ?*anyopaque, href: []const u8) ?[]const u8,
};

/// What `Cache` is allowed to spend. Taken from `raster.Limits`, which is
/// where a caller sets it.
pub const Budget = struct {
    /// The most pixels to decode and reduce, over every picture together.
    pixels: u64,
    /// The most distinct pictures to decode.
    images: usize,
    /// The widest and tallest one picture may be.
    max_width: u32,
    max_height: u32,
};

/// A decoded picture, and the reductions of it that have been asked for.
///
/// `levels[0]` is the picture as decoded; `levels[k]` is it halved `k` times,
/// each dimension rounded up. All are premultiplied RGBA.
pub const Bitmap = struct {
    levels: std.ArrayList(z2d.Surface) = .empty,

    pub fn width(self: *const Bitmap) u32 {
        return @intCast(self.levels.items[0].getWidth());
    }

    pub fn height(self: *const Bitmap) u32 {
        return @intCast(self.levels.items[0].getHeight());
    }

    fn deinit(self: *Bitmap, gpa: Allocator) void {
        for (self.levels.items) |*level| level.deinit(gpa);
        self.levels.deinit(gpa);
    }
};

/// Every picture a render has decoded, by the `<image>` element that named it.
///
/// Keyed by element rather than by URL, because the element is what is
/// reached twice: a `<use>` of an `<image>`, or an `<image>` inside a
/// `<pattern>` that is drawn once per tile. Two elements with the same URL
/// are two decodes, which costs time and not correctness, and is not worth
/// hashing a megabyte of base64 to avoid.
pub const Cache = struct {
    entries: std.AutoHashMapUnmanaged(ztree.NodeId, Bitmap) = .empty,
    budget: Budget,

    pub fn init(budget: Budget) Cache {
        return .{ .budget = budget };
    }

    pub fn deinit(self: *Cache, gpa: Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |b| b.deinit(gpa);
        self.entries.deinit(gpa);
    }

    /// The picture `node` names, decoded the first time it is asked for.
    pub fn get(
        self: *Cache,
        gpa: Allocator,
        node: ztree.NodeId,
        href: []const u8,
        resolver: ?Resolver,
    ) Error!*Bitmap {
        if (self.entries.getPtr(node)) |b| return b;
        if (self.budget.images == 0) return error.TooManyImages;

        var fetched = try fetch(gpa, href, resolver);
        defer fetched.deinit();
        var surface = try decode(gpa, fetched.bytes, self.budget);
        errdefer surface.deinit(gpa);

        var bitmap: Bitmap = .{};
        errdefer bitmap.levels.deinit(gpa);
        try bitmap.levels.append(gpa, surface);
        try self.entries.putNoClobber(gpa, node, bitmap);

        self.budget.images -= 1;
        self.budget.pixels -= pixelCount(&surface);
        return self.entries.getPtr(node).?;
    }

    /// `bitmap` halved `k` times, made the first time it is asked for.
    ///
    /// Each level is made from the one before, so asking for the fourth makes
    /// the first three too. Every one is paid for out of the pixel budget --
    /// together they are at most a third again of the picture, but a third
    /// again of a large picture is still a lot.
    pub fn level(self: *Cache, gpa: Allocator, bitmap: *Bitmap, k: usize) Error!*const z2d.Surface {
        while (bitmap.levels.items.len <= k) {
            const from = &bitmap.levels.items[bitmap.levels.items.len - 1];
            const w = halfUp(from.getWidth());
            const h = halfUp(from.getHeight());
            const cost: u64 = @as(u64, @intCast(w)) * @as(u64, @intCast(h));
            if (cost > self.budget.pixels) return error.EmbeddedImageTooLarge;
            // At least one pixel each way, since `from` is, so the size
            // cannot be refused -- only the allocation can fail.
            var half = z2d.Surface.init(.image_surface_rgba, gpa, w, h) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidWidth, error.InvalidHeight => unreachable,
            };
            errdefer half.deinit(gpa);
            halve(&half, from);
            try bitmap.levels.append(gpa, half);
            self.budget.pixels -= cost;
        }
        return &bitmap.levels.items[k];
    }
};

fn halfUp(n: i32) i32 {
    return @divFloor(n + 1, 2);
}

fn pixelCount(sfc: *const z2d.Surface) u64 {
    return @as(u64, @intCast(sfc.getWidth())) * @as(u64, @intCast(sfc.getHeight()));
}

/// Encoded bytes, and whatever has to be released once they are decoded.
const Fetched = struct {
    bytes: []const u8,
    url: ?uri.data.Url = null,

    fn deinit(self: *Fetched) void {
        if (self.url) |u| u.deinit();
    }
};

/// The encoded bytes an `href` names.
fn fetch(gpa: Allocator, raw: []const u8, resolver: ?Resolver) Error!Fetched {
    const href = std.mem.trim(u8, raw, " \t\r\n");
    if (isDataUrl(href)) {
        const url = uri.data.Url.parse(gpa, href) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadDataUrl,
        };
        errdefer url.deinit();
        // Believed, unlike every other media type: a nested document is not
        // something a decoder is going to recognise, and saying so by name is
        // better than reporting it as an unknown format.
        if (url.media_type) |mt| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, mt, " \t"), "image/svg+xml")) {
                return error.UnsupportedImageFormat;
            }
        }
        return .{ .bytes = url.data, .url = url };
    }
    const r = resolver orelse return error.UnresolvedImage;
    return .{ .bytes = r.resolve(r.ctx, href) orelse return error.UnresolvedImage };
}

/// Whether `href` is a `data:` URL, by its scheme, which RFC 3986 makes
/// case-insensitive.
pub fn isDataUrl(href: []const u8) bool {
    return href.len >= 5 and std.ascii.eqlIgnoreCase(href[0..5], "data:");
}

/// Decode `bytes` into premultiplied RGBA, inside what is left of `budget`.
fn decode(gpa: Allocator, bytes: []const u8, budget: Budget) Error!z2d.Surface {
    var reader: std.Io.Reader = .fixed(bytes);
    return z2dimg.decode(gpa, &reader, .{
        .surface_type = .image_surface_rgba,
        .limits = limitsFor(budget, bytes.len),
    }) catch |err| translate(err);
}

/// A picture's own width and height, read from its header alone.
///
/// For measuring an `<image>` whose size is `auto` without decoding it --
/// which is what a bounding box in the middle of drawing something else wants.
/// The `data:` URL is still read in full, since base64 cannot be read in part.
pub fn intrinsicSize(gpa: Allocator, href: []const u8, resolver: ?Resolver, budget: Budget) Error!struct { u32, u32 } {
    var fetched = try fetch(gpa, href, resolver);
    defer fetched.deinit();
    var reader: std.Io.Reader = .fixed(fetched.bytes);
    const info = z2dimg.probe(&reader, limitsFor(budget, fetched.bytes.len)) catch |err| return translate(err);
    return .{ info.width, info.height };
}

fn limitsFor(budget: Budget, input: usize) z2dimg.Limits {
    return .{
        .max_width = budget.max_width,
        .max_height = budget.max_height,
        .max_pixels = budget.pixels,
        // The bytes are already in memory -- they were in the document.
        .max_input_bytes = input,
        .max_frames = 1,
        .max_total_pixels = budget.pixels,
    };
}

/// z2dimg's errors as this library's own.
///
/// Not tidiness: Zig's error names are global, and z2dimg's `ImageTooLarge`
/// is the very same value as the one `raster` uses for an output surface
/// larger than `Limits` allows. Letting it through would report an oversized
/// embedded picture as an oversized render.
fn translate(err: z2dimg.DecodeError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ImageTooLarge => error.EmbeddedImageTooLarge,
        error.UnknownFormat, error.Unsupported => error.UnsupportedImageFormat,
        // A fixed reader fails only by running out, which for an image is a
        // file cut short.
        error.InvalidData, error.EndOfStream, error.ReadFailed => error.BadImageData,
    };
}

/// Halve `from` into `to`, averaging each two-by-two block.
///
/// Premultiplied, so a transparent pixel adds nothing to its neighbours'
/// colour. An odd last row or column averages with itself, which is the edge
/// repeated rather than transparency brought in from outside.
fn halve(to: *z2d.Surface, from: *const z2d.Surface) void {
    const fw = from.getWidth();
    const fh = from.getHeight();
    const tw = to.getWidth();
    const th = to.getHeight();
    const src = from.image_surface_rgba.buf;
    const dst = to.image_surface_rgba.buf;
    var y: i32 = 0;
    while (y < th) : (y += 1) {
        const y0 = 2 * y;
        const y1 = @min(y0 + 1, fh - 1);
        var x: i32 = 0;
        while (x < tw) : (x += 1) {
            const x0 = 2 * x;
            const x1 = @min(x0 + 1, fw - 1);
            const q = [4]z2d.pixel.RGBA{
                src[@intCast(y0 * fw + x0)],
                src[@intCast(y0 * fw + x1)],
                src[@intCast(y1 * fw + x0)],
                src[@intCast(y1 * fw + x1)],
            };
            dst[@intCast(y * tw + x)] = .{
                .r = average(q[0].r, q[1].r, q[2].r, q[3].r),
                .g = average(q[0].g, q[1].g, q[2].g, q[3].g),
                .b = average(q[0].b, q[1].b, q[2].b, q[3].b),
                .a = average(q[0].a, q[1].a, q[2].a, q[3].a),
            };
        }
    }
}

fn average(a: u8, b: u8, c: u8, d: u8) u8 {
    const sum: u32 = @as(u32, a) + b + c + d;
    return @intCast((sum + 2) / 4);
}

// -- tests -------------------------------------------------------------------

/// A one-pixel opaque red PNG, the smallest thing that exercises the whole
/// path from attribute to surface.
const red_png_base64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";

/// Small pictures for the tests here, in `raster` and in `sandbox`, each
/// written by Pillow and so from an encoder that is not z2dimg's.
pub const fixtures = struct {
    /// Two pixels square: red, green / blue, transparent.
    pub const quad_png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42gXBAQEAAACAEP9PFyIJBQM/0gX7Pk0ZHwAAAABJRU5ErkJggg==";
    /// Sixteen pixels square, black and white alternating one pixel at a time.
    pub const checker_png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAHElEQVR42mNgYGD4//8/CSRpqiFg1IZRG4aGDQDZV36QxkmgQQAAAABJRU5ErkJggg==";
    /// Eight pixels square of rgb(128, 64, 32), at quality 95.
    pub const jpeg = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD47ooor8TP6MP/2Q==";
    /// Two pixels square of rgb(0, 128, 255), lossless.
    pub const webp = "data:image/webp;base64,UklGRhwAAABXRUJQVlA4TBAAAAAvAUAAAAdQwOh//wMR0f8A";
    /// Two pixels square of yellow, from a palette.
    pub const gif = "data:image/gif;base64,R0lGODdhAgACAIEAAP//AAAAAAAAAAAAACwAAAAAAgACAAAIBgABCAQQEAA7";
};

const test_budget: Budget = .{
    .pixels = 1 << 20,
    .images = 16,
    .max_width = 1 << 12,
    .max_height = 1 << 12,
};

test "a data URL is decoded to premultiplied RGBA" {
    var cache: Cache = .init(test_budget);
    defer cache.deinit(testing.allocator);
    const b = try cache.get(testing.allocator, 1, "data:image/png;base64," ++ red_png_base64, null);
    try testing.expectEqual(@as(u32, 1), b.width());
    try testing.expectEqual(@as(u32, 1), b.height());
    const px = b.levels.items[0].image_surface_rgba.buf[0];
    try testing.expectEqual(z2d.pixel.RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 }, px);
    // Asked for again, it is the same decode.
    try testing.expectEqual(b, try cache.get(testing.allocator, 1, "ignored", null));
    try testing.expectEqual(@as(usize, 15), cache.budget.images);
}

test "base64 broken across lines is still base64" {
    var cache: Cache = .init(test_budget);
    defer cache.deinit(testing.allocator);
    const wrapped = "  data:image/png;base64," ++ red_png_base64[0..40] ++ "\n    " ++ red_png_base64[40..] ++ "\n";
    _ = try cache.get(testing.allocator, 1, wrapped, null);
}

test "the media type is not what chooses the decoder" {
    var cache: Cache = .init(test_budget);
    defer cache.deinit(testing.allocator);
    _ = try cache.get(testing.allocator, 1, "data:image/jpeg;base64," ++ red_png_base64, null);
}

test "every way an href can fail says which" {
    const gpa = testing.allocator;
    var cache: Cache = .init(test_budget);
    defer cache.deinit(gpa);
    try testing.expectError(error.BadDataUrl, cache.get(gpa, 1, "data:image/png;base64", null));
    try testing.expectError(error.BadDataUrl, cache.get(gpa, 1, "data:image/png;base64,!!!!", null));
    try testing.expectError(error.UnresolvedImage, cache.get(gpa, 1, "picture.png", null));
    try testing.expectError(error.UnsupportedImageFormat, cache.get(gpa, 1, "data:text/plain,hello", null));
    try testing.expectError(error.UnsupportedImageFormat, cache.get(gpa, 1, "data:image/svg+xml,<svg/>", null));
    try testing.expectError(
        error.BadImageData,
        cache.get(gpa, 1, "data:image/png;base64," ++ red_png_base64[0..60], null),
    );
    // None of those spent anything.
    try testing.expectEqual(test_budget, cache.budget);
}

test "a resolver answers for anything that is not a data URL" {
    const Ctx = struct {
        fn resolve(ctx: ?*anyopaque, href: []const u8) ?[]const u8 {
            const bytes: *const []const u8 = @ptrCast(@alignCast(ctx.?));
            return if (std.mem.eql(u8, href, "red.png")) bytes.* else null;
        }
    };
    var png: [128]u8 = undefined;
    const n = try std.base64.standard.Decoder.calcSizeForSlice(red_png_base64);
    try std.base64.standard.Decoder.decode(png[0..n], red_png_base64);
    var bytes: []const u8 = png[0..n];
    const resolver: Resolver = .{ .ctx = @ptrCast(&bytes), .resolve = Ctx.resolve };

    var cache: Cache = .init(test_budget);
    defer cache.deinit(testing.allocator);
    _ = try cache.get(testing.allocator, 1, " red.png ", resolver);
    try testing.expectError(error.UnresolvedImage, cache.get(testing.allocator, 2, "blue.png", resolver));
}

test "the budget is spent across pictures, and a picture past it is refused" {
    var cache: Cache = .init(.{ .pixels = 1, .images = 16, .max_width = 8, .max_height = 8 });
    defer cache.deinit(testing.allocator);
    _ = try cache.get(testing.allocator, 1, "data:;base64," ++ red_png_base64, null);
    try testing.expectError(
        error.EmbeddedImageTooLarge,
        cache.get(testing.allocator, 2, "data:;base64," ++ red_png_base64, null),
    );

    var few: Cache = .init(.{ .pixels = 1 << 10, .images = 1, .max_width = 8, .max_height = 8 });
    defer few.deinit(testing.allocator);
    _ = try few.get(testing.allocator, 1, "data:;base64," ++ red_png_base64, null);
    try testing.expectError(
        error.TooManyImages,
        few.get(testing.allocator, 2, "data:;base64," ++ red_png_base64, null),
    );
}

test "halving averages blocks and repeats an odd edge" {
    const gpa = testing.allocator;
    var from = try z2d.Surface.init(.image_surface_rgba, gpa, 3, 1);
    defer from.deinit(gpa);
    const buf = from.image_surface_rgba.buf;
    buf[0] = .{ .r = 200, .g = 0, .b = 0, .a = 200 };
    buf[1] = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    buf[2] = .{ .r = 0, .g = 0, .b = 100, .a = 100 };

    var to = try z2d.Surface.init(.image_surface_rgba, gpa, 2, 1);
    defer to.deinit(gpa);
    halve(&to, &from);
    try testing.expectEqual(z2d.pixel.RGBA{ .r = 100, .g = 0, .b = 0, .a = 100 }, to.image_surface_rgba.buf[0]);
    try testing.expectEqual(z2d.pixel.RGBA{ .r = 0, .g = 0, .b = 100, .a = 100 }, to.image_surface_rgba.buf[1]);
}

test "reductions are made on demand and paid for" {
    const gpa = testing.allocator;
    var cache: Cache = .init(test_budget);
    defer cache.deinit(gpa);
    const b = try cache.get(gpa, 1, "data:;base64," ++ red_png_base64, null);
    const before = cache.budget.pixels;
    const l2 = try cache.level(gpa, b, 2);
    try testing.expectEqual(@as(i32, 1), l2.getWidth());
    try testing.expectEqual(@as(usize, 3), b.levels.items.len);
    try testing.expectEqual(before - 2, cache.budget.pixels);
}
