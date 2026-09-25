// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Run the fuzz targets in `tests/fuzz.zig` against input this makes up.
//!
//! Zig has a fuzzer of its own and those targets are written for it, so the
//! obvious thing to run is `zig build fuzz --fuzz`. With the devshell's
//! patched Zig that now *compiles* — `flake.nix` says what the patch is —
//! and then ends with
//!
//! ```
//! error: step 'run test': corrupted coverage file: pcs_len was zero
//! ```
//!
//! because nothing in 0.16.0 populates the table of program counters, however
//! the modules are built. A fuzzer with no coverage is a random number
//! generator, so this is one written down honestly: it makes an input, hands
//! it to a target, and says so when one comes back with an error.
//!
//! ```console
//! $ zig build fuzz-run                                # a minute of each
//! $ zig build fuzz-run -- --seconds 300 --target render
//! $ zig build fuzz-run -- --seed 12345                # exactly again
//! $ zig build fuzz-run -- --input fuzz-findings/x.bin --target render
//! ```
//!
//! # What an input is
//!
//! Not a file: a `std.testing.Smith` reads it as a stream of answers, and the
//! encoding is worth knowing before writing a generator for it.
//!
//! * `smith.slice(buf)` reads **four** bytes as a little-endian `u32` length,
//!   then that many bytes of content. A length larger than `buf.len` is not
//!   reduced into range — it yields an *empty* slice. So a string of random
//!   bytes gives almost every target nothing at all to parse, and a generator
//!   that does not write a plausible length is fuzzing nothing.
//! * `smith.value(T)` reads **eight** bytes as a little-endian `u64` and, if
//!   that value is outside the asked-for range, returns the range's minimum
//!   rather than reducing it. For an `i64` every value is in range; for a
//!   `bool` only 0 and 1 are, so random bytes make it false every time.
//!
//! Every target here begins with a `slice`, so `makeInput` writes two
//! length-prefixed chunks — two because a target may ask for two slices, and
//! the second would otherwise only ever see the random tail — and each chunk
//! is a mutation of one of the target's own seeds. That corpus is the whole of
//! what stands in for coverage feedback. A reply, a command and a listing line
//! are all mostly printable ASCII with a little punctuation, and random bytes
//! are none of that: starting from something that already parses is what gets
//! past the first character.
//!
//! The length is capped at the target's own buffer size, which `Target` has to
//! carry for the reason above: a length larger than the buffer yields nothing
//! rather than a truncation, and getting it wrong is silent — the target runs,
//! reports no failure, and was handed the empty string every time.
//!
//! # The watchdog
//!
//! Nothing here should be able to loop — every parser walks a bounded input
//! once — but "should" is what a fuzzer is for. A thread watches the clock,
//! and an iteration that outlasts `--timeout` seconds is reported as a hang
//! with the input that caused it. There is no way to unwind out of it, so that
//! ends the run.

const std = @import("std");
const targets = @import("fuzz_targets");

const Smith = std.testing.Smith;

/// Milliseconds on a clock that only goes forwards while the machine is up.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// What the watchdog needs to see, written before each iteration begins.
const Watch = struct {
    /// When the running iteration started, or zero between iterations.
    started_ms: std.atomic.Value(i64) = .init(0),
    /// The input it is running, which is what a hang has to report.
    input: []const u8 = &.{},
    target: []const u8 = "",
    timeout_s: u32 = 10,
    dir: []const u8 = "",
};

var watch: Watch = .{};

/// Panics print the input that caused them, and write it where it can be fed
/// back.
///
/// Without this a panic is the one kind of failure that loses its input: the
/// loop reports an *error* by writing the bytes to `fuzz-findings` and going
/// on, but a panic unwinds nothing and takes the process with it, so the only
/// record is a stack trace and no way to reproduce it. That is the failure
/// most worth keeping, since a panic in a renderer is a crash in whatever
/// opened the file.
pub const panic = std.debug.FullPanic(panicWithInput);

fn panicWithInput(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const input = watch.input;
    if (input.len != 0) {
        // Hex rather than a file. A panic handler has no `Io` to hand and no
        // business making one, and `std.posix` in 0.16 no longer wraps `open`,
        // so what can be done here is print — which is enough:
        //
        //     printf '<hex>' | xxd -r -p > crash.bin
        //     zig build fuzz-run -- --input crash.bin --target <name>
        std.debug.print("\n{s}: panicked on this input, {d} bytes:\n ", .{ watch.target, input.len });
        for (input, 0..) |b, i| {
            if (i != 0 and i % 32 == 0) std.debug.print("\n ", .{});
            std.debug.print("{x:0>2}", .{b});
        }
        std.debug.print("\n\nfeed it back with:\n", .{});
        std.debug.print("  printf '", .{});
        for (input) |b| std.debug.print("\\x{x:0>2}", .{b});
        std.debug.print("' > crash.bin\n", .{});
        std.debug.print("  zig build fuzz-run -- --input crash.bin --target {s}\n\n", .{watch.target});
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two allocators, and they have to be two. The targets are written to run
    // against the testing allocator, which cannot be named outside a test
    // build; this is the same thing by another route, a debug allocator whose
    // outstanding allocations are counted after every input, since a leak is
    // one of the things being fuzzed for. Nothing else may allocate from it --
    // the loop's own buffer would be indistinguishable from a target's leak --
    // so everything here uses the process allocator instead.
    var checked: std.heap.DebugAllocator(.{}) = .init;
    defer _ = checked.deinit();
    targets.backing = checked.allocator();
    const gpa = init.gpa;

    var seconds: u32 = 60;
    var iterations: ?u64 = null;
    var seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Timestamp.now(io, .real).nanoseconds)));
    var only: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var dir: []const u8 = "fuzz-findings";
    var timeout_s: u32 = 10;
    var alloc_fail = false;

    // The allocating form, which is the one that works everywhere: Windows
    // hands a program its command line as one string to be split. The
    // strings it hands out live in it, and are used long after parsing, so
    // it lives to the end.
    var args: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seconds")) {
            seconds = std.fmt.parseInt(u32, args.next() orelse "60", 10) catch 60;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch null;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch seed;
        } else if (std.mem.eql(u8, arg, "--target")) {
            only = args.next();
        } else if (std.mem.eql(u8, arg, "--input")) {
            input_path = args.next();
        } else if (std.mem.eql(u8, arg, "--findings")) {
            dir = args.next() orelse dir;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            timeout_s = std.fmt.parseInt(u32, args.next() orelse "10", 10) catch 10;
        } else if (std.mem.eql(u8, arg, "--alloc-fail")) {
            alloc_fail = true;
        } else {
            std.debug.print(
                \\usage: fuzz [--target NAME] [--seconds N | --iterations N] [--seed S]
                \\            [--timeout S] [--findings DIR] [--input FILE] [--alloc-fail]
                \\
                \\Targets: {s}
                \\
            , .{targetNames()});
            std.process.exit(2);
        }
    }

    watch.timeout_s = timeout_s;
    watch.dir = dir;

    const thread = try std.Thread.spawn(.{}, watchdog, .{io});
    thread.detach();

    // One input, from a file, and nothing else: this is how a finding is
    // looked at again after it has been fixed.
    if (input_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const name = only orelse targets.all[0].name;
        const target = find(name) orelse {
            std.debug.print("no target called {s}; there are: {s}\n", .{ name, targetNames() });
            std.process.exit(2);
        };
        watch.input = bytes;
        watch.target = target.name;
        watch.started_ms.store(nowMs(io), .release);
        target.run(bytes) catch |err| {
            std.debug.print("{s}: {t}\n", .{ target.name, err });
            show(bytes);
            std.process.exit(1);
        };
        std.debug.print("{s}: that input is fine now\n", .{target.name});
        return;
    }

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    std.debug.print("seed {d}\n", .{seed});
    var failures: usize = 0;
    for (targets.all) |target| {
        if (only) |name| if (!std.mem.eql(u8, name, target.name)) continue;
        // A target that opts out of `--alloc-fail` is still run, just without
        // allocations being failed -- skipping it outright would quietly stop
        // fuzzing it at all in that mode. `Target.alloc_fail` says why any
        // target would.
        if (alloc_fail and !target.alloc_fail and only == null) {
            std.debug.print("{s}: allocations not failed (see Target.alloc_fail)\n", .{target.name});
        }

        var runs: u64 = 0;
        const deadline = nowMs(io) + @as(i64, seconds) * 1000;
        while (if (iterations) |n| runs < n else nowMs(io) < deadline) : (runs += 1) {
            try makeInput(gpa, &buffer, random, target);
            watch.input = buffer.items;
            watch.target = target.name;
            watch.started_ms.store(nowMs(io), .release);
            const result = if (alloc_fail and target.alloc_fail)
                runWithFailingAllocations(checked.allocator(), target, buffer.items)
            else
                target.run(buffer.items);
            watch.started_ms.store(0, .release);
            if (checked.detectLeaks() != 0) {
                std.debug.print("\n{s}: leaked\n", .{target.name});
                try report(io, dir, target.name, buffer.items);
                std.process.exit(1);
            }
            result catch |err| {
                failures += 1;
                std.debug.print("\n{s}: {t}\n", .{ target.name, err });
                try report(io, dir, target.name, buffer.items);
                // Keep going: one shape of failure is usually many inputs, and
                // stopping at the first says less than a handful does.
                if (failures >= 10) {
                    std.debug.print("ten failures; stopping\n", .{});
                    std.process.exit(1);
                }
            };
        }
        std.debug.print("{s}: {d} runs\n", .{ target.name, runs });
    }
    if (failures != 0) std.process.exit(1);
}

/// Runs one input many times over, failing a different allocation each time.
///
/// A different kind of test from feeding a parser strange bytes, and one that
/// strange bytes cannot reach: it exercises the *error paths*. Every `try` on
/// an allocation is a branch that unwinds, and every `errdefer` on the way out
/// is a line that has usually never run. A leak or a double free there is
/// invisible to ordinary fuzzing, because ordinary fuzzing never runs out of
/// memory.
///
/// The only acceptable outcomes are success and `error.OutOfMemory`: a
/// renderer that turns a failed allocation into `InvalidNumber` has swallowed
/// a fact about the machine and reported it as a fact about the document.
///
/// Stops when an iteration completes without inducing a failure, which means
/// the input needed fewer allocations than that and every one has now been
/// tried.
fn runWithFailingAllocations(
    checked: std.mem.Allocator,
    target: targets.Target,
    input: []const u8,
) anyerror!void {
    var fail_at: usize = 0;
    while (fail_at < 512) : (fail_at += 1) {
        var failing: std.testing.FailingAllocator = .init(checked, .{ .fail_index = fail_at });
        targets.backing = failing.allocator();
        defer targets.backing = checked;

        target.run(input) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => |e| return e,
        };
        if (!failing.has_induced_failure) return;
    }
}

fn find(name: []const u8) ?targets.Target {
    for (targets.all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn targetNames() []const u8 {
    comptime var names: []const u8 = "";
    inline for (targets.all, 0..) |t, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ t.name;
    }
    return names;
}

/// Make the next input: two length-prefixed chunks and a random tail.
///
/// Two, because a target may ask for two slices, and the second would
/// otherwise only ever see whatever random bytes happened to follow. A target
/// that asks for one slice reads the first chunk and leaves the rest for its
/// `value` calls.
///
/// The length is capped at `target.content_max` rather than at some number
/// chosen here, because `Smith.slice` answers a length larger than its buffer
/// with an *empty* slice rather than a truncated one. Getting that wrong is
/// silent: the target runs, reports no failure, and has been handed nothing.
fn makeInput(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    random: std.Random,
    target: targets.Target,
) !void {
    out.clearRetainingCapacity();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);

    for (0..2) |_| {
        content.clearRetainingCapacity();
        if (target.corpus.len == 0 or random.uintLessThan(u8, 8) == 0) {
            // Sometimes nothing but noise, so that the shapes nobody thought
            // of are reachable at all.
            const len = random.uintLessThan(usize, target.content_max);
            try content.ensureUnusedCapacity(gpa, len);
            for (0..len) |_| content.appendAssumeCapacity(random.int(u8));
        } else {
            const seed = target.corpus[random.uintLessThan(usize, target.corpus.len)];
            try content.appendSlice(gpa, seed);
            const rounds = 1 + random.uintLessThan(usize, 8);
            for (0..rounds) |_| try mutate(gpa, &content, random, target.interesting);

            // Put whatever consistency the format needs back. Not
            // every time: a seventh of mutants are left broken, because
            // refusing a corrupt file is a path worth exercising too — it is
            // just not worth exercising ninety-seven percent of the time,
            // which is what happens without this.
            if (target.repair) |repair| {
                if (random.uintLessThan(u8, 8) != 0) repair(content.items);
            }
        }
        if (content.items.len > target.content_max) {
            content.shrinkRetainingCapacity(target.content_max);
        }

        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(content.items.len), .little);
        try out.appendSlice(gpa, &length);
        try out.appendSlice(gpa, content.items);
    }

    // And a tail, for whatever a target asks after its slices: an `i64` reads
    // eight bytes from here.
    const tail = 16 + random.uintLessThan(usize, 48);
    try out.ensureUnusedCapacity(gpa, tail);
    for (0..tail) |_| out.appendAssumeCapacity(random.int(u8));
}

fn mutate(
    gpa: std.mem.Allocator,
    content: *std.ArrayList(u8),
    random: std.Random,
    interesting: []const u8,
) !void {
    if (content.items.len == 0) {
        try content.append(gpa, random.int(u8));
        return;
    }
    switch (random.uintLessThan(u8, 8)) {
        // A byte, replaced. The commonest useful mutation, and the one that
        // turns a reply code into a nearly-a-reply-code.
        0, 1 => content.items[random.uintLessThan(usize, content.items.len)] = random.int(u8),
        // A byte, replaced by one of the ones this protocol is made of.
        2, 3 => content.items[random.uintLessThan(usize, content.items.len)] =
            interesting[random.uintLessThan(usize, interesting.len)],
        4 => try content.insert(gpa, random.uintLessThan(usize, content.items.len), random.int(u8)),
        5 => try content.insert(
            gpa,
            random.uintLessThan(usize, content.items.len),
            interesting[random.uintLessThan(usize, interesting.len)],
        ),
        // A run on the end, which is how a line grows a second field.
        6 => for (0..1 + random.uintLessThan(usize, 16)) |_| {
            try content.append(gpa, interesting[random.uintLessThan(usize, interesting.len)]);
        },
        else => _ = content.orderedRemove(random.uintLessThan(usize, content.items.len)),
    }
}

/// Print a failing input and write it where it can be fed back.
fn report(io: std.Io, dir: []const u8, target: []const u8, input: []const u8) !void {
    show(input);

    var name: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "{s}/{s}-{x:0>16}.bin", .{
        dir,
        target,
        std.hash.Wyhash.hash(0, input),
    }) catch return;

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("(could not write {s}: {t})\n", .{ path, err });
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, input) catch {};
    std.debug.print(
        "written to {s}, and `--input {s} --target {s}` runs it again\n",
        .{ path, path, target },
    );
}

/// The input, in hex, and then what a target actually reads out of it.
///
/// The second half earns its lines: an input is a stream of answers rather
/// than a file, so the bytes alone do not say what the parser was given, and
/// that is the first thing anybody wants to see.
fn show(input: []const u8) void {
    std.debug.print("input, {d} bytes:\n ", .{input.len});
    for (input, 0..) |b, i| {
        if (i != 0 and i % 32 == 0) std.debug.print("\n ", .{});
        std.debug.print(" {x:0>2}", .{b});
    }
    std.debug.print("\n", .{});

    var smith: Smith = .{ .in = input };
    var buffer: [4096]u8 = undefined;
    const content = buffer[0..smith.slice(&buffer)];
    std.debug.print("which reads as {d} bytes:\n ", .{content.len});
    for (content, 0..) |b, i| {
        if (i != 0 and i % 32 == 0) std.debug.print("\n ", .{});
        std.debug.print(" {x:0>2}", .{b});
    }
    std.debug.print("\n", .{});
}

/// Watch for an iteration that never ends.
fn watchdog(io: std.Io) void {
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch return;
        const started = watch.started_ms.load(.acquire);
        if (started == 0) continue;
        const elapsed = nowMs(io) - started;
        if (elapsed < @as(i64, watch.timeout_s) * 1000) continue;

        std.debug.print(
            "\n{s}: no answer after {d} seconds, which is a hang\n",
            .{ watch.target, @divTrunc(elapsed, 1000) },
        );
        show(watch.input);
        var name: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&name, "{s}/{s}-hang-{x:0>16}.bin", .{
            watch.dir,
            watch.target,
            std.hash.Wyhash.hash(0, watch.input),
        }) catch std.process.exit(3);
        std.Io.Dir.cwd().createDirPath(io, watch.dir) catch {};
        if (std.Io.Dir.cwd().createFile(io, path, .{})) |file| {
            defer file.close(io);
            file.writeStreamingAll(io, watch.input) catch {};
            std.debug.print("written to {s}\n", .{path});
        } else |_| {}
        std.process.exit(3);
    }
}
