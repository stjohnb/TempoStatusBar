{
  description = "TempoStatusBar Linux tray app (Rust) — dev shell and package";

  # nixos-unstable, not a stable release branch, because the Rust toolchain
  # this crate needs (1.92+) isn't backported to stable channels yet. Revisit
  # once a stable release ships it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Darwin shells use the 26.05 stable branch: nixos-unstable (26.11) dropped
  # x86_64-darwin, which both shared Macs still are.
  inputs.nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { self, nixpkgs, nixpkgs-darwin }:
    let
      # Linux systems for the static/GTK builds; the macOS app itself is the Swift/Xcode target.
      # `darwinSystems` below only provides the macOS CI dev shell.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
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

        # Minimal shell for Linux workflow steps that talk to the Forgejo API
        # or AWS — .forgejo/workflows/linux-ci.yml's PR comment,
        # linux-release.yml's version gate and release publish, pr-cleanup.yml
        # and s3-bootstrap.yml. Kept separate from `default` so these jobs
        # never realise the Rust + GTK4 closure. The runner baseline is
        # nix/git/docker only (issue #218); CI uses curl against the Forgejo
        # API, not `gh`.
        ci = pkgs.mkShell {
          packages = [ pkgs.curl pkgs.jq pkgs.awscli2 ];
        };

        # Minimal shell for the Trivy filesystem scan in main-verification.yml,
        # pr-verification.yml and release-tag.yml. Replaces
        # aquasecurity/trivy-action, whose runtime download of the Trivy binary
        # from GitHub releases failed Main Verification (issue #237).
        security = pkgs.mkShell {
          packages = [ pkgs.trivy ];
        };
      })
      # Darwin-only shell for interactive use (CI uses `macos-tools`): SwiftLint and the
      # AWS CLI, pinned by flake.lock instead of an unpinned `brew install`.
      # mkShellNoCC keeps the cc-stdenv Apple SDK hooks from overriding the
      # job's DEVELOPER_DIR, which SwiftLint's SourceKit relies on.
      // nixpkgs.lib.genAttrs darwinSystems (system:
        let pkgs = nixpkgs-darwin.legacyPackages.${system}; in {
          macos = pkgs.mkShellNoCC { packages = [ pkgs.swiftlint pkgs.awscli2 ]; };
        });

      # Tools for the `[host, macos, tempo]` jobs, run with `nix shell`, not
      # `nix develop`: develop fetches bashInteractive from the flake's
      # `nixpkgs` input (unstable, no x86_64-darwin) and falls back to macOS's
      # bash 3.2, which cannot parse the stdenv setup script.
      packages = nixpkgs.lib.genAttrs darwinSystems (system:
        let pkgs = nixpkgs-darwin.legacyPackages.${system}; in {
          macos-tools = pkgs.symlinkJoin {
            name = "macos-ci-tools";
            paths = [ pkgs.swiftlint pkgs.awscli2 ];
          };
        })
      // forAllSystems (pkgs: {
        # `default` is what St-John-Software/nixos-config builds from the public
        # mirror — keep the attribute name.
        default = mkTempoStatusBar { inherit pkgs; rustPlatform = pkgs.rustPlatform; gui = true; };
        # Fully static musl build — the published release artifact. This works
        # only because of the feature flags this crate chose: reqwest's
        # rustls-no-provider plus a ring/webpki-roots config built in
        # tempo.rs (not reqwest's "rustls" feature, whose aws-lc-rs provider
        # needs a C/cmake toolchain; the system cert store is never consulted),
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
