// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The SVG path data mini-language -- the `d` attribute -- as `z2d.Path`
//! operations.
//!
//! This is a complete implementation of the grammar in SVG 1.1 §8.3. A survey
//! of all 7,447 Material Design Icons finds every command in use, `A` fifteen
//! thousand times, and both the absolute and the relative spelling of each.
//!
//! Three things about z2d shape the code here, and each of them is a silently
//! wrong picture rather than an error if it is got wrong:
//!
//! * **`z2d.painter.fill` refuses an unclosed subpath** with
//!   `error.PathNotClosed`. SVG closes every subpath implicitly when filling,
//!   whether or not the data said `Z`, so `close` is emitted at the end of
//!   each subpath here rather than left to the caller.
//! * **The current transformation matrix is applied when a point is added**,
//!   not when the path is filled. `Path.transformation` therefore has to carry
//!   the viewBox-to-pixels scale before the first `moveTo`, which is what
//!   `document.buildPathIn` does.
//! * **z2d's own `arc` is circular**, takes a centre and two angles rather
//!   than SVG's endpoint parameterization, and draws a connecting line from
//!   the current point if there is one. None of that is what `A` means, so
//!   arcs go through `arc.zig` and come back as cubics.
//!
//! ## Bounding the work
//!
//! A `d` attribute is a string an attacker writes, and every byte of it can
//! ask for another path node -- an arc alone can ask for four. `Options.max_nodes`
//! is the ceiling, because a path that has grown past any plausible drawing is
//! a denial of service rather than a picture, and the rasterizer's cost is
//! superlinear in the node count.

const std = @import("std");
const z2d = @import("z2d");

const arc = @import("arc.zig");

pub const Error = error{
    /// The data did not begin with a `moveto`, which §8.3.2 requires.
    ExpectedMoveTo,
    /// A command letter that is not one of `MmLlHhVvCcSsQqTtAaZz`.
    UnknownCommand,
    /// A command ran out of numbers part way through its argument sequence.
    TruncatedCommand,
    /// A number that `std.fmt.parseFloat` would not take, or one that is not
    /// finite. An infinity or a NaN reaching z2d is a hang or a panic rather
    /// than a wrong picture, so it is refused here.
    InvalidNumber,
    /// An arc flag that was neither `0` nor `1`. §8.3.8's grammar allows only
    /// those two, unseparated, and reading a `1` out of a `15` would silently
    /// shift every following argument.
    InvalidFlag,
    /// The data asked for more path nodes than `Options.max_nodes` permits.
    PathTooComplex,
};

pub const BuildError = Error || std.mem.Allocator.Error || z2d.Path.Error;

/// How much path a caller is willing to pay for.
pub const Options = struct {
    /// The most `z2d.Path` nodes this `d` may produce.
    ///
    /// Nodes rather than bytes, because the two are not proportional: `a` with
    /// a large sweep produces four cubics from a dozen characters, and
    /// repeating it is the cheapest way to write an expensive path. The
    /// default is far above any real drawing -- the most complex Material
    /// Design Icon has about six hundred nodes -- and far below what would
    /// keep a rasterizer busy for minutes.
    max_nodes: usize = 1 << 20,

    /// Whether to close a subpath the data left open.
    ///
    /// SVG fills as though every subpath were closed and z2d refuses to fill
    /// one that is not, so filling wants this on. **Stroking wants it off**:
    /// a stroked open subpath is capped at its two ends, and closing it would
    /// draw a line back to the start that the document never asked for. It is
    /// the one place where the same `d` has to become two different node sets,
    /// which is why it is a decision here rather than an invariant.
    ///
    /// An explicit `Z` closes either way -- that is the data saying so.
    close_subpaths: bool = true,

    /// Nothing is refused. For a program drawing files it produced itself.
    pub const unlimited: Options = .{ .max_nodes = std.math.maxInt(usize) };
};

/// Parse `d` and append it to `path`.
///
/// `path.transformation` is honoured, so set the viewBox scale on it first.
/// Every subpath is closed, so the result can be handed straight to
/// `z2d.painter.fill`.
pub fn build(
    path: *z2d.Path,
    alloc: std.mem.Allocator,
    d: []const u8,
    opts: Options,
) BuildError!void {
    var p: Scanner = .{ .src = d };
    var state: State = .{
        .path = path,
        .alloc = alloc,
        .close_subpaths = opts.close_subpaths,
        // The budget is what this call may *add*, so a caller appending a
        // second path to the same `z2d.Path` is not refused for the first
        // one's nodes.
        .node_ceiling = std.math.add(usize, path.nodes.items.len, opts.max_nodes) catch
            std.math.maxInt(usize),
    };

    p.skipWsAndCommas();
    if (p.done()) return;

    // §8.3.2: the first command must be a moveto. Anything else has no
    // current point to work from, and z2d would answer `error.NoCurrentPoint`
    // from somewhere much less informative than here.
    if (p.peek() != 'M' and p.peek() != 'm') return error.ExpectedMoveTo;

    var command: u8 = 0;
    while (true) {
        p.skipWsAndCommas();
        if (p.done()) break;

        const c = p.peek();
        if (isCommand(c)) {
            command = c;
            p.pos += 1;
            p.skipWsAndCommas();
        } else if (command == 0) {
            return error.UnknownCommand;
        } else if (!isNumberStart(c)) {
            return error.UnknownCommand;
        } else {
            // A repeated argument sequence with the command letter left out.
            // §8.3.2 makes a repeated `moveto` mean `lineto`, which is the one
            // place the implicit command is not simply the previous one.
            command = switch (command) {
                'M' => 'L',
                'm' => 'l',
                // §8.3.3's `closepath` takes no arguments, so there is no
                // argument sequence for a bare number to repeat. Carrying `Z`
                // forward would run a command that consumes nothing while the
                // number that provoked it is still there, and the loop would
                // never end -- found by the fuzzer, on `M3,9...Z6`.
                'Z', 'z' => return error.UnknownCommand,
                else => command,
            };
        }

        try state.run(&p, command);
    }

    try state.finishSubpath();
}

fn isCommand(c: u8) bool {
    return switch (c) {
        'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z' => true,
        else => false,
    };
}

fn isNumberStart(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.';
}

/// Where the pen is, and what the previous command left behind for `S` and `T`
/// to reflect.
const State = struct {
    path: *z2d.Path,
    alloc: std.mem.Allocator,
    /// The node count this build may not exceed. Absolute rather than a
    /// remaining budget, so that an arc which appends several nodes is caught
    /// by the same check as everything else.
    node_ceiling: usize,
    /// See `Options.close_subpaths`.
    close_subpaths: bool,

    /// The current point, in user units.
    x: f64 = 0,
    y: f64 = 0,
    /// Where the current subpath began, which `Z` returns to.
    start_x: f64 = 0,
    start_y: f64 = 0,
    /// The second control point of the previous cubic, for `S`/`s`.
    cubic_cx: f64 = 0,
    cubic_cy: f64 = 0,
    had_cubic: bool = false,
    /// The control point of the previous quadratic, for `T`/`t`.
    quad_cx: f64 = 0,
    quad_cy: f64 = 0,
    had_quad: bool = false,
    /// Whether there is an open subpath that still needs closing.
    open: bool = false,

    /// Refuses a path that has grown past its budget.
    ///
    /// Checked after each command rather than before, because a command does
    /// not know in advance how many nodes it will add -- an arc's segment
    /// count falls out of the geometry. Overshooting by an arc's worth is
    /// bounded and harmless; overshooting by a megabyte of them is what this
    /// prevents.
    fn checkBudget(self: *const State) Error!void {
        if (self.path.nodes.items.len > self.node_ceiling) return error.PathTooComplex;
    }

    fn run(self: *State, p: *Scanner, command: u8) BuildError!void {
        // Lower case is the relative spelling of every command.
        const rel = std.ascii.isLower(command);
        switch (command) {
            'M', 'm' => {
                const px = try p.number();
                const py = try p.number();
                try self.finishSubpath();
                self.x = if (rel) self.x + px else px;
                self.y = if (rel) self.y + py else py;
                self.start_x = self.x;
                self.start_y = self.y;
                try self.path.moveTo(self.alloc, self.x, self.y);
                self.open = true;
                self.clearReflection();
            },
            'L', 'l' => {
                const px = try p.number();
                const py = try p.number();
                self.x = if (rel) self.x + px else px;
                self.y = if (rel) self.y + py else py;
                try self.path.lineTo(self.alloc, self.x, self.y);
                self.open = true;
                self.clearReflection();
            },
            'H', 'h' => {
                const px = try p.number();
                self.x = if (rel) self.x + px else px;
                try self.path.lineTo(self.alloc, self.x, self.y);
                self.open = true;
                self.clearReflection();
            },
            'V', 'v' => {
                const py = try p.number();
                self.y = if (rel) self.y + py else py;
                try self.path.lineTo(self.alloc, self.x, self.y);
                self.open = true;
                self.clearReflection();
            },
            'C', 'c' => {
                const ox = if (rel) self.x else 0;
                const oy = if (rel) self.y else 0;
                const x1 = ox + try p.number();
                const y1 = oy + try p.number();
                const x2 = ox + try p.number();
                const y2 = oy + try p.number();
                const x3 = ox + try p.number();
                const y3 = oy + try p.number();
                try self.cubic(x1, y1, x2, y2, x3, y3);
            },
            'S', 's' => {
                const ox = if (rel) self.x else 0;
                const oy = if (rel) self.y else 0;
                // §8.3.6: with no preceding cubic, the first control point is
                // the current point.
                const x1 = if (self.had_cubic) 2 * self.x - self.cubic_cx else self.x;
                const y1 = if (self.had_cubic) 2 * self.y - self.cubic_cy else self.y;
                const x2 = ox + try p.number();
                const y2 = oy + try p.number();
                const x3 = ox + try p.number();
                const y3 = oy + try p.number();
                try self.cubic(x1, y1, x2, y2, x3, y3);
            },
            'Q', 'q' => {
                const ox = if (rel) self.x else 0;
                const oy = if (rel) self.y else 0;
                const cx = ox + try p.number();
                const cy = oy + try p.number();
                const px = ox + try p.number();
                const py = oy + try p.number();
                try self.quadratic(cx, cy, px, py);
            },
            'T', 't' => {
                const ox = if (rel) self.x else 0;
                const oy = if (rel) self.y else 0;
                const cx = if (self.had_quad) 2 * self.x - self.quad_cx else self.x;
                const cy = if (self.had_quad) 2 * self.y - self.quad_cy else self.y;
                const px = ox + try p.number();
                const py = oy + try p.number();
                try self.quadratic(cx, cy, px, py);
            },
            'A', 'a' => {
                const rx = try p.number();
                const ry = try p.number();
                const rotation = try p.number();
                const large_arc = try p.flag();
                const sweep = try p.flag();
                const ex = if (rel) self.x + try p.number() else try p.number();
                const ey = if (rel) self.y + try p.number() else try p.number();
                try arc.append(self.path, self.alloc, .{
                    .x1 = self.x,
                    .y1 = self.y,
                    .x2 = ex,
                    .y2 = ey,
                    .rx = rx,
                    .ry = ry,
                    .rotation_deg = rotation,
                    .large_arc = large_arc,
                    .sweep = sweep,
                });
                self.x = ex;
                self.y = ey;
                self.open = true;
                self.clearReflection();
            },
            'Z', 'z' => {
                if (self.open) {
                    try self.path.close(self.alloc);
                    self.open = false;
                }
                // §8.3.3: the current point becomes the start of the subpath
                // that was just closed, so a command following `Z` without an
                // intervening `M` continues from there.
                self.x = self.start_x;
                self.y = self.start_y;
                self.clearReflection();
            },
            else => return error.UnknownCommand,
        }
        try self.checkBudget();
    }

    fn cubic(self: *State, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) BuildError!void {
        try self.path.curveTo(self.alloc, x1, y1, x2, y2, x3, y3);
        self.open = true;
        self.x = x3;
        self.y = y3;
        self.cubic_cx = x2;
        self.cubic_cy = y2;
        self.had_cubic = true;
        self.had_quad = false;
    }

    /// A quadratic lifted to a cubic: the two cubic controls sit two thirds of
    /// the way from each endpoint towards the quadratic's single control.
    fn quadratic(self: *State, cx: f64, cy: f64, px: f64, py: f64) BuildError!void {
        const third = 1.0 / 3.0;
        const x1 = self.x + 2.0 * third * (cx - self.x);
        const y1 = self.y + 2.0 * third * (cy - self.y);
        const x2 = px + 2.0 * third * (cx - px);
        const y2 = py + 2.0 * third * (cy - py);
        try self.path.curveTo(self.alloc, x1, y1, x2, y2, px, py);
        self.open = true;
        self.x = px;
        self.y = py;
        self.quad_cx = cx;
        self.quad_cy = cy;
        self.had_quad = true;
        self.had_cubic = false;
    }

    fn clearReflection(self: *State) void {
        self.had_cubic = false;
        self.had_quad = false;
    }

    /// Close a subpath the data left open, when the caller wants that.
    ///
    /// An explicit `Z` does not come through here; it closes whatever this
    /// says, because that is the document rather than the caller speaking.
    fn finishSubpath(self: *State) BuildError!void {
        if (!self.open) return;
        self.open = false;
        if (!self.close_subpaths) return;
        try self.path.close(self.alloc);
    }
};

/// A scanner over a string of numbers separated by commas and whitespace.
///
/// The separators are commas and whitespace, either, both, or neither --
/// `M3,9H7` and `M 3 9 H 7` and `M3 9H7` are the same path -- so every number
/// reads past whatever precedes it.
///
/// Public because `transform.zig` needs exactly this: SVG's transform list is
/// written in the same number syntax, down to numbers that abut, and a second
/// implementation of `number` is a second place for `.5.5` to be read as one
/// malformed number instead of two good ones.
pub const Scanner = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn done(self: *const Scanner) bool {
        return self.pos >= self.src.len;
    }

    pub fn peek(self: *const Scanner) u8 {
        return self.src[self.pos];
    }

    pub fn skipWsAndCommas(self: *Scanner) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n', ',' => {},
                else => return,
            }
        }
    }

    /// One number of the grammar's `number` production.
    ///
    /// The extent is found here rather than handed to `parseFloat` wholesale,
    /// because the grammar lets numbers abut: `1-2` is two of them, and so is
    /// `.5.5`, which a greedy scan would read as one malformed one.
    pub fn number(self: *Scanner) Error!f64 {
        self.skipWsAndCommas();
        const start = self.pos;

        if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
            self.pos += 1;
        }

        var saw_digit = false;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {
            saw_digit = true;
        }
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {
                saw_digit = true;
            }
        }
        if (!saw_digit) return error.TruncatedCommand;

        // An exponent only counts if it has digits behind it; otherwise the
        // `e` belongs to whatever comes next, which in practice means a
        // malformed path rather than a command letter, but the grammar is
        // clear and this keeps the failure local.
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            const mark = self.pos;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                self.pos += 1;
            }
            var saw_exp_digit = false;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {
                saw_exp_digit = true;
            }
            if (!saw_exp_digit) self.pos = mark;
        }

        const value = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch
            return error.InvalidNumber;
        // An infinity or a NaN reaching z2d is a hang or a panic rather than a
        // wrong picture, so neither gets past here.
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        return value;
    }

    /// One of §8.3.8's arc flags.
    ///
    /// A flag is a single character, and unlike every other argument it is not
    /// separated from what follows: `a1 1 0 011 1` carries the flags `0` and
    /// `1` and then the endpoint `1 1`. Reading it as a number would take the
    /// `011` and shift every remaining argument along by two.
    pub fn flag(self: *Scanner) Error!bool {
        self.skipWsAndCommas();
        if (self.done()) return error.TruncatedCommand;
        const c = self.src[self.pos];
        self.pos += 1;
        return switch (c) {
            '0' => false,
            '1' => true,
            else => error.InvalidFlag,
        };
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn buildOne(gpa: std.mem.Allocator, d: []const u8) !z2d.Path {
    var path: z2d.Path = .empty;
    errdefer path.deinit(gpa);
    try build(&path, gpa, d, .{});
    return path;
}

test "every subpath comes back closed" {
    var path = try buildOne(testing.allocator, "M0 0L10 0L10 10");
    defer path.deinit(testing.allocator);
    try testing.expect(path.isClosed());
}

test "a repeated moveto argument is a lineto" {
    var path = try buildOne(testing.allocator, "M1 1 2 2 3 3Z");
    defer path.deinit(testing.allocator);
    // Five, not four: z2d's `close` appends a `close_path` and then an
    // implicit `move_to` back to where the subpath began, which is what keeps
    // its own fill and stroke state machines reachable.
    try testing.expectEqual(@as(usize, 5), path.nodes.items.len);
    try testing.expect(path.nodes.items[0] == .move_to);
    try testing.expect(path.nodes.items[1] == .line_to);
    try testing.expect(path.nodes.items[2] == .line_to);
}

test "abutting numbers are separate numbers" {
    var path = try buildOne(testing.allocator, "M1-2L.5.5Z");
    defer path.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 1), path.nodes.items[0].move_to.point.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -2), path.nodes.items[0].move_to.point.y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), path.nodes.items[1].line_to.point.x, 1e-12);
}

test "arc flags are single characters and are not separated" {
    // `011 1` is the two flags `0` and `1`, then the endpoint `1 1`. Reading
    // the flag as a number would take `011` and shift everything along.
    var path = try buildOne(testing.allocator, "M0 0a1 1 0 011 1z");
    defer path.deinit(testing.allocator);
    // The arc ends with a `lineTo` onto the endpoint the command names, and
    // `z` then appends a `close_path` and an implicit `move_to`, so the
    // endpoint is three from the end.
    const endpoint = path.nodes.items[path.nodes.items.len - 3];
    try testing.expectApproxEqAbs(@as(f64, 1), endpoint.line_to.point.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), endpoint.line_to.point.y, 1e-9);
}

test "data that does not begin with a moveto is refused" {
    var path: z2d.Path = .empty;
    defer path.deinit(testing.allocator);
    try testing.expectError(error.ExpectedMoveTo, build(&path, testing.allocator, "L1 1", .{}));
}

test "an unknown command is refused rather than skipped" {
    var path: z2d.Path = .empty;
    defer path.deinit(testing.allocator);
    try testing.expectError(error.UnknownCommand, build(&path, testing.allocator, "M0 0X1 1", .{}));
}

test "a non-finite number is refused before it reaches z2d" {
    var path: z2d.Path = .empty;
    defer path.deinit(testing.allocator);
    try testing.expectError(
        error.InvalidNumber,
        build(&path, testing.allocator, "M0 0L1e400 1", .{}),
    );
}

test "a path past its node budget is refused" {
    var path: z2d.Path = .empty;
    defer path.deinit(testing.allocator);
    try testing.expectError(
        error.PathTooComplex,
        build(&path, testing.allocator, "M0 0L1 1L2 2L3 3L4 4L5 5", .{ .max_nodes = 3 }),
    );
}

test "a drawing command after Z opens a new subpath that must be closed" {
    // §8.3.3: a command following `Z` with no intervening `M` continues from
    // the start of the subpath just closed, which begins a *new* subpath. Not
    // marking it open left it unclosed, and `painter.fill` refuses that.
    var path = try buildOne(testing.allocator, "M2 2L4 2L4 4ZL8 8Z");
    defer path.deinit(testing.allocator);
    try testing.expect(path.isClosed());
}

test "a number after Z is refused rather than repeating a command that reads none" {
    // `closepath` consumes no arguments, so treating a bare number after `Z`
    // as an implicit repeat of it would run a command that advances the
    // scanner by nothing, forever. The fuzzer found this in eight seconds.
    var path: z2d.Path = .empty;
    defer path.deinit(testing.allocator);
    try testing.expectError(error.UnknownCommand, build(&path, testing.allocator, "M0 0L1 1Z6", .{}));
}

test "the empty string is a path with nothing in it" {
    var path = try buildOne(testing.allocator, "   ");
    defer path.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), path.nodes.items.len);
}
