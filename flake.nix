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
          zig = pkgs.zig_0_17;
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
              # The second oracle, for what resvg does not implement at all --
              # `vector-effect`, which it parses and ignores. Held to the same
              # tolerances; `REFERENCES` in tools/check_oracle.py says which
              # fixtures go to it.
              pkgs.inkscape
              (pkgs.python3.withPackages (ps: [ ps.pillow ]))
              # A font for the text fixtures, and the *same* font for both
              # renderers: resvg is given it with `--use-font-file` and told
              # `--skip-system-fonts`, and this one is handed the same bytes.
              # Comparing text drawn in two different faces would compare the
              # faces rather than the renderers.
              pkgs.dejavu_fonts
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

            # Where the text fixtures' font is. Both `zig build oracle` and
            # `tools/check_oracle.py` read it from here, so that neither has a
            # store path written into it.
            SVG_TEST_FONT = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
            # What that face calls itself, which resvg needs as its default
            # family: told to skip the system fonts it still looks for Times
            # New Roman otherwise, finds nothing, and draws no text at all.
            SVG_TEST_FONT_FAMILY = "DejaVu Sans";
          };
        }
      );
    };
}
