// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The `<style>` element and the cascade: SVG 1.1 §6.
//!
//! `style.zig` reads one declaration block, which is the whole of the `style`
//! attribute. This is the rest of §6: a stylesheet of rules, each a list of
//! selectors and a block, and the rules for deciding which of several
//! declarations of the same property an element actually gets.
//!
//! It is deliberately **CSS 2**, which is what SVG 1.1 §6.2 normatively
//! references, and deliberately only the part of CSS 2 that selects: there are
//! no at-rules here, no `@media`, no `@import`, and no pseudo-classes. Each of
//! those is refused rather than skipped, for the reason everything else in this
//! library is refused rather than skipped -- a rule that was meant to apply and
//! silently did not is a picture that looks finished and is not.
//!
//! `@import` is refused for a second reason as well, and it is the same reason
//! `<use xlink:href="other.svg#x">` is: fetching a stylesheet is I/O, and being
//! sans-I/O is what lets the renderer run in a process that cannot open
//! anything.
//!
//! ## What selects
//!
//! `*`, a type name, `.class`, `#id`, and `[attr]`, `[attr=value]`,
//! `[attr~=word]` and `[attr|=prefix]`, in any combination; the four
//! combinators ` `, `>`, `+` and `~`; and lists of those separated by commas.
//! A type name is matched **case-sensitively**, because this is XML rather
//! than HTML and `RECT` is not `rect` -- resvg agrees, and a fixture pins it.
//!
//! ## The cascade, which is shorter than it sounds
//!
//! CSS 2.1 §6.4.3 orders declarations of one property, and SVG 1.1 §6.4 adds
//! the presentation attributes at the bottom of it. Written out for the one
//! origin this has -- the author's -- it comes to five bands:
//!
//!   1. `!important` in a `style` attribute
//!   2. `!important` in a rule, by specificity
//!   3. a `style` attribute
//!   4. a rule, by specificity and then by source order
//!   5. a presentation attribute
//!
//! The `style` attribute outranks every selector because CSS gives it a
//! specificity higher than any of them can reach, and the presentation
//! attributes lose to everything because §6.4 says so in as many words. That
//! ordering is `document.zig`'s `presentation`, and this file supplies the two
//! middle bands.
//!
//! ## Where this differs from resvg
//!
//! The general sibling combinator, `~`, selects here and does not in resvg.
//! Nothing in the corpus uses it, because a fixture that did would be
//! measuring resvg's gap rather than this code -- the same reason
//! `rebeccapurple` is not in a fixture.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ztree = @import("ztree");

const style = @import("style.zig");

pub const Error = error{
    /// A selector this cannot read at all -- an empty one, a stray
    /// combinator, an unterminated `[`.
    BadSelector,
    /// A selector whose syntax is understood and whose meaning is not: a
    /// pseudo-class or pseudo-element, or a namespace separator. Refused
    /// rather than dropped, because a rule that was meant to apply and did
    /// not is a picture that looks finished and is not.
    UnsupportedSelector,
    /// `@media`, `@import`, or any other at-rule. See the note above on why
    /// `@import` could not be implemented here even if the rest were.
    UnsupportedAtRule,
    /// A rule whose `{` never closes.
    UnterminatedRule,
    /// More rules in one document than `max_rules`.
    TooManyCssRules,
    /// One complex selector with more compounds than `max_compounds`, or one
    /// compound with more conditions than `max_conditions`.
    SelectorTooComplex,
} || Allocator.Error;

/// Bounds, so that a hostile document cannot turn a stylesheet into an
/// allocation. All three are far above anything a real document reaches.
pub const max_rules = 4096;
pub const max_compounds = 32;
pub const max_conditions = 32;

/// How one compound selector attaches to the one to its left.
pub const Combinator = enum { descendant, child, adjacent, sibling };

/// The operator in an attribute selector. CSS 2's three, and presence.
pub const AttrOp = enum {
    /// `[attr]`
    present,
    /// `[attr=value]`
    exact,
    /// `[attr~=word]`: one of a whitespace-separated list.
    word,
    /// `[attr|=prefix]`: the value, or the value followed by a hyphen.
    prefix_dash,
};

/// One condition on a compound selector, beyond its type name.
pub const Condition = union(enum) {
    class: []const u8,
    id: []const u8,
    attribute: struct {
        name: []const u8,
        op: AttrOp,
        value: []const u8 = "",
    },
};

/// One compound selector: an optional type name and any number of conditions,
/// written without spaces -- `rect.a#b[c]`.
pub const Compound = struct {
    /// Null is `*`, which matches any element and counts for nothing.
    name: ?[]const u8 = null,
    conditions: []const Condition = &.{},
    /// How this attaches to the compound *after* it in `Selector.compounds`,
    /// which is the one to its left in the document. Meaningless on the last.
    combinator: Combinator = .descendant,
};

/// §5.2's specificity, as the three counts CSS 2.1 defines.
pub const Specificity = struct {
    /// `#id` conditions.
    a: u32 = 0,
    /// Classes and attribute conditions.
    b: u32 = 0,
    /// Type names.
    c: u32 = 0,

    /// One number that orders the same way, so a cascade is a comparison.
    /// Each field is bounded by `max_compounds * max_conditions`, so ten bits
    /// apiece is room to spare.
    pub fn rank(self: Specificity) u32 {
        return (self.a << 20) | (self.b << 10) | self.c;
    }
};

/// One complex selector, held **subject first**: `compounds[0]` is the element
/// the rule applies to and the rest are its ancestors or siblings.
///
/// Subject first because that is the order matching walks in: the subject is
/// the element in hand, and everything after it is a question about the tree
/// around it. Stored the other way round, every match would begin by finding
/// the far end of the selector.
pub const Selector = struct {
    compounds: []const Compound,
    specificity: Specificity,
};

/// One rule: the selectors that choose it, and the declarations it carries.
///
/// The block is kept as written and read with `style.property` at the point of
/// use, which is the same code the `style` attribute goes through -- so a
/// property means the same thing in both places by construction rather than by
/// two parsers agreeing.
pub const Rule = struct {
    selectors: []const Selector,
    block: []const u8,
};

/// What the cascade found: a value, and whether it was marked `!important`.
pub const Match = struct {
    value: []const u8,
    important: bool,
    specificity: u32,
};

/// Every `<style>` element of a document, parsed.
pub const Stylesheet = struct {
    rules: []const Rule = &.{},
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Stylesheet) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }

    pub fn isEmpty(self: Stylesheet) bool {
        return self.rules.len == 0;
    }

    /// The winning declaration of `name` for `node`, among the rules that
    /// select it, or null when none does.
    ///
    /// Important declarations beat unimportant ones; within a band the higher
    /// specificity wins, and equal specificity goes to the later rule. Source
    /// order falls out of walking the rules forwards and taking `>=`.
    pub fn lookup(
        self: Stylesheet,
        tree: *const ztree.Document,
        node: ztree.NodeId,
        name: []const u8,
    ) ?Match {
        var best: ?Match = null;
        for (self.rules) |rule| {
            const decl = style.declaration(rule.block, name) orelse continue;
            var rank: ?u32 = null;
            for (rule.selectors) |sel| {
                if (!matches(tree, node, sel)) continue;
                const r = sel.specificity.rank();
                if (rank == null or r > rank.?) rank = r;
            }
            const r = rank orelse continue;
            const candidate: Match = .{
                .value = decl.value,
                .important = decl.important,
                .specificity = r,
            };
            if (best) |b| {
                if (wins(candidate, b)) best = candidate;
            } else best = candidate;
        }
        return best;
    }
};

/// Whether `a` beats `b` for the same property. Equal on both counts means `a`
/// came later, and later wins.
fn wins(a: Match, b: Match) bool {
    if (a.important != b.important) return a.important;
    return a.specificity >= b.specificity;
}

/// A presentation property of `node`, resolved through the whole of §6.4's
/// cascade: the `style` attribute, the stylesheet, and the presentation
/// attribute, with the important declarations of the first two on top.
///
/// This is the one place that order is written down, and everything that reads
/// a presentation property goes through it -- the walk in `document.zig`, a
/// gradient's `stop-color`, a filter primitive's `flood-color`. A property
/// read any other way would be one the cascade silently did not reach, which
/// is exactly the bug that `style` had here before it was implemented.
pub fn property(
    sheet: *const Stylesheet,
    tree: *const ztree.Document,
    node: ztree.NodeId,
    name: []const u8,
) ?[]const u8 {
    const from_style: ?style.Declaration = if (tree.attributeValue(node, "", "style")) |block|
        style.declaration(block, name)
    else
        null;
    const from_sheet: ?Match = if (sheet.isEmpty())
        null
    else
        sheet.lookup(tree, node, name);

    if (from_style) |d| {
        if (d.important) return d.value;
    }
    if (from_sheet) |m| {
        if (m.important) return m.value;
    }
    if (from_style) |d| return d.value;
    if (from_sheet) |m| return m.value;
    return tree.attributeValue(node, "", name);
}

// -- matching ----------------------------------------------------------------

/// Whether `sel` selects `node`.
pub fn matches(tree: *const ztree.Document, node: ztree.NodeId, sel: Selector) bool {
    if (sel.compounds.len == 0) return false;
    return matchFrom(tree, node, sel.compounds, 0);
}

/// Match `compounds[i..]` with `node` as the subject of `compounds[i]`.
///
/// Recursive rather than a loop because a descendant combinator has to
/// backtrack: `g g rect` against a rect with three `<g>` ancestors has to try
/// each of them as the nearer `g`, and a greedy walk that takes the first one
/// gets `a b a` wrong. The depth is the selector's length, which
/// `max_compounds` bounds.
fn matchFrom(
    tree: *const ztree.Document,
    node: ztree.NodeId,
    compounds: []const Compound,
    i: usize,
) bool {
    if (!matchCompound(tree, node, compounds[i])) return false;
    if (i + 1 == compounds.len) return true;

    switch (compounds[i].combinator) {
        .child => {
            const p = parentElement(tree, node) orelse return false;
            return matchFrom(tree, p, compounds, i + 1);
        },
        .descendant => {
            var walk = parentElement(tree, node);
            while (walk) |a| : (walk = parentElement(tree, a)) {
                if (matchFrom(tree, a, compounds, i + 1)) return true;
            }
            return false;
        },
        .adjacent => {
            const s = previousElement(tree, node) orelse return false;
            return matchFrom(tree, s, compounds, i + 1);
        },
        .sibling => {
            var walk = previousElement(tree, node);
            while (walk) |s| : (walk = previousElement(tree, s)) {
                if (matchFrom(tree, s, compounds, i + 1)) return true;
            }
            return false;
        },
    }
}

fn matchCompound(tree: *const ztree.Document, node: ztree.NodeId, c: Compound) bool {
    const n = tree.node(node);
    if (n.kind != .element) return false;
    // XML, not HTML: `RECT` does not select a `<rect>`.
    if (c.name) |want| {
        if (!std.mem.eql(u8, n.name.local, want)) return false;
    }
    for (c.conditions) |cond| {
        if (!matchCondition(tree, node, cond)) return false;
    }
    return true;
}

fn matchCondition(tree: *const ztree.Document, node: ztree.NodeId, cond: Condition) bool {
    switch (cond) {
        .class => |want| {
            const raw = tree.attributeValue(node, "", "class") orelse return false;
            return hasWord(raw, want);
        },
        .id => |want| {
            const raw = tree.attributeValue(node, "", "id") orelse return false;
            return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), want);
        },
        .attribute => |a| {
            const raw = tree.attributeValue(node, "", a.name) orelse return false;
            return switch (a.op) {
                .present => true,
                .exact => std.mem.eql(u8, raw, a.value),
                .word => hasWord(raw, a.value),
                .prefix_dash => std.mem.eql(u8, raw, a.value) or
                    (raw.len > a.value.len and
                        std.mem.startsWith(u8, raw, a.value) and
                        raw[a.value.len] == '-'),
            };
        },
    }
}

/// Whether `list` holds `want` as one whitespace-separated word. This is both
/// how `class="a b c"` is read and what `[attr~=word]` asks.
fn hasWord(list: []const u8, want: []const u8) bool {
    if (want.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, want)) return true;
    }
    return false;
}

fn parentElement(tree: *const ztree.Document, node: ztree.NodeId) ?ztree.NodeId {
    const p = tree.node(node).parent orelse return null;
    if (tree.node(p).kind != .element) return null;
    return p;
}

/// The element immediately before `node` among its parent's children, skipping
/// text and comments -- which is what CSS means by the previous sibling.
fn previousElement(tree: *const ztree.Document, node: ztree.NodeId) ?ztree.NodeId {
    const p = tree.node(node).parent orelse return null;
    const kids = tree.node(p).children.items;
    var seen: ?ztree.NodeId = null;
    for (kids) |kid| {
        if (kid == node) return seen;
        if (tree.node(kid).kind == .element) seen = kid;
    }
    return null;
}

// -- parsing -----------------------------------------------------------------

/// Parse the text of every `<style>` element of a document, in document order.
///
/// They are one stylesheet rather than several: §6.2 concatenates them, and
/// source order across the whole document is what breaks a specificity tie.
pub fn parse(gpa: Allocator, sources: []const []const u8) Error!Stylesheet {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var rules: std.ArrayList(Rule) = .empty;
    for (sources) |src| {
        var p: Parser = .{ .src = src, .arena = a };
        while (try p.rule()) |r| {
            if (rules.items.len == max_rules) return error.TooManyCssRules;
            try rules.append(a, r);
        }
    }

    return .{ .rules = try rules.toOwnedSlice(a), .arena = arena };
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,

    /// The next rule, or null at the end of the stylesheet.
    fn rule(self: *Parser) Error!?Rule {
        self.trivia();
        if (self.pos >= self.src.len) return null;
        // No at-rule is implemented, and `@import` could not be: fetching a
        // stylesheet is the I/O this library does not do.
        if (self.src[self.pos] == '@') return error.UnsupportedAtRule;

        const start = self.pos;
        const open = self.findBraceOpen() orelse return error.UnterminatedRule;
        const selector_text = self.src[start..open];
        self.pos = open + 1;
        const close = self.findBraceClose() orelse return error.UnterminatedRule;
        const block = self.src[self.pos..close];
        self.pos = close + 1;

        return .{
            .selectors = try self.selectorList(selector_text),
            .block = block,
        };
    }

    /// Whitespace and `/* ... */`, which may sit anywhere a space may.
    fn trivia(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c) {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                // An unterminated comment swallows the rest, which is what
                // CSS 2.1 §4.1.9 says to do.
                const end = std.mem.indexOfPos(u8, self.src, self.pos + 2, "*/") orelse self.src.len;
                self.pos = @min(end + 2, self.src.len);
                continue;
            }
            return;
        }
    }

    /// The `{` that opens the next rule, skipping over the places a brace can
    /// appear without opening one.
    fn findBraceOpen(self: *Parser) ?usize {
        var i = self.pos;
        while (i < self.src.len) {
            switch (self.src[i]) {
                '{' => return i,
                '"', '\'' => i = skipString(self.src, i),
                '[' => i = skipTo(self.src, i, ']'),
                '/' => i = skipComment(self.src, i),
                else => i += 1,
            }
        }
        return null;
    }

    /// The `}` closing the block that `pos` is inside, allowing for nested
    /// braces, strings and comments.
    fn findBraceClose(self: *Parser) ?usize {
        var depth: usize = 0;
        var i = self.pos;
        while (i < self.src.len) {
            switch (self.src[i]) {
                '}' => {
                    if (depth == 0) return i;
                    depth -= 1;
                    i += 1;
                },
                '{' => {
                    depth += 1;
                    i += 1;
                },
                '"', '\'' => i = skipString(self.src, i),
                '/' => i = skipComment(self.src, i),
                else => i += 1,
            }
        }
        return null;
    }

    /// `a, b, c` -- split at the commas that are not inside brackets or
    /// strings.
    fn selectorList(self: *Parser, text: []const u8) Error![]const Selector {
        var out: std.ArrayList(Selector) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= text.len) {
            if (i == text.len or text[i] == ',') {
                try out.append(self.arena, try self.complex(text[start..i]));
                start = i + 1;
                i += 1;
                continue;
            }
            switch (text[i]) {
                '"', '\'' => i = skipString(text, i),
                '[' => i = skipTo(text, i, ']'),
                '/' => i = skipComment(text, i),
                else => i += 1,
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    /// One complex selector: compounds joined by combinators, stored subject
    /// first.
    fn complex(self: *Parser, text: []const u8) Error!Selector {
        var parts: [max_compounds]Compound = undefined;
        // `links[k]` is the combinator written to the left of `parts[k]`.
        var links: [max_compounds]Combinator = undefined;
        var count: usize = 0;

        var i: usize = 0;
        var pending: Combinator = .descendant;
        while (true) {
            // Whitespace between two compounds *is* the descendant
            // combinator, so whether any was there has to be remembered.
            // A comment is not whitespace for that purpose: CSS removes it
            // during tokenization, which leaves `a/**/b` as one compound.
            var spaced = skipTrivia(text, &i);
            // An explicit combinator overrides the whitespace around it, so
            // `a > b` links with `child` rather than with both.
            var explicit = false;
            while (i < text.len) {
                const comb: Combinator = switch (text[i]) {
                    '>' => .child,
                    '+' => .adjacent,
                    '~' => .sibling,
                    else => break,
                };
                // Two combinators in a row is not a selector.
                if (explicit) return error.BadSelector;
                pending = comb;
                explicit = true;
                i += 1;
                spaced = skipTrivia(text, &i) or spaced;
            }
            if (i >= text.len) {
                // Trailing whitespace is fine; a trailing combinator is not.
                if (explicit) return error.BadSelector;
                break;
            }
            // Two compounds with neither whitespace nor a combinator between
            // them means the compound parser stopped at something it could
            // not read.
            if (!explicit and count > 0 and !spaced) return error.BadSelector;

            if (count == max_compounds) return error.SelectorTooComplex;
            const parsed = try self.compound(text, &i);
            parts[count] = parsed;
            links[count] = pending;
            count += 1;
            pending = .descendant;
        }
        if (count == 0) return error.BadSelector;

        // Subject first, each carrying the combinator that stood to its left.
        const compounds = try self.arena.alloc(Compound, count);
        var spec: Specificity = .{};
        for (compounds, 0..) |*slot, j| {
            const k = count - 1 - j;
            slot.* = parts[k];
            slot.combinator = links[k];
            if (parts[k].name != null) spec.c += 1;
            for (parts[k].conditions) |cond| {
                switch (cond) {
                    .id => spec.a += 1,
                    .class, .attribute => spec.b += 1,
                }
            }
        }
        return .{ .compounds = compounds, .specificity = spec };
    }

    /// `rect.a#b[c=d]`, starting at `i.*` and leaving it past the end.
    fn compound(self: *Parser, text: []const u8, i: *usize) Error!Compound {
        var name: ?[]const u8 = null;
        var conditions: [max_conditions]Condition = undefined;
        var count: usize = 0;

        if (i.* < text.len and text[i.*] == '*') {
            i.* += 1;
        } else if (identLen(text, i.*) > 0) {
            const n = identLen(text, i.*);
            name = text[i.*..][0..n];
            i.* += n;
        }

        while (i.* < text.len) {
            const c = text[i.*];
            // A pseudo-class or pseudo-element is understood and not
            // implemented; a `|` is a namespace selector, likewise.
            if (c == ':' or c == '|') return error.UnsupportedSelector;
            if (c != '.' and c != '#' and c != '[') break;
            if (count == max_conditions) return error.SelectorTooComplex;

            if (c == '.' or c == '#') {
                const n = identLen(text, i.* + 1);
                if (n == 0) return error.BadSelector;
                const word = text[i.* + 1 ..][0..n];
                conditions[count] = if (c == '.')
                    .{ .class = word }
                else
                    .{ .id = word };
                i.* += 1 + n;
            } else {
                conditions[count] = try attribute(text, i);
            }
            count += 1;
        }

        if (name == null and count == 0 and (i.* == 0 or text[i.* - 1] != '*')) {
            return error.BadSelector;
        }
        return .{
            .name = name,
            .conditions = try self.arena.dupe(Condition, conditions[0..count]),
        };
    }
};

/// `[name]`, `[name=value]`, `[name~=value]`, `[name|=value]`.
fn attribute(text: []const u8, i: *usize) Error!Condition {
    var p = i.* + 1;
    _ = skipTrivia(text, &p);
    const n = identLen(text, p);
    if (n == 0) return error.BadSelector;
    const name = text[p..][0..n];
    p += n;
    _ = skipTrivia(text, &p);
    if (p >= text.len) return error.BadSelector;

    if (text[p] == ']') {
        i.* = p + 1;
        return .{ .attribute = .{ .name = name, .op = .present } };
    }

    const op: AttrOp = switch (text[p]) {
        '=' => .exact,
        '~' => .word,
        '|' => .prefix_dash,
        // `^=`, `$=` and `*=` are CSS 3, and this is CSS 2.
        else => return error.UnsupportedSelector,
    };
    if (op != .exact) {
        p += 1;
        if (p >= text.len or text[p] != '=') return error.BadSelector;
    }
    p += 1;
    _ = skipTrivia(text, &p);
    if (p >= text.len) return error.BadSelector;

    var value: []const u8 = undefined;
    if (text[p] == '"' or text[p] == '\'') {
        const quote = text[p];
        const end = std.mem.indexOfScalarPos(u8, text, p + 1, quote) orelse
            return error.BadSelector;
        value = text[p + 1 .. end];
        p = end + 1;
    } else {
        const len = identLen(text, p);
        if (len == 0) return error.BadSelector;
        value = text[p..][0..len];
        p += len;
    }
    _ = skipTrivia(text, &p);
    if (p >= text.len or text[p] != ']') return error.BadSelector;
    i.* = p + 1;
    return .{ .attribute = .{ .name = name, .op = op, .value = value } };
}

/// How many bytes of identifier start at `i`.
///
/// Letters, digits, `-` and `_`, and any byte with the high bit set so that a
/// class name in another script is one identifier rather than none. An escape
/// sequence is not read: nothing writes one in an SVG, and reading half of it
/// would be worse than reading none.
fn identLen(text: []const u8, i: usize) usize {
    var n: usize = 0;
    while (i + n < text.len) {
        const c = text[i + n];
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c >= 0x80;
        if (!ok) break;
        n += 1;
    }
    return n;
}

/// Past whitespace and comments, answering whether any *whitespace* was
/// among them -- which is what the descendant combinator is written as.
fn skipTrivia(text: []const u8, i: *usize) bool {
    var spaced = false;
    while (i.* < text.len) {
        switch (text[i.*]) {
            ' ', '\t', '\r', '\n', 0x0c => {
                spaced = true;
                i.* += 1;
            },
            '/' => {
                // A solidus that does not open a comment is not trivia; it is
                // something the selector parser has to see and refuse.
                if (i.* + 1 >= text.len or text[i.* + 1] != '*') return spaced;
                i.* = skipComment(text, i.*);
            },
            else => return spaced,
        }
    }
    return spaced;
}

/// Past a quoted string beginning at `i`, or past the quote alone when it
/// never closes.
fn skipString(text: []const u8, i: usize) usize {
    const quote = text[i];
    var j = i + 1;
    while (j < text.len) : (j += 1) {
        if (text[j] == '\\') {
            j += 1;
            continue;
        }
        if (text[j] == quote) return j + 1;
    }
    return text.len;
}

fn skipTo(text: []const u8, i: usize, close: u8) usize {
    const end = std.mem.findScalar(u8, text[i..], close) orelse return text.len;
    return i + end + 1;
}

/// Past a comment beginning at `i`, or past the slash when it is not one.
fn skipComment(text: []const u8, i: usize) usize {
    if (i + 1 < text.len and text[i + 1] == '*') {
        const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return text.len;
        return end + 2;
    }
    return i + 1;
}

// -- tests -------------------------------------------------------------------

fn sheetOf(gpa: Allocator, text: []const u8) !Stylesheet {
    return parse(gpa, &.{text});
}

test "a rule is a selector list and a block" {
    const gpa = testing.allocator;
    var sheet = try sheetOf(gpa, "rect { fill: red } circle,ellipse{fill:blue}");
    defer sheet.deinit();

    try testing.expectEqual(@as(usize, 2), sheet.rules.len);
    try testing.expectEqual(@as(usize, 1), sheet.rules[0].selectors.len);
    try testing.expectEqualStrings("rect", sheet.rules[0].selectors[0].compounds[0].name.?);
    try testing.expectEqualStrings("red", style.property(sheet.rules[0].block, "fill").?);
    try testing.expectEqual(@as(usize, 2), sheet.rules[1].selectors.len);
    try testing.expectEqualStrings("ellipse", sheet.rules[1].selectors[1].compounds[0].name.?);
}

test "comments may sit anywhere a space may" {
    const gpa = testing.allocator;
    var sheet = try sheetOf(gpa, "/* before */ rect /* between */ { fill: red } /* after */");
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 1), sheet.rules.len);
    try testing.expectEqualStrings("rect", sheet.rules[0].selectors[0].compounds[0].name.?);

    // CSS 2.1 §4.1.9: an unterminated comment runs to the end of the sheet,
    // so what follows it is not a rule that was lost.
    var open = try sheetOf(gpa, "rect{fill:red} /* and then nothing closes");
    defer open.deinit();
    try testing.expectEqual(@as(usize, 1), open.rules.len);
}

test "a selector is stored subject first" {
    const gpa = testing.allocator;
    var sheet = try sheetOf(gpa, "g > svg rect { fill: red }");
    defer sheet.deinit();
    const sel = sheet.rules[0].selectors[0];
    try testing.expectEqual(@as(usize, 3), sel.compounds.len);
    // The subject is the rightmost compound, and each carries the combinator
    // written to its left.
    try testing.expectEqualStrings("rect", sel.compounds[0].name.?);
    try testing.expectEqual(Combinator.descendant, sel.compounds[0].combinator);
    try testing.expectEqualStrings("svg", sel.compounds[1].name.?);
    try testing.expectEqual(Combinator.child, sel.compounds[1].combinator);
    try testing.expectEqualStrings("g", sel.compounds[2].name.?);
}

test "specificity counts ids, then classes and attributes, then types" {
    const gpa = testing.allocator;
    var sheet = try sheetOf(gpa,
        \\* {fill:a}
        \\rect {fill:b}
        \\.c {fill:c}
        \\#d {fill:d}
        \\rect.c[x] {fill:e}
        \\g rect {fill:f}
    );
    defer sheet.deinit();
    const spec = struct {
        fn of(s: Stylesheet, i: usize) Specificity {
            return s.rules[i].selectors[0].specificity;
        }
    }.of;
    try testing.expectEqual(Specificity{ .a = 0, .b = 0, .c = 0 }, spec(sheet, 0));
    try testing.expectEqual(Specificity{ .a = 0, .b = 0, .c = 1 }, spec(sheet, 1));
    try testing.expectEqual(Specificity{ .a = 0, .b = 1, .c = 0 }, spec(sheet, 2));
    try testing.expectEqual(Specificity{ .a = 1, .b = 0, .c = 0 }, spec(sheet, 3));
    try testing.expectEqual(Specificity{ .a = 0, .b = 2, .c = 1 }, spec(sheet, 4));
    // A descendant selector counts both of its type names.
    try testing.expectEqual(Specificity{ .a = 0, .b = 0, .c = 2 }, spec(sheet, 5));

    // And they order the way CSS says: one id beats any number of classes.
    try testing.expect(spec(sheet, 3).rank() > spec(sheet, 4).rank());
    try testing.expect(spec(sheet, 2).rank() > spec(sheet, 1).rank());
}

test "an attribute selector reads all four of CSS 2's forms" {
    const gpa = testing.allocator;
    var sheet = try sheetOf(gpa, "[a]{f:1}[b=c]{f:1}[d~='e']{f:1}[g|=\"h\"]{f:1}");
    defer sheet.deinit();
    const cond = struct {
        fn of(s: Stylesheet, i: usize) @FieldType(Condition, "attribute") {
            return s.rules[i].selectors[0].compounds[0].conditions[0].attribute;
        }
    }.of;
    try testing.expectEqual(AttrOp.present, cond(sheet, 0).op);
    try testing.expectEqualStrings("a", cond(sheet, 0).name);
    try testing.expectEqual(AttrOp.exact, cond(sheet, 1).op);
    try testing.expectEqualStrings("c", cond(sheet, 1).value);
    try testing.expectEqual(AttrOp.word, cond(sheet, 2).op);
    try testing.expectEqualStrings("e", cond(sheet, 2).value);
    try testing.expectEqual(AttrOp.prefix_dash, cond(sheet, 3).op);
    try testing.expectEqualStrings("h", cond(sheet, 3).value);
}

test "what is understood but not implemented is refused, not dropped" {
    const gpa = testing.allocator;
    // A pseudo-class, a namespace separator, and a CSS 3 attribute operator.
    // Each would silently change which elements a rule picks, which is the
    // failure this library is meant not to have.
    try testing.expectError(error.UnsupportedSelector, sheetOf(gpa, "rect:first-child{f:1}"));
    try testing.expectError(error.UnsupportedSelector, sheetOf(gpa, "svg|rect{f:1}"));
    try testing.expectError(error.UnsupportedSelector, sheetOf(gpa, "[a^=b]{f:1}"));
    // An at-rule, which includes the one that would need I/O.
    try testing.expectError(error.UnsupportedAtRule, sheetOf(gpa, "@media screen{rect{f:1}}"));
    try testing.expectError(error.UnsupportedAtRule, sheetOf(gpa, "@import url(x.css);"));
}

test "a selector that is not one is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadSelector, sheetOf(gpa, "{fill:red}"));
    try testing.expectError(error.BadSelector, sheetOf(gpa, "rect >{fill:red}"));
    try testing.expectError(error.BadSelector, sheetOf(gpa, "rect > > g{fill:red}"));
    try testing.expectError(error.BadSelector, sheetOf(gpa, ".{fill:red}"));
    try testing.expectError(error.BadSelector, sheetOf(gpa, "[a=]{fill:red}"));
    // An unclosed `[` swallows the brace that would have opened the block, so
    // what is reported is the rule never closing rather than the selector.
    try testing.expectError(error.UnterminatedRule, sheetOf(gpa, "[a={fill:red}"));
    try testing.expectError(error.UnterminatedRule, sheetOf(gpa, "rect{fill:red"));
    try testing.expectError(error.UnterminatedRule, sheetOf(gpa, "rect"));
}

test "a brace inside a string or a bracket does not open a rule" {
    const gpa = testing.allocator;
    var sheet = try sheetOf(gpa, "[a=\"{\"]{fill:red}");
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 1), sheet.rules.len);
    try testing.expectEqualStrings("red", style.property(sheet.rules[0].block, "fill").?);
}

const Tree = struct {
    doc: *ztree.Document,
    fn deinit(self: *Tree) void {
        self.doc.destroy();
    }
    fn byId(self: *Tree, id: []const u8) ztree.NodeId {
        for (self.doc.nodes.items, 0..) |n, i| {
            if (n.kind != .element) continue;
            const got = self.doc.attributeValue(@intCast(i), "", "id") orelse continue;
            if (std.mem.eql(u8, got, id)) return @intCast(i);
        }
        unreachable;
    }
};

fn treeOf(gpa: Allocator, src: []const u8) !Tree {
    return .{ .doc = try ztree.parse(gpa, src, .{ .entities = .strict }) };
}

/// Whether `selector` picks the element with `id` out of `src`.
///
/// The rule text has to outlive the stylesheet, which slices into it rather
/// than copying, so it is freed last rather than being left to the arena.
fn selects(gpa: Allocator, selector: []const u8, src: []const u8, id: []const u8) !bool {
    var t = try treeOf(gpa, src);
    defer t.deinit();
    const text = try std.fmt.allocPrint(gpa, "{s}{{fill:red}}", .{selector});
    defer gpa.free(text);
    var sheet = try parse(gpa, &.{text});
    defer sheet.deinit();
    return matches(t.doc, t.byId(id), sheet.rules[0].selectors[0]);
}

test "the four combinators walk the tree the way CSS says" {
    const gpa = testing.allocator;
    const doc =
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"outer\"><g id=\"inner\">" ++
        "<circle id=\"c\"/><text id=\"t\"/><rect id=\"r\"/></g></g></svg>";

    try testing.expect(try selects(gpa, "g rect", doc, "r"));
    try testing.expect(try selects(gpa, "svg rect", doc, "r"));
    try testing.expect(try selects(gpa, "g > rect", doc, "r"));
    try testing.expect(!try selects(gpa, "svg > rect", doc, "r"));
    // The adjacent sibling is the element before it, and text or comments
    // between them do not count.
    try testing.expect(try selects(gpa, "text + rect", doc, "r"));
    try testing.expect(!try selects(gpa, "circle + rect", doc, "r"));
    // The general sibling reaches further back, which resvg does not do.
    try testing.expect(try selects(gpa, "circle ~ rect", doc, "r"));
}

test "a descendant combinator backtracks" {
    const gpa = testing.allocator;
    // `a b a` against a tree where the first `<g>` tried is the wrong one:
    // a greedy walk that takes the nearest ancestor and never reconsiders
    // reports no match here.
    const doc =
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"g1\"><text id=\"x\"><g id=\"g2\">" ++
        "<g id=\"g3\"><rect id=\"r\"/></g></g></text></g></svg>";
    try testing.expect(try selects(gpa, "g text g rect", doc, "r"));
}

test "a compound selector asks every one of its questions" {
    const gpa = testing.allocator;
    const doc =
        "<svg xmlns=\"http://www.w3.org/2000/svg\">" ++
        "<rect id=\"r\" class=\"a b\" data-k=\"v w\" lang=\"en-GB\"/></svg>";

    try testing.expect(try selects(gpa, "rect.a.b#r", doc, "r"));
    try testing.expect(!try selects(gpa, "rect.a.c", doc, "r"));
    try testing.expect(try selects(gpa, "[data-k]", doc, "r"));
    try testing.expect(try selects(gpa, "[data-k~=\"w\"]", doc, "r"));
    try testing.expect(!try selects(gpa, "[data-k=\"w\"]", doc, "r"));
    try testing.expect(try selects(gpa, "[lang|=\"en\"]", doc, "r"));
    try testing.expect(!try selects(gpa, "[lang|=\"e\"]", doc, "r"));
    try testing.expect(try selects(gpa, "*", doc, "r"));
    // XML, not HTML: a type name is matched with regard to case.
    try testing.expect(!try selects(gpa, "RECT", doc, "r"));
}

test "the cascade takes specificity first and source order second" {
    const gpa = testing.allocator;
    var t = try treeOf(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" class=\"a\"/></svg>");
    defer t.deinit();
    var sheet = try sheetOf(gpa,
        \\rect {fill:one}
        \\rect {fill:two}
        \\.a {fill:three}
        \\#r {fill:four}
    );
    defer sheet.deinit();
    const r = t.byId("r");

    try testing.expectEqualStrings("four", sheet.lookup(t.doc, r, "fill").?.value);

    var narrower = try sheetOf(gpa, "rect{fill:one}rect{fill:two}");
    defer narrower.deinit();
    // Equal specificity: the later rule wins.
    try testing.expectEqualStrings("two", narrower.lookup(t.doc, r, "fill").?.value);

    // A rule that selects nothing contributes nothing.
    var missing = try sheetOf(gpa, "circle{fill:one}");
    defer missing.deinit();
    try testing.expectEqual(@as(?Match, null), missing.lookup(t.doc, r, "fill"));
}

test "an important declaration beats a more specific one" {
    const gpa = testing.allocator;
    var t = try treeOf(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" class=\"a\"/></svg>");
    defer t.deinit();
    var sheet = try sheetOf(gpa, "rect{fill:low!important} #r{fill:high}");
    defer sheet.deinit();
    const got = sheet.lookup(t.doc, t.byId("r"), "fill").?;
    try testing.expectEqualStrings("low", got.value);
    try testing.expect(got.important);
}

test "the whole cascade, including the two ends only `property` can see" {
    const gpa = testing.allocator;
    var t = try treeOf(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\">" ++
        "<rect id=\"plain\" fill=\"attr\"/>" ++
        "<rect id=\"styled\" fill=\"attr\" style=\"fill:inline\"/>" ++
        "<rect id=\"shouted\" fill=\"attr\" style=\"fill:inline\"/>" ++
        "<rect id=\"insistent\" fill=\"attr\" style=\"fill:inline!important\"/></svg>");
    defer t.deinit();
    var sheet = try sheetOf(gpa,
        \\#plain {fill:rule}
        \\#styled {fill:rule}
        \\#shouted {fill:rule!important}
        \\#insistent {fill:rule!important}
    );
    defer sheet.deinit();

    // A rule beats a presentation attribute, §6.4.
    try testing.expectEqualStrings("rule", property(&sheet, t.doc, t.byId("plain"), "fill").?);
    // A `style` attribute beats a rule, because CSS gives it a specificity no
    // selector can reach.
    try testing.expectEqualStrings("inline", property(&sheet, t.doc, t.byId("styled"), "fill").?);
    // An important rule beats an ordinary `style` attribute...
    try testing.expectEqualStrings("rule", property(&sheet, t.doc, t.byId("shouted"), "fill").?);
    // ...and an important `style` attribute beats that.
    try testing.expectEqualStrings("inline", property(&sheet, t.doc, t.byId("insistent"), "fill").?);

    // With no stylesheet at all the two ends still work.
    const none: Stylesheet = .{};
    try testing.expectEqualStrings("attr", property(&none, t.doc, t.byId("plain"), "fill").?);
    try testing.expectEqualStrings("inline", property(&none, t.doc, t.byId("styled"), "fill").?);
    try testing.expectEqual(@as(?[]const u8, null), property(&none, t.doc, t.byId("plain"), "stroke"));
}

test "several style elements are one sheet in document order" {
    const gpa = testing.allocator;
    var t = try treeOf(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\"/></svg>");
    defer t.deinit();
    var sheet = try parse(gpa, &.{ "rect{fill:first}", "rect{fill:second}" });
    defer sheet.deinit();
    try testing.expectEqualStrings("second", sheet.lookup(t.doc, t.byId("r"), "fill").?.value);
}

test "a selector longer than the bounds is refused rather than truncated" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..max_compounds + 1) |_| try buf.appendSlice(gpa, "g ");
    try buf.appendSlice(gpa, "rect{fill:red}");
    try testing.expectError(error.SelectorTooComplex, sheetOf(gpa, buf.items));
}
