{
  description = "TempoStatusBar Linux tray app (Rust) — dev shell and package";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      # Linux only: the macOS app is the Swift/Xcode target and does not use nix.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Single source of truth for the version: linux/Cargo.toml. The release
      # workflow reads it back out with `nix eval .#static.version`, so the tag,
      # the flake and the binary's --version can never disagree.
      version = (builtins.fromTOML (builtins.readFile ./linux/Cargo.toml)).package.version;
      mkTempoStatusBar = rustPlatform: rustPlatform.buildRustPackage {
        pname = "tempo-statusbar";
        inherit version;
        src = ./linux;
        cargoLock.lockFile = ./linux/Cargo.lock;
        meta = {
          description = "Linux tray companion to the TempoStatusBar macOS menu bar app";
          mainProgram = "tempo-statusbar";
          platforms = nixpkgs.lib.platforms.linux;
        };
      };
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
          ];
        };
      });

      packages = forAllSystems (pkgs: {
        # `default` is what St-John-Software/nixos-config builds from the public
        # mirror — keep the attribute name.
        default = mkTempoStatusBar pkgs.rustPlatform;
        # Fully static musl build — the published release artifact. This works
        # only because of the feature flags this crate chose: rustls-tls +
        # webpki-roots (no rustls-native-certs, so no system cert store),
        # ksni's zbus backend (no libdbus-sys), and no openssl-sys/native-tls.
        # `ring` is the only crate with C/asm and it builds for musl.
        #
        # Defined for aarch64-linux too because the expression costs nothing,
        # but CI only builds and publishes x86_64; other architectures build
        # from source.
        static = mkTempoStatusBar pkgs.pkgsStatic.rustPlatform;
      });
    };
}
