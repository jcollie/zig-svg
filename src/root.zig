// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! zig-svg draws SVG documents onto [z2d](https://github.com/vancluever/z2d)
//! surfaces.
//!
//! ```zig
//! const svg = @import("svg");
//!
//! var surface = try svg.render(gpa, source, .{ .width = 64, .height = 64 });
//! defer surface.deinit(gpa);
//! ```
//!
//! ## What it draws, and what it does not
//!
//! The static half of SVG 1.1: paths and the basic shapes, `<g>`, `<a>`,
//! `<use>` and `<symbol>`, nested `<svg>` viewports, `<switch>` and the
//! conditional attributes, `display` and `visibility`, transforms, fills and
//! strokes with every property that goes with them, markers and
//! `paint-order`, gradients and patterns, clipping and masking, the commonest
//! `<filter>`
//! primitives, CSS in a `style` attribute or a `<style>` element, `<text>` and
//! `<tspan>` with the fonts the caller supplies, and `<image>` with the
//! pictures z2dimg decodes. The path data grammar of §8.3 is complete,
//! elliptical arcs included, and so is §7.8's `preserveAspectRatio`.
//! `README.md` has the table, and `tests/oracle` has a fixture for each of
//! them checked against resvg.
//!
//! What it does not draw is the half that makes SVG a programming language
//! rather than a picture format -- scripting, animation, `<foreignObject>`,
//! and external references other than the pictures an `<image>` names, which
//! the caller is asked for.
//!
//! An element it cannot draw is **refused**, not skipped. A renderer that
//! skips what it does not understand produces a picture quietly missing a
//! piece, which is the failure nobody notices; `error.UnsupportedElement` is
//! the failure somebody does. That refusal is also what keeps this honest as
//! it grows: every feature on the list is a document that errors today.
//!
//! ## Sans-I/O
//!
//! Nothing here opens, closes, reads or writes a file, and nothing takes an
//! `Io`. A document arrives as a byte slice and pixels come back as memory;
//! where either came from is the calling program's business. So is anything
//! the document names from outside itself: a font is asked of
//! `Options.fonts`, and a picture that is not a `data:` URL of
//! `Options.images`, and both answer out of memory the caller already holds. That is what
//! makes `sandbox` possible — rendering never needed a file, so a process that
//! cannot open one is still a perfectly capable renderer.
//!
//! ## Sandboxing
//!
//! `sandbox.render` runs the renderer in a forked process locked down by the
//! kernel -- seccomp on Linux, reducing it to four system calls, one of them on
//! a single descriptor; Capsicum on FreeBSD, taking away every global
//! namespace -- with every inherited descriptor closed behind it, and passes
//! the pixels back through shared memory. It matters more for SVG than for most formats: the full
//! specification *includes* fetching documents, running scripts and reading
//! fonts, so a renderer growing towards it grows towards exactly the
//! capabilities the sandbox takes away. See that module for what it does and
//! does not protect against.
//!
//! ## Limits
//!
//! Every number in a document is a number somebody else chose, and two of them
//! — the output size and the path length — decide what the render costs. See
//! `Limits`; the defaults are worth reading before trusting them with input
//! from anywhere.

const std = @import("std");

/// Reading an `<svg>` element far enough to draw what is in it.
pub const document = @import("document.zig");
/// The colour syntax a presentation attribute is written in.
pub const color = @import("color.zig");
/// The `transform` attribute, as one matrix.
pub const transform = @import("transform.zig");
/// SVG's basic shapes, as path operations.
pub const shapes = @import("shapes.zig");
/// `<linearGradient>` and `<radialGradient>`.
pub const gradient = @import("gradient.zig");
pub const pattern = @import("pattern.zig");
/// `<filter>` and its primitives: SVG 1.1 §15.
pub const filter = @import("filter.zig");
/// The pixel operations those primitives are made of.
pub const image = @import("image.zig");
/// The rest of them: the colour, compositing and neighbourhood operations.
pub const fe = @import("fe.zig");
/// The pictures an `<image>` names: fetched from a `data:` URL or the
/// caller, decoded by z2dimg, and kept for the length of a render.
pub const bitmap = @import("bitmap.zig");
/// Drawing a decoded picture under a matrix.
pub const resample = @import("resample.zig");
/// Where a path's markers go and which way each faces: SVG 1.1 §11.6.
pub const marker = @import("marker.zig");
/// SVG 1.1 §6: the `style` attribute, a `<style>` element's rules, and the
/// cascade that decides between them.
///
/// Re-exported rather than re-implemented. It is [its own library][zig-css],
/// because deciding which of several declarations of one property applies to
/// an element is a job with one right answer that has nothing to do with
/// drawing.
///
/// [zig-css]: https://git.jcollie.dev/jeff/zig-css
pub const css = @import("css");
/// The lengths an attribute is written in, and their units.
pub const length = @import("length.zig");
/// The path data mini-language of SVG 1.1 §8.3.
pub const path = @import("path.zig");
/// SVG's elliptical arc command, as cubic Béziers.
pub const arc = @import("arc.zig");
/// From a document to pixels.
pub const raster = @import("raster.zig");
/// Rendering in a process that cannot do anything else.
pub const sandbox = @import("sandbox.zig");

/// Render a document into a surface of its own.
pub const render = raster.render;
/// Render a document into a surface the caller already has.
pub const draw = raster.draw;

/// A `viewBox` and the shapes it encloses.
pub const Document = document.Document;
/// Walks a document's `<path>` elements in painting order.
pub const PathIterator = document.PathIterator;
/// One drawable element, with the paint that applies to it.
pub const Shape = document.Shape;
/// An `<image>`, placed and ready to decode.
pub const Image = document.Image;
/// What a drawable element contributes: a `d`, or a basic shape's numbers.
pub const Geometry = shapes.Geometry;
/// A colour, in straight alpha.
pub const Color = color.Color;
/// What a `fill` attribute can say.
pub const Paint = color.Paint;
pub const ViewBox = document.ViewBox;
/// How a `viewBox` is fitted into the box it is drawn in.
pub const PreserveAspectRatio = document.PreserveAspectRatio;
/// Read a document without drawing it.
pub const read = document.read;

/// How to draw.
pub const Options = raster.Options;
/// Where in a surface to draw.
pub const Box = raster.Box;
/// How much a caller is willing to spend on a picture somebody else wrote.
pub const Limits = raster.Limits;
/// How the caller supplies a picture an `<image>` names by URL.
pub const ImageResolver = raster.ImageResolver;
/// Everything a render can fail with.
pub const Error = raster.Error;

test {
    std.testing.refAllDecls(@This());
    _ = document;
    _ = color;
    _ = transform;
    _ = shapes;
    _ = gradient;
    _ = pattern;
    _ = filter;
    _ = fe;
    _ = image;
    _ = bitmap;
    _ = resample;
    _ = marker;
    _ = css;
    _ = length;
    _ = path;
    _ = arc;
    _ = raster;
    _ = sandbox;
}
