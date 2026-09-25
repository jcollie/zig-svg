// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Locking the sandboxed renderer down on FreeBSD, with Capsicum.
//!
//! Capsicum is not a system call filter, and the difference shapes everything
//! here. seccomp asks "which calls may this process make?" and answers with a
//! list. Capsicum asks "which *things* may this process name?" and answers:
//! only the descriptors it already holds, and on each of those only the rights
//! that descriptor was limited to. A process in *capability mode* --- entered
//! with `cap_enter(2)`, and never left --- has lost every global namespace at
//! once: no path can be opened, no address connected to, no other process
//! signalled, no `sysctl` read beyond a short list of harmless ones.
//!
//! So where the seccomp filter permits four calls and kills on the fifth,
//! capability mode permits a couple of hundred calls and makes all of them
//! useless for escaping. `mmap` of anonymous memory works; `mmap` of a file
//! cannot happen because there is no file to name. `write` works on a held
//! descriptor, and only if that descriptor has `CAP_WRITE`.
//!
//! ## The rights the child keeps
//!
//! The child holds exactly the descriptors `sandbox.zig` gives it, and each is
//! limited with `cap_rights_limit(2)` before capability mode is entered:
//!
//! | descriptor | rights |
//! | --- | --- |
//! | the reply pipe | `CAP_WRITE` |
//! | standard input, output and error, under `strict` | none at all |
//!
//! Rights are per descriptor-table entry, and the child's table is its own
//! copy, so limiting them there does nothing to the parent's.
//!
//! The standard streams are limited rather than closed so that the numbers
//! stay taken --- a closed zero is the first number anything created later
//! would be given --- and so that writing to one is a refusal the process can
//! be killed for, which is the next part.
//!
//! ## Refusal is fatal
//!
//! Capsicum's own answer to a forbidden call is an error, `ECAPMODE` or
//! `ENOTCAPABLE`, and a process that gets one carries on. That is fine for
//! containment --- nothing escaped --- but it would make a subverted renderer
//! indistinguishable from one that failed quietly, which the Linux sandbox
//! does not. `procctl(PROC_TRAPCAP_CTL)` closes the gap: with it enabled, a
//! call refused for either reason also delivers `SIGTRAP`, whose default is to
//! end the process. The parent reads that as `error.SandboxViolation`, exactly
//! as it reads `SIGSYS` on Linux.
//!
//! A subverted child could catch or ignore `SIGTRAP` --- `sigaction` is not a
//! global namespace, so capability mode allows it --- and would then get the
//! plain error back instead. It gains nothing by it: the call was still
//! refused. The trap is how a violation is *reported*, not how it is stopped.
//!
//! ## The profiles
//!
//! `seccomp.Profile` is shared with Linux so that a caller's options mean the
//! same thing on both:
//!
//! - `strict`: the standard streams have no rights, and a refused call is
//!   fatal. A panic trying to print itself dies of the trap, which is what a
//!   panic under the strict seccomp filter does too.
//! - `permissive`: the standard streams are left alone and nothing traps. A
//!   panic prints its message, fails quietly to open the debug information
//!   for a trace, and aborts --- so it arrives as `error.RendererCrashed`,
//!   which is the point of asking for this profile.
//!
//! Capability mode itself is the same under both. Memory and signals are
//! never refused by it, so there is nothing for `permissive` to loosen there.
//!
//! ## What this does not do that seccomp does
//!
//! It does not stop the child creating processes. `fork` names no global
//! object, so capability mode allows it, and the new process is in capability
//! mode too --- contained, but a way to spend resources. `RLIMIT_NPROC` is set
//! to zero before capability mode is entered, which refuses `fork` to an
//! ordinary user; the kernel exempts root from that limit, so a program
//! running as root has only capability mode between a subverted renderer and a
//! fork bomb.
//!
//! It does not refuse the long tail of calls that touch only the process
//! itself --- `getpid`, `sigprocmask`, `clock_gettime` and the rest. None of
//! them reaches anything outside, which is the property that matters.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const testing = std.testing;

const seccomp = @import("seccomp.zig");

/// Whether capability mode can be entered on this target.
pub const supported = builtin.os.tag == .freebsd and @bitSizeOf(usize) == 64;

extern "c" fn cap_enter() c_int;
extern "c" fn cap_rights_limit(fd: c_int, rights: *const c.cap_rights) c_int;
extern "c" fn procctl(idtype: c_int, id: i64, cmd: c_int, data: ?*anyopaque) c_int;

/// `P_PID` from `sys/wait.h`'s `idtype_t`.
const P_PID: c_int = 0;
/// From `sys/procctl.h`.
const PROC_TRACE_CTL: c_int = 7;
const PROC_TRACE_CTL_DISABLE: c_int = 2;
const PROC_TRAPCAP_CTL: c_int = 9;
const PROC_TRAPCAP_CTL_ENABLE: c_int = 1;

/// A set of rights, as `cap_rights_init` would build it.
///
/// Built here rather than by calling `__cap_rights_init`, which is variadic,
/// because the layout is simple and fixed by the ABI (`sys/capsicum.h`): two
/// words, each carrying its own index as a marker bit --- 57 for the first,
/// 58 for the second --- and the version, zero, in the top two bits of the
/// first. The kernel checks all of that and refuses a set that is malformed,
/// so a mistake here is `EINVAL` rather than a hole.
pub const Rights = struct {
    /// `CAPRIGHT(0, 0x1)`: `read(2)` and its relatives.
    pub const read: u64 = 0x1;
    /// `CAPRIGHT(0, 0x2)`: `write(2)` and its relatives.
    pub const write: u64 = 0x2;

    /// The set holding exactly `bits`, all of which are first-word rights.
    pub fn of(bits: u64) c.cap_rights {
        return .{ .rights = .{ (1 << 57) | bits, 1 << 58 } };
    }

    /// The empty set: a descriptor limited to this can be closed and nothing
    /// else.
    pub const none: c.cap_rights = of(0);
};

/// Errors from locking a process down.
pub const InstallError = error{
    /// A descriptor could not be limited. It is left with rights the child
    /// should not have, so capability mode is never entered.
    RightsRefused,
    /// `cap_enter` failed: a kernel built without `options CAPABILITY_MODE`.
    CapabilityModeRefused,
};

/// Limits the child's descriptors and enters capability mode, irreversibly.
///
/// `reply` is the one descriptor the child keeps besides the standard
/// streams. Must be called after every other descriptor has
/// been closed, since anything still open keeps whatever rights it had.
pub fn install(comptime profile: seccomp.Profile, reply: c_int) InstallError!void {
    const strict = switch (profile) {
        .strict => true,
        .permissive => false,
    };

    try limit(reply, Rights.of(Rights.write));

    if (strict) {
        for ([_]c_int{ 0, 1, 2 }) |fd| try limit(fd, Rights.none);

        // The trap is delivered as an ordinary signal, so a Debug build's
        // handler for it --- or one the parent left installed --- must not be
        // what receives it. Back to the kernel's own disposition, which is to
        // end the process.
        var dfl: c.Sigaction = .{ .handler = .{ .handler = null }, .flags = 0, .mask = undefined };
        _ = c.sigemptyset(&dfl.mask);
        _ = c.sigaction(.TRAP, &dfl, null);

        var enable: c_int = PROC_TRAPCAP_CTL_ENABLE;
        // Best effort: without it a violation is still refused, only not
        // fatal, so its absence is no reason to refuse to render.
        _ = procctl(P_PID, c.getpid(), PROC_TRAPCAP_CTL, &enable);
    }

    if (cap_enter() != 0) return error.CapabilityModeRefused;
}

/// Limits `fd` to `rights`.
///
/// A descriptor that is not open has no rights to take away, so that refusal
/// is not an error: a closed standard stream, or a test's child that closed
/// the reply descriptor on purpose.
fn limit(fd: c_int, rights: c.cap_rights) InstallError!void {
    if (cap_rights_limit(fd, &rights) == 0) return;
    if (c._errno().* == @intFromEnum(c.E.BADF)) return;
    return error.RightsRefused;
}

/// Stops another process of the same user attaching to the child with
/// `ptrace` and reading the shared mapping out from under the parent.
pub fn disableTracing() void {
    var disable: c_int = PROC_TRACE_CTL_DISABLE;
    _ = procctl(P_PID, c.getpid(), PROC_TRACE_CTL, &disable);
}

test "the rights sets carry the markers the kernel checks" {
    // The ABI, written down: `CAP_READ` is `(1 << 57) | 1`, and every second
    // word carries `1 << 58` whether or not it holds a right.
    const r = Rights.of(Rights.read);
    try testing.expectEqual(@as(u64, 0x0200_0000_0000_0001), r.rights[0]);
    try testing.expectEqual(@as(u64, 0x0400_0000_0000_0000), r.rights[1]);
    try testing.expectEqual(@as(u64, 0x0200_0000_0000_0000), Rights.none.rights[0]);
}
