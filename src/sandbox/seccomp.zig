// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Building the seccomp filter that the sandboxed decoder runs under.
//!
//! A seccomp filter is a classic-BPF program the kernel runs before every
//! system call the process makes. Its input is a `struct seccomp_data` — the
//! call number, the architecture, and the six arguments — and its output is a
//! verdict. The one used here is `SECCOMP_RET_KILL_PROCESS`, which is exactly
//! what it says: the process is gone, immediately, with no chance to catch the
//! signal or to run anything else first. A filter is inherited across `fork`
//! and `execve` and cannot be removed once installed, which is what makes it
//! worth anything.
//!
//! The filter built here is an allowlist. Everything not named is refused, so
//! a call this library has never heard of — one added to the kernel after it
//! was written — is refused too. That is the right way round: a denylist
//! written in 2026 protects nothing against a kernel from 2030.
//!
//! ## Reading the program
//!
//! Classic BPF has no labels. Jumps are forward-only and are counted in
//! instructions from the one after the jump, so the whole program is laid out
//! in one shape and the distances computed from it:
//!
//! ```text
//!   0  ld   [arch]                      the architecture of the call
//!   1  jeq  #this_arch, next, KILL      refuse anything else
//!   2  ld   [nr]                        the call number
//!   3  jge  #x32_bit, KILL, next        x86-64 only; see below
//!   4  jeq  #allowed[0], ALLOW, next
//!   5  jeq  #allowed[1], ALLOW, next
//!      ...
//!   n  ret  #KILL_PROCESS
//!  n+1  ret  #ALLOW
//! ```
//!
//! Checking the architecture first is not a formality. System call numbers are
//! per-architecture and they collide: on x86-64, number 1 is `write`, and on
//! the 32-bit x86 ABI that the same kernel will happily run, number 1 is
//! `exit`. A filter that allowed `write` by number and did not check the
//! architecture would be allowing a different call entirely to a process that
//! asked for it through the other gate.
//!
//! The x32 check is the same problem in a subtler form: x86-64's x32 ABI
//! shares the architecture token with ordinary x86-64 but sets bit 30 of every
//! call number, so `write | 0x40000000` is a call this filter would otherwise
//! see as an unknown number and refuse — which is correct, but only by
//! accident. Refusing the whole range explicitly says so on purpose.
//!
//! ## What this does not do
//!
//! A seccomp filter cannot read memory. It sees the call's arguments as
//! integers, so it can say "no `openat` at all" but never "no `openat` outside
//! this directory": the path is a pointer, and following it would race with
//! another thread rewriting what it points at. That is why the sandbox is
//! built around a renderer that needs no files rather than around a filter that
//! tries to police which files it opens.
//!
//! The exception is a **file descriptor**, which is an integer and not a
//! pointer, and so is the one argument a filter can usefully compare. `Rule`
//! carries that comparison, and `write` is what needs it: the child inherits
//! every descriptor the calling program had open, so permitting `write` on all
//! of them would let a renderer subverted by a malicious document put
//! attacker-controlled bytes into a connection the parent already had. The
//! descriptor has to be a constant for the filter to compare it, which is what
//! `reply_fd` and the `dup3` in front of the filter are for.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const BPF = linux.BPF;
const SECCOMP = linux.SECCOMP;
const testing = std.testing;

/// One classic-BPF instruction: the kernel's `struct sock_filter`.
pub const Insn = extern struct {
    code: u16,
    /// Instructions to skip when the comparison is true.
    jt: u8,
    /// Instructions to skip when it is false.
    jf: u8,
    k: u32,
};

/// `struct sock_fprog`, the thing handed to `seccomp(2)`.
pub const Program = extern struct {
    len: u16,
    filter: [*]const Insn,
};

/// Bit 30 of a system call number marks the x86-64 x32 ABI.
const x32_bit: u32 = 0x40000000;

/// How much of the system call surface the decoder is allowed.
pub const Profile = enum {
    /// What a decoder that has already been handed its input and its output
    /// buffer can possibly need, and nothing else: report the result, and
    /// stop.
    ///
    /// This is the point of the whole exercise. The decoders in this library
    /// are pure functions over memory, so a decoder that is working correctly
    /// makes no system calls at all, and one that has been subverted into
    /// opening a file, connecting to a host or spawning a program dies at the
    /// attempt rather than succeeding at it.
    ///
    /// The cost is that a decoder needing memory beyond the buffer it was
    /// given cannot ask for it — there is no `mmap` and no `brk` — and that a
    /// decoder which *aborts* dies of the filter rather than of the abort,
    /// since `abort` is a signal a process sends to itself and sending it is a
    /// system call. The parent then reports `SandboxViolation` for what was
    /// really a panic. Both mean the same thing, that there is a bug in the
    /// decoder, which is why conflating them is tolerable — but `permissive`
    /// tells them apart.
    strict,

    /// Also the memory and signal calls a Zig runtime makes: enough that a
    /// decoder using a general-purpose allocator works rather than being
    /// confined to the buffer it was handed, and that a panic reports as
    /// `DecoderCrashed` rather than as a filter violation.
    ///
    /// Still no file of any kind, no network, no `execve`, no `ptrace`, no
    /// creating a process. A decoder cannot read `/etc/passwd` under this
    /// profile any more than under `strict`.
    ///
    /// What it does not buy is a stack trace. Printing one means reading the
    /// executable's debug info, and that is a file; the panic *message* is
    /// written to the inherited standard error before the trace is attempted,
    /// so it is seen, and then the process dies on the first `openat`. Making
    /// the trace work would mean opening files, at which point there is not
    /// much sandbox left.
    permissive,

    /// The rules this profile is made of: every call it permits, and for one
    /// of them the only descriptor it may be used on.
    pub fn rules(comptime self: Profile) []const Rule {
        comptime {
            var out: []const Rule = &.{};
            for (self.syscalls()) |sys| out = out ++ &[_]Rule{.{ .sys = sys }};

            // Writing the reply, which is the only thing the child has to
            // say. Under `strict` it may say it down one descriptor and no
            // other: the child inherits everything the parent had open, and a
            // renderer that cannot *open* a socket can still write to one
            // that was already there.
            //
            // `permissive` leaves `write` alone, because its whole purpose is
            // to let a panic reach the standard error the child inherited and
            // so tell a crash from a filter violation.
            out = out ++ switch (self) {
                .strict => &[_]Rule{.{ .sys = .write, .fd = reply_fd }},
                .permissive => &[_]Rule{.{ .sys = .write }},
            };
            return out;
        }
    }

    /// The calls this profile permits with no condition attached, in the
    /// order the filter tests them.
    pub fn syscalls(comptime self: Profile) []const linux.SYS {
        const strict_set = &[_]linux.SYS{
            // Leaving, both spellings: `exit_group` is what a Zig program
            // exits with, and `exit` is what a bare thread would.
            .exit_group,
            .exit,
            // Returning from a signal handler. Never reached in an ordinary
            // decode, and the process cannot be killed cleanly without it if
            // one is ever delivered.
            .rt_sigreturn,
        };
        return switch (self) {
            .strict => strict_set,
            .permissive => strict_set ++ named(&.{
                // Memory: what a general-purpose allocator asks for, so that
                // a codec is not confined to the fixed buffer it was handed.
                "mmap",            "mmap2",   "munmap",        "mremap",
                "mprotect",        "madvise", "brk",
                // Signals: what it takes to abort cleanly, so that a panic
                // arrives at the parent as a crash and not as a violation.
                          "getpid",
                "gettid",          "tgkill",  "rt_sigaction",  "rt_sigprocmask",
                "sigaltstack",
                // Odds and ends a runtime start-up may still be finishing.
                    "futex",   "clock_gettime", "getrandom",
                "restart_syscall",
            }),
        };
    }
};

/// The descriptor a child writes its reply to.
///
/// Fixed, and that is the point. A seccomp filter is built at compile time and
/// compares constants, so the descriptor it is to permit has to be one -- and
/// the number `pipe2` hands out is not. The child therefore moves the reply
/// pipe onto this number with `dup3` before installing the filter, which it
/// may do freely because at that moment there is no filter to stop it.
///
/// Three, because nought, one and two are the standard streams and the child
/// inherits them. z2dimg, which this module comes from, uses four: it has a
/// second pipe for acknowledging streamed frames, and that one takes three.
/// Nothing here streams, so nothing here needs it.
pub const reply_fd: u32 = 3;

/// One entry in a filter: a call, and optionally the only value its first
/// argument may hold.
pub const Rule = struct {
    sys: linux.SYS,

    /// The value `args[0]` must equal, or null to permit any arguments.
    ///
    /// Only a descriptor is worth putting here, and that is a limitation of
    /// seccomp rather than of this type: a filter sees arguments as integers
    /// and cannot follow a pointer, so it can say "no `openat` at all" and
    /// never "no `openat` outside this directory". A descriptor *is* an
    /// integer, which makes it the one argument a filter can usefully police.
    fd: ?u32 = null,

    /// How many instructions this rule compiles to.
    fn len(self: Rule) usize {
        return if (self.fd == null) 1 else 6;
    }
};

/// The system calls of `names` that exist on this architecture.
///
/// Which calls a kernel has is not the same everywhere: aarch64 has no `open`
/// and no `fstat`, x86-64 has no `mmap2`. Naming them as strings and asking
/// whether each exists is what lets one list describe a profile on every
/// target, instead of one list per target drifting apart from the others.
fn named(comptime names: []const []const u8) []const linux.SYS {
    comptime {
        var out: []const linux.SYS = &.{};
        for (names) |name| {
            if (@hasField(linux.SYS, name)) out = out ++ &[_]linux.SYS{@field(linux.SYS, name)};
        }
        return out;
    }
}

/// Set in an `AUDIT_ARCH_*` token when the ABI is 64-bit.
const audit_64bit: u32 = 0x80000000;
/// Set when it is little-endian.
const audit_le: u32 = 0x40000000;

/// The `AUDIT_ARCH_*` token for the target being compiled for, or zero if it
/// is one this module has no token for.
///
/// Written out rather than taken from `std.os.linux.AUDIT.ARCH.current`, which
/// cannot be referenced at all in Zig 0.16.0: the enum it belongs to names an
/// ELF machine, `EM_FRV`, that `std.elf.EM` does not have, so evaluating the
/// enum is a compile error whichever member is wanted. The values are
/// mechanical anyway — the ELF machine number, with bit 31 set for a 64-bit
/// ABI and bit 30 for a little-endian one — and the whole filter turns on
/// getting this right, so having it here where it can be read is no loss.
const audit_arch: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 62 | audit_64bit | audit_le, // EM_X86_64
    .aarch64 => 183 | audit_64bit | audit_le, // EM_AARCH64
    .aarch64_be => 183 | audit_64bit,
    .riscv64 => 243 | audit_64bit | audit_le, // EM_RISCV
    .loongarch64 => 258 | audit_64bit | audit_le, // EM_LOONGARCH
    .powerpc64 => 21 | audit_64bit, // EM_PPC64
    .powerpc64le => 21 | audit_64bit | audit_le,
    .s390x => 22 | audit_64bit, // EM_S390, and big-endian
    .mips64 => 8 | audit_64bit, // EM_MIPS
    .mips64el => 8 | audit_64bit | audit_le,
    .sparc64 => 43 | audit_64bit, // EM_SPARCV9
    else => 0,
};

/// Whether a filter can be built for the architecture being compiled for.
///
/// A filter is architecture-independent apart from two things: the token it
/// compares `seccomp_data.arch` against, and the x32 range that only x86-64
/// has. So what this comes down to is whether `audit_arch` knows this target.
pub const supported = builtin.os.tag == .linux and @bitSizeOf(usize) == 64 and audit_arch != 0;

/// The filter for a profile, assembled at compile time.
///
/// Returns an array rather than a slice so that it can live in the caller's
/// frame: `seccomp(2)` is handed a pointer to the instructions, and after
/// `fork` in a process that may have had threads there is nothing to be
/// allocated from.
pub fn build(comptime profile: Profile) [programLen(profile)]Insn {
    comptime {
        const rules = profile.rules();
        const arch_check_len = 2;
        const x32_check_len: usize = if (builtin.cpu.arch == .x86_64) 2 else 1;
        var body_len: usize = 0;
        for (rules) |rule| body_len += rule.len();
        // Where the two `ret` instructions end up.
        const kill_at = arch_check_len + x32_check_len + body_len;

        // Which half of an eight-byte argument holds the low word. A filter
        // loads four bytes at a time, and which four are the ones that matter
        // is the target's business.
        const args_at = @offsetOf(SECCOMP.data, "arg0");
        const little = builtin.cpu.arch.endian() == .little;
        const arg0_lo: u32 = args_at + (if (little) 0 else 4);
        const arg0_hi: u32 = args_at + (if (little) 4 else 0);

        var insns: [programLen(profile)]Insn = undefined;
        var i: usize = 0;

        // The architecture, and nothing further if it is not ours.
        insns[i] = ld(@offsetOf(SECCOMP.data, "arch"));
        i += 1;
        insns[i] = jeq(audit_arch, 0, @intCast(kill_at - (i + 1)));
        i += 1;

        insns[i] = ld(@offsetOf(SECCOMP.data, "nr"));
        i += 1;

        if (builtin.cpu.arch == .x86_64) {
            // Anything at or above the x32 bit is the other ABI.
            insns[i] = jge(x32_bit, @intCast(kill_at - (i + 1)), 0);
            i += 1;
        }

        for (rules) |rule| {
            const fd = rule.fd orelse {
                // A match jumps to the `ret #ALLOW` that follows the kill.
                insns[i] = jeq(@intFromEnum(rule.sys), @intCast(kill_at + 1 - (i + 1)), 0);
                i += 1;
                continue;
            };

            // A rule with a condition. The call number is loaded again first,
            // because the instructions below leave an argument in the
            // accumulator and every rule has to start from the same place --
            // which also means one of these may sit anywhere in the chain
            // rather than only at the end of it.
            insns[i] = ld(@offsetOf(SECCOMP.data, "nr"));
            i += 1;
            // Not this call: step over the four instructions that test it.
            insns[i] = jeq(@intFromEnum(rule.sys), 0, 4);
            i += 1;
            // The top half of the argument has to be zero. The kernel narrows
            // a descriptor to `unsigned int` and would ignore anything up
            // there, but a filter that looked at half a number and permitted
            // the call would be one whose reasoning did not survive being
            // written down.
            insns[i] = ld(arg0_hi);
            i += 1;
            insns[i] = jeq(0, 0, @intCast(kill_at - (i + 1)));
            i += 1;
            insns[i] = ld(arg0_lo);
            i += 1;
            insns[i] = jeq(fd, @intCast(kill_at + 1 - (i + 1)), @intCast(kill_at - (i + 1)));
            i += 1;
        }

        insns[i] = ret(SECCOMP.RET.KILL_PROCESS);
        i += 1;
        insns[i] = ret(SECCOMP.RET.ALLOW);
        i += 1;

        std.debug.assert(i == insns.len);
        return insns;
    }
}

/// How many instructions `build` produces, which the return type needs before
/// the body has run.
pub fn programLen(comptime profile: Profile) usize {
    comptime {
        const x32 = if (builtin.cpu.arch == .x86_64) @as(usize, 1) else 0;
        var body: usize = 0;
        for (profile.rules()) |rule| body += rule.len();
        return 2 + 1 + x32 + body + 2;
    }
}

/// `ld [k]`: a word-sized absolute load out of `struct seccomp_data`, which is
/// the only addressing mode a seccomp filter is allowed.
fn ld(offset: u32) Insn {
    return .{ .code = BPF.LD | BPF.W | BPF.ABS, .jt = 0, .jf = 0, .k = offset };
}

/// `jeq #k, jt, jf`
fn jeq(k: u32, jt: u8, jf: u8) Insn {
    return .{ .code = BPF.JMP | BPF.JEQ | BPF.K, .jt = jt, .jf = jf, .k = k };
}

/// `jge #k, jt, jf`
fn jge(k: u32, jt: u8, jf: u8) Insn {
    return .{ .code = BPF.JMP | BPF.JGE | BPF.K, .jt = jt, .jf = jf, .k = k };
}

/// `ret #k`
fn ret(k: u32) Insn {
    return .{ .code = BPF.RET | BPF.K, .jt = 0, .jf = 0, .k = k };
}

/// Errors from locking a process down.
pub const InstallError = error{
    /// `PR_SET_NO_NEW_PRIVS` was refused, so a filter cannot be installed:
    /// without it the kernel requires `CAP_SYS_ADMIN` to install one, since a
    /// filter that could hide system calls from a setuid program would be a
    /// way to attack it.
    NoNewPrivsRefused,
    /// The kernel refused the filter. Either seccomp is not built into it, or
    /// the program is malformed — which, since it is assembled at compile
    /// time from a fixed shape, would be a bug here.
    FilterRefused,
};

/// Installs the filter on the calling thread, irreversibly.
///
/// Must be called from the child after `fork` and before anything is decoded.
/// Both of the system calls it makes are on the allowlist of neither profile,
/// which is fine and deliberate: the filter is not in force until the second
/// of them returns.
pub fn install(comptime profile: Profile) InstallError!void {
    // Every filter needs this first, and it is a one-way door of its own: a
    // process that has set it cannot gain privileges through `execve` again.
    if (linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0) != 0) {
        return error.NoNewPrivsRefused;
    }

    const insns = comptime build(profile);
    const prog: Program = .{ .len = @intCast(insns.len), .filter = &insns };
    if (linux.seccomp(SECCOMP.SET_MODE_FILTER, 0, &prog) != 0) {
        return error.FilterRefused;
    }
}

test "the program is the shape the layout promises" {
    if (!supported) return error.SkipZigTest;

    const insns = comptime build(.strict);
    try testing.expectEqual(comptime programLen(.strict), insns.len);

    // First an architecture check, then a load of the call number.
    try testing.expectEqual(@as(u16, BPF.LD | BPF.W | BPF.ABS), insns[0].code);
    try testing.expectEqual(@as(u32, @offsetOf(SECCOMP.data, "arch")), insns[0].k);
    try testing.expectEqual(@as(u16, BPF.JMP | BPF.JEQ | BPF.K), insns[1].code);
    try testing.expectEqual(@as(u32, @offsetOf(SECCOMP.data, "nr")), insns[2].k);

    // And two verdicts at the end, refusing before allowing.
    try testing.expectEqual(@as(u32, SECCOMP.RET.KILL_PROCESS), insns[insns.len - 2].k);
    try testing.expectEqual(@as(u32, SECCOMP.RET.ALLOW), insns[insns.len - 1].k);
}

test "every jump lands on a verdict and never off the end" {
    if (!supported) return error.SkipZigTest;

    inline for (.{ Profile.strict, Profile.permissive }) |profile| {
        const insns = comptime build(profile);
        const allow_at = insns.len - 1;
        const kill_at = insns.len - 2;

        for (insns, 0..) |insn, i| {
            if (insn.code & 0x07 != BPF.JMP) continue;
            // Classic BPF counts a jump from the instruction after it.
            const on_true = i + 1 + insn.jt;
            const on_false = i + 1 + insn.jf;
            try testing.expect(on_true <= allow_at);
            try testing.expect(on_false <= allow_at);
            // Nothing may fall into the middle of the allowlist by jumping;
            // a jump either skips to a verdict or continues to the next test.
            try testing.expect(on_true == allow_at or on_true == kill_at or insn.jt == 0);
            try testing.expect(on_false == allow_at or on_false == kill_at or insn.jf == 0);
        }
    }
}

test "the strict profile allows only what a pure renderer needs" {
    const allowed = comptime Profile.strict.rules();
    try testing.expectEqual(@as(usize, 4), allowed.len);
    for (allowed) |rule| switch (rule.sys) {
        // And `write` only down the reply pipe. The child inherits every
        // descriptor the parent had open, so a renderer that cannot open a
        // socket can still write to one that was already there -- which is
        // the hole this closes.
        .write => try testing.expectEqual(@as(?u32, reply_fd), rule.fd),
        .exit_group, .exit, .rt_sigreturn => try testing.expectEqual(@as(?u32, null), rule.fd),
        // Anything else would need justifying in the doc comment above, and
        // this is where that gets noticed.
        else => return error.UnexpectedSyscallInStrictProfile,
    };
}

test "only the permissive profile lets a child write anywhere" {
    // The panic message goes to the standard error the child inherited, which
    // is what tells a crash from a filter violation -- and is exactly the
    // freedom the strict profile must not have.
    for (comptime Profile.strict.rules()) |rule| {
        if (rule.sys == .write) try testing.expectEqual(@as(?u32, reply_fd), rule.fd);
    }
    var permissive_write_is_free = false;
    for (comptime Profile.permissive.rules()) |rule| {
        if (rule.sys == .write and rule.fd == null) permissive_write_is_free = true;
    }
    try testing.expect(permissive_write_is_free);
}

test "a rule with a descriptor compiles to a longer filter" {
    // Six instructions rather than one, and the filter still ends on a
    // verdict: the generic checks below walk every jump, so this only has to
    // pin the size down so that a change to the encoding is noticed here.
    const plain: Rule = .{ .sys = .exit_group };
    const conditional: Rule = .{ .sys = .write, .fd = reply_fd };
    try testing.expectEqual(@as(usize, 1), plain.len());
    try testing.expectEqual(@as(usize, 6), conditional.len());
    // Both are comptime-only: their bodies are a `comptime` block, so a
    // runtime call cannot take the value back out.
    try testing.expectEqual(
        comptime programLen(.strict),
        (comptime build(.strict)).len,
    );
}
test "the permissive profile is a superset of the strict one" {
    const strict = comptime Profile.strict.syscalls();
    const permissive = comptime Profile.permissive.syscalls();
    try testing.expect(permissive.len > strict.len);
    for (strict) |s| {
        var found = false;
        for (permissive) |p| {
            if (p == s) found = true;
        }
        try testing.expect(found);
    }
}

test "no profile ever permits the calls the sandbox exists to prevent" {
    // The list this sandbox is for. If one of these ever appears in a profile,
    // the profile has stopped being a sandbox and this says so.
    const forbidden = comptime named(&.{
        "execve", "execveat", "ptrace", "socket",   "connect",
        "open",   "openat2",  "unlink", "unlinkat", "clone",
        "fork",   "vfork",    "kill",   "setuid",   "chdir",
        "chroot", "mount",    "reboot", "bpf",      "process_vm_readv",
    });
    inline for (.{ Profile.strict, Profile.permissive }) |profile| {
        for (comptime profile.syscalls()) |allowed| {
            for (forbidden) |bad| {
                try testing.expect(allowed != bad);
            }
        }
    }
}
