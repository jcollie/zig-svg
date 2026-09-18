// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Rendering in a process that cannot do anything but render.
//!
//! An SVG renderer is where memory-safety bugs live. It parses
//! attacker-controlled text, does floating-point arithmetic on numbers out of
//! that text, turns the results into buffer indices, and is reached by every
//! program that displays a picture from anywhere. Zig's bounds and overflow
//! checks catch a great deal of that in a safe build and none of it in
//! `ReleaseFast`, and neither build catches a logic error that reads the wrong
//! part of a buffer it is entitled to read. So the renderer is run somewhere it
//! can do no harm even if it is wrong.
//!
//! This follows [glycin](https://gitlab.gnome.org/GNOME/glycin), GNOME's image
//! loading library, which runs each format's loader as a separate sandboxed
//! process and passes the pixels back through shared memory. The mechanism
//! here is smaller — one `fork`, one seccomp filter, one `memfd` — because the
//! renderer it is protecting is already pure: it is handed a byte slice and a
//! buffer, so there is nothing to permit.
//!
//! ## How it works
//!
//! ```text
//!   parent                              child
//!   ------                              -----
//!   read the document into memory
//!   memfd_create + ftruncate
//!   mmap MAP_SHARED  ─────────────────▶ inherited across fork()
//!   pipe2
//!   fork()  ──────────────────────────▶ prctl(PR_SET_NO_NEW_PRIVS)
//!                                       seccomp(SET_MODE_FILTER)
//!                                       ── nothing further is permitted ──
//!                                       parse and rasterize, allocating
//!                                       from the mapping
//!                                       write(pipe, reply)
//!                                       exit_group(0)
//!   waitpid   ◀────────────────────────
//!   read the reply, validate it
//!   munmap the unused tail
//!   wrap the pixels as a z2d.Surface
//! ```
//!
//! Three details carry most of the design.
//!
//! **The source is copied in before the fork**, rather than streamed to the
//! child. A child that could still read its input would need `read` on a file
//! descriptor an attacker might redirect, and would introduce a deadlock — two
//! processes each blocked writing to a pipe the other is not draining. Copying
//! first costs the memory the document occupies, bounded by
//! `Limits.max_input_bytes`, and buys a child that needs no input system call
//! at all: after `fork` the bytes are simply there, copy-on-write.
//!
//! **The child allocates out of the shared mapping.** Its allocator is a
//! `FixedBufferAllocator` over the `memfd`, so the surface it draws into is
//! already in memory the parent can see, and there is nothing to copy back. It
//! also means the child needs no `mmap` and no `brk`: the memory was reserved
//! before the filter was installed. The reservation is address space rather
//! than memory — pages of a `memfd` are allocated when they are first touched
//! — so the default budget costs nothing for a small picture.
//!
//! Rasterizing wants rather more working memory than the pixels alone:
//! `z2d.painter.fill` builds the path, plots it into polygons and allocates a
//! scanline mask. `Options.working_bytes` is that, and it is the number to
//! raise when a render that succeeds unsandboxed comes back
//! `error.OutOfMemory` from here.
//!
//! **The reply is one fixed-size struct**, small enough that the write cannot
//! block on a full pipe, which is what lets the parent wait for the child to
//! exit *before* reading it. By the time the parent looks at the pixels the
//! writer of those pixels no longer exists.
//!
//! ## What this protects against, and what it does not
//!
//! It contains a renderer that has been subverted into doing something other
//! than rendering: reading a file, opening a socket, executing a program,
//! attaching to another process. All of those die at the attempt. That matters
//! more for SVG than for most formats, because SVG is a format whose full
//! specification *includes* fetching documents, running scripts and reading
//! fonts — so a renderer that grows towards it grows towards exactly the
//! capabilities this takes away.
//!
//! It contains a renderer that crashes. A segmentation fault in the child is
//! `error.RendererCrashed` in the parent, not a dead program.
//!
//! It does **not** make the pixels trustworthy. A subverted renderer can still
//! write whatever it likes into the shared mapping, because writing there is
//! its job. What the parent validates is the *shape* of the result — that the
//! buffer is inside the mapping, correctly aligned, and exactly the length the
//! stated dimensions require — so a malicious reply cannot make the parent
//! read out of bounds. The contents of a valid-looking buffer are the
//! attacker's if the renderer was theirs.
//!
//! It does not stop a renderer reading the rest of the shared mapping, which
//! holds this render's own working memory and nothing else.
//!
//! It is not a replacement for the limits. A child cannot exhaust the parent's
//! memory, but it can touch every page of the mapping, so the mapping is sized
//! by `Limits` like everything else here.
//!
//! ## Cost
//!
//! A `fork` and a `waitpid` per picture, plus the page faults for the pixels.
//! That is tens of microseconds against a render measured in milliseconds for
//! anything but a tiny icon — but it is per picture, so a program drawing
//! thousands of small icons should measure rather than assume, and should
//! consider rendering a sheet of them in one child instead.
//!
//! ## Where it runs
//!
//! Linux only, and only on 64-bit. `available` says so at compile time, and
//! `render` returns `error.SandboxUnavailable` at run time rather than
//! silently rendering unsandboxed — a security feature that quietly turns
//! itself off is worse than one that was never there.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");
const ztree = @import("ztree");

const raster = @import("raster.zig");

/// The seccomp filter the child runs under.
pub const seccomp = @import("sandbox/seccomp.zig");

/// Whether this target can sandbox anything.
///
/// A 32-bit address space cannot hold the reservation this design makes, and
/// seccomp is Linux's. Everywhere else, `render` fails rather than pretending.
pub const available = builtin.os.tag == .linux and @bitSizeOf(usize) == 64 and seccomp.supported;

/// The most address space the mapping may reserve. Far above any plausible
/// picture, and low enough that a `Limits` with nothing in it is caught here
/// rather than by `mmap`.
const max_reservation: u64 = 1 << 40;

/// Errors from a sandboxed render.
///
/// A superset of `raster.Error`: everything an ordinary render can fail with,
/// plus what can go wrong with the sandbox itself.
pub const Error = raster.Error || Allocator.Error || error{
    /// Not Linux, or not 64-bit.
    SandboxUnavailable,

    /// `Limits` does not bound the picture tightly enough to reserve memory
    /// for — `Limits.unlimited`, or something close to it. The sandbox has to
    /// reserve the output before it knows how big the output is, so it needs a
    /// ceiling; an ordinary `render` does not and will take these limits
    /// happily.
    LimitsUnbounded,

    /// The document is larger than `Limits.max_input_bytes`.
    InputTooLarge,

    /// The child was killed for making a system call the filter refused.
    ///
    /// This means the renderer tried to do something other than render. It is
    /// either an exploit or a bug, and under `seccomp.Profile.strict` it is
    /// also what a panicking renderer looks like, because printing a panic
    /// means reading debug info and reading is a system call. Re-running with
    /// `seccomp.Profile.permissive` tells the two apart.
    SandboxViolation,

    /// The child died some other way: a segmentation fault, an abort, a
    /// signal from outside. The renderer has a bug.
    RendererCrashed,

    /// The child exited without a usable reply, or with one that does not
    /// describe a buffer inside the shared mapping. Nothing is read from a
    /// mapping on the strength of a reply that failed this check.
    SandboxProtocolError,

    /// The sandbox could not be set up: `memfd_create`, `mmap`, `pipe2` or
    /// `fork` was refused. Not a property of the document.
    SandboxFailed,

    /// z2d refused to rasterize for a reason the wire has no narrower
    /// spelling of. An ordinary `render` would have said which; this is what
    /// is left of it after a trip through a pipe, and it means there is
    /// something to look at by re-running unsandboxed.
    RasterFailed,
};

/// How to render, and how tightly to lock the renderer down.
pub const Options = struct {
    /// The same options an unsandboxed render takes.
    render: raster.Options = .{},

    /// How much of the system call surface to leave the renderer.
    profile: seccomp.Profile = .strict,

    /// Working memory the renderer gets on top of the pixels: the path nodes,
    /// the plotted polygons and the scanline mask that `z2d.painter.fill`
    /// allocates while running.
    ///
    /// Address space rather than memory, like the rest of the mapping. Too
    /// small shows up as `error.OutOfMemory` from the render.
    working_bytes: usize = 32 << 20,
};

/// A rendered picture living in memory the sandbox set up.
///
/// The surface's buffer is inside a shared mapping rather than in the
/// allocator's heap, so it must **not** be released with
/// `z2d.Surface.deinit` — that would hand the mapping to an allocator that
/// never handed it out. Call `deinit` here instead, which unmaps it. The
/// surface is perfectly ordinary in every other way: draw on it, composite it,
/// clone it.
pub const Image = struct {
    /// The pixels. Valid until `deinit`.
    surface: z2d.Surface,

    /// The mapping the surface's buffer lives in. Not for the caller to touch;
    /// it is here so that `deinit` can give it back.
    mapping: []align(std.heap.page_size_min) u8,

    /// Unmaps the pixels. The surface is invalid afterwards.
    pub fn deinit(self: *Image) void {
        _ = linux.munmap(self.mapping.ptr, self.mapping.len);
        self.* = undefined;
    }

    /// A copy of the surface in ordinary heap memory, which can be released
    /// with `z2d.Surface.deinit` like any other.
    ///
    /// For a caller who wants the sandbox for the render and does not want to
    /// think about the mapping afterwards — the cost is one copy of the
    /// pixels.
    pub fn toOwned(self: *const Image, gpa: Allocator) Allocator.Error!z2d.Surface {
        // Done by hand because z2d has no copy constructor to call: `init`
        // allocates a blank surface and `initBuffer` adopts a buffer without
        // copying it, so there is nothing that takes a surface and gives back
        // an owned one. The switch is `inline else` so that each variant's
        // buffer keeps its own element type.
        switch (self.surface) {
            inline else => |s, tag| {
                const buf = try gpa.dupe(std.meta.Elem(@TypeOf(s.buf)), s.buf);
                return @unionInit(z2d.Surface, @tagName(tag), .{
                    .width = s.width,
                    .height = s.height,
                    .buf = buf,
                });
            },
        }
    }
};

/// Renders `src` in a sandboxed child process.
///
/// `gpa` is used for a copy of the document only, and is released before this
/// returns; the pixels come back in a mapping the `Image` owns.
///
/// Beware `fork` in a threaded program. This forks, and the child runs Zig
/// code between the fork and the `exit_group`, which in a multi-threaded
/// parent is only safe if that code is async-signal-safe. It is: the child
/// installs a filter, renders out of a fixed buffer it was given, writes a
/// struct to a pipe and exits, taking no lock and allocating nothing from the
/// parent's heap. Nothing here calls into libc.
pub fn render(gpa: Allocator, src: []const u8, opts: Options) Error!Image {
    if (!available) return error.SandboxUnavailable;

    const limits = opts.render.limits;
    if (src.len > limits.max_input_bytes) return error.InputTooLarge;

    // The reservation, decided before anything has been parsed: the pixels a
    // `Limits` permits at four bytes each, plus the rasterizer's working
    // memory.
    const pixel_bytes = math.mul(u64, limits.max_pixels, 4) catch return error.LimitsUnbounded;
    const requested = math.add(u64, pixel_bytes, opts.working_bytes) catch return error.LimitsUnbounded;
    if (requested > max_reservation) return error.LimitsUnbounded;
    const page = std.heap.pageSize();
    const cap: usize = @intCast(mem.alignForward(u64, requested, page));

    // The whole document, in ordinary memory, before the fork. The caller's
    // slice would do, since `fork` shares it copy-on-write either way — but
    // only if the caller is not about to free it, and a copy is the one thing
    // that makes the child's lifetime independent of the parent's.
    const input = try gpa.dupe(u8, src);
    defer gpa.free(input);

    const fd = try makeMemfd(cap);
    defer _ = linux.close(fd);

    const base = try mapShared(fd, cap);
    // Unmapped on every path out but the successful one, where ownership
    // passes to the `Image`.
    var mapped = true;
    defer if (mapped) {
        _ = linux.munmap(base, cap);
    };

    var pipe_fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SandboxFailed;
    // The write end is closed early on the successful path, so that the pipe
    // reaches end of stream when the child is gone; this flag is what keeps
    // the cleanup from closing it a second time and shutting whatever
    // descriptor number has since been handed out.
    var pipe_open = [2]bool{ true, true };
    defer for (pipe_fds, pipe_open) |pfd, open| {
        if (open) _ = linux.close(pfd);
    };

    const arena = base[0..cap];

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return error.SandboxFailed;
    const pid: i32 = @intCast(fork_rc);

    if (pid == 0) {
        // The child. Nothing below this line returns.
        _ = linux.close(pipe_fds[0]);
        childMain(pipe_fds[1], arena, input, opts);
    }

    // The parent keeps only the read end, so that the pipe reaches end of
    // stream when the child is gone.
    _ = linux.close(pipe_fds[1]);
    pipe_open[1] = false;

    const status = try waitFor(pid);
    const reply = readReply(pipe_fds[0]);

    try checkExit(status);

    const r = reply orelse return error.SandboxProtocolError;
    if (r.magic != reply_magic) return error.SandboxProtocolError;
    if (r.status != 0) return wireToError(r.status);

    const surface_type = surfaceTypeFromWire(r.surface_type) orelse return error.SandboxProtocolError;
    const sfc = try wrapSurface(surface_type, arena, r);

    // Everything past the pixels is the renderer's spent working memory, and
    // giving it back is the difference between a live mapping the size of the
    // picture and one the size of the budget.
    const keep = mem.alignForward(usize, @intCast(r.offset + r.len), page);
    if (keep < cap) _ = linux.munmap(base + keep, cap - keep);

    mapped = false;
    return .{
        .surface = sfc,
        .mapping = @alignCast(base[0..keep]),
    };
}

// -- the child ---------------------------------------------------------------

/// Everything the child does, which is as little as it can be.
///
/// Async-signal-safe throughout, because a `fork` from a threaded parent gives
/// a child holding whatever locks the other threads held at the moment of the
/// fork, forever. Nothing here takes a lock, allocates from the parent's heap,
/// or calls libc.
fn childMain(write_fd: i32, arena: []u8, input: []const u8, opts: Options) noreturn {
    var reply: Reply = .{
        .magic = reply_magic,
        .status = @intFromEnum(WireError.protocol),
        .surface_type = 0,
        .width = 0,
        .height = 0,
        .offset = 0,
        .len = 0,
    };

    result: {
        // The point of no return: after this the process can report a result
        // and stop, and that is all.
        switch (opts.profile) {
            inline else => |p| seccomp.install(p) catch {
                reply.status = @intFromEnum(WireError.sandbox);
                break :result;
            },
        }

        var fba: std.heap.FixedBufferAllocator = .init(arena);

        // The surface is allocated first and the rasterizer's working memory
        // after it, which is what lets the parent unmap the tail: the pixels
        // are at a known offset near the bottom of the mapping rather than
        // somewhere above a megabyte of spent scanline masks.
        const sfc = raster.render(fba.allocator(), input, opts.render) catch |err| {
            reply.status = @intFromEnum(wireFromError(err));
            break :result;
        };

        const bytes = surfaceBytes(sfc);
        reply.status = 0;
        reply.surface_type = @intFromEnum(std.meta.activeTag(sfc)) + 1;
        reply.width = @intCast(sfc.getWidth());
        reply.height = @intCast(sfc.getHeight());
        reply.offset = @intFromPtr(bytes.ptr) - @intFromPtr(arena.ptr);
        reply.len = bytes.len;
    }

    writeAll(write_fd, mem.asBytes(&reply));
    _ = linux.exit_group(0);
    unreachable;
}

/// The surface's pixel buffer as bytes, wherever in the union it lives.
fn surfaceBytes(sfc: z2d.Surface) []const u8 {
    return switch (sfc) {
        inline else => |s| mem.sliceAsBytes(s.buf),
    };
}

/// `write` until it is all gone, which is the child's only system call in
/// ordinary operation.
fn writeAll(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                off += rc;
            },
            .INTR => continue,
            // Nothing useful is left to do: the parent will see a missing
            // reply and say so.
            else => return,
        }
    }
}

// -- the wire ----------------------------------------------------------------

/// Guards against a reply that is not one: a short write, a child that died
/// mid-struct, a pipe with something else in it.
const reply_magic: u32 = 0x7376_6773; // "svgs"

/// What the child tells the parent. Fixed size, so the write cannot block and
/// the parent can wait for the child before reading it.
const Reply = extern struct {
    magic: u32,
    /// Zero, or a `WireError`.
    status: u16,
    /// `@intFromEnum(SurfaceType) + 1`, so that zero is never a valid type.
    surface_type: u8,
    _pad: [1]u8 = @splat(0),
    width: u32,
    height: u32,
    /// Where the pixel buffer starts within the shared mapping.
    offset: u64,
    /// How long it is, in bytes.
    len: u64,
};

/// An error, as a number that survives a process boundary.
///
/// A Zig error is an integer whose value depends on how the program was
/// compiled, so it cannot simply be written down and read back. This
/// enumeration is the stable spelling, and the two functions either side of it
/// are the only places the mapping exists.
const WireError = enum(u16) {
    ok = 0,
    not_an_svg = 1,
    bad_view_box = 2,
    no_path = 3,
    unsupported_element = 4,
    malformed_xml = 5,
    bad_path_data = 6,
    path_too_complex = 7,
    image_too_large = 8,
    bad_size = 9,
    out_of_memory = 10,
    too_many_shapes = 14,
    bad_color = 15,
    bad_opacity = 16,
    bad_fill_rule = 17,
    bad_transform = 18,
    too_deeply_nested = 20,
    non_finite_transform = 21,
    coordinate_out_of_range = 22,
    bad_length = 23,
    bad_stroke_style = 24,
    too_many_dashes = 25,
    bad_preserve_aspect_ratio = 26,
    no_size = 27,
    bad_reference = 29,
    unknown_reference = 30,
    recursive_use = 31,
    too_many_use_hops = 32,
    unsupported_paint_server = 33,
    unsupported_spread_method = 34,
    bad_gradient_units = 35,
    too_many_stops = 36,
    bad_stop_offset = 37,
    too_many_gradient_hops = 38,
    too_many_layers = 39,
    /// Something z2d refused that is none of the above.
    raster_failed = 11,
    /// The filter could not be installed, so nothing was rendered.
    sandbox = 12,
    /// The child never got as far as setting a status.
    protocol = 13,
    _,
};

fn wireFromError(err: anyerror) WireError {
    return switch (err) {
        error.NotAnSvg => .not_an_svg,
        error.BadViewBox => .bad_view_box,
        error.NoPath => .no_path,
        error.UnsupportedElement => .unsupported_element,
        error.ExpectedMoveTo,
        error.UnknownCommand,
        error.TruncatedCommand,
        error.InvalidNumber,
        error.InvalidFlag,
        => .bad_path_data,
        error.PathTooComplex => .path_too_complex,
        error.TooManyShapes => .too_many_shapes,
        error.BadColor => .bad_color,
        error.BadOpacity => .bad_opacity,
        error.BadFillRule => .bad_fill_rule,
        error.BadTransform => .bad_transform,
        error.TooDeeplyNested => .too_deeply_nested,
        error.NonFiniteTransform => .non_finite_transform,
        error.CoordinateOutOfRange => .coordinate_out_of_range,
        error.BadLength => .bad_length,
        error.BadStrokeStyle => .bad_stroke_style,
        error.TooManyDashes => .too_many_dashes,
        error.BadPreserveAspectRatio => .bad_preserve_aspect_ratio,
        error.NoSize => .no_size,
        error.BadReference => .bad_reference,
        error.UnknownReference => .unknown_reference,
        error.RecursiveUse => .recursive_use,
        error.TooManyUseHops => .too_many_use_hops,
        error.UnsupportedPaintServer => .unsupported_paint_server,
        error.UnsupportedSpreadMethod => .unsupported_spread_method,
        error.BadGradientUnits => .bad_gradient_units,
        error.TooManyStops => .too_many_stops,
        error.BadStopOffset => .bad_stop_offset,
        error.TooManyGradientHops => .too_many_gradient_hops,
        error.TooManyLayers => .too_many_layers,
        error.ImageTooLarge => .image_too_large,
        error.BadSize => .bad_size,
        error.OutOfMemory => .out_of_memory,
        // Everything zxml can refuse a document with, which is a long list
        // that all means the same thing to a caller: it was not XML.
        else => if (isXmlError(err)) .malformed_xml else .raster_failed,
    };
}

/// Whether `err` is one of the XML reader's, decided by asking the error set
/// rather than by listing its members here — a list that would go stale
/// silently the next time zxml grew a way to refuse a document.
fn isXmlError(err: anyerror) bool {
    @setEvalBranchQuota(20000);
    inline for (@typeInfo(ztree.ParseError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

fn wireToError(status: u16) Error {
    return switch (@as(WireError, @enumFromInt(status))) {
        .ok => error.SandboxProtocolError, // never called with zero
        .not_an_svg => error.NotAnSvg,
        .bad_view_box => error.BadViewBox,
        .no_path => error.NoPath,
        .unsupported_element => error.UnsupportedElement,
        // The one place the wire loses detail: zxml has two dozen ways to
        // refuse a document and this picks the one that says the least about
        // which. A caller that needs to know which runs `document.read`
        // itself, which is cheap and needs no sandbox.
        .malformed_xml => error.UnexpectedEndOfDocument,
        .bad_path_data => error.UnknownCommand,
        .path_too_complex => error.PathTooComplex,
        .too_many_shapes => error.TooManyShapes,
        .bad_color => error.BadColor,
        .bad_opacity => error.BadOpacity,
        .bad_fill_rule => error.BadFillRule,
        .bad_transform => error.BadTransform,
        .too_deeply_nested => error.TooDeeplyNested,
        .non_finite_transform => error.NonFiniteTransform,
        .coordinate_out_of_range => error.CoordinateOutOfRange,
        .bad_length => error.BadLength,
        .bad_stroke_style => error.BadStrokeStyle,
        .too_many_dashes => error.TooManyDashes,
        .bad_preserve_aspect_ratio => error.BadPreserveAspectRatio,
        .no_size => error.NoSize,
        .bad_reference => error.BadReference,
        .unknown_reference => error.UnknownReference,
        .recursive_use => error.RecursiveUse,
        .too_many_use_hops => error.TooManyUseHops,
        .unsupported_paint_server => error.UnsupportedPaintServer,
        .unsupported_spread_method => error.UnsupportedSpreadMethod,
        .bad_gradient_units => error.BadGradientUnits,
        .too_many_stops => error.TooManyStops,
        .bad_stop_offset => error.BadStopOffset,
        .too_many_gradient_hops => error.TooManyGradientHops,
        .too_many_layers => error.TooManyLayers,
        .image_too_large => error.ImageTooLarge,
        .bad_size => error.BadSize,
        .out_of_memory => error.OutOfMemory,
        .raster_failed => error.RasterFailed,
        .sandbox => error.SandboxFailed,
        .protocol, _ => error.SandboxProtocolError,
    };
}

fn surfaceTypeFromWire(v: u8) ?z2d.surface.SurfaceType {
    if (v == 0) return null;
    const fields = @typeInfo(z2d.surface.SurfaceType).@"enum".fields;
    if (v - 1 >= fields.len) return null;
    return @enumFromInt(v - 1);
}

// -- the parent's half -------------------------------------------------------

fn makeMemfd(cap: usize) Error!i32 {
    const rc = linux.memfd_create("zig-svg-pixels", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.SandboxFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(cap))) != .SUCCESS) return error.SandboxFailed;
    return fd;
}

fn mapShared(fd: i32, cap: usize) Error![*]u8 {
    const rc = linux.mmap(
        null,
        cap,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    if (linux.errno(rc) != .SUCCESS) return error.SandboxFailed;
    return @ptrFromInt(rc);
}

fn waitFor(pid: i32) Error!u32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return status,
            .INTR => continue,
            else => return error.SandboxFailed,
        }
    }
}

/// Turns how the child died into the error that says so.
fn checkExit(status: u32) Error!void {
    if (linux.W.IFSIGNALED(status)) {
        return switch (linux.W.TERMSIG(status)) {
            .SYS => error.SandboxViolation,
            else => error.RendererCrashed,
        };
    }
    if (!linux.W.IFEXITED(status)) return error.RendererCrashed;
    if (linux.W.EXITSTATUS(status) != 0) return error.RendererCrashed;
}

/// Reads the reply, if there is a whole one.
///
/// Called after the child has been reaped, so the pipe holds everything it
/// will ever hold and a short read means a short write.
fn readReply(fd: i32) ?Reply {
    var reply: Reply = undefined;
    const buf = mem.asBytes(&reply);
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null; // end of stream, short reply
                off += rc;
            },
            .INTR => continue,
            else => return null,
        }
    }
    return reply;
}

/// Builds a surface over the child's pixels, having satisfied itself that they
/// are where the reply says they are.
///
/// This is the security boundary on the way back. Every number in the reply
/// was written by the process that is not trusted, so each one is checked
/// against something the parent knows: the mapping's length, the alignment the
/// pixel type needs, and the buffer length the stated dimensions imply. Only
/// then is a pointer made out of an offset.
///
/// z2d has no constructor for this. `Surface.initBuffer` would do it, but it
/// clears the buffer it is given, which here means erasing the picture. So the
/// union is built directly out of the fields, which are public and are the
/// same three fields `initBuffer` would have set.
fn wrapSurface(
    surface_type: z2d.surface.SurfaceType,
    arena: []u8,
    reply: Reply,
) Error!z2d.Surface {
    if (reply.width == 0 or reply.height == 0) return error.SandboxProtocolError;
    const end = math.add(u64, reply.offset, reply.len) catch return error.SandboxProtocolError;
    if (end > arena.len) return error.SandboxProtocolError;

    const w: i32 = math.cast(i32, reply.width) orelse return error.SandboxProtocolError;
    const h: i32 = math.cast(i32, reply.height) orelse return error.SandboxProtocolError;
    const count = @as(u64, reply.width) * @as(u64, reply.height);
    const offset: usize = @intCast(reply.offset);

    switch (surface_type) {
        inline .image_surface_argb,
        .image_surface_xrgb,
        .image_surface_rgb,
        .image_surface_rgba,
        .image_surface_alpha8,
        => |t| {
            const T = t.toPixelType();
            if (reply.len != count * @sizeOf(T)) return error.SandboxProtocolError;
            if (offset % @alignOf(T) != 0) return error.SandboxProtocolError;
            const ptr: [*]T = @ptrCast(@alignCast(arena.ptr + offset));
            return @unionInit(z2d.Surface, @tagName(t), .{
                .width = w,
                .height = h,
                .buf = ptr[0..@intCast(count)],
            });
        },
        inline .image_surface_alpha4,
        .image_surface_alpha2,
        .image_surface_alpha1,
        => |t| {
            const T = t.toPixelType();
            // The packing z2d uses: as many pixels to a byte as fit, rounded
            // up to a whole byte at the end of the image rather than the end
            // of each row.
            if (reply.len != (count * @bitSizeOf(T) + 7) / 8) return error.SandboxProtocolError;
            return @unionInit(z2d.Surface, @tagName(t), .{
                .width = w,
                .height = h,
                .buf = arena[offset..][0..@intCast(reply.len)],
            });
        },
    }
}

// -- tests -------------------------------------------------------------------

const icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2,2H22V22H2V2Z" /></svg>
;

/// Small enough that the mapping is a few megabytes rather than a gigabyte,
/// which is what makes these tests cheap.
const test_limits: raster.Limits = .{
    .max_width = 256,
    .max_height = 256,
    .max_pixels = 1 << 16,
};

test "an icon renders inside the sandbox" {
    if (!available) return error.SkipZigTest;

    var image = render(testing.allocator, icon, .{
        .render = .{
            .width = 64,
            .height = 64,
            .fill = .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
            .limits = test_limits,
        },
        .working_bytes = 4 << 20,
    }) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer image.deinit();

    try testing.expectEqual(@as(i32, 64), image.surface.getWidth());
    try testing.expectEqual(@as(i32, 64), image.surface.getHeight());
    // Inside the square, which runs from 5 to 59 at this scale.
    try testing.expectEqual(@as(u8, 255), image.surface.getPixel(32, 32).?.rgba.r);
    // And outside it.
    try testing.expectEqual(@as(u8, 0), image.surface.getPixel(1, 1).?.rgba.a);
}

test "the picture survives being taken out of the mapping" {
    if (!available) return error.SkipZigTest;

    var image = render(testing.allocator, icon, .{
        .render = .{ .width = 32, .height = 32, .limits = test_limits },
        .working_bytes = 4 << 20,
    }) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    const before = image.surface.getPixel(16, 16).?;

    var owned = try image.toOwned(testing.allocator);
    defer owned.deinit(testing.allocator);
    image.deinit();

    try testing.expectEqual(before, owned.getPixel(16, 16).?);
}

test "a document the reader refuses comes back as that refusal" {
    if (!available) return error.SkipZigTest;

    try testing.expectError(error.UnsupportedElement, render(
        testing.allocator,
        "<svg viewBox=\"0 0 24 24\"><text x=\"1\" y=\"1\">hi</text></svg>",
        .{ .render = .{ .limits = test_limits }, .working_bytes = 4 << 20 },
    ));
    try testing.expectError(error.NoSize, render(
        testing.allocator,
        "<svg><path d=\"M0 0Z\"/></svg>",
        .{ .render = .{ .limits = test_limits }, .working_bytes = 4 << 20 },
    ));
}

test "limits with no ceiling are refused rather than mapped" {
    if (!available) return error.SkipZigTest;
    try testing.expectError(error.LimitsUnbounded, render(testing.allocator, icon, .{
        .render = .{ .limits = .unlimited },
    }));
}

test "a document larger than the input limit never reaches a child" {
    if (!available) return error.SkipZigTest;
    try testing.expectError(error.InputTooLarge, render(testing.allocator, icon, .{
        .render = .{ .limits = .{
            .max_width = 256,
            .max_height = 256,
            .max_pixels = 1 << 16,
            .max_input_bytes = 8,
        } },
    }));
}

test "every wire error round trips to something a caller can act on" {
    // The wire is the one place an error crosses a process boundary, and a
    // mistake in either direction is silent: a status nothing maps produces
    // `SandboxProtocolError`, which reads as a sandbox bug rather than as a
    // malformed document.
    const cases = [_]struct { anyerror, WireError }{
        .{ error.NotAnSvg, .not_an_svg },
        .{ error.BadViewBox, .bad_view_box },
        .{ error.NoPath, .no_path },
        .{ error.UnsupportedElement, .unsupported_element },
        .{ error.InvalidFlag, .bad_path_data },
        .{ error.PathTooComplex, .path_too_complex },
        .{ error.TooManyShapes, .too_many_shapes },
        .{ error.BadColor, .bad_color },
        .{ error.BadOpacity, .bad_opacity },
        .{ error.BadFillRule, .bad_fill_rule },
        .{ error.BadTransform, .bad_transform },
        .{ error.TooDeeplyNested, .too_deeply_nested },
        .{ error.NonFiniteTransform, .non_finite_transform },
        .{ error.CoordinateOutOfRange, .coordinate_out_of_range },
        .{ error.BadLength, .bad_length },
        .{ error.BadStrokeStyle, .bad_stroke_style },
        .{ error.TooManyDashes, .too_many_dashes },
        .{ error.BadPreserveAspectRatio, .bad_preserve_aspect_ratio },
        .{ error.NoSize, .no_size },
        .{ error.BadReference, .bad_reference },
        .{ error.RecursiveUse, .recursive_use },
        .{ error.UnsupportedSpreadMethod, .unsupported_spread_method },
        .{ error.TooManyStops, .too_many_stops },
        .{ error.ImageTooLarge, .image_too_large },
        .{ error.BadSize, .bad_size },
        .{ error.OutOfMemory, .out_of_memory },
        .{ error.InvalidName, .malformed_xml },
        .{ error.PathNotClosed, .raster_failed },
    };
    for (cases) |c| {
        try testing.expectEqual(c[1], wireFromError(c[0]));
        // And every one of them comes back as an error rather than as a
        // protocol failure.
        try testing.expect(wireToError(@intFromEnum(c[1])) != error.SandboxProtocolError);
    }
    // A status from the future is a protocol error and not a wrong error.
    try testing.expectEqual(error.SandboxProtocolError, wireToError(60000));
}

test "every error this library defines has a wire spelling of its own" {
    // The failure this catches is silent: an error with no case in
    // `wireFromError` falls through to `raster_failed`, and the caller of a
    // sandboxed render is told "z2d refused this" for what was really a
    // malformed colour. Adding an error to the library without adding it here
    // is exactly the kind of thing nobody notices.
    //
    // Two whole sets are exempt rather than named one by one, so that this
    // does not have to be edited when a dependency grows an error. An error
    // from z2d genuinely *is* "the rasterizer refused", which is what
    // `raster_failed` says; an error from zxml genuinely is "that was not
    // XML", which is what `malformed_xml` says.
    @setEvalBranchQuota(40000);
    inline for (@typeInfo(raster.Error).error_set.?) |e| {
        const err = @field(anyerror, e.name);
        const exempt = comptime err == error.RasterFailed or
            inSet(z2d.painter.FillError, err) or
            inSet(z2d.Path.Error, err) or
            inSet(ztree.ParseError, err);
        if (!exempt and wireFromError(err) == .raster_failed) {
            std.debug.print("no wire spelling for error.{s}\n", .{e.name});
            return error.ErrorMissingFromWire;
        }
    }
}

/// Whether `err` belongs to the error set `Set`.
fn inSet(comptime Set: type, comptime err: anyerror) bool {
    comptime {
        for (@typeInfo(Set).error_set.?) |e| {
            if (err == @field(anyerror, e.name)) return true;
        }
        return false;
    }
}
