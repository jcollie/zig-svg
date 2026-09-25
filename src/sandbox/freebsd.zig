// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The FreeBSD half of the sandbox's process plumbing, with Capsicum to lock
//! the child down.
//!
//! The same functions as `linux.zig`, with the same names and meanings; see
//! that file for why they are split out at all.
//!
//! These go through libc, because FreeBSD's system call interface is libc's
//! and nothing else is promised to be stable. That matters for the child,
//! which runs between a `fork` and an `_exit` in what may have been a threaded
//! parent: every call it makes here is one POSIX lists as async-signal-safe or
//! a thin wrapper around a single system call (`closefrom`, `procctl`,
//! `cap_rights_limit`, `cap_enter`), none of which takes a lock.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const capsicum = @import("capsicum.zig");
const seccomp = @import("seccomp.zig");

pub const Fd = i32;
pub const Pid = i32;

/// How a wait status is taken apart.
pub const W = c.W;
pub const SIG = c.SIG;

/// The signal a process dies of when capability mode refuses a call. See
/// `capsicum` for why a refusal kills at all.
pub const violation: SIG = .TRAP;

/// Whether this backend can run here at all.
pub const supported = capsicum.supported;

/// What `confine` can fail with.
pub const ConfineError = capsicum.InstallError;

extern "c" fn closefrom(lowfd: c_int) void;

/// A shared mapping of `len` bytes that a forked child sees too, or null.
///
/// Anonymous and shared, which FreeBSD backs with swap-backed memory that is
/// allocated when first touched, so no descriptor is needed at all --- one
/// fewer thing for the child to inherit.
pub fn mapShared(len: usize) ?[*]align(std.heap.page_size_min) u8 {
    const p = c.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (p == c.MAP_FAILED) return null;
    return @ptrCast(@alignCast(p));
}

pub fn unmap(ptr: [*]align(std.heap.page_size_min) u8, len: usize) void {
    _ = c.munmap(ptr, len);
}

/// A pipe, close-on-exec, or false.
pub fn pipe(fds: *[2]Fd) bool {
    return c.pipe2(fds, .{ .CLOEXEC = true }) == 0;
}

pub fn close(fd: Fd) void {
    _ = c.close(fd);
}

/// Zero in the child, the child's pid in the parent, null on failure.
///
/// libc's `fork`, which runs the `pthread_atfork` handlers and leaves the
/// child's copy of libc usable for the async-signal-safe calls it goes on to
/// make.
pub fn fork() ?Pid {
    const rc = c.fork();
    if (rc < 0) return null;
    return rc;
}

/// One `read`, retried across a signal. Zero at end of stream, null on error.
pub fn read(fd: Fd, buf: []u8) ?usize {
    while (true) {
        const rc = c.read(fd, buf.ptr, buf.len);
        switch (c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return null,
        }
    }
}

/// One `write`, retried across a signal. Null on error.
pub fn write(fd: Fd, bytes: []const u8) ?usize {
    while (true) {
        const rc = c.write(fd, bytes.ptr, bytes.len);
        switch (c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return null,
        }
    }
}

/// `_exit`, not `exit`: nothing registered with `atexit` belongs to the child.
pub fn exit(code: u8) noreturn {
    c._exit(code);
}

/// Waits for `pid` to end and returns its wait status, or null.
pub fn wait(pid: Pid) ?u32 {
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        switch (c.errno(rc)) {
            .SUCCESS => return @bitCast(status),
            .INTR => continue,
            else => return null,
        }
    }
}

/// Kills `pid` outright.
pub fn kill(pid: Pid) void {
    _ = c.kill(pid, .KILL);
}

/// A duplicate of `fd` numbered at least `min`, or null.
pub fn park(fd: Fd, min: Fd) ?Fd {
    const rc = c.fcntl(fd, c.F.DUPFD, min);
    if (rc < 0) return null;
    return rc;
}

/// Duplicates `fd` onto `want`, which must not be `fd` itself.
pub fn claim(fd: Fd, want: Fd) bool {
    return c.dup2(fd, want) == want;
}

/// Closes every descriptor numbered `first` or above.
pub fn closeFrom(first: Fd) void {
    closefrom(first);
}

/// The limits and flags a child is given before capability mode is entered.
///
/// The limits cannot be undone afterwards, since an unprivileged process can
/// only lower a hard limit. Tracing can be: `procctl(2)` lets a process
/// re-enable its own, so a subverted child could make itself attachable
/// again. That would help only a second process of the same user that is
/// already running and waiting for it, and such a process could attach to the
/// parent instead, so it is a courtesy rather than a wall. On Linux the
/// filter leaves no `prctl` to undo `PR_SET_DUMPABLE` with.
pub fn harden(cpu_seconds: ?u32) void {
    // A crash must not write the shared mapping out to disk.
    const no_core: c.rlimit = .{ .cur = 0, .max = 0 };
    _ = c.setrlimit(.CORE, &no_core);

    if (cpu_seconds) |seconds| {
        const cpu: c.rlimit = .{ .cur = seconds, .max = seconds };
        _ = c.setrlimit(.CPU, &cpu);
    }

    // Capability mode does not stop `fork`, which names nothing global; this
    // does, for anyone but root. See `capsicum`.
    const no_procs: c.rlimit = .{ .cur = 0, .max = 0 };
    _ = c.setrlimit(.NPROC, &no_procs);

    capsicum.disableTracing();
}

/// Locks the calling process down, irreversibly. See `capsicum`.
pub fn confine(comptime profile: seccomp.Profile) ConfineError!void {
    return capsicum.install(profile, @intCast(seccomp.reply_fd));
}

// -- for the tests ------------------------------------------------------------

/// A harmless call that capability mode refuses, for a test to prove the
/// sandbox refuses it.
///
/// Not `getpid`, which is the Linux backend's choice: capability mode permits
/// that, since it names nothing outside the process. Opening a path is the
/// canonical thing it forbids.
pub fn forbiddenCall() void {
    _ = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
}

/// Dies of a segmentation fault, with the kernel's own disposition rather
/// than whatever handler a Debug build installed.
pub fn crash() noreturn {
    // Hardened like a real child first, so that the crash leaves no core file.
    harden(null);
    var dfl: c.Sigaction = .{ .handler = .{ .handler = null }, .flags = 0, .mask = undefined };
    _ = c.sigemptyset(&dfl.mask);
    _ = c.sigaction(.SEGV, &dfl, null);
    _ = c.kill(c.getpid(), .SEGV);
    exit(0);
}
