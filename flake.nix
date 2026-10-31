{
  description = "Multi-touch support for external touchscreens on macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./package.nix { };
      });

      homeModules.default = import ./home-module.nix self;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell.override { stdenv = pkgs.swiftPackages.stdenv; } {
          packages = [
            pkgs.swift
            pkgs.swiftpm
          ];
        };
      });
    };
}
