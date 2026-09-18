// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z2d_dep = b.dependency("z2d", .{ .target = target, .optimize = optimize });
    const ztree_dep = b.dependency("ztree", .{ .target = target, .optimize = optimize });

    const z2d = z2d_dep.module("z2d");
    // ztree rather than zxml directly: the reader needs random access to
    // resolve a `#id` reference, which a pull parser cannot give it. See
    // src/document.zig.
    const ztree = ztree_dep.module("ztree");

    // One module. The reader, the path grammar, the rasterizer and the sandbox
    // live together because Zig only analyses what is referenced: a program
    // that draws an icon and never mentions the sandbox does not compile the
    // sandbox, so splitting them would cost a dependency edge to save nothing.
    const mod = b.addModule("svg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "z2d", .module = z2d },
            .{ .name = "ztree", .module = ztree },
        },
    });

    const test_step = b.step("test", "Run the tests");
    const check_step = b.step("check", "Compile everything without running it");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    check_step.dependOn(&mod_tests.step);

    // The fuzz targets: what the renderer must do with input nobody wrote.
    // They are ordinary tests as well, so `zig build test` exercises the same
    // properties on the corpus checked in beside them.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "svg", .module = mod },
            .{ .name = "z2d", .module = z2d },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fuzz_mod })).step);

    // The loop that drives those targets without Zig's own fuzzer, which this
    // toolchain cannot usefully run: `tools/fuzz.zig` says why, and the short
    // version is that the coverage table comes back empty. Optimised, because
    // a fuzzer's whole job is how many inputs it gets through, and ReleaseSafe
    // keeps every check that makes a failure a failure.
    const fuzz_run = b.addExecutable(.{
        .name = "svg-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "fuzz_targets", .module = fuzz_mod }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_run);
    run_fuzz.stdio = .inherit;
    if (b.args) |a| run_fuzz.addArgs(a);
    b.step("fuzz-run", "Fuzz the targets with a loop of our own")
        .dependOn(&run_fuzz.step);
    check_step.dependOn(&fuzz_run.step);

    // Renders one document to a PNG, so that the path parser can be looked at.
    // A wrong arc is a slightly wrong picture, which is not something a test
    // discovers by itself.
    const svgdump = b.addExecutable(.{
        .name = "svgdump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/svgdump.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "svg", .module = mod },
                .{ .name = "z2d", .module = z2d },
            },
        }),
    });
    b.installArtifact(svgdump);
    const run_svgdump = b.addRunArtifact(svgdump);
    run_svgdump.stdio = .inherit;
    if (b.args) |a| run_svgdump.addArgs(a);
    b.step("svgdump", "Render one document to a PNG").dependOn(&run_svgdump.step);

    // Renders every document in `tests/oracle` for `tools/check_oracle.py` to
    // hold against resvg. This is the one claim about the renderer that a Zig
    // test cannot make on its own: a test here can check this renderer against
    // itself, and does, but only an independent implementation of the same
    // specification disagrees where the specification was misread.
    const oracle = b.addExecutable(.{
        .name = "svg-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/oracle.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "svg", .module = mod },
                .{ .name = "z2d", .module = z2d },
            },
        }),
    });
    const run_oracle = b.addRunArtifact(oracle);
    run_oracle.stdio = .inherit;
    run_oracle.addArg("tests/oracle");
    run_oracle.addArg(b.getInstallPath(.prefix, "oracle"));
    b.step("oracle", "Render the oracle corpus into zig-out/oracle")
        .dependOn(&run_oracle.step);
    check_step.dependOn(&oracle.step);

    // -- the library, and its documentation -----------------------------------
    //
    // A consumer imports the module above and never links against a compiled
    // object, so this artifact exists for two other reasons. Zig emits the API
    // documentation as a side effect of compiling, and something has to do
    // that compiling; and `zig build` with nothing installed produces an empty
    // output directory, which a Nix build rejects as a derivation that built
    // nothing.
    const library = b.addLibrary(.{ .name = "svg", .root_module = mod });
    b.installArtifact(library);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Build the API documentation into zig-out/docs")
        .dependOn(&install_docs.step);

    // That viewer fetches `sources.tar` and `main.wasm` at runtime, which a
    // browser refuses to do from a `file://` page, so reading the docs locally
    // means serving them. It is the same reason `zig std` runs a server rather
    // than opening a file.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always the machine running the build, never whatever -Dtarget
            // the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // It runs until interrupted, so its output has to reach the terminal
    // rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;
    b.step("docs-serve", "Serve the API documentation over HTTP")
        .dependOn(&run_docs_server.step);

    // The server has tests of its own, and nothing else builds it, so without
    // these two lines it could stop compiling and no test would notice.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
    check_step.dependOn(&svgdump.step);
}
