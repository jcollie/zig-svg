// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Renders one SVG document to a PNG, so that the parser can be looked at.
//!
//! The path grammar is the part of this library with the most detail in it and
//! the least to say for itself at run time -- a wrong arc is a slightly wrong
//! picture, which is not something a test discovers by itself. This is how it
//! gets checked by eye, and how it gets compared against resvg by hand:
//!
//! ```console
//! $ zig build svgdump -- icon.svg out.png --size 256
//! $ resvg --width 256 --height 256 icon.svg theirs.png
//! ```
//!
//! `--sandbox` renders in a forked child locked down by seccomp on Linux or
//! Capsicum on FreeBSD, which is the way to see that the sandbox is working on
//! the machine in front of you.

const std = @import("std");
const z2d = @import("z2d");
const svg = @import("svg");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // The allocating form, which is the one that works everywhere: Windows
    // hands a program its command line as one UTF-16 string to be split, and
    // there is no splitting it without somewhere to put the pieces.
    var args: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();

    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var sandboxed = false;
    // Black on nothing, which is what SVG's own defaults say and what resvg
    // draws when the document names no fill.
    var background: ?z2d.Pixel = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--size")) {
            const n = try std.fmt.parseInt(u32, args.next() orelse return usage(), 10);
            width = n;
            height = n;
        } else if (std.mem.eql(u8, arg, "--width")) {
            width = try std.fmt.parseInt(u32, args.next() orelse return usage(), 10);
        } else if (std.mem.eql(u8, arg, "--height")) {
            height = try std.fmt.parseInt(u32, args.next() orelse return usage(), 10);
        } else if (std.mem.eql(u8, arg, "--sandbox")) {
            sandboxed = true;
        } else if (std.mem.eql(u8, arg, "--white")) {
            background = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage();
        } else if (in_path == null) {
            in_path = arg;
        } else if (out_path == null) {
            out_path = arg;
        } else {
            return usage();
        }
    }

    const input = in_path orelse return usage();
    const output = out_path orelse return usage();

    const src = try std.Io.Dir.cwd().readFileAlloc(io, input, gpa, .limited(1 << 22));
    defer gpa.free(src);

    const opts: svg.Options = .{
        .width = width,
        .height = height,
        .background = background,
    };

    if (sandboxed) {
        var image = try svg.sandbox.render(gpa, src, .{ .render = opts });
        defer image.deinit();
        try z2d.png_exporter.writeToPNGFile(io, image.surface, output, .{});
        return;
    }

    var surface = try svg.render(gpa, src, opts);
    defer surface.deinit(gpa);
    try z2d.png_exporter.writeToPNGFile(io, surface, output, .{});
}

fn usage() error{BadUsage} {
    std.debug.print(
        \\usage: svgdump <in.svg> <out.png> [--size N | --width N --height N]
        \\                                  [--white] [--sandbox]
        \\
    , .{});
    return error.BadUsage;
}
