// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Linux half of the sandbox's process plumbing: raw system calls, no
//! libc, and seccomp to lock the child down.
//!
//! `sandbox.zig` is written against the handful of functions here and their
//! FreeBSD twins in `freebsd.zig`, which have the same names and the same
//! meanings. Everything that differs between the two kernels lives in these
//! files; everything that does not --- the wire, the validation, the order the
//! child does things in --- lives there, once.
//!
//! Raw system calls rather than libc because the child runs between a `fork`
//! and an `exit_group` in what may have been a threaded parent, where anything
//! that takes a lock can deadlock for ever. None of these does.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const math = std.math;

const seccomp = @import("seccomp.zig");

pub const Fd = i32;
pub const Pid = i32;

/// How a wait status is taken apart.
pub const W = linux.W;
pub const SIG = linux.SIG;

/// The signal a process dies of when the filter refuses a call.
pub const violation: SIG = .SYS;

/// Whether this backend can run here at all.
pub const supported = seccomp.supported;

/// What `confine` can fail with.
pub const ConfineError = seccomp.InstallError;

/// A shared mapping of `len` bytes that a forked child sees too, or null.
///
/// Backed by a `memfd` so that its pages are allocated when first touched
/// rather than when reserved. The descriptor is closed before this returns:
/// the mapping keeps the memory alive, and a descriptor left open would be one
/// more thing for the child to inherit.
pub fn mapShared(len: usize) ?[*]align(std.heap.page_size_min) u8 {
    const rc = linux.memfd_create("zig-svg-pixels", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: Fd = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(len))) != .SUCCESS) return null;
    const addr = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return null;
    return @ptrFromInt(addr);
}

pub fn unmap(ptr: [*]align(std.heap.page_size_min) u8, len: usize) void {
    _ = linux.munmap(ptr, len);
}

/// A pipe, close-on-exec, or false.
pub fn pipe(fds: *[2]Fd) bool {
    return linux.errno(linux.pipe2(fds, .{ .CLOEXEC = true })) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

/// Zero in the child, the child's pid in the parent, null on failure.
pub fn fork() ?Pid {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// One `read`, retried across a signal. Zero at end of stream, null on error.
pub fn read(fd: Fd, buf: []u8) ?usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => return null,
        }
    }
}

/// One `write`, retried across a signal. Null on error.
pub fn write(fd: Fd, bytes: []const u8) ?usize {
    while (true) {
        const rc = linux.write(fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => return null,
        }
    }
}

pub fn exit(code: u8) noreturn {
    _ = linux.exit_group(code);
    unreachable;
}

/// Waits for `pid` to end and returns its wait status, or null.
pub fn wait(pid: Pid) ?u32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return status,
            .INTR => continue,
            else => return null,
        }
    }
}

/// Kills `pid` outright.
pub fn kill(pid: Pid) void {
    _ = linux.kill(pid, .KILL);
}

/// A duplicate of `fd` numbered at least `min`, or null.
pub fn park(fd: Fd, min: Fd) ?Fd {
    const rc = linux.fcntl(fd, linux.F.DUPFD, @intCast(min));
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Duplicates `fd` onto `want`, which must not be `fd` itself.
pub fn claim(fd: Fd, want: Fd) bool {
    return linux.errno(linux.dup3(fd, want, 0)) == .SUCCESS;
}

/// Closes every descriptor numbered `first` or above.
///
/// Best effort on a kernel without `close_range`, which is Linux 5.9. The
/// fallback is bounded rather than running to the descriptor limit, which may
/// be millions.
pub fn closeFrom(first: Fd) void {
    const rc = linux.close_range(first, math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false });
    if (linux.errno(rc) == .SUCCESS) return;
    var fd: Fd = first;
    while (fd < 4096) : (fd += 1) _ = linux.close(fd);
}

/// The limits and flags a child is given before its filter goes on.
///
/// None of these needs permitting, because all of them happen first, and none
/// of them can be undone afterwards --- `RLIMIT` hard limits only ever go
/// down for a process without privilege, and `PR_SET_DUMPABLE` is not a thing
/// a filtered process can call back.
pub fn harden(cpu_seconds: ?u32) void {
    // A crash must not write the shared mapping out to disk.
    const no_core: linux.rlimit = .{ .cur = 0, .max = 0 };
    _ = linux.setrlimit(.CORE, &no_core);

    if (cpu_seconds) |seconds| {
        const cpu: linux.rlimit = .{ .cur = seconds, .max = seconds };
        _ = linux.setrlimit(.CPU, &cpu);
    }

    // Not dumpable: no core file, and no ptrace attach from another process
    // of the same user, which would otherwise be able to read the mapping out
    // from under the parent.
    _ = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
}

/// Locks the calling process down, irreversibly. See `seccomp`.
///
/// The descriptor numbers are compiled into the filter, so the ones the child
/// was given have to be the ones `seccomp` names --- which is what the child
/// arranges before it gets here.
pub fn confine(comptime profile: seccomp.Profile) ConfineError!void {
    return seccomp.install(profile);
}

// -- for the tests ------------------------------------------------------------

/// A harmless call that no profile permits, for a test to prove the sandbox
/// refuses it.
pub fn forbiddenCall() void {
    _ = linux.getpid();
}

/// Dies of a segmentation fault, with the kernel's own disposition rather
/// than whatever handler a Debug build installed.
pub fn crash() noreturn {
    // A Debug build installs a handler for this signal that prints a stack
    // trace, and a forked child has inherited it along with the test runner's
    // pipe to the build runner: left in place, the child writes a crash report
    // the parent is about to prove it survived, and the step fails on the
    // noise.
    //
    // Hardened like a real child first, which is what keeps the crash from
    // leaving a core file behind --- including the one qemu-user writes of its
    // own accord when the tests run under emulation.
    harden(null);
    const dfl: linux.Sigaction = .{
        .handler = .{ .handler = null },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.SEGV, &dfl, null);
    _ = linux.kill(linux.getpid(), .SEGV);
    exit(0);
}
