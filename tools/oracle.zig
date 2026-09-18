// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Renders every document in a directory to a PNG, for `check_oracle.py` to
//! hold against resvg.
//!
//! This is the one claim about this renderer that a Zig test cannot make on
//! its own. A test here can check this parser against this rasterizer, and
//! does; what it cannot do is notice that both of them read the specification
//! the same wrong way. resvg is an independent implementation of the same
//! specification, so it disagrees exactly where the specification was misread,
//! which is the class of bug no self-consistent test can see.
//!
//! ```console
//! $ zig build oracle
//! $ python3 tools/check_oracle.py tests/oracle zig-out/oracle
//! ```
//!
//! ## The manifest
//!
//! Beside the PNGs this writes `manifest.txt`, one `name<TAB>width<TAB>height`
//! per document, and `check_oracle.py` passes those numbers straight to resvg.
//!
//! That indirection is not ceremony. resvg's `--width` and `--height` are a
//! box to *fit* rather than a size to produce: given a square box and a
//! document twice as wide as it is tall, it writes a picture half the height
//! asked for. This renderer letterboxes into exactly the box it is handed, so
//! the two only draw the same picture when the box already has the document's
//! own proportions. Deciding that here and writing it down is what makes both
//! sides agree without either one parsing the other's idea of a viewBox.

const std = @import("std");
const z2d = @import("z2d");
const svg = @import("svg");

/// The longer side of every rendered fixture, in pixels.
///
/// Large enough that a difference in how a curve is flattened shows up as more
/// than one pixel, and small enough that the whole corpus renders in a moment.
const long_edge: u32 = 256;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    defer args.deinit();
    _ = args.skip();

    const in_dir_path = args.next() orelse return usage();
    const out_dir_path = args.next() orelse return usage();

    var in_dir = try std.Io.Dir.cwd().openDir(io, in_dir_path, .{ .iterate = true });
    defer in_dir.close(io);

    try std.Io.Dir.cwd().createDirPath(io, out_dir_path);
    var out_dir = try std.Io.Dir.cwd().openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    var manifest_file = try out_dir.createFile(io, "manifest.txt", .{});
    defer manifest_file.close(io);
    var manifest_buf: [4096]u8 = undefined;
    var manifest_writer = manifest_file.writer(io, &manifest_buf);
    const manifest = &manifest_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const log = &stderr.interface;

    var rendered: usize = 0;
    var refused: usize = 0;
    var it = in_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
        const stem = entry.name[0 .. entry.name.len - ".svg".len];

        const src = try in_dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 22));
        defer gpa.free(src);

        // The size comes from the *document*: its own `width` and `height`
        // when it names them, and its viewBox's extent when it does not. That
        // is what resvg draws at when it is given no size of its own, so both
        // renderers are working to the same box -- and it is what makes
        // `preserveAspectRatio` testable at all, since a fixture can now ask
        // for a box its viewBox does not fit.
        //
        // Scaled up so the longer side is `long_edge`, because a 16-unit
        // document compared at 16 pixels is comparing antialiasing.
        const doc = svg.read(src) catch |err| {
            try log.print("{s}: {t}\n", .{ entry.name, err });
            refused += 1;
            continue;
        };
        const scale = @as(f64, @floatFromInt(long_edge)) / @max(doc.width, doc.height);
        const width = atLeastOne(doc.width * scale);
        const height = atLeastOne(doc.height * scale);

        var surface = svg.render(gpa, src, .{
            .width = width,
            .height = height,
            // Black on transparent, which is what SVG's defaults say and what
            // resvg draws for a path that names no fill. Naming anything else
            // here would be comparing two different pictures.
            .fill = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        }) catch |err| {
            // A fixture this renderer refuses is a fact worth seeing rather
            // than a reason to stop: the corpus deliberately holds documents
            // that are on the feature list and not yet implemented, and
            // `check_oracle.py` reports a missing PNG as "not implemented"
            // rather than as a failure.
            try log.print("{s}: {t}\n", .{ entry.name, err });
            refused += 1;
            continue;
        };
        defer surface.deinit(gpa);

        // z2d's exporter takes a path relative to the current directory and
        // has no writer-shaped entry point, so the whole path is built here.
        const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ out_dir_path, stem });
        defer gpa.free(out_path);
        try z2d.png_exporter.writeToPNGFile(io, surface, out_path, .{});

        try manifest.print("{s}\t{d}\t{d}\n", .{ stem, width, height });
        rendered += 1;
    }

    try manifest.flush();
    try log.print("rendered {d} documents into {s}, refused {d}\n", .{
        rendered,
        out_dir_path,
        refused,
    });
    try log.flush();
}

/// A viewBox dimension as a pixel count, never zero.
///
/// Rounded **up**, which is what resvg does: asked for a 256-square box, a
/// 13-by-5 viewBox comes back 99 tall rather than the 98 that rounding to
/// nearest would give. Getting this wrong does not make a picture slightly
/// wrong, it makes the two images different sizes and the comparison
/// impossible -- so it is worth matching exactly rather than approximately.
/// It is also what `raster.fitDimension` does for a document's default size.
fn atLeastOne(v: f64) u32 {
    return @max(1, @as(u32, @intFromFloat(@ceil(v))));
}

fn usage() error{BadUsage} {
    std.debug.print("usage: oracle <in-dir> <out-dir>\n", .{});
    return error.BadUsage;
}
