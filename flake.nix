# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-svg - SVG rendering onto z2d surfaces";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    # Turns build.zig.zon into a Nix expression, so that the dependencies are
    # fetched by Nix and the build itself needs no network of its own.
    #
    # An input rather than a `nix run` of it, so that the Zig it runs is this
    # flake's. zon2nix shells out to `zig env` and looks for zig on PATH; run
    # from a shell without one it says "unable to execute zig, is it in your
    # PATH?" and stops without writing anything, so the old build.zig.zon.nix
    # survives looking untouched. The devshell below wraps it so that cannot
    # happen.
    zon2nix = {
      url = "git+https://codeberg.org/jcollie/zon2nix.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zon2nix,
      ...
    }:

    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      # The devshell's Zig, with one line of its own standard library put
      # right, because without it a test executable cannot be built in fuzz
      # mode at all.
      #
      # Zig 0.16.0's `compiler/test_runner.zig` reports a failing fuzz input by
      # asking `std.debug.writeStackTrace` to print what `@errorReturnTrace()`
      # gave it. Those are two different types: an error return trace is a
      # `builtin.StackTrace`, a ring buffer with a write index, where that
      # function takes a `debug.StackTrace`, a plain slice and a count of what
      # was skipped. It is on the path taken only under `-ffuzz`, and it stops
      # *any* project with a fuzz test in it from building one. The fix is the
      # function next door, which takes exactly the type in hand and is what
      # the other three call sites in the same file use.
      #
      # `--replace-fail` is the whole safety of this: the day Zig ships the fix
      # the pattern will not be found, the build will fail here rather than
      # patch something else, and this can go.
      #
      # It buys the fuzzer and not its coverage. Nothing in this release
      # populates the table of program counters, so a bounded run ends with
      # "corrupted coverage file: pcs_len was zero" and an unbounded one panics
      # in the build runner's coverage thread; neither is a finding, and a
      # finding says "input saved to" above the report. `zig build fuzz-run` is
      # the loop that works, and tools/fuzz.zig says why.
      fuzzableZig =
        pkgs:
        let
          # A farm of symlinks rather than a copy: the library is 217 MB, and
          # exactly one file of it is being changed.
          library = pkgs.runCommand "zig-0.16.0-lib-fuzz-fix" { } ''
            cp -rs --no-preserve=mode ${pkgs.zig_0_16}/lib/zig $out
            chmod -R u+w $out
            rm $out/compiler/test_runner.zig
            cp --no-preserve=mode \
              ${pkgs.zig_0_16}/lib/zig/compiler/test_runner.zig \
              $out/compiler/test_runner.zig
            substituteInPlace $out/compiler/test_runner.zig \
              --replace-fail \
                'std.debug.writeStackTrace(trace, stderr)' \
                'std.debug.writeErrorReturnTrace(trace, stderr)'
          '';
        in
        pkgs.symlinkJoin {
          name = "zig-0.16.0-fuzzable";
          paths = [ pkgs.zig_0_16 ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/zig --set ZIG_LIB_DIR ${library}
          '';
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
          zig-svg = pkgs.callPackage ./package.nix { };
        in
        {
          inherit zig-svg;
          default = zig-svg;
          # The Zig package cache on its own, so that a workflow job running
          # `zig build` for something other than the package -- the API
          # documentation -- can have the dependencies without building the
          # package to get at them.
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
        }
      );

      # `nix flake check` builds the package, which runs `zig build test` as
      # its check phase.
      checks = forAllSystems (system: { inherit (self.packages.${system}) zig-svg; });

      overlays.default = final: _prev: {
        zig-svg = final.callPackage ./package.nix { };
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
          zig = fuzzableZig pkgs;
        in
        {
          default = pkgs.mkShell {
            name = "zig-svg";
            nativeBuildInputs = [
              zig
              pkgs.pinact
              pkgs.git-pages-cli
              pkgs.reuse
              # The oracle. This renderer is checked against resvg rather than
              # only against itself, because a test written from our own output
              # agrees with whatever we misread; an independent implementation
              # of the same specification does not. See tools/check_oracle.py.
              pkgs.resvg
              (pkgs.python3.withPackages (ps: [ ps.pillow ]))
              # Regenerates build.zig.zon.nix from build.zig.zon, with the Zig
              # it shells out to fixed to this flake's rather than whatever the
              # caller happens to have.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ zig ]}
                '';
              })
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              # `strace -f` on a sandboxed render is how you find out which
              # system call the filter refused, which the SIGSYS itself does
              # not say. See src/sandbox/seccomp.zig.
              pkgs.strace
            ];
          };
        }
      );
    };
}
