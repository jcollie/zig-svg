# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  callPackage,
  zig_0_16,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "zig-svg";

  # Taken from build.zig.zon so that the package version cannot drift from the
  # one the Zig package manager reports.
  version =
    let
      zon = builtins.readFile ./build.zig.zon;
      matched = builtins.match ''.*\.version = "([^"]+)".*'' zon;
    in
    if matched == null then throw "zig-svg: no .version found in build.zig.zon" else builtins.head matched;

  # Named rather than filtered, so that editing something outside this list --
  # the flake, a scratch file, the README -- does not rebuild the package.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      ./tests
      ./tools
      ./LICENSES
      ./README.md
      ./REUSE.toml
    ];
  };

  nativeBuildInputs = [ zig_0_16.hook ];

  # The Zig package cache, which the build cannot fetch for itself: it runs
  # without a network. build.zig.zon.nix is generated from build.zig.zon by
  # zon2nix, so every dependency's hash comes from the manifest rather than
  # being kept by hand, and regenerating it is the whole of updating one:
  #
  #     nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
  #
  # --system points Zig at that directory and forbids fetching outright, so a
  # dependency missing from it is a build error naming the package rather than
  # a silent attempt to reach the network. The check phase assembles its own
  # flags, so it needs the same option.
  zigBuildFlags = [
    "--system"
    "${callPackage ./build.zig.zon.nix { }}"
  ];
  zigCheckFlags = finalAttrs.zigBuildFlags;

  # `zig build test` here rather than only in CI. Every test in this library is
  # pure -- no filesystem, no network -- except the sandbox's, which fork and
  # install a seccomp filter. The Nix build sandbox permits both.
  doCheck = true;

  meta = {
    description = "SVG rendering onto z2d surfaces";
    longDescription = ''
      A sans-I/O SVG renderer for Zig: it draws SVG documents onto z2d
      surfaces, taking the document as a byte slice and performing no I/O of
      its own. Because rendering is therefore a pure function over memory, the
      optional sandbox can run it in a forked process that seccomp has reduced
      to four system calls -- which matters for SVG, a format whose full
      specification includes fetching documents and running scripts.
    '';
    homepage = "https://git.jcollie.dev/jeff/zig-svg";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
