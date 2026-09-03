{
  description = "TempoStatusBar Linux tray app (Rust) — dev shell and package";

  # nixos-unstable, not a stable release branch, because the Rust toolchain
  # this crate needs (1.92+) isn't backported to stable channels yet. Revisit
  # once a stable release ships it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Linux only: the macOS app is the Swift/Xcode target and does not use nix.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Single source of truth for the version: linux/Cargo.toml. The release
      # workflow reads it back out with `nix eval .#static.version`, so the tag,
      # the flake and the binary's --version can never disagree.
      version = (builtins.fromTOML (builtins.readFile ./linux/Cargo.toml)).package.version;
      # `gui = false` drops the GTK4 windows (and every GTK dependency) via
      # Cargo's `gui` feature — the only way the fully-static musl build can
      # keep working, since GTK cannot be statically linked.
      mkTempoStatusBar = { rustPlatform, pkgs, gui }: rustPlatform.buildRustPackage ({
        pname = "tempo-statusbar";
        inherit version;
        src = ./linux;
        cargoLock.lockFile = ./linux/Cargo.lock;
        meta = {
          description = "Linux tray companion to the TempoStatusBar macOS menu bar app";
          mainProgram = "tempo-statusbar";
          platforms = nixpkgs.lib.platforms.linux;
        };
      } // (if gui then {
        # wrapGAppsHook4 puts the icon theme and GSettings schemas on the
        # binary's environment; without it GTK aborts at window creation.
        nativeBuildInputs = [ pkgs.pkg-config pkgs.wrapGAppsHook4 ];
        buildInputs = [
          pkgs.gtk4
          pkgs.glib
          pkgs.gsettings-desktop-schemas
          pkgs.adwaita-icon-theme
        ];
      } else {
        buildNoDefaultFeatures = true;
      }));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.clippy
            pkgs.rustfmt
            # readelf, for linux-release.yml's static-linkage assertion.
            pkgs.binutils
            # gtk4-sys resolves GTK through pkg-config.
            pkgs.pkg-config
          ];
          buildInputs = [ pkgs.gtk4 pkgs.glib ];
        };

        # Minimal shell for workflow steps that only shell out to the GitHub
        # CLI — linux-release.yml's version gate and release publish, and
        # actions-storage-cleanup.yml. Kept separate from `default` so a
        # gh-only job never realises the Rust + GTK4 closure. The runner
        # baseline is nix/git/docker only; `gh` is not on it (issue #218).
        ci = pkgs.mkShell {
          packages = [ pkgs.gh pkgs.jq ];
        };
      });

      packages = forAllSystems (pkgs: {
        # `default` is what St-John-Software/nixos-config builds from the public
        # mirror — keep the attribute name.
        default = mkTempoStatusBar { inherit pkgs; rustPlatform = pkgs.rustPlatform; gui = true; };
        # Fully static musl build — the published release artifact. This works
        # only because of the feature flags this crate chose: rustls-tls +
        # webpki-roots (no rustls-native-certs, so no system cert store),
        # ksni's zbus backend (no libdbus-sys), and no openssl-sys/native-tls.
        # `ring` is the only crate with C/asm and it builds for musl.
        #
        # The GTK4 GUI is excluded here by design: no Rust GUI toolkit survives
        # static linking, so this build passes --no-default-features and ships
        # the tray plus the CLI only.
        #
        # Defined for aarch64-linux too because the expression costs nothing,
        # but CI only builds and publishes x86_64; other architectures build
        # from source.
        static = mkTempoStatusBar { inherit pkgs; rustPlatform = pkgs.pkgsStatic.rustPlatform; gui = false; };
      });
    };
}
