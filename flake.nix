{
  description = "PianoBooster - learn to play the piano";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.pianobooster;

        # Reuse nixpkgs' pianobooster (deps, cmake flags, soundfont patch) and
        # only swap in this checkout as the source.
        pianobooster = pkgs.pianobooster.overrideAttrs (old: {
          version = "1.0.0-dev";

          # Only the files the build reads, so edits to docs, the flake, etc.
          # don't change the source hash and trigger a full rebuild.
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./CMakeLists.txt
              ./src
              ./translations
              ./music
              ./icons
              ./doc/faq.md
              ./pianobooster.desktop
              ./pianobooster.6
              ./license.txt
              ./README.md
              ./Changelog.txt
            ];
          };

          # Provides the "adwaita-dark" QStyle used by QT_STYLE_OVERRIDE.
          buildInputs = old.buildInputs ++ [ pkgs.adwaita-qt6 ];
          qtWrapperArgs = (old.qtWrapperArgs or [ ]) ++ [
            "--prefix QT_PLUGIN_PATH : ${pkgs.adwaita-qt6}/lib/qt-6/plugins"
          ];
        });
      });

      devShells = forAllSystems (pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          pb = self.packages.${system}.pianobooster;

          # PianoBooster looks for a soundfont in <dir of binary>/soundfont/*.sf2;
          # the nixpkgs soundfont patch only applies to `nix build`, not pb-build.
          soundfont = pkgs.soundfont-fluid;

          # Inhibit idle while playing, force the xcb platform plugin (the GL
          # score view misrenders on native Wayland), and use Adwaita dark.
          run = pkgs.writeShellScriptBin "pb-run" ''
            set -euo pipefail
            # CMake's `ADD_SUBDIRECTORY(src build)` nests the binary one level
            # deeper than the build dir; fall back to the flat layout just in case.
            dir="''${PB_BUILD_DIR:-build}"
            bin="$dir/build/pianobooster"
            [ -x "$bin" ] || bin="$dir/pianobooster"
            if [ ! -x "$bin" ]; then
              echo "pb-run: pianobooster not built yet -- run 'pb-build' first" >&2
              exit 1
            fi
            exec ${pkgs.systemd}/bin/systemd-inhibit \
              --what=idle --who=pianobooster --why=Playback \
              env QT_QPA_PLATFORM=xcb QT_STYLE_OVERRIDE=adwaita-dark \
              QT_PLUGIN_PATH="${pkgs.adwaita-qt6}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}" \
              "$bin" "$@"
          '';

          configure = pkgs.writeShellScriptBin "pb-configure" ''
            set -euo pipefail
            exec cmake -S . -B "''${PB_BUILD_DIR:-build}" \
              -DQT_PACKAGE_NAME=Qt6 \
              -DCMAKE_BUILD_TYPE=Debug \
              -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
              -DUSE_BUNDLED_RTMIDI=OFF \
              -DUSE_JACK=ON \
              "$@"
          '';

          build = pkgs.writeShellScriptBin "pb-build" ''
            set -euo pipefail
            dir="''${PB_BUILD_DIR:-build}"
            [ -f "$dir/CMakeCache.txt" ] || pb-configure
            exec cmake --build "$dir" -j"$(nproc)" "$@"
          '';
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ pb ];

            packages = with pkgs; [
              configure
              build
              run
              gdb
              clang-tools # clangd, for editor integration
            ];

            shellHook = ''
              export PB_BUILD_DIR="''${PB_BUILD_DIR:-build}"
              export CMAKE_EXPORT_COMPILE_COMMANDS=1

              # GC-root this shell's dependencies. Without it a periodic nix-gc
              # deletes the Qt/fluidsynth/etc. store paths that the binary and
              # CMakeCache in $PB_BUILD_DIR point at, forcing a rebuild.
              # Re-run on every entry so the root follows flake.lock updates.
              nix build --quiet --no-warn-dirty \
                ".#devShells.${system}.default.inputDerivation" \
                -o .nix-gcroot-devshell 2>/dev/null \
                || echo "warning: could not GC-root the dev shell" >&2

              mkdir -p "$PB_BUILD_DIR/build/soundfont"
              for sf in ${soundfont}/share/soundfonts/*.sf2; do
                ln -sfn "$sf" "$PB_BUILD_DIR/build/soundfont/$(basename "$sf")"
              done

              echo "PianoBooster dev shell (Qt6)"
              echo "  pb-configure   cmake configure into \$PB_BUILD_DIR ($PB_BUILD_DIR)"
              echo "  pb-build       build (configures first if needed)"
              echo "  pb-run         run with systemd-inhibit + xcb + adwaita-dark"
            '';
          };
        });
    };
}
