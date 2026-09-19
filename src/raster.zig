// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! From an SVG document to pixels: the reader, the path grammar and z2d's
//! rasterizer wired together.
//!
//! Two entry points. `render` makes a surface of its own and is what a program
//! wanting a picture calls. `draw` paints into a surface the caller already
//! has, at a position the caller chooses, and is what a program composing
//! several things into one image calls -- an icon above a label, say.
//!
//! Neither performs any I/O. The source is a byte slice, the result is memory,
//! and where either came from is the calling program's business. That is what
//! makes `sandbox` possible: rendering never needed a file, so a process that
//! cannot open one is still a perfectly capable renderer.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");
const ztree = @import("ztree");

const color = @import("color.zig");
const css = @import("css.zig");
const document = @import("document.zig");
const filter = @import("filter.zig");
const gradient = @import("gradient.zig");
const image = @import("image.zig");
const length = @import("length.zig");
const path = @import("path.zig");
const pattern = @import("pattern.zig");
const shapes = @import("shapes.zig");
const transform = @import("transform.zig");

/// How much a caller is willing to spend on a picture somebody else wrote.
///
/// Every number in an SVG is a number an attacker chose, and two of them --
/// the output size and the path length -- decide how much memory and how much
/// time the render takes. The defaults are sized for a program drawing icons
/// and illustrations for a person to look at: large enough that nothing real
/// is refused, small enough that a hostile file cannot ask for a terabyte.
pub const Limits = struct {
    /// The widest picture to rasterize.
    max_width: u32 = 1 << 14,

    /// The tallest picture to rasterize.
    max_height: u32 = 1 << 14,

    /// The most pixels to rasterize, however they are arranged. This is the
    /// bound that matters: width and height can each be modest while their
    /// product is not, and it is the product that is allocated. At four bytes
    /// a pixel the default is a quarter of a gigabyte.
    max_pixels: u64 = 1 << 26,

    /// The most `z2d.Path` nodes the document's shapes may produce between
    /// them.
    ///
    /// Nodes rather than bytes of source, because the two are not
    /// proportional: `a` with a large sweep produces four cubics from a dozen
    /// characters, and repeating it is the cheapest way to write an expensive
    /// path.
    ///
    /// A budget for the whole document rather than for each shape. Per shape
    /// it would bound nothing: ten thousand `<path>` elements, each just under
    /// the limit, is the same denial of service written out longhand.
    max_path_nodes: usize = 1 << 20,

    /// The most `<path>` elements to draw.
    ///
    /// The node budget does not cover this. An empty `d` produces no nodes and
    /// still costs a fill, and a fill allocates its plotted polygons and a
    /// scanline mask however little there is to plot -- so a document of a
    /// million empty paths is bounded by this and by nothing else.
    max_shapes: usize = 1 << 12,

    /// How deep a stack of composited layers to allow.
    ///
    /// A container with an `opacity` has to be drawn into a surface of its own
    /// and composited once, and each such surface is the size of the whole
    /// picture. So this multiplies the memory a render can take: the ceiling
    /// is `max_pixels` times four bytes times *this*, and a sandboxed render's
    /// `working_bytes` has to cover it. A clip or a mask is another such
    /// surface on top, and `max_mask_depth` says how many of those can be
    /// alive at once.
    ///
    /// Eight is far past any document that means something by its nesting.
    max_layers: usize = 8,

    /// The most tiles to draw for one `<pattern>`.
    ///
    /// Each is clipped to its own cell, because §13.3 hides what overflows a
    /// tile, and a clip is a surface -- so a pattern whose tile is a hundredth
    /// of a unit across on a shape a thousand units wide is a great many
    /// surfaces. The tiles are counted before any is drawn and the whole
    /// pattern is refused if there are too many, rather than a partial lattice
    /// being painted.
    max_pattern_tiles: usize = 1 << 14,

    /// How deep to follow a mask into another mask.
    ///
    /// A `<mask>` may carry a `mask` of its own and a `<clipPath>` a
    /// `clip-path` of its own, and each level is another surface the size of
    /// the picture plus a walk of its content. The recursion is bounded here
    /// rather than by the cycle check in the walk, because a mask naming
    /// itself is a cycle the *iterator* never sees -- each level starts a
    /// fresh walk that is perfectly finite on its own.
    max_mask_depth: usize = 4,

    /// The most source to buffer, for the callers that have to buffer it --
    /// `sandbox.render` copies the document into memory before it forks,
    /// because a sandboxed process that could still read its input would need
    /// a system call this library would rather not permit it.
    ///
    /// Unused by `render` and `draw`, which are handed a slice and never hold
    /// anything the caller did not already have.
    max_input_bytes: u64 = 1 << 24,

    /// Nothing is refused. For a program drawing files it produced itself, on
    /// a machine it is not sharing.
    pub const unlimited: Limits = .{
        .max_width = math.maxInt(u32),
        .max_height = math.maxInt(u32),
        .max_pixels = math.maxInt(u64),
        .max_path_nodes = math.maxInt(usize),
        .max_shapes = math.maxInt(usize),
        .max_layers = 64,
        .max_input_bytes = math.maxInt(u64),
    };

    /// Refuses a picture this budget will not pay for.
    ///
    /// Zero in either dimension is refused as well: z2d surfaces start at 1×1,
    /// and a renderer that returned a zero-pixel one would hand every caller
    /// an edge case to discover for themselves.
    pub fn check(self: Limits, width: u64, height: u64) error{ ImageTooLarge, BadSize }!void {
        if (width == 0 or height == 0) return error.BadSize;
        if (width > self.max_width or height > self.max_height) return error.ImageTooLarge;
        // In u64 and so cannot overflow: both sides are already below 2^32.
        if (width * height > self.max_pixels) return error.ImageTooLarge;
    }
};

/// How to draw.
pub const Options = struct {
    /// The output size in pixels. Either left null takes that dimension from
    /// the `viewBox`, rounded up -- which is what `width` and `height` on the
    /// `<svg>` element would say if this reader read them.
    width: ?u32 = null,
    height: ?u32 = null,

    /// What to paint a shape that names no colour of its own, and what
    /// `fill="currentColor"` resolves to.
    ///
    /// SVG's initial `fill` is black, and so is this -- but a shape whose
    /// document says nothing is painted in *this* colour rather than in black,
    /// which is a deliberate difference. Not one of the 7,447 Material Design
    /// Icons carries a `fill`, so under the letter of the specification the
    /// set could only ever be drawn black; this is what lets a caller draw one
    /// in any colour they like. A document that does name a colour is drawn in
    /// the colour it names.
    ///
    /// An `rgba` or `argb` pixel must be premultiplied, which z2d checks and
    /// refuses.
    fill: z2d.Pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },

    /// What to clear the surface to before drawing. Null leaves it at the
    /// pixel type's zero value, which for `rgba` is transparent and for `rgb`
    /// is black.
    ///
    /// Ignored by `draw`, which never clears a surface it did not make.
    background: ?z2d.Pixel = null,

    /// The surface to make. The default carries an alpha channel, because an
    /// icon that cannot be transparent is not much of an icon.
    ///
    /// Overridden by `background` when there is one: a surface cleared to a
    /// pixel takes its type from that pixel, so naming both and having them
    /// disagree would mean silently ignoring one of them.
    surface_type: z2d.surface.SurfaceType = .image_surface_rgba,

    /// The rule for a shape whose document names none. SVG's initial
    /// `fill-rule` is `nonzero`, and so is this.
    fill_rule: z2d.options.FillRule = .non_zero,

    /// What `stroke="currentColor"` resolves to when nothing named a `color`,
    /// which is the same colour a fill would use.
    ///
    /// There is deliberately no "default stroke": SVG's initial `stroke` is
    /// `none`, so a shape whose document says nothing about stroking is not
    /// stroked. Doing otherwise would put lines in a picture that the document
    /// does not have -- which is the opposite of the `fill` case, where the
    /// document saying nothing is the *normal* case for an icon.
    stroke_width: f64 = 1.0,

    anti_aliasing_mode: z2d.options.AntiAliasMode = .default,
    tolerance: f64 = z2d.options.default_tolerance,

    limits: Limits = .{},

    /// Where the fonts come from, or null when the caller has none to give.
    ///
    /// A document with `<text>` in it and no resolver is refused rather than
    /// drawn without its text.
    fonts: ?FontResolver = null,
};

/// What a document asks for when it wants a font.
pub const FontRequest = struct {
    /// One name out of the `font-family` list, trimmed and unquoted. Empty
    /// when the resolver is being asked for its **default** face: that happens
    /// after every name in the list has been offered and none answered, and
    /// also when the document named no family at all.
    family: []const u8,
    /// §10.10's numeric weight: 400 for `normal`, 700 for `bold`.
    weight: u16 = 400,
    italic: bool = false,
};

/// How the caller supplies fonts.
///
/// A callback rather than a list, so that a caller with a font database can
/// answer out of it and one with a single embedded face can ignore the
/// question. The bytes are borrowed: the resolver keeps ownership and they
/// must outlive the render.
///
/// **It runs inside the sandboxed child.** `sandbox.render` forks and installs
/// a seccomp filter before the document is parsed, so a resolver that opens a
/// file or reaches the network dies of the filter and the render comes back as
/// `error.SandboxViolation`. That is a loud failure rather than a quiet one,
/// but it is still a failure: a resolver must answer out of memory it already
/// holds. Reading the font files is the caller's job, and doing it before the
/// render is the caller's job too.
pub const FontResolver = struct {
    /// Passed back to `resolve` untouched. Whatever the caller needs to find a
    /// face -- a database, a hash map, a single slice.
    ctx: ?*anyopaque = null,

    /// Answers with the bytes of a face, or null when it has none for this
    /// request. Called once per name in the `font-family` list, in order, and
    /// then once more with an empty `family` for the default.
    resolve: *const fn (ctx: ?*anyopaque, req: FontRequest) ?[]const u8,

    /// The face for a shape, or null when nothing answers.
    ///
    /// §10.10's `font-family` is a list in preference order, so each name is
    /// offered in turn. When none answers -- or the document named none --
    /// the resolver is asked for its default, which is what every other
    /// renderer does with a family it does not have. Refusing instead would
    /// refuse a great many real documents, since naming a font the machine
    /// lacks is the ordinary case rather than the exceptional one.
    pub fn faceFor(self: FontResolver, shape: document.Shape) ?[]const u8 {
        const req: FontRequest = .{
            .family = "",
            .weight = shape.font_weight orelse 400,
            .italic = shape.font_italic orelse false,
        };
        if (shape.font_family) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |raw| {
                const name = std.mem.trim(u8, raw, " \t\r\n'\"");
                if (name.len == 0) continue;
                var named = req;
                named.family = name;
                if (self.resolve(self.ctx, named)) |bytes| return bytes;
            }
        }
        return self.resolve(self.ctx, req);
    }
};

/// Everything a render can fail with.
pub const Error = document.Error || document.BuildError || path.BuildError || z2d.painter.FillError || error{
    /// The picture is larger than `Limits` permits.
    ImageTooLarge,
    /// A width or height of zero, whether asked for or taken from the viewBox.
    BadSize,
    /// The document has more `<path>` elements than `Limits.max_shapes`.
    TooManyShapes,
    /// A `stroke-dasharray` naming more than `max_dashes` lengths.
    TooManyDashes,
    /// A `fill` or `stroke` naming an element that is not a paint server at
    /// all.
    UnsupportedPaintServer,
    /// A `<pattern>` whose lattice would need more tiles than
    /// `Limits.max_pattern_tiles` to cover what it paints.
    TooManyPatternTiles,
    /// A document with `<text>` in it, and either no `Options.fonts` at all or
    /// a resolver that answered nothing -- not even a default. Refused rather
    /// than drawn with the text missing.
    NoFontSupplied,
    /// Bytes a resolver returned that are not a font this can read.
    BadFont,
    /// A `<textPath>` naming something with no geometry to follow.
    BadTextPath,
    /// Containers needing a layer of their own, nested more deeply than
    /// `Limits.max_layers`.
    TooManyLayers,
    /// A `clip-path` naming something that is not a `<clipPath>`.
    BadClipPath,
    /// A `mask` naming something that is not a `<mask>`.
    BadMask,
    /// A `clipPathUnits`, `maskUnits` or `maskContentUnits` that is neither
    /// `userSpaceOnUse` nor `objectBoundingBox`. Refused rather than taken as
    /// the default, because a document that misspells one means something by
    /// it and the two answers differ by the whole bounding box.
    UnsupportedClipUnits,
    /// Masks and clips nested more deeply than `Limits.max_mask_depth` -- a
    /// `<mask>` whose content is itself masked, or a `<clipPath>` carrying a
    /// `clip-path` of its own, repeated past any sense.
    TooManyMaskHops,
} || gradient.Error || pattern.Error || filter.Error || image.Error;

/// Where in a surface to draw, in pixels.
pub const Box = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64,
    height: f64,
};

/// Render `src` into a surface of its own.
///
/// The caller owns the surface and releases it with `z2d.Surface.deinit`.
pub fn render(gpa: Allocator, src: []const u8, opts: Options) Error!z2d.Surface {
    var doc = try document.read(gpa, src);
    defer doc.deinit();

    // The document's own size, which is what `width` and `height` say when it
    // has them and the `viewBox`'s extent when it does not.
    const width = opts.width orelse fitDimension(doc.width);
    const height = opts.height orelse fitDimension(doc.height);
    try opts.limits.check(width, height);

    var surface = if (opts.background) |px|
        try z2d.Surface.initPixel(px, gpa, @intCast(width), @intCast(height))
    else
        try z2d.Surface.init(opts.surface_type, gpa, @intCast(width), @intCast(height));
    errdefer surface.deinit(gpa);

    try drawDocument(gpa, &surface, &doc, .{
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    }, opts);

    return surface;
}

/// Render `src` into a surface the caller already has, inside `box`.
///
/// The surface is not cleared: whatever is already there is drawn over, which
/// is the point -- this is how an icon goes on top of a background somebody
/// else painted.
pub fn draw(
    gpa: Allocator,
    surface: *z2d.Surface,
    src: []const u8,
    box: Box,
    opts: Options,
) Error!void {
    var doc = try document.read(gpa, src);
    defer doc.deinit();
    return drawDocument(gpa, surface, &doc, box, opts);
}

/// The half of `draw` that has the document already, so that `render` does not
/// parse the XML twice to find out how large to make its surface.
///
/// Each `<path>` is built and filled on its own, in document order, which is
/// SVG's painting model: a shape is painted over whatever is already there.
///
/// Filling them separately is not the same as building them into one path and
/// filling that once, which would be cheaper. Two overlapping subpaths wound
/// in opposite directions leave a hole under the nonzero rule; painted as two
/// shapes the second simply covers the first. Merging them would quietly
/// choose the first answer for a document that means the second.
fn drawDocument(
    gpa: Allocator,
    destination: *z2d.Surface,
    doc: *const document.Document,
    box: Box,
    opts: Options,
) Error!void {
    if (doc.shape_count > opts.limits.max_shapes) return error.TooManyShapes;

    // Spent down across the whole document rather than reset per shape. See
    // `Limits.max_path_nodes`.
    var nodes_left = opts.limits.max_path_nodes;

    // A container with an `opacity` is drawn into a surface of its own and
    // composited once, so the walk's groups become a stack of surfaces here.
    // `target` is whichever is on top, and the caller's surface at the bottom.
    var layers: Layers = .{ .bottom = destination };
    defer layers.deinit(gpa);

    var walk = doc.paths();
    return drawItems(gpa, &layers, doc, &walk, .{
        .base = doc.transformFor(box.x, box.y, box.width, box.height),
        .nodes_left = &nodes_left,
        .depth = 0,
    }, opts);
}

/// Spend `used` nodes from the document's budget, or refuse when it has run
/// out.
///
/// Not a plain subtraction, and the difference is a panic. Several of the
/// builders produce a fixed number of nodes whatever `max_nodes` says -- a
/// `<rect>` is five and an `<ellipse>` rather more, because there is no
/// sensible half-drawn rectangle -- and text produces however many its glyphs
/// need. So the budget can be overshot, and subtracting past zero in a `usize`
/// is an integer overflow, which is a crash rather than an error.
///
/// Overshooting *is* the budget running out, so that is what it reports.
///
/// The fuzzer found this through a `<pattern>`, which is where it became easy
/// to reach: a pattern draws its content once per cell of the lattice and they
/// all spend from the one budget, so a document with a fine enough pattern
/// drains it to nearly nothing and then the next rectangle asks for five.
fn spendNodes(pass: Pass, used: usize) Error!void {
    if (used > pass.nodes_left.*) return error.PathTooComplex;
    pass.nodes_left.* -= used;
}

/// Everything a run of `drawItems` shares with the one that called it.
const Pass = struct {
    /// The matrix outside every shape's own: the viewBox-to-pixels mapping for
    /// the document itself, and the identity for a `<mask>`, whose content
    /// matrix is folded into its iterator instead.
    base: z2d.Transformation,
    /// The document's node budget, spent by every pass alike so that a
    /// document cannot buy itself more of it by drawing inside a mask.
    nodes_left: *usize,
    /// How many masks and clips deep this pass already is.
    depth: usize,
};

/// Draw whatever a walk yields onto the top of a layer stack.
///
/// The document itself and the content of a `<mask>` are drawn by the same
/// code, which is what makes a mask as expressive as the picture: a group
/// inside one gets its layer, a gradient inside one gets its bounding box, and
/// a clip inside one gets cut.
fn drawItems(
    gpa: Allocator,
    layers: *Layers,
    doc: *const document.Document,
    items: *document.PathIterator,
    pass: Pass,
    opts: Options,
) Error!void {
    const width = layers.bottom.getWidth();
    const height = layers.bottom.getHeight();
    const view_box = pass.base;

    // Where the next run of text goes. One per walk, because the runs of a
    // `<text>` arrive consecutively and each carries on from the last; a run
    // that begins a new element resets it.
    var pen: Pen = .{};

    while (try items.next()) |item| {
        const shape = switch (item) {
            .shape => |sh| sh,
            .open_group => |g| {
                const group_ctm = view_box.mul(g.transform);
                const cut = try buildCut(
                    gpa,
                    doc,
                    .{ .clip_path = g.clip_path, .mask = g.mask },
                    group_ctm,
                    .{ .container = g.node },
                    pass,
                    width,
                    height,
                    opts,
                );
                errdefer if (cut) |c| {
                    var owned = c;
                    owned.deinit(gpa);
                };
                const filtered = try buildFilter(
                    gpa,
                    doc,
                    g.filter,
                    group_ctm,
                    .{ .container = g.node },
                    g.current_color orelse callerColor(opts),
                    width,
                    height,
                    opts,
                );
                try layers.open(gpa, g.opacity, cut, filtered, opts.limits.max_layers);
                continue;
            },
            .close_group => {
                try layers.close(gpa);
                continue;
            },
        };
        const ctm = view_box.mul(shape.transform);

        // A clip or a mask on a shape is the same layer a clip on a group
        // gets. It costs a surface the size of the picture for one shape,
        // which is the price of `dst_in` being a whole-surface operation --
        // documents clip groups far more often than single shapes.
        var shape_layer = false;
        {
            const cut = try buildCut(
                gpa,
                doc,
                .{ .clip_path = shape.clip_path, .mask = shape.mask },
                ctm,
                .{ .shape = shape },
                pass,
                width,
                height,
                opts,
            );
            errdefer if (cut) |c| {
                var owned = c;
                owned.deinit(gpa);
            };
            const filtered = try buildFilter(
                gpa,
                doc,
                shape.filter,
                ctm,
                .{ .shape = shape },
                shape.current_color orelse callerColor(opts),
                width,
                height,
                opts,
            );
            if (cut != null or filtered != null) {
                try layers.open(gpa, 1.0, cut, filtered, opts.limits.max_layers);
                shape_layer = true;
            }
        }

        const surface = layers.target();
        // Kept so the stroke can start from the same place the fill did: both
        // draw the same run, and the fill leaves the pen past it.
        const pen_before_fill = pen;
        const fill_paint = resolveFill(shape, opts);
        const stroke = try resolveStroke(shape, opts);

        // §11.3: fill first, then stroke over it, per element.
        if (fill_paint) |paint| {
            var p: z2d.Path = .empty;
            defer p.deinit(gpa);

            // The viewBox mapping outside, the shape's own `transform` chain
            // inside, so that a `transform` is in user units like the path
            // data it applies to.
            try buildGeometry(gpa, &p, shape, ctm, .{
                .max_nodes = pass.nodes_left.*,
            }, doc, &pen, opts);
            try spendNodes(pass, p.nodes.items.len);

            // A shape with no geometry draws nothing, which is not an error;
            // `painter.fill` would take it too, but this says so on purpose.
            if (p.nodes.items.len != 0) {
                var built: Source = try makeSource(gpa, doc, shape, paint, ctm, opts);
                defer built.deinit(gpa);
                const fill_rule = shape.fill_rule orelse opts.fill_rule;
                switch (built) {
                    // A `<pattern>` is drawn rather than sampled, so what it
                    // needs is the region rather than a source: the same fill,
                    // into an alpha mask, which then cuts the lattice.
                    .tiled => |t| {
                        var region = try fillCoverage(gpa, surface, p.nodes.items, .{
                            .fill_rule = fill_rule,
                            .anti_aliasing_mode = opts.anti_aliasing_mode,
                            .tolerance = opts.tolerance,
                        });
                        defer region.deinit(gpa);
                        try paintTiled(
                            gpa,
                            doc,
                            surface,
                            t,
                            &region,
                            pathBox(p.nodes.items),
                            .{ .shape = shape },
                            ctm,
                            pass,
                            opts,
                        );
                    },
                    else => if (built.pattern()) |source| {
                        try z2d.painter.fill(gpa, surface, &source, p.nodes.items, .{
                            .fill_rule = fill_rule,
                            .anti_aliasing_mode = opts.anti_aliasing_mode,
                            .tolerance = opts.tolerance,
                        });
                    },
                }
            }
        }

        if (stroke) |*s| stroking: {
            // Built a second time, because the subpaths have to be left as
            // the document wrote them: a stroked open subpath is capped at its
            // ends rather than joined back to its start.
            //
            // The points are transformed exactly as the fill's are. z2d takes
            // the matrix *as well*, and uses it only to shape the pen -- which
            // is Cairo's model, and is what makes the pen warp under a
            // non-uniform scale as SVG says it must. Passing untransformed
            // points and relying on the matrix to place them draws the whole
            // document in the top-left corner at user-space coordinates.
            var p: z2d.Path = .empty;
            defer p.deinit(gpa);

            // The same pen the fill used, rewound: a run is filled and then
            // stroked, and both have to land in the same place.
            var stroke_pen = pen_before_fill;
            try buildGeometry(gpa, &p, shape, ctm, .{
                .max_nodes = pass.nodes_left.*,
                // Glyph outlines are closed contours whatever this says, so a
                // stroked `<text>` is outlined rather than having its letters
                // capped at their ends.
                .close_subpaths = false,
            }, doc, &stroke_pen, opts);
            try spendNodes(pass, p.nodes.items.len);

            if (p.nodes.items.len != 0) {
                // Where the matrix is a similarity, the pen is scaled here and
                // z2d is handed the identity; where it is not, z2d is handed
                // the matrix and shapes the pen itself. `uniformScale` says
                // why the two are not interchangeable in practice even though
                // they are in geometry.
                var nib = s.*;
                var pen_ctm: z2d.Transformation = ctm;
                if (uniformScale(ctm)) |factor| {
                    nib.scaleBy(factor);
                    pen_ctm = .identity;
                }

                var built: Source = try makeSource(gpa, doc, shape, nib.paint, ctm, opts);
                defer built.deinit(gpa);
                const stroke_opts: z2d.painter.StrokeOptions = .{
                    .line_width = nib.width,
                    .line_cap_mode = nib.cap,
                    .line_join_mode = nib.join,
                    .miter_limit = nib.miter_limit,
                    .dashes = nib.dashes(),
                    .dash_offset = nib.dash_offset,
                    .transformation = pen_ctm,
                    .anti_aliasing_mode = opts.anti_aliasing_mode,
                    .tolerance = opts.tolerance,
                };
                // A pattern on a `stroke` covers the stroked outline rather
                // than the filled one, and that outline is the only thing that
                // differs from the fill case -- so the mask is stroked and
                // everything after it is the same.
                if (built == .tiled) {
                    var region = try strokeCoverage(gpa, surface, p.nodes.items, stroke_opts);
                    defer region.deinit(gpa);
                    try paintTiled(
                        gpa,
                        doc,
                        surface,
                        built.tiled,
                        &region,
                        strokeBox(pathBox(p.nodes.items), nib.width, ctm),
                        .{ .shape = shape },
                        ctm,
                        pass,
                        opts,
                    );
                    break :stroking;
                }
                const source = built.pattern() orelse break :stroking;
                z2d.painter.stroke(gpa, surface, &source, p.nodes.items, stroke_opts) catch |err| switch (err) {
                    // A `transform` that collapses the plane -- `scale(0)` --
                    // has nothing to stroke through. Filling it draws nothing
                    // and stroking it should too, rather than failing.
                    error.InvalidMatrix => {},
                    else => |e| return e,
                };
            }
        }

        // Closed here rather than from a `defer`, because closing a layer can
        // now fail: a filter allocates. The failure path does not need it --
        // `drawDocument` unwinds the whole stack when a draw gives up.
        if (shape_layer) try layers.close(gpa);
    }
}

// -- filters -----------------------------------------------------------------

/// A `<filter>` read, measured and reduced to canvas pixels, waiting for the
/// layer it applies to to be finished.
///
/// Prepared when the layer is *opened* rather than when it is closed, because
/// everything it needs -- the element's bounding box, the matrix in force, the
/// `color` for a `currentColor` -- is known there and gone by the time the
/// layer comes off the stack.
const Filtered = struct {
    spec: filter.Filter,
    /// §15.7.5's region, in whole canvas pixels and already cut to the canvas.
    /// Everything the filter produces is confined to it.
    region: image.PixelBox,
    /// How much of a device pixel one user unit is, per axis. A filter runs on
    /// the canvas, so this is what turns a `stdDeviation` into a number of
    /// pixels. Rotation is deliberately not carried: see `filter.zig`.
    scale_x: f64,
    scale_y: f64,
    /// The matrix in force on the filtered element, for mapping a primitive's
    /// own subregion.
    ctm: z2d.Transformation,
    /// §7.11's bounding box of the filtered element, in its user space. Only
    /// meaningful when some units in the filter are `objectBoundingBox`.
    bbox: Box,
    /// What a `currentColor` in an `feFlood` resolves to.
    current: color.Color,

    fn deinit(self: *Filtered, gpa: Allocator) void {
        self.spec.deinit(gpa);
    }
};

/// Read the `<filter>` an element names and work out what it comes to on this
/// canvas, or null when the element names none.
///
/// §15.7.1: a `filter` naming something that is not a `<filter>`, or naming
/// nothing at all, means the element **is not rendered** -- not that the
/// filter is skipped. That is one of the few places in SVG where a dangling
/// reference is defined rather than an error, and resvg agrees. It arrives
/// here as a filter with no primitives, which produces transparent black,
/// which is the same answer by a shorter road.
fn buildFilter(
    gpa: Allocator,
    doc: *const document.Document,
    id: ?[]const u8,
    ctm: z2d.Transformation,
    subject: Subject,
    current: color.Color,
    width: i32,
    height: i32,
    opts: Options,
) Error!?Filtered {
    const name = id orelse return null;

    var spec: filter.Filter = blk: {
        const node = doc.ids.get(name) orelse break :blk .{};
        break :blk try filter.read(gpa, doc.tree, &doc.ids, &doc.stylesheet, node, doc.viewport()) orelse .{};
    };
    errdefer spec.deinit(gpa);

    // Measured only when something actually asks in bounding-box units, which
    // is the common case for the region and the rare one for the primitives.
    var measure: Measure = .{ .subject = subject };
    const bbox: Box = if (spec.units == .object_bounding_box or
        spec.primitive_units == .object_bounding_box)
        try measure.get(gpa, doc, opts)
    else
        .{ .width = 0, .height = 0 };

    const canvas: image.PixelBox = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height };
    const region_user: Box = switch (spec.units) {
        .user_space => .{ .x = spec.x, .y = spec.y, .width = spec.width, .height = spec.height },
        .object_bounding_box => .{
            .x = bbox.x + spec.x * bbox.width,
            .y = bbox.y + spec.y * bbox.height,
            .width = spec.width * bbox.width,
            .height = spec.height * bbox.height,
        },
    };

    return .{
        .spec = spec,
        .region = pixelBoxOf(mappedBounds(ctm, region_user)).intersect(canvas),
        .scale_x = std.math.hypot(ctm.ax, ctm.cx),
        .scale_y = std.math.hypot(ctm.by, ctm.dy),
        .ctm = ctm,
        .bbox = bbox,
        .current = current,
    };
}

/// A device-space box, rounded outwards to whole pixels.
///
/// Outwards rather than to nearest, so that a region is never narrower than
/// the document asked for: losing the outermost row of a blur is visible and
/// gaining a transparent one is not.
fn pixelBoxOf(b: Box) image.PixelBox {
    const lo_x = @floor(b.x);
    const lo_y = @floor(b.y);
    const hi_x = @ceil(b.x + b.width);
    const hi_y = @ceil(b.y + b.height);
    const limit = @as(f64, @floatFromInt(std.math.maxInt(i32)));
    return .{
        .x0 = @intFromFloat(std.math.clamp(lo_x, -limit, limit)),
        .y0 = @intFromFloat(std.math.clamp(lo_y, -limit, limit)),
        .x1 = @intFromFloat(std.math.clamp(hi_x, -limit, limit)),
        .y1 = @intFromFloat(std.math.clamp(hi_y, -limit, limit)),
    };
}

fn pixelBoxToUser(b: image.PixelBox) Box {
    return .{
        .x = @floatFromInt(b.x0),
        .y = @floatFromInt(b.y0),
        .width = @floatFromInt(b.x1 - b.x0),
        .height = @floatFromInt(b.y1 - b.y0),
    };
}

/// Run a filter chain over the layer it applies to, replacing the layer's
/// content with what came out.
fn runFilter(gpa: Allocator, target: *z2d.Surface, f: Filtered) Error!void {
    const clear: z2d.pixel.RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const n = f.spec.primitives.len;

    // §15.7.1's empty filter, and a region with no pixels in it, come to the
    // same thing: the element draws nothing.
    if (n == 0 or f.region.isEmpty()) {
        @memset(target.image_surface_rgba.buf, clear);
        return;
    }

    var chain: Chain = try .init(gpa, target, f);
    defer chain.deinit();

    for (f.spec.primitives, 0..) |p, i| {
        try chain.step(i, p);
        chain.release(i);
    }

    // The last primitive is the filter's output, whatever its `result` said.
    const out = &chain.results[n - 1].?;
    if (chain.spaces[n - 1] != .srgb) image.toSrgb(out);
    image.clipTo(out, f.region);
    @memcpy(target.image_surface_rgba.buf, out.image_surface_rgba.buf);
}

/// One input, resolved: a surface somebody else owns and the subregion its
/// content is confined to.
const Ref = struct {
    sfc: *z2d.Surface,
    box: image.PixelBox,
};

/// The state of one run of a filter chain.
const Chain = struct {
    gpa: Allocator,
    f: Filtered,
    width: i32,
    height: i32,
    /// `SourceGraphic`: the layer as the element painted it, cut to the region.
    source: z2d.Surface,
    source_space: filter.ColorSpace,
    /// `SourceAlpha`, built the first time something asks for it. Black has the
    /// same value in either colour space, so this one never needs converting.
    source_alpha: ?z2d.Surface,
    results: []?z2d.Surface,
    boxes: []image.PixelBox,
    spaces: []filter.ColorSpace,
    /// The last primitive that reads each result, so a buffer can be given back
    /// the moment nothing can refer to it again. Without this a chain of
    /// thirty primitives would hold thirty copies of the canvas.
    last_use: []usize,

    fn init(gpa: Allocator, target: *z2d.Surface, f: Filtered) Error!Chain {
        const n = f.spec.primitives.len;
        var source = try target.clone(gpa);
        errdefer source.deinit(gpa);
        image.clipTo(&source, f.region);

        const results = try gpa.alloc(?z2d.Surface, n);
        errdefer gpa.free(results);
        @memset(results, null);
        const boxes = try gpa.alloc(image.PixelBox, n);
        errdefer gpa.free(boxes);
        const spaces = try gpa.alloc(filter.ColorSpace, n);
        errdefer gpa.free(spaces);
        const last_use = try gpa.alloc(usize, n);
        errdefer gpa.free(last_use);

        var self: Chain = .{
            .gpa = gpa,
            .f = f,
            .width = target.getWidth(),
            .height = target.getHeight(),
            .source = source,
            .source_space = .srgb,
            .source_alpha = null,
            .results = results,
            .boxes = boxes,
            .spaces = spaces,
            .last_use = last_use,
        };
        self.planLifetimes();
        return self;
    }

    fn deinit(self: *Chain) void {
        self.source.deinit(self.gpa);
        if (self.source_alpha) |*s| s.deinit(self.gpa);
        for (self.results) |*r| {
            if (r.*) |*s| s.deinit(self.gpa);
        }
        self.gpa.free(self.results);
        self.gpa.free(self.boxes);
        self.gpa.free(self.spaces);
        self.gpa.free(self.last_use);
    }

    /// Which primitive last reads each earlier one's result.
    fn planLifetimes(self: *Chain) void {
        const prims = self.f.spec.primitives;
        for (self.last_use, 0..) |*slot, i| slot.* = i;
        // The last primitive is the filter's answer, so it outlives the loop.
        self.last_use[prims.len - 1] = prims.len;

        for (prims, 0..) |p, i| {
            switch (p.kind) {
                .gaussian_blur => |g| self.noteUse(i, g.in),
                .offset => |o| self.noteUse(i, o.in),
                .flood => {},
                .merge => |m| for (self.f.spec.merge_nodes[m.first..][0..m.count]) |in| {
                    self.noteUse(i, in);
                },
            }
        }
    }

    fn noteUse(self: *Chain, reader: usize, in: filter.Input) void {
        const j = self.slotOf(reader, in) orelse return;
        self.last_use[j] = @max(self.last_use[j], reader);
    }

    /// The primitive whose result `in` names, as seen from `reader`, or null
    /// when it names a source rather than a result.
    fn slotOf(self: *const Chain, reader: usize, in: filter.Input) ?usize {
        switch (in) {
            .source_graphic, .source_alpha => return null,
            // §15.7.2: at the head of a chain "the one before" means the
            // source, and after it, it means the one before.
            .previous => return if (reader == 0) null else reader - 1,
            .named => |want| {
                // Backwards, so that two primitives sharing a `result` name
                // resolve to the nearer one -- which is what a chain written
                // that way means.
                var i = reader;
                while (i > 0) {
                    i -= 1;
                    const r = self.f.spec.primitives[i].result orelse continue;
                    if (std.mem.eql(u8, r, want)) return i;
                }
                return null;
            },
        }
    }

    /// Give back every buffer that nothing after `i` can refer to.
    fn release(self: *Chain, i: usize) void {
        for (self.results[0 .. i + 1], 0..) |*r, j| {
            if (self.last_use[j] > i) continue;
            if (r.*) |*s| {
                s.deinit(self.gpa);
                r.* = null;
            }
        }
    }

    /// Hand back the surface an `in` names, converted into `want` if it is not
    /// already there.
    ///
    /// The conversion is in place, which is how resvg does it and is why a
    /// chain that alternates colour spaces loses a little precision each time:
    /// eight bits of linear light is a coarse thing to keep a picture in.
    fn resolve(self: *Chain, reader: usize, in: filter.Input, want: filter.ColorSpace) Error!Ref {
        // A named input nothing produced is an error rather than a silent
        // transparent black: the document meant a buffer that is not there.
        if (in == .named and self.slotOf(reader, in) == null) return error.BadFilterInput;

        if (in == .source_alpha) {
            if (self.source_alpha == null) {
                var a = try self.source.clone(self.gpa);
                image.alphaOnly(&a);
                self.source_alpha = a;
            }
            return .{ .sfc = &self.source_alpha.?, .box = self.f.region };
        }
        if (self.slotOf(reader, in)) |j| {
            const sfc = &self.results[j].?;
            if (self.spaces[j] != want) {
                convert(sfc, want);
                self.spaces[j] = want;
            }
            return .{ .sfc = sfc, .box = self.boxes[j] };
        }
        if (self.source_space != want) {
            convert(&self.source, want);
            self.source_space = want;
        }
        return .{ .sfc = &self.source, .box = self.f.region };
    }

    /// The subregion a primitive's output is confined to. §15.7.6.
    ///
    /// The default is the union of what its inputs covered, which for a chain
    /// that sets no subregions anywhere is the filter region throughout. An
    /// attribute overrides one edge of that at a time, so a primitive may set
    /// `x` alone and inherit the other three.
    fn subregion(self: *Chain, reader: usize, p: filter.Primitive, default: image.PixelBox) image.PixelBox {
        if (p.x == null and p.y == null and p.width == null and p.height == null) {
            return default.intersect(self.f.region);
        }
        _ = reader;
        // The defaults are in canvas pixels and the attributes are in user
        // units, so the two are met in user space: the default box is taken
        // back through the matrix, the attributes replace the edges they name,
        // and the result comes forward again.
        const inv = self.f.ctm.inverse() catch return default.intersect(self.f.region);
        const du = mappedBounds(inv, pixelBoxToUser(default));

        const bbox = self.f.bbox;
        const bbox_units = self.f.spec.primitive_units == .object_bounding_box;
        const x = if (p.x) |v| (if (bbox_units) bbox.x + v * bbox.width else v) else du.x;
        const y = if (p.y) |v| (if (bbox_units) bbox.y + v * bbox.height else v) else du.y;
        const w = if (p.width) |v| (if (bbox_units) v * bbox.width else v) else du.width;
        const h = if (p.height) |v| (if (bbox_units) v * bbox.height else v) else du.height;

        const dev = mappedBounds(self.f.ctm, .{ .x = x, .y = y, .width = w, .height = h });
        return pixelBoxOf(dev).intersect(self.f.region);
    }

    /// A length written in `primitiveUnits`, in canvas pixels.
    fn lengthX(self: *const Chain, v: f64) f64 {
        const user = if (self.f.spec.primitive_units == .object_bounding_box)
            v * self.f.bbox.width
        else
            v;
        return user * self.f.scale_x;
    }

    fn lengthY(self: *const Chain, v: f64) f64 {
        const user = if (self.f.spec.primitive_units == .object_bounding_box)
            v * self.f.bbox.height
        else
            v;
        return user * self.f.scale_y;
    }

    fn blank(self: *Chain) Error!z2d.Surface {
        return z2d.Surface.init(.image_surface_rgba, self.gpa, self.width, self.height);
    }

    /// Run one primitive and leave its output in `results[i]`.
    fn step(self: *Chain, i: usize, p: filter.Primitive) Error!void {
        const space = p.color_space;
        switch (p.kind) {
            .gaussian_blur => |g| {
                const in = try self.resolve(i, g.in, space);
                var out = try in.sfc.clone(self.gpa);
                errdefer out.deinit(self.gpa);
                try image.gaussianBlur(
                    self.gpa,
                    &out,
                    self.f.region,
                    self.lengthX(g.std_dev_x),
                    self.lengthY(g.std_dev_y),
                );
                self.finish(i, out, self.subregion(i, p, in.box), space);
            },
            .offset => |o| {
                const in = try self.resolve(i, o.in, space);
                var out = try self.blank();
                errdefer out.deinit(self.gpa);
                const dx = roundToPixel(self.lengthX(o.dx));
                const dy = roundToPixel(self.lengthY(o.dy));
                image.offset(&out, in.sfc, dx, dy);
                // §15.7.6 defaults a subregion to the union of its *inputs'*
                // subregions, and does not move it: a shadow offset past the
                // edge of what its input covered is cut off there, which is
                // why a drop shadow needs a region wide enough to hold it.
                self.finish(i, out, self.subregion(i, p, in.box), space);
            },
            .flood => |fl| {
                var out = try self.blank();
                errdefer out.deinit(self.gpa);
                // A flood covers its subregion and nothing else, so the
                // subregion is worked out first and then filled.
                const box = self.subregion(i, p, self.f.region);
                image.flood(&out, floodPixel(fl.color orelse self.f.current, fl.opacity, space), box);
                self.finish(i, out, box, space);
            },
            .merge => |m| {
                var out = try self.blank();
                errdefer out.deinit(self.gpa);
                var covered: image.PixelBox = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
                for (self.f.spec.merge_nodes[m.first..][0..m.count]) |node| {
                    const in = try self.resolve(i, node, space);
                    // Document order, first at the bottom: §15.19.
                    out.composite(in.sfc, .src_over, 0, 0, .{ .precision = .float });
                    covered = covered.unite(in.box);
                }
                self.finish(i, out, self.subregion(i, p, covered), space);
            },
        }
    }

    fn finish(
        self: *Chain,
        i: usize,
        out: z2d.Surface,
        box: image.PixelBox,
        space: filter.ColorSpace,
    ) void {
        var owned = out;
        image.clipTo(&owned, box);
        self.results[i] = owned;
        self.boxes[i] = box;
        self.spaces[i] = space;
    }
};

fn convert(sfc: *z2d.Surface, want: filter.ColorSpace) void {
    switch (want) {
        .linear_rgb => image.toLinear(sfc),
        .srgb => image.toSrgb(sfc),
    }
}

/// `feOffset` moves by whole pixels. The fractional part is rounded away
/// rather than resampled, which is what resvg does and what keeps an offset
/// from softening the thing it moves.
fn roundToPixel(v: f64) i32 {
    if (!std.math.isFinite(v)) return 0;
    const limit = @as(f64, @floatFromInt(std.math.maxInt(i32) / 2));
    return @intFromFloat(@round(std.math.clamp(v, -limit, limit)));
}

/// `flood-color` and `flood-opacity`, premultiplied and in the space the
/// primitive runs in.
fn floodPixel(c: color.Color, opacity: f64, space: filter.ColorSpace) z2d.pixel.RGBA {
    const alpha = std.math.clamp(c.alpha * opacity, 0, 1);
    const in_space: [3]u8 = switch (space) {
        .srgb => .{ c.r, c.g, c.b },
        .linear_rgb => .{ image.linearize(c.r), image.linearize(c.g), image.linearize(c.b) },
    };
    return z2d.pixel.RGBA.fromClamped(
        @as(f64, @floatFromInt(in_space[0])) / 255.0,
        @as(f64, @floatFromInt(in_space[1])) / 255.0,
        @as(f64, @floatFromInt(in_space[2])) / 255.0,
        alpha,
    );
}

/// What a shape is painted with: one colour, or a gradient to be built.
const Paint = union(enum) {
    pixel: z2d.Pixel,
    /// The id of a paint server, and the alpha to fade it by. The gradient
    /// itself is built at the point of painting, because it needs the shape's
    /// bounding box and that is not known until the path is.
    reference: struct { id: []const u8, alpha: f64 },
};

/// What one shape's `fill` comes to, or null when it is not painted at all.
///
/// Three alphas multiply together: the colour's own, from `#rrggbbaa` or
/// `rgba()`; `fill-opacity`; and `opacity`. For a shape that has a fill and
/// nothing else, multiplying `opacity` in like this is exactly what
/// compositing the shape as its own layer would produce -- which is why
/// `opacity` on a shape is implemented and `opacity` on a container, where
/// shapes could overlap, is refused by the reader instead.
fn resolveFill(shape: document.Shape, opts: Options) ?Paint {
    const alpha = (shape.fill_opacity orelse 1.0) * shape.opacity;
    if (alpha <= 0) return null;

    // A shape that named no `fill` is treated as though it had named
    // `currentColor`, which lands on the caller's colour by the same route --
    // `color`'s initial value is the caller's choice. The two spellings are
    // the same picture, and the icon sets in the world use one or the other.
    const named: ?color.Color = switch (shape.fill orelse .current) {
        .none => return null,
        .color => |c| c,
        .current => shape.current_color,
        .reference => |id| return .{ .reference = .{ .id = id, .alpha = alpha } },
    };

    const pixel = (if (named) |c| fadeColor(c, alpha) else fadePixel(opts.fill, alpha)) orelse
        return null;
    return .{ .pixel = pixel };
}

/// A parsed colour as a premultiplied pixel, faded by `alpha`.
fn fadeColor(c: color.Color, alpha: f64) ?z2d.Pixel {
    const a = c.alpha * alpha;
    if (a <= 0) return null;
    return .{ .rgba = .fromClamped(
        @as(f64, @floatFromInt(c.r)) / 255.0,
        @as(f64, @floatFromInt(c.g)) / 255.0,
        @as(f64, @floatFromInt(c.b)) / 255.0,
        a,
    ) };
}

/// The line style a stroke is drawn with, which is the same whether it is
/// painted in a colour or with a gradient.
fn strokeStyle(shape: document.Shape, width: f64, paint: Paint) Error!Stroke {
    return .{
        .paint = paint,
        .width = width,
        .cap = shape.stroke_linecap orelse .butt,
        .join = shape.stroke_linejoin orelse .miter,
        // SVG's initial `stroke-miterlimit` is **4**. z2d's is 10, which would
        // miter every corner sharper than about 11 degrees that should have
        // been bevelled -- a difference that shows on any spike and on nothing
        // else, so it is exactly the kind of wrong nobody notices. resvg was
        // asked, and it is 4.
        .miter_limit = shape.stroke_miterlimit orelse 4.0,
        .dash_offset = shape.stroke_dashoffset orelse 0,
    };
}

/// A z2d paint source, and whatever it had to build to exist.
///
/// A gradient owns its stops, so it cannot simply be returned by value and
/// pointed at -- `z2d.Pattern` holds a `*Gradient`. This keeps the gradient
/// beside the pattern so both live exactly as long as the draw that uses them.
const Source = union(enum) {
    pixel: z2d.Pixel,
    gradient: z2d.Gradient,
    /// A `<pattern>`, which is not a z2d pattern at all: it is a picture drawn
    /// once per tile and cut to the shape afterwards, so it carries what is
    /// needed to do that rather than anything z2d can paint with. `pattern()`
    /// returns null for it and `paintTiled` is what draws it.
    tiled: Tiled,
    /// A reference that resolves to nothing paintable -- a gradient with no
    /// stops. resvg draws nothing for one, and so does this.
    nothing,

    fn deinit(self: *Source, gpa: Allocator) void {
        switch (self.*) {
            // The stops are in a buffer the caller owns, so there is nothing
            // of z2d's to release.
            .gradient => |*g| g.deinit(gpa),
            else => {},
        }
    }

    fn pattern(self: *Source) ?z2d.Pattern {
        return switch (self.*) {
            .pixel => |p| .{ .opaque_pattern = .{ .pixel = p } },
            .gradient => |*g| g.asPattern(),
            .tiled, .nothing => null,
        };
    }
};

/// A `<pattern>` resolved far enough to draw.
const Tiled = struct {
    spec: pattern.Pattern,
    /// `fill-opacity` and `opacity` folded together, applied to the finished
    /// lattice once rather than to each tile.
    alpha: f64,
};

/// The stack of surfaces a document with composited groups is drawn onto.
///
/// The caller's surface is the bottom and is never owned. Each layer above it
/// is a transparent surface the size of the picture, drawn into as though it
/// were the real one and then composited down in two steps: its alpha is
/// multiplied by the group's `opacity`, and the result is painted over what is
/// below. That is what makes a group's opacity apply to the group *once*
/// rather than to each shape in it -- two overlapping shapes at half opacity
/// show only the upper one through the group, where halving each separately
/// would show both.
const Layers = struct {
    bottom: *z2d.Surface,
    stack: [max_stack]Entry = undefined,
    depth: usize = 0,

    /// Room for any `Limits.max_layers` a caller can sensibly ask for. The
    /// limit itself is checked against the caller's value, not this.
    const max_stack = 64;

    const Entry = struct {
        surface: z2d.Surface,
        opacity: f64,
        /// The alpha mask this layer is cut to, or null. Owned by the entry.
        clip: ?z2d.Surface = null,
        /// The filter this layer's finished picture is put through before any
        /// of that, or null. Owned by the entry.
        filter: ?Filtered = null,
    };

    fn target(self: *Layers) *z2d.Surface {
        if (self.depth == 0) return self.bottom;
        return &self.stack[self.depth - 1].surface;
    }

    fn open(
        self: *Layers,
        gpa: Allocator,
        opacity: f64,
        clip: ?z2d.Surface,
        filtered: ?Filtered,
        limit: usize,
    ) Error!void {
        errdefer if (clip) |c| {
            var owned = c;
            owned.deinit(gpa);
        };
        errdefer if (filtered) |f| {
            var owned = f;
            owned.deinit(gpa);
        };
        if (self.depth >= @min(limit, max_stack)) return error.TooManyLayers;
        const below = self.target();
        // Transparent and with an alpha channel whatever the destination is,
        // because the whole point is to know afterwards which of its pixels
        // were painted.
        const sfc = try z2d.Surface.init(
            .image_surface_rgba,
            gpa,
            below.getWidth(),
            below.getHeight(),
        );
        self.stack[self.depth] = .{
            .surface = sfc,
            .opacity = opacity,
            .clip = clip,
            .filter = filtered,
        };
        self.depth += 1;
    }

    fn close(self: *Layers, gpa: Allocator) Error!void {
        if (self.depth == 0) return;
        self.depth -= 1;
        var entry = self.stack[self.depth];
        defer entry.surface.deinit(gpa);

        defer if (entry.clip) |*c| c.deinit(gpa);
        defer if (entry.filter) |*f| f.deinit(gpa);

        // §15 first, and it is first for a reason: a filter reads the layer as
        // the element painted it, and the clip, the mask and the opacity all
        // apply to what the filter produced rather than to what it read.
        if (entry.filter) |f| try runFilter(gpa, &entry.surface, f);

        const below = self.target();
        // A clip is the same `dst_in` as the opacity, with a mask surface in
        // place of a uniform alpha: where the clip path covered nothing the
        // mask is zero, and the layer's alpha goes with it.
        if (entry.clip) |*c| {
            entry.surface.composite(c, .dst_in, 0, 0, .{ .precision = .float });
        }
        // `dst_in` against a uniform alpha multiplies the layer's own alpha by
        // it, which is the group opacity; then `src_over` paints the result
        // down. Two operations in one batch, so the intermediate never has to
        // be written anywhere.
        // In float precision rather than z2d's default of integer. Each
        // nested layer is another multiply rounded back into a byte, and two
        // of them put every pixel of a nested group about two levels away from
        // what resvg draws -- a uniform haze rather than a wrong picture, but
        // one that compounds with depth and costs nothing to avoid.
        const precision: z2d.compositor.SurfaceCompositor.RunOptions = .{ .precision = .float };
        const faded: z2d.Pixel = .{ .alpha8 = .{ .a = alphaByte(entry.opacity) } };
        z2d.compositor.SurfaceCompositor.run(&entry.surface, 0, 0, 1, .{
            .{ .operator = .dst_in, .src = .{ .pixel = faded } },
        }, precision);
        below.composite(&entry.surface, .src_over, 0, 0, precision);
    }

    fn deinit(self: *Layers, gpa: Allocator) void {
        // Only reached when a draw failed part way through; the layers a
        // successful one opened have all been closed.
        while (self.depth > 0) {
            self.depth -= 1;
            self.stack[self.depth].surface.deinit(gpa);
            if (self.stack[self.depth].clip) |*c| c.deinit(gpa);
            if (self.stack[self.depth].filter) |*f| f.deinit(gpa);
        }
    }
};

/// Which coordinate system a `clipPathUnits`, `maskUnits` or
/// `maskContentUnits` names.
const Units = enum {
    /// The user space in force on the element being clipped or masked -- not
    /// on the `<clipPath>` or `<mask>`, which have none of their own.
    user_space,
    /// Fractions of §7.11's object bounding box: the extent of the clipped
    /// element's own geometry, before its own `transform` and without its
    /// stroke.
    object_bounding_box,

    fn of(
        doc: *const document.Document,
        node: ztree.NodeId,
        name: []const u8,
        default: Units,
    ) Error!Units {
        const raw = doc.tree.attributeValue(node, "", name) orelse return default;
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len == 0) return default;
        if (std.mem.eql(u8, t, "userSpaceOnUse")) return .user_space;
        if (std.mem.eql(u8, t, "objectBoundingBox")) return .object_bounding_box;
        return error.UnsupportedClipUnits;
    }

    /// The matrix that takes a coordinate written in these units into the user
    /// space of the element being clipped.
    fn placement(self: Units, box: Box) z2d.Transformation {
        return switch (self) {
            .user_space => .identity,
            .object_bounding_box => .{
                .ax = box.width,
                .by = 0,
                .cx = 0,
                .dy = box.height,
                .tx = box.x,
                .ty = box.y,
            },
        };
    }
};

/// What has to be measured when something asks for `objectBoundingBox` units.
///
/// Held rather than measured up front because measuring costs a walk and a
/// rebuild of every path in it, and most documents' clips are in user space
/// and never ask.
const Subject = union(enum) {
    /// One element, measured from its own geometry.
    shape: document.Shape,
    /// A container, measured as the union of everything inside it.
    container: ztree.NodeId,
};

/// The cached answer to "what is this element's bounding box", so that an
/// element with both a clip and a mask in `objectBoundingBox` units is walked
/// once rather than twice.
const Measure = struct {
    subject: Subject,
    box: ?Box = null,

    fn get(
        self: *Measure,
        gpa: Allocator,
        doc: *const document.Document,
        opts: Options,
    ) Error!Box {
        if (self.box) |b| return b;
        const b = switch (self.subject) {
            .shape => |sh| try boundingBox(gpa, doc, sh, opts),
            .container => |node| try contentBox(gpa, doc, node, opts),
        };
        self.box = b;
        return b;
    }
};

/// The ids an element's `clip-path` and `mask` name.
const Cut = struct {
    clip_path: ?[]const u8,
    mask: ?[]const u8,
};

/// The alpha mask an element is cut to, or null when it names neither a clip
/// nor a mask.
///
/// An element may carry both, and §14.4 makes the result the intersection:
/// multiplying the two masks together with `dst_in` is that intersection, and
/// it means the layer machinery still sees one mask however many produced it.
fn buildCut(
    gpa: Allocator,
    doc: *const document.Document,
    cut: Cut,
    ctm: z2d.Transformation,
    subject: Subject,
    pass: Pass,
    width: i32,
    height: i32,
    opts: Options,
) Error!?z2d.Surface {
    if (cut.clip_path == null and cut.mask == null) return null;
    var measure: Measure = .{ .subject = subject };

    var result: ?z2d.Surface = null;
    errdefer if (result) |*r| r.deinit(gpa);

    if (cut.clip_path) |id| {
        result = try buildClip(gpa, doc, id, ctm, &measure, pass, width, height, opts);
    }
    if (cut.mask) |id| {
        var m = try buildMask(gpa, doc, id, ctm, &measure, pass, width, height, opts);
        if (result) |*r| {
            defer m.deinit(gpa);
            r.composite(&m, .dst_in, 0, 0, .{ .precision = .float });
        } else {
            result = m;
        }
    }
    return result;
}

/// Render a `<clipPath>` into an alpha mask the size of the picture.
///
/// The mask is opaque wherever the clip path's shapes cover and transparent
/// everywhere else, which is what `dst_in` wants: §14.3 makes the clip the
/// *union* of its children's fill regions, so they are simply all filled into
/// the same surface.
///
/// The shapes are drawn under the matrix in force on the clipped element, not
/// on the `<clipPath>` -- `clipPathUnits="userSpaceOnUse"` means the user space
/// of the thing being clipped, and `objectBoundingBox` means fractions of that
/// element's own box. Each may carry its own `transform`, and a `clip-rule`
/// decides its winding; and §14.3 gives the `<clipPath>` element itself a
/// `transform` that applies to all of them together.
///
/// A `<clipPath>` may itself carry a `clip-path`, and then the clip is the
/// intersection of the two. That is a second surface and a second walk, which
/// is why `Limits.max_mask_depth` bounds how far it goes.
fn buildClip(
    gpa: Allocator,
    doc: *const document.Document,
    id: []const u8,
    ctm: z2d.Transformation,
    measure: *Measure,
    pass: Pass,
    width: i32,
    height: i32,
    opts: Options,
) Error!z2d.Surface {
    if (pass.depth >= opts.limits.max_mask_depth) return error.TooManyMaskHops;
    const node = doc.ids.get(id) orelse return error.UnknownReference;
    if (!std.mem.eql(u8, doc.tree.node(node).name.local, "clipPath")) return error.BadClipPath;

    const units = try Units.of(doc, node, "clipPathUnits", .user_space);
    const box = if (units == .object_bounding_box) try measure.get(gpa, doc, opts) else Box{
        .width = 0,
        .height = 0,
    };
    // A shape with no extent in one direction has no box to be fractions of,
    // and a clip that is fractions of nothing covers nothing. `or`, not `and`:
    // a box of some width and no height is just as degenerate, and letting it
    // through hands z2d a matrix that collapses the plane.
    if (units == .object_bounding_box and (!(box.width > 0) or !(box.height > 0))) {
        return z2d.Surface.init(.image_surface_alpha8, gpa, width, height);
    }
    // §14.3: a `transform` on the `<clipPath>` itself applies, inside the
    // units mapping. `subtree` leaves the root's attributes alone, so it is
    // folded in here -- and nowhere else, since a `transform` on a `<mask>`
    // does not apply at all.
    const placed = ctm.mul(units.placement(box)).mul(try doc.transformOf(node));
    if (!transform.isFinite(placed)) return error.NonFiniteTransform;

    var mask = try z2d.Surface.init(.image_surface_alpha8, gpa, width, height);
    errdefer mask.deinit(gpa);

    const white: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };

    var clip_pen: Pen = .{};
    var it = doc.subtree(node, placed);
    while (try it.next()) |item| {
        const shape = switch (item) {
            .shape => |sh| sh,
            // A `<g>` inside a `<clipPath>` contributes its children and
            // nothing else; there is no layer to composite inside a mask.
            else => continue,
        };
        var p: z2d.Path = .empty;
        defer p.deinit(gpa);
        // Through the text-aware builder: §14.3 lets a `<clipPath>` hold a
        // `<text>`, and cutting a shape to the letters of a word is a thing
        // documents actually do.
        try buildGeometry(gpa, &p, shape, shape.transform, .{
            .max_nodes = pass.nodes_left.*,
        }, doc, &clip_pen, opts);
        try spendNodes(pass, p.nodes.items.len);
        if (p.nodes.items.len == 0) continue;

        try z2d.painter.fill(gpa, &mask, &white, p.nodes.items, .{
            // §14.3's `clip-rule`, which is a property of its own: a document
            // can fill nonzero and clip even-odd, so reading `fill-rule` here
            // would cut the wrong hole.
            .fill_rule = shape.clip_rule orelse .non_zero,
            .anti_aliasing_mode = opts.anti_aliasing_mode,
            .tolerance = opts.tolerance,
        });
    }

    // §14.3.5: a `clip-path` on the `<clipPath>` itself intersects what its
    // children came to. Measured against the same element, because the units
    // of a clip on a clip are still the clipped element's.
    if (try clipOnClip(doc, node)) |outer| {
        var deeper = pass;
        deeper.depth += 1;
        var second = try buildClip(gpa, doc, outer, ctm, measure, deeper, width, height, opts);
        defer second.deinit(gpa);
        mask.composite(&second, .dst_in, 0, 0, .{ .precision = .float });
    }
    return mask;
}

/// Render a `<mask>` into the alpha mask that `dst_in` cuts a layer with.
///
/// §14.4. The content is drawn as an ordinary picture -- gradients, groups,
/// opacity and all -- and then each pixel's *luminance* becomes its alpha.
/// That is the whole difference from a clip: a clip asks where its shapes are,
/// a mask asks how bright they are, so a white shape masks nothing away and a
/// grey one halves what is under it. `mask-type="alpha"` asks how opaque they
/// are instead, and then the colour does not matter.
///
/// Two accidents make the luminance pass exact rather than approximate. The
/// surface holds premultiplied colour, and luminance is linear, so the
/// luminance of the premultiplied channels is already the luminance times the
/// alpha -- which is the product §14.4 asks for, with no demultiply to round
/// through. And the coefficients are applied to the bytes as stored: resvg
/// does not linearize first, and measuring it says so plainly, because `#808080`
/// yields an alpha of 128 where a linearized one would yield 55.
fn buildMask(
    gpa: Allocator,
    doc: *const document.Document,
    id: []const u8,
    ctm: z2d.Transformation,
    measure: *Measure,
    pass: Pass,
    width: i32,
    height: i32,
    opts: Options,
) Error!z2d.Surface {
    if (pass.depth >= opts.limits.max_mask_depth) return error.TooManyMaskHops;
    const node = doc.ids.get(id) orelse return error.UnknownReference;
    if (!std.mem.eql(u8, doc.tree.node(node).name.local, "mask")) return error.BadMask;

    const region_units = try Units.of(doc, node, "maskUnits", .object_bounding_box);
    const content_units = try Units.of(doc, node, "maskContentUnits", .user_space);
    const kind = try MaskType.of(doc, node);

    // §14.4's defaults are a tenth of the box outside it on every side, which
    // leaves room for a mask whose content is blurred or stroked past the edge
    // of what it masks.
    const region = try maskRegion(doc, node, region_units);

    var out = try z2d.Surface.init(.image_surface_alpha8, gpa, width, height);
    errdefer out.deinit(gpa);
    // A region with no extent masks everything away, and so does a mask in
    // bounding-box units on a shape that has no box. Both leave `out`
    // transparent, which is that answer.
    if (!(region.width > 0) or !(region.height > 0)) return out;

    const box = if (region_units == .object_bounding_box or
        content_units == .object_bounding_box)
        try measure.get(gpa, doc, opts)
    else
        Box{ .width = 0, .height = 0 };
    if ((region_units == .object_bounding_box or content_units == .object_bounding_box) and
        (!(box.width > 0) or !(box.height > 0)))
    {
        return out;
    }

    // The mask's content is drawn into a colour surface, because luminance
    // needs colour; the alpha surface above is what it is turned into.
    var canvas = try z2d.Surface.init(.image_surface_rgba, gpa, width, height);
    defer canvas.deinit(gpa);

    const content = ctm.mul(content_units.placement(box));
    if (!transform.isFinite(content)) return error.NonFiniteTransform;

    {
        var layers: Layers = .{ .bottom = &canvas };
        defer layers.deinit(gpa);
        var it = doc.subtree(node, content);
        // The content matrix rides in the iterator rather than in `base`, so
        // that `<g transform>` inside the mask composes on top of it exactly
        // as it would in the document.
        //
        // A deeper `Pass`, because the content may reach back out: a `<use>`
        // inside a mask can name the very element the mask is on, and then the
        // recursion is through the *drawing* rather than through a `mask`
        // attribute. Counting it here is what bounds that too.
        try drawItems(gpa, &layers, doc, &it, .{
            .base = .identity,
            .nodes_left = pass.nodes_left,
            .depth = pass.depth + 1,
        }, opts);
    }

    try coverage(kind, &canvas, &out, ctm.mul(region_units.placement(box)), region);

    // §14.4: a `mask` on the `<mask>` itself masks the mask.
    if (try maskOnMask(doc, node)) |outer| {
        var deeper = pass;
        deeper.depth += 1;
        var second = try buildMask(gpa, doc, outer, ctm, measure, deeper, width, height, opts);
        defer second.deinit(gpa);
        out.composite(&second, .dst_in, 0, 0, .{ .precision = .float });
    }
    return out;
}

/// A `<mask>`'s `x`, `y`, `width` and `height`, in whatever units it named.
///
/// The defaults are §14.4's: `-10%`, `-10%`, `120%`, `120%`. In bounding-box
/// units a percentage is just the number over a hundred, so both spellings of
/// the default come out the same; in user space they are percentages of the
/// viewport like any other length.
fn maskRegion(
    doc: *const document.Document,
    node: ztree.NodeId,
    units: Units,
) Error!Box {
    const viewport = doc.viewport();
    const read = struct {
        fn f(
            d: *const document.Document,
            n: ztree.NodeId,
            name: []const u8,
            axis: length.Axis,
            u: Units,
            vp: length.Viewport,
            default: f64,
        ) Error!f64 {
            const raw = d.tree.attributeValue(n, "", name) orelse return default;
            const t = std.mem.trim(u8, raw, " \t\r\n");
            if (t.len == 0) return default;
            if (u == .user_space) return length.parse(t, axis, vp);
            // A fraction of the box, so there is no viewport in it: a bare
            // number is the fraction and a percentage is that over a hundred.
            if (std.mem.endsWith(u8, t, "%")) {
                const v = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch
                    return error.BadLength;
                return v / 100.0;
            }
            return std.fmt.parseFloat(f64, t) catch error.BadLength;
        }
    }.f;
    return .{
        .x = try read(doc, node, "x", .x, units, viewport, -0.1),
        .y = try read(doc, node, "y", .y, units, viewport, -0.1),
        .width = try read(doc, node, "width", .x, units, viewport, 1.2),
        .height = try read(doc, node, "height", .y, units, viewport, 1.2),
    };
}

/// A `clip-path` on a `<clipPath>` element itself, or null.
fn clipOnClip(doc: *const document.Document, node: ztree.NodeId) Error!?[]const u8 {
    return referenceAttribute(doc, node, "clip-path");
}

/// A `mask` on a `<mask>` element itself, or null.
fn maskOnMask(doc: *const document.Document, node: ztree.NodeId) Error!?[]const u8 {
    return referenceAttribute(doc, node, "mask");
}

/// The id a `url(#...)` attribute names, read straight off the tree.
///
/// The walk reads these for the elements it yields, but a `<clipPath>` and a
/// `<mask>` are roots the walk never visits as a child, so their own are read
/// here instead. Ignoring them would draw a clip wider than the document asked
/// for, which is the kind of quiet difference this library exists to avoid.
fn referenceAttribute(
    doc: *const document.Document,
    node: ztree.NodeId,
    name: []const u8,
) Error!?[]const u8 {
    const raw = doc.tree.attributeValue(node, "", name) orelse return null;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0 or std.mem.eql(u8, t, "none")) return null;
    const open = std.mem.find(u8, t, "#") orelse return error.BadReference;
    if (!std.mem.startsWith(u8, t, "url(")) return error.BadReference;
    const close = std.mem.lastIndexOfScalar(u8, t, ')') orelse return error.BadReference;
    if (close <= open + 1) return error.BadReference;
    return std.mem.trim(u8, t[open + 1 .. close], " \t\r\n\"\'");
}

/// What a `<mask>` takes from its content: how bright it is, or how opaque.
const MaskType = enum {
    /// The default, and the one §14.4 defines.
    luminance,
    /// SVG 2's `mask-type: alpha`, which takes the content's alpha and ignores
    /// its colour. resvg implements it, so this does too -- and refuses a
    /// spelling it does not know rather than falling back to luminance, which
    /// would draw a mask the document did not ask for.
    ///
    alpha,

    fn of(doc: *const document.Document, node: ztree.NodeId) Error!MaskType {
        // A presentation property like any other, so it comes through the
        // cascade: `style="mask-type:alpha"` and a `mask-type` rule both work.
        const raw = css.property(&doc.stylesheet, doc.tree, node, "mask-type") orelse
            return .luminance;
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len == 0 or std.mem.eql(u8, t, "luminance")) return .luminance;
        if (std.mem.eql(u8, t, "alpha")) return .alpha;
        return error.BadMask;
    }
};

/// Turn a drawn mask into the alpha mask it stands for, clipped to its region.
///
/// `region` is in the space `placement` maps into pixels, and everything
/// outside it is left at zero -- which is §14.4's statement that a mask does
/// not extend past its own `x`, `y`, `width` and `height`. The rectangle is
/// mapped rather than intersected, so a rotated element's mask region rotates
/// with it, and the corners are taken as the axis-aligned span of the four
/// mapped ones. That is exact for the similarity transforms a mask region is
/// written under and generous for the rest, which errs towards drawing what
/// the document asked for.
fn coverage(
    kind: MaskType,
    canvas: *const z2d.Surface,
    out: *z2d.Surface,
    placement: z2d.Transformation,
    region: Box,
) Error!void {
    const bounds = mappedBounds(placement, region);
    const width = out.getWidth();
    const height = out.getHeight();

    // Clamped at both ends before the cast, not just at the end that would
    // read outside the surface. `@intFromFloat` into an `i32` is a *panic* for
    // anything the type cannot hold, and a mask region is four numbers the
    // document chose -- `width="1e300"` is a crash rather than a large
    // rectangle if only the near end is bounded.
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const lo_x: i32 = @intFromFloat(std.math.clamp(@floor(bounds.x), 0.0, w));
    const lo_y: i32 = @intFromFloat(std.math.clamp(@floor(bounds.y), 0.0, h));
    const hi_x: i32 = @intFromFloat(std.math.clamp(@ceil(bounds.x + bounds.width), 0.0, w));
    const hi_y: i32 = @intFromFloat(std.math.clamp(@ceil(bounds.y + bounds.height), 0.0, h));

    var y = lo_y;
    while (y < hi_y) : (y += 1) {
        var x = lo_x;
        while (x < hi_x) : (x += 1) {
            const px = canvas.getPixel(x, y) orelse continue;
            const rgba = z2d.pixel.RGBA.fromPixel(px);
            const a: u8 = switch (kind) {
                // §14.4's coefficients, on the bytes as stored. They sum to
                // one, so a premultiplied channel set can never exceed its own
                // alpha and the result is always a valid alpha.
                .luminance => @intFromFloat(@round(std.math.clamp(
                    0.2125 * @as(f64, @floatFromInt(rgba.r)) +
                        0.7154 * @as(f64, @floatFromInt(rgba.g)) +
                        0.0721 * @as(f64, @floatFromInt(rgba.b)),
                    0.0,
                    255.0,
                ))),
                .alpha => rgba.a,
            };
            out.putPixel(x, y, .{ .alpha8 = .{ .a = a } });
        }
    }
}

/// The axis-aligned span of a rectangle after a matrix.
fn mappedBounds(m: z2d.Transformation, box: Box) Box {
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    const xs = [2]f64{ box.x, box.x + box.width };
    const ys = [2]f64{ box.y, box.y + box.height };
    for (xs) |x| for (ys) |y| {
        // z2d's own, rather than the arithmetic written out here. Its matrix
        // is `[ax by tx; cx dy ty]`, so `by` and `cx` are not where a reader
        // coming from SVG's `matrix(a b c d e f)` expects them, and writing
        // the multiply by hand got them the wrong way round once already --
        // which a rotated mask region showed and nothing else would have.
        var px = x;
        var py = y;
        m.userToDevice(&px, &py);
        min_x = @min(min_x, px);
        min_y = @min(min_y, py);
        max_x = @max(max_x, px);
        max_y = @max(max_y, py);
    };
    // All four, because a NaN coordinate leaves the others perfectly finite
    // and would be carried into a cast that cannot take it.
    if (!std.math.isFinite(min_x) or !std.math.isFinite(min_y) or
        !std.math.isFinite(max_x) or !std.math.isFinite(max_y))
    {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

/// Paint a shape with a `<pattern>`.
///
/// §13.3. The tile is drawn once per cell of the lattice, each clipped to its
/// own cell, and the whole lattice is then cut to the shape by the coverage
/// mask the caller has already painted. Three properties force that shape:
///
/// * `overflow` on a `<pattern>` is `hidden`, so content running past a tile's
///   edge is cut off rather than appearing in the neighbour. A pattern of
///   overlapping circles is a completely different picture without it, and
///   resvg honours it -- so every tile needs a clip, and drawing one tile and
///   stamping it is not enough.
/// * `patternTransform`, and any rotation on the shape itself, turn the
///   lattice. Stamping an axis-aligned tile cannot place a rotated one, so the
///   content is redrawn per cell under the full matrix instead.
/// * The tile's contents are an arbitrary picture -- groups, gradients, clips,
///   masks -- so drawing them means the same `drawItems` that draws the
///   document, which is also what makes a pattern inside a mask work.
///
/// Each cell's scratch surfaces are the size of that cell's *device
/// footprint*, not of the picture, so the total cost is proportional to the
/// area painted rather than to the area times the number of tiles.
fn paintTiled(
    gpa: Allocator,
    doc: *const document.Document,
    target: *z2d.Surface,
    tiled: Tiled,
    mask: *z2d.Surface,
    device_box: Box,
    subject: Subject,
    ctm: z2d.Transformation,
    pass: Pass,
    opts: Options,
) Error!void {
    if (pass.depth >= opts.limits.max_mask_depth) return error.TooManyMaskHops;
    const spec = tiled.spec;
    const content = spec.content orelse return;

    var measure: Measure = .{ .subject = subject };

    // The tile is converted into user space *first*, rather than the units
    // mapping being left in the matrix. `patternUnits` says where the tile is
    // and `patternContentUnits` says where its contents are, and the two
    // default to opposite systems -- so leaving a bounding-box scale in the
    // matrix would put the contents through it as well, and a `<rect
    // width="4">` inside a tile that is a quarter of a 32-unit shape would
    // come out 128 units across instead of 4.
    var tile: Box = .{
        .x = spec.x,
        .y = spec.y,
        .width = spec.width,
        .height = spec.height,
    };
    if (spec.units == .object_bounding_box) {
        const box = try measure.get(gpa, doc, opts);
        if (!(box.width > 0) or !(box.height > 0)) return;
        tile = .{
            .x = box.x + spec.x * box.width,
            .y = box.y + spec.y * box.height,
            .width = spec.width * box.width,
            .height = spec.height * box.height,
        };
    }
    if (!(tile.width > 0) or !(tile.height > 0)) return;

    // What is left is the shape's own transform with `patternTransform`
    // inside it, which is the order a gradient's `gradientTransform` takes.
    const place = ctm.mul(spec.transform);
    if (!transform.isFinite(place)) return error.NonFiniteTransform;

    // What maps the tile's contents into the tile, with the tile's own corner
    // as the origin -- confirmed against resvg, which draws a pattern's
    // content relative to its `x` and `y` rather than to the user origin.
    // §13.3: a `viewBox` replaces `patternContentUnits` outright, fitting the
    // contents into the tile by §7.8 exactly as the root `<svg>` is fitted
    // into its viewport.
    const tile_content: z2d.Transformation = if (spec.view_box) |vb|
        document.viewBoxTransform(vb, spec.preserve_aspect_ratio, 0, 0, tile.width, tile.height)
    else if (spec.content_units == .object_bounding_box) content_box: {
        const box = try measure.get(gpa, doc, opts);
        if (!(box.width > 0) or !(box.height > 0)) return;
        break :content_box .{
            .ax = box.width,
            .by = 0,
            .cx = 0,
            .dy = box.height,
            .tx = 0,
            .ty = 0,
        };
    } else .identity;

    // Whether the tile has to be clipped at all.
    //
    // §13.3 hides what overflows a tile, but clipping content that was never
    // going to overflow is not free: the clip's edge and the content's edge
    // are then the *same* edge, anti-aliased twice, and multiplying one
    // coverage by the other squares it. A half-covered pixel along the tile
    // boundary comes out a quarter covered, which is a visibly thin, pale
    // fringe everywhere the content reaches its tile's edge -- which, for the
    // usual tile whose content fills it, is every edge in the picture.
    //
    // So the contents are measured once, strokes included, and the clip is
    // only built for a tile they actually leave.
    const extent = mappedBounds(
        tile_content,
        try contentExtent(gpa, doc, content, true, opts),
    );
    const needs_clip = extent.x < -0.001 or extent.y < -0.001 or
        extent.x + extent.width > tile.width + 0.001 or
        extent.y + extent.height > tile.height + 0.001;

    // Which cells are needed: take the device area actually being painted back
    // into pattern space, and cover its extent.
    const inverse = place.inverse() catch return;
    const painted = intersect(device_box, .{
        .width = @floatFromInt(target.getWidth()),
        .height = @floatFromInt(target.getHeight()),
    }) orelse return;
    const in_pattern = mappedBounds(inverse, painted);

    const first_i = @floor((in_pattern.x - tile.x) / tile.width);
    const last_i = @ceil((in_pattern.x + in_pattern.width - tile.x) / tile.width);
    const first_j = @floor((in_pattern.y - tile.y) / tile.height);
    const last_j = @ceil((in_pattern.y + in_pattern.height - tile.y) / tile.height);
    if (!std.math.isFinite(first_i) or !std.math.isFinite(last_i) or
        !std.math.isFinite(first_j) or !std.math.isFinite(last_j)) return;

    const columns = last_i - first_i;
    const rows = last_j - first_j;
    if (!(columns > 0) or !(rows > 0)) return;
    const budget: f64 = @floatFromInt(opts.limits.max_pattern_tiles);
    if (columns * rows > budget) return error.TooManyPatternTiles;

    // The whole lattice is assembled here first, so that the shape's coverage
    // cuts it once rather than each tile being cut twice.
    var plane = try z2d.Surface.init(
        .image_surface_rgba,
        gpa,
        target.getWidth(),
        target.getHeight(),
    );
    defer plane.deinit(gpa);

    const precision: z2d.compositor.SurfaceCompositor.RunOptions = .{ .precision = .float };
    const white: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };

    var j = first_j;
    while (j < last_j) : (j += 1) {
        var i = first_i;
        while (i < last_i) : (i += 1) {
            const cell: Box = .{
                .x = tile.x + i * tile.width,
                .y = tile.y + j * tile.height,
                .width = tile.width,
                .height = tile.height,
            };
            const footprint = intersect(mappedBounds(place, cell), painted) orelse continue;
            const fx: i32 = @intFromFloat(@floor(footprint.x));
            const fy: i32 = @intFromFloat(@floor(footprint.y));
            const fw: i32 = @intFromFloat(@ceil(footprint.x + footprint.width) - @floor(footprint.x));
            const fh: i32 = @intFromFloat(@ceil(footprint.y + footprint.height) - @floor(footprint.y));
            if (fw <= 0 or fh <= 0) continue;

            // Everything for this cell is drawn as though the footprint's
            // corner were the origin, so the surfaces are the size of one tile
            // rather than of the picture.
            const to_cell: z2d.Transformation = z2d.Transformation.identity
                .translate(-@as(f64, @floatFromInt(fx)), -@as(f64, @floatFromInt(fy)))
                .mul(place);

            var ink = try z2d.Surface.init(.image_surface_rgba, gpa, fw, fh);
            defer ink.deinit(gpa);
            var cut: ?z2d.Surface = if (needs_clip)
                try z2d.Surface.init(.image_surface_alpha8, gpa, fw, fh)
            else
                null;
            defer if (cut) |*c| c.deinit(gpa);

            // The cell's own rectangle, which is what `overflow: hidden` cuts
            // the content to.
            if (cut) |*cut_surface| {
                var rect: z2d.Path = .empty;
                defer rect.deinit(gpa);
                try document.buildShape(&rect, gpa, .{ .rect = .{
                    .x = cell.x,
                    .y = cell.y,
                    .width = cell.width,
                    .height = cell.height,
                } }, to_cell, .{ .max_nodes = pass.nodes_left.* });
                if (rect.nodes.items.len == 0) continue;
                // Anti-aliased, and the cells are summed rather than painted
                // over each other -- see the `plus` below. A hard edge here
                // would avoid the seam too, but at the cost of cutting the
                // *content's* own anti-aliasing wherever it reaches the tile
                // boundary, which for a tile whose content fills it is every
                // edge in the picture.
                try z2d.painter.fill(gpa, cut_surface, &white, rect.nodes.items, .{
                    .anti_aliasing_mode = opts.anti_aliasing_mode,
                    .tolerance = opts.tolerance,
                });
            }

            {
                var layers: Layers = .{ .bottom = &ink };
                defer layers.deinit(gpa);
                var it = doc.subtree(content, to_cell
                    .translate(cell.x, cell.y)
                    .mul(tile_content));
                try drawItems(gpa, &layers, doc, &it, .{
                    .base = .identity,
                    .nodes_left = pass.nodes_left,
                    .depth = pass.depth + 1,
                }, opts);
            }

            if (cut) |*c| ink.composite(c, .dst_in, 0, 0, precision);
            // `plus`, not `src_over`. Neighbouring cells share an edge, and
            // the anti-aliased clip gives each of them part of the pixels
            // along it. Painting one over the other leaves about three
            // quarters coverage where there should be one -- a seam along
            // every tile boundary. Adding them gives exactly one, because the
            // cells partition the plane and the two parts are the whole.
            plane.composite(&ink, .plus, fx, fy, precision);
        }
    }

    // `fill-opacity` and `opacity` apply to the finished lattice, not to each
    // tile: fading them one at a time would show the seams where neighbours
    // overlap.
    if (tiled.alpha < 1.0) {
        const faded: z2d.Pixel = .{ .alpha8 = .{ .a = alphaByte(tiled.alpha) } };
        z2d.compositor.SurfaceCompositor.run(&plane, 0, 0, 1, .{
            .{ .operator = .dst_in, .src = .{ .pixel = faded } },
        }, precision);
    }
    plane.composite(mask, .dst_in, 0, 0, precision);
    target.composite(&plane, .src_over, 0, 0, precision);
}

/// The region a fill would cover, as an alpha mask the size of the picture.
fn fillCoverage(
    gpa: Allocator,
    like: *const z2d.Surface,
    nodes: []const PathNode,
    fill_opts: z2d.painter.FillOptions,
) Error!z2d.Surface {
    var mask = try z2d.Surface.init(
        .image_surface_alpha8,
        gpa,
        like.getWidth(),
        like.getHeight(),
    );
    errdefer mask.deinit(gpa);
    const white: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
    try z2d.painter.fill(gpa, &mask, &white, nodes, fill_opts);
    return mask;
}

/// The region a stroke would cover, as an alpha mask the size of the picture.
fn strokeCoverage(
    gpa: Allocator,
    like: *const z2d.Surface,
    nodes: []const PathNode,
    stroke_opts: z2d.painter.StrokeOptions,
) Error!z2d.Surface {
    var mask = try z2d.Surface.init(
        .image_surface_alpha8,
        gpa,
        like.getWidth(),
        like.getHeight(),
    );
    errdefer mask.deinit(gpa);
    const white: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
    z2d.painter.stroke(gpa, &mask, &white, nodes, stroke_opts) catch |err| switch (err) {
        // As in the ordinary stroke: a matrix that collapses the plane has
        // nothing to stroke through, and covers nothing.
        error.InvalidMatrix => {},
        else => |e| return e,
    };
    return mask;
}

/// A stroked path's device extent: the path's own, grown by half the pen.
///
/// Generous rather than exact -- a join can reach a miter limit past this, and
/// it costs a few tiles that turn out to be empty rather than a wrong picture.
fn strokeBox(box: Box, width: f64, ctm: z2d.Transformation) Box {
    const scale = @sqrt(@abs(ctm.determinant()));
    const pad = @abs(width) * 0.5 * (if (std.math.isFinite(scale) and scale > 0) scale else 1.0) + 1.0;
    return .{
        .x = box.x - pad,
        .y = box.y - pad,
        .width = box.width + 2 * pad,
        .height = box.height + 2 * pad,
    };
}

/// Build a shape's geometry into `p`, whichever kind it is.
///
/// `document.buildShape` covers every geometry but text, which needs a font it
/// has no way to reach. This is where the two meet, so that everything after
/// it -- filling, stroking, clipping, measuring -- sees one path and does not
/// care which kind of element made it.
fn buildGeometry(
    gpa: Allocator,
    p: *z2d.Path,
    shape: document.Shape,
    ctm: z2d.Transformation,
    build_opts: path.Options,
    doc: *const document.Document,
    pen: ?*Pen,
    opts: Options,
) Error!void {
    var scratch: Pen = .{};
    return switch (shape.geometry) {
        .text => |run| buildText(gpa, p, run, shape, ctm, pen orelse &scratch, doc, build_opts, opts),
        else => document.buildShape(p, gpa, shape.geometry, ctm, build_opts),
    };
}

/// Where the next run of text begins.
///
/// A `<text>` is a sequence of runs sharing a pen: a `<tspan>` with no position
/// of its own carries on from wherever the previous run left off, so drawing
/// one run means knowing what the ones before it came to. The renderer keeps
/// this across the runs of a text element and resets it when a new one starts.
const Pen = struct {
    x: f64 = 0,
    y: f64 = 0,
    /// Whether anything has been drawn yet in this `<text>`. Until something
    /// has, a run with no position of its own has nothing to carry on from.
    placed: bool = false,
};

/// Build a `<text>` run's glyph outlines into `p`, under `ctm`.
///
/// Everything after this treats the result as an ordinary path, which is the
/// whole point of doing it this way: text is filled, stroked, clipped, masked
/// and pattern-filled by the same code as every other shape, rather than by a
/// second set of routines that would drift from it.
///
/// The caller's `FontResolver` runs here. A document with text and no resolver
/// is refused -- `error.NoFontSupplied` -- rather than drawn with the text
/// quietly missing.
fn buildText(
    gpa: Allocator,
    p: *z2d.Path,
    run: shapes.Text,
    shape: document.Shape,
    ctm: z2d.Transformation,
    pen: *Pen,
    doc: *const document.Document,
    build_opts: path.Options,
    opts: Options,
) Error!void {
    var font = try faceFor(shape, opts);
    const size = shape.font_size orelse 16;

    const collapsed = try collapseWhitespace(gpa, run.utf8);
    defer gpa.free(collapsed);

    // §10.4: `x` and `y` are absolute and start a new *chunk*; `dx` and `dy`
    // shift the pen without starting one. A run with neither carries on.
    if (run.starts_element or !pen.placed) {
        pen.x = 0;
        pen.y = 0;
        pen.placed = true;
    }
    var starts_chunk = run.starts_element;
    if (run.x) |x| {
        pen.x = x;
        starts_chunk = true;
    }
    if (run.y) |y| pen.y = y;
    pen.x += run.dx;
    pen.y += run.dy;

    if (collapsed.len == 0 or !(size > 0)) return;

    const text_opts: z2d.text.ShowTextOptions = .{ .size = size };

    // §10.9: the anchor moves a whole *chunk*, not a run -- so placing the
    // first run of one means knowing the width of every run in it, and those
    // widths need the font. The chunk is measured by walking the `<text>` this
    // run belongs to, which is the same trick a clip in bounding-box units
    // uses to measure a group.
    if (starts_chunk) {
        const anchor = shape.text_anchor orelse .start;
        if (anchor != .start) {
            const width = try chunkWidth(gpa, doc, run, opts);
            pen.x -= if (anchor == .middle) width / 2 else width;
        }
    }

    // §10.13: a run inside a `<textPath>` follows a shape rather than a
    // line, which is a different placement for every glyph.
    if (run.on_path) |on_path| {
        try buildOnPath(gpa, p, &font, collapsed, on_path, size, pen, ctm, doc, build_opts, opts);
        return;
    }

    // The attributes that place glyphs one at a time. Without them the whole
    // run goes down in one call, which is both faster and exactly what z2d
    // does internally anyway.
    if (run.rotate != null or run.text_length != null) {
        try buildGlyphs(gpa, p, &font, collapsed, run, size, pen, ctm, build_opts);
        return;
    }

    var glyphs = z2d.text.outline(
        gpa,
        &font,
        collapsed,
        pen.x,
        // §10.4: a `<text>`'s `y` is the **baseline**. z2d places a run by the
        // top of its em box, one em above, because the glyph outline is
        // reflected about the em box rather than about the baseline. Passing
        // the baseline straight through puts every line one font-size down the
        // page, which looks like a plausible picture and is the wrong one.
        pen.y - font.baselineOffset(size),
        .{ .size = size, .transformation = ctm },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Every other way this fails is the font or the string being
        // something the shaper cannot read.
        else => return error.BadFont,
    };
    defer glyphs.deinit(gpa);

    pen.x += z2d.text.measure(gpa, &font, collapsed, text_opts) catch
        return error.BadFont;

    // A run of text is as many nodes as its glyphs need, and a document can
    // always write more text. Without this the budget would be the one thing
    // text did not answer to.
    try withinBudget(p, glyphs.nodes.items.len, build_opts);
    try p.nodes.appendSlice(gpa, glyphs.nodes.items);
}

/// Refuse when adding `adding` nodes would put `p` past what `opts` allows.
///
/// The same ceiling `shapes.build` keeps, and for the same reason: the budget
/// exists so that a document cannot ask for unbounded work, and a builder that
/// does not consult it is a hole in that.
fn withinBudget(p: *const z2d.Path, adding: usize, opts: path.Options) Error!void {
    const ceiling = std.math.add(usize, p.nodes.items.len, opts.max_nodes) catch
        std.math.maxInt(usize);
    const after = std.math.add(usize, p.nodes.items.len, adding) catch
        std.math.maxInt(usize);
    if (after > ceiling) return error.PathTooComplex;
}

/// Build a run one glyph at a time, for `rotate` and `textLength`.
///
/// Both need each glyph placed on its own: `rotate` turns each about its own
/// origin, and `textLength` changes the gaps between them without touching
/// their shapes -- which is §10.4's `lengthAdjust="spacing"`, the initial
/// value, and what resvg draws.
///
/// The whole difficulty is the step from one glyph's origin to the next,
/// because it is the glyph's advance *plus the kerning pair* with what follows
/// and z2d exposes neither on its own. Measuring a two-character string and
/// taking away the second character's own width leaves exactly that step, so
/// the kerning survives being placed by hand -- which is the thing that would
/// otherwise go quietly wrong, since text without kerning looks like text.
fn buildGlyphs(
    gpa: Allocator,
    p: *z2d.Path,
    font: *z2d.Font,
    utf8: []const u8,
    run: shapes.Text,
    size: f64,
    pen: *Pen,
    ctm: z2d.Transformation,
    build_opts: path.Options,
) Error!void {
    const opts: z2d.text.ShowTextOptions = .{ .size = size };

    // Where each character begins and ends, so that a glyph can be cut out of
    // the run and measured or drawn on its own.
    var bounds: std.ArrayListUnmanaged(usize) = .empty;
    defer bounds.deinit(gpa);
    try splitCodepoints(gpa, utf8, &bounds);
    const count = bounds.items.len - 1;
    if (count == 0) return;

    // The step from each glyph's origin to the next, kerning included.
    var steps: std.ArrayListUnmanaged(f64) = .empty;
    defer steps.deinit(gpa);
    var natural: f64 = 0;
    for (0..count) |i| {
        const step = try glyphStep(gpa, font, utf8, bounds.items, i, count, opts);
        try steps.append(gpa, step);
        natural += step;
    }

    // §10.4: `textLength` is the width the run is adjusted to. With one glyph
    // there is no gap to put the difference in, so there is nothing to adjust.
    var extra: f64 = 0;
    if (run.text_length) |want| {
        if (count > 1) extra = (want - natural) / @as(f64, @floatFromInt(count - 1));
    }

    const baseline = font.baselineOffset(size);
    var x = pen.x;
    for (0..count) |i| {
        const glyph = utf8[bounds.items[i]..bounds.items[i + 1]];
        // Each glyph is turned about its own origin, which is where it sits on
        // the baseline rather than the corner of its ink.
        var placement = ctm.translate(x, pen.y);
        if (try rotationAt(run.rotate, i)) |degrees| {
            placement = placement.rotate(degrees * std.math.pi / 180.0);
        }
        var one = z2d.text.outline(
            gpa,
            font,
            glyph,
            0,
            -baseline,
            .{ .size = size, .transformation = placement },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadFont,
        };
        defer one.deinit(gpa);
        try withinBudget(p, one.nodes.items.len, build_opts);
        try p.nodes.appendSlice(gpa, one.nodes.items);

        x += steps.items[i];
        if (i + 1 < count) x += extra;
    }
    pen.x = x;
}

/// Lay a run along a `<textPath>`'s shape.
///
/// §10.13. Each glyph is placed so that the **middle of its advance** sits on
/// the path at the right distance, turned to the tangent there -- the middle
/// rather than the start, because a glyph turned about its own left edge on a
/// tight curve leans away from the line it is meant to sit on.
///
/// A glyph whose midpoint falls off either end of the path is not drawn, which
/// is what the specification says to do and is why a string longer than its
/// path simply stops.
fn buildOnPath(
    gpa: Allocator,
    p: *z2d.Path,
    font: *z2d.Font,
    utf8: []const u8,
    on_path: shapes.OnPath,
    size: f64,
    pen: *Pen,
    ctm: z2d.Transformation,
    doc: *const document.Document,
    build_opts: path.Options,
    opts: Options,
) Error!void {
    var arc: Arc = .{};
    defer arc.deinit(gpa);
    try measurePath(gpa, doc, on_path.node, &arc, opts);
    if (arc.total() <= 0) return;

    const start = switch (on_path.offset) {
        .absolute => |v| v,
        .fraction => |f| f * arc.total(),
    };

    const text_opts: z2d.text.ShowTextOptions = .{ .size = size };
    var bounds: std.ArrayListUnmanaged(usize) = .empty;
    defer bounds.deinit(gpa);
    try splitCodepoints(gpa, utf8, &bounds);
    const count = bounds.items.len - 1;
    if (count == 0) return;

    const baseline = font.baselineOffset(size);
    var along = start;
    for (0..count) |i| {
        const glyph = utf8[bounds.items[i]..bounds.items[i + 1]];
        const step = try glyphStep(gpa, font, utf8, bounds.items, i, count, text_opts);
        // The midpoint of this glyph's advance is what sits on the curve.
        if (arc.at(along + step / 2)) |spot| {
            const placement = ctm
                .translate(spot.x, spot.y)
                .rotate(spot.angle)
                .translate(-step / 2, 0);
            var one = z2d.text.outline(
                gpa,
                font,
                glyph,
                0,
                -baseline,
                .{ .size = size, .transformation = placement },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadFont,
            };
            defer one.deinit(gpa);
            try withinBudget(p, one.nodes.items.len, build_opts);
            try p.nodes.appendSlice(gpa, one.nodes.items);
        }
        along += step;
    }
    // A `<textPath>` leaves the pen where the run ended along the curve, which
    // is what a `<tspan>` after it carries on from.
    pen.placed = true;
}

/// The shape a `<textPath>` names, flattened and measured.
///
/// Built in the *user* space of the referencing element rather than in device
/// space: the distances §10.13 talks about are user units, and the whole run
/// is put through `ctm` afterwards like any other geometry.
fn measurePath(
    gpa: Allocator,
    doc: *const document.Document,
    node: ztree.NodeId,
    out: *Arc,
    opts: Options,
) Error!void {
    // The element's *own* geometry, not its children's: a `<path>` has no
    // children, so walking its subtree would find nothing at all.
    const geometry = (try doc.geometryOf(node)) orelse return error.BadTextPath;
    // Text is not a shape to lay text along, and following it would be a
    // recursion with no bottom.
    if (geometry == .text) return error.BadTextPath;

    var built: z2d.Path = .empty;
    defer built.deinit(gpa);
    try document.buildShape(&built, gpa, geometry, try doc.transformOf(node), .{
        .max_nodes = opts.limits.max_path_nodes,
        // Left open: a closed subpath would add a segment back to the start
        // that the document did not draw, and text would run along it.
        .close_subpaths = false,
    });
    try flatten(gpa, built.nodes.items, out);
}

/// Where each character of `utf8` begins, and where the last one ends.
fn splitCodepoints(
    gpa: Allocator,
    utf8: []const u8,
    out: *std.ArrayListUnmanaged(usize),
) Error!void {
    var i: usize = 0;
    while (i < utf8.len) {
        try out.append(gpa, i);
        i += std.unicode.utf8ByteSequenceLength(utf8[i]) catch return error.BadFont;
    }
    try out.append(gpa, utf8.len);
}

/// The step from one glyph's origin to the next, kerning included.
///
/// A glyph's advance and its kerning pair with what follows, which z2d exposes
/// neither of on its own: measuring the two characters together and taking
/// away the second's own width leaves exactly the step. Without it the kerning
/// would be lost the moment glyphs were placed by hand, and text without
/// kerning still looks like text.
fn glyphStep(
    gpa: Allocator,
    font: *z2d.Font,
    utf8: []const u8,
    bounds: []const usize,
    i: usize,
    count: usize,
    opts: z2d.text.ShowTextOptions,
) Error!f64 {
    if (i + 1 < count) {
        const both = utf8[bounds[i]..bounds[i + 2]];
        const next = utf8[bounds[i + 1]..bounds[i + 2]];
        const whole = z2d.text.measure(gpa, font, both, opts) catch return error.BadFont;
        const tail = z2d.text.measure(gpa, font, next, opts) catch return error.BadFont;
        return whole - tail;
    }
    const here = utf8[bounds[i]..bounds[i + 1]];
    return z2d.text.measure(gpa, font, here, opts) catch error.BadFont;
}

/// A path flattened to a polyline, with how far along each vertex sits.
///
/// §10.13 places a glyph at a *distance* along a shape, which a Bezier does
/// not answer directly: there is no closed form for the arc length of a cubic.
/// Flattening it to short straight pieces and adding them up is what every
/// renderer does instead, and the error is bounded by how short the pieces
/// are.
const Arc = struct {
    xs: std.ArrayListUnmanaged(f64) = .empty,
    ys: std.ArrayListUnmanaged(f64) = .empty,
    /// Cumulative length at each vertex, so `at` can binary-search it.
    lengths: std.ArrayListUnmanaged(f64) = .empty,

    /// How finely a curve is chopped. Sixteen pieces per cubic is well past
    /// what a glyph's placement can show at any size this draws at.
    const per_curve = 256;

    fn deinit(self: *Arc, gpa: Allocator) void {
        self.xs.deinit(gpa);
        self.ys.deinit(gpa);
        self.lengths.deinit(gpa);
    }

    fn total(self: Arc) f64 {
        return if (self.lengths.items.len == 0) 0 else self.lengths.items[self.lengths.items.len - 1];
    }

    fn add(self: *Arc, gpa: Allocator, x: f64, y: f64) Error!void {
        if (self.xs.items.len == 0) {
            try self.xs.append(gpa, x);
            try self.ys.append(gpa, y);
            try self.lengths.append(gpa, 0);
            return;
        }
        const last = self.xs.items.len - 1;
        const dx = x - self.xs.items[last];
        const dy = y - self.ys.items[last];
        const step = @sqrt(dx * dx + dy * dy);
        // A repeated point adds nothing and would make a zero-length segment
        // with no direction to take a tangent from.
        if (!(step > 0)) return;
        try self.xs.append(gpa, x);
        try self.ys.append(gpa, y);
        try self.lengths.append(gpa, self.lengths.items[last] + step);
    }

    /// The point at `distance` along, and the direction the path is going
    /// there. Null when the distance falls off either end, which §10.13 says
    /// is a glyph that is not rendered.
    fn at(self: Arc, distance: f64) ?struct { x: f64, y: f64, angle: f64 } {
        if (self.xs.items.len < 2) return null;
        if (distance < 0 or distance > self.total()) return null;

        // The first vertex at or past the distance.
        var lo: usize = 1;
        var hi: usize = self.lengths.items.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.lengths.items[mid] < distance) lo = mid + 1 else hi = mid;
        }
        const i = lo;
        const span = self.lengths.items[i] - self.lengths.items[i - 1];
        const t = if (span > 0) (distance - self.lengths.items[i - 1]) / span else 0;
        const x0 = self.xs.items[i - 1];
        const y0 = self.ys.items[i - 1];
        const x1 = self.xs.items[i];
        const y1 = self.ys.items[i];
        return .{
            .x = x0 + (x1 - x0) * t,
            .y = y0 + (y1 - y0) * t,
            .angle = std.math.atan2(y1 - y0, x1 - x0),
        };
    }
};

/// Flatten a built path into an `Arc`.
fn flatten(gpa: Allocator, nodes: []const PathNode, out: *Arc) Error!void {
    var cx: f64 = 0;
    var cy: f64 = 0;
    var start_x: f64 = 0;
    var start_y: f64 = 0;
    for (nodes) |node| switch (node) {
        .move_to => |n| {
            // §10.13 lays text along *the* path; a second subpath would need
            // a rule for where one ends and the next begins that the
            // specification does not give, so the first is what is followed.
            if (out.xs.items.len != 0) return;
            cx = n.point.x;
            cy = n.point.y;
            start_x = cx;
            start_y = cy;
            try out.add(gpa, cx, cy);
        },
        .line_to => |n| {
            cx = n.point.x;
            cy = n.point.y;
            try out.add(gpa, cx, cy);
        },
        .curve_to => |n| {
            var step: usize = 1;
            while (step <= Arc.per_curve) : (step += 1) {
                const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(Arc.per_curve));
                const u = 1 - t;
                // de Casteljau, written out: the cubic at `t`.
                const bx = u * u * u * cx + 3 * u * u * t * n.p1.x +
                    3 * u * t * t * n.p2.x + t * t * t * n.p3.x;
                const by = u * u * u * cy + 3 * u * u * t * n.p1.y +
                    3 * u * t * t * n.p2.y + t * t * t * n.p3.y;
                try out.add(gpa, bx, by);
            }
            cx = n.p3.x;
            cy = n.p3.y;
        },
        .close_path => {
            cx = start_x;
            cy = start_y;
            try out.add(gpa, cx, cy);
        },
    };
}

/// The angle for the glyph at `index` in a `rotate` list, in degrees.
///
/// §10.4: the list is one angle per character and the **last** one repeats for
/// whatever is left, which is what makes `rotate="45"` turn every glyph rather
/// than only the first.
fn rotationAt(list: ?[]const u8, index: usize) Error!?f64 {
    const raw = list orelse return null;
    var it = std.mem.tokenizeAny(u8, raw, " ,\t\r\n");
    var seen: usize = 0;
    var last: ?f64 = null;
    while (it.next()) |tok| {
        const v = std.fmt.parseFloat(f64, tok) catch return error.BadLength;
        last = v;
        if (seen == index) return v;
        seen += 1;
    }
    return last;
}

/// The face a shape's text is drawn in.
fn faceFor(shape: document.Shape, opts: Options) Error!z2d.Font {
    const resolver = opts.fonts orelse return error.NoFontSupplied;
    const bytes = resolver.faceFor(shape) orelse return error.NoFontSupplied;
    return z2d.Font.loadBuffer(bytes) catch error.BadFont;
}

/// How wide the chunk beginning at `from` is, in user units.
///
/// A chunk runs from a position the document gave outright to the next one, so
/// this walks the `<text>` and adds up every run from `from` until another
/// names an `x` of its own. Each is measured in *its* font at *its* size,
/// because a `<tspan>` may change both.
///
/// It costs a second walk of the element, which is what §10.9 asks for:
/// `text-anchor` cannot be applied to the first run until the last one is
/// known.
fn chunkWidth(
    gpa: Allocator,
    doc: *const document.Document,
    from: shapes.Text,
    opts: Options,
) Error!f64 {
    var total: f64 = 0;
    var started = false;
    // `textRuns` rather than `subtree`: the `<text>`'s own `font-size` and
    // `font-family` are what its runs are drawn with, and a walk that skipped
    // them would measure at the default size instead -- which is a ratio
    // wrong, not a rounding.
    var it = try doc.textRuns(from.owner);
    while (try it.next()) |item| {
        const shape = switch (item) {
            .shape => |sh| sh,
            else => continue,
        };
        const run = switch (shape.geometry) {
            .text => |t| t,
            else => continue,
        };
        // Wait for the run this chunk starts at, then stop at the next one
        // that places itself.
        if (!started) {
            if (run.utf8.ptr != from.utf8.ptr) continue;
            started = true;
        } else if (run.x != null) break;

        const size = shape.font_size orelse 16;
        if (!(size > 0)) continue;
        var font = try faceFor(shape, opts);
        const collapsed = try collapseWhitespace(gpa, run.utf8);
        defer gpa.free(collapsed);
        total += run.dx;
        if (collapsed.len == 0) continue;
        // `textLength` says what the run comes to, so that *is* its width --
        // which is the point of the attribute.
        total += run.text_length orelse
            z2d.text.measure(gpa, &font, collapsed, .{ .size = size }) catch
            return error.BadFont;
    }
    return total;
}

/// XML whitespace collapsed the way SVG's default `xml:space` asks.
///
/// Every tab, newline and carriage return becomes a space, runs of spaces
/// become one, and the leading and trailing ones go. That is what makes text
/// indented across several lines in the source draw as one line here, which is
/// how documents are actually written -- and getting it wrong shows up as the
/// text being in the wrong place rather than as anything that looks like a
/// whitespace bug.
///
/// `xml:space="preserve"` asks for the other treatment and is not implemented;
/// the reader refuses nothing for it yet because the attribute is rare and its
/// absence is the case that matters.
fn collapseWhitespace(gpa: Allocator, raw: []const u8) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_space = false;
    for (raw) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                if (out.items.len != 0) pending_space = true;
            },
            else => {
                if (pending_space) try out.append(gpa, ' ');
                pending_space = false;
                try out.append(gpa, c);
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The overlap of two boxes, or null when they do not meet.
fn intersect(a: Box, b: Box) ?Box {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    if (!(x1 > x0) or !(y1 > y0)) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

/// An opacity as the byte an alpha mask wants.
fn alphaByte(opacity: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(opacity, 0.0, 1.0) * 255.0));
}

/// Turn a resolved paint into something z2d can draw with.
///
/// A colour is a pattern on its own. A reference has to be found, read, and
/// placed: a gradient's numbers are in a space of their own, and the matrix
/// that says where that space is depends on the shape being painted.
fn makeSource(
    gpa: Allocator,
    doc: *const document.Document,
    shape: document.Shape,
    paint: Paint,
    ctm: z2d.Transformation,
    opts: Options,
) Error!Source {
    const ref = switch (paint) {
        .pixel => |p| return .{ .pixel = p },
        .reference => |r| r,
    };

    const node = doc.ids.get(ref.id) orelse return error.UnknownReference;

    // A `<pattern>` is a paint server too, and the only one that is not a z2d
    // pattern: it is drawn rather than sampled. `paintTiled` does that; this
    // only resolves it.
    if (try pattern.read(doc.tree, &doc.ids, node, doc.viewport())) |spec| {
        // §13.3 makes a pattern with no tile, or with nothing in it, paint
        // nothing at all -- which is what resvg draws, and is not an error.
        if (!spec.isDrawable()) return .nothing;
        return .{ .tiled = .{ .spec = spec, .alpha = ref.alpha } };
    }

    const spec = (try gradient.read(
        doc.tree,
        &doc.ids,
        &doc.stylesheet,
        node,
        doc.viewport(),
        shape.current_color orelse callerColor(opts),
    )) orelse return error.UnsupportedPaintServer;

    // A gradient with no stops paints nothing, which is what resvg draws and
    // is not an error: the gradient exists, it just has no colours in it.
    if (spec.stop_count == 0) return .nothing;

    // Where the gradient's own space sits: the shape's transform, then the
    // units mapping, then `gradientTransform` inside that.
    var placement = ctm;
    if (spec.units == .object_bounding_box) {
        const box = try boundingBox(gpa, doc, shape, opts);
        // A shape with no extent in one direction has no box to be fractions
        // of, and §7.11 says such a gradient is not rendered.
        if (!(box.width > 0) or !(box.height > 0)) return .nothing;
        placement = placement.mul(.{
            .ax = box.width,
            .by = 0,
            .cx = 0,
            .dy = box.height,
            .tx = box.x,
            .ty = box.y,
        });
    }
    placement = placement.mul(spec.transform);
    if (!transform.isFinite(placement)) return error.NonFiniteTransform;

    var g: z2d.Gradient = .init(.{
        .type = switch (spec.kind) {
            .linear => |l| .{ .linear = .{ .x0 = l.x1, .y0 = l.y1, .x1 = l.x2, .y1 = l.y2 } },
            // SVG's focal point is z2d's inner circle, with a radius of zero:
            // the two-circle form is exactly what §13.2.3 describes, so the
            // focus needs no special case.
            .radial => |r| .{ .radial = .{
                .inner_x = r.fx orelse r.cx,
                .inner_y = r.fy orelse r.cy,
                .inner_radius = 0,
                .outer_x = r.cx,
                .outer_y = r.cy,
                .outer_radius = r.r,
            } },
        },
        // `.linear_rgb` is the one that gives SVG's sRGB interpolation, and
        // the name is the opposite of what it sounds like.
        //
        // z2d's `LinearRGB` is the space an 8-bit pixel's bytes are already
        // in, so interpolating in it blends the encoded values -- which is
        // what SVG's `color-interpolation: sRGB` asks for. Its `SRGB` applies
        // a gamma transform on top, so `.srgb` blends *decoded* values and
        // comes out dark. Measured: the midpoint of red to blue is 126,0,129
        // under `.linear_rgb` and 54,0,57 under `.srgb`, and resvg draws
        // 127,0,128.
        //
        // The same inversion decides the stops below, which is why they go in
        // as `.rgba` rather than `.srgba`.
        .method = .linear_rgb,
        // §13.2.2's `spreadMethod`, whose three values are z2d's three extend
        // modes under the same meanings.
        .extend = spec.spread,
    });
    errdefer g.deinit(gpa);

    for (spec.slice()) |stop| {
        const a = stop.value.alpha * ref.alpha;
        // `.rgba`, for the reason above: it is the space the bytes are
        // already in, so this hands z2d the colour the document wrote.
        // `.srgba` would decode them and paint mediumseagreen as 11,117,43.
        try g.addStop(gpa, @floatCast(stop.offset), .{ .rgba = .{
            @as(f32, @floatFromInt(stop.value.r)) / 255.0,
            @as(f32, @floatFromInt(stop.value.g)) / 255.0,
            @as(f32, @floatFromInt(stop.value.b)) / 255.0,
            @floatCast(a),
        } });
    }
    g.setTransformation(placement) catch |err| switch (err) {
        // A placement that collapses the plane has nothing to sample through.
        error.InvalidMatrix => return .nothing,
        else => |e| return e,
    };
    return .{ .gradient = g };
}

/// The caller's own fill as a colour, for a `stop-color="currentColor"` in a
/// document that names no `color` of its own.
fn callerColor(opts: Options) color.Color {
    const straight = z2d.pixel.RGBA.fromPixel(opts.fill).demultiply();
    return .{
        .r = straight.r,
        .g = straight.g,
        .b = straight.b,
        .alpha = @as(f64, @floatFromInt(straight.a)) / 255.0,
    };
}

/// A shape's bounding box in its **own** user space -- before its transform,
/// which is what §7.11 means by the object bounding box.
///
/// It costs a third build of the same geometry, and there is no way round
/// that: the fill's path is already in device space and the stroke's is too,
/// and the bounding box of a rotated shape is not the rotation of its bounding
/// box. Only a gradient in `objectBoundingBox` units asks for one.
fn boundingBox(
    gpa: Allocator,
    doc: *const document.Document,
    shape: document.Shape,
    opts: Options,
) Error!Box {
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    try buildGeometry(gpa, &p, shape, .identity, .{
        .max_nodes = opts.limits.max_path_nodes,
    }, doc, null, opts);
    return pathBox(p.nodes.items);
}

/// A container's bounding box, in the container's own user space.
///
/// The union of the boxes of everything inside it, each under its own
/// transform relative to the container -- which is what walking the subtree
/// from the identity yields, since the walk composes every `transform` it
/// meets on top of the matrix it started with and the container's own is not
/// among them.
///
/// It costs a walk and a rebuild of every path under the container, so it is
/// asked for only when a `clipPathUnits` or a `maskUnits` actually says
/// `objectBoundingBox`, and asked for once per element however many of them
/// say it.
fn contentBox(
    gpa: Allocator,
    doc: *const document.Document,
    node: ztree.NodeId,
    opts: Options,
) Error!Box {
    return contentExtent(gpa, doc, node, false, opts);
}

/// `contentBox`, optionally grown by what each shape's stroke reaches.
///
/// §7.11's bounding box is the fill geometry alone, which is what a gradient
/// and a clip in `objectBoundingBox` units want. A `<pattern>` asking whether
/// its contents stay inside their tile wants the opposite: a stroke that
/// crosses the tile edge has to be cut like anything else, so it has to be
/// measured like anything else.
fn contentExtent(
    gpa: Allocator,
    doc: *const document.Document,
    node: ztree.NodeId,
    with_stroke: bool,
    opts: Options,
) Error!Box {
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);

    var measure_pen: Pen = .{};
    var it = doc.subtree(node, .identity);
    while (try it.next()) |item| {
        const shape = switch (item) {
            .shape => |sh| sh,
            // A group inside contributes its shapes, which the walk yields in
            // their own right; the group itself has no geometry to measure.
            else => continue,
        };
        var p: z2d.Path = .empty;
        defer p.deinit(gpa);
        try buildGeometry(gpa, &p, shape, shape.transform, .{
            .max_nodes = opts.limits.max_path_nodes,
        }, doc, &measure_pen, opts);
        if (p.nodes.items.len == 0) continue;
        var box = pathBox(p.nodes.items);
        if (with_stroke) {
            if (try resolveStroke(shape, opts)) |pen| {
                // Half the pen on each side, and the miter limit on top: a
                // join can reach further than the pen alone, and over-reaching
                // here only costs a clip that turns out to have been
                // unnecessary.
                const reach = @abs(pen.width) * 0.5 * @max(1.0, pen.miter_limit);
                box = .{
                    .x = box.x - reach,
                    .y = box.y - reach,
                    .width = box.width + 2 * reach,
                    .height = box.height + 2 * reach,
                };
            }
        }
        min_x = @min(min_x, box.x);
        min_y = @min(min_y, box.y);
        max_x = @max(max_x, box.x + box.width);
        max_y = @max(max_y, box.y + box.height);
    }
    if (!std.math.isFinite(min_x) or !std.math.isFinite(min_y)) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

/// One node of a built path. z2d does not re-export the type from its root,
/// so it is named through the field that holds them.
const PathNode = std.meta.Elem(@FieldType(z2d.Path, "nodes").Slice);

/// The axis-aligned extent of a built path.
fn pathBox(nodes: []const PathNode) Box {
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    const see = struct {
        fn f(pt: anytype, lo_x: *f64, lo_y: *f64, hi_x: *f64, hi_y: *f64) void {
            lo_x.* = @min(lo_x.*, pt.x);
            lo_y.* = @min(lo_y.*, pt.y);
            hi_x.* = @max(hi_x.*, pt.x);
            hi_y.* = @max(hi_y.*, pt.y);
        }
    }.f;
    for (nodes) |node| switch (node) {
        .move_to => |n| see(n.point, &min_x, &min_y, &max_x, &max_y),
        .line_to => |n| see(n.point, &min_x, &min_y, &max_x, &max_y),
        // The control points, not the curve. A hull is larger than the curve
        // it bounds, so a gradient over a curved shape can start a little
        // outside it -- the specification wants the tight box, and getting it
        // means solving each cubic for its extrema. Worth doing when a fixture
        // shows the difference; the hull is what most renderers used for
        // years.
        .curve_to => |n| {
            see(n.p1, &min_x, &min_y, &max_x, &max_y);
            see(n.p2, &min_x, &min_y, &max_x, &max_y);
            see(n.p3, &min_x, &min_y, &max_x, &max_y);
        },
        .close_path => {},
    };
    if (!std.math.isFinite(min_x) or !std.math.isFinite(min_y)) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

/// The most dashes a `stroke-dasharray` may name.
///
/// The list is read into the caller's frame rather than allocated, so it needs
/// a ceiling; and a dash pattern with more than this many phases in it is a
/// pattern nobody can see. A longer list is refused rather than truncated,
/// because truncating one would change where every dash after it falls.
pub const max_dashes = 64;

/// Everything `z2d.painter.stroke` needs, resolved from a shape.
///
/// The dash lengths are held as an array and a count rather than as a slice,
/// and `dashes()` makes the slice from whichever copy you are holding. A
/// `dashes: []const f64` field pointing into a `storage` field beside it would
/// be a slice into *this* struct -- and this struct is returned by value, so
/// every copy's slice would point at the dead frame of the function that built
/// it. It would read the right numbers for a while, too.
const Stroke = struct {
    paint: Paint,
    width: f64,
    cap: z2d.options.CapMode,
    join: z2d.options.JoinMode,
    miter_limit: f64,
    dash_offset: f64,
    dash_count: usize = 0,
    dash_storage: [max_dashes]f64 = undefined,

    fn dashes(self: *const Stroke) []const f64 {
        return self.dash_storage[0..self.dash_count];
    }

    /// Rescales the pen for stroking in device space. See `uniformScale`.
    fn scaleBy(self: *Stroke, s: f64) void {
        self.width *= s;
        self.dash_offset *= s;
        for (self.dash_storage[0..self.dash_count]) |*d| d.* *= s;
    }
};

/// The scale factor of `t` if it is a similarity, and null otherwise.
///
/// A similarity -- a uniform scale, with any rotation and translation -- maps
/// a circle to a circle, so a round pen of radius `r` under it is exactly a
/// round pen of radius `r * s`. That makes two ways of stroking *equivalent*
/// rather than merely close, and the choice between them matters for a reason
/// that has nothing to do with geometry:
///
/// z2d reverts `line_cap_mode`, `line_join_mode` and `miter_limit` to their
/// defaults for a thin line, to keep it from showing artifacts. That guard
/// used to be decided by the *user-space* width, which meant a
/// `stroke-width="1"` -- the initial value, so much the commonest one --
/// silently lost its round caps however large the picture was drawn. Strokings
/// in device space, with the pen scaled here, was how this library got them
/// back, and a thin stroke under a genuinely warped transform lost them
/// anyway, because there this has to hand z2d the matrix and let it shape an
/// elliptical pen.
///
/// The z2d this builds against decides that guard by the device width now, so
/// both branches are right and the warped case is no longer the exception it
/// was. What remains here is the equivalence itself, which costs nothing and
/// keeps the similarity case exact rather than leaving it to a pen z2d derives
/// from a matrix.
///
/// The columns of the linear part have to be the same length and at right
/// angles, which is the definition, tested proportionally so that it holds for
/// a matrix scaled by a millionth as well as by a million.
fn uniformScale(t: z2d.Transformation) ?f64 {
    const len_x = @sqrt(t.ax * t.ax + t.cx * t.cx);
    const len_y = @sqrt(t.by * t.by + t.dy * t.dy);
    if (!(len_x > 0) or !(len_y > 0)) return null;

    const tolerance = 1e-9;
    if (@abs(len_x - len_y) > tolerance * @max(len_x, len_y)) return null;
    const dot = t.ax * t.by + t.cx * t.dy;
    if (@abs(dot) > tolerance * len_x * len_y) return null;
    return len_x;
}

/// How to stroke one shape, or null when it is not stroked.
///
/// SVG's initial `stroke` is `none`, so a shape whose document says nothing
/// about stroking is not stroked. That is the opposite of `fill`, where saying
/// nothing means the caller's colour -- and deliberately so: an icon with no
/// `fill` is the normal case, while a shape stroked without asking would put
/// lines in a picture the document does not have.
fn resolveStroke(shape: document.Shape, opts: Options) Error!?Stroke {
    const paint = shape.stroke orelse return null;

    // §11.4: a width of zero, or less, disables the stroke.
    const width = shape.stroke_width orelse opts.stroke_width;
    if (!(width > 0)) return null;

    const alpha = (shape.stroke_opacity orelse 1.0) * shape.opacity;
    const named: ?color.Color = switch (paint) {
        .none => return null,
        .color => |c| c,
        .current => shape.current_color,
        .reference => |id| {
            var ref: Stroke = try strokeStyle(shape, width, .{
                .reference = .{ .id = id, .alpha = alpha },
            });
            if (shape.stroke_dasharray) |raw| {
                ref.dash_count = try readDashes(raw, &ref.dash_storage);
            }
            return ref;
        },
    };
    const pixel = (if (named) |c| fadeColor(c, alpha) else fadePixel(opts.fill, alpha)) orelse
        return null;

    var result: Stroke = try strokeStyle(shape, width, .{ .pixel = pixel });
    if (shape.stroke_dasharray) |raw| {
        result.dash_count = try readDashes(raw, &result.dash_storage);
    }
    return result;
}

/// Reads a `stroke-dasharray` into `out`, and says how much of it was used.
///
/// §11.4, and what resvg actually does, which is not quite the same: reading
/// stops at the first value that is not a length and the lengths before it are
/// used, the way a `points` list truncates. A list that is empty, says `none`,
/// is all zeroes, or holds a negative number is not a dash pattern at all and
/// leaves the stroke solid -- the negative case because §11.4 calls it an
/// error, and an erroneous value falls back to the initial one.
///
/// An odd count is repeated, so `4` dashes four on and four off. That is the
/// specification rather than a convenience, and z2d does not do it for us.
fn readDashes(raw: []const u8, out: *[max_dashes]f64) Error!usize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return 0;

    var s: path.Scanner = .{ .src = trimmed };
    var n: usize = 0;
    var total: f64 = 0;
    while (true) {
        s.skipWsAndCommas();
        if (s.done()) break;
        const v = s.number() catch break;
        if (v < 0) return 0; // §11.4: an error, so the initial value stands
        // Doubling below needs room for two of everything.
        if (n >= max_dashes / 2) return error.TooManyDashes;
        out[n] = v;
        n += 1;
        total += v;
    }
    if (n == 0 or total <= 0) return 0;

    if (n % 2 == 1) {
        @memcpy(out[n..][0..n], out[0..n]);
        n *= 2;
    }
    return n;
}

/// The caller's own pixel, faded by `alpha`.
///
/// Returned exactly as given when there is nothing to fade, so that a caller
/// who named an `rgb` pixel keeps it: widening every fill to `rgba` would make
/// z2d composite where it could have copied, for no visible difference.
fn fadePixel(px: z2d.Pixel, alpha: f64) ?z2d.Pixel {
    if (alpha >= 1.0) return px;
    if (alpha <= 0) return null;
    const straight = z2d.pixel.RGBA.fromPixel(px).demultiply();
    return .{ .rgba = .fromClamped(
        @as(f64, @floatFromInt(straight.r)) / 255.0,
        @as(f64, @floatFromInt(straight.g)) / 255.0,
        @as(f64, @floatFromInt(straight.b)) / 255.0,
        @as(f64, @floatFromInt(straight.a)) / 255.0 * alpha,
    ) };
}

/// The document's own size as a pixel count.
///
/// Rounded to nearest, which is what resvg does with an explicit `width`: a
/// `4cm` document comes out 151 pixels rather than 152, and `1.4` comes out 1.
/// Clamped as well -- the size has already been checked to be positive and
/// finite, and anything past `u32` is refused by `Limits.check` a moment later
/// with an error that says which limit it broke.
fn fitDimension(v: f64) u32 {
    const rounded = @round(v);
    if (rounded >= @as(f64, math.maxInt(u32))) return math.maxInt(u32);
    return @intFromFloat(rounded);
}

// -- tests -------------------------------------------------------------------

const icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2,2H22V22H2V2Z" /></svg>
;

test "the viewBox is the default size" {
    var surface = try render(testing.allocator, icon, .{});
    defer surface.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 24), surface.getWidth());
    try testing.expectEqual(@as(i32, 24), surface.getHeight());
}

test "a square drawn across the middle of the viewBox lands in the middle" {
    var surface = try render(testing.allocator, icon, .{
        .width = 48,
        .height = 48,
        .fill = .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    });
    defer surface.deinit(testing.allocator);

    // Inside the square, which runs from 4 to 44 at this scale.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(24, 24).?.rgba.r);
    // And outside it, which nothing painted, so it is still transparent.
    try testing.expectEqual(@as(u8, 0), surface.getPixel(1, 1).?.rgba.a);
}

test "a background fills the surface before the path is drawn" {
    var surface = try render(testing.allocator, icon, .{
        .background = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } },
        .fill = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },
    });
    defer surface.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(0, 0).?.rgb.b);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(12, 12).?.rgb.r);
}

test "a picture larger than the limits allow is refused" {
    try testing.expectError(error.ImageTooLarge, render(testing.allocator, icon, .{
        .width = 4096,
        .height = 4096,
        .limits = .{ .max_pixels = 1024 },
    }));
}

test "a zero dimension is refused rather than made into a surface" {
    try testing.expectError(error.BadSize, render(testing.allocator, icon, .{ .width = 0 }));
}

test "every shape in the document is painted" {
    const gpa = testing.allocator;
    // Two squares side by side, neither covering the other.
    const src =
        \\<svg viewBox="0 0 4 2"><path d="M0 0H2V2H0Z"/><path d="M2 0H4V2H2Z"/></svg>
    ;
    var surface = try render(gpa, src, .{
        .width = 40,
        .height = 20,
        .fill = .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    });
    defer surface.deinit(gpa);

    try testing.expectEqual(@as(u8, 255), surface.getPixel(10, 10).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(30, 10).?.rgba.a);
}

test "shapes are painted in document order, the later over the earlier" {
    const gpa = testing.allocator;
    // A big square, then a smaller one on top of it. With `src_over` and an
    // opaque fill the picture is the same either way -- what this pins is that
    // both were drawn at all, and that the second did not erase the first.
    const src =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H8V8H0Z"/><path d="M2 2H6V6H2Z"/></svg>
    ;
    var surface = try render(gpa, src, .{
        .width = 80,
        .height = 80,
        .fill = .{ .rgba = .{ .r = 0, .g = 0, .b = 255, .a = 255 } },
    });
    defer surface.deinit(gpa);

    // Inside the inner square, and inside the outer one but outside the inner.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(40, 40).?.rgba.b);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(5, 40).?.rgba.b);
}

test "overlapping shapes are not merged into one fill" {
    const gpa = testing.allocator;
    // One subpath clockwise, the next counterclockwise, overlapping. Built
    // into a single path and filled once under the nonzero rule, the second
    // would punch a hole in the first. Painted as two shapes it does not --
    // which is what SVG means and what resvg draws.
    const merged =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H8V8H0ZM2 2V6H6V2Z"/></svg>
    ;
    const separate =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H8V8H0Z"/><path d="M2 2V6H6V2Z"/></svg>
    ;

    var holed = try render(gpa, merged, .{ .width = 80, .height = 80 });
    defer holed.deinit(gpa);
    var solid = try render(gpa, separate, .{ .width = 80, .height = 80 });
    defer solid.deinit(gpa);

    // The middle of the merged one is a hole; the middle of the other is not.
    try testing.expectEqual(@as(u8, 0), holed.getPixel(40, 40).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), solid.getPixel(40, 40).?.rgba.a);
}

test "the node budget is spent across the document, not per shape" {
    const gpa = testing.allocator;
    // Three shapes of five nodes each. A per-shape budget of eight would take
    // all three; a document-wide one runs out during the second.
    const src =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H2V2H0Z"/><path d="M3 3H5V5H3Z"/><path d="M6 6H8V8H6Z"/></svg>
    ;
    try testing.expectError(error.PathTooComplex, render(gpa, src, .{
        .width = 16,
        .height = 16,
        .limits = .{ .max_path_nodes = 8 },
    }));
    // And with room for all three it draws.
    var surface = try render(gpa, src, .{
        .width = 16,
        .height = 16,
        .limits = .{ .max_path_nodes = 64 },
    });
    defer surface.deinit(gpa);
}

test "a document with more shapes than the limit allows is refused" {
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 8 8"><path d="M0 0H2V2H0Z"/><path d="M3 3H5V5H3Z"/><path d="M6 6H8V8H6Z"/></svg>
    ;
    try testing.expectError(error.TooManyShapes, render(gpa, src, .{
        .width = 16,
        .height = 16,
        .limits = .{ .max_shapes = 2 },
    }));
}

/// The pixel at the middle of a 20x20 render of a full-viewBox square.
fn middleOf(gpa: Allocator, src: []const u8, opts: Options) !z2d.pixel.RGBA {
    var o = opts;
    o.width = 20;
    o.height = 20;
    var surface = try render(gpa, src, o);
    defer surface.deinit(gpa);
    return z2d.pixel.RGBA.fromPixel(surface.getPixel(10, 10).?).demultiply();
}

fn square(comptime attrs: []const u8) []const u8 {
    return "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" " ++ attrs ++ "/></svg>";
}

test "a shape is painted the colour its document names" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        square("fill=\"red\""),
        square("fill=\"#f00\""),
        square("fill=\"#ff0000\""),
        square("fill=\"rgb(255,0,0)\""),
        square("fill=\"RED\""),
    }) |src| {
        const px = try middleOf(gpa, src, .{});
        try testing.expectEqual(@as(u8, 255), px.r);
        try testing.expectEqual(@as(u8, 0), px.g);
        try testing.expectEqual(@as(u8, 255), px.a);
    }
}

test "a shape that names no colour is painted the caller's" {
    // The whole reason a Material Design Icon can be drawn in any colour: not
    // one of the 7,447 carries a `fill`.
    const gpa = testing.allocator;
    const px = try middleOf(gpa, square(""), .{
        .fill = .{ .rgba = .{ .r = 0, .g = 255, .b = 0, .a = 255 } },
    });
    try testing.expectEqual(@as(u8, 255), px.g);
    try testing.expectEqual(@as(u8, 0), px.r);
}

test "currentColor is the caller's colour, or the color property when there is one" {
    const gpa = testing.allocator;
    const callers: Options = .{ .fill = .{ .rgba = .{ .r = 0, .g = 0, .b = 255, .a = 255 } } };

    const from_caller = try middleOf(gpa, square("fill=\"currentColor\""), callers);
    try testing.expectEqual(@as(u8, 255), from_caller.b);

    // `color` on the root is inherited and is what `currentColor` resolves to.
    const from_color = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" color=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"currentColor\"/></svg>",
        callers,
    );
    try testing.expectEqual(@as(u8, 255), from_color.r);
    try testing.expectEqual(@as(u8, 0), from_color.b);

    // `fill` on the root is *not* what it resolves to -- that is the trap, and
    // resvg agrees: a `fill` ancestor leaves `color` at its initial value.
    const not_fill = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"currentColor\"/></svg>",
        callers,
    );
    try testing.expectEqual(@as(u8, 255), not_fill.b);
}

test "fill and fill-opacity are inherited from the root, and overridden by the shape" {
    const gpa = testing.allocator;
    const inherited = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><path d=\"M0 0H8V8H0Z\"/></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), inherited.r);

    const overridden = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"blue\"/></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), overridden.b);
    try testing.expectEqual(@as(u8, 0), overridden.r);

    const faded = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill-opacity=\"0.5\"><path d=\"M0 0H8V8H0Z\" fill=\"red\"/></svg>",
        .{},
    );
    try testing.expectApproxEqAbs(@as(f64, 128), @as(f64, @floatFromInt(faded.a)), 1.0);
}

test "the three alphas multiply together" {
    const gpa = testing.allocator;
    // The colour's own alpha, then fill-opacity, then opacity.
    const px = try middleOf(gpa, square("fill=\"#ff000080\" fill-opacity=\"0.5\" opacity=\"0.5\""), .{});
    // 0.5 * 0.5 * 0.5 = 0.125, which is 32 of 255.
    try testing.expectApproxEqAbs(@as(f64, 32), @as(f64, @floatFromInt(px.a)), 1.5);
}

test "a shape that would paint nothing is skipped" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        square("fill=\"none\""),
        square("fill=\"transparent\""),
        square("fill-opacity=\"0\""),
        square("opacity=\"0\""),
        square("fill=\"#ff000000\""),
    }) |src| {
        const px = try middleOf(gpa, src, .{});
        try testing.expectEqual(@as(u8, 0), px.a);
    }
}

test "shapes in one document can be different colours" {
    const gpa = testing.allocator;
    const src =
        \\<svg viewBox="0 0 4 2"><path d="M0 0H2V2H0Z" fill="red"/><path d="M2 0H4V2H2Z" fill="blue"/></svg>
    ;
    var surface = try render(gpa, src, .{ .width = 40, .height = 20 });
    defer surface.deinit(gpa);
    const left = z2d.pixel.RGBA.fromPixel(surface.getPixel(10, 10).?).demultiply();
    const right = z2d.pixel.RGBA.fromPixel(surface.getPixel(30, 10).?).demultiply();
    try testing.expectEqual(@as(u8, 255), left.r);
    try testing.expectEqual(@as(u8, 0), left.b);
    try testing.expectEqual(@as(u8, 255), right.b);
    try testing.expectEqual(@as(u8, 0), right.r);
}

test "fill-rule is read from the document, and is case-sensitive" {
    const gpa = testing.allocator;
    // Both subpaths wound the same way: nonzero fills the middle, evenodd
    // leaves a hole.
    const both = "M0 0H8V8H0ZM2 2H6V6H2Z";
    const nonzero = "<svg viewBox=\"0 0 8 8\"><path d=\"" ++ both ++ "\"/></svg>";
    const evenodd = "<svg viewBox=\"0 0 8 8\"><path d=\"" ++ both ++ "\" fill-rule=\"evenodd\"/></svg>";

    try testing.expectEqual(@as(u8, 255), (try middleOf(gpa, nonzero, .{})).a);
    try testing.expectEqual(@as(u8, 0), (try middleOf(gpa, evenodd, .{})).a);

    // `EVENODD` is not `evenodd`: this is an XML attribute value, not a CSS
    // keyword, so it is not matched without regard to case. resvg reads it the
    // same way -- but it falls back to nonzero where this refuses.
    try testing.expectError(error.BadFillRule, render(gpa, "<svg viewBox=\"0 0 8 8\"><path d=\"" ++
        both ++ "\" fill-rule=\"EVENODD\"/></svg>", .{}));
}

test "a value that cannot be read is refused rather than defaulted" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadColor, render(gpa, square("fill=\"notacolour\""), .{}));
    try testing.expectError(error.BadColor, render(gpa, square("fill=\"#12345\""), .{}));
    try testing.expectError(error.BadOpacity, render(gpa, square("opacity=\"half\""), .{}));
    try testing.expectError(error.BadOpacity, render(gpa, square("fill-opacity=\"\""), .{}));
}

test "a group's opacity applies to the group once, not to each shape" {
    const gpa = testing.allocator;
    // Two overlapping opaque squares at half opacity. Composited as a group
    // the overlap shows only the upper one at half; multiplied into each shape
    // it would show both, and come out more opaque where they meet.
    const grouped = "<svg viewBox=\"0 0 16 16\"><g opacity=\"0.5\">" ++
        "<rect x=\"0\" y=\"0\" width=\"10\" height=\"16\" fill=\"red\"/>" ++
        "<rect x=\"6\" y=\"0\" width=\"10\" height=\"16\" fill=\"red\"/></g></svg>";
    const each = "<svg viewBox=\"0 0 16 16\">" ++
        "<rect x=\"0\" y=\"0\" width=\"10\" height=\"16\" fill=\"red\" opacity=\"0.5\"/>" ++
        "<rect x=\"6\" y=\"0\" width=\"10\" height=\"16\" fill=\"red\" opacity=\"0.5\"/></svg>";

    var a = try render(gpa, grouped, .{ .width = 16, .height = 16 });
    defer a.deinit(gpa);
    var b = try render(gpa, each, .{ .width = 16, .height = 16 });
    defer b.deinit(gpa);

    // Away from the overlap the two agree.
    try testing.expectEqual(a.getPixel(2, 8).?.rgba.a, b.getPixel(2, 8).?.rgba.a);
    // In it they must not: the group stays half, the other pair stacks up.
    const group_overlap = a.getPixel(8, 8).?.rgba.a;
    const each_overlap = b.getPixel(8, 8).?.rgba.a;
    try testing.expectApproxEqAbs(@as(f64, 128), @as(f64, @floatFromInt(group_overlap)), 2);
    try testing.expect(each_overlap > group_overlap + 30);
}

test "opacity on the root is a group opacity too" {
    const gpa = testing.allocator;
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\" opacity=\"0.5\"><rect width=\"8\" height=\"8\" fill=\"red\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer surface.deinit(gpa);
    try testing.expectApproxEqAbs(
        @as(f64, 128),
        @as(f64, @floatFromInt(surface.getPixel(4, 4).?.rgba.a)),
        2,
    );
}

test "a clip cuts a shape to the union of the clip path's shapes" {
    const gpa = testing.allocator;
    const src = "<svg viewBox=\"0 0 16 16\"><defs><clipPath id=\"c\">" ++
        "<rect x=\"0\" y=\"0\" width=\"8\" height=\"16\"/>" ++
        "<rect x=\"8\" y=\"8\" width=\"8\" height=\"8\"/></clipPath></defs>" ++
        "<rect width=\"16\" height=\"16\" fill=\"red\" clip-path=\"url(#c)\"/></svg>";
    var surface = try render(gpa, src, .{ .width = 16, .height = 16 });
    defer surface.deinit(gpa);

    // Inside the left bar, and inside the bottom-right square.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(4, 4).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(12, 12).?.rgba.a);
    // And the quadrant neither covers.
    try testing.expectEqual(@as(u8, 0), surface.getPixel(12, 4).?.rgba.a);
}

test "clip-rule is read separately from fill-rule" {
    const gpa = testing.allocator;
    // The shape fills nonzero and clips even-odd, so the hole belongs to the
    // clip and not to the fill. Reading one for the other cuts the wrong one.
    const both = "M0 0H16V16H0ZM4 4H12V12H4Z";
    const src = "<svg viewBox=\"0 0 16 16\"><defs><clipPath id=\"c\">" ++
        "<path d=\"" ++ both ++ "\" clip-rule=\"evenodd\"/></clipPath></defs>" ++
        "<rect width=\"16\" height=\"16\" fill=\"red\" clip-path=\"url(#c)\"/></svg>";
    var surface = try render(gpa, src, .{ .width = 16, .height = 16 });
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(2, 8).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(8, 8).?.rgba.a);
}

test "a clip that names the wrong thing is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownReference, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" clip-path=\"url(#nothing)\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadClipPath, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><defs><rect id=\"r\" width=\"4\" height=\"4\"/></defs>" ++
            "<rect width=\"8\" height=\"8\" clip-path=\"url(#r)\"/></svg>",
        .{},
    ));
    // Neither of the two units the specification defines, so it is refused
    // rather than taken as the default: the two answers differ by the whole
    // bounding box, and a document that misspells one means something by it.
    try testing.expectError(error.UnsupportedClipUnits, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><defs><clipPath id=\"c\" clipPathUnits=\"fractionOfTheMoon\">" ++
            "<rect width=\"1\" height=\"1\"/></clipPath></defs>" ++
            "<rect width=\"8\" height=\"8\" clip-path=\"url(#c)\"/></svg>",
        .{},
    ));
}

test "a clip in objectBoundingBox units is fractions of what it clips" {
    const gpa = testing.allocator;
    const head = "<svg viewBox=\"0 0 8 8\"><clipPath id=\"c\" clipPathUnits=\"objectBoundingBox\">" ++
        "<rect width=\"0.5\" height=\"1\"/></clipPath>";
    // The clip is the left half of the box, and the box is what it clips. On
    // the shape that is its own geometry, 0..8, so the cut falls at x=4. On
    // the group it is the union of the two halves, 0..8 again, so the same
    // `<clipPath>` cuts the group in the same place -- which is the whole
    // point of the units, and is what needed measuring a container to do.
    for ([_][]const u8{
        head ++ "<rect width=\"8\" height=\"8\" fill=\"black\" clip-path=\"url(#c)\"/></svg>",
        head ++ "<g clip-path=\"url(#c)\"><rect width=\"4\" height=\"8\" fill=\"black\"/>" ++
            "<rect x=\"4\" width=\"4\" height=\"8\" fill=\"black\"/></g></svg>",
    }) |src| {
        var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
        defer surface.deinit(gpa);
        try testing.expectEqual(@as(u8, 255), surface.getPixel(2, 4).?.rgba.a);
        try testing.expectEqual(@as(u8, 0), surface.getPixel(6, 4).?.rgba.a);
    }
}

test "the object bounding box is measured before the element's own transform" {
    const gpa = testing.allocator;
    // §7.11's box is the geometry in the element's own coordinate system, so
    // the `translate` is outside it: the rect measures 0..8 and the clip cuts
    // it at its own midpoint, which lands at x=6 once it is moved.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 16 8\"><clipPath id=\"c\" clipPathUnits=\"objectBoundingBox\">" ++
            "<rect width=\"0.5\" height=\"1\"/></clipPath>" ++
            "<rect width=\"8\" height=\"8\" fill=\"black\" transform=\"translate(2,0)\"" ++
            " clip-path=\"url(#c)\"/></svg>",
        .{ .width = 16, .height = 8 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(4, 4).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(8, 4).?.rgba.a);
}

test "a filter naming nothing draws nothing at all" {
    const gpa = testing.allocator;
    // §15.7.1, and one of the few places in SVG where a dangling reference is
    // *defined* rather than an error: the element is not rendered. resvg
    // agrees, and a document relying on it looks completely different if the
    // filter is merely skipped.
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" filter=\"url(#nope)\"/></svg>",
        // Names something real that is not a filter.
        "<svg viewBox=\"0 0 8 8\"><g id=\"g\"/><rect width=\"8\" height=\"8\" filter=\"url(#g)\"/></svg>",
        // A filter with no primitives produces transparent black.
        "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"/><rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
    }) |src| {
        var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
        defer surface.deinit(gpa);
        for (surface.image_surface_rgba.buf) |px| try testing.expectEqual(@as(u8, 0), px.a);
    }

    // `none` asks for no filter at all, which is not the same as asking for
    // one that is not there: the element draws normally.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" mask=\"none\" filter=\"none\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.image_surface_rgba.buf[0].a);
}

test "a primitive this does not implement is refused" {
    const gpa = testing.allocator;
    // The rule the rest of the library follows: a chain with a link missing
    // is not the picture the document asked for, so it is refused rather than
    // run with the link left out.
    try testing.expectError(error.UnsupportedFilterPrimitive, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feTurbulence baseFrequency=\"0.1\"/></filter>" ++
            "<rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
        .{ .width = 8, .height = 8 },
    ));
    // An `in` naming a result nothing produced is the document meaning a
    // buffer that is not there, rather than meaning transparent black.
    try testing.expectError(error.BadFilterInput, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feOffset in=\"absent\" dx=\"1\"/></filter>" ++
            "<rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
        .{ .width = 8, .height = 8 },
    ));
    try testing.expectError(error.BadStdDeviation, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"-1\"/></filter>" ++
            "<rect width=\"8\" height=\"8\" filter=\"url(#f)\"/></svg>",
        .{ .width = 8, .height = 8 },
    ));
}

test "a blur spreads a shape and the filter region cuts it off" {
    const gpa = testing.allocator;
    // The default region is §15.7.5's -10%,-10%,120%,120% of the bounding
    // box, which is room for a small blur and not for a large one. A document
    // that wants more says so; one that does not gets a hard edge, and that
    // is the document's answer rather than this renderer's mistake.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 40 40\"><filter id=\"f\"><feGaussianBlur stdDeviation=\"2\"/></filter>" ++
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"#000\" filter=\"url(#f)\"/></svg>",
        .{ .width = 40, .height = 40 },
    );
    defer surface.deinit(gpa);

    const at = struct {
        fn f(sfc: *z2d.Surface, x: i32, y: i32) u8 {
            return sfc.image_surface_rgba.buf[@intCast(y * sfc.getWidth() + x)].a;
        }
    }.f;

    // Soft where the edge was, solid in the middle, and nothing at all
    // outside the region -- which runs from 8 to 32.
    try testing.expectEqual(@as(u8, 255), at(&surface, 20, 20));
    try testing.expect(at(&surface, 10, 20) > 60);
    try testing.expect(at(&surface, 10, 20) < 200);
    try testing.expect(at(&surface, 8, 20) > 0);
    try testing.expectEqual(@as(u8, 0), at(&surface, 7, 20));
    try testing.expectEqual(@as(u8, 0), at(&surface, 32, 20));
}

test "a drop shadow is an offset flood cut to the blurred alpha, merged under the source" {
    const gpa = testing.allocator;
    // The canonical five-primitive chain, which is what `<filter>` is for in
    // practice and what exercises `result` names, `SourceAlpha` and the merge
    // order all at once.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 40 40\">" ++
            "<filter id=\"f\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\">" ++
            "<feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"1\" result=\"b\"/>" ++
            "<feOffset in=\"b\" dx=\"4\" dy=\"4\" result=\"o\"/>" ++
            "<feMerge><feMergeNode in=\"o\"/><feMergeNode in=\"SourceGraphic\"/></feMerge>" ++
            "</filter>" ++
            "<rect x=\"10\" y=\"10\" width=\"16\" height=\"16\" fill=\"red\" filter=\"url(#f)\"/></svg>",
        .{ .width = 40, .height = 40 },
    );
    defer surface.deinit(gpa);

    const px = struct {
        fn f(sfc: *z2d.Surface, x: i32, y: i32) z2d.pixel.RGBA {
            return sfc.image_surface_rgba.buf[@intCast(y * sfc.getWidth() + x)];
        }
    }.f;

    // The rectangle itself is still red and still on top of its own shadow.
    try testing.expectEqual(@as(u8, 255), px(&surface, 18, 18).r);
    try testing.expectEqual(@as(u8, 255), px(&surface, 18, 18).a);
    // Below and right of it, black with nothing red in it: the shadow came
    // from `SourceAlpha`, which throws the colour away.
    const shadow = px(&surface, 28, 28);
    try testing.expect(shadow.a > 128);
    try testing.expectEqual(@as(u8, 0), shadow.r);
    // Above and left there is neither shape nor shadow.
    try testing.expectEqual(@as(u8, 0), px(&surface, 6, 6).a);
}

test "a filter runs in linearRGB unless the document says otherwise" {
    const gpa = testing.allocator;
    // §15.3, and the surprise in the whole of `<filter>`: the midpoint of a
    // blurred black-and-white boundary is a long way from the midpoint of the
    // numbers, because the average is taken of the light.
    const doc =
        "<svg viewBox=\"0 0 32 16\"><filter id=\"f\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"{s}>" ++
        "<feGaussianBlur stdDeviation=\"3\"/></filter>" ++
        "<g filter=\"url(#f)\"><rect width=\"16\" height=\"16\" fill=\"#fff\"/>" ++
        "<rect x=\"16\" width=\"16\" height=\"16\" fill=\"#000\"/></g></svg>";

    var linear_src: [512]u8 = undefined;
    var srgb_src: [512]u8 = undefined;
    const linear = try std.fmt.bufPrint(&linear_src, doc, .{""});
    const srgb = try std.fmt.bufPrint(&srgb_src, doc, .{" color-interpolation-filters=\"sRGB\""});

    var a = try render(gpa, linear, .{ .width = 32, .height = 16 });
    defer a.deinit(gpa);
    var b = try render(gpa, srgb, .{ .width = 32, .height = 16 });
    defer b.deinit(gpa);

    const mid = struct {
        fn f(sfc: *z2d.Surface) u8 {
            return sfc.image_surface_rgba.buf[@intCast(8 * sfc.getWidth() + 16)].r;
        }
    }.f;
    // In sRGB the boundary lands near half of 255; in linearRGB it lands far
    // brighter, because half the light is about 188.
    try testing.expect(mid(&b) < 140);
    try testing.expect(mid(&a) > 165);
}

test "a pattern draws its tile once per cell, and refuses an absurd lattice" {
    const gpa = testing.allocator;
    // Four 4-unit tiles over an 8-unit square, each with a 2-unit mark in its
    // corner: the mark repeats, which is the whole of what a pattern is.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\"" ++
            " patternUnits=\"userSpaceOnUse\"><rect width=\"2\" height=\"2\"" ++
            " fill=\"black\"/></pattern>" ++
            "<rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer surface.deinit(gpa);
    for ([_][2]i32{ .{ 1, 1 }, .{ 5, 1 }, .{ 1, 5 }, .{ 5, 5 } }) |at| {
        try testing.expectEqual(@as(u8, 255), surface.getPixel(at[0], at[1]).?.rgba.a);
    }
    for ([_][2]i32{ .{ 3, 3 }, .{ 7, 3 }, .{ 3, 7 } }) |at| {
        try testing.expectEqual(@as(u8, 0), surface.getPixel(at[0], at[1]).?.rgba.a);
    }

    // A tile small enough that the lattice would need more cells than the
    // budget allows. Refused whole rather than drawn part way.
    try testing.expectError(error.TooManyPatternTiles, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"0.001\" height=\"0.001\"" ++
            " patternUnits=\"userSpaceOnUse\"><rect width=\"1\" height=\"1\"/></pattern>" ++
            "<rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
        .{ .width = 8, .height = 8 },
    ));

    // A pattern that paints itself. The walk sees no cycle -- each level is a
    // finite document drawing a finite tile -- so only the pass depth catches
    // it, the same bound a mask inside a mask runs into.
    try testing.expectError(error.TooManyMaskHops, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\"" ++
            " patternUnits=\"userSpaceOnUse\"><rect width=\"4\" height=\"4\"" ++
            " fill=\"url(#p)\"/></pattern>" ++
            "<rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
        .{ .width = 8, .height = 8 },
    ));

    // A pattern with no tile, and one with nothing in it, paint nothing --
    // which is what resvg draws, and is not an error.
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"0\" height=\"4\"" ++
            " patternUnits=\"userSpaceOnUse\"><rect width=\"2\" height=\"2\"/></pattern>" ++
            "<rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><pattern id=\"p\" width=\"4\" height=\"4\"" ++
            " patternUnits=\"userSpaceOnUse\"/>" ++
            "<rect width=\"8\" height=\"8\" fill=\"url(#p)\"/></svg>",
    }) |src| {
        var blank = try render(gpa, src, .{ .width = 8, .height = 8 });
        defer blank.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), blank.getPixel(4, 4).?.rgba.a);
    }
}

test "a mask turns its content's luminance into coverage" {
    const gpa = testing.allocator;
    // White masks nothing away, mid-grey halves what is under it, and black
    // masks everything. The greys are the whole difference between a mask and
    // a clip, which only ever answers "covered" or "not".
    //
    // Mid-grey coming out at 128 rather than at 55 is also the evidence that
    // the coefficients go on the bytes as stored: linearizing first would more
    // than halve it. resvg draws 128, and so does this.
    for ([_]struct { src: []const u8, alpha: u8 }{
        .{ .src = "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><rect width=\"8\" height=\"8\"" ++
            " fill=\"#ffffff\"/></mask><rect width=\"8\" height=\"8\" fill=\"black\"" ++
            " mask=\"url(#m)\"/></svg>", .alpha = 255 },
        .{ .src = "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><rect width=\"8\" height=\"8\"" ++
            " fill=\"#808080\"/></mask><rect width=\"8\" height=\"8\" fill=\"black\"" ++
            " mask=\"url(#m)\"/></svg>", .alpha = 128 },
        .{ .src = "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><rect width=\"8\" height=\"8\"" ++
            " fill=\"#000000\"/></mask><rect width=\"8\" height=\"8\" fill=\"black\"" ++
            " mask=\"url(#m)\"/></svg>", .alpha = 0 },
    }) |case| {
        var surface = try render(gpa, case.src, .{ .width = 8, .height = 8 });
        defer surface.deinit(gpa);
        // Within one of the answer: the coefficients are applied in floating
        // point and rounded once.
        const got = surface.getPixel(4, 4).?.rgba.a;
        try testing.expect(@abs(@as(i32, got) - @as(i32, case.alpha)) <= 1);
    }
}

test "a mask's region clips it, and a mask that names the wrong thing is refused" {
    const gpa = testing.allocator;
    // The content covers everything; the region is the top half, in the user
    // space of the masked element.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" maskUnits=\"userSpaceOnUse\"" ++
            " x=\"0\" y=\"0\" width=\"8\" height=\"4\">" ++
            "<rect width=\"8\" height=\"8\" fill=\"white\"/></mask>" ++
            "<rect width=\"8\" height=\"8\" fill=\"black\" mask=\"url(#m)\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(4, 2).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(4, 6).?.rgba.a);

    try testing.expectError(error.UnknownReference, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" mask=\"url(#nothing)\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadMask, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><clipPath id=\"c\"><rect width=\"8\" height=\"8\"/></clipPath>" ++
            "<rect width=\"8\" height=\"8\" mask=\"url(#c)\"/></svg>",
        .{},
    ));
}

test "mask-type=alpha takes the content's opacity and not its colour" {
    const gpa = testing.allocator;
    // Red and green have wildly different luminances and the same alpha, so a
    // mask that cannot tell them apart is reading alpha.
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask-type=\"alpha\"><rect width=\"8\"" ++
            " height=\"8\" fill=\"#ff0000\" fill-opacity=\"0.5\"/></mask>" ++
            "<rect width=\"8\" height=\"8\" fill=\"black\" mask=\"url(#m)\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask-type=\"alpha\"><rect width=\"8\"" ++
            " height=\"8\" fill=\"#00ff00\" fill-opacity=\"0.5\"/></mask>" ++
            "<rect width=\"8\" height=\"8\" fill=\"black\" mask=\"url(#m)\"/></svg>",
    }) |src| {
        var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
        defer surface.deinit(gpa);
        try testing.expectEqual(@as(u8, 128), surface.getPixel(4, 4).?.rgba.a);
    }
    // A spelling neither this nor the specification knows is refused rather
    // than taken as luminance.
    try testing.expectError(error.BadMask, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask-type=\"lightness\">" ++
            "<rect width=\"8\" height=\"8\" fill=\"white\"/></mask>" ++
            "<rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
        .{},
    ));
}

test "an absurd mask region is bounded rather than a crash" {
    const gpa = testing.allocator;
    // The region's four numbers are the document's, and turning a float into
    // the surface's `i32` is a panic for anything the type cannot hold.
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" maskUnits=\"userSpaceOnUse\" x=\"-1e300\"" ++
            " y=\"-1e300\" width=\"1e300\" height=\"1e300\"><rect width=\"8\" height=\"8\"" ++
            " fill=\"white\"/></mask><rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" x=\"1e300\" y=\"1e300\" width=\"1e300\"" ++
            " height=\"1e300\"><rect width=\"8\" height=\"8\" fill=\"white\"/></mask>" ++
            "<rect width=\"8\" height=\"8\" mask=\"url(#m)\"/></svg>",
    }) |src| {
        var surface = render(gpa, src, .{ .width = 8, .height = 8 }) catch continue;
        defer surface.deinit(gpa);
    }
}

test "a mask that masks itself is bounded rather than endless" {
    const gpa = testing.allocator;
    // Through the `mask` attribute on the `<mask>` itself.
    try testing.expectError(error.TooManyMaskHops, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\" mask=\"url(#m)\">" ++
            "<rect width=\"8\" height=\"8\" fill=\"white\"/></mask>" ++
            "<rect width=\"8\" height=\"8\" fill=\"black\" mask=\"url(#m)\"/></svg>",
        .{},
    ));
    // And through what the mask *draws*: a `<use>` inside it naming the very
    // element the mask is on. The walk sees no cycle here -- each level is a
    // finite document of its own -- so only the pass depth catches it.
    try testing.expectError(error.TooManyMaskHops, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><mask id=\"m\"><use href=\"#r\"/></mask>" ++
            "<rect id=\"r\" width=\"8\" height=\"8\" fill=\"white\" mask=\"url(#m)\"/></svg>",
        .{},
    ));
}

test "a definition is not drawn where it stands" {
    const gpa = testing.allocator;
    // Written straight into the body rather than into `<defs>`, which §5.5
    // allows and which used to be `error.UnsupportedElement`.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"red\"/>" ++
            "</linearGradient><clipPath id=\"c\"><rect width=\"4\" height=\"8\"/></clipPath>" ++
            "<rect width=\"8\" height=\"8\" fill=\"url(#g)\" clip-path=\"url(#c)\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(2, 4).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(6, 4).?.rgba.a);
}

test "groups nested past the layer limit are refused" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<svg viewBox=\"0 0 8 8\">");
    for (0..6) |_| try src.appendSlice(gpa, "<g opacity=\"0.9\">");
    try src.appendSlice(gpa, "<rect width=\"8\" height=\"8\"/>");
    for (0..6) |_| try src.appendSlice(gpa, "</g>");
    try src.appendSlice(gpa, "</svg>");

    try testing.expectError(error.TooManyLayers, render(gpa, src.items, .{
        .width = 8,
        .height = 8,
        .limits = .{ .max_layers = 3 },
    }));
}

test "a transform moves a shape" {
    const gpa = testing.allocator;
    // A 4x4 square at the origin of an 8x8 viewBox, rendered at 8 pixels: the
    // square covers the top-left quadrant, and translate(4,4) puts it in the
    // bottom-right.
    const plain = "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" fill=\"red\"/></svg>";
    const moved = "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" fill=\"red\" transform=\"translate(4,4)\"/></svg>";

    var a = try render(gpa, plain, .{ .width = 8, .height = 8 });
    defer a.deinit(gpa);
    var b = try render(gpa, moved, .{ .width = 8, .height = 8 });
    defer b.deinit(gpa);

    try testing.expectEqual(@as(u8, 255), a.getPixel(1, 1).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), a.getPixel(6, 6).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), b.getPixel(1, 1).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), b.getPixel(6, 6).?.rgba.a);
}

test "a group's transform applies to what is inside it, and composes" {
    const gpa = testing.allocator;
    // Two ways of putting the square in the bottom-right: on the group, or
    // split between the group and the shape. Both must land in the same place.
    const on_group = "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,4)\">" ++
        "<path d=\"M0 0H4V4H0Z\" fill=\"red\"/></g></svg>";
    const split = "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,0)\">" ++
        "<path d=\"M0 0H4V4H0Z\" fill=\"red\" transform=\"translate(0,4)\"/></g></svg>";
    const nested = "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(4,0)\">" ++
        "<g transform=\"translate(0,4)\"><path d=\"M0 0H4V4H0Z\" fill=\"red\"/></g></g></svg>";

    for ([_][]const u8{ on_group, split, nested }) |src| {
        var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
        defer surface.deinit(gpa);
        try testing.expectEqual(@as(u8, 255), surface.getPixel(6, 6).?.rgba.a);
        try testing.expectEqual(@as(u8, 0), surface.getPixel(1, 1).?.rgba.a);
    }
}

test "a group's transform is undone when the group closes" {
    const gpa = testing.allocator;
    // The second shape is a sibling of the group, not a child, so the
    // translate must not still be in force when it is drawn. A stack that
    // never pops would put both squares in the bottom-right.
    const src = "<svg viewBox=\"0 0 8 8\">" ++
        "<g transform=\"translate(4,4)\"><path d=\"M0 0H4V4H0Z\" fill=\"red\"/></g>" ++
        "<path d=\"M0 0H4V4H0Z\" fill=\"blue\"/></svg>";
    var surface = try render(gpa, src, .{ .width = 8, .height = 8 });
    defer surface.deinit(gpa);
    const top_left = z2d.pixel.RGBA.fromPixel(surface.getPixel(1, 1).?).demultiply();
    const bottom_right = z2d.pixel.RGBA.fromPixel(surface.getPixel(6, 6).?).demultiply();
    try testing.expectEqual(@as(u8, 255), top_left.b);
    try testing.expectEqual(@as(u8, 255), bottom_right.r);
}

test "a group's presentation attributes are inherited and overridden" {
    const gpa = testing.allocator;
    const inherited = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g fill=\"red\"><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), inherited.r);

    const overridden = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g fill=\"red\"><path d=\"M0 0H8V8H0Z\" fill=\"blue\"/></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), overridden.b);

    // Three levels: the root, a group, and the shape, each overriding the last.
    const deep = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><g fill=\"blue\">" ++
            "<g><path d=\"M0 0H8V8H0Z\" fill=\"lime\"/></g></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), deep.g);
    try testing.expectEqual(@as(u8, 0), deep.r);
    try testing.expectEqual(@as(u8, 0), deep.b);

    // And a group that names nothing passes its parent's value straight down.
    const through = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\" fill=\"red\"><g><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), through.r);
}

test "a transform on the root applies in user units" {
    const gpa = testing.allocator;
    // viewBox 8 units wide rendered at 32 pixels, so the scale is 4. A root
    // translate of 2 *user* units moves the shape 8 pixels, not 2 -- the
    // viewBox mapping is outside the document's own transforms.
    const src = "<svg viewBox=\"0 0 8 8\" transform=\"translate(2,0)\">" ++
        "<path d=\"M0 0H2V2H0Z\" fill=\"red\"/></svg>";
    var surface = try render(gpa, src, .{ .width = 32, .height = 32 });
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(4, 4).?.rgba.a);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(12, 4).?.rgba.a);
}

test "a malformed transform is refused, and an empty one is the identity" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadTransform, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" transform=\"bogus(1)\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadTransform, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g transform=\"translate(\"><path d=\"M0 0H8V8H0Z\"/></g></svg>",
        .{},
    ));
    const identity = try middleOf(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0Z\" transform=\"\"/></svg>",
        .{},
    );
    try testing.expectEqual(@as(u8, 255), identity.a);
}

test "groups nested past the limit are refused rather than overflowing" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<svg viewBox=\"0 0 8 8\">");
    for (0..document.max_container_depth + 2) |_| try src.appendSlice(gpa, "<g>");
    try src.appendSlice(gpa, "<path d=\"M0 0H8V8H0Z\"/>");
    for (0..document.max_container_depth + 2) |_| try src.appendSlice(gpa, "</g>");
    try src.appendSlice(gpa, "</svg>");

    try testing.expectError(error.TooDeeplyNested, render(gpa, src.items, .{}));
}

test "a transform that puts a point past the rasterizer's reach is refused" {
    // Found by the fuzzer, and it was a *panic* rather than an error: z2d
    // reduces a polygon's extent to an i32, so a four-unit square scaled by
    // 1e300 is `@intFromFloat` on a value out of range. The matrix itself is
    // perfectly finite, which is why checking the matrix is not enough.
    const gpa = testing.allocator;
    try testing.expectError(error.CoordinateOutOfRange, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H4V4H0Z\" transform=\"scale(1e300)\"/></svg>",
        .{},
    ));
    // The same number written in the path data is *not* an error, because
    // z2d clamps a coordinate as it is added -- `H1e300` becomes 8388607. The
    // clamp is on the wrong side of the transform, which is the whole reason
    // the check above has to exist; see `document.max_coordinate`.
    //
    // Moving that clamp after the matrix looks like it would settle this, and
    // does not: it leaves a corner at the origin where it is and snaps the
    // rest to the bound, so `scale(1e10)` on a small square stops being far
    // away and covers the viewport instead. It was tried in the z2d fork and
    // reverted. Refusing here keeps the geometry honest.
    var clamped = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H1e300V1e300H0Z\"/></svg>",
        .{ .width = 8, .height = 8 },
    );
    defer clamped.deinit(gpa);
}
test "a transform that overflows to infinity is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.NonFiniteTransform, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><g transform=\"scale(1e300)\">" ++
            "<path d=\"M0 0H8V8H0Z\" transform=\"scale(1e300)\"/></g></svg>",
        .{},
    ));
}

test "a similarity transform is recognised, and a warped one is not" {
    try testing.expect(uniformScale(.identity).? == 1.0);
    try testing.expectApproxEqAbs(@as(f64, 3), uniformScale(try transform.parse("scale(3)")).?, 1e-12);
    // Rotation and translation do not change the scale.
    try testing.expectApproxEqAbs(
        @as(f64, 2),
        uniformScale(try transform.parse("translate(5,7) rotate(37) scale(2)")).?,
        1e-9,
    );
    // A reflection is still a similarity: it maps a circle to a circle.
    try testing.expectApproxEqAbs(@as(f64, 2), uniformScale(try transform.parse("scale(2,-2)")).?, 1e-12);
    // These are not.
    try testing.expectEqual(@as(?f64, null), uniformScale(try transform.parse("scale(3,1)")));
    try testing.expectEqual(@as(?f64, null), uniformScale(try transform.parse("skewX(20)")));
    try testing.expectEqual(@as(?f64, null), uniformScale(try transform.parse("scale(0)")));
}

fn dashesOf(raw: []const u8) ![]const f64 {
    const S = struct {
        var storage: [max_dashes]f64 = undefined;
    };
    const n = try readDashes(raw, &S.storage);
    return S.storage[0..n];
}

test "a dash array is read, and an odd one is repeated" {
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, try dashesOf("4 2"));
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, try dashesOf("4,2"));
    // §11.4: an odd count is repeated, so `4` is four on and four off.
    try testing.expectEqualSlices(f64, &.{ 4, 4 }, try dashesOf("4"));
    try testing.expectEqualSlices(f64, &.{ 4, 2, 1, 4, 2, 1 }, try dashesOf("4,2,1"));
}

test "a dash array that is not one leaves the stroke solid" {
    for ([_][]const u8{ "", "   ", "none", "0", "0 0", "0,0,0", "-4 2", "abc" }) |raw| {
        try testing.expectEqual(@as(usize, 0), (try dashesOf(raw)).len);
    }
}

test "a dash array stops at the first value that is not a length" {
    // The same leniency a `points` list gets, and for the same reason: resvg
    // and every browser draw the dashes they managed to read.
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, try dashesOf("4 2 bogus"));
}

test "a dash array longer than the ceiling is refused" {
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..max_dashes) |_| try long.appendSlice(testing.allocator, "1 ");
    var storage: [max_dashes]f64 = undefined;
    try testing.expectError(error.TooManyDashes, readDashes(long.items, &storage));
}

test "a shape with no stroke named is not stroked" {
    const gpa = testing.allocator;
    // SVG's initial `stroke` is `none`, so unlike `fill` the caller's colour
    // is *not* the default here -- a shape stroked without asking would put
    // lines in a picture the document does not have.
    var surface = try render(gpa, square(""), .{ .width = 20, .height = 20 });
    defer surface.deinit(gpa);
    var doc = try document.read(gpa, square(""));
    defer doc.deinit();
    var it = doc.paths();
    const only = (try it.next()).?.shape;
    try testing.expectEqual(@as(?color.Paint, null), only.stroke);
    try testing.expectEqual(@as(?Stroke, null), try resolveStroke(only, .{}));
}

test "a stroke of zero or negative width is not drawn" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-width=\"0\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-width=\"-3\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"none\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-opacity=\"0\"/></svg>",
    }) |src| {
        var surface = try render(gpa, src, .{ .width = 16, .height = 16 });
        defer surface.deinit(gpa);
        for (0..16) |y| for (0..16) |x| {
            try testing.expectEqual(
                @as(u8, 0),
                surface.getPixel(@intCast(x), @intCast(y)).?.rgba.a,
            );
        };
    }
}

test "a stroked line finally draws something" {
    const gpa = testing.allocator;
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" stroke-width=\"2\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(8, 8).?.rgba.a);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(8, 1).?.rgba.a);
}

test "fill is painted first and the stroke over it" {
    const gpa = testing.allocator;
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 16 16\"><rect x=\"4\" y=\"4\" width=\"8\" height=\"8\" " ++
            "fill=\"blue\" stroke=\"red\" stroke-width=\"4\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer surface.deinit(gpa);
    const middle = z2d.pixel.RGBA.fromPixel(surface.getPixel(8, 8).?).demultiply();
    const edge = z2d.pixel.RGBA.fromPixel(surface.getPixel(4, 8).?).demultiply();
    try testing.expectEqual(@as(u8, 255), middle.b);
    try testing.expectEqual(@as(u8, 255), edge.r);
}

test "a stroke style this reader does not know is refused" {
    const gpa = testing.allocator;
    const line = "<svg viewBox=\"0 0 8 8\"><line x1=\"0\" y1=\"4\" x2=\"8\" y2=\"4\" stroke=\"red\" ";
    try testing.expectError(error.BadStrokeStyle, render(
        gpa,
        line ++ "stroke-linecap=\"ROUND\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadStrokeStyle, render(
        gpa,
        line ++ "stroke-linejoin=\"bogus\"/></svg>",
        .{},
    ));
    try testing.expectError(error.BadStrokeStyle, render(
        gpa,
        line ++ "stroke-miterlimit=\"wide\"/></svg>",
        .{},
    ));
    // A miter limit below one is clamped rather than refused, which is what
    // resvg does: `0.5` draws exactly what `1` draws.
    var surface = try render(gpa, line ++ "stroke-miterlimit=\"0.5\"/></svg>", .{});
    defer surface.deinit(gpa);
}

test "an entity reference in an attribute value is resolved" {
    const gpa = testing.allocator;
    // `&#90;` is `Z`, so this closes the subpath and fills a square. Without
    // decoding it reaches the path parser as five literal characters and is
    // `error.UnknownCommand`.
    var surface = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&#90;\" fill=\"red\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer surface.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), surface.getPixel(8, 8).?.rgba.a);
}

test "a reference is resolved in every kind of attribute value" {
    const gpa = testing.allocator;
    // A colour, a number, a length, a transform, a `points` list and a dash
    // array -- the parsed ones through the reader's buffer and the borrowed
    // ones where they are drawn.
    const cases = [_][]const u8{
        // `&#114;ed` is `red`.
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"&#114;ed\"/></svg>",
        // `&#56;` is `8`.
        "<svg viewBox=\"0 0 8 8\"><rect width=\"&#56;\" height=\"8\" fill=\"red\"/></svg>",
        // A transform list.
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"red\" transform=\"translate(&#48;,0)\"/></svg>",
        // A `points` list, decoded with an allocator rather than a buffer.
        "<svg viewBox=\"0 0 8 8\"><polygon points=\"0,0 8,0 8,&#56; 0,8\" fill=\"red\"/></svg>",
    };
    for (cases) |src| {
        var surface = try render(gpa, src, .{ .width = 16, .height = 16 });
        defer surface.deinit(gpa);
        try testing.expectEqual(@as(u8, 255), surface.getPixel(8, 8).?.rgba.a);
    }

    // And a dash array, which is read where the stroke is resolved.
    var dashed = try render(
        gpa,
        "<svg viewBox=\"0 0 16 16\"><line x1=\"0\" y1=\"8\" x2=\"16\" y2=\"8\" " ++
            "stroke=\"red\" stroke-width=\"4\" stroke-dasharray=\"&#52; 2\"/></svg>",
        .{ .width = 16, .height = 16 },
    );
    defer dashed.deinit(gpa);
    // Dashed rather than solid: something along the line is unpainted.
    var gaps: usize = 0;
    for (0..16) |x| {
        if (dashed.getPixel(@intCast(x), 8).?.rgba.a == 0) gaps += 1;
    }
    try testing.expect(gaps > 0);
}

test "an entity nobody declared is refused rather than drawn as text" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownEntity, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"&nosuch;\"/></svg>",
        .{},
    ));
    try testing.expectError(error.UnknownEntity, render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0H8V8H0&nosuch;\"/></svg>",
        .{},
    ));
}

test "a path past the node limit is refused" {
    try testing.expectError(error.PathTooComplex, render(testing.allocator, icon, .{
        .limits = .{ .max_path_nodes = 2 },
    }));
}

test "draw paints into a surface somebody else made" {
    const gpa = testing.allocator;
    var surface = try z2d.Surface.initPixel(
        .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
        gpa,
        64,
        32,
    );
    defer surface.deinit(gpa);

    try draw(gpa, &surface, icon, .{
        .x = 32,
        .y = 0,
        .width = 32,
        .height = 32,
    }, .{ .fill = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } });

    // Painted on the right half and not on the left.
    try testing.expectEqual(@as(u8, 255), surface.getPixel(48, 16).?.rgb.g);
    try testing.expectEqual(@as(u8, 0), surface.getPixel(16, 16).?.rgb.g);
}

/// Records what a document asked for, and answers nothing.
///
/// Enough for every question here that is about the *request* rather than the
/// glyphs: which families were offered and in what order, and what weight and
/// style went with them. Answering nothing means the render ends in
/// `NoFontSupplied`, which is fine -- by then the asking has happened, and it
/// is what these tests are looking at.
///
/// The alternative would be a font to draw with, and a unit test has no way to
/// find one: `SVG_TEST_FONT` is what the devshell sets, and 0.16 reaches the
/// environment only through `std.process.Init`, which a test does not get.
/// `tests/oracle` is where text is checked against a real face, against resvg,
/// with both given the same file.
const Asked = struct {
    /// Copied rather than borrowed. A request's `family` points into the
    /// document's arena, which `render` releases before it returns, so
    /// keeping the slice and reading it afterwards is a use-after-free -- and
    /// one that showed up as a crash rather than as a wrong answer.
    var storage: [8][64]u8 = undefined;
    var lengths: [8]usize = undefined;
    var count: usize = 0;
    var weight: u16 = 0;
    var italic: bool = false;

    fn resolve(ctx: ?*anyopaque, req: FontRequest) ?[]const u8 {
        _ = ctx;
        if (count < storage.len) {
            const n = @min(req.family.len, storage[count].len);
            @memcpy(storage[count][0..n], req.family[0..n]);
            lengths[count] = n;
            count += 1;
        }
        weight = req.weight;
        italic = req.italic;
        return null;
    }

    fn family(i: usize) []const u8 {
        return storage[i][0..lengths[i]];
    }

    fn reset() void {
        count = 0;
        weight = 0;
        italic = false;
    }

    fn resolver() FontResolver {
        return .{ .ctx = null, .resolve = Asked.resolve };
    }
};

test "text is refused when there is no font to draw it with" {
    const gpa = testing.allocator;
    const src = "<svg viewBox=\"0 0 32 32\"><text x=\"2\" y=\"20\" font-size=\"12\">hi</text></svg>";

    // No resolver at all.
    try testing.expectError(error.NoFontSupplied, render(gpa, src, .{}));

    // And a resolver that answers nothing, not even a default: refused rather
    // than drawn with the text missing, which would be a picture that looks
    // finished and is not.
    Asked.reset();
    try testing.expectError(error.NoFontSupplied, render(gpa, src, .{
        .fonts = Asked.resolver(),
    }));
}

test "the font-family list is offered in order, then the default" {
    Asked.reset();
    _ = render(
        testing.allocator,
        "<svg viewBox=\"0 0 32 32\"><text x=\"2\" y=\"20\" font-size=\"12\"" ++
            " font-family=\"'Fancy One', Second , Third\">hi</text></svg>",
        .{ .fonts = Asked.resolver() },
    ) catch {};

    // §10.10's list is a preference order, so each name is offered in turn --
    // trimmed and unquoted -- and the empty one at the end is the request for
    // whatever the resolver calls its default.
    try testing.expectEqual(@as(usize, 4), Asked.count);
    try testing.expectEqualStrings("Fancy One", Asked.family(0));
    try testing.expectEqualStrings("Second", Asked.family(1));
    try testing.expectEqualStrings("Third", Asked.family(2));
    try testing.expectEqualStrings("", Asked.family(3));
}

test "a document naming no family asks only for the default" {
    Asked.reset();
    _ = render(
        testing.allocator,
        "<svg viewBox=\"0 0 32 32\"><text x=\"2\" y=\"20\" font-size=\"12\">hi</text></svg>",
        .{ .fonts = Asked.resolver() },
    ) catch {};
    try testing.expectEqual(@as(usize, 1), Asked.count);
    try testing.expectEqualStrings("", Asked.family(0));
}

test "a font request carries the weight and the style" {
    for ([_]struct { attrs: []const u8, weight: u16, italic: bool }{
        .{ .attrs = "", .weight = 400, .italic = false },
        .{ .attrs = " font-weight=\"bold\"", .weight = 700, .italic = false },
        .{ .attrs = " font-weight=\"600\"", .weight = 600, .italic = false },
        .{ .attrs = " font-style=\"italic\"", .weight = 400, .italic = true },
        // `oblique` is a slanted upright rather than a true italic, and a
        // resolver asked for one and given the other is closer than one asked
        // for nothing.
        .{ .attrs = " font-style=\"oblique\"", .weight = 400, .italic = true },
        .{ .attrs = " font-weight=\"bold\" font-style=\"italic\"", .weight = 700, .italic = true },
    }) |case| {
        Asked.reset();
        const src = try std.fmt.allocPrint(
            testing.allocator,
            "<svg viewBox=\"0 0 32 32\"><text x=\"2\" y=\"20\" font-size=\"12\"{s}>hi</text></svg>",
            .{case.attrs},
        );
        defer testing.allocator.free(src);
        _ = render(testing.allocator, src, .{ .fonts = Asked.resolver() }) catch {};
        try testing.expectEqual(case.weight, Asked.weight);
        try testing.expectEqual(case.italic, Asked.italic);
    }
}

test "a font property is inherited through a container" {
    Asked.reset();
    _ = render(
        testing.allocator,
        "<svg viewBox=\"0 0 32 32\"><g font-family=\"Outer\" font-weight=\"bold\">" ++
            "<text x=\"2\" y=\"20\" font-size=\"12\">hi</text></g></svg>",
        .{ .fonts = Asked.resolver() },
    ) catch {};
    try testing.expectEqualStrings("Outer", Asked.family(0));
    try testing.expectEqual(@as(u16, 700), Asked.weight);
}

test "a text property the reader cannot read is refused" {
    const gpa = testing.allocator;
    for ([_]struct { attrs: []const u8, want: anyerror }{
        .{ .attrs = " text-anchor=\"centre\"", .want = error.BadTextAnchor },
        .{ .attrs = " font-weight=\"heavy\"", .want = error.BadFontWeight },
        .{ .attrs = " font-weight=\"0\"", .want = error.BadFontWeight },
        .{ .attrs = " font-style=\"slanted\"", .want = error.BadFontStyle },
    }) |case| {
        const src = try std.fmt.allocPrint(
            gpa,
            "<svg viewBox=\"0 0 32 32\"><text x=\"2\" y=\"20\"{s}>hi</text></svg>",
            .{case.attrs},
        );
        defer gpa.free(src);
        try testing.expectError(case.want, render(gpa, src, .{ .fonts = Asked.resolver() }));
    }
}

test "whitespace in a text run is collapsed" {
    const gpa = testing.allocator;
    for ([_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = "  hello   world  ", .want = "hello world" },
        .{ .raw = "\n    indented\n    across lines\n  ", .want = "indented across lines" },
        .{ .raw = "\t\ttabs\tbetween\t", .want = "tabs between" },
        .{ .raw = "", .want = "" },
        .{ .raw = "   ", .want = "" },
        .{ .raw = "one", .want = "one" },
    }) |case| {
        const got = try collapseWhitespace(gpa, case.raw);
        defer gpa.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "a rotate list gives its last angle to every glyph after it" {
    // §10.4: one angle per character, and the last repeats for whatever is
    // left -- which is what makes `rotate="45"` turn every glyph rather than
    // only the first.
    try testing.expectEqual(@as(?f64, null), try rotationAt(null, 0));
    for (0..4) |i| {
        try testing.expectEqual(@as(?f64, 45), try rotationAt("45", i));
    }
    try testing.expectEqual(@as(?f64, 0), try rotationAt("0 30 -30", 0));
    try testing.expectEqual(@as(?f64, 30), try rotationAt("0 30 -30", 1));
    try testing.expectEqual(@as(?f64, -30), try rotationAt("0 30 -30", 2));
    try testing.expectEqual(@as(?f64, -30), try rotationAt("0 30 -30", 9));
    // Commas and runs of space separate as well as single spaces do.
    try testing.expectEqual(@as(?f64, 30), try rotationAt(" 0 , 30 ,-30 ", 1));
    // An empty list has no angle to give.
    try testing.expectEqual(@as(?f64, null), try rotationAt("   ", 0));
    // And something that is not a number is refused rather than skipped.
    try testing.expectError(error.BadLength, rotationAt("0 wobbly", 1));
}

test "a node budget too small to draw with is refused, not overflowed" {
    const gpa = testing.allocator;

    // Found by the fuzzer, through a `<pattern>`. Several builders produce a
    // fixed number of nodes whatever the budget says -- there is no sensible
    // half-drawn rectangle -- so the budget can be overshot, and subtracting
    // past zero in a `usize` is an integer overflow rather than an error.
    for ([_][]const u8{
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><circle cx=\"4\" cy=\"4\" r=\"3\"/></svg>",
        "<svg viewBox=\"0 0 8 8\"><ellipse cx=\"4\" cy=\"4\" rx=\"3\" ry=\"2\"/></svg>",
    }) |src| {
        try testing.expectError(error.PathTooComplex, render(gpa, src, .{
            .width = 8,
            .height = 8,
            .limits = .{ .max_path_nodes = 2 },
        }));
    }

    // And the way the fuzzer reached it: a pattern spends one budget across
    // every cell of its lattice, so a fine enough one drains it to nearly
    // nothing and the next rectangle asks for five.
    try testing.expectError(error.PathTooComplex, render(
        gpa,
        "<svg viewBox=\"0 0 32 32\"><pattern id=\"p\" width=\"2\" height=\"2\"" ++
            " patternUnits=\"userSpaceOnUse\"><rect width=\"1\" height=\"1\"/></pattern>" ++
            "<rect width=\"32\" height=\"32\" fill=\"url(#p)\"/></svg>",
        .{ .width = 32, .height = 32, .limits = .{ .max_path_nodes = 40 } },
    ));

    // A budget that is enough still draws.
    var fine = try render(
        gpa,
        "<svg viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\" fill=\"black\"/></svg>",
        .{ .width = 8, .height = 8, .limits = .{ .max_path_nodes = 64 } },
    );
    defer fine.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), fine.getPixel(4, 4).?.rgba.a);
}

test "the node ceiling is what keeps text from outrunning the budget" {
    // Text is the one builder whose size the document chooses freely -- a run
    // is as many nodes as its glyphs need -- so it consults the ceiling before
    // appending rather than after, which is what the other builders that can
    // overshoot do not. Checked here directly, because drawing a glyph needs
    // a font and a unit test has no way to find one: 0.16 reaches the
    // environment only through `std.process.Init`, which a test does not get.
    const gpa = testing.allocator;
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 1, 1);

    // `max_nodes` is what this build may add, so with two already there and a
    // budget of six, six more fit and seven do not.
    try withinBudget(&p, 6, .{ .max_nodes = 6 });
    try testing.expectError(error.PathTooComplex, withinBudget(&p, 7, .{ .max_nodes = 6 }));
    // Adding nothing always fits, even with nothing left.
    try withinBudget(&p, 0, .{ .max_nodes = 0 });
    try testing.expectError(error.PathTooComplex, withinBudget(&p, 1, .{ .max_nodes = 0 }));
    // A budget so large that the ceiling would wrap is still a budget, and
    // saturating rather than wrapping is what keeps it one.
    try withinBudget(&p, 1 << 40, .{ .max_nodes = std.math.maxInt(usize) });
}

test "an Arc measures a path and answers points along it" {
    const gpa = testing.allocator;
    var arc: Arc = .{};
    defer arc.deinit(gpa);

    // A right-angled path: ten across, then ten down.
    try arc.add(gpa, 0, 0);
    try arc.add(gpa, 10, 0);
    try arc.add(gpa, 10, 10);
    try testing.expectApproxEqAbs(@as(f64, 20), arc.total(), 1e-9);

    // Along the first leg, heading east.
    const a = arc.at(5).?;
    try testing.expectApproxEqAbs(@as(f64, 5), a.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), a.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), a.angle, 1e-9);

    // Along the second, heading south -- which is a quarter turn in SVG's
    // coordinates, where y grows downwards.
    const b = arc.at(15).?;
    try testing.expectApproxEqAbs(@as(f64, 10), b.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), b.y, 1e-9);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, b.angle, 1e-9);

    // Both ends are on the path; past either is not, which is §10.13's rule
    // for a glyph that simply is not rendered.
    try testing.expect(arc.at(0) != null);
    try testing.expect(arc.at(20) != null);
    try testing.expect(arc.at(-0.5) == null);
    try testing.expect(arc.at(20.5) == null);

    // A repeated point adds no length and leaves no segment without a
    // direction to take a tangent from.
    try arc.add(gpa, 10, 10);
    try testing.expectApproxEqAbs(@as(f64, 20), arc.total(), 1e-9);
    try testing.expectEqual(@as(usize, 3), arc.xs.items.len);
}

test "flattening a curve gets its length about right" {
    const gpa = testing.allocator;

    // A quarter circle of radius ten, as the cubic that approximates one.
    // The cubic is not exactly a circle, so its length is not exactly
    // `pi * r / 2` either -- it is within a fraction of a percent, and so is
    // the flattening, which is far finer than a glyph's placement can show.
    const k = 0.5522847498307936;
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    try p.moveTo(gpa, 10, 0);
    try p.curveTo(gpa, 10, 10 * k, 10 * k, 10, 0, 10);

    var arc: Arc = .{};
    defer arc.deinit(gpa);
    try flatten(gpa, p.nodes.items, &arc);

    const truth = std.math.pi * 10.0 / 2.0;
    try testing.expectApproxEqRel(truth, arc.total(), 0.002);
}

test "only the first subpath of a textPath's shape is followed" {
    const gpa = testing.allocator;
    // §10.13 lays text along *the* path, and gives no rule for where one
    // subpath ends and the next begins, so the first is what is followed.
    var p: z2d.Path = .empty;
    defer p.deinit(gpa);
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 6, 0);
    try p.moveTo(gpa, 100, 100);
    try p.lineTo(gpa, 200, 100);

    var arc: Arc = .{};
    defer arc.deinit(gpa);
    try flatten(gpa, p.nodes.items, &arc);
    try testing.expectApproxEqAbs(@as(f64, 6), arc.total(), 1e-9);
}
